import 'package:flutter/material.dart';

import '../../core/formatting/due_format.dart';
import '../../core/models/task.dart';
import '../assistant_theme.dart';
import '../widgets/task_tile.dart';

/// Вид секции повестки.
enum AgendaKind { overdue, day, freeRun, later, noDate }

/// Секция повестки: просроченное, один день, серия свободных дней,
/// «Позже» или «Без срока». Неизменяемая.
@immutable
final class AgendaSection {
  AgendaSection({
    required this.kind,
    required this.label,
    List<Task> tasks = const <Task>[],
    this.start,
    this.end,
  }) : tasks = List<Task>.unmodifiable(tasks);

  final AgendaKind kind;
  final String label;
  final List<Task> tasks;

  /// Первый календарный день секции (для [AgendaKind.day] и
  /// [AgendaKind.freeRun]), локальная полночь.
  final DateTime? start;

  /// Последний календарный день секции (включительно).
  final DateTime? end;

  @override
  String toString() => 'AgendaSection($kind, $label, ${tasks.length})';
}

const List<String> _weekdaysShort = <String>[
  'пн',
  'вт',
  'ср',
  'чт',
  'пт',
  'сб',
  'вс',
];

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

/// Разница в календарных днях без влияния перехода на летнее время.
int _calendarDays(DateTime from, DateTime to) {
  final a = DateTime.utc(from.year, from.month, from.day);
  final b = DateTime.utc(to.year, to.month, to.day);
  return b.difference(a).inDays;
}

String _capitalize(String value) =>
    value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

String _dayMonth(DateTime day, DateTime now) {
  final base = '${day.day} ${_monthsGenitive[day.month - 1]}';
  return day.year == now.year ? base : '$base ${day.year}';
}

/// «Завтра · пт, 6 ноября», «Сегодня · чт, 5 ноября», а для дальних дней —
/// «Вс, 8 ноября».
String _dayLabel(DateTime day, DateTime now) {
  final weekday = _weekdaysShort[day.weekday - 1];
  final relative = _calendarDays(now, day) <= 2;
  if (relative) {
    return '${_capitalize(formatDay(day, now))} · '
        '$weekday, ${_dayMonth(day, now)}';
  }
  return '${_capitalize(weekday)}, ${formatDay(day, now)}';
}

/// «свободно» для одного дня, «свободно · 7–9 ноября» для серии,
/// «свободно · 30 ноября – 2 декабря» через границу месяца.
String _freeRunLabel(DateTime start, DateTime end, DateTime now) {
  if (_calendarDays(start, end) == 0) return 'свободно';
  if (start.year == end.year && start.month == end.month) {
    final month = _monthsGenitive[start.month - 1];
    final year = start.year == now.year ? '' : ' ${start.year}';
    return 'свободно · ${start.day}–${end.day} $month$year';
  }
  return 'свободно · ${_dayMonth(start, now)} – ${_dayMonth(end, now)}';
}

List<Task> _byDue(List<Task> tasks) {
  final indexed = tasks.indexed.toList()
    ..sort((a, b) {
      final byDue = a.$2.dueAt!.compareTo(b.$2.dueAt!);
      return byDue != 0 ? byDue : a.$1.compareTo(b.$1);
    });
  return <Task>[for (final (_, task) in indexed) task];
}

/// Сколько активных задач впереди: срок сегодня или позже, не
/// просрочены — то, что повестка ([buildAgenda]) раскладывает по дням и в
/// «Позже». Счётчик «Планирования» в меню.
int upcomingCount(List<Task> tasks, DateTime now) => tasks
    .where(
      (Task t) => t.isActive && t.dueAt != null && !isOverdue(t, now),
    )
    .length;

/// Раскладывает активные задачи по повестке на [days] календарных дней,
/// начиная с сегодняшнего (по местному времени [now]).
///
/// Порядок: «Просрочено» (если есть), затем дни окна — день с задачами
/// даёт секцию [AgendaKind.day], подряд идущие пустые дни сворачиваются
/// в одну [AgendaKind.freeRun]; затем «Позже» и «Без срока» (если есть).
/// Неактивные задачи (выполненные, отменённые, удалённые) пропускаются.
List<AgendaSection> buildAgenda(
  List<Task> tasks,
  DateTime now, {
  int days = 14,
}) {
  final window = days < 0 ? 0 : days;
  final overdue = <Task>[];
  final later = <Task>[];
  final noDate = <Task>[];
  final perDay = List<List<Task>>.generate(window, (_) => <Task>[]);

  for (final task in tasks) {
    if (!task.isActive) continue;
    final due = task.dueAt;
    if (due == null) {
      noDate.add(task);
    } else if (isOverdue(task, now)) {
      overdue.add(task);
    } else {
      final offset = _calendarDays(now, due);
      if (offset >= 0 && offset < window) {
        perDay[offset].add(task);
      } else {
        later.add(task);
      }
    }
  }

  final sections = <AgendaSection>[
    if (overdue.isNotEmpty)
      AgendaSection(
        kind: AgendaKind.overdue,
        label: 'Просрочено',
        tasks: _byDue(overdue),
      ),
  ];

  DateTime? freeStart;
  DateTime? freeEnd;
  void flushFree() {
    if (freeStart == null) return;
    sections.add(
      AgendaSection(
        kind: AgendaKind.freeRun,
        label: _freeRunLabel(freeStart!, freeEnd!, now),
        start: freeStart,
        end: freeEnd,
      ),
    );
    freeStart = null;
    freeEnd = null;
  }

  for (var i = 0; i < window; i++) {
    // Через конструктор, а не Duration: так переход на летнее время
    // не сдвигает день.
    final day = DateTime(now.year, now.month, now.day + i);
    final items = perDay[i];
    if (items.isEmpty) {
      freeStart ??= day;
      freeEnd = day;
      continue;
    }
    flushFree();
    sections.add(
      AgendaSection(
        kind: AgendaKind.day,
        label: _dayLabel(day, now),
        tasks: _byDue(items),
        start: day,
        end: day,
      ),
    );
  }
  flushFree();

  if (later.isNotEmpty) {
    sections.add(
      AgendaSection(
        kind: AgendaKind.later,
        label: 'Позже',
        tasks: _byDue(later),
      ),
    );
  }
  if (noDate.isNotEmpty) {
    sections.add(
      AgendaSection(
        kind: AgendaKind.noDate,
        label: 'Без срока',
        tasks: noDate,
      ),
    );
  }
  return sections;
}

String _daysWord(int n) {
  final mod100 = n % 100;
  final mod10 = n % 10;
  if (mod100 >= 11 && mod100 <= 14) return 'дней';
  if (mod10 == 1) return 'день';
  if (mod10 >= 2 && mod10 <= 4) return 'дня';
  return 'дней';
}

/// Экран «Планирование»: повестка по дням на [days] дней вперёд.
///
/// Данные и действия приходят через конструктор; сам экран ничего
/// не сохраняет.
final class PlanningScreen extends StatelessWidget {
  const PlanningScreen({
    super.key,
    required this.tasks,
    required this.now,
    required this.selectedId,
    required this.onOpenTask,
    required this.onToggleDone,
    this.days = 14,
  });

  /// Активные задачи.
  final List<Task> tasks;
  final DateTime now;

  /// Задача, с которой сейчас работает помощник.
  final String? selectedId;
  final ValueChanged<Task> onOpenTask;
  final ValueChanged<Task> onToggleDone;
  final int days;

  @override
  Widget build(BuildContext context) {
    final sections = buildAgenda(tasks, now, days: days);
    final hasTasks = sections.any((s) => s.tasks.isNotEmpty);
    final window = days < 0 ? 0 : days;

    return SingleChildScrollView(
      key: const ValueKey<String>('planning-scroll'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  'Планирование',
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(color: AssistantColors.textStrong),
                ),
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  '$window ${_daysWord(window)} вперёд · '
                  'с ${_weekdaysShort[now.weekday - 1]}, '
                  '${_dayMonth(now, now)}',
                  style: technicalTextStyle,
                ),
              ),
              if (!hasTasks)
                const EmptyState(
                  icon: Icons.event_available_outlined,
                  title: 'Планов нет',
                  hint: 'Задачи со сроком появятся здесь по дням.',
                )
              else
                for (final section in sections) ..._buildSection(section),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildSection(AgendaSection section) {
    if (section.kind == AgendaKind.freeRun) {
      return <Widget>[
        Padding(
          key: ValueKey<String>('free-${section.start!.toIso8601String()}'),
          padding: const EdgeInsets.fromLTRB(8, 16, 8, 4),
          child: Row(
            children: <Widget>[
              const SizedBox(
                width: 12,
                child: Divider(color: AssistantColors.borderSoft),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  section.label,
                  style: technicalTextStyle.copyWith(
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
        ),
      ];
    }
    final isDay = section.kind == AgendaKind.day;
    final label =
        isDay ? section.label : '${section.label} · ${section.tasks.length}';
    return <Widget>[
      SectionLabel(
        label,
        key: ValueKey<String>(
          isDay
              ? 'day-${section.start!.toIso8601String()}'
              : 'section-${section.kind.name}',
        ),
        danger: section.kind == AgendaKind.overdue,
      ),
      for (final task in section.tasks)
        TaskTile(
          task: task,
          now: now,
          selected: task.id == selectedId,
          onTap: () => onOpenTask(task),
          onToggleDone: () => onToggleDone(task),
        ),
    ];
  }
}
