import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/voice/voice_model.dart';
import 'package:local_assistant/core/voice/voice_recognizer.dart';

void main() {
  group('VoiceModelSpec.ruSmall', () {
    const spec = VoiceModelSpec.ruSmall;

    test('закреплены https-адрес alphacephei.com, размер и SHA-256', () {
      expect(spec.uri.scheme, 'https');
      expect(spec.uri.host, 'alphacephei.com');
      expect(spec.uri.path, '/vosk/models/vosk-model-small-ru-0.22.zip');
      expect(spec.bytes, 46236750);
      expect(spec.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(
        spec.sha256,
        '961d5ff98a17f4aa6de69864d0aa71fa5bac682301d2b5d17a3f24c5c99a46d4',
      );
      expect(spec.folderName, 'vosk-model-small-ru-0.22');
    });

    test('нужные файлы и пределы распаковки', () {
      expect(spec.requiredFiles, <String>['am/final.mdl', 'conf/model.conf']);
      expect(spec.limits.maxEntries, 64);
      expect(spec.limits.maxEntryBytes, 64 * 1024 * 1024);
      expect(spec.limits.maxTotalBytes, 128 * 1024 * 1024);
      // Архив меньше предела распаковки, предел — с запасом на ~87 МБ.
      expect(spec.bytes, lessThan(spec.limits.maxTotalBytes));
    });
  });

  group('normalizeRecognized', () {
    test('пробелы по краям и двойные пробелы убираются', () {
      expect(normalizeRecognized('  купить   хлеб \n'), 'Купить хлеб');
    });

    test('заглавная только первая буква, остальное как есть', () {
      expect(normalizeRecognized('напомни про Москву'), 'Напомни про Москву');
      expect(normalizeRecognized('ёлка'), 'Ёлка');
      expect(normalizeRecognized('Уже с заглавной'), 'Уже с заглавной');
    });

    test('пустой и из одних пробелов — пусто', () {
      expect(normalizeRecognized(''), '');
      expect(normalizeRecognized('   '), '');
    });

    test('цифры и знаки в начале не ломаются', () {
      expect(normalizeRecognized('2 задачи'), '2 задачи');
    });
  });

  group('тексты ошибок голосового ввода', () {
    test('по-русски и без распознанного текста', () {
      for (final code in VoiceErrorCode.values) {
        expect(code.message, matches(RegExp('[а-яё]')));
      }
    });
  });

  group('AppSettings: голосовой ввод', () {
    test('по умолчанию выключен и в JSON не пишется', () {
      const settings = AppSettings();
      expect(settings.voiceInput, isFalse);
      expect(settings.voiceSendImmediately, isFalse);
      final json = settings.toJson();
      expect(json.containsKey('voice.enabled'), isFalse);
      expect(json.containsKey('voice.send_now'), isFalse);
      expect(json.containsKey('voice.mic_explained'), isFalse);
    });

    test('включённые значения переживают сохранение', () {
      final settings = const AppSettings().copyWith(
        voiceInput: true,
        voiceSendImmediately: true,
        voiceMicExplained: true,
      );
      final json = settings.toJson();
      expect(json['voice.enabled'], isTrue);
      expect(json['voice.send_now'], isTrue);
      final back = AppSettings.fromJson(json);
      expect(back.voiceInput, isTrue);
      expect(back.voiceSendImmediately, isTrue);
      expect(back.voiceMicExplained, isTrue);
      // Остальное copyWith не трогает.
      expect(back.showTimestamps, settings.showTimestamps);
    });

    test('неверный тип — значение по умолчанию', () {
      final back = AppSettings.fromJson(<String, dynamic>{
        'voice.enabled': 'да',
        'voice.send_now': 1,
      });
      expect(back.voiceInput, isFalse);
      expect(back.voiceSendImmediately, isFalse);
    });
  });

  group('платформа и приватность', () {
    String read(String path) => File(path).readAsStringSync();

    test('Android: RECORD_AUDIO, libvosk только arm64, модель вне копии', () {
      final manifest = read('android/app/src/main/AndroidManifest.xml');
      expect(
        manifest,
        contains('android:name="android.permission.RECORD_AUDIO"'),
      );
      final gradle = read('android/app/build.gradle.kts');
      expect(
        gradle,
        contains('implementation("com.alphacephei:vosk-android:0.3.75@aar")'),
      );
      for (final abi in <String>['armeabi-v7a', 'x86', 'x86_64']) {
        expect(gradle, contains('"lib/$abi/libvosk.so"'));
      }
      const exclude = '<exclude domain="file" path="assistant/voice/" />';
      final rules =
          read('android/app/src/main/res/xml/data_extraction_rules.xml');
      expect(exclude.allMatches(rules).length, 2);
      expect(
        read('android/app/src/main/res/xml/backup_rules.xml'),
        contains(exclude),
      );
    });

    test('лицензии Vosk в assets и pubspec', () {
      final notice = read('assets/voice/NOTICE.txt');
      for (final name in <String>['Vosk', 'Kaldi', 'OpenFST', 'OpenBLAS']) {
        expect(notice, contains(name));
      }
      expect(notice, contains('Apache License 2.0'));
      expect(read('pubspec.yaml'), contains('assets/voice/NOTICE.txt'));
    });

    test('код голосового ввода ничего не печатает в журнал', () {
      final files = <File>[
        for (final dir in <String>['lib/core/voice', 'lib/app/voice'])
          ...Directory(dir).listSync(recursive: true).whereType<File>(),
        File('lib/core/downloads/verified_download.dart'),
        File('lib/core/downloads/safe_zip.dart'),
      ];
      expect(files, isNotEmpty);
      for (final file in files) {
        final text = file.readAsStringSync();
        expect(
          text,
          isNot(matches(RegExp(r'\b(print|debugPrint|log)\('))),
          reason: file.path,
        );
        expect(text, isNot(contains('dart:developer')), reason: file.path);
      }
    });

    test('Vosk молчит: уровень журнала -1', () {
      expect(
        read('lib/app/voice/vosk_voice_recognizer.dart'),
        contains('setLogLevel(-1)'),
      );
    });
  });
}
