import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/screens/projects_screen.dart';
import 'package:local_assistant/app/widgets/task_tile.dart';
import 'package:local_assistant/core/models/task.dart';

final DateTime now = DateTime(2026, 11, 5, 12);

Task task(
  String id,
  String title, {
  List<String> tags = const <String>[],
  DateTime? dueAt,
  DuePrecision precision = DuePrecision.dateTime,
}) {
  return Task(
    id: id,
    title: title,
    status: TaskStatus.planned,
    priority: TaskPriority.normal,
    createdAt: now,
    updatedAt: now,
    dueAt: dueAt,
    duePrecision: precision,
    tags: tags,
  );
}

final List<Task> sample = <Task>[
  task(
    'a',
    'Отчёт',
    tags: <String>['работа'],
    dueAt: DateTime(2026, 11, 4, 10),
  ),
  task(
    'b',
    'Созвон',
    tags: <String>['работа'],
    dueAt: DateTime(2026, 11, 5, 18),
  ),
  task('c', 'Купить молоко', tags: <String>['дом']),
  task('d', 'Позвонить маме'),
];

Widget host({
  List<Task>? tasks,
  String? selectedId,
  ValueChanged<Task>? onOpenTask,
  ValueChanged<Task>? onToggleDone,
}) {
  return MaterialApp(
    theme: AssistantTheme.dark(),
    home: Scaffold(
      body: ProjectsScreen(
        tasks: tasks ?? sample,
        now: now,
        selectedId: selectedId,
        onOpenTask: onOpenTask ?? (_) {},
        onToggleDone: onToggleDone ?? (_) {},
      ),
    ),
  );
}

void main() {
  testWidgets('shows sorted project cards with counts', (tester) async {
    await tester.pumpWidget(host());

    expect(find.text('Проекты'), findsOneWidget);
    expect(
      find.text(
        'Проект задаётся меткой в команде: Добавь задачу «Отчёт» '
        '#работа — или в документе задачи.',
      ),
      findsOneWidget,
    );
    final dom = tester.getTopLeft(find.text('#дом')).dy;
    final work = tester.getTopLeft(find.text('#работа')).dy;
    final none = tester.getTopLeft(find.text('Без проекта')).dy;
    expect(dom, lessThan(work));
    expect(work, lessThan(none));

    expect(find.text('активных: 2'), findsOneWidget);
    expect(find.text('активных: 1'), findsNWidgets(2));
    final overdue = tester.widget<Text>(find.text('просрочено: 1'));
    expect(overdue.style?.color, AssistantColors.danger);
    expect(find.byType(TaskTile), findsNothing);
  });

  testWidgets('omits "Без проекта" when every task has a project',
      (tester) async {
    await tester.pumpWidget(host(tasks: sample.sublist(0, 3)));
    expect(find.text('Без проекта'), findsNothing);
    expect(find.textContaining('просрочено'), findsOneWidget);
  });

  testWidgets('expands one card at a time and collapses on second tap',
      (tester) async {
    await tester.pumpWidget(host());

    await tester.tap(find.byKey(const ValueKey<String>('project-работа')));
    await tester.pump();
    expect(find.text('Отчёт'), findsOneWidget);
    expect(find.text('Созвон'), findsOneWidget);
    expect(find.text('Просрочено · 1'), findsOneWidget);
    expect(find.text('Сегодня · 1'), findsOneWidget);
    final label = tester.widget<SectionLabel>(
      find.ancestor(
        of: find.text('Просрочено · 1'),
        matching: find.byType(SectionLabel),
      ),
    );
    expect(label.danger, isTrue);

    await tester.tap(find.byKey(const ValueKey<String>('project-none')));
    await tester.pump();
    expect(find.text('Отчёт'), findsNothing);
    expect(find.text('Позвонить маме'), findsOneWidget);
    expect(find.text('Без срока · 1'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('project-none')));
    await tester.pump();
    expect(find.byType(TaskTile), findsNothing);
  });

  testWidgets('task tiles open, toggle and mark the selected task',
      (tester) async {
    final opened = <String>[];
    final toggled = <String>[];
    await tester.pumpWidget(
      host(
        selectedId: 'b',
        onOpenTask: (t) => opened.add(t.id),
        onToggleDone: (t) => toggled.add(t.id),
      ),
    );
    await tester.tap(find.byKey(const ValueKey<String>('project-работа')));
    await tester.pump();

    await tester.tap(find.text('Отчёт'));
    await tester.tap(find.byKey(const ValueKey<String>('toggle-b')));
    expect(opened, <String>['a']);
    expect(toggled, <String>['b']);

    final tile = tester.widget<TaskTile>(
      find.ancestor(of: find.text('Созвон'), matching: find.byType(TaskTile)),
    );
    expect(tile.selected, isTrue);
    expect(tile.showProject, isFalse);
  });

  testWidgets('shows empty state without tasks', (tester) async {
    await tester.pumpWidget(host(tasks: const <Task>[]));
    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('Нет активных задач'), findsOneWidget);
  });

  for (final width in <double>[320, 1600]) {
    testWidgets('no overflow at ${width.toInt()}px with textScaler 2.0',
        (tester) async {
      tester.view.physicalSize = Size(width, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      final many = <Task>[
        for (var i = 0; i < 8; i++)
          task(
            'x$i',
            'Очень длинное название задачи номер $i для проверки переносов',
            tags: <String>['оченьдлинноеназваниепроекта$i'],
            dueAt: DateTime(2026, 11, 3 + i, 9),
          ),
        ...sample,
      ];
      await tester.pumpWidget(host(tasks: many, selectedId: 'a'));
      expect(tester.takeException(), isNull);

      final card = find.byKey(const ValueKey<String>('project-работа'));
      await tester.ensureVisible(card);
      await tester.pump();
      await tester.tap(card);
      await tester.pump();
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(host(tasks: const <Task>[]));
      expect(tester.takeException(), isNull);
    });
  }
}
