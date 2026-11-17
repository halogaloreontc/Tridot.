// IsolateJobRunner: отменённый изолят мог дописать временную папку после
// первой уборки (kill не мгновенный) — после его выхода уборка повторяется.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';
import 'package:local_assistant/core/jobs/job_runner.dart';
import 'package:path/path.dart' as p;

/// Работа, которая без остановки пишет во временную папку задачи.
JobDone _stubborn(JobRequest request, JobReporter reporter) {
  final temp = request.temp!;
  for (var i = 0; i < 2000; i++) {
    Directory(temp).createSync(recursive: true);
    File(p.join(temp, 'entry-$i')).writeAsStringSync('x');
    reporter.progress(i / 2000, 'Распаковка');
    sleep(const Duration(milliseconds: 2));
  }
  return const JobDone();
}

void main() {
  test('отмена: временная папка убрана и после выхода изолята', () async {
    final temp = Directory.systemTemp.createTempSync('isolate_runner');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final scratch = p.join(temp.path, '.a.tmp-j1_0');
    final runner = IsolateJobRunner(<String, JobWork>{
      ExtensionForms.archiver: _stubborn,
    });
    final events = <JobEvent>[];
    final done = runner
        .start(
          JobRequest(
            cardId: 'j1_0',
            extensionId: ExtensionForms.archiver,
            action: ExtensionForms.extract,
            sources: const <JobSource>[],
            outputDir: temp.path,
            temp: scratch,
          ),
        )
        .listen(events.add)
        .asFuture<void>();
    for (var i = 0; i < 200 && !Directory(scratch).existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(Directory(scratch).existsSync(), isTrue);
    runner.cancel('j1_0');
    await done;
    expect((events.last as JobFailed).code, JobCodes.cancelled);
    // Выход изолята доходит чуть позже итога.
    for (var i = 0; i < 100 && Directory(scratch).existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(Directory(scratch).existsSync(), isFalse);
  });
}
