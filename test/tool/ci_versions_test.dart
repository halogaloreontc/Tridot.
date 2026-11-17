// Один Flutter и одна система везде (ADR-036): CI проверяет той версией,
// которой собирается выпуск веб-помощника и которая названа в README.
// Новый Flutter — правкой всех трёх мест сразу.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

List<String> _flutterVersions(String workflow) => RegExp(
      r'^\s+flutter-version:\s*(.+?)\s*$',
      multiLine: true,
    ).allMatches(workflow).map((Match m) => m.group(1)!).toList();

Iterable<String> _workflows() => Directory('.github/workflows')
    .listSync()
    .whereType<File>()
    .map((File f) => f.path)
    .where((String p) => p.endsWith('.yml') || p.endsWith('.yaml'));

void main() {
  test('Flutter в CI, в выпуске и в README — одна версия', () {
    final ci = _read('.github/workflows/ci.yml');
    final pinned = RegExp(
      r'^  FLUTTER_VERSION:\s*(\d+\.\d+\.\d+)\s*$',
      multiLine: true,
    ).firstMatch(ci);
    expect(pinned, isNotNull, reason: 'env.FLUTTER_VERSION в ci.yml');
    final version = pinned!.group(1)!;
    // Обе задачи CI (verify, android) берут версию из env, а не свою.
    expect(_flutterVersions(ci), <String>[
      r'${{ env.FLUTTER_VERSION }}',
      r'${{ env.FLUTTER_VERSION }}',
    ]);
    expect(
      _flutterVersions(_read('.github/workflows/web-assistant-release.yml')),
      <String>[version],
    );
    expect(_read('README.md'), contains('Flutter $version'));
  });

  test('в каждом workflow Flutter и система закреплены', () {
    final paths = _workflows().toList();
    expect(paths, isNotEmpty);
    for (final path in paths) {
      final text = _read(path);
      expect(
        _flutterVersions(text),
        hasLength('subosito/flutter-action@'.allMatches(text).length),
        reason: '$path: у каждой установки Flutter своя flutter-version',
      );
      expect(text, isNot(contains('ubuntu-latest')), reason: path);
    }
  });
}
