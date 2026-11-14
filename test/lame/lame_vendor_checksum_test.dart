// Исходники LAME в packages/tridot_lame/third_party (ADR-026) — те самые,
// что в архиве lame-3.100.tar.gz с закреплённой SHA-256: каждый файл
// сверяется со списком SHA256SUMS, лишних и пропавших нет.
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const String _root = 'packages/tridot_lame/third_party';
const String _lame = '$_root/lame-3.100';

Map<String, String> _sums() => <String, String>{
      for (final line in File('$_root/SHA256SUMS').readAsLinesSync())
        if (line.trim().isNotEmpty)
          line.substring(66).trim(): line.substring(0, 64),
    };

void main() {
  test('у каждого файла LAME своя сумма, и она совпадает', () {
    final sums = _sums();
    expect(sums, isNotEmpty);
    final files = <String>{
      for (final entity in Directory(_lame).listSync(recursive: true))
        if (entity is File)
          p.posix.joinAll(p.split(p.relative(entity.path, from: _lame))),
    };
    expect(files, sums.keys.toSet(), reason: 'лишние или пропавшие файлы');
    for (final MapEntry(key: name, value: sum) in sums.entries) {
      final actual =
          sha256.convert(File(p.join(_lame, name)).readAsBytesSync());
      expect(actual.toString(), sum, reason: name);
    }
  });

  test('список исходников хука совпадает с взятыми .c файлами', () {
    final hook =
        File('packages/tridot_lame/hook/build.dart').readAsStringSync();
    final listed = RegExp(r"^  '([A-Za-z0-9_]+)',$", multiLine: true)
        .allMatches(hook)
        .map((Match m) => m.group(1)!)
        .toSet();
    final vendored = <String>{
      for (final name in _sums().keys)
        if (name.startsWith('libmp3lame/') &&
            name.endsWith('.c') &&
            !name.contains('/vector/'))
          p.posix.basenameWithoutExtension(name),
    };
    expect(listed, vendored);
    expect(listed, hasLength(19));
  });

  test('SOURCE.md называет архив и его SHA-256', () {
    final source = File('$_root/SOURCE.md').readAsStringSync();
    expect(source, contains('lame-3.100.tar.gz'));
    expect(
      source,
      contains(
        'ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e',
      ),
    );
  });
}
