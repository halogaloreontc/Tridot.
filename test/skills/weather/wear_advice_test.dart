import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/skills/weather/wear_advice.dart';

void main() {
  String base(double feels) =>
      WearAdvice.of(feels: feels, code: 0).single.split('.').last;

  test('границы диапазонов', () {
    expect(base(-15), 'frost');
    expect(base(-14.9), 'winter');
    expect(base(-5), 'winter');
    expect(base(-4.9), 'cold');
    expect(base(5), 'cold');
    expect(base(5.1), 'cool');
    expect(base(12), 'cool');
    expect(base(12.1), 'mild');
    expect(base(18), 'mild');
    expect(base(18.1), 'warm');
    expect(base(24), 'warm');
    expect(base(24.1), 'hot');
  });

  test('зонт: вероятность от 50% или дождь по коду', () {
    expect(
      WearAdvice.of(feels: 10, precipChance: 50, code: 3),
      contains('weather.wear.umbrella'),
    );
    expect(
      WearAdvice.of(feels: 10, precipChance: 49, code: 3),
      isNot(contains('weather.wear.umbrella')),
    );
    expect(
      WearAdvice.of(feels: 10, precipChance: 0, code: 61),
      contains('weather.wear.umbrella'),
    );
  });

  test('обувь: снег или сильный дождь', () {
    expect(WearAdvice.of(feels: -3, code: 73), contains('weather.wear.boots'));
    expect(WearAdvice.of(feels: 8, code: 82), contains('weather.wear.boots'));
    expect(
      WearAdvice.of(feels: 8, code: 61),
      isNot(contains('weather.wear.boots')),
    );
  });

  test('ветер от 10 м/с', () {
    expect(
      WearAdvice.of(feels: 8, code: 0, windMax: 10),
      contains('weather.wear.wind'),
    );
    expect(
      WearAdvice.of(feels: 8, code: 0, windMax: 9.9),
      isNot(contains('weather.wear.wind')),
    );
  });
}
