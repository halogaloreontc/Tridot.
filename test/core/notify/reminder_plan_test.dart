import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/notify/reminder_plan.dart';

final DateTime _now = DateTime(2026, 11, 15, 12, 0);

Task _task(
  String id, {
  DateTime? due,
  DuePrecision precision = DuePrecision.dateTime,
  TaskStatus status = TaskStatus.planned,
  DateTime? deletedAt,
  String? title,
}) =>
    Task(
      id: id,
      title: title ?? 'Задача $id',
      status: status,
      priority: TaskPriority.normal,
      dueAt: due,
      duePrecision: precision,
      createdAt: _now,
      updatedAt: _now,
      deletedAt: deletedAt,
    );

List<Reminder> _plan(List<Task> tasks, {int? dateOnlyHour = 9}) =>
    ReminderPlan.from(
      tasks,
      now: _now,
      persona: 'Нода',
      dateOnlyHour: dateOnlyHour,
    );

void main() {
  test('точность срока → время напоминания', () {
    final plan = _plan(<Task>[
      _task('t', due: DateTime(2026, 11, 15, 18, 30)),
      _task(
        'p',
        due: DateTime(2026, 11, 16, PartOfDay.evening.hour),
        precision: DuePrecision.partOfDay,
      ),
      _task('d', due: DateTime(2026, 11, 17), precision: DuePrecision.date),
    ]);
    expect(
      <(String, DateTime)>[for (final r in plan) (r.taskId, r.at)],
      <(String, DateTime)>[
        ('t', DateTime(2026, 11, 15, 18, 30)),
        ('p', DateTime(2026, 11, 16, 19)),
        ('d', DateTime(2026, 11, 17, 9)),
      ],
    );
    expect(plan.first.title, 'Задача t');
    expect(plan.first.persona, 'Нода');
  });

  test('прошедшие, выполненные, удалённые и без срока — не напоминаются', () {
    final plan = _plan(<Task>[
      _task('past', due: DateTime(2026, 11, 15, 11, 59)),
      _task('now', due: _now),
      _task(
        'done',
        due: DateTime(2026, 11, 16, 10),
        status: TaskStatus.done,
      ),
      _task(
        'cancelled',
        due: DateTime(2026, 11, 16, 10),
        status: TaskStatus.cancelled,
      ),
      _task(
        'deleted',
        due: DateTime(2026, 11, 16, 10),
        deletedAt: _now,
      ),
      _task('none'),
      // Срок сегодня без времени, а 9:00 уже прошло.
      _task('today', due: DateTime(2026, 11, 15), precision: DuePrecision.date),
    ]);
    expect(plan, isEmpty);
  });

  test('не дальше 30 дней и не больше 50', () {
    final far = _plan(<Task>[
      _task('in', due: DateTime(2026, 12, 15, 11)),
      _task('out', due: DateTime(2026, 12, 15, 12, 1)),
    ]);
    expect(far.map((Reminder r) => r.taskId), <String>['in']);
    final many = _plan(<Task>[
      for (var i = 0; i < 70; i++)
        _task('$i', due: _now.add(Duration(hours: 70 - i))),
    ]);
    expect(many, hasLength(ReminderPlan.maxItems));
    // Ближайшие первыми.
    expect(many.first.taskId, '69');
    expect(many.last.taskId, '20');
  });

  test('без часа для задач на день — только задачи со временем', () {
    final plan = _plan(
      <Task>[
        _task('d', due: DateTime(2026, 11, 17), precision: DuePrecision.date),
        _task('t', due: DateTime(2026, 11, 17, 10)),
      ],
      dateOnlyHour: null,
    );
    expect(plan.map((Reminder r) => r.taskId), <String>['t']);
  });

  test('ключ меняется со сроком; название в одну строку', () {
    final a = _plan(<Task>[_task('x', due: DateTime(2026, 11, 16, 10))]);
    final b = _plan(<Task>[_task('x', due: DateTime(2026, 11, 16, 11))]);
    expect(a.single.id, isNot(b.single.id));
    final long = _plan(<Task>[
      _task(
        'l',
        due: DateTime(2026, 11, 16, 10),
        title: 'Первая\nвторая  ${'а' * 200}',
      ),
    ]).single;
    expect(long.title, startsWith('Первая вторая а'));
    expect(long.title.runes.length, ReminderPlan.maxTitle);
    expect(long.title, endsWith('…'));
    expect(
      long.toJson()['at'],
      DateTime(2026, 11, 16, 10).millisecondsSinceEpoch,
    );
  });

  test('отложенные сохраняются только у наступивших активных задач', () {
    final ids = ReminderPlan.snoozable(
      <Task>[
        _task('past', due: DateTime(2026, 11, 15, 11)),
        _task('yesterday', due: DateTime(2026, 11, 14, 9)),
        _task(
          'date',
          due: DateTime(2026, 11, 15),
          precision: DuePrecision.date,
        ),
        _task('future', due: DateTime(2026, 11, 16, 9)),
        _task('none'),
        _task(
          'gone',
          due: DateTime(2026, 11, 15, 11),
          deletedAt: _now,
        ),
      ],
      now: _now,
    );
    expect(ids, <String>{'past', 'yesterday', 'date'});
  });
}
