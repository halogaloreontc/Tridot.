import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/settings/app_settings.dart';
import '../widgets/grouped.dart';
import 'app_lock.dart';
import 'device_auth.dart';

/// «Настройки → Защита» (ADR-025): вход в приложение по отпечатку / Face ID
/// и через сколько снова спрашивать. Переключатель виден, только если на
/// устройстве есть блокировка экрана (иначе спрашивать нечего). ПИН-код
/// сейфа и вход в сейф по отпечатку — в настройках самого сейфа.
class SecuritySection extends StatefulWidget {
  const SecuritySection({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.lock,
    this.hasVault = false,
  });

  final AppSettings settings;
  final ValueChanged<AppSettings> onChanged;
  final AppLockController lock;

  /// Есть навык «Пароли»: подсказка про настройки сейфа.
  final bool hasVault;

  @override
  State<SecuritySection> createState() => _SecuritySectionState();
}

class _SecuritySectionState extends State<SecuritySection> {
  DeviceAuthStatus? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_probe());
  }

  Future<void> _probe() async {
    final status = await widget.lock.auth.status();
    if (mounted) setState(() => _status = status);
  }

  /// Включение — только после удачного системного запроса: иначе можно
  /// запереть себя на устройстве, где проверка не работает.
  Future<void> _toggle(bool on) async {
    if (_busy) return;
    if (!on) {
      widget.onChanged(widget.settings.copyWith(appLock: false));
      return;
    }
    setState(() => _busy = true);
    try {
      final result =
          await widget.lock.auth.authenticate('Включить вход по отпечатку');
      if (!mounted) return;
      if (result == DeviceAuthResult.ok) {
        widget.onChanged(widget.settings.copyWith(appLock: true));
      } else if (result != DeviceAuthResult.canceled) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Проверка не прошла — не включено.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final available = status?.available ?? false;
    final settings = widget.settings;
    if (!available && !widget.hasVault) return const SizedBox.shrink();
    String after(int seconds) => switch (seconds) {
          0 => 'Сразу',
          60 => 'Через 1 мин',
          _ => 'Через ${seconds ~/ 60} мин',
        };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InsetGroup(
          header: 'Защита',
          footer: widget.hasVault
              ? 'ПИН-код сейфа и вход в сейф по отпечатку / Face ID — в '
                  '«Сейф → Настройки → Вход в сейф».'
              : null,
          children: <Widget>[
            if (available)
              GroupedSwitchRow(
                key: const ValueKey<String>('setting-app-lock'),
                title: 'Вход в приложение по отпечатку / Face ID',
                subtitle: 'Спросит ${status!.means}. Это замок экрана, а не '
                    'шифрование: напоминания приходят как прежде.',
                value: settings.appLock,
                onChanged: _busy ? null : (bool v) => unawaited(_toggle(v)),
              ),
          ],
        ),
        if (available && settings.appLock)
          GroupedChoiceList<int>(
            header: 'Снова спрашивать',
            options: AppSettings.appLockAfterChoices,
            selected: settings.appLockAfter,
            label: after,
            optionKey: (int s) => ValueKey<String>('setting-app-lock-after-$s'),
            onSelected: (int seconds) => widget.onChanged(
              settings.copyWith(appLockAfter: seconds),
            ),
          ),
      ],
    );
  }
}
