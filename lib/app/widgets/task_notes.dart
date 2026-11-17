import 'package:flutter/material.dart';

import '../../core/formatting/due_format.dart';
import '../../core/formatting/plural.dart';
import '../../core/models/task.dart';
import '../assistant_theme.dart';

/// Кратко о заметках и пунктах для строки задачи: «2 заметки · пункты
/// 1/3». Пусто, если ни того, ни другого нет (ADR-033).
String taskExtrasSummary(Task task) {
  final parts = <String>[
    if (task.notes.isNotEmpty)
      '${task.notes.length} '
          '${ruPlural(task.notes.length, 'заметка', 'заметки', 'заметок')}',
    if (task.items.isNotEmpty)
      'пункты ${task.items.where((TaskItem i) => i.done).length}/'
          '${task.items.length}',
  ];
  return parts.join('\u00a0· ');
}

/// Пункты и заметки задачи из чата (ADR-033): в документе задачи и в
/// шапке её чата. Заметки — старые сверху, у каждой время записи.
final class TaskNotesSection extends StatelessWidget {
  const TaskNotesSection({
    super.key,
    required this.task,
    required this.now,
    this.onToggleItem,
  });

  final Task task;
  final DateTime now;

  /// Отметить пункт [index]; `null` — только показ.
  final ValueChanged<int>? onToggleItem;

  @override
  Widget build(BuildContext context) {
    if (task.notes.isEmpty && task.items.isEmpty) {
      return const SizedBox.shrink();
    }
    final body = Theme.of(context).textTheme.bodyMedium;
    return Column(
      key: const Key('task-notes'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (task.items.isNotEmpty) ...<Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Text('Пункты', style: metaStyle(context)),
          ),
          for (var i = 0; i < task.items.length; i++)
            InkWell(
              key: Key('task-item-$i'),
              onTap: onToggleItem == null ? null : () => onToggleItem!(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(
                      task.items[i].done
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 18,
                      color: task.items[i].done
                          ? context.colors.success
                          : context.colors.muted,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        task.items[i].text,
                        style: body?.copyWith(
                          decoration: task.items[i].done
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
        if (task.notes.isNotEmpty) ...<Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Text('Заметки из чата', style: metaStyle(context)),
          ),
          for (final note in task.notes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // Время — своей шириной: на крупном шрифте «12:00» не
                  // рвётся (ADR-021).
                  Text(_when(note.at), style: metaNumStyle(context)),
                  const SizedBox(width: 12),
                  Expanded(child: Text(note.text, style: body)),
                ],
              ),
            ),
        ],
      ],
    );
  }

  /// «14:05» сегодня, «03.11» — раньше.
  String _when(DateTime at) {
    if (at.year == now.year && at.month == now.month && at.day == now.day) {
      return formatTime(at);
    }
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(at.day)}.${two(at.month)}';
  }
}
