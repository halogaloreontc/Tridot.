import 'package:flutter/material.dart';

import '../../core/chats/attachments.dart';
import '../../core/cloud/cloud_disk.dart';
import '../../core/commands/command_catalog.dart';
import '../assistant_theme.dart';
import '../layout.dart';
import '../attachments/attachment_picker.dart';
import '../attachments/attachment_views.dart';
import 'command_finder_sheet.dart';
import 'composer_shell.dart';
import 'mode_switch.dart';
import 'whole_word_text.dart';

// Прежние импорты этого файла продолжают находить голос и режим.
export 'composer_shell.dart' show VoiceButtonMode, voiceLongPressDuration;
export 'mode_switch.dart' show AssistantViewMode;

/// Файл, выбранный для следующего сообщения: чип над полем ввода.
final class PendingAttachmentChip {
  const PendingAttachmentChip({
    required this.name,
    required this.kind,
    required this.size,
  });

  final String name;
  final AttachmentKind kind;
  final int size;
}

/// Пункт «Найти команду» в «+» → «Шаблоны команд».
final class _FindCommand {
  const _FindCommand();
}

/// Поле команды приложения: [ComposerShell] с «+» (файлы, диски, шаблоны),
/// переключателем «Диалог / Документ» и чипами файлов. Выбор файлов и
/// облако подключаются только здесь — общий вид поля их не тянет. Не
/// блокируется во время отправки, чтобы не терять фокус: повторную
/// отправку отсекает хозяин.
final class CommandComposer extends StatefulWidget {
  const CommandComposer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.sending,
    required this.mode,
    required this.onModeChanged,
    required this.onSend,
    required this.onCommand,
    required this.previousCommand,
    required this.nextCommand,
    this.onAttach,
    this.onCloudDisk,
    this.onConnectDisk,
    this.cloudDisks = const <CloudDisk>[],
    this.templates = const <CommandEntry>[],
    this.onFindCommand,
    this.pending = const <PendingAttachmentChip>[],
    this.onRemovePending,
    this.header,
    this.voiceMode = VoiceButtonMode.hidden,
    this.onVoiceTap,
    this.onVoiceLongPress,
    this.onVoiceCancel,
    this.voicePartial,
    this.voiceNotice,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sending;
  final AssistantViewMode mode;
  final ValueChanged<AssistantViewMode> onModeChanged;
  final VoidCallback onSend;

  /// Команда из «+» → «Шаблоны команд» (ADR-020).
  final ValueChanged<CommandEntry> onCommand;

  /// «+» → «Прикрепить файл» → вид файла (ADR-019).
  final ValueChanged<PickKind>? onAttach;

  /// «+» → «Облачный диск» → подключённый диск.
  final ValueChanged<CloudDisk>? onCloudDisk;

  /// «+» → «Облачный диск» → «Подключить диск» (ни одного не подключено).
  final VoidCallback? onConnectDisk;

  /// Подключённые облачные диски ([CloudDiskMenu.entries]).
  final List<CloudDisk> cloudDisks;

  /// Частые команды в «+» → «Шаблоны команд» ([CommandCatalog.top]).
  final List<CommandEntry> templates;

  /// «Найти команду» — пятый пункт «Шаблонов команд»; `null` — пункта нет.
  final VoidCallback? onFindCommand;

  /// Файлы, выбранные для следующего сообщения.
  final List<PendingAttachmentChip> pending;

  /// Крестик на чипе файла [pending]`[i]`.
  final ValueChanged<int>? onRemovePending;

  /// Микрофон при пустом поле (ADR-023): голосовой ввод в поле, без
  /// озвучивания ответов.
  final VoiceButtonMode voiceMode;

  /// Нажатие на микрофон: при [VoiceButtonMode.off] — предложение
  /// включить, иначе — начать слушать, а пока слушает — закончить с
  /// итогом (на всех платформах, и для экранного диктора).
  final VoidCallback? onVoiceTap;

  /// Долгое нажатие пальцем на пустое поле ввода (только в
  /// [VoiceButtonMode.idle]): начать слушать. С текстом, с файлами и
  /// мышью — обычное выделение и меню «Вставить».
  final VoidCallback? onVoiceLongPress;

  /// Крестик на месте «+», пока слушает или готовится: прервать без
  /// итога.
  final VoidCallback? onVoiceCancel;

  /// Промежуточный распознанный текст: серой строкой над полем, пока
  /// слушает.
  final String? voicePartial;

  /// Подсказка голосового ввода («Нет доступа к микрофону…», «Микрофон
  /// выключен…»): строкой над полем, а не всплывающим уведомлением —
  /// уведомление закрыло бы сам микрофон.
  final String? voiceNotice;

  /// Прошлая и следующая команда из истории для ↑/↓; null — нет.
  final String? Function() previousCommand;
  final String? Function() nextCommand;

  /// Строка над полем: выбор адресата в дуэте помощников.
  final Widget? header;

  @override
  State<CommandComposer> createState() => _CommandComposerState();
}

final class _CommandComposerState extends State<CommandComposer> {
  /// «+»: три пункта со своими списками — «Облачный диск», «Прикрепить
  /// файл», «Шаблоны команд» (действия сейфа — там же, в «Найти
  /// команду»). Выбор
  /// выполняется после закрытия листа: выбор файлов и диалоги открываются
  /// уже над экраном.
  Future<void> _openPlus() async {
    final choice = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (BuildContext context) => _PlusSheet(
        cloudDisks: widget.cloudDisks,
        canAttach: widget.onAttach != null,
        templates: widget.templates,
        canFind: widget.onFindCommand != null,
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case CommandEntry entry:
        widget.onCommand(entry);
      case _FindCommand _:
        widget.onFindCommand?.call();
      case PickKind kind:
        widget.onAttach?.call(kind);
      case CloudDisk disk:
        widget.onCloudDisk?.call(disk);
      case CloudDiskConnect _:
        widget.onConnectDisk?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final plus = Tooltip(
      message: 'Файлы, диски и шаблоны команд',
      child: InkResponse(
        key: const Key('templates-button'),
        onTap: _openPlus,
        radius: 24,
        child: const ComposerRoundIcon(icon: Icons.add),
      ),
    );
    final header = widget.header;
    final pending = widget.pending;
    final Widget? above = header == null && pending.isEmpty
        ? null
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (header != null)
                Align(alignment: Alignment.centerLeft, child: header),
              if (pending.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        for (var i = 0; i < pending.length; i++)
                          AttachmentChip(
                            key: Key('pending-attachment-$i'),
                            name: pending[i].name,
                            kind: pending[i].kind,
                            size: pending[i].size,
                            onRemove: widget.onRemovePending == null
                                ? null
                                : () => widget.onRemovePending!(i),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          );
    return ComposerShell(
      controller: widget.controller,
      focusNode: widget.focusNode,
      sending: widget.sending,
      onSend: widget.onSend,
      previousCommand: widget.previousCommand,
      nextCommand: widget.nextCommand,
      leading: plus,
      // Подписи «Диалог / Документ» — если помещаются целиком.
      center: (BuildContext context, double width) => ModeSwitch(
        mode: widget.mode,
        onChanged: widget.onModeChanged,
        labels: ModeSwitch.labelsFit(context, width),
      ),
      above: above,
      hasAttachments: pending.isNotEmpty,
      voiceMode: widget.voiceMode,
      onVoiceTap: widget.onVoiceTap,
      onVoiceLongPress: widget.onVoiceLongPress,
      onVoiceCancel: widget.onVoiceCancel,
      voicePartial: widget.voicePartial,
      voiceNotice: widget.voiceNotice,
    );
  }
}

/// Лист «+» (ADR-019): у каждого из трёх пунктов свой раскрывающийся
/// список. Возвращает выбор: [CommandEntry], [_FindCommand], [PickKind],
/// [CloudDisk] или [CloudDiskConnect].
final class _PlusSheet extends StatefulWidget {
  const _PlusSheet({
    required this.cloudDisks,
    required this.canAttach,
    required this.templates,
    required this.canFind,
  });

  final List<CloudDisk> cloudDisks;
  final bool canAttach;
  final List<CommandEntry> templates;
  final bool canFind;

  @override
  State<_PlusSheet> createState() => _PlusSheetState();
}

enum _PlusGroup { cloud, attach, templates }

final class _PlusSheetState extends State<_PlusSheet> {
  _PlusGroup? _open;

  void _pick(Object value) => Navigator.of(context).pop(value);

  void _toggle(_PlusGroup group) =>
      setState(() => _open = _open == group ? null : group);

  @override
  Widget build(BuildContext context) {
    final cloud = CloudDiskMenu.entries(widget.cloudDisks);
    return SafeArea(
      child: SingleChildScrollView(
        key: const Key('composer-plus-sheet'),
        // Одна сгруппированная панель на фоне шторки (ADR-027).
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: _inset(
          context,
          <Widget>[
            // Один подключённый диск — пункт сразу открывает его, без
            // выбора диска.
            if (cloud case CloudDiskSingle(:final disk))
              _row(
                key: const Key('composer-cloud'),
                icon: Icons.cloud_outlined,
                label: 'Облачный диск',
                detail: disk.label,
                tile: context.colors.tileBlue,
                onTap: () => _pick(disk),
              )
            else
              ..._group(
                group: _PlusGroup.cloud,
                key: const Key('composer-cloud'),
                icon: Icons.cloud_outlined,
                label: 'Облачный диск',
                tile: context.colors.tileBlue,
                children: switch (cloud) {
                  CloudDiskChoice(:final disks) => <Widget>[
                      for (final disk in disks)
                        _row(
                          key: Key('cloud-${disk.name}'),
                          icon: Icons.folder_open_outlined,
                          label: disk.label,
                          onTap: () => _pick(disk),
                          nested: true,
                        ),
                    ],
                  _ => <Widget>[
                      _row(
                        key: const Key('cloud-connect'),
                        icon: Icons.add_link,
                        label: CloudDiskConnect.label,
                        detail: 'Яндекс Диск, Google Диск',
                        onTap: () => _pick(const CloudDiskConnect()),
                        nested: true,
                      ),
                    ],
                },
              ),
            if (widget.canAttach)
              ..._group(
                group: _PlusGroup.attach,
                key: const Key('composer-attach'),
                icon: Icons.attach_file,
                label: 'Прикрепить файл',
                tile: context.colors.tileGray,
                children: <Widget>[
                  for (final kind in PickKind.values)
                    _row(
                      key: Key('attach-${kind.name}'),
                      icon: kind.icon,
                      label: kind.label,
                      onTap: () => _pick(kind),
                      nested: true,
                    ),
                ],
              ),
            ..._group(
              group: _PlusGroup.templates,
              key: const Key('composer-templates'),
              icon: Icons.bolt,
              label: 'Шаблоны команд',
              tile: context.colors.tileViolet,
              children: <Widget>[
                for (final entry in widget.templates)
                  _row(
                    key: Key('command-top-${entry.id}'),
                    icon: commandIcon(entry.iconName),
                    label: entry.label,
                    onTap: () => _pick(entry),
                    nested: true,
                  ),
                if (widget.canFind)
                  _row(
                    key: const Key('command-find'),
                    icon: Icons.search,
                    label: 'Найти команду',
                    detail: 'Все команды по разделам',
                    onTap: () => _pick(const _FindCommand()),
                    nested: true,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Строки на листе ячейкой со скруглением и разделителями «вставкой».
  Widget _inset(BuildContext context, List<Widget> rows) => ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Material(
          color: context.colors.workspace,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (var i = 0; i < rows.length; i++) ...<Widget>[
                if (i > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 56),
                    child: Divider(
                      height: .5,
                      thickness: .5,
                      color: context.colors.divider,
                    ),
                  ),
                rows[i],
              ],
            ],
          ),
        ),
      );

  List<Widget> _group({
    required _PlusGroup group,
    required Key key,
    required IconData icon,
    required String label,
    required List<Widget> children,
    Color? tile,
  }) {
    final open = _open == group;
    return <Widget>[
      _row(
        key: key,
        icon: icon,
        label: label,
        trailing: Icon(
          open ? Icons.expand_less : Icons.expand_more,
          color: context.colors.icon,
        ),
        expanded: open,
        tile: tile,
        onTap: () => _toggle(group),
      ),
      if (open) ...children,
    ];
  }

  Widget _row({
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    String? detail,
    Widget? trailing,
    bool nested = false,
    bool? expanded,
    Color? tile,
  }) {
    final colors = context.colors;
    // Пункт верхнего уровня — значком на цветной плитке, вложенный — просто
    // значком.
    final Widget leading = nested
        ? SizedBox(
            width: 28,
            child: Icon(icon, size: 22, color: colors.icon),
          )
        : Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: tile ?? colors.tileGray,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(icon, size: 18, color: Colors.white),
          );
    return Semantics(
      expanded: expanded,
      child: ListTile(
        key: key,
        onTap: onTap,
        minTileHeight: AppSize.rowMin,
        horizontalTitleGap: 12,
        contentPadding: EdgeInsets.only(left: nested ? 32 : 16, right: 16),
        leading: leading,
        // Целыми словами: на 320 px со шрифтом 200 % простой Text рвал
        // «Прикрепит|ь файл».
        title: WholeWordText(
          label,
          style: TextStyle(fontSize: 16, color: colors.textStrong),
        ),
        subtitle: detail == null
            ? null
            : WholeWordText(
                detail,
                style: TextStyle(fontSize: 14, color: colors.muted),
              ),
        trailing: trailing,
      ),
    );
  }
}
