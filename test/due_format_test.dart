import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/formatting/due_format.dart';
import 'package:local_assistant/core/models/task.dart';

Task _task(DateTime? due, [DuePrecision precision = DuePrecision.dateTime]) =>
    Task(
      id: 't${due?.millisecondsSinceEpoch ?? 0}${precision.name}',
      title: 'Задача',
      status: TaskStatus.planned,
      priority: TaskPriority.normal,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      dueAt: due,
      duePrecision: precision,
    );

void main() {
  final now = DateTime(2026, 11, 2, 16, 30);

  test('относительные дни и время', () {
    expect(
      formatDue(DateTime(2026, 11, 2, 18), DuePrecision.dateTime, now),
      'сегодня в 18:00',
    );
    expect(formatDue(DateTime(2026, 11, 3), DuePrecision.date, now), 'завтра');
    expect(
      formatDue(DateTime(2026, 11, 4, 9, 5), DuePrecision.dateTime, now),
      'послезавтра в 9:05',
    );
    expect(
      formatDue(DateTime(2026, 11, 15), DuePrecision.date, now),
      '15 ноября',
    );
    expect(
      formatDue(DateTime(2027, 1, 10, 12), DuePrecision.dateTime, now),
      '10 января 2027 в 12:00',
    );
    expect(formatDue(DateTime(2026, 11, 1), DuePrecision.date, now), 'вчера');
  });

  test('переход через месяц и год считается по календарю', () {
    final lateNight = DateTime(2026, 12, 31, 23, 50);
    expect(formatDay(DateTime(2027, 1, 1), lateNight), 'завтра');
  });

  test('просрочка: дата без времени — только со следующего дня', () {
    final todayDate = _task(DateTime(2026, 11, 2), DuePrecision.date);
    final yesterdayDate = _task(DateTime(2026, 11, 1), DuePrecision.date);
    expect(isOverdue(todayDate, now), isFalse);
    expect(isOverdue(yesterdayDate, now), isTrue);
    expect(isOverdue(_task(DateTime(2026, 11, 2, 16)), now), isTrue);
    expect(isOverdue(_task(DateTime(2026, 11, 2, 17)), now), isFalse);
    expect(isOverdue(_task(null), now), isFalse);
  });

  test('группы идут по порядку, пустые пропускаются', () {
    final tasks = <Task>[
      _task(DateTime(2026, 11, 2, 9)),
      _task(DateTime(2026, 11, 2, 20)),
      _task(DateTime(2026, 11, 20), DuePrecision.date),
      _task(null),
    ];
    final groups = groupTasks(tasks, now);
    expect(
      groups.map(((TaskGroup, List<Task>) g) => g.$1),
      <TaskGroup>[
        TaskGroup.overdue,
        TaskGroup.today,
        TaskGroup.later,
        TaskGroup.noDate,
      ],
    );
    expect(groups.first.$2.single.dueAt, DateTime(2026, 11, 2, 9));
  });
  group('часть суток', () {
    test('срок пишется словами, без условного часа', () {
      expect(
        formatDue(DateTime(2026, 11, 3, 19), DuePrecision.partOfDay, now),
        'завтра вечером',
      );
      expect(
        formatDue(DateTime(2026, 11, 2, 9), DuePrecision.partOfDay, now),
        'сегодня утром',
      );
      expect(
        formatDue(DateTime(2026, 11, 2, 13), DuePrecision.partOfDay, now),
        'сегодня днём',
      );
      expect(
        formatDue(DateTime(2026, 11, 6, 14), DuePrecision.partOfDay, now),
        '6 ноября после обеда',
      );
    });

    test('просрочено с концом части суток', () {
      final evening = _task(DateTime(2026, 11, 2, 19), DuePrecision.partOfDay);
      expect(isOverdue(evening, DateTime(2026, 11, 2, 19, 30)), isFalse);
      expect(isOverdue(evening, DateTime(2026, 11, 2, 23, 59)), isFalse);
      expect(isOverdue(evening, DateTime(2026, 11, 3)), isTrue);
      final morning = _task(DateTime(2026, 11, 2, 9), DuePrecision.partOfDay);
      expect(isOverdue(morning, DateTime(2026, 11, 2, 11, 59)), isFalse);
      expect(isOverdue(morning, DateTime(2026, 11, 2, 12)), isTrue);
      expect(groupOf(morning, now), TaskGroup.overdue);
      expect(overdueMoment(morning), DateTime(2026, 11, 2, 12));
      expect(overdueMoment(evening), DateTime(2026, 11, 3));
    });

    test('часть суток по часу срока', () {
      expect(PartOfDay.of(DateTime(2026, 11, 2, 9)), PartOfDay.morning);
      expect(PartOfDay.of(DateTime(2026, 11, 2, 13)), PartOfDay.day);
      expect(PartOfDay.of(DateTime(2026, 11, 2, 14)), PartOfDay.afternoon);
      expect(PartOfDay.of(DateTime(2026, 11, 2, 19)), PartOfDay.evening);
      // Срок поправили вручную — ближайшая часть.
      expect(PartOfDay.of(DateTime(2026, 11, 2, 7)), PartOfDay.morning);
      expect(PartOfDay.of(DateTime(2026, 11, 2, 21)), PartOfDay.evening);
    });

    test('точность сохраняется в JSON и читается старыми и новыми данными', () {
      final task = _task(DateTime(2026, 11, 3, 19), DuePrecision.partOfDay);
      final json = task.toJson();
      expect(json['due_precision'], 'partOfDay');
      expect(Task.fromJson(json).duePrecision, DuePrecision.partOfDay);
      // Старый файл без поля и файл более новой версии с незнакомым
      // значением — dateTime, загрузка не падает.
      expect(
        Task.fromJson(<String, dynamic>{...json}..remove('due_precision'))
            .duePrecision,
        DuePrecision.dateTime,
      );
      expect(
        Task.fromJson(<String, dynamic>{...json, 'due_precision': 'week'})
            .duePrecision,
        DuePrecision.dateTime,
      );
    });
  });
}
