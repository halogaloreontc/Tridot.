// Канал `tridot/homescreen` (ADR-034): что именно уходит в Android и как
// разбираются ответы — по договору в начале home_screen_channel.dart.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/homescreen/home_screen_channel.dart';
import 'package:local_assistant/core/homescreen/home_screen_snapshot.dart';
import 'package:local_assistant/core/models/task.dart';

const MethodChannel _method = MethodChannel('tridot/homescreen-test');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late Map<String, Object?> answers;

  setUp(() {
    calls = <MethodCall>[];
    answers = <String, Object?>{};
    messenger.setMockMethodCallHandler(_method, (MethodCall call) async {
      calls.add(call);
      final answer = answers[call.method];
      if (answer is Exception) throw answer;
      return answer;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(_method, null));

  /// Вызов от Android в приложение.
  Future<void> fromAndroid(String method, [Object? arguments]) async {
    await messenger.handlePlatformMessage(
      _method.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, arguments),
      ),
      (ByteData? _) {},
    );
  }

  test('state: что стоит на рабочем столе', () async {
    final channel = MethodChannelHomeScreen(channel: _method);
    answers['state'] = <Object?, Object?>{
      'supported': true,
      'canPin': true,
      'installed': <Object?, Object?>{'today': 1, 'quick': 0, 'combo': 2},
      'needsSnapshot': true,
    };
    final state = await channel.state();
    expect(calls.single.method, 'state');
    expect(calls.single.arguments, isNull);
    expect(state.supported, isTrue);
    expect(state.canPin, isTrue);
    expect(state.needsSnapshot, isTrue);
    expect(state.has(HomeScreenKind.today), isTrue);
    expect(state.has(HomeScreenKind.quick), isFalse);
    expect(state.installed, <HomeScreenKind, int>{
      HomeScreenKind.today: 1,
      HomeScreenKind.combo: 2,
    });
  });

  test('state: канала нет или ответ не тот — виджетов нет', () async {
    final channel = MethodChannelHomeScreen(channel: _method);
    expect((await channel.state()).supported, isFalse);
    answers['state'] = 'да';
    expect((await channel.state()).supported, isFalse);
    answers['state'] = PlatformException(code: 'x');
    final state = await channel.state();
    expect(state.supported, isFalse);
    expect(state.canPin, isFalse);
    expect(state.installed, isEmpty);
    // Обработчика нет вовсе (старая сборка Android).
    messenger.setMockMethodCallHandler(_method, null);
    expect((await channel.state()).supported, isFalse);
    expect(await channel.pending(), isEmpty);
    expect(await channel.pin(HomeScreenKind.today), isFalse);
    expect(await channel.takeLaunch(), isNull);
    await channel.sync(
      HomeScreenPlan.from(
        const <Task>[],
        now: DateTime(2026, 11, 16, 12),
        showText: true,
        voice: false,
      ),
    );
    await channel.ack(1);
  });

  test('sync: снимок — одной строкой JSON', () async {
    final channel = MethodChannelHomeScreen(channel: _method);
    final now = DateTime(2026, 11, 16, 12);
    final snapshot = HomeScreenPlan.from(
      <Task>[
        Task(
          id: 'task_1',
          title: 'Купить хлеб',
          status: TaskStatus.planned,
          priority: TaskPriority.normal,
          dueAt: DateTime(2026, 11, 16, 18),
          createdAt: now,
          updatedAt: now,
        ),
      ],
      now: now,
      showText: true,
      voice: true,
    );
    await channel.sync(snapshot);
    expect(calls.single.method, 'sync');
    final sent = calls.single.arguments;
    expect(sent, isA<String>());
    expect(sent, snapshot.encode());
    final json = jsonDecode(sent as String) as Map<String, Object?>;
    expect(
      json.keys,
      <String>['v', 'mode', 'voice', 'until', 'tasks', 'frames'],
    );
    final frame =
        (json['frames']! as List<Object?>).first! as Map<String, Object?>;
    expect(frame.keys, <String>['from', 'count', 'summary', 'alert', 'rows']);
  });

  test('pending: очередь списком или строкой JSON; мусор пропускается',
      () async {
    final channel = MethodChannelHomeScreen(channel: _method);
    final list = <Object?>[
      <Object?, Object?>{
        'seq': 12,
        'op': 'done',
        'task': 'task_1',
        'at': 1763300000000,
      },
      'мусор',
      <Object?, Object?>{
        'seq': 13,
        'op': 'undo',
        'task': 'task_1',
        'at': 1763300002000,
        'doneAt': 1763300000000,
      },
    ];
    answers['pending'] = list;
    final ops = await channel.pending();
    expect(calls.single.method, 'pending');
    expect(ops.map((HomeScreenOp op) => op.seq), <int>[12, 13]);
    expect(ops.first.kind, HomeScreenOpKind.done);
    expect(ops.last.kind, HomeScreenOpKind.undo);
    expect(
      ops.last.doneAt,
      DateTime.fromMillisecondsSinceEpoch(1763300000000),
    );
    answers['pending'] = jsonEncode(list);
    expect(
      (await channel.pending()).map((HomeScreenOp op) => op.seq),
      <int>[12, 13],
    );
    for (final junk in <Object?>[null, 'не json', 7, <Object?, Object?>{}]) {
      answers['pending'] = junk;
      expect(await channel.pending(), isEmpty, reason: '$junk');
    }
  });

  test('ack, pin и takeLaunch', () async {
    final channel = MethodChannelHomeScreen(channel: _method);
    await channel.ack(13);
    expect(calls.last.method, 'ack');
    expect(calls.last.arguments, <String, Object?>{'upTo': 13});

    answers['pin'] = true;
    expect(await channel.pin(HomeScreenKind.combo), isTrue);
    expect(calls.last.method, 'pin');
    expect(calls.last.arguments, <String, Object?>{'kind': 'combo'});
    answers['pin'] = null;
    expect(await channel.pin(HomeScreenKind.quick), isFalse);
    expect(calls.last.arguments, <String, Object?>{'kind': 'quick'});
    expect(
      HomeScreenKind.values.map((HomeScreenKind k) => k.name),
      <String>['today', 'quick', 'combo'],
    );

    answers['takeLaunch'] = 'voice';
    expect(await channel.takeLaunch(), HomeScreenLaunch.voice);
    answers['takeLaunch'] = 'compose';
    expect(await channel.takeLaunch(), HomeScreenLaunch.compose);
    answers['takeLaunch'] = 'другое';
    expect(await channel.takeLaunch(), isNull);
    answers['takeLaunch'] = null;
    expect(await channel.takeLaunch(), isNull);
  });

  test('от Android: launch, pendingChanged, needSnapshot', () async {
    final channel = MethodChannelHomeScreen(channel: _method);
    final launches = <HomeScreenLaunch>[];
    var pending = 0;
    var wanted = 0;
    final subscriptions = <StreamSubscription<Object?>>[
      channel.launches.listen(launches.add),
      channel.pendingChanged.listen((_) => pending++),
      channel.snapshotWanted.listen((_) => wanted++),
    ];
    await fromAndroid('launch', 'compose');
    await fromAndroid('launch', 'voice');
    await fromAndroid('launch', 'нечто');
    await fromAndroid('pendingChanged');
    await fromAndroid('needSnapshot');
    await fromAndroid('needSnapshot');
    await fromAndroid('неизвестный');
    await Future<void>.delayed(Duration.zero);
    expect(launches, <HomeScreenLaunch>[
      HomeScreenLaunch.compose,
      HomeScreenLaunch.voice,
    ]);
    expect(pending, 1);
    expect(wanted, 2);
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  });

  test('где виджетов нет — всё пусто', () async {
    const none = UnsupportedHomeScreen();
    expect(none.supported, isFalse);
    expect((await none.state()).supported, isFalse);
    expect(await none.pending(), isEmpty);
    expect(await none.pin(HomeScreenKind.today), isFalse);
    expect(await none.takeLaunch(), isNull);
    expect(await none.launches.isEmpty, isTrue);
    expect(await none.pendingChanged.isEmpty, isTrue);
    expect(await none.snapshotWanted.isEmpty, isTrue);
  });
}
