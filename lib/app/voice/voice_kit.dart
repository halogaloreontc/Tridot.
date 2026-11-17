import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/downloads/safe_zip.dart';
import '../../core/downloads/verified_download.dart';
import '../../core/settings/app_settings.dart' show VoiceEngineChoice;
import '../../core/voice/voice_model.dart';
import '../../core/voice/voice_recognizer.dart';

/// Этап установки модели голосового ввода.
enum VoiceKitPhase {
  notInstalled,
  downloading,
  verifying,
  installing,
  installed,
  error,
}

/// Почему модель не установилась.
enum VoiceKitError {
  /// Нет сети или обрыв: скачанное сохранено, загрузка продолжится.
  network,

  /// Сервер отдал больше ожидаемого.
  tooLarge,

  /// Контрольная сумма архива не совпала.
  checksum,

  /// Архив не прошёл проверку при распаковке или в нём нет нужных файлов.
  extract,

  /// Не удалось записать файлы (нет места, нет доступа).
  storage,
}

/// Текст ошибки для пользователя.
extension VoiceKitErrorText on VoiceKitError {
  String get message => switch (this) {
        VoiceKitError.network => 'Не удалось скачать модель. Проверьте '
            'интернет — загрузка продолжится с места остановки',
        VoiceKitError.tooLarge =>
          'Сервер отдаёт не тот файл: он больше ожидаемого. Попробуйте позже',
        VoiceKitError.checksum =>
          'Файл повреждён: контрольная сумма не совпала',
        VoiceKitError.extract => 'Архив модели не прошёл проверку',
        VoiceKitError.storage =>
          'Не удалось сохранить модель. Проверьте свободное место',
      };
}

/// Распаковка архива: в приложении — [extractZipSafely], в тестах — что
/// угодно.
typedef ZipExtractor = Future<void> Function(
  File zip,
  Directory dest, {
  required ZipLimits limits,
  String? stripRoot,
});

/// Голосовой ввод (ADR-023): модель на устройстве и распознаватель.
///
/// Модель лежит в `<поддержка>/assistant/voice/<папка модели>` и считается
/// установленной, только если есть `installed.json` (пишется последним) и
/// все [VoiceModelSpec.requiredFiles]. Установка: загрузка в `.zip.part`
/// с продолжением → размер → SHA-256 → `.zip` → распаковка во временную
/// `tmp-…` → проверка файлов → переименование → `installed.json` →
/// удаление архива. Папка исключена из резервной копии Android.
final class VoiceKit extends ChangeNotifier {
  VoiceKit({
    required this.recognizer,
    this.device,
    required this.downloader,
    required this.spec,
    required this.dir,
    Future<String> Function(File file) hasher = sha256OfFile,
    ZipExtractor extractor = extractZipSafely,
    DateTime Function() now = DateTime.now,
  })  : _hasher = hasher,
        _extractor = extractor,
        _now = now;

  /// Vosk: модель на диске.
  final VoiceRecognizer recognizer;

  /// Распознавание телефона (ADR-023); `null` — его нет (не Android).
  final OnDeviceRecognizer? device;

  final FileDownloader downloader;
  final VoiceModelSpec spec;

  /// Папка голосового ввода: `<поддержка>/assistant/voice`.
  final String dir;

  final Future<String> Function(File file) _hasher;
  final ZipExtractor _extractor;
  final DateTime Function() _now;

  VoiceKitPhase _phase = VoiceKitPhase.notInstalled;
  VoiceKitError? _error;
  int _received = 0;
  int _total = 0;
  int _installedBytes = 0;
  bool _hasPartial = false;
  CancelToken? _cancel;
  Future<void>? _installing;
  Future<void>? _loading;
  bool _disposed = false;

  DeviceVoiceStatus _deviceStatus = DeviceVoiceStatus.unavailable;
  int? _devicePercent;
  bool _deviceDownloading = false;
  VoiceEngineChoice _choice = VoiceEngineChoice.auto;

  /// Голосовой ввод есть, если есть хоть одно распознавание.
  VoiceSupport get support => recognizer.support == VoiceSupport.supported ||
          (device != null &&
              _deviceStatus != DeviceVoiceStatus.unavailable &&
              _deviceStatus != DeviceVoiceStatus.unsupported)
      ? VoiceSupport.supported
      : VoiceSupport.unsupported;

  /// Что распознавание телефона знает о русском ([refreshDevice]).
  DeviceVoiceStatus get deviceStatus =>
      device == null ? DeviceVoiceStatus.unavailable : _deviceStatus;

  /// Процент системной загрузки русского языка (Android 14+), если идёт.
  int? get deviceDownloadPercent => _devicePercent;

  /// Идёт системная загрузка русского языка, начатая отсюда.
  bool get isDeviceDownloading => _deviceDownloading;

  /// Выбор в настройках (`voice.engine`).
  VoiceEngineChoice get choice => _choice;

  set choice(VoiceEngineChoice value) {
    if (_choice == value) return;
    _choice = value;
    _notify();
  }

  /// Распознавание телефона можно выбрать: оно есть и знает русский
  /// (хотя бы после загрузки).
  bool get deviceSelectable => switch (deviceStatus) {
        DeviceVoiceStatus.unavailable || DeviceVoiceStatus.unsupported => false,
        _ => true,
      };

  /// Чем распознаётся сейчас. «Авто» — телефон, если он готов: тогда не
  /// нужна загрузка 44 МБ. Выбран телефон, но русский ещё не скачан —
  /// Vosk, если его модель есть, иначе телефон (микрофон предложит
  /// скачать язык).
  VoiceEngine get engine {
    if (_choice == VoiceEngineChoice.vosk || device == null) {
      return VoiceEngine.vosk;
    }
    final status = deviceStatus;
    if (status == DeviceVoiceStatus.ready ||
        status == DeviceVoiceStatus.unknown) {
      return VoiceEngine.device;
    }
    if (_choice == VoiceEngineChoice.device &&
        (status == DeviceVoiceStatus.notInstalled ||
            status == DeviceVoiceStatus.pending)) {
      return isInstalled ? VoiceEngine.vosk : VoiceEngine.device;
    }
    return VoiceEngine.vosk;
  }

  /// Распознаватель выбранного движка.
  VoiceRecognizer get active =>
      engine == VoiceEngine.device ? device! : recognizer;

  /// Можно слушать без загрузок: телефон знает русский или модель Vosk
  /// установлена.
  bool get isReady => engine == VoiceEngine.device
      ? deviceStatus == DeviceVoiceStatus.ready ||
          deviceStatus == DeviceVoiceStatus.unknown
      : isInstalled;

  /// Узнаёт у телефона, знает ли он русский: при запуске, при возврате в
  /// приложение (после системной загрузки) и после загрузки.
  Future<void> refreshDevice() async {
    final device = this.device;
    if (device == null) return;
    DeviceVoiceStatus status;
    try {
      status = await device.checkStatus();
    } on Object {
      status = DeviceVoiceStatus.unavailable;
    }
    if (_disposed) return;
    // Ошибка 12 в этой сессии важнее «unknown» Android 12.
    if (_deviceStatus == DeviceVoiceStatus.unsupported &&
        status == DeviceVoiceStatus.unknown) {
      return;
    }
    if (status == _deviceStatus) return;
    _deviceStatus = status;
    if (status != DeviceVoiceStatus.pending) _devicePercent = null;
    _notify();
  }

  /// Просит Android скачать русский язык. Возвращает итог загрузки.
  Future<DeviceLanguageDownload> downloadDeviceLanguage() async {
    final device = this.device;
    if (device == null) return const DeviceDownloadError();
    _deviceDownloading = true;
    _devicePercent = null;
    _notify();
    DeviceLanguageDownload last = const DeviceDownloadError();
    try {
      await for (final update in device.downloadLanguage()) {
        if (_disposed) break;
        last = update;
        switch (update) {
          case DeviceDownloadProgress(:final percent):
            _devicePercent = percent.clamp(0, 100);
            _deviceStatus = DeviceVoiceStatus.pending;
          case DeviceDownloadSuccess():
            _devicePercent = null;
            _deviceStatus = DeviceVoiceStatus.ready;
          case DeviceDownloadScheduled():
            _devicePercent = null;
            _deviceStatus = DeviceVoiceStatus.pending;
          case DeviceDownloadError():
            _devicePercent = null;
        }
        _notify();
      }
    } on Object {
      last = const DeviceDownloadError();
    }
    _deviceDownloading = false;
    if (_disposed) return last;
    _notify();
    if (last is! DeviceDownloadSuccess) await refreshDevice();
    return last;
  }

  /// Ошибка распознавания телефона о языке (коды 12 и 13): статус
  /// понижается, следующее нажатие берёт новый движок. Текущая попытка не
  /// переключается на ходу.
  void reportDeviceError(VoiceErrorCode code) {
    final next = switch (code) {
      VoiceErrorCode.languageUnsupported => DeviceVoiceStatus.unsupported,
      VoiceErrorCode.languageUnavailable => DeviceVoiceStatus.notInstalled,
      _ => null,
    };
    if (next == null || device == null || next == _deviceStatus) return;
    _deviceStatus = next;
    _notify();
  }

  VoiceKitPhase get phase => _phase;

  /// Ошибка, если [phase] — [VoiceKitPhase.error].
  VoiceKitError? get error => _error;

  /// Скачано байт (при [VoiceKitPhase.downloading]).
  int get received => _received;

  /// Всего байт в архиве.
  int get total => _total == 0 ? spec.bytes : _total;

  /// Сколько места занимает установленная модель.
  int get installedBytes => _installedBytes;

  /// Есть недокачанный архив: следующая загрузка продолжит его.
  bool get hasPartial => _hasPartial;

  bool get isInstalled => _phase == VoiceKitPhase.installed;

  /// Идёт загрузка, проверка или распаковка.
  bool get isBusy =>
      _phase == VoiceKitPhase.downloading ||
      _phase == VoiceKitPhase.verifying ||
      _phase == VoiceKitPhase.installing;

  /// Папка установленной модели.
  String get modelPath => p.join(dir, spec.folderName);

  File get _part => File(p.join(dir, '${spec.folderName}.zip.part'));

  File get _zip => File(p.join(dir, '${spec.folderName}.zip'));

  File get _marker => File(p.join(modelPath, 'installed.json'));

  void _set(VoiceKitPhase phase, {VoiceKitError? error}) {
    _phase = phase;
    _error = error;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Состояние по файлам на диске (при запуске и после внешних изменений).
  Future<void> refresh() async {
    if (isBusy) return;
    if (await _isInstalledOnDisk()) {
      _installedBytes = await _sizeOf(Directory(modelPath));
      _hasPartial = false;
      _set(VoiceKitPhase.installed);
    } else {
      _installedBytes = 0;
      _hasPartial = await _part.exists() || await _zip.exists();
      _set(VoiceKitPhase.notInstalled);
    }
  }

  Future<bool> _isInstalledOnDisk() async {
    try {
      if (!await _marker.exists()) return false;
      final decoded = jsonDecode(await _marker.readAsString());
      if (decoded is! Map ||
          decoded['version'] != spec.folderName ||
          decoded['sha256'] != spec.sha256) {
        return false;
      }
      for (final file in spec.requiredFiles) {
        if (!await File(p.join(modelPath, file)).exists()) return false;
      }
      return true;
    } on Object {
      return false;
    }
  }

  /// Скачивает, проверяет и распаковывает модель. Повторный вызов во время
  /// установки возвращает ту же установку.
  Future<void> install() {
    final running = _installing;
    if (running != null) return running;
    // Отмена работает с первого мгновения, ещё до начала загрузки.
    final cancel = _cancel = CancelToken();
    return _installing = _install(cancel).whenComplete(() {
      _installing = null;
      _cancel = null;
    });
  }

  /// Прерывает загрузку; скачанное остаётся для продолжения.
  void cancel() => _cancel?.cancel();

  Future<void> _install(CancelToken cancel) async {
    if (await _isInstalledOnDisk()) {
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
      // Архив уже проверяли, но установка прервалась: проверим заново.
      if (await _zip.exists() && !await part.exists()) {
        await _zip.rename(part.path);
      }
      _received = await part.exists() ? await part.length() : 0;
      _total = spec.bytes;
      _set(VoiceKitPhase.downloading);
      await for (final progress in downloader.download(
        spec.uri,
        part,
        expectedBytes: spec.bytes,
        cancel: cancel,
      )) {
        _received = progress.received;
        _total = progress.total;
        _notify();
      }
      if (cancel.isCancelled) {
        throw const DownloadException(DownloadError.cancelled);
      }
      if (!await part.exists() || await part.length() != spec.bytes) {
        await _deleteQuietly(part);
        _set(VoiceKitPhase.error, error: VoiceKitError.network);
        return;
      }
      _set(VoiceKitPhase.verifying);
      final digest = await _hasher(part);
      if (digest.toLowerCase() != spec.sha256.toLowerCase()) {
        await _deleteQuietly(part);
        _hasPartial = false;
        _set(VoiceKitPhase.error, error: VoiceKitError.checksum);
        return;
      }
      final zip = await part.rename(_zip.path);
      _set(VoiceKitPhase.installing);
      final temporary = Directory(
        p.join(dir, 'tmp-${_now().microsecondsSinceEpoch}'),
      );
      try {
        await _extractor(
          zip,
          temporary,
          limits: spec.limits,
          stripRoot: spec.folderName,
        );
        for (final file in spec.requiredFiles) {
          if (!await File(p.join(temporary.path, file)).exists()) {
            throw const UnsafeZipException('missing_required');
          }
        }
      } on Object catch (error) {
        await _deleteQuietly(temporary);
        if (error is FileSystemException) {
          // Не хватило места или нет доступа: проверенный архив оставляем —
          // «Повторить» после освобождения места не скачивает его заново.
          _hasPartial = await _exists(zip);
          _set(VoiceKitPhase.error, error: VoiceKitError.storage);
          return;
        }
        // Архив прошёл проверку суммы, но не распаковался: скачивать его
        // заново бессмысленно, удаляем.
        await _deleteQuietly(zip);
        _hasPartial = false;
        _set(VoiceKitPhase.error, error: VoiceKitError.extract);
        return;
      }
      final target = Directory(modelPath);
      await _deleteQuietly(target);
      await temporary.rename(target.path);
      final marker = File('${_marker.path}.tmp');
      await marker.writeAsString(
        jsonEncode(<String, String>{
          'version': spec.folderName,
          'sha256': spec.sha256,
        }),
        flush: true,
      );
      await marker.rename(_marker.path);
      await _deleteQuietly(zip);
      _hasPartial = false;
      _installedBytes = await _sizeOf(target);
      _set(VoiceKitPhase.installed);
    } on DownloadException catch (error) {
      switch (error.error) {
        case DownloadError.cancelled:
          _hasPartial = await part.exists();
          _set(VoiceKitPhase.notInstalled);
        case DownloadError.network:
          _hasPartial = await part.exists();
          _set(VoiceKitPhase.error, error: VoiceKitError.network);
        case DownloadError.storage:
          _hasPartial = await _exists(part);
          _set(VoiceKitPhase.error, error: VoiceKitError.storage);
        case DownloadError.tooLarge:
        case DownloadError.sizeMismatch:
          await _deleteQuietly(part);
          _hasPartial = false;
          _set(VoiceKitPhase.error, error: VoiceKitError.tooLarge);
        case DownloadError.checksumMismatch:
          await _deleteQuietly(part);
          _hasPartial = false;
          _set(VoiceKitPhase.error, error: VoiceKitError.checksum);
      }
    } on FileSystemException {
      _hasPartial = await _exists(part);
      _set(VoiceKitPhase.error, error: VoiceKitError.storage);
    } on Object {
      // Непредвиденный сбой (например, проверка суммы не запустилась):
      // не зависаем в «Загрузке», скачанное остаётся для продолжения.
      _hasPartial = await _exists(part);
      _set(VoiceKitPhase.error, error: VoiceKitError.storage);
    }
  }

  /// Удаляет модель, недокачанный архив и временные папки.
  Future<void> delete() async {
    cancel();
    try {
      await _installing;
    } on Object {
      // Установка и так прервана.
    }
    try {
      await _loading;
    } on Object {
      // Загрузка модели не удалась — освобождать нечего.
    }
    try {
      await recognizer.unload();
    } on Object {
      // Распознаватель уже освобождён.
    }
    await _deleteQuietly(Directory(modelPath));
    await _deleteQuietly(_part);
    await _deleteQuietly(_zip);
    await _deleteTemporary();
    _installedBytes = 0;
    _hasPartial = false;
    _set(VoiceKitPhase.notInstalled);
  }

  /// Загружает модель в распознаватель. Уже загруженную распознаватель
  /// не загружает повторно, а после сбоя изолята — загрузит заново (своего
  /// признака «загружено» здесь нет, чтобы он не устаревал). Ошибка —
  /// [VoiceEngineException].
  Future<void> ensureLoaded() {
    if (engine == VoiceEngine.device) return Future<void>.value();
    if (!isInstalled) {
      return Future<void>.error(
        const VoiceEngineException(VoiceErrorCode.modelLoad),
      );
    }
    return _loading ??= recognizer.load(modelPath).then(
      (_) {},
      onError: (Object error) {
        throw error is VoiceEngineException
            ? error
            : const VoiceEngineException(VoiceErrorCode.modelLoad);
      },
    ).whenComplete(() => _loading = null);
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
      // Нечего удалять или нет доступа — не мешает дальнейшему.
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
    unawaited(recognizer.dispose());
    final device = this.device;
    if (device != null) unawaited(device.dispose());
    super.dispose();
  }
}
