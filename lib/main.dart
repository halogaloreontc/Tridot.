import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app/assistant_theme.dart';
import 'app/home_page.dart';
import 'core/scenario/assistant_controller.dart';
import 'core/scenario/scenario_parser.dart';
import 'core/services/clock.dart';
import 'core/services/task_service.dart';
import 'core/settings/app_settings.dart';
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
  final assistant = AssistantController(
    taskService: tasks,
    parser: ScenarioParser(clock: clock),
    clock: clock,
  );
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
