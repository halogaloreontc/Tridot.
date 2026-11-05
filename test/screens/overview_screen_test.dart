import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/screens/overview_screen.dart';
import 'package:local_assistant/core/models/task.dart';

// Четверг, 5 ноября 2026.
final DateTime now = DateTime(2026, 11, 5, 12);

Task task(
  String id, {
  TaskStatus status = TaskStatus.planned,
  DateTime? dueAt,
  DuePrecision precision = DuePrecision.dateTime,
  DateTime? completedAt,
}) {
  return Task(
    id: id,
    title: 'Задача $id',
    status: status,
    priority: TaskPriority.normal,
    createdAt: DateTime(2026, 9, 1),
    updatedAt: DateTime(2026, 9, 1),
    dueAt: dueAt,
    duePrecision: precision,
    completedAt: completedAt,
  );
}

Task done(String id, DateTime completedAt) =>
    task(id, status: TaskStatus.done, completedAt: completedAt);

final class Recorder {
  final List<Task> opened = <Task>[];
  final List<Task> toggled = <Task>[];
  int goToTasks = 0;
}

Widget buildScreen(
  List<Task> tasks,
  Recorder recorder, {
  String? selectedId,
}) {
  return MaterialApp(
    theme: AssistantTheme.dark(),
    home: Scaffold(
      body: OverviewScreen(
        tasks: tasks,
        now: now,
        selectedId: selectedId,
        onOpenTask: recorder.opened.add,
        onToggleDone: recorder.toggled.add,
        onGoToTasks: () => recorder.goToTasks++,
      ),
    ),
  );
}

List<Task> sample() => <Task>[
      task('overdue', dueAt: DateTime(2026, 11, 4, 9)),
      task('today', dueAt: DateTime(2026, 11, 5, 18)),
      task(
        'today-date',
        dueAt: DateTime(2026, 11, 5),
        precision: DuePrecision.date,
      ),
      task('tomorrow', dueAt: DateTime(2026, 11, 6, 10)),
      task('later', dueAt: DateTime(2026, 11, 20, 10)),
      task('much-later', dueAt: DateTime(2026, 12, 20, 10)),
      task('no-date'),
      done('d1', DateTime(2026, 11, 3, 10)),
      done('d2', DateTime(2026, 11, 3, 17)),
      done('d3', DateTime(2026, 10, 30, 8)),
      done('old', DateTime(2026, 10, 1, 8)),
      task('cancelled', status: TaskStatus.cancelled),
    ];

String statValue(WidgetTester tester, String id) {
  final texts = tester.widgetList<Text>(
    find.descendant(
      of: find.byKey(Key('stat-$id')),
      matching: find.byType(Text),
    ),
  );
  return texts.first.data!;
}

void main() {
  group('completionsByDay', () {
    test('считает выполнения по локальным дням', () {
      final counts = completionsByDay(<Task>[
        done('a', DateTime(2026, 11, 3, 9)),
        done('b', DateTime(2026, 11, 3, 23, 59)),
        done('c', DateTime(2026, 11, 4, 0, 1)),
        task('active'),
        task('done-no-date', status: TaskStatus.done),
      ]);
      expect(counts, <DateTime, int>{
        DateTime(2026, 11, 3): 2,
        DateTime(2026, 11, 4): 1,
      });
    });

    test('пустой список и задачи без completedAt дают пустую карту', () {
      expect(completionsByDay(const <Task>[]), isEmpty);
      expect(
        completionsByDay(<Task>[task('x'), task('y', status: TaskStatus.done)]),
        isEmpty,
      );
    });

    test('ключи — полночь', () {
      final counts =
          completionsByDay(<Task>[done('a', DateTime(2026, 1, 2, 15))]);
      final key = counts.keys.single;
      expect(key.hour, 0);
      expect(key.minute, 0);
      expect(key.isUtc, isFalse);
    });
  });

  testWidgets('без задач показывает подсказку', (tester) async {
    await tester.pumpWidget(buildScreen(const <Task>[], Recorder()));
    expect(find.text('Обзор'), findsOneWidget);
    expect(find.byKey(const Key('overview-empty')), findsOneWidget);
    expect(
      find.text(
        'Создайте первую задачу в чате: Добавь задачу «…» на завтра',
      ),
      findsOneWidget,
    );
    expect(find.text('Ближайшие'), findsNothing);
  });

  testWidgets('счётчики считаются верно и ведут к задачам', (tester) async {
    final recorder = Recorder();
    await tester.pumpWidget(buildScreen(sample(), recorder));

    expect(statValue(tester, 'active'), '7');
    expect(statValue(tester, 'overdue'), '1');
    expect(statValue(tester, 'today'), '2');
    expect(statValue(tester, 'done-week'), '3');
    expect(find.text('Выполнено за 7 дней'), findsOneWidget);

    for (final id in <String>['active', 'overdue', 'today', 'done-week']) {
      await tester.tap(find.byKey(Key('stat-$id')));
    }
    expect(recorder.goToTasks, 4);
  });

  testWidgets('выполнено за 7 дней включает сегодня и ровно 6 дней назад',
      (tester) async {
    await tester.pumpWidget(
      buildScreen(
        <Task>[
          done('today', DateTime(2026, 11, 5, 8)),
          done('edge', DateTime(2026, 10, 30, 0, 5)),
          done('outside', DateTime(2026, 10, 29, 23, 55)),
        ],
        Recorder(),
      ),
    );
    expect(statValue(tester, 'done-week'), '2');
  });

  testWidgets('ближайшие: просроченные первыми, не больше пяти',
      (tester) async {
    final recorder = Recorder();
    await tester.pumpWidget(
      buildScreen(sample(), recorder, selectedId: 'today'),
    );

    final order = <String>[
      'overdue',
      'today-date',
      'today',
      'tomorrow',
      'later',
    ];
    final ys = <double>[
      for (final id in order) tester.getTopLeft(find.byKey(Key('task-$id'))).dy,
    ];
    for (var i = 1; i < ys.length; i++) {
      expect(ys[i], greaterThan(ys[i - 1]));
    }
    expect(find.byKey(const Key('task-much-later')), findsNothing);
    expect(find.byKey(const Key('task-no-date')), findsNothing);
    expect(find.byKey(const Key('task-d1')), findsNothing);
    expect(find.byTooltip('С этой задачей работает помощник'), findsOneWidget);

    await tester.tap(find.byKey(const Key('task-tomorrow')));
    expect(recorder.opened.single.id, 'tomorrow');

    await tester.tap(find.byKey(const Key('toggle-overdue')));
    expect(recorder.toggled.single.id, 'overdue');
  });

  testWidgets('без задач со сроком показывает пустое состояние',
      (tester) async {
    await tester.pumpWidget(
      buildScreen(
        <Task>[task('no-date'), done('d', DateTime(2026, 11, 1))],
        Recorder(),
      ),
    );
    expect(find.byKey(const Key('upcoming-empty')), findsOneWidget);
  });

  testWidgets('сетка активности: подсказки, итог, будущие дни не рисуются',
      (tester) async {
    await tester.pumpWidget(buildScreen(sample(), Recorder()));

    expect(find.text('Активность'), findsOneWidget);
    final cell = find.byKey(const Key('activity-2026-11-3'));
    expect(cell, findsOneWidget);
    expect(tester.widget<Tooltip>(cell).message, '3 ноября: выполнено 2');
    expect(
      tester
          .widget<Tooltip>(find.byKey(const Key('activity-2026-11-5')))
          .message,
      '5 ноября: выполнено 0',
    );
    // Пятница после сегодняшнего четверга не рисуется.
    expect(find.byKey(const Key('activity-2026-11-6')), findsNothing);
    // Первый столбец начинается с понедельника 7 недель назад.
    expect(find.byKey(const Key('activity-2026-9-14')), findsOneWidget);
    expect(find.byKey(const Key('activity-2026-9-13')), findsNothing);
    // 8 недель: 7 полных недель + пн..чт текущей.
    expect(find.byType(Tooltip).evaluate().length, greaterThanOrEqualTo(53));

    expect(find.text('Выполнено за 8 недель: 4'), findsOneWidget);
    expect(find.text('меньше'), findsOneWidget);
    expect(find.text('больше'), findsOneWidget);
  });

  testWidgets('нет переполнения на 320x640 при textScaler 2.0', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(buildScreen(sample(), Recorder()));
    expect(tester.takeException(), isNull);

    await tester.drag(
      find.byKey(const Key('overview-scroll')),
      const Offset(0, -2000),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Выполнено за 8 недель: 4'), findsOneWidget);
  });

  testWidgets('нет переполнения на 1600px', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(buildScreen(sample(), Recorder()));
    expect(tester.takeException(), isNull);
  });
}
