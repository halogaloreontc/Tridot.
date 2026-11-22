import 'package:flutter/material.dart';

import '../app/assistant_theme.dart';
import '../core/models/clarification.dart';

/// Кнопки вопроса помощника под сообщением — как в ленте приложения: «Да»
/// и «Нет» подсказки модели (ADR-045), варианты уточнения. Главный ответ
/// (`answer: true`) — залитая кнопка, остальные — контурные. Нажатие
/// отправляет подпись варианта обычным сообщением.
final class WidgetClarifyButtons extends StatelessWidget {
  const WidgetClarifyButtons({
    super.key,
    required this.clarification,
    required this.onChoose,
    this.enabled = true,
  });

  final Clarification clarification;
  final ValueChanged<ClarifyOption> onChoose;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    Widget button(int index, ClarifyOption option) {
      final key = ValueKey<String>('clarify-option-$index');
      final onPressed = enabled ? () => onChoose(option) : null;
      final child = Text(option.label, textAlign: TextAlign.center);
      if (option.answer ?? false) {
        return FilledButton(
          key: key,
          style: FilledButton.styleFrom(minimumSize: const Size(40, 44)),
          onPressed: onPressed,
          child: child,
        );
      }
      return OutlinedButton(
        key: key,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(40, 44),
          foregroundColor: context.colors.textStrong,
        ),
        onPressed: onPressed,
        child: child,
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (final (index, option) in clarification.options.indexed)
            button(index, option),
        ],
      ),
    );
  }
}
