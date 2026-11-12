// Настоящие шрифты приложения (Inter, JetBrains Mono) для тестов, где
// важна ширина текста: тестовый шрифт рисует каждую букву квадратом, и
// подписи в нём заметно шире, чем на устройстве.
import 'dart:io';

import 'package:flutter/services.dart';

bool _loaded = false;

/// Загружает шрифты из assets/fonts один раз на процесс тестов.
Future<void> loadAppFonts() async {
  if (_loaded) return;
  Future<ByteData> read(String path) => Future<ByteData>.value(
        ByteData.sublistView(File(path).readAsBytesSync()),
      );
  await (FontLoader('Inter')..addFont(read('assets/fonts/InterVariable.ttf')))
      .load();
  await (FontLoader('JetBrains Mono')
        ..addFont(read('assets/fonts/JetBrainsMonoVariable.ttf')))
      .load();
  _loaded = true;
}
