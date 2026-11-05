import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/screens/planning_screen.dart';
import 'package:local_assistant/core/models/task.dart';

Task _task(
  String id, {
  DateTime? due,
  DuePrecision precision = DuePrecision.dateTime,
  TaskStatus status = TaskStatus.planned,
  List<String> tags = const <String>[],
}) =>
    Task(
      id: id,
      title: 'Задача $id',
      status: status,
      priority: TaskPriority.normal,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      dueAt: due,
      duePrecision: precision,
      tags: tags,
    );

List<String> _labels(List<AgendaSection> sections) =>
    <String>[for (final s in sections) s.label];

List<AgendaKind> _kinds(List<AgendaSection> sections) =>
    <AgendaKind>[for (final s in sections) s.kind];

List<String> _ids(AgendaSection section) =>
    <String>[for (final t in section.tasks) t.id];

void main() {
  // Четверг.
  final now = DateTime(2026, 11, 5, 14);

  group('buildAgenda', () {
    test('без задач всё окно — одна свободная серия', () {
      final agenda = buildAgenda(const <Task>[], now);
      expect(_kinds(agenda), <AgendaKind>[AgendaKind.freeRun]);
      expect(agenda.single.label, 'свободно · 5–18 ноября');
      expect(agenda.single.start, DateTime(2026, 11, 5));
      expect(agenda.single.end, DateTime(2026, 11, 18));
    });

    test('пустые дни подряд сворачиваются в одну строку', () {
      final agenda = buildAgenda(
        <Task>[
          _task('a', due: DateTime(2026, 11, 5, 18)),
          _task('b', due: DateTime(2026, 11, 9), precision: DuePrecision.date),
        ],
        now,
      );
      expect(_kinds(agenda), <AgendaKind>[
        AgendaKind.day,
        AgendaKind.freeRun,
        AgendaKind.day,
        AgendaKind.freeRun,
      ]);
      expect(_labels(agenda), <String>[
        'Сегодня · чт, 5 ноября',
        'свободно · 6–8 ноября',
        'Пн, 9 ноября',
        'свободно · 10–18 ноября',
      ]);
      expect(_ids(agenda[0]), <String>['a']);
      expect(_ids(agenda[2]), <String>['b']);
    });

    test('один свободный день — просто «свободно»', () {
      final agenda = buildAgenda(
        <Task>[
          _task('a', due: DateTime(2026, 11, 5, 18)),
          _task('b', due: DateTime(2026, 11, 7, 10)),
        ],
        now,
        days: 3,
      );
      expect(_labels(agenda), <String>[
        'Сегодня · чт, 5 ноября',
        'свободно',
        'Послезавтра · сб, 7 ноября',
      ]);
      expect(agenda[1].start, DateTime(2026, 11, 6));
      expect(agenda[1].end, DateTime(2026, 11, 6));
    });

    test('заголовок завтрашнего дня', () {
      final agenda = buildAgenda(
        <Task>[_task('a', due: DateTime(2026, 11, 6, 9))],
        now,
        days: 2,
      );
      expect(_labels(agenda), <String>['свободно', 'Завтра · пт, 6 ноября']);
    });

    test('прошедшее сегодня время — просрочено, дата сегодня — нет', () {
      final agenda = buildAgenda(
        <Task>[
          _task('later-today', due: DateTime(2026, 11, 5, 20)),
          _task('past-today', due: DateTime(2026, 11, 5, 9)),
          _task(
            'date-today',
            due: DateTime(2026, 11, 5),
            precision: DuePrecision.date,
          ),
          _task(
            'date-yesterday',
            due: DateTime(2026, 11, 4),
            precision: DuePrecision.date,
          ),
        ],
        now,
        days: 1,
      );
      expect(_kinds(agenda), <AgendaKind>[AgendaKind.overdue, AgendaKind.day]);
      expect(agenda[0].label, 'Просрочено');
      expect(_ids(agenda[0]), <String>['date-yesterday', 'past-today']);
      expect(_ids(agenda[1]), <String>['date-today', 'later-today']);
    });

    test('задачи дня идут по сроку, при равенстве — в исходном порядке', () {
      final agenda = buildAgenda(
        <Task>[
          _task('c', due: DateTime(2026, 11, 6, 18)),
          _task('a', due: DateTime(2026, 11, 6, 9)),
          _task('b', due: DateTime(2026, 11, 6, 9)),
        ],
        now,
        days: 2,
      );
      expect(_ids(agenda[1]), <String>['a', 'b', 'c']);
    });

    test('переход через границу месяца', () {
      final lateNovember = DateTime(2026, 11, 25, 10);
      final agenda = buildAgenda(
        <Task>[
          _task('dec', due: DateTime(2026, 12, 1, 12)),
        ],
        lateNovember,
      );
      expect(_labels(agenda), <String>[
        'свободно · 25–30 ноября',
        'Вт, 1 декабря',
        'свободно · 2–8 декабря',
      ]);
      expect(
        buildAgenda(const <Task>[], lateNovember).single.label,
        'свободно · 25 ноября – 8 декабря',
      );
    });

    test('переход через границу года', () {
      final agenda = buildAgenda(
        <Task>[_task('ny', due: DateTime(2027, 1, 2, 12))],
        DateTime(2026, 12, 28, 10),
      );
      expect(_labels(agenda), <String>[
        'свободно · 28 декабря – 1 января 2027',
        'Сб, 2 января 2027',
        'свободно · 3–10 января 2027',
      ]);
    });

    test('после окна — «Позже», без срока — «Без срока»', () {
      final agenda = buildAgenda(
        <Task>[
          _task('none-1'),
          _task('far', due: DateTime(2027, 2, 1, 10)),
          _task(
            'edge',
            due: DateTime(2026, 11, 19),
            precision: DuePrecision.date,
          ),
          _task('none-2'),
          _task('last-day', due: DateTime(2026, 11, 18, 23, 59)),
        ],
        now,
      );
      expect(_kinds(agenda), <AgendaKind>[
        AgendaKind.freeRun,
        AgendaKind.day,
        AgendaKind.later,
        AgendaKind.noDate,
      ]);
      expect(agenda[0].label, 'свободно · 5–17 ноября');
      expect(_ids(agenda[1]), <String>['last-day']);
      expect(agenda[2].label, 'Позже');
      expect(_ids(agenda[2]), <String>['edge', 'far']);
      expect(agenda[3].label, 'Без срока');
      expect(_ids(agenda[3]), <String>['none-1', 'none-2']);
    });

    test('неактивные задачи пропускаются', () {
      final agenda = buildAgenda(
        <Task>[
          _task('done', due: DateTime(2026, 11, 6), status: TaskStatus.done),
          _task('cancelled', status: TaskStatus.cancelled),
        ],
        now,
        days: 3,
      );
      expect(_kinds(agenda), <AgendaKind>[AgendaKind.freeRun]);
    });

    test('дни окна — последовательные локальные полуночи', () {
      // Окно захватывает переход на летнее время в марте.
      final start = DateTime(2027, 3, 20, 12);
      final tasks = <Task>[
        for (var i = 0; i < 20; i++)
          _task('d$i', due: DateTime(2027, 3, 20 + i, 23)),
      ];
      final agenda = buildAgenda(tasks, start, days: 20);
      expect(agenda, hasLength(20));
      for (var i = 0; i < 20; i++) {
        final section = agenda[i];
        expect(section.kind, AgendaKind.day);
        expect(section.start, DateTime(2027, 3, 20 + i));
        expect(section.start!.hour, 0);
        expect(_ids(section), <String>['d$i']);
      }
    });

    test('секции неизменяемы', () {
      final agenda = buildAgenda(
        <Task>[_task('a', due: DateTime(2026, 11, 5, 18))],
        now,
        days: 1,
      );
      expect(
        () => agenda.single.tasks.add(_task('x')),
        throwsUnsupportedError,
      );
    });
  });

  group('PlanningScreen', () {
    final tasks = <Task>[
      _task('overdue', due: DateTime(2026, 11, 4, 10), tags: <String>['дом']),
      _task('today', due: DateTime(2026, 11, 5, 18)),
      _task(
        'tomorrow',
        due: DateTime(2026, 11, 6),
        precision: DuePrecision.date,
      ),
      _task('far', due: DateTime(2027, 1, 20, 12)),
      _task('nodate'),
    ];

    Future<void> pump(
      WidgetTester tester, {
      List<Task>? items,
      String? selectedId,
      ValueChanged<Task>? onOpen,
      ValueChanged<Task>? onToggle,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          theme: AssistantTheme.dark(),
          home: Scaffold(
            body: PlanningScreen(
              tasks: items ?? tasks,
              now: now,
              selectedId: selectedId,
              onOpenTask: onOpen ?? (_) {},
              onToggleDone: onToggle ?? (_) {},
            ),
          ),
        ),
      );
    }

    testWidgets('показывает заголовок и секции повестки', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pump(tester);

      expect(find.text('Планирование'), findsOneWidget);
      expect(find.text('14 дней вперёд · с чт, 5 ноября'), findsOneWidget);
      expect(find.text('Просрочено · 1'), findsOneWidget);
      expect(find.text('Сегодня · чт, 5 ноября'), findsOneWidget);
      expect(find.text('Завтра · пт, 6 ноября'), findsOneWidget);
      expect(find.text('свободно · 7–18 ноября'), findsOneWidget);
      expect(find.text('Позже · 1'), findsOneWidget);
      expect(find.text('Без срока · 1'), findsOneWidget);
      for (final id in <String>['overdue', 'today', 'tomorrow', 'far']) {
        expect(find.text('Задача $id'), findsOneWidget);
      }

      // Порядок секций на экране.
      double y(String text) => tester.getTopLeft(find.text(text)).dy;
      expect(y('Просрочено · 1'), lessThan(y('Сегодня · чт, 5 ноября')));
      expect(y('Сегодня · чт, 5 ноября'), lessThan(y('Завтра · пт, 6 ноября')));
      expect(y('Завтра · пт, 6 ноября'), lessThan(y('свободно · 7–18 ноября')));
      expect(y('свободно · 7–18 ноября'), lessThan(y('Позже · 1')));
      expect(y('Позже · 1'), lessThan(y('Без срока · 1')));
    });

    testWidgets('нажатие на задачу открывает её', (tester) async {
      Task? opened;
      await pump(tester, onOpen: (task) => opened = task);
      await tester.tap(find.text('Задача today'));
      expect(opened?.id, 'today');
    });

    testWidgets('кружок завершает задачу', (tester) async {
      Task? toggled;
      await pump(tester, onToggle: (task) => toggled = task);
      await tester.tap(find.byKey(const ValueKey<String>('toggle-tomorrow')));
      expect(toggled?.id, 'tomorrow');
    });

    testWidgets('выбранная задача помечена', (tester) async {
      await pump(tester, selectedId: 'today');
      expect(
        find.byTooltip('С этой задачей работает помощник'),
        findsOneWidget,
      );
    });

    testWidgets('без задач — пустое состояние', (tester) async {
      await pump(tester, items: const <Task>[]);
      expect(find.text('Планов нет'), findsOneWidget);
    });

    testWidgets('без переполнения на 320x640 при масштабе текста 2',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await pump(tester, selectedId: 'today');
      expect(tester.takeException(), isNull);

      await tester.drag(
        find.byKey(const ValueKey<String>('planning-scroll')),
        const Offset(0, -2000),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Без срока · 1'), findsOneWidget);
    });

    testWidgets('без переполнения на 1600 px', (tester) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pump(tester);
      expect(tester.takeException(), isNull);
    });
  });
}
