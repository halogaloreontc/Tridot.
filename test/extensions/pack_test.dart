import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/extensions/pack.dart';

Map<String, Object?> validPack() => <String, Object?>{
      'format': 'assistant-pack/1',
      'id': 'jokes.test',
      'type': 'jokes',
      'title': 'Тестовые шутки',
      'author': 'Автор',
      'language': 'ru',
      'version': '1.0.0',
      'description': 'Для проверки.',
      'entries': <Object?>[
        <String, Object?>{
          'id': 'j1',
          'text': 'Шутка про задачи',
          'tags': <String>['Задачи', 'понедельник'],
          'persona': 'any',
        },
        <String, Object?>{
          'id': 'j2',
          'text': 'Шутка для Noda',
          'persona': 'noda',
          'styles': <String>['friendly', 'brief'],
        },
      ],
    };

List<String> errorsOf(Map<String, Object?> json) =>
    PackFormat.parse(jsonEncode(json)).errors;

Map<String, Object?> withEntry(Map<String, Object?> entry) =>
    validPack()..['entries'] = <Object?>[entry];

void main() {
  test('правильный пак принят', () {
    final result = PackFormat.parse(jsonEncode(validPack()));
    expect(result.errors, isEmpty);
    final pack = result.pack!;
    expect(pack.id, 'jokes.test');
    expect(pack.entries, hasLength(2));
    expect(pack.entries.first.tags, <String>['задачи', 'понедельник']);
    expect(pack.entries.last.persona, PackPersona.noda);
    expect(pack.entries.last.styles, <PackStyle>[
      PackStyle.friendly,
      PackStyle.brief,
    ]);
    // Сериализация обратно — тот же пак.
    final again = PackFormat.parse(pack.encode()).pack!;
    expect(again.toJson(), pack.toJson());
  });

  test('встроенный пак шуток проходит проверку', () {
    final source = File('assets/packs/jokes_basic.json').readAsStringSync();
    final result = PackFormat.parse(source);
    expect(result.errors, isEmpty);
    final pack = result.pack!;
    expect(pack.id, 'jokes.basic');
    expect(pack.type, 'jokes');
    expect(pack.entries.length, inInclusiveRange(20, 40));
    for (final entry in pack.entries) {
      expect(entry.tags, isNotEmpty, reason: entry.id);
      expect(entry.persona, PackPersona.any, reason: entry.id);
      expect(entry.text.length, lessThanOrEqualTo(200), reason: entry.id);
    }
  });

  group('ошибки по-русски', () {
    void expectError(Map<String, Object?> json, String fragment) {
      final errors = errorsOf(json);
      expect(
        errors.any((String e) => e.contains(fragment)),
        isTrue,
        reason: 'ожидалось «$fragment», есть: $errors',
      );
    }

    test('не JSON и не объект', () {
      expect(PackFormat.parse('{').errors.single, startsWith('Это не JSON'));
      expect(
        PackFormat.parse('[]').errors.single,
        'Пак должен быть JSON-объектом { … }.',
      );
    });

    test('формат и его версия', () {
      expectError(validPack()..remove('format'), 'Нет поля «format»');
      expectError(
        validPack()..['format'] = 'assistant-pack/2',
        'Версия формата «assistant-pack/2» не поддерживается',
      );
      expectError(validPack()..['format'] = 'quiz/1', 'Неизвестный формат');
    });

    test('id', () {
      for (final bad in <String>['A', 'x', '-jokes', 'шутки', 'a/b', 'a b']) {
        expectError(validPack()..['id'] = bad, 'Идентификатор');
      }
      expectError(validPack()..['id'] = 'a' * 65, 'длиннее 64');
      expect(errorsOf(validPack()..['id'] = 'ab'), isEmpty);
      expect(errorsOf(validPack()..['id'] = 'my_pack-2.0'), isEmpty);
    });

    test('вид, язык, версия, обязательные поля', () {
      expectError(validPack()..['type'] = 'quiz', 'Неизвестный вид пака');
      expectError(validPack()..['language'] = 'en', 'только «ru»');
      expectError(validPack()..['version'] = '1.0', 'вида «1.0.0»');
      expectError(validPack()..remove('title'), 'Нет поля «title»');
      expectError(validPack()..remove('author'), 'Нет поля «author»');
      expectError(validPack()..['title'] = '  ', 'Поле «title» пустое');
      expectError(validPack()..['title'] = 5, 'должно быть строкой');
      expectError(validPack()..['description'] = 1, 'должно быть строкой');
      expectError(validPack()..['extra'] = true, 'Неизвестное поле «extra»');
    });

    test('записи', () {
      expectError(validPack()..remove('entries'), 'Нет поля «entries»');
      expectError(validPack()..['entries'] = 'нет', 'должно быть списком');
      expectError(validPack()..['entries'] = <Object?>[], 'ни одной записи');
      expectError(
        validPack()
          ..['entries'] = <Object?>[
            for (var i = 0; i < 5001; i++)
              <String, Object?>{'id': 'e$i', 'text': 'т'},
          ],
        'Записей больше 5000',
      );
      expectError(
        withEntry(<String, Object?>{'id': 'j1'}),
        'entries[0]: нет строкового поля «text»',
      );
      expectError(
        withEntry(<String, Object?>{'id': 'j1', 'text': 'x' * 501}),
        'текст длиннее 500',
      );
      expectError(
        withEntry(<String, Object?>{'id': 'j1', 'text': 'a\u0000b'}),
        'управляющие символы',
      );
      expectError(
        validPack()
          ..['entries'] = <Object?>[
            <String, Object?>{'id': 'j1', 'text': 'а'},
            <String, Object?>{'id': 'j1', 'text': 'б'},
          ],
        'entries[1]: id «j1» уже есть',
      );
      expectError(
        withEntry(<String, Object?>{'id': 'J 1', 'text': 'а'}),
        'entries[0]: id',
      );
      expectError(withEntry(<String, Object?>{'text': 'а'}), '«id»');
      expectError(validPack()..['entries'] = <Object?>[1], 'объектом');
      expectError(
        withEntry(<String, Object?>{'id': 'j1', 'text': 'а', 'x': 1}),
        'неизвестное поле «x»',
      );
    });

    test('метки, помощник, стили', () {
      expectError(
        withEntry(<String, Object?>{
          'id': 'j1',
          'text': 'а',
          'tags': <String>[for (var i = 0; i < 11; i++) 't$i'],
        }),
        'меток больше 10',
      );
      expectError(
        withEntry(<String, Object?>{
          'id': 'j1',
          'text': 'а',
          'tags': <String>['т' * 31],
        }),
        'длиннее 30',
      );
      expectError(
        withEntry(<String, Object?>{
          'id': 'j1',
          'text': 'а',
          'tags': <Object?>[1],
        }),
        'непустой строкой',
      );
      expectError(
        withEntry(<String, Object?>{'id': 'j1', 'text': 'а', 'tags': 'т'}),
        'списком строк',
      );
      expectError(
        withEntry(<String, Object?>{'id': 'j1', 'text': 'а', 'persona': 'bob'}),
        'any, rio, noda',
      );
      expectError(
        withEntry(<String, Object?>{
          'id': 'j1',
          'text': 'а',
          'styles': <String>['loud'],
        }),
        'неизвестный стиль «loud»',
      );
    });

    test('файл больше 1 МБ', () {
      final huge = '{"x":"${'a' * (PackFormat.maxBytes + 1)}"}';
      expect(PackFormat.parse(huge).errors.single, 'Файл пака больше 1 МБ.');
    });

    test('много ошибок — список обрезан', () {
      final json = validPack()
        ..['entries'] = <Object?>[for (var i = 0; i < 40; i++) 1];
      final errors = errorsOf(json);
      expect(errors, hasLength(PackFormat.maxReportedErrors + 1));
      expect(errors.last, startsWith('И ещё ошибок:'));
    });

    test('текст — только текст: разметка не трогается', () {
      final pack = PackFormat.parse(
        jsonEncode(
          withEntry(<String, Object?>{
            'id': 'j1',
            'text': '<b>жирный</b> **звёзды** \${код}',
          }),
        ),
      ).pack!;
      expect(pack.entries.single.text, '<b>жирный</b> **звёзды** \${код}');
    });
  });

  test('PackPersona.suits', () {
    expect(PackPersona.any.suits(PackPersona.rio), isTrue);
    expect(PackPersona.rio.suits(PackPersona.rio), isTrue);
    expect(PackPersona.rio.suits(PackPersona.noda), isFalse);
    expect(PackPersona.noda.suits(PackPersona.any), isTrue);
  });

  group('находки ревью', () {
    test('метка порядка байтов (BOM) в начале не мешает', () {
      final result = PackFormat.parse('\uFEFF${jsonEncode(validPack())}');
      expect(result.errors, isEmpty);
      expect(result.pack!.id, 'jokes.test');
    });

    test('управляющие символы и знаки направления в метках отклонены', () {
      for (final tag in <String>['a\u0000b', 'a\u0007b', '\u202Eevil']) {
        final errors = errorsOf(
          withEntry(<String, Object?>{
            'id': 'e1',
            'text': 'текст',
            'tags': <String>[tag],
          }),
        );
        expect(
          errors,
          <String>['entries[0]: в метке есть управляющие символы.'],
          reason: tag.codeUnits.toString(),
        );
      }
    });

    test('знаки направления текста в названии и тексте отклонены', () {
      expect(
        errorsOf(validPack()..['title'] = '\u202Etxt.exe'),
        <String>['В поле «title» есть управляющие символы.'],
      );
      for (final bidi in <String>['\u202D', '\u2066', '\u200F']) {
        expect(
          errorsOf(
            withEntry(<String, Object?>{'id': 'e1', 'text': 'а$bidiб'}),
          ),
          <String>['entries[0]: в тексте есть управляющие символы.'],
        );
      }
    });

    test('«И ещё ошибок: N» — настоящее число ошибок', () {
      final json = validPack()
        ..['entries'] = <Object?>[
          for (var i = 0; i < 300; i++)
            <String, Object?>{'id': 'BAD', 'text': ''},
        ];
      final errors = errorsOf(json);
      // 300 записей × (плохой id + пустой текст) = 600 ошибок.
      expect(errors, hasLength(PackFormat.maxReportedErrors + 1));
      expect(errors.last, 'И ещё ошибок: 580.');
    });

    test('сохранённый вид компактный и без persona «any»', () {
      final pack = PackFormat.parse(jsonEncode(validPack())).pack!;
      final encoded = pack.encode();
      expect(encoded, isNot(contains('\n')));
      expect(encoded, isNot(contains('"persona":"any"')));
      expect(encoded, contains('"persona":"noda"'));
      expect(PackFormat.parse(encoded).pack!.toJson(), pack.toJson());
    });
  });
}
