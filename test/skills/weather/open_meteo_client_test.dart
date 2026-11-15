import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/skills/weather/open_meteo_client.dart';
import 'package:local_assistant/core/skills/weather/weather_models.dart';

import '../../support/fake_weather.dart';

const WeatherPlace kazan = WeatherPlace(
  name: 'Казань',
  latitude: 55.78874,
  longitude: 49.12214,
  countryCode: 'RU',
);

void main() {
  final clock = FixedClock(DateTime(2026, 11, 15, 9, 40));

  group('адреса', () {
    test('поиск: кириллица кодируется, параметры по списку', () async {
      final transport = RecordingTransport.kazan();
      final places = await OpenMeteoClient(transport).geocode('Казань');
      final uri = transport.uris.single;
      expect(uri.scheme, 'https');
      expect(uri.host, 'geocoding-api.open-meteo.com');
      expect(uri.path, '/v1/search');
      expect(uri.queryParameters, <String, String>{
        'name': 'Казань',
        'count': '10',
        'language': 'ru',
        'format': 'json',
      });
      // В адресе нет сырых байтов кириллицы: nginx их отклоняет.
      expect(uri.toString(), isNot(contains('Казань')));
      expect(uri.toString(), contains('%D0%9A'));
      expect(places, hasLength(3));
      expect(places.first.name, 'Казань');
      expect(places.first.countryCode, 'RU');
      expect(places.first.population, 1243500);
      expect(transport.requests.single.timeout, const Duration(seconds: 6));
    });

    test('прогноз: координаты — два знака, поля и единицы', () async {
      final transport = RecordingTransport.kazan();
      await OpenMeteoClient(transport, clock: clock).forecast(kazan);
      final request = transport.requests.single;
      final q = request.uri.queryParameters;
      expect(request.uri.host, 'api.open-meteo.com');
      expect(request.uri.path, '/v1/forecast');
      expect(q['latitude'], '55.79');
      expect(q['longitude'], '49.12');
      expect(q['timezone'], 'auto');
      expect(q['forecast_days'], '7');
      expect(q['wind_speed_unit'], 'ms');
      expect(q['current'], contains('apparent_temperature'));
      expect(q['daily'], contains('precipitation_probability_max'));
      expect(q.containsKey('hourly'), isFalse);
      expect(request.timeout, const Duration(seconds: 8));
      // Только эти поля — ни имени, ни города в запросе прогноза.
      expect(q.keys.toSet(), <String>{
        'latitude',
        'longitude',
        'current',
        'daily',
        'timezone',
        'forecast_days',
        'wind_speed_unit',
      });
    });

    test('отрицательные координаты округляются так же', () {
      final uri = OpenMeteoClient.forecastUri(
        const WeatherPlace(name: 'X', latitude: -33.86785, longitude: -0.004),
      );
      expect(uri.queryParameters['latitude'], '-33.87');
      expect(uri.queryParameters['longitude'], '-0.00');
    });

    test('только разрешённые адреса, только https', () {
      expect(OpenMeteo.allowedHosts, <String>{
        'geocoding-api.open-meteo.com',
        'api.open-meteo.com',
      });
      expect(OpenMeteoClient.geocodeUri('а').scheme, 'https');
      expect(OpenMeteoClient.forecastUri(kazan).scheme, 'https');
    });

    test('название из одного знака не ищется', () async {
      final transport = RecordingTransport.kazan();
      expect(await OpenMeteoClient(transport).geocode(' К '), isEmpty);
      expect(transport.requests, isEmpty);
    });
  });

  group('разбор', () {
    test('прогноз Казани: сейчас и 7 дней', () async {
      final transport = RecordingTransport.kazan();
      final f = await OpenMeteoClient(transport, clock: clock).forecast(kazan);
      expect(f.fetchedAt, clock.value);
      expect(f.utcOffset, 10800);
      expect(f.current.time, DateTime(2026, 11, 15, 9, 30));
      expect(f.current.temperature, 2.0);
      expect(f.current.feelsLike, -1.5);
      expect(f.current.code, 3);
      expect(f.current.wind, closeTo(2.62, 1e-9));
      expect(f.days, hasLength(7));
      expect(f.days[1].chance, 75);
      expect(f.days[1].code, 61);
      expect(f.today, DateTime(2026, 11, 15));
      expect(f.day(2)!.date, DateTime(2026, 11, 17));
    });

    test('null в массивах — нет значения; длины обрезаются', () async {
      final transport =
          RecordingTransport((_) => FakeReply.fixture('forecast_nulls.json'));
      final f = await OpenMeteoClient(transport, clock: clock).forecast(kazan);
      expect(f.current.temperature, isNull);
      expect(f.current.feelsLike, -1.5);
      expect(f.current.isDay, isFalse);
      // weather_code короче time: дней столько, сколько кодов.
      expect(f.days, hasLength(2));
      expect(f.days[0].min, isNull);
      expect(f.days[1].max, isNull);
      expect(f.days[1].chance, isNull);
    });

    test('без current или daily.time — failed', () {
      expect(
        () => OpenMeteoClient.parseForecast(
          <String, Object?>{'daily': <String, Object?>{}},
          kazan,
          clock.value,
        ),
        throwsA(_error(WeatherError.failed)),
      );
      expect(
        () => OpenMeteoClient.parseForecast(
          <String, Object?>{
            'current': <String, Object?>{'time': '2026-11-15T09:30'},
            'daily': <String, Object?>{'time': <Object?>[]},
          },
          kazan,
          clock.value,
        ),
        throwsA(_error(WeatherError.failed)),
      );
    });

    test('пустой поиск — пустой список', () async {
      final transport =
          RecordingTransport((_) => FakeReply.fixture('geocode_empty.json'));
      expect(await OpenMeteoClient(transport).geocode('Казани'), isEmpty);
    });
  });

  group('ошибки', () {
    Future<void> expectError(FakeReply reply, WeatherError error) async {
      final transport = RecordingTransport((_) => reply);
      await expectLater(
        OpenMeteoClient(transport, clock: clock).forecast(kazan),
        throwsA(_error(error)),
      );
      // Повторов нет.
      expect(transport.requests, hasLength(1));
    }

    test(
      '429 — busy',
      () => expectError(const FakeReply(429), WeatherError.busy),
    );
    test(
      '400 — failed',
      () => expectError(
        FakeReply.fixture('error_400.json', status: 400),
        WeatherError.failed,
      ),
    );
    test(
      '302 — failed',
      () => expectError(const FakeReply(302), WeatherError.failed),
    );
    test(
      '500 — failed',
      () => expectError(const FakeReply(500), WeatherError.failed),
    );
    test(
      'не JSON — failed',
      () => expectError(const FakeReply(200, '<html>'), WeatherError.failed),
    );
    test(
      'тайм-аут — offline',
      () => expectError(
        FakeReply.error(TimeoutException('t')),
        WeatherError.offline,
      ),
    );
    test(
      'нет сети — offline',
      () => expectError(
        const FakeReply.error(SocketException('x')),
        WeatherError.offline,
      ),
    );
    test(
      'TLS — offline',
      () => expectError(
        const FakeReply.error(HandshakeException('x')),
        WeatherError.offline,
      ),
    );
    test('текст исключения наружу не идёт', () {
      expect(
        const WeatherException(WeatherError.offline).toString(),
        'WeatherException(offline)',
      );
    });
  });
}

Matcher _error(WeatherError error) => isA<WeatherException>()
    .having((WeatherException e) => e.error, 'error', error);
