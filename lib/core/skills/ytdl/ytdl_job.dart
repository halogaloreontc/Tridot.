/// Загрузка видео через yt-dlp (ADR-024, шаг 3): отдельный процесс со
/// списком аргументов — без оболочки, без конфигов пользователя
/// (`--ignore-config`), без cookies, без плагинов, без плейлистов. Ссылка
/// идёт последним аргументом после `--`. Промежуточные файлы — во
/// временной папке задачи (`-P temp:`), в папку загрузок переносится
/// только готовый файл; отмена убирает временную папку целиком.
///
/// Вывод yt-dlp (в нём ссылка, название и пути) наружу не уходит: только
/// ход работы, путь результата и код ошибки.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../jobs/job_runner.dart';
import '../converter/ffmpeg_job.dart' show ProcessStarter;
import 'ytdl_formats.dart';

/// Аргументы yt-dlp и разбор его вывода.
abstract final class YtdlArgs {
  /// Начало строки хода загрузки (`--progress-template`).
  static const String progressMark = 'tridot-progress';

  /// Начало строки обработки после загрузки (склейка, mp3).
  static const String postMark = 'tridot-post';

  /// Начало строки с путём готового файла (`--print after_move:`).
  static const String fileMark = 'tridot-file';

  /// Список аргументов: [url] в папку [home] через временную [temp].
  /// [ffmpeg] — путь к проверенному ffmpeg конвертера или `null`: тогда
  /// видео — только цельным файлом (без склейки дорожек), а звук в mp3
  /// недоступен ([ArgumentError]).
  static List<String> build({
    required String url,
    required String format,
    required String home,
    required String temp,
    String? ffmpeg,
  }) {
    if (!YtdlUrl.valid(url)) throw ArgumentError('url');
    final height = YtdlFormats.heightOf(format);
    if (height == null && format != YtdlFormats.audio) {
      throw ArgumentError.value(format, 'format');
    }
    if (format == YtdlFormats.audio && ffmpeg == null) {
      throw ArgumentError.value(format, 'format', 'нужен ffmpeg');
    }
    return <String>[
      '--ignore-config',
      '--no-plugin-dirs',
      '--no-playlist',
      '--no-cookies',
      '--no-cookies-from-browser',
      '--no-mtime',
      '--windows-filenames',
      '--color',
      'never',
      '--newline',
      '--progress',
      '--progress-delta',
      '0.2',
      '--progress-template',
      'download:$progressMark %(progress.downloaded_bytes)s '
          '%(progress.total_bytes,progress.total_bytes_estimate)s',
      '--progress-template',
      'postprocess:$postMark',
      '--print',
      'after_move:$fileMark %(filepath)s',
      '--no-simulate',
      if (ffmpeg != null) ...<String>['--ffmpeg-location', ffmpeg],
      '-P',
      'home:$home',
      '-P',
      'temp:$temp',
      '-o',
      '%(title).150B [%(id)s].%(ext)s',
      ...switch (format) {
        YtdlFormats.audio => <String>[
            '-f', 'ba/b', //
            '-x',
            '--audio-format', 'mp3',
            '--audio-quality', '2',
          ],
        _ when ffmpeg != null => <String>[
            '-f',
            'bv*[height<=$height]+ba/b[height<=$height]/bv*+ba/b',
          ],
        // Без ffmpeg дорожки не склеить: только цельный файл.
        _ => <String>[
            '-f',
            'b[height<=$height][ext=mp4]/b[height<=$height]/b',
          ],
      },
      '--',
      url,
    ];
  }

  /// Ход загрузки по строке `tridot-progress <скачано> <всего>`: первое
  /// поле — это строка хода, второе — доля 0..1 или `null` (размер
  /// неизвестен).
  static (bool, double?) progressOf(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('$progressMark ')) return (false, null);
    final parts = trimmed.substring(progressMark.length + 1).split(' ');
    if (parts.length != 2) return (true, null);
    final done = double.tryParse(parts[0]);
    final total = double.tryParse(parts[1]);
    if (done == null || total == null || total <= 0) return (true, null);
    return (true, (done / total).clamp(0, 1).toDouble());
  }

  /// Путь готового файла по строке `tridot-file <путь>` или `null`.
  static String? fileOf(String line) {
    if (!line.startsWith('$fileMark ')) return null;
    final path = line.substring(fileMark.length + 1).trim();
    return path.isEmpty ? null : path;
  }

  /// Код ошибки по концу stderr: текст yt-dlp (со ссылкой) наружу не
  /// уходит.
  static String errorOf(String stderrTail) {
    final text = stderrTail.toLowerCase();
    if (text.contains('no space left') || text.contains('permission denied')) {
      return JobCodes.disk;
    }
    if (text.contains('unsupported url')) return JobCodes.badUrl;
    if (text.contains('ffmpeg not found') ||
        text.contains('ffprobe and ffmpeg not found') ||
        text.contains('ffmpeg is not installed')) {
      return JobCodes.noTool;
    }
    if (text.contains('video unavailable') ||
        text.contains('private video') ||
        text.contains('sign in to confirm') ||
        text.contains('members-only') ||
        text.contains('is not available') ||
        text.contains('has been removed') ||
        text.contains('requested format is not available') ||
        text.contains('http error 403') ||
        text.contains('http error 404') ||
        text.contains('http error 410')) {
      return JobCodes.unavailable;
    }
    if (text.contains('unable to download webpage') ||
        text.contains('unable to download video data') ||
        text.contains('urlopen error') ||
        text.contains('getaddrinfo') ||
        text.contains('name or service not known') ||
        text.contains('temporary failure in name resolution') ||
        text.contains('timed out') ||
        text.contains('connection reset') ||
        text.contains('connection refused') ||
        text.contains('network is unreachable') ||
        text.contains('failed to resolve') ||
        text.contains('ssl')) {
      return JobCodes.network;
    }
    return JobCodes.failed;
  }
}

/// Задачи загрузчика видео. [ytdlpPath] — путь к проверенному yt-dlp или
/// `null` (не скачан, не прошёл проверку); [ffmpegPath] — то же для ffmpeg
/// конвертера (склейка дорожек и mp3).
final class YtdlJobRunner implements JobRunner {
  YtdlJobRunner({
    required this.ytdlpPath,
    required this.ffmpegPath,
    ProcessStarter? starter,
    bool? windows,
    bool? processGroup,
    this.killGrace = const Duration(seconds: 3),
  })  : _starter = starter ?? _startProcess,
        _windows = windows ?? Platform.isWindows,
        _group = processGroup ?? (starter == null && Platform.isLinux);

  final Future<String?> Function() ytdlpPath;
  final Future<String?> Function() ffmpegPath;
  final ProcessStarter _starter;
  final bool _windows;

  /// Linux: yt-dlp запускается в своей группе процессов (`setsid`), и
  /// «Отмена» останавливает всю группу — вместе с ffmpeg, который yt-dlp
  /// запускает для склейки и mp3.
  final bool _group;

  /// Программа, которая запускает команду в новой группе процессов.
  static const String setsidTool = 'setsid';

  /// Сколько ждать после мягкой остановки перед `SIGKILL`.
  final Duration killGrace;

  final Map<String, _YtdlRun> _running = <String, _YtdlRun>{};

  static const int _tailLimit = 4096;

  static Future<Process> _startProcess(
    String executable,
    List<String> arguments,
  ) =>
      Process.start(executable, arguments, runInShell: false);

  @override
  Stream<JobEvent> start(JobRequest request) {
    final run = _YtdlRun(request);
    _running[request.cardId] = run;
    unawaited(_run(run));
    return run.controller.stream;
  }

  Future<void> _run(_YtdlRun run) async {
    final request = run.request;
    final temp = request.temp!;
    try {
      final exe = await ytdlpPath();
      if (run.finished) return;
      if (exe == null) {
        _finish(run, const JobFailed(JobCodes.noDownloader));
        return;
      }
      final ffmpeg = await ffmpegPath();
      if (run.finished) return;
      if (YtdlFormats.needsFfmpeg(request.action) && ffmpeg == null) {
        _finish(run, const JobFailed(JobCodes.noTool));
        return;
      }
      final url = request.url;
      if (url == null || !YtdlUrl.valid(url)) {
        _finish(run, const JobFailed(JobCodes.badUrl));
        return;
      }
      await Directory(request.outputDir).create(recursive: true);
      await Directory(temp).create(recursive: true);
      final args = YtdlArgs.build(
        url: url,
        format: request.action,
        home: request.outputDir,
        temp: temp,
        ffmpeg: ffmpeg,
      );
      run.controller.add(const JobProgress(null, 'Скачивание'));
      final process = await _launch(run, exe, args);
      run.process = process;
      if (run.finished) {
        _kill(process, group: run.group);
        return;
      }
      String? output;
      var tail = '';
      void line(String text) {
        if (run.finished) return;
        output = YtdlArgs.fileOf(text) ?? output;
        final (isProgress, value) = YtdlArgs.progressOf(text);
        if (isProgress) {
          run.controller.add(
            JobProgress(value?.clamp(0, 0.99).toDouble(), 'Скачивание'),
          );
        } else if (text.trim() == YtdlArgs.postMark) {
          run.controller.add(const JobProgress(null, 'Обработка'));
        }
      }

      final outDone = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(line)
          .asFuture<void>();
      final errDone = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((String text) {
        line(text);
        tail = '$tail\n$text';
        if (tail.length > _tailLimit) {
          tail = tail.substring(tail.length - _tailLimit);
        }
      }).asFuture<void>();
      final code = await process.exitCode;
      await Future.wait(<Future<void>>[
        errDone.catchError((Object _) {}),
        outDone.catchError((Object _) {}),
      ]);
      if (run.finished) return;
      IsolateJobRunner.removeQuietly(temp);
      final result = output;
      if (code == 0) {
        final inside = result != null &&
            p.isWithin(
              p.canonicalize(request.outputDir),
              p.canonicalize(result),
            ) &&
            File(result).existsSync();
        _finish(
          run,
          JobDone(
            outputs: <String>[if (inside) result],
            outputDir: request.outputDir,
          ),
        );
        return;
      }
      _finish(run, JobFailed(YtdlArgs.errorOf(tail)));
    } on Object catch (error) {
      IsolateJobRunner.removeQuietly(temp);
      if (!run.finished) {
        _finish(
          run,
          JobFailed(
            error is ProcessException
                ? JobCodes.noDownloader
                : error is ArgumentError
                    ? JobCodes.failed
                    : JobCodes.of(error),
          ),
        );
      }
    }
  }

  /// Запуск yt-dlp; на Linux — через `setsid` в своей группе процессов.
  /// `setsid` нет — обычный запуск (останавливается только сам yt-dlp).
  Future<Process> _launch(_YtdlRun run, String exe, List<String> args) async {
    if (_group) {
      try {
        final process = await _starter(setsidTool, <String>[exe, ...args]);
        run.group = true;
        return process;
      } on ProcessException {
        // Нет setsid: запуск без своей группы.
      }
    }
    return _starter(exe, args);
  }

  void _finish(_YtdlRun run, JobEvent event) {
    _running.remove(run.request.cardId);
    run.finish(event);
  }

  @override
  void cancel(String cardId) {
    final run = _running.remove(cardId);
    if (run == null || run.finished) return;
    run.finish(const JobFailed(JobCodes.cancelled));
    final process = run.process;
    final temp = run.request.temp!;
    if (process != null) _kill(process, group: run.group);
    IsolateJobRunner.removeQuietly(temp);
    if (process != null) {
      // Процесс мог ещё писать во временную папку: убираем и после выхода.
      unawaited(
        process.exitCode.then((_) => IsolateJobRunner.removeQuietly(temp)),
      );
    }
  }

  void _kill(Process process, {bool group = false}) {
    if (group) {
      // Вся группа: загрузчик PyInstaller, Python и ffmpeg. Аргументы
      // списком, без оболочки; `-PID` — группа с этим номером.
      void signal(String name) => unawaited(
            Process.run(
              'kill',
              <String>['-$name', '--', '-${process.pid}'],
            ).then((_) {}, onError: (Object _) => process.kill()),
          );
      signal('TERM');
      // Сам yt-dlp мог выйти, а его ffmpeg — нет: группе — `SIGKILL` в
      // любом случае (пустой группе сигнал ничего не делает).
      unawaited(Future<void>.delayed(killGrace, () => signal('KILL')));
      return;
    }
    if (_windows) {
      // Дерево процессов целиком (yt-dlp запускает ffmpeg); аргументы
      // списком, без оболочки.
      unawaited(
        Process.run(
          'taskkill',
          <String>['/T', '/F', '/PID', '${process.pid}'],
        ).then((_) {}, onError: (Object _) => process.kill()),
      );
      return;
    }
    // Одиночный файл yt-dlp — загрузчик PyInstaller: SIGTERM он передаёт
    // дочернему Python, а тот — ffmpeg. Не вышел — SIGKILL.
    process.kill();
    var exited = false;
    unawaited(process.exitCode.then((_) => exited = true));
    unawaited(
      Future<void>.delayed(killGrace, () {
        if (!exited) process.kill(ProcessSignal.sigkill);
      }),
    );
  }
}

final class _YtdlRun {
  _YtdlRun(this.request);

  final JobRequest request;
  final StreamController<JobEvent> controller = StreamController<JobEvent>();
  Process? process;
  bool finished = false;

  /// Запущен в своей группе процессов (`setsid`).
  bool group = false;

  void finish(JobEvent event) {
    if (finished) return;
    finished = true;
    controller
      ..add(event)
      ..close();
  }
}
