import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/skills/weather/weather_service.dart';

import '../../support/fake_weather.dart';

/// Часы, которые можно переводить.
final class _Clock implements Clock {
  _Clock(this.value);

  DateTime value;

  @override
  DateTime now() => value;
}

const WeatherPlace kazan = WeatherPlace(
  name: 'Казань',
  latitude: 55.78874,
  longitude: 49.12214,
  countryCode: 'RU',
);

void main() {
  late _Clock clock;
  setUp(() => clock = _Clock(DateTime(2026, 11, 15, 9, 40)));

  WeatherService service(
    RecordingTransport transport, {
    WeatherSettings? settings,
    WeatherStore? store,
  }) {
    final s = WeatherService(transport: transport, store: store, clock: clock);
    return s;
  }

  Future<WeatherService> allowed(
    RecordingTransport transport, {
    WeatherPlace? place = kazan,
    WeatherStore? store,
  }) async {
    final s = service(transport, store: store);
    await s.update(
      WeatherSettings(
        source: WeatherSource.openMeteo,
        networkAllowedAt: clock.value,
        place: place,
      ),
    );
    return s;
  }

  group('без разрешения — ни одного запроса', () {
    test('источник не выбран', () async {
      final transport = RecordingTransport.kazan();
      final s = service(transport);
      final result = await s.forecast(placeQuery: 'Казани');
      expect(result.error, WeatherError.noConsent);
      await expectLater(
        s.search('Казань'),
        throwsA(isA<WeatherException>()),
      );
      expect(transport.requests, isEmpty);
    });

    test('Open-Meteo без «Разрешить»', () async {
      final transport = RecordingTransport.kazan();
      final s = service(transport);
      await s.update(
        const WeatherSettings(source: WeatherSource.openMeteo, place: kazan),
      );
      expect((await s.forecast()).error, WeatherError.noConsent);
      expect((await s.forecastFor(kazan)).error, WeatherError.noConsent);
      expect(transport.requests, isEmpty);
    });

    for (final source in <WeatherSource>[
      WeatherSource.link,
      WeatherSource.app,
    ]) {
      test('источник ${source.name}, даже с давним согласием', () async {
        final transport = RecordingTransport.kazan();
        final s = service(transport);
        await s.update(
          WeatherSettings(
            source: source,
            networkAllowedAt: clock.value,
            place: kazan,
            link: 'https://example.com/weather',
          ),
        );
        expect(
          (await s.forecast(placeQuery: 'Казани')).error,
          WeatherError.noConsent,
        );
        expect(transport.requests, isEmpty);
      });
    }

    test('отзыв согласия прекращает запросы', () async {
      final transport = RecordingTransport.kazan();
      final s = await allowed(transport);
      expect((await s.forecast()).forecast, isNotNull);
      await s.revokeNetwork();
      clock.value = clock.value.add(const Duration(hours: 1));
      expect((await s.forecast()).error, WeatherError.noConsent);
      expect(transport.requests, hasLength(1));
    });
  });

  group('кэш', () {
    test('свежий (до 30 минут) — без запроса', () async {
      final transport = RecordingTransport.kazan();
      final s = await allowed(transport);
      await s.forecast();
      clock.value = clock.value.add(const Duration(minutes: 29));
      final again = await s.forecast();
      expect(again.forecast, isNotNull);
      expect(again.stale, isFalse);
      expect(transport.requests, hasLength(1));
      clock.value = clock.value.add(const Duration(minutes: 2));
      await s.forecast();
      expect(transport.requests, hasLength(2));
    });

    test('«Обновить» идёт в сеть и при свежем кэше', () async {
      final transport = RecordingTransport.kazan();
      final s = await allowed(transport);
      await s.forecast();
      await s.forecastFor(kazan, refresh: true);
      expect(transport.requests, hasLength(2));
    });

    test('без связи — сохранённый до 12 часов с пометкой', () async {
      var offline = false;
      final transport = RecordingTransport(
        (Uri uri) => offline
            ? FakeReply.error(socketError)
            : FakeReply.fixture('forecast_kazan.json'),
      );
      final s = await allowed(transport);
      await s.forecast();
      offline = true;
      clock.value = clock.value.add(const Duration(hours: 11));
      final cached = await s.forecast();
      expect(cached.stale, isTrue);
      expect(cached.error, WeatherError.offline);
      expect(cached.forecast!.fetchedAt, DateTime(2026, 11, 15, 9, 40));
      clock.value = clock.value.add(const Duration(hours: 2));
      final none = await s.forecast();
      expect(none.forecast, isNull);
      expect(none.error, WeatherError.offline);
      expect(s.lastError, WeatherError.offline);
    });

    test('429 с кэшем — кэш с пометкой, без кэша — busy', () async {
      var busy = false;
      final transport = RecordingTransport(
        (Uri uri) => busy
            ? const FakeReply(429)
            : FakeReply.fixture('forecast_kazan.json'),
      );
      final s = await allowed(transport);
      busy = true;
      expect((await s.forecast()).error, WeatherError.busy);
      busy = false;
      await s.forecast();
      busy = true;
      clock.value = clock.value.add(const Duration(hours: 1));
      final cached = await s.forecast();
      expect(cached.stale, isTrue);
      expect(cached.error, WeatherError.busy);
    });

    test('найденный город запоминается: второй раз без поиска', () async {
      final transport = RecordingTransport.kazan();
      final s = await allowed(transport, place: null);
      final first = await s.forecast(placeQuery: 'Казани');
      expect(first.forecast!.place.name, 'Казань');
      expect(first.forecast!.place.countryCode, 'RU');
      final searches = transport.uris
          .where((Uri u) => u.host.startsWith('geocoding'))
          .map((Uri u) => u.queryParameters['name'])
          .toList();
      expect(searches, <String>['Казань']);
      clock.value = clock.value.add(const Duration(hours: 1));
      await s.forecast(placeQuery: 'казани');
      expect(
        transport.uris.where((Uri u) => u.host.startsWith('geocoding')),
        hasLength(1),
      );
    });

    test('«Москве» — не «Москверо»: перебор до точного совпадения', () async {
      final transport = RecordingTransport.kazan();
      final s = await allowed(transport, place: null);
      final result = await s.forecast(placeQuery: 'Москве');
      expect(result.forecast!.place.name, 'Москва');
      expect(result.forecast!.place.countryCode, 'RU');
    });

    test('не нашлось — notFound, не больше трёх запросов', () async {
      final transport = RecordingTransport.kazan();
      final s = await allowed(transport, place: null);
      final result = await s.forecast(placeQuery: 'Неведомске');
      expect(result.error, WeatherError.notFound);
      expect(result.query, 'Неведомске');
      expect(transport.requests.length, lessThanOrEqualTo(3));
    });

    test('без города — noPlace, без запроса', () async {
      final transport = RecordingTransport.kazan();
      final s = await allowed(transport, place: null);
      expect((await s.forecast()).missingPlace, isTrue);
      expect(transport.requests, isEmpty);
    });

    test('«Удалить данные погоды» стирает кэш и города', () async {
      final transport = RecordingTransport.kazan();
      final store = MemoryWeatherStore();
      final s = await allowed(transport, place: null, store: store);
      await s.forecast(placeQuery: 'Казани');
      expect(s.hasData, isTrue);
      expect(store.files.containsKey(WeatherService.cacheFile), isTrue);
      await s.clearData();
      expect(s.hasData, isFalse);
      expect(store.files.containsKey(WeatherService.cacheFile), isFalse);
      await s.forecast(placeQuery: 'Казани');
      expect(
        transport.uris.where((Uri u) => u.host.startsWith('geocoding')),
        hasLength(2),
      );
    });
  });

  group('на диске', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('weather_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('настройки и кэш переживают перезапуск', () async {
      final transport = RecordingTransport.kazan();
      final first = await allowed(
        transport,
        store: JsonWeatherStore(dir.path),
      );
      await first.update(
        first.settings.copyWith(link: 'https://example.com/w?city=1'),
      );
      await first.forecast();
      final second = WeatherService(
        transport: transport,
        store: JsonWeatherStore(dir.path),
        clock: clock,
      );
      await second.load();
      expect(second.settings.source, WeatherSource.openMeteo);
      expect(second.settings.place, kazan);
      expect(second.settings.link, 'https://example.com/w?city=1');
      expect(second.lastForecast?.place.name, 'Казань');
      await second.forecast();
      expect(transport.requests, hasLength(1));
      expect(File('${dir.path}/settings.json.tmp').existsSync(), isFalse);
    });

    test('битые файлы — настройки по умолчанию', () async {
      File('${dir.path}/settings.json').writeAsStringSync('{не json');
      File('${dir.path}/cache.json').writeAsStringSync('[1,2');
      final s = WeatherService(store: JsonWeatherStore(dir.path), clock: clock);
      await s.load();
      expect(s.settings.source, WeatherSource.none);
      expect(s.hasData, isFalse);
    });

    test('ссылка из файла проверяется заново', () async {
      File('${dir.path}/settings.json').writeAsStringSync(
        jsonEncode(<String, Object?>{
          'source': 'link',
          'link': 'javascript:alert(1)',
        }),
      );
      final s = WeatherService(store: JsonWeatherStore(dir.path), clock: clock);
      await s.load();
      expect(s.settings.source, WeatherSource.link);
      expect(s.settings.link, isNull);
    });
  });
}
