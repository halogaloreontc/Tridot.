import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/intent/intent_tokenizer.dart';

import 'local_packs.dart';

/// Эталон — HuggingFace tokenizers (tools/intent_model/dart_fixtures.py):
/// синтетические фразы с пунктуацией, числами, эмодзи, латиницей, «ё»,
/// длинными словами и невидимыми знаками. Урезанные словари дают те же
/// номера, что полные (это проверяет сам генератор); с полными — если пакет
/// собран локально (tools/intent_model/out).
void main() {
  final golden = jsonDecode(
    File('test/fixtures/intent/tokenizer_golden.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final phrases = (golden['phrases']! as List<Object?>).cast<String>();

  List<int> ids(Object? row) => (row! as List<Object?>).cast<int>();

  for (final tier in <String>['light', 'accurate']) {
    group('токенизатор $tier', () {
      final tokenizer = IntentTokenizer.parse(
        File('test/fixtures/intent/tokenizer_${tier}_mini.json')
            .readAsStringSync(),
      );
      final expected = golden[tier]! as List<Object?>;

      test('совпадает с tokenizers на ${phrases.length} фразах', () {
        expect(phrases.length, greaterThanOrEqualTo(200));
        final wrong = <String>[];
        for (final (index, phrase) in phrases.indexed) {
          final got = tokenizer.encode(phrase);
          final want = ids(expected[index]);
          if (got.length != want.length ||
              !Iterable<int>.generate(got.length)
                  .every((int i) => got[i] == want[i])) {
            wrong.add('${jsonEncode(phrase)}: $got ≠ $want');
          }
        }
        expect(wrong, isEmpty);
      });

      test('не длиннее 64 со служебными, служебные по краям', () {
        final long = tokenizer.encode('слово ' * 200);
        expect(long, hasLength(64));
        final empty = tokenizer.encode('');
        expect(empty, hasLength(2));
        expect(long.first, empty.first);
        expect(long.last, empty.last);
        expect(tokenizer.encode('слово ' * 200, maxLength: 10), hasLength(10));
      });

      final full = localPackFile(tier, 'tokenizer.json');
      test(
        'полный словарь пакета даёт те же номера',
        () {
          final real = IntentTokenizer.parse(full!.readAsStringSync());
          for (final (index, phrase) in phrases.indexed) {
            expect(real.encode(phrase), ids(expected[index]), reason: phrase);
          }
        },
        skip: full == null ? 'пакет $tier не собран локально' : false,
      );
    });
  }

  test('пакет фраз: дополнение, маска, нулевые типы', () {
    final batch = TokenBatch.of(
      <List<int>>[
        <int>[2, 10, 3],
        <int>[2, 3],
      ],
      padId: 0,
    );
    expect(batch.rows, 2);
    expect(batch.length, 3);
    expect(batch.ids, <int>[2, 10, 3, 2, 3, 0]);
    expect(batch.mask, <int>[1, 1, 1, 1, 1, 0]);
    expect(batch.input('token_type_ids'), everyElement(0));
    expect(() => batch.input('pixel_values'), throwsArgumentError);
  });

  test('неизвестная модель и нижний регистр — ошибка формата', () {
    expect(
      () => IntentTokenizer.fromJson(<String, Object?>{
        'model': <String, Object?>{'type': 'Unigram'},
      }),
      throwsFormatException,
    );
    expect(
      () => IntentTokenizer.fromJson(<String, Object?>{
        'normalizer': <String, Object?>{'lowercase': true},
        'model': <String, Object?>{
          'type': 'WordPiece',
          'vocab': <String, Object?>{'[UNK]': 0},
        },
      }),
      throwsFormatException,
    );
  });
}
