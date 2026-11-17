import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../connectors/http_transport.dart';
import '../../services/clock.dart';
import 'open_meteo_client.dart';
import 'place_names.dart';
import 'weather_models.dart';
import 'weather_settings.dart';

export 'open_meteo_client.dart' show WeatherError, WeatherException, OpenMeteo;
export 'weather_models.dart';
export 'weather_settings.dart';

/// Ответ на «какая погода»: прогноз (может быть из кэша) или ошибка.
final class WeatherResult {
  const WeatherResult._({
    this.forecast,
    this.error,
    this.stale = false,
    this.query,
    this.missingPlace = false,
  });

  /// Свежий прогноз.
  const WeatherResult.fresh(Forecast forecast) : this._(forecast: forecast);

  /// Сохранённый прогноз, потому что сейчас [error] (нет связи, сервис
  /// перегружен).
  const WeatherResult.cached(Forecast forecast, WeatherError error)
      : this._(forecast: forecast, error: error, stale: true);

  const WeatherResult.failed(WeatherError error, {String? query})
      : this._(error: error, query: query);

  /// Город не выбран и во фразе не назван.
  const WeatherResult.noPlace() : this._(missingPlace: true);

  final Forecast? forecast;
  final WeatherError? error;

  /// [forecast] — сохранённый, а не только что полученный.
  final bool stale;

  /// Что искали, если город не нашёлся.
  final String? query;
  final bool missingPlace;
}

/// Погода для навыка: настройки и прогноз с проверками (ADR-030). Через
/// этот интерфейс коннектор и тесты не знают о файлах и сети.
abstract interface class WeatherBackend {
  /// Настройки на сейчас (после [load]).
  WeatherSettings get settings;

  /// Прочитать настройки и кэш с диска; повторный вызов ничего не делает.
  Future<void> load();

  /// Прогноз для города [placeQuery] из фразы (как сказано: «Казани»)
  /// или для города из настроек. [refresh] — не брать свежий кэш.
  Future<WeatherResult> forecast({String? placeQuery, bool refresh = false});

  /// Последняя ошибка сети и когда она была; `null` — после успеха.
  WeatherError? get lastError;
  DateTime? get lastErrorAt;
}

/// Где лежат настройки и кэш погоды.
abstract interface class WeatherStore {
  Future<String?> read(String name);
  Future<void> write(String name, String text);
  Future<void> delete(String name);
}

/// Хранилище в памяти: тесты и корпус.
final class MemoryWeatherStore implements WeatherStore {
  final Map<String, String> files = <String, String>{};

  @override
  Future<String?> read(String name) async => files[name];

  @override
  Future<void> write(String name, String text) async => files[name] = text;

  @override
  Future<void> delete(String name) async => files.remove(name);
}

/// Файлы `<поддержка>/assistant/weather/settings.json` и `cache.json`;
/// запись через `.tmp`, как у настроек приложения.
final class JsonWeatherStore implements WeatherStore {
  JsonWeatherStore(this.directory);

  final String directory;
  Future<void> _writes = Future<void>.value();

  File _file(String name) => File('$directory${Platform.pathSeparator}$name');

  @override
  Future<String?> read(String name) async {
    try {
      final file = _file(name);
      if (!await file.exists()) return null;
      return await file.readAsString();
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(String name, String text) {
    final write = _writes.then((_) async {
      final file = _file(name);
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(file.path);
    });
    _writes = write.catchError((Object _) {});
    return write;
  }

  @override
  Future<void> delete(String name) {
    final delete = _writes.then((_) async {
      final file = _file(name);
      if (await file.exists()) await file.delete();
    });
    _writes = delete.catchError((Object _) {});
    return delete;
  }
}

/// Погода: настройки, разрешение, кэш и запросы к Open-Meteo (ADR-030).
///
/// Без разрешения или при источнике «ссылка» и «приложение» транспорт не
/// вызывается вовсе. Свежий прогноз (до [freshFor]) отдаётся без запроса;
/// без связи — сохранённый не старше [staleFor] с пометкой. Найденные
/// города запоминаются (до [maxPlaces]), чтобы «погода в Казани» второй
/// раз не искала город.
final class WeatherService implements WeatherBackend {
  WeatherService({
    HttpTransport? transport,
    WeatherStore? store,
    Clock clock = const SystemClock(),
  })  : _client =
            transport == null ? null : OpenMeteoClient(transport, clock: clock),
        _store = store ?? MemoryWeatherStore(),
        _clock = clock;

  /// Без сети и диска: корпус и тесты навыка.
  factory WeatherService.memory({
    HttpTransport? transport,
    Clock clock = const SystemClock(),
    WeatherSettings settings = const WeatherSettings(),
  }) =>
      WeatherService(
        transport: transport,
        store: MemoryWeatherStore(),
        clock: clock,
      )
        .._settings = settings
        .._loaded = true;

  final OpenMeteoClient? _client;
  final WeatherStore _store;
  final Clock _clock;

  static const String settingsFile = 'settings.json';
  static const String cacheFile = 'cache.json';

  /// Текущие данные у Open-Meteo обновляются раз в 15 минут.
  static const Duration freshFor = Duration(minutes: 30);

  /// Сколько показывать сохранённый прогноз без связи.
  static const Duration staleFor = Duration(hours: 12);

  static const int maxPlaces = 8;

  WeatherSettings _settings = const WeatherSettings();
  final Map<String, Forecast> _forecasts = <String, Forecast>{};
  final Map<String, WeatherPlace> _found = <String, WeatherPlace>{};
  bool _loaded = false;
  Future<void>? _loading;

  WeatherError? _lastError;
  DateTime? _lastErrorAt;

  @override
  WeatherSettings get settings => _settings;

  @override
  WeatherError? get lastError => _lastError;

  @override
  DateTime? get lastErrorAt => _lastErrorAt;

  /// Последний сохранённый прогноз для города из настроек.
  Forecast? get lastForecast {
    final place = _settings.place;
    if (place != null) return _forecasts[place.key];
    if (_forecasts.isEmpty) return null;
    final all = _forecasts.values.toList()
      ..sort((Forecast a, Forecast b) => b.fetchedAt.compareTo(a.fetchedAt));
    return all.first;
  }

  /// Есть ли что удалять кнопкой «Удалить данные погоды».
  bool get hasData => _forecasts.isNotEmpty || _found.isNotEmpty;

  @override
  Future<void> load() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _read();
  }

  Future<void> _read() async {
    try {
      final settings = await _store.read(settingsFile);
      if (settings != null) {
        _settings = WeatherSettings.fromJson(jsonDecode(settings));
      }
    } on Object {
      _settings = const WeatherSettings();
    }
    try {
      final cache = await _store.read(cacheFile);
      if (cache != null) _readCache(jsonDecode(cache));
    } on Object {
      _forecasts.clear();
      _found.clear();
    }
    _loaded = true;
  }

  void _readCache(Object? json) {
    if (json is! Map) return;
    final forecasts = json['forecasts'];
    if (forecasts is List) {
      for (final item in forecasts) {
        if (Forecast.fromJson(item) case final Forecast f) {
          _forecasts[f.place.key] = f;
        }
      }
    }
    final places = json['places'];
    if (places is Map) {
      places.forEach((Object? key, Object? value) {
        final place = WeatherPlace.fromJson(value);
        if (key is String && place != null) _found[key] = place;
      });
    }
  }

  Future<void> _saveSettings() =>
      _store.write(settingsFile, jsonEncode(_settings.toJson()));

  Future<void> _saveCache() => _store.write(
        cacheFile,
        jsonEncode(<String, Object?>{
          'format': 'tridot-weather-cache/1',
          'forecasts': <Object?>[
            for (final f in _forecasts.values) f.toJson(),
          ],
          'places': <String, Object?>{
            for (final entry in _found.entries) entry.key: entry.value.toJson(),
          },
        }),
      );

  /// Новые настройки — сразу на диск.
  Future<void> update(WeatherSettings settings) async {
    await load();
    _settings = settings;
    await _saveSettings();
  }

  /// «Разрешить»: запросы к Open-Meteo с этого момента.
  Future<void> allowNetwork() =>
      update(_settings.copyWith(networkAllowedAt: _clock.now()));

  /// «Отозвать разрешение»: запросов больше нет.
  Future<void> revokeNetwork() =>
      update(_settings.copyWith(clearNetwork: true));

  /// «Удалить данные погоды»: кэш прогнозов и найденные города.
  Future<void> clearData() async {
    await load();
    _forecasts.clear();
    _found.clear();
    _lastError = null;
    _lastErrorAt = null;
    await _store.delete(cacheFile);
  }

  bool get _mayAsk =>
      _client != null &&
      _settings.source == WeatherSource.openMeteo &&
      _settings.networkAllowed;

  /// Поиск города по кнопке «Найти»: до 10 вариантов. Без разрешения —
  /// [WeatherError.noConsent], без запроса.
  Future<List<WeatherPlace>> search(String name) async {
    await load();
    if (!_mayAsk) throw const WeatherException(WeatherError.noConsent);
    try {
      final results = await _client!.geocode(name);
      _ok();
      return results;
    } on WeatherException catch (e) {
      _fail(e.error);
      rethrow;
    }
  }

  @override
  Future<WeatherResult> forecast({
    String? placeQuery,
    bool refresh = false,
  }) async {
    await load();
    if (!_mayAsk) return const WeatherResult.failed(WeatherError.noConsent);
    WeatherPlace? place;
    if (placeQuery != null && placeQuery.trim().isNotEmpty) {
      final found = await _resolve(placeQuery);
      if (found.$2 != null) return found.$2!;
      place = found.$1;
    } else {
      place = _settings.place;
    }
    if (place == null) return const WeatherResult.noPlace();
    return _forecastFor(place, refresh: refresh);
  }

  /// Город из фразы: из запомненных или поиском по вариантам падежа.
  Future<(WeatherPlace?, WeatherResult?)> _resolve(String query) async {
    final key = PlaceNames.key(query);
    final known = _found[key];
    if (known != null) return (known, null);
    final candidates = PlaceNames.candidates(query);
    for (final candidate in candidates) {
      final List<WeatherPlace> results;
      try {
        results = await _client!.geocode(candidate);
      } on WeatherException catch (e) {
        _fail(e.error);
        // Без связи — сохранённый прогноз этого города, если он есть.
        final cached = _cachedNamed(candidates);
        if (cached != null && _usable(cached)) {
          return (null, WeatherResult.cached(cached, e.error));
        }
        return (null, WeatherResult.failed(e.error, query: query));
      }
      final place = PlaceNames.pick(
        results,
        candidate,
        preferCountry: _settings.place?.countryCode,
      );
      if (place != null) {
        _remember(key, place);
        return (place, null);
      }
    }
    return (null, WeatherResult.failed(WeatherError.notFound, query: query));
  }

  Forecast? _cachedNamed(List<String> names) {
    final keys = names.map(PlaceNames.key).toSet();
    for (final f in _forecasts.values) {
      if (keys.contains(PlaceNames.key(f.place.name))) return f;
    }
    return null;
  }

  void _remember(String key, WeatherPlace place) {
    _found.remove(key);
    _found[key] = place;
    while (_found.length > maxPlaces) {
      _found.remove(_found.keys.first);
    }
  }

  /// Прогноз для известного города [place] — кнопка «Обновить» карточки и
  /// «Проверить» в настройках. Без разрешения — без запроса.
  Future<WeatherResult> forecastFor(
    WeatherPlace place, {
    bool refresh = false,
  }) async {
    await load();
    if (!_mayAsk) return const WeatherResult.failed(WeatherError.noConsent);
    return _forecastFor(place, refresh: refresh);
  }

  bool _usable(Forecast f) => _clock.now().difference(f.fetchedAt) <= staleFor;

  Future<WeatherResult> _forecastFor(
    WeatherPlace place, {
    required bool refresh,
  }) async {
    final cached = _forecasts[place.key];
    if (!refresh &&
        cached != null &&
        _clock.now().difference(cached.fetchedAt) < freshFor &&
        !_clock.now().isBefore(cached.fetchedAt)) {
      return WeatherResult.fresh(cached);
    }
    try {
      final fresh = await _client!.forecast(place);
      _forecasts.remove(place.key);
      _forecasts[place.key] = fresh;
      while (_forecasts.length > maxPlaces) {
        _forecasts.remove(_forecasts.keys.first);
      }
      _ok();
      await _saveCache();
      return WeatherResult.fresh(fresh);
    } on WeatherException catch (e) {
      _fail(e.error);
      if ((e.error == WeatherError.offline || e.error == WeatherError.busy) &&
          cached != null &&
          _usable(cached)) {
        return WeatherResult.cached(cached, e.error);
      }
      return WeatherResult.failed(e.error);
    }
  }

  void _ok() {
    _lastError = null;
    _lastErrorAt = null;
  }

  void _fail(WeatherError error) {
    _lastError = error;
    _lastErrorAt = _clock.now();
  }
}
