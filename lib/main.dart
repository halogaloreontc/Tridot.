import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app/assistant_theme.dart';
import 'app/home_page.dart';
import 'app/passwords/passwords_kit.dart';
import 'app/voice/voice_kit.dart';
import 'app/voice/vosk_voice_recognizer.dart';
import 'core/app_info.dart';
import 'core/chats/chat_store.dart';
import 'core/connectors/connector.dart';
import 'core/connectors/file_secret_store.dart';
import 'core/connectors/io_http_transport.dart';
import 'core/connectors/manifest/connection.dart';
import 'core/connectors/manifest/connection_service.dart';
import 'core/connectors/manifest/connection_slots.dart';
import 'core/connectors/tasks_connector.dart';
import 'core/downloads/verified_download.dart';
import 'core/extensions/extension_registry.dart';
import 'core/passwords/vault.dart';
import 'core/passwords/vault_crypto.dart';
import 'core/passwords/vault_store.dart';
import 'core/scenario/assistant_controller.dart';
import 'core/scenario/scenario_parser.dart';
import 'core/services/clock.dart';
import 'core/services/task_service.dart';
import 'core/settings/app_settings.dart';
import 'core/skills/calculator/calculator_connector.dart';
import 'core/skills/data/data_connector.dart';
import 'core/skills/passwords/passwords_connector.dart';
import 'core/skills/talk/talk_connector.dart';
import 'core/storage/json_task_repository.dart';
import 'core/storage/storage_info.dart';
import 'core/voice/voice_model.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Лицензии шрифтов Inter, JetBrains Mono и Cormorant Unicase (SIL OFL) —
  // в «Настройки → Лицензии».
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('assets/fonts/Inter-OFL.txt');
    yield LicenseEntryWithLineBreaks(<String>['Inter'], text);
    final mono =
        await rootBundle.loadString('assets/fonts/JetBrainsMono-OFL.txt');
    yield LicenseEntryWithLineBreaks(<String>['JetBrains Mono'], mono);
    final display =
        await rootBundle.loadString('assets/fonts/CormorantUnicase-OFL.txt');
    yield LicenseEntryWithLineBreaks(<String>['Cormorant Unicase'], display);
    // Словари навыка «Пароли»: EFF large (CC BY 3.0 US), SecLists (MIT).
    final words = await rootBundle.loadString('assets/passwords/NOTICE.txt');
    yield LicenseEntryWithLineBreaks(
      <String>['EFF Long Wordlist', 'SecLists'],
      words,
    );
    // Голосовой ввод (ADR-023): libvosk (Vosk, Kaldi, OpenFST — Apache-2.0,
    // OpenBLAS/CLAPACK — BSD) и скачиваемая модель vosk-model-small-ru.
    final voice = await rootBundle.loadString('assets/voice/NOTICE.txt');
    yield LicenseEntryWithLineBreaks(
      <String>['Vosk', 'Kaldi', 'OpenFST', 'OpenBLAS'],
      voice,
    );
  });
  final documents = await getApplicationDocumentsDirectory();
  final folder = p.join(documents.path, 'assistant');
  final tasksPath = p.join(folder, 'tasks.json');
  final repository = JsonTaskRepository(tasksPath);
  // История чатов (ADR-010): файл на чат в <документы>/assistant/chats.
  final chatsPath = p.join(folder, 'chats');
  const clock = SystemClock();
  final tasks = TaskService(repository: repository, clock: clock);
  // Паки — только данные (ADR-005): встроенные из assets/packs,
  // пользовательские — в <документы>/assistant/packs.
  final packs = PackStore(
    loadBuiltIn: _builtInPacks,
    userDirectory: p.join(folder, 'packs'),
  );
  // Подключения к приложениям assistant/1 (ADR-011): секреты — в служебной
  // папке приложения, отдельно от задач и settings.json; состояние и кэш
  // описаний — в <документы>/assistant/connections. Выключены, пока их не
  // подключат в «Настройки → Подключения».
  final support = await getApplicationSupportDirectory();
  final secrets = FileSecretStore(
    p.join(support.path, 'assistant', 'secrets.json'),
  );
  final transport = IoHttpTransport();
  final connectionStore = JsonConnectionStore(p.join(folder, 'connections'));
  final connections = <ConnectionService>[
    for (final slot in ConnectionSlots.all)
      await ConnectionService.restore(
        slot: slot,
        transport: transport,
        secrets: secrets,
        store: connectionStore,
        builtIn: await _builtInManifest(slot.builtInAsset),
        clock: clock,
      ),
  ];
  // Хранилище паролей (ADR-014): <поддержка>/assistant/vault, отдельно от
  // secrets.json склада (D19) и исключено из облачной копии Android
  // (D20). Транспорт ему не передаётся. Навык видит только VaultFacade;
  // показ, копирование и ввод — экраны и карточки lib/app. Если libsodium
  // не загрузилась — навык честно говорит, что хранилище недоступно.
  final vault = await _openVault(p.join(support.path, 'assistant', 'vault'));
  final passwords = vault == null ? null : PasswordsKit(vault: vault);
  // Словари генератора и оценки — встроенные файлы, без сети.
  await passwords?.loadWordlists(rootBundle.loadString);
  // Навыки и подключения регистрируются здесь; порядок важен только при
  // равной уверенности (тогда маршрутизатор всё равно переспросит). Что
  // включено — выбор пользователя в «Настройки → Расширения».
  final extensions = ExtensionRegistry(
    connectors: <Connector>[
      TasksConnector(taskService: tasks, parser: ScenarioParser(clock: clock)),
      for (final connection in connections) connection.connector,
      const CalculatorConnector(),
      TalkConnector(taskService: tasks),
      // Включаемый навык вне ролей, по умолчанию выключен (D1).
      PasswordsConnector(
        vault: passwords?.facade,
        canCopySecrets: passwords?.canCopySecrets ?? false,
        vaultExisted: () => passwords?.vaultExisted ?? false,
      ),
      // Копия и «хранилище» без опоры на пароли: уточняющий вопрос
      // «Копию чего: паролей или всех данных?» (решения владельца 3, 5).
      // Включён всегда.
      const DataConnector(),
    ],
    packs: packs,
  );
  await packs.load();
  // Голосовой ввод (ADR-023): пока только Android — libvosk приходит из
  // AAR только для arm64-v8a. Модель скачивается по требованию в
  // <поддержка>/assistant/voice (исключена из резервной копии Android).
  final voice = Platform.isAndroid
      ? VoiceKit(
          recognizer: VoskVoiceRecognizer(),
          downloader: IoFileDownloader(),
          spec: VoiceModelSpec.ruSmall,
          dir: p.join(support.path, 'assistant', 'voice'),
        )
      : null;
  await voice?.refresh();
  // SecretGuard: при открытом хранилище пароль в чате узнаётся и по
  // отпечатку, без слова «пароль».
  final assistant = AssistantController(
    extensions: extensions,
    clock: clock,
    knownSecret: passwords?.facade.knownSecret,
  );
  runApp(
    AssistantApp(
      assistant: assistant,
      tasks: tasks,
      clock: clock,
      storage: JsonStorageInfo(tasksPath, chatsDirectory: chatsPath),
      settingsStore: JsonSettingsStore(p.join(folder, 'settings.json')),
      chatStore: JsonChatStore(chatsPath),
      connections: connections,
      passwords: passwords,
      voice: voice,
    ),
  );
}

/// Хранилище паролей или `null`, если libsodium недоступна.
Future<Vault?> _openVault(String directory) async {
  try {
    final vault = Vault(
      store: FileVaultStore(directory),
      crypto: await SodiumVaultCrypto.load(),
      device: Platform.isAndroid || Platform.isIOS
          ? VaultDevice.mobile
          : VaultDevice.desktop,
    );
    await vault.load();
    return vault;
  } on Object {
    return null;
  }
}

/// Встроенная копия описания из assets или `null`.
Future<String?> _builtInManifest(String? asset) async {
  if (asset == null) return null;
  try {
    return await rootBundle.loadString(asset);
  } on Object {
    return null;
  }
}

/// Тексты встроенных паков: все `assets/packs/*.json` из манифеста.
Future<List<String>> _builtInPacks() async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final paths = manifest
      .listAssets()
      .where(
        (String path) =>
            path.startsWith('assets/packs/') && path.endsWith('.json'),
      )
      .toList()
    ..sort();
  return <String>[for (final path in paths) await rootBundle.loadString(path)];
}

final class AssistantApp extends StatelessWidget {
  const AssistantApp({
    super.key,
    required this.assistant,
    required this.tasks,
    this.clock = const SystemClock(),
    this.storage = const MemoryStorageInfo(),
    this.settingsStore,
    this.chatStore,
    this.connections = const <ConnectionService>[],
    this.passwords,
    this.voice,
  });

  final AssistantController assistant;
  final TaskService tasks;
  final Clock clock;
  final StorageInfo storage;
  final SettingsStore? settingsStore;
  final ChatStore? chatStore;

  /// Подключения к приложениям: экран «Настройки → Подключения».
  final List<ConnectionService> connections;

  /// Навык «Пароли»; `null` — libsodium не загрузилась.
  final PasswordsKit? passwords;

  /// Голосовой ввод; `null` — платформа без движка распознавания.
  final VoiceKit? voice;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppInfo.name,
      debugShowCheckedModeBanner: false,
      theme: AssistantTheme.dark(),
      darkTheme: AssistantTheme.dark(),
      themeMode: ThemeMode.dark,
      home: HomePage(
        assistant: assistant,
        tasks: tasks,
        clock: clock,
        storage: storage,
        settingsStore: settingsStore,
        chatStore: chatStore,
        connections: connections,
        passwords: passwords,
        voice: voice,
      ),
    );
  }
}
