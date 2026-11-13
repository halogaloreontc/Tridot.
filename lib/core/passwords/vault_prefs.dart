/// Защитные настройки навыка «Пароли» (раздел 9): живут только внутри
/// зашифрованного индекса (`prefs`), меняются в открытом хранилище, а
/// ослабление требует мастер-пароля. Подделка `settings.json` или чужая
/// копия их не меняет.
library;

/// Одна защитная настройка: ключ в `prefs`, значения и что считается
/// ослаблением.
final class VaultPref<T extends Object> {
  const VaultPref._(this.key, this.fallback, this.choices, this._weaker);

  final String key;

  /// Значение по умолчанию (раздел 9).
  final T fallback;

  /// Допустимые значения по порядку (для выбора на экране).
  final List<T> choices;

  final bool Function(T from, T to) _weaker;

  /// Значение из [prefs]: неизвестное или неверного типа — [fallback].
  T of(Map<String, Object?> prefs) {
    final value = prefs[key];
    return value is T && choices.contains(value) ? value : fallback;
  }

  /// Переход [from] → [to] ослабляет защиту.
  bool weakens(T from, T to) => _weaker(from, to);
}

bool _longer(int from, int to) => to > from;
bool _turnsOn(bool from, bool to) => to && !from;
bool _turnsOff(bool from, bool to) => from && !to;

abstract final class VaultPrefs {
  /// Автозапирание после простоя, мин.
  static const VaultPref<int> autolockMinutes =
      VaultPref<int>._('autolock_min', 5, <int>[1, 5, 15, 30], _longer);

  /// Мастер-пароль обязателен каждые N часов.
  static const VaultPref<int> masterEveryHours =
      VaultPref<int>._('master_every_h', 72, <int>[24, 72, 168], _longer);

  /// Сколько секунд виден показанный пароль.
  static const VaultPref<int> revealSeconds =
      VaultPref<int>._('reveal_s', 15, <int>[10, 15, 30], _longer);

  /// Через сколько секунд очищается буфер обмена.
  static const VaultPref<int> clipboardSeconds =
      VaultPref<int>._('clipboard_s', 30, <int>[15, 30, 60, 90], _longer);

  /// Подсказки можно хранить в истории (решение владельца №1: выкл.).
  static const VaultPref<bool> hintsInHistory = VaultPref<bool>._(
    'hints_in_history',
    false,
    <bool>[false, true],
    _turnsOn,
  );

  /// Логин в ответах целиком (решение владельца №2: выкл., маска).
  static const VaultPref<bool> loginInReplies = VaultPref<bool>._(
    'login_in_replies',
    false,
    <bool>[false, true],
    _turnsOn,
  );

  /// Переспрашивать мастер-пароль для важных записей (вкл.).
  static const VaultPref<bool> repromptImportant = VaultPref<bool>._(
    'reprompt_important',
    true,
    <bool>[true, false],
    _turnsOff,
  );

  /// Хронология паролей (ADR-015, выкл.): прежние пароли записи хранятся
  /// зашифрованными. Включение — ослабление D7, только с мастер-паролем.
  static const VaultPref<bool> passwordHistory = VaultPref<bool>._(
    'pw_history',
    false,
    <bool>[false, true],
    _turnsOn,
  );

  static const List<VaultPref<int>> numbers = <VaultPref<int>>[
    autolockMinutes,
    masterEveryHours,
    revealSeconds,
    clipboardSeconds,
  ];

  static const List<VaultPref<bool>> flags = <VaultPref<bool>>[
    hintsInHistory,
    loginInReplies,
    repromptImportant,
    passwordHistory,
  ];

  /// Неизвестный ключ или недопустимое значение в [changes] — ошибка
  /// вызывающего (`ArgumentError` без значения).
  static void check(Map<String, Object?> changes) {
    for (final MapEntry(:key, :value) in changes.entries) {
      final number = numbers.where((VaultPref<int> p) => p.key == key);
      final flag = flags.where((VaultPref<bool> p) => p.key == key);
      final ok = number.isNotEmpty
          ? value is int && number.first.choices.contains(value)
          : flag.isNotEmpty && value is bool;
      if (!ok) throw ArgumentError('недопустимая настройка');
    }
  }

  /// Ослабляет ли [changes] защиту относительно [current]: дольше
  /// автозапирание, показ или буфер, реже мастер-пароль, подсказки или
  /// логин в истории, выключен переспрос, включена хронология паролей.
  static bool weakens(
    Map<String, Object?> current,
    Map<String, Object?> changes,
  ) {
    for (final pref in numbers) {
      final next = changes[pref.key];
      if (next is int && pref.weakens(pref.of(current), next)) return true;
    }
    for (final pref in flags) {
      final next = changes[pref.key];
      if (next is bool && pref.weakens(pref.of(current), next)) return true;
    }
    return false;
  }
}
