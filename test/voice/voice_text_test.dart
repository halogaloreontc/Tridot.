import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/spoken_time.dart';
import 'package:local_assistant/core/voice/voice_recognizer.dart';

void main() {
  group('VoiceText.clean (ADR-023)', () {
    test('обрывки распознавателя убираются', () {
      expect(
        VoiceText.clean(
          'можешь поставить зэд напоминание с утра чтобы я написал андрею',
        ),
        'можешь поставить напоминание с утра чтобы я написал андрею',
      );
      expect(VoiceText.clean('ээ напомни купить хлеб'), 'напомни купить хлеб');
      expect(VoiceText.clean('э напомни купить хлеб'), 'напомни купить хлеб');
    });

    test('«мм», «эм», «зет» — шум только в начале фразы', () {
      expect(VoiceText.clean('мм напомни купить хлеб'), 'напомни купить хлеб');
      expect(
        VoiceText.clean('купить сверло 6 мм'),
        'купить сверло 6 мм',
      );
      expect(
        VoiceText.clean('купить футболку размер эм'),
        'купить футболку размер эм',
      );
    });

    test('«ноль» после часа — минуты, повтором не считается', () {
      expect(
        VoiceText.clean('напомни в шесть ноль пять позвонить'),
        'напомни в 6:05 позвонить',
      );
      expect(
        VoiceText.clean('напомни в двадцать один ноль ноль позвонить'),
        'напомни в 21:00 позвонить',
      );
    });

    test('число месяца словами — цифрами', () {
      expect(
        VoiceText.clean('напомни пятнадцатого ноября оплатить кредит'),
        'напомни 15 ноября оплатить кредит',
      );
      expect(
        VoiceText.clean('двадцать пятого декабря поздравить'),
        '25 декабря поздравить',
      );
    });

    test('одиночное «э» не в начале — буква, остаётся', () {
      expect(VoiceText.clean('купить витамин э'), 'купить витамин э');
    });

    test('повтор слова подряд убирается', () {
      expect(
        VoiceText.clean('напомни напомни купить хлеб'),
        'напомни купить хлеб',
      );
    });

    test('время словами — цифрами', () {
      expect(
        VoiceText.clean('напомни завтра в восемь тридцать утра'),
        'напомни завтра в 8:30 утра',
      );
      expect(
        VoiceText.clean('в полдевятого выпить таблетку'),
        'в 8:30 выпить таблетку',
      );
      expect(
        VoiceText.clean('к десяти отвезти документы'),
        'к 10 отвезти документы',
      );
      expect(VoiceText.clean('в половине девятого'), 'в 8:30');
      expect(VoiceText.clean('без пятнадцати девять'), '8:45');
      expect(VoiceText.clean('в девять часов'), 'в 9 часов');
    });

    test('число словами перед единицей — цифрами', () {
      expect(
        VoiceText.clean('поставь таймер на пять минут'),
        'поставь таймер на 5 минут',
      );
      expect(VoiceText.clean('через одну минуту'), 'через 1 минуту');
      expect(
        VoiceText.clean('таймер на двадцать пять секунд'),
        'таймер на 25 секунд',
      );
      expect(VoiceText.clean('через два часа'), 'через 2 часа');
      expect(VoiceText.clean('три раза в день'), '3 раза в день');
    });

    test('число без единицы, порядковые и «полчаса» — как есть', () {
      expect(VoiceText.clean('купить один хлеб'), 'купить один хлеб');
      expect(VoiceText.clean('через полчаса'), 'через полчаса');
      expect(VoiceText.clean('пятая минута'), 'пятая минута');
      expect(VoiceText.clean('один раз'), '1 раз');
      expect(VoiceText.clean('три разбора'), 'три разбора');
    });

    test('точка в конце убирается, вопрос и восклицание остаются', () {
      expect(VoiceText.clean('Напомни купить хлеб.'), 'Напомни купить хлеб');
      expect(
        VoiceText.clean('Какая формула суммы?'),
        'Какая формула суммы?',
      );
      expect(VoiceText.clean('Готово!'), 'Готово!');
      expect(VoiceText.clean('и так далее...'), 'и так далее...');
    });

    test('текст в кавычках не трогается', () {
      expect(
        VoiceText.clean('добавь «зэд в девять» на завтра'),
        'добавь «зэд в девять» на завтра',
      );
    });

    test('normalizeRecognized чистит и ставит заглавную', () {
      expect(
        normalizeRecognized('  зэд напомни  в девять позвонить маме '),
        'Напомни в 9 позвонить маме',
      );
    });
  });

  group('SpokenTime', () {
    String digits(String text) =>
        SpokenTime.find(text).map((SpokenTimeMatch m) => m.digits).join(',');

    test('часы и минуты словами', () {
      expect(digits('в девять'), '9');
      expect(digits('к восьми утра'), '8');
      expect(digits('в двадцать два'), '22');
      expect(digits('в девять сорок пять'), '9:45');
      expect(digits('в час дня'), '1');
      expect(digits('полпервого'), '12:30');
      expect(digits('без четверти восемь'), '7:45');
    });

    test('«в час» без части суток и «через девять» — не время', () {
      expect(digits('в час пик'), '');
      expect(digits('через девять дней'), '');
      expect(digits('купить девять яиц'), '');
      expect(digits('таймер на двадцать пять секунд'), '');
      expect(digits('на пять минут'), '');
      expect(digits('до десяти дней'), '');
    });
  });
}
