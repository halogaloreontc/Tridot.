// JobCards: копия вложения из хранилища в памяти не выходит из временной
// папки задачи, выключенное расширение не запускается, копии от выбора
// файлов на телефоне остаются для «Повторить» после ошибки.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/files/file_opener.dart';
import 'package:local_assistant/app/jobs/job_cards.dart';
import 'package:local_assistant/app/jobs/job_hub.dart';
import 'package:local_assistant/app/jobs/job_picker.dart';
import 'package:local_assistant/core/chats/attachments.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';
import 'package:local_assistant/core/jobs/job_runner.dart';
import 'package:path/path.dart' as p;

final class _Runner implements JobRunner {
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
    jobs[cardId]
      ?..add(const JobFailed(JobCodes.cancelled))
      ..close();
  }
}

final class _Picker implements JobFilePicker {
  @override
  Future<List<JobFile>> files() async => const <JobFile>[];

  @override
  Future<JobFile?> folder() async => null;

  @override
  Future<String?> saveFile(String suggestedName, String initialDirectory) =>
      throw UnimplementedError();

  @override
  Future<String?> chooseFolder(String initialDirectory) =>
      throw UnimplementedError();
}

final class _Source implements AttachmentSource {
  _Source(this.bytes);

  final Uint8List bytes;

  @override
  String get name => 'a.txt';

  @override
  String? get mimeType => null;

  @override
  Future<int> length() async => bytes.length;

  @override
  Future<Uint8List> readAsBytes() async => bytes;

  @override
  Future<void> saveTo(String path) => File(path).writeAsBytes(bytes);
}

void main() {
  late Directory temp;
  late _Runner runner;
  late JobHub hub;
  late AttachmentStore store;
  final enabled = <String>{ExtensionForms.archiver};

  setUp(() {
    temp = Directory.systemTemp.createTempSync('job_cards');
    runner = _Runner();
    hub = JobHub(runner: runner, persist: (_) {});
    store = InMemoryAttachmentStore();
    enabled
      ..clear()
      ..add(ExtensionForms.archiver);
  });

  tearDown(() {
    hub.dispose();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  JobCards cards({JobPlatform platform = JobPlatform.linux}) => JobCards(
        hub: hub,
        platform: platform,
        picker: _Picker(),
        opener: FileOpener(platform: platform),
        attachments: () => store,
        tempRoot: () async => temp.path,
        isEnabled: enabled.contains,
      );

  ExtensionCard card(List<JobFile> files) => ExtensionCard(
        id: 'j1_0',
        extensionId: ExtensionForms.archiver,
        updatedAt: DateTime(2026),
        values: <String, Object?>{'files': files, 'action': ExtensionForms.zip},
      );

  test('вложение с именем «../../x» копируется внутрь временной папки',
      () async {
    final attachment = await store.import(
      'session:1',
      'm1',
      0,
      _Source(Uint8List.fromList(<int>[1, 2, 3])),
      name: 'a.txt',
      now: DateTime(2026),
    );
    final c = card(<JobFile>[
      JobFile(path: attachment.path, name: '../../evil.txt', attachment: true),
    ]);
    await cards().run('session:1', c);
    final request = runner.requests['j1_0']!;
    final copy = request.sources.single.path;
    final jobs = p.join(temp.path, JobCards.tempFolder, 'j1_0');
    expect(p.isWithin(jobs, copy), isTrue, reason: copy);
    expect(p.basename(copy), 'evil.txt');
    expect(File(copy).readAsBytesSync(), <int>[1, 2, 3]);
    expect(File(p.join(temp.path, 'evil.txt')).existsSync(), isFalse);
  });

  test('выключенное расширение: карточка не запускается', () async {
    final source = File(p.join(temp.path, 'a.txt'))..writeAsStringSync('x');
    final c = card(<JobFile>[JobFile(path: source.path, name: 'a.txt')]);
    enabled.clear();
    await cards().run('session:1', c);
    expect(runner.requests, isEmpty);
    expect(c.state, CardState.form);
    enabled.add(ExtensionForms.archiver);
    await cards().run('session:1', c);
    expect(runner.requests, contains('j1_0'));
  });

  test('телефон: копия от выбора файлов остаётся после ошибки для «Повторить»',
      () async {
    final picked = File(p.join(temp.path, 'uuid', 'a.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
    final c = card(<JobFile>[JobFile(path: picked.path, name: 'a.txt')]);
    final jobCards = cards(platform: JobPlatform.android);
    await jobCards.run('session:1', c);
    runner.jobs['j1_0']!.add(const JobFailed(JobCodes.disk));
    await pumpEventQueue();
    expect(c.state, CardState.failed);
    expect(picked.existsSync(), isTrue);
    hub.retry('session:1', c);
    await jobCards.run('session:2', c);
    runner.jobs['j1_0']!.add(const JobDone());
    await pumpEventQueue();
    expect(c.state, CardState.done);
    await pumpEventQueue();
    expect(picked.existsSync(), isFalse);
  });

  test('копии от выбора файлов старше суток удаляются при запуске', () async {
    final old = Directory(
      p.join(temp.path, '0f8fad5b-d9cb-469f-a165-70867728950e'),
    )..createSync();
    File(p.join(old.path, 'a.txt')).writeAsStringSync('x');
    final other = Directory(p.join(temp.path, 'tridot-jobs'))..createSync();
    await dropPickerLeftovers(
      temp,
      now: DateTime.now().add(const Duration(days: 2)),
    );
    expect(old.existsSync(), isFalse);
    expect(other.existsSync(), isTrue);
    final fresh = Directory(
      p.join(temp.path, '1f8fad5b-d9cb-469f-a165-70867728950e'),
    )..createSync();
    await dropPickerLeftovers(temp);
    expect(fresh.existsSync(), isTrue);
  });
}
