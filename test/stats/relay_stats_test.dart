import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/stats/relay_stats.dart';

// Четверг, 5 ноября 2026.
final DateTime now = DateTime(2026, 11, 5, 12);

Task task(
  String id, {
  TaskStatus status = TaskStatus.planned,
  DateTime? createdAt,
  DateTime? completedAt,
  DateTime? deletedAt,
}) {
  final created = createdAt ?? DateTime(2026, 9, 1);
  return Task(
    id: id,
    title: 'Задача $id',
    status: status,
    priority: TaskPriority.normal,
    createdAt: created,
    updatedAt: created,
    completedAt: completedAt,
    deletedAt: deletedAt,
  );
}

Task done(String id, DateTime completedAt, {DateTime? createdAt}) => task(
      id,
      status: TaskStatus.done,
      completedAt: completedAt,
      createdAt: createdAt,
    );

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

    test('удалённые не считаются, ключи — полночь', () {
      final counts = completionsByDay(<Task>[
        done('a', DateTime(2026, 1, 2, 15)),
        task(
          'gone',
          status: TaskStatus.done,
          completedAt: DateTime(2026, 1, 2, 16),
          deletedAt: DateTime(2026, 1, 3),
        ),
      ]);
      final key = counts.keys.single;
      expect(counts[key], 1);
      expect(key.hour, 0);
      expect(key.isUtc, isFalse);
    });
  });

  group('RelayStats', () {
    test('пусто: один день вместе, ничего не закрыто, серии нет', () {
      final stats = RelayStats.compute(
        tasks: const <Task>[],
        sessionDays: const <DateTime, int>{},
        sessions: 0,
        firstSeen: null,
        now: now,
      );
      expect(stats.daysTogether, 1);
      expect(stats.tasksClosed, 0);
      expect(stats.streak, 0);
      expect(
        stats.line,
        'Вместе 1 день · сессий 0 · задач закрыто 0 · серия 0 дней',
      );
    });

    test('дни вместе от firstSeen включительно, склонения', () {
      RelayStats from(DateTime first) => RelayStats.compute(
            tasks: const <Task>[],
            sessionDays: const <DateTime, int>{},
            sessions: 3,
            firstSeen: first,
            now: now,
          );
      expect(from(DateTime(2026, 11, 4)).daysTogether, 2);
      expect(from(DateTime(2026, 11, 4)).line, startsWith('Вместе 2 дня'));
      expect(from(DateTime(2026, 11, 1)).line, startsWith('Вместе 5 дней'));
      expect(from(DateTime(2026, 10, 15)).line, startsWith('Вместе 22 дня'));
      expect(from(DateTime(2026, 10, 16)).line, startsWith('Вместе 21 день'));
      // Через смену времени (25 октября) день не теряется.
      expect(from(DateTime(2026, 10, 1)).daysTogether, 36);
    });

    test('самая ранняя задача раньше firstSeen сдвигает начало', () {
      final stats = RelayStats.compute(
        tasks: <Task>[task('old', createdAt: DateTime(2026, 11, 1, 10))],
        sessionDays: const <DateTime, int>{},
        sessions: 0,
        firstSeen: DateTime(2026, 11, 4),
        now: now,
      );
      expect(stats.daysTogether, 5);
    });

    test('задачи закрыто: выполненные и не удалённые', () {
      final stats = RelayStats.compute(
        tasks: <Task>[
          done('a', DateTime(2026, 11, 2)),
          done('b', DateTime(2026, 11, 3)),
          task('c'),
          task(
            'gone',
            status: TaskStatus.done,
            completedAt: DateTime(2026, 11, 3),
            deletedAt: DateTime(2026, 11, 4),
          ),
        ],
        sessionDays: const <DateTime, int>{},
        sessions: 0,
        firstSeen: DateTime(2026, 9, 1),
        now: now,
      );
      expect(stats.tasksClosed, 2);
    });

    test('серия считается до сегодня, а если сегодня пусто — до вчера', () {
      RelayStats with_(Map<DateTime, int> days) => RelayStats.compute(
            tasks: const <Task>[],
            sessionDays: days,
            sessions: 1,
            firstSeen: DateTime(2026, 10, 1),
            now: now,
          );
      final three = <DateTime, int>{
        DateTime(2026, 11, 2): 1,
        DateTime(2026, 11, 3): 2,
        DateTime(2026, 11, 4): 1,
      };
      expect(with_(three).streak, 3);
      expect(
        with_(<DateTime, int>{...three, DateTime(2026, 11, 5): 1}).streak,
        4,
      );
      // Разрыв 3 ноября.
      expect(
        with_(<DateTime, int>{
          DateTime(2026, 11, 2): 1,
          DateTime(2026, 11, 4): 1,
        }).streak,
        1,
      );
      expect(with_(<DateTime, int>{DateTime(2026, 11, 3): 1}).streak, 0);
    });

    test('активность складывает созданные, закрытые и команды в сессиях', () {
      final stats = RelayStats.compute(
        tasks: <Task>[
          done(
            'a',
            DateTime(2026, 11, 4, 9),
            createdAt: DateTime(2026, 11, 3, 8),
          ),
        ],
        sessionDays: <DateTime, int>{DateTime(2026, 11, 4): 2},
        sessions: 1,
        firstSeen: null,
        now: now,
      );
      expect(stats.activityByDay, <DateTime, int>{
        DateTime(2026, 11, 3): 1,
        DateTime(2026, 11, 4): 3,
      });
      expect(stats.streak, 2);
    });

    test('будущие дни в активность не попадают', () {
      final stats = RelayStats.compute(
        tasks: const <Task>[],
        sessionDays: <DateTime, int>{DateTime(2026, 11, 9): 1},
        sessions: 1,
        firstSeen: null,
        now: now,
      );
      expect(stats.activityByDay, isEmpty);
    });
  });
}
