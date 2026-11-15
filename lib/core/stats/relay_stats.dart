/// Статистика «Мой Связной» только по данным на этом устройстве: задачи
/// и дни активности сессий. Без сети и без выдуманных чисел.
library;

import '../formatting/plural.dart';
import '../models/task.dart';

/// Локальная дата в полночь.
DateTime dateOnly(DateTime value) {
  final local = value.toLocal();
  return DateTime(local.year, local.month, local.day);
}

/// Число выполненных задач по дням. Ключ — локальная дата в полночь.
/// Учитываются только завершённые и не удалённые задачи с [Task.completedAt].
Map<DateTime, int> completionsByDay(Iterable<Task> tasks) {
  final result = <DateTime, int>{};
  for (final task in tasks) {
    final completed = task.completedAt;
    if (completed == null ||
        task.status != TaskStatus.done ||
        task.deletedAt != null) {
      continue;
    }
    final day = dateOnly(completed);
    result[day] = (result[day] ?? 0) + 1;
  }
  return result;
}

/// Итог для шапки «Мой Связной» и сетки активности.
final class RelayStats {
  const RelayStats({
    required this.daysTogether,
    required this.sessions,
    required this.tasksClosed,
    required this.streak,
    required this.activityByDay,
  });

  /// [tasks] — все задачи (удалённые пропускаются); [sessionDays] — дни
  /// с командами в сессиях (ChatBook.activityDays); [sessions] — сколько
  /// сессий с командами; [firstSeen] — первый день (AppSettings.firstSeenDay).
  factory RelayStats.compute({
    required Iterable<Task> tasks,
    required Map<DateTime, int> sessionDays,
    required int sessions,
    required DateTime? firstSeen,
    required DateTime now,
  }) {
    final today = dateOnly(now);
    final activity = <DateTime, int>{};
    void add(DateTime day, int count) {
      if (day.isAfter(today)) return;
      activity[day] = (activity[day] ?? 0) + count;
    }

    var closed = 0;
    var earliest = firstSeen == null ? today : dateOnly(firstSeen);
    for (final task in tasks) {
      if (task.deletedAt != null) continue;
      add(dateOnly(task.createdAt), 1);
      final created = dateOnly(task.createdAt);
      if (created.isBefore(earliest)) earliest = created;
      if (task.status == TaskStatus.done) closed++;
    }
    for (final MapEntry(:key, :value) in completionsByDay(tasks).entries) {
      add(key, value);
    }
    for (final MapEntry(:key, :value) in sessionDays.entries) {
      final day = dateOnly(key);
      add(day, value);
      if (day.isBefore(earliest)) earliest = day;
    }

    // Серия: подряд активные дни, считая от сегодня; если сегодня ещё
    // пусто — от вчера, серия не обрывается утром.
    var cursor = today;
    if ((activity[cursor] ?? 0) == 0) {
      cursor = DateTime(cursor.year, cursor.month, cursor.day - 1);
    }
    var streak = 0;
    while ((activity[cursor] ?? 0) > 0) {
      streak++;
      cursor = DateTime(cursor.year, cursor.month, cursor.day - 1);
    }

    return RelayStats(
      daysTogether: _daysBetween(earliest, today) + 1,
      sessions: sessions,
      tasksClosed: closed,
      streak: streak,
      activityByDay: Map<DateTime, int>.unmodifiable(activity),
    );
  }

  /// Дней от первого по сегодня включительно, не меньше 1.
  final int daysTogether;
  final int sessions;
  final int tasksClosed;

  /// Подряд активных дней до сегодня (или до вчера).
  final int streak;

  /// Локальная дата в полночь → сколько было дел: созданных и закрытых
  /// задач, команд в сессиях.
  final Map<DateTime, int> activityByDay;

  /// «Вместе 28 дней · сессий 180 · задач закрыто 64 · серия 5 дней».
  String get line => 'Вместе ${days(daysTogether)} · сессий $sessions · '
      'задач закрыто $tasksClosed · серия ${days(streak)}';

  static int _daysBetween(DateTime from, DateTime to) {
    // Через UTC: переход на летнее время не съедает день.
    final a = DateTime.utc(from.year, from.month, from.day);
    final b = DateTime.utc(to.year, to.month, to.day);
    final diff = b.difference(a).inDays;
    return diff < 0 ? 0 : diff;
  }
}
