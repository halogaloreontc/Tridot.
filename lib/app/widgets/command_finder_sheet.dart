import 'package:flutter/material.dart';

import '../../core/commands/command_catalog.dart';
import '../assistant_theme.dart';

/// Значок команды каталога по имени ([CommandEntry.iconName]).
IconData commandIcon(String name) => switch (name) {
      'add' => Icons.add,
      'event' => Icons.event_outlined,
      'tag' => Icons.tag,
      'bell' => Icons.notifications_none,
      'checklist' => Icons.checklist,
      'today' => Icons.today_outlined,
      'check' => Icons.check,
      'update' => Icons.update,
      'history' => Icons.history,
      'help' => Icons.help_outline,
      'mood' => Icons.mood,
      'chat' => Icons.chat_bubble_outline,
      'calc' => Icons.calculate_outlined,
      'percent' => Icons.percent,
      'search' => Icons.search,
      'inbox' => Icons.move_to_inbox_outlined,
      'photo' => Icons.no_photography_outlined,
      'key' => Icons.key_outlined,
      'password' => Icons.password,
      'shield' => Icons.add_moderator_outlined,
      'lock' => Icons.lock_outline,
      'backup' => Icons.backup_outlined,
      'restore' => Icons.restore,
      'storage' => Icons.storage_outlined,
      'zip' => Icons.folder_zip_outlined,
      'unzip' => Icons.unarchive_outlined,
      'convert' => Icons.transform,
      'download' => Icons.download_outlined,
      'list' => Icons.list_alt,
      _ => Icons.bolt,
    };

/// «Найти команду»: все команды включённых навыков по разделам и поиск
/// по ним (ADR-020). Возвращает выбранную команду или `null`.
Future<CommandEntry?> showCommandFinder(
  BuildContext context,
  CommandCatalog catalog,
) =>
    showModalBottomSheet<CommandEntry>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AssistantColors.raised,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (BuildContext context) => CommandFinderSheet(catalog: catalog),
    );

final class CommandFinderSheet extends StatefulWidget {
  const CommandFinderSheet({super.key, required this.catalog});

  final CommandCatalog catalog;

  @override
  State<CommandFinderSheet> createState() => _CommandFinderSheetState();
}

final class _CommandFinderSheetState extends State<CommandFinderSheet> {
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final found = widget.catalog.search(_query.text);
    final groups = <CommandCategory, List<CommandEntry>>{};
    for (final entry in found) {
      (groups[entry.category] ??= <CommandEntry>[]).add(entry);
    }
    return Padding(
      // Клавиатура не закрывает поле поиска.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        key: const Key('command-finder'),
        expand: false,
        initialChildSize: .7,
        minChildSize: .4,
        maxChildSize: .95,
        builder: (BuildContext context, ScrollController scroll) {
          return Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  key: const Key('command-search'),
                  controller: _query,
                  autofocus: false,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(color: AssistantColors.textStrong),
                  decoration: const InputDecoration(
                    hintText: 'Найти команду',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                  ),
                ),
              ),
              Expanded(
                child: found.isEmpty
                    ? const Center(
                        key: Key('command-empty'),
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'Такой команды нет. Возможно, нужный навык '
                            'выключен в «Расширениях».',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AssistantColors.muted),
                          ),
                        ),
                      )
                    : ListView(
                        controller: scroll,
                        padding: const EdgeInsets.only(bottom: 16),
                        children: <Widget>[
                          for (final MapEntry(:key, :value)
                              in groups.entries) ...<Widget>[
                            Padding(
                              key: Key('command-category-${key.name}'),
                              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                              child: Text(
                                key.label,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AssistantColors.muted,
                                ),
                              ),
                            ),
                            for (final entry in value) _tile(entry),
                          ],
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _tile(CommandEntry entry) => ListTile(
        key: Key('command-entry-${entry.id}'),
        minTileHeight: 52,
        leading: Icon(
          commandIcon(entry.iconName),
          size: 20,
          color: AssistantColors.textStrong,
        ),
        title: Text(
          entry.label,
          style: const TextStyle(
            fontSize: 15,
            color: AssistantColors.textStrong,
          ),
        ),
        subtitle: Text(
          entry.kind == CommandKind.action ? 'Открыть' : entry.preview,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: metaTextStyle,
        ),
        onTap: () => Navigator.of(context).pop(entry),
      );
}
