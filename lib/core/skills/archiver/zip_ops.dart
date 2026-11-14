/// Работа архиватора: создать ZIP, распаковать, посмотреть содержимое
/// (docs/PLANS.md, «Архиватор»). Чистый Dart (пакет `archive`), всё в
/// отдельном изоляте ([IsolateJobRunner]). Исходники не меняются:
/// архив пишется в `<имя>.zip.part` и переименовывается в конце,
/// распаковка идёт во временную папку рядом и переименовывается в конце.
library;

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../../downloads/safe_zip.dart';
import '../../jobs/extension_card.dart';
import '../../jobs/job_placement.dart';
import '../../jobs/job_runner.dart';

abstract final class ZipOps {
  /// Задача по действию карточки: имена результата и временные пути.
  /// Ввод-вывод — только проверка имён (быстро, в главном изоляте).
  static JobRequest plan({
    required String cardId,
    required String action,
    required List<JobSource> sources,
    required String outputDir,
    ZipLimits limits = ZipLimits.desktop,
    String? explicitTarget,
    String? level,
  }) {
    switch (action) {
      case ExtensionForms.zip:
        final name = sources.length == 1
            ? JobPlacement.safeName(
                sources.single.folder
                    ? sources.single.name
                    : p.basenameWithoutExtension(sources.single.name),
              )
            : 'Архив';
        final target =
            explicitTarget ?? JobPlacement.uniquePath(outputDir, '$name.zip');
        return JobRequest(
          cardId: cardId,
          extensionId: ExtensionForms.archiver,
          action: action,
          sources: sources,
          outputDir: p.dirname(target),
          target: target,
          temp: JobPlacement.tempFile(target, cardId),
          limits: limits,
          options: <String, String>{
            if (level != null &&
                ExtensionForms.validDefault(
                  ExtensionForms.archiver,
                  'level',
                  level,
                ))
              'level': level,
          },
        );
      case ExtensionForms.extract:
        final name = JobPlacement.safeName(
          p.basenameWithoutExtension(sources.single.name),
        );
        final target = JobPlacement.uniquePath(outputDir, name, folder: true);
        return JobRequest(
          cardId: cardId,
          extensionId: ExtensionForms.archiver,
          action: action,
          sources: sources,
          outputDir: outputDir,
          target: target,
          temp: JobPlacement.tempFolder(outputDir, name, cardId),
          limits: limits,
        );
      default:
        return JobRequest(
          cardId: cardId,
          extensionId: ExtensionForms.archiver,
          action: ExtensionForms.list,
          sources: sources,
          outputDir: outputDir,
          limits: limits,
        );
    }
  }

  /// Работа в изоляте.
  static JobDone run(JobRequest request, JobReporter reporter) {
    for (final source in request.sources) {
      final type = FileSystemEntity.typeSync(source.path);
      if (type == FileSystemEntityType.notFound) throw const JobMissing();
    }
    return switch (request.action) {
      ExtensionForms.zip => _create(request, reporter),
      ExtensionForms.extract => _extract(request, reporter),
      _ => _list(request),
    };
  }

  static JobDone _create(JobRequest request, JobReporter reporter) {
    final target = request.target!;
    final part = request.temp!;
    // Что положить: файлы и содержимое папок, без ссылок.
    final entries = <(File, String)>[];
    final folders = <String>[];
    for (final source in request.sources) {
      final type = FileSystemEntity.typeSync(source.path, followLinks: false);
      if (type == FileSystemEntityType.link) continue;
      if (type == FileSystemEntityType.directory) {
        final root = JobPlacement.safeName(source.name, fallback: 'Папка');
        folders.add('$root/');
        _walk(Directory(source.path), root, entries, folders, target, part);
      } else if (type == FileSystemEntityType.file) {
        // Имя из вложения или от выбора файлов (на Android его даёт чужое
        // приложение) — только как имя файла: без `/`, `..` и знаков,
        // запрещённых в Windows.
        entries.add((File(source.path), entryName(source.name)));
      }
    }
    if (entries.length + folders.length > request.limits.maxEntries) {
      throw const UnsafeZipException('too_many_entries');
    }
    final total = entries.fold<int>(
      0,
      (int sum, (File, String) e) => sum + e.$1.lengthSync(),
    );
    reporter.progress(0, 'Сжатие');
    final encoder = ZipFileEncoder();
    // Сжатие из карточки: обычное (6), сильное (9) или без сжатия (0).
    encoder.create(
      part,
      level: ExtensionForms.zipLevel(request.options['level']),
    );
    var done = 0;
    try {
      for (final folder in folders) {
        encoder.addArchiveFile(ArchiveFile.directory(folder));
      }
      final names = <String>{};
      for (final (file, name) in entries) {
        var unique = name;
        var n = 2;
        while (!names.add(unique)) {
          final ext = p.posix.extension(name);
          unique = '${name.substring(0, name.length - ext.length)} ($n)$ext';
          n++;
        }
        final input = InputFileStream(file.path);
        try {
          final entry = ArchiveFile.stream(unique, input)
            ..lastModTime =
                file.lastModifiedSync().millisecondsSinceEpoch ~/ 1000
            ..mode = file.statSync().mode;
          encoder.addArchiveFile(entry);
        } finally {
          input.closeSync();
        }
        done += file.lengthSync();
        reporter.progress(total == 0 ? null : done / total, 'Сжатие');
      }
      encoder.closeSync();
    } on Object {
      try {
        encoder.closeSync();
      } on Object {
        // Файл уже закрыт или запись не удалась — его всё равно удаляем.
      }
      IsolateJobRunner.removeQuietly(part);
      rethrow;
    }
    final String result;
    try {
      // Имя могли занять, пока шла работа: чужой файл не заменяется.
      result = JobPlacement.commitFile(part, target);
    } on Object {
      IsolateJobRunner.removeQuietly(part);
      rethrow;
    }
    reporter.progress(1, 'Сжатие');
    return JobDone(outputs: <String>[result], outputDir: p.dirname(result));
  }

  /// Файлы папки [dir] под путём [prefix]; ссылки не раскрываются, сам
  /// будущий архив ([target], [part]) не попадает в архив.
  static void _walk(
    Directory dir,
    String prefix,
    List<(File, String)> entries,
    List<String> folders,
    String target,
    String part,
  ) {
    final children = dir.listSync(followLinks: false)
      ..sort(
        (FileSystemEntity a, FileSystemEntity b) => a.path.compareTo(b.path),
      );
    for (final child in children) {
      final name = '$prefix/${entryName(p.basename(child.path))}';
      if (child is Link) continue;
      if (child is Directory) {
        folders.add('$name/');
        _walk(child, name, entries, folders, target, part);
      } else if (child is File) {
        if (p.equals(child.path, target) || p.equals(child.path, part)) {
          continue;
        }
        entries.add((child, name));
      }
    }
  }

  static JobDone _extract(JobRequest request, JobReporter reporter) {
    final temp = request.temp!;
    final target = request.target!;
    reporter.progress(0, 'Распаковка');
    try {
      extractZipSafelySync(
        request.sources.single.path,
        temp,
        limits: request.limits,
        onProgress: (int done, int total) =>
            reporter.progress(total == 0 ? null : done / total, 'Распаковка'),
      );
      final result = JobPlacement.commitFolder(temp, target);
      reporter.progress(1, 'Распаковка');
      return JobDone(outputs: <String>[result], outputDir: result);
    } on Object {
      IsolateJobRunner.removeQuietly(temp);
      rethrow;
    }
  }

  static JobDone _list(JobRequest request) {
    final entries = listZipSafely(request.sources.single.path, request.limits);
    final lines = <String>[
      for (final entry in entries.take(ExtensionCard.listingLimit))
        entry.isDirectory
            ? '${entry.name}/'
            : '${entry.name} · ${sizeLabel(entry.size)}',
    ];
    return JobDone(
      listing: lines,
      listingMore: entries.length > ExtensionCard.listingLimit
          ? entries.length - ExtensionCard.listingLimit
          : 0,
    );
  }

  /// Имя записи архива из имени файла [name]: только последняя часть
  /// пути, без знаков, запрещённых в именах файлов.
  static String entryName(String name) => JobPlacement.fileName(name);

  /// «2,4 МБ», «830 КБ», «12 Б».
  static String sizeLabel(int bytes) {
    if (bytes < 1024) return '$bytes Б';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} КБ';
    final mb = bytes / (1024 * 1024);
    final text = mb >= 10 ? mb.round().toString() : mb.toStringAsFixed(1);
    return '${text.replaceAll('.', ',')} МБ';
  }
}
