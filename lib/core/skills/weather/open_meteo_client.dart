import 'dart:convert';

import '../../connectors/http_transport.dart';
import '../../services/clock.dart';
import 'weather_models.dart';

/// Что пошло не так с погодой — без текста исключений и адресов (ADR-030).
enum WeatherError {
  /// Нет связи: тайм-аут, обрыв, ошибка TLS.
  offline,

  /// Сервис перегружен (429).
  busy,

  /// Сервис ответил ошибкой или не тем (400, 3xx, 5xx, не JSON).
  failed,

  /// Город не найден.
  notFound,

  /// Прогноз Open-Meteo не разрешён.
  noConsent,
}

/// Ошибка погоды для того, кто спрашивал.
final class WeatherException implements Exception {
  const WeatherException(this.error);

  final WeatherError error;

  @override
  String toString() => 'WeatherException(${error.name})';
}

/// Адреса и подписи Open-Meteo.
abstract final class OpenMeteo {
  /// Единственные адреса, куда ходит погода; только https.
  static const Set<String> allowedHosts = <String>{
    geocodingHost,
    forecastHost,
  };

  static const String geocodingHost = 'geocoding-api.open-meteo.com';
  static const String forecastHost = 'api.open-meteo.com';

  /// Подпись под данными (лицензия CC BY 4.0 требует указать источник).
  static const String attribution = 'Open-Meteo.com · CC BY 4.0';
  static const String siteUrl = 'https://open-meteo.com/';
  static const String licenseUrl =
      'https://creativecommons.org/licenses/by/4.0/';

  static const String currentFields = 'temperature_2m,apparent_temperature,'
      'precipitation,weather_code,wind_speed_10m,wind_gusts_10m,is_day';

  static const String dailyFields = 'weather_code,temperature_2m_max,'
      'temperature_2m_min,apparent_temperature_max,apparent_temperature_min,'
      'precipitation_sum,precipitation_probability_max,wind_speed_10m_max';

  /// Дней прогноза.
  static const int days = 7;
}

/// Клиент Open-Meteo поверх [HttpTransport] (ADR-030): поиск города и
/// прогноз. Повторов нет — сервис бесплатный, лишняя нагрузка ни к чему.
/// Разрешение и кэш проверяет `WeatherService`; клиент только ходит.
final class OpenMeteoClient {
  OpenMeteoClient(this._transport, {Clock clock = const SystemClock()})
      : _clock = clock;

  final HttpTransport _transport;
  final Clock _clock;

  static const Duration geocodeTimeout = Duration(seconds: 6);
  static const Duration forecastTimeout = Duration(seconds: 8);

  /// Адрес поиска города [name]: кириллица кодируется.
  static Uri geocodeUri(String name) =>
      Uri.https(OpenMeteo.geocodingHost, '/v1/search', <String, String>{
        'name': name,
        'count': '10',
        'language': 'ru',
        'format': 'json',
      });

  /// Адрес прогноза для [place]: координаты — два знака.
  static Uri forecastUri(WeatherPlace place) =>
      Uri.https(OpenMeteo.forecastHost, '/v1/forecast', <String, String>{
        'latitude': WeatherFormat.coordinate(place.latitude),
        'longitude': WeatherFormat.coordinate(place.longitude),
        'current': OpenMeteo.currentFields,
        'daily': OpenMeteo.dailyFields,
        'timezone': 'auto',
        'forecast_days': '${OpenMeteo.days}',
        'wind_speed_unit': 'ms',
      });

  /// До 10 городов с названием [name]; пусто — не нашлось.
  Future<List<WeatherPlace>> geocode(String name) async {
    final query = name.trim();
    if (query.length < 2) return const <WeatherPlace>[];
    final json = await _get(geocodeUri(query), geocodeTimeout);
    final results = json['results'];
    if (results == null) return const <WeatherPlace>[];
    if (results is! List) throw const WeatherException(WeatherError.failed);
    return <WeatherPlace>[
      for (final item in results)
        if (WeatherPlace.fromJson(item) case final WeatherPlace place) place,
    ];
  }

  /// Прогноз для [place] на [OpenMeteo.days] дней.
  Future<Forecast> forecast(WeatherPlace place) async {
    final json = await _get(forecastUri(place), forecastTimeout);
    return parseForecast(json, place, _clock.now());
  }

  Future<Map<String, Object?>> _get(Uri uri, Duration timeout) async {
    if (uri.scheme != 'https' || !OpenMeteo.allowedHosts.contains(uri.host)) {
      throw const WeatherException(WeatherError.failed);
    }
    final HttpResponseData response;
    try {
      response = await _transport.send(
        HttpRequestData(
          method: 'GET',
          uri: uri,
          headers: const <String, String>{'accept': 'application/json'},
          timeout: timeout,
        ),
      );
    } on Object {
      // Тайм-аут, обрыв, TLS, слишком большой ответ: для человека это
      // «нет связи». Текст исключения никуда не идёт.
      throw const WeatherException(WeatherError.offline);
    }
    if (response.statusCode == 429) {
      throw const WeatherException(WeatherError.busy);
    }
    if (!response.isSuccess) {
      throw const WeatherException(WeatherError.failed);
    }
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, Object?>) return decoded;
    } on FormatException {
      // Ниже — та же ошибка.
    }
    throw const WeatherException(WeatherError.failed);
  }

  /// Разбор ответа прогноза: `null` в массивах — «нет значения», массивы
  /// разной длины обрезаются до общей. Без `current` или `daily.time` —
  /// [WeatherError.failed].
  static Forecast parseForecast(
    Map<String, Object?> json,
    WeatherPlace place,
    DateTime fetchedAt,
  ) {
    const fail = WeatherException(WeatherError.failed);
    final current = json['current'];
    final daily = json['daily'];
    if (current is! Map || daily is! Map) throw fail;
    final time = current['time'] is String
        ? DateTime.tryParse(current['time'] as String)
        : null;
    final code = current['weather_code'];
    if (time == null) throw fail;
    final times = daily['time'];
    if (times is! List || times.isEmpty) throw fail;
    List<Object?> column(String key) {
      final value = daily[key];
      return value is List ? value : const <Object?>[];
    }

    final codes = column('weather_code');
    final max = column('temperature_2m_max');
    final min = column('temperature_2m_min');
    final feelsMax = column('apparent_temperature_max');
    final feelsMin = column('apparent_temperature_min');
    final sums = column('precipitation_sum');
    final chances = column('precipitation_probability_max');
    final winds = column('wind_speed_10m_max');
    // Обязательные столбцы задают общую длину; необязательные короче —
    // просто нет значений.
    var length = times.length;
    if (codes.length < length) length = codes.length;
    Object? at(List<Object?> list, int i) => i < list.length ? list[i] : null;
    double? number(Object? value) => value is num ? value.toDouble() : null;
    final days = <DailyWeather>[];
    for (var i = 0; i < length; i++) {
      final dateText = times[i];
      final date = dateText is String ? DateTime.tryParse(dateText) : null;
      final dayCode = codes[i];
      if (date == null || dayCode is! num) continue;
      final chance = at(chances, i);
      days.add(
        DailyWeather(
          date: DateTime(date.year, date.month, date.day),
          code: dayCode.round(),
          max: number(at(max, i)),
          min: number(at(min, i)),
          feelsMax: number(at(feelsMax, i)),
          feelsMin: number(at(feelsMin, i)),
          precipitation: number(at(sums, i)),
          chance: chance is num ? chance.round() : null,
          windMax: number(at(winds, i)),
        ),
      );
    }
    if (days.isEmpty) throw fail;
    final offset = json['utc_offset_seconds'];
    return Forecast(
      place: place,
      fetchedAt: fetchedAt,
      utcOffset: offset is num ? offset.round() : 0,
      current: CurrentWeather(
        time: time,
        code: code is num ? code.round() : days.first.code,
        temperature: number(current['temperature_2m']),
        feelsLike: number(current['apparent_temperature']),
        precipitation: number(current['precipitation']),
        wind: number(current['wind_speed_10m']),
        gusts: number(current['wind_gusts_10m']),
        isDay: current['is_day'] != 0,
      ),
      days: days,
    );
  }
}
