import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/connectors/http_transport.dart';
import '../../core/downloads/safe_zip.dart';
import '../../core/downloads/verified_download.dart';
import '../../core/intent/intent_fallback.dart';
import '../../core/intent/intent_io.dart';
import '../../core/intent/intent_release.dart';
import '../../core/settings/app_settings.dart';
import '../voice/voice_kit.dart' show ZipExtractor;

export '../../core/intent/intent_release.dart';

/// Где живёт модель: [IntentSetup] в приложении, подделка в тестах.
abstract interface class IntentModelHost {
  /// Запасной слой: память и текущая модель.
  IntentFallback get fallback;

  /// Папка пакета для разработки (`TRIDOT_INTENT_PACK`) или `null`.
  String? get devPack;

  /// Загрузить пакет из [dir]; прежняя модель закрывается. `false` — не
  /// вышло, прежняя модель остаётся.
  Future<bool> load(String dir);

  /// Выгрузить модель.
  Future<void> unload();
}

/// Этап установки модели понимания.
enum IntentKitPhase {
  idle,

  /// Читаем `latest.json`.
  checking,
  downloading,
  verifying,
  installing,
  error,
}

/// Почему модель не установилась.
enum IntentKitError {
  /// Нет сети или обрыв: скачанное сохранено, загрузка продолжится.
  network,

  /// `latest.json` нет, он битый или в нём нет этого уровня.
  release,

  /// Сервер отдал больше ожидаемого.
  tooLarge,

  /// sha256 архива не совпала.
  checksum,

  /// Архив или пакет не прошёл проверку.
  extract,

  /// Не удалось записать файлы (нет места, нет доступа).
  storage,
}

/// Текст ошибки для пользователя.
extension IntentKitErrorText on IntentKitError {
  String get message => switch (this) {
        IntentKitError.network => 'Не удалось скачать модель. Проверьте '
            'интернет — загрузка продолжится с места остановки',
        IntentKitError.release =>
          'Модель сейчас недоступна для загрузки. Попробуйте позже',
        IntentKitError.tooLarge =>
          'Сервер отдаёт не тот файл: он больше ожидаемого. Попробуйте позже',
        IntentKitError.checksum =>
          'Файл повреждён: контрольная сумма не совпала',
        IntentKitError.extract => 'Архив модели не прошёл проверку',
        IntentKitError.storage =>
          'Не удалось сохранить модель. Проверьте свободное место',
      };
}

/// Установленный пакет: уровень, версия, папка.
final class IntentInstalled {
  const IntentInstalled({
    required this.tier,
    required this.version,
    required this.path,
    this.bytes = 0,
  });

  final IntentTier tier;
  final String version;

  /// `<поддержка>/assistant/intent/<уровень>-<версия>`.
  final String path;

  /// Сколько места занимает.
  final int bytes;
}

/// Проверка распакованного пакета: манифест или исключение.
typedef IntentPackVerifier = Future<IntentManifest> Function(String dir);

Future<IntentManifest> _verifyInIsolate(String dir) =>
    Isolate.run(() => verifyPackDirectory(dir), debugName: 'intent-verify');

/// Модель понимания на устройстве (ADR-041, шаг 3): выбор уровня,
/// загрузка, проверка, обновление; переключатели учёбы и журнала.
///
/// Сеть — только по явному действию: «Скачать», «Проверить обновление».
/// Установка: `latest.json` → архив уровня в `<уровень>-<версия>.zip.part`
/// с продолжением → размер → sha256 целиком → `.zip` → распаковка в
/// `tmp-…` → проверка манифеста и sha256 каждого файла → папка
/// `<уровень>-<версия>` → указатель `active.json` (через временный файл,
/// атомарно) → загрузка модели → удаление прежних версий и архива.
final class IntentKit extends ChangeNotifier {
  IntentKit({
    required this.host,
    required this.transport,
    required this.downloader,
    required this.root,
    Future<String> Function(File file) hasher = sha256OfFile,
    ZipExtractor extractor = extractZipSafely,
    IntentPackVerifier verifier = _verifyInIsolate,
    DateTime Function() now = DateTime.now,
  })  : _hasher = hasher,
        _extractor = extractor,
        _verifier = verifier,
        _now = now;

  final IntentModelHost host;

  /// Для `latest.json` (маленький файл).
  final HttpTransport transport;

  /// Для архива: с продолжением и отменой.
  final FileDownloader downloader;

  /// `<поддержка>/assistant/intent`.
  final String root;

  final Future<String> Function(File file) _hasher;
  final ZipExtractor _extractor;
  final IntentPackVerifier _verifier;
  final DateTime Function() _now;

  /// Примерные размеры архивов, пока `latest.json` не прочитан.
  static const Map<IntentTier, int> approxBytes = <IntentTier, int>{
    IntentTier.light: 32 * 1000 * 1000,
    IntentTier.accurate: 131 * 1000 * 1000,
  };

  /// Больше этого — совет скачивать по Wi‑Fi.
  static const int wifiHintBytes = 50 * 1000 * 1000;

  /// Пределы распаковки пакета.
  static const ZipLimits limits = ZipLimits(
    maxEntries: 32,
    maxTotalBytes: 640 * 1024 * 1024,
    maxEntryBytes: 512 * 1024 * 1024,
    maxRatio: 200,
  );

  IntentKitPhase _phase = IntentKitPhase.idle;
  IntentKitError? _error;
  IntentTier? _busyTier;
  int _received = 0;
  int _total = 0;
  bool _hasPartial = false;
  IntentInstalled? _installed;
  IntentRelease? _release;
  bool _checking = false;
  IntentKitError? _checkError;
  bool _checked = false;
  IntentTier _desired = IntentTier.off;
  String? _loadedPath;
  bool _loadFailed = false;
  bool _devLoaded = false;
  CancelToken? _cancel;
  Future<void>? _installing;
  Future<void> _syncs = Future<void>.value();
  bool _disposed = false;

  IntentMemory get memory => host.fallback.memory;

  IntentKitPhase get phase => _phase;
  IntentKitError? get error => _error;

  /// Какой уровень сейчас скачивается (или не скачался).
  IntentTier? get busyTier => _busyTier;

  int get received => _received;
  int get total => _total;

  bool get isBusy => switch (_phase) {
        IntentKitPhase.checking ||
        IntentKitPhase.downloading ||
        IntentKitPhase.verifying ||
        IntentKitPhase.installing =>
          true,
        _ => false,
      };

  /// Есть недокачанный архив: загрузка продолжится.
  bool get hasPartial => _hasPartial;

  IntentInstalled? get installed => _installed;

  /// Последний прочитанный `latest.json`.
  IntentRelease? get release => _release;

  /// Идёт «Проверить обновление».
  bool get checking => _checking;

  /// Чем кончилась последняя проверка обновления.
  IntentKitError? get checkError => _checkError;

  /// Проверка обновления была и прошла.
  bool get checked => _checked;

  /// Уровень из настроек.
  IntentTier get desired => _desired;

  /// Модель работает (загружена из установленного пакета или папки
  /// разработки).
  bool get running => _loadedPath != null || _devLoaded;

  /// Модель скачана, но не запустилась на этом устройстве.
  bool get loadFailed => _loadFailed;

  /// В `latest.json` версия новее установленной.
  bool get updateAvailable {
    final installed = _installed;
    final release = _release;
    if (installed == null || release == null) return false;
    return release.of(installed.tier) != null &&
        release.newerThan(installed.version);
  }

  /// Размер архива [tier]: из `latest.json` или примерный.
  int bytesOf(IntentTier tier) =>
      _release?.of(tier)?.size ?? approxBytes[tier] ?? 0;

  /// Описание команды из меток загруженной модели («создать задачу»).
  String? describe(String? label) {
    if (label == null) return null;
    final description =
        host.fallback.model?.index.labels.byId(label)?.description;
    return description == null || description.isEmpty ? null : description;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _set(IntentKitPhase phase, {IntentKitError? error}) {
    _phase = phase;
    _error = error;
    _notify();
  }

  File get _pointer => File(p.join(root, 'active.json'));

  static final RegExp _packName = RegExp(r'^(light|accurate)-\d+\.\d+\.\d+$');

  /// Состояние по диску: при запуске.
  Future<void> refresh() async {
    if (isBusy) return;
    _installed = await _readInstalled();
    _hasPartial = await _anyPartial();
    _notify();
  }

  Future<IntentInstalled?> _readInstalled() async {
    try {
      if (await _pointer.exists()) {
        final json = jsonDecode(await _pointer.readAsString());
        if (json is Map<String, Object?>) {
          final tier = IntentTier.parse(json['tier']);
          final version = json['version'];
          final dir = json['dir'];
          if (tier != IntentTier.off &&
              version is String &&
              dir is String &&
              _packName.hasMatch(dir)) {
            final path = p.join(root, dir);
            if (DirectoryPackSource(path).exists) {
              return IntentInstalled(
                tier: tier,
                version: version,
                path: path,
                bytes: await _sizeOf(Directory(path)),
              );
            }
          }
        }
      }
      // Пакет, положенный руками в `active/` (шаг 2).
      final legacy = p.join(root, 'active');
      if (DirectoryPackSource(legacy).exists) {
        final manifest = await IntentPack.readManifest(
          DirectoryPackSource(legacy),
        );
        final tier = IntentTier.parse(manifest.tier);
        if (tier != IntentTier.off) {
          return IntentInstalled(
            tier: tier,
            version: manifest.version,
            path: legacy,
            bytes: await _sizeOf(Directory(legacy)),
          );
        }
      }
    } on Object {
      // Битый указатель или манифест — модели нет.
    }
    return null;
  }

  Future<bool> _anyPartial() async {
    final dir = Directory(root);
    try {
      if (!await dir.exists()) return false;
      await for (final entity in dir.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (entity is File &&
            (name.endsWith('.zip.part') || name.endsWith('.zip'))) {
          return true;
        }
      }
    } on Object {
      // Нет доступа.
    }
    return false;
  }

  /// Настройки → память и модель: «Учиться», «Собирать», уровень.
  Future<void> apply(AppSettings settings) async {
    await memory.setLearning(settings.intentLearning);
    await memory.setLogging(settings.intentLogging);
    if (_desired != settings.intentTier) {
      _desired = settings.intentTier;
      _notify();
    }
    await _sync();
  }

  /// Модель по уровню из настроек: «Выключено» — выгрузить; иначе —
  /// установленный пакет (пока скачивается другой уровень, работает
  /// прежний). По очереди: смена уровня во время загрузки не путает.
  Future<void> _sync() {
    final next = _syncs.then((_) => _doSync());
    _syncs = next.catchError((Object _) {});
    return next;
  }

  Future<void> _doSync() async {
    final dev = host.devPack;
    if (dev != null) {
      if (!_devLoaded) _devLoaded = await host.load(dev);
      _notify();
      return;
    }
    final installed = _installed;
    if (_desired == IntentTier.off || installed == null) {
      if (_loadedPath != null) {
        _loadedPath = null;
        await host.unload();
      }
      _loadFailed = false;
      _notify();
      return;
    }
    if (_loadedPath == installed.path) return;
    final ok = await host.load(installed.path);
    _loadedPath = ok ? installed.path : null;
    _loadFailed = !ok;
    _notify();
  }

  /// «Проверить обновление»: читает `latest.json`. Только по нажатию.
  Future<void> checkUpdate() async {
    if (_checking) return;
    _checking = true;
    _checkError = null;
    _notify();
    try {
      _release = await _fetchRelease();
      _checked = true;
    } on _ReleaseFailure catch (failure) {
      _checkError = failure.error;
    }
    _checking = false;
    _notify();
  }

  Future<IntentRelease> _fetchRelease() async {
    var uri = IntentRelease.latestUrl;
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
        throw const _ReleaseFailure(IntentKitError.network);
      }
      final status = response.statusCode;
      if (status >= 300 && status < 400) {
        final location = response.headers['location'];
        final next = location == null ? null : uri.resolve(location);
        if (next == null ||
            next.scheme != 'https' ||
            !(next.host == IntentRelease.latestUrl.host ||
                IntentRelease.redirectHosts.contains(next.host))) {
          throw const _ReleaseFailure(IntentKitError.release);
        }
        uri = next;
        continue;
      }
      if (status == 404 || status == 410) {
        throw const _ReleaseFailure(IntentKitError.release);
      }
      if (!response.isSuccess) {
        throw const _ReleaseFailure(IntentKitError.network);
      }
      try {
        return IntentRelease.parse(response.body);
      } on IntentReleaseException {
        throw const _ReleaseFailure(IntentKitError.release);
      }
    }
    throw const _ReleaseFailure(IntentKitError.release);
  }

  /// Скачать и установить [tier] (или его новую версию). Повторный вызов
  /// во время установки возвращает ту же установку.
  Future<void> install(IntentTier tier) {
    final running = _installing;
    if (running != null) {
      // Прежняя установка уже готова и только убирает старые версии —
      // новая начнётся следом, а не потеряется.
      return isBusy ? running : running.then((_) => install(tier));
    }
    if (tier == IntentTier.off) return Future<void>.value();
    final cancel = _cancel = CancelToken();
    return _installing = _install(tier, cancel).whenComplete(() {
      _installing = null;
      _cancel = null;
    });
  }

  /// Прервать загрузку; скачанное остаётся для продолжения.
  void cancel() => _cancel?.cancel();

  /// Завершается, когда установки нет (после [cancel] — когда она
  /// остановилась).
  Future<void> get whenIdle async {
    try {
      await _installing;
    } on Object {
      // Установка и так закончилась.
    }
  }

  Future<void> _install(IntentTier tier, CancelToken cancel) async {
    _busyTier = tier;
    _received = 0;
    _total = bytesOf(tier);
    _set(IntentKitPhase.checking);
    final IntentRelease release;
    try {
      release = await _fetchRelease();
    } on _ReleaseFailure catch (failure) {
      _set(IntentKitPhase.error, error: failure.error);
      return;
    }
    _release = release;
    _checked = true;
    final entry = release.of(tier);
    if (entry == null) {
      _set(IntentKitPhase.error, error: IntentKitError.release);
      return;
    }
    final current = _installed;
    if (current != null &&
        current.tier == tier &&
        IntentRelease.compareVersions(release.version, current.version) <= 0) {
      _busyTier = null;
      _set(IntentKitPhase.idle);
      await _sync();
      return;
    }
    final name = '${tier.id}-${release.version}';
    final part = File(p.join(root, '$name.zip.part'));
    final zip = File(p.join(root, '$name.zip'));
    try {
      if (cancel.isCancelled) {
        throw const DownloadException(DownloadError.cancelled);
      }
      await Directory(root).create(recursive: true);
      await _deleteLeftovers(keep: name);
      if (await zip.exists() && !await part.exists()) {
        await zip.rename(part.path);
      }
      _received = await part.exists() ? await part.length() : 0;
      _total = entry.size;
      _set(IntentKitPhase.downloading);
      await for (final progress in downloader.download(
        entry.url,
        part,
        expectedBytes: entry.size,
        cancel: cancel,
      )) {
        _received = progress.received;
        _total = progress.total;
        _notify();
      }
      if (cancel.isCancelled) {
        throw const DownloadException(DownloadError.cancelled);
      }
      if (!await part.exists() || await part.length() != entry.size) {
        await _deleteQuietly(part);
        _hasPartial = false;
        _set(IntentKitPhase.error, error: IntentKitError.network);
        return;
      }
      _set(IntentKitPhase.verifying);
      final digest = await _hasher(part);
      if (digest.toLowerCase() != entry.sha256) {
        await _deleteQuietly(part);
        _hasPartial = false;
        _set(IntentKitPhase.error, error: IntentKitError.checksum);
        return;
      }
      await part.rename(zip.path);
      _set(IntentKitPhase.installing);
      final temporary = Directory(
        p.join(root, 'tmp-${_now().microsecondsSinceEpoch}'),
      );
      try {
        await _extractor(zip, temporary, limits: limits);
        final manifest = await _verifier(temporary.path);
        if (manifest.tier != tier.id || manifest.version != release.version) {
          throw const IntentPackException('не тот уровень или версия');
        }
      } on Object catch (error) {
        await _deleteQuietly(temporary);
        if (error is FileSystemException) {
          _hasPartial = await _exists(zip);
          _set(IntentKitPhase.error, error: IntentKitError.storage);
          return;
        }
        await _deleteQuietly(zip);
        _hasPartial = false;
        _set(IntentKitPhase.error, error: IntentKitError.extract);
        return;
      }
      final target = Directory(p.join(root, name));
      await _deleteQuietly(target);
      await temporary.rename(target.path);
      final pointer = File('${_pointer.path}.tmp');
      await pointer.writeAsString(
        jsonEncode(<String, String>{
          'tier': tier.id,
          'version': release.version,
          'dir': name,
          'sha256': entry.sha256,
        }),
        flush: true,
      );
      await pointer.rename(_pointer.path);
      await _deleteQuietly(zip);
      _hasPartial = false;
      _installed = IntentInstalled(
        tier: tier,
        version: release.version,
        path: target.path,
        bytes: await _sizeOf(target),
      );
      _busyTier = null;
      _set(IntentKitPhase.idle);
      // Сначала новая модель, потом удаление прежней: открытый файл
      // прежней модели закрывается при загрузке новой.
      await _sync();
      await _deleteOldPacks(keep: name);
    } on DownloadException catch (error) {
      switch (error.error) {
        case DownloadError.cancelled:
          _hasPartial = await _exists(part);
          _busyTier = null;
          _set(IntentKitPhase.idle);
        case DownloadError.network:
          _hasPartial = await _exists(part);
          _set(IntentKitPhase.error, error: IntentKitError.network);
        case DownloadError.storage:
          _hasPartial = await _exists(part);
          _set(IntentKitPhase.error, error: IntentKitError.storage);
        case DownloadError.tooLarge:
        case DownloadError.sizeMismatch:
          await _deleteQuietly(part);
          _hasPartial = false;
          _set(IntentKitPhase.error, error: IntentKitError.tooLarge);
        case DownloadError.checksumMismatch:
          await _deleteQuietly(part);
          _hasPartial = false;
          _set(IntentKitPhase.error, error: IntentKitError.checksum);
      }
    } on FileSystemException {
      _hasPartial = await _exists(part);
      _set(IntentKitPhase.error, error: IntentKitError.storage);
    } on Object {
      _hasPartial = await _exists(part);
      _set(IntentKitPhase.error, error: IntentKitError.storage);
    }
  }

  /// Сбросить ошибку (например, выбрали «Выключено»).
  void dismissError() {
    if (_phase != IntentKitPhase.error) return;
    _busyTier = null;
    _set(IntentKitPhase.idle);
  }

  /// «Удалить модель»: модель выгружается, пакеты, указатель и
  /// недокачанное удаляются. Память (личные примеры, журнал) остаётся.
  Future<void> delete() async {
    cancel();
    try {
      await _installing;
    } on Object {
      // Установка и так прервана.
    }
    await _syncs;
    if (_loadedPath != null) {
      _loadedPath = null;
      await host.unload();
    }
    _loadFailed = false;
    await _deleteQuietly(_pointer);
    final dir = Directory(root);
    if (await dir.exists()) {
      await for (final entity in dir.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (_packName.hasMatch(name) ||
            name == 'active' ||
            name.startsWith('tmp-') ||
            name.endsWith('.zip') ||
            name.endsWith('.zip.part')) {
          await _deleteQuietly(entity);
        }
      }
    }
    _installed = null;
    _hasPartial = false;
    _busyTier = null;
    _set(IntentKitPhase.idle);
  }

  /// «Забыть выученное».
  Future<void> forgetLearned() async {
    await memory.forgetLearned();
    _notify();
  }

  /// «Непонятые фразы → Очистить всё».
  Future<void> clearUnclear() async {
    await memory.clearUnclear();
    _notify();
  }

  /// Удалить одну непонятую фразу.
  Future<void> removeUnclear(UnclearPhrase phrase) async {
    await memory.removeUnclear(phrase);
    _notify();
  }

  /// Временные папки и архивы других версий (не [keep]).
  Future<void> _deleteLeftovers({required String keep}) async {
    final dir = Directory(root);
    if (!await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      final name = p.basename(entity.path);
      final archive = name.endsWith('.zip.part') || name.endsWith('.zip');
      if (name.startsWith('tmp-') ||
          (archive && !name.startsWith('$keep.zip'))) {
        await _deleteQuietly(entity);
      }
    }
  }

  /// Прежние версии и уровни после установки [keep].
  Future<void> _deleteOldPacks({required String keep}) async {
    final dir = Directory(root);
    if (!await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is Directory &&
          name != keep &&
          (_packName.hasMatch(name) || name == 'active')) {
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

  static Future<int> _sizeOf(Directory directory) async {
    var total = 0;
    try {
      await for (final entity
          in directory.list(recursive: true, followLinks: false)) {
        if (entity is File) total += await entity.length();
      }
    } on Object {
      // Папку удалили или нет доступа.
    }
    return total;
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel?.cancel();
    super.dispose();
  }
}

final class _ReleaseFailure implements Exception {
  const _ReleaseFailure(this.error);

  final IntentKitError error;
}
