/// Слова «Сегодня»: какие задачи туда попадают и как подписаны их сроки.
/// Общие для колонки «Сегодня», «Сводки» и виджета рабочего стола
/// (ADR-034) — без Flutter, чтобы тем же кодом строился снимок виджета.
library;

import '../models/task.dart';
import 'due_format.dart';
import 'plural.dart';

/// Задачи на «Сегодня»: на сегодня и просроченные, просроченные первыми.
List<Task> todayTasks(List<Task> active, DateTime now) {
  final overdue = <Task>[];
  final today = <Task>[];
  for (final task in active) {
    switch (groupOf(task, now)) {
      case TaskGroup.overdue:
        overdue.add(task);
      case TaskGroup.today:
        today.add(task);
      case TaskGroup.tomorrow || TaskGroup.later || TaskGroup.noDate:
        break;
    }
  }
  return <Task>[...overdue, ...today];
}

/// «пн, 9 ноября».
String todayDateLabel(DateTime now) {
  const week = <String>['пн', 'вт', 'ср', 'чт', 'пт', 'сб', 'вс'];
  const months = <String>[
    'января',
    'февраля',
    'марта',
    'апреля',
    'мая',
    'июня',
    'июля',
    'августа',
    'сентября',
    'октября',
    'ноября',
    'декабря',
  ];
  return '${week[now.weekday - 1]}, ${now.day} ${months[now.month - 1]}';
}

/// Срок задачи коротко, без слова «просрочено»: сегодня — «11:00»,
/// «вечером», «без времени»; другой день — «вчера», «завтра в 10:00»,
/// «15 ноября».
String todayDueShort(Task task, DateTime now) {
  final due = task.dueAt;
  if (due == null) return 'без срока';
  final sameDay =
      due.year == now.year && due.month == now.month && due.day == now.day;
  if (!sameDay) return formatDue(due, task.duePrecision, now);
  return switch (task.duePrecision) {
    DuePrecision.date => 'без времени',
    DuePrecision.dateTime => formatTime(due),
    DuePrecision.partOfDay => PartOfDay.of(due).label,
  };
}

/// Подпись срока задачи в «Сегодня»: «11:00», «вечером», «без времени»,
/// у просроченной — «…, просрочено».
String todayDueLabel(Task task, DateTime now) {
  final base = todayDueShort(task, now);
  return isOverdue(task, now) ? '$base, просрочено' : base;
}

/// «просрочена 1 задача», «просрочены 2 задачи», «просрочено 5 задач».
String overdueSummary(int overdue) {
  final verb = ruPlural(overdue, 'просрочена', 'просрочены', 'просрочено');
  final noun = ruPlural(overdue, 'задача', 'задачи', 'задач');
  return '$verb $overdue $noun';
}

/// Итог под заголовком: «просрочена 1 задача», «3 дела», «дел нет».
String todaySummary(int count, int overdue) {
  if (overdue > 0) return overdueSummary(overdue);
  if (count == 0) return 'дел нет';
  return deeds(count);
}
