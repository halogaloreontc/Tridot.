import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:onnxruntime_v2/onnxruntime_v2.dart';

import '../../core/intent/intent_encoder.dart';
import '../../core/intent/intent_io.dart';
import '../../core/intent/intent_pack.dart';
import '../../core/intent/intent_tokenizer.dart';

/// Кодировщик модели понимания в приложении (ADR-045): ONNX Runtime через
/// dart:ffi (`onnxruntime_v2`) в отдельном изоляте — модель, токенизатор и
/// прогон не держат поток интерфейса. Android, macOS, Windows, Linux; в
/// веб-помощник не попадает (там onnxruntime-web, шаг 4).
///
/// Изолят открывает пакет сам ([DirectoryPackSource]): токенизатор
/// сверяется с манифестом, модель — по размеру (sha256 — при установке).
final class OnnxIntentEncoder implements IntentEncoder {
  OnnxIntentEncoder._(
    this.manifest,
    this._isolate,
    this._requests,
    this._replies,
  );

  /// Открывает пакет в папке [dir] с манифестом [manifest]. [threads] —
  /// потоков ONNX Runtime на прогон.
  static Future<OnnxIntentEncoder> open(
    String dir,
    IntentManifest manifest, {
    int threads = 2,
  }) async {
    final replies = ReceivePort();
    final isolate = await Isolate.spawn<_Start>(
      _main,
      _Start(replies.sendPort, dir, threads),
      debugName: 'intent-encoder',
      errorsAreFatal: false,
    );
    final stream = replies.asBroadcastStream();
    final first = await stream.first;
    if (first is! SendPort) {
      replies.close();
      isolate.kill(priority: Isolate.immediate);
      throw IntentPackException('$first');
    }
    return OnnxIntentEncoder._(manifest, isolate, first, stream)
      .._listen(replies);
  }

  final IntentManifest manifest;
  final Isolate _isolate;
  final SendPort _requests;
  final Stream<Object?> _replies;
  final Map<int, Completer<List<Float32List>>> _waiting =
      <int, Completer<List<Float32List>>>{};
  ReceivePort? _port;
  int _next = 0;
  bool _closed = false;

  void _listen(ReceivePort port) {
    _port = port;
    _replies.listen((Object? message) {
      if (message case (final int id, final Object? body)) {
        final done = _waiting.remove(id);
        if (done == null) return;
        if (body case (final TransferableTypedData data, final int rows)) {
          final flat = data.materialize().asFloat32List();
          done.complete(<Float32List>[
            for (var row = 0; row < rows; row++)
              Float32List.sublistView(flat, row * dims, (row + 1) * dims),
          ]);
        } else {
          done.completeError(IntentPackException('$body'));
        }
      }
    });
  }

  @override
  int get dims => manifest.dims;

  @override
  Future<List<Float32List>> embed(List<String> texts) {
    if (_closed) {
      return Future<List<Float32List>>.error(
        const IntentPackException('модель закрыта'),
      );
    }
    if (texts.isEmpty) return Future<List<Float32List>>.value(const []);
    final id = _next++;
    final done = Completer<List<Float32List>>();
    _waiting[id] = done;
    _requests.send((id, texts));
    return done.future;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _requests.send(null);
    for (final done in _waiting.values) {
      done.completeError(const IntentPackException('модель закрыта'));
    }
    _waiting.clear();
    _port?.close();
    _isolate.kill();
  }
}

final class _Start {
  const _Start(this.replies, this.dir, this.threads);

  final SendPort replies;
  final String dir;
  final int threads;
}

/// Изолят модели: открыть пакет, отвечать на `(id, фразы)` векторами.
Future<void> _main(_Start start) async {
  final TokenizedEncoder encoder;
  final _OrtRuntime runtime;
  try {
    final source = DirectoryPackSource(start.dir);
    final manifest = await IntentPack.readManifest(source);
    final tokenizer = await IntentPack.readTokenizer(source, manifest);
    final model = source.file(IntentManifest.modelFile);
    final expected = manifest.files[IntentManifest.modelFile]!;
    if (await model.length() != expected.size) {
      throw const IntentPackException('model.int8.onnx: не тот размер');
    }
    runtime = _OrtRuntime.open(model, manifest.output, start.threads);
    encoder = TokenizedEncoder(
      tokenizer: tokenizer,
      runtime: runtime,
      manifest: manifest,
    );
  } on Object catch (error) {
    start.replies.send('модель не открылась: $error');
    return;
  }
  final requests = ReceivePort();
  start.replies.send(requests.sendPort);
  await for (final message in requests) {
    if (message case (final int id, final List<String> texts)) {
      try {
        final vectors = await encoder.embed(texts);
        final flat = Float32List(vectors.length * encoder.dims);
        for (final (row, vector) in vectors.indexed) {
          flat.setAll(row * encoder.dims, vector);
        }
        start.replies.send(
          (
            id,
            (TransferableTypedData.fromList(<TypedData>[flat]), vectors.length),
          ),
        );
      } on Object catch (error) {
        start.replies.send((id, 'сбой модели: $error'));
      }
    } else {
      requests.close();
    }
  }
  await runtime.close();
}

/// [IntentRuntime] на ONNX Runtime: входы int64 `[rows, length]`, выход —
/// векторы `[rows, dims]`.
final class _OrtRuntime implements IntentRuntime {
  _OrtRuntime(this._session, this._options, this.output);

  factory _OrtRuntime.open(File model, String output, int threads) {
    OrtEnv.instance.init();
    final options = OrtSessionOptions()
      ..setIntraOpNumThreads(threads)
      ..setInterOpNumThreads(1)
      ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);
    return _OrtRuntime(OrtSession.fromFile(model, options), options, output);
  }

  final OrtSession _session;
  final OrtSessionOptions _options;
  final String output;

  @override
  Future<Float32List> run(TokenBatch batch, List<String> inputs) async {
    final shape = <int>[batch.rows, batch.length];
    final values = <String, OrtValue>{
      for (final name in inputs)
        name: OrtValueTensor.createTensorWithDataList(
          Int64List.fromList(batch.input(name)),
          shape,
        ),
    };
    final runOptions = OrtRunOptions();
    List<OrtValue?> outputs = const <OrtValue?>[];
    try {
      outputs = _session.run(runOptions, values, <String>[output]);
      final flat = <double>[];
      void collect(Object? value) {
        if (value is num) {
          flat.add(value.toDouble());
        } else if (value is List) {
          value.forEach(collect);
        }
      }

      collect(outputs.first?.value);
      return Float32List.fromList(flat);
    } finally {
      for (final value in values.values) {
        value.release();
      }
      for (final value in outputs) {
        value?.release();
      }
      runOptions.release();
    }
  }

  @override
  Future<void> close() async {
    await _session.release();
    _options.release();
    OrtEnv.instance.release();
  }
}
