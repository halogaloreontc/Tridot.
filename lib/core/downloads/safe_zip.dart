import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// Пределы распаковки: архив, который в них не укладывается, не
/// распаковывается вовсе (ADR-023).
final class ZipLimits {
  const ZipLimits({
    required this.maxEntries,
    required this.maxTotalBytes,
    required this.maxEntryBytes,
  });

  /// Сколько записей (файлов и папок) может быть в архиве.
  final int maxEntries;

  /// Сумма распакованных размеров всех файлов.
  final int maxTotalBytes;

  /// Распакованный размер одного файла.
  final int maxEntryBytes;
}

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
Future<void> extractZipSafely(
  File zip,
  Directory dest, {
  required ZipLimits limits,
  String? stripRoot,
}) {
  final zipPath = zip.path;
  final destPath = dest.path;
  return Isolate.run(
    () => extractZipSafelySync(
      zipPath,
      destPath,
      limits: limits,
      stripRoot: stripRoot,
    ),
  );
}

/// То же, что [extractZipSafely], в текущем изоляте.
void extractZipSafelySync(
  String zipPath,
  String destPath, {
  required ZipLimits limits,
  String? stripRoot,
}) {
  final input = InputFileStream(zipPath);
  try {
    final decoder = ZipDecoder();
    final Archive archive;
    try {
      archive = decoder.decodeStream(input, verify: true);
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
    for (final header in headers) {
      final name = header.filename;
      if (name.contains('\\')) throw const UnsafeZipException('backslash');
      final key =
          name.endsWith('/') ? name.substring(0, name.length - 1) : name;
      if (!names.add(key)) throw const UnsafeZipException('duplicate');
    }
    final plan = _plan(archive, limits, stripRoot);
    _write(plan, destPath, limits);
  } finally {
    input.closeSync();
  }
}

final class _Entry {
  const _Entry(this.file, this.relative);

  final ArchiveFile file;

  /// Путь внутри [dest] через `/`; пустой — сама папка.
  final String relative;
}

List<_Entry> _plan(Archive archive, ZipLimits limits, String? stripRoot) {
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

void _write(List<_Entry> plan, String destPath, ZipLimits limits) {
  final destDir = Directory(destPath)..createSync(recursive: true);
  final base = p.canonicalize(destDir.resolveSymbolicLinksSync());
  var written = 0;
  for (final entry in plan) {
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
