import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/intent/intent_fallback.dart';
import 'package:local_assistant/core/intent/intent_http.dart';

import '../web_widget/intent_fakes.dart';

/// Указатель склада: `assistant/intent/web/current.json`.
final class FakePointer implements HttpTransport {
  FakePointer(this.response);

  HttpResponseData response;
  final List<HttpRequestData> requests = <HttpRequestData>[];

  @override
  Future<HttpResponseData> send(HttpRequestData request) async {
    requests.add(request);
    return response;
  }
}

/// Пакет модели понимания со склада (ADR-045, шаг 4): указатель, манифест,
/// sha256 каждого файла, уровень `web`, адрес склада.
void main() {
  final base = Uri.parse('https://warehouse.example/');
  late FakePackServer server;
  late Map<String, Uint8List> files;
  late Uint8List manifest;

  setUp(() {
    server = FakePackServer();
    files = webPackFiles();
    manifest = webManifest(files);
    server.serve(<String, Uint8List>{...files, 'manifest.json': manifest});
  });

  Future<HttpPackSource?> open(String? pointer, {int status = 200}) =>
      HttpPackSource.open(
        base: base,
        transport: FakePointer(
          HttpResponseData(statusCode: status, body: pointer ?? ''),
        ),
        fetcher: server,
      );

  test('указатель → папка версии: манифест и файлы сверены', () async {
    final transport = FakePointer(
      HttpResponseData(
        statusCode: 200,
        body: webPointer(manifest: manifest),
      ),
    );
    final source = await HttpPackSource.open(
      base: base,
      transport: transport,
      fetcher: server,
    );
    expect(source, isNotNull);
    expect(
      transport.requests.single.uri.toString(),
      'https://warehouse.example/assistant/intent/web/current.json',
    );
    expect(transport.requests.single.headers['Cache-Control'], 'no-cache');
    expect(source!.manifest.tier, 'web');
    expect(source.manifest.modelKey, 'web@1.0.0');
    expect(
      source.dir.toString(),
      'https://warehouse.example/assistant/intent/web/1.0.0-6dc650b6/',
    );
    expect(await source.read('model.int8.onnx'), files['model.int8.onnx']);
    expect(await source.read('manifest.json'), manifest);
    // Склад в подпапке: путь — от его адреса.
    final sub = FakePackServer()
      ..serve(
        <String, Uint8List>{...files, 'manifest.json': manifest},
        base: 'https://host.example/sklad/',
      );
    final nested = await HttpPackSource.open(
      base: Uri.parse('https://host.example/sklad/'),
      transport: FakePointer(
        HttpResponseData(statusCode: 200, body: webPointer()),
      ),
      fetcher: sub,
    );
    expect(nested!.dir.path, '/sklad/assistant/intent/web/1.0.0-6dc650b6/');
  });

  test(
      'нет указателя (404, старый склад, страница вместо файла) — нет '
      'модели', () async {
    expect(await open(null, status: 404), isNull);
    expect(await open('<!doctype html><html></html>'), isNull);
    expect(await open('{"version": "1.0.0"}'), isNull);
    // Чужой уровень, опасная папка, не та версия в указателе — тоже нет.
    expect(await open(webPointer(tier: 'light')), isNull);
    expect(await open(webPointer(dir: '../../data')), isNull);
    expect(await open(webPointer(dir: '.hidden')), isNull);
    expect(await open(webPointer(version: 'latest')), isNull);
    expect(server.requests, isEmpty);
  });

  test('подменённый файл — отказ по sha256, и модель тоже', () async {
    final source = (await open(webPointer()))!;
    final model = Uint8List.fromList(files['model.int8.onnx']!);
    model[10] ^= 1;
    server.files[source.dir.resolve('model.int8.onnx').toString()] = model;
    await expectLater(
      source.read('model.int8.onnx'),
      throwsA(
        isA<IntentPackException>()
            .having((e) => e.message, 'message', contains('sha256')),
      ),
    );
    // Не тот размер.
    server.files[source.dir.resolve('index.bin').toString()] =
        Uint8List.fromList(<int>[...files['index.bin']!, 0]);
    await expectLater(
      source.read('index.bin'),
      throwsA(isA<IntentPackException>()),
    );
    // Файла нет в манифесте — не читается вовсе.
    await expectLater(
      source.read('../config.php'),
      throwsA(isA<IntentPackException>()),
    );
  });

  test('уровень манифеста не web, версия не та, сумма манифеста — отказ',
      () async {
    final light = webManifest(files, tier: 'light');
    server.serve(<String, Uint8List>{...files, 'manifest.json': light});
    await expectLater(
      open(webPointer()),
      throwsA(
        isA<IntentPackException>()
            .having((e) => e.message, 'message', contains('уровень light')),
      ),
    );
    server.serve(<String, Uint8List>{
      ...files,
      'manifest.json': webManifest(files, version: '1.0.1'),
    });
    await expectLater(open(webPointer()), throwsA(isA<IntentPackException>()));
    server.serve(<String, Uint8List>{...files, 'manifest.json': manifest});
    await expectLater(
      open(webPointer(manifest: utf8.encode('другой'))),
      throwsA(isA<IntentPackException>()),
    );
    // Указатель есть, а папки нет — ошибка, не «нет модели».
    await expectLater(
      open(webPointer(dir: '9.9.9-00000000')),
      throwsA(isA<IntentPackException>()),
    );
  });

  test('модель из пакета: индекс, токенизатор, байты модели — среде', () async {
    final source = (await open(webPointer()))!;
    final runtime = FakeWebRuntime(<String, Float32List>{
      'что там пришло': webVector(<String, double>{
        'warehouse:warehouse.today': 1,
      }),
    });
    final model = await loadIntentModel(source, source.manifest, runtime.open);
    expect(runtime.model, files['model.int8.onnx']);
    expect(model.index.dims, webDims);
    expect(model.manifest.connectors, <String>['warehouse', 'calc', 'talk']);
    final fallback = IntentFallback(model: model);
    final suggestion = await fallback.suggest('что там пришло');
    expect(suggestion?.first.id, 'warehouse:warehouse.today');
  });
}
