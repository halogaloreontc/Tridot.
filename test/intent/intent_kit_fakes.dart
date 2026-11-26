import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:local_assistant/app/intent/intent_kit.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/downloads/safe_zip.dart';
import 'package:local_assistant/core/intent/intent_fallback.dart';
import 'package:local_assistant/core/intent/intent_io.dart';

import '../support/fake_voice.dart';
import 'fake_intent.dart';

/// Модель «на устройстве» для [IntentKit]: запоминает загрузки и
/// выгрузки; загруженная — поддельная модель с метками [fakeLabels].
final class FakeIntentHost implements IntentModelHost {
  FakeIntentHost({IntentMemory? memory})
      : fallback = IntentFallback(
          memory: memory ??
              IntentMemory(store: InMemoryIntentMemoryStore(), blocks: null),
        );

  @override
  final IntentFallback fallback;

  @override
  String? devPack;

  final List<String> loads = <String>[];
  int unloads = 0;

  /// `false` — модель «не запустилась».
  bool loadResult = true;

  @override
  Future<bool> load(String dir) async {
    loads.add(dir);
    if (!loadResult) return false;
    fallback.model = fakeModel(FakeEncoder(const {}));
    return true;
  }

  @override
  Future<void> unload() async {
    unloads++;
    fallback.model = null;
  }
}

/// `latest.json` и переадресации GitHub: ответы по адресу.
final class FakeReleaseTransport implements HttpTransport {
  final Map<String, HttpResponseData> responses = <String, HttpResponseData>{};
  final List<Uri> requests = <Uri>[];

  /// Обрыв связи вместо ответа.
  bool offline = false;

  void latest(String body) {
    responses[IntentRelease.latestUrl.toString()] = const HttpResponseData(
      statusCode: 302,
      headers: <String, String>{
        'location': 'https://release-assets.githubusercontent.com/latest',
      },
    );
    responses['https://release-assets.githubusercontent.com/latest'] =
        HttpResponseData(statusCode: 200, body: body);
  }

  @override
  Future<HttpResponseData> send(HttpRequestData request) async {
    requests.add(request.uri);
    if (offline) throw const SocketException('нет сети');
    return responses[request.uri.toString()] ??
        const HttpResponseData(statusCode: 404);
  }
}

/// Крошечный синтетический пакет: файлы, `manifest.json` с их суммами.
/// [corrupt] — имя файла, который в архиве не совпадёт с манифестом.
List<int> fakePackZip({
  String tier = 'accurate',
  String version = '1.0.0',
  String? corrupt,
  String? manifestTier,
}) {
  final files = <String, List<int>>{
    'model.int8.onnx': List<int>.generate(3000, (int i) => (i * 7) % 256),
    'index.bin': utf8.encode('индекс $tier $version'),
    'labels.json': utf8.encode(fakeLabelsJson()),
    'tokenizer.json': utf8.encode('{"model": "тест"}'),
  };
  final manifest = <String, Object?>{
    'format': IntentManifest.format,
    'tier': manifestTier ?? tier,
    'title': tier == 'web' ? 'Веб-помощник' : 'Лёгкая',
    'version': version,
    'threshold': 0.9,
    'k': 5,
    'dims': fakeDims,
    'max_length': 64,
    'inputs': <String>['input_ids', 'attention_mask'],
    'output': 'embedding',
    'files': <String, Object?>{
      for (final MapEntry(:key, :value) in files.entries)
        key: <String, Object?>{
          'size': value.length,
          'sha256': crypto.sha256.convert(value).toString(),
        },
    },
  };
  if (corrupt != null) {
    final bytes = List<int>.of(files[corrupt]!);
    bytes[0] = (bytes[0] + 1) % 256;
    files[corrupt] = bytes;
  }
  final archive = Archive();
  for (final MapEntry(:key, :value) in files.entries) {
    archive.add(ArchiveFile(key, value.length, value));
  }
  archive.add(ArchiveFile.string('manifest.json', jsonEncode(manifest)));
  return ZipEncoder().encode(archive);
}

String fakeArchiveUrl(String tier, String version) =>
    '${IntentRelease.allowedPrefix}intent-latest/'
    'tridot-intent-$tier-$version.zip';

/// `latest.json` с архивами [zips] (уровень → байты); [sha] — подменить
/// сумму.
String fakeLatestJson(
  String version,
  Map<String, List<int>> zips, {
  String? sha,
}) =>
    jsonEncode(<String, Object?>{
      'format': IntentRelease.format,
      'version': version,
      'tiers': <String, Object?>{
        for (final MapEntry(:key, :value) in zips.entries)
          key: <String, Object?>{
            'url': fakeArchiveUrl(key, version),
            'file': 'tridot-intent-$key-$version.zip',
            'size': value.length,
            'sha256': sha ?? crypto.sha256.convert(value).toString(),
            'title': key == 'web' ? 'Веб-помощник' : 'Лёгкая',
            'threshold': 0.9,
          },
      },
    });

/// [IntentKit] без изолятов: сумма, распаковка и проверка — в текущем
/// (для `testWidgets` вместе с `runAsync`).
IntentKit fakeIntentKit({
  required FakeIntentHost host,
  required FakeReleaseTransport transport,
  required FakeFileDownloader downloader,
  required String root,
}) =>
    IntentKit(
      host: host,
      transport: transport,
      downloader: downloader,
      root: root,
      hasher: (File file) async =>
          crypto.sha256.convert(await file.readAsBytes()).toString(),
      extractor: (
        File zip,
        Directory dest, {
        required ZipLimits limits,
        String? stripRoot,
      }) async =>
          extractZipSafelySync(
        zip.path,
        dest.path,
        limits: limits,
        stripRoot: stripRoot,
      ),
      verifier: verifyPackDirectory,
    );
