import 'generator_options.dart';
import 'keyboard_layouts.dart';
import 'password_strength.dart';
import 'password_wordlists.dart';
import 'secret_bytes.dart';
import 'vault_format.dart';

/// Что не так с подсказкой (5.3).
enum HintProblem {
  /// В подсказке весь пароль.
  containsPassword,

  /// Общий кусок от 4 символов с учётом регистра, раскладки, транслита и
  /// l33t.
  sharedFragment,

  /// Подсказка (или слово в ней) — пароль какой-то записи (по отпечатку).
  equalsPassword,

  /// Слово из пароля-фразы (предупреждение, не запрет).
  passphraseWord,

  /// С паролями важных записей не сравнили: без свежего мастер-пароля
  /// кончились попытки, в подсказке несколько догадок или это новая
  /// подсказка самой важной записи (оракул отпечатков, 15.2). Запрет до
  /// подтверждения — предел не превращает «нельзя» в «можно».
  needsConfirm,

  /// Подсказка длиннее [HintGuard.maxHint] — не сохраняется и ни с чем
  /// не сравнивается.
  tooLong,
}

/// Итог проверки подсказки: [block] — сохранить нельзя, [warning] —
/// можно, но стоит переписать. Ни пароля, ни найденного куска.
final class HintVerdict {
  const HintVerdict({this.block, this.warning});

  static const HintVerdict fine = HintVerdict();

  final HintProblem? block;
  final HintProblem? warning;

  bool get ok => block == null;

  /// Текст для поля «Подсказка».
  String? get message => switch (block ?? warning) {
        HintProblem.containsPassword =>
          'В подсказке не должно быть самого пароля.',
        HintProblem.sharedFragment =>
          'В подсказке есть кусок пароля — с учётом регистра, раскладки, '
              'транслита и замен вроде «0 → o». Подсказка должна '
              'напоминать, а не раскрывать.',
        HintProblem.equalsPassword =>
          'В подсказке записан пароль одной из записей.',
        HintProblem.needsConfirm =>
          'Без мастер-пароля подсказку не сверить с паролями важных '
              'записей. Подтвердите мастер-паролем.',
        HintProblem.tooLong =>
          'Подсказка слишком длинная: не больше ${HintGuard.maxHint} '
              'символов.',
        HintProblem.passphraseWord =>
          'В подсказке есть слово из пароля-фразы — это облегчает подбор. '
              'Лучше напомнить, о чём фраза, своими словами.',
        null => null,
      };

  @override
  String toString() => 'HintVerdict(${block?.name}, ${warning?.name})';
}

/// Проверка подсказки к паролю (5.3). Подсказку покажут, когда человек
/// забудет пароль, — значит, её увидит и тот, кто взял открытое
/// хранилище. Запрет: подсказка содержит пароль или общий с ним кусок от
/// [fragment] символов (регистр, ЙЦУКЕН↔QWERTY, транслит, l33t), или
/// совпадает по отпечатку с паролем любой записи. Предупреждение: слово
/// из пароля-фразы.
abstract final class HintGuard {
  /// Самый короткий запрещённый общий кусок.
  static const int fragment = 4;

  /// Самая длинная подсказка (как в файле хранилища).
  static const int maxHint = VaultFormat.maxHint;

  /// Кандидаты, которые подсказка [hint] сверяет с паролями записей:
  /// вся подсказка и каждое её слово от [fragment] символов, без повторов.
  /// Подсказки по структуре генератора ([structureHints]) — постоянный
  /// текст, а не догадка: их слова не сверяются.
  static Set<String> _candidates(String hint) {
    final text = _maskStructures(hint.trim(), null).trim();
    if (text.isEmpty) return <String>{};
    return <String>{
      text,
      ...text.split(RegExp(r'\s+')).where((String t) => t.length >= fragment),
    };
  }

  /// Сколько разных догадок о пароле проверяет подсказка [hint] (15.2:
  /// с важными записями без мастер-пароля — не больше одной за попытку).
  static int candidates(String hint) =>
      hint.trim().isEmpty ? 0 : _candidates(hint).length;

  /// Все подсказки по структуре, которые выдаёт генератор (5.4,
  /// [GeneratorOptions.structureHint]), с параметрами; длинные — раньше
  /// (короткая бывает началом длинной). Слова: 3–10 × разделитель ×
  /// заглавная × 0–4 цифры; символы: длина 8–64 × набор классов.
  static final List<(String, GeneratorOptions)> structureHints = () {
    final out = <(String, GeneratorOptions)>[];
    for (var words = GeneratorOptions.minWords;
        words <= GeneratorOptions.maxWords;
        words++) {
      for (final separator in GeneratorOptions.separators) {
        for (final capital in <bool>[true, false]) {
          for (var digits = 0; digits <= 4; digits++) {
            final o = GeneratorOptions(
              words: words,
              separator: separator,
              capital: capital,
              digitCount: digits,
            );
            out.add((o.structureHint, o));
          }
        }
      }
    }
    for (var length = GeneratorOptions.minLength;
        length <= GeneratorOptions.maxLength;
        length++) {
      for (var mask = 1; mask < 16; mask++) {
        final o = GeneratorOptions(
          mode: GeneratorMode.characters,
          length: length,
          lower: mask & 1 != 0,
          upper: mask & 2 != 0,
          digits: mask & 4 != 0,
          symbols: mask & 8 != 0,
        );
        out.add((o.structureHint, o));
      }
    }
    out.sort(
      ((String, GeneratorOptions) a, (String, GeneratorOptions) b) =>
          b.$1.length.compareTo(a.$1.length),
    );
    return List<(String, GeneratorOptions)>.unmodifiable(out);
  }();

  /// [text], где подсказки по структуре генератора заменены пробелом.
  /// [fits] — маскировать только структуру, которой пароль соответствует
  /// (`null` — любую). Текст структуры зависит только от параметров
  /// генератора, не от значения: общий с паролем кусок в нём — совпадение,
  /// а не утечка («5 английских слов» транслитом — `angl`, как в
  /// `angler`). Пароль, набранный человеком (`fyukbqcrb` — «английских»
  /// в другой раскладке), структуре не соответствует — и не маскируется.
  static String _maskStructures(
    String text,
    bool Function(GeneratorOptions options)? fits,
  ) {
    var out = text;
    for (final (structure, options) in structureHints) {
      if (!out.contains(structure)) continue;
      if (fits != null && !fits(options)) continue;
      out = out.replaceAll(structure, ' ');
    }
    return out;
  }

  /// Пароль [pw] (кодовые точки как есть) мог выйти из генератора с
  /// параметрами [o]: символы — длина и классы; слова — слова EFF через
  /// разделитель, заглавная и цифры в конце. Без словаря EFF слова не
  /// проверить — `false`.
  static bool _fits(
    List<int> pw,
    GeneratorOptions o,
    PasswordWordlists? lists,
    List<List<int>> scratch,
  ) {
    if (o.mode == GeneratorMode.characters) {
      if (pw.length != o.length) return false;
      final classes = <List<int>>[
        for (final set in o.classes) set.runes.toList(),
      ];
      if (!pw.every((int r) => classes.any((List<int> c) => c.contains(r)))) {
        return false;
      }
      return classes.every((List<int> c) => pw.any(c.contains));
    }
    if (lists == null || lists.effWords.isEmpty) return false;
    final digits = o.digitCount;
    final end = pw.length - digits;
    if (end <= 0) return false;
    for (var i = end; i < pw.length; i++) {
      if (!KeyboardLayouts.isDigit(pw[i])) return false;
    }
    if (KeyboardLayouts.isDigit(pw[end - 1])) return false;
    final sep = o.separator.codeUnits;
    var capitals = 0;
    for (var i = 0; i < end; i++) {
      final r = pw[i];
      if (r >= 0x41 && r <= 0x5A) {
        capitals++;
        final atStart = i == 0 ||
            (sep.isNotEmpty && i >= sep.length && _endsWith(pw, i, sep));
        if (!atStart && sep.isNotEmpty) return false;
      }
    }
    if (capitals != (o.capital ? 1 : 0)) return false;
    final body = KeyboardLayouts.lowerAll(pw.sublist(0, end));
    scratch.add(body);
    // reach[p] — сколькими словами можно дойти до начала слова в p.
    final reach = List<Set<int>>.generate(end + 1, (_) => <int>{});
    reach[0].add(0);
    final longest = lists.effWords.longest;
    for (var p = 0; p < end; p++) {
      if (reach[p].isEmpty) continue;
      for (var j = p + 1; j <= end && j - p <= longest; j++) {
        if (lists.effWords.rank(body, p, j) == null) continue;
        final counts = <int>{for (final k in reach[p]) k + 1};
        if (j == end) {
          if (counts.contains(o.words)) return true;
          continue;
        }
        if (sep.isEmpty) {
          reach[j].addAll(counts);
        } else if (j + sep.length < end && _startsWith(body, j, sep)) {
          reach[j + sep.length].addAll(counts);
        }
      }
    }
    return false;
  }

  static bool _startsWith(List<int> runes, int at, List<int> part) {
    if (at + part.length > runes.length) return false;
    for (var k = 0; k < part.length; k++) {
      if (runes[at + k] != part[k]) return false;
    }
    return true;
  }

  static bool _endsWith(List<int> runes, int end, List<int> part) =>
      _startsWith(runes, end - part.length, part);

  /// [knownPassword] — совпадает ли слово по отпечатку с паролем
  /// какой-нибудь записи (открытое хранилище). [lists] — для слов фразы.
  static HintVerdict check(
    String hint,
    SecretBytes password, {
    bool Function(String token)? knownPassword,
    PasswordWordlists? lists,
  }) {
    final text = hint.trim();
    if (text.isEmpty) return HintVerdict.fine;
    // Длину — до любых сравнений.
    if (text.length > maxHint) {
      return const HintVerdict(block: HintProblem.tooLong);
    }
    HintVerdict known() {
      if (knownPassword == null) return HintVerdict.fine;
      return _candidates(text).any(knownPassword)
          ? const HintVerdict(block: HintProblem.equalsPassword)
          : HintVerdict.fine;
    }

    if (password.isEmpty) return known();
    final pw = Utf8Runes.decode(password.unsafeBytes);
    if (pw == null) return known();
    final scratch = <List<int>>[];
    try {
      // Подсказка по структуре генератора к паролю этой структуры не
      // сравнивается с ним: постоянный текст ничего о значении не говорит,
      // а случайный общий кусок иначе запрещал бы её (5.4).
      final own = _maskStructures(
        text,
        (GeneratorOptions o) => _fits(pw, o, lists, scratch),
      );
      // Вся подсказка — структура: сравнивать с паролем нечего.
      if (own.trim().isEmpty) return known();
      final hintRunes = KeyboardLayouts.lowerAll(own.runes.toList());
      final pwLower = KeyboardLayouts.lowerAll(pw);
      scratch.add(pwLower);
      // Обе стороны — во всех видах: как есть, в другой раскладке
      // (ЙЦУКЕН↔QWERTY), без l33t и транслитом. «k0tik» к `kotik2019`,
      // «rjnbr» к `котик2019`, «sobaka» к `cj,frf2019` — один и тот же кусок.
      final pwForms = _forms(pwLower);
      scratch.addAll(pwForms);
      final hintForms = _forms(hintRunes);
      // Пароль короче куска — запрет, только если он есть целиком.
      if (pwLower.length < fragment) {
        if (_contains(hintRunes, pwLower)) {
          return const HintVerdict(block: HintProblem.containsPassword);
        }
      } else {
        var longest = 0;
        for (final h in hintForms) {
          for (final p in pwForms) {
            final common = _longestCommon(h, p);
            if (common > longest) longest = common;
          }
        }
        if (longest >= pwLower.length) {
          return const HintVerdict(block: HintProblem.containsPassword);
        }
        if (longest >= fragment) {
          return const HintVerdict(block: HintProblem.sharedFragment);
        }
      }
      final other = known();
      if (!other.ok) return other;
      if (lists != null && !lists.effWords.isEmpty) {
        final words = _letterTokens(pwLower);
        scratch.addAll(words);
        for (final word in words) {
          if (word.length >= 3 &&
              lists.effWords.contains(word) &&
              _contains(hintRunes, word)) {
            return const HintVerdict(warning: HintProblem.passphraseWord);
          }
        }
      }
      return HintVerdict.fine;
    } finally {
      pw.fillRange(0, pw.length, 0);
      for (final s in scratch) {
        s.fillRange(0, s.length, 0);
      }
    }
  }

  /// Виды текста для сравнения: раскладка (как есть, латиница → кириллица,
  /// кириллица → латиница) × l33t (как есть, «1 → i», «1 → l») × транслит
  /// (нет, основной, второй). [runes] уже в нижнем регистре.
  static List<List<int>> _forms(List<int> runes) {
    final out = <List<int>>[];
    final layouts = <List<int>>[
      runes,
      KeyboardLayouts.lowerAll(KeyboardLayouts.latinToCyrillic(runes)),
      KeyboardLayouts.lowerAll(KeyboardLayouts.cyrillicToLatin(runes)),
    ];
    for (var i = 0; i < layouts.length; i++) {
      final layout = layouts[i];
      for (final plain in <List<int>>[
        layout,
        KeyboardLayouts.unleet(layout),
        KeyboardLayouts.unleet(layout, alt: true),
      ]) {
        out
          ..add(identical(plain, runes) ? List<int>.of(plain) : plain)
          ..add(KeyboardLayouts.translit(plain))
          ..add(KeyboardLayouts.translit(plain, alt: true));
      }
    }
    return out;
  }

  static bool _space(int r) => r == 0x20 || r == 0x09 || r == 0x0A;

  /// Длина самого длинного общего куска без пробелов.
  static int _longestCommon(List<int> a, List<int> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    var best = 0;
    var previous = List<int>.filled(b.length + 1, 0);
    var current = List<int>.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      for (var j = 1; j <= b.length; j++) {
        if (a[i - 1] == b[j - 1] && !_space(a[i - 1])) {
          current[j] = previous[j - 1] + 1;
          if (current[j] > best) best = current[j];
        } else {
          current[j] = 0;
        }
      }
      final t = previous;
      previous = current;
      current = t;
    }
    return best;
  }

  static bool _contains(List<int> haystack, List<int> needle) {
    if (needle.isEmpty || needle.length > haystack.length) return false;
    for (var i = 0; i + needle.length <= haystack.length; i++) {
      var ok = true;
      for (var k = 0; k < needle.length; k++) {
        if (haystack[i + k] != needle[k]) {
          ok = false;
          break;
        }
      }
      if (ok) return true;
    }
    return false;
  }

  static List<List<int>> _letterTokens(List<int> runes) {
    final out = <List<int>>[];
    var start = -1;
    for (var i = 0; i <= runes.length; i++) {
      final letter = i < runes.length && KeyboardLayouts.isLetter(runes[i]);
      if (letter && start < 0) start = i;
      if (!letter && start >= 0) {
        out.add(runes.sublist(start, i));
        start = -1;
      }
    }
    return out;
  }
}
