/// Звук и видео конвертера через ffmpeg (ADR-024, шаг 2): отдельный
/// процесс со списком аргументов — без оболочки, без чтения stdin, без
/// перезаписи (`-n`). Ход работы — из `-progress pipe:1`, длительность — из
/// строки `Duration:` в stderr. Результат пишется во временный файл с
/// явным форматом (`-f`) и переименовывается после кода выхода 0. Текст
/// stderr (в нём пути) наружу не уходит: только код ошибки.
///
/// Только Windows и Linux: на Android запуск скачанных программ запрещён
/// системой (W^X, targetSdk ≥ 29), на macOS — песочницей.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../jobs/job_placement.dart';
import '../../jobs/job_runner.dart';
import 'convert_targets.dart';

/// Аргументы ffmpeg и разбор его вывода.
abstract final class FfmpegArgs {
  /// Список аргументов для цели [target]: [input] → [output]. Пути идут
  /// отдельными элементами: оболочки нет, разбирать их некому. Кадр
  /// берётся на первой секунде; [seek] `false` — самый первый кадр (видео
  /// короче секунды).
  static List<String> build({
    required String target,
    required String input,
    required String output,
    bool seek = true,
  }) {
    return <String>[
      '-hide_banner',
      '-nostdin',
      '-n',
      // Быстрый поиск до входа.
      if (isFrame(target) && seek) ...<String>['-ss', '1'],
      // Вход — только файл на диске: «.mp4», который на деле список HLS
      // или concat, не откроет ни сеть, ни другие локальные файлы.
      '-protocol_whitelist',
      'file',
      '-i',
      input,
      ...switch (target) {
        ConvertTargets.mp3 => <String>[
            '-map', '0:a:0', //
            '-vn',
            '-c:a', 'libmp3lame',
            '-q:a', '2',
          ],
        ConvertTargets.mp4 => <String>[
            '-map', '0:v:0', //
            '-map', '0:a:0?',
            '-c:v', 'libopenh264',
            '-pix_fmt', 'yuv420p',
            '-b:v', '4M',
            '-c:a', 'aac',
            '-b:a', '160k',
            '-movflags', '+faststart',
          ],
        ConvertTargets.webm => <String>[
            '-map', '0:v:0', //
            '-map', '0:a:0?',
            '-c:v', 'libvpx-vp9',
            '-b:v', '0',
            '-crf', '33',
            '-deadline', 'good',
            '-cpu-used', '4',
            '-row-mt', '1',
            '-c:a', 'libopus',
            '-b:a', '128k',
          ],
        ConvertTargets.frameJpeg => <String>[
            '-map', '0:v:0', //
            '-frames:v', '1',
            '-update', '1',
            '-c:v', 'mjpeg',
            '-q:v', '2',
          ],
        ConvertTargets.framePng => <String>[
            '-map', '0:v:0', //
            '-frames:v', '1',
            '-update', '1',
            '-c:v', 'png',
          ],
        _ => throw ArgumentError.value(target, 'target'),
      },
      '-progress',
      'pipe:1',
      '-nostats',
      '-f',
      formatOf(target),
      output,
    ];
  }

  /// Цель — кадр из видео.
  static bool isFrame(String target) =>
      target == ConvertTargets.frameJpeg || target == ConvertTargets.framePng;

  /// Формат вывода (`-f`): временный файл без своего расширения.
  static String formatOf(String target) => switch (target) {
        ConvertTargets.mp3 => 'mp3',
        ConvertTargets.mp4 => 'mp4',
        ConvertTargets.webm => 'webm',
        ConvertTargets.frameJpeg || ConvertTargets.framePng => 'image2',
        _ => throw ArgumentError.value(target, 'target'),
      };

  /// Длительность из строки stderr `  Duration: 00:01:02.50, start: …`;
  /// нет или `N/A` — `null`.
  static Duration? durationOf(String line) {
    final match =
        RegExp(r'Duration:\s*(\d+):(\d{2}):(\d{2})(?:\.(\d+))?').firstMatch(
      line,
    );
    if (match == null) return null;
    final fraction = match.group(4) ?? '0';
    final micros = int.parse(fraction.padRight(6, '0').substring(0, 6));
    return Duration(
      hours: int.parse(match.group(1)!),
      minutes: int.parse(match.group(2)!),
      seconds: int.parse(match.group(3)!),
      microseconds: micros,
    );
  }

  /// Сколько обработано по строке `-progress` (`out_time_us=1234567`;
  /// `out_time_ms` у ffmpeg — тоже микросекунды); иначе `null`.
  static Duration? progressOf(String line) {
    final match =
        RegExp(r'^out_time_(?:us|ms)=(\d+)\s*$').firstMatch(line.trim());
    if (match == null) return null;
    return Duration(microseconds: int.parse(match.group(1)!));
  }

  /// Код ошибки по концу stderr: пути и текст ffmpeg наружу не уходят.
  static String errorOf(String stderrTail) {
    final text = stderrTail.toLowerCase();
    if (text.contains('no space left') || text.contains('permission denied')) {
      return JobCodes.disk;
    }
    if (text.contains('does not contain any stream') ||
        text.contains('matches no streams') ||
        text.contains('nothing was encoded')) {
      return JobCodes.noStream;
    }
    if (text.contains('invalid data found') ||
        text.contains('could not find codec') ||
        text.contains('error opening input') ||
        text.contains('decoding error')) {
      return JobCodes.media;
    }
    return JobCodes.failed;
  }
}

/// Запуск процесса: в приложении — [Process.start] без оболочки, в тестах
/// — подделка.
typedef ProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments,
);

Future<Process> _startProcess(String executable, List<String> arguments) =>
    Process.start(executable, arguments, runInShell: false);

/// Задачи конвертера, которым нужен ffmpeg. [ffmpegPath] — путь к
/// проверенной программе или `null` (не скачана, не прошла проверку).
final class FfmpegJobRunner implements JobRunner {
  FfmpegJobRunner({
    required this.ffmpegPath,
    ProcessStarter? starter,
    bool? windows,
  })  : _starter = starter ?? _startProcess,
        _windows = windows ?? Platform.isWindows;

  final Future<String?> Function() ffmpegPath;
  final ProcessStarter _starter;
  final bool _windows;

  final Map<String, _FfmpegRun> _running = <String, _FfmpegRun>{};

  /// Сколько последних знаков stderr держать для кода ошибки.
  static const int _tailLimit = 4096;

  @override
  Stream<JobEvent> start(JobRequest request) {
    final run = _FfmpegRun(request);
    _running[request.cardId] = run;
    unawaited(_run(run));
    return run.controller.stream;
  }

  Future<void> _run(_FfmpegRun run) async {
    final request = run.request;
    final temp = request.temp!;
    final target = request.target!;
    var lastCode = -1;
    var lastTail = '';
    try {
      final exe = await ffmpegPath();
      if (run.finished) return;
      if (exe == null) {
        _finish(run, const JobFailed(JobCodes.noTool));
        return;
      }
      final source = request.sources.single;
      if (!File(source.path).existsSync()) {
        _finish(run, const JobFailed(JobCodes.missing));
        return;
      }
      final frame = FfmpegArgs.isFrame(request.action);
      run.controller.add(JobProgress(frame ? null : 0, 'Конвертация'));
      // Кадр на первой секунде не нашёлся (видео короче) — ещё раз с
      // самого начала.
      for (final seek
          in frame ? const <bool>[true, false] : const <bool>[true]) {
        IsolateJobRunner.removeQuietly(temp);
        final (code, tail) = await _once(run, exe, source.path, temp, seek);
        if (run.finished) return;
        final produced = File(temp);
        if (code == 0 && produced.existsSync() && produced.lengthSync() > 0) {
          // Имя могли занять, пока шла работа: чужой файл не заменяется.
          final result = JobPlacement.commitFile(temp, target);
          _finish(
            run,
            JobDone(outputs: <String>[result], outputDir: p.dirname(result)),
          );
          return;
        }
        lastCode = code;
        lastTail = tail;
      }
      IsolateJobRunner.removeQuietly(temp);
      _finish(
        run,
        JobFailed(
          lastCode == 0 ? JobCodes.noStream : FfmpegArgs.errorOf(lastTail),
        ),
      );
    } on Object catch (error) {
      IsolateJobRunner.removeQuietly(temp);
      if (!run.finished) {
        _finish(
          run,
          JobFailed(
            error is ProcessException ? JobCodes.noTool : JobCodes.of(error),
          ),
        );
      }
    }
  }

  /// Один запуск ffmpeg: код выхода и конец stderr.
  Future<(int, String)> _once(
    _FfmpegRun run,
    String exe,
    String input,
    String temp,
    bool seek,
  ) async {
    final frame = FfmpegArgs.isFrame(run.request.action);
    final process = await _starter(
      exe,
      FfmpegArgs.build(
        target: run.request.action,
        input: input,
        output: temp,
        seek: seek,
      ),
    );
    run.process = process;
    if (run.finished) {
      _kill(process);
      return (-1, '');
    }
    Duration? total;
    var tail = '';
    final errDone = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((String line) {
      total ??= FfmpegArgs.durationOf(line);
      tail = '$tail\n$line';
      if (tail.length > _tailLimit) {
        tail = tail.substring(tail.length - _tailLimit);
      }
    }).asFuture<void>();
    final outDone = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((String line) {
      final done = FfmpegArgs.progressOf(line);
      final length = total;
      if (done == null || frame || run.finished) return;
      if (length == null || length.inMicroseconds <= 0) {
        run.controller.add(const JobProgress(null, 'Конвертация'));
        return;
      }
      final value = done.inMicroseconds / length.inMicroseconds;
      run.controller.add(JobProgress(value.clamp(0, 0.99), 'Конвертация'));
    }).asFuture<void>();
    final code = await process.exitCode;
    await Future.wait(<Future<void>>[
      errDone.catchError((Object _) {}),
      outDone.catchError((Object _) {}),
    ]);
    return (code, tail);
  }

  void _finish(_FfmpegRun run, JobEvent event) {
    _running.remove(run.request.cardId);
    run.finish(event);
  }

  @override
  void cancel(String cardId) {
    final run = _running.remove(cardId);
    if (run == null || run.finished) return;
    run.finish(const JobFailed(JobCodes.cancelled));
    final process = run.process;
    if (process != null) _kill(process);
    // Процесс мог ещё держать файл: удаляем и сейчас, и после выхода.
    IsolateJobRunner.removeQuietly(run.request.temp!);
    if (process != null) {
      unawaited(
        process.exitCode.then(
          (_) => IsolateJobRunner.removeQuietly(run.request.temp!),
        ),
      );
    }
  }

  void _kill(Process process) {
    if (_windows) {
      // Дерево процессов целиком; аргументы списком, без оболочки.
      unawaited(
        Process.run(
          'taskkill',
          <String>['/T', '/F', '/PID', '${process.pid}'],
        ).then((_) {}, onError: (Object _) => process.kill()),
      );
    } else {
      process.kill(ProcessSignal.sigkill);
    }
  }
}

final class _FfmpegRun {
  _FfmpegRun(this.request);

  final JobRequest request;
  final StreamController<JobEvent> controller = StreamController<JobEvent>();
  Process? process;
  bool finished = false;

  void finish(JobEvent event) {
    if (finished) return;
    finished = true;
    controller
      ..add(event)
      ..close();
  }
}
