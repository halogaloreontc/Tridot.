import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/utterance.dart';
import 'package:local_assistant/core/skills/weather/weather_phrases.dart';

/// Понедельник, 2 ноября 2026, 16:30 — как в корпусе.
final DateTime now = DateTime(2026, 11, 2, 16, 30);

WeatherAsk? ask(String text) =>
    WeatherPhrases.parse(Utterance.analyze(text, now: now), now);

void main() {
  group('о погоде', () {
    final cases = <String, WeatherAskKind>{
      'погода': WeatherAskKind.now,
      'какая погода завтра': WeatherAskKind.day,
      'будет дождь?': WeatherAskKind.rain,
      'погода в Казани': WeatherAskKind.now,
      'что надеть': WeatherAskKind.wear,
      'во что одеться в субботу': WeatherAskKind.wear,
      'прогноз на неделю': WeatherAskKind.week,
      'на выходных будет снег?': WeatherAskKind.rain,
      'вчера был дождь?': WeatherAskKind.past,
      'открой погоду': WeatherAskKind.open,
      'погода через две недели': WeatherAskKind.range,
      'Какая сейчас температура?': WeatherAskKind.now,
      'кстати, завтра будет дождь': WeatherAskKind.rain,
    };
    cases.forEach((String text, WeatherAskKind kind) {
      test('«$text» → ${kind.name}', () {
        final result = ask(text);
        expect(result, isNotNull);
        expect(result!.kind, kind);
      });
    });
  });

  group('не о погоде', () {
    for (final text in <String>[
      'погоди',
      'погодите минутку',
      'погодя позвоню',
      'напомни взять зонт, если дождь',
      'добавь задачу купить зонт',
      'купить зонт',
      'почистить снег у гаража',
      'температура от -5 до 12 градусов, нормально?',
      'у меня температура',
      'погода в доме',
      'погода в семье',
      'прогноз продаж',
      'привет',
      'написать статью о погоде',
      'сдать отчёт о погоде завтра',
      'прочитать прогноз погоды для отчёта',
      'обсудить с Иваном погоду на складе',
      'подготовить отчёт о погоде для клиента',
      'найти статью про погоду в Казани',
      'статья о погоде',
      'перенеси задачу про зонт на завтра',
      'выполнил задачу про зонт',
    ]) {
      test('«$text»', () => expect(ask(text), isNull));
    }
  });

  group('день', () {
    test('завтра — +1', () {
      final a = ask('какая погода завтра')!;
      expect(a.dayOffset, 1);
      expect(a.date, DateTime(2026, 11, 3));
    });

    test('«в субботу» — день, а не город', () {
      final a = ask('во что одеться в субботу')!;
      expect(a.placeQuery, isNull);
      expect(a.date, DateTime(2026, 11, 7));
    });

    test('на выходных — с субботы, диапазон weekend', () {
      final a = ask('погода на выходных')!;
      expect(a.kind, WeatherAskKind.week);
      expect(a.range, WeatherRange.weekend);
      expect(a.dayOffset, 5);
    });
  });

  group('город', () {
    final cases = <String, String>{
      'погода в Казани': 'Казань',
      'погода в казани завтра': 'Казань',
      'Какая погода в Москве?': 'Москва',
      'погода в Нижнем Новгороде на выходных': 'Нижний Новгород',
      'погода в нижнем новгороде': 'Нижний Новгород',
      'погода в Ростове-на-Дону': 'Ростов-на-Дону',
      'погода послезавтра в Сочи': 'Сочи',
      'погода Казань': 'Казань',
    };
    cases.forEach((String text, String place) {
      test('«$text» → $place', () => expect(ask(text)!.placeName, place));
    });

    test('«на улице», «в городе» — не город', () {
      expect(ask('На улице дождь?')!.placeQuery, isNull);
      expect(ask('Какая сейчас температура в городе?')!.placeQuery, isNull);
    });

    test('город как сказан — для запроса и ответа', () {
      expect(ask('погода в Казани')!.placeQuery, 'Казани');
    });
  });

  group('день недели и выходные относительно сегодня', () {
    WeatherAsk? at(String text, DateTime when) =>
        WeatherPhrases.parse(Utterance.analyze(text, now: when), when);
    final saturday = DateTime(2026, 11, 7, 10);
    final sunday = DateTime(2026, 11, 8, 10);

    test('«погода в субботу» в субботу — сегодня', () {
      final a = at('погода в субботу', saturday)!;
      expect(a.dayOffset, 0);
      expect(a.kind, isNot(WeatherAskKind.range));
    });

    test('«погода в понедельник» в понедельник — сегодня', () {
      expect(at('погода в понедельник', now)!.dayOffset, 0);
    });

    test('«погода в следующую субботу» в субботу — через неделю', () {
      expect(at('погода в следующую субботу', saturday)!.dayOffset, 7);
    });

    test('«погода на выходных» в воскресенье — сегодня', () {
      final a = at('погода на выходных', sunday)!;
      expect(a.dayOffset, 0);
      expect(a.range, WeatherRange.weekend);
    });
  });

  test('«открыть погоду» и «расскажи о погоде» — всё ещё погода', () {
    expect(ask('открыть погоду')?.kind, WeatherAskKind.open);
    expect(ask('расскажи о погоде'), isNotNull);
  });
}
