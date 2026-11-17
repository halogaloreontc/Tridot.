// Архиватор (ADR-024): создать ZIP из файлов и папок, посмотреть,
// распаковать — на временных папках. Исходники не меняются, опасные архивы
// не распаковываются, отмена не оставляет следов.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/downloads/safe_zip.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';
import 'package:local_assistant/core/jobs/job_placement.dart';
import 'package:local_assistant/core/jobs/job_runner.dart';
import 'package:local_assistant/core/skills/archiver/zip_ops.dart';
import 'package:path/path.dart' as p;

final class _Reporter implements JobReporter {
  final List<(double?, String?)> ticks = <(double?, String?)>[];

  @override
  void progress(double? value, String? stage) => ticks.add((value, stage));
}

String _hash(String path) =>
    sha256.convert(File(path).readAsBytesSync()).toString();

Uint8List _zip(Map<String, String> files) {
  final archive = Archive();
  for (final MapEntry(:key, :value) in files.entries) {
    archive.add(ArchiveFile.string(key, value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('zip_ops_test');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  File file(String name, String text) {
    final f = File(p.join(temp.path, name));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(text);
    return f;
  }

  JobDone run(String action, List<JobSource> sources, {String? out}) {
    final request = ZipOps.plan(
      cardId: 'j1_0',
      action: action,
      sources: sources,
      outputDir: out ?? temp.path,
    );
    return ZipOps.run(request, _Reporter());
  }

  Map<String, String> read(String zipPath) {
    final archive = ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync());
    return <String, String>{
      for (final entry in archive)
        if (entry.isFile) entry.name: String.fromCharCodes(entry.content),
    };
  }

  group('создать архив', () {
    test('один файл: «<имя>.zip» рядом, исходник не изменён', () {
      final source = file('отчёт.txt', 'hello');
      final before = _hash(source.path);
      final done = run(ExtensionForms.zip, <JobSource>[
        JobSource(source.path, 'отчёт.txt'),
      ]);
      expect(p.basename(done.outputs.single), 'отчёт.zip');
      expect(read(done.outputs.single), <String, String>{'отчёт.txt': 'hello'});
      expect(_hash(source.path), before);
      expect(
        File(JobPlacement.tempFile(done.outputs.single, 'j1_0')).existsSync(),
        isFalse,
      );
    });

    test('сжатие: без сжатия, обычное, сильное — читается одинаково', () {
      final text = List<String>.generate(4000, (int i) => 'line $i ').join();
      final source = file('много.txt', text);
      final sizes = <String, int>{};
      for (final level in <String>['store', 'normal', 'strong']) {
        final request = ZipOps.plan(
          cardId: 'j_$level',
          action: ExtensionForms.zip,
          sources: <JobSource>[JobSource(source.path, 'много.txt')],
          outputDir: p.join(temp.path, level),
          level: level,
        );
        expect(request.options, <String, String>{'level': level});
        Directory(request.outputDir).createSync(recursive: true);
        final done = ZipOps.run(request, _Reporter());
        expect(read(done.outputs.single), <String, String>{'много.txt': text});
        sizes[level] = File(done.outputs.single).lengthSync();
      }
      expect(sizes['store'], greaterThan(sizes['normal']!));
      expect(sizes['strong'], lessThanOrEqualTo(sizes['normal']!));
      // Без сжатия — метод «stored».
      final stored = ZipDecoder().decodeBytes(
        File(p.join(temp.path, 'store', 'много.zip')).readAsBytesSync(),
      );
      expect(stored.files.single.compression, CompressionType.none);
      // Неизвестное значение в задачу не попадает.
      expect(
        ZipOps.plan(
          cardId: 'x',
          action: ExtensionForms.zip,
          sources: <JobSource>[JobSource(source.path, 'много.txt')],
          outputDir: temp.path,
          level: '11',
        ).options,
        isEmpty,
      );
      expect(ExtensionForms.zipLevel('strong'), 9);
      expect(ExtensionForms.zipLevel('store'), 0);
      expect(ExtensionForms.zipLevel(null), 6);
    });

    test('несколько файлов — «Архив.zip», совпадение имени — «(2)»', () {
      final a = file('a.txt', 'a');
      final b = file('b.txt', 'b');
      final sources = <JobSource>[
        JobSource(a.path, 'a.txt'),
        JobSource(b.path, 'b.txt'),
      ];
      final first = run(ExtensionForms.zip, sources);
      expect(p.basename(first.outputs.single), 'Архив.zip');
      final second = run(ExtensionForms.zip, sources);
      expect(p.basename(second.outputs.single), 'Архив (2).zip');
    });

    test('папка целиком, ссылки не попадают', () {
      file('docs/x.txt', 'x');
      file('docs/sub/y.txt', 'y');
      final outside = file('secret.txt', 's');
      if (!Platform.isWindows) {
        Link(p.join(temp.path, 'docs', 'link.txt')).createSync(outside.path);
      }
      final out = Directory(p.join(temp.path, 'out'))..createSync();
      final done = run(
        ExtensionForms.zip,
        <JobSource>[
          JobSource(p.join(temp.path, 'docs'), 'docs', folder: true),
        ],
        out: out.path,
      );
      expect(p.basename(done.outputs.single), 'docs.zip');
      expect(read(done.outputs.single), <String, String>{
        'docs/sub/y.txt': 'y',
        'docs/x.txt': 'x',
      });
    });

    test('имя вложения, а не имя копии на диске', () {
      final copy = file('m_1-0.png', 'png');
      final done = run(ExtensionForms.zip, <JobSource>[
        JobSource(copy.path, 'кот.png'),
      ]);
      expect(read(done.outputs.single).keys, <String>['кот.png']);
      expect(p.basename(done.outputs.single), 'кот.zip');
    });

    test('исходника нет — «missing»', () {
      expect(
        () => run(ExtensionForms.zip, <JobSource>[
          JobSource(p.join(temp.path, 'нет.txt'), 'нет.txt'),
        ]),
        throwsA(isA<JobMissing>()),
      );
    });
  });

  group('посмотреть и распаковать', () {
    test('содержимое: строки и «ещё N»', () {
      final zip = File(p.join(temp.path, 'a.zip'))
        ..writeAsBytesSync(
          _zip(<String, String>{'a.txt': 'aaa', 'b/c.txt': 'c'}),
        );
      final done = run(ExtensionForms.list, <JobSource>[
        JobSource(zip.path, 'a.zip'),
      ]);
      expect(done.listing, contains('a.txt · 3 Б'));
      expect(done.listingMore, 0);
      expect(done.outputs, isEmpty);
    });

    test('распаковка в папку рядом с архивом, архив не изменён', () {
      final zip = File(p.join(temp.path, 'фото.zip'))
        ..writeAsBytesSync(_zip(<String, String>{'1.txt': 'one'}));
      final before = _hash(zip.path);
      final done = run(ExtensionForms.extract, <JobSource>[
        JobSource(zip.path, 'фото.zip'),
      ]);
      expect(p.basename(done.outputs.single), 'фото');
      expect(
        File(p.join(done.outputs.single, '1.txt')).readAsStringSync(),
        'one',
      );
      expect(_hash(zip.path), before);
      // Повтор — «фото (2)», временных папок не остаётся.
      final again = run(ExtensionForms.extract, <JobSource>[
        JobSource(zip.path, 'фото.zip'),
      ]);
      expect(p.basename(again.outputs.single), 'фото (2)');
      expect(
        temp.listSync().map((e) => p.basename(e.path)).where(
              (String n) => n.contains('.tmp-'),
            ),
        isEmpty,
      );
    });

    for (final (label, name, reason) in <(String, String, String)>[
      ('«../»', '../evil.txt', 'parent_segment'),
      ('абсолютный путь', '/abs.txt', 'absolute'),
      ('имя для Windows', 'con.txt', 'windows_name'),
    ]) {
      test('опасный архив ($label): ничего не записано рядом', () {
        final zip = File(p.join(temp.path, 'bad.zip'))
          ..writeAsBytesSync(_zip(<String, String>{name: 'x'}));
        final request = ZipOps.plan(
          cardId: 'j1_0',
          action: ExtensionForms.extract,
          sources: <JobSource>[JobSource(zip.path, 'bad.zip')],
          outputDir: temp.path,
        );
        expect(
          () => ZipOps.run(request, _Reporter()),
          throwsA(
            isA<UnsafeZipException>().having((e) => e.reason, 'reason', reason),
          ),
        );
        expect(JobCodes.of(UnsafeZipException(reason)), JobCodes.unsafe);
        expect(
          temp.listSync().map((e) => p.basename(e.path)),
          <String>['bad.zip'],
        );
      });
    }

    test('пределы: записи, размер — «limits»', () {
      final zip = File(p.join(temp.path, 'many.zip'))
        ..writeAsBytesSync(
          _zip(<String, String>{for (var i = 0; i < 5; i++) 'f$i.txt': 'x'}),
        );
      final request = ZipOps.plan(
        cardId: 'j1_0',
        action: ExtensionForms.extract,
        sources: <JobSource>[JobSource(zip.path, 'many.zip')],
        outputDir: temp.path,
        limits: const ZipLimits(
          maxEntries: 3,
          maxTotalBytes: 100,
          maxEntryBytes: 100,
        ),
      );
      Object? error;
      try {
        ZipOps.run(request, _Reporter());
      } on Object catch (e) {
        error = e;
      }
      expect(JobCodes.of(error!), JobCodes.limits);
      final big = File(p.join(temp.path, 'big.zip'))
        ..writeAsBytesSync(_zip(<String, String>{'a.txt': 'x' * 200}));
      final sized = ZipOps.plan(
        cardId: 'j1_1',
        action: ExtensionForms.extract,
        sources: <JobSource>[JobSource(big.path, 'big.zip')],
        outputDir: temp.path,
        limits: const ZipLimits(
          maxEntries: 3,
          maxTotalBytes: 100,
          maxEntryBytes: 1000,
        ),
      );
      try {
        ZipOps.run(sized, _Reporter());
      } on Object catch (e) {
        error = e;
      }
      expect(JobCodes.of(error), JobCodes.limits);
    });

    test('ZIP с паролем — «password», пароль не спрашивается', () {
      final archive = Archive()..add(ArchiveFile.string('a.txt', 'x'));
      final zip = File(p.join(temp.path, 'locked.zip'))
        ..writeAsBytesSync(ZipEncoder(password: 'x').encode(archive));
      Object? error;
      try {
        run(ExtensionForms.extract, <JobSource>[
          JobSource(zip.path, 'locked.zip'),
        ]);
      } on Object catch (e) {
        error = e;
      }
      expect(JobCodes.of(error!), JobCodes.password);
      expect(JobCodes.message(JobCodes.password), contains('пока не'));
    });
  });

  group('в изоляте', () {
    test('ход работы и итог приходят событиями', () async {
      final source = file('a.txt', 'a' * 1000);
      final runner = IsolateJobRunner(<String, JobWork>{
        ExtensionForms.archiver: ZipOps.run,
      });
      final request = ZipOps.plan(
        cardId: 'j2_0',
        action: ExtensionForms.zip,
        sources: <JobSource>[JobSource(source.path, 'a.txt')],
        outputDir: temp.path,
      );
      final events = await runner.start(request).toList();
      expect(events.last, isA<JobDone>());
      expect(events.whereType<JobProgress>(), isNotEmpty);
      expect(File(p.join(temp.path, 'a.zip')).existsSync(), isTrue);
    });

    test('отмена посреди работы: ни .part, ни результата, исходник цел',
        () async {
      final big = File(p.join(temp.path, 'big.bin'));
      final sink = big.openSync(mode: FileMode.write);
      final chunk = Uint8List(1 << 20);
      for (var i = 0; i < chunk.length; i++) {
        chunk[i] = (i * 7919) & 0xff;
      }
      for (var i = 0; i < 64; i++) {
        sink.writeFromSync(chunk);
      }
      sink.closeSync();
      final before = _hash(big.path);
      final runner = IsolateJobRunner(<String, JobWork>{
        ExtensionForms.archiver: ZipOps.run,
      });
      final request = ZipOps.plan(
        cardId: 'j3_0',
        action: ExtensionForms.zip,
        sources: <JobSource>[JobSource(big.path, 'big.bin')],
        outputDir: temp.path,
      );
      final events = <JobEvent>[];
      final done = Completer<void>();
      runner.start(request).listen(events.add, onDone: done.complete);
      // Ждём, пока изолят начнёт писать.
      final part = File(request.temp!);
      for (var i = 0; i < 200 && !part.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      runner.cancel('j3_0');
      await done.future;
      final last = events.last;
      if (last is JobFailed) {
        expect(last.code, JobCodes.cancelled);
        expect(part.existsSync(), isFalse);
        expect(File(request.target!).existsSync(), isFalse);
      } else {
        // Машина успела сжать всё раньше отмены — тоже честный итог.
        expect(last, isA<JobDone>());
      }
      expect(_hash(big.path), before);
    });
  });

  test('уникальные имена: файлы и папки', () {
    file('x.zip', '');
    expect(
      p.basename(JobPlacement.uniquePath(temp.path, 'x.zip')),
      'x (2).zip',
    );
    Directory(p.join(temp.path, 'd')).createSync();
    expect(
      p.basename(JobPlacement.uniquePath(temp.path, 'd', folder: true)),
      'd (2)',
    );
    expect(JobPlacement.safeName('a/b:c?.'), 'a_b_c_');
    expect(JobPlacement.safeName(' .. '), 'Архив');
  });

  group('имя результата и временные файлы', () {
    test('имя заняли, пока шла работа: чужой файл не заменён', () {
      final source = file('doc.txt', 'hello');
      final request = ZipOps.plan(
        cardId: 'j1_0',
        action: ExtensionForms.zip,
        sources: <JobSource>[JobSource(source.path, 'doc.txt')],
        outputDir: temp.path,
      );
      // Пользователь сохранил «doc.zip» после «Запустить».
      final user = file('doc.zip', 'USER DATA');
      final done = ZipOps.run(request, _Reporter());
      expect(user.readAsStringSync(), 'USER DATA');
      expect(p.basename(done.outputs.single), 'doc (2).zip');
      expect(read(done.outputs.single), <String, String>{'doc.txt': 'hello'});
    });

    test('две карточки с одним именем результата — разные временные файлы', () {
      final source = file('doc.txt', 'hello');
      JobRequest plan(String id) => ZipOps.plan(
            cardId: id,
            action: ExtensionForms.zip,
            sources: <JobSource>[JobSource(source.path, 'doc.txt')],
            outputDir: temp.path,
          );
      final a = plan('j1_0');
      final b = plan('j2_0');
      expect(a.target, b.target);
      expect(a.temp, isNot(b.temp));
      final first = ZipOps.run(a, _Reporter());
      final second = ZipOps.run(b, _Reporter());
      expect(first.outputs.single, isNot(second.outputs.single));
      expect(read(first.outputs.single), <String, String>{'doc.txt': 'hello'});
      expect(read(second.outputs.single), <String, String>{'doc.txt': 'hello'});
    });

    test('распаковка: папку заняли — следующее имя, чужая цела', () {
      final zip = File(p.join(temp.path, 'a.zip'))
        ..writeAsBytesSync(_zip(<String, String>{'x.txt': 'x'}));
      final request = ZipOps.plan(
        cardId: 'j1_0',
        action: ExtensionForms.extract,
        sources: <JobSource>[JobSource(zip.path, 'a.zip')],
        outputDir: temp.path,
      );
      final mine = file(p.join('a', 'мой.txt'), 'мой');
      final done = ZipOps.run(request, _Reporter());
      expect(mine.readAsStringSync(), 'мой');
      expect(p.basename(done.outputs.single), 'a (2)');
      expect(
        File(p.join(done.outputs.single, 'x.txt')).readAsStringSync(),
        'x',
      );
    });

    test('имя из вложения с «../» — в архиве только имя файла', () {
      final source = file('evil.txt', 'x');
      final done = run(ExtensionForms.zip, <JobSource>[
        JobSource(source.path, '../../evil.txt'),
        JobSource(source.path, '..\\..\\win.txt'),
        JobSource(source.path, '..'),
      ]);
      final names = read(done.outputs.single).keys.toSet();
      expect(names, <String>{'evil.txt', 'win.txt', 'Файл'});
      // Свой архив свой же просмотр принимает.
      expect(
        listZipSafely(done.outputs.single, ZipLimits.desktop),
        hasLength(3),
      );
    });
  });

  group('JobPlacement', () {
    test('временные пути карточки узнаются, чужие — нет', () {
      final dir = temp.path;
      expect(
        JobPlacement.isTempFor(
          JobPlacement.tempFile(p.join(dir, 'a.zip'), 'j1_0'),
          'j1_0',
        ),
        isTrue,
      );
      expect(
        JobPlacement.isTempFor(
          JobPlacement.tempFolder(dir, 'a', 'j1_0'),
          'j1_0',
        ),
        isTrue,
      );
      expect(
        JobPlacement.isTempFor(JobPlacement.downloadTemp(dir, 'j1_0'), 'j1_0'),
        isTrue,
      );
      for (final foreign in <String>[
        dir,
        p.join(dir, 'Pictures'),
        p.join(dir, 'a.zip.part'),
        JobPlacement.tempFile(p.join(dir, 'a.zip'), 'j2_0'),
        'relative/.a.zip.j1_0.part',
        p.join(dir, '..', '.a.zip.j1_0.part', '..'),
      ]) {
        expect(
          JobPlacement.isTempFor(foreign, 'j1_0'),
          isFalse,
          reason: foreign,
        );
      }
    });

    test('имя файла: без пути, «..» и запрещённых знаков', () {
      expect(JobPlacement.fileName('../../a.txt'), 'a.txt');
      expect(JobPlacement.fileName('C:\\x\\b.txt'), 'b.txt');
      expect(JobPlacement.fileName('..'), 'Файл');
      expect(JobPlacement.fileName('a:b?.txt'), 'a_b_.txt');
    });
  });
}
