import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

Widget buildApp() {
  final repository = InMemoryTaskRepository();
  final clock = FixedClock(DateTime(2026, 11, 4, 12));
  final tasks = TaskService(repository: repository, clock: clock);
  return MaterialApp(
    home: HomePage(
      assistant: AssistantController(
        taskService: tasks,
        parser: ScenarioParser(clock: clock),
      ),
      tasks: tasks,
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
}
