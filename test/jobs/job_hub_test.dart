// JobHub: состояние карточки по событиям задачи, сохранение только при
// смене состояния, отмена с уборкой, уборка после перезапуска.
import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/jobs/job_hub.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';
import 'package:local_assistant/core/jobs/job_runner.dart';
import 'package:path/path.dart' as p;

final class FakeJobRunner implements JobRunner {
  final Map<String, StreamController<JobEvent>> jobs =
      <String, StreamController<JobEvent>>{};
  final Map<String, JobRequest> requests = <String, JobRequest>{};

  @override
  Stream<JobEvent> start(JobRequest request) {
    final controller = StreamController<JobEvent>();
    jobs[request.cardId] = controller;
    requests[request.cardId] = request;
    return controller.stream;
  }

  @override
  void cancel(String cardId) {
    final request = requests[cardId];
    for (final path in request?.cleanup ?? const <String>[]) {
      IsolateJobRunner.removeQuietly(path);
    }
    jobs[cardId]
      ?..add(const JobFailed(JobCodes.cancelled))
      ..close();
  }
}

ExtensionCard _card() => ExtensionCard(
      id: 'j1_0',
      extensionId: ExtensionForms.archiver,
      updatedAt: DateTime(2026),
      values: <String, Object?>{'action': ExtensionForms.zip},
    );

void main() {
  late Directory temp;
  late FakeJobRunner runner;
  late List<String> saved;
  late JobHub hub;
  var now = DateTime(2026, 11, 14, 10);

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('job_hub_test');
    runner = FakeJobRunner();
    saved = <String>[];
    now = DateTime(2026, 11, 14, 10);
    hub = JobHub(runner: runner, persist: saved.add, now: () => now);
  });

  tearDown(() async {
    hub.dispose();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  JobRequest request(String part) => JobRequest(
        cardId: 'j1_0',
        extensionId: ExtensionForms.archiver,
        action: ExtensionForms.zip,
        sources: const <JobSource>[],
        outputDir: temp.path,
        target: p.join(temp.path, 'a.zip'),
        temp: part,
      );

  test('форма → идёт → готово; сохранение только при смене состояния',
      () async {
    final card = _card();
    final finished = <CardState>[];
    hub.start(
      'session:1',
      card,
      request(p.join(temp.path, 'a.zip.part')),
      onFinished: (ExtensionCard c) => finished.add(c.state),
    );
    expect(card.state, CardState.running);
    expect(card.cleanup, isNotEmpty);
    expect(saved, <String>['session:1']);
    expect(hub.isRunning('j1_0'), isTrue);
    final job = runner.jobs['j1_0']!;
    for (var i = 1; i <= 5; i++) {
      job.add(JobProgress(i / 10, 'Сжатие'));
    }
    await pumpEventQueue();
    // Ход работы — только в памяти, не чаще 10 раз в секунду.
    expect(saved, hasLength(1));
    expect(hub.progressOf('j1_0').value?.value, 0.1);
    now = now.add(const Duration(milliseconds: 150));
    job.add(const JobProgress(0.6, 'Сжатие'));
    await pumpEventQueue();
    expect(hub.progressOf('j1_0').value?.value, 0.6);
    job.add(
      JobDone(
        outputs: <String>[p.join(temp.path, 'a.zip')],
        outputDir: temp.path,
      ),
    );
    await pumpEventQueue();
    expect(card.state, CardState.done);
    expect(card.outputs.single, endsWith('a.zip'));
    expect(card.cleanup, isEmpty);
    expect(saved, hasLength(2));
    expect(finished, <CardState>[CardState.done]);
    expect(hub.isRunning('j1_0'), isFalse);
  });

  test('ошибка — код и «Повторить» возвращает форму', () async {
    final card = _card();
    hub.start('session:1', card, request(p.join(temp.path, 'a.zip.part')));
    runner.jobs['j1_0']!.add(const JobFailed(JobCodes.disk));
    await pumpEventQueue();
    expect(card.state, CardState.failed);
    expect(card.errorCode, JobCodes.disk);
    hub.retry('session:1', card);
    expect(card.state, CardState.form);
    expect(card.errorCode, isNull);
    expect(card.choice('action'), ExtensionForms.zip);
  });

  test('отмена: «Отменено», временный файл удалён', () async {
    final part = File(p.join(temp.path, 'a.zip.part'))..writeAsStringSync('x');
    final card = _card();
    hub.start('session:1', card, request(part.path));
    hub.cancel('j1_0');
    await pumpEventQueue();
    expect(card.state, CardState.cancelled);
    expect(card.errorCode, isNull);
    expect(part.existsSync(), isFalse);
  });

  test('после перезапуска: «Прервано», временные пути убраны один раз', () {
    final part = File(p.join(temp.path, '.a.zip.j1_0.part'))
      ..writeAsStringSync('x');
    final dir = Directory(p.join(temp.path, '.a.tmp-j1_0'))..createSync();
    File(p.join(dir.path, 'x')).writeAsStringSync('x');
    final restored = ExtensionCard.fromJson(
      (_card()
            ..state = CardState.running
            ..cleanup = <String>[part.path, dir.path])
          .toJson(),
    )!;
    expect(restored.state, CardState.interrupted);
    expect(hub.sweepInterrupted('session:1', restored), isTrue);
    expect(part.existsSync(), isFalse);
    expect(dir.existsSync(), isFalse);
    expect(restored.cleanup, isEmpty);
    expect(hub.sweepInterrupted('session:1', restored), isFalse);
  });

  test('уборка не трогает чужие пути из файла чата', () {
    // Чужой или изменённый файл чата: «шла задача», а в уборке — папка
    // пользователя и чужой временный файл другой карточки.
    final pictures = Directory(p.join(temp.path, 'Pictures'))..createSync();
    File(p.join(pictures.path, 'фото.jpg')).writeAsStringSync('x');
    final other = File(p.join(temp.path, '.a.zip.j9_9.part'))
      ..writeAsStringSync('x');
    final mine = File(p.join(temp.path, '.a.zip.j1_0.part'))
      ..writeAsStringSync('x');
    final card = _card()
      ..state = CardState.interrupted
      ..cleanup = <String>[pictures.path, other.path, mine.path];
    hub.sweepInterrupted('session:1', card);
    expect(pictures.existsSync(), isTrue);
    expect(other.existsSync(), isTrue);
    expect(mine.existsSync(), isFalse);
    final restored = ExtensionCard.fromJson(
      (_card()
            ..state = CardState.running
            ..cleanup = <String>[pictures.path, other.path])
          .toJson(),
    )!;
    expect(restored.cleanup, isEmpty);
  });

  test('удаление чата отменяет его задачи, другие идут дальше', () async {
    final card = _card();
    final other = ExtensionCard(
      id: 'j2_0',
      extensionId: ExtensionForms.archiver,
      updatedAt: now,
    );
    hub.start('session:1', card, request(p.join(temp.path, '.a.j1_0.part')));
    hub.start(
      'session:2',
      other,
      JobRequest(
        cardId: 'j2_0',
        extensionId: ExtensionForms.archiver,
        action: ExtensionForms.zip,
        sources: const <JobSource>[],
        outputDir: temp.path,
      ),
    );
    hub.cancelChat('session:1');
    await pumpEventQueue();
    expect(card.state, CardState.cancelled);
    expect(other.state, CardState.running);
    hub.cancelAll();
    await pumpEventQueue();
    expect(other.state, CardState.cancelled);
  });

  test('поле-ссылка: чат сохраняется не на каждую букву', () {
    fakeAsync((FakeAsync async) {
      final card = _card();
      var notified = 0;
      hub.addListener(() => notified++);
      for (final text in <String>['h', 'ht', 'htt', 'http']) {
        card.setValue('url', text);
        hub.editedLater('session:1', card);
        async.elapse(const Duration(milliseconds: 100));
      }
      expect(saved, isEmpty);
      expect(notified, 0);
      async.elapse(JobHub.editDelay);
      expect(saved, <String>['session:1']);
    });
  });
}
