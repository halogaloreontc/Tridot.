// Выпуск веб-помощника «Связной» для складов (ADR-032, docs/WEB_WIDGET.md).
//
//   dart run tool/widget_release/release.dart build --version 1.0.0 \
//       --notes "Первая версия"
//   dart run tool/widget_release/release.dart pubkey
//   dart run tool/widget_release/release.dart verify \
//       build/widget_release/1.0.0/latest.json --pubkey <base64>
//
// Закрытый ключ подписи — только у владельца: путь к файлу PEM в
// SVYAZNOY_SIGN_KEY_FILE или сам текст PEM в SVYAZNOY_SIGN_KEY. В
// репозиторий он не попадает и в вывод не печатается. Подписывает
// OpenSSL 3 (`openssl pkeyutl -sign -rawin`, Ed25519).

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
      case 'pubkey':
        stdout.writeln(await withSigningKey(publicKeyBase64));
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
  pubkey  открытый ключ (base64, 32 байта) для ASSIST_WEB_PUBKEY склада
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

  if (options['skip-build'] == null) {
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
      mode: ProcessStartMode.inheritStdio,
      runInShell: Platform.isWindows,
    );
    if (await build.exitCode != 0) throw const _Fail('flutter build web упал');
    writeBuildStamp(Directory('build/web'), version);
  }
  final web = Directory('build/web');
  if (!web.existsSync()) throw const _Fail('Нет build/web — соберите заново');
  if (checkBuildStamp(web, version) case final String why) throw _Fail(why);
  final files = collectBuild(web);
  final total = files.values.fold<int>(0, (int s, List<int> b) => s + b.length);
  stdout.writeln(
    'Файлов: ${files.length}, ${(total / 1048576).toStringAsFixed(1)} МБ',
  );

  final zip = await withSigningKey(
    (String key) => buildReleaseZip(
      version: version,
      files: files,
      notes: notes,
      minApi: minApi,
      minServer: minServer,
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
    '${latestJson(version: version, url: url, size: zip.length, sha256: hash, signature: base64.encode(latestSig), notes: notes, minApi: minApi, minServer: minServer)}\n',
    flush: true,
  );
  stdout
    ..writeln('Готово: ${outDir.path}/$zipName (${zip.length} байт)')
    ..writeln('sha256: $hash')
    ..writeln('Дальше: tool/widget_release/upload.sh ${outDir.path}')
    ..writeln('или загрузите архив вручную: Инструменты → Помощник → '
        '«Загрузить архив…».');
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
  final pub = base64.decode(args[2]);
  if (pub.length != 32) throw const _Fail('Открытый ключ — 32 байта');
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
  if (!latestOk) throw const _Fail('Подпись latest.json не сошлась');
  final archive = ZipDecoder().decodeBytes(zip);
  final manifest = archive.findFile(releaseJsonName)!.content;
  final sig =
      base64.decode(utf8.decode(archive.findFile(releaseSigName)!.content));
  if (!await verifyEd25519(pub, releaseSigningBytes(manifest), sig)) {
    throw const _Fail('Подпись _release.json не сошлась');
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
    'Выпуск ${release['version']} проверен: подписи и sha256 сходятся.',
  );
}

// ------------------------------------------------------------- ключ

/// Путь к PEM закрытого ключа на время [use]: из SVYAZNOY_SIGN_KEY_FILE,
/// иначе текст SVYAZNOY_SIGN_KEY пишется во временный файл 0600 и потом
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
  final text = env['SVYAZNOY_SIGN_KEY'];
  if (text == null || !text.contains('PRIVATE KEY')) {
    throw const _Fail(
      'Нет ключа подписи: задайте SVYAZNOY_SIGN_KEY_FILE (путь к PEM) или '
      'SVYAZNOY_SIGN_KEY (текст PEM). Создать: openssl genpkey -algorithm '
      'ed25519 -out svyaznoy-sign.pem',
    );
  }
  final dir = Directory.systemTemp.createTempSync('svz-key-');
  final file = File('${dir.path}/key.pem');
  try {
    if (!Platform.isWindows) {
      await Process.run('chmod', <String>['700', dir.path]);
    }
    file.writeAsStringSync(text.endsWith('\n') ? text : '$text\n', flush: true);
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
