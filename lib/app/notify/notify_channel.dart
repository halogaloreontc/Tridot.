import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/notify/reminder_plan.dart';
import '../../core/skills/alarm/alarm_connector.dart';

/// Разрешение показывать уведомления (ADR-029).
enum NotifyPermission {
  /// Разрешено.
  granted,

  /// Отказано, но системный вопрос ещё можно задать (Android 13+).
  denied,

  /// Выключено так, что вернуть можно только в настройках системы.
  permanentlyDenied,

  /// Ещё не спрашивали.
  notAsked,

  /// На этом устройстве системных уведомлений нет (Windows, Linux).
  unsupported;

  static NotifyPermission parse(Object? value) =>
      NotifyPermission.values.firstWhere(
        (NotifyPermission p) => p.name == value,
        orElse: () => NotifyPermission.unsupported,
      );

  bool get isGranted => this == granted;

  /// Можно показать системный вопрос.
  bool get canAsk => this == notAsked || this == denied;
}

/// Точное время напоминаний (Android 12+: «Будильники и напоминания»).
enum ExactAlarm {
  granted,
  denied,

  /// Не нужно: Android до 12, macOS.
  notNeeded;

  static ExactAlarm parse(Object? value) => ExactAlarm.values.firstWhere(
        (ExactAlarm e) => e.name == value,
        orElse: () => ExactAlarm.notNeeded,
      );
}

/// Системные уведомления, напоминания и будильник в «Часах» (ADR-029).
///
/// Без сети: уведомления создаются на устройстве. Системе передаётся
/// только расписание ([Reminder]: название задачи, время, имя помощника).
abstract interface class NotifyPlatform {
  /// Для этой платформы: канал на Android и macOS, иначе [UnsupportedNotify].
  factory NotifyPlatform.current() => Platform.isAndroid || Platform.isMacOS
      ? MethodChannelNotify()
      : const UnsupportedNotify();

  /// Системные уведомления есть на этом устройстве.
  bool get supported;

  /// Будильник и таймер ставятся в «Часах» (Android).
  bool get alarmsSupported;

  Future<NotifyPermission> status();

  /// Системный вопрос (Android 13+, macOS); итог — новое состояние.
  Future<NotifyPermission> request();

  Future<ExactAlarm> exactStatus();

  /// Страница уведомлений приложения в настройках системы.
  Future<void> openNotificationSettings();

  /// «Будильники и напоминания» (Android 12+).
  Future<void> openExactAlarmSettings();

  /// Заменяет всё расписание напоминаний на [upcoming]. Отложенные
  /// («Через 10 минут») напоминания задач из [snoozable] остаются.
  Future<void> sync(
    List<Reminder> upcoming, {
    Set<String> snoozable = const <String>{},
  });

  /// Есть приложение «Часы», которое принимает будильник.
  Future<bool> canSetAlarm();

  Future<bool> setAlarm({
    required int hour,
    required int minute,
    String? label,
    List<int>? days,
  });

  Future<bool> setTimer({required int seconds, String? label});

  /// Нажато уведомление: id задачи.
  Stream<String> get openedTask;

  /// Приложение открыли нажатием на уведомление: id задачи (один раз).
  Future<String?> takeLaunchTask();
}

/// Канал `tridot/notify` (Android: NotifyChannel.kt, macOS:
/// NotifyChannel.swift).
final class MethodChannelNotify implements NotifyPlatform {
  MethodChannelNotify({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('tridot/notify') {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  final StreamController<String> _opened = StreamController<String>.broadcast();

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method == 'openTask' && call.arguments is String) {
      _opened.add(call.arguments as String);
    }
    return null;
  }

  @override
  bool get supported => true;

  @override
  bool get alarmsSupported => Platform.isAndroid;

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<NotifyPermission> status() async =>
      NotifyPermission.parse(await _invoke<String>('status'));

  @override
  Future<NotifyPermission> request() async =>
      NotifyPermission.parse(await _invoke<String>('request'));

  @override
  Future<ExactAlarm> exactStatus() async =>
      ExactAlarm.parse(await _invoke<String>('exactStatus'));

  @override
  Future<void> openNotificationSettings() =>
      _invoke<void>('openNotificationSettings');

  @override
  Future<void> openExactAlarmSettings() =>
      _invoke<void>('openExactAlarmSettings');

  @override
  Future<void> sync(
    List<Reminder> upcoming, {
    Set<String> snoozable = const <String>{},
  }) =>
      _invoke<void>('sync', <String, Object?>{
        'reminders': <Object?>[
          for (final reminder in upcoming) reminder.toJson(),
        ],
        'snoozable': snoozable.toList(),
      });

  @override
  Future<bool> canSetAlarm() async =>
      alarmsSupported && (await _invoke<bool>('canSetAlarm') ?? false);

  @override
  Future<bool> setAlarm({
    required int hour,
    required int minute,
    String? label,
    List<int>? days,
  }) async =>
      await _invoke<bool>('setAlarm', <String, Object?>{
        'hour': hour,
        'minute': minute,
        if (label != null) 'label': label,
        if (days != null && days.isNotEmpty) 'days': days,
      }) ??
      false;

  @override
  Future<bool> setTimer({required int seconds, String? label}) async =>
      await _invoke<bool>('setTimer', <String, Object?>{
        'seconds': seconds,
        if (label != null) 'label': label,
      }) ??
      false;

  @override
  Stream<String> get openedTask => _opened.stream;

  @override
  Future<String?> takeLaunchTask() => _invoke<String>('takeLaunchTask');
}

/// Windows и Linux: системных уведомлений и будильника нет.
final class UnsupportedNotify implements NotifyPlatform {
  const UnsupportedNotify();

  @override
  bool get supported => false;

  @override
  bool get alarmsSupported => false;

  @override
  Future<NotifyPermission> status() async => NotifyPermission.unsupported;

  @override
  Future<NotifyPermission> request() async => NotifyPermission.unsupported;

  @override
  Future<ExactAlarm> exactStatus() async => ExactAlarm.notNeeded;

  @override
  Future<void> openNotificationSettings() async {}

  @override
  Future<void> openExactAlarmSettings() async {}

  @override
  Future<void> sync(
    List<Reminder> upcoming, {
    Set<String> snoozable = const <String>{},
  }) async {}

  @override
  Future<bool> canSetAlarm() async => false;

  @override
  Future<bool> setAlarm({
    required int hour,
    required int minute,
    String? label,
    List<int>? days,
  }) async =>
      false;

  @override
  Future<bool> setTimer({required int seconds, String? label}) async => false;

  @override
  Stream<String> get openedTask => const Stream<String>.empty();

  @override
  Future<String?> takeLaunchTask() async => null;
}

/// Будильник навыка «Будильник» через [NotifyPlatform].
final class NotifyAlarmSetter implements AlarmSetter {
  const NotifyAlarmSetter(this.platform);

  final NotifyPlatform platform;

  @override
  bool get supported => platform.alarmsSupported;

  @override
  Future<bool> canSet() => platform.canSetAlarm();

  @override
  Future<bool> set(AlarmRequest request) => request.isTimer
      ? platform.setTimer(seconds: request.seconds ?? 0, label: request.label)
      : platform.setAlarm(
          hour: request.hour ?? 0,
          minute: request.minute ?? 0,
          label: request.label,
          days: request.days,
        );
}
