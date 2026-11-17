import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'free_space.dart';

/// Пределы распаковки: архив, который в них не укладывается, не
/// распаковывается вовсе (ADR-023).
final class ZipLimits {
  const ZipLimits({
    required this.maxEntries,
    required this.maxTotalBytes,
    required this.maxEntryBytes,
    this.maxRatio,
  });

  /// Пределы архиватора на компьютере: 10 000 записей, всего 2 ГБ,
  /// сжатие не больше 200:1 у записей больше 1 МБ.
  static const ZipLimits desktop = ZipLimits(
    maxEntries: 10000,
    maxTotalBytes: 2 * 1024 * 1024 * 1024,
    maxEntryBytes: 2 * 1024 * 1024 * 1024,
    maxRatio: 200,
  );

  /// Пределы архиватора на телефоне: всего 1 ГБ.
  static const ZipLimits mobile = ZipLimits(
    maxEntries: 10000,
    maxTotalBytes: 1024 * 1024 * 1024,
    maxEntryBytes: 1024 * 1024 * 1024,
    maxRatio: 200,
  );

  /// Записи больше этого размера проверяются на степень сжатия.
  static const int ratioFloor = 1024 * 1024;

  /// Сколько записей (файлов и папок) может быть в архиве.
  final int maxEntries;

  /// Сумма распакованных размеров всех файлов.
  final int maxTotalBytes;

  /// Распакованный размер одного файла.
  final int maxEntryBytes;

  /// Во сколько раз распакованная запись больше [ratioFloor] может быть
  /// больше сжатой; `null` — не проверяется (zip-бомба).
  final int? maxRatio;
}

/// Запись архива для «Посмотреть содержимое».
final class ZipEntryInfo {
  const ZipEntryInfo(this.name, this.size, {required this.isDirectory});

  /// Путь внутри архива через `/`.
  final String name;

  /// Распакованный размер (у папки 0).
  final int size;

  final bool isDirectory;
}

/// Ход распаковки: записано [done] байт из [total].
typedef ZipProgress = void Function(int done, int total);

/// Почему архив не распакован. [reason] — служебный код для тестов и
/// разбора, не для пользователя: имена файлов из архива в него не попадают.
final class UnsafeZipException implements Exception {
  const UnsafeZipException(this.reason);

  final String reason;

  @override
  String toString() => 'UnsafeZipException($reason)';
}

/// Распаковывает [zip] в [dest] в отдельном изоляте.
///
/// Сначала проверяются все записи, и только потом пишется первый байт.
/// Отказ: абсолютный путь, буква диска, `\`, `..` и `.` в пути,
/// управляющие знаки, ссылки (символические и жёсткие), повтор имени,
/// больше [ZipLimits.maxEntries] записей, файл больше
/// [ZipLimits.maxEntryBytes], сумма больше [ZipLimits.maxTotalBytes], а
/// при [stripRoot] — запись вне этой папки (сама папка срезается). Каждый
/// путь после `canonicalize` должен остаться внутри [dest]. При записи
/// байты считаются заново: заголовок, который преуменьшает размер, тоже
/// приводит к отказу.
///
/// При отказе во время записи в [dest] могут остаться частично записанные
/// файлы — вызывающий распаковывает во временную папку и удаляет её. Вне
/// [dest] не пишется ничего.
///
/// [onlyEntries] — распаковать только эти записи (пути внутри архива до
/// среза [stripRoot]); проверяются всё равно все. [onProgress] — ход
/// записи в байтах. [cancel] спрашивается между записями: `true` —
/// [UnsafeZipException] `cancelled`. Если свободное место на диске
/// известно ([freeBytes]) и его меньше суммы распакованных размеров —
/// `no_space` до первого байта. Архив с паролем — `password`.
Future<void> extractZipSafely(
  File zip,
  Directory dest, {
  required ZipLimits limits,
  String? stripRoot,
  Set<String>? onlyEntries,
}) {
  final zipPath = zip.path;
  final destPath = dest.path;
  return Isolate.run(
    () => extractZipSafelySync(
      zipPath,
      destPath,
      limits: limits,
      stripRoot: stripRoot,
      onlyEntries: onlyEntries,
    ),
  );
}

/// То же, что [extractZipSafely], в текущем изоляте.
void extractZipSafelySync(
  String zipPath,
  String destPath, {
  required ZipLimits limits,
  String? stripRoot,
  Set<String>? onlyEntries,
  ZipProgress? onProgress,
  bool Function()? cancel,
}) {
  final input = InputFileStream(zipPath);
  try {
    final archive = _decode(input, limits);
    _extract(
      _plan(archive.$1, limits, stripRoot, archive.$2),
      destPath,
      limits,
      onlyEntries: onlyEntries,
      onProgress: onProgress,
      cancel: cancel,
    );
  } finally {
    input.closeSync();
  }
}

/// Распаковка уже прочитанного архива [archive] другого формата (tar,
/// [extractTarXzSafelySync]) с теми же проверками и пределами, что у ZIP:
/// все записи проверяются до первого байта, ссылки — отказ, путь после
/// `canonicalize` — только внутри [destPath]. Степень сжатия у таких
/// архивов не проверяется ([ZipLimits.maxRatio] должен быть `null`):
/// размер распакованного потока ограничивает вызывающий.
void extractArchiveSafelySync(
  Archive archive,
  String destPath, {
  required ZipLimits limits,
  String? stripRoot,
  Set<String>? onlyEntries,
  ZipProgress? onProgress,
  bool Function()? cancel,
}) {
  if (limits.maxRatio != null) {
    throw ArgumentError.value(limits.maxRatio, 'limits.maxRatio');
  }
  final names = <String>{};
  for (final file in archive) {
    final name = file.name;
    final key = name.endsWith('/') ? name.substring(0, name.length - 1) : name;
    if (!names.add(key)) throw const UnsafeZipException('duplicate');
  }
  _extract(
    _plan(archive, limits, stripRoot),
    destPath,
    limits,
    onlyEntries: onlyEntries,
    onProgress: onProgress,
    cancel: cancel,
  );
}

void _extract(
  List<_Entry> checked,
  String destPath,
  ZipLimits limits, {
  Set<String>? onlyEntries,
  ZipProgress? onProgress,
  bool Function()? cancel,
}) {
  var plan = checked;
  if (onlyEntries != null) {
    plan = <_Entry>[
      for (final entry in plan)
        if (entry.file.isFile && onlyEntries.contains(entry.relative)) entry,
    ];
  }
  final total = plan.fold<int>(
    0,
    (int sum, _Entry e) => e.file.isFile ? sum + e.file.size : sum,
  );
  final free = freeBytes(_existingParent(destPath));
  if (free != null && total > free) {
    throw const UnsafeZipException('no_space');
  }
  _write(plan, destPath, limits, onProgress: onProgress, cancel: cancel);
}

/// Записи архива [zipPath] после тех же проверок, что при распаковке:
/// архив, который нельзя распаковать, нельзя и посмотреть. Ничего не
/// пишет.
List<ZipEntryInfo> listZipSafely(String zipPath, ZipLimits limits) {
  final input = InputFileStream(zipPath);
  try {
    final archive = _decode(input, limits);
    return <ZipEntryInfo>[
      for (final entry in _plan(archive.$1, limits, null, archive.$2))
        ZipEntryInfo(
          entry.relative,
          entry.file.isFile ? entry.file.size : 0,
          isDirectory: !entry.file.isFile,
        ),
    ];
  } finally {
    input.closeSync();
  }
}

/// Архив и сжатые размеры записей по центральному каталогу.
(Archive, Map<String, int>) _decode(InputFileStream input, ZipLimits limits) {
  final decoder = ZipDecoder();
  final Archive archive;
  try {
    archive = decoder.decodeStream(input, verify: true);
  } on ArchivePasswordException {
    throw const UnsafeZipException('password');
  } on Object {
    throw const UnsafeZipException('corrupt');
  }
  // Archive склеивает записи с одинаковым именем — считаем и сверяем по
  // центральному каталогу, где видна каждая запись.
  final headers = decoder.directory.fileHeaders;
  if (headers.length > limits.maxEntries) {
    throw const UnsafeZipException('too_many_entries');
  }
  final names = <String>{};
  final compressed = <String, int>{};
  for (final header in headers) {
    // Бит 0 — запись зашифрована: пароль не спрашиваем никогда.
    if (header.generalPurposeBitFlag & 1 != 0) {
      throw const UnsafeZipException('password');
    }
    final name = header.filename;
    if (name.contains('\\')) throw const UnsafeZipException('backslash');
    final key = name.endsWith('/') ? name.substring(0, name.length - 1) : name;
    if (!names.add(key)) throw const UnsafeZipException('duplicate');
    compressed[key] = header.compressedSize;
  }
  return (archive, compressed);
}

/// Ближайшая существующая папка пути [path] (для свободного места).
String _existingParent(String path) {
  var current = p.absolute(path);
  while (!Directory(current).existsSync()) {
    final parent = p.dirname(current);
    if (parent == current) break;
    current = parent;
  }
  return current;
}

final class _Entry {
  const _Entry(this.file, this.relative);

  final ArchiveFile file;

  /// Путь внутри [dest] через `/`; пустой — сама папка.
  final String relative;
}

/// Имена, которые нельзя создать в Windows: CON, PRN, AUX, NUL, COM1-9,
/// LPT1-9 (с любым расширением).
final RegExp _windowsReserved = RegExp(
  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$',
  caseSensitive: false,
);

List<_Entry> _plan(
  Archive archive,
  ZipLimits limits,
  String? stripRoot, [
  Map<String, int> compressed = const <String, int>{},
]) {
  if (archive.length > limits.maxEntries) {
    throw const UnsafeZipException('too_many_entries');
  }
  final root = stripRoot == null ? null : _cleanRoot(stripRoot);
  final seen = <String>{};
  final plan = <_Entry>[];
  var total = 0;
  for (final file in archive) {
    final name = file.name;
    if (name.isEmpty || name.length > 512) {
      throw const UnsafeZipException('bad_name');
    }
    if (name.contains('\\')) throw const UnsafeZipException('backslash');
    if (name.startsWith('/')) throw const UnsafeZipException('absolute');
    if (RegExp(r'^[A-Za-z]:').hasMatch(name)) {
      throw const UnsafeZipException('drive_letter');
    }
    if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
      throw const UnsafeZipException('control_char');
    }
    final trimmed =
        name.endsWith('/') ? name.substring(0, name.length - 1) : name;
    final segments = trimmed.split('/');
    for (final segment in segments) {
      if (segment == '..') throw const UnsafeZipException('parent_segment');
      if (segment == '.' || segment.isEmpty) {
        throw const UnsafeZipException('bad_segment');
      }
      // Такие имена Windows не создаст или создаст не тем файлом.
      if (RegExp(r'[:*?"<>|]').hasMatch(segment) ||
          _windowsReserved.hasMatch(segment) ||
          segment.endsWith('.') ||
          segment.endsWith(' ')) {
        throw const UnsafeZipException('windows_name');
      }
    }
    if (file.isSymbolicLink ||
        file.isHardLink ||
        (file.mode & 0xf000) == 0xa000) {
      throw const UnsafeZipException('link');
    }
    if (!seen.add(trimmed)) throw const UnsafeZipException('duplicate');
    var relative = trimmed;
    if (root != null) {
      if (trimmed == root) {
        relative = '';
      } else if (trimmed.startsWith('$root/')) {
        relative = trimmed.substring(root.length + 1);
      } else {
        throw const UnsafeZipException('outside_root');
      }
    }
    if (file.isFile) {
      if (relative.isEmpty) throw const UnsafeZipException('bad_name');
      final size = file.size;
      if (size < 0 || size > limits.maxEntryBytes) {
        throw const UnsafeZipException('entry_too_large');
      }
      final ratio = limits.maxRatio;
      if (ratio != null && size > ZipLimits.ratioFloor) {
        final packed = compressed[trimmed] ?? 0;
        if (packed <= 0 || size / packed > ratio) {
          throw const UnsafeZipException('ratio');
        }
      }
      total += size;
      if (total > limits.maxTotalBytes) {
        throw const UnsafeZipException('total_too_large');
      }
    }
    plan.add(_Entry(file, relative));
  }
  return plan;
}

String _cleanRoot(String root) {
  final cleaned =
      root.endsWith('/') ? root.substring(0, root.length - 1) : root;
  if (cleaned.isEmpty ||
      cleaned.contains('\\') ||
      cleaned.split('/').any((s) => s.isEmpty || s == '.' || s == '..')) {
    throw ArgumentError.value(root, 'stripRoot');
  }
  return cleaned;
}

void _write(
  List<_Entry> plan,
  String destPath,
  ZipLimits limits, {
  ZipProgress? onProgress,
  bool Function()? cancel,
}) {
  final destDir = Directory(destPath)..createSync(recursive: true);
  final base = p.canonicalize(destDir.resolveSymbolicLinksSync());
  final total = plan.fold<int>(
    0,
    (int sum, _Entry e) => e.file.isFile ? sum + e.file.size : sum,
  );
  var written = 0;
  for (final entry in plan) {
    if (cancel != null && cancel()) {
      throw const UnsafeZipException('cancelled');
    }
    if (entry.relative.isEmpty) continue;
    final target = p.canonicalize(p.join(base, entry.relative));
    if (!p.isWithin(base, target)) {
      throw const UnsafeZipException('escapes_dest');
    }
    if (!entry.file.isFile) {
      Directory(target).createSync(recursive: true);
      _requireInside(base, target);
      continue;
    }
    final parent = Directory(p.dirname(target))..createSync(recursive: true);
    _requireInside(base, parent.path, allowEqual: true);
    if (FileSystemEntity.typeSync(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const UnsafeZipException('exists');
    }
    final declared = entry.file.size;
    final output = _CountingFileStream(
      target,
      limit: declared,
      totalBefore: written,
      totalLimit: limits.maxTotalBytes,
    );
    try {
      entry.file.writeContent(output);
    } on UnsafeZipException {
      rethrow;
    } on FileSystemException {
      // Ошибка диска (нет места), а не испорченный архив.
      rethrow;
    } on Object {
      throw const UnsafeZipException('corrupt');
    } finally {
      output.closeSync();
    }
    if (output.length != declared) {
      throw const UnsafeZipException('size_mismatch');
    }
    written += output.length;
    onProgress?.call(written, total);
  }
}

/// Путь [path] после разрешения ссылок — внутри [base] (или равен ему).
void _requireInside(String base, String path, {bool allowEqual = false}) {
  final real = p.canonicalize(Directory(path).resolveSymbolicLinksSync());
  if (allowEqual && real == base) return;
  if (!p.isWithin(base, real)) {
    throw const UnsafeZipException('escapes_dest');
  }
}

/// Файл, который бросает [UnsafeZipException], как только записано больше
/// [limit] байт или вместе с прежними файлами больше [totalLimit].
final class _CountingFileStream extends OutputFileStream {
  _CountingFileStream(
    String path, {
    required this.limit,
    required this.totalBefore,
    required this.totalLimit,
  }) : super.withFileHandle(
          FileHandle(path, mode: FileAccess.write),
          bufferSize: 64 * 1024,
        );

  final int limit;
  final int totalBefore;
  final int totalLimit;

  void _check() {
    if (length > limit) throw const UnsafeZipException('size_mismatch');
    if (totalBefore + length > totalLimit) {
      throw const UnsafeZipException('total_too_large');
    }
  }

  @override
  void writeByte(int value) {
    super.writeByte(value);
    _check();
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    super.writeBytes(bytes, length: length);
    _check();
  }

  @override
  void writeRange(Uint8List bytes, int start, int end) {
    super.writeRange(bytes, start, end);
    _check();
  }

  @override
  void writeZeros(int count) {
    super.writeZeros(count);
    _check();
  }

  @override
  void writeStream(InputStream stream) {
    super.writeStream(stream);
    _check();
  }

  @override
  void writeBackReference(int distance, int count) {
    super.writeBackReference(distance, count);
    _check();
  }
}
