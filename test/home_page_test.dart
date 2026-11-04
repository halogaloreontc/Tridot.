import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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

final class _MutableClock implements Clock {
  _MutableClock(this.value);

  DateTime value;

  @override
  DateTime now() => value;
}

final class _SlowRepository implements TaskRepository {
  final InMemoryTaskRepository _inner = InMemoryTaskRepository();

  @override
  Future<List<Task>> list() async {
    await Future<void>.delayed(const Duration(seconds: 1));
    return _inner.list();
  }

  @override
  Future<Task?> get(String id) => _inner.get(id);

  @override
  Future<void> save(Task task) => _inner.save(task);
}

final _clock = FixedClock(DateTime(2026, 11, 2, 16, 30));

Future<(TaskService, AssistantController)> _pump(
  WidgetTester tester, {
  required Size size,
  TaskRepository? repository,
  Clock? clock,
  EdgeInsets viewInsets = EdgeInsets.zero,
}) async {
  final usedClock = clock ?? _clock;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final tasks = TaskService(
    repository: repository ?? InMemoryTaskRepository(),
    clock: usedClock,
  );
  final assistant = AssistantController(
    taskService: tasks,
    parser: ScenarioParser(clock: usedClock),
    clock: usedClock,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(viewInsets: viewInsets),
        child: child!,
      ),
      home: HomePage(assistant: assistant, tasks: tasks, clock: usedClock),
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

  testWidgets('заголовок использует размер из темы, а не 14 px',
      (WidgetTester tester) async {
    await _pump(tester, size: _phone);
    final title = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Помощник'),
      ),
    );
    expect(title.text.style?.fontSize, greaterThanOrEqualTo(20));
  });

  testWidgets('клавиатура в горизонтальной ориентации не ломает экран',
      (WidgetTester tester) async {
    final (tasks, _) = await _pump(
      tester,
      size: const Size(640, 360),
      viewInsets: const EdgeInsets.only(bottom: 180),
    );
    await tasks.create(title: 'Купить хлеб');
    await _say(tester, 'Добавь задачу «Купить молоко» на завтра');
    expect(tester.takeException(), isNull);
    final list = tester.getSize(find.byType(ListView).first);
    expect(list.height, greaterThan(40));
  });

  testWidgets('крупный шрифт на узком экране не даёт переполнения',
      (WidgetTester tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(
      tester,
      size: const Size(360, 640),
      viewInsets: const EdgeInsets.only(bottom: 280),
    );
    await _say(tester, 'Добавь задачу «Купить хлеб» на завтра');
    expect(tester.takeException(), isNull);
  });

  testWidgets('после полуночи задача уходит в «Просрочено» без действий',
      (WidgetTester tester) async {
    final clock = _MutableClock(DateTime(2026, 11, 2, 16, 30));
    final (tasks, _) = await _pump(tester, size: _desktop, clock: clock);
    await tasks.create(title: 'Отчёт', dueAt: DateTime(2026, 11, 2, 18));
    await _say(tester, 'Покажи задачи');
    expect(find.text('Сегодня · 1'), findsOneWidget);

    clock.value = DateTime(2026, 11, 2, 18, 0, 2);
    await tester.pump(const Duration(hours: 1, minutes: 30, seconds: 2));
    expect(find.text('Просрочено · 1'), findsOneWidget);
  });

  testWidgets('подсказки-команды недоступны, пока идёт отправка',
      (WidgetTester tester) async {
    await _pump(tester, size: _desktop, repository: _SlowRepository());
    await tester.pump(const Duration(seconds: 2));
    await tester.enterText(
      find.byKey(const Key('chat-input')),
      'Покажи задачи',
    );
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump(const Duration(milliseconds: 100));
    final chip = tester.widget<ActionChip>(
      find.widgetWithText(ActionChip, 'Мои задачи'),
    );
    expect(chip.onPressed, isNull);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    final after = tester.widget<ActionChip>(
      find.widgetWithText(ActionChip, 'Мои задачи'),
    );
    expect(after.onPressed, isNotNull);
  });

  testWidgets('снятие выбора на телефоне убирает уведомление',
      (WidgetTester tester) async {
    final (tasks, _) = await _pump(tester, size: _phone);
    await tasks.create(title: 'A');
    await _say(tester, 'Покажи задачи');
    await tester.tap(find.text('Задачи').last);
    await tester.pumpAndSettle();
    await tester.tap(_keyPrefix('task-'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Выбрана «A»'), findsOneWidget);

    await tester.tap(_keyPrefix('task-'));
    await tester.pumpAndSettle();
    expect(find.text('Выбрана «A»'), findsNothing);
  });

  testWidgets('Enter и Shift+Enter с клавиатуры отправляют всю строку',
      (WidgetTester tester) async {
    await _pump(tester, size: _desktop);
    await tester.tap(find.byKey(const Key('chat-input')));
    await tester.enterText(
      find.byKey(const Key('chat-input')),
      'Покажи задачи',
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.text('Активных задач пока нет.'), findsOneWidget);
    final field = tester.widget<TextField>(find.byKey(const Key('chat-input')));
    expect(field.controller!.text, isEmpty);
  });
}
