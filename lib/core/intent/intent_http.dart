import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../connectors/http_transport.dart';
import 'intent_fallback.dart';
import 'intent_tokenizer.dart';

/// Ответ на запрос файла пакета: код и байты.
final class BytesResponse {
  const BytesResponse(this.statusCode, this.bytes);

  final int statusCode;
  final Uint8List bytes;
}

/// Файлы пакета модели по адресу склада (ADR-045, шаг 4): `fetch` браузера
/// с `credentials: omit` в веб-помощнике (`fetch_transport.dart`), подделка
/// в тестах. Обрыв связи — исключение, 4xx/5xx — [BytesResponse].
abstract interface class BytesFetcher {
  Future<BytesResponse> fetchBytes(Uri uri, {Duration timeout});
}

/// sha256 в шестнадцатеричном виде, нижний регистр. В браузере — Web
/// Crypto (`intent_web.dart`), иначе [dartSha256].
typedef Sha256Hasher = Future<String> Function(Uint8List bytes);

Future<String> dartSha256(Uint8List bytes) async =>
    crypto.sha256.convert(bytes).toString();

/// Среда выполнения модели из байтов `model.int8.onnx`: onnxruntime-web в
/// веб-помощнике, подделка в тестах.
typedef IntentRuntimeFactory = Future<IntentRuntime> Function(
  Uint8List model,
  IntentManifest manifest,
);

/// Указатель `assistant/intent/web/current.json` на складе: какая версия
/// пакета рабочая и в какой папке рядом она лежит.
///
/// ```json
/// {"format": "tridot-intent-current/1", "tier": "web", "version": "1.0.0",
///  "dir": "1.0.0-6dc650b6", "manifest_sha256": "…"}
/// ```
///
/// Папки версий после распаковки не меняются (кэш навсегда), указатель
/// склад пишет через временный файл — смена версии атомарна.
final class IntentPointer {
  const IntentPointer({
    required this.version,
    required this.dir,
    this.manifestSha256,
  });

  static const String format = 'tridot-intent-current/1';

  final String version;

  /// Имя папки версии рядом с указателем: `1.0.0-6dc650b6`.
  final String dir;

  /// sha256 `manifest.json` этой версии; `null` — склад не указал.
  final String? manifestSha256;

  static final RegExp _dir = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');
  static final RegExp _version = RegExp(r'^\d{1,4}\.\d{1,4}\.\d{1,4}$');
  static final RegExp _sha = RegExp(r'^[0-9a-f]{64}$');

  /// Указатель из [text] или `null`, если это не он (страница вместо
  /// файла, чужой формат, не тот уровень, опасное имя папки).
  static IntentPointer? parse(String text, {String tier = 'web'}) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (json is! Map<String, Object?>) return null;
    final version = json['version'];
    final dir = json['dir'];
    final sha = json['manifest_sha256'];
    if (json['format'] != format ||
        json['tier'] != tier ||
        version is! String ||
        !_version.hasMatch(version) ||
        dir is! String ||
        !_dir.hasMatch(dir) ||
        dir.contains('..') ||
        (sha != null && (sha is! String || !_sha.hasMatch(sha)))) {
      return null;
    }
    return IntentPointer(
      version: version,
      dir: dir,
      manifestSha256: sha as String?,
    );
  }
}

/// Пакет модели понимания на складе, со своего адреса веб-помощника
/// (ADR-045, шаг 4): `<адрес склада>/assistant/intent/web/current.json` →
/// папка версии `assistant/intent/web/<dir>/` с файлами пакета
/// (`manifest.json`, `model.int8.onnx`, `tokenizer.json`, `index.bin`,
/// `labels.json`, …). Нет указателя (404, старый склад) — модели нет.
///
/// Каждый файл сверяется с манифестом целиком — размер и sha256 (и
/// модель): сервер склада тоже может отдать не то. Уровень — только `web`,
/// версия манифеста — та, что в указателе. Адрес — только тот же, что у
/// склада.
final class HttpPackSource implements IntentPackSource {
  HttpPackSource._({
    required this.dir,
    required this.pointer,
    required this.manifest,
    required Uint8List manifestBytes,
    required BytesFetcher fetcher,
    required Sha256Hasher hasher,
  })  : _manifestBytes = manifestBytes,
        _fetcher = fetcher,
        _hasher = hasher;

  /// Папка уровня `web` от адреса склада.
  static const String webPath = 'assistant/intent/web/';
  static const String pointerFile = 'current.json';

  /// Сколько ждать один файл (модель — 29 МБ).
  static const Duration fileTimeout = Duration(minutes: 3);

  /// Больше этого пакет не бывает: склад отдаёт что-то не то.
  static const int maxFileBytes = 96 * 1024 * 1024;

  /// Адрес указателя для склада [base] (`https://sklad.example/`).
  static Uri pointerUri(Uri base) => base.resolve('$webPath$pointerFile');

  /// Папка версии.
  final Uri dir;
  final IntentPointer pointer;
  final IntentManifest manifest;
  final Uint8List _manifestBytes;
  final BytesFetcher _fetcher;
  final Sha256Hasher _hasher;

  /// Пакет склада [base] или `null`, если склад модель не ставил (404,
  /// не указатель). Битый или чужой пакет — [IntentPackException].
  /// Указатель читается без кэша ([transport]), файлы — [fetcher].
  static Future<HttpPackSource?> open({
    required Uri base,
    required HttpTransport transport,
    required BytesFetcher fetcher,
    Sha256Hasher hasher = dartSha256,
    String tier = 'web',
  }) async {
    final pointerAt = pointerUri(base);
    final response = await transport.send(
      HttpRequestData(
        method: 'GET',
        uri: pointerAt,
        headers: const <String, String>{
          'Accept': 'application/json',
          'Cache-Control': 'no-cache',
        },
      ),
    );
    if (!response.isSuccess) return null;
    final pointer = IntentPointer.parse(response.body, tier: tier);
    if (pointer == null) return null;
    final dir = pointerAt.resolve('${pointer.dir}/');
    if (!_sameOrigin(dir, base)) {
      throw const IntentPackException('пакет не на адресе склада');
    }
    final bytes = await _get(fetcher, dir.resolve(IntentManifest.manifestFile));
    if (pointer.manifestSha256 case final String expected
        when await hasher(bytes) != expected) {
      throw const IntentPackException('manifest.json: не та sha256');
    }
    final IntentManifest manifest;
    try {
      manifest = IntentManifest.parse(utf8.decode(bytes));
    } on FormatException {
      throw const IntentPackException('manifest.json: не UTF-8');
    }
    if (manifest.tier != tier) {
      throw IntentPackException(
        'manifest.json: уровень ${manifest.tier}, нужен $tier',
      );
    }
    if (manifest.version != pointer.version) {
      throw IntentPackException(
        'manifest.json: версия ${manifest.version}, '
        'в указателе ${pointer.version}',
      );
    }
    return HttpPackSource._(
      dir: dir,
      pointer: pointer,
      manifest: manifest,
      manifestBytes: bytes,
      fetcher: fetcher,
      hasher: hasher,
    );
  }

  @override
  Future<Uint8List> read(String name) async {
    if (name == IntentManifest.manifestFile) return _manifestBytes;
    final expected = manifest.files[name];
    if (expected == null) throw IntentPackException('$name нет в манифесте');
    final bytes = await _get(_fetcher, dir.resolve(name));
    if (bytes.length != expected.size) {
      throw IntentPackException(
        '$name: ${bytes.length} байт, в манифесте ${expected.size}',
      );
    }
    if (await _hasher(bytes) != expected.sha256) {
      throw IntentPackException('$name: не та sha256');
    }
    return bytes;
  }

  static Future<Uint8List> _get(BytesFetcher fetcher, Uri uri) async {
    final BytesResponse response;
    try {
      response = await fetcher.fetchBytes(uri, timeout: fileTimeout);
    } on Object catch (error) {
      throw IntentPackException('${_name(uri)}: $error');
    }
    if (response.statusCode != 200) {
      throw IntentPackException(
        '${_name(uri)}: склад ответил ${response.statusCode}',
      );
    }
    if (response.bytes.length > maxFileBytes) {
      throw IntentPackException('${_name(uri)}: слишком большой');
    }
    return response.bytes;
  }

  static String _name(Uri uri) =>
      uri.pathSegments.isEmpty ? '$uri' : uri.pathSegments.last;

  static bool _sameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;
}

/// Модель из пакета [source]: индекс и токенизатор проверены по манифесту,
/// модель отдаётся среде [runtime] байтами. Ошибка —
/// [IntentPackException] или ошибка среды.
Future<IntentModel> loadIntentModel(
  IntentPackSource source,
  IntentManifest manifest,
  IntentRuntimeFactory runtime,
) async {
  final index = await IntentPack.readIndex(source, manifest);
  final IntentTokenizer tokenizer =
      await IntentPack.readTokenizer(source, manifest);
  final model = await source.read(IntentManifest.modelFile);
  final engine = await runtime(model, manifest);
  return IntentModel(
    manifest: manifest,
    index: index,
    encoder: TokenizedEncoder(
      tokenizer: tokenizer,
      runtime: engine,
      manifest: manifest,
    ),
  );
}
