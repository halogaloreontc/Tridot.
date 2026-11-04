import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/app/theme.dart';
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

final _clock = FixedClock(DateTime(2026, 11, 2, 16, 30));

Future<(TaskService, AssistantController)> _pump(
  WidgetTester tester, {
  required Size size,
  TaskRepository? repository,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final tasks = TaskService(
    repository: repository ?? InMemoryTaskRepository(),
    clock: _clock,
  );
  final assistant = AssistantController(
    taskService: tasks,
    parser: ScenarioParser(clock: _clock),
    clock: _clock,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      home: HomePage(assistant: assistant, tasks: tasks, clock: _clock),
    ),
  );
  await tester.pumpAndSettle();
  return (tasks, assistant);
}

Future<void> _say(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('chat-input')), text);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.pumpAndSettle();
}

Finder _keyPrefix(String prefix) => find.byWidgetPredicate(
      (Widget w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith(prefix),
    );

const _phone = Size(390, 844);
const _desktop = Size(1280, 800);

void main() {
  testWidgets('телефон: создать задачу в чате и увидеть её во вкладке',
      (WidgetTester tester) async {
    await _pump(tester, size: _phone);
    expect(find.byType(NavigationBar), findsOneWidget);

    await _say(tester, 'Добавь задачу «Отчёт» завтра в 10:00');
    expect(find.text('Создал задачу «Отчёт» на завтра в 10:00.'), findsOne);
    final field = tester.widget<TextField>(find.byKey(const Key('chat-input')));
    expect(field.controller!.text, isEmpty);
    expect(field.focusNode!.hasFocus, isTrue, reason: 'фокус остаётся в поле');

    await tester.tap(find.text('Задачи').last);
    await tester.pumpAndSettle();
    expect(find.text('Завтра · 1'), findsOneWidget);
    expect(find.text('завтра в 10:00'), findsWidgets);
  });

  testWidgets('кружок слева завершает задачу и снимает выбор',
      (WidgetTester tester) async {
    final (_, assistant) = await _pump(tester, size: _desktop);
    await _say(tester, 'Добавь задачу «Купить хлеб»');
    expect(assistant.selectedTaskId, isNotNull);

    await tester.tap(_keyPrefix('complete-'));
    await tester.pumpAndSettle();

    expect(find.text('Задач пока нет'), findsOneWidget);
    expect(assistant.selectedTaskId, isNull);
    expect(find.byKey(const Key('selected-task-chip')), findsNothing);
  });

  testWidgets('выбор задачи показывает подсказку и снимается крестиком',
      (WidgetTester tester) async {
    final (tasks, assistant) = await _pump(tester, size: _desktop);
    await tasks.create(title: 'Позвонить маме');
    await _say(tester, 'Покажи задачи');
    assistant.clearSelection();

    await tester.tap(_keyPrefix('task-'));
    await tester.pumpAndSettle();
    expect(find.text('Работаю с «Позвонить маме»'), findsOneWidget);
    expect(find.text('Завершить'), findsOneWidget);

    await tester.tap(find.byTooltip('Снять выбор'));
    await tester.pumpAndSettle();
    expect(assistant.selectedTaskId, isNull);
    expect(find.text('Завершить'), findsNothing);
  });

  testWidgets('подсказка «Новая задача» ставит курсор внутрь кавычек',
      (WidgetTester tester) async {
    await _pump(tester, size: _phone);
    await tester.tap(find.text('Новая задача'));
    await tester.pump();

    final field = tester.widget<TextField>(find.byKey(const Key('chat-input')));
    expect(field.controller!.text, 'Добавь задачу «» на завтра');
    expect(field.controller!.selection.baseOffset, 'Добавь задачу «'.length);
  });

  testWidgets('ошибка загрузки показывается, а не «пусто»',
      (WidgetTester tester) async {
    await _pump(tester, size: _desktop, repository: _BrokenRepository());
    expect(find.text('Не удалось загрузить задачи'), findsOneWidget);
    expect(find.text('Повторить'), findsOneWidget);
  });

  testWidgets('просроченная задача попадает в свою группу',
      (WidgetTester tester) async {
    final (tasks, _) = await _pump(tester, size: _desktop);
    await tasks.create(title: 'Старое', dueAt: DateTime(2026, 11, 1, 10));
    await _say(tester, 'Покажи задачи');
    expect(find.text('Просрочено · 1'), findsOneWidget);
    expect(find.text('вчера в 10:00'), findsWidgets);
  });
}
