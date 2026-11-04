import 'package:flutter/material.dart';

import '../assistant_theme.dart';

final class HistoryEntry {
  const HistoryEntry({required this.messages, required this.timestamp});

  final List<String> messages;
  final String timestamp;
}

final class HistoryRail extends StatefulWidget {
  const HistoryRail({super.key, required this.entries});

  final List<HistoryEntry> entries;

  @override
  State<HistoryRail> createState() => _HistoryRailState();
}

final class _HistoryRailState extends State<HistoryRail> {
  int? _preview;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('history-rail'),
      width: 36,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: List<Widget>.generate(widget.entries.length, (index) {
                final active = _preview == index;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: MouseRegion(
                    onEnter: (_) => setState(() => _preview = index),
                    onExit: (_) => setState(() => _preview = null),
                    child: InkWell(
                      key: Key('history-$index'),
                      onTap: () => setState(
                        () => _preview = _preview == index ? null : index,
                      ),
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 32,
                        height: 18,
                        child: Center(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            width: active ? 19.2 : 11.2,
                            height: 2.56,
                            transform: Matrix4.translationValues(
                              active ? -1.6 : 0,
                              0,
                              0,
                            ),
                            decoration: BoxDecoration(
                              color: active
                                  ? const Color(0xFFC4C9C5)
                                  : const Color(0xFF4A504B),
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
          if (_preview != null)
            Positioned(
              right: 44,
              top: 24,
              child: _Preview(entry: widget.entries[_preview!]),
            ),
        ],
      ),
    );
  }
}

final class _Preview extends StatelessWidget {
  const _Preview({required this.entry});

  final HistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1B1E1B),
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: Color(0xFF414741)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Container(
        width: 300,
        constraints: const BoxConstraints(maxHeight: 300),
        padding: const EdgeInsets.all(14),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                'Сообщения версии',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              for (var index = 0; index < entry.messages.length; index++)
                Align(
                  alignment: index.isOdd
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding:
                        index.isOdd ? const EdgeInsets.all(9) : EdgeInsets.zero,
                    decoration: BoxDecoration(
                      color: index.isOdd
                          ? const Color(0xFF292D29)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      entry.messages[index],
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: const Color(0xFFC9CECA),
                          ),
                    ),
                  ),
                ),
              Text(entry.timestamp, style: technicalTextStyle),
            ],
          ),
        ),
      ),
    );
  }
}
