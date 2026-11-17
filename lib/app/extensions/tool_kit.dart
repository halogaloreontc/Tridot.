import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/downloads/safe_tar.dart';
import '../../core/downloads/safe_zip.dart';
import '../../core/downloads/verified_download.dart';
import '../../core/extensions/tools/tool_spec.dart';

/// Этап установки внешней программы.
enum ToolPhase {
  notInstalled,
  downloading,
  verifying,
  installing,
  installed,
  error,
}

/// Почему программа не установилась.
enum ToolError {
  /// Нет сети или обрыв: скачанное сохранено, загрузка продолжится.
  network,

  /// Сервер отдал больше ожидаемого.
  tooLarge,

  /// Контрольная сумма архива или программы не совпала.
  checksum,

  /// Архив не прошёл проверку при распаковке.
  extract,

  /// Не удалось записать файлы (нет места, нет доступа).
  storage,
}

/// Текст ошибки для пользователя.
extension ToolErrorText on ToolError {
  String get message => switch (this) {
        ToolError.network => 'Не удалось скачать. Проверьте интернет — '
            'загрузка продолжится с места остановки',
        ToolError.tooLarge =>
          'Сервер отдаёт не тот файл: он больше ожидаемого. Попробуйте позже',
        ToolError.checksum =>
          'Файл повреждён или подменён: контрольная сумма не совпала. '
              'Он удалён',
        ToolError.extract => 'Архив не прошёл проверку',
        ToolError.storage => 'Не удалось сохранить. Проверьте свободное место',
      };
}

/// Распаковка одной программы из архива: в приложении — безопасная
/// распаковка ZIP или tar.xz только записи [ToolSpec.entry], в тестах —
/// что угодно. [scratch] — путь для временного `.tar`.
typedef ToolExtractor = Future<void> Function(
  ToolSpec spec,
  String archive,
  String dest,
  String scratch,
);

/// Права на запуск (`chmod 755`) после распаковки; на Windows не нужны.
typedef ToolChmod = Future<void> Function(String path);

/// Пределы распаковки архива программы: в архивах ffmpeg 30–50 записей,
/// всего около 420 МБ, программа — до 145 МБ.
const ZipLimits toolZipLimits = ZipLimits(
  maxEntries: 500,
  maxTotalBytes: 700 * 1024 * 1024,
  maxEntryBytes: 200 * 1024 * 1024,
  maxRatio: 200,
);

/// То же для tar.xz: степень сжатия не проверяется (размер распакованного
/// потока ограничен [ZipLimits.maxTotalBytes]).
const ZipLimits toolTarLimits = ZipLimits(
  maxEntries: 500,
  maxTotalBytes: 700 * 1024 * 1024,
  maxEntryBytes: 200 * 1024 * 1024,
);

Future<void> _extract(
  ToolSpec spec,
  String archive,
  String dest,
  String scratch,
) {
  switch (spec.archive) {
    case ToolArchive.none:
      // Распаковывать нечего: программа скачана сама по себе.
      return Future<void>.value();
    case ToolArchive.zip:
      return extractZipSafely(
        File(archive),
        Directory(dest),
        limits: toolZipLimits,
        onlyEntries: <String>{spec.entry},
      );
    case ToolArchive.tarXz:
      return extractTarXzSafely(
        archive,
        dest,
        scratch,
        limits: toolTarLimits,
        onlyEntries: <String>{spec.entry},
      );
  }
}

Future<void> _chmodExecutable(String path) async {
  if (Platform.isWindows) return;
  // Аргументы списком, без оболочки.
  final result = await Process.run('chmod', <String>['755', path]);
  if (result.exitCode != 0) {
    throw const FileSystemException('chmod');
  }
}

/// Внешняя программа расширения (ADR-024): ffmpeg для конвертера, yt-dlp
/// для загрузчика видео (без архива — [ToolArchive.none]).
///
/// Лежит в `<поддержка>/tools/<id>/<версия>/<программа>` и считается
/// установленной, только если рядом есть `installed.json` (пишется
/// последним) с версией, суммой архива и суммой самой программы.
/// Установка — только по кнопке: загрузка в `.part` с продолжением →
/// размер → SHA-256 архива → распаковка одной записи во временную папку
/// → права на запуск → SHA-256 программы → `installed.json` → удаление
/// архива. Перед первым запуском в этом сеансе приложения сумма программы
/// считается заново ([verifiedPath]); не совпала — программа удаляется.
final class ToolKit extends ChangeNotifier {
  ToolKit({
    required this.spec,
    required this.downloader,
    required this.dir,
    Future<String> Function(File file) hasher = sha256OfFile,
    ToolExtractor extractor = _extract,
    ToolChmod chmod = _chmodExecutable,
    DateTime Function() now = DateTime.now,
  })  : _hasher = hasher,
        _extractor = extractor,
        _chmod = chmod,
        _now = now;

  final ToolSpec spec;
  final FileDownloader downloader;

  /// Папка программы: `<поддержка>/tools/<id>`.
  final String dir;

  final Future<String> Function(File file) _hasher;
  final ToolExtractor _extractor;
  final ToolChmod _chmod;
  final DateTime Function() _now;

  ToolPhase _phase = ToolPhase.notInstalled;
  ToolError? _error;
  int _received = 0;
  bool _hasPartial = false;
  bool _verified = false;
  CancelToken? _cancel;
  Future<void>? _installing;
  Future<String?>? _verifying;
  bool _disposed = false;
  String? _olderVersion;

  ToolPhase get phase => _phase;

  /// Установлена прежняя версия программы (не эта сборка констант):
  /// «Обновить» поставит закреплённую в приложении.
  String? get olderVersion => _olderVersion;

  /// Ошибка, если [phase] — [ToolPhase.error].
  ToolError? get error => _error;

  /// Скачано байт.
  int get received => _received;

  /// Есть недокачанный архив.
  bool get hasPartial => _hasPartial;

  bool get isInstalled => _phase == ToolPhase.installed;

  bool get isBusy =>
      _phase == ToolPhase.downloading ||
      _phase == ToolPhase.verifying ||
      _phase == ToolPhase.installing;

  /// Путь программы после установки.
  String get binaryPath => p.join(dir, spec.version, spec.binaryName);

  String get _archiveName => p.posix.basename(spec.uri.path);

  File get _part => File(p.join(dir, '$_archiveName.part'));

  File get _archive => File(p.join(dir, _archiveName));

  File get _marker => File(p.join(dir, spec.version, 'installed.json'));

  void _set(ToolPhase phase, {ToolError? error}) {
    _phase = phase;
    _error = error;
    if (!_disposed) notifyListeners();
  }

  /// Состояние по файлам на диске.
  Future<void> refresh() async {
    if (isBusy) return;
    if (await _installedSha() != null) {
      _hasPartial = false;
      _olderVersion = null;
      _set(ToolPhase.installed);
    } else {
      _hasPartial = await _exists(_part) || await _exists(_archive);
      _olderVersion = await _findOlderVersion();
      _set(ToolPhase.notInstalled);
    }
  }

  /// Версия прежней установки (константы сменились с выпуском
  /// приложения) или `null`. Прежняя версия не запускается: её сумма
  /// закреплена уже не в этой сборке.
  Future<String?> _findOlderVersion() async {
    try {
      final folder = Directory(dir);
      if (!await folder.exists()) return null;
      await for (final entity in folder.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final name = p.basename(entity.path);
        if (name == spec.version || name.startsWith('tmp-')) continue;
        final marker = File(p.join(entity.path, 'installed.json'));
        if (!await marker.exists()) continue;
        final decoded = jsonDecode(await marker.readAsString());
        if (decoded is Map && decoded['version'] is String) {
          final version = decoded['version'] as String;
          if (RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(version)) {
            return version;
          }
        }
      }
    } on Object {
      return null;
    }
    return null;
  }

  /// Сумма программы из `installed.json`, если установка цела.
  Future<String?> _installedSha() async {
    try {
      if (!await _marker.exists()) return null;
      final decoded = jsonDecode(await _marker.readAsString());
      if (decoded is! Map ||
          decoded['version'] != spec.version ||
          decoded['sha256'] != spec.sha256) {
        return null;
      }
      final binary = decoded['binary_sha256'];
      if (binary is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(binary)) {
        return null;
      }
      if (!await File(binaryPath).exists()) return null;
      return binary;
    } on Object {
      return null;
    }
  }

  /// Скачивает, проверяет и распаковывает программу. Сборка без суммы из
  /// официального источника ([ToolSpec.available] — `false`) не
  /// скачивается никогда: [StateError].
  Future<void> install() {
    if (!spec.available) {
      return Future<void>.error(
        StateError('Сборка ${spec.id} недоступна: нет закреплённой суммы'),
      );
    }
    final running = _installing;
    if (running != null) return running;
    final cancel = _cancel = CancelToken();
    return _installing = _install(cancel).whenComplete(() {
      _installing = null;
      _cancel = null;
    });
  }

  /// Прерывает загрузку; скачанное остаётся для продолжения.
  void cancel() => _cancel?.cancel();

  Future<void> _install(CancelToken cancel) async {
    if (await _installedSha() != null) {
      await refresh();
      return;
    }
    final part = _part;
    try {
      if (cancel.isCancelled) {
        throw const DownloadException(DownloadError.cancelled);
      }
      await Directory(dir).create(recursive: true);
      await _deleteTemporary();
      if (await _archive.exists() && !await part.exists()) {
        await _archive.rename(part.path);
      }
      _received = await part.exists() ? await part.length() : 0;
      _set(ToolPhase.downloading);
      await for (final progress in downloader.download(
        spec.uri,
        part,
        expectedBytes: spec.bytes,
        cancel: cancel,
      )) {
        _received = progress.received;
        if (!_disposed) notifyListeners();
      }
      if (cancel.isCancelled) {
        throw const DownloadException(DownloadError.cancelled);
      }
      if (!await part.exists() || await part.length() != spec.bytes) {
        await _deleteQuietly(part);
        _set(ToolPhase.error, error: ToolError.network);
        return;
      }
      _set(ToolPhase.verifying);
      final digest = await _hasher(part);
      if (digest.toLowerCase() != spec.sha256) {
        await _deleteQuietly(part);
        _hasPartial = false;
        _set(ToolPhase.error, error: ToolError.checksum);
        return;
      }
      final archive = await part.rename(_archive.path);
      _set(ToolPhase.installing);
      if (spec.archive == ToolArchive.none) {
        // Сама программа (yt-dlp): проверенный файл становится программой.
        final versionDir = Directory(p.join(dir, spec.version));
        try {
          await _deleteQuietly(versionDir);
          await versionDir.create(recursive: true);
          await archive.rename(binaryPath);
          await _chmod(binaryPath);
        } on Object {
          await _deleteQuietly(versionDir);
          _hasPartial = await _exists(archive);
          _set(ToolPhase.error, error: ToolError.storage);
          return;
        }
        await _finishInstall(archive);
        return;
      }
      final stamp = _now().microsecondsSinceEpoch;
      final temporary = p.join(dir, 'tmp-$stamp');
      final scratch = p.join(dir, 'tmp-$stamp.tar');
      try {
        await _extractor(spec, archive.path, temporary, scratch);
        final extracted = File(p.join(temporary, spec.entry));
        if (!await extracted.exists()) {
          throw const UnsafeZipException('missing_required');
        }
        final versionDir = Directory(p.join(dir, spec.version));
        await _deleteQuietly(versionDir);
        await versionDir.create(recursive: true);
        await extracted.rename(binaryPath);
        await _chmod(binaryPath);
      } on Object catch (error) {
        await _deleteQuietly(Directory(temporary));
        await _deleteQuietly(File(scratch));
        await _deleteQuietly(Directory(p.join(dir, spec.version)));
        if (error is FileSystemException) {
          _hasPartial = await _exists(archive);
          _set(ToolPhase.error, error: ToolError.storage);
          return;
        }
        await _deleteQuietly(archive);
        _hasPartial = false;
        _set(ToolPhase.error, error: ToolError.extract);
        return;
      }
      await _deleteQuietly(Directory(temporary));
      await _finishInstall(archive);
    } on DownloadException catch (error) {
      switch (error.error) {
        case DownloadError.cancelled:
          _hasPartial = await _exists(part);
          _set(ToolPhase.notInstalled);
        case DownloadError.network:
          _hasPartial = await _exists(part);
          _set(ToolPhase.error, error: ToolError.network);
        case DownloadError.storage:
          _hasPartial = await _exists(part);
          _set(ToolPhase.error, error: ToolError.storage);
        case DownloadError.tooLarge:
        case DownloadError.sizeMismatch:
          await _deleteQuietly(part);
          _hasPartial = false;
          _set(ToolPhase.error, error: ToolError.tooLarge);
        case DownloadError.checksumMismatch:
          await _deleteQuietly(part);
          _hasPartial = false;
          _set(ToolPhase.error, error: ToolError.checksum);
      }
    } on Object {
      _hasPartial = await _exists(part);
      _set(ToolPhase.error, error: ToolError.storage);
    }
  }

  /// Сумма установленной программы → `installed.json` → уборка архива и
  /// старых версий.
  Future<void> _finishInstall(File archive) async {
    _set(ToolPhase.verifying);
    final binarySha = await _hasher(File(binaryPath));
    final marker = File('${_marker.path}.tmp');
    await marker.writeAsString(
      jsonEncode(<String, String>{
        'version': spec.version,
        'sha256': spec.sha256,
        'binary_sha256': binarySha.toLowerCase(),
      }),
      flush: true,
    );
    await marker.rename(_marker.path);
    await _deleteQuietly(archive);
    await _deleteOldVersions();
    _hasPartial = false;
    _olderVersion = null;
    _verified = true;
    _set(ToolPhase.installed);
  }

  /// Путь программы, если она установлена и её сумма совпадает с той, что
  /// записана при установке. Считается один раз за сеанс приложения (в
  /// отдельном изоляте); не совпала — программа удаляется, ответ `null`.
  Future<String?> verifiedPath() {
    if (_phase != ToolPhase.installed) return Future<String?>.value();
    if (_verified) return Future<String?>.value(binaryPath);
    return _verifying ??= _verify().whenComplete(() => _verifying = null);
  }

  Future<String?> _verify() async {
    final expected = await _installedSha();
    if (expected == null) {
      await refresh();
      return null;
    }
    String actual;
    try {
      actual = await _hasher(File(binaryPath));
    } on Object {
      actual = '';
    }
    // Программа без архива (yt-dlp) — сам скачанный файл: её сумма
    // известна заранее и сверяется ещё и с закреплённой в приложении, а не
    // только с записанной в installed.json (его можно подменить вместе с
    // программой).
    final pinned = spec.archive == ToolArchive.none &&
        actual.toLowerCase() != spec.sha256.toLowerCase();
    if (actual.toLowerCase() != expected || pinned) {
      await _deleteQuietly(Directory(p.join(dir, spec.version)));
      _set(ToolPhase.error, error: ToolError.checksum);
      return null;
    }
    _verified = true;
    return binaryPath;
  }

  /// Удаляет программу, недокачанный архив и временные файлы.
  Future<void> delete() async {
    cancel();
    try {
      await _installing;
    } on Object {
      // Установка и так прервана.
    }
    await _deleteQuietly(Directory(p.join(dir, spec.version)));
    await _deleteQuietly(_part);
    await _deleteQuietly(_archive);
    await _deleteTemporary();
    await _deleteOldVersions();
    _hasPartial = false;
    _olderVersion = null;
    _verified = false;
    _set(ToolPhase.notInstalled);
  }

  /// Старые версии программы (после обновления констант в выпуске).
  Future<void> _deleteOldVersions() async {
    final folder = Directory(dir);
    if (!await folder.exists()) return;
    await for (final entity in folder.list(followLinks: false)) {
      if (entity is Directory && p.basename(entity.path) != spec.version) {
        await _deleteQuietly(entity);
      }
    }
  }

  Future<void> _deleteTemporary() async {
    final folder = Directory(dir);
    if (!await folder.exists()) return;
    await for (final entity in folder.list(followLinks: false)) {
      if (p.basename(entity.path).startsWith('tmp-')) {
        await _deleteQuietly(entity);
      }
    }
  }

  static Future<bool> _exists(File file) async {
    try {
      return await file.exists();
    } on Object {
      return false;
    }
  }

  static Future<void> _deleteQuietly(FileSystemEntity entity) async {
    try {
      if (await entity.exists()) await entity.delete(recursive: true);
    } on Object {
      // Нечего удалять или нет доступа.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel?.cancel();
    super.dispose();
  }
}
