import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../assistant_theme.dart';

enum AssistantViewMode { dialogue, document }

/// Шаблон команды из меню «+». `|` в [template] — место курсора.
final class CommandTemplate {
  const CommandTemplate(this.label, this.template, {this.icon = Icons.bolt});

  final String label;
  final String template;
  final IconData icon;
}

/// Источники документов для «+». Подключение дисков — следующий этап;
/// пункты видны заранее, а нажатие честно сообщает, что это в разработке.
enum DocumentSource {
  googleDrive('Google Диск', Icons.add_to_drive),
  yandexDisk('Яндекс Диск', Icons.cloud_outlined);

  const DocumentSource(this.label, this.icon);

  final String label;
  final IconData icon;
}

const List<CommandTemplate> defaultTemplates = <CommandTemplate>[
  CommandTemplate('Новая задача', 'Добавь задачу «|»', icon: Icons.add),
  CommandTemplate(
    'Задача на завтра в 10:00',
    'Добавь задачу «|» на завтра в 10:00',
    icon: Icons.event_outlined,
  ),
  CommandTemplate(
    'Задача в проект',
    'Добавь задачу «|» #проект',
    icon: Icons.tag,
  ),
  CommandTemplate(
    'Перенести выбранную',
    'Перенеси её на завтра в |',
    icon: Icons.update,
  ),
  CommandTemplate('Показать задачи', 'Покажи задачи', icon: Icons.checklist),
];

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
    required this.onTemplate,
    required this.onDocumentSource,
    required this.onVoice,
    required this.previousCommand,
    required this.nextCommand,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sending;
  final AssistantViewMode mode;
  final ValueChanged<AssistantViewMode> onModeChanged;
  final VoidCallback onSend;
  final ValueChanged<CommandTemplate> onTemplate;

  /// Выбран источник документа в меню «+».
  final ValueChanged<DocumentSource> onDocumentSource;

  /// Микрофон при пустом поле: голосовое общение с помощником.
  final VoidCallback onVoice;

  /// Прошлая и следующая команда из истории для ↑/↓; null — нет.
  final String? Function() previousCommand;
  final String? Function() nextCommand;

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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, _) {
        final hasText = widget.controller.text.trim().isNotEmpty;
        // Пустое поле — микрофон для голоса, с текстом — кнопка отправки.
        final voice = !hasText && !widget.sending;
        return Container(
          key: const Key('assistant-composer'),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: const Color(0xFF272B28),
            border: Border.all(color: AssistantColors.border),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                key: const Key('assistant-input'),
                controller: widget.controller,
                focusNode: widget.focusNode,
                minLines: 1,
                maxLines: 6,
                textInputAction: TextInputAction.send,
                textCapitalization: TextCapitalization.sentences,
                onSubmitted: (_) {
                  if (!widget.sending) widget.onSend();
                },
                decoration: const InputDecoration(
                  hintText: 'Напишите команду…',
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.fromLTRB(8, 6, 8, 12),
                  isDense: true,
                ),
              ),
              LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final plus = PopupMenuButton<Object>(
                    key: const Key('templates-button'),
                    tooltip: 'Документы и шаблоны команд',
                    onSelected: (Object value) {
                      if (value is CommandTemplate) widget.onTemplate(value);
                      if (value is DocumentSource) {
                        widget.onDocumentSource(value);
                      }
                    },
                    color: AssistantColors.raised,
                    itemBuilder: (BuildContext context) =>
                        <PopupMenuEntry<Object>>[
                      const PopupMenuItem<Object>(
                        enabled: false,
                        height: 28,
                        child:
                            Text('Документ с диска', style: technicalTextStyle),
                      ),
                      for (final source in DocumentSource.values)
                        PopupMenuItem<Object>(
                          key: Key('source-${source.name}'),
                          value: source,
                          child: Row(
                            children: <Widget>[
                              Icon(source.icon, size: 18),
                              const SizedBox(width: 10),
                              Flexible(child: Text(source.label)),
                              const SizedBox(width: 8),
                              const Text('скоро', style: technicalTextStyle),
                            ],
                          ),
                        ),
                      const PopupMenuDivider(),
                      const PopupMenuItem<Object>(
                        enabled: false,
                        height: 28,
                        child:
                            Text('Шаблоны команд', style: technicalTextStyle),
                      ),
                      for (final template in defaultTemplates)
                        PopupMenuItem<Object>(
                          value: template,
                          child: Row(
                            children: <Widget>[
                              Icon(template.icon, size: 18),
                              const SizedBox(width: 10),
                              Flexible(child: Text(template.label)),
                            ],
                          ),
                        ),
                    ],
                    child: const _RoundIcon(icon: Icons.add),
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
                      fixedSize: const Size(40, 40),
                      backgroundColor: const Color(0xFFC4C9C5),
                      foregroundColor: const Color(0xFF171917),
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
                  final modes = _ModeSwitch(
                    mode: widget.mode,
                    onChanged: widget.onModeChanged,
                  );
                  // Переключатель не сжимается: если места мало (узкий
                  // экран, крупный шрифт), он встаёт отдельной строкой.
                  final scale = MediaQuery.textScalerOf(context).scale(1);
                  final needed = 112 + 200 * scale;
                  if (constraints.maxWidth >= needed) {
                    return Row(
                      children: <Widget>[
                        plus,
                        Expanded(child: Center(child: modes)),
                        send,
                      ],
                    );
                  }
                  return Column(
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: _ModeSwitch(
                          mode: widget.mode,
                          onChanged: widget.onModeChanged,
                          stretch: true,
                        ),
                      ),
                      Row(
                        children: <Widget>[plus, const Spacer(), send],
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
      width: 40,
      height: 40,
      decoration: const BoxDecoration(
        color: Colors.black,
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 20, color: AssistantColors.textStrong),
    );
  }
}

final class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({
    required this.mode,
    required this.onChanged,
    this.stretch = false,
  });

  final AssistantViewMode mode;
  final ValueChanged<AssistantViewMode> onChanged;

  /// На всю ширину строки: сегменты делят её поровну, подписи обрезаются.
  final bool stretch;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: stretch ? MainAxisSize.max : MainAxisSize.min,
        children: <Widget>[
          for (final (label, value, key)
              in <(String, AssistantViewMode, String)>[
            ('Диалог', AssistantViewMode.dialogue, 'mode-dialogue'),
            ('Документ', AssistantViewMode.document, 'mode-document'),
          ])
            stretch
                ? Expanded(child: _button(label, value, key))
                : _button(label, value, key),
        ],
      ),
    );
  }

  Widget _button(String label, AssistantViewMode value, String key) {
    final active = mode == value;
    return Semantics(
      button: true,
      selected: active,
      child: InkWell(
        key: Key(key),
        onTap: () => onChanged(value),
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          constraints: const BoxConstraints(minHeight: 40),
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(horizontal: stretch ? 6 : 14),
          decoration: BoxDecoration(
            color: active ? AssistantColors.textStrong : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: active ? const Color(0xFF171917) : AssistantColors.muted,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }
}
