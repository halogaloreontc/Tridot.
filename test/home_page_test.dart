import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';
import 'package:local_assistant/core/storage/task_repository.dart';

final class _BrokenRepository implements TaskRepository {
  @override
  Future<List<Task>> list() async => throw const FormatException('битый файл');

  @override
  Future<Task?> get(String id) async => null;

  @override
  Future<void> save(Task task) async {}
}

Widget buildApp({TaskRepository? repository, TaskService? service}) {
  final clock = FixedClock(DateTime(2026, 11, 4, 12));
  final tasks = service ??
      TaskService(
        repository: repository ?? InMemoryTaskRepository(),
        clock: clock,
      );
  return MaterialApp(
    home: HomePage(
      assistant: AssistantController(
        taskService: tasks,
        parser: ScenarioParser(clock: clock),
        clock: clock,
      ),
      tasks: tasks,
      clock: clock,
    ),
  );
}

void main() {
  testWidgets('основные области и настройки видны в диалоге', (tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pump();

    expect(find.byKey(const Key('app-sidebar')), findsOneWidget);
    expect(find.byKey(const Key('status-cube')), findsOneWidget);
    expect(find.byKey(const Key('history-rail')), findsOneWidget);
    expect(find.byKey(const Key('assistant-composer')), findsOneWidget);
    expect(find.text('Настройки'), findsOneWidget);
  });

  testWidgets('общий composer сохраняет текст при открытии документа',
      (tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pump();

    await tester.enterText(
      find.byKey(const Key('assistant-input')),
      'Черновик команды',
    );
    await tester.tap(find.byKey(const Key('mode-document')));
    await tester.pumpAndSettle();

    expect(find.text('Черновик команды'), findsOneWidget);
    expect(find.byKey(const Key('document-editor')), findsOneWidget);
    expect(find.byKey(const Key('demo-save-status')), findsOneWidget);
  });

  testWidgets('выбор полосы истории открывает сообщения версии',
      (tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pump();

    await tester.tap(find.byKey(const Key('history-0')));
    await tester.pump();

    expect(find.text('Сообщения версии'), findsOneWidget);
    expect(find.textContaining('Я готов к первому сценарию'), findsWidgets);
  });

  testWidgets('команда списка проходит через существующий контроллер',
      (tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pump();

    await tester.enterText(
      find.byKey(const Key('assistant-input')),
      'Покажи задачи',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('assistant-send')));
    await tester.pump();
    await tester.pump();

    expect(find.text('Активных задач пока нет.'), findsOneWidget);
  });

  testWidgets('пример из приветствия создаёт задачу', (tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pump();

    expect(
      find.textContaining(AssistantController.exampleCommand),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const Key('assistant-input')),
      AssistantController.exampleCommand,
    );
    await tester.testTextInput.receiveAction(TextInputAction.send);
    // Кубик статуса после успеха анимируется бесконечно, поэтому без settle.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      find.text('Создал задачу «Позвонить клиенту» на завтра в 11:00.'),
      findsOneWidget,
    );
  });

  testWidgets('в панели задач срок показан по-человечески', (tester) async {
    final clock = FixedClock(DateTime(2026, 11, 4, 12));
    final service =
        TaskService(repository: InMemoryTaskRepository(), clock: clock);
    await service.create(title: 'Отчёт', dueAt: DateTime(2026, 11, 5, 10));
    await service.create(title: 'Старое', dueAt: DateTime(2026, 11, 3, 9));
    await tester.pumpWidget(buildApp(service: service));
    await tester.pump();

    await tester.tap(find.byKey(const Key('tasks-toggle')));
    await tester.pumpAndSettle();

    expect(find.text('завтра в 10:00'), findsWidgets);
    expect(find.text('просрочено · вчера в 9:00'), findsWidgets);
  });

  testWidgets('ошибка загрузки задач видна и даёт повторить', (tester) async {
    await tester.pumpWidget(buildApp(repository: _BrokenRepository()));
    await tester.pump();

    await tester.tap(find.byKey(const Key('tasks-toggle')));
    await tester.pumpAndSettle();

    expect(find.text('Не удалось загрузить задачи'), findsOneWidget);
    expect(find.text('Повторить'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
