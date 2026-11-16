// Выпуск веб-помощника «Связной» (ADR-032): что кладётся в архив, как
// описывается и подписывается. Здесь — без Flutter и без сети: проверяют
// тесты test/tool/widget_release_test.dart. Сборку, подпись ключом и
// запись файлов делает release.dart.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

/// Имя продукта в `_release.json`: склад сверяет его с `latest.json`.
const String releaseProduct = 'svyaznoy-web';

/// Версия договора склад ↔ помощник по умолчанию (`ASSIST_WEB_API`).
const int defaultMinApi = 1;

/// С каких версий складов помощник работает: номера у двух складов разные.
const Map<String, String> defaultMinServer = <String, String>{
  'depotdesk': '1.4.63',
  'halowarekeep': '1.4.67',
};

/// Подписываемые байты `_release.json`: метка и сам файл как есть.
const String releaseSignatureTag = 'SVYAZNOY-WEB-RELEASE-V1\n';

/// Метка подписи `latest.json`.
const String latestSignatureTag = 'SVYAZNOY-WEB-LATEST-V1\n';

/// Файлы описания выпуска в корне архива.
const String releaseJsonName = '_release.json';
const String releaseSigName = '_release.sig';

/// Пределы — те же, что проверяет склад перед установкой.
const int maxEntries = 3000;
const int maxTotalBytes = 80 * 1024 * 1024;

/// Расширения, которые склад распаковывает (`awVerify`): всё остальное —
/// отказ. `NOTICES` без расширения — нельзя, лицензии лежат в
/// `LICENSES.txt`.
const Set<String> allowedExtensions = <String>{
  'html',
  'js',
  'mjs',
  'json',
  'wasm',
  'css',
  'png',
  'svg',
  'ico',
  'webp',
  'otf',
  'ttf',
  'woff2',
  'bin',
  'symbols',
  'txt',
  'frag',
};

final RegExp _version = RegExp(r'^\d{1,4}\.\d{1,4}\.\d{1,4}$');

/// Версия выпуска: `1.0.0`. Без букв и хвостов — склад сравнивает
/// числами и делает из неё имя папки.
bool isReleaseVersion(String version) => _version.hasMatch(version);

/// Почему путь [path] внутри архива склад не примет; `null` — примет.
String? checkEntryName(String path) {
  if (path.isEmpty || path.length > 200) return 'длина пути';
  if (path.startsWith('/') || path.contains('\\')) return 'абсолютный путь';
  if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(path)) return 'управляющий знак';
  if (!RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(path)) return 'знак не из списка';
  final parts = path.split('/');
  for (final part in parts) {
    if (part.isEmpty || part == '.' || part == '..') return 'пустая часть пути';
    if (part.startsWith('.')) return 'имя с точкой в начале';
  }
  final name = parts.last;
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return 'нет расширения';
  final ext = name.substring(dot + 1).toLowerCase();
  if (!allowedExtensions.contains(ext)) return 'расширение .$ext';
  return null;
}

/// Что убрать из `build/web`, чтобы архив был легче и склад его принял.
///
/// CanvasKit — только `canvaskit/` и `chromium/` (сборка JS): без
/// skwasm, wimp, webparagraph и символов отладки. Ассеты «Tridot», которые
/// помощнику не нужны: паки, пароли, голос, каталоги ответов (ядро берёт
/// их из `builtin_replies.g.dart`), шрифты Cormorant и JetBrains Mono.
/// Своего service worker у помощника нет.
bool isPruned(String path) {
  if (path.split('/').any((String p) => p.startsWith('.'))) return true;
  const exact = <String>{
    'flutter_service_worker.js',
    'version.json',
    'favicon.png',
    'manifest.json',
  };
  if (exact.contains(path)) return true;
  if (path.startsWith('icons/')) return true;
  if (path.startsWith('canvaskit/')) {
    const keep = <String>{
      'canvaskit/canvaskit.js',
      'canvaskit/canvaskit.wasm',
      'canvaskit/chromium/canvaskit.js',
      'canvaskit/chromium/canvaskit.wasm',
    };
    return !keep.contains(path);
  }
  if (path.startsWith('assets/assets/')) {
    const keep = <String>{
      'assets/assets/connectors/depotdesk.assistant.json',
      'assets/assets/fonts/GolosText-Variable.ttf',
      'assets/assets/fonts/GolosText-OFL.txt',
    };
    return !keep.contains(path);
  }
  // Ворклет записи звука (плагин record): помощник не пишет звук.
  if (path.startsWith('assets/packages/record_web/')) return true;
  return false;
}

/// FontManifest без семейств, чьих файлов в архиве нет: иначе движок
/// пытается их скачать и пишет ошибки.
String pruneFontManifest(String source, Set<String> kept) {
  final json = jsonDecode(source);
  if (json is! List) throw const FormatException('FontManifest не список');
  final out = <Object?>[];
  for (final family in json) {
    if (family is! Map) continue;
    final fonts = family['fonts'];
    if (fonts is! List) continue;
    final present = <Object?>[
      for (final font in fonts)
        if (font is Map && kept.contains('assets/${font['asset']}')) font,
    ];
    if (present.isEmpty) continue;
    out.add(
      <String, Object?>{...family.cast<String, Object?>(), 'fonts': present},
    );
  }
  return jsonEncode(out);
}

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// Отпечаток ключа издателя — тот же, что показывает склад в «Инструменты
/// → Помощник» и выпуск в GitHub Actions: sha256 от 32 байт открытого ключа
/// (не от base64), первые 16 знаков hex строчными, по 4 через пробел —
/// `21fe 31df a154 a261`. 64 бита: подобрать другой ключ с тем же
/// отпечатком не по силам (32 бита подбирались бы за часы). Только чтобы
/// сверить глазами; склад проверяет подпись полным ключом.
String publisherFingerprint(List<int> publicKey) {
  if (publicKey.length != 32) {
    throw ArgumentError.value(publicKey.length, 'publicKey', 'нужно 32 байта');
  }
  final hex = sha256Hex(publicKey);
  return <String>[
    for (var i = 0; i < 16; i += 4) hex.substring(i, i + 4),
  ].join(' ');
}

/// Окружение для `flutter build web`: всё, кроме ключа подписи
/// (`SVYAZNOY_SIGN_KEY`, `SVYAZNOY_SIGN_KEY_FILE`) и ключей бакета — сборке
/// они не нужны, а она запускает код пакетов.
Map<String, String> buildEnvironment(Map<String, String> env) =>
    <String, String>{
      for (final MapEntry<String, String> e in env.entries)
        if (!_secretEnv.contains(e.key.toUpperCase())) e.key: e.value,
    };

const Set<String> _secretEnv = <String>{
  'SVYAZNOY_SIGN_KEY',
  'SVYAZNOY_SIGN_KEY_FILE',
  'AWS_ACCESS_KEY_ID',
  'AWS_SECRET_ACCESS_KEY',
  'AWS_SESSION_TOKEN',
};

final RegExp _pem = RegExp(
  r'-----BEGIN PRIVATE KEY-----([\s\S]*?)-----END PRIVATE KEY-----',
);

/// Закрытый ключ PEM в виде, который читает OpenSSL, — из текста, который
/// вставили в секрет GitHub или в переменную как получилось: с `\r\n`, в
/// одну строку, с лишними пробелами или с буквальными `\n`. `null` — в
/// тексте нет PEM `PRIVATE KEY` (PKCS#8 без пароля).
String? normalizePrivateKeyPem(String text) {
  final match = _pem.firstMatch(text);
  if (match == null) return null;
  final body = match.group(1)!.replaceAll(RegExp(r'\\[nr]|\s'), '');
  if (body.isEmpty || !RegExp(r'^[A-Za-z0-9+/]+=*$').hasMatch(body)) {
    return null;
  }
  final lines = <String>[
    for (var i = 0; i < body.length; i += 64)
      body.substring(i, i + 64 > body.length ? body.length : i + 64),
  ];
  return '-----BEGIN PRIVATE KEY-----\n${lines.join('\n')}\n'
      '-----END PRIVATE KEY-----\n';
}

/// Описание выпуска `_release.json`: что внутри и для каких складов.
/// Пути — по алфавиту; JSON без пробелов. Подписываются именно эти байты.
/// [publicKey] (base64) — подсказка складу: подпись не сошлась — он
/// покажет оба отпечатка, свой и этого ключа. Склад ей не верит: подпись
/// проверяет только своим ключом.
Uint8List releaseJson({
  required String version,
  required Map<String, List<int>> files,
  String notes = '',
  int minApi = defaultMinApi,
  Map<String, String> minServer = defaultMinServer,
  String? publicKey,
}) {
  final paths = files.keys.toList()..sort();
  var total = 0;
  final hashes = <String, String>{};
  for (final path in paths) {
    final bytes = files[path]!;
    total += bytes.length;
    hashes[path] = sha256Hex(bytes);
  }
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode(<String, Object?>{
        'product': releaseProduct,
        'version': version,
        'minApi': minApi,
        'minServer': minServer,
        'notes': notes,
        if (publicKey != null) 'pubkey': publicKey,
        'files': hashes,
        'total': total,
      }),
    ),
  );
}

/// Байты подписи `_release.sig`.
Uint8List releaseSigningBytes(List<int> releaseJsonBytes) => Uint8List.fromList(
      <int>[...utf8.encode(releaseSignatureTag), ...releaseJsonBytes],
    );

/// Байты подписи `latest.json`: версия, sha256 и размер архива, minApi.
Uint8List latestSigningBytes({
  required String version,
  required String sha256,
  required int size,
  required int minApi,
}) =>
    Uint8List.fromList(
      utf8.encode('$latestSignatureTag$version\n$sha256\n$size\n$minApi'),
    );

/// `latest.json` для бакета: склад читает его по своему источнику
/// обновлений. [url] — адрес архива: относительный (рядом с `latest.json`)
/// или https того же хоста. [publicKey] — та же подсказка, что в
/// [releaseJson], подписью не покрыта.
String latestJson({
  required String version,
  required String url,
  required int size,
  required String sha256,
  required String signature,
  String notes = '',
  int minApi = defaultMinApi,
  Map<String, String> minServer = defaultMinServer,
  String? publicKey,
}) =>
    const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'version': version,
      'minApi': minApi,
      'minServer': minServer,
      'url': url,
      'size': size,
      'sha256': sha256,
      'notes': notes,
      'sig': signature,
      if (publicKey != null) 'pubkey': publicKey,
    });

/// Подпись Ed25519: 64 байта подписи по [message].
typedef Signer = Future<Uint8List> Function(Uint8List message);

/// Архив выпуска: файлы сборки по алфавиту, потом `_release.json` и
/// `_release.sig` (base64 подписи). Время в архиве постоянное — одинаковая
/// сборка даёт одинаковый архив.
Future<Uint8List> buildReleaseZip({
  required String version,
  required Map<String, List<int>> files,
  required Signer sign,
  String notes = '',
  int minApi = defaultMinApi,
  Map<String, String> minServer = defaultMinServer,
  String? publicKey,
}) async {
  if (!isReleaseVersion(version)) {
    throw ArgumentError.value(version, 'version', 'нужно вида 1.0.0');
  }
  final problems = <String>[
    for (final path in files.keys)
      if (checkEntryName(path) case final String why) '$path: $why',
  ];
  if (files.containsKey(releaseJsonName) || files.containsKey(releaseSigName)) {
    problems.add('служебные имена заняты');
  }
  if (files.length + 2 > maxEntries) problems.add('больше $maxEntries файлов');
  final total = files.values.fold<int>(0, (int s, List<int> b) => s + b.length);
  if (total > maxTotalBytes) problems.add('больше 80 МБ');
  if (!files.containsKey('index.html')) problems.add('нет index.html');
  if (problems.isNotEmpty) {
    throw FormatException('Склад не примет архив: ${problems.join('; ')}');
  }
  final manifest = releaseJson(
    version: version,
    files: files,
    notes: notes,
    minApi: minApi,
    minServer: minServer,
    publicKey: publicKey,
  );
  final signature = await sign(releaseSigningBytes(manifest));
  if (signature.length != 64) {
    throw StateError(
      'Подпись Ed25519 — 64 байта, а получено ${signature.length}',
    );
  }
  const stamp = 1735689600; // 2025-01-01: постоянное время файлов архива.
  final archive = Archive();
  final paths = files.keys.toList()..sort();
  for (final path in paths) {
    archive.addFile(ArchiveFile.bytes(path, files[path]!)..lastModTime = stamp);
  }
  archive
    ..addFile(ArchiveFile.bytes(releaseJsonName, manifest)..lastModTime = stamp)
    ..addFile(
      ArchiveFile.bytes(releaseSigName, utf8.encode(base64.encode(signature)))
        ..lastModTime = stamp,
    );
  return ZipEncoder().encodeBytes(archive);
}

/// Отметка в `build/web`: с какой `--version` (SVYAZNOY_WEB_VERSION) она
/// собрана. Имя с точкой — в архив не попадает ([isPruned]). Новый
/// `flutter build web` папку очищает, и отметка пропадает вместе со старой
/// сборкой.
const String buildStampName = '.svz-version';

/// Записать отметку версии в собранную папку [web].
void writeBuildStamp(Directory web, String version) =>
    File('${web.path}/$buildStampName').writeAsStringSync(version, flush: true);

/// Почему готовую [web] нельзя выпустить как [version] (`--skip-build`);
/// `null` — можно. Помощник сравнивает версию из `current.json` с зашитой в
/// `main.dart.js`: чужая версия ломает и обновление, и откат.
String? checkBuildStamp(Directory web, String version) {
  final stamp = File('${web.path}/$buildStampName');
  if (!stamp.existsSync()) {
    return 'build/web собрана не этим инструментом (нет $buildStampName) — '
        'соберите без --skip-build';
  }
  final built = stamp.readAsStringSync().trim();
  if (built != version) {
    return 'build/web собрана как $built, а выпуск — $version: '
        'соберите без --skip-build';
  }
  return null;
}

/// Файлы папки сборки [root] с путями через `/`, без лишнего ([isPruned]);
/// FontManifest — без убранных шрифтов, NOTICES — в `LICENSES.txt`.
Map<String, List<int>> collectBuild(Directory root) {
  final all = <String, List<int>>{};
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is Link) {
      throw FormatException('Ссылка в сборке: ${entity.path}');
    }
    if (entity is! File) continue;
    final relative = entity.path
        .substring(root.path.length)
        .replaceAll(Platform.pathSeparator, '/')
        .replaceFirst(RegExp('^/+'), '');
    all[relative] = entity.readAsBytesSync();
  }
  final files = <String, List<int>>{
    for (final MapEntry(:key, :value) in all.entries)
      if (!isPruned(key) && key != 'assets/NOTICES') key: value,
  };
  if (all['assets/NOTICES'] case final List<int> notices) {
    files['LICENSES.txt'] = notices;
  }
  if (files['assets/FontManifest.json'] case final List<int> fonts) {
    files['assets/FontManifest.json'] = utf8.encode(
      pruneFontManifest(utf8.decode(fonts), files.keys.toSet()),
    );
  }
  return files;
}
