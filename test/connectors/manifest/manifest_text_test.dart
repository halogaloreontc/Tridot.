import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/manifest/manifest_text.dart';

/// Порт core.mjs (halowarekeep/tools/assistant): числа, формы слов, даты
/// и шаблоны должны совпадать со складом знак в знак.
void main() {
  final vars = ManifestVars(DateTime(2026, 11, 5, 14, 30));

  group('askText', () {
    test('строчные, ё → е, без кавычек и знаков по краям', () {
      expect(askText('  Где «Ёлка»  лежит?! '), 'где елка лежит');
      expect(askText('"Стул" венский.'), 'стул венский');
      expect(askText(null), '');
    });
  });

  group('askNum', () {
    test('тысячи пробелом, дробь запятой, минус «−», до сотых', () {
      expect(askNum(1234.5), '1 234,5');
      expect(askNum(1234567), '1 234 567');
      expect(askNum(-1500), '−1 500');
      expect(askNum(2.005), '2,01');
      expect(askNum(3), '3');
      expect(askNum('12'), '12');
      expect(askNum(0), '0');
    });

    test('не число — как есть, отсутствие — пусто', () {
      expect(askNum('абв'), 'абв');
      expect(askNum(absent), '');
      expect(askNum(null), '0');
    });
  });

  group('askPlural', () {
    test('1, 2, 5, 11, 21, 112', () {
      const forms = 'приход,прихода,приходов';
      expect(askPlural(1, forms), '1 приход');
      expect(askPlural(2, forms), '2 прихода');
      expect(askPlural(5, forms), '5 приходов');
      expect(askPlural(11, forms), '11 приходов');
      expect(askPlural(21, forms), '21 приход');
      expect(askPlural(112, forms), '112 приходов');
      expect(askPlural(1234, forms), '1 234 прихода');
    });

    test('не хватает форм — берётся последняя заданная', () {
      expect(askPlural(5, 'штука'), '5 штука');
      expect(askPlural(absent, 'позиция,позиции,позиций'), ' позиций');
    });
  });

  group('askDate', () {
    test('этот год — без года, другой — с годом', () {
      expect(askDate('2026-11-05', vars), '05.11');
      expect(askDate('2025-12-30T10:00', vars), '30.12.2025');
      expect(askDate('вчера', vars), 'вчера');
      expect(askDate(absent, vars), '');
    });
  });

  group('встроенные значения', () {
    test('today, yesterday, today-6, tz, zone', () {
      expect(vars.lookup('today'), '2026-11-05');
      expect(vars.lookup('yesterday'), '2026-11-04');
      expect(vars.lookup('today-6'), '2026-10-30');
      expect(vars.lookup('today+1'), '2026-11-06');
      expect(
        vars.lookup('tz'),
        '${-DateTime(2026, 11, 5, 14, 30).timeZoneOffset.inMinutes}',
      );
      expect(vars.lookup('zone'), '');
      expect(vars.lookup('token'), same(absent));
    });

    test('сдвиг через границу месяца и года', () {
      final january = ManifestVars(DateTime(2026, 1, 2));
      expect(january.lookup('today-6'), '2025-12-27');
      expect(january.yesterday, '2026-01-01');
    });
  });

  group('askFill', () {
    final row = <String, Object?>{
      'sku': '',
      'name': 'Стул',
      'qty': 1200,
      'scan': false,
      'skus': <Object?>['64115', '64116'],
    };
    final response = <String, Object?>{'count': 3, 'q': 'стул'};

    test('цепочка: строка → ответ → поля фразы', () {
      expect(
        askFill(
          '{name}: {qty|num} шт. из «{q}», {count}',
          <Object?>[row, response],
          vars,
        ),
        'Стул: 1 200 шт. из «стул», 3',
      );
      expect(
        askFill(
          '{cell}',
          <Object?>[
            row,
            <String, String>{'cell': '215-3'},
          ],
          vars,
        ),
        '215-3',
      );
    });

    test('or, if, unless, plural, date', () {
      final chain = <Object?>[row, response];
      expect(askFill('{sku|or:без артикула}', chain, vars), 'без артикула');
      expect(askFill('{name|or:—}', chain, vars), 'Стул');
      expect(
        askFill('{scan|unless: · скан не прикреплён}', chain, vars),
        ' · скан не прикреплён',
      );
      expect(askFill('{name|if:есть}', chain, vars), 'есть');
      expect(
        askFill('{count|plural:позиция,позиции,позиций}', chain, vars),
        '3 позиции',
      );
      expect(
        askFill(
          '{day|date}',
          <Object?>[
            <String, Object?>{'day': '2026-10-20'},
          ],
          vars,
        ),
        '20.10',
      );
      expect(askFill(r'{$today}', chain, vars), '2026-11-05');
    });

    test('массив — через запятую, объект и false — пусто', () {
      final chain = <Object?>[row];
      expect(askFill('{skus}', chain, vars), '64115, 64116');
      expect(askFill('{scan}', chain, vars), '');
      expect(askFill('{missing}', chain, vars), '');
    });
  });

  test('askTidy убирает пустые « · »', () {
    expect(askTidy('Реестр ·  · 09:15'), 'Реестр · 09:15');
    expect(askTidy(' · Приход 12 · '), 'Приход 12');
    expect(askTidy(null), '');
  });

  group('askBody', () {
    test('поле целиком — как есть, число остаётся числом', () {
      final body = askBody(
        <String, Object?>{
          'from': r'{$today-6}',
          'to': r'{$today}',
          'tz': r'{$tz}',
          'zone': r'{$zone}',
          'days': 30,
          'q': '{q}',
          'text': 'артикул {q}',
        },
        <String, String>{'q': '64115'},
        vars,
      );
      expect(body['from'], '2026-10-30');
      expect(body['to'], '2026-11-05');
      expect(body['days'], 30);
      expect(body['zone'], '');
      expect(body['q'], '64115');
      expect(body['text'], 'артикул 64115');
    });

    test('неизвестное поле в тело не попадает', () {
      final body = askBody(
        <String, Object?>{'q': '{nope}', 'x': r'{$nope}'},
        const <String, String>{},
        vars,
      );
      expect(body, isEmpty);
    });
  });
}
