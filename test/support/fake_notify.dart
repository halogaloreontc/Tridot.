import 'dart:async';

import 'package:local_assistant/app/notify/notify_channel.dart';
import 'package:local_assistant/core/notify/reminder_plan.dart';

/// Поддельные уведомления (ADR-029): состояние задаётся тестом, вызовы
/// записываются.
final class FakeNotify implements NotifyPlatform {
  FakeNotify({
    this.permission = NotifyPermission.notAsked,
    this.afterRequest = NotifyPermission.granted,
    this.exact = ExactAlarm.notNeeded,
    this.alarms = true,
    this.clock = true,
    this.supported = true,
  });

  NotifyPermission permission;

  /// Что ответит системный вопрос.
  NotifyPermission afterRequest;

  ExactAlarm exact;

  final bool alarms;

  /// Есть ли «Часы».
  bool clock;

  @override
  final bool supported;

  int requests = 0;
  int settingsOpened = 0;
  int exactOpened = 0;
  final List<List<Reminder>> synced = <List<Reminder>>[];

  /// Задачи, чьи отложенные напоминания сохраняются, — по каждому sync.
  final List<Set<String>> syncedSnoozable = <Set<String>>[];
  final List<({int hour, int minute, String? label, List<int>? days})>
      alarmsSet = <({int hour, int minute, String? label, List<int>? days})>[];
  final List<({int seconds, String? label})> timersSet =
      <({int seconds, String? label})>[];
  String? launchTask;
  final StreamController<String> opened = StreamController<String>.broadcast();

  @override
  bool get alarmsSupported => alarms;

  @override
  Future<NotifyPermission> status() async => permission;

  @override
  Future<NotifyPermission> request() async {
    requests++;
    permission = afterRequest;
    return permission;
  }

  @override
  Future<ExactAlarm> exactStatus() async => exact;

  @override
  Future<void> openNotificationSettings() async => settingsOpened++;

  @override
  Future<void> openExactAlarmSettings() async => exactOpened++;

  @override
  Future<void> sync(
    List<Reminder> upcoming, {
    Set<String> snoozable = const <String>{},
  }) async {
    synced.add(List<Reminder>.of(upcoming));
    syncedSnoozable.add(Set<String>.of(snoozable));
  }

  @override
  Future<bool> canSetAlarm() async => alarms && clock;

  @override
  Future<bool> setAlarm({
    required int hour,
    required int minute,
    String? label,
    List<int>? days,
  }) async {
    if (!alarms || !clock) return false;
    alarmsSet.add((hour: hour, minute: minute, label: label, days: days));
    return true;
  }

  @override
  Future<bool> setTimer({required int seconds, String? label}) async {
    if (!alarms || !clock) return false;
    timersSet.add((seconds: seconds, label: label));
    return true;
  }

  @override
  Stream<String> get openedTask => opened.stream;

  @override
  Future<String?> takeLaunchTask() async {
    final task = launchTask;
    launchTask = null;
    return task;
  }
}
