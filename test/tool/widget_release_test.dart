import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/widget_release/release.dart' as release;
import '../../tool/widget_release/release_core.dart';

/// Выпуск веб-помощника (ADR-032): состав архива, описание, подписи.
/// Ключ — одноразовый, создаётся здесь же и стирается после тестов.
void main() {
  late Directory temp;
  late String keyFile;
  var openssl = false;

  setUpAll(() async {
    temp = Directory.systemTemp.createTempSync('svz-release-test-');
    keyFile = '${temp.path}/throwaway.pem';
    try {
      final r = await Process.run(
        'openssl',
        <String>['genpkey', '-algorithm', 'ed25519', '-out', keyFile],
      );
      openssl = r.exitCode == 0;
    } on ProcessException {
      openssl = false;
    }
  });

  tearDownAll(() => temp.deleteSync(recursive: true));

  Map<String, List<int>> sample() => <String, List<int>>{
        'index.html': utf8.encode('<!doctype html><title>Связной</title>'),
        'main.dart.js': utf8.encode('console.log(1)'),
        'canvaskit/canvaskit.wasm': <int>[0, 97, 115, 109],
        'assets/FontManifest.json': utf8.encode('[]'),
      };

  group('имена файлов — как проверяет склад', () {
    test('годятся', () {
      for (final ok in <String>[
        'index.html',
        'canvaskit/chromium/canvaskit.wasm',
        'assets/assets/fonts/GolosText-Variable.ttf',
        'assets/shaders/ink_sparkle.frag',
        'LICENSES.txt',
      ]) {
        expect(checkEntryName(ok), isNull, reason: ok);
      }
    });

    test('не годятся', () {
      for (final bad in <String>[
        '../evil.js',
        'a/../b.js',
        '/abs.js',
        r'win\path.js',
        '.htaccess',
        'assets/.hidden/x.js',
        'api.php',
        'shell.sh',
        'assets/NOTICES',
        'x\u0000.js',
        'пробел файла.js',
      ]) {
        expect(checkEntryName(bad), isNotNull, reason: bad);
      }
    });
  });

  test('что убирается из сборки', () {
    expect(isPruned('canvaskit/skwasm.wasm'), isTrue);
    expect(isPruned('canvaskit/canvaskit.js.symbols'), isTrue);
    expect(isPruned('canvaskit/webparagraph/canvaskit.wasm'), isTrue);
    expect(isPruned('canvaskit/chromium/canvaskit.wasm'), isFalse);
    expect(isPruned('canvaskit/canvaskit.wasm'), isFalse);
    expect(isPruned('assets/assets/passwords/eff_large_wordlist.txt'), isTrue);
    expect(isPruned('assets/assets/fonts/JetBrainsMonoVariable.ttf'), isTrue);
    expect(isPruned('assets/assets/fonts/GolosText-Variable.ttf'), isFalse);
    expect(
      isPruned('assets/assets/connectors/depotdesk.assistant.json'),
      isFalse,
    );
    expect(isPruned('flutter_service_worker.js'), isTrue);
    expect(isPruned('.last_build_id'), isTrue);
    expect(isPruned('main.dart.js'), isFalse);
  });

  test('FontManifest — без убранных шрифтов', () {
    const source = '[{"family":"Golos Text","fonts":[{"asset":'
        '"assets/fonts/GolosText-Variable.ttf"}]},{"family":"JetBrains Mono",'
        '"fonts":[{"asset":"assets/fonts/JetBrainsMonoVariable.ttf"}]}]';
    final out = jsonDecode(
      pruneFontManifest(
        source,
        <String>{'assets/assets/fonts/GolosText-Variable.ttf'},
      ),
    ) as List<Object?>;
    expect(out, hasLength(1));
    expect((out.single! as Map<String, Object?>)['family'], 'Golos Text');
  });

  test('сборка из папки: NOTICES → LICENSES.txt, лишнее убрано', () {
    final web = Directory('${temp.path}/web')..createSync();
    void put(String path, String text) =>
        (File('${web.path}/$path')..createSync(recursive: true))
            .writeAsStringSync(text);
    put('index.html', '<html></html>');
    put('.last_build_id', 'x');
    put('assets/NOTICES', 'licenses');
    put('canvaskit/skwasm.js', 'x');
    put('assets/FontManifest.json', '[]');
    final files = collectBuild(web);
    expect(
      files.keys.toSet(),
      <String>{'index.html', 'LICENSES.txt', 'assets/FontManifest.json'},
    );
  });

  test('--skip-build: только сборка с той же версией', () {
    final web = Directory('${temp.path}/stamp')..createSync();
    File('${web.path}/index.html').writeAsStringSync('<html></html>');
    expect(checkBuildStamp(web, '1.0.0'), contains('нет $buildStampName'));
    writeBuildStamp(web, '1.0.0');
    expect(checkBuildStamp(web, '1.0.0'), isNull);
    expect(checkBuildStamp(web, '1.0.1'), contains('собрана как 1.0.0'));
    // Отметка в архив не попадает.
    expect(collectBuild(web).keys, <String>['index.html']);
  });

  test('_release.json: файлы по алфавиту с sha256 и общий размер', () {
    final bytes = releaseJson(
      version: '1.2.3',
      files: sample(),
      notes: 'Что нового',
    );
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    expect(json['product'], 'svyaznoy-web');
    expect(json['version'], '1.2.3');
    expect(json['minApi'], defaultMinApi);
    expect(json['minServer'], defaultMinServer);
    final files = json['files']! as Map<String, Object?>;
    expect(files.keys.toList(), (files.keys.toList()..sort()));
    expect(files['main.dart.js'], sha256Hex(utf8.encode('console.log(1)')));
    expect(
      json['total'],
      sample().values.fold<int>(0, (int s, List<int> b) => s + b.length),
    );
    expect(json.containsKey('pubkey'), isFalse);
  });

  test('ключ выпуска — подсказка складу в _release.json и latest.json', () {
    const pub = '11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=';
    final manifest = jsonDecode(
      utf8.decode(
        releaseJson(version: '1.2.3', files: sample(), publicKey: pub),
      ),
    ) as Map<String, Object?>;
    expect(manifest['pubkey'], pub);
    final latest = jsonDecode(
      latestJson(
        version: '1.2.3',
        url: 'svyaznoy-web-1.2.3.zip',
        size: 1,
        sha256: 'ab',
        signature: 'c2ln',
        publicKey: pub,
      ),
    ) as Map<String, Object?>;
    expect(latest['pubkey'], pub);
    // Подписью latest.json ключ не покрыт: склад ему не верит.
    expect(
      utf8.decode(
        latestSigningBytes(version: '1.2.3', sha256: 'ab', size: 1, minApi: 1),
      ),
      isNot(contains(pub)),
    );
  });

  test('строки подписи — как на складе', () {
    expect(
      utf8.decode(
        latestSigningBytes(version: '1.0.0', sha256: 'ab', size: 7, minApi: 1),
      ),
      'SVYAZNOY-WEB-LATEST-V1\n1.0.0\nab\n7\n1',
    );
    expect(
      utf8.decode(releaseSigningBytes(utf8.encode('{}'))),
      'SVYAZNOY-WEB-RELEASE-V1\n{}',
    );
  });

  test('отпечаток ключа издателя — как на складе и в GitHub Actions', () {
    // Открытый ключ из RFC 8032, тест 1: тот же пример у складов.
    final pub = base64.decode('11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=');
    expect(publisherFingerprint(pub), '21fe 31df a154 a261');
    expect(() => publisherFingerprint(pub.sublist(1)), throwsArgumentError);
  });

  test('сборке Flutter ключ подписи и ключи бакета не передаются', () {
    final env = buildEnvironment(<String, String>{
      'PATH': '/usr/bin',
      'HOME': '/home/u',
      'SVYAZNOY_SIGN_KEY': '-----BEGIN PRIVATE KEY-----',
      'SVYAZNOY_SIGN_KEY_FILE': '/keys/k.pem',
      'AWS_ACCESS_KEY_ID': 'id',
      'AWS_SECRET_ACCESS_KEY': 'secret',
      'SVYAZNOY_BUCKET': 'svyaznoy-web',
    });
    expect(env, <String, String>{
      'PATH': '/usr/bin',
      'HOME': '/home/u',
      'SVYAZNOY_BUCKET': 'svyaznoy-web',
    });
  });

  test('ключ из секрета GitHub: переносы, одна строка, буквальные \\n',
      () async {
    if (!openssl) {
      markTestSkipped('нет OpenSSL 3 с Ed25519');
      return;
    }
    final pem = File(keyFile).readAsStringSync();
    expect(normalizePrivateKeyPem(pem), pem);
    final body = pem
        .replaceAll('-----BEGIN PRIVATE KEY-----', '')
        .replaceAll('-----END PRIVATE KEY-----', '')
        .trim();
    for (final pasted in <String>[
      pem.replaceAll('\n', '\r\n'),
      pem.trim(),
      '  ${pem.replaceAll('\n', ' ')}  ',
      pem.replaceAll('\n', r'\n'),
      '-----BEGIN PRIVATE KEY-----$body-----END PRIVATE KEY-----',
    ]) {
      expect(normalizePrivateKeyPem(pasted), pem, reason: pasted);
    }
    // Из записанного так ключа OpenSSL берёт тот же открытый ключ.
    final again = File('${temp.path}/normalized.pem')
      ..writeAsStringSync(normalizePrivateKeyPem(pem.replaceAll('\n', ' '))!);
    expect(
      await release.publicKeyBase64(again.path),
      await release.publicKeyBase64(keyFile),
    );
    for (final bad in <String>[
      '',
      body,
      '-----BEGIN PUBLIC KEY-----\n$body\n-----END PUBLIC KEY-----',
      '-----BEGIN ENCRYPTED PRIVATE KEY-----\n$body\n'
          '-----END ENCRYPTED PRIVATE KEY-----',
      '-----BEGIN PRIVATE KEY-----\n*не base64*\n-----END PRIVATE KEY-----',
    ]) {
      expect(normalizePrivateKeyPem(bad), isNull, reason: bad);
    }
  });

  test('версия и неподходящий состав — отказ до подписи', () async {
    var signed = false;
    Future<Uint8List> sign(Uint8List m) async {
      signed = true;
      return Uint8List(64);
    }

    await expectLater(
      buildReleaseZip(version: '1.0', files: sample(), sign: sign),
      throwsArgumentError,
    );
    await expectLater(
      buildReleaseZip(
        version: '1.0.0',
        files: <String, List<int>>{
          ...sample(),
          '../x.js': <int>[1],
        },
        sign: sign,
      ),
      throwsFormatException,
    );
    await expectLater(
      buildReleaseZip(
        version: '1.0.0',
        files: <String, List<int>>{
          'main.dart.js': <int>[1],
        },
        sign: sign,
      ),
      throwsFormatException,
      reason: 'без index.html',
    );
    expect(signed, isFalse);
  });

  test('подпись Ed25519 одноразовым ключом: архив и latest.json', () async {
    if (!openssl) {
      markTestSkipped('нет OpenSSL 3 с Ed25519');
      return;
    }
    final pub = base64.decode(await release.publicKeyBase64(keyFile));
    expect(pub, hasLength(32));
    final zip = await buildReleaseZip(
      version: '1.0.0',
      files: sample(),
      notes: 'Проба',
      sign: (Uint8List m) => release.signEd25519(keyFile, m),
    );
    // Одинаковая сборка — одинаковый архив.
    final again = await buildReleaseZip(
      version: '1.0.0',
      files: sample(),
      notes: 'Проба',
      sign: (Uint8List m) => release.signEd25519(keyFile, m),
    );
    expect(sha256Hex(again), sha256Hex(zip));

    final archive = ZipDecoder().decodeBytes(zip);
    expect(
      archive.files.map((ArchiveFile f) => f.name),
      containsAll(<String>[releaseJsonName, releaseSigName, 'index.html']),
    );
    final manifest = archive.findFile(releaseJsonName)!.content;
    final sig =
        base64.decode(utf8.decode(archive.findFile(releaseSigName)!.content));
    expect(sig, hasLength(64));
    expect(
      await release.verifyEd25519(pub, releaseSigningBytes(manifest), sig),
      isTrue,
    );
    // Подменённый файл описания — подпись не сходится.
    final tampered = Uint8List.fromList(manifest)..[10] ^= 1;
    expect(
      await release.verifyEd25519(pub, releaseSigningBytes(tampered), sig),
      isFalse,
    );

    final latestSig = await release.signEd25519(
      keyFile,
      latestSigningBytes(
        version: '1.0.0',
        sha256: sha256Hex(zip),
        size: zip.length,
        minApi: 1,
      ),
    );
    final latest = jsonDecode(
      latestJson(
        version: '1.0.0',
        url: 'svyaznoy-web-1.0.0.zip',
        size: zip.length,
        sha256: sha256Hex(zip),
        signature: base64.encode(latestSig),
      ),
    ) as Map<String, Object?>;
    expect(
      latest.keys,
      containsAll(<String>[
        'version',
        'minApi',
        'minServer',
        'url',
        'size',
        'sha256',
        'notes',
        'sig',
      ]),
    );
    expect(
      await release.verifyEd25519(
        pub,
        latestSigningBytes(
          version: '1.0.0',
          sha256: sha256Hex(zip),
          size: zip.length + 1,
          minApi: 1,
        ),
        latestSig,
      ),
      isFalse,
      reason: 'другой размер — другая подпись',
    );
  });

  test('проверка подписи PHP sodium — как на складе', () async {
    if (!openssl) {
      markTestSkipped('нет OpenSSL 3 с Ed25519');
      return;
    }
    ProcessResult probe;
    try {
      probe = await Process.run('php', <String>[
        '-r',
        'echo function_exists("sodium_crypto_sign_verify_detached") ? 1 : 0;',
      ]);
    } on ProcessException {
      markTestSkipped('нет php');
      return;
    }
    if (probe.stdout != '1') {
      markTestSkipped('нет php-sodium');
      return;
    }
    final pub = await release.publicKeyBase64(keyFile);
    final message = latestSigningBytes(
      version: '1.0.0',
      sha256: 'a' * 64,
      size: 123,
      minApi: 1,
    );
    final sig = await release.signEd25519(keyFile, message);
    final php = await Process.run('php', <String>[
      '-r',
      r'echo sodium_crypto_sign_verify_detached(base64_decode($argv[1]), '
          r'base64_decode($argv[2]), base64_decode($argv[3])) ? "ok" : "bad";',
      base64.encode(sig),
      base64.encode(message),
      pub,
    ]);
    expect(php.stdout, 'ok');
  });
}
