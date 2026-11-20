import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/number_words.dart';
import 'package:local_assistant/core/connectors/spoken_time.dart';

void main() {
  group('NumberWords.find', () {
    List<int> values(String text) => <int>[
          for (final match in NumberWords.find(text)) match.value,
        ];

    test('составные числа целиком', () {
      expect(values('сто сорок четыре'), <int>[144]);
      expect(values('восемьсот'), <int>[800]);
      expect(values('тыща две'), <int>[1002]);
      expect(values('две тысячи двадцать шесть'), <int>[2026]);
      expect(values('от восьмисот'), <int>[800]);
    });

    test('время на часах — два числа', () {
      expect(values('восемь тридцать'), <int>[8, 30]);
      expect(values('двадцать один ноль ноль'), <int>[21, 0, 0]);
    });

    test('падеж не смешивается', () {
      // «Без двадцати шесть» — 5:40, а не 26.
      expect(values('без двадцати шесть'), <int>[20, 6]);
      expect(values('сорока пяти'), <int>[45]);
    });
  });

  group('NumberWords.ordinal', () {
    test('порядковое и окончание', () {
      expect(NumberWords.ordinal('пятого'), (5, 'ого'));
      expect(NumberWords.ordinal('третьему'), (3, 'ому'));
      expect(NumberWords.ordinal('двадцатое'), (20, 'ое'));
      expect(NumberWords.ordinal('пятый'), isNull);
    });

    test('составное число месяца', () {
      expect(
        NumberWords.dayOrdinalAt(<String>['двадцать', 'пятого'], 0),
        (25, 'ого', 1),
      );
      expect(
        NumberWords.dayOrdinalAt(<String>['тридцать', 'второго'], 0),
        isNull,
      );
    });
  });

  group('SpokenTime: число месяца без месяца', () {
    List<String> digits(String text) => <String>[
          for (final match in SpokenTime.find(text)) match.digits,
        ];

    test('родительный и винительный после «на»', () {
      expect(digits('напомни двадцать пятого оплатить'), <String>['25-го']);
      expect(digits('перенеси на двадцать девятое'), <String>['29-е']);
      expect(digits('к двадцать пятому числу'), <String>['25-му']);
    });

    test('при существительном — не дата', () {
      expect(digits('встретить гостей второго подъезда'), isEmpty);
      expect(digits('занять третье место'), isEmpty);
      expect(digits('в начале пятого'), isEmpty);
    });

    test('время словами', () {
      expect(digits('в восемнадцать ноль-ноль'), <String>['18:00']);
      expect(digits('к девяти пятнадцати'), <String>['9:15']);
      expect(digits('к двум часам дня'), <String>['2']);
    });
  });
}
