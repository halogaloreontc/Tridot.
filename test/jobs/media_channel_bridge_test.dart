// Каналы системного конвертера (ADR-026): что уходит в `tridot/media`,
// как приходят события `tridot/media/events`, и что без канала (Windows,
// Linux, тесты) системного конвертера просто нет.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/jobs/media_channel_bridge.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';
import 'package:local_assistant/core/skills/converter/platform_media_job.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const method = MethodChannel('tridot/media');
  const events = EventChannel('tridot/media/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger
      ..setMockMethodCallHandler(method, null)
      ..setMockStreamHandler(events, null);
  });

  test('без канала — системного конвертера нет', () async {
    final bridge = ChannelMediaBridge();
    expect(await bridge.capabilities(), isNull);
    final caps = await loadNativeMediaCaps(
      bridge,
      platform: JobPlatform.android,
    );
    expect(caps.targets, isEmpty);
    await expectLater(
      bridge.start(const <String, Object?>{'id': 'x'}),
      throwsA(
        isA<MediaBridgeException>()
            .having((MediaBridgeException e) => e.code, 'code', 'unsupported'),
      ),
    );
    await bridge.cancel('x');
  });

  test('capabilities, start, cancel и отказ с кодом', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(method, (MethodCall call) async {
      calls.add(call);
      switch (call.method) {
        case 'capabilities':
          return <String, Object?>{
            'targets': <String>['mp3', 'wav'],
            'video1080': true,
            'api': 34,
          };
        case 'start':
          final args = call.arguments as Map<Object?, Object?>;
          if (args['target'] == 'webm') {
            throw PlatformException(code: 'unsupported');
          }
          return null;
      }
      return null;
    });
    final bridge = ChannelMediaBridge();
    final caps = await loadNativeMediaCaps(
      bridge,
      platform: JobPlatform.android,
    );
    expect(caps.targets, <String>{'mp3', 'wav'});
    await bridge.start(const <String, Object?>{'id': 'a', 'target': 'mp3'});
    await expectLater(
      bridge.start(const <String, Object?>{'id': 'b', 'target': 'webm'}),
      throwsA(
        isA<MediaBridgeException>()
            .having((MediaBridgeException e) => e.code, 'code', 'unsupported'),
      ),
    );
    await bridge.cancel('a');
    expect(
      calls.map((MethodCall c) => c.method),
      <String>['capabilities', 'start', 'start', 'cancel'],
    );
    expect(calls.last.arguments, <String, Object?>{'id': 'a'});
  });

  test('события приходят картами; не карты отбрасываются', () async {
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink sink) {
          sink
            ..success(<String, Object?>{'id': 'a', 'progress': 0.5})
            ..success('мусор')
            ..success(<String, Object?>{'id': 'a', 'done': true})
            ..endOfStream();
        },
      ),
    );
    final bridge = ChannelMediaBridge();
    final got = await bridge.events.toList();
    expect(got, <Map<Object?, Object?>>[
      <Object?, Object?>{'id': 'a', 'progress': 0.5},
      <Object?, Object?>{'id': 'a', 'done': true},
    ]);
  });
}
