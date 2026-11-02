import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app/home_page.dart';
import 'core/scenario/assistant_controller.dart';
import 'core/scenario/scenario_parser.dart';
import 'core/services/clock.dart';
import 'core/services/task_service.dart';
import 'core/storage/json_task_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final documents = await getApplicationDocumentsDirectory();
  final repository =
      JsonTaskRepository(p.join(documents.path, 'assistant', 'tasks.json'));
  const clock = SystemClock();
  final tasks = TaskService(repository: repository, clock: clock);
  final assistant = AssistantController(
    taskService: tasks,
    parser: ScenarioParser(clock: clock),
  );
  runApp(AssistantApp(assistant: assistant, tasks: tasks));
}

final class AssistantApp extends StatelessWidget {
  const AssistantApp({super.key, required this.assistant, required this.tasks});

  final AssistantController assistant;
  final TaskService tasks;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Личный помощник',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF176B68),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF4F6F5),
      ),
      home: HomePage(assistant: assistant, tasks: tasks),
    );
  }
}
