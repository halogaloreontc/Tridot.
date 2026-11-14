import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart' as crypto;

import '../app_info.dart';

/// Сколько скачано из скольких байт.
final class DownloadProgress {
  const DownloadProgress(this.received, this.total);

  final int received;
  final int total;

  @override
  bool operator ==(Object other) =>
      other is DownloadProgress &&
      other.received == received &&
      other.total == total;

  @override
  int get hashCode => Object.hash(received, total);

  @override
  String toString() => 'DownloadProgress($received/$total)';
}

/// Почему загрузка не удалась.
enum DownloadError {
  /// Нет сети, обрыв, неожиданный ответ сервера. Скачанное остаётся в
  /// `.part` — следующая попытка продолжит с места остановки.
  network,

  /// Сервер отдаёт больше ожидаемого. `.part` удалён.
  tooLarge,

  /// Файл скачан, но его размер не тот. `.part` удалён.
  sizeMismatch,

  /// Контрольная сумма не совпала (проверяет вызывающий).
  checksumMismatch,

  /// Отменили. `.part` остаётся.
  cancelled,

  /// Не удалось записать файл (нет места, нет доступа). Скачанное
  /// остаётся в `.part`; повторять загрузку без свободного места
  /// бессмысленно.
  storage,
}

final class DownloadException implements Exception {
  const DownloadException(this.error);

  final DownloadError error;

  @override
  String toString() => 'DownloadException(${error.name})';
}

/// Отмена загрузки: [cancel] можно звать из любого места и сколько угодно
/// раз.
final class CancelToken {
  final Completer<void> _done = Completer<void>();

  bool get isCancelled => _done.isCompleted;

  /// Завершается при отмене.
  Future<void> get whenCancelled => _done.future;

  void cancel() {
    if (!_done.isCompleted) _done.complete();
  }
}

/// Загрузчик файла с продолжением после обрыва (ADR-023). Общий: модель
/// голосового ввода, а позже и другие большие файлы.
abstract interface class FileDownloader {
  /// Скачивает [uri] в [partFile]. Если [partFile] уже есть — продолжает
  /// с его конца. Поток сообщает о ходе загрузки и завершается, когда в
  /// [partFile] ровно [expectedBytes] байт; ошибка — [DownloadException].
  /// Контрольную сумму проверяет вызывающий ([sha256OfFile]).
  Stream<DownloadProgress> download(
    Uri uri,
    File partFile, {
    required int expectedBytes,
    required CancelToken cancel,
  });
}

/// [FileDownloader] на `dart:io` `HttpClient`.
///
/// Только https; не больше [maxRedirects] переадресаций, только на https
/// и только на тот же сайт.
/// `Range` для продолжения: 206 — дописываем, 200 — сервер не умеет
/// продолжать, начинаем заново. Больше [download.expectedBytes] не пишется
/// ни байта. Ни адрес, ни ответ в журнал не пишутся.
final class IoFileDownloader implements FileDownloader {
  IoFileDownloader({
    HttpClient Function()? client,
    this.allowLoopbackHttp = false,
    this.idleTimeout = const Duration(seconds: 60),
  }) : _client = client ?? HttpClient.new;

  final HttpClient Function() _client;

  /// Для тестов: разрешить http на 127.0.0.1 / ::1.
  final bool allowLoopbackHttp;

  /// Сколько ждать следующих байт, прежде чем считать связь оборванной.
  final Duration idleTimeout;

  static const int maxRedirects = 3;

  /// Как часто сообщать о ходе: каждые 128 КБ.
  static const int _progressStep = 128 * 1024;

  bool _allowed(Uri uri) {
    if (uri.scheme == 'https' && uri.host.isNotEmpty) return true;
    if (allowLoopbackHttp && uri.scheme == 'http') {
      final address = InternetAddress.tryParse(uri.host);
      return address != null && address.isLoopback;
    }
    return false;
  }

  @override
  Stream<DownloadProgress> download(
    Uri uri,
    File partFile, {
    required int expectedBytes,
    required CancelToken cancel,
  }) {
    final controller = StreamController<DownloadProgress>();
    controller.onListen = () {
      _run(uri, partFile, expectedBytes, cancel, controller).then(
        (_) => controller.close(),
        onError: (Object error, StackTrace stack) {
          controller.addError(
            error is DownloadException
                ? error
                : const DownloadException(DownloadError.network),
          );
          controller.close();
        },
      );
    };
    return controller.stream;
  }

  Future<void> _run(
    Uri uri,
    File partFile,
    int expected,
    CancelToken cancel,
    StreamController<DownloadProgress> progress,
  ) async {
    if (cancel.isCancelled) {
      throw const DownloadException(DownloadError.cancelled);
    }
    var offset = await partFile.exists() ? await partFile.length() : 0;
    if (offset > expected) {
      await partFile.delete();
      offset = 0;
    }
    if (offset == expected) {
      progress.add(DownloadProgress(offset, expected));
      return;
    }
    progress.add(DownloadProgress(offset, expected));
    final client = _client()
      ..userAgent = '${AppInfo.latinName}/1'
      ..connectionTimeout = const Duration(seconds: 30)
      ..autoUncompress = false;
    final cancelled = cancel.whenCancelled.then((_) {
      client.close(force: true);
    });
    RandomAccessFile? sink;
    try {
      final response = await _open(client, uri, offset);
      if (cancel.isCancelled) {
        throw const DownloadException(DownloadError.cancelled);
      }
      final status = response.statusCode;
      final FileMode mode;
      if (status == HttpStatus.partialContent && offset > 0) {
        final start = _rangeStart(response.headers.value('content-range'));
        if (start != offset) {
          await _drain(response);
          await partFile.delete();
          throw const DownloadException(DownloadError.network);
        }
        mode = FileMode.append;
      } else if (status == HttpStatus.ok) {
        offset = 0;
        mode = FileMode.write;
      } else {
        await _drain(response);
        if (status == HttpStatus.requestedRangeNotSatisfiable &&
            await partFile.exists()) {
          await partFile.delete();
        }
        throw const DownloadException(DownloadError.network);
      }
      final length = response.contentLength;
      if (length >= 0 && offset + length > expected) {
        await _drain(response);
        if (mode == FileMode.write && await partFile.exists()) {
          await partFile.delete();
        }
        throw const DownloadException(DownloadError.tooLarge);
      }
      await partFile.parent.create(recursive: true);
      final out = sink = await partFile.open(mode: mode);
      var received = offset;
      var reported = offset;
      progress.add(DownloadProgress(received, expected));
      await for (final chunk in response.timeout(idleTimeout)) {
        if (cancel.isCancelled) break;
        if (received + chunk.length > expected) {
          await out.close();
          sink = null;
          await partFile.delete();
          throw const DownloadException(DownloadError.tooLarge);
        }
        await out.writeFrom(chunk);
        received += chunk.length;
        if (received - reported >= _progressStep || received == expected) {
          reported = received;
          progress.add(DownloadProgress(received, expected));
        }
      }
      await out.flush();
      await out.close();
      sink = null;
      if (cancel.isCancelled) {
        throw const DownloadException(DownloadError.cancelled);
      }
      if (received != expected) {
        // Связь оборвалась раньше конца: скачанное остаётся в .part.
        throw const DownloadException(DownloadError.network);
      }
      if (reported != received) {
        progress.add(DownloadProgress(received, expected));
      }
    } on DownloadException {
      rethrow;
    } on Object catch (error) {
      if (cancel.isCancelled) {
        throw const DownloadException(DownloadError.cancelled);
      }
      // Ошибка диска (например, кончилось место) — не «проверьте интернет».
      if (error is FileSystemException) {
        throw const DownloadException(DownloadError.storage);
      }
      throw const DownloadException(DownloadError.network);
    } finally {
      try {
        await sink?.close();
      } on Object {
        // Уже закрыт.
      }
      client.close(force: true);
      unawaited(cancelled);
    }
  }

  Future<HttpClientResponse> _open(
    HttpClient client,
    Uri uri,
    int offset,
  ) async {
    var current = uri;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      if (!_allowed(current) || !_sameSite(uri, current)) {
        throw const DownloadException(DownloadError.network);
      }
      final request = await client.getUrl(current);
      request.followRedirects = false;
      if (offset > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
      }
      final response = await request.close();
      if (!response.isRedirect) return response;
      final location = response.headers.value(HttpHeaders.locationHeader);
      await _drain(response);
      if (location == null) break;
      current = current.resolve(location);
    }
    throw const DownloadException(DownloadError.network);
  }

  /// Переадресация — только на тот же сайт ([origin] или его поддомен):
  /// запрос с устройства не уходит третьим лицам, даже если сервер
  /// переадресует (целостность и так проверяет SHA-256).
  static bool _sameSite(Uri origin, Uri target) {
    final host = origin.host.toLowerCase();
    final next = target.host.toLowerCase();
    return next == host || next.endsWith('.$host');
  }

  static Future<void> _drain(HttpClientResponse response) async {
    try {
      await response.drain<void>();
    } on Object {
      // Тело не нужно.
    }
  }

  /// Начало из `Content-Range: bytes 100-199/200`.
  static int? _rangeStart(String? header) {
    if (header == null) return null;
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(
      header.trim(),
    );
    return match == null ? null : int.tryParse(match.group(1)!);
  }
}

/// SHA-256 файла строкой из 64 строчных шестнадцатеричных знаков. Читает
/// файл потоком в отдельном изоляте.
Future<String> sha256OfFile(File file) {
  final path = file.path;
  return Isolate.run(() async {
    final digest = await crypto.sha256.bind(File(path).openRead()).first;
    return digest.toString();
  });
}
