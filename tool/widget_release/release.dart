// Выпуск веб-помощника «Связной» для складов (ADR-032, docs/WEB_WIDGET.md).
//
//   dart run tool/widget_release/release.dart build --version 1.0.0 \
//       --notes "Первая версия"
//   dart run tool/widget_release/release.dart web --version 1.0.0
//   dart run tool/widget_release/release.dart pubkey
//   dart run tool/widget_release/release.dart ort [--tgz архив.tgz]
//   dart run tool/widget_release/release.dart fingerprint [<base64>]
//   dart run tool/widget_release/release.dart verify \
//       build/widget_release/1.0.0/latest.json --pubkey <base64>
//
// Закрытый ключ подписи — только у владельца: путь к файлу PEM в
// SVYAZNOY_SIGN_KEY_FILE или сам текст PEM в SVYAZNOY_SIGN_KEY (так его
// передаёт выпуск в GitHub Actions — из секрета). В репозиторий он не
// попадает и в вывод не печатается. Подписывает OpenSSL 3
// (`openssl pkeyutl -sign -rawin`, Ed25519). Сборке Flutter ключ не
// передаётся: `flutter build web` идёт без SVYAZNOY_SIGN_KEY* в окружении
// ([buildEnvironment]); выпуск в GitHub Actions собирает (`web`) в шаге без
// ключа, а подписывает (`build --skip-build`) заранее собранным
// инструментом — без `dart run` и хуков сборки пакетов рядом с ключом.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'release_core.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first == '-h' || args.first == '--help') {
    stdout.writeln(_usage);
    return;
  }
  try {
    switch (args.first) {
      case 'build':
        await _build(_options(args.skip(1)));
      case 'web':
        await _web(_options(args.skip(1)));
      case 'pubkey':
        stdout.writeln(await withSigningKey(publicKeyBase64));
      case 'ort':
        await ensureOrtWeb(_options(args.skip(1))['tgz']);
      case 'fingerprint':
        await _fingerprint(args.skip(1).toList());
      case 'verify':
        await _verify(args.skip(1).toList());
      default:
        stderr.writeln(_usage);
        exitCode = 64;
    }
  } on _Fail catch (error) {
    stderr.writeln('Ошибка: ${error.message}');
    exitCode = 1;
  }
}

const String _usage = '''
Выпуск веб-помощника «Связной».

  build   --version 1.0.0 [--notes "…" | --notes-file файл]
          [--min-api 1] [--min-server depotdesk=1.4.63,halowarekeep=1.4.67]
          [--url адрес-архива] [--out build/widget_release] [--skip-build]
  web     --version 1.0.0
          только flutter build web (ключ не нужен); потом build --skip-build
  pubkey  открытый ключ (base64, 32 байта) для склада
  ort     [--tgz onnxruntime-web-$ortWebVersion.tgz]
          onnxruntime-web в web/ort/ (модель понимания, ADR-045): скачать
          из npm и проверить sha512 архива и sha256 файлов; build и web
          делают это сами
  fingerprint [<base64>]
          отпечаток открытого ключа, как на складе: «21fe 31df a154 a261»;
          без аргумента — ключа подписи
  verify  путь/к/latest.json --pubkey <base64>

Ключ: SVYAZNOY_SIGN_KEY_FILE=путь/к/svyaznoy-sign.pem
  или SVYAZNOY_SIGN_KEY="-----BEGIN PRIVATE KEY-----…".
Подробно: tool/widget_release/README.md.''';

final class _Fail implements Exception {
  const _Fail(this.message);
  final String message;
}

Map<String, String> _options(Iterable<String> args) {
  final out = <String, String>{};
  final list = args.toList();
  for (var i = 0; i < list.length; i++) {
    final arg = list[i];
    if (!arg.startsWith('--')) throw _Fail('Непонятный аргумент: $arg');
    final name = arg.substring(2);
    if (name == 'skip-build') {
      out[name] = 'yes';
      continue;
    }
    if (i + 1 >= list.length) throw _Fail('Нет значения у $arg');
    out[name] = list[++i];
  }
  return out;
}

Map<String, String> parseMinServer(String text) {
  final out = <String, String>{};
  for (final part in text.split(',')) {
    final pair = part.split('=');
    if (pair.length != 2 ||
        !RegExp(r'^[a-z]{1,32}$').hasMatch(pair[0].trim()) ||
        !isReleaseVersion(pair[1].trim())) {
      throw _Fail('--min-server: нужно вида depotdesk=1.4.63');
    }
    out[pair[0].trim()] = pair[1].trim();
  }
  return out;
}

/// Открытый ключ из base64: ровно 32 байта.
List<int> _publicKey(String text) {
  try {
    final bytes = base64.decode(text.trim());
    if (bytes.length == 32) return bytes;
  } on FormatException {
    // Ниже — общий отказ.
  }
  throw const _Fail('Открытый ключ — 44 знака base64 (32 байта)');
}

String _fingerprintOrEmpty(String b64) {
  try {
    return publisherFingerprint(_publicKey(b64));
  } on _Fail {
    return '';
  }
}

Future<void> _fingerprint(List<String> args) async {
  if (args.length > 1) throw const _Fail('fingerprint [<base64>]');
  final pub = args.isEmpty ? await withSigningKey(publicKeyBase64) : args[0];
  stdout.writeln(publisherFingerprint(_publicKey(pub)));
}

Future<void> _build(Map<String, String> options) async {
  final version = options['version'] ?? '';
  if (!isReleaseVersion(version)) {
    throw const _Fail('--version: нужно вида 1.0.0');
  }
  var notes = options['notes'] ?? '';
  if (options['notes-file'] case final String path) {
    notes = File(path).readAsStringSync().trim();
  }
  if (notes.length > 2000) throw const _Fail('Что нового — не длиннее 2000');
  final minApi = int.tryParse(options['min-api'] ?? '$defaultMinApi');
  if (minApi == null || minApi < 1) throw const _Fail('--min-api: число');
  final minServer = options['min-server'] == null
      ? defaultMinServer
      : parseMinServer(options['min-server']!);
  final outDir =
      Directory('${options['out'] ?? 'build/widget_release'}/$version');
  final zipName = 'svyaznoy-web-$version.zip';
  final url = options['url'] ?? zipName;
  if (!url.startsWith('https://') &&
      !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(url)) {
    throw const _Fail('--url: https://… или имя файла рядом с latest.json');
  }
  // Ключ проверяем до сборки: без него выпуск всё равно не подписать.
  await withSigningKey((String _) async => '');

  if (options['skip-build'] == null) await _flutterBuild(version);
  final web = Directory('build/web');
  if (!web.existsSync()) throw const _Fail('Нет build/web — соберите заново');
  if (checkBuildStamp(web, version) case final String why) throw _Fail(why);
  final files = collectBuild(web);
  final ort = checkOrtWeb(files);
  if (ort.isNotEmpty) {
    throw _Fail(
      'onnxruntime-web в сборке не тот: ${ort.join('; ')} — соберите '
      'без --skip-build',
    );
  }
  final total = files.values.fold<int>(0, (int s, List<int> b) => s + b.length);
  stdout.writeln(
    'Файлов: ${files.length}, ${(total / 1048576).toStringAsFixed(1)} МБ',
  );

  final pub = await withSigningKey(publicKeyBase64);
  final zip = await withSigningKey(
    (String key) => buildReleaseZip(
      version: version,
      files: files,
      notes: notes,
      minApi: minApi,
      minServer: minServer,
      publicKey: pub,
      sign: (Uint8List message) => signEd25519(key, message),
    ),
  );
  final hash = sha256Hex(zip);
  final latestSig = await withSigningKey(
    (String key) => signEd25519(
      key,
      latestSigningBytes(
        version: version,
        sha256: hash,
        size: zip.length,
        minApi: minApi,
      ),
    ),
  );
  outDir.createSync(recursive: true);
  File('${outDir.path}/$zipName').writeAsBytesSync(zip, flush: true);
  File('${outDir.path}/latest.json').writeAsStringSync(
    '${latestJson(version: version, url: url, size: zip.length, sha256: hash, signature: base64.encode(latestSig), notes: notes, minApi: minApi, minServer: minServer, publicKey: pub)}\n',
    flush: true,
  );
  stdout
    ..writeln('Готово: ${outDir.path}/$zipName (${zip.length} байт)')
    ..writeln('sha256: $hash')
    ..writeln('Ключ издателя: ${publisherFingerprint(base64.decode(pub))}')
    ..writeln('Дальше: tool/widget_release/upload.sh ${outDir.path}')
    ..writeln('или загрузите архив вручную: Инструменты → Помощник → '
        '«Загрузить архив…».');
}

/// `web`: только сборка, без ключа — в GitHub Actions это отдельный шаг без
/// секрета; подпись потом — `build --skip-build`.
Future<void> _web(Map<String, String> options) async {
  final version = options['version'] ?? '';
  if (!isReleaseVersion(version)) {
    throw const _Fail('--version: нужно вида 1.0.0');
  }
  if (options.keys.any((String k) => k != 'version')) {
    throw const _Fail('web: только --version');
  }
  await _flutterBuild(version);
  stdout.writeln(
    'Собрано: build/web ($version). Подпись: build --version $version '
    '--skip-build',
  );
}

/// `flutter build web` с версией в `main.dart.js` и меткой сборки. Окружение —
/// без ключа подписи ([buildEnvironment]): сборка запускает чужой код
/// (хуки пакетов, плагины), ему ключ ни к чему.
Future<void> _flutterBuild(String version) async {
  await ensureOrtWeb();
  stdout.writeln('Сборка: flutter build web …');
  final build = await Process.start(
    'flutter',
    <String>[
      'build',
      'web',
      '--release',
      '-t',
      'lib/web_widget/main.dart',
      '--no-web-resources-cdn',
      '--no-source-maps',
      '--no-wasm-dry-run',
      '--dart-define=SVYAZNOY_WEB_VERSION=$version',
    ],
    environment: buildEnvironment(Platform.environment),
    includeParentEnvironment: false,
    mode: ProcessStartMode.inheritStdio,
    runInShell: Platform.isWindows,
  );
  if (await build.exitCode != 0) throw const _Fail('flutter build web упал');
  writeBuildStamp(Directory('build/web'), version);
}

/// onnxruntime-web в `web/ort/` ([ortWebFiles]): уже на месте и те же
/// sha256 — ничего не делает; иначе архив пакета npm — из [tgz] или
/// скачивается — проверяется ([extractOrtWeb]) и раскладывается.
Future<void> ensureOrtWeb([String? tgz]) async {
  bool present() => ortWebFiles.entries.every((e) {
        final file = File('web/${e.key}');
        return file.existsSync() &&
            sha256Hex(file.readAsBytesSync()) == e.value.$2;
      });
  if (tgz == null && present()) return;
  final List<int> bytes;
  if (tgz != null) {
    bytes = File(tgz).readAsBytesSync();
  } else {
    stdout.writeln('onnxruntime-web $ortWebVersion: $ortWebTarball');
    bytes = await _download(Uri.parse(ortWebTarball));
  }
  final Map<String, Uint8List> files;
  try {
    files = extractOrtWeb(bytes);
  } on FormatException catch (error) {
    throw _Fail('onnxruntime-web: ${error.message}');
  }
  for (final MapEntry(:key, :value) in files.entries) {
    final file = File('web/$key');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(value, flush: true);
  }
  stdout.writeln('onnxruntime-web $ortWebVersion — в web/ort/');
}

Future<List<int>> _download(Uri uri) async {
  final client = HttpClient()
    ..findProxy = HttpClient.findProxyFromEnvironment
    ..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    if (response.statusCode != 200) {
      throw _Fail('$uri: ответ ${response.statusCode}');
    }
    final out = BytesBuilder(copy: false);
    await for (final chunk in response) {
      out.add(chunk);
      if (out.length > 64 * 1024 * 1024) throw _Fail('$uri: слишком большой');
    }
    return out.takeBytes();
  } on SocketException catch (error) {
    throw _Fail('$uri: ${error.message}');
  } finally {
    client.close(force: true);
  }
}

/// Проверка выпуска открытым ключом — как это делает склад (через
/// OpenSSL вместо libsodium).
Future<void> _verify(List<String> args) async {
  if (args.length != 3 || args[1] != '--pubkey') {
    throw const _Fail('verify путь/к/latest.json --pubkey <base64>');
  }
  final latestFile = File(args[0]);
  final latest =
      jsonDecode(latestFile.readAsStringSync()) as Map<String, Object?>;
  final pub = _publicKey(args[2]);
  // Ключ выпуска из latest.json — только подсказка, чтобы показать оба
  // отпечатка, если подпись не сойдётся.
  final hint = switch (latest['pubkey']) {
    final String b64 => _fingerprintOrEmpty(b64),
    _ => '',
  };
  final which = hint.isEmpty || hint == publisherFingerprint(pub)
      ? ''
      : ' (проверяемый ключ ${publisherFingerprint(pub)}, '
          'ключ выпуска $hint)';
  final url = latest['url']! as String;
  if (url.startsWith('https://')) {
    throw const _Fail('Проверяется только архив рядом с latest.json');
  }
  final zip = File('${latestFile.parent.path}/$url').readAsBytesSync();
  if (zip.length != latest['size'] || sha256Hex(zip) != latest['sha256']) {
    throw const _Fail('Размер или sha256 архива не сходятся');
  }
  final latestOk = await verifyEd25519(
    pub,
    latestSigningBytes(
      version: latest['version']! as String,
      sha256: latest['sha256']! as String,
      size: latest['size']! as int,
      minApi: latest['minApi']! as int,
    ),
    base64.decode(latest['sig']! as String),
  );
  if (!latestOk) throw _Fail('Подпись latest.json не сошлась$which');
  final archive = ZipDecoder().decodeBytes(zip);
  final manifest = archive.findFile(releaseJsonName)!.content;
  final sig =
      base64.decode(utf8.decode(archive.findFile(releaseSigName)!.content));
  if (!await verifyEd25519(pub, releaseSigningBytes(manifest), sig)) {
    throw _Fail('Подпись _release.json не сошлась$which');
  }
  final release = jsonDecode(utf8.decode(manifest)) as Map<String, Object?>;
  final listed = (release['files']! as Map).cast<String, String>();
  for (final file in archive.files) {
    if (file.name == releaseJsonName || file.name == releaseSigName) continue;
    if (listed[file.name] != sha256Hex(file.content)) {
      throw _Fail('Файл не из описания или изменён: ${file.name}');
    }
  }
  stdout.writeln(
    'Выпуск ${release['version']} проверен: подписи и sha256 сходятся. '
    'Ключ издателя: ${publisherFingerprint(pub)}.',
  );
}

// ------------------------------------------------------------- ключ

/// Путь к PEM закрытого ключа на время [use]: из SVYAZNOY_SIGN_KEY_FILE,
/// иначе текст SVYAZNOY_SIGN_KEY ([normalizePrivateKeyPem]: вставленный
/// в секрет GitHub как получилось) пишется во временный файл 0600 и потом
/// стирается.
Future<T> withSigningKey<T>(Future<T> Function(String keyFile) use) async {
  final env = Platform.environment;
  final path = env['SVYAZNOY_SIGN_KEY_FILE'];
  if (path != null && path.isNotEmpty) {
    if (!File(path).existsSync()) {
      throw const _Fail('SVYAZNOY_SIGN_KEY_FILE: файла нет');
    }
    return use(path);
  }
  final raw = env['SVYAZNOY_SIGN_KEY'];
  if (raw == null || raw.trim().isEmpty) {
    throw const _Fail(
      'Нет ключа подписи: задайте SVYAZNOY_SIGN_KEY_FILE (путь к PEM) или '
      'SVYAZNOY_SIGN_KEY (текст PEM). Создать: на складе «Инструменты → '
      'Помощник → Ключ издателя → Создать ключ» или openssl genpkey '
      '-algorithm ed25519 -out svyaznoy-sign.pem',
    );
  }
  final text = normalizePrivateKeyPem(raw);
  if (text == null) {
    throw const _Fail(
      'SVYAZNOY_SIGN_KEY: нужен весь текст ключа вместе со строками '
      '-----BEGIN PRIVATE KEY----- и -----END PRIVATE KEY-----',
    );
  }
  final dir = Directory.systemTemp.createTempSync('svz-key-');
  final file = File('${dir.path}/key.pem');
  try {
    if (!Platform.isWindows) {
      await Process.run('chmod', <String>['700', dir.path]);
    }
    file.writeAsStringSync(text, flush: true);
    if (!Platform.isWindows) {
      await Process.run('chmod', <String>['600', file.path]);
    }
    return await use(file.path);
  } finally {
    try {
      file.writeAsBytesSync(
        List<int>.filled(file.lengthSync(), 0),
        flush: true,
      );
    } on Object {
      // Файла уже нет.
    }
    dir.deleteSync(recursive: true);
  }
}

/// Подпись Ed25519 ключом [keyFile] (PEM) через OpenSSL 3.
Future<Uint8List> signEd25519(String keyFile, Uint8List message) async {
  final dir = Directory.systemTemp.createTempSync('svz-sign-');
  try {
    final input = File('${dir.path}/msg.bin')..writeAsBytesSync(message);
    final output = File('${dir.path}/sig.bin');
    final result = await Process.run('openssl', <String>[
      'pkeyutl',
      '-sign',
      '-rawin',
      '-inkey',
      keyFile,
      '-in',
      input.path,
      '-out',
      output.path,
    ]);
    if (result.exitCode != 0) {
      throw const _Fail(
        'OpenSSL не подписал: нужен OpenSSL 3 и ключ Ed25519 (PEM)',
      );
    }
    return output.readAsBytesSync();
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// Открытый ключ для склада: последние 32 байта DER SubjectPublicKeyInfo.
Future<String> publicKeyBase64(String keyFile) async {
  final result = await Process.run(
    'openssl',
    <String>['pkey', '-in', keyFile, '-pubout', '-outform', 'DER'],
    stdoutEncoding: null,
  );
  final der = result.stdout as List<int>;
  if (result.exitCode != 0 || der.length != 44) {
    throw const _Fail('Это не ключ Ed25519');
  }
  return base64.encode(der.sublist(der.length - 32));
}

/// Проверка подписи открытым ключом [publicKey] (32 байта) через OpenSSL.
Future<bool> verifyEd25519(
  List<int> publicKey,
  Uint8List message,
  List<int> signature,
) async {
  final dir = Directory.systemTemp.createTempSync('svz-verify-');
  try {
    // DER SubjectPublicKeyInfo Ed25519: постоянный заголовок + 32 байта.
    const prefix = <int>[
      0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00, //
    ];
    final pub = File('${dir.path}/pub.der')
      ..writeAsBytesSync(<int>[...prefix, ...publicKey]);
    final input = File('${dir.path}/msg.bin')..writeAsBytesSync(message);
    final sig = File('${dir.path}/sig.bin')..writeAsBytesSync(signature);
    final result = await Process.run('openssl', <String>[
      'pkeyutl',
      '-verify',
      '-rawin',
      '-pubin',
      '-keyform',
      'DER',
      '-inkey',
      pub.path,
      '-in',
      input.path,
      '-sigfile',
      sig.path,
    ]);
    return result.exitCode == 0;
  } finally {
    dir.deleteSync(recursive: true);
  }
}
