import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/chats/attachments.dart';
import '../../core/cloud/cloud_disk.dart';
import '../../core/commands/command_catalog.dart';
import '../assistant_theme.dart';
import '../attachments/attachment_picker.dart';
import '../attachments/attachment_views.dart';
import 'command_finder_sheet.dart';

enum AssistantViewMode { dialogue, document }

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

/// Поле команды. Не блокируется во время отправки, чтобы не терять фокус:
/// повторную отправку отсекает хозяин.
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
    required this.onVoice,
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

  /// Микрофон при пустом поле: голосовое общение с помощником.
  final VoidCallback onVoice;

  /// Прошлая и следующая команда из истории для ↑/↓; null — нет.
  final String? Function() previousCommand;
  final String? Function() nextCommand;

  /// Строка над полем: выбор адресата в дуэте помощников.
  final Widget? header;

  @override
  State<CommandComposer> createState() => _CommandComposerState();
}

final class _CommandComposerState extends State<CommandComposer> {
  @override
  void initState() {
    super.initState();
    widget.focusNode.onKeyEvent = _onKey;
  }

  @override
  void didUpdateWidget(covariant CommandComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      widget.focusNode.onKeyEvent = _onKey;
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (shift) {
        _insert('\n');
      } else if (!widget.sending) {
        widget.onSend();
      }
      return KeyEventResult.handled;
    }
    final text = widget.controller.text;
    final singleLine = !text.contains('\n');
    if (key == LogicalKeyboardKey.arrowUp && singleLine) {
      return _recall(widget.previousCommand());
    }
    if (key == LogicalKeyboardKey.arrowDown && singleLine) {
      return _recall(widget.nextCommand());
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _recall(String? command) {
    if (command == null) return KeyEventResult.ignored;
    widget.controller.value = TextEditingValue(
      text: command,
      selection: TextSelection.collapsed(offset: command.length),
    );
    return KeyEventResult.handled;
  }

  void _insert(String text) {
    final value = widget.controller.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final updated =
        value.text.replaceRange(selection.start, selection.end, text);
    widget.controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: selection.start + text.length),
    );
  }

  /// «+»: три пункта со своими списками — «Облачный диск», «Прикрепить
  /// файл», «Шаблоны команд» (действия сейфа — там же, в «Найти
  /// команду»). Выбор
  /// выполняется после закрытия листа: выбор файлов и диалоги открываются
  /// уже над экраном.
  Future<void> _openPlus() async {
    final choice = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AssistantColors.raised,
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
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, _) {
        // Файлы можно отправить и без текста.
        final hasText = widget.controller.text.trim().isNotEmpty ||
            widget.pending.isNotEmpty;
        // Пустое поле — микрофон для голоса, с текстом — кнопка отправки.
        final voice = !hasText && !widget.sending;
        return Container(
          key: const Key('assistant-composer'),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AssistantColors.raised,
            border: Border.all(color: AssistantColors.border),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (widget.header case final Widget header)
                Align(alignment: Alignment.centerLeft, child: header),
              if (widget.pending.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        for (var i = 0; i < widget.pending.length; i++)
                          AttachmentChip(
                            key: Key('pending-attachment-$i'),
                            name: widget.pending[i].name,
                            kind: widget.pending[i].kind,
                            size: widget.pending[i].size,
                            onRemove: widget.onRemovePending == null
                                ? null
                                : () => widget.onRemovePending!(i),
                          ),
                      ],
                    ),
                  ),
                ),
              TextField(
                key: const Key('assistant-input'),
                controller: widget.controller,
                focusNode: widget.focusNode,
                // Две строки, как в макете «Д»: высота поля не прыгает,
                // когда текст переносится на вторую строку.
                minLines: 2,
                maxLines: 6,
                textInputAction: TextInputAction.send,
                textCapitalization: TextCapitalization.sentences,
                onSubmitted: (_) {
                  if (!widget.sending) widget.onSend();
                },
                style: const TextStyle(
                  fontSize: 16,
                  color: AssistantColors.textStrong,
                ),
                decoration: const InputDecoration(
                  hintText: 'Спросить, найти или поручить…',
                  hintMaxLines: 1,
                  hintStyle: TextStyle(color: AssistantColors.muted),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.fromLTRB(6, 4, 6, 8),
                  isDense: true,
                ),
              ),
              LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final plus = Tooltip(
                    message: 'Файлы, диски и шаблоны команд',
                    child: InkResponse(
                      key: const Key('templates-button'),
                      onTap: _openPlus,
                      radius: 24,
                      child: const _RoundIcon(icon: Icons.add),
                    ),
                  );
                  final send = IconButton(
                    key: const Key('assistant-send'),
                    onPressed: widget.sending
                        ? null
                        : voice
                            ? widget.onVoice
                            : widget.onSend,
                    tooltip: voice ? 'Голосовой режим' : 'Отправить',
                    style: IconButton.styleFrom(
                      fixedSize: const Size(44, 44),
                      backgroundColor: AssistantColors.primary,
                      foregroundColor: AssistantColors.onPrimary,
                      disabledBackgroundColor: AssistantColors.raised,
                      disabledForegroundColor: AssistantColors.muted,
                    ),
                    icon: widget.sending
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            voice ? Icons.mic_none : Icons.arrow_upward,
                            size: 20,
                          ),
                  );
                  // Две строки: сверху ввод, снизу «+», переключатель режимов
                  // ровно посередине и микрофон или отправка. На широком поле
                  // у иконок режимов есть подписи, на узком — только иконки.
                  // Подписи — если помещаются целиком: «+» и микрофон по
                  // 44, капсула (отступ 2 и рамка 1 с каждой стороны), у
                  // каждой половины поля 24, иконка 17, зазор 6 и подпись по
                  // её реальной ширине. На телефоне 390 — с подписями
                  // (D-Phone), на 320 и при крупном шрифте — только иконки.
                  final labels = constraints.maxWidth >=
                      2 * 44 +
                          6 +
                          2 * (24 + 17 + 6) +
                          _ModeSwitch.labelsWidth(context);
                  return Row(
                    children: <Widget>[
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: plus,
                        ),
                      ),
                      _ModeSwitch(
                        mode: widget.mode,
                        onChanged: widget.onModeChanged,
                        labels: labels,
                      ),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: send,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

final class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: AssistantColors.border),
      ),
      child: Icon(icon, size: 20, color: AssistantColors.textStrong),
    );
  }
}

/// Компактный переключатель «Диалог / Документ»: капсула из двух иконок,
/// на широком поле — с подписями справа от иконок.
final class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({
    required this.mode,
    required this.onChanged,
    required this.labels,
  });

  final AssistantViewMode mode;
  final ValueChanged<AssistantViewMode> onChanged;
  final bool labels;

  /// Ширина обеих подписей при текущем шрифте и его масштабе.
  static double labelsWidth(BuildContext context) {
    var total = 0.0;
    for (final label in const <String>['Диалог', 'Документ']) {
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: DefaultTextStyle.of(context).style.merge(
                const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              ),
        ),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      total += painter.width;
      painter.dispose();
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: AssistantColors.panel,
        border: Border.all(color: AssistantColors.borderSoft),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _button(
            'Диалог',
            Icons.chat_bubble_outline,
            AssistantViewMode.dialogue,
            'mode-dialogue',
          ),
          _button(
            'Документ',
            Icons.edit_document,
            AssistantViewMode.document,
            'mode-document',
          ),
        ],
      ),
    );
  }

  Widget _button(
    String label,
    IconData icon,
    AssistantViewMode value,
    String key,
  ) {
    final active = mode == value;
    final color = active ? AssistantColors.textStrong : AssistantColors.muted;
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        selected: active,
        label: 'Режим: $label',
        onTap: () => onChanged(value),
        excludeSemantics: true,
        child: InkWell(
          key: Key(key),
          onTap: () => onChanged(value),
          borderRadius: BorderRadius.circular(999),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
            alignment: Alignment.center,
            padding: EdgeInsets.symmetric(horizontal: labels ? 12 : 8),
            decoration: BoxDecoration(
              color: active ? AssistantColors.bubble : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(icon, size: 17, color: color),
                if (labels) ...<Widget>[
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      color: color,
                      fontSize: 13,
                      fontWeight: active ? FontWeight.w500 : FontWeight.w400,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
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
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // Один подключённый диск — пункт сразу открывает его, без
            // выбора диска.
            if (cloud case CloudDiskSingle(:final disk))
              _row(
                key: const Key('composer-cloud'),
                icon: Icons.cloud_outlined,
                label: 'Облачный диск',
                detail: disk.label,
                onTap: () => _pick(disk),
              )
            else
              ..._group(
                group: _PlusGroup.cloud,
                key: const Key('composer-cloud'),
                icon: Icons.cloud_outlined,
                label: 'Облачный диск',
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

  List<Widget> _group({
    required _PlusGroup group,
    required Key key,
    required IconData icon,
    required String label,
    required List<Widget> children,
  }) {
    final open = _open == group;
    return <Widget>[
      _row(
        key: key,
        icon: icon,
        label: label,
        trailing: Icon(
          open ? Icons.expand_less : Icons.expand_more,
          color: AssistantColors.icon,
        ),
        expanded: open,
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
  }) {
    return Semantics(
      expanded: expanded,
      child: ListTile(
        key: key,
        onTap: onTap,
        minTileHeight: 48,
        contentPadding: EdgeInsets.only(left: nested ? 56 : 20, right: 16),
        leading: Icon(icon, size: 20, color: AssistantColors.textStrong),
        title: Text(
          label,
          style: const TextStyle(
            fontSize: 15,
            color: AssistantColors.textStrong,
          ),
        ),
        subtitle: detail == null ? null : Text(detail, style: metaTextStyle),
        trailing: trailing,
      ),
    );
  }
}
