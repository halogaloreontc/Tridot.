import 'weather_codes.dart';

/// «Что надеть»: записи каталога по ощущаемой температуре и осадкам
/// (ADR-030). Только id записей — текст даёт каталог ответов.
abstract final class WearAdvice {
  /// Основная запись и добавки: `weather.wear.cold`, `weather.wear.umbrella`…
  static List<String> of({
    required double? feels,
    int? precipChance,
    required int code,
    double? windMax,
  }) {
    final t = feels ?? 10;
    final base = t <= -15
        ? 'frost'
        : t <= -5
            ? 'winter'
            : t <= 5
                ? 'cold'
                : t <= 12
                    ? 'cool'
                    : t <= 18
                        ? 'mild'
                        : t <= 24
                            ? 'warm'
                            : 'hot';
    return <String>[
      'weather.wear.$base',
      if ((precipChance ?? 0) >= 50 ||
          WeatherCodes.isRain(code) ||
          WeatherCodes.isStorm(code))
        'weather.wear.umbrella',
      if (WeatherCodes.isSnow(code) || WeatherCodes.isHeavyRain(code))
        'weather.wear.boots',
      if ((windMax ?? 0) >= 10) 'weather.wear.wind',
    ];
  }
}
