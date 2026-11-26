import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/gen/gen_release.dart';

String _json({
  String url =
      'https://github.com/halogaloreontc/Tridot./releases/download/gen-latest/tridot-gen-1.0.0.gguf',
  Object size = 2497000000,
  String sha = 'ab',
  Object? ram,
}) =>
    jsonEncode(<String, Object?>{
      'format': 'tridot-gen-latest/1',
      'version': '1.0.0',
      'model': <String, Object?>{
        'url': url,
        'size': size,
        'sha256': sha == 'ab' ? 'AB' * 32 : sha,
        if (ram != null) 'min_ram_mb': ram,
      },
    });

void main() {
  test('разбор: адрес, размер, sha256, порог памяти по умолчанию', () {
    final r = GenRelease.parse(_json());
    expect(r.version, '1.0.0');
    expect(r.size, 2497000000);
    expect(r.sha256, 'ab' * 32);
    expect(r.minRamMb, GenRelease.defaultMinRamMb);
    expect(GenRelease.parse(_json(ram: 7500)).minRamMb, 7500);
  });

  test('чужой адрес, не GGUF, размер, сумма — отказ', () {
    for (final text in <String>[
      _json(url: 'https://example.com/m.gguf'),
      _json(
        url:
            'https://github.com/halogaloreontc/Tridot./releases/download/gen-latest/m.zip',
      ),
      _json(
        url:
            'https://github.com/halogaloreontc/Tridot./releases/download/../../m.gguf',
      ),
      _json(size: 5000000000),
      _json(size: '1'),
      _json(sha: 'xyz'),
      '{"format":"tridot-intent-latest/1"}',
      'не json',
    ]) {
      expect(
        () => GenRelease.parse(text),
        throwsA(isA<GenReleaseException>()),
        reason: text,
      );
    }
  });
}
