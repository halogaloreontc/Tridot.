import 'package:flutter/material.dart';

import '../assistant_theme.dart';
import '../layout.dart';
import 'whole_word_text.dart';

/// Одна команда пользователя в истории разговора.
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

/// «⋯ → История команд» (ADR-027): шторка со списком команд сессии, от
/// новых к старым, одной сгруппированной панелью. Хроники поверх ленты
/// больше нет — лента остаётся листом для чтения.
///
/// Возвращает номер выбранной команды (по порядку в сессии) или `null`.
Future<int?> showCommandHistory(
  BuildContext context, {
  required List<HistoryEntry> entries,
}) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: AppSize.maxSettings),
    builder: (BuildContext context) => _HistorySheet(entries: entries),
  );
}

final class _HistorySheet extends StatelessWidget {
  const _HistorySheet({required this.entries});

  final List<HistoryEntry> entries;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .8,
        ),
        child: ListView(
          key: const Key('history-sheet'),
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(
            AppSpace.insetH,
            0,
            AppSpace.insetH,
            AppSpace.xl,
          ),
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, AppSpace.s),
              child: Semantics(
                header: true,
                child: WholeWordText(
                  'История команд',
                  style: text.titleMedium!.copyWith(color: colors.textStrong),
                ),
              ),
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.group),
              child: Material(
                color: colors.workspace,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (var i = entries.length - 1; i >= 0; i--) ...<Widget>[
                      if (i != entries.length - 1)
                        Padding(
                          padding: const EdgeInsets.only(left: AppSpace.m),
                          child: Divider(
                            height: .5,
                            thickness: .5,
                            color: colors.divider,
                          ),
                        ),
                      _HistoryRow(
                        key: Key('history-item-$i'),
                        entry: entries[i],
                        onTap: () => Navigator.of(context).pop(i),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.m,
                6,
                AppSpace.m,
                0,
              ),
              child: WholeWordText(
                'Нажмите на команду, чтобы перейти к ней в ленте',
                style: text.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _HistoryRow extends StatelessWidget {
  const _HistoryRow({super.key, required this.entry, required this.onTap});

  final HistoryEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final result = entry.result;
    return Semantics(
      button: true,
      label: 'Перейти к команде: ${entry.command}, ${entry.timestamp}',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSize.rowMin),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.rowH,
              vertical: AppSpace.rowV,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      WholeWordText(
                        entry.command,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyLarge!.copyWith(
                          color: colors.textStrong,
                        ),
                      ),
                      if (result != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: WholeWordText(
                            result,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodyMedium!.copyWith(
                              color: colors.muted,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpace.s),
                Text(entry.timestamp, style: metaNumStyle(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
