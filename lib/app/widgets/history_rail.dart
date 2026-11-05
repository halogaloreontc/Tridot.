import 'package:flutter/material.dart';

import '../assistant_theme.dart';

/// Одна команда пользователя в истории разговора.
final class HistoryEntry {
  const HistoryEntry({required this.command, required this.timestamp});

  final String command;
  final String timestamp;
}

/// Узкая полоса справа от чата: по черте на каждую команду пользователя.
/// Наведение или долгое нажатие показывает команду, нажатие прокручивает
/// чат к ней. Длинная история прокручивается внутри полосы.
final class HistoryRail extends StatelessWidget {
  const HistoryRail({
    super.key,
    required this.entries,
    required this.onSelect,
    this.activeIndex,
  });

  final List<HistoryEntry> entries;
  final ValueChanged<int> onSelect;
  final int? activeIndex;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('history-rail'),
      width: 40,
      child: entries.isEmpty
          ? const SizedBox.shrink()
          : Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (var index = 0; index < entries.length; index++)
                      _Mark(
                        key: Key('history-$index'),
                        entry: entries[index],
                        active: index == activeIndex,
                        onTap: () => onSelect(index),
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}

final class _Mark extends StatefulWidget {
  const _Mark({
    super.key,
    required this.entry,
    required this.active,
    required this.onTap,
  });

  final HistoryEntry entry;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_Mark> createState() => _MarkState();
}

final class _MarkState extends State<_Mark> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final highlighted = widget.active || _hover;
    return Tooltip(
      message: '${widget.entry.command}\n${widget.entry.timestamp}',
      preferBelow: false,
      waitDuration: const Duration(milliseconds: 250),
      child: Semantics(
        button: true,
        label: 'Перейти к команде: ${widget.entry.command}',
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(8),
            // 40×40 — удобная цель для пальца; черта по центру.
            child: SizedBox(
              width: 40,
              height: 40,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: highlighted ? 20 : 12,
                  height: 3,
                  decoration: BoxDecoration(
                    color: highlighted
                        ? AssistantColors.textStrong
                        : AssistantColors.muted,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
