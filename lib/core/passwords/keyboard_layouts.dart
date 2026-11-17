/// Раскладки, транслит и l33t для оценки надёжности, `HintGuard` и
/// ответов «почти» (разделы 3.4, 5.3, 5.5). Работает с кодовыми точками
/// (`List<int>`), а не со строками: из пароля строки не создаются.
abstract final class KeyboardLayouts {
  static const String _latin =
      'qwertyuiop[]asdfghjkl;\'zxcvbnm,.`QWERTYUIOP{}ASDFGHJKL:"ZXCVBNM<>~';
  static const String _cyrillic =
      'йцукенгшщзхъфывапролджэячсмитьбюёЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮЁ';

  static final Map<int, int> _toCyrillic = _pairs(_latin, _cyrillic);
  static final Map<int, int> _toLatin = _pairs(_cyrillic, _latin);

  static Map<int, int> _pairs(String from, String to) {
    final a = from.runes.toList();
    final b = to.runes.toList();
    assert(a.length == b.length, 'таблица раскладок');
    return <int, int>{for (var i = 0; i < a.length; i++) a[i]: b[i]};
  }

  /// Та же клавиша в другой раскладке (ЙЦУКЕН↔QWERTY); иначе как есть.
  static int swap(int rune) => _toCyrillic[rune] ?? _toLatin[rune] ?? rune;

  /// Набранное в английской раскладке как русское: `ghbdtn` → `привет`.
  static List<int> latinToCyrillic(List<int> runes) =>
      <int>[for (final r in runes) _toCyrillic[r] ?? r];

  /// Русское как набранное в английской раскладке: `привет` → `ghbdtn`.
  static List<int> cyrillicToLatin(List<int> runes) =>
      <int>[for (final r in runes) _toLatin[r] ?? r];

  static bool isLatinLetter(int r) =>
      (r >= 0x61 && r <= 0x7A) || (r >= 0x41 && r <= 0x5A);

  static bool isCyrillic(int r) =>
      (r >= 0x410 && r <= 0x44F) || r == 0x401 || r == 0x451;

  static bool isDigit(int r) => r >= 0x30 && r <= 0x39;

  static bool isUpper(int r) =>
      (r >= 0x41 && r <= 0x5A) || (r >= 0x410 && r <= 0x42F) || r == 0x401;

  static bool isLower(int r) =>
      (r >= 0x61 && r <= 0x7A) || (r >= 0x430 && r <= 0x44F) || r == 0x451;

  static bool isLetter(int r) => isUpper(r) || isLower(r);

  /// Нижний регистр латиницы и кириллицы (остальное как есть).
  static int lower(int r) {
    if (r >= 0x41 && r <= 0x5A) return r + 0x20;
    if (r >= 0x410 && r <= 0x42F) return r + 0x20;
    if (r == 0x401) return 0x451;
    return r;
  }

  /// Верхний регистр латиницы и кириллицы.
  static int upper(int r) {
    if (r >= 0x61 && r <= 0x7A) return r - 0x20;
    if (r >= 0x430 && r <= 0x44F) return r - 0x20;
    if (r == 0x451) return 0x401;
    return r;
  }

  /// Другой регистр (Caps Lock).
  static int flipCase(int r) => isUpper(r) ? lower(r) : upper(r);

  static List<int> lowerAll(List<int> runes) =>
      <int>[for (final r in runes) lower(r)];

  /// Транслит кириллицы латиницей (как пишут в паролях и подсказках):
  /// `собака` → `sobaka`. [alt] — второй частый вариант (`ж` → `j`,
  /// `х` → `h`, `ц` → `c`, `й` → `j`, `я` → `ja`).
  static List<int> translit(List<int> runes, {bool alt = false}) {
    final out = <int>[];
    for (final r in runes) {
      final l = lower(r);
      final mapped = (alt ? _translitAlt[l] : null) ?? _translit[l];
      if (mapped == null) {
        out.add(l);
      } else {
        out.addAll(mapped.codeUnits);
      }
    }
    return out;
  }

  static const Map<int, String> _translit = <int, String>{
    0x430: 'a', 0x431: 'b', 0x432: 'v', 0x433: 'g', 0x434: 'd', //
    0x435: 'e', 0x451: 'e', 0x436: 'zh', 0x437: 'z', 0x438: 'i',
    0x439: 'y', 0x43A: 'k', 0x43B: 'l', 0x43C: 'm', 0x43D: 'n',
    0x43E: 'o', 0x43F: 'p', 0x440: 'r', 0x441: 's', 0x442: 't',
    0x443: 'u', 0x444: 'f', 0x445: 'kh', 0x446: 'ts', 0x447: 'ch',
    0x448: 'sh', 0x449: 'sch', 0x44A: '', 0x44B: 'y', 0x44C: '',
    0x44D: 'e', 0x44E: 'yu', 0x44F: 'ya',
  };

  static const Map<int, String> _translitAlt = <int, String>{
    0x436: 'j',
    0x445: 'h',
    0x446: 'c',
    0x439: 'j',
    0x44F: 'ja',
    0x44E: 'ju',
    0x451: 'yo',
    0x449: 'shch',
    0x44C: "'",
  };

  /// l33t: символ → буква. `1` и `|` дают «i» (в [alt] — «l»).
  static List<int> unleet(List<int> runes, {bool alt = false}) => <int>[
        for (final r in runes)
          (alt ? _leetAlt[r] : null) ?? _leet[r] ?? lower(r),
      ];

  /// [rune] — l33t-замена буквы (`4`, `@`, `3`, `1`, `!`, `|`, `0`, `$`,
  /// `5`, `7`, `+`, `8`, `9`).
  static bool isLeet(int rune) => _leet.containsKey(rune);

  /// Есть ли в [runes] l33t-замены.
  static int leetCount(List<int> runes) =>
      runes.where((int r) => _leet.containsKey(r)).length;

  static final Map<int, int> _leet = <int, int>{
    0x34: 0x61, // 4 → a
    0x40: 0x61, // @ → a
    0x33: 0x65, // 3 → e
    0x31: 0x69, // 1 → i
    0x21: 0x69, // ! → i
    0x7C: 0x69, // | → i
    0x30: 0x6F, // 0 → o
    0x24: 0x73, // $ → s
    0x35: 0x73, // 5 → s
    0x37: 0x74, // 7 → t
    0x2B: 0x74, // + → t
    0x38: 0x62, // 8 → b
    0x39: 0x67, // 9 → g
  };

  static final Map<int, int> _leetAlt = <int, int>{
    0x31: 0x6C, // 1 → l
    0x7C: 0x6C, // | → l
    0x39: 0x71, // 9 → q
  };

  /// Ряды клавиатуры (нижний регистр): QWERTY и ЙЦУКЕН.
  static const List<String> rows = <String>[
    '`1234567890-=',
    'qwertyuiop[]\\',
    "asdfghjkl;'",
    'zxcvbnm,./',
    'йцукенгшщзхъ',
    'фывапролджэ',
    'ячсмитьбю.',
  ];

  /// Столбцы QWERTY (`qaz`, `wsx`, `1qaz`).
  static const List<String> columns = <String>[
    '1qaz',
    '2wsx',
    '3edc',
    '4rfv',
    '5tgb',
    '6yhn',
    '7ujm',
    '8ik,',
    '9ol.',
    '0p;/',
  ];

  /// Верхний регистр (Shift) знаков → клавиша: QWERTY (`!` → `1`,
  /// `{` → `[`, `?` → `/`) и ЙЦУКЕН (`"` → `2`, `№` → `3`, `;` → `4`,
  /// `:` → `6`, `?` → `7`, `,` → `.`). Знак может стоять на нескольких
  /// клавишах (раскладки разные) — тогда у него все их позиции.
  static const Map<String, String> shifted = <String, String>{
    '~': '`', '!': '1', '@': '2', '#': '3', r'$': '4', '%': '5', //
    '^': '6', '&': '7', '*': '8', '(': '9', ')': '0', '_': '-',
    '+': '=', '{': '[', '}': ']', '|': '\\', ':': ';', '"': "'",
    '<': ',', '>': '.', '?': '/',
  };

  static const Map<String, String> _shiftedRu = <String, String>{
    '"': '2',
    '№': '3',
    ';': '4',
    ':': '6',
    '?': '7',
    ',': '.',
  };

  /// Клавиша символа [rune] без Shift и регистра: `Q` → `q`, `!` → `1`,
  /// `{` → `[`; [russian] — знаки ЙЦУКЕН (`"` → `2`, `№` → `3`, `;` → `4`,
  /// `:` → `6`, `?` → `7`) раньше QWERTY. Кириллица остаётся кириллицей.
  static int unshift(int rune, {bool russian = false}) {
    final l = lower(rune);
    final base = (russian ? _unshiftRu[l] : null) ?? _unshiftEn[l];
    return base ?? l;
  }

  static final Map<int, int> _unshiftEn = <int, int>{
    for (final MapEntry(:key, :value) in shifted.entries)
      key.runes.first: value.runes.first,
  };

  static final Map<int, int> _unshiftRu = <int, int>{
    for (final MapEntry(:key, :value) in _shiftedRu.entries)
      if (key != ',') key.runes.first: value.runes.first,
  };

  /// Знак набран с Shift ([shifted]).
  static bool isShifted(int rune) => _shiftedRunes.contains(rune);

  static final Set<int> _shiftedRunes = <int>{
    for (final k in <String>[...shifted.keys, ..._shiftedRu.keys])
      k.runes.first,
  };

  /// (линия, позиция) каждой клавиши для поиска «соседних»; знаки с Shift
  /// — на позициях своих клавиш (`!@#$` — тот же ряд, что `1234`).
  static final Map<int, List<(int, int)>> keyPositions = () {
    final map = <int, List<(int, int)>>{};
    final lines = <String>[...rows, ...columns];
    for (var line = 0; line < lines.length; line++) {
      final runes = lines[line].runes.toList();
      for (var i = 0; i < runes.length; i++) {
        (map[runes[i]] ??= <(int, int)>[]).add((line, i));
      }
    }
    for (final table in <Map<String, String>>[shifted, _shiftedRu]) {
      for (final MapEntry(:key, :value) in table.entries) {
        final base = map[value.runes.first];
        if (base == null) continue;
        final list = map[key.runes.first] ??= <(int, int)>[];
        for (final p in base) {
          if (!list.contains(p)) list.add(p);
        }
      }
    }
    return map;
  }();

  /// Сколько всего клавиш в рядах и столбцах (для оценки перебора).
  static final int keyCount =
      <String>[...rows, ...columns].fold(0, (int n, String s) => n + s.length);
}

/// Логарифмы без `dart:math` (в `lib/core/passwords` он запрещён тестом
/// вместе с `Random`).
abstract final class PasswordMath {
  static const double _ln2 = 0.6931471805599453;

  /// log2([x]) для `x > 0`.
  static double log2(double x) {
    if (x <= 0) return double.negativeInfinity;
    if (x.isInfinite) return double.infinity;
    var e = 0;
    var m = x;
    while (m >= 2) {
      m /= 2;
      e++;
    }
    while (m < 1) {
      m *= 2;
      e--;
    }
    // ln m = 2·atanh((m − 1)/(m + 1)), m ∈ [1, 2): ряд сходится быстро.
    final y = (m - 1) / (m + 1);
    final y2 = y * y;
    var term = y;
    var sum = 0.0;
    for (var k = 1; k < 60; k += 2) {
      sum += term / k;
      term *= y2;
    }
    return e + 2 * sum / _ln2;
  }

  /// log10 из бит.
  static double bitsToLog10(double bits) => bits * 0.30102999566398120;

  /// 2^[bits] (для небольших значений; дальше — бесконечность).
  static double pow2(double bits) {
    if (bits > 1000) return double.infinity;
    var whole = bits.floor();
    final frac = bits - whole;
    var result = 1.0;
    while (whole > 0) {
      result *= 2;
      whole--;
    }
    // 2^frac = e^(frac·ln2) рядом Тейлора.
    final x = frac * _ln2;
    var term = 1.0;
    var sum = 1.0;
    for (var k = 1; k < 30; k++) {
      term *= x / k;
      sum += term;
    }
    return result * sum;
  }
}
