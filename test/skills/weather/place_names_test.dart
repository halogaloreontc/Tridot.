import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/skills/weather/place_names.dart';
import 'package:local_assistant/core/skills/weather/weather_models.dart';

import '../../support/fake_weather.dart';

List<WeatherPlace> _results(String fixture) => <WeatherPlace>[
      for (final item in (jsonDecode(weatherFixture(fixture))
          as Map<String, Object?>)['results']! as List<Object?>)
        WeatherPlace.fromJson(item)!,
    ];

void main() {
  group('candidates', () {
    test('Казани → Казань', () {
      expect(PlaceNames.candidates('Казани').first, 'Казань');
    });

    test('Москве → Москва первой', () {
      expect(PlaceNames.candidates('Москве').first, 'Москва');
    });

    test('Нижнем Новгороде → Нижний Новгород', () {
      expect(
        PlaceNames.candidates('Нижнем Новгороде').first,
        'Нижний Новгород',
      );
      expect(
        PlaceNames.candidates('нижнем новгороде').first,
        'Нижний Новгород',
      );
    });

    test('Ростове-на-Дону → Ростов-на-Дону', () {
      expect(PlaceNames.candidates('Ростове-на-Дону').first, 'Ростов-на-Дону');
    });

    test('Санкт-Петербурге → Санкт-Петербург', () {
      expect(
        PlaceNames.candidates('санкт-петербурге').first,
        'Санкт-Петербург',
      );
    });

    test('Сочи — как есть', () {
      expect(PlaceNames.candidates('Сочи'), <String>['Сочи']);
    });

    test('именительный — как есть', () {
      expect(PlaceNames.candidates('Москва'), <String>['Москва']);
    });

    test('не больше трёх вариантов, исходный — всегда среди них', () {
      for (final query in <String>[
        'Москве',
        'Нижнем Новгороде',
        'Великом Новгороде',
        'Ростове-на-Дону',
      ]) {
        final list = PlaceNames.candidates(query);
        expect(list.length, lessThanOrEqualTo(PlaceNames.maxCandidates));
        expect(list, contains(query));
      }
    });
  });

  group('pick', () {
    test('«Москве» не берёт «Москверо»', () {
      expect(
        PlaceNames.pick(_results('geocode_moskve.json'), 'Москве'),
        isNull,
      );
      expect(
        PlaceNames.pick(_results('geocode_moskve.json'), 'Москва'),
        isNull,
      );
    });

    test('точное совпадение, Россия раньше, затем население', () {
      final place = PlaceNames.pick(_results('geocode_moskva.json'), 'москва');
      expect(place!.countryCode, 'RU');
      expect(place.population, 10381222);
    });

    test('посёлок в стране сохранённого города не перевешивает Казань', () {
      final place = PlaceNames.pick(
        _results('geocode_kazan.json'),
        'Казань',
        preferCountry: 'BY',
      );
      expect(place!.countryCode, 'RU');
    });

    WeatherPlace city(String code, int population) => WeatherPlace(
          name: 'Париж',
          latitude: 0,
          longitude: 0,
          countryCode: code,
          population: population,
        );

    test('Париж — во Франции, а не посёлок в России', () {
      final results = <WeatherPlace>[city('RU', 1500), city('FR', 2138551)];
      expect(PlaceNames.pick(results, 'Париж')!.countryCode, 'FR');
      expect(
        PlaceNames.pick(results, 'Париж', preferCountry: 'RU')!.countryCode,
        'FR',
      );
    });

    test('среди сопоставимых городов страна сохранённого — первой', () {
      final results = <WeatherPlace>[city('US', 300000), city('BY', 60000)];
      expect(
        PlaceNames.pick(results, 'Париж', preferCountry: 'BY')!.countryCode,
        'BY',
      );
      expect(PlaceNames.pick(results, 'Париж')!.countryCode, 'US');
    });

    test('«Казанка» — не «Казань»', () {
      final results = _results('geocode_kazan.json');
      expect(PlaceNames.pick(results, 'Казанка')!.name, 'Казанка');
      expect(PlaceNames.pick(results, 'Казань')!.admin1, 'Татарстан');
    });

    test('«ё» и регистр не мешают', () {
      expect(PlaceNames.key('Орёл'), PlaceNames.key('орел'));
    });
  });
}
