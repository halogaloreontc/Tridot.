import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Системный запрос личности сейчас на экране (отпечаток, лицо, PIN-код
/// экрана). Пока он идёт, уход приложения в фон — это экран системы, а не
/// человек ушёл: сейф и вход в приложение не запираются от этого
/// (ADR-025). Когда запрос закончился, состояние приложения проверяется
/// снова — по-настоящему ушли в фон, значит, запираем.
abstract final class SystemAuthGuard {
  static final ValueNotifier<int> active = ValueNotifier<int>(0);

  static bool get busy => active.value > 0;

  static Future<T> run<T>(Future<T> Function() action) async {
    active.value++;
    try {
      return await action();
    } finally {
      active.value--;
    }
  }
}

/// Итог системной проверки личности.
enum DeviceAuthResult { ok, canceled, lockout, unavailable }

/// Что умеет устройство для входа в приложение.
@immutable
final class DeviceAuthStatus {
  const DeviceAuthStatus({
    this.supported = false,
    this.credential = false,
    this.biometric = false,
    this.fingerprint = false,
    this.face = false,
  });

  /// Система поддерживает запрос (Android 11+).
  final bool supported;

  /// Есть блокировка экрана (PIN-код, графический ключ, пароль).
  final bool credential;

  /// Настроена биометрия.
  final bool biometric;
  final bool fingerprint;
  final bool face;

  /// Переключатель «по отпечатку / Face ID» имеет смысл: без блокировки
  /// экрана запрашивать нечего.
  bool get available => supported && credential;

  /// Пояснение под переключателем: чем именно спросит система.
  String get means {
    final parts = <String>[
      if (biometric && fingerprint) 'отпечаток',
      if (biometric && face) 'лицо',
    ];
    if (parts.isEmpty) return 'PIN-код или пароль экрана';
    return '${parts.join(' или ')}, а если не выйдет — PIN-код или пароль '
        'экрана';
  }
}

/// Системная проверка личности для входа в приложение и подтверждений в
/// сейфе (ADR-025). Биометрические данные приложению не передаются:
/// система отвечает только «да» или «нет».
abstract interface class DeviceAuth {
  Future<DeviceAuthStatus> status();

  Future<DeviceAuthResult> authenticate(String reason);

  /// Запретить снимки экрана и показ в недавних (экраны ПИН-кода и кода
  /// восстановления). Где не умеет — ничего не делает.
  Future<void> secureWindow(bool on);

  /// Для текущей платформы: Android — системный BiometricPrompt; на
  /// компьютере пока нет (переключатели скрыты).
  static DeviceAuth get current =>
      Platform.isAndroid ? const ChannelDeviceAuth() : const NoDeviceAuth();
}

/// Нет системной проверки: компьютер и тесты.
final class NoDeviceAuth implements DeviceAuth {
  const NoDeviceAuth();

  @override
  Future<DeviceAuthStatus> status() async => const DeviceAuthStatus();

  @override
  Future<DeviceAuthResult> authenticate(String reason) async =>
      DeviceAuthResult.unavailable;

  @override
  Future<void> secureWindow(bool on) async {}
}

/// Android: каналы `tridot/auth` и `tridot/vault_key` (MainActivity).
final class ChannelDeviceAuth implements DeviceAuth {
  const ChannelDeviceAuth();

  static const MethodChannel _auth = MethodChannel('tridot/auth');
  static const MethodChannel _key = MethodChannel('tridot/vault_key');

  @override
  Future<DeviceAuthStatus> status() async {
    try {
      final raw = await _auth.invokeMapMethod<String, Object?>('status');
      if (raw == null) return const DeviceAuthStatus();
      final kinds = raw['kinds'];
      return DeviceAuthStatus(
        supported: raw['supported'] == true,
        credential: raw['credential'] == true,
        biometric: raw['biometric'] == true,
        fingerprint: kinds is List && kinds.contains('fingerprint'),
        face: kinds is List && kinds.contains('face'),
      );
    } on Object {
      return const DeviceAuthStatus();
    }
  }

  @override
  Future<DeviceAuthResult> authenticate(String reason) =>
      SystemAuthGuard.run(() async {
        try {
          final result = await _auth.invokeMethod<String>(
            'authenticate',
            <String, Object?>{'reason': reason},
          );
          return switch (result) {
            'ok' => DeviceAuthResult.ok,
            'lockout' => DeviceAuthResult.lockout,
            'canceled' => DeviceAuthResult.canceled,
            _ => DeviceAuthResult.unavailable,
          };
        } on Object {
          return DeviceAuthResult.unavailable;
        }
      });

  @override
  Future<void> secureWindow(bool on) async {
    try {
      await _key
          .invokeMethod<void>('secureWindow', <String, Object?>{'on': on});
    } on Object {
      // Нет канала — снимки экрана не запрещены (честно в ADR-025).
    }
  }
}
