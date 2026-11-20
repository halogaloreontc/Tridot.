import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app/assistant_theme.dart';
import 'app/extensions/tool_kit.dart';
import 'app/extensions/weather_kit.dart';
import 'app/extensions/ytdl_kit.dart';
import 'app/links/incoming_links.dart';
import 'app/links/link_opener.dart';
import 'app/security/sealed_secret_store.dart';
import 'app/files/file_opener.dart';
import 'app/jobs/job_picker.dart';
import 'app/jobs/media_channel_bridge.dart';
import 'app/home_page.dart';
import 'app/homescreen/home_screen_channel.dart';
import 'app/notify/notify_channel.dart';
import 'app/passwords/device_keys.dart';
import 'app/passwords/passwords_kit.dart';
import 'app/security/app_lock.dart';
import 'app/security/device_auth.dart';
import 'app/intent/intent_kit.dart';
import 'app/intent/intent_setup.dart';
import 'app/voice/device_voice_recognizer.dart';
import 'app/voice/voice_kit.dart';
import 'app/voice/vosk_voice_recognizer.dart';
import 'app/widgets/keyboard_safe.dart';
import 'core/app_info.dart';
import 'core/build_flags.dart';
import 'core/chats/chat_store.dart';
import 'core/connectors/connector.dart';
import 'core/connectors/manifest/warehouse_signals.dart';
import 'core/connectors/io_http_transport.dart';
import 'core/connectors/manifest/app_connections.dart';
import 'core/connectors/manifest/connection_directory_io.dart';
import 'core/connectors/manifest/connection_store_io.dart';
import 'core/connectors/manifest/connection_service.dart';
import 'core/connectors/manifest/connection_slots.dart';
import 'core/connectors/tasks_connector.dart';
import 'core/downloads/verified_download.dart';
import 'core/extensions/extension_registry.dart';
import 'core/extensions/tools/tool_spec.dart';
import 'core/jobs/extension_card.dart';
import 'core/passwords/vault.dart';
import 'core/passwords/vault_crypto.dart';
import 'core/passwords/vault_store.dart';
import 'core/scenario/assistant_controller.dart';
import 'core/scenario/connector_assembly.dart';
import 'core/scenario/scenario_parser.dart';
import 'core/services/clock.dart';
import 'core/services/task_service.dart';
import 'core/settings/app_settings.dart';
import 'core/skills/alarm/alarm_connector.dart';
import 'core/skills/archiver/archiver_connector.dart';
import 'core/skills/calculator/calculator_connector.dart';
import 'core/skills/converter/converter_connector.dart';
import 'core/skills/converter/platform_media_job.dart';
import 'core/skills/data/data_connector.dart';
import 'core/skills/files/files_connector.dart';
import 'core/skills/passwords/passwords_connector.dart';
import 'core/skills/talk/talk_connector.dart';
import 'core/skills/weather/weather_connector.dart';
import 'core/skills/ytdl/ytdl_connector.dart';
import 'core/skills/ytdl/ytdl_unavailable.dart';
import 'core/storage/json_task_repository.dart';
import 'core/storage/storage_info.dart';
import 'core/voice/voice_model.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Лицензии шрифтов Golos Text, JetBrains Mono и Cormorant Unicase (SIL OFL) —
  // в «Настройки → Лицензии».
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('assets/fonts/GolosText-OFL.txt');
    yield LicenseEntryWithLineBreaks(<String>['Golos Text'], text);
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
    // Расширения (ADR-024, ADR-026): ffmpeg (LGPL, с libmp3lame) и yt-dlp
    // скачиваются по кнопке, в приложение не встроены; LAME 3.100 встроен
    // (libtridot_mp3, LGPL-2.0-or-later) — раздел 4 файла, полный текст
    // LGPL — в разделе пакета «tridot_lame» (его LICENSE Flutter добавляет
    // сам); AndroidX Media3 (Apache-2.0) — раздел 5: лицензии библиотек
    // Android Flutter сам не показывает.
    final tools = await rootBundle.loadString('assets/extensions/NOTICE.txt');
    yield LicenseEntryWithLineBreaks(
      <String>[
        'FFmpeg',
        'LAME',
        'image',
        if (!kPlayBuild) 'yt-dlp',
        'Media3',
      ],
      tools,
    );
  });
  // Временные папки задач расширений прошлого запуска (копии вложений из
  // памяти, результаты в режиме «Только в памяти») больше не нужны.
  await _dropJobTemp();
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
  // Секреты подключений (ADR-031): Android Keystore (AES-GCM, файл
  // secrets.sealed), связка ключей Mac, DPAPI на Windows; Linux — файл
  // 600. Прежний открытый secrets.json переносится и стирается; не
  // вышло — остаётся в работе он.
  final secretsChoice = await openSecretStore(
    plainPath: p.join(support.path, 'assistant', 'secrets.json'),
    secure: switch (currentJobPlatform()) {
      JobPlatform.android => SealedSecretStore(
          p.join(support.path, 'assistant', 'secrets.sealed'),
          const AndroidKeystoreSealer(),
        ),
      JobPlatform.windows => SealedSecretStore(
          p.join(support.path, 'assistant', 'secrets.sealed'),
          const DpapiSealer(),
        ),
      JobPlatform.macos => const KeychainSecretStore(),
      _ => null,
    },
    backend: switch (currentJobPlatform()) {
      JobPlatform.android => SecretBackend.keystore,
      JobPlatform.windows => SecretBackend.dpapi,
      JobPlatform.macos => SecretBackend.keychain,
      _ => SecretBackend.file,
    },
  );
  final secrets = secretsChoice.store;
  final transport = IoHttpTransport();
  final connectionStore = JsonConnectionStore(p.join(folder, 'connections'));
  final device = switch (currentJobPlatform()) {
    JobPlatform.android => 'Связной · Android',
    JobPlatform.macos => 'Связной · Mac',
    JobPlatform.windows => 'Связной · Windows',
    _ => 'Связной · Linux',
  };
  final knownConnections = <ConnectionService>[
    for (final slot in ConnectionSlots.all)
      await ConnectionService.restore(
        slot: slot,
        transport: transport,
        secrets: secrets,
        store: connectionStore,
        builtIn: await _builtInManifest(slot.builtInAsset),
        clock: clock,
        device: device,
      ),
  ];
  // Приложения из каталога подключений (ADR-039): connections/_directory.json,
  // закреплённые описания рядом. Склад в каталоге не хранится.
  ExtensionRegistry? registry;
  final appConnections = AppConnections(
    transport: transport,
    secrets: secrets,
    store: connectionStore,
    directory: JsonConnectionDirectory(p.join(folder, 'connections')),
    known: knownConnections,
    clock: clock,
    device: device,
    reservedIds: () => <String>{
      for (final connector in registry?.connectors ?? const <Connector>[])
        connector.info.id,
      for (final installed in registry?.packs.packs ?? const <InstalledPack>[])
        installed.pack.id,
    },
  );
  await appConnections.load();
  final connections = appConnections.services;
  // Сигналы склада (ADR-031): только пока приложение открыто — паузу и
  // продолжение даёт HomePage по жизненному циклу.
  final signals = <WarehouseSignals>[
    for (final connection in knownConnections)
      if (connection.slot.id == ConnectionSlots.warehouse.id)
        WarehouseSignals(
          service: connection,
          transport: transport,
          secrets: secrets,
          clock: clock,
        ),
  ];
  // «Открыть в Tridot» и «Поделиться» ссылкой склада: Android и Mac.
  final platformNow = currentJobPlatform();
  final incoming =
      platformNow == JobPlatform.android || platformNow == JobPlatform.macos
          ? IncomingLinks()
          : null;
  // Хранилище паролей (ADR-014): <поддержка>/assistant/vault, отдельно от
  // secrets.json склада (D19) и исключено из облачной копии Android
  // (D20). Транспорт ему не передаётся. Навык видит только VaultFacade;
  // показ, копирование и ввод — экраны и карточки lib/app. Если libsodium
  // не загрузилась — навык честно говорит, что хранилище недоступно.
  // Ключ устройства для сейфа (ADR-025): Android Keystore, DPAPI на
  // Windows, файл в <поддержка>/assistant/vault_keys на macOS и Linux.
  final vault = await _openVault(
    p.join(support.path, 'assistant', 'vault'),
    keys: p.join(support.path, 'assistant', 'vault_keys'),
  );
  final passwords = vault == null ? null : PasswordsKit(vault: vault);
  // Словари генератора и оценки — встроенные файлы, без сети.
  await passwords?.loadWordlists(rootBundle.loadString);
  // Навыки и подключения регистрируются здесь; порядок важен только при
  // равной уверенности (тогда маршрутизатор всё равно переспросит). Что
  // включено — выбор пользователя в «Настройки → Расширения».
  // ffmpeg для конвертера (ADR-024): только Windows и Linux, скачивается
  // по кнопке в <поддержка>/assistant/tools/ffmpeg, проверяется по
  // закреплённой SHA-256.
  final ffmpegSpec = ToolSpecs.forCurrentPlatform('ffmpeg');
  final ffmpeg = (Platform.isWindows || Platform.isLinux) &&
          ffmpegSpec != null &&
          ffmpegSpec.available
      ? ToolKit(
          spec: ffmpegSpec,
          downloader: IoFileDownloader(
            allowedRedirectHosts: ffmpegSpec.redirectHosts,
          ),
          dir: p.join(support.path, 'assistant', 'tools', 'ffmpeg'),
        )
      : null;
  await ffmpeg?.refresh();
  // Звук и видео на телефоне и Mac (ADR-026): средства системы и
  // встроенный LAME. Что они умеют на этом устройстве — один вопрос при
  // запуске; не ответили — там конвертируются только картинки.
  NativeMedia? nativeMedia;
  final platform = currentJobPlatform();
  if (platform == JobPlatform.android || platform == JobPlatform.macos) {
    final bridge = ChannelMediaBridge();
    final caps = await loadNativeMediaCaps(bridge, platform: platform);
    if (caps.targets.isNotEmpty) {
      nativeMedia = NativeMedia(
        caps: caps,
        runner: PlatformMediaJobRunner(bridge),
      );
    }
  }
  final converterEnvironment = _ConverterEnvironment(
    ffmpeg,
    nativeMedia?.caps ?? NativeMediaCaps.none,
  );
  // Загрузчик видео (ADR-024, шаг 3): только Windows и Linux и не в сборке
  // для Google Play (`--dart-define=TRIDOT_STORE=play`): там его код
  // выбрасывается как недостижимый. yt-dlp скачивается по кнопке в
  // <поддержка>/assistant/tools/ytdlp, проверяется по закреплённой
  // SHA-256.
  YtdlKit? ytdl;
  if (!kPlayBuild && ytdlSupported(currentJobPlatform())) {
    final ytdlpSpec = ToolSpecs.forCurrentPlatform('ytdlp');
    if (ytdlpSpec != null) {
      ytdl = YtdlKit(
        tool: ToolKit(
          spec: ytdlpSpec,
          downloader: IoFileDownloader(
            allowedRedirectHosts: ytdlpSpec.redirectHosts,
          ),
          dir: p.join(support.path, 'assistant', 'tools', 'ytdlp'),
        ),
        settingsPath: p.join(support.path, 'assistant', 'ytdl.json'),
        defaultRoot: () async => (await getDownloadsDirectory())?.path,
      );
      await ytdl.tool.refresh();
      await ytdl.load();
    }
  }
  // Уведомления о задачах и будильник в «Часах» (ADR-029): свой канал
  // `tridot/notify` на Android и macOS, на остальных — нет.
  final notify = NotifyPlatform.current();
  // Виджеты рабочего стола (ADR-034): «Сегодня», «Быстрый ввод» и оба
  // вместе — свой канал `tridot/homescreen`, только Android. Снимок задач
  // остаётся на устройстве.
  final homeScreen = HomeScreenPlatform.current();
  // Погода (ADR-030): выключена по умолчанию; Open-Meteo — только после
  // «Разрешить», своя ссылка и приложение открываются системой. Настройки
  // и кэш — в <поддержка>/assistant/weather, на устройстве.
  final weatherService = WeatherService(
    transport: transport,
    store: JsonWeatherStore(p.join(support.path, 'assistant', 'weather')),
    clock: clock,
  );
  final weather = WeatherKit(
    service: weatherService,
    links: LinkOpener(platform: currentJobPlatform()),
  );
  await weather.load();
  // Один путь сборки коннекторов — при запуске и после «Подключить» /
  // «Удалить» приложение (ADR-039): реестр пересобирается между ходами.
  final assembly = ConnectorAssembly(
    connections: appConnections,
    before: <Connector>[
      TasksConnector(taskService: tasks, parser: ScenarioParser(clock: clock)),
    ],
    after: <Connector>[
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
      // Архиватор ZIP (ADR-024): расширение, выключено по умолчанию; ведёт
      // Лиорио. Работа — в отдельном изоляте по кнопке карточки.
      ArchiverConnector(),
      // Конвертер (ADR-024, ADR-026): картинки — везде на Dart, звук и
      // видео — скачиваемым ffmpeg на Windows и Linux, средствами системы
      // на телефоне и Mac.
      ConverterConnector(environment: converterEnvironment),
      // Погода (ADR-030): ведёт Связной; сеть — только с разрешения.
      WeatherConnector(backend: weatherService, clock: clock),
      // Будильник и таймер (ADR-029): открывает «Часы» с заполненным
      // будильником, человек подтверждает там. Ведёт Нода (оповещения).
      AlarmConnector(setter: NotifyAlarmSetter(notify)),
      // «Удали этот файл» (ADR-028): результат карточки или вложение из
      // «Файлов сессии», только после подтверждения. Ведёт Лиорио.
      FilesConnector(),
      // Загрузчик видео: ссылка уходит только в yt-dlp. Где его нет
      // (Android, macOS, сборка для Google Play), на те же фразы Лиорио
      // честно отвечает, почему, — без карточки и без ссылки в ответе.
      if (!kPlayBuild && ytdl != null)
        YtdlConnector()
      else
        YtdlUnavailableConnector(
          YtdlUnavailableReason.of(currentJobPlatform(), play: kPlayBuild),
        ),
    ],
  );
  final extensions = ExtensionRegistry(
    connectors: assembly.build(),
    packs: packs,
  );
  registry = extensions;
  await packs.load();
  // Голосовой ввод (ADR-023): пока только Android — libvosk приходит из
  // AAR только для arm64-v8a. Модель скачивается по требованию в
  // <поддержка>/assistant/voice (исключена из резервной копии Android).
  // Где телефон сам распознаёт русский без интернета (Android 12+,
  // createOnDeviceSpeechRecognizer), модель не нужна.
  final voice = Platform.isAndroid
      ? VoiceKit(
          recognizer: VoskVoiceRecognizer(),
          device: DeviceVoiceRecognizer(),
          downloader: IoFileDownloader(),
          spec: VoiceModelSpec.ruSmall,
          dir: p.join(support.path, 'assistant', 'voice'),
        )
      : null;
  await voice?.refresh();
  await voice?.refreshDevice();
  // SecretGuard: при открытом хранилище пароль в чате узнаётся и по
  // отпечатку, без слова «пароль».
  // «Открыть» у результата архиватора на Android — только файлы из папок
  // приложения (то же проверяет MainActivity).
  final opener = Platform.isAndroid
      ? FileOpener(
          platform: JobPlatform.android,
          allowedRoots: <String>[
            folder,
            (await getTemporaryDirectory()).path,
          ],
        )
      : null;
  final assistant = AssistantController(
    extensions: extensions,
    clock: clock,
    knownSecret: passwords?.facade.knownSecret,
  );
  assembly.attach(extensions, assistant);
  // Запасной слой понимания (ADR-041): на «не понял» — «Похоже, вы хотите
  // …?». Память (личные примеры, журнал непонятых) — в
  // <поддержка>/assistant/intent, только на устройстве. Модель — уровень
  // из «Настройки → Понимание фраз» (IntentKit): скачивается только по
  // кнопке, грузится в фоне после чтения настроек, не задерживая запуск.
  // Без модели ответы правил те же.
  final intentSetup = await IntentSetup.open(
    support.path,
    knownSecret: passwords?.facade.knownSecret,
    clock: clock,
  );
  assistant.intent = intentSetup.fallback;
  final intent = IntentKit(
    host: intentSetup,
    transport: transport,
    downloader: IoFileDownloader(
      allowedRedirectHosts: IntentRelease.redirectHosts,
    ),
    root: intentSetup.root,
  );
  await intent.refresh();
  // Вход в приложение по отпечатку / Face ID (ADR-025): включён — экран
  // закрыт с первого кадра, до загрузки остального интерфейса.
  final settingsStore = JsonSettingsStore(p.join(folder, 'settings.json'));
  final early = await settingsStore.load();
  final appLock = AppLockController(
    auth: DeviceAuth.current,
    enabled: early.appLock,
    after: Duration(seconds: early.appLockAfter),
  );
  runApp(
    AssistantApp(
      assistant: assistant,
      tasks: tasks,
      clock: clock,
      storage: JsonStorageInfo(tasksPath, chatsDirectory: chatsPath),
      settingsStore: settingsStore,
      appLock: appLock,
      chatStore: JsonChatStore(chatsPath),
      connections: connections,
      appConnections: appConnections,
      passwords: passwords,
      voice: voice,
      intent: intent,
      fileOpener: opener,
      ffmpeg: ffmpeg,
      nativeMedia: nativeMedia,
      ytdl: ytdl,
      weather: weather,
      notify: notify,
      homeScreen: homeScreen,
      incoming: incoming,
      signals: signals,
      initialAppearance: early.appearance,
      initialReduceMotion: early.reduceMotion,
    ),
  );
}

/// Платформа, готовность ffmpeg и системный конвертер — для текста ответа
/// конвертера.
final class _ConverterEnvironment implements ConverterEnvironment {
  _ConverterEnvironment(this.ffmpeg, this.native);

  final ToolKit? ffmpeg;

  @override
  JobPlatform get platform => currentJobPlatform();

  @override
  bool get ffmpegReady => ffmpeg?.isInstalled ?? false;

  /// Что умеет система телефона или Mac (ADR-026).
  @override
  final NativeMediaCaps native;
}

/// Удаляет `<временная папка>/tridot-jobs` целиком; ошибки — молча.
Future<void> _dropJobTemp() async {
  try {
    final temp = await getTemporaryDirectory();
    final jobs = Directory(p.join(temp.path, 'tridot-jobs'));
    if (await jobs.exists()) await jobs.delete(recursive: true);
    if (Platform.isAndroid) await dropPickerLeftovers(temp);
  } on Object {
    // Не вышло — уберём при следующем запуске.
  }
}

/// Хранилище паролей или `null`, если libsodium недоступна.
Future<Vault?> _openVault(String directory, {required String keys}) async {
  try {
    final crypto = await SodiumVaultCrypto.load();
    final vault = Vault(
      store: FileVaultStore(directory),
      crypto: crypto,
      device: Platform.isAndroid || Platform.isIOS
          ? VaultDevice.mobile
          : VaultDevice.desktop,
      deviceKey: deviceKeyFor(keys, crypto),
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

/// Режим темы для оформления из настроек (ADR-027).
ThemeMode themeModeOf(AppAppearance appearance) => switch (appearance) {
      AppAppearance.system => ThemeMode.system,
      AppAppearance.light => ThemeMode.light,
      AppAppearance.dark => ThemeMode.dark,
    };

/// Значки строки состояния и цвет системной панели навигации под тему.
SystemUiOverlayStyle overlayStyleFor(ThemeData theme) {
  final light = theme.brightness == Brightness.light;
  final background = theme.scaffoldBackgroundColor;
  return (light ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light)
      .copyWith(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: background,
    systemNavigationBarIconBrightness:
        light ? Brightness.dark : Brightness.light,
  );
}

final class AssistantApp extends StatefulWidget {
  const AssistantApp({
    super.key,
    required this.assistant,
    required this.tasks,
    this.clock = const SystemClock(),
    this.storage = const MemoryStorageInfo(),
    this.settingsStore,
    this.chatStore,
    this.connections = const <ConnectionService>[],
    this.appConnections,
    this.passwords,
    this.voice,
    this.intent,
    this.fileOpener,
    this.ffmpeg,
    this.nativeMedia,
    this.ytdl,
    this.weather,
    this.notify,
    this.homeScreen,
    this.appLock,
    this.incoming,
    this.signals = const <WarehouseSignals>[],
    this.initialAppearance = AppAppearance.system,
    this.initialReduceMotion = false,
  });

  /// Оформление, прочитанное из настроек до первого кадра.
  final AppAppearance initialAppearance;

  /// «Меньше анимации» из настроек до первого кадра: смена темы без
  /// перетекания цветов.
  final bool initialReduceMotion;

  final AssistantController assistant;
  final TaskService tasks;
  final Clock clock;
  final StorageInfo storage;
  final SettingsStore? settingsStore;
  final ChatStore? chatStore;

  /// Подключения к приложениям: экран «Настройки → Подключения».
  final List<ConnectionService> connections;

  /// Каталог подключений (ADR-039): «Подключить приложение».
  final AppConnections? appConnections;

  /// Навык «Пароли»; `null` — libsodium не загрузилась.
  final PasswordsKit? passwords;

  /// Голосовой ввод; `null` — платформа без движка распознавания.
  final VoiceKit? voice;

  /// Модель понимания (ADR-041); `null` — раздела «Понимание фраз» нет.
  final IntentKit? intent;

  /// «Открыть» у результата карточки расширения; `null` — по умолчанию.
  final FileOpener? fileOpener;

  /// ffmpeg конвертера; `null` — платформа без него.
  final ToolKit? ffmpeg;

  /// Системный конвертер звука и видео; `null` — его нет.
  final NativeMedia? nativeMedia;

  /// Загрузчик видео; `null` — нет в этой сборке или на платформе.
  final YtdlKit? ytdl;

  /// Погода (ADR-030).
  final WeatherKit? weather;

  /// Вход в приложение по отпечатку / Face ID; `null` — нет замка.
  final AppLockController? appLock;

  /// Уведомления и будильник (ADR-029); `null` — их нет.
  final NotifyPlatform? notify;

  /// Виджеты рабочего стола (ADR-034); `null` — их нет.
  final HomeScreenPlatform? homeScreen;

  /// «Открыть в Tridot» и «Поделиться» (ADR-031); `null` — нет.
  final IncomingLinks? incoming;

  /// Сигналы склада, пока приложение открыто (ADR-031).
  final List<WarehouseSignals> signals;

  @override
  State<AssistantApp> createState() => _AssistantAppState();
}

final class _AssistantAppState extends State<AssistantApp> {
  /// Режим темы: меняется из настроек без перезапуска, состояние экранов
  /// (поле ввода, открытый Сейф) остаётся.
  late final ValueNotifier<ThemeMode> _themeMode =
      ValueNotifier<ThemeMode>(themeModeOf(widget.initialAppearance));

  /// «Меньше анимации»: тема меняется сразу, без перетекания (§5.6).
  late final ValueNotifier<bool> _reduceMotion =
      ValueNotifier<bool>(widget.initialReduceMotion);

  @override
  void dispose() {
    _themeMode.dispose();
    _reduceMotion.dispose();
    super.dispose();
  }

  Widget _overlay(BuildContext context, Widget child) =>
      AnnotatedRegion<SystemUiOverlayStyle>(
        value: overlayStyleFor(Theme.of(context)),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final lock = widget.appLock;
    final home = HomePage(
      assistant: widget.assistant,
      tasks: widget.tasks,
      clock: widget.clock,
      storage: widget.storage,
      settingsStore: widget.settingsStore,
      chatStore: widget.chatStore,
      connections: widget.connections,
      appConnections: widget.appConnections,
      passwords: widget.passwords,
      voice: widget.voice,
      intent: widget.intent,
      fileOpener: widget.fileOpener,
      ffmpeg: widget.ffmpeg,
      nativeMedia: widget.nativeMedia,
      ytdl: widget.ytdl,
      weather: widget.weather,
      incoming: widget.incoming,
      signals: widget.signals,
      notify: widget.notify,
      homeScreen: widget.homeScreen,
      appLock: widget.appLock,
      onAppearanceChanged: (AppAppearance appearance) =>
          _themeMode.value = themeModeOf(appearance),
      onReduceMotionChanged: (bool reduce) => _reduceMotion.value = reduce,
    );
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[_themeMode, _reduceMotion]),
      builder: (BuildContext context, Widget? _) => MaterialApp(
        builder: (BuildContext context, Widget? child) {
          final content = child ?? const SizedBox.shrink();
          // Поле в фокусе — целиком над клавиатурой (ADR-040).
          return KeyboardSafeScope(
            child: _overlay(
              context,
              lock == null
                  ? content
                  : AppLockGate(controller: lock, child: content),
            ),
          );
        },
        title: AppInfo.name,
        debugShowCheckedModeBanner: false,
        theme: AssistantTheme.light(),
        darkTheme: AssistantTheme.dark(),
        themeMode: _themeMode.value,
        themeAnimationDuration:
            _reduceMotion.value ? Duration.zero : kThemeAnimationDuration,
        home: home,
      ),
    );
  }
}
