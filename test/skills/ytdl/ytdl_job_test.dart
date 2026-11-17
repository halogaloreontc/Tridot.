// Загрузчик видео (ADR-024, шаг 3): аргументы yt-dlp без оболочки и
// конфигов, ссылка последней после `--`, разбор хода работы и пути
// результата, коды ошибок без текста yt-dlp (в нём ссылка), отмена
// убивает процесс и убирает временную папку, нет программы — свой код.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/jobs/job_runner.dart';
import 'package:local_assistant/core/skills/ytdl/ytdl_formats.dart';
import 'package:local_assistant/core/skills/ytdl/ytdl_job.dart';
import 'package:path/path.dart' as p;

const String _url = 'https://example.com/watch?v=abc&list=x';

/// Процесс-подделка: пишет stdout/stderr и выходит с кодом по [finish].
final class _FakeProcess implements Process {
  final StreamController<List<int>> _out = StreamController<List<int>>();
  final StreamController<List<int>> _err = StreamController<List<int>>();
  final Completer<int> _exit = Completer<int>();
  final List<ProcessSignal> killed = <ProcessSignal>[];

  /// Не выходить на SIGTERM (как зависший процесс).
  bool stubborn = false;

  void out(String line) => _out.add(utf8.encode('$line\n'));
  void err(String line) => _err.add(utf8.encode('$line\n'));

  Future<void> finish(int code) async {
    if (!_out.isClosed) await _out.close();
    if (!_err.isClosed) await _err.close();
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
    if (!stubborn || signal == ProcessSignal.sigkill) unawaited(finish(-15));
    return true;
  }
}

/// Запуски через подделку. До запуска задача создаёт папки настоящим
/// вводом-выводом (поток ввода-вывода, а не очередь событий), поэтому
/// тест ждёт сам вызов: одного `pumpEventQueue()` под нагрузкой не
/// хватало — папок ещё не было, запуска тоже.
final class _Starts {
  _Starts(this.process, {this.missing});

  final _FakeProcess process;

  /// Программа, которой «нет» (ProcessException), например setsid.
  final String? missing;

  /// Вызовы по порядку: программа и аргументы.
  final List<(String, List<String>)> calls = <(String, List<String>)>[];

  final Completer<void> _launched = Completer<void>();

  Future<Process> call(String exe, List<String> args) async {
    calls.add((exe, args));
    if (exe == missing) throw ProcessException(exe, const <String>[]);
    if (!_launched.isCompleted) _launched.complete();
    return process;
  }

  /// Ждёт удачного запуска; дальше задача подхватывает процесс без
  /// ввода-вывода — ей хватает очереди событий. Задача кончилась раньше
  /// запуска ([done]) — тест падает сразу, а не через 30 с.
  Future<void> launched(Future<Object?> done) async {
    await Future.any(<Future<void>>[
      _launched.future,
      done.then((_) {
        if (!_launched.isCompleted) fail('задача кончилась без запуска');
      }),
    ]);
    await pumpEventQueue();
  }
}

void main() {
  group('аргументы', () {
    test('без оболочки, конфигов, cookies и плагинов; ссылка после --', () {
      final args = YtdlArgs.build(
        url: _url,
        format: YtdlFormats.video720,
        home: '/home/u/Загрузки/Tridot',
        temp: '/home/u/Загрузки/Tridot/.tridot-j1.tmp',
        ffmpeg: '/tools/ffmpeg',
      );
      expect(
        args,
        containsAll(<String>[
          '--ignore-config',
          '--no-plugin-dirs',
          '--no-playlist',
          '--no-cookies',
          '--no-cookies-from-browser',
          '--newline',
        ]),
      );
      expect(args.last, _url);
      expect(args[args.length - 2], '--');
      // Ссылка — ровно один элемент списка и только в конце.
      expect(args.where((String a) => a.contains('example.com')), hasLength(1));
      expect(
        args,
        containsAllInOrder(<String>['--ffmpeg-location', '/tools/ffmpeg']),
      );
      expect(
        args,
        containsAllInOrder(<String>[
          '-P',
          'home:/home/u/Загрузки/Tridot',
          '-P',
          'temp:/home/u/Загрузки/Tridot/.tridot-j1.tmp',
        ]),
      );
      expect(args, isNot(contains('-U')));
      expect(args, isNot(contains('--update')));
      expect(args[args.indexOf('-f') + 1], contains('height<=720'));
      expect(args[args.indexOf('-f') + 1], contains('+ba'));
    });

    test('без ffmpeg — только цельный файл, звук в mp3 недоступен', () {
      final args = YtdlArgs.build(
        url: _url,
        format: YtdlFormats.video1080,
        home: '/d',
        temp: '/d/.t',
      );
      expect(args, isNot(contains('--ffmpeg-location')));
      expect(args[args.indexOf('-f') + 1], isNot(contains('+')));
      expect(args[args.indexOf('-f') + 1], contains('height<=1080'));
      expect(
        () => YtdlArgs.build(
          url: _url,
          format: YtdlFormats.audio,
          home: '/d',
          temp: '/d/.t',
        ),
        throwsArgumentError,
      );
      final audio = YtdlArgs.build(
        url: _url,
        format: YtdlFormats.audio,
        home: '/d',
        temp: '/d/.t',
        ffmpeg: '/f',
      );
      expect(
        audio,
        containsAllInOrder(<String>['-x', '--audio-format', 'mp3']),
      );
    });

    test('плохая ссылка и неизвестный формат — ошибка до запуска', () {
      for (final url in <String>[
        'ftp://example.com/v',
        'file:///etc/passwd',
        '-o/etc/x',
        'https://',
        'https://exa mple.com',
      ]) {
        expect(
          () => YtdlArgs.build(
            url: url,
            format: YtdlFormats.video480,
            home: '/d',
            temp: '/d/.t',
          ),
          throwsArgumentError,
          reason: url,
        );
      }
      expect(
        () => YtdlArgs.build(url: _url, format: 'best', home: '/d', temp: '/t'),
        throwsArgumentError,
      );
    });

    test('ход работы и путь результата', () {
      expect(
        YtdlArgs.progressOf('tridot-progress 50 200'),
        (true, 0.25),
      );
      expect(YtdlArgs.progressOf('tridot-progress 10 NA'), (true, null));
      expect(YtdlArgs.progressOf('[download] 10%'), (false, null));
      expect(
        YtdlArgs.fileOf('tridot-file /d/Ролик [abc].mp4'),
        '/d/Ролик [abc].mp4',
      );
      expect(YtdlArgs.fileOf('[Merger] Merging'), isNull);
    });

    test('коды ошибок без текста yt-dlp', () {
      expect(
        YtdlArgs.errorOf('ERROR: Unsupported URL: $_url'),
        JobCodes.badUrl,
      );
      expect(
        YtdlArgs.errorOf('ERROR: [youtube] abc: Video unavailable'),
        JobCodes.unavailable,
      );
      expect(
        YtdlArgs.errorOf('ERROR: [generic] Unable to download webpage: '
            '<urlopen error [Errno -2] Name or service not known>'),
        JobCodes.network,
      );
      expect(
        YtdlArgs.errorOf('ERROR: unable to write data: [Errno 28] No space '
            'left on device'),
        JobCodes.disk,
      );
      expect(YtdlArgs.errorOf('что-то странное'), JobCodes.failed);
      for (final code in <String>[
        JobCodes.badUrl,
        JobCodes.unavailable,
        JobCodes.network,
        JobCodes.noDownloader,
      ]) {
        expect(JobCodes.message(code), isNot(contains('http')));
      }
    });
  });

  group('задача', () {
    late Directory temp;
    late String home;
    late String scratch;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('ytdl_job');
      home = p.join(temp.path, 'Tridot');
      scratch = p.join(home, '.tridot-j1.tmp');
    });
    tearDown(() => temp.deleteSync(recursive: true));

    JobRequest request({String format = YtdlFormats.video720}) => JobRequest(
          cardId: 'j1',
          extensionId: 'ytdl',
          action: format,
          sources: const <JobSource>[],
          outputDir: home,
          temp: scratch,
          url: _url,
        );

    test('готово: путь из --print, ход работы, временная папка убрана',
        () async {
      final process = _FakeProcess();
      final starts = _Starts(process);
      final runner = YtdlJobRunner(
        ytdlpPath: () async => '/tools/yt-dlp',
        ffmpegPath: () async => null,
        windows: false,
        starter: starts.call,
      );
      final events = <JobEvent>[];
      final done = runner.start(request()).listen(events.add).asFuture<void>();
      await starts.launched(done);
      final (exe, argv) = starts.calls.single;
      expect(exe, '/tools/yt-dlp');
      expect(argv.last, _url);
      expect(Directory(scratch).existsSync(), isTrue);
      process
        ..out('tridot-progress 50 100')
        ..err('tridot-post');
      final file = File(p.join(home, 'Ролик [abc].mp4'))
        ..writeAsStringSync('v');
      process.out('tridot-file ${file.path}');
      await process.finish(0);
      await done;
      expect(
        events.whereType<JobProgress>().map((JobProgress e) => e.value),
        contains(0.5),
      );
      expect(
        events.whereType<JobProgress>().map((JobProgress e) => e.stage),
        contains('Обработка'),
      );
      final result = events.last as JobDone;
      expect(result.outputs, <String>[file.path]);
      expect(result.outputDir, home);
      expect(Directory(scratch).existsSync(), isFalse);
    });

    test('путь вне папки загрузок не принимается', () async {
      final process = _FakeProcess();
      final starts = _Starts(process);
      final runner = YtdlJobRunner(
        ytdlpPath: () async => '/tools/yt-dlp',
        ffmpegPath: () async => null,
        windows: false,
        starter: starts.call,
      );
      final events = <JobEvent>[];
      final done = runner.start(request()).listen(events.add).asFuture<void>();
      await starts.launched(done);
      final outside = File(p.join(temp.path, 'чужой.mp4'))
        ..writeAsStringSync('x');
      process.out('tridot-file ${outside.path}');
      await process.finish(0);
      await done;
      expect((events.last as JobDone).outputs, isEmpty);
    });

    test('ошибка: только код, без текста и ссылки', () async {
      final process = _FakeProcess();
      final starts = _Starts(process);
      final runner = YtdlJobRunner(
        ytdlpPath: () async => '/tools/yt-dlp',
        ffmpegPath: () async => null,
        windows: false,
        starter: starts.call,
      );
      final events = <JobEvent>[];
      final done = runner.start(request()).listen(events.add).asFuture<void>();
      await starts.launched(done);
      process.err('ERROR: [youtube] abc: Private video. $_url');
      await process.finish(1);
      await done;
      final failed = events.last as JobFailed;
      expect(failed.code, JobCodes.unavailable);
      expect(Directory(scratch).existsSync(), isFalse);
    });

    test('нет yt-dlp — свой код; звук без ffmpeg — noTool', () async {
      final none = YtdlJobRunner(
        ytdlpPath: () async => null,
        ffmpegPath: () async => null,
        starter: (String e, List<String> a) => fail('не запускается'),
      );
      expect(
        (await none.start(request()).last as JobFailed).code,
        JobCodes.noDownloader,
      );
      final noFfmpeg = YtdlJobRunner(
        ytdlpPath: () async => '/tools/yt-dlp',
        ffmpegPath: () async => null,
        starter: (String e, List<String> a) => fail('не запускается'),
      );
      expect(
        (await noFfmpeg.start(request(format: YtdlFormats.audio)).last
                as JobFailed)
            .code,
        JobCodes.noTool,
      );
      final broken = YtdlJobRunner(
        ytdlpPath: () async => '/tools/yt-dlp',
        ffmpegPath: () async => null,
        starter: (String e, List<String> a) async =>
            throw const ProcessException('yt-dlp', <String>[]),
      );
      expect(
        (await broken.start(request()).last as JobFailed).code,
        JobCodes.noDownloader,
      );
    });

    test('отмена: SIGTERM, затем SIGKILL; временная папка убрана', () async {
      final process = _FakeProcess()..stubborn = true;
      final starts = _Starts(process);
      final runner = YtdlJobRunner(
        ytdlpPath: () async => '/tools/yt-dlp',
        ffmpegPath: () async => null,
        windows: false,
        killGrace: const Duration(milliseconds: 10),
        starter: starts.call,
      );
      final events = <JobEvent>[];
      final done = runner.start(request()).listen(events.add).asFuture<void>();
      await starts.launched(done);
      File(p.join(scratch, 'Ролик.mp4.part')).writeAsStringSync('частично');
      runner.cancel('j1');
      await done;
      expect((events.last as JobFailed).code, JobCodes.cancelled);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        process.killed,
        <ProcessSignal>[ProcessSignal.sigterm, ProcessSignal.sigkill],
      );
      expect(Directory(scratch).existsSync(), isFalse);
    });

    test('Linux: запуск через setsid, «Отмена» — всей группе', () async {
      final process = _FakeProcess();
      final starts = _Starts(process);
      final runner = YtdlJobRunner(
        ytdlpPath: () async => '/tools/yt-dlp',
        ffmpegPath: () async => null,
        windows: false,
        processGroup: true,
        starter: starts.call,
      );
      final done = runner.start(request()).last;
      await starts.launched(done);
      final (exe, argv) = starts.calls.single;
      expect(exe, YtdlJobRunner.setsidTool);
      expect(argv.first, '/tools/yt-dlp');
      expect(argv.last, _url);
      await process.finish(0);
      await done;
    });

    test('Linux: нет setsid — обычный запуск', () async {
      final process = _FakeProcess();
      final starts = _Starts(process, missing: YtdlJobRunner.setsidTool);
      final runner = YtdlJobRunner(
        ytdlpPath: () async => '/tools/yt-dlp',
        ffmpegPath: () async => null,
        windows: false,
        processGroup: true,
        starter: starts.call,
      );
      final done = runner.start(request()).last;
      await starts.launched(done);
      expect(
        starts.calls.map(((String, List<String>) c) => c.$1),
        <String>[YtdlJobRunner.setsidTool, '/tools/yt-dlp'],
      );
      await process.finish(0);
      await done;
    });

    test(
      'Linux, настоящий процесс: «Отмена» останавливает и дочерний',
      () async {
        // «yt-dlp» — сценарий оболочки, который запускает дочерний процесс
        // (как yt-dlp запускает ffmpeg) и ждёт.
        final script = File(p.join(temp.path, 'fake-ytdlp.sh'))
          ..writeAsStringSync(
            '#!/bin/sh\nsleep 300 &\necho \$! > "\$0.child"\nwait\n',
          );
        await Process.run('chmod', <String>['755', script.path]);
        final runner = YtdlJobRunner(
          ytdlpPath: () async => script.path,
          ffmpegPath: () async => null,
          killGrace: const Duration(milliseconds: 200),
        );
        final events = <JobEvent>[];
        final done =
            runner.start(request()).listen(events.add).asFuture<void>();
        // Файл появляется раньше, чем в нём номер (`>` сначала создаёт
        // пустой): ждём номер, а не файл.
        final childFile = File('${script.path}.child');
        String childPid() =>
            childFile.existsSync() ? childFile.readAsStringSync().trim() : '';
        for (var i = 0; i < 250 && childPid().isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final child = childPid();
        expect(child, matches(RegExp(r'^\d+$')));
        // Жив — есть в /proc и не зомби. Процесс могут убрать между
        // проверкой и чтением: нет файла — значит, уже не жив.
        bool childAlive() {
          try {
            return !File('/proc/$child/stat')
                .readAsStringSync()
                .contains(') Z ');
          } on FileSystemException {
            return false;
          }
        }

        expect(childAlive(), isTrue);
        runner.cancel('j1');
        await done;
        expect((events.last as JobFailed).code, JobCodes.cancelled);
        var alive = true;
        for (var i = 0; i < 250 && alive; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          alive = childAlive();
        }
        expect(alive, isFalse);
      },
      skip: Platform.isLinux &&
              (File('/usr/bin/setsid').existsSync() ||
                  File('/bin/setsid').existsSync())
          ? false
          : 'нужен Linux с setsid',
    );
  });
}
