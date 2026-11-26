import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../../core/gen/gen_model.dart';

/// «Продвинутая» (ADR-046) через llama.cpp: обёртка `native/tridot_llama`
/// по dart:ffi в своём изоляте — разбор запроса и генерация не держат поток
/// интерфейса. Запросы идут по одному; общее начало соседних запросов
/// обёртка не пересчитывает.
final class LlamaGenModel implements GenModel {
  LlamaGenModel._(this._isolate, this._requests, this._replies, this._cancel);

  final Isolate _isolate;
  final SendPort _requests;
  final StreamIterator<Object?> _replies;
  final Pointer<Int32> _cancel;
  Future<void> _queue = Future<void>.value();
  bool _closed = false;

  /// Имя библиотеки обёртки на платформе.
  static String get defaultLibrary => switch (Abi.current()) {
        Abi.windowsX64 || Abi.windowsArm64 => 'tridot_llama.dll',
        Abi.macosArm64 || Abi.macosX64 => 'libtridot_llama.dylib',
        _ => 'libtridot_llama.so',
      };

  /// Загрузить модель [modelPath]. Ошибка — [GenModelException].
  static Future<LlamaGenModel> open(
    String modelPath, {
    String? library,
    int contextTokens = 4096,
    int threads = 4,
  }) async {
    final port = ReceivePort();
    final replies = StreamIterator<Object?>(port);
    final cancel = calloc<Int32>();
    final isolate = await Isolate.spawn(
      _main,
      _Start(
        port.sendPort,
        library ?? defaultLibrary,
        modelPath,
        contextTokens,
        threads,
        cancel.address,
      ),
      debugName: 'llama',
    );
    await replies.moveNext();
    final ready = replies.current;
    if (ready is! SendPort) {
      await replies.cancel();
      isolate.kill(priority: Isolate.immediate);
      calloc.free(cancel);
      throw GenModelException('$ready');
    }
    return LlamaGenModel._(isolate, ready, replies, cancel);
  }

  @override
  Future<String> complete({
    required String system,
    required String user,
    String? grammar,
    int maxTokens = 200,
  }) {
    final prompt = '<|im_start|>system\n$system<|im_end|>\n'
        '<|im_start|>user\n$user<|im_end|>\n<|im_start|>assistant\n';
    final done = Completer<String>();
    _queue = _queue.then((_) async {
      if (_closed) {
        done.completeError(const GenModelException('модель закрыта'));
        return;
      }
      _cancel.value = 0;
      _requests.send(_Request(prompt, grammar, maxTokens));
      await _replies.moveNext();
      final reply = _replies.current;
      if (reply is String) {
        done.complete(reply);
      } else {
        done.completeError(GenModelException('$reply'));
      }
    });
    return done.future;
  }

  /// Прервать текущий ответ: [complete] завершится [GenModelException].
  void cancel() => _cancel.value = 1;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    cancel();
    await _queue;
    _requests.send(null);
    await _replies.moveNext();
    await _replies.cancel();
    _isolate.kill();
    calloc.free(_cancel);
  }
}

final class GenModelException implements Exception {
  const GenModelException(this.message);

  final String message;

  @override
  String toString() => 'GenModelException($message)';
}

final class _Start {
  const _Start(
    this.replies,
    this.library,
    this.model,
    this.contextTokens,
    this.threads,
    this.cancel,
  );

  final SendPort replies;
  final String library;
  final String model;
  final int contextTokens;
  final int threads;
  final int cancel;
}

final class _Request {
  const _Request(this.prompt, this.grammar, this.maxTokens);

  final String prompt;
  final String? grammar;
  final int maxTokens;
}

typedef _LoadC = Pointer<Void> Function(Pointer<Utf8>, Int32, Int32);
typedef _Load = Pointer<Void> Function(Pointer<Utf8>, int, int);
typedef _CompleteC = Int32 Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Int32,
  Pointer<Uint8>,
  Int32,
  Pointer<Int32>,
);
typedef _Complete = int Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Int32>,
);
typedef _FreeC = Void Function(Pointer<Void>);
typedef _Free = void Function(Pointer<Void>);

const Map<int, String> _errors = <int, String>{
  -1: 'не удалось разобрать запрос на токены',
  -2: 'запрос длиннее контекста модели',
  -3: 'грамматика не разобралась',
  -4: 'ошибка вычисления модели',
  -5: 'отменено',
};

Future<void> _main(_Start start) async {
  final _Load load;
  final _Complete complete;
  final _Free free;
  try {
    final lib = DynamicLibrary.open(start.library);
    load = lib.lookupFunction<_LoadC, _Load>('tl_load');
    complete = lib.lookupFunction<_CompleteC, _Complete>('tl_complete');
    free = lib.lookupFunction<_FreeC, _Free>('tl_free');
  } on Object catch (e) {
    start.replies.send('нет библиотеки ${start.library}: $e');
    return;
  }
  final path = start.model.toNativeUtf8();
  final ctx = load(path, start.contextTokens, start.threads);
  calloc.free(path);
  if (ctx == nullptr) {
    start.replies.send('модель не загрузилась');
    return;
  }
  final requests = ReceivePort();
  start.replies.send(requests.sendPort);
  const capacity = 64 * 1024;
  final out = calloc<Uint8>(capacity);
  final cancel = Pointer<Int32>.fromAddress(start.cancel);
  await for (final message in requests) {
    if (message is! _Request) break;
    final prompt = message.prompt.toNativeUtf8();
    final grammar = message.grammar?.toNativeUtf8() ?? nullptr;
    final n = complete(
      ctx,
      prompt,
      grammar.cast<Utf8>(),
      message.maxTokens,
      out,
      capacity,
      cancel,
    );
    calloc.free(prompt);
    if (grammar != nullptr) calloc.free(grammar);
    start.replies.send(
      n >= 0
          ? out.cast<Utf8>().toDartString(length: n)
          : _errors[n] ?? 'ошибка $n',
    );
  }
  free(ctx);
  calloc.free(out);
  requests.close();
  start.replies.send(null);
}
