// Последний выбор в карточках (ADR-026): в настройках только известные поля
// и допустимые значения; файл настроек с мусором не мешает.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/settings/app_settings.dart';

void main() {
  test('туда и обратно; ключи по порядку', () {
    const settings = AppSettings(
      formDefaults: <String, String>{
        'converter.audio_kbps': '320',
        'archiver.level': 'strong',
      },
    );
    final json =
        jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>;
    expect((json['form_defaults'] as Map).keys, <String>[
      'archiver.level',
      'converter.audio_kbps',
    ]);
    expect(AppSettings.fromJson(json).formDefaults, settings.formDefaults);
    expect(const AppSettings().toJson().containsKey('form_defaults'), isFalse);
  });

  test('недопустимое отбрасывается', () {
    final settings = AppSettings.fromJson(<String, dynamic>{
      'form_defaults': <String, Object?>{
        'converter.audio_kbps': '999',
        'converter.video_res': '720',
        'converter.target': 'mp3',
        'converter.file': '/etc/passwd',
        'archiver.level': 'ultra',
        'ytdl.format': 'audio',
        'audio_kbps': '320',
        'converter.jpeg_quality': 85,
        '.x': 'y',
      },
    });
    expect(settings.formDefaults, <String, String>{
      'converter.video_res': '720',
    });
    expect(
      AppSettings.fromJson(<String, dynamic>{'form_defaults': 'мусор'})
          .formDefaults,
      isEmpty,
    );
  });
}
