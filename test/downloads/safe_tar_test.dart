// Распаковка tar.xz для ffmpeg на Linux (ADR-024, шаг 2): те же проверки,
// что у ZIP, — `..`, абсолютные пути, ссылки, пределы — до первого байта;
// только нужные записи; временный .tar удаляется.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/downloads/safe_tar.dart';
import 'package:local_assistant/core/downloads/safe_zip.dart';
import 'package:path/path.dart' as p;

const ZipLimits _limits = ZipLimits(
  maxEntries: 20,
  maxTotalBytes: 1024 * 1024,
  maxEntryBytes: 512 * 1024,
);

ArchiveFile _file(String name, String text) {
  final bytes = Uint8List.fromList(utf8.encode(text));
  return ArchiveFile.bytes(name, bytes)..mode = 0x81a4;
}

Matcher _unsafe(String reason) => throwsA(
      isA<UnsafeZipException>().having((e) => e.reason, 'reason', reason),
    );

void main() {
  late Directory temp;
  late String dest;
  late String scratch;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('safe_tar');
    dest = p.join(temp.path, 'out');
    scratch = p.join(temp.path, 'tmp.tar');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  String tarXz(Archive archive) {
    final tar = TarEncoder().encodeBytes(archive);
    final path = p.join(temp.path, 'a.tar.xz');
    File(path).writeAsBytesSync(XZEncoder().encodeBytes(tar));
    return path;
  }

  String tarOnly(Archive archive) {
    final path = p.join(temp.path, 'a.tar');
    File(path).writeAsBytesSync(TarEncoder().encodeBytes(archive));
    return path;
  }

  test('только нужная запись; временный .tar удалён', () {
    final archive = Archive()
      ..add(ArchiveFile.directory('ff/bin/'))
      ..add(_file('ff/bin/ffmpeg', 'программа'))
      ..add(_file('ff/bin/ffplay', 'не нужна'))
      ..add(_file('ff/LICENSE.txt', 'LGPL'));
    extractTarXzSafelySync(
      tarXz(archive),
      dest,
      scratch,
      limits: _limits,
      onlyEntries: const <String>{'ff/bin/ffmpeg'},
    );
    expect(File(p.join(dest, 'ff/bin/ffmpeg')).readAsStringSync(), 'программа');
    expect(File(p.join(dest, 'ff/bin/ffplay')).existsSync(), isFalse);
    expect(File(scratch).existsSync(), isFalse);
  });

  test('`..` — отказ, вне папки ничего не пишется', () {
    final archive = Archive()
      ..add(_file('ok.txt', 'a'))
      ..add(_file('../evil.txt', 'b'));
    expect(
      () => extractTarSafelySync(tarOnly(archive), dest, limits: _limits),
      _unsafe('parent_segment'),
    );
    expect(File(p.join(temp.path, 'evil.txt')).existsSync(), isFalse);
    expect(Directory(dest).existsSync(), isFalse);
  });

  test('абсолютный путь — отказ', () {
    final archive = Archive()..add(_file('/etc/passwd', 'x'));
    expect(
      () => extractTarSafelySync(tarOnly(archive), dest, limits: _limits),
      _unsafe('absolute'),
    );
  });

  test('символическая ссылка — отказ', () {
    final archive = Archive()
      ..add(_file('a.txt', 'a'))
      ..add(ArchiveFile.symlink('link', '/etc'));
    expect(
      () => extractTarSafelySync(tarOnly(archive), dest, limits: _limits),
      _unsafe('link'),
    );
  });

  test('пределы: число записей и размер', () {
    final many = Archive();
    for (var i = 0; i < 25; i++) {
      many.add(_file('f$i.txt', 'x'));
    }
    expect(
      () => extractTarSafelySync(tarOnly(many), dest, limits: _limits),
      _unsafe('too_many_entries'),
    );
    final big = Archive()
      ..add(ArchiveFile.bytes('big.bin', Uint8List(600 * 1024)));
    expect(
      () => extractTarSafelySync(tarOnly(big), dest, limits: _limits),
      _unsafe('entry_too_large'),
    );
  });

  test('не tar.xz — corrupt, временный .tar удалён', () {
    final path = p.join(temp.path, 'bad.tar.xz');
    File(path).writeAsStringSync('это не архив');
    expect(
      () => extractTarXzSafelySync(path, dest, scratch, limits: _limits),
      _unsafe('corrupt'),
    );
    expect(File(scratch).existsSync(), isFalse);
  });

  test('проверка степени сжатия для tar не задаётся', () {
    expect(
      () => extractArchiveSafelySync(
        Archive(),
        dest,
        limits: ZipLimits.desktop,
      ),
      throwsArgumentError,
    );
  });

  test('в отдельном изоляте', () async {
    final archive = Archive()..add(_file('ff/bin/ffmpeg', 'x'));
    await extractTarXzSafely(
      tarXz(archive),
      dest,
      scratch,
      limits: _limits,
      onlyEntries: const <String>{'ff/bin/ffmpeg'},
    );
    expect(File(p.join(dest, 'ff/bin/ffmpeg')).existsSync(), isTrue);
  });
}
