// ffmpeg конвертера (ADR-024, шаг 2): список аргументов без оболочки,
// разбор хода работы, переименование результата после кода 0, коды ошибок
// без текста stderr, отмена убивает процесс и убирает временный файл,
// нет программы — noTool.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/jobs/job_runner.dart';
import 'package:local_assistant/core/skills/converter/convert_targets.dart';
import 'package:local_assistant/core/skills/converter/ffmpeg_job.dart';
import 'package:local_assistant/core/skills/converter/image_convert.dart';
import 'package:path/path.dart' as p;

/// Процесс-подделка: пишет stdout/stderr, создаёт выходной файл и выходит
/// с кодом [code] по [finish].
final class _FakeProcess implements Process {
  _FakeProcess();

  final StreamController<List<int>> _out = StreamController<List<int>>();
  final StreamController<List<int>> _err = StreamController<List<int>>();
  final Completer<int> _exit = Completer<int>();
  final List<ProcessSignal> killed = <ProcessSignal>[];

  void out(String line) => _out.add(utf8.encode('$line\n'));
  void err(String line) => _err.add(utf8.encode('$line\n'));

  Future<void> finish(int code) async {
    await _out.close();
    await _err.close();
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  Stream<List<int>> get stdout => _out.stream;

  @override
  Stream<List<int>> get stderr => _err.stream;

  @override
  IOSink get stdin => throw UnimplementedError();

  @override
  Future<int> get exitCode => _exit.future;

  @override
  int get pid => 4242;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed.add(signal);
    unawaited(finish(-9));
    return true;
  }
}

void main() {
  group('аргументы', () {
    test('каждая цель: вход после -i, выход последним, формат явно', () {
      for (final target in <String>[
        ConvertTargets.mp3,
        ConvertTargets.m4a,
        ConvertTargets.wav,
        ConvertTargets.mp4,
        ConvertTargets.mov,
        ConvertTargets.webm,
        ConvertTargets.frameJpeg,
        ConvertTargets.framePng,
      ]) {
        final args = FfmpegArgs.build(
          target: target,
          input: '/in/видео; rm -rf ~.mp4',
          output: '/out/.v.part',
        );
        expect(args.first, '-hide_banner', reason: target);
        expect(args, containsAll(<String>['-nostdin', '-n']));
        expect(args[args.indexOf('-i') + 1], '/in/видео; rm -rf ~.mp4');
        expect(args.last, '/out/.v.part');
        expect(args[args.length - 2], FfmpegArgs.formatOf(target));
        expect(args[args.length - 3], '-f');
        expect(args, containsAllInOrder(<String>['-progress', 'pipe:1']));
        // Путь — один элемент: никакой оболочки.
        expect(args.where((String a) => a.contains('rm -rf')), hasLength(1));
      }
    });

    test('кодеки LGPL-сборки', () {
      List<String> of(String t) =>
          FfmpegArgs.build(target: t, input: 'i', output: 'o');
      expect(of('mp3'), containsAllInOrder(<String>['-c:a', 'libmp3lame']));
      expect(of('mp4'), containsAllInOrder(<String>['-c:v', 'libopenh264']));
      expect(of('mp4'), isNot(contains('libx264')));
      expect(of('webm'), containsAllInOrder(<String>['-c:v', 'libvpx-vp9']));
      expect(of('webm'), containsAllInOrder(<String>['-c:a', 'libopus']));
      expect(
        of('frame-jpeg'),
        containsAllInOrder(<String>['-ss', '1', '-i', 'i', '-frames:v', '1']),
      );
      expect(
        FfmpegArgs.build(
          target: 'frame-png',
          input: 'i',
          output: 'o',
          seek: false,
        ),
        isNot(contains('-ss')),
      );
      expect(() => of('pdf'), throwsArgumentError);
    });

    test('качество: битрейт, размер, качество видео, кадр JPEG', () {
      List<String> of(String t, Map<String, String> o) => FfmpegArgs.build(
            target: t,
            input: 'i',
            output: 'o',
            options: ConvertOptions.fromMap(o, t),
          );
      // По умолчанию: mp3 192 кбит/с CBR, mp4 без масштаба, 4 Мбит/с.
      expect(
        of('mp3', const <String, String>{}),
        containsAllInOrder(<String>['-c:a', 'libmp3lame', '-b:a', '192k']),
      );
      expect(of('mp3', const <String, String>{}), isNot(contains('-q:a')));
      expect(
        of('mp3', const <String, String>{'audio_kbps': '320'}),
        containsAllInOrder(<String>['-b:a', '320k']),
      );
      // Чужое и недопустимое значение не доходит до ffmpeg.
      expect(
        of('mp3', const <String, String>{'audio_kbps': '999; rm'}),
        containsAllInOrder(<String>['-b:a', '192k']),
      );
      expect(
        of('m4a', const <String, String>{'audio_kbps': '256'}),
        containsAllInOrder(<String>['-vn', '-c:a', 'aac', '-b:a', '256k']),
      );
      expect(FfmpegArgs.formatOf('m4a'), 'ipod');
      expect(
        of('wav', const <String, String>{}),
        containsAllInOrder(<String>['-vn', '-c:a', 'pcm_s16le']),
      );
      final plain = of('mp4', const <String, String>{});
      expect(plain, isNot(contains('-vf')));
      expect(plain, containsAllInOrder(<String>['-b:v', '4000k']));
      expect(plain, containsAllInOrder(<String>['-b:a', '160k']));
      final small = of('mp4', const <String, String>{
        'video_res': '720',
        'video_quality': 'eco',
      });
      expect(
        small,
        containsAllInOrder(<String>[
          '-vf',
          "scale='min(1280,iw)':'min(1280,ih)':"
              'force_original_aspect_ratio=decrease:force_divisible_by=2',
          '-c:v',
          'libopenh264',
          '-b:v',
          '1800k',
          '-b:a',
          '128k',
        ]),
      );
      expect(
        of('mov', const <String, String>{
          'video_res': '1080',
          'video_quality': 'high',
        }),
        containsAllInOrder(<String>['-vf', '-b:v', '8000k', '-f', 'mov']),
      );
      expect(
        of('webm', const <String, String>{
          'video_res': '480',
          'video_quality': 'high',
        }),
        containsAllInOrder(<String>['-vf', '-c:v', 'libvpx-vp9', '-crf', '28']),
      );
      expect(
        of('frame-jpeg', const <String, String>{'jpeg_quality': '60'}),
        containsAllInOrder(<String>['-c:v', 'mjpeg', '-q:v', '8']),
      );
      expect(
        of('frame-jpeg', const <String, String>{}),
        containsAllInOrder(<String>['-q:v', '3']),
      );
    });

    test('масштаб ffmpeg: длинная сторона, чётные размеры, без увеличения',
        () async {
      // Настоящий ffmpeg, если он есть на машине (необязательно).
      final ffmpeg = Platform.isLinux && File('/usr/bin/ffmpeg').existsSync()
          ? '/usr/bin/ffmpeg'
          : null;
      if (ffmpeg == null) {
        markTestSkipped('ffmpeg не установлен');
        return;
      }
      final dir = Directory.systemTemp.createTempSync('ff');
      addTearDown(() => dir.deleteSync(recursive: true));
      Future<String> probe(int w, int h, String res) async {
        final input = p.join(dir.path, 'in_${w}x$h.mp4');
        if (!File(input).existsSync()) {
          final made = await Process.run(ffmpeg, <String>[
            '-hide_banner', '-loglevel', 'error', //
            '-f', 'lavfi', '-i', 'testsrc=size=${w}x$h:rate=5:duration=0.4',
            '-pix_fmt', 'yuv420p', input,
          ]);
          expect(made.exitCode, 0, reason: '${made.stderr}');
        }
        final out = p.join(dir.path, 'out_${w}x${h}_$res.png');
        final args = FfmpegArgs.build(
          target: ConvertTargets.framePng,
          input: input,
          output: out,
          seek: false,
          options: ConvertOptions.fromMap(
            <String, String>{'video_res': res},
            ConvertTargets.mp4,
          ),
        );
        // Масштаб тот же, что у mp4; проверяем его на одном кадре.
        final vf = FfmpegArgs.build(
          target: ConvertTargets.mp4,
          input: input,
          output: out,
          options: ConvertOptions.fromMap(
            <String, String>{'video_res': res},
            ConvertTargets.mp4,
          ),
        );
        final filter = vf[vf.indexOf('-vf') + 1];
        final i = args.indexOf('-c:v');
        final run = await Process.run(ffmpeg, <String>[
          ...args.sublist(0, i),
          '-vf',
          filter,
          ...args
              .sublist(i)
              .where((String a) => a != 'pipe:1' && a != '-progress'),
        ]);
        expect(run.exitCode, 0, reason: '${run.stderr}');
        final info =
            await Process.run(ffmpeg, <String>['-hide_banner', '-i', out]);
        return RegExp(r', (\d{2,5}x\d{2,5})')
            .firstMatch('${info.stderr}')!
            .group(1)!;
      }

      expect(await probe(1920, 1080, '720'), '1280x720');
      expect(await probe(1080, 1920, '480'), '480x854');
      // Меньшее видео не растягивается.
      expect(await probe(640, 360, '1080'), '640x360');
    });

    test('длительность и ход работы', () {
      expect(
        FfmpegArgs.durationOf('  Duration: 00:01:02.50, start: 0.000000'),
        const Duration(minutes: 1, seconds: 2, milliseconds: 500),
      );
      expect(FfmpegArgs.durationOf('  Duration: N/A, bitrate: N/A'), isNull);
      expect(
        FfmpegArgs.progressOf('out_time_us=1500000'),
        const Duration(milliseconds: 1500),
      );
      expect(FfmpegArgs.progressOf('out_time=00:00:01.500000'), isNull);
      expect(FfmpegArgs.progressOf('progress=end'), isNull);
    });

    test('коды ошибок по stderr', () {
      expect(
        FfmpegArgs.errorOf('x.mp4: Invalid data found when processing input'),
        JobCodes.media,
      );
      expect(
        FfmpegArgs.errorOf('Output file does not contain any stream'),
        JobCodes.noStream,
      );
      expect(FfmpegArgs.errorOf('No space left on device'), JobCodes.disk);
      expect(FfmpegArgs.errorOf('что-то ещё'), JobCodes.failed);
    });
  });

  group('процесс', () {
    late Directory temp;
    late File source;
    late List<List<String>> started;
    late List<_FakeProcess> processes;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('ffmpeg_job');
      source = File(p.join(temp.path, 'клип.mp4'))..writeAsStringSync('v');
      started = <List<String>>[];
      processes = <_FakeProcess>[];
    });
    tearDown(() => temp.deleteSync(recursive: true));

    FfmpegJobRunner runner({
      String? path = '/tools/ffmpeg',
      void Function(_FakeProcess process, List<String> args)? script,
    }) =>
        FfmpegJobRunner(
          ffmpegPath: () async => path,
          windows: false,
          starter: (String exe, List<String> args) async {
            expect(exe, path);
            started.add(args);
            final process = _FakeProcess();
            processes.add(process);
            script?.call(process, args);
            return process;
          },
        );

    JobRequest request(String target) => ConvertOps.plan(
          cardId: 'c1',
          target: target,
          source: JobSource(source.path, 'клип.mp4'),
          outputDir: temp.path,
        );

    test('ход работы по -progress, результат после кода 0', () async {
      final r = request(ConvertTargets.mp3);
      final events = <JobEvent>[];
      final done = Completer<void>();
      runner(
        script: (_FakeProcess process, List<String> args) {
          scheduleMicrotask(() async {
            process.err('  Duration: 00:00:10.00, start: 0.000000');
            await Future<void>.delayed(Duration.zero);
            process.out('out_time_us=5000000');
            await Future<void>.delayed(Duration.zero);
            File(args.last).writeAsStringSync('mp3');
            await process.finish(0);
          });
        },
      ).start(r).listen(events.add, onDone: done.complete);
      await done.future;
      final progress = events.whereType<JobProgress>().map((e) => e.value);
      expect(progress, contains(0.5));
      final last = events.last as JobDone;
      expect(last.outputs.single, p.join(temp.path, 'клип.mp3'));
      expect(File(last.outputs.single).readAsStringSync(), 'mp3');
      expect(File(r.temp!).existsSync(), isFalse);
      expect(source.readAsStringSync(), 'v', reason: 'исходник не меняется');
    });

    test('ошибка — только код, временный файл убран', () async {
      final r = request(ConvertTargets.webm);
      final events = await runner(
        script: (_FakeProcess process, List<String> args) {
          scheduleMicrotask(() async {
            File(args.last).writeAsStringSync('полфайла');
            process.err('${source.path}: Invalid data found when processing');
            await process.finish(1);
          });
        },
      ).start(r).toList();
      expect((events.last as JobFailed).code, JobCodes.media);
      expect(File(r.temp!).existsSync(), isFalse);
      expect(File(r.target!).existsSync(), isFalse);
    });

    test('кадр: короткое видео — второй запуск без -ss', () async {
      final r = request(ConvertTargets.frameJpeg);
      final events = await runner(
        script: (_FakeProcess process, List<String> args) {
          scheduleMicrotask(() async {
            if (!args.contains('-ss')) File(args.last).writeAsStringSync('j');
            await process.finish(args.contains('-ss') ? 1 : 0);
          });
        },
      ).start(r).toList();
      expect(started, hasLength(2));
      expect(started.first, contains('-ss'));
      expect(started.last, isNot(contains('-ss')));
      expect(events.last, isA<JobDone>());
      expect(p.basename((events.last as JobDone).outputs.single), 'клип.jpg');
    });

    test('нет программы — noTool, процесс не запускается', () async {
      final events =
          await runner(path: null).start(request(ConvertTargets.mp3)).toList();
      expect((events.single as JobFailed).code, JobCodes.noTool);
      expect(started, isEmpty);
    });

    test('исходника нет — missing', () async {
      source.deleteSync();
      final events = await runner().start(request(ConvertTargets.mp3)).toList();
      expect((events.single as JobFailed).code, JobCodes.missing);
    });

    test('отмена убивает процесс и убирает временный файл', () async {
      final r = request(ConvertTargets.mp4);
      final job = runner(
        script: (_FakeProcess process, List<String> args) {
          File(args.last).writeAsStringSync('часть');
        },
      );
      final events = <JobEvent>[];
      final done = Completer<void>();
      job.start(r).listen(events.add, onDone: done.complete);
      for (var i = 0; i < 20 && processes.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(File(r.temp!).existsSync(), isTrue);
      job.cancel('c1');
      await done.future;
      expect((events.last as JobFailed).code, JobCodes.cancelled);
      expect(processes.single.killed, <ProcessSignal>[ProcessSignal.sigkill]);
      await Future<void>.delayed(Duration.zero);
      expect(File(r.temp!).existsSync(), isFalse);
      expect(File(r.target!).existsSync(), isFalse);
    });

    test('маршрут: картинки — изолят, звук и видео — ffmpeg', () async {
      final isolate = _Recorder();
      final ffmpeg = _Recorder();
      final router = JobRunnerRouter(
        (JobRequest r) => ConvertOps.usesDart(r) ? isolate : ffmpeg,
      );
      await router.start(request(ConvertTargets.mp3)).toList();
      final picture = ConvertOps.plan(
        cardId: 'c2',
        target: ConvertTargets.png,
        source: const JobSource('/a/b.jpg', 'b.jpg'),
        outputDir: '/a',
      );
      await router.start(picture).toList();
      expect(ffmpeg.started, <String>['c1']);
      expect(isolate.started, <String>['c2']);
      router.cancel('c1');
      expect(ffmpeg.cancelled, isEmpty, reason: 'задача уже закончилась');
    });
  });
}

final class _Recorder implements JobRunner {
  final List<String> started = <String>[];
  final List<String> cancelled = <String>[];

  @override
  Stream<JobEvent> start(JobRequest request) {
    started.add(request.cardId);
    return Stream<JobEvent>.value(const JobDone());
  }

  @override
  void cancel(String cardId) => cancelled.add(cardId);
}
