// Правая панель «Сегодня» (макет «Д»): просроченные первыми, просрочка —
// текстом и точкой, ждущие карточки, разделы, без быстрых действий.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/shell/today_panel.dart';
import 'package:local_assistant/core/models/task.dart';

final _now = DateTime(2026, 11, 9, 12, 40);

Task _task(String id, String title, DateTime? due, {DuePrecision? p}) => Task(
      id: id,
      title: title,
      status: TaskStatus.planned,
      priority: TaskPriority.normal,
      createdAt: DateTime(2026, 11, 1),
      updatedAt: DateTime(2026, 11, 1),
      dueAt: due,
      duePrecision: p ?? DuePrecision.dateTime,
    );

void main() {
  final call = _task('a', 'Позвонить поставщику', DateTime(2026, 11, 9, 11));
  final check = _task('b', 'Сверить накладные', DateTime(2026, 11, 9, 16));
  final pack = _task(
    'c',
    'Заказать упаковку',
    DateTime(2026, 11, 9),
    p: DuePrecision.date,
  );
  final later = _task('d', 'Потом', DateTime(2026, 11, 12));
  final none = _task('e', 'Без срока', null);

  test('отбор и порядок: просроченные первыми, без завтрашних', () {
    final list = todayTasks(<Task>[check, later, pack, none, call], _now);
    expect(list.map((Task t) => t.id), <String>['a', 'b', 'c']);
    expect(todayDueLabel(call, _now), '11:00, просрочено');
    expect(todayDueLabel(check, _now), '16:00');
    expect(todayDueLabel(pack, _now), 'без времени');
    expect(todaySummary(3, 1), 'просрочена 1 задача');
    expect(todaySummary(3, 2), 'просрочены 2 задачи');
    expect(todaySummary(3, 0), '3 дела');
    expect(todayDateLabel(_now), 'пн, 9 ноября');
  });

  testWidgets('просрочка — текстом и точкой, ждущие карточки, разделы',
      (tester) async {
    tester.view.physicalSize = const Size(340, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final log = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AssistantTheme.dark(),
        home: Scaffold(
          body: TodayPanel(
            now: _now,
            tasks: todayTasks(<Task>[check, call, pack], _now),
            onOpenTask: (Task t) => log.add('open:${t.id}'),
            onToggleDone: (Task t) => log.add('done:${t.id}'),
            onAllTasks: () => log.add('all'),
            pending: <TodayPending>[
              TodayPending(
                id: 'r1',
                title: 'Отметка прихода ждёт подтверждения',
                subtitle: 'Нода · склад',
                onTap: () => log.add('pending'),
              ),
            ],
            sections: <TodaySection>[
              TodaySection(
                id: 'projects',
                label: 'Проекты',
                onTap: () => log.add('projects'),
              ),
            ],
          ),
        ),
      ),
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('today-summary'))).data,
      'просрочена 1 задача',
    );
    final first =
        tester.getRect(find.byKey(const ValueKey<String>('today-task-a')));
    final second =
        tester.getRect(find.byKey(const ValueKey<String>('today-task-b')));
    expect(first.top, lessThan(second.top), reason: 'просроченная выше');
    expect(find.text('11:00, просрочено'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('today-overdue-a')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('today-overdue-b')),
      findsNothing,
    );
    expect(find.byKey(const Key('quick-Задача')), findsNothing);
    await tester.tap(find.byKey(const ValueKey<String>('today-task-a')));
    await tester.tap(find.byKey(const ValueKey<String>('today-done-b')));
    await tester.tap(find.byKey(const ValueKey<String>('today-pending-r1')));
    await tester.tap(find.byKey(const Key('today-all-tasks')));
    await tester.tap(find.byKey(const Key('today-section-projects')));
    expect(log, <String>['open:a', 'done:b', 'pending', 'all', 'projects']);
    expect(
      tester
          .widget<Container>(
            find
                .descendant(
                  of: find.byKey(const ValueKey<String>('today-done-a')),
                  matching: find.byType(Container),
                )
                .first,
          )
          .decoration,
      isA<BoxDecoration>().having(
        (BoxDecoration d) => (d.border! as Border).top.color,
        'рамка',
        AssistantColors.danger,
      ),
    );
  });

  testWidgets('«Свернуть «Сегодня»» — значок »» и подсказка', (tester) async {
    tester.view.physicalSize = const Size(340, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var collapsed = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AssistantTheme.dark(),
        home: Scaffold(
          body: TodayPanel(
            now: _now,
            tasks: const <Task>[],
            onOpenTask: (_) {},
            onToggleDone: (_) {},
            onAllTasks: () {},
            onClose: () => collapsed++,
          ),
        ),
      ),
    );
    final button = find.byKey(const Key('today-collapse'));
    expect(
      find.descendant(
        of: button,
        matching: find.byIcon(Icons.keyboard_double_arrow_right),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Свернуть «Сегодня»'), findsOneWidget);
    expect(find.byKey(const Key('today-close')), findsNothing);
    expect(tester.getSize(button).height, greaterThanOrEqualTo(44));
    await tester.tap(button);
    expect(collapsed, 1);
  });
}
