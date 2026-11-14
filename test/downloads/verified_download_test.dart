import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/downloads/verified_download.dart';
import 'package:path/path.dart' as p;

/// Сервер на 127.0.0.1, который отдаёт [body] и умеет (или нет) `Range`.
final class _Server {
  _Server(this.body);

  Uint8List body;
  bool honorRange = true;

  /// Заявить больший Content-Length, чем есть.
  int? lieLength;

  /// Отдать больше байт, чем [body] (без Content-Length).
  int extraBytes = 0;

  /// Оборвать ответ после стольких байт.
  int? cutAfter;

  /// Задержка между кусками.
  Duration? slow;

  /// Переадресация: путь → куда.
  final Map<String, String> redirects = <String, String>{};

  final List<String?> ranges = <String?>[];
  late HttpServer _server;

  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}/model.zip');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final redirect = redirects[request.uri.path];
    if (redirect != null) {
      response
        ..statusCode = HttpStatus.found
        ..headers.set(HttpHeaders.locationHeader, redirect);
      await response.close();
      return;
    }
    final range = request.headers.value(HttpHeaders.rangeHeader);
    ranges.add(range);
    var start = 0;
    final match =
        range == null ? null : RegExp(r'bytes=(\d+)-').firstMatch(range);
    if (honorRange && match != null) {
      start = int.parse(match.group(1)!);
      response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(
          'content-range',
          'bytes $start-${body.length - 1}/${body.length}',
        );
    }
    var data = Uint8List.sublistView(body, start);
    if (extraBytes > 0) {
      data = Uint8List.fromList(
        <int>[...data, ...List<int>.filled(extraBytes, 1)],
      );
    } else {
      response.contentLength = lieLength ?? data.length;
    }
    final cut = cutAfter;
    if (cut != null && cut < data.length) {
      // Длина заявлена полная, а байт меньше — связь «обрывается».
      response.add(Uint8List.sublistView(data, 0, cut));
      try {
        // Байт меньше заявленного: сервер закрывает соединение.
        await response.close();
      } on Object {
        // Ожидаемо: «Content size below specified contentLength».
      }
      return;
    }
    const step = 1000;
    for (var i = 0; i < data.length; i += step) {
      response.add(
        Uint8List.sublistView(data, i, (i + step).clamp(0, data.length)),
      );
      if (slow != null) {
        await response.flush();
        await Future<void>.delayed(slow!);
      }
    }
    try {
      await response.close();
    } on Object {
      // Клиент ушёл.
    }
  }
}

Uint8List _bytes(int n) =>
    Uint8List.fromList(List<int>.generate(n, (i) => (i * 7 + 3) & 0xff));

void main() {
  late Directory temp;
  late File part;
  late _Server server;
  final downloader = IoFileDownloader(allowLoopbackHttp: true);

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('download_test');
    part = File(p.join(temp.path, 'model.zip.part'));
    server = _Server(_bytes(300000));
    await server.start();
  });

  tearDown(() async {
    await server.close();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<List<DownloadProgress>> run({CancelToken? cancel, int? expected}) =>
      downloader
          .download(
            server.uri,
            part,
            expectedBytes: expected ?? server.body.length,
            cancel: cancel ?? CancelToken(),
          )
          .toList();

  Matcher failsWith(DownloadError error) => throwsA(
        isA<DownloadException>().having((e) => e.error, 'error', error),
      );

  test('скачивает файл целиком и сообщает о ходе', () async {
    final progress = await run();
    expect(part.readAsBytesSync(), server.body);
    expect(progress.first, DownloadProgress(0, server.body.length));
    expect(
      progress.last,
      DownloadProgress(server.body.length, server.body.length),
    );
    expect(server.ranges, <String?>[null]);
  });

  test('продолжает с места остановки через Range и 206', () async {
    part.writeAsBytesSync(Uint8List.sublistView(server.body, 0, 120000));
    final progress = await run();
    expect(server.ranges, <String?>['bytes=120000-']);
    expect(part.readAsBytesSync(), server.body);
    expect(progress.first.received, 120000);
  });

  test('сервер не умеет Range (200): файл начинается заново', () async {
    server.honorRange = false;
    part.writeAsBytesSync(List<int>.filled(5000, 9));
    await run();
    expect(part.readAsBytesSync(), server.body);
  });

  test('уже скачанный файл не скачивается снова', () async {
    part.writeAsBytesSync(server.body);
    final progress = await run();
    expect(server.ranges, isEmpty);
    expect(progress, <DownloadProgress>[
      DownloadProgress(server.body.length, server.body.length),
    ]);
  });

  test('Content-Length больше ожидаемого — tooLarge, ничего не пишется',
      () async {
    await expectLater(run(expected: 1000), failsWith(DownloadError.tooLarge));
    expect(part.existsSync(), isFalse);
  });

  test('тело больше ожидаемого без Content-Length — обрыв и удаление',
      () async {
    server.extraBytes = 5000;
    await expectLater(run(), failsWith(DownloadError.tooLarge));
    expect(part.existsSync(), isFalse);
  });

  test('обрыв связи — network, скачанное остаётся для продолжения', () async {
    server.cutAfter = 100000;
    await expectLater(run(), failsWith(DownloadError.network));
    final kept = part.lengthSync();
    expect(kept, greaterThan(0));
    expect(kept, lessThan(server.body.length));
    server.cutAfter = null;
    await run();
    expect(server.ranges.last, 'bytes=$kept-');
    expect(part.readAsBytesSync(), server.body);
  });

  test('отмена закрывает загрузку и оставляет .part', () async {
    server.slow = const Duration(milliseconds: 5);
    final cancel = CancelToken();
    final stream = downloader.download(
      server.uri,
      part,
      expectedBytes: server.body.length,
      cancel: cancel,
    );
    final done = expectLater(
      stream,
      emitsThrough(
        emitsError(
          isA<DownloadException>().having(
            (e) => e.error,
            'error',
            DownloadError.cancelled,
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    cancel.cancel();
    await done;
    expect(part.existsSync(), isTrue);
    expect(part.lengthSync(), lessThan(server.body.length));
  });

  test('отменённая заранее загрузка не начинается', () async {
    final cancel = CancelToken()..cancel();
    await expectLater(
      run(cancel: cancel),
      failsWith(DownloadError.cancelled),
    );
    expect(server.ranges, isEmpty);
  });

  test('http без разрешения и не https — отказ', () async {
    final strict = IoFileDownloader();
    await expectLater(
      strict
          .download(
            server.uri,
            part,
            expectedBytes: server.body.length,
            cancel: CancelToken(),
          )
          .toList(),
      failsWith(DownloadError.network),
    );
    expect(server.ranges, isEmpty);
  });

  test('переадресация на http (не https) — отказ', () async {
    server.redirects['/model.zip'] = 'http://example.com/model.zip';
    await expectLater(run(), failsWith(DownloadError.network));
  });

  test('переадресация на другой сайт — отказ, запрос туда не уходит', () async {
    // Второй сервер слушает все адреса: без запрета 127.0.0.2 дошёл бы до
    // него и скачал файл.
    final other = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    var otherRequests = 0;
    other.listen((HttpRequest request) async {
      otherRequests++;
      request.response.add(server.body);
      await request.response.close();
    });
    addTearDown(() => other.close(force: true));
    server.redirects['/model.zip'] = 'http://127.0.0.2:${other.port}/model.zip';
    await expectLater(run(), failsWith(DownloadError.network));
    expect(otherRequests, 0);
  });

  test('переадресация в пределах сайта — разрешена', () async {
    server.redirects['/model.zip'] = '/mirror/model.zip';
    final progress = await run();
    expect(progress.last.received, server.body.length);
    expect(part.readAsBytesSync(), server.body);
  });

  test('ошибка диска — storage, а не «проверьте интернет»', () async {
    // На месте папки для .part — файл: записать некуда, как без места.
    final blocker = File(p.join(temp.path, 'blocker'))..writeAsStringSync('x');
    final blocked = File(p.join(blocker.path, 'model.zip.part'));
    await expectLater(
      downloader
          .download(
            server.uri,
            blocked,
            expectedBytes: server.body.length,
            cancel: CancelToken(),
          )
          .toList(),
      failsWith(DownloadError.storage),
    );
  });

  test('цепочка переадресаций длиннее трёх — отказ', () async {
    server.redirects['/model.zip'] = '/r1';
    server.redirects['/r1'] = '/r2';
    server.redirects['/r2'] = '/r3';
    server.redirects['/r3'] = '/r4';
    await expectLater(run(), failsWith(DownloadError.network));
  });

  test('sha256OfFile совпадает с известной суммой', () async {
    final file = File(p.join(temp.path, 'abc.txt'))..writeAsStringSync('abc');
    expect(
      await sha256OfFile(file),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    final big = File(p.join(temp.path, 'big.bin'))
      ..writeAsBytesSync(server.body);
    expect(
      await sha256OfFile(big),
      crypto.sha256.convert(server.body).toString(),
    );
  });
}
