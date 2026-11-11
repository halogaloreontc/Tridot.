import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../core/extensions/extension_registry.dart';
import '../../core/passwords/vault.dart';
import 'clipboard_guard.dart';

/// Когда запирать хранилище (раздел 3.6): выключили навык, приложение
/// ушло в фон или спряталось, окно закрывают. На компьютере потеря
/// фокуса (`inactive`) только прячет показанное. При каждом запирании
/// очищается буфер, если там наш пароль.
final class VaultLifecycle {
  VaultLifecycle({required this.vault, required this.clipboard}) {
    vault.addListener(_onSignal);
  }

  /// Id навыка в «Расширениях».
  static const String skillId = 'passwords';

  final Vault vault;
  final ClipboardGuard clipboard;

  void Function()? _unfollow;

  /// Следить за навыком в [registry]: выключили — запереть (D18).
  void follow(ExtensionRegistry registry) {
    _unfollow?.call();
    _unfollow = vault.followExtension(registry, skillId);
  }

  void onAppState(AppLifecycleState state) => vault.onAppState(
        switch (state) {
          AppLifecycleState.resumed => VaultAppState.resumed,
          AppLifecycleState.inactive => VaultAppState.inactive,
          AppLifecycleState.hidden => VaultAppState.hidden,
          AppLifecycleState.paused => VaultAppState.paused,
          AppLifecycleState.detached => VaultAppState.detached,
        },
      );

  /// Окно закрывают: запереть и очистить буфер до выхода.
  Future<void> onExit() async {
    vault.lock();
    await clipboard.clearIfOurs();
  }

  void _onSignal(VaultSignal signal) {
    if (signal == VaultSignal.locked) unawaited(clipboard.clearIfOurs());
  }

  void dispose() {
    _unfollow?.call();
    _unfollow = null;
    vault.removeListener(_onSignal);
  }
}
