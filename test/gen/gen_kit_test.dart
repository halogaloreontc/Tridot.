import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/gen/gen_kit.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/gen/gen_model.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:path/path.dart' as p;

import 'gen_fakes.dart';

final class _Transport implements HttpTransport {
  String? body;
  bool offline = false;
  final List<Uri> requests = <Uri>[];

  @override
  Future<HttpResponseData> send(HttpRequestData request) async {
    requests.add(request.uri);
    if (offline) throw const SocketException('нет сети');
    if (request.uri == GenRelease.latestUrl) {
      return const HttpResponseData(
        statusCode: 302,
        headers: <String, String>{
          'location': 'https://release-assets.githubusercontent.com/gen',
        },
      );
    }
    final b = body;
    return b == null
        ? const HttpResponseData(statusCode: 404)
        : HttpResponseData(statusCode: 200, body: b);
  }
}

final class _Model implements GenModel, Closeable {
  _Model(this.path);

  final String path;
  bool closed = false;

  @override
  Future<String> complete({
    required String system,
    required String user,
    String? grammar,
    int maxTokens = 200,
  }) async =>
      '';

  @override
  Future<void> close() async => closed = true;
}

void main() {
  late Directory temp;
  late String root;
  late _Transport transport;
  late PartsDownloader downloader;
  late List<_Model> opened;
  late int? ram;

  GenKit kit({String? dev}) => GenKit(
        transport: transport,
        downloader: downloader,
        root: root,
        opener: (String path) async {
          final m = _Model(path);
          opened.add(m);
          return m;
        },
        ram: () async => ram,
        hasher: (File f) async =>
            crypto.sha256.convert(await f.readAsBytes()).toString(),
        devModel: dev,
      );

  List<String> entries() => Directory(root).existsSync()
      ? (Directory(root).listSync().map((e) => p.basename(e.path)).toList()
        ..sort())
      : <String>[];

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('gen_kit_test');
    root = p.join(temp.path, 'gen');
    transport = _Transport();
    downloader = PartsDownloader();
    opened = <_Model>[];
    ram = 16000;
  });

  tearDown(() => temp.delete(recursive: true));

  List<int> publish(
    String version, {
    int? minRam,
    int? badPart,
    String? wholeSha,
  }) {
    final bytes =
        List<int>.generate(4000, (i) => (i * 13 + version.length) % 256);
    transport.body = publishGen(
      downloader,
      version,
      bytes,
      minRam: minRam,
      badPart: badPart,
      wholeSha: wholeSha,
    );
    return bytes;
  }

  test('скачивание, указатель, модель при первом вопросе', () async {
    final g = kit();
    addTearDown(g.dispose);
    await g.refresh();
    publish('1.0.0');
    await g.apply(const AppSettings(genEnabled: true));
    expect(await g.model(), isNull, reason: 'ещё не скачана');
    await g.install();
    expect(g.phase, GenKitPhase.idle);
    expect(g.installed?.version, '1.0.0');
    expect(entries(), <String>['active.json', 'gen-1.0.0.gguf']);
    final m = await g.model();
    expect(m, isNotNull);
    expect(identical(await g.model(), m), isTrue, reason: 'загружена один раз');
    expect(opened.single.path, p.join(root, 'gen-1.0.0.gguf'));

    final again = kit();
    addTearDown(again.dispose);
    await again.refresh();
    expect(again.installed?.version, '1.0.0');
  });

  test('выключение выгружает модель, файл остаётся', () async {
    final g = kit();
    addTearDown(g.dispose);
    publish('1.0.0');
    await g.apply(const AppSettings(genEnabled: true));
    await g.install();
    await g.model();
    await g.apply(const AppSettings());
    expect(opened.single.closed, isTrue);
    expect(await g.model(), isNull);
    expect(entries(), contains('gen-1.0.0.gguf'));
  });

  test('мало памяти — ничего не скачивается', () async {
    ram = 5800;
    final g = kit();
    addTearDown(g.dispose);
    await g.refresh();
    expect(g.enoughMemory, isFalse);
    publish('1.0.0');
    await g.install();
    expect(g.error, GenKitError.lowMemory);
    expect(downloader.calls, 0);
  });

  test('порог памяти из выпуска', () async {
    ram = 7200;
    final g = kit();
    addTearDown(g.dispose);
    await g.refresh();
    publish('1.0.0', minRam: 7500);
    await g.install();
    expect(g.error, GenKitError.lowMemory);
  });

  test('сумма части не совпала — часть удалена, склеенное начало цело',
      () async {
    final g = kit();
    addTearDown(g.dispose);
    publish('1.0.0', badPart: 2);
    await g.install();
    expect(g.error, GenKitError.checksum);
    expect(g.installed, isNull);
    expect(entries(), <String>['gen-1.0.0.gguf.part']);
    expect(File(p.join(root, 'gen-1.0.0.gguf.part')).lengthSync(), 1500);
  });

  test('сумма целого файла не совпала — всё удалено', () async {
    final g = kit();
    addTearDown(g.dispose);
    publish('1.0.0', wholeSha: 'b' * 64);
    await g.install();
    expect(g.error, GenKitError.checksum);
    expect(entries(), isEmpty);
  });

  test('части склеиваются по порядку, на диске — только модель', () async {
    final g = kit();
    addTearDown(g.dispose);
    final bytes = publish('1.0.0');
    await g.install();
    expect(downloader.calls, 3);
    expect(File(p.join(root, 'gen-1.0.0.gguf')).readAsBytesSync(), bytes);
    expect(entries(), <String>['active.json', 'gen-1.0.0.gguf']);
  });

  test('обрыв — продолжение с места, готовые части не качаются снова',
      () async {
    final g = kit();
    addTearDown(g.dispose);
    final bytes = publish('1.0.0');
    downloader.dropAfter = 4; // часть 1 (3 куска) и кусок части 2
    await g.install();
    expect(g.error, GenKitError.network);
    expect(g.hasPartial, isTrue);
    downloader.dropAfter = null;
    downloader.offsets.clear();
    await g.install();
    expect(
      downloader.offsets,
      <int>[500, 0],
      reason: 'часть 2 — с места, часть 3 — с нуля',
    );
    expect(File(p.join(root, 'gen-1.0.0.gguf')).readAsBytesSync(), bytes);
  });

  test('обновление: новая версия, старая удалена, модель перезагружается',
      () async {
    final g = kit();
    addTearDown(g.dispose);
    publish('1.0.0');
    await g.apply(const AppSettings(genEnabled: true));
    await g.install();
    await g.model();
    publish('1.1.0');
    await g.checkUpdate();
    expect(g.updateAvailable, isTrue);
    await g.install();
    expect(entries(), <String>['active.json', 'gen-1.1.0.gguf']);
    expect(opened.first.closed, isTrue);
    await g.model();
    expect(opened.last.path, endsWith('gen-1.1.0.gguf'));
  });

  test('сеть — только по действию', () async {
    final g = kit();
    addTearDown(g.dispose);
    await g.refresh();
    await g.apply(const AppSettings(genEnabled: true));
    await g.model();
    expect(transport.requests, isEmpty);
  });

  test('чужой адрес и битый latest.json — «недоступна»', () async {
    final g = kit();
    addTearDown(g.dispose);
    transport.body = publishGen(downloader, '1.0.0', <int>[1, 2, 3]).replaceAll(
      GenRelease.latestUrl.host,
      'example.com',
    );
    await g.install();
    expect(g.error, GenKitError.release);
    transport.body = '{"format":"other"}';
    await g.install();
    expect(g.error, GenKitError.release);
    expect(downloader.calls, 0);
  });

  test('«Удалить модель»: файлов нет, модель закрыта', () async {
    final g = kit();
    addTearDown(g.dispose);
    publish('1.0.0');
    await g.apply(const AppSettings(genEnabled: true));
    await g.install();
    await g.model();
    await g.delete();
    expect(entries(), isEmpty);
    expect(opened.single.closed, isTrue);
    expect(g.installed, isNull);
  });

  test('модель для разработки — при любом переключателе', () async {
    final g = kit(dev: '/dev/model.gguf');
    addTearDown(g.dispose);
    expect(await g.model(), isNotNull);
    expect(opened.single.path, '/dev/model.gguf');
  });

  test('настройка gen.enabled сохраняется', () {
    const s = AppSettings(genEnabled: true);
    expect(s.toJson()['gen.enabled'], isTrue);
    expect(AppSettings.fromJson(s.toJson()).genEnabled, isTrue);
    expect(const AppSettings().toJson().containsKey('gen.enabled'), isFalse);
  });
}
