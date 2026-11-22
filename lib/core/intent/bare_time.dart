/// Голое время — «7:30», «в 9», «нет, на 6:45», «к 6 вечера» — без
/// разговора о будильнике или задаче не команда (ADR-045, дополнение
/// web-accurate). Веб-уровни модели путали его с калькулятором: в
/// веб-помощнике такие фразы до модели не доходят. Тот же разбор —
/// `data.bare_time` в `tools/intent_model` (пробы считаются так же).
bool bareTimePhrase(String text) {
  final match = _bareTime.firstMatch(text.toLowerCase().trim());
  if (match == null) return false;
  // Голое число («15») — не время: нужен предлог, двоеточие или «утра».
  return match.namedGroup('pre') != null ||
      match.namedGroup('min') != null ||
      match.namedGroup('suf') != null;
}

final RegExp _bareTime = RegExp(
  r'^(?:(?:да|нет|ну|ок|давай|лучше)[,\s]+)?'
  r'(?<pre>(?:часам\s+к|около|после|в|к|на|до|с)\s+)?'
  r'(?:[01]?\d|2[0-3])(?<min>:[0-5]\d)?'
  r'(?:\s+(?<suf>утра|вечера|дня|ночи|часов|часа|ч))?[.!?]?$',
);
