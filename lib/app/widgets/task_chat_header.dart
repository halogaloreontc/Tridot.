import 'package:flutter/material.dart';

import '../../core/formatting/due_format.dart';
import '../../core/models/task.dart';
import '../assistant_theme.dart';

/// Шапка чата задачи (ADR-010): название, срок, статус и действия —
/// «Выполнено» / «Вернуть в работу», «Перенести…», документ.
///
/// Раскладка — по ширине, которая досталась шапке (а не по ширине окна:
/// рядом с ней поиск и кнопка панели):
/// - широко — одна строка: название, срок, статус, кнопка и значки;
/// - средне — название, под ним срок и статус, действия значками;
/// - узко или крупный шрифт — название и меню действий.
/// Кнопки не сжимают название до буквы.
final class TaskChatHeader extends StatelessWidget {
  const TaskChatHeader({
    super.key,
    required this.task,
    required this.now,
    required this.narrow,
    required this.onDone,
    required this.onReopen,
    required this.onReschedule,
    required this.onOpenDocument,
  });

  /// Задача чата; `null`, пока список задач не прочитан.
  final Task? task;
  final DateTime now;
  final bool narrow;
  final VoidCallback onDone;
  final VoidCallback onReopen;
  final VoidCallback onReschedule;
  final VoidCallback onOpenDocument;

  /// Сколько названия должно остаться видно в одной строке; меньше — срок
  /// и статус уходят под название, действия — в значки.
  static const double minTitleWidth = 180;

  /// Меньше — название и меню действий.
  static const double mediumWidth = 320;

  static TextStyle _titleStyleOf(BuildContext context) => TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: context.colors.textStrong,
      );

  /// «В работе», «Выполнена», «Просрочена».
  static (String, Color) statusOf(
    Task task,
    DateTime now,
    AppPalette colors,
  ) {
    if (task.status == TaskStatus.done) {
      return ('Выполнена', colors.success);
    }
    if (isOverdue(task, now)) return ('Просрочена', colors.danger);
    return ('В работе', colors.muted);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) =>
            _build(context, constraints.maxWidth),
      );

  Widget _build(BuildContext context, double width) {
    final task = this.task;
    if (task == null) {
      return Text(
        'Задача',
        key: Key('task-chat-header'),
        style: _titleStyleOf(context),
      );
    }
    final done = task.status == TaskStatus.done;
    final due = task.dueAt;
    final (status, statusColor) = statusOf(task, now, context.colors);
    final title = Text(
      task.title,
      key: const Key('task-chat-title'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: _titleStyleOf(context),
    );
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    final compact = narrow || largeText || width < mediumWidth;
    if (!compact && width < _fullWidth(context, task, status, done: done)) {
      return _medium(
        context,
        task,
        done: done,
        status: status,
        color: statusColor,
      );
    }
    if (compact) {
      return Row(
        key: const Key('task-chat-header'),
        children: <Widget>[
          Expanded(
            child: Tooltip(
              message: <String>[
                status,
                if (due != null) formatDue(due, task.duePrecision, now),
              ].join(' · '),
              child: title,
            ),
          ),
          PopupMenuButton<String>(
            key: const Key('task-chat-menu'),
            tooltip: 'Действия с задачей',
            icon:
                Icon(Icons.more_horiz, size: 22, color: context.colors.accent),
            onSelected: (String value) => switch (value) {
              'done' => onDone(),
              'reopen' => onReopen(),
              'reschedule' => onReschedule(),
              _ => onOpenDocument(),
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                enabled: false,
                child: Text(
                  status,
                  key: const Key('task-chat-status'),
                  style: metaStyle(context).copyWith(color: statusColor),
                ),
              ),
              if (done)
                const PopupMenuItem<String>(
                  key: Key('task-chat-reopen'),
                  value: 'reopen',
                  child: Text('Вернуть в работу'),
                )
              else
                const PopupMenuItem<String>(
                  key: Key('task-chat-done'),
                  value: 'done',
                  child: Text('Выполнено'),
                ),
              const PopupMenuItem<String>(
                key: Key('task-chat-reschedule'),
                value: 'reschedule',
                child: Text('Перенести…'),
              ),
              const PopupMenuItem<String>(
                key: Key('task-chat-document'),
                value: 'document',
                child: Text('Документ задачи'),
              ),
            ],
          ),
        ],
      );
    }
    final buttonStyle = OutlinedButton.styleFrom(
      foregroundColor: context.colors.text,
      minimumSize: const Size(0, 32),
      visualDensity: VisualDensity.standard,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      shape: const StadiumBorder(),
    );
    return Row(
      key: const Key('task-chat-header'),
      children: <Widget>[
        Flexible(child: title),
        if (due != null) ...<Widget>[
          const SizedBox(width: 10),
          Text(
            formatDue(due, task.duePrecision, now),
            style: metaStyle(context),
          ),
        ],
        const SizedBox(width: 10),
        Text(
          status,
          key: const Key('task-chat-status'),
          style: metaStyle(context).copyWith(color: statusColor),
        ),
        const SizedBox(width: 12),
        if (done)
          OutlinedButton.icon(
            key: const Key('task-chat-reopen'),
            onPressed: onReopen,
            style: buttonStyle,
            icon: const Icon(Icons.replay, size: 16),
            label: const Text(
              'Вернуть в работу',
              style: TextStyle(fontSize: 13),
            ),
          )
        else
          OutlinedButton.icon(
            key: const Key('task-chat-done'),
            onPressed: onDone,
            style: buttonStyle,
            icon: const Icon(Icons.check, size: 16),
            label: const Text('Выполнено', style: TextStyle(fontSize: 13)),
          ),
        IconButton(
          key: const Key('task-chat-reschedule'),
          tooltip: 'Перенести…',
          onPressed: onReschedule,
          iconSize: 18,
          icon: const Icon(Icons.update),
        ),
        IconButton(
          key: const Key('task-chat-document'),
          tooltip: 'Открыть документ задачи',
          onPressed: onOpenDocument,
          iconSize: 18,
          icon: const Icon(Icons.description_outlined),
        ),
      ],
    );
  }

  /// Ширина одной строки без названия плюс [minTitleWidth]: тексты
  /// меряются тем же шрифтом и масштабом, что на экране.
  double _fullWidth(
    BuildContext context,
    Task task,
    String status, {
    required bool done,
  }) {
    final scaler = MediaQuery.textScalerOf(context);
    final base = DefaultTextStyle.of(context).style;
    double measure(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: base.merge(style)),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    final due = task.dueAt;
    final label = Theme.of(context)
        .textTheme
        .labelLarge
        ?.merge(const TextStyle(fontSize: 13));
    return minTitleWidth +
        (due == null
            ? 0
            : 10 +
                measure(
                  formatDue(due, task.duePrecision, now),
                  metaStyle(context),
                )) +
        10 +
        measure(status, metaStyle(context)) +
        12 +
        // Кнопка: отступы 12 + значок 16 + промежуток 8 + подпись.
        12 +
        16 +
        8 +
        measure(
          done ? 'Вернуть в работу' : 'Выполнено',
          label ?? const TextStyle(fontSize: 13),
        ) +
        12 +
        // Два значка по 48 и запас на округление.
        2 * 48 +
        8;
  }

  /// Средняя ширина: название, под ним срок и статус; действия — значки с
  /// подсказками.
  Widget _medium(
    BuildContext context,
    Task task, {
    required bool done,
    required String status,
    required Color color,
  }) {
    final due = task.dueAt;
    return Row(
      key: const Key('task-chat-header'),
      children: <Widget>[
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                task.title,
                key: const Key('task-chat-title'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _titleStyleOf(context).copyWith(height: 1.25),
              ),
              Row(
                children: <Widget>[
                  if (due != null) ...<Widget>[
                    Flexible(
                      child: Text(
                        formatDue(due, task.duePrecision, now),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: metaStyle(context).copyWith(height: 1.2),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    status,
                    key: const Key('task-chat-status'),
                    maxLines: 1,
                    style: metaStyle(context).copyWith(
                      color: color,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (done)
          IconButton(
            key: const Key('task-chat-reopen'),
            tooltip: 'Вернуть в работу',
            onPressed: onReopen,
            iconSize: 18,
            icon: const Icon(Icons.replay),
          )
        else
          IconButton(
            key: const Key('task-chat-done'),
            tooltip: 'Выполнено',
            onPressed: onDone,
            iconSize: 18,
            icon: const Icon(Icons.check),
          ),
        IconButton(
          key: const Key('task-chat-reschedule'),
          tooltip: 'Перенести…',
          onPressed: onReschedule,
          iconSize: 18,
          icon: const Icon(Icons.update),
        ),
        IconButton(
          key: const Key('task-chat-document'),
          tooltip: 'Открыть документ задачи',
          onPressed: onOpenDocument,
          iconSize: 18,
          icon: const Icon(Icons.description_outlined),
        ),
      ],
    );
  }
}
