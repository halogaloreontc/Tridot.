import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

import '../../core/jobs/extension_card.dart';

/// Платформа этого устройства для карточек расширений.
JobPlatform currentJobPlatform() {
  if (Platform.isAndroid) return JobPlatform.android;
  if (Platform.isIOS) return JobPlatform.ios;
  if (Platform.isWindows) return JobPlatform.windows;
  if (Platform.isMacOS) return JobPlatform.macos;
  return JobPlatform.linux;
}

/// Выбор файлов и мест для карточек расширений; в тестах — подделка.
abstract interface class JobFilePicker {
  /// Файлы с диска; отменили — пусто. На Android это копии во временной
  /// папке приложения (file_selector).
  Future<List<JobFile>> files();

  /// Папка целиком (компьютер); отменили — `null`.
  Future<JobFile?> folder();

  /// Куда сохранить файл [suggestedName] (macOS, песочница): путь или
  /// `null`.
  Future<String?> saveFile(String suggestedName, String initialDirectory);

  /// В какую папку распаковать (macOS, песочница): путь или `null`.
  Future<String?> chooseFolder(String initialDirectory);
}

/// Системный выбор (пакет file_selector).
final class FileSelectorJobPicker implements JobFilePicker {
  const FileSelectorJobPicker();

  @override
  Future<List<JobFile>> files() async {
    final picked = await openFiles();
    return <JobFile>[
      for (final file in picked)
        if (file.path.isNotEmpty)
          JobFile(
            path: file.path,
            name: file.name.isEmpty ? p.basename(file.path) : file.name,
          ),
    ];
  }

  @override
  Future<JobFile?> folder() async {
    final path = await getDirectoryPath();
    if (path == null || path.isEmpty) return null;
    return JobFile(path: path, name: p.basename(path), folder: true);
  }

  @override
  Future<String?> saveFile(
    String suggestedName,
    String initialDirectory,
  ) async =>
      (await getSaveLocation(
        suggestedName: suggestedName,
        initialDirectory: initialDirectory,
      ))
          ?.path;

  @override
  Future<String?> chooseFolder(String initialDirectory) =>
      getDirectoryPath(initialDirectory: initialDirectory);
}

/// Копии файлов, которые выбор файлов на Android кладёт во временную
/// папку (`<cache>/<uuid>/<имя>`), остаются после ошибки или отмены задачи
/// — для «Повторить». Старше суток они не нужны и удаляются при запуске.
Future<void> dropPickerLeftovers(
  Directory temp, {
  DateTime? now,
  Duration age = const Duration(days: 1),
}) async {
  final uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
  final limit = (now ?? DateTime.now()).subtract(age);
  await for (final entity in temp.list(followLinks: false)) {
    if (entity is! Directory || !uuid.hasMatch(p.basename(entity.path))) {
      continue;
    }
    try {
      if ((await entity.stat()).modified.isBefore(limit)) {
        await entity.delete(recursive: true);
      }
    } on Object {
      // Не вышло — в следующий раз.
    }
  }
}
