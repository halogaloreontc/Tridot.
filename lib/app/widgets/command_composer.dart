import 'package:flutter/material.dart';

enum AssistantViewMode { dialogue, document }

final class CommandComposer extends StatelessWidget {
  const CommandComposer({
    super.key,
    required this.controller,
    required this.sending,
    required this.mode,
    required this.onModeChanged,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final AssistantViewMode mode;
  final ValueChanged<AssistantViewMode> onModeChanged;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final hasText = controller.text.trim().isNotEmpty;
        return Container(
          key: const Key('assistant-composer'),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: const Color(0xFF272B28),
            border: Border.all(color: const Color(0xFF3A403A)),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                key: const Key('assistant-input'),
                controller: controller,
                enabled: !sending,
                minLines: 1,
                maxLines: 6,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) {
                  if (!sending) onSend();
                },
                decoration: const InputDecoration(
                  hintText: 'Напишите команду…',
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.fromLTRB(8, 6, 8, 12),
                  isDense: true,
                ),
              ),
              Row(
                children: <Widget>[
                  _RoundButton(
                    key: const Key('attachment-button'),
                    tooltip: 'Вложения пока не реализованы',
                    onPressed: null,
                    child: const Icon(Icons.add),
                  ),
                  const Spacer(),
                  _ModeSwitch(mode: mode, onChanged: onModeChanged),
                  const Spacer(),
                  _RoundButton(
                    key: const Key('assistant-send'),
                    tooltip: hasText
                        ? 'Отправить'
                        : 'Голосовой ввод пока не реализован',
                    onPressed: hasText && !sending ? onSend : null,
                    light: true,
                    child: Icon(hasText ? Icons.arrow_upward : Icons.mic_none),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

final class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.mode, required this.onChanged});

  final AssistantViewMode mode;
  final ValueChanged<AssistantViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _button('Диалог', AssistantViewMode.dialogue, 'mode-dialogue'),
          _button('Документ', AssistantViewMode.document, 'mode-document'),
        ],
      ),
    );
  }

  Widget _button(String label, AssistantViewMode value, String key) {
    final active = mode == value;
    return InkWell(
      key: Key(key),
      onTap: () => onChanged(value),
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: active ? const Color(0xFFE5E7E6) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? const Color(0xFF171917) : const Color(0xFF858C87),
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

final class _RoundButton extends StatelessWidget {
  const _RoundButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.child,
    this.light = false,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final Widget child;
  final bool light;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      style: IconButton.styleFrom(
        fixedSize: const Size(32, 32),
        minimumSize: const Size(32, 32),
        maximumSize: const Size(32, 32),
        padding: EdgeInsets.zero,
        backgroundColor: light ? const Color(0xFFC4C9C5) : Colors.black,
        foregroundColor: light ? const Color(0xFF171917) : Colors.white,
        disabledBackgroundColor: light ? const Color(0xFFC4C9C5) : Colors.black,
      ),
      icon: child,
    );
  }
}
