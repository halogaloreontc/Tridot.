import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../core/intent/intent_fallback.dart';
import '../core/intent/intent_http.dart';
import '../core/intent/intent_tokenizer.dart';

// Модель понимания в браузере (ADR-045, шаг 4): onnxruntime-web через
// dart:js_interop. Только для сборки веб-помощника (`main.dart`): тесты на
// VM и приложение этот файл не импортируют (test/web_widget/web_graph_test).
//
// onnxruntime-web лежит в самой сборке помощника, `ort/` рядом с
// index.html (`tool/widget_release/ort_web.dart` — версия и sha256): CSP
// помощника пускает скрипты и WASM только со своего адреса. Модуль
// подгружается только когда склад поставил модель и она нужна — запуск
// помощника он не замедляет. Один поток WASM: COOP/COEP не нужны.

/// Модуль onnxruntime-web в сборке помощника.
const String ortModulePath = 'ort/ort.wasm.bundle.min.mjs';

extension type _Ort(JSObject _) implements JSObject {
  external _Env get env;
  @JS('InferenceSession')
  external _SessionFactory get inferenceSession;
  @JS('Tensor')
  external JSFunction get tensor;
}

extension type _Env(JSObject _) implements JSObject {
  external _WasmEnv get wasm;
}

extension type _WasmEnv(JSObject _) implements JSObject {
  external set numThreads(int value);
  external set proxy(bool value);
}

extension type _SessionFactory(JSObject _) implements JSObject {
  external JSPromise<_Session> create(JSUint8Array model, JSObject options);
}

extension type _Session(JSObject _) implements JSObject {
  external JSPromise<JSObject> run(JSObject feeds);
  external JSPromise<JSAny?> release();
}

extension type _Tensor(JSObject _) implements JSObject {
  external JSAny get data;
  external void dispose();
}

@JS('BigInt64Array')
extension type _BigInt64Array._(JSObject _) implements JSObject {
  external factory _BigInt64Array(int length);
  external JSArrayBuffer get buffer;
}

Future<_Ort>? _module;

/// Модуль onnxruntime-web: один на страницу, загружается при первой
/// модели. Не загрузился — следующая попытка загрузит заново.
Future<_Ort> _loadOrt() => _module ??= () async {
      try {
        final url = Uri.base.resolve(ortModulePath).toString();
        final module = _Ort(await importModule(url.toJS).toDart);
        module.env.wasm
          ..numThreads = 1
          ..proxy = false;
        return module;
      } on Object {
        _module = null;
        rethrow;
      }
    }();

/// [IntentRuntime] на onnxruntime-web (WASM): одна сессия модели в потоке
/// страницы; прогон фразы — миллисекунды.
final class OrtWebRuntime implements IntentRuntime {
  OrtWebRuntime._(this._ort, this._session, this._output);

  final _Ort _ort;
  final _Session _session;
  final String _output;
  bool _closed = false;

  /// Загрузить модуль onnxruntime-web заранее: нет его в сборке — модель
  /// не скачивается.
  static Future<void> prepare() => _loadOrt();

  /// [IntentRuntimeFactory] для [WidgetIntent].
  static Future<IntentRuntime> open(
    Uint8List model,
    IntentManifest manifest,
  ) async {
    final ort = await _loadOrt();
    final options = JSObject()
      ..['executionProviders'] = <JSString>['wasm'.toJS].toJS
      ..['graphOptimizationLevel'] = 'all'.toJS;
    final session =
        await ort.inferenceSession.create(model.toJS, options).toDart;
    return OrtWebRuntime._(ort, session, manifest.output);
  }

  @override
  Future<Float32List> run(TokenBatch batch, List<String> inputs) async {
    if (_closed) throw StateError('модель закрыта');
    final dims = <JSNumber>[batch.rows.toJS, batch.length.toJS].toJS;
    final feeds = JSObject();
    final tensors = <_Tensor>[];
    for (final name in inputs) {
      final tensor = _Tensor(
        _ort.tensor.callAsConstructor<JSObject>(
          'int64'.toJS,
          _int64(batch.input(name)),
          dims,
        ),
      );
      tensors.add(tensor);
      feeds[name] = tensor;
    }
    try {
      final result = await _session.run(feeds).toDart;
      final out = _Tensor(result[_output]! as JSObject);
      final data = (out.data as JSFloat32Array).toDart;
      // Копия: память тензора освобождается ниже.
      final copy = Float32List.fromList(data);
      out.dispose();
      return copy;
    } finally {
      for (final tensor in tensors) {
        tensor.dispose();
      }
    }
  }

  /// `BigInt64Array` из номеров токенов: младшие и старшие 32 бита
  /// little-endian, как в памяти WASM.
  static JSObject _int64(Int32List values) {
    final array = _BigInt64Array(values.length);
    final words = array.buffer.toDart.asInt32List();
    for (var i = 0; i < values.length; i++) {
      words[i * 2] = values[i];
      words[i * 2 + 1] = values[i] < 0 ? -1 : 0;
    }
    return array;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _session.release().toDart;
    } on Object {
      // Страница всё равно её освободит.
    }
  }
}

/// sha256 через Web Crypto (быстро и для 30 МБ модели). Нет `crypto.subtle`
/// (страница не по https) — [dartSha256].
Future<String> webSha256(Uint8List bytes) async {
  try {
    final digest = await web.window.crypto.subtle
        .digest('SHA-256'.toJS, bytes.toJS)
        .toDart;
    final out = (digest! as JSArrayBuffer).toDart.asUint8List();
    final hex = StringBuffer();
    for (final byte in out) {
      hex.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return hex.toString();
  } on Object {
    return dartSha256(bytes);
  }
}

/// Скачать [text] файлом [name] (журнал «Непонятые фразы»): ссылка с
/// `download` на `blob:` этой страницы. Фрейм помощника без `sandbox` —
/// браузер сохраняет файл как обычно.
void downloadText(String name, String text) {
  final blob = web.Blob(
    <JSAny>[text.toJS].toJS,
    web.BlobPropertyBag(type: 'application/x-ndjson;charset=utf-8'),
  );
  final url = web.URL.createObjectURL(blob);
  final link = web.HTMLAnchorElement()
    ..href = url
    ..download = name
    ..style.display = 'none';
  web.document.body?.append(link);
  link.click();
  link.remove();
  Timer(const Duration(seconds: 30), () => web.URL.revokeObjectURL(url));
}
