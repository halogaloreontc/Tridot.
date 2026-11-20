import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/manifest/app_profile.dart';
import 'package:local_assistant/core/connectors/manifest/manifest_format.dart';

import 'fixtures.dart';

/// Профиль приложения из `app` описания (ADR-043). Только выдуманные
/// приложения и значения.
void main() {
  Map<String, Object?> app([Map<String, Object?> extra = const {}]) =>
      <String, Object?>{
        'id': 'testcrm',
        'title': 'Тестовая CRM',
        'name': 'автосервис',
        'forms': <String, Object?>{
          'nom': 'автосервис',
          'gen': 'автосервиса',
          'dat': 'автосервису',
          'acc': 'автосервис',
          'ins': 'автосервисом',
          'prep': 'автосервисе',
        },
        'in': 'в автосервисе',
        'gender': 'm',
        'addressing': <String>['сервис', 'автосервис'],
        ...extra,
      };

  ({AppProfile? profile, List<String> warnings}) parse(Object? raw) =>
      AppProfile.parse(raw);

  group('годный профиль', () {
    test('все поля', () {
      final (:profile, :warnings) = parse(app());
      expect(warnings, isEmpty);
      expect(profile, isNotNull);
      expect(profile!.appId, 'testcrm');
      expect(profile.name, 'автосервис');
      expect(profile.declinable, isTrue);
      expect(profile.forms!.gen, 'автосервиса');
      expect(profile.forms!.prep, 'автосервисе');
      expect(profile.inPhrase, 'в автосервисе');
      expect(profile.gender, AppGender.m);
      expect(profile.addressing, <String>['сервис', 'автосервис']);
    });

    test('род: m, f, n, pl', () {
      for (final (raw, gender) in <(String, AppGender)>[
        ('m', AppGender.m),
        ('f', AppGender.f),
        ('n', AppGender.n),
        ('pl', AppGender.pl),
      ]) {
        expect(
          parse(app(<String, Object?>{'gender': raw})).profile!.gender,
          gender,
        );
      }
    });

    test('только имя — несклоняемое, без рода и обращений', () {
      final (:profile, :warnings) =
          parse(<String, Object?>{'id': 'testcrm', 'name': 'CRM'});
      expect(warnings, isEmpty);
      expect(profile!.name, 'CRM');
      expect(profile.declinable, isFalse);
      expect(profile.cases.gen, 'CRM');
      expect(profile.cases.prep, 'CRM');
      expect(profile.inPhrase, isNull);
      expect(profile.gender, isNull);
      expect(profile.addressing, isEmpty);
    });

    test('имя с кавычками «» и дефисом', () {
      final (:profile, :warnings) = parse(<String, Object?>{
        'id': 'testcrm',
        'name': 'авто-сервис «Тест»',
      });
      expect(warnings, isEmpty);
      expect(profile!.name, 'авто-сервис «Тест»');
    });

    test('без имени профиля нет, и это не ошибка', () {
      final (:profile, :warnings) =
          parse(<String, Object?>{'id': 'testcrm', 'title': 'Тест'});
      expect(profile, isNull);
      expect(warnings, isEmpty);
      expect(parse(null).profile, isNull);
      expect(parse('строка').profile, isNull);
    });
  });

  group('плохие поля отбрасываются с предупреждением', () {
    test('синтаксис шаблонов в имени — профиля нет', () {
      for (final name in <String>[
        '{login}',
        'сервис {вы:a|ты:b}',
        'сервис|склад',
        'сервис}',
        r'сервис $token',
        'сервис <b>',
        '',
        '123',
        'а' * 41,
      ]) {
        final (:profile, :warnings) =
            parse(<String, Object?>{'id': 'testcrm', 'name': name});
        expect(profile, isNull, reason: name);
        expect(warnings, isNotEmpty, reason: name);
      }
    });

    test('имя не строка или нет app.id — профиля нет', () {
      expect(
        parse(<String, Object?>{'id': 'testcrm', 'name': 5}).profile,
        isNull,
      );
      expect(parse(<String, Object?>{'name': 'автосервис'}).profile, isNull);
      expect(
        parse(<String, Object?>{'id': 'Bad Id', 'name': 'автосервис'}).profile,
        isNull,
      );
    });

    test('занятое или приватное имя — профиля нет', () {
      for (final name in <String>['склад', 'Пароли', 'Нода', 'задачи', 'PIN']) {
        final (:profile, :warnings) =
            parse(<String, Object?>{'id': 'testcrm', 'name': name});
        expect(profile, isNull, reason: name);
        expect(warnings, isNotEmpty, reason: name);
      }
    });

    test('падежи с чужим nom, неполные или со знаками — несклоняемое', () {
      for (final forms in <Object?>[
        <String, Object?>{
          'nom': 'база',
          'gen': 'базы',
          'dat': 'базе',
          'acc': 'базу',
          'ins': 'базой',
          'prep': 'базе',
        },
        <String, Object?>{'nom': 'автосервис', 'gen': 'автосервиса'},
        <String, Object?>{
          'nom': 'автосервис',
          'gen': '{text}',
          'dat': 'автосервису',
          'acc': 'автосервис',
          'ins': 'автосервисом',
          'prep': 'автосервисе',
        },
        'автосервис',
      ]) {
        final (:profile, :warnings) =
            parse(app(<String, Object?>{'forms': forms, 'in': null}));
        expect(profile, isNotNull);
        expect(profile!.declinable, isFalse, reason: '$forms');
        expect(warnings.single, startsWith('app.forms'));
      }
    });

    test('неизвестный род отброшен', () {
      final (:profile, :warnings) =
          parse(app(<String, Object?>{'gender': 'male'}));
      expect(profile!.gender, isNull);
      expect(warnings.single, startsWith('app.gender'));
    });

    test('«in» без предлога или не с предложным падежом — отброшено', () {
      for (final value in <String>[
        'автосервисе',
        'в автосервису',
        'за базой',
      ]) {
        final (:profile, :warnings) =
            parse(app(<String, Object?>{'in': value}));
        expect(profile!.inPhrase, isNull, reason: value);
        expect(warnings.single, startsWith('app.in'), reason: value);
      }
    });

    test('обращения: приватные, занятые и со знаками — отброшены', () {
      final (:profile, :warnings) = parse(
        app(<String, Object?>{
          'addressing': <Object?>[
            'сервис',
            'пароль',
            'пин',
            'код',
            'логин',
            'склад',
            'на складе',
            'Нода',
            'связной',
            'задачи',
            'калькулятор',
            'привет',
            '{login}',
            'сер|вис',
            7,
          ],
        }),
      );
      expect(profile!.addressing, <String>['сервис']);
      expect(warnings, hasLength(14));
    });

    test('обращения, занятые другим подключением, — отброшены', () {
      final (:profile, :warnings) = AppProfile.parse(
        app(),
        taken: <String>{'сервис'},
      );
      expect(profile!.addressing, <String>['автосервис']);
      expect(warnings, hasLength(1));
    });

    test('обращений не больше восьми', () {
      final (:profile, :warnings) = parse(
        app(<String, Object?>{
          'addressing': <String>[
            for (var i = 0; i < 12; i++) 'сервис${'а' * (i + 1)}',
          ],
        }),
      );
      expect(profile!.addressing, hasLength(AppProfile.maxAddressing));
      expect(warnings.single, contains('больше'));
    });
  });

  group('в описании', () {
    test('профиль разбирается вместе с описанием тестовой CRM', () {
      final description = ManifestDescription.parse(
        File('test/fixtures/assistant/testcrm.json').readAsStringSync(),
        appId: 'testcrm',
      );
      expect(description.profile!.name, 'автосервис');
      expect(description.profile!.gender, AppGender.m);
      expect(description.profileWarnings, isEmpty);
    });

    test('плохой профиль не отклоняет описание', () {
      final json = jsonDecode(
        File('test/fixtures/assistant/testcrm.json').readAsStringSync(),
      ) as Map<String, Object?>;
      (json['app']! as Map<String, Object?>)['name'] = '{login}';
      final description =
          ManifestDescription.parse(jsonEncode(json), appId: 'testcrm');
      expect(description.profile, isNull);
      expect(description.profileWarnings, isNotEmpty);
      expect(description.commands, isNotEmpty);
    });

    test('у склада профиля нет: у него свой слот', () {
      expect(manifest().profile, isNull);
      expect(manifest().profileWarnings, isEmpty);
      expect(manifest(builtInManifestPath).profile, isNull);
    });
  });
}
