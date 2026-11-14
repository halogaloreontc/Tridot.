// Системный конвертер (ADR-026): Dart запускает задачу по мосту, получает
// ход работы и итог, сам переименовывает временный файл в результат
// (чужой файл не заменяется — «(2)»), убирает временный файл при ошибке и
// отмене, а оборванный поток событий — ошибка, а не вечное ожидание.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';
import 'package:local_assistant/core/jobs/job_runner.dart';
import 'package:local_assistant/core/skills/converter/convert_targets.dart';
import 'package:local_assistant/core/skills/converter/image_convert.dart';
import 'package:local_assistant/core/skills/converter/platform_media_job.dart';
import 'package:path/path.dart' as p;

/// Мост-подделка: запоминает вызовы, события шлёт тест.
final class _FakeBridge implements MediaBridge {
  final StreamController<Map<Object?, Object?>> controller =
      StreamController<Map<Object?, Object?>>.broadcast();
  final List<Map<String, Object?>> started = <Map<String, Object?>>[];
  final List<String> cancelled = <String>[];
  Map<Object?, Object?>? caps;
  Object? startError;
  bool hang = false;

  @override
  Future<Map<Object?, Object?>?> capabilities() async {
    if (hang) return Completer<Map<Object?, Object?>?>().future;
    return caps;
  }

  @override
  Future<void> start(Map<String, Object?> arguments) async {
    started.add(arguments);
    if (startError case final Object error) throw error;
  }

  @override
  Future<void> cancel(String id) async => cancelled.add(id);

  @override
  Stream<Map<Object?, Object?>> get events => controller.stream;

  void send(Map<Object?, Object?> event) => controller.add(event);
}

void main() {
  late Directory dir;
  late File input;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('native-media-');
    input = File(p.join(dir.path, 'клип.mp4'))..writeAsBytesSync(<int>[1, 2]);
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  JobRequest plan(
    String target, [
    Map<String, String> options = const <String, String>{},
  ]) =>
      ConvertOps.plan(
        cardId: 'c1',
        target: target,
        source: JobSource(input.path, 'клип.mp4'),
        outputDir: dir.path,
        options: options,
      );

  /// События задачи до итога.
  Future<List<JobEvent>> collect(Stream<JobEvent> stream) => stream.toList();

  test('аргументы: пути, цель и качество из карточки', () async {
    final bridge = _FakeBridge();
    final runner = PlatformMediaJobRunner(bridge);
    final request = plan(ConvertTargets.mp3, <String, String>{
      ConvertQuality.audioKbps: '320',
    });
    final events = collect(runner.start(request));
    await pumpEventQueue();
    final args = bridge.started.single;
    expect(args['input'], input.path);
    expect(args['output'], request.temp);
    expect(args['target'], 'mp3');
    expect(args['audioKbps'], 320);
    expect(args['id'], startsWith('c1-'));
    bridge.send(<Object?, Object?>{'id': args['id'], 'error': 'encoder'});
    expect((await events).last, isA<JobFailed>());
  });

  test('ход работы → готово: результат под своим именем', () async {
    final bridge = _FakeBridge();
    final runner = PlatformMediaJobRunner(bridge);
    final request = plan(ConvertTargets.m4a);
    final events = collect(runner.start(request));
    await pumpEventQueue();
    final id = bridge.started.single['id'];
    bridge
      ..send(<Object?, Object?>{'id': id, 'progress': 0.5})
      ..send(<Object?, Object?>{'id': 'чужая', 'progress': 0.9})
      ..send(<Object?, Object?>{'id': id, 'progress': null})
      ..send(<Object?, Object?>{'id': id, 'progress': 1.0});
    File(request.temp!).writeAsBytesSync(<int>[9, 9, 9]);
    bridge.send(<Object?, Object?>{'id': id, 'done': true});
    final list = await events;
    final progress = list.whereType<JobProgress>().map((e) => e.value);
    expect(progress, <double?>[0, 0.5, null, 0.99]);
    final done = list.last as JobDone;
    expect(done.outputs.single, p.join(dir.path, 'клип.m4a'));
    expect(File(done.outputs.single).readAsBytesSync(), <int>[9, 9, 9]);
    expect(File(request.temp!).existsSync(), isFalse);
  });

  test('имя заняли, пока шла работа, — «(2)», чужой файл цел', () async {
    final bridge = _FakeBridge();
    final runner = PlatformMediaJobRunner(bridge);
    final request = plan(ConvertTargets.mp3);
    final events = collect(runner.start(request));
    await pumpEventQueue();
    File(request.target!).writeAsStringSync('чужой');
    File(request.temp!).writeAsBytesSync(<int>[1]);
    bridge.send(<Object?, Object?>{
      'id': bridge.started.single['id'],
      'done': true,
    });
    final done = (await events).last as JobDone;
    expect(done.outputs.single, p.join(dir.path, 'клип (2).mp3'));
    expect(File(request.target!).readAsStringSync(), 'чужой');
  });

  test('готово, но файла нет — ошибка, а не пустой результат', () async {
    final bridge = _FakeBridge();
    final runner = PlatformMediaJobRunner(bridge);
    final events = collect(runner.start(plan(ConvertTargets.wav)));
    await pumpEventQueue();
    bridge.send(<Object?, Object?>{
      'id': bridge.started.single['id'],
      'done': true,
    });
    expect(((await events).last as JobFailed).code, JobCodes.failed);
  });

  test('коды ошибок системы; неизвестный — failed; временный убран', () async {
    for (final (sent, expected) in <(Object?, String)>[
      ('noStream', JobCodes.noStream),
      ('mediaOpen', JobCodes.mediaOpen),
      ('encoder', JobCodes.encoder),
      ('disk', JobCodes.disk),
      ('tooBig', JobCodes.tooBig),
      ('tooBigWav', JobCodes.tooBigWav),
      ('noMemory', JobCodes.noMemory),
      ('/data/user/0/секрет.mp4', JobCodes.failed),
      (42, JobCodes.failed),
    ]) {
      final bridge = _FakeBridge();
      final runner = PlatformMediaJobRunner(bridge);
      final request = plan(ConvertTargets.mp3);
      final events = collect(runner.start(request));
      await pumpEventQueue();
      File(request.temp!).writeAsBytesSync(<int>[1]);
      bridge.send(<Object?, Object?>{
        'id': bridge.started.single['id'],
        'error': sent,
      });
      expect(((await events).last as JobFailed).code, expected);
      expect(File(request.temp!).existsSync(), isFalse);
      expect(JobCodes.message(expected), isNot(contains('/data')));
    }
  });

  test('отказ при запуске (неверная цель) — сразу, без временного файла',
      () async {
    final bridge = _FakeBridge()
      ..startError = const MediaBridgeException('unsupported');
    final runner = PlatformMediaJobRunner(bridge);
    final request = plan(ConvertTargets.mp4);
    final list = await collect(runner.start(request));
    expect((list.last as JobFailed).code, JobCodes.unsupported);
    expect(File(request.temp!).existsSync(), isFalse);
  });

  test('исходника нет — missing, система не зовётся', () async {
    final bridge = _FakeBridge();
    final runner = PlatformMediaJobRunner(bridge);
    input.deleteSync();
    final list = await collect(runner.start(plan(ConvertTargets.mp3)));
    expect((list.last as JobFailed).code, JobCodes.missing);
    expect(bridge.started, isEmpty);
  });

  test('отмена: cancelled сразу, система отменяет, временный убран', () async {
    final bridge = _FakeBridge();
    final runner = PlatformMediaJobRunner(
      bridge,
      cancelGrace: const Duration(milliseconds: 20),
    );
    final request = plan(ConvertTargets.mp3);
    final events = collect(runner.start(request));
    await pumpEventQueue();
    final id = bridge.started.single['id']! as String;
    File(request.temp!).writeAsBytesSync(<int>[1]);
    runner.cancel('c1');
    expect(((await events).last as JobFailed).code, JobCodes.cancelled);
    await pumpEventQueue();
    expect(bridge.cancelled, <String>[id]);
    expect(File(request.temp!).existsSync(), isFalse);
    // Система успела дописать ещё — уборка через cancelGrace.
    File(request.temp!).writeAsBytesSync(<int>[2]);
    bridge.send(<Object?, Object?>{'id': id, 'done': true});
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(File(request.temp!).existsSync(), isFalse);
    expect(File(request.target!).existsSync(), isFalse);
  });

  test('«Повторить» после отмены — новый id у системы', () async {
    final bridge = _FakeBridge();
    final runner = PlatformMediaJobRunner(
      bridge,
      cancelGrace: Duration.zero,
    );
    unawaited(collect(runner.start(plan(ConvertTargets.mp3))));
    await pumpEventQueue();
    runner.cancel('c1');
    unawaited(collect(runner.start(plan(ConvertTargets.mp3))));
    await pumpEventQueue();
    expect(bridge.started, hasLength(2));
    expect(bridge.started[0]['id'], isNot(bridge.started[1]['id']));
  });

  test(
      '«Повторить» сразу после отмены: поздняя уборка прежнего запуска '
      'не трогает файл нового', () async {
    final bridge = _FakeBridge();
    final runner = PlatformMediaJobRunner(
      bridge,
      cancelGrace: const Duration(milliseconds: 20),
    );
    final first = plan(ConvertTargets.mp3);
    unawaited(collect(runner.start(first)));
    await pumpEventQueue();
    runner.cancel('c1');
    final second = plan(ConvertTargets.mp3);
    expect(second.temp, isNot(first.temp));
    final events = collect(runner.start(second));
    await pumpEventQueue();
    final id = bridge.started.last['id'];
    File(second.temp!).writeAsBytesSync(<int>[7, 7]);
    // Прошла отсрочка уборки прежнего запуска.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(File(second.temp!).existsSync(), isTrue);
    bridge.send(<Object?, Object?>{'id': id, 'done': true});
    final done = (await events).last as JobDone;
    expect(File(done.outputs.single).readAsBytesSync(), <int>[7, 7]);
  });

  test('поток событий оборвался — failed, а не вечное ожидание', () async {
    final bridge = _FakeBridge();
    final runner = PlatformMediaJobRunner(bridge);
    final request = plan(ConvertTargets.mp3);
    final events = collect(runner.start(request));
    await pumpEventQueue();
    File(request.temp!).writeAsBytesSync(<int>[1]);
    await bridge.controller.close();
    expect(((await events).last as JobFailed).code, JobCodes.failed);
    expect(File(request.temp!).existsSync(), isFalse);
  });

  test('кадр: ход работы неизвестен с начала', () async {
    final bridge = _FakeBridge();
    final runner = PlatformMediaJobRunner(bridge);
    final events = collect(runner.start(plan(ConvertTargets.frameJpeg)));
    await pumpEventQueue();
    expect(bridge.started.single['jpegQuality'], 85);
    bridge.send(<Object?, Object?>{
      'id': bridge.started.single['id'],
      'error': 'noStream',
    });
    final first = (await events).first as JobProgress;
    expect(first.value, isNull);
  });

  group('что умеет система', () {
    test('ответ разбирается; лишнее и невозможное отбрасывается', () async {
      final bridge = _FakeBridge()
        ..caps = <Object?, Object?>{
          'targets': <Object?>[
            'mp3',
            'm4a',
            'wav',
            'mp4',
            'mov',
            'webm',
            'png',
            'flac',
            7,
            'frame-jpeg',
          ],
          'video1080': false,
          'api': 34,
        };
      final caps = await loadNativeMediaCaps(
        bridge,
        platform: JobPlatform.android,
      );
      expect(caps.targets, <String>{'mp3', 'm4a', 'wav', 'mp4', 'frame-jpeg'});
      expect(caps.video1080, isFalse);
    });

    test('нет ответа, пусто или ошибка — ничего системного', () async {
      expect(
        (await loadNativeMediaCaps(
          _FakeBridge(),
          platform: JobPlatform.android,
        ))
            .targets,
        isEmpty,
      );
      expect(
        (await loadNativeMediaCaps(
          _FakeBridge()..hang = true,
          platform: JobPlatform.android,
          timeout: const Duration(milliseconds: 10),
        ))
            .targets,
        isEmpty,
      );
      expect(
        nativeMediaCapsOf(
          <Object?, Object?>{'targets': 'mp3'},
          JobPlatform.macos,
        ).targets,
        isEmpty,
      );
    });

    test('на Mac MOV остаётся, WebM — нет', () {
      final caps = nativeMediaCapsOf(
        <Object?, Object?>{
          'targets': <Object?>['mov', 'webm', 'mp3'],
        },
        JobPlatform.macos,
      );
      expect(caps.targets, <String>{'mov', 'mp3'});
      expect(caps.video1080, isTrue);
    });
  });
}
