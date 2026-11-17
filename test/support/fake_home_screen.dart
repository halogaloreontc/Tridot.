import 'dart:async';
import 'dart:convert';

import 'package:local_assistant/app/homescreen/home_screen_channel.dart';

/// Поддельные виджеты рабочего стола (ADR-034): состояние задаётся тестом,
/// вызовы записываются по порядку.
final class FakeHomeScreen implements HomeScreenPlatform {
  FakeHomeScreen({
    this.supported = true,
    this.stateSupported = true,
    this.canPin = true,
    this.pinAccepted = true,
    Map<HomeScreenKind, int>? installed,
  }) : installed = installed ?? <HomeScreenKind, int>{};

  @override
  final bool supported;

  /// Что ответит `state`: система знает виджеты.
  bool stateSupported;

  /// Лаунчер добавляет виджет по просьбе приложения.
  bool canPin;

  /// Лаунчер принял просьбу — и человек согласился: виджет появляется.
  bool pinAccepted;

  final Map<HomeScreenKind, int> installed;

  /// Все вызовы по порядку: `pending`, `sync`, `ack:3`, `pin:today`.
  final List<String> calls = <String>[];

  final List<HomeScreenSnapshot> synced = <HomeScreenSnapshot>[];

  /// Очередь отметок: `ack` стирает подтверждённые, как система.
  final List<HomeScreenOp> queue = <HomeScreenOp>[];

  final List<int> acked = <int>[];
  final List<HomeScreenKind> pinned = <HomeScreenKind>[];

  /// Чем «открыли» приложение (холодный запуск с виджета).
  HomeScreenLaunch? launch;

  int stateCalls = 0;

  final StreamController<HomeScreenLaunch> launched =
      StreamController<HomeScreenLaunch>.broadcast();
  final StreamController<void> changed = StreamController<void>.broadcast();
  final StreamController<void> wanted = StreamController<void>.broadcast();

  /// Последний снимок так, как его получит Android: разобранный JSON.
  Map<String, Object?> get last =>
      jsonDecode(synced.last.encode()) as Map<String, Object?>;

  /// Первый кадр последнего снимка.
  Map<String, Object?> get frame =>
      (last['frames']! as List<Object?>).first! as Map<String, Object?>;

  /// Названия задач первого кадра последнего снимка по порядку.
  List<String> get titles {
    final tasks =
        (last['tasks']! as List<Object?>).cast<Map<String, Object?>>();
    final rows = (frame['rows']! as List<Object?>).cast<Map<String, Object?>>();
    return <String>[
      for (final row in rows) tasks[row['t']! as int]['title']! as String,
    ];
  }

  @override
  Future<HomeScreenState> state() async {
    stateCalls++;
    return HomeScreenState(
      supported: stateSupported,
      canPin: canPin,
      installed: Map<HomeScreenKind, int>.of(installed),
    );
  }

  @override
  Future<void> sync(HomeScreenSnapshot snapshot) async {
    calls.add('sync');
    synced.add(snapshot);
  }

  @override
  Future<List<HomeScreenOp>> pending() async {
    calls.add('pending');
    return List<HomeScreenOp>.of(queue);
  }

  @override
  Future<void> ack(int upTo) async {
    calls.add('ack:$upTo');
    acked.add(upTo);
    queue.removeWhere((HomeScreenOp op) => op.seq <= upTo);
  }

  @override
  Future<bool> pin(HomeScreenKind kind) async {
    calls.add('pin:${kind.name}');
    pinned.add(kind);
    if (pinAccepted) installed[kind] = (installed[kind] ?? 0) + 1;
    return pinAccepted;
  }

  @override
  Future<HomeScreenLaunch?> takeLaunch() async {
    final value = launch;
    launch = null;
    return value;
  }

  @override
  Stream<HomeScreenLaunch> get launches => launched.stream;

  @override
  Stream<void> get pendingChanged => changed.stream;

  @override
  Stream<void> get snapshotWanted => wanted.stream;
}
