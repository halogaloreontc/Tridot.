import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app/assistant_theme.dart';
import 'app/home_page.dart';
import 'core/connectors/connector.dart';
import 'core/connectors/tasks_connector.dart';
import 'core/extensions/extension_registry.dart';
import 'core/scenario/assistant_controller.dart';
import 'core/scenario/scenario_parser.dart';
import 'core/services/clock.dart';
import 'core/services/task_service.dart';
import 'core/settings/app_settings.dart';
import 'core/skills/calculator/calculator_connector.dart';
import 'core/skills/talk/talk_connector.dart';
import 'core/storage/json_task_repository.dart';
import 'core/storage/storage_info.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Лицензии шрифтов Inter и JetBrains Mono (SIL OFL) — в «Настройки → Лицензии».
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('assets/fonts/Inter-OFL.txt');
    yield LicenseEntryWithLineBreaks(<String>['Inter'], text);
    final mono =
        await rootBundle.loadString('assets/fonts/JetBrainsMono-OFL.txt');
    yield LicenseEntryWithLineBreaks(<String>['JetBrains Mono'], mono);
  });
  final documents = await getApplicationDocumentsDirectory();
  final folder = p.join(documents.path, 'assistant');
  final tasksPath = p.join(folder, 'tasks.json');
  final repository = JsonTaskRepository(tasksPath);
  const clock = SystemClock();
  final tasks = TaskService(repository: repository, clock: clock);
  // Паки — только данные (ADR-005): встроенные из assets/packs,
  // пользовательские — в <документы>/assistant/packs.
  final packs = PackStore(
    loadBuiltIn: _builtInPacks,
    userDirectory: p.join(folder, 'packs'),
  );
  // Навыки и подключения регистрируются здесь; порядок важен только при
  // равной уверенности (тогда маршрутизатор всё равно переспросит). Что
  // включено — выбор пользователя в «Настройки → Расширения».
  final extensions = ExtensionRegistry(
    connectors: <Connector>[
      TasksConnector(taskService: tasks, parser: ScenarioParser(clock: clock)),
      const CalculatorConnector(),
      TalkConnector(taskService: tasks),
    ],
    packs: packs,
  );
  await packs.load();
  final assistant = AssistantController(extensions: extensions, clock: clock);
  runApp(
    AssistantApp(
      assistant: assistant,
      tasks: tasks,
      clock: clock,
      storage: JsonStorageInfo(tasksPath),
      settingsStore: JsonSettingsStore(p.join(folder, 'settings.json')),
    ),
  );
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
  });

  final AssistantController assistant;
  final TaskService tasks;
  final Clock clock;
  final StorageInfo storage;
  final SettingsStore? settingsStore;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Личный помощник',
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
      ),
    );
  }
}
