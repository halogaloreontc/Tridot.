import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../assistant_theme.dart';
import '../layout.dart';

/// Кнопка «Копировать» под сообщением: весь текст в буфер обмена одним
/// нажатием, без выделения. После нажатия на полторы секунды — галочка и
/// подпись «Скопировано» (для диктора — объявление).
final class MessageCopyButton extends StatefulWidget {
  const MessageCopyButton({super.key, required this.text});

  final String text;

  /// Сколько держится галочка после копирования.
  static const Duration doneFor = Duration(milliseconds: 1500);

  @override
  State<MessageCopyButton> createState() => _MessageCopyButtonState();
}

final class _MessageCopyButtonState extends State<MessageCopyButton> {
  bool _done = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    SemanticsService.sendAnnouncement(
      View.of(context),
      'Скопировано',
      Directionality.of(context),
    );
    setState(() => _done = true);
    _timer?.cancel();
    _timer = Timer(MessageCopyButton.doneFor, () {
      if (mounted) setState(() => _done = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      button: true,
      label: _done ? 'Скопировано' : 'Копировать сообщение',
      // Для диктора — своё действие «нажать»: внутренняя кнопка скрыта.
      onTap: () => unawaited(_copy()),
      excludeSemantics: true,
      child: Tooltip(
        message: _done ? 'Скопировано' : 'Копировать',
        child: InkResponse(
          key: const ValueKey<String>('message-copy'),
          onTap: () => unawaited(_copy()),
          radius: 20,
          // Цель нажатия — 48 в ширину (ADR-027) и 40 в высоту: строка под
          // ответом не выше, чем нужно пальцу; значок — тихий, 18.
          child: SizedBox(
            width: AppSize.minTap,
            height: 40,
            child: Icon(
              _done ? Icons.check_rounded : Icons.copy_rounded,
              size: 18,
              color: _done ? colors.success : colors.muted,
            ),
          ),
        ),
      ),
    );
  }
}

/// Кнопка копирования под пузырём своего сообщения: на компьютере — при
/// наведении (место под неё держится, лента не прыгает), на телефоне её
/// нет — там текст выделяется долгим нажатием.
final class HoverCopy extends StatefulWidget {
  const HoverCopy({super.key, required this.text, required this.child});

  final String text;
  final Widget child;

  @override
  State<HoverCopy> createState() => _HoverCopyState();
}

final class _HoverCopyState extends State<HoverCopy> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final desktop = switch (Theme.of(context).platform) {
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux =>
        true,
      _ => false,
    };
    if (!desktop) return widget.child;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          widget.child,
          Visibility(
            visible: _hover,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: MessageCopyButton(text: widget.text),
          ),
        ],
      ),
    );
  }
}
