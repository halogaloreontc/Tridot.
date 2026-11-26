import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/connectors/http_transport.dart';
import '../../core/downloads/verified_download.dart';
import '../../core/gen/gen_model.dart';
import '../../core/gen/gen_release.dart';
import '../../core/intent/intent_release.dart';
import '../../core/settings/app_settings.dart';

export '../../core/gen/gen_release.dart';

/// Этап установки «Продвинутой».
enum GenKitPhase { idle, checking, downloading, verifying, error }

/// Почему модель не установилась.
enum GenKitError { network, release, lowMemory, tooLarge, checksum, storage }

extension GenKitErrorText on GenKitError {
  String get message => switch (this) {
        GenKitError.network => 'Не удалось скачать модель. Проверьте '
            'интернет — загрузка продолжится с места остановки',
        GenKitError.release =>
          'Модель сейчас недоступна для загрузки. Попробуйте позже',
        GenKitError.lowMemory => 'На этом устройстве мало памяти для '
            '«Продвинутой»: нужно от 8 ГБ',
        GenKitError.tooLarge =>
          'Сервер отдаёт не тот файл: он больше ожидаемого. Попробуйте позже',
        GenKitError.checksum => 'Файл повреждён: контрольная сумма не совпала',
        GenKitError.storage =>
          'Не удалось сохранить модель. Проверьте свободное место',
      };
}

/// Установленная модель.
final class GenInstalled {
  const GenInstalled({
    required this.version,
    required this.path,
    required this.bytes,
  });

  final String version;
  final String path;
  final int bytes;
}

/// Открыть модель из файла GGUF; `null` — не загрузилась.
typedef GenModelOpener = Future<GenModel?> Function(String path);

/// Объём памяти устройства в МБ; `null` — не узнать.
typedef RamProbe = Future<int?> Function();

/// `MemTotal` из `/proc/meminfo` — Linux и Android; иначе `null`.
Future<int?> procMemTotalMb() async {
  try {
    final text = await File('/proc/meminfo').readAsString();
    final m =
        RegExp(r'^MemTotal:\s+(\d+)\s+kB', multiLine: true).firstMatch(text);
    return m == null ? null : int.parse(m.group(1)!) ~/ 1024;
  } on Object {
    return null;
  }
}

/// «Продвинутая» на устройстве (ADR-046): загрузка, проверка, обновление,
/// удаление и сама модель.
///
/// Сеть — только по нажатию: «Скачать», «Проверить обновление». Установка:
/// `latest.json` → проверка памяти → `gen-<версия>.gguf.part` с
/// продолжением → размер → sha256 целиком → `.gguf` → указатель
/// `active.json` (через временный файл) → удаление прежних версий. Модель
/// загружается при первом вопросе ([model]) и остаётся в памяти до
/// выключения или удаления.
final class GenKit extends ChangeNotifier {
  GenKit({
    required this.transport,
    required this.downloader,
    required this.root,
    required this.opener,
    RamProbe ram = procMemTotalMb,
    Future<String> Function(File file) hasher = sha256OfFile,
    this.devModel,
  })  : _ram = ram,
        _hasher = hasher;

  final HttpTransport transport;
  final FileDownloader downloader;

  /// `<поддержка>/assistant/gen`.
  final String root;
  final GenModelOpener opener;

  /// Файл модели для разработки (`TRIDOT_GEN_MODEL`): работает при любом
  /// переключателе, ничего не скачивая.
  final String? devModel;

  final RamProbe _ram;
  final Future<String> Function(File file) _hasher;

  /// Примерный размер, пока `latest.json` не прочитан.
  static const int approxBytes = 2900 * 1000 * 1000;

  GenKitPhase _phase = GenKitPhase.idle;
  GenKitError? _error;
  int _received = 0;
  int _total = 0;
  bool _hasPartial = false;
  GenInstalled? _installed;
  GenRelease? _release;
  bool _checking = false;
  GenKitError? _checkError;
  bool _enabled = false;
  int? _ramMb;
  bool _ramKnown = false;
  CancelToken? _cancel;
  Future<void>? _installing;
  Future<GenModel?>? _model;
  bool _disposed = false;

  GenKitPhase get phase => _phase;
  GenKitError? get error => _error;
  int get received => _received;
  int get total => _total;
  bool get hasPartial => _hasPartial;
  GenInstalled? get installed => _installed;
  GenRelease? get release => _release;
  bool get checking => _checking;
  GenKitError? get checkError => _checkError;
  bool get enabled => _enabled;

  /// Память устройства в МБ (после [refresh]); `null` — не узнать.
  int? get ramMb => _ramMb;

  bool get isBusy =>
      _phase == GenKitPhase.checking ||
      _phase == GenKitPhase.downloading ||
      _phase == GenKitPhase.verifying;

  /// Памяти хватает или её не узнать (тогда решает человек).
  bool get enoughMemory {
    final ram = _ramMb;
    return ram == null ||
        ram >= (_release?.minRamMb ?? GenRelease.defaultMinRamMb);
  }

  int get bytes => _release?.size ?? approxBytes;

  bool get updateAvailable {
    final i = _installed;
    final r = _release;
    return i != null && r != null && r.newerThan(i.version);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _set(GenKitPhase phase, {GenKitError? error}) {
    _phase = phase;
    _error = error;
    _notify();
  }

  File get _pointer => File(p.join(root, 'active.json'));

  static final RegExp _modelName = RegExp(r'^gen-\d+\.\d+\.\d+\.gguf$');

  /// Недокачанное: склеенное начало и части.
  static final RegExp _pieceName =
      RegExp(r'^gen-\d+\.\d+\.\d+\.gguf\.(part|\d{3})$');

  /// Состояние по диску и память устройства: при запуске.
  Future<void> refresh() async {
    if (!_ramKnown) {
      _ramMb = await _ram();
      _ramKnown = true;
    }
    if (isBusy) return;
    _installed = await _readInstalled();
    _hasPartial = await _anyPartial();
    _notify();
  }

  Future<GenInstalled?> _readInstalled() async {
    try {
      if (!await _pointer.exists()) return null;
      final json = jsonDecode(await _pointer.readAsString());
      if (json is! Map<String, Object?>) return null;
      final version = json['version'];
      final file = json['file'];
      if (version is! String || file is! String || !_modelName.hasMatch(file)) {
        return null;
      }
      final f = File(p.join(root, file));
      if (!await f.exists()) return null;
      return GenInstalled(
        version: version,
        path: f.path,
        bytes: await f.length(),
      );
    } on Object {
      return null;
    }
  }

  Future<bool> _anyPartial() async {
    try {
      final dir = Directory(root);
      if (!await dir.exists()) return false;
      await for (final e in dir.list(followLinks: false)) {
        if (e is File && _pieceName.hasMatch(p.basename(e.path))) return true;
      }
    } on Object {
      // Нет доступа.
    }
    return false;
  }

  /// Переключатель «Продвинутая» из настроек.
  Future<void> apply(AppSettings settings) async {
    if (_enabled == settings.genEnabled) return;
    _enabled = settings.genEnabled;
    if (!_enabled) await _unload();
    _notify();
  }

  /// Модель для навыков: загружается при первом вызове. `null` — выключено,
  /// не скачано или не загрузилась.
  Future<GenModel?> model() {
    final dev = devModel;
    final path = dev ?? (_enabled ? _installed?.path : null);
    if (path == null) return Future<GenModel?>.value();
    return _model ??= opener(path).then((GenModel? m) {
      if (m == null) _model = null;
      return m;
    });
  }

  Future<void> _unload() async {
    final loading = _model;
    _model = null;
    final m = await loading;
    if (m is Closeable) await (m as Closeable).close();
  }

  /// «Проверить обновление»: только по нажатию.
  Future<void> checkUpdate() async {
    if (_checking) return;
    _checking = true;
    _checkError = null;
    _notify();
    try {
      _release = await _fetchRelease();
    } on _Failure catch (f) {
      _checkError = f.error;
    }
    _checking = false;
    _notify();
  }

  Future<GenRelease> _fetchRelease() async {
    var uri = GenRelease.latestUrl;
    for (var hop = 0; hop <= 3; hop++) {
      final HttpResponseData response;
      try {
        response = await transport.send(
          HttpRequestData(
            method: 'GET',
            uri: uri,
            headers: const <String, String>{'accept': 'application/json'},
            timeout: const Duration(seconds: 20),
          ),
        );
      } on Object {
        throw const _Failure(GenKitError.network);
      }
      final status = response.statusCode;
      if (status >= 300 && status < 400) {
        final location = response.headers['location'];
        final next = location == null ? null : uri.resolve(location);
        if (next == null ||
            next.scheme != 'https' ||
            !(next.host == GenRelease.latestUrl.host ||
                IntentRelease.redirectHosts.contains(next.host))) {
          throw const _Failure(GenKitError.release);
        }
        uri = next;
        continue;
      }
      if (status == 404 || status == 410) {
        throw const _Failure(GenKitError.release);
      }
      if (!response.isSuccess) throw const _Failure(GenKitError.network);
      try {
        return GenRelease.parse(response.body);
      } on GenReleaseException {
        throw const _Failure(GenKitError.release);
      }
    }
    throw const _Failure(GenKitError.release);
  }

  /// Скачать и установить модель (или её новую версию).
  Future<void> install() {
    final running = _installing;
    if (running != null) return running;
    final cancel = _cancel = CancelToken();
    return _installing = _install(cancel).whenComplete(() {
      _installing = null;
      _cancel = null;
    });
  }

  void cancel() => _cancel?.cancel();

  Future<void> get whenIdle async {
    try {
      await _installing;
    } on Object {
      // Установка и так закончилась.
    }
  }

  Future<void> _install(CancelToken cancel) async {
    _received = 0;
    _total = bytes;
    _set(GenKitPhase.checking);
    final GenRelease release;
    try {
      release = await _fetchRelease();
    } on _Failure catch (f) {
      _set(GenKitPhase.error, error: f.error);
      return;
    }
    _release = release;
    if (!enoughMemory) {
      _set(GenKitPhase.error, error: GenKitError.lowMemory);
      return;
    }
    final current = _installed;
    if (current != null &&
        IntentRelease.compareVersions(release.version, current.version) <= 0) {
      _set(GenKitPhase.idle);
      return;
    }
    final name = 'gen-${release.version}.gguf';
    // Склеенное начало модели; части качаются по одной в `<имя>.NNN` и
    // дописываются сюда, как только прошли проверку.
    final part = File(p.join(root, '$name.part'));
    final target = File(p.join(root, name));
    try {
      await Directory(root).create(recursive: true);
      await _deleteOther(keep: name, keepPrefix: '$name.');
      var done = await part.exists() ? await part.length() : 0;
      _received = done;
      _total = release.size;
      _set(GenKitPhase.downloading);
      var start = 0;
      for (final (i, piece) in release.parts.indexed) {
        final end = start + piece.size;
        if (done >= end) {
          start = end;
          continue;
        }
        if (done != start) {
          // Склеенное не на границе части: начать заново.
          await _deleteQuietly(part);
          done = 0;
          _hasPartial = false;
          _set(GenKitPhase.error, error: GenKitError.checksum);
          return;
        }
        final file =
            File(p.join(root, '$name.${(i + 1).toString().padLeft(3, '0')}'));
        await for (final progress in downloader.download(
          piece.url,
          file,
          expectedBytes: piece.size,
          cancel: cancel,
        )) {
          _received = start + progress.received;
          _notify();
        }
        if (cancel.isCancelled) {
          throw const DownloadException(DownloadError.cancelled);
        }
        if (await file.length() != piece.size ||
            (await _hasher(file)).toLowerCase() != piece.sha256) {
          await _deleteQuietly(file);
          _set(GenKitPhase.error, error: GenKitError.checksum);
          return;
        }
        final sink = part.openWrite(mode: FileMode.append);
        await sink.addStream(file.openRead());
        await sink.flush();
        await sink.close();
        await _deleteQuietly(file);
        done = end;
        start = end;
      }
      _set(GenKitPhase.verifying);
      if (await part.length() != release.size ||
          (await _hasher(part)).toLowerCase() != release.sha256) {
        await _deleteQuietly(part);
        _hasPartial = false;
        _set(GenKitPhase.error, error: GenKitError.checksum);
        return;
      }
      await _unload();
      await part.rename(target.path);
      final tmp = File('${_pointer.path}.tmp');
      await tmp.writeAsString(
        jsonEncode(<String, String>{
          'version': release.version,
          'file': name,
          'sha256': release.sha256,
        }),
        flush: true,
      );
      await tmp.rename(_pointer.path);
      _installed = GenInstalled(
        version: release.version,
        path: target.path,
        bytes: release.size,
      );
      _hasPartial = false;
      await _deleteOther(keep: name);
      _set(GenKitPhase.idle);
    } on DownloadException catch (e) {
      _hasPartial = await _anyPartial();
      switch (e.error) {
        case DownloadError.cancelled:
          _set(GenKitPhase.idle);
        case DownloadError.network:
          _set(GenKitPhase.error, error: GenKitError.network);
        case DownloadError.storage:
          _set(GenKitPhase.error, error: GenKitError.storage);
        case DownloadError.tooLarge || DownloadError.sizeMismatch:
          await _deleteOther(keep: target.path);
          _hasPartial = false;
          _set(GenKitPhase.error, error: GenKitError.tooLarge);
        case DownloadError.checksumMismatch:
          await _deleteOther(keep: target.path);
          _hasPartial = false;
          _set(GenKitPhase.error, error: GenKitError.checksum);
      }
    } on FileSystemException {
      _hasPartial = await _anyPartial();
      _set(GenKitPhase.error, error: GenKitError.storage);
    }
  }

  void dismissError() {
    if (_phase == GenKitPhase.error) _set(GenKitPhase.idle);
  }

  /// «Удалить модель»: выгрузить, удалить файлы и недокачанное.
  Future<void> delete() async {
    cancel();
    await whenIdle;
    await _unload();
    await _deleteQuietly(_pointer);
    await _deleteOther();
    _installed = null;
    _hasPartial = false;
    _set(GenKitPhase.idle);
  }

  /// Удаляет модели и недокачанное, кроме [keep] и файлов, начинающихся
  /// с [keepPrefix] (недокачанное той же версии).
  Future<void> _deleteOther({String? keep, String? keepPrefix}) async {
    final dir = Directory(root);
    if (!await dir.exists()) return;
    await for (final e in dir.list(followLinks: false)) {
      final name = p.basename(e.path);
      if (name == keep || (keepPrefix != null && name.startsWith(keepPrefix))) {
        continue;
      }
      if (_modelName.hasMatch(name) || _pieceName.hasMatch(name)) {
        await _deleteQuietly(e);
      }
    }
  }

  static Future<void> _deleteQuietly(FileSystemEntity e) async {
    try {
      if (await e.exists()) await e.delete(recursive: true);
    } on Object {
      // Нечего удалять.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    unawaited(_unload());
    super.dispose();
  }
}

/// Модель, которую нужно закрыть (llama.cpp держит память и файл).
abstract interface class Closeable {
  Future<void> close();
}

final class _Failure implements Exception {
  const _Failure(this.error);

  final GenKitError error;
}
