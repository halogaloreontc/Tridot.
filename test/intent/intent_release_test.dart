import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/intent/intent_memory.dart';
import 'package:local_assistant/core/intent/intent_release.dart';
import 'package:local_assistant/core/intent/unclear_export.dart';
import 'package:local_assistant/core/settings/app_settings.dart';

String _latest({
  String version = '1.0.0',
  String url =
      'https://github.com/halogaloreontc/Tridot./releases/download/intent-latest/tridot-intent-accurate-1.0.0.zip',
  Object size = 131000000,
  String sha = 'ab',
  bool withLight = false,
}) =>
    jsonEncode(<String, Object?>{
      'format': 'tridot-intent-latest/1',
      'version': version,
      'tiers': <String, Object?>{
        if (withLight)
          'light': <String, Object?>{
            'url': 'https://github.com/halogaloreontc/Tridot./releases/'
                'download/intent-latest/tridot-intent-light-1.0.0.zip',
            'file': 'tridot-intent-light-1.0.0.zip',
            'size': 33000000,
            'sha256': 'cd' * 32,
            'title': 'Лёгкая (rubert-tiny2)',
            'threshold': 0.91,
          },
        'accurate': <String, Object?>{
          'url': url,
          'file': 'tridot-intent-accurate-1.0.0.zip',
          'size': size,
          'sha256': sha == 'ab' ? 'AB' * 32 : sha,
          'title': 'Лёгкая',
          'threshold': 0.895,
        },
      },
    });

void main() {
  group('latest.json', () {
    test('формат шага 1 разбирается', () {
      final release = IntentRelease.parse(_latest());
      expect(release.version, '1.0.0');
      final accurate = release.of(IntentTier.accurate)!;
      expect(accurate.size, 131000000);
      expect(accurate.sha256, 'ab' * 32);
      expect(accurate.threshold, 0.895);
    });

    test('прежний выпуск с `light` тоже разбирается', () {
      final release = IntentRelease.parse(_latest(withLight: true));
      expect(release.of(IntentTier.accurate)?.size, 131000000);
    });

    test('чужой адрес, http, битые размер и сумма — отказ', () {
      for (final text in <String>[
        _latest(url: 'https://example.com/x.zip'),
        _latest(
          url: 'http://github.com/halogaloreontc/Tridot./releases/download/'
              'intent-latest/a.zip',
        ),
        _latest(
          url: 'https://github.com/halogaloreontc/Tridot./releases/download/'
              '../../evil.zip',
        ),
        _latest(size: -1),
        _latest(size: '1'),
        _latest(sha: 'xyz'),
        _latest(version: 'latest'),
        '{"format": "other"}',
        'не json',
      ]) {
        expect(
          () => IntentRelease.parse(text),
          throwsA(isA<IntentReleaseException>()),
          reason: text,
        );
      }
    });

    test('версии сравниваются по числам', () {
      expect(IntentRelease.compareVersions('1.10.0', '1.9.9'), greaterThan(0));
      expect(IntentRelease.compareVersions('0.1.0', '0.1.0'), 0);
      expect(IntentRelease.compareVersions('0.1.0', '1.0.0'), lessThan(0));
      expect(
        IntentRelease.parse(_latest(version: '1.2.0')).newerThan('1.1.9'),
        isTrue,
      );
    });
  });

  group('настройки', () {
    test('по умолчанию и у прежних настроек: выключено, учёба и журнал', () {
      final old = AppSettings.fromJson(<String, dynamic>{
        'reduce_motion': true,
        'voice.enabled': true,
      });
      expect(old.intentTier, IntentTier.off);
      expect(old.intentLearning, isTrue);
      expect(old.intentLogging, isTrue);
      expect(old.intentOffered, isFalse);
      expect(
        const AppSettings().toJson().keys.where((k) => k.startsWith('intent')),
        isEmpty,
      );
    });

    test('выбор сохраняется и читается', () {
      const settings = AppSettings(
        intentTier: IntentTier.accurate,
        intentLearning: false,
        intentLogging: false,
        intentOffered: true,
      );
      final json = jsonDecode(jsonEncode(settings.toJson()));
      final back = AppSettings.fromJson(json as Map<String, dynamic>);
      expect(back.intentTier, IntentTier.accurate);
      expect(back.intentLearning, isFalse);
      expect(back.intentLogging, isFalse);
      expect(back.intentOffered, isTrue);
      expect(
        AppSettings.fromJson(<String, dynamic>{'intent.tier': 'huge'})
            .intentTier,
        IntentTier.off,
      );
    });
  });

  group('выгрузка непонятых', () {
    final at = DateTime(2026, 11, 20, 15, 30);

    test('JSONL: фраза, статус, метка, день — без времени', () {
      final lines = UnclearExport.lines(<UnclearPhrase>[
        UnclearPhrase(
          text: '  напомни   купить хлеб ',
          at: at,
          kind: UnclearKind.accepted,
          label: 'tasks:task.create',
        ),
        UnclearPhrase(
          text: 'что-то странное',
          at: at,
          kind: UnclearKind.unknown,
        ),
      ]);
      expect(lines, hasLength(2));
      expect(jsonDecode(lines[0]), <String, Object?>{
        'text': 'напомни купить хлеб',
        'status': 'accepted',
        'label': 'tasks:task.create',
        'date': '2026-11-20',
      });
      expect(lines[1], isNot(contains('15:30')));
      expect(UnclearExport.text(lines), '${lines[0]}\n${lines[1]}\n');
      expect(UnclearExport.fileName(at), 'tridot-unclear-2026-11-20.jsonl');
    });

    test('приватное не выгружается, даже если попало в журнал', () {
      final lines = UnclearExport.lines(
        <UnclearPhrase>[
          UnclearPhrase(
            text: 'мой пароль от почты CANARY-x9',
            at: at,
            kind: UnclearKind.unknown,
          ),
          UnclearPhrase(
            text: 'пин-код CANARY',
            at: at,
            kind: UnclearKind.unknown,
          ),
          UnclearPhrase(
            text: 'особая фраза',
            at: at,
            kind: UnclearKind.unknown,
          ),
          UnclearPhrase(
            text: 'обычная фраза',
            at: at,
            kind: UnclearKind.unknown,
          ),
        ],
        blocks: (String text) => text.contains('особая'),
      );
      expect(lines, hasLength(1));
      expect(lines.single, contains('обычная фраза'));
    });
  });
}
