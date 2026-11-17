import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';

import 'safe_zip.dart';

/// Распаковывает `.tar.xz` [archivePath] в [destPath] в отдельном изоляте
/// (ADR-024, шаг 2: ffmpeg для Linux). Сначала xz распаковывается потоком
/// во временный `.tar` [tarPath] — не больше [ZipLimits.maxTotalBytes] и
/// ещё 64 МБ на заголовки, — затем tar читается с диска, все записи
/// проверяются как у ZIP ([extractArchiveSafelySync]) и только потом
/// пишется первый байт. Ссылки, устройства и прочие особые записи —
/// отказ. Временный `.tar` удаляется в любом случае.
Future<void> extractTarXzSafely(
  String archivePath,
  String destPath,
  String tarPath, {
  required ZipLimits limits,
  String? stripRoot,
  Set<String>? onlyEntries,
}) =>
    Isolate.run(
      () => extractTarXzSafelySync(
        archivePath,
        destPath,
        tarPath,
        limits: limits,
        stripRoot: stripRoot,
        onlyEntries: onlyEntries,
      ),
    );

/// Запас на заголовки tar сверх суммы файлов.
const int _tarOverhead = 64 * 1024 * 1024;

/// То же, что [extractTarXzSafely], в текущем изоляте.
void extractTarXzSafelySync(
  String archivePath,
  String destPath,
  String tarPath, {
  required ZipLimits limits,
  String? stripRoot,
  Set<String>? onlyEntries,
}) {
  try {
    final input = InputFileStream(archivePath);
    final output = OutputFileStream(tarPath);
    try {
      final bool ok;
      try {
        ok = XZDecoder().decodeStream(
          input,
          output,
          verify: true,
          maxOutputSize: limits.maxTotalBytes + _tarOverhead,
        );
      } on FileSystemException {
        rethrow;
      } on Object {
        throw const UnsafeZipException('corrupt');
      }
      if (!ok) throw const UnsafeZipException('corrupt');
    } finally {
      output.closeSync();
      input.closeSync();
    }
    extractTarSafelySync(
      tarPath,
      destPath,
      limits: limits,
      stripRoot: stripRoot,
      onlyEntries: onlyEntries,
    );
  } finally {
    try {
      final tar = File(tarPath);
      if (tar.existsSync()) tar.deleteSync();
    } on Object {
      // Не вышло — останется во временной папке до следующей уборки.
    }
  }
}

/// Распаковывает несжатый `.tar` [tarPath] в [destPath] с проверками
/// [extractArchiveSafelySync]. Записи, кроме обычных файлов и папок
/// (ссылки, устройства, FIFO), — отказ `link`/`special`.
void extractTarSafelySync(
  String tarPath,
  String destPath, {
  required ZipLimits limits,
  String? stripRoot,
  Set<String>? onlyEntries,
}) {
  final input = InputFileStream(tarPath);
  try {
    final decoder = TarDecoder();
    final Archive archive;
    try {
      archive = decoder.decodeStream(input, verify: true);
    } on Object {
      throw const UnsafeZipException('corrupt');
    }
    if (decoder.files.length > limits.maxEntries) {
      throw const UnsafeZipException('too_many_entries');
    }
    final names = <String>{};
    for (final file in decoder.files) {
      switch (file.typeFlag) {
        case '0' || '' || '\u0000' || '7' || '5':
          break;
        case '1' || '2':
          throw const UnsafeZipException('link');
        default:
          throw const UnsafeZipException('special');
      }
      final name = file.filename;
      final key =
          name.endsWith('/') ? name.substring(0, name.length - 1) : name;
      if (!names.add(key)) throw const UnsafeZipException('duplicate');
    }
    extractArchiveSafelySync(
      archive,
      destPath,
      limits: limits,
      stripRoot: stripRoot,
      onlyEntries: onlyEntries,
    );
  } finally {
    input.closeSync();
  }
}
