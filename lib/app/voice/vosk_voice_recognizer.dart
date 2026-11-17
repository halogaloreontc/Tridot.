import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:record/record.dart';

import '../../core/voice/voice_recognizer.dart';
import '../../core/voice/vosk_ffi.dart';

/// Голосовой ввод на Vosk (ADR-023): модель и распознаватель живут в
/// отдельном долгоживущем изоляте, микрофон — пакет `record` (PCM 16 бит,
/// 16 кГц, моно) в главном изоляте. Куски звука уходят в изолят как
/// [TransferableTypedData] и сразу забываются.
///
/// Звук существует только в памяти: не сохраняется, не отправляется, не
/// пишется в журнал; распознанный текст — тоже (`vosk_set_log_level(-1)`).
/// Любой сбой движка или изолята — [VoiceError], а не падение.
final class VoskVoiceRecognizer implements VoiceRecognizer {
  VoskVoiceRecognizer({
    this.libraryName = VoskBindings.libraryName,
    PcmSource Function()? microphone,
    @visibleForTesting void Function(List<Object?> args)? worker,
    @visibleForTesting VoiceSupport? support,
  })  : _newMic = microphone ?? RecordPcmSource.new,
        _worker = worker ?? _voskWorker,
        _support = support;

  /// Имя `libvosk` для [DynamicLibrary.open].
  final String libraryName;

  final PcmSource Function() _newMic;

  /// Точка входа изолята распознавания; в тестах — без `libvosk`.
  final void Function(List<Object?> args) _worker;

  static const int sampleRate = 16000;

  VoiceSupport? _support;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  Isolate? _isolate;
  Future<void>? _spawning;
  int _nextId = 0;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};

  PcmSource? _recorder;
  StreamController<VoiceEvent>? _events;
  StreamSubscription<Uint8List>? _audio;
  Completer<void>? _audioDone;

  /// Микрофон запущен (или запускается) и ещё не остановлен — даже если
  /// поток звука ещё никто не слушает.
  bool _micOn = false;
  Future<void>? _starting;
  String? _loadedPath;

  /// Есть ли `libvosk`. Создаётся он только на Android (`main.dart`):
  /// на других платформах библиотеки в сборке нет.
  @override
  VoiceSupport get support =>
      _support ??= VoskBindings.tryOpen(libraryName) != null
          ? VoiceSupport.supported
          : VoiceSupport.unsupported;

  PcmSource get _mic => _recorder ??= _newMic();

  @override
  Future<VoicePermission> ensurePermission() async {
    try {
      return await _mic.hasPermission()
          ? VoicePermission.granted
          : VoicePermission.denied;
    } on Object {
      return VoicePermission.denied;
    }
  }

  @override
  Future<void> load(String modelDir) async {
    if (_loadedPath == modelDir && _toWorker != null) return;
    if (support == VoiceSupport.unsupported) {
      throw const VoiceEngineException(VoiceErrorCode.modelLoad);
    }
    await _ensureWorker();
    await _request('load', modelDir);
    _loadedPath = modelDir;
  }

  @override
  Stream<VoiceEvent> start() {
    final previous = _events;
    final controller = StreamController<VoiceEvent>();
    _events = controller;
    if (previous != null && !previous.isClosed) unawaited(previous.close());
    _starting = _begin(controller);
    return controller.stream;
  }

  Future<void> _begin(StreamController<VoiceEvent> controller) async {
    if (_loadedPath == null || _toWorker == null) {
      _fail(controller, VoiceErrorCode.modelLoad);
      return;
    }
    try {
      await _request('begin');
    } on Object {
      _fail(controller, VoiceErrorCode.engine);
      return;
    }
    // Отменили, пока изолят готовился: микрофон не включаем вовсе.
    if (_events != controller) return;
    try {
      _micOn = true;
      final stream = await _mic.start();
      if (_events != controller) {
        // Отменили, пока микрофон включался: выключаем его сразу, а не
        // при следующем сеансе.
        await _stopMic();
        return;
      }
      final done = Completer<void>();
      _audioDone = done;
      _audio = stream.listen(
        (Uint8List chunk) {
          if (chunk.isEmpty) return;
          _toWorker?.send(<Object?>[
            -1,
            'audio',
            TransferableTypedData.fromList(<TypedData>[chunk]),
          ]);
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object _) {
          if (!done.isCompleted) done.complete();
          _fail(controller, VoiceErrorCode.microphone);
        },
        cancelOnError: true,
      );
    } on Object {
      await _stopMic();
      _fail(controller, VoiceErrorCode.microphone);
    }
  }

  /// Выключает микрофон, если он включён.
  Future<void> _stopMic() async {
    if (!_micOn) return;
    _micOn = false;
    try {
      await _recorder?.stop();
    } on Object {
      // Уже остановлен.
    }
  }

  @override
  Future<void> stop() async {
    final controller = _events;
    if (controller == null) return;
    await _starting;
    if (_events != controller) return;
    await _stopRecorder();
    try {
      final text = await _request('finish');
      if (_events == controller) {
        controller.add(VoiceFinal(text is String ? text : ''));
      }
    } on Object {
      if (_events == controller) {
        controller.add(const VoiceError(VoiceErrorCode.engine));
      }
    }
    if (_events == controller) _events = null;
    await controller.close();
  }

  @override
  Future<void> cancel() async {
    final controller = _events;
    _events = null;
    try {
      await _starting;
    } on Object {
      // Начало уже завершилось ошибкой.
    }
    await _stopRecorder();
    if (_toWorker != null) {
      try {
        await _request('reset');
      } on Object {
        // Изолят уже остановлен.
      }
    }
    if (controller != null && !controller.isClosed) await controller.close();
  }

  @override
  Future<void> unload() async {
    await cancel();
    if (_toWorker != null) {
      try {
        await _request('unload');
      } on Object {
        // Изолят уже остановлен.
      }
    }
    _loadedPath = null;
  }

  @override
  Future<void> dispose() async {
    await cancel();
    if (_toWorker != null) {
      try {
        await _request('dispose').timeout(const Duration(seconds: 2));
      } on Object {
        // Изолят не ответил — его всё равно остановим.
      }
    }
    _shutdownWorker();
    final recorder = _recorder;
    _recorder = null;
    try {
      await recorder?.dispose();
    } on Object {
      // Микрофон уже освобождён.
    }
  }

  Future<void> _stopRecorder() async {
    final recorder = _recorder;
    final subscription = _audio;
    final done = _audioDone;
    _audio = null;
    _audioDone = null;
    if (subscription == null) {
      await _stopMic();
      return;
    }
    _micOn = false;
    try {
      await recorder?.stop();
    } on Object {
      // Уже остановлен.
    }
    // Последние куски звука уходят в изолят до «finish»: порт сохраняет
    // порядок сообщений.
    if (done != null) {
      await done.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
    }
    await subscription.cancel();
  }

  void _fail(StreamController<VoiceEvent> controller, VoiceErrorCode code) {
    if (_events != controller || controller.isClosed) return;
    controller.add(VoiceError(code));
    _events = null;
    unawaited(_stopRecorder());
    unawaited(controller.close());
  }

  Future<void> _ensureWorker() {
    if (_toWorker != null) return Future<void>.value();
    return _spawning ??= _spawn().whenComplete(() => _spawning = null);
  }

  Future<void> _spawn() async {
    final port = ReceivePort();
    final ready = Completer<SendPort>();
    port.listen((Object? message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message is List && message.length == 3 && message[0] is int) {
        _onWorker(message[0] as int, message[1], message[2]);
        return;
      }
      // Сообщение onError (список из двух строк) или onExit (null):
      // изолят упал или завершился.
      if (!ready.isCompleted) {
        ready.completeError(
          const VoiceEngineException(VoiceErrorCode.engine),
        );
      }
      _workerDied();
    });
    _fromWorker = port;
    try {
      _isolate = await Isolate.spawn<List<Object?>>(
        _worker,
        <Object?>[port.sendPort, libraryName],
        onError: port.sendPort,
        onExit: port.sendPort,
        debugName: 'voice',
      );
      _toWorker = await ready.future.timeout(const Duration(seconds: 20));
    } on Object {
      _shutdownWorker();
      throw const VoiceEngineException(VoiceErrorCode.engine);
    }
  }

  void _onWorker(int id, Object? kind, Object? payload) {
    if (id < 0) {
      final controller = _events;
      if (controller == null) return;
      if (kind == 'partial' && payload is String) {
        controller.add(VoicePartial(payload));
      } else if (kind == 'engine_error') {
        _fail(controller, VoiceErrorCode.engine);
      }
      return;
    }
    final completer = _pending.remove(id);
    if (completer == null) return;
    if (kind == 'ok') {
      completer.complete(payload);
    } else {
      completer.completeError(
        VoiceEngineException(
          payload == 'model' ? VoiceErrorCode.modelLoad : VoiceErrorCode.engine,
        ),
      );
    }
  }

  void _workerDied() {
    final controller = _events;
    if (controller != null) _fail(controller, VoiceErrorCode.engine);
    _shutdownWorker();
  }

  void _shutdownWorker() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _fromWorker?.close();
    _fromWorker = null;
    _toWorker = null;
    _loadedPath = null;
    final pending = _pending.values.toList();
    _pending.clear();
    for (final completer in pending) {
      completer.completeError(
        const VoiceEngineException(VoiceErrorCode.engine),
      );
    }
  }

  Future<Object?> _request(String kind, [Object? payload]) {
    final port = _toWorker;
    if (port == null) {
      return Future<Object?>.error(
        const VoiceEngineException(VoiceErrorCode.engine),
      );
    }
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    port.send(<Object?>[id, kind, payload]);
    return completer.future;
  }
}

/// Источник звука: PCM 16 бит, [VoskVoiceRecognizer.sampleRate] Гц, моно.
abstract interface class PcmSource {
  /// Проверяет и при необходимости запрашивает доступ к микрофону.
  Future<bool> hasPermission();

  Future<Stream<Uint8List>> start();

  /// Останавливает запись; поток из [start] завершается.
  Future<void> stop();

  Future<void> dispose();
}

/// Микрофон через пакет `record`: только поток в память, без файла.
final class RecordPcmSource implements PcmSource {
  final AudioRecorder _recorder = AudioRecorder();

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> start() => _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: VoskVoiceRecognizer.sampleRate,
          numChannels: 1,
        ),
      );

  @override
  Future<void> stop() async {
    await _recorder.stop();
  }

  @override
  Future<void> dispose() => _recorder.dispose();
}

/// Изолят распознавания: владеет моделью и распознавателем Vosk.
/// Сообщения — `[id, вид, данные]`; ответ — `[id, 'ok' | 'fail', данные]`,
/// промежуточный текст — `[-1, 'partial', текст]`. Ничего не печатает.
void _voskWorker(List<Object?> args) {
  final out = args[0]! as SendPort;
  final vosk = VoskBindings.tryOpen(args[1]! as String);
  vosk?.setLogLevel(-1);
  final inbox = ReceivePort();
  out.send(inbox.sendPort);

  var model = nullptr.cast<Void>();
  var recognizer = nullptr.cast<Void>();
  var buffer = nullptr.cast<Uint8>();
  var capacity = 0;
  final segments = <String>[];
  var shown = '';

  String read(Pointer<Utf8> json, String key) {
    if (json == nullptr) return '';
    try {
      final decoded = jsonDecode(json.toDartString());
      final value = decoded is Map ? decoded[key] : null;
      return value is String ? value.trim() : '';
    } on Object {
      return '';
    }
  }

  String joined(String tail) =>
      <String>[...segments, tail].where((s) => s.isNotEmpty).join(' ');

  void freeRecognizer() {
    if (vosk != null && recognizer != nullptr) vosk.recognizerFree(recognizer);
    recognizer = nullptr.cast<Void>();
  }

  void freeModel() {
    freeRecognizer();
    if (vosk != null && model != nullptr) vosk.modelFree(model);
    model = nullptr.cast<Void>();
  }

  inbox.listen((Object? message) {
    if (message is! List || message.length != 3) return;
    final id = message[0] as int;
    final kind = message[1];
    final payload = message[2];
    void ok([Object? value]) => out.send(<Object?>[id, 'ok', value]);
    void fail(String code) => out.send(<Object?>[id, 'fail', code]);
    try {
      switch (kind) {
        case 'load':
          if (vosk == null) return fail('model');
          freeModel();
          final path = (payload! as String).toNativeUtf8();
          try {
            model = vosk.modelNew(path);
          } finally {
            malloc.free(path);
          }
          if (model == nullptr) return fail('model');
          ok();
        case 'begin':
          if (vosk == null || model == nullptr) return fail('model');
          if (recognizer == nullptr) {
            recognizer = vosk.recognizerNew(
              model,
              VoskVoiceRecognizer.sampleRate.toDouble(),
            );
            if (recognizer == nullptr) return fail('engine');
          } else {
            vosk.reset(recognizer);
          }
          segments.clear();
          shown = '';
          ok();
        case 'audio':
          if (vosk == null || recognizer == nullptr) return;
          final bytes =
              (payload! as TransferableTypedData).materialize().asUint8List();
          if (bytes.isEmpty) return;
          if (bytes.length > capacity) {
            if (buffer != nullptr) malloc.free(buffer);
            buffer = malloc<Uint8>(bytes.length);
            capacity = bytes.length;
          }
          buffer.asTypedList(bytes.length).setAll(0, bytes);
          final status = vosk.acceptWaveform(recognizer, buffer, bytes.length);
          // Звук в буфере больше не нужен.
          buffer.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
          if (status < 0) {
            out.send(<Object?>[-1, 'engine_error', null]);
            return;
          }
          final String next;
          if (status == 1) {
            final text = read(vosk.result(recognizer), 'text');
            if (text.isNotEmpty) segments.add(text);
            next = joined('');
          } else {
            next = joined(read(vosk.partialResult(recognizer), 'partial'));
          }
          if (next != shown) {
            shown = next;
            out.send(<Object?>[-1, 'partial', next]);
          }
        case 'finish':
          if (vosk == null || recognizer == nullptr) return ok('');
          final text = joined(read(vosk.finalResult(recognizer), 'text'));
          vosk.reset(recognizer);
          segments.clear();
          shown = '';
          ok(text);
        case 'reset':
          if (vosk != null && recognizer != nullptr) vosk.reset(recognizer);
          segments.clear();
          shown = '';
          ok();
        case 'unload':
          freeModel();
          segments.clear();
          shown = '';
          ok();
        case 'dispose':
          freeModel();
          if (buffer != nullptr) malloc.free(buffer);
          buffer = nullptr.cast<Uint8>();
          capacity = 0;
          ok();
          inbox.close();
        default:
          if (id >= 0) fail('engine');
      }
    } on Object {
      if (id >= 0) {
        fail('engine');
      } else {
        out.send(<Object?>[-1, 'engine_error', null]);
      }
    }
  });
}
