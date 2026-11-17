/// Исполнитель задач расширений: тяжёлая работа — в отдельном изоляте
/// ([IsolateJobRunner]) или в отдельном процессе (ffmpeg, yt-dlp).
/// Интерфейс от неё не замирает: в главный изолят приходят только события
/// хода работы, итог и код ошибки.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../downloads/safe_zip.dart';

/// Коды ошибок задач: в карточке по ним — понятный русский текст, а пути и
/// тексты исключений в историю не попадают.
abstract final class JobCodes {
  /// Нет места на диске или ошибка записи.
  static const String disk = 'disk';

  /// Архив больше пределов (записи, размер, степень сжатия).
  static const String limits = 'limits';

  /// Повреждённый архив или не ZIP.
  static const String badZip = 'badZip';

  /// ZIP с паролем: пароль не спрашивается никогда.
  static const String password = 'password';

  /// Опасные пути в архиве (`../`, абсолютные, ссылки).
  static const String unsafe = 'unsafe';

  /// Исходного файла больше нет.
  static const String missing = 'missing';

  /// Отменено.
  static const String cancelled = 'cancelled';

  /// Формат файла не поддерживается (HEIC, неизвестный).
  static const String unsupported = 'unsupported';

  /// Картинка больше 50 мегапикселей (или файл картинки больше 200 МБ).
  static const String tooBig = 'tooBig';

  /// WAV получается больше 4 ГБ (предел формата).
  static const String tooBigWav = 'tooBigWav';

  /// Не хватило памяти устройства (система телефона или Mac).
  static const String noMemory = 'noMemory';

  /// Файл не прочитать: повреждён или внутри не то, что в имени.
  static const String media = 'media';

  /// Система телефона или Mac не открывает этот файл: контейнер или кодек
  /// ей неизвестен (ADR-026).
  static const String mediaOpen = 'mediaOpen';

  /// Системный кодировщик (или встроенный LAME) отказал.
  static const String encoder = 'encoder';

  /// Нужной внешней программы (ffmpeg) нет или она не прошла проверку.
  static const String noTool = 'noTool';

  /// В файле нет нужной дорожки (звука у видео, видео у звука).
  static const String noStream = 'noStream';

  /// Нет сети или сайт не ответил (загрузчик видео).
  static const String network = 'network';

  /// Видео недоступно: удалено, закрыто, нужен вход, нет такого формата.
  static const String unavailable = 'unavailable';

  /// Ссылка не поддерживается yt-dlp.
  static const String badUrl = 'badUrl';

  /// yt-dlp не установлен или не прошёл проверку.
  static const String noDownloader = 'noDownloader';

  /// Что-то другое.
  static const String failed = 'failed';

  /// Понятный текст ошибки по коду.
  static String message(String? code) => switch (code) {
        disk => 'Не удалось записать результат: мало места или нет доступа '
            'к папке',
        limits => 'Архив слишком большой: больше 10 000 файлов, больше '
            'допустимого размера или подозрительно сильно сжат',
        badZip => 'Это не ZIP или архив повреждён',
        password => 'ZIP с паролем пока не поддерживается',
        unsafe => 'В архиве опасные пути — распаковка остановлена, ничего '
            'не записано вне временной папки',
        missing => 'Исходного файла больше нет — выберите его заново',
        unsupported => 'Этот формат здесь не поддерживается',
        tooBig => 'Картинка слишком большая: можно до 50 мегапикселей и '
            '200 МБ',
        tooBigWav => 'WAV получается больше 4 ГБ — это предел формата; '
            'выберите MP3 или M4A',
        noMemory => 'Не хватило памяти устройства — попробуйте файл '
            'поменьше или качество ниже',
        media => 'Не удалось прочитать файл: он повреждён или внутри не тот '
            'формат',
        mediaOpen => 'Этот файл не открывается на этом устройстве: система '
            'не знает его формат или кодек',
        encoder => 'Кодировщик устройства отказал — попробуйте другое '
            'качество или формат',
        noStream => 'В файле нет нужной дорожки: например, у видео нет звука',
        noTool => 'ffmpeg не установлен или не прошёл проверку — скачайте '
            'его заново: Настройки → Расширения → Конвертер → Настроить',
        network => 'Не удалось скачать: нет сети или сайт не отвечает',
        unavailable => 'Видео недоступно: оно удалено, закрыто, требует '
            'входа или нужного качества нет',
        badUrl => 'Эту ссылку загрузчик не поддерживает',
        noDownloader => 'yt-dlp не установлен или не прошёл проверку — '
            'скачайте его: Настройки → Расширения → Загрузчик видео → '
            'Настроить',
        cancelled => 'Отменено',
        _ => 'Не получилось выполнить задачу',
      };

  /// Код по исключению задачи.
  static String of(Object error) {
    if (error is UnsafeZipException) {
      return switch (error.reason) {
        'password' => password,
        'corrupt' || 'size_mismatch' => badZip,
        'too_many_entries' ||
        'total_too_large' ||
        'entry_too_large' ||
        'ratio' =>
          limits,
        'no_space' => disk,
        'cancelled' => cancelled,
        _ => unsafe,
      };
    }
    if (error is JobMissing) return missing;
    if (error is JobError) return error.code;
    if (error is FileSystemException) return disk;
    return failed;
  }
}

/// Исходного файла нет на месте.
final class JobMissing implements Exception {
  const JobMissing();

  @override
  String toString() => 'JobMissing';
}

/// Ошибка задачи с готовым кодом [JobCodes].
final class JobError implements Exception {
  const JobError(this.code);

  final String code;

  @override
  String toString() => 'JobError($code)';
}

/// Исходный файл задачи: путь на диске и имя для архива.
final class JobSource {
  const JobSource(this.path, this.name, {this.folder = false});

  final String path;
  final String name;
  final bool folder;
}

/// Что сделать: всё, что нужно изоляту, уже посчитано (имена результата и
/// временные пути), чтобы при отмене было ясно, что убрать.
final class JobRequest {
  const JobRequest({
    required this.cardId,
    required this.extensionId,
    required this.action,
    required this.sources,
    required this.outputDir,
    this.target,
    this.temp,
    this.url,
    this.limits = ZipLimits.desktop,
    this.options = const <String, String>{},
  });

  final String cardId;
  final String extensionId;
  final String action;
  final List<JobSource> sources;

  /// Папка результата.
  final String outputDir;

  /// Итоговый путь результата (архив, папка распаковки).
  final String? target;

  /// Временный путь (`.part`, временная папка): убирается при отмене.
  final String? temp;

  /// Ссылка загрузчика видео: уходит только в yt-dlp, в историю и
  /// журналы не пишется.
  final String? url;

  final ZipLimits limits;

  /// Настройки задачи из карточки (только допустимые значения): качество
  /// конвертера (`audio_kbps` → `320`), сжатие архива (`level`).
  final Map<String, String> options;

  /// Временные пути, которые нужно убрать, если задача не закончилась.
  List<String> get cleanup => <String>[if (temp != null) temp!];
}

/// Событие задачи.
sealed class JobEvent {
  const JobEvent();
}

/// Ход работы: [value] 0..1 или `null` (неизвестно), [stage] — «Сжатие».
final class JobProgress extends JobEvent {
  const JobProgress(this.value, this.stage);

  final double? value;
  final String? stage;
}

/// Готово.
final class JobDone extends JobEvent {
  const JobDone({
    this.outputs = const <String>[],
    this.outputDir,
    this.listing = const <String>[],
    this.listingMore = 0,
  });

  final List<String> outputs;
  final String? outputDir;
  final List<String> listing;
  final int listingMore;
}

/// Ошибка с кодом [JobCodes] (в том числе `cancelled`).
final class JobFailed extends JobEvent {
  const JobFailed(this.code);

  final String code;
}

/// Ход работы изнутри задачи.
abstract interface class JobReporter {
  void progress(double? value, String? stage);
}

/// Работа задачи: выполняется в изоляте, поэтому это статическая функция
/// или функция верхнего уровня.
typedef JobWork = JobDone Function(JobRequest request, JobReporter reporter);

/// Исполнитель задач.
abstract interface class JobRunner {
  /// Запускает задачу; поток событий кончается [JobDone] или [JobFailed].
  Stream<JobEvent> start(JobRequest request);

  /// Отменяет задачу карточки [cardId]: временные пути убираются, поток
  /// кончается [JobFailed] `cancelled`.
  void cancel(String cardId);
}

/// Задачи в отдельных изолятах. [work] — работа по id расширения.
final class IsolateJobRunner implements JobRunner {
  IsolateJobRunner(this.work);

  final Map<String, JobWork> work;

  final Map<String, _Running> _running = <String, _Running>{};

  @override
  Stream<JobEvent> start(JobRequest request) {
    final controller = StreamController<JobEvent>();
    final job = work[request.extensionId];
    if (job == null) {
      controller
        ..add(const JobFailed(JobCodes.failed))
        ..close();
      return controller.stream;
    }
    final port = ReceivePort();
    final running = _Running(request, controller, port);
    _running[request.cardId] = running;
    port.listen((Object? message) {
      if (message is List && message.isNotEmpty) {
        // После отмены изолят ещё может прислать ход работы или итог.
        if (running.finished) return;
        switch (message[0]) {
          case 'p':
            controller.add(
              JobProgress(message[1] as double?, message[2] as String?),
            );
          case 'done':
            running.finish(
              JobDone(
                outputs: (message[1] as List).cast<String>(),
                outputDir: message[2] as String?,
                listing: (message[3] as List).cast<String>(),
                listingMore: message[4] as int,
              ),
            );
            _running.remove(request.cardId);
          case 'fail':
            _cleanup(request);
            running.finish(JobFailed(message[1] as String));
            _running.remove(request.cardId);
        }
      } else if (message == null) {
        // Изолят завершился. Не прислал итога — упал. Отменённый мог
        // успеть записать ещё одну запись после первой уборки (kill не
        // мгновенный, а запись на диск синхронная): убираем ещё раз.
        if (!running.finished) {
          _cleanup(request);
          running.finish(const JobFailed(JobCodes.failed));
        } else if (running.cancelled) {
          _cleanup(request);
        }
        if (identical(_running[request.cardId], running)) {
          _running.remove(request.cardId);
        }
        port.close();
      }
    });
    Isolate.spawn<_JobStart>(
      _jobEntry,
      _JobStart(port.sendPort, request, job),
      onExit: port.sendPort,
      errorsAreFatal: true,
    ).then(
      (Isolate isolate) {
        if (running.finished) {
          isolate.kill(priority: Isolate.immediate);
        } else {
          running.isolate = isolate;
        }
      },
      onError: (Object _) {
        running.finish(const JobFailed(JobCodes.failed));
        _running.remove(request.cardId);
        port.close();
      },
    );
    return controller.stream;
  }

  @override
  void cancel(String cardId) {
    final running = _running.remove(cardId);
    if (running == null || running.finished) return;
    running.cancelled = true;
    running.isolate?.kill(priority: Isolate.immediate);
    _cleanup(running.request);
    running.finish(const JobFailed(JobCodes.cancelled));
  }

  /// Убирает временные пути задачи.
  static void _cleanup(JobRequest request) {
    for (final path in request.cleanup) {
      removeQuietly(path);
    }
  }

  /// Удаляет файл или папку [path], если они есть; ошибки — молча.
  static void removeQuietly(String path) {
    try {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      switch (type) {
        case FileSystemEntityType.directory:
          Directory(path).deleteSync(recursive: true);
        case FileSystemEntityType.notFound:
          break;
        default:
          File(path).deleteSync();
      }
    } on Object {
      // Не вышло — останется до следующей уборки.
    }
  }
}

final class _Running {
  _Running(this.request, this.controller, this.port);

  final JobRequest request;
  final StreamController<JobEvent> controller;
  final ReceivePort port;
  Isolate? isolate;
  bool finished = false;

  /// Отменена: после выхода изолята временные пути убираются ещё раз.
  bool cancelled = false;

  /// Итог задачи. Порт остаётся открытым до выхода изолята (`onExit`).
  void finish(JobEvent event) {
    if (finished) return;
    finished = true;
    controller
      ..add(event)
      ..close();
  }
}

final class _JobStart {
  const _JobStart(this.port, this.request, this.work);

  final SendPort port;
  final JobRequest request;
  final JobWork work;
}

/// Ход работы шлётся не чаще 10 раз в секунду.
final class _PortReporter implements JobReporter {
  _PortReporter(this.port);

  final SendPort port;
  final Stopwatch _clock = Stopwatch()..start();
  int _last = -1000;
  String? _stage;

  @override
  void progress(double? value, String? stage) {
    final now = _clock.elapsedMilliseconds;
    if (stage == _stage && now - _last < 100 && value != 1) return;
    _last = now;
    _stage = stage;
    port.send(<Object?>['p', value, stage]);
  }
}

void _jobEntry(_JobStart start) {
  try {
    final done = start.work(start.request, _PortReporter(start.port));
    start.port.send(<Object?>[
      'done',
      done.outputs,
      done.outputDir,
      done.listing,
      done.listingMore,
    ]);
  } on Object catch (error) {
    start.port.send(<Object?>['fail', JobCodes.of(error)]);
  }
}

/// Задачи разных видов: изолят (архиватор, картинки) или отдельный процесс
/// (ffmpeg). [pick] выбирает исполнителя по задаче; отмена идёт тому, кто
/// её запустил.
final class JobRunnerRouter implements JobRunner {
  JobRunnerRouter(this.pick);

  final JobRunner Function(JobRequest request) pick;

  final Map<String, JobRunner> _owners = <String, JobRunner>{};

  @override
  Stream<JobEvent> start(JobRequest request) {
    final runner = pick(request);
    _owners[request.cardId] = runner;
    return runner.start(request).map((JobEvent event) {
      if (event is! JobProgress) _owners.remove(request.cardId);
      return event;
    });
  }

  @override
  void cancel(String cardId) => _owners.remove(cardId)?.cancel(cardId);
}
