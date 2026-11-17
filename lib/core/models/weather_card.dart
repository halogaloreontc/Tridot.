import '../skills/weather/weather_models.dart';

/// Какая карточка погоды под ответом.
enum WeatherCardKind {
  /// Прогноз Open-Meteo.
  forecast,

  /// Открыта своя страница или приложение: «Открыть ещё раз».
  launcher,

  /// Источник не выбран: «Настроить».
  setup,
}

/// Карточка погоды под ответом (ADR-030): снимок прогноза или кнопка
/// «Открыть ещё раз». Пишется в историю чата (ключ сообщения `weather`);
/// адреса ссылки в ней нет — кнопка берёт его из настроек.
final class WeatherCard {
  const WeatherCard.forecast(
    Forecast this.forecast, {
    this.focusDay,
    this.stale = false,
  })  : kind = WeatherCardKind.forecast,
        label = null,
        app = false;

  const WeatherCard.launcher({required String this.label, this.app = false})
      : kind = WeatherCardKind.launcher,
        forecast = null,
        focusDay = null,
        stale = false;

  const WeatherCard.setup()
      : kind = WeatherCardKind.setup,
        forecast = null,
        focusDay = null,
        stale = false,
        label = null,
        app = false;

  final WeatherCardKind kind;
  final Forecast? forecast;

  /// День, о котором спросили (0 — сегодня); выделен в списке дней.
  final int? focusDay;

  /// Прогноз сохранённый: связи не было.
  final bool stale;

  /// «Страница погоды», «Приложение: Яндекс Погода».
  final String? label;

  /// Открывается приложение, а не страница.
  final bool app;

  /// Та же карточка с новым снимком (кнопка «Обновить»).
  WeatherCard refreshed(Forecast forecast, {bool stale = false}) =>
      WeatherCard.forecast(forecast, focusDay: focusDay, stale: stale);

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind.name,
        if (forecast != null) 'forecast': forecast!.toJson(),
        if (focusDay != null) 'focus_day': focusDay,
        if (stale) 'stale': true,
        if (label != null) 'label': label,
        if (app) 'app': true,
      };

  /// Битая карточка — `null`: сообщение читается без неё.
  static WeatherCard? fromJson(Object? json) {
    if (json is! Map) return null;
    switch (json['kind']) {
      case 'forecast':
        final forecast = Forecast.fromJson(json['forecast']);
        if (forecast == null) return null;
        final focus = json['focus_day'];
        return WeatherCard.forecast(
          forecast,
          focusDay: focus is int && focus >= 0 && focus < 16 ? focus : null,
          stale: json['stale'] == true,
        );
      case 'launcher':
        final label = json['label'];
        if (label is! String || label.isEmpty || label.length > 120) {
          return null;
        }
        return WeatherCard.launcher(label: label, app: json['app'] == true);
      case 'setup':
        return const WeatherCard.setup();
    }
    return null;
  }
}
