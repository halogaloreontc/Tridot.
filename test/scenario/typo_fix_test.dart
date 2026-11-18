// Опечатки в словах команд (TypoFix): что исправляется и что — нет.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/scenario/typo_fix.dart';

void main() {
  test('слово команды на расстоянии одной правки', () {
    const cases = <String, String>{
      'постпвь будильник на 7': 'поставь будильник на 7',
      'склоько венских стульев': 'сколько венских стульев',
      'Пакажи заадчи': 'Покажи задачи',
      'что пишло сегодня': 'что пришло сегодня',
      'какая поггда завтра': 'какая погода завтра',
      'рааспакуй арххив': 'распакуй архив',
    };
    cases.forEach((String input, String expected) {
      expect(TypoFix.repair(input), expected, reason: input);
    });
  });

  test('не опечатка — фраза как есть', () {
    for (final text in <String>[
      'выключи будильник',
      'наполни ванну вечером',
      'обложи налогом завтра',
      'двинь стол',
      'купить молоко',
      'напомню завтра',
      'запишу хлеб',
      'погоди минутку',
    ]) {
      expect(TypoFix.repair(text), isNull, reason: text);
    }
  });

  test('растянутая буква', () {
    expect(TypoFix.repairDue('купить молоко завтраа'), 'купить молоко завтра');
    expect(TypoFix.repair('напоомни купить хлеб'), 'напомни купить хлеб');
    expect(TypoFix.repair('ванна вечером'), isNull, reason: 'не слово словаря');
  });

  test('только слова срока', () {
    expect(
      TypoFix.repairDue('напоми заввтра в 10 позвонить маме'),
      'напоми завтра в 10 позвонить маме',
    );
    expect(TypoFix.repairDue('постпвь будильник на 7'), isNull);
  });
}
