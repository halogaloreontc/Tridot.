import 'package:flutter/material.dart';

import '../assistant_theme.dart';

/// Одна команда пользователя в хронике разговора.
final class HistoryEntry {
  const HistoryEntry({
    required this.command,
    required this.timestamp,
    this.result,
  });

  final String command;
  final String timestamp;

  /// Ответ помощника на эту команду, если он уже есть.
  final String? result;
}

/// Хроника команд: колонка коротких полос у правого края чата, закреплённая
/// по центру средней части — зеркальная пара кубику у последнего ответа.
///
/// Полосы «живые»: старые короче и тусклее, свежие длиннее и светлее,
/// последняя — цвета успешного кубика. Наведение показывает карточку с
/// командой и ответом, нажатие ведёт к сообщению. На узком экране полосы
/// слишком мелкие для пальца, поэтому нажатие открывает список команд.
final class HistoryRail extends StatelessWidget {
  const HistoryRail({
    super.key,
    required this.entries,
    required this.onSelect,
    this.activeIndex,
    this.compact = false,
  });

  final List<HistoryEntry> entries;
  final ValueChanged<int> onSelect;
  final int? activeIndex;

  /// Узкий экран: вся колонка — одна кнопка, открывающая список команд.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final rail = SizedBox(
      key: const Key('history-rail'),
      width: compact ? 24 : 32,
      child: entries.isEmpty
          ? const SizedBox.shrink()
          : Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (var index = 0; index < entries.length; index++)
                      _Mark(
                        key: Key('history-$index'),
                        entry: entries[index],
                        age: entries.length - 1 - index,
                        active: index == activeIndex,
                        compact: compact,
                        onTap: compact
                            ? () => _openList(context)
                            : () => onSelect(index),
                      ),
                  ],
                ),
              ),
            ),
    );
    if (!compact || entries.isEmpty) return rail;
    return Semantics(
      button: true,
      label: 'Хроника команд: ${entries.length}. Открыть список',
      child: GestureDetector(
        key: const Key('history-rail-open'),
        behavior: HitTestBehavior.opaque,
        onTap: () => _openList(context),
        child: ExcludeSemantics(child: rail),
      ),
    );
  }

  Future<void> _openList(BuildContext context) async {
    final index = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AssistantColors.panel,
      showDragHandle: true,
      builder: (BuildContext context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text('Хроника команд', style: TextStyle(fontSize: 16)),
            ),
            for (var i = entries.length - 1; i >= 0; i--)
              ListTile(
                key: Key('history-item-$i'),
                title: Text(entries[i].command),
                subtitle: entries[i].result == null
                    ? null
                    : Text(
                        entries[i].result!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                leading: Text(entries[i].timestamp, style: technicalTextStyle),
                onTap: () => Navigator.of(context).pop(i),
              ),
          ],
        ),
      ),
    );
    if (index != null) onSelect(index);
  }
}

final class _Mark extends StatefulWidget {
  const _Mark({
    super.key,
    required this.entry,
    required this.age,
    required this.active,
    required this.compact,
    required this.onTap,
  });

  final HistoryEntry entry;

  /// 0 — последняя команда, дальше — старше.
  final int age;
  final bool active;
  final bool compact;
  final VoidCallback onTap;

  @override
  State<_Mark> createState() => _MarkState();
}

final class _MarkState extends State<_Mark> {
  bool _hover = false;

  /// Длина и цвет полосы по свежести команды.
  (double, Color) get _look {
    final scale = widget.compact ? .8 : 1.0;
    if (widget.active || _hover) {
      return (18 * scale, AssistantColors.textStrong);
    }
    return switch (widget.age) {
      0 => (16 * scale, AssistantColors.success),
      1 => (14 * scale, AssistantColors.muted),
      2 || 3 => (12 * scale, const Color(0xFF5E655F)),
      _ => (8 * scale, AssistantColors.border),
    };
  }

  @override
  Widget build(BuildContext context) {
    final (width, color) = _look;
    final mark = SizedBox(
      width: widget.compact ? 24 : 32,
      height: widget.compact ? 14 : 20,
      child: Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: EdgeInsets.only(right: widget.compact ? 4 : 0),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: width,
            height: 3,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ),
      ),
    );
    if (widget.compact) return mark;
    return Tooltip(
      key: Key('history-tip-${widget.entry.timestamp}-${widget.age}'),
      preferBelow: false,
      verticalOffset: 0,
      margin: const EdgeInsets.only(right: 48),
      waitDuration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: AssistantColors.raised,
        border: Border.all(color: AssistantColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      richMessage: TextSpan(
        children: <InlineSpan>[
          TextSpan(
            text: '${widget.entry.timestamp} · команда\n',
            style: technicalTextStyle,
          ),
          TextSpan(
            text: widget.entry.command,
            style: const TextStyle(
              fontSize: 14,
              color: AssistantColors.textStrong,
            ),
          ),
          if (widget.entry.result != null)
            TextSpan(
              text: '\n${widget.entry.result}',
              style: const TextStyle(fontSize: 13, color: AssistantColors.text),
            ),
          const TextSpan(
            text: '\nНажмите, чтобы перейти к сообщению',
            style: technicalTextStyle,
          ),
        ],
      ),
      child: Semantics(
        button: true,
        label: 'Перейти к команде: ${widget.entry.command}',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: mark,
          ),
        ),
      ),
    );
  }
}
