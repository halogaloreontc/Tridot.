// Предустановки качества у Kotlin (android/.../media/Presets.kt) и Swift
// (macos/Runner/MediaChannel.swift, MediaPresets) — те же числа, что
// ConvertQuality в Dart (ADR-026): файлы читаются как текст и сверяются.
// Поменяли таблицу в одном месте — тест напомнит про остальные.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/skills/converter/convert_quality.dart';

const String _kotlin =
    'android/app/src/main/kotlin/com/example/local_assistant/media/Presets.kt';
const String _swift = 'macos/Runner/MediaChannel.swift';

List<int> _numbers(String list) =>
    list.split(',').map((String s) => int.parse(s.trim())).toList();

/// Числа из `intArrayOf(…)` после [name] в [text].
List<int> _kotlinInts(String text, String name) {
  final match = RegExp('$name = intArrayOf\\(([^)]*)\\)').firstMatch(text);
  expect(match, isNotNull, reason: name);
  return _numbers(match!.group(1)!);
}

/// Числа из `static let name = [...]` в [text].
List<int> _swiftInts(String text, String name) {
  final match = RegExp('static let $name = \\[([0-9, ]*)\\]').firstMatch(text);
  expect(match, isNotNull, reason: name);
  return _numbers(match!.group(1)!);
}

void main() {
  final kotlin = File(_kotlin).readAsStringSync();
  final swift = File(_swift).readAsStringSync();

  List<int> values(QualityField field) =>
      field.values.map(((String, String) v) => int.parse(v.$1)).toList();

  List<int> videoRow(String res) => <int>[
        for (final q in <String>['high', 'mid', 'eco'])
          ConvertQuality.videoKbps(res, q),
      ];

  final videoAudio = <int>[
    for (final q in <String>['high', 'mid', 'eco'])
      ConvertQuality.videoAudioKbps(q),
  ];

  group('Kotlin', () {
    test('битрейт звука и качество JPEG', () {
      expect(_kotlinInts(kotlin, 'AUDIO_KBPS'), values(ConvertQuality.audio));
      expect(
        kotlin,
        contains('AUDIO_KBPS_DEFAULT = ${ConvertQuality.audio.defaultValue}'),
      );
      expect(_kotlinInts(kotlin, 'JPEG_QUALITY'), values(ConvertQuality.jpeg));
      expect(
        kotlin,
        contains('JPEG_QUALITY_DEFAULT = ${ConvertQuality.jpeg.defaultValue}'),
      );
    });

    test('битрейт видео по размеру и качеству', () {
      for (final (res, _) in ConvertQuality.resolution.values) {
        final row = RegExp('"$res" to intArrayOf\\(([^)]*)\\)')
            .firstMatch(kotlin)!
            .group(1)!;
        expect(_numbers(row), videoRow(res), reason: res);
      }
      expect(_kotlinInts(kotlin, 'VIDEO_AUDIO_KBPS'), videoAudio);
    });

    test('длинная сторона кадра', () {
      for (final res in <String>['1080', '720', '480']) {
        expect(
          kotlin,
          contains('"$res" to ${ConvertQuality.longSide(res)}'),
          reason: res,
        );
      }
    });

    test('качество видео — те же коды', () {
      expect(
        kotlin,
        contains('VIDEO_QUALITY = arrayOf("high", "mid", "eco")'),
      );
      expect(
        ConvertQuality.video.values.map(((String, String) v) => v.$1),
        <String>['high', 'mid', 'eco'],
      );
    });
  });

  group('Swift (macOS)', () {
    test('битрейт звука и качество JPEG', () {
      expect(_swiftInts(swift, 'audioKbps'), values(ConvertQuality.audio));
      expect(
        swift,
        contains(
          'static let audioKbpsDefault = ${ConvertQuality.audio.defaultValue}',
        ),
      );
      expect(_swiftInts(swift, 'jpegQuality'), values(ConvertQuality.jpeg));
      expect(
        swift,
        contains(
          'static let jpegQualityDefault = '
          '${ConvertQuality.jpeg.defaultValue}',
        ),
      );
    });

    test('битрейт видео по размеру и качеству', () {
      for (final (res, _) in ConvertQuality.resolution.values) {
        final row = RegExp('"$res": \\[([0-9, ]*)\\]').firstMatch(swift);
        expect(row, isNotNull, reason: res);
        expect(_numbers(row!.group(1)!), videoRow(res), reason: res);
      }
      expect(_swiftInts(swift, 'videoAudioKbps'), videoAudio);
    });

    test('длинная сторона кадра', () {
      for (final res in <String>['1080', '720', '480']) {
        expect(
          swift,
          contains('"$res": ${ConvertQuality.longSide(res)}'),
          reason: res,
        );
      }
    });

    test('качество видео и коэффициенты «как в исходнике» — как у Kotlin', () {
      expect(
        swift,
        contains('static let videoQuality = ["high", "mid", "eco"]'),
      );
      final kotlinFactor = RegExp(r'PIXEL_FACTOR = doubleArrayOf\(([^)]*)\)')
          .firstMatch(kotlin)!
          .group(1)!;
      final swiftFactor = RegExp(r'static let pixelFactor = \[([^\]]*)\]')
          .firstMatch(swift)!
          .group(1)!;
      List<double> doubles(String s) =>
          s.split(',').map((String v) => double.parse(v.trim())).toList();
      expect(doubles(swiftFactor), doubles(kotlinFactor));
      // Порог и потолок битрейта «как в исходнике» — те же.
      expect(kotlin, contains('coerceIn(300_000.0, cap)'));
      expect(swift, contains('max(byPixels, 300_000)'));
    });
  });
}
