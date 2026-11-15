import 'weather_models.dart';

/// Откуда помощник берёт погоду (ADR-030).
enum WeatherSource {
  /// Не выбрано: помощник подсказывает, где настроить.
  none,

  /// Прогноз Open-Meteo в чате — сеть только после «Разрешить».
  openMeteo,

  /// Своя страница погоды: открывается в браузере, Tridot по ней не ходит.
  link,

  /// Приложение погоды на устройстве.
  app;

  static WeatherSource byName(Object? name) =>
      values.where((WeatherSource s) => s.name == name).firstOrNull ?? none;
}

/// Приложение погоды: имя пакета (Android) или id программы и подпись.
final class WeatherApp {
  const WeatherApp({required this.id, required this.label});

  /// `ru.yandex.weatherplugin`, `com.apple.weather`, `msnweather`.
  final String id;

  /// «Яндекс Погода».
  final String label;

  Map<String, Object?> toJson() => <String, Object?>{'id': id, 'label': label};

  static WeatherApp? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final label = json['label'];
    if (id is! String || id.isEmpty || id.length > 200) return null;
    return WeatherApp(
      id: id,
      label: label is String && label.isNotEmpty ? label : id,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WeatherApp && other.id == id && other.label == label;

  @override
  int get hashCode => Object.hash(id, label);
}

/// Настройки погоды: источник, разрешение сети, город, своя ссылка и
/// приложение. Живут только на устройстве (`weather/settings.json`).
final class WeatherSettings {
  const WeatherSettings({
    this.source = WeatherSource.none,
    this.networkAllowedAt,
    this.place,
    this.link,
    this.app,
  });

  final WeatherSource source;

  /// Когда человек разрешил запросы к Open-Meteo; `null` — не разрешал или
  /// отозвал.
  final DateTime? networkAllowedAt;

  /// Город по умолчанию.
  final WeatherPlace? place;

  /// Своя страница погоды (уже проверенная [WeatherLink.parse]).
  final String? link;

  final WeatherApp? app;

  bool get networkAllowed => networkAllowedAt != null;

  WeatherSettings copyWith({
    WeatherSource? source,
    DateTime? networkAllowedAt,
    bool clearNetwork = false,
    WeatherPlace? place,
    bool clearPlace = false,
    String? link,
    bool clearLink = false,
    WeatherApp? app,
    bool clearApp = false,
  }) =>
      WeatherSettings(
        source: source ?? this.source,
        networkAllowedAt:
            clearNetwork ? null : networkAllowedAt ?? this.networkAllowedAt,
        place: clearPlace ? null : place ?? this.place,
        link: clearLink ? null : link ?? this.link,
        app: clearApp ? null : app ?? this.app,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'format': 'tridot-weather/1',
        'source': source.name,
        if (networkAllowedAt != null)
          'network_allowed_at': networkAllowedAt!.toIso8601String(),
        if (place != null) 'place': place!.toJson(),
        if (link != null) 'link': link,
        if (app != null) 'app': app!.toJson(),
      };

  /// Битые поля пропускаются: ссылка проверяется заново.
  static WeatherSettings fromJson(Object? json) {
    if (json is! Map) return const WeatherSettings();
    final allowed = json['network_allowed_at'];
    final link = json['link'];
    return WeatherSettings(
      source: WeatherSource.byName(json['source']),
      networkAllowedAt: allowed is String ? DateTime.tryParse(allowed) : null,
      place: WeatherPlace.fromJson(json['place']),
      link: link is String ? WeatherLink.parse(link).url : null,
      app: WeatherApp.fromJson(json['app']),
    );
  }
}

/// Что не так со ссылкой.
enum WeatherLinkIssue {
  empty,
  notHttps,
  noHost,
  tooLong;

  /// Сообщение под полем.
  String get message => switch (this) {
        empty => 'Вставьте ссылку на страницу погоды',
        notHttps => 'Нужна ссылка, которая начинается с https://',
        noHost => 'В ссылке нет адреса сайта',
        tooLong => 'Ссылка слишком длинная',
      };
}

/// Результат проверки ссылки: [url] или [issue].
final class WeatherLinkResult {
  const WeatherLinkResult.ok(String this.url) : issue = null;

  const WeatherLinkResult.bad(WeatherLinkIssue this.issue) : url = null;

  final String? url;
  final WeatherLinkIssue? issue;

  bool get ok => url != null;
}

/// Проверка своей ссылки на страницу погоды.
abstract final class WeatherLink {
  static const int maxLength = 2048;

  static final RegExp _url = RegExp(r'[a-zA-Z][a-zA-Z0-9+.-]*://\S+');

  /// Ссылка из вставленного текста: «Погода в Казани https://…» →
  /// `https://…`. Только https, адрес сайта с точкой, без `user:pass@`,
  /// без пробелов и управляющих знаков, не длиннее [maxLength].
  static WeatherLinkResult parse(String input) {
    final text = input.trim();
    if (text.isEmpty) {
      return const WeatherLinkResult.bad(WeatherLinkIssue.empty);
    }
    final found = _url.firstMatch(text);
    var candidate = found == null ? text : found.group(0)!;
    // Знаки препинания и кавычки после ссылки в тексте — не её часть.
    while (candidate.isNotEmpty &&
        '.,;:!?)»"\''.contains(candidate[candidate.length - 1])) {
      candidate = candidate.substring(0, candidate.length - 1);
    }
    if (candidate.length > maxLength) {
      return const WeatherLinkResult.bad(WeatherLinkIssue.tooLong);
    }
    if (RegExp(r'[\s\x00-\x1F\x7F]').hasMatch(candidate)) {
      return const WeatherLinkResult.bad(WeatherLinkIssue.notHttps);
    }
    final uri = Uri.tryParse(candidate);
    if (uri == null || uri.scheme.toLowerCase() != 'https') {
      return const WeatherLinkResult.bad(WeatherLinkIssue.notHttps);
    }
    final host = uri.host;
    if (host.isEmpty ||
        !host.contains('.') ||
        host.startsWith('.') ||
        host.endsWith('.') ||
        uri.userInfo.isNotEmpty) {
      return const WeatherLinkResult.bad(WeatherLinkIssue.noHost);
    }
    // «HTTPS://…» — схема строчными: Android и macOS сравнивают её точно.
    return WeatherLinkResult.ok(
      'https${candidate.substring(uri.scheme.length)}',
    );
  }

  /// Ссылку можно открывать: https и всё остальное из [parse].
  static bool safe(String url) => parse(url).url == url;
}
