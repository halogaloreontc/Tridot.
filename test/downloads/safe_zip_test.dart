import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/downloads/safe_zip.dart';
import 'package:path/path.dart' as p;

const ZipLimits _limits = ZipLimits(
  maxEntries: 64,
  maxTotalBytes: 4096,
  maxEntryBytes: 2048,
);

Uint8List _zip(List<ArchiveFile> files) {
  final archive = Archive();
  files.forEach(archive.add);
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// Заменяет в байтах архива имя [from] на [to] той же длины: так
/// получаются записи, которые `ZipEncoder` сам не создаст.
Uint8List _rename(Uint8List bytes, String from, String to) {
  assert(from.length == to.length);
  final out = Uint8List.fromList(bytes);
  final a = from.codeUnits;
  for (var i = 0; i + a.length <= out.length; i++) {
    var match = true;
    for (var j = 0; j < a.length && match; j++) {
      match = out[i + j] == a[j];
    }
    if (match) out.setRange(i, i + a.length, to.codeUnits);
  }
  return out;
}

ArchiveFile _text(String name, String text) => ArchiveFile.string(name, text);

void main() {
  late Directory temp;
  late Directory dest;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('safe_zip_test');
    dest = Directory(p.join(temp.path, 'out'));
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<File> write(List<int> bytes) async {
    final file = File(p.join(temp.path, 'a.zip'));
    await file.writeAsBytes(bytes);
    return file;
  }

  /// Всё, что есть в temp, кроме самого архива и [dest].
  List<String> outside() => temp
      .listSync(recursive: true)
      .map((e) => p.relative(e.path, from: temp.path))
      .where((path) => path != 'a.zip' && !p.isWithin('out', path))
      .where((path) => path != 'out')
      .toList();

  Future<void> expectRejected(
    List<int> bytes,
    String reason, {
    String? stripRoot,
  }) async {
    final zip = await write(bytes);
    await expectLater(
      extractZipSafely(zip, dest, limits: _limits, stripRoot: stripRoot),
      throwsA(
        isA<UnsafeZipException>().having((e) => e.reason, 'reason', reason),
      ),
    );
    expect(outside(), isEmpty);
  }

  test('обычный архив распаковывается, корневая папка срезается', () async {
    final zip = await write(
      _zip(<ArchiveFile>[
        ArchiveFile.directory('model/'),
        ArchiveFile.directory('model/am/'),
        _text('model/am/final.mdl', 'данные'),
        _text('model/conf/model.conf', 'conf'),
      ]),
    );
    await extractZipSafely(zip, dest, limits: _limits, stripRoot: 'model');
    expect(
      File(p.join(dest.path, 'am', 'final.mdl')).readAsStringSync(),
      'данные',
    );
    expect(
      File(p.join(dest.path, 'conf', 'model.conf')).readAsStringSync(),
      'conf',
    );
    expect(Directory(p.join(dest.path, 'model')).existsSync(), isFalse);
  });

  test('ошибка диска — FileSystemException, а не «испорченный архив»',
      () async {
    final zip = await write(
      _zip(<ArchiveFile>[_text('model/am/final.mdl', 'данные')]),
    );
    // На месте папки назначения — файл: записать некуда, как без места.
    File(dest.path).writeAsStringSync('занято');
    await expectLater(
      extractZipSafely(zip, dest, limits: _limits, stripRoot: 'model'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('без stripRoot пути сохраняются как есть', () async {
    final zip = await write(_zip(<ArchiveFile>[_text('a/b.txt', 'x')]));
    await extractZipSafely(zip, dest, limits: _limits);
    expect(File(p.join(dest.path, 'a', 'b.txt')).existsSync(), isTrue);
  });

  test('«..» в пути — отказ', () async {
    await expectRejected(
      _zip(<ArchiveFile>[_text('ok.txt', 'x'), _text('../evil.txt', 'x')]),
      'parent_segment',
    );
    await expectRejected(
      _zip(<ArchiveFile>[_text('model/../../evil.txt', 'x')]),
      'parent_segment',
    );
  });

  test('абсолютный путь — отказ', () async {
    await expectRejected(
      _zip(<ArchiveFile>[_text('/tmp/evil.txt', 'x')]),
      'absolute',
    );
  });

  test('буква диска — отказ', () async {
    await expectRejected(
      _zip(<ArchiveFile>[_text('C:/evil.txt', 'x')]),
      'drive_letter',
    );
  });

  test('обратная косая черта — отказ', () async {
    await expectRejected(
      _rename(_zip(<ArchiveFile>[_text('a_b.txt', 'x')]), 'a_b', r'a\b'),
      'backslash',
    );
  });

  test('символическая ссылка — отказ', () async {
    await expectRejected(
      _zip(<ArchiveFile>[
        _text('a.txt', 'x'),
        ArchiveFile.symlink('link', '/etc/passwd'),
      ]),
      'link',
    );
  });

  test('больше записей, чем можно, — отказ', () async {
    await expectRejected(
      _zip(<ArchiveFile>[
        for (var i = 0; i < 65; i++) _text('f$i.txt', 'x'),
      ]),
      'too_many_entries',
    );
  });

  test('слишком большой файл — отказ', () async {
    await expectRejected(
      _zip(<ArchiveFile>[_text('big.bin', 'x' * 3000)]),
      'entry_too_large',
    );
  });

  test('сумма размеров больше предела — отказ', () async {
    await expectRejected(
      _zip(<ArchiveFile>[
        _text('a.bin', 'x' * 2000),
        _text('b.bin', 'x' * 2000),
        _text('c.bin', 'x' * 200),
      ]),
      'total_too_large',
    );
    expect(dest.existsSync(), isFalse);
  });

  test('запись вне stripRoot — отказ', () async {
    await expectRejected(
      _zip(<ArchiveFile>[
        _text('model/a.txt', 'x'),
        _text('other/b.txt', 'x'),
      ]),
      'outside_root',
      stripRoot: 'model',
    );
    expect(dest.existsSync(), isFalse);
  });

  test('повтор имени — отказ', () async {
    await expectRejected(
      _rename(
        _zip(<ArchiveFile>[_text('a.txt', 'x'), _text('b.txt', 'y')]),
        'b.txt',
        'a.txt',
      ),
      'duplicate',
    );
  });

  test('заголовок преуменьшает размер — отказ при записи', () async {
    final bytes = _zip(<ArchiveFile>[
      ArchiveFile.noCompress('a.bin', 100, Uint8List(100)),
    ]);
    // Размер «без сжатия» в локальном заголовке (смещение 22) и в
    // центральном каталоге (смещение 24) — 10 вместо 100.
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i + 4 <= bytes.length; i++) {
      final signature = data.getUint32(i, Endian.little);
      if (signature == 0x04034b50) {
        data.setUint32(i + 22, 10, Endian.little);
      } else if (signature == 0x02014b50) {
        data.setUint32(i + 24, 10, Endian.little);
      }
    }
    final zip = await write(bytes);
    await expectLater(
      extractZipSafely(zip, dest, limits: _limits),
      throwsA(isA<UnsafeZipException>()),
    );
    expect(outside(), isEmpty);
  });

  test('не zip — отказ', () async {
    await expectRejected(List<int>.filled(200, 7), 'corrupt');
  });
}
