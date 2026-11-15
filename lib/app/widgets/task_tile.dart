import 'package:flutter/material.dart';

import '../../core/formatting/due_format.dart';
import '../../core/models/task.dart';
import '../assistant_theme.dart';
import 'whole_word_text.dart';

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
    // Выбранная — заливкой на уровень выше, без рамки (ADR-027).
    return Material(
      color: selected && highlightSelected
          ? context.colors.bubble
          : Colors.transparent,
      child: InkWell(
        key: ValueKey<String>('task-${task.id}'),
        onTap: onTap,
        child: Padding(
          // В карточке ленты — строка не ниже 56 (ADR-027).
          padding: EdgeInsets.symmetric(
            horizontal: 8,
            vertical: dense ? 4 : 2,
          ),
          child: Row(
            children: <Widget>[
              IconButton(
                key: ValueKey<String>('toggle-${task.id}'),
                tooltip: done ? 'Вернуть в работу' : 'Отметить выполненной',
                onPressed: onToggleDone,
                // Один кружок во всех списках: выполнено — акцентом (ADR-027).
                icon: _Check(done: done, overdue: overdue),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: dense ? 6 : 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        task.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        // Списки — тем же 17/15, что и в ленте (ADR-027).
                        style: Theme.of(context).textTheme.bodyLarge!.copyWith(
                              color: done
                                  ? context.colors.muted
                                  : context.colors.textStrong,
                              decoration:
                                  done ? TextDecoration.lineThrough : null,
                            ),
                      ),
                      if (details.isNotEmpty)
                        Text(
                          details.join(' · '),
                          maxLines: dense ? 2 : 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.bodyMedium!.copyWith(
                                    color: overdue
                                        ? context.colors.danger
                                        : context.colors.muted,
                                  ),
                        ),
                    ],
                  ),
                ),
              ),
              if (selected)
                Padding(
                  padding: EdgeInsets.only(left: 8, right: 4),
                  child: Tooltip(
                    message: 'С этой задачей работает помощник',
                    child: Icon(
                      Icons.push_pin_outlined,
                      size: 18,
                      color: context.colors.accent,
                    ),
                  ),
                ),
              if (dense && onTap != null)
                Padding(
                  padding: const EdgeInsets.only(left: 4, right: 4),
                  child: Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: context.colors.faint,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Кружок задачи в карточке ленты: контур 24 (выполнена — заливка акцентом
/// с галочкой).
final class _Check extends StatelessWidget {
  const _Check({required this.done, required this.overdue});

  final bool done;
  final bool overdue;

  @override
  Widget build(BuildContext context) => Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: done ? context.colors.accent : null,
          border: done
              ? null
              : Border.all(
                  color:
                      overdue ? context.colors.danger : context.colors.border,
                  width: 1.5,
                ),
        ),
        child: done
            ? Icon(Icons.check, size: 16, color: context.colors.onAccent)
            : null,
      );
}

/// Заголовок группы в списках: «Сегодня · 2». Обычный регистр, 15
/// полужирным приглушённым цветом, без разрядки (ADR-027).
final class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.danger = false});

  final String text;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 20, 8, 6),
      child: WholeWordText(
        text,
        style: style.copyWith(
          color: danger ? context.colors.danger : context.colors.muted,
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
            Icon(icon, size: 32, color: context.colors.muted),
            const SizedBox(height: 12),
            Text(title, textAlign: TextAlign.center),
            if (hint != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                hint!,
                style: metaStyle(context),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
