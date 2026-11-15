import 'dart:async';

import 'package:flutter/material.dart';

import '../assistant_theme.dart';
import '../widgets/whole_word_text.dart';
import 'device_auth.dart';

/// Вход в приложение по отпечатку / Face ID (ADR-025), по желанию.
///
/// Включён — приложение закрыто при запуске и после возврата из фона, если
/// там пробыли дольше [after]. Открывает только системный запрос
/// (биометрия, а если не вышло — PIN-код или пароль экрана). Это проверка в
/// интерфейсе, а не шифрование: история, задачи и файлы на диске те же, а
/// напоминания приходят как прежде. Сейф защищён отдельно (своим ключом).
final class AppLockController extends ChangeNotifier {
  AppLockController({
    required this.auth,
    bool enabled = false,
    Duration after = defaultAfter,
    Stopwatch? stopwatch,
  })  : _enabled = enabled,
        _after = after,
        _locked = enabled,
        _watch = stopwatch ?? (Stopwatch()..start()) {
    SystemAuthGuard.active.addListener(_onSystemAuth);
  }

  final DeviceAuth auth;
  final Stopwatch _watch;

  /// Варианты «запрашивать после фона» (секунды).
  static const List<int> afterChoices = <int>[0, 60, 300];
  static const Duration defaultAfter = Duration(seconds: 60);

  bool _enabled;
  Duration _after;
  bool _locked;
  Duration? _backgroundAt;
  bool _busy = false;
  AppLifecycleState? _pending;

  /// Сообщение на экране замка (почему не открылось).
  String? message;

  /// Замок выключился сам (пропала блокировка экрана): сохранить это в
  /// настройках.
  VoidCallback? onDisabled;

  bool get enabled => _enabled;
  Duration get after => _after;
  bool get locked => _enabled && _locked;
  bool get busy => _busy;

  /// Настройки поменялись (или загрузились).
  void configure({required bool enabled, required Duration after}) {
    final turnedOn = enabled && !_enabled;
    _enabled = enabled;
    _after = after;
    // Только что включили сами — уже проверили, не запираем.
    if (!enabled || turnedOn) _locked = false;
    notifyListeners();
  }

  /// Состояние приложения: ушли в фон — запомнить когда; вернулись позже
  /// [after] — закрыть. Пока на экране системный запрос личности, это не
  /// «ушли в фон».
  void onAppState(AppLifecycleState state) {
    if (SystemAuthGuard.busy) {
      _pending = state;
      return;
    }
    switch (state) {
      case AppLifecycleState.paused ||
            AppLifecycleState.hidden ||
            AppLifecycleState.detached:
        _backgroundAt ??= _watch.elapsed;
      case AppLifecycleState.resumed:
        final at = _backgroundAt;
        _backgroundAt = null;
        if (_enabled && at != null && _watch.elapsed - at >= _after) {
          _locked = true;
          message = null;
          notifyListeners();
        }
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _onSystemAuth() {
    if (SystemAuthGuard.busy) return;
    final state = _pending;
    _pending = null;
    if (state != null && state != AppLifecycleState.resumed) {
      onAppState(state);
    }
  }

  /// Системный запрос личности. Блокировку экрана убрали — замок
  /// выключается сам (иначе человек остался бы заперт), [onDisabled]
  /// сохраняет это в настройках.
  Future<void> unlock({VoidCallback? onDisabled}) async {
    if (_busy || !locked) return;
    _busy = true;
    message = null;
    notifyListeners();
    try {
      final status = await auth.status();
      if (!status.available) {
        _enabled = false;
        _locked = false;
        onDisabled?.call();
        return;
      }
      final result = await auth.authenticate('Вход в Tridot');
      switch (result) {
        case DeviceAuthResult.ok:
          _locked = false;
        case DeviceAuthResult.lockout:
          message = 'Слишком много попыток. Подождите и попробуйте снова.';
        case DeviceAuthResult.canceled:
          message = null;
        case DeviceAuthResult.unavailable:
          message = 'Проверка сейчас недоступна. Попробуйте ещё раз.';
      }
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    SystemAuthGuard.active.removeListener(_onSystemAuth);
    super.dispose();
  }
}

/// Замок поверх всего приложения (над навигатором `MaterialApp`). Пока
/// заперто, содержимое не рисуется, не принимает касаний и не читается
/// экранной читалкой; его состояние (черновик, открытая сессия) остаётся.
class AppLockGate extends StatefulWidget {
  const AppLockGate({
    super.key,
    required this.controller,
    required this.child,
    this.onDisabled,
  });

  final AppLockController controller;
  final Widget child;

  /// Замок выключился сам (пропала блокировка экрана).
  final VoidCallback? onDisabled;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  bool _asked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_changed);
    _askSoon();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.controller.onAppState(state);
  }

  void _changed() {
    if (!mounted) return;
    if (!widget.controller.locked) _asked = false;
    setState(() {});
    _askSoon();
  }

  /// Заперли — системный запрос сразу, один раз; дальше — по кнопке.
  void _askSoon() {
    if (!widget.controller.locked || _asked) return;
    _asked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_unlock());
    });
  }

  Future<void> _unlock() => widget.controller.unlock(
        onDisabled: widget.onDisabled ?? widget.controller.onDisabled,
      );

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final locked = controller.locked;
    return Stack(
      children: <Widget>[
        Offstage(
          offstage: locked,
          child: TickerMode(
            enabled: !locked,
            child: ExcludeSemantics(excluding: locked, child: widget.child),
          ),
        ),
        if (locked)
          Positioned.fill(
            child: _LockScreen(
              busy: controller.busy,
              message: controller.message,
              onUnlock: () => unawaited(_unlock()),
            ),
          ),
      ],
    );
  }
}

class _LockScreen extends StatelessWidget {
  const _LockScreen({
    required this.busy,
    required this.message,
    required this.onUnlock,
  });

  final bool busy;
  final String? message;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey<String>('app-lock'),
      color: context.colors.workspace,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    Icons.fingerprint,
                    size: 48,
                    color: context.colors.muted,
                  ),
                  const SizedBox(height: 16),
                  WholeWordText(
                    'Tridot закрыт',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 18,
                      color: context.colors.textStrong,
                    ),
                  ),
                  const SizedBox(height: 8),
                  WholeWordText(
                    'Откройте так же, как разблокируете устройство.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.colors.muted),
                  ),
                  if (message != null) ...<Widget>[
                    const SizedBox(height: 12),
                    WholeWordText(
                      message!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.colors.warning),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    key: const ValueKey<String>('app-lock-open'),
                    onPressed: busy ? null : onUnlock,
                    icon: const Icon(Icons.lock_open_outlined, size: 18),
                    label: const Text('Открыть'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
