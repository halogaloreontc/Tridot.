/// Город прогноза: то, что вернул поиск Open-Meteo, и то, что хранится в
/// настройках погоды (ADR-030). Координаты — как пришли; в запрос прогноза
/// они уходят округлёнными до двух знаков ([WeatherFormat.coordinate]).
final class WeatherPlace {
  const WeatherPlace({
    required this.name,
    required this.latitude,
    required this.longitude,
    this.id,
    this.admin1,
    this.country,
    this.countryCode,
    this.timezone,
    this.population,
  });

  final int? id;

  /// «Казань» — как в ответе поиска, в именительном падеже.
  final String name;

  /// Регион: «Татарстан».
  final String? admin1;

  /// Страна: «Россия».
  final String? country;

  /// Код страны: «RU».
  final String? countryCode;
  final double latitude;
  final double longitude;
  final String? timezone;
  final int? population;

  /// Ключ кэша прогноза: координаты, округлённые как в запросе.
  String get key =>
      '${WeatherFormat.coordinate(latitude)},${WeatherFormat.coordinate(longitude)}';

  /// «Татарстан, Россия» — без пустых частей.
  String get region => <String>[
        if (admin1 case final String a when a.isNotEmpty && a != name) a,
        if (country case final String c when c.isNotEmpty) c,
      ].join(', ');

  /// «Казань — Татарстан, Россия» для списка найденных городов.
  String get label => region.isEmpty ? name : '$name — $region';

  Map<String, Object?> toJson() => <String, Object?>{
        if (id != null) 'id': id,
        'name': name,
        'lat': latitude,
        'lon': longitude,
        if (admin1 != null) 'admin1': admin1,
        if (country != null) 'country': country,
        if (countryCode != null) 'country_code': countryCode,
        if (timezone != null) 'timezone': timezone,
        if (population != null) 'population': population,
      };

  /// Битая запись — `null`.
  static WeatherPlace? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final lat = json['lat'] ?? json['latitude'];
    final lon = json['lon'] ?? json['longitude'];
    if (name is! String || name.isEmpty || lat is! num || lon is! num) {
      return null;
    }
    if (lat.abs() > 90 || lon.abs() > 180) return null;
    String? text(String key) =>
        json[key] is String ? json[key] as String : null;
    final id = json['id'];
    final population = json['population'];
    return WeatherPlace(
      id: id is int ? id : null,
      name: name,
      latitude: lat.toDouble(),
      longitude: lon.toDouble(),
      admin1: text('admin1'),
      country: text('country'),
      countryCode: text('country_code'),
      timezone: text('timezone'),
      population: population is int ? population : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WeatherPlace &&
      other.name == name &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(name, latitude, longitude);
}

/// Погода сейчас. Время — местное время города, без смещения.
final class CurrentWeather {
  const CurrentWeather({
    required this.time,
    required this.code,
    this.temperature,
    this.feelsLike,
    this.precipitation,
    this.wind,
    this.gusts,
    this.isDay = true,
  });

  final DateTime time;
  final int code;
  final double? temperature;
  final double? feelsLike;

  /// Осадки за последние 15 минут, мм.
  final double? precipitation;

  /// Ветер, м/с.
  final double? wind;
  final double? gusts;
  final bool isDay;

  Map<String, Object?> toJson() => <String, Object?>{
        'time': WeatherFormat.localIso(time),
        'code': code,
        if (temperature != null) 'temp': temperature,
        if (feelsLike != null) 'feels': feelsLike,
        if (precipitation != null) 'precip': precipitation,
        if (wind != null) 'wind': wind,
        if (gusts != null) 'gusts': gusts,
        'day': isDay,
      };

  static CurrentWeather? fromJson(Object? json) {
    if (json is! Map) return null;
    final time = json['time'] is String
        ? DateTime.tryParse(json['time'] as String)
        : null;
    final code = json['code'];
    if (time == null || code is! int) return null;
    return CurrentWeather(
      time: time,
      code: code,
      temperature: _num(json['temp']),
      feelsLike: _num(json['feels']),
      precipitation: _num(json['precip']),
      wind: _num(json['wind']),
      gusts: _num(json['gusts']),
      isDay: json['day'] != false,
    );
  }
}

/// Прогноз на один день города.
final class DailyWeather {
  const DailyWeather({
    required this.date,
    required this.code,
    this.max,
    this.min,
    this.feelsMax,
    this.feelsMin,
    this.precipitation,
    this.chance,
    this.windMax,
  });

  /// Местная дата города (полночь).
  final DateTime date;
  final int code;
  final double? max;
  final double? min;
  final double? feelsMax;
  final double? feelsMin;

  /// Сумма осадков, мм.
  final double? precipitation;

  /// Наибольшая вероятность осадков, %.
  final int? chance;

  /// Наибольший ветер, м/с.
  final double? windMax;

  Map<String, Object?> toJson() => <String, Object?>{
        'date': WeatherFormat.isoDate(date),
        'code': code,
        if (max != null) 'max': max,
        if (min != null) 'min': min,
        if (feelsMax != null) 'feels_max': feelsMax,
        if (feelsMin != null) 'feels_min': feelsMin,
        if (precipitation != null) 'precip': precipitation,
        if (chance != null) 'chance': chance,
        if (windMax != null) 'wind': windMax,
      };

  static DailyWeather? fromJson(Object? json) {
    if (json is! Map) return null;
    final date = json['date'] is String
        ? DateTime.tryParse(json['date'] as String)
        : null;
    final code = json['code'];
    if (date == null || code is! int) return null;
    final chance = json['chance'];
    return DailyWeather(
      date: DateTime(date.year, date.month, date.day),
      code: code,
      max: _num(json['max']),
      min: _num(json['min']),
      feelsMax: _num(json['feels_max']),
      feelsMin: _num(json['feels_min']),
      precipitation: _num(json['precip']),
      chance: chance is num ? chance.round() : null,
      windMax: _num(json['wind']),
    );
  }
}

/// Прогноз для города: погода сейчас и по дням, и когда он получен.
final class Forecast {
  const Forecast({
    required this.place,
    required this.fetchedAt,
    required this.current,
    required this.days,
    this.utcOffset = 0,
  });

  final WeatherPlace place;

  /// Когда получен — время устройства.
  final DateTime fetchedAt;

  /// Смещение пояса города от UTC, секунды.
  final int utcOffset;
  final CurrentWeather current;
  final List<DailyWeather> days;

  /// «Сегодня» города: дата из [CurrentWeather.time].
  DateTime get today =>
      DateTime(current.time.year, current.time.month, current.time.day);

  /// День [offset] от «сегодня» города или `null`, если прогноза нет.
  DailyWeather? day(int offset) {
    final date = DateTime(today.year, today.month, today.day + offset);
    for (final day in days) {
      if (day.date == date) return day;
    }
    return null;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'place': place.toJson(),
        'fetched_at': fetchedAt.toIso8601String(),
        'utc_offset': utcOffset,
        'current': current.toJson(),
        'days': <Object?>[for (final day in days) day.toJson()],
      };

  static Forecast? fromJson(Object? json) {
    if (json is! Map) return null;
    final place = WeatherPlace.fromJson(json['place']);
    final fetched = json['fetched_at'] is String
        ? DateTime.tryParse(json['fetched_at'] as String)
        : null;
    final current = CurrentWeather.fromJson(json['current']);
    final days = json['days'];
    if (place == null || fetched == null || current == null || days is! List) {
      return null;
    }
    final offset = json['utc_offset'];
    return Forecast(
      place: place,
      fetchedAt: fetched,
      utcOffset: offset is int ? offset : 0,
      current: current,
      days: <DailyWeather>[
        for (final day in days)
          if (DailyWeather.fromJson(day) case final DailyWeather d) d,
      ],
    );
  }
}

double? _num(Object? value) => value is num ? value.toDouble() : null;

/// Подписи значений погоды: «+2°», «−3°», «3 м/с», «0,1 мм», «10%».
abstract final class WeatherFormat {
  /// Минус — U+2212, как в типографике.
  static const String minus = '−';

  /// Координата для запроса: два знака, около километра.
  static String coordinate(double value) => value.toStringAsFixed(2);

  /// «+2°», «−3°», «0°»; нет значения — «—».
  static String temp(double? value) {
    if (value == null) return '—';
    final rounded = value.round();
    if (rounded == 0) return '0°';
    return rounded > 0 ? '+$rounded°' : '$minus${-rounded}°';
  }

  /// «3 м/с».
  static String speed(double? value) =>
      value == null ? '—' : '${value.round()} м/с';

  /// «Ветер 3 м/с, порывы до 6 м/с» — порывы, только если они заметно
  /// сильнее ветра (на 4 м/с и больше).
  static String wind(double? wind, double? gusts) {
    final base = speed(wind);
    if (wind == null || gusts == null || gusts < wind + 4) return base;
    return '$base, порывы до ${gusts.round()} м/с';
  }

  /// «0,1 мм» — с запятой.
  static String millimetres(double? value) {
    if (value == null) return '—';
    final text = value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return '${text.replaceAll('.', ',')} мм';
  }

  /// «10%».
  static String percent(int? value) => value == null ? 'нет данных' : '$value%';

  /// «9:30».
  static String clock(DateTime time) =>
      '${time.hour}:${time.minute.toString().padLeft(2, '0')}';

  static String isoDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  /// Местное время без смещения: «2026-11-15T09:30».
  static String localIso(DateTime time) =>
      '${isoDate(time)}T${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';

  static const List<String> _weekdaysAcc = <String>[
    'в понедельник',
    'во вторник',
    'в среду',
    'в четверг',
    'в пятницу',
    'в субботу',
    'в воскресенье',
  ];

  static const List<String> _weekdaysShort = <String>[
    'Пн',
    'Вт',
    'Ср',
    'Чт',
    'Пт',
    'Сб',
    'Вс',
  ];

  static const List<String> _monthsGen = <String>[
    'января',
    'февраля',
    'марта',
    'апреля',
    'мая',
    'июня',
    'июля',
    'августа',
    'сентября',
    'октября',
    'ноября',
    'декабря',
  ];

  /// «сегодня», «завтра», «в субботу, 21 ноября» — день [offset] от
  /// [today].
  static String day(DateTime today, int offset) {
    if (offset == 0) return 'сегодня';
    if (offset == 1) return 'завтра';
    final date = DateTime(today.year, today.month, today.day + offset);
    return '${_weekdaysAcc[date.weekday - 1]}, ${date.day} '
        '${_monthsGen[date.month - 1]}';
  }

  /// «21 ноября».
  static String date(DateTime date) =>
      '${date.day} ${_monthsGen[date.month - 1]}';

  /// «Пн, 16» для строки дня в карточке.
  static String shortDay(DateTime date) =>
      '${_weekdaysShort[date.weekday - 1]}, ${date.day}';
}
