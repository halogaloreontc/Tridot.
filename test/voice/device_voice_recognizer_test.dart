import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/voice/device_voice_recognizer.dart';
import 'package:local_assistant/core/voice/voice_recognizer.dart';

const MethodChannel _method = MethodChannel('tridot/voice-test');
const EventChannel _events = EventChannel('tridot/voice-test/events');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late Map<Object?, Object?> statusAnswer;
  late Object? startAnswer;
  late String downloadAnswer;
  MockStreamHandlerEventSink? sink;

  setUp(() {
    calls = <MethodCall>[];
    statusAnswer = <Object?, Object?>{
      'api': 34,
      'available': true,
      'language': 'installed',
    };
    startAnswer = 0;
    downloadAnswer = 'requested';
    sink = null;
    messenger.setMockMethodCallHandler(_method, (MethodCall call) async {
      calls.add(call);
      return switch (call.method) {
        'status' => statusAnswer,
        'start' => startAnswer,
        'download' => downloadAnswer,
        _ => null,
      };
    });
    messenger.setMockStreamHandler(
      _events,
      MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink events) {
          sink = events;
        },
        onCancel: (Object? arguments) => sink = null,
      ),
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_method, null);
    messenger.setMockStreamHandler(_events, null);
  });

  DeviceVoiceRecognizer recognizer({
    Duration stopTimeout = const Duration(milliseconds: 50),
  }) =>
      DeviceVoiceRecognizer(
        method: _method,
        events: _events,
        permission: () async => true,
        stopTimeout: stopTimeout,
      );

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  void native(Map<String, Object?> event) => sink!.success(event);

  group('статус', () {
    final cases = <(Map<Object?, Object?>, DeviceVoiceStatus)>[
      (
        <Object?, Object?>{
          'api': 30,
          'available': false,
          'language': 'unsupported',
        },
        DeviceVoiceStatus.unavailable,
      ),
      (
        <Object?, Object?>{
          'api': 33,
          'available': true,
          'language': 'installed',
        },
        DeviceVoiceStatus.ready,
      ),
      (
        <Object?, Object?>{
          'api': 33,
          'available': true,
          'language': 'supported',
        },
        DeviceVoiceStatus.notInstalled,
      ),
      (
        <Object?, Object?>{'api': 34, 'available': true, 'language': 'pending'},
        DeviceVoiceStatus.pending,
      ),
      (
        <Object?, Object?>{
          'api': 33,
          'available': true,
          'language': 'unsupported',
        },
        DeviceVoiceStatus.unsupported,
      ),
      (
        <Object?, Object?>{'api': 31, 'available': true, 'language': 'unknown'},
        DeviceVoiceStatus.unknown,
      ),
    ];
    for (final (answer, expected) in cases) {
      test('$answer → ${expected.name}', () async {
        statusAnswer = answer;
        final voice = recognizer();
        expect(await voice.checkStatus(), expected);
        expect(calls.single.method, 'status');
        expect(calls.single.arguments, <String, Object?>{'language': 'ru-RU'});
        expect(
          voice.support,
          expected == DeviceVoiceStatus.unavailable
              ? VoiceSupport.unsupported
              : VoiceSupport.supported,
        );
      });
    }

    test('нет канала — unavailable', () async {
      final voice = DeviceVoiceRecognizer(
        method: const MethodChannel('tridot/voice-missing'),
        events: _events,
        permission: () async => true,
      );
      expect(await voice.checkStatus(), DeviceVoiceStatus.unavailable);
      expect(voice.support, VoiceSupport.unsupported);
    });
  });

  test('начало: русский и номер сессии; промежуточный, затем итог', () async {
    final voice = recognizer();
    final events = <VoiceEvent>[];
    final done = Completer<void>();
    voice.start().listen(events.add, onDone: done.complete);
    await settle();
    final start = calls.singleWhere((MethodCall c) => c.method == 'start');
    final arguments = start.arguments as Map<Object?, Object?>;
    expect(arguments['language'], 'ru-RU');
    final session = arguments['session']! as int;
    native(<String, Object?>{
      'session': session,
      'type': 'partial',
      'text': 'напомни',
    });
    native(<String, Object?>{
      'session': session,
      'type': 'final',
      'text': 'Напомни купить хлеб',
    });
    await done.future;
    expect(events, hasLength(2));
    expect((events[0] as VoicePartial).text, 'напомни');
    expect((events[1] as VoiceFinal).text, 'Напомни купить хлеб');
  });

  group('ошибки', () {
    final cases = <int, VoiceErrorCode?>{
      1: VoiceErrorCode.engine,
      2: VoiceErrorCode.engine,
      3: VoiceErrorCode.microphone,
      4: VoiceErrorCode.engine,
      5: VoiceErrorCode.engine,
      6: null,
      7: null,
      8: VoiceErrorCode.busy,
      9: VoiceErrorCode.microphone,
      10: VoiceErrorCode.busy,
      11: VoiceErrorCode.engine,
      12: VoiceErrorCode.languageUnsupported,
      13: VoiceErrorCode.languageUnavailable,
    };
    for (final MapEntry(key: code, value: expected) in cases.entries) {
      test('код $code → ${expected?.name ?? 'пустой итог'}', () async {
        final voice = recognizer();
        final events = <VoiceEvent>[];
        final done = Completer<void>();
        voice.start().listen(events.add, onDone: done.complete);
        await settle();
        native(<String, Object?>{'session': 1, 'type': 'error', 'code': code});
        await done.future;
        final event = events.single;
        if (expected == null) {
          expect((event as VoiceFinal).text, isEmpty);
        } else {
          expect((event as VoiceError).code, expected);
        }
      });
    }

    test('код 12 и 13 меняют статус', () async {
      final voice = recognizer();
      final first = voice.start().toList();
      await settle();
      native(<String, Object?>{'session': 1, 'type': 'error', 'code': 13});
      await first;
      expect(voice.status, DeviceVoiceStatus.notInstalled);
    });

    test('начать не удалось (-1) — сбой движка', () async {
      startAnswer = -1;
      final voice = recognizer();
      final events = await voice.start().toList();
      expect((events.single as VoiceError).code, VoiceErrorCode.engine);
      expect(voice.status, DeviceVoiceStatus.unavailable);
    });

    test('нет канала — сбой движка, без исключения', () async {
      final voice = DeviceVoiceRecognizer(
        method: const MethodChannel('tridot/voice-missing'),
        events: _events,
        permission: () async => true,
      );
      final events = await voice.start().toList();
      expect((events.single as VoiceError).code, VoiceErrorCode.engine);
      expect(voice.support, VoiceSupport.unsupported);
    });
  });

  test('события прежней сессии не попадают в новую', () async {
    final voice = recognizer();
    unawaited(voice.start().drain<void>());
    await settle();
    final events = <VoiceEvent>[];
    voice.start().listen(events.add);
    await settle();
    native(<String, Object?>{
      'session': 1,
      'type': 'partial',
      'text': 'старое',
    });
    native(<String, Object?>{'session': 2, 'type': 'partial', 'text': 'новое'});
    await settle();
    expect(events.map((VoiceEvent e) => (e as VoicePartial).text), <String>[
      'новое',
    ]);
  });

  test('итог не пришёл после стопа — последнее промежуточное', () async {
    final voice = recognizer();
    final events = <VoiceEvent>[];
    final done = Completer<void>();
    voice.start().listen(events.add, onDone: done.complete);
    await settle();
    native(<String, Object?>{
      'session': 1,
      'type': 'partial',
      'text': 'купить хлеб',
    });
    await settle();
    await voice.stop();
    await done.future;
    expect((events.last as VoiceFinal).text, 'купить хлеб');
    expect(
      calls.map((MethodCall c) => c.method),
      containsAllInOrder(<String>['start', 'stop', 'cancel']),
    );
  });

  test('отмена: поток закрыт без итога, поздние события молчат', () async {
    final voice = recognizer();
    final events = <VoiceEvent>[];
    final done = Completer<void>();
    voice.start().listen(events.add, onDone: done.complete);
    await settle();
    await voice.cancel();
    await done.future;
    native(<String, Object?>{'session': 1, 'type': 'error', 'code': 5});
    native(<String, Object?>{'session': 1, 'type': 'final', 'text': 'поздно'});
    await settle();
    expect(events, isEmpty);
    expect(calls.last.method, 'cancel');
  });

  test('загрузка языка: проценты, затем успех', () async {
    final voice = recognizer();
    await voice.checkStatus();
    final updates = <DeviceLanguageDownload>[];
    final done = Completer<void>();
    voice.downloadLanguage().listen(updates.add, onDone: done.complete);
    await settle();
    expect(calls.last.method, 'download');
    native(<String, Object?>{
      'type': 'download',
      'state': 'progress',
      'value': 40,
    });
    native(<String, Object?>{'type': 'download', 'state': 'success'});
    await done.future;
    expect((updates.first as DeviceDownloadProgress).percent, 40);
    expect(updates.last, isA<DeviceDownloadSuccess>());
  });

  test('загрузка отложена системой', () async {
    final voice = recognizer();
    await voice.checkStatus();
    final updates = <DeviceLanguageDownload>[];
    final done = Completer<void>();
    voice.downloadLanguage().listen(updates.add, onDone: done.complete);
    await settle();
    native(<String, Object?>{'type': 'download', 'state': 'scheduled'});
    await done.future;
    expect(updates.single, isA<DeviceDownloadScheduled>());
  });

  test('Android 13: без новостей — «скачает позже»', () async {
    statusAnswer = <Object?, Object?>{
      'api': 33,
      'available': true,
      'language': 'supported',
    };
    final voice = recognizer();
    await voice.checkStatus();
    final updates = await voice.downloadLanguage().toList();
    expect(updates.single, isA<DeviceDownloadScheduled>());
  });

  test('загрузка не поддерживается — ошибка', () async {
    downloadAnswer = 'unsupported';
    final voice = recognizer();
    final updates = await voice.downloadLanguage().toList();
    expect(updates.single, isA<DeviceDownloadError>());
  });

  test('Dart зовёт только status, download, start, stop и cancel', () async {
    final voice = recognizer();
    await voice.checkStatus();
    final listening = voice.start().drain<void>();
    await settle();
    await voice.stop();
    await listening;
    await voice.cancel();
    final download = voice.downloadLanguage().drain<void>();
    await settle();
    native(<String, Object?>{'type': 'download', 'state': 'success'});
    await download;
    expect(
      calls.map((MethodCall c) => c.method).toSet().difference(
            deviceVoiceMethods,
          ),
      isEmpty,
    );
    expect(deviceVoiceMethods, <String>{
      'status',
      'download',
      'start',
      'stop',
      'cancel',
    });
  });

  test('в коде канала нет сетевого распознавателя и PREFER_OFFLINE', () {
    final kotlin = File(
      'android/app/src/main/kotlin/com/example/local_assistant/voice/'
      'VoiceChannel.kt',
    ).readAsStringSync();
    // Код без комментариев: в них эти имена упоминаются как запрет.
    final code = kotlin
        .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
        .replaceAll(RegExp(r'//.*'), '');
    expect(code, isNot(contains('createSpeechRecognizer(')));
    expect(code, isNot(contains('EXTRA_PREFER_OFFLINE')));
    expect(code, isNot(contains('Log.')));
    expect(code, contains('createOnDeviceSpeechRecognizer'));
  });
}
