import '../models/task.dart';

const List<String> _monthsGenitive = <String>[
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

/// Срок по-человечески относительно [now]: «сегодня в 18:00», «завтра»,
/// «послезавтра в 9:30», «15 ноября», «10 января 2027 в 12:00», «завтра
/// вечером».
String formatDue(DateTime due, DuePrecision precision, DateTime now) {
  final day = formatDay(due, now);
  return switch (precision) {
    DuePrecision.date => day,
    DuePrecision.dateTime => '$day в ${formatTime(due)}',
    DuePrecision.partOfDay => '$day ${PartOfDay.of(due).label}',
  };
}

String formatDay(DateTime due, DateTime now) {
  final difference = _calendarDays(now, due);
  switch (difference) {
    case -1:
      return 'вчера';
    case 0:
      return 'сегодня';
    case 1:
      return 'завтра';
    case 2:
      return 'послезавтра';
  }
  final month = _monthsGenitive[due.month - 1];
  if (due.year == now.year) return '${due.day} $month';
  return '${due.day} $month ${due.year}';
}

String formatTime(DateTime value) =>
    '${value.hour}:${value.minute.toString().padLeft(2, '0')}';

/// Срок прошёл: для даты без времени — со следующего дня, для части
/// суток — с её концом («вечером» — с полуночи).
bool isOverdue(Task task, DateTime now) {
  final due = task.dueAt;
  if (due == null) return false;
  return switch (task.duePrecision) {
    DuePrecision.date => _calendarDays(now, due) < 0,
    DuePrecision.dateTime => due.isBefore(now),
    DuePrecision.partOfDay => !PartOfDay.of(due).endOn(due).isAfter(now),
  };
}

/// Момент, с которого задача просрочена, или `null` без срока: для даты —
/// полночь следующего дня, для части суток — её конец.
DateTime? overdueMoment(Task task) {
  final due = task.dueAt;
  if (due == null) return null;
  return switch (task.duePrecision) {
    DuePrecision.date => DateTime(due.year, due.month, due.day + 1),
    DuePrecision.dateTime => due,
    DuePrecision.partOfDay => PartOfDay.of(due).endOn(due),
  };
}

/// Разница в календарных днях, без влияния перехода на летнее время.
int _calendarDays(DateTime from, DateTime to) {
  final a = DateTime.utc(from.year, from.month, from.day);
  final b = DateTime.utc(to.year, to.month, to.day);
  return b.difference(a).inDays;
}

enum TaskGroup { overdue, today, tomorrow, later, noDate }

extension TaskGroupTitle on TaskGroup {
  String get title => switch (this) {
        TaskGroup.overdue => 'Просрочено',
        TaskGroup.today => 'Сегодня',
        TaskGroup.tomorrow => 'Завтра',
        TaskGroup.later => 'Позже',
        TaskGroup.noDate => 'Без срока',
      };
}

TaskGroup groupOf(Task task, DateTime now) {
  final due = task.dueAt;
  if (due == null) return TaskGroup.noDate;
  if (isOverdue(task, now)) return TaskGroup.overdue;
  return switch (_calendarDays(now, due)) {
    0 => TaskGroup.today,
    1 => TaskGroup.tomorrow,
    _ => TaskGroup.later,
  };
}

/// Группы в порядке показа; пустые группы не возвращаются. Порядок задач
/// внутри группы сохраняется (TaskService уже сортирует по сроку).
List<(TaskGroup, List<Task>)> groupTasks(List<Task> tasks, DateTime now) {
  final groups = <TaskGroup, List<Task>>{};
  for (final task in tasks) {
    groups.putIfAbsent(groupOf(task, now), () => <Task>[]).add(task);
  }
  return <(TaskGroup, List<Task>)>[
    for (final group in TaskGroup.values)
      if (groups[group] case final items?) (group, items),
  ];
}
