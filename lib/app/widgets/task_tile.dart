import 'package:flutter/material.dart';

import '../../core/formatting/due_format.dart';
import '../../core/models/task.dart';
import '../assistant_theme.dart';

/// Строка задачи для всех списков: панель задач, проекты, планирование,
/// обзор, архив. Кружок слева завершает задачу (или возвращает её в работу
/// для завершённых), нажатие на строку открывает задачу.
final class TaskTile extends StatelessWidget {
  const TaskTile({
    super.key,
    required this.task,
    required this.now,
    this.selected = false,
    this.onTap,
    this.onToggleDone,
    this.showProject = true,
    this.dense = false,
    this.highlightSelected = true,
  });

  final Task task;
  final DateTime now;
  final bool selected;
  final VoidCallback? onTap;

  /// Завершить активную задачу или вернуть завершённую в работу.
  final VoidCallback? onToggleDone;
  final bool showProject;
  final bool dense;

  /// Подсвечивать выбранную задачу фоном и рамкой. В карточке внутри ответа
  /// рамка уже есть, там выбор показывает только булавка.
  final bool highlightSelected;

  @override
  Widget build(BuildContext context) {
    final done = task.status == TaskStatus.done;
    final overdue = !done && isOverdue(task, now);
    final due = task.dueAt;
    final details = <String>[
      if (due != null)
        overdue
            ? 'просрочено · ${formatDue(due, task.duePrecision, now)}'
            : formatDue(due, task.duePrecision, now),
      if (showProject && task.project != null) '#${task.project}',
    ];
    return Material(
      color: selected && highlightSelected
          ? AssistantColors.raised
          : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: selected && highlightSelected
              ? AssistantColors.border
              : Colors.transparent,
        ),
      ),
      child: InkWell(
        key: ValueKey<String>('task-${task.id}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 4,
            vertical: dense ? 2 : 6,
          ),
          child: Row(
            children: <Widget>[
              IconButton(
                key: ValueKey<String>('toggle-${task.id}'),
                tooltip: done ? 'Вернуть в работу' : 'Отметить выполненной',
                onPressed: onToggleDone,
                icon: Icon(
                  done ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 20,
                  color: done
                      ? AssistantColors.success
                      : overdue
                          ? AssistantColors.danger
                          : AssistantColors.muted,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      task.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color:
                            done ? AssistantColors.muted : AssistantColors.text,
                        decoration: done ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    if (details.isNotEmpty)
                      Text(
                        details.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: metaTextStyle.copyWith(
                          color: overdue ? AssistantColors.danger : null,
                        ),
                      ),
                  ],
                ),
              ),
              if (selected)
                const Padding(
                  padding: EdgeInsets.only(left: 8, right: 4),
                  child: Tooltip(
                    message: 'С этой задачей работает помощник',
                    child: Icon(
                      Icons.push_pin_outlined,
                      size: 16,
                      color: AssistantColors.success,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Заголовок секции в списках: «Сегодня · 2».
final class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.danger = false});

  final String text;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 4),
      child: Text(
        text,
        style: metaTextStyle.copyWith(
          color: danger ? AssistantColors.danger : null,
          letterSpacing: .3,
        ),
      ),
    );
  }
}

/// Пустое состояние экрана.
final class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.hint,
  });

  final IconData icon;
  final String title;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 32, color: AssistantColors.muted),
            const SizedBox(height: 12),
            Text(title, textAlign: TextAlign.center),
            if (hint != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                hint!,
                style: metaTextStyle,
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
