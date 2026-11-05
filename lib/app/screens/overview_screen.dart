import 'package:flutter/material.dart';

import '../../core/formatting/due_format.dart';
import '../../core/models/task.dart';
import '../assistant_theme.dart';
import '../widgets/task_tile.dart';

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

/// Сколько недель показывает сетка активности.
const int activityWeeks = 8;

/// Сколько ближайших задач показывает обзор.
const int upcomingLimit = 5;

/// Число выполненных задач по дням. Ключ — локальная дата в полночь.
/// Учитываются только завершённые и не удалённые задачи с [Task.completedAt].
Map<DateTime, int> completionsByDay(List<Task> tasks) {
  final result = <DateTime, int>{};
  for (final task in tasks) {
    final completed = task.completedAt;
    if (completed == null ||
        task.status != TaskStatus.done ||
        task.deletedAt != null) {
      continue;
    }
    final local = completed.toLocal();
    final day = DateTime(local.year, local.month, local.day);
    result[day] = (result[day] ?? 0) + 1;
  }
  return result;
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _dayLabel(DateTime day) =>
    '${day.day} ${_monthsGenitive[day.month - 1]}';

/// Обзор: счётчики, ближайшие задачи и сетка выполненных задач.
final class OverviewScreen extends StatelessWidget {
  const OverviewScreen({
    super.key,
    required this.tasks,
    required this.now,
    required this.selectedId,
    required this.onOpenTask,
    required this.onToggleDone,
    required this.onGoToTasks,
  });

  /// Все неудалённые задачи: активные и завершённые.
  final List<Task> tasks;
  final DateTime now;
  final String? selectedId;
  final ValueChanged<Task> onOpenTask;
  final ValueChanged<Task> onToggleDone;
  final VoidCallback onGoToTasks;

  @override
  Widget build(BuildContext context) {
    final visible = tasks.where((Task t) => t.deletedAt == null).toList();
    return SingleChildScrollView(
      key: const Key('overview-scroll'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'Обзор',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(color: AssistantColors.textStrong),
              ),
              if (visible.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 24),
                  child: EmptyState(
                    key: Key('overview-empty'),
                    icon: Icons.inbox_outlined,
                    title: 'Задач пока нет',
                    hint: 'Создайте первую задачу в чате: '
                        'Добавь задачу «…» на завтра',
                  ),
                )
              else ...<Widget>[
                const SizedBox(height: 16),
                _buildStats(visible),
                const SectionLabel('Ближайшие'),
                ..._buildUpcoming(visible),
                const SectionLabel('Активность'),
                _ActivityGrid(
                  counts: completionsByDay(visible),
                  now: now,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStats(List<Task> visible) {
    final today = _dateOnly(now);
    final weekStart = today.subtract(const Duration(days: 6));
    final active = visible.where((Task t) => t.isActive).toList();
    final overdue = active.where((Task t) => isOverdue(t, now)).length;
    final dueToday = active.where((Task t) {
      final due = t.dueAt;
      return due != null && _sameDay(due, now);
    }).length;
    final doneWeek = visible.where((Task t) {
      final completed = t.completedAt;
      if (t.status != TaskStatus.done || completed == null) return false;
      final day = _dateOnly(completed.toLocal());
      return !day.isBefore(weekStart) && !day.isAfter(today);
    }).length;

    final stats = <(String, String, int, Color)>[
      ('active', 'Активные', active.length, AssistantColors.textStrong),
      (
        'overdue',
        'Просрочено',
        overdue,
        overdue > 0 ? AssistantColors.danger : AssistantColors.textStrong,
      ),
      ('today', 'Сегодня', dueToday, AssistantColors.textStrong),
      ('done-week', 'Выполнено за 7 дней', doneWeek, AssistantColors.success),
    ];

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        const spacing = 8.0;
        final columns = constraints.maxWidth >= 640 ? 4 : 2;
        final width =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: <Widget>[
            for (final (id, label, value, color) in stats)
              SizedBox(
                width: width,
                child: _StatTile(
                  key: Key('stat-$id'),
                  label: label,
                  value: value,
                  valueColor: color,
                  onTap: onGoToTasks,
                ),
              ),
          ],
        );
      },
    );
  }

  List<Widget> _buildUpcoming(List<Task> visible) {
    final upcoming =
        visible.where((Task t) => t.isActive && t.dueAt != null).toList()
          ..sort((Task a, Task b) {
            final aOver = isOverdue(a, now);
            final bOver = isOverdue(b, now);
            if (aOver != bOver) return aOver ? -1 : 1;
            final byDue = a.dueAt!.compareTo(b.dueAt!);
            if (byDue != 0) return byDue;
            return a.id.compareTo(b.id);
          });
    if (upcoming.isEmpty) {
      return const <Widget>[
        EmptyState(
          key: Key('upcoming-empty'),
          icon: Icons.event_available_outlined,
          title: 'Нет задач со сроком',
          hint: 'Задачи со сроком появятся здесь',
        ),
      ];
    }
    return <Widget>[
      for (final task in upcoming.take(upcomingLimit))
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

final class _StatTile extends StatelessWidget {
  const _StatTile({
    super.key,
    required this.label,
    required this.value,
    required this.valueColor,
    required this.onTap,
  });

  final String label;
  final int value;
  final Color valueColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AssistantColors.raised,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  '$value',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w500,
                    color: valueColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(label, style: technicalTextStyle),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Сетка в стиле GitHub: столбцы — недели, строки — пн..вс,
/// последний столбец содержит сегодняшний день.
final class _ActivityGrid extends StatelessWidget {
  const _ActivityGrid({required this.counts, required this.now});

  final Map<DateTime, int> counts;
  final DateTime now;

  static const double cell = 14;
  static const double gap = 3;

  static Color shade(int count) {
    if (count <= 0) return AssistantColors.raised;
    if (count == 1) return AssistantColors.success.withValues(alpha: .35);
    if (count <= 3) return AssistantColors.success.withValues(alpha: .65);
    return AssistantColors.success;
  }

  @override
  Widget build(BuildContext context) {
    final today = _dateOnly(now);
    final lastMonday = today.subtract(Duration(days: today.weekday - 1));
    final firstMonday = DateTime(
      lastMonday.year,
      lastMonday.month,
      lastMonday.day - 7 * (activityWeeks - 1),
    );
    var total = 0;
    final columns = <Widget>[];
    for (var week = 0; week < activityWeeks; week++) {
      final cells = <Widget>[];
      for (var weekday = 0; weekday < 7; weekday++) {
        final day = DateTime(
          firstMonday.year,
          firstMonday.month,
          firstMonday.day + week * 7 + weekday,
        );
        if (weekday > 0) cells.add(const SizedBox(height: gap));
        if (day.isAfter(today)) {
          cells.add(const SizedBox(width: cell, height: cell));
          continue;
        }
        final count = counts[day] ?? 0;
        total += count;
        cells.add(
          Tooltip(
            key: Key(
              'activity-${day.year}-${day.month}-${day.day}',
            ),
            message: '${_dayLabel(day)}: выполнено $count',
            child: Container(
              width: cell,
              height: cell,
              decoration: BoxDecoration(
                color: shade(count),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        );
      }
      if (week > 0) columns.add(const SizedBox(width: gap));
      columns.add(Column(mainAxisSize: MainAxisSize.min, children: cells));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(mainAxisSize: MainAxisSize.min, children: columns),
          const SizedBox(height: 10),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            runSpacing: 4,
            children: <Widget>[
              const Text('меньше', style: technicalTextStyle),
              for (final level in const <int>[0, 1, 2, 4])
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: shade(level),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              const Text('больше', style: technicalTextStyle),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Выполнено за $activityWeeks недель: $total',
            key: const Key('activity-total'),
            style: technicalTextStyle,
          ),
        ],
      ),
    );
  }
}
