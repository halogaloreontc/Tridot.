/// Значок погоды для карточки: интерфейс выбирает по нему иконку.
enum WeatherGlyph { sun, cloud, fog, rain, snow, storm }

/// Коды погоды WMO из ответа Open-Meteo (`weather_code`): подпись неба,
/// вид осадков и значок (ADR-030).
///
/// 0–3 — от ясно до пасмурно; 45, 48 — туман; 51–57 — морось (56, 57 —
/// ледяная); 61–67 — дождь (66, 67 — ледяной); 71–77 — снег (77 —
/// снежная крупа); 80–82 — ливень; 85, 86 — снегопад; 95 — гроза; 96, 99 —
/// гроза с градом.
abstract final class WeatherCodes {
  /// Подпись неба для `{sky}`: «ясно», «пасмурно», «дождь».
  static String sky(int code) => switch (code) {
        0 => 'ясно',
        1 => 'малооблачно',
        2 => 'облачно',
        3 => 'пасмурно',
        45 || 48 => 'туман',
        51 || 53 || 55 => 'морось',
        56 || 57 || 66 || 67 => 'ледяной дождь',
        61 || 63 || 65 => 'дождь',
        80 || 81 || 82 => 'ливень',
        71 || 73 || 75 || 77 => 'снег',
        85 || 86 => 'снегопад',
        95 => 'гроза',
        96 || 99 => 'гроза с градом',
        _ => 'облачно',
      };

  /// Вид осадков для `{kind}` («будет дождь»); `null` — осадков нет.
  static String? kind(int code) {
    if (isStorm(code)) return 'гроза';
    if (code == 56 || code == 57 || code == 66 || code == 67) {
      return 'ледяной дождь';
    }
    if (isSnow(code)) return 'снег';
    if (isRain(code)) return 'дождь';
    return null;
  }

  /// Дождь, морось или ливень (и ледяной).
  static bool isRain(int code) =>
      (code >= 51 && code <= 67) || (code >= 80 && code <= 82);

  /// Снег, снежная крупа или снегопад.
  static bool isSnow(int code) =>
      (code >= 71 && code <= 77) || code == 85 || code == 86;

  /// Гроза (с градом или без).
  static bool isStorm(int code) => code == 95 || code == 96 || code == 99;

  /// Сильный дождь или ливень: нужна непромокаемая обувь.
  static bool isHeavyRain(int code) =>
      code == 65 || code == 67 || code == 81 || code == 82 || isStorm(code);

  /// Осадки любого вида.
  static bool isWet(int code) => isRain(code) || isSnow(code) || isStorm(code);

  static WeatherGlyph glyph(int code) {
    if (code == 0 || code == 1) return WeatherGlyph.sun;
    if (code == 45 || code == 48) return WeatherGlyph.fog;
    if (isStorm(code)) return WeatherGlyph.storm;
    if (isSnow(code)) return WeatherGlyph.snow;
    if (isRain(code)) return WeatherGlyph.rain;
    return WeatherGlyph.cloud;
  }
}
