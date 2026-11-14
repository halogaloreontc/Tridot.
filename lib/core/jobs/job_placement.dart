import 'dart:io';

import 'package:path/path.dart' as p;

import 'extension_card.dart';

/// Куда кладётся результат задачи (ADR-024, «Куда кладётся результат»).
/// Исходники не меняются никогда.
abstract final class JobPlacement {
  /// Папка результата:
  /// - вложения сессии и любые файлы на телефоне — папка карточки в
  ///   сессии [sessionOut] (`files/<сессия>/out/<id>`);
  /// - хранилище в памяти ([sessionOut] = `null`) — временная папка
  ///   [tempOut], она удаляется при следующем запуске;
  /// - файлы с диска на компьютере — рядом с первым исходником.
  ///
  /// На macOS место рядом с исходником выбирает пользователь в окне
  /// сохранения (песочница) — это делает интерфейс до вызова.
  static String outputDir({
    required List<JobFile> files,
    required JobPlatform platform,
    required String? sessionOut,
    required String tempOut,
  }) {
    final fromDisk = files.isNotEmpty &&
        files.every((JobFile f) => !f.attachment) &&
        platform.isDesktop;
    if (fromDisk) return p.dirname(files.first.path);
    return sessionOut ?? tempOut;
  }

  /// Свободное имя [name] в папке [dir]: `имя.zip`, `имя (2).zip`,
  /// `имя (3).zip`… Для папок — без расширения.
  static String uniquePath(String dir, String name, {bool folder = false}) {
    final ext = folder ? '' : p.extension(name);
    final base = folder ? name : p.basenameWithoutExtension(name);
    var candidate = p.join(dir, name);
    var n = 2;
    while (FileSystemEntity.typeSync(candidate, followLinks: false) !=
        FileSystemEntityType.notFound) {
      candidate = p.join(dir, '$base ($n)$ext');
      n++;
    }
    return candidate;
  }

  /// Временный файл результата [target] задачи карточки [cardId]: скрытый,
  /// рядом с ним, с id карточки в имени (`.<имя>.<id>.part`) — две
  /// задачи с одинаковым именем результата не пишут в один файл.
  static String tempFile(String target, String cardId) =>
      p.join(p.dirname(target), '.${p.basename(target)}.$cardId.part');

  /// Временная папка распаковки в [dir]: `.<имя>.tmp-<id>`.
  static String tempFolder(String dir, String name, String cardId) =>
      p.join(dir, '.$name.tmp-$cardId');

  /// Временная папка загрузчика видео в [dir]: `.tridot-<id>.tmp`.
  static String downloadTemp(String dir, String cardId) =>
      p.join(dir, '.tridot-$cardId.tmp');

  /// [path] — временный путь задачи карточки [cardId] одного из видов
  /// выше. Уборка прерванной задачи удаляет только такие пути: путь из
  /// чужого или изменённого файла чата («C:\Users\…») не тронется.
  static bool isTempFor(String path, String cardId) {
    if (cardId.isEmpty || !p.isAbsolute(path)) return false;
    final parts = p.split(p.normalize(path));
    if (parts.contains('..')) return false;
    final name = parts.last;
    return (name.startsWith('.') && name.endsWith('.$cardId.part')) ||
        (name.startsWith('.') && name.endsWith('.tmp-$cardId')) ||
        name == '.tridot-$cardId.tmp';
  }

  /// Готовый временный файл [temp] становится результатом: имя [target]
  /// или, если его уже заняли (другой задачей или пользователем, пока шла
  /// работа), следующее свободное «(2)», «(3)». Чужой файл не
  /// заменяется никогда: имя сначала занимается пустым файлом
  /// (`exclusive`), и только на него переименовывается результат.
  /// Возвращает итоговый путь.
  static String commitFile(String temp, String target) {
    final dir = p.dirname(target);
    final name = p.basename(target);
    for (var attempt = 0; attempt < 100; attempt++) {
      final candidate = attempt == 0 ? target : uniquePath(dir, name);
      try {
        File(candidate).createSync(exclusive: true);
      } on FileSystemException {
        // Имя занято (или заняли между проверкой и созданием) — следующее.
        continue;
      }
      try {
        File(temp).renameSync(candidate);
      } on Object {
        try {
          File(candidate).deleteSync();
        } on Object {
          // Пустой файл-заглушка останется; результат — во временном.
        }
        rethrow;
      }
      return candidate;
    }
    throw const FileSystemException('no free name');
  }

  /// Готовая временная папка [temp] становится результатом [target] или
  /// следующим свободным именем. Переименование папки не заменяет
  /// непустую папку (а на Windows — никакую): занятое имя — пробуем
  /// следующее.
  static String commitFolder(String temp, String target) {
    final dir = p.dirname(target);
    final name = p.basename(target);
    FileSystemException? last;
    for (var attempt = 0; attempt < 100; attempt++) {
      final candidate =
          attempt == 0 ? target : uniquePath(dir, name, folder: true);
      if (FileSystemEntity.typeSync(candidate, followLinks: false) !=
          FileSystemEntityType.notFound) {
        continue;
      }
      try {
        Directory(temp).renameSync(candidate);
        return candidate;
      } on FileSystemException catch (error) {
        last = error;
      }
    }
    throw last ?? const FileSystemException('no free name');
  }

  /// Только имя файла из [name] (имя вложения, имя от выбора файлов,
  /// которое на Android даёт чужое приложение): последняя часть пути, без
  /// `..`, разделителей и знаков, запрещённых в Windows.
  static String fileName(String name, {String fallback = 'Файл'}) => safeName(
        p.posix.basename(name.replaceAll('\\', '/')),
        fallback: fallback,
      );

  /// Имя для файла на диске: без `/ \ : * ? " < > |` и управляющих знаков,
  /// без точек и пробелов по краям. Пустое — [fallback].
  static String safeName(String name, {String fallback = 'Архив'}) {
    final cleaned = name
        .replaceAll(RegExp(r'[\u0000-\u001f\u007f/\\:*?"<>|]'), '_')
        .trim()
        .replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
    return cleaned.isEmpty ? fallback : cleaned;
  }
}
