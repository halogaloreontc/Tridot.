import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/passwords/secret_bytes.dart';
import '../../core/passwords/vault_codes.dart';
import '../assistant_theme.dart';
import '../security/device_auth.dart';
import '../widgets/whole_word_text.dart';

/// Набор ПИН-кода сейфа (ADR-025): кнопки 0–9 и «стереть», шесть точек.
///
/// Без текстового поля: нет клавиатуры системы, подсказок, автозаполнения
/// и вставки — ПИН-код не попадает ни в буфер, ни в словарь клавиатуры.
/// На компьютере цифры можно набирать с клавиатуры. Цифры живут в буфере,
/// который затирается сразу после отправки; наружу — только [SecretBytes]
/// (его затирает пульт, когда [onComplete] закончится). Экранная читалка
/// слышит «Введено 3 из 6», но не цифры. Раскладка постоянная: так проще
/// на ощупь и с читалкой.
class PinPad extends StatefulWidget {
  const PinPad({
    super.key,
    required this.onComplete,
    this.enabled = true,
    this.error,
    this.until,
    this.onPauseEnd,
    this.now = DateTime.now,
  });

  /// Набраны все 6 цифр. Байты затираются после завершения.
  final Future<void> Function(SecretBytes pin) onComplete;

  final bool enabled;

  /// Ошибка под точками (новая ошибка — точки вздрагивают).
  final String? error;

  /// Пауза после ошибок: до этого времени кнопки не нажимаются, под
  /// точками — отсчёт «через 0:28», он идёт каждую секунду. Кончилась —
  /// [onPauseEnd] (обычно убрать ошибку).
  final DateTime? until;

  final VoidCallback? onPauseEnd;

  /// Часы для паузы (тесты подставляют свои).
  final DateTime Function() now;

  /// Текст паузы до [until] от [now].
  static String pauseText(DateTime until, DateTime now) {
    final left = until.difference(now);
    final total = left.inSeconds + (left.inMilliseconds % 1000 > 0 ? 1 : 0);
    final minutes = total ~/ 60;
    final seconds = (total % 60).toString().padLeft(2, '0');
    return 'Слишком много ошибок. Следующая попытка через $minutes:$seconds.';
  }

  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad> with SingleTickerProviderStateMixin {
  final List<int> _digits = List<int>.filled(VaultPin.length, 0);
  int _count = 0;
  bool _sending = false;
  final FocusNode _focus = FocusNode(debugLabel: 'pin-pad');
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
  );

  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(PinPad old) {
    super.didUpdateWidget(old);
    if (widget.error != null && widget.error != old.error) {
      unawaited(_shake.forward(from: 0));
    }
    if (widget.until != old.until) _syncTicker();
  }

  bool get _paused {
    final until = widget.until;
    return until != null && widget.now().isBefore(until);
  }

  void _syncTicker() {
    _ticker?.cancel();
    _ticker = null;
    if (!_paused) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_paused) {
        setState(() {});
        return;
      }
      _ticker?.cancel();
      _ticker = null;
      setState(() {});
      widget.onPauseEnd?.call();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _clear();
    _focus.dispose();
    _shake.dispose();
    super.dispose();
  }

  void _clear() {
    _digits.fillRange(0, _digits.length, 0);
    _count = 0;
  }

  bool get _active => widget.enabled && !_sending && !_paused;

  void _add(int digit) {
    if (!_active || _count >= VaultPin.length) return;
    setState(() => _digits[_count++] = digit);
    if (_count == VaultPin.length) unawaited(_send());
  }

  void _back() {
    if (!_active || _count == 0) return;
    setState(() => _digits[--_count] = 0);
  }

  Future<void> _send() async {
    final pin = SecretBytes.copy(<int>[for (final d in _digits) 0x30 + d]);
    setState(() {
      _sending = true;
      _clear();
    });
    try {
      await widget.onComplete(pin);
    } finally {
      pin.wipe();
      if (mounted) setState(() => _sending = false);
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.backspace) {
      _back();
      return KeyEventResult.handled;
    }
    final digit = _digitOf(key);
    if (digit == null) return KeyEventResult.ignored;
    _add(digit);
    return KeyEventResult.handled;
  }

  static int? _digitOf(LogicalKeyboardKey key) {
    const top = <LogicalKeyboardKey>[
      LogicalKeyboardKey.digit0,
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
    ];
    const pad = <LogicalKeyboardKey>[
      LogicalKeyboardKey.numpad0,
      LogicalKeyboardKey.numpad1,
      LogicalKeyboardKey.numpad2,
      LogicalKeyboardKey.numpad3,
      LogicalKeyboardKey.numpad4,
      LogicalKeyboardKey.numpad5,
      LogicalKeyboardKey.numpad6,
      LogicalKeyboardKey.numpad7,
      LogicalKeyboardKey.numpad8,
      LogicalKeyboardKey.numpad9,
    ];
    final a = top.indexOf(key);
    if (a >= 0) return a;
    final b = pad.indexOf(key);
    return b >= 0 ? b : null;
  }

  /// Сторона кнопки: 64 на обычном экране, меньше на низком (320×640 с
  /// крупным шрифтом «0» и «стереть» иначе уходят за край), но не меньше
  /// 48 — палец должен попадать.
  static double keySize(BuildContext context) =>
      (MediaQuery.sizeOf(context).height * 0.085).clamp(48.0, 72.0);

  @override
  Widget build(BuildContext context) {
    final until = widget.until;
    final error = _paused && until != null
        ? PinPad.pauseText(until, widget.now())
        : widget.error;
    final size = keySize(context);
    final gap = size >= 60 ? 6.0 : 4.0;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _key,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AnimatedBuilder(
            animation: _shake,
            builder: (BuildContext context, Widget? child) =>
                Transform.translate(
              offset: Offset(
                math.sin(_shake.value * math.pi * 6) * 8 * (1 - _shake.value),
                0,
              ),
              child: child,
            ),
            child: Semantics(
              key: const ValueKey<String>('pin-dots'),
              label: 'Введено $_count из ${VaultPin.length}',
              liveRegion: true,
              excludeSemantics: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (var i = 0; i < VaultPin.length; i++)
                    Container(
                      width: 12,
                      height: 12,
                      margin: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i < _count
                            ? context.colors.textStrong
                            : Colors.transparent,
                        border: Border.all(
                          color: error != null
                              ? context.colors.danger
                              : context.colors.muted,
                          width: 1.5,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // Место под ошибкой не меньше 44: точки и кнопки не прыгают, а
          // длинная ошибка в две-три строки (крупный шрифт) растит место,
          // а не режется по высоте.
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Center(
                child: error == null
                    ? null
                    : WholeWordText(
                        error,
                        key: const ValueKey<String>('pin-error'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: context.colors.danger),
                      ),
              ),
            ),
          ),
          for (final row in const <List<int?>>[
            <int?>[1, 2, 3],
            <int?>[4, 5, 6],
            <int?>[7, 8, 9],
            <int?>[null, 0, -1],
          ])
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final cell in row)
                  Padding(
                    padding: EdgeInsets.all(gap),
                    child: cell == null
                        ? SizedBox(width: size, height: size)
                        : cell < 0
                            ? _Key(
                                key: const ValueKey<String>('pin-pad-back'),
                                size: size,
                                label: 'Стереть',
                                onTap: _active ? _back : null,
                                child: const Icon(Icons.backspace_outlined),
                              )
                            : _Key(
                                key: ValueKey<String>('pin-pad-$cell'),
                                size: size,
                                label: '$cell',
                                onTap: _active ? () => _add(cell) : null,
                                child: Text(
                                  '$cell',
                                  style: TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.w400,
                                    color: context.colors.textStrong,
                                  ),
                                ),
                              ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({
    super.key,
    required this.label,
    required this.onTap,
    required this.child,
    this.size = 64,
  });

  final double size;
  final String label;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      // Заливка контрастнее и фона сейфа, и листа диалога, без рамки
      // (ADR-027): иначе цифры висят без видимых кнопок.
      child: Material(
        color: onTap == null ? context.colors.raised : context.colors.bubble,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: MediaQuery.withNoTextScaling(child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// Пока виден, снимки экрана и показ в «недавних» запрещены (Android,
/// FLAG_SECURE). Вложенные области считаются: запрет снимается, когда
/// уходит последняя.
class SecureWindowScope extends StatefulWidget {
  const SecureWindowScope({super.key, required this.auth, required this.child});

  final DeviceAuth auth;
  final Widget child;

  static int _depth = 0;

  @override
  State<SecureWindowScope> createState() => _SecureWindowScopeState();
}

class _SecureWindowScopeState extends State<SecureWindowScope> {
  @override
  void initState() {
    super.initState();
    if (SecureWindowScope._depth++ == 0) {
      unawaited(widget.auth.secureWindow(true));
    }
  }

  @override
  void dispose() {
    if (--SecureWindowScope._depth == 0) {
      unawaited(widget.auth.secureWindow(false));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
