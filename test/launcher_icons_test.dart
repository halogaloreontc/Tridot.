import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/personas/persona_palette.dart';

/// Ширина и высота PNG из заголовка IHDR.
(int, int) _pngSize(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  // Подпись PNG (8 байт), длина и тип блока IHDR (8 байт).
  expect(bytes.sublist(12, 16), 'IHDR'.codeUnits);
  return (data.getUint32(16), data.getUint32(20));
}

/// Размеры картинок внутри ICO.
List<int> _icoSizes(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  expect(data.getUint16(0, Endian.little), 0);
  expect(data.getUint16(2, Endian.little), 1);
  final count = data.getUint16(4, Endian.little);
  return <int>[
    for (var i = 0; i < count; i++)
      // 0 в каталоге ICO означает 256.
      switch (bytes[6 + 16 * i]) {
        0 => 256,
        final int w => w
      },
  ]..sort();
}

const Map<String, int> _android = <String, int>{
  'mdpi': 48,
  'hdpi': 72,
  'xhdpi': 96,
  'xxhdpi': 144,
  'xxxhdpi': 192,
};

/// Знак Tridot на иконках запуска: три точки цветами помощников на сетке
/// 24, как `RelayGlyphPainter`, растянутой на 80 % плитки (ADR-016).
void main() {
  test('Android: ic_launcher нужных размеров', () {
    for (final MapEntry(:key, :value) in _android.entries) {
      final bytes = File('android/app/src/main/res/mipmap-$key/ic_launcher.png')
          .readAsBytesSync();
      expect(_pngSize(bytes), (value, value), reason: key);
    }
  });

  test('macOS: AppIcon нужных размеров', () {
    for (final size in <int>[16, 32, 64, 128, 256, 512, 1024]) {
      final bytes = File(
        'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$size.png',
      ).readAsBytesSync();
      expect(_pngSize(bytes), (size, size), reason: '$size');
    }
  });

  test('Windows: app_icon.ico — 16, 32, 48 и 256', () {
    final bytes =
        File('windows/runner/resources/app_icon.ico').readAsBytesSync();
    expect(_icoSizes(bytes), <int>[16, 32, 48, 256]);
  });

  testWidgets('в центрах точек — цвета Связной, Лиорио и Ноды', (tester) async {
    Future<void> check(String path, double inset) async {
      final bytes = File(path).readAsBytesSync();
      final pixels = await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        final data = await frame.image.toByteData();
        final size = frame.image.width;
        frame.image.dispose();
        return (data!, size);
      });
      final (data, size) = pixels!;
      final side = size - 2 * inset;
      final k = side * 0.8 / 24;
      final origin = inset + side * 0.1;
      const colors = <int>[
        PersonaPalette.sado,
        PersonaPalette.liorio,
        PersonaPalette.noda,
      ];
      for (final (i, color) in colors.indexed) {
        final x = (origin + (5 + 7 * i) * k).floor();
        final y = (origin + 12 * k).floor();
        final rgba = data.getUint32((y * size + x) * 4);
        final argb = (rgba & 0xFF) << 24 | rgba >> 8;
        expect(
          argb.toRadixString(16),
          color.toRadixString(16),
          reason: '$path, точка $i',
        );
      }
    }

    await check(
      'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png',
      0,
    );
    await check(
      'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png',
      100,
    );
  });
}
