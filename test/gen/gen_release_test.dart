import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/gen/gen_release.dart';

const String _base =
    'https://github.com/halogaloreontc/Tridot./releases/download/gen-latest/';

String _json({
  String url = '${_base}tridot-gen-1.0.0.gguf.001',
  Object size = 2000000000,
  Object partSize = 2000000000,
  String sha = 'ab',
  Object? ram,
  bool twoParts = false,
}) =>
    jsonEncode(<String, Object?>{
      'format': 'tridot-gen-latest/1',
      'version': '1.0.0',
      'model': <String, Object?>{
        'size': size,
        'sha256': 'CD' * 32,
        'parts': <Object?>[
          <String, Object?>{
            'url': url,
            'size': partSize,
            'sha256': sha == 'ab' ? 'AB' * 32 : sha,
          },
          if (twoParts)
            <String, Object?>{
              'url': '${_base}tridot-gen-1.0.0.gguf.002',
              'size': 497000000,
              'sha256': 'ef' * 32,
            },
        ],
        if (ram != null) 'min_ram_mb': ram,
      },
    });

void main() {
  test('разбор: части, размеры, суммы, порог памяти по умолчанию', () {
    final r = GenRelease.parse(_json(size: 2497000000, twoParts: true));
    expect(r.version, '1.0.0');
    expect(r.size, 2497000000);
    expect(r.sha256, 'cd' * 32);
    expect(r.parts, hasLength(2));
    expect(r.parts.first.sha256, 'ab' * 32);
    expect(r.parts.last.url.path, endsWith('.gguf.002'));
    expect(r.minRamMb, GenRelease.defaultMinRamMb);
    expect(GenRelease.parse(_json(ram: 7500)).minRamMb, 7500);
  });

  test('чужой адрес, не GGUF, размер, сумма — отказ', () {
    for (final text in <String>[
      _json(url: 'https://example.com/m.gguf'),
      _json(url: '${_base}m.zip'),
      _json(url: '${_base}m.gguf'),
      _json(size: 2497000000),
      _json(partSize: 3000000000, size: 3000000000),
      _json(
        url:
            'https://github.com/halogaloreontc/Tridot./releases/download/../../m.gguf.001',
      ),
      _json(size: 5000000000, partSize: 5000000000),
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
