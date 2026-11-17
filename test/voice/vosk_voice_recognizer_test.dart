import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/voice/vosk_voice_recognizer.dart';
import 'package:local_assistant/core/voice/voice_recognizer.dart';

/// Изолят без `libvosk`: отвечает на тот же протокол, что настоящий.
/// Каждый кусок звука — промежуточный текст «слово N», «finish» — итог.
void _fakeWorker(List<Object?> args) {
  final out = args[0]! as SendPort;
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  var chunks = 0;
  inbox.listen((Object? message) {
    final list = message! as List<Object?>;
    final id = list[0]! as int;
    switch (list[1]) {
      case 'audio':
        chunks++;
        out.send(<Object?>[-1, 'partial', 'слово $chunks']);
      case 'finish':
        out.send(<Object?>[id, 'ok', 'итог $chunks']);
        chunks = 0;
      case 'dispose':
        out.send(<Object?>[id, 'ok', null]);
        inbox.close();
      default:
        chunks = list[1] == 'begin' ? 0 : chunks;
        out.send(<Object?>[id, 'ok', null]);
    }
  });
}

/// Микрофон для тестов: [start] включается за [startDelay], [stop]
/// выключает и закрывает поток.
final class _SlowMic implements PcmSource {
  _SlowMic({this.startDelay = Duration.zero});

  final Duration startDelay;
  int starts = 0;
  int stops = 0;
  bool recording = false;
  StreamController<Uint8List>? _audio;

  void speak() => _audio?.add(Uint8List(320));

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Stream<Uint8List>> start() async {
    starts++;
    await Future<void>.delayed(startDelay);
    recording = true;
    final audio = _audio = StreamController<Uint8List>.broadcast();
    return audio.stream;
  }

  @override
  Future<void> stop() async {
    stops++;
    recording = false;
    final audio = _audio;
    _audio = null;
    await audio?.close();
  }

  @override
  Future<void> dispose() async {
    if (recording) await stop();
  }
}

void main() {
  late _SlowMic mic;
  late VoskVoiceRecognizer recognizer;

  VoskVoiceRecognizer make(_SlowMic source) => VoskVoiceRecognizer(
        microphone: () => source,
        worker: _fakeWorker,
        support: VoiceSupport.supported,
      );

  tearDown(() async {
    await recognizer.dispose();
  });

  test('слушает, показывает промежуточное и отдаёт итог; микрофон выключен',
      () async {
    mic = _SlowMic();
    recognizer = make(mic);
    await recognizer.load('/модель');
    final events = <VoiceEvent>[];
    final done = Completer<void>();
    recognizer.start().listen(events.add, onDone: done.complete);
    while (!mic.recording) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    mic
      ..speak()
      ..speak();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await recognizer.stop();
    await done.future;
    expect(
      events.whereType<VoicePartial>().map((e) => e.text),
      <String>['слово 1', 'слово 2'],
    );
    expect((events.last as VoiceFinal).text, 'итог 2');
    expect(mic.stops, 1);
    expect(mic.recording, isFalse);
  });

  test('отмена, пока микрофон включается, выключает его сразу', () async {
    mic = _SlowMic(startDelay: const Duration(milliseconds: 150));
    recognizer = make(mic);
    await recognizer.load('/модель');
    final events = <VoiceEvent>[];
    final done = Completer<void>();
    recognizer.start().listen(events.add, onDone: done.complete);
    while (mic.starts == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    // Короткое касание: отпустили, пока микрофон ещё включался.
    await recognizer.cancel();
    await done.future;
    expect(mic.starts, 1);
    expect(mic.stops, 1);
    expect(mic.recording, isFalse);
    expect(events, isEmpty);
  });

  test('отмена до включения микрофона — микрофон не включается', () async {
    mic = _SlowMic();
    recognizer = make(mic);
    await recognizer.load('/модель');
    final done = Completer<void>();
    recognizer.start().listen((_) {}, onDone: done.complete);
    // Сразу: изолят ещё не ответил на «begin».
    await recognizer.cancel();
    await done.future;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(mic.starts, 0);
    expect(mic.recording, isFalse);
  });

  test('новое начало закрывает прежний поток', () async {
    mic = _SlowMic();
    recognizer = make(mic);
    await recognizer.load('/модель');
    final firstDone = Completer<void>();
    recognizer.start().listen((_) {}, onDone: firstDone.complete);
    await recognizer.cancel();
    final second = <VoiceEvent>[];
    final secondDone = Completer<void>();
    recognizer.start().listen(second.add, onDone: secondDone.complete);
    await firstDone.future;
    while (!mic.recording) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await recognizer.stop();
    await secondDone.future;
    expect(second.last, isA<VoiceFinal>());
    expect(mic.recording, isFalse);
  });

  test('без загруженной модели — ошибка, микрофон не включается', () async {
    mic = _SlowMic();
    recognizer = make(mic);
    final events = await recognizer.start().toList();
    expect(events.single, isA<VoiceError>());
    expect(
      (events.single as VoiceError).code,
      VoiceErrorCode.modelLoad,
    );
    expect(mic.starts, 0);
  });
}
