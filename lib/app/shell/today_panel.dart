import 'package:flutter/material.dart';

import '../../core/formatting/due_format.dart';
import '../../core/formatting/plural.dart';
import '../../core/models/task.dart';
import '../assistant_theme.dart';

/// Ждущая отметки карточка действия в «Сегодня»: «Приход 318 ждёт
/// отметки · Нода · склад».
final class TodayPending {
  const TodayPending({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String id;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
}

/// Пилюля «Разделов»: подпись, подпись для чтения с экрана, точка
/// состояния (подключения).
final class TodaySection {
  const TodaySection({
    required this.id,
    required this.label,
    required this.onTap,
    this.semantics,
    this.dot,
  });

  final String id;
  final String label;
  final String? semantics;
  final Color? dot;
  final VoidCallback onTap;
}

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

/// Подпись срока задачи в «Сегодня»: «11:00», «вечером», «без времени»,
/// у просроченной — «…, просрочено».
String todayDueLabel(Task task, DateTime now) {
  final due = task.dueAt;
  if (due == null) return 'без срока';
  final sameDay =
      due.year == now.year && due.month == now.month && due.day == now.day;
  final String base;
  if (sameDay) {
    base = switch (task.duePrecision) {
      DuePrecision.date => 'без времени',
      DuePrecision.dateTime => formatTime(due),
      DuePrecision.partOfDay => PartOfDay.of(due).label,
    };
  } else {
    base = formatDue(due, task.duePrecision, now);
  }
  return isOverdue(task, now) ? '$base, просрочено' : base;
}

/// Итог под заголовком: «просрочена 1 задача», «3 дела», «дел нет».
String todaySummary(int count, int overdue) {
  if (overdue > 0) {
    final verb = ruPlural(overdue, 'просрочена', 'просрочены', 'просрочено');
    final noun = ruPlural(overdue, 'задача', 'задачи', 'задач');
    return '$verb $overdue $noun';
  }
  if (count == 0) return 'дел нет';
  return deeds(count);
}

/// Правая панель «Сегодня» (макет «Д»): дела на сегодня и просроченные,
/// ждущие отметки карточки склада, разделы. Быстрых действий здесь нет.
///
/// Своего состояния нет: всё приходит параметрами и колбэками.
final class TodayPanel extends StatelessWidget {
  const TodayPanel({
    super.key,
    required this.now,
    required this.tasks,
    required this.onOpenTask,
    required this.onToggleDone,
    required this.onAllTasks,
    this.pending = const <TodayPending>[],
    this.sections = const <TodaySection>[],
    this.onClose,
    this.closeTooltip = 'Закрыть «Сегодня»',
    this.closeKey = const Key('today-close'),
    this.selectedId,
    this.loading = false,
    this.error,
    this.onRetry,
    this.emptyHint,
  });

  final DateTime now;

  /// Уже отобранные и упорядоченные ([todayTasks]).
  final List<Task> tasks;
  final ValueChanged<Task> onOpenTask;
  final ValueChanged<Task> onToggleDone;
  final VoidCallback onAllTasks;
  final List<TodayPending> pending;
  final List<TodaySection> sections;

  /// Закрыть (телефон) или свернуть колонку (широкий экран).
  final VoidCallback? onClose;
  final String closeTooltip;
  final Key closeKey;
  final String? selectedId;
  final bool loading;
  final Object? error;
  final VoidCallback? onRetry;

  /// Подсказка, когда задач нет совсем.
  final String? emptyHint;

  @override
  Widget build(BuildContext context) {
    final overdue = tasks.where((Task t) => isOverdue(t, now)).length;
    return Material(
      key: const Key('today-panel'),
      color: AssistantColors.sidebar,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 4, top: 6, bottom: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Semantics(
                        header: true,
                        child: const Text(
                          'Сегодня',
                          style: TextStyle(
                            fontSize: 22,
                            height: 1.2,
                            fontWeight: FontWeight.w600,
                            color: AssistantColors.textStrong,
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Wrap(
                        spacing: 8,
                        children: <Widget>[
                          Text(todayDateLabel(now), style: technicalTextStyle),
                          const ExcludeSemantics(
                            child: Text('·', style: technicalTextStyle),
                          ),
                          Text(
                            todaySummary(tasks.length, overdue),
                            key: const Key('today-summary'),
                            style: technicalTextStyle,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (onClose != null)
                IconButton(
                  key: closeKey,
                  tooltip: closeTooltip,
                  onPressed: onClose,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(44, 44),
                  ),
                  icon: const Icon(Icons.close, color: AssistantColors.text),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Semantics(
                    header: true,
                    child: const Text(
                      'Дела',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AssistantColors.textStrong,
                      ),
                    ),
                  ),
                ),
              ),
              Flexible(
                child: TextButton(
                  key: const Key('today-all-tasks'),
                  onPressed: onAllTasks,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(44, 44),
                    foregroundColor: AssistantColors.muted,
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          'Все задачи',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                      Icon(Icons.chevron_right, size: 16),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ..._tasks(),
          for (final item in pending) ...<Widget>[
            const SizedBox(height: 8),
            _PendingRow(item: item),
          ],
          if (sections.isNotEmpty) ...<Widget>[
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Semantics(
                header: true,
                child: const Text(
                  'Разделы',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AssistantColors.textStrong,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final section in sections) _SectionPill(section: section),
              ],
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _tasks() {
    if (loading) {
      return const <Widget>[
        Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (error != null) {
      return <Widget>[
        Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: <Widget>[
              const Text('Не удалось загрузить задачи'),
              const SizedBox(height: 4),
              Text(
                '$error',
                style: technicalTextStyle,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: onRetry,
                child: const Text('Повторить'),
              ),
            ],
          ),
        ),
      ];
    }
    if (tasks.isEmpty) {
      return <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'На сегодня дел нет',
                style: TextStyle(color: AssistantColors.text),
              ),
              if (emptyHint != null) ...<Widget>[
                const SizedBox(height: 4),
                Text(emptyHint!, style: technicalTextStyle),
              ],
            ],
          ),
        ),
      ];
    }
    return <Widget>[
      for (final (index, task) in tasks.indexed) ...<Widget>[
        if (index > 0) const SizedBox(height: 8),
        _TaskRow(
          task: task,
          now: now,
          selected: task.id == selectedId,
          onTap: () => onOpenTask(task),
          onToggle: () => onToggleDone(task),
        ),
      ],
    ];
  }
}

final class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.task,
    required this.now,
    required this.selected,
    required this.onTap,
    required this.onToggle,
  });

  final Task task;
  final DateTime now;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final overdue = isOverdue(task, now);
    final due = todayDueLabel(task, now);
    return Material(
      color: AssistantColors.raised,
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: selected ? AssistantColors.border : AssistantColors.borderSoft,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: InkWell(
        key: ValueKey<String>('today-task-${task.id}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 58),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
            child: Row(
              children: <Widget>[
                Semantics(
                  button: true,
                  label: 'Завершить «${task.title}»',
                  onTap: onToggle,
                  excludeSemantics: true,
                  child: InkWell(
                    key: ValueKey<String>('today-done-${task.id}'),
                    onTap: onToggle,
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox.square(
                      dimension: 44,
                      child: Center(
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: overdue
                                  ? AssistantColors.danger
                                  : AssistantColors.faint,
                              width: 1.5,
                            ),
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        task.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          height: 1.3,
                          color: AssistantColors.textStrong,
                        ),
                      ),
                      Row(
                        children: <Widget>[
                          // Просрочено — не только цветом: точка и слово.
                          if (overdue) ...<Widget>[
                            Container(
                              key: ValueKey<String>('today-overdue-${task.id}'),
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: AssistantColors.danger,
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              due,
                              style: technicalTextStyle.copyWith(
                                color: overdue
                                    ? AssistantColors.danger
                                    : AssistantColors.muted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _PendingRow extends StatelessWidget {
  const _PendingRow({required this.item});

  final TodayPending item;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AssistantColors.raised,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: AssistantColors.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: InkWell(
        key: ValueKey<String>('today-pending-${item.id}'),
        onTap: item.onTap,
        borderRadius: BorderRadius.circular(14),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: <Widget>[
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: AssistantColors.nodaBg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.inventory_2_outlined,
                    size: 16,
                    color: AssistantColors.noda,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        item.title,
                        style: const TextStyle(
                          height: 1.3,
                          color: AssistantColors.textStrong,
                        ),
                      ),
                      Text(
                        item.subtitle,
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.3,
                          color: AssistantColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _SectionPill extends StatelessWidget {
  const _SectionPill({required this.section});

  final TodaySection section;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: section.semantics ?? section.label,
      onTap: section.onTap,
      excludeSemantics: true,
      child: Material(
        color: AssistantColors.raised,
        shape: const StadiumBorder(
          side: BorderSide(color: AssistantColors.borderSoft),
        ),
        child: InkWell(
          key: Key('today-section-${section.id}'),
          onTap: section.onTap,
          customBorder: const StadiumBorder(),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (section.dot != null) ...<Widget>[
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: section.dot,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      section.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: AssistantColors.textStrong,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
