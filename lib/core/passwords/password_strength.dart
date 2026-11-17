// Пределы оценки (сознательно не модели, а честные ограничения; в
// интерфейсе не обещаем больше):
// - счётные последовательности (`1-2-3-4`, `10203040`, `jan feb mar`)
//   распознаются только как шаг ±1…±3 соседних символов;
// - фраза-«XKCD» из частых слов не по EFF (`correcthorsebatterystaple`)
//   оценивается по словарю частых паролей и EFF, без языковой модели;
// - почти одинаковые слова (`cobalt-cobolt`, `mantis-mantes`) — не повтор:
//   back-reference ищет точные копии (с регистром, l33t и задом наперёд);
// - слова EFF подряд в порядке списка (`abacus-abdomen-abide-abiding`)
//   считаются случайными;
// - клавиатурные ряды в хвосте после 128 символов не ищутся — хвост
//   считается копиями и перебором ([PasswordStrength._tailBits]);
// - цепочки рядов знают три связи: соседняя клавиша (одна линия и
//   направление на цепочку), та же клавиша с Shift или без, шаг до ±3
//   (один на цепочку); связи можно мешать (`1!2@3#`), рисунок смеси
//   стоит log2 3 на связь или несколько бит, если он повторяется с
//   периодом 2–3. Чередуются 2–4 цепочки блоками одной длины 1–3
//   (`q1w2`, `qw12er34`, `Qw12!@Er34`); блоки разной длины (`q12we345`),
//   длиннее 3 и цепочки короче 3 символов не распознаются;
// - фраза из слов EFF: длина слова оплачивается один раз на ряд слов
//   одной длины, одинаковый регистр (`IceAimFax`) — один раз на ряд,
//   порядок слов фразы (log2 k!) не добавляется. Разделители — один
//   основной вид (частые `-`, `.`, `_`, пробел, `,` — 2 бита) плюс log2 33
//   за каждый другой; места — равные промежутки, «между словами и перед
//   хвостом» (`Ice-Aim-Fax-Lid-1`) или произвольные. Частота слов в речи
//   не учитывается: все слова одной длины равноценны;
// - фраза из 4 слов со средней длиной меньше 5 букв (5 и больше слов —
//   меньше 4) не проходит в мастер-пароль как «фраза» (`masterProblem`),
//   только по оценке; из случайных фраз EFF это около 0,4 % для 4 слов;
// - повтор слова мастер-пароля ищется с учётом одного «s» на конце
//   (`power` и `powers`), но не других форм (`-es`, `-ies`, `-ed`).
import 'dart:typed_data';

import 'generator_options.dart';
import 'keyboard_layouts.dart';
import 'password_wordlists.dart';
import 'secret_bytes.dart';

/// Почему пароль слабее, чем кажется (для пояснений в карточке и на
/// экране «Проверка»; без самого пароля).
enum StrengthReason {
  /// Есть в списке частых паролей.
  common,

  /// Английское слово (словарь EFF).
  dictionary,

  /// Русское слово кириллицей.
  russianWord,

  /// Русское слово, набранное в английской раскладке (`ghbdtn`).
  russianLayout,

  /// Соседние клавиши (`qwerty`, `йцукен`, `1qaz`).
  keyboard,

  /// Последовательность (`abc`, `12345`, `987`).
  sequence,

  /// Повтор (`aaaa`, `abcabc`).
  repeat,

  /// Год или дата (1940–2035).
  date,

  /// Замены букв цифрами и знаками (`p@ssw0rd`).
  leet,

  /// Название сервиса, логин или адрес.
  userInput,

  /// Короче 12 символов.
  short,
}

/// Какие классы символов есть и длина — для ступени «Подсказка
/// посильнее» (D27): «12 символов: строчные, прописные, цифры».
final class PasswordShape {
  const PasswordShape({
    required this.length,
    this.lower = false,
    this.upper = false,
    this.digits = false,
    this.symbols = false,
    this.cyrillic = false,
    this.spaces = false,
  });

  /// Форма пароля [password] (без значения).
  factory PasswordShape.of(SecretBytes password) {
    final runes = Utf8Runes.decode(password.unsafeBytes) ?? <int>[];
    try {
      return PasswordShape(
        length: runes.length,
        lower: runes.any(
          (int r) => KeyboardLayouts.isLower(r) && r < 0x80,
        ),
        upper: runes.any(
          (int r) => KeyboardLayouts.isUpper(r) && r < 0x80,
        ),
        digits: runes.any(KeyboardLayouts.isDigit),
        cyrillic: runes.any(KeyboardLayouts.isCyrillic),
        spaces: runes.contains(0x20),
        symbols: runes.any(
          (int r) =>
              r != 0x20 &&
              !KeyboardLayouts.isLetter(r) &&
              !KeyboardLayouts.isDigit(r),
        ),
      );
    } finally {
      runes.fillRange(0, runes.length, 0);
    }
  }

  final int length;
  final bool lower;
  final bool upper;
  final bool digits;
  final bool symbols;
  final bool cyrillic;
  final bool spaces;

  /// «12 символов: строчные, прописные, цифры».
  String describe() {
    final kinds = <String>[
      if (lower) 'строчные латинские',
      if (upper) 'прописные латинские',
      if (cyrillic) 'русские буквы',
      if (digits) 'цифры',
      if (symbols) 'знаки',
      if (spaces) 'пробелы',
    ];
    final n = length;
    final mod100 = n % 100;
    final mod10 = n % 10;
    final word = mod100 >= 11 && mod100 <= 14
        ? 'символов'
        : mod10 == 1
            ? 'символ'
            : mod10 >= 2 && mod10 <= 4
                ? 'символа'
                : 'символов';
    return kinds.isEmpty ? '$n $word' : '$n $word: ${kinds.join(', ')}';
  }

  @override
  String toString() => 'PasswordShape(•••)';
}

/// Итог оценки: число 0–4, биты и причины. Ни пароля, ни его частей.
final class StrengthEstimate {
  const StrengthEstimate({
    required this.bits,
    required this.reasons,
    required this.length,
    this.passphraseWords = 0,
    this.passphraseLetters = 0,
  });

  /// log2 числа догадок атакующего.
  final double bits;

  final Set<StrengthReason> reasons;

  /// Символов в пароле.
  final int length;

  /// Слов EFF во фразе (мастер-пароль: «фраза из ≥ 4 слов», 5.1).
  final int passphraseWords;

  /// Букв в этих словах (средняя длина слова фразы — для 5.1: фраза из
  /// коротких слов — не фраза).
  final int passphraseLetters;

  int get score => StrengthScale.scoreOf(bits);

  double get log10Guesses => PasswordMath.bitsToLog10(bits);

  String get label => StrengthScale.label(score);

  @override
  String toString() => 'StrengthEstimate($score)';
}

/// UTF-8 → кодовые точки без создания строки (3.7). `null` — не UTF-8.
abstract final class Utf8Runes {
  static List<int>? decode(Uint8List bytes) {
    final out = <int>[];
    var i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      int need;
      int rune;
      if (b < 0x80) {
        out.add(b);
        i++;
        continue;
      } else if (b & 0xE0 == 0xC0) {
        need = 1;
        rune = b & 0x1F;
      } else if (b & 0xF0 == 0xE0) {
        need = 2;
        rune = b & 0x0F;
      } else if (b & 0xF8 == 0xF0) {
        need = 3;
        rune = b & 0x07;
      } else {
        out.fillRange(0, out.length, 0);
        return null;
      }
      if (i + need >= bytes.length) {
        out.fillRange(0, out.length, 0);
        return null;
      }
      for (var k = 1; k <= need; k++) {
        final c = bytes[i + k];
        if (c & 0xC0 != 0x80) {
          out.fillRange(0, out.length, 0);
          return null;
        }
        rune = (rune << 6) | (c & 0x3F);
      }
      out.add(rune);
      i += need + 1;
    }
    return out;
  }

  /// Кодовые точки → UTF-8.
  static Uint8List encode(List<int> runes) {
    final out = <int>[];
    for (final r in runes) {
      if (r < 0x80) {
        out.add(r);
      } else if (r < 0x800) {
        out
          ..add(0xC0 | (r >> 6))
          ..add(0x80 | (r & 0x3F));
      } else if (r < 0x10000) {
        out
          ..add(0xE0 | (r >> 12))
          ..add(0x80 | ((r >> 6) & 0x3F))
          ..add(0x80 | (r & 0x3F));
      } else {
        out
          ..add(0xF0 | (r >> 18))
          ..add(0x80 | ((r >> 12) & 0x3F))
          ..add(0x80 | ((r >> 6) & 0x3F))
          ..add(0x80 | (r & 0x3F));
      }
    }
    final bytes = Uint8List.fromList(out);
    out.fillRange(0, out.length, 0);
    return bytes;
  }
}

/// Найденный кусок пароля и цена его угадывания.
final class _Match {
  const _Match(
    this.start,
    this.end,
    this.bits,
    this.reason, {
    this.word = 0,
    this.lengthBits = 0,
    this.caseKind = 3,
    this.caseBits = 0,
  });

  final int start;
  final int end;
  final double bits;
  final StrengthReason reason;

  /// Слово EFF длиной [word] (0 — не слово EFF). Во фразе выбор длины
  /// оплачивается один раз на ряд слов одной длины: слово той же длины,
  /// что предыдущее, стоит на [lengthBits] дешевле.
  final int word;
  final double lengthBits;

  /// Регистр слова: 0 — строчные, 1 — первая заглавная, 2 — все
  /// заглавные, 3 — иначе. Тот же рисунок, что у предыдущего слова
  /// (`IceAimFax`), — бесплатно: на [caseBits] дешевле.
  final int caseKind;
  final double caseBits;
}

/// Клетка разбора [PasswordStrength._segment]: цена, последний кусок
/// (`null` — символ перебором), прежнее состояние и число кусков.
final class _Cell {
  const _Cell(this.cost, this.match, this.previous, this.count);

  final double cost;
  final _Match? match;
  final int previous;
  final int count;
}

/// Оценка надёжности (5.5): минимум по моделям — перебор по алфавиту,
/// частые пароли, словарь EFF, русские слова (и в английской раскладке),
/// ряды клавиатуры QWERTY/ЙЦУКЕН, последовательности, повторы, даты
/// 1940–2035, l33t и данные записи (сервис, логин, домен). Пароль
/// разбирается на куски так, чтобы атакующему было проще всего (как в
/// zxcvbn), цена кусков складывается в битах.
///
/// Работает с кодовыми точками: строк из пароля не создаёт, буферы
/// затирает.
final class PasswordStrength {
  PasswordStrength(this.lists);

  final PasswordWordlists lists;

  /// Длиннее — хвост считается перебором по классам символов (порядок
  /// величины не меняется, а время разбора ограничено).
  static const int _analyzed = 128;

  /// Нижняя граница догадок для куска короче всего пароля (zxcvbn).
  static final double _minSubmatchBits = PasswordMath.log2(50);

  /// Оценка пароля [password]. [userInputs] — название, логин, адреса:
  /// пароль из них слаб, даже если длинный.
  StrengthEstimate estimate(
    SecretBytes password, {
    List<String> userInputs = const <String>[],
  }) {
    final runes = Utf8Runes.decode(password.unsafeBytes);
    if (runes == null) {
      return StrengthEstimate(
        bits: password.length * 8.0,
        reasons: const <StrengthReason>{},
        length: password.length,
      );
    }
    try {
      return estimateRunes(runes, userInputs: userInputs);
    } finally {
      runes.fillRange(0, runes.length, 0);
    }
  }

  /// То же по кодовым точкам (вызывающий их затирает).
  StrengthEstimate estimateRunes(
    List<int> runes, {
    List<String> userInputs = const <String>[],
  }) {
    final n = runes.length;
    if (n == 0) {
      return const StrengthEstimate(
        bits: 0,
        reasons: <StrengthReason>{StrengthReason.short},
        length: 0,
      );
    }
    final head = n > _analyzed ? runes.sublist(0, _analyzed) : runes;
    final inputs = _inputs(userInputs);
    _alphabet = _alphabetBits(runes);
    try {
      return _estimate(runes, head, inputs);
    } finally {
      _alphabet = null;
    }
  }

  StrengthEstimate _estimate(
    List<int> runes,
    List<int> head,
    RuneDictionary inputs,
  ) {
    final n = runes.length;
    var (bits, reasons, _) = _segment(head, inputs, allowRepeat: true);
    final stripped = _withoutSeparators(head, inputs);
    if (stripped != null && stripped.$1 < bits) (bits, reasons) = stripped;
    var total = bits;
    if (!identical(head, runes)) {
      head.fillRange(0, head.length, 0);
      final (tail, repeated) = _tailBits(runes, _analyzed, _brute);
      total += tail;
      if (repeated) reasons.add(StrengthReason.repeat);
    }
    final (words, letters) = _passphraseWords(runes);
    return StrengthEstimate(
      bits: total,
      reasons: <StrengthReason>{
        ...reasons,
        if (n < 12) StrengthReason.short,
      },
      length: n,
      passphraseWords: words,
      passphraseLetters: letters,
    );
  }

  /// Хвост длиннее [_analyzed]: копии уже встречавшихся кусков (от 3
  /// символов, источник — не дальше [_analyzed] назад, с перекрытием —
  /// так `abcd` × 36 или `qwerty` × 23 стоят несколько бит, а не перебор)
  /// и перебор по классам для нового. Жадно, за O(n · [_analyzed]).
  /// Второе — были ли копии.
  static (double, bool) _tailBits(
    List<int> runes,
    int from,
    double Function(int) brute,
  ) {
    final n = runes.length;
    final lower = KeyboardLayouts.lowerAll(runes);
    final window = PasswordMath.log2(_analyzed.toDouble());
    var total = 0.0;
    var repeated = false;
    try {
      var i = from;
      while (i < n) {
        var best = 0;
        var exact = true;
        for (var s = i - _analyzed < 0 ? 0 : i - _analyzed; s < i; s++) {
          var len = 0;
          while (i + len < n && lower[s + len] == lower[i + len]) {
            len++;
          }
          if (len > best) {
            best = len;
            exact = _equalAt(runes, s, i, len);
          }
        }
        if (best >= 3) {
          var cost = 0.0;
          for (var k = i; k < i + best; k++) {
            cost += brute(runes[k]);
          }
          final copy =
              window + PasswordMath.log2(best.toDouble()) + (exact ? 0 : 1);
          total += copy < cost ? copy : cost;
          repeated = true;
          i += best;
        } else {
          total += brute(runes[i]);
          i++;
        }
      }
    } finally {
      lower.fillRange(0, lower.length, 0);
    }
    return (total, repeated);
  }

  /// Разделитель для модели «без разделителей»: знак ASCII, не буква и
  /// не цифра (`-`, `.`, `_`, пробел, `#`).
  static bool _isSeparator(int r) =>
      r < 0x80 && !KeyboardLayouts.isLetter(r) && !KeyboardLayouts.isDigit(r);

  /// Частые разделители слов фразы.
  static const Set<int> _commonSeparators = <int>{0x2D, 0x2E, 0x5F, 0x20, 0x2C};

  /// Тот же пароль без разделителей (`a-b-c-d-e-f`, `abc-def-ghi`):
  /// разбор остатка + выбор знаков (один вид — log2(33), а частый
  /// разделитель слов `-`, `.`, `_`, пробел, `,` — 2 бита; разные — по
  /// log2(33) на каждый) + места: через равные промежутки — log2(n);
  /// между кусками разбора остатка (слова фразы, хвост `-1`, `!` в
  /// конце) — 1 бит + выбрать, между какими (log2 C(куски, m)); иначе
  /// log2 C(n, m). `null` — разделителей нет или остаток короче 3.
  (double, Set<StrengthReason>)? _withoutSeparators(
    List<int> runes,
    RuneDictionary inputs,
  ) {
    final n = runes.length;
    final kept = <int>[];
    final at = <int>[];
    for (var i = 0; i < n; i++) {
      if (_isSeparator(runes[i])) {
        at.add(i);
      } else {
        kept.add(runes[i]);
      }
    }
    final m = at.length;
    try {
      if (m == 0 || kept.length < 3) return null;
      final (bits, reasons, cuts) = _segment(kept, inputs, allowRepeat: true);
      // Самый частый вид — один выбор, остальные — по log2(33) каждый
      // (`ice_aim_fax_lid!`: `_` и `!` в конце).
      final tally = <int, int>{};
      for (final k in at) {
        tally[runes[k]] = (tally[runes[k]] ?? 0) + 1;
      }
      var main = at.isEmpty ? 0 : runes[at.first];
      for (final MapEntry(:key, :value) in tally.entries) {
        if (value > tally[main]!) main = key;
      }
      final kindBits = (_commonSeparators.contains(main) ? 2.0 : _log33) +
          (m - tally[main]!) * _log33;
      // Равные промежутки: `ab-cd-ef`, `a.b.c` — без разделителя по краям.
      var regular = at.first > 0 && at.last < n - 1;
      final gap = at.first;
      for (var k = 0; regular && k < m; k++) {
        if (at[k] != gap + k * (gap + 1)) regular = false;
      }
      if (regular && (n - at.last - 1) != gap) regular = false;
      var placeBits = 0.0;
      if (regular) {
        placeBits = PasswordMath.log2(n.toDouble());
      } else {
        for (var k = 1; k <= m; k++) {
          placeBits += PasswordMath.log2((n - m + k) / k);
        }
      }
      // Между кусками: место k-го разделителя в остатке — граница
      // кусков или конец (`ice-aim-fax-lid-1`, `ice_aim_fax_lid!`).
      var between = true;
      for (var k = 0; k < m && between; k++) {
        final place = at[k] - k;
        if (k > 0 && at[k - 1] - (k - 1) == place) between = false;
        if (place != kept.length && !cuts.contains(place)) between = false;
      }
      if (between) {
        final slots = cuts.length + 1;
        var choose = 1.0;
        for (var k = 1; k <= m; k++) {
          choose += PasswordMath.log2((slots - m + k) / k);
        }
        if (choose < placeBits) placeBits = choose;
      }
      return (bits + kindBits + placeBits, reasons);
    } finally {
      kept.fillRange(0, kept.length, 0);
    }
  }

  /// Данные записи: слова длиной ≥ 3 в нижнем регистре.
  RuneDictionary _inputs(List<String> userInputs) {
    final tokens = <String>[];
    for (final input in userInputs) {
      final lower = input.toLowerCase();
      if (lower.length >= 3) tokens.add(lower);
      for (final part in lower.split(RegExp(r'[^a-zа-яё0-9]+'))) {
        if (part.length >= 3) tokens.add(part);
      }
    }
    return RuneDictionary(tokens);
  }

  /// Самое дешёвое для атакующего разбиение (динамика по позициям).
  /// Третье — границы кусков (без 0 и конца): где разделители «между
  /// кусками» ([_withoutSeparators]).
  ///
  /// Слова EFF подряд — фраза: выбор длины слова оплачивается один раз на
  /// ряд слов одной длины, одинаковый регистр (`IceAimFax`) — один раз на
  /// ряд, и ряд слов в порядке кусков (log2 k!) — один кусок: порядок
  /// слов фразы атакующий и так перебирает словами.
  (double, Set<StrengthReason>, List<int>) _segment(
    List<int> runes,
    RuneDictionary inputs, {
    required bool allowRepeat,
  }) {
    final n = runes.length;
    final lower = KeyboardLayouts.lowerAll(runes);
    final matches = <_Match>[
      ..._dictionary(runes, lower, inputs),
      ..._leet(runes, lower),
      ..._keyboard(runes, lower),
      ..._sequences(lower),
      ..._repeatedChars(runes),
      ..._normalized(runes),
      ..._interleaved(runes, lower),
      if (allowRepeat) ..._repeatedChunks(runes, lower, inputs),
      if (allowRepeat) ..._backReferences(runes, lower),
      if (allowRepeat) ..._stretched(runes, lower, inputs),
      ..._dates(runes),
    ];
    final byEnd = <int, List<_Match>>{};
    for (final m in matches) {
      (byEnd[m.end] ??= <_Match>[]).add(m);
    }
    // Состояние после позиции: 0 — последним был не слово EFF, иначе
    // длина слова · 4 + рисунок регистра ([_Match.caseKind]).
    final cells = List<Map<int, _Cell>>.generate(n + 1, (_) => <int, _Cell>{});
    cells[0][0] = const _Cell(0, null, 0, 0);
    for (var j = 1; j <= n; j++) {
      final here = cells[j];
      void offer(int state, _Cell cell) {
        final old = here[state];
        if (old == null || cell.cost < old.cost) here[state] = cell;
      }

      var cheapest = double.infinity;
      var from = 0;
      for (final MapEntry(:key, :value) in cells[j - 1].entries) {
        if (value.cost < cheapest) {
          cheapest = value.cost;
          from = key;
        }
      }
      offer(
        0,
        _Cell(
          cheapest + _brute(runes[j - 1]),
          null,
          from,
          cells[j - 1][from]!.count,
        ),
      );
      for (final m in byEnd[j] ?? const <_Match>[]) {
        final whole = m.start == 0 && m.end == n;
        final state = m.word > 0 ? m.word * 4 + m.caseKind : 0;
        for (final MapEntry(:key, :value) in cells[m.start].entries) {
          var bits = m.bits;
          final phrase = m.word > 0 && key > 0;
          if (phrase) {
            if (key ~/ 4 == m.word) bits -= m.lengthBits;
            if (key % 4 == m.caseKind) bits -= m.caseBits;
          }
          final cost =
              whole || bits >= _minSubmatchBits ? bits : _minSubmatchBits;
          offer(
            state,
            _Cell(
              value.cost + cost,
              m,
              key,
              value.count + (phrase ? 0 : 1),
            ),
          );
        }
      }
    }
    var end = 0;
    for (final MapEntry(:key, :value) in cells[n].entries) {
      if (value.cost < cells[n][end]!.cost) end = key;
    }
    final total = cells[n][end]!;
    final reasons = <StrengthReason>{};
    final cuts = <int>[];
    var j = n;
    var state = end;
    while (j > 0) {
      final cell = cells[j][state]!;
      final m = cell.match;
      if (m == null) {
        j--;
      } else {
        reasons.add(m.reason);
        j = m.start;
      }
      if (j > 0) cuts.add(j);
      state = cell.previous;
    }
    // Порядок кусков атакующему тоже неизвестен: + log2(k!) (zxcvbn).
    var order = 0.0;
    for (var k = 2; k <= total.count; k++) {
      order += PasswordMath.log2(k.toDouble());
    }
    for (var i = 0; i < lower.length; i++) {
      lower[i] = 0;
    }
    return (total.cost + order, reasons, cuts.reversed.toList());
  }

  /// Перебор по алфавиту всего пароля (бит на символ) на время
  /// [estimateRunes].
  double? _alphabet;

  /// Перебор одного символа, который не вошёл ни в один кусок: алфавит
  /// всего пароля — объединение его классов (строчные, прописные, цифры,
  /// знаки, кириллица). Атакующий не знает, где в случайном
  /// `k7yf6nt2q8` буква, а где цифра: класс «по месту» занижал бы
  /// случайные пароли из букв и цифр на ~1 бит на символ.
  double _brute(int r) {
    final alphabet = _alphabet;
    final own = _charBits(r);
    return alphabet == null || alphabet <= own ? own : (own + alphabet) / 2;
  }

  static double _alphabetBits(List<int> runes) {
    var digits = false;
    var lower = false;
    var upper = false;
    var symbols = false;
    var cyrLower = false;
    var cyrUpper = false;
    var other = false;
    for (final r in runes) {
      if (KeyboardLayouts.isDigit(r)) {
        digits = true;
      } else if (r >= 0x61 && r <= 0x7A) {
        lower = true;
      } else if (r >= 0x41 && r <= 0x5A) {
        upper = true;
      } else if (KeyboardLayouts.isCyrillic(r)) {
        if (KeyboardLayouts.isUpper(r)) {
          cyrUpper = true;
        } else {
          cyrLower = true;
        }
      } else if (r >= 0x20 && r < 0x7F) {
        symbols = true;
      } else {
        other = true;
      }
    }
    final size = (digits ? 10 : 0) +
        (lower ? 26 : 0) +
        (upper ? 26 : 0) +
        (symbols ? 33 : 0) +
        (cyrLower ? 33 : 0) +
        (cyrUpper ? 33 : 0) +
        (other ? 100 : 0);
    return PasswordMath.log2(size < 2 ? 2 : size.toDouble());
  }

  /// Перебор одного символа: размер его класса.
  static double _charBits(int r) {
    if (KeyboardLayouts.isDigit(r)) return _log10;
    if ((r >= 0x61 && r <= 0x7A) || (r >= 0x41 && r <= 0x5A)) return _log26;
    if (KeyboardLayouts.isCyrillic(r)) return _log33;
    if (r >= 0x20 && r < 0x7F) return _log33;
    return _log100;
  }

  static final double _log10 = PasswordMath.log2(10);
  static final double _log26 = PasswordMath.log2(26);
  static final double _log33 = PasswordMath.log2(33);
  static final double _log100 = PasswordMath.log2(100);

  /// Цена регистра букв куска (zxcvbn): строчные — 0, первая заглавная или
  /// все заглавные — 1 бит, иначе — число способов расставить заглавные.
  static double _caseBits(List<int> runes, int start, int end) {
    var upper = 0;
    var lowerCount = 0;
    for (var i = start; i < end; i++) {
      if (KeyboardLayouts.isUpper(runes[i])) upper++;
      if (KeyboardLayouts.isLower(runes[i])) lowerCount++;
    }
    if (upper == 0) return 0;
    if (lowerCount == 0) return 1;
    if (upper == 1 && KeyboardLayouts.isUpper(runes[start])) return 1;
    final total = upper + lowerCount;
    final small = upper < lowerCount ? upper : lowerCount;
    var sum = 0.0;
    for (var k = 1; k <= small; k++) {
      sum += _choose(total, k);
    }
    return PasswordMath.log2(sum);
  }

  static double _choose(int n, int k) {
    var r = 1.0;
    for (var i = 1; i <= k; i++) {
      r = r * (n - k + i) / i;
    }
    return r;
  }

  Iterable<_Match> _dictionary(
    List<int> runes,
    List<int> lower,
    RuneDictionary inputs,
  ) sync* {
    final n = lower.length;
    final reversed = lower.reversed.toList();
    for (var i = 0; i < n; i++) {
      for (var j = i + 3; j <= n && j - i <= 32; j++) {
        final effBits = _effBits(j - i);
        final caseBits = _caseBits(runes, i, j);
        final common = lists.common.rank(lower, i, j);
        if (common != null) {
          yield _Match(
            i,
            j,
            PasswordMath.log2(common.toDouble()) + caseBits,
            StrengthReason.common,
          );
        }
        if (lists.effWords.rank(lower, i, j) != null) {
          yield _word(runes, i, j, effBits + caseBits, caseBits);
        }
        final russian = lists.russian.rank(lower, i, j);
        if (russian != null) {
          yield _Match(
            i,
            j,
            PasswordMath.log2(russian.toDouble()) + caseBits,
            StrengthReason.russianWord,
          );
        }
        final layout = lists.russianInLatin.rank(lower, i, j);
        if (layout != null) {
          yield _Match(
            i,
            j,
            PasswordMath.log2(layout.toDouble()) + 1 + caseBits,
            StrengthReason.russianLayout,
          );
        }
        final input = inputs.rank(lower, i, j);
        if (input != null) {
          yield _Match(
            i,
            j,
            PasswordMath.log2(input.toDouble()) + 1 + caseBits,
            StrengthReason.userInput,
          );
        }
        // Слово задом наперёд: + 1 бит.
        final ri = n - j;
        final rj = n - i;
        final rev = lists.common.rank(reversed, ri, rj);
        if (rev != null) {
          yield _Match(
            i,
            j,
            PasswordMath.log2(rev.toDouble()) + 1 + caseBits,
            StrengthReason.common,
          );
        }
        if (lists.effWords.rank(reversed, ri, rj) != null) {
          yield _word(runes, i, j, effBits + 1 + caseBits, caseBits);
        }
      }
    }
    reversed.fillRange(0, reversed.length, 0);
  }

  /// `p@ssw0rd`: замены → слово из словаря, + 1 бит за каждую замену
  /// (не больше 4).
  Iterable<_Match> _leet(List<int> runes, List<int> lower) sync* {
    if (KeyboardLayouts.leetCount(lower) == 0) return;
    final n = lower.length;
    for (final alt in <bool>[false, true]) {
      final plain = KeyboardLayouts.unleet(lower, alt: alt);
      for (var i = 0; i < n; i++) {
        for (var j = i + 3; j <= n && j - i <= 32; j++) {
          final subs = KeyboardLayouts.leetCount(lower.sublist(i, j));
          if (subs == 0) continue;
          final extra = (subs > 4 ? 4 : subs) + _caseBits(runes, i, j);
          final rank = lists.common.rank(plain, i, j) ??
              lists.russianInLatin.rank(plain, i, j);
          if (rank != null) {
            yield _Match(
              i,
              j,
              PasswordMath.log2(rank.toDouble()) + extra,
              StrengthReason.leet,
            );
          } else if (lists.effWords.rank(plain, i, j) != null) {
            yield _word(
              runes,
              i,
              j,
              _effBits(j - i) + extra,
              _caseBits(runes, i, j),
              reason: StrengthReason.leet,
            );
          }
        }
      }
      plain.fillRange(0, plain.length, 0);
    }
  }

  /// Соседние клавиши одного ряда или столбца в одну сторону, от 3.
  Iterable<_Match> _keyboard(List<int> runes, List<int> lower) sync* {
    final n = lower.length;
    final keys = KeyboardLayouts.keyPositions;
    for (var i = 0; i + 2 < n; i++) {
      final first = keys[lower[i]];
      if (first == null) continue;
      for (final (line, pos) in first) {
        for (final dir in <int>[1, -1]) {
          var j = i + 1;
          var p = pos;
          while (j < n) {
            final next = keys[lower[j]];
            if (next == null ||
                !next.any(((int, int) k) => k.$1 == line && k.$2 == p + dir)) {
              break;
            }
            p += dir;
            j++;
          }
          var shifted = false;
          for (var k = i; k < i + 2 && k < j; k++) {
            if (KeyboardLayouts.isShifted(lower[k])) shifted = true;
          }
          for (var end = i + 3; end <= j; end++) {
            final len = end - i;
            if (KeyboardLayouts.isShifted(lower[end - 1])) shifted = true;
            // Shift у знаков (`!@#$`, `!QAZ@WSX`) — как регистр: бит.
            yield _Match(
              i,
              end,
              PasswordMath.log2(
                    (KeyboardLayouts.keyCount * 2 * len).toDouble(),
                  ) +
                  _caseBits(runes, i, end) +
                  (shifted ? 1 : 0),
              StrengthReason.keyboard,
            );
          }
        }
      }
    }
  }

  /// Цена слова EFF длиной [length]: выбрать длину (log2 7) и слово
  /// этой длины, но не больше log2(7776). Коротких слов мало (82 из 3
  /// букв, 467 из 4): фраза `iceaimfaxlid` — не 4 × 12,9 бита.
  double _effBits(int length) {
    final cache = _effCache ??= <int, double>{};
    return cache[length] ??= () {
      final all = PasswordMath.log2(PasswordWordlists.effSize.toDouble());
      final count = lists.effWords.countOfLength(length);
      if (count == 0) return all;
      final bits = PasswordMath.log2(count.toDouble()) + _log7;
      return bits < all ? bits : all;
    }();
  }

  Map<int, double>? _effCache;

  /// Сколько из [_effBits] — выбор длины слова (во фразе он один на ряд
  /// слов одной длины).
  double _effLengthBits(int length) {
    final count = lists.effWords.countOfLength(length);
    if (count == 0) return 0;
    final rest = _effBits(length) - PasswordMath.log2(count.toDouble());
    return rest > 0 ? rest : 0;
  }

  /// Кусок [i, j) — слово EFF ценой [bits], из них [caseBits] — регистр.
  _Match _word(
    List<int> runes,
    int i,
    int j,
    double bits,
    double caseBits, {
    StrengthReason reason = StrengthReason.dictionary,
  }) {
    var upper = 0;
    var lowerCount = 0;
    for (var k = i; k < j; k++) {
      if (KeyboardLayouts.isUpper(runes[k])) upper++;
      if (KeyboardLayouts.isLower(runes[k])) lowerCount++;
    }
    final kind = upper == 0
        ? 0
        : lowerCount == 0
            ? 2
            : upper == 1 && KeyboardLayouts.isUpper(runes[i])
                ? 1
                : 3;
    return _Match(
      i,
      j,
      bits,
      reason,
      word: j - i,
      lengthBits: _effLengthBits(j - i),
      caseKind: kind,
      caseBits: kind == 1 || kind == 2 ? caseBits : 0,
    );
  }

  static final double _log7 = PasswordMath.log2(7);

  /// Частые пароли, слова EFF и ряды клавиш на нормализованной копии:
  /// клавиши без Shift (`!Q@W` → `1q2w`), русская раскладка → клавиши
  /// QWERTY (`1й2ц` → `1q2w`), нижний регистр. Цена — как у исходной
  /// модели + рисунок Shift/регистра ([_maskBits]) + 1 бит за раскладку.
  /// Два варианта знаков: QWERTY и ЙЦУКЕН (`"№;:?` — цифры с Shift).
  Iterable<_Match> _normalized(List<int> runes) sync* {
    final n = runes.length;
    var cyrillic = false;
    var symbols = false;
    for (final r in runes) {
      if (KeyboardLayouts.isCyrillic(r)) cyrillic = true;
      if (KeyboardLayouts.isShifted(r)) symbols = true;
    }
    if (!cyrillic && !symbols) return;
    for (final russian in <bool>[false, if (cyrillic || symbols) true]) {
      final norm = List<int>.filled(n, 0);
      final shift = List<bool>.filled(n, false);
      final swapped = List<bool>.filled(n, false);
      for (var i = 0; i < n; i++) {
        final r = runes[i];
        var key = KeyboardLayouts.unshift(r, russian: russian);
        shift[i] = KeyboardLayouts.isUpper(r) ||
            (!KeyboardLayouts.isLetter(r) && key != r);
        if (KeyboardLayouts.isCyrillic(key)) {
          final latin = KeyboardLayouts.cyrillicToLatin(<int>[key]).single;
          swapped[i] = latin != key;
          key = latin;
        }
        norm[i] = key;
      }
      try {
        double extra(int i, int j) {
          var layout = false;
          for (var k = i; k < j; k++) {
            if (swapped[k]) layout = true;
          }
          return _maskBits(shift, i, j) + (layout ? 1 : 0);
        }

        for (var i = 0; i < n; i++) {
          for (var j = i + 3; j <= n && j - i <= 32; j++) {
            final common = lists.common.rank(norm, i, j);
            final eff = lists.effWords.rank(norm, i, j) != null;
            if (common == null && !eff) continue;
            final add = extra(i, j);
            if (common != null) {
              // `1q2w3e4r`, `asdfgh` из `фывапр` — в списке частых, но
              // человеку понятнее «соседние клавиши».
              yield _Match(
                i,
                j,
                PasswordMath.log2(common.toDouble()) + add,
                _isWalk(norm, i, j)
                    ? StrengthReason.keyboard
                    : StrengthReason.common,
              );
            }
            if (eff) {
              yield _Match(
                i,
                j,
                _effBits(j - i) + add,
                StrengthReason.dictionary,
                word: j - i,
                lengthBits: _effLengthBits(j - i),
              );
            }
          }
        }
        for (final m in _keyboard(norm, norm)) {
          yield _Match(
            m.start,
            m.end,
            m.bits + extra(m.start, m.end),
            m.reason,
          );
        }
      } finally {
        norm.fillRange(0, n, 0);
        shift.fillRange(0, n, false);
      }
    }
  }

  /// Битовая маска «соседние клавиши» в [_links].
  static const int _keyboardLinks = (1 << 40) - 2;

  /// Кусок [i, j) — ряд соседних клавиш (одна линия, одно направление)
  /// или чередование двух таких рядов (`1q2w3e`).
  static bool _isWalk(List<int> runes, int i, int j) {
    for (var k = 1; k <= 2; k++) {
      var ok = j - i >= 3 * k;
      for (var r = 0; r < k && ok; r++) {
        var links = _keyboardLinks;
        for (var at = i + r; at + k < j && links != 0; at += k) {
          links &= _links(runes[at], runes[at + k]);
        }
        if (links == 0) ok = false;
      }
      if (ok) return true;
    }
    return false;
  }

  /// Цена рисунка «нажат Shift / заглавная» [mask] на куске [i, j): нет —
  /// 0; все или только первый — 1 бит; повторяющийся рисунок с периодом
  /// 2–3 (`!q@w`, `Qq1!`) — период + 1; иначе — число способов выбрать
  /// места (как [_caseBits]).
  static double _maskBits(List<bool> mask, int i, int j) {
    final t = j - i;
    var s = 0;
    for (var k = i; k < j; k++) {
      if (mask[k]) s++;
    }
    if (s == 0) return 0;
    if (s == t || (s == 1 && mask[i])) return 1;
    for (var p = 2; p <= 3 && p * 2 <= t; p++) {
      var periodic = true;
      for (var k = i + p; k < j && periodic; k++) {
        if (mask[k] != mask[k - p]) periodic = false;
      }
      if (periodic) return p + 1.0;
    }
    final small = s < t - s ? s : t - s;
    var sum = 0.0;
    for (var k = 1; k <= small; k++) {
      sum += _choose(t, k);
    }
    return PasswordMath.log2(sum);
  }

  /// Связи двух символов для чередующихся цепочек ([_interleaved]) —
  /// битовая маска: 0 — та же клавиша (с Shift или без, другой регистр);
  /// 1 + 2·линия + направление — соседние клавиши одной линии
  /// ([KeyboardLayouts.keyPositions]); 40 + 3 + шаг — последовательность
  /// с шагом до ±3 (`aceg`, `2468`) — и по клавишам без Shift (`1!3#`:
  /// `!` → `1`, `1` → `3`).
  static int _links(int a, int b) {
    var mask = 0;
    final la = KeyboardLayouts.lower(a);
    final lb = KeyboardLayouts.lower(b);
    if (KeyboardLayouts.unshift(a) == KeyboardLayouts.unshift(b) ||
        KeyboardLayouts.unshift(a, russian: true) ==
            KeyboardLayouts.unshift(b, russian: true)) {
      mask |= 1;
    }
    final pa = KeyboardLayouts.keyPositions[la];
    final pb = KeyboardLayouts.keyPositions[lb];
    if (pa != null && pb != null) {
      for (final (line, pos) in pa) {
        for (final (line2, pos2) in pb) {
          if (line != line2) continue;
          if (pos2 == pos + 1) mask |= 1 << (1 + 2 * line + 1);
          if (pos2 == pos - 1) mask |= 1 << (1 + 2 * line);
        }
      }
    }
    for (final (x, y) in <(int, int)>[
      (la, lb),
      (KeyboardLayouts.unshift(a), KeyboardLayouts.unshift(b)),
      (
        KeyboardLayouts.unshift(a, russian: true),
        KeyboardLayouts.unshift(b, russian: true),
      ),
    ]) {
      final d = y - x;
      if (d != 0 && d >= -3 && d <= 3 && _sameKind(x, y)) {
        mask |= 1 << (43 + d);
      }
    }
    return mask;
  }

  static final double _log3 = PasswordMath.log2(3);

  /// Цена цепочки [chain] (от 2 символов) со связями по [_links]: самая
  /// дешёвая из моделей — одна клавиша × длина, ряд клавиш,
  /// последовательность, смешанная цепочка ([_mixedBits]); плюс рисунок
  /// Shift/регистра.
  double _chainBits(List<int> chain) {
    final count = chain.length;
    final shift = <bool>[
      for (final r in chain)
        KeyboardLayouts.isUpper(r) || KeyboardLayouts.isShifted(r),
    ];
    final masks = <int>[
      for (var t = 0; t + 1 < count; t++) _links(chain[t], chain[t + 1]),
    ];
    var links = -1;
    for (final m in masks) {
      links &= m;
    }
    final first = KeyboardLayouts.lower(chain.first);
    final length = PasswordMath.log2(count.toDouble());
    final walk = PasswordMath.log2((KeyboardLayouts.keyCount * 2).toDouble());
    var best = double.infinity;
    if (links & 1 != 0) best = _charBits(first) + length;
    if (links & _keyboardLinks != 0 && walk + length < best) {
      best = walk + length;
    }
    for (var d = -3; d <= 3; d++) {
      if (d == 0 || links & (1 << (43 + d)) == 0) continue;
      final base = KeyboardLayouts.isDigit(first) ? 10 : 26;
      final step = d < 0 ? -d : d;
      final seq = PasswordMath.log2(
        (base * count * (d < 0 ? 2 : 1) * (step == 1 ? 1 : 3)).toDouble(),
      );
      if (seq < best) best = seq;
    }
    if (links == 0) {
      final mixed = _mixedBits(masks);
      if (mixed != null && walk + length + mixed < best) {
        best = walk + length + mixed;
      }
    }
    shift.fillRange(0, count, false);
    return best + _maskBits(shift, 0, count);
  }

  /// Смешанная цепочка (`1!2@3#`, `1!3#5%`): каждая связь — своя из трёх
  /// («та же клавиша ± Shift», «соседняя клавиша» одной линии и
  /// направления на всю цепочку, «шаг ≤ 3» одного шага на всю цепочку).
  /// Цена рисунка связей: повторяется с периодом 2–3 — выбрать период и
  /// связь на каждое его место (log2 3 + p·log2 3); иначе — log2 3 на
  /// связь. Плюс линия и направление соседних клавиш (2 бита) и шаг
  /// (log2 6), если они есть. `null` — какую-то связь не объяснить.
  static double? _mixedBits(List<int> masks) {
    var union = 0;
    for (final m in masks) {
      if (m == 0) return null;
      union |= m;
    }
    final keys = <int>[
      0,
      for (var bit = 1; bit < 43; bit++)
        if (union & (1 << bit) != 0) 1 << bit,
    ];
    final steps = <int>[
      0,
      for (var d = -3; d <= 3; d++)
        if (d != 0 && union & (1 << (43 + d)) != 0) 1 << (43 + d),
    ];
    final c = masks.length;
    double? best;
    for (final key in keys) {
      for (final step in steps) {
        // Какие из трёх связей годятся для каждой: 1 — та же клавиша,
        // 2 — соседняя, 4 — шаг.
        final allowed = <int>[
          for (final m in masks)
            (m & 1 != 0 ? 1 : 0) |
                (m & key != 0 ? 2 : 0) |
                (m & step != 0 ? 4 : 0),
        ];
        if (allowed.contains(0)) continue;
        var pattern = c * _log3;
        for (var p = 2; p <= 3 && p < c; p++) {
          var periodic = true;
          for (var r = 0; r < p && periodic; r++) {
            var common = 7;
            for (var t = r; t < c; t += p) {
              common &= allowed[t];
            }
            if (common == 0) periodic = false;
          }
          if (periodic) {
            final cost = _log3 + p * _log3;
            if (cost < pattern) pattern = cost;
            break;
          }
        }
        final bits = pattern +
            (key != 0 ? 2 : 0) +
            (step != 0 ? PasswordMath.log2(6) : 0);
        if (best == null || bits < best) best = bits;
      }
    }
    return best;
  }

  /// Чередование 2–4 цепочек ([_chainBits]) блоками по 1–3 символа:
  /// `q1w2e3r4` (по одному), `qw12er34ty56`, `QW!@ER#$`, `Qw12!@Er34#$`
  /// (по два), `1й2ц3у4к`, `Qq1!Ww2@Ee3#` — блок номер t идёт в цепочку
  /// t mod k. Каждая цепочка сама по себе ряд клавиш, последовательность,
  /// одна клавиша (с Shift и без) или их смесь, от 3 символов (и не
  /// меньше двух блоков). Цена — сумма цепочек + log2(k) + 1 бит, за
  /// блоки длиннее одного символа — ещё log2(3). Только самый длинный
  /// кусок с каждого начала.
  Iterable<_Match> _interleaved(List<int> runes, List<int> lower) sync* {
    final n = runes.length;
    for (var b = 1; b <= 3; b++) {
      for (var k = 2; k <= 4; k++) {
        final period = b * k;
        final least = b == 1 ? 3 : b + 1;
        if (n < period + least) continue;
        // Предыдущий символ той же цепочки для позиции со сдвигом [o].
        int previous(int o) => o % b != 0 ? o - 1 : o - b * (k - 1) - 1;
        var lastEnd = -1;
        for (var i = 0; i < n; i++) {
          var end = i + 1;
          while (end < n) {
            final p = previous(end - i);
            if (p >= 0 && _links(runes[i + p], runes[end]) == 0) break;
            end++;
          }
          final ownEnd = end;
          if (ownEnd <= lastEnd) {
            lastEnd = ownEnd;
            continue;
          }
          lastEnd = ownEnd;
          final chains = List<List<int>>.generate(k, (_) => <int>[]);
          for (var o = 0; o < end - i; o++) {
            chains[(o ~/ b) % k].add(runes[i + o]);
          }
          try {
            if (chains.any((List<int> c) => c.length < least)) continue;
            var bits =
                PasswordMath.log2(k.toDouble()) + 1 + (b > 1 ? _log3 : 0);
            for (final chain in chains) {
              bits += _chainBits(chain);
            }
            yield _Match(i, end, bits, StrengthReason.keyboard);
          } finally {
            for (final c in chains) {
              c.fillRange(0, c.length, 0);
            }
          }
        }
      }
    }
  }

  /// `abc`, `123`, `987`, `абв`: шаг ±1, от 3 символов; `aceg`, `2468`,
  /// `zwtq`: постоянный шаг до ±3, от 4 символов (+ log2(3) за шаг).
  Iterable<_Match> _sequences(List<int> lower) sync* {
    final n = lower.length;
    for (var i = 0; i + 2 < n; i++) {
      final delta = lower[i + 1] - lower[i];
      final step = delta < 0 ? -delta : delta;
      if (step == 0 || step > 3) continue;
      if (!_sameKind(lower[i], lower[i + 1])) continue;
      // Начало цепочки с тем же шагом уже разобрано.
      if (i > 0 &&
          lower[i] - lower[i - 1] == delta &&
          _sameKind(lower[i - 1], lower[i])) {
        continue;
      }
      var j = i + 2;
      while (j < n &&
          lower[j] - lower[j - 1] == delta &&
          _sameKind(lower[j], lower[j - 1])) {
        j++;
      }
      final shortest = step == 1 ? 3 : 4;
      for (var from = i; from + shortest <= j; from++) {
        final first = lower[from];
        final base = '019azая'.runes.contains(first)
            ? 4
            : KeyboardLayouts.isDigit(first)
                ? 10
                : 26;
        for (var end = from + shortest; end <= j; end++) {
          yield _Match(
            from,
            end,
            PasswordMath.log2(
              (base * (end - from) * (delta < 0 ? 2 : 1) * (step == 1 ? 1 : 3))
                  .toDouble(),
            ),
            StrengthReason.sequence,
          );
        }
      }
    }
  }

  static bool _sameKind(int a, int b) =>
      (KeyboardLayouts.isDigit(a) && KeyboardLayouts.isDigit(b)) ||
      (a >= 0x61 && a <= 0x7A && b >= 0x61 && b <= 0x7A) ||
      (KeyboardLayouts.isCyrillic(a) && KeyboardLayouts.isCyrillic(b));

  /// `aaaa`: символ × длина.
  Iterable<_Match> _repeatedChars(List<int> runes) sync* {
    final n = runes.length;
    for (var i = 0; i + 2 < n; i++) {
      if (i > 0 && runes[i - 1] == runes[i]) continue;
      var j = i + 1;
      while (j < n && runes[j] == runes[i]) {
        j++;
      }
      for (var end = i + 3; end <= j; end++) {
        yield _Match(
          i,
          end,
          _charBits(runes[i]) + PasswordMath.log2((end - i).toDouble()),
          StrengthReason.repeat,
        );
      }
    }
  }

  /// `abcabc`, `qwe123qwe123`, `Able-able-ABLE-`, `able1-able2-able3-`:
  /// кусок × число повторов. Повторы сравниваются без учёта регистра и с
  /// цифрами «как класс»: другой регистр стоит бит-другой, цифры —
  /// перебор, а счётчик (`1, 2, 3` или `9, 8, 7`) — 2 бита на всё.
  Iterable<_Match> _repeatedChunks(
    List<int> runes,
    List<int> lower,
    RuneDictionary inputs,
  ) sync* {
    final n = runes.length;
    final shape = <int>[
      for (final r in lower) KeyboardLayouts.isDigit(r) ? 0x30 : r,
    ];
    try {
      for (var i = 0; i < n; i++) {
        for (var p = 2; i + 2 * p <= n; p++) {
          // Цифры «как класс» — только в куске с буквами или знаками:
          // кусок из одних цифр сравнивается как есть (иначе любые цифры
          // «повторяются», а разбор стоит секунды).
          final key = _allDigits(lower, i, p) ? lower : shape;
          // Кусок сам из повторов меньшего (`1111`, `abab`) — его уже
          // учёл меньший период; повтор, который тянется левее, — уже
          // учтён с более раннего начала.
          if (_periodic(key, i, p)) continue;
          if (i >= p && _equalAt(key, i - p, i, p)) continue;
          var reps = 1;
          while (i + (reps + 1) * p <= n && _equalAt(key, i, i + reps * p, p)) {
            reps++;
          }
          if (reps < 2) continue;
          final chunk = runes.sublist(i, i + p);
          final (chunkBits, _, _) = _segment(chunk, inputs, allowRepeat: false);
          chunk.fillRange(0, chunk.length, 0);
          var extra = 0.0;
          var counter = false;
          int? step;
          int? previous = _digitsValue(runes, i, p);
          for (var k = 1; k < reps; k++) {
            final at = i + k * p;
            if (!_equalAt(lower, i, at, p)) {
              final value = _digitsValue(runes, at, p);
              final delta =
                  value == null || previous == null ? null : value - previous;
              if (delta != null &&
                  (delta == 1 || delta == -1) &&
                  (step == null || step == delta)) {
                step = delta;
                counter = true;
              } else {
                extra += _digitCount(runes, at, p) * _log10;
                step = 0;
              }
              previous = value;
            }
            if (!_equalAt(runes, i, at, p)) {
              final caseBits = _caseBits(runes, at, at + p);
              extra += _equalAt(lower, i, at, p) || caseBits > 0
                  ? (caseBits < 1 ? 1 : caseBits)
                  : 0;
            }
          }
          yield _Match(
            i,
            i + reps * p,
            chunkBits +
                PasswordMath.log2(reps.toDouble()) +
                extra +
                (counter ? 2 : 0),
            StrengthReason.repeat,
          );
        }
      }
    } finally {
      shape.fillRange(0, shape.length, 0);
    }
  }

  /// Число из цифр куска (по порядку) — для счётчика; `null` — цифр нет
  /// или их больше 9.
  static int? _digitsValue(List<int> runes, int start, int length) {
    var value = 0;
    var digits = 0;
    for (var k = start; k < start + length; k++) {
      if (!KeyboardLayouts.isDigit(runes[k])) continue;
      if (++digits > 9) return null;
      value = value * 10 + runes[k] - 0x30;
    }
    return digits == 0 ? null : value;
  }

  static int _digitCount(List<int> runes, int start, int length) {
    var digits = 0;
    for (var k = start; k < start + length; k++) {
      if (KeyboardLayouts.isDigit(runes[k])) digits++;
    }
    return digits;
  }

  static bool _allDigits(List<int> runes, int start, int length) {
    for (var k = start; k < start + length; k++) {
      if (!KeyboardLayouts.isDigit(runes[k])) return false;
    }
    return true;
  }

  /// Кусок `runes[start, start + length)` — повтор меньшего куска.
  static bool _periodic(List<int> runes, int start, int length) {
    for (var d = 1; d * 2 <= length; d++) {
      if (length % d != 0) continue;
      var ok = true;
      for (var k = d; k < length; k++) {
        if (runes[start + k] != runes[start + k - d]) {
          ok = false;
          break;
        }
      }
      if (ok) return true;
    }
    return false;
  }

  /// Повтор уже встречавшегося куска от 3 символов в любом месте пароля
  /// (`able-acid-able-acid`, `tiger-lamp-tiger`), в том числе задом
  /// наперёд (`able-elba`, `Kp3vX-Xv3pK`) и с l33t-заменами
  /// (`velvet-v3lv3t`, `Mantis-M4NT15`): атакующему достаточно указать,
  /// откуда и сколько скопировать, — log2(позиция) + log2(длина); задом
  /// наперёд — + 1 бит, каждая замена — + 1 бит, другой регистр — ещё
  /// бит-другой. Сравнение — без учёта регистра и замен, обе таблицы
  /// l33t (`1 → i` и `1 → l`: `lily-1i1y`, `lamp-1amp`).
  Iterable<_Match> _backReferences(List<int> runes, List<int> lower) sync* {
    final n = runes.length;
    final plain = KeyboardLayouts.unleet(lower);
    final alt = KeyboardLayouts.unleet(lower, alt: true);
    final best = List<double>.filled(n + 1, double.infinity);
    final caseCost = List<double>.filled(n + 1, -1);
    try {
      for (var j = 1; j + 3 <= n; j++) {
        final where = PasswordMath.log2(j < 2 ? 2 : j.toDouble());
        var longest = 0;
        best.fillRange(0, best.length, double.infinity);
        caseCost.fillRange(0, caseCost.length, -1);
        double caseAt(int len) {
          if (caseCost[len] < 0) {
            final c = _caseBits(runes, j, j + len);
            caseCost[len] = c < 1 ? 1 : c;
          }
          return caseCost[len];
        }

        void source(int Function(int k) at, int limit, double extra) {
          var subs = 0;
          var cased = false;
          for (var k = 0; k < limit; k++) {
            final s = at(k);
            if (plain[s] != plain[j + k] && alt[s] != alt[j + k]) {
              if (k > longest) longest = k;
              return;
            }
            if (lower[s] != lower[j + k]) {
              subs++;
            } else if (runes[s] != runes[j + k]) {
              cased = true;
            }
            final len = k + 1;
            if (len < 3) continue;
            final bits = where +
                PasswordMath.log2(len.toDouble()) +
                extra +
                subs +
                (cased ? caseAt(len) : 0);
            if (bits < best[len]) best[len] = bits;
          }
          if (limit > longest) longest = limit;
        }

        for (var i = 0; i < j; i++) {
          // Вперёд: копия `[i, i + len)` (может перекрывать саму себя).
          source((int k) => i + k, n - j, 0);
          // Задом наперёд: копия куска, кончающегося на `i`.
          source((int k) => i - k, i + 1 < n - j ? i + 1 : n - j, 1);
        }
        for (var len = 3; len <= longest; len++) {
          if (best[len].isFinite) {
            yield _Match(j, j + len, best[len], StrengthReason.repeat);
          }
        }
      }
    } finally {
      plain.fillRange(0, plain.length, 0);
      alt.fillRange(0, alt.length, 0);
    }
  }

  /// `aa11bb22cc33`, `aaabbbccc`, `AaBbCcDd`: каждый символ повторён 2 или
  /// 3 раза (без учёта регистра) — цена куска без повторов + log2(k) и
  /// бит за одинаковый рисунок регистра в группах (разный — бит на
  /// группу). Только самые длинные цепочки (от 3 групп), со всех сдвигов.
  Iterable<_Match> _stretched(
    List<int> runes,
    List<int> lower,
    RuneDictionary inputs,
  ) sync* {
    final n = runes.length;
    // Одна клавиша с Shift и без (`1!`, `Qq`, `2@`) — тоже повтор.
    final keys = <int>[for (final r in runes) KeyboardLayouts.unshift(r)];
    bool group(int at, int k) {
      if (at + k > n) return false;
      for (var q = 1; q < k; q++) {
        if (keys[at + q] != keys[at]) return false;
      }
      return true;
    }

    int pattern(int at, int k) {
      var mask = 0;
      for (var q = 0; q < k; q++) {
        final r = runes[at + q];
        if (KeyboardLayouts.isUpper(r) || KeyboardLayouts.isShifted(r)) {
          mask |= 1 << q;
        }
      }
      return mask;
    }

    for (final k in <int>[2, 3]) {
      for (var i = 0; i + 3 * k <= n; i++) {
        if (!group(i, k)) continue;
        if (i >= k && group(i - k, k)) continue;
        var end = i;
        while (group(end, k)) {
          end += k;
        }
        final groups = (end - i) ~/ k;
        if (groups < 3) continue;
        var mixed = false;
        var same = true;
        final first = pattern(i, k);
        for (var at = i; at < end; at += k) {
          final p = pattern(at, k);
          if (p != 0 && p != (1 << k) - 1) mixed = true;
          if (p != first) same = false;
        }
        final caseBits = !mixed ? 0 : (same ? 1 : groups);
        final single = <int>[for (var at = i; at < end; at += k) runes[at]];
        final (bits, _, _) = _segment(single, inputs, allowRepeat: false);
        single.fillRange(0, single.length, 0);
        yield _Match(
          i,
          end,
          bits + PasswordMath.log2(k.toDouble()) + caseBits,
          StrengthReason.repeat,
        );
      }
    }
    keys.fillRange(0, keys.length, 0);
  }

  static bool _equalAt(List<int> runes, int a, int b, int length) {
    for (var k = 0; k < length; k++) {
      if (runes[a + k] != runes[b + k]) return false;
    }
    return true;
  }

  static const int _firstYear = 1940;
  static const int _lastYear = 2035;
  static final double _yearBits =
      PasswordMath.log2((_lastYear - _firstYear + 1).toDouble());
  static final double _dateBits = PasswordMath.log2(
    365.0 * (_lastYear - _firstYear + 1),
  );

  /// Годы 1940–2035 и даты (`010190`, `01.01.1990`, `19900101`).
  Iterable<_Match> _dates(List<int> runes) sync* {
    final n = runes.length;
    int? number(int start, int length) {
      if (start + length > n) return null;
      var v = 0;
      for (var k = start; k < start + length; k++) {
        if (!KeyboardLayouts.isDigit(runes[k])) return null;
        v = v * 10 + runes[k] - 0x30;
      }
      return v;
    }

    bool year4(int? y) => y != null && y >= _firstYear && y <= _lastYear;
    bool day(int? d) => d != null && d >= 1 && d <= 31;
    bool month(int? m) => m != null && m >= 1 && m <= 12;

    for (var i = 0; i < n; i++) {
      if (year4(number(i, 4))) {
        yield _Match(i, i + 4, _yearBits, StrengthReason.date);
      }
      // Без разделителей: ддммгг, ддммгггг, ггггммдд, ммддгггг.
      final six = number(i, 6) != null;
      if (six &&
          (day(number(i, 2)) && month(number(i + 2, 2)) ||
              month(number(i, 2)) && day(number(i + 2, 2)))) {
        yield _Match(i, i + 6, _dateBits, StrengthReason.date);
      }
      if (number(i, 8) != null) {
        final dmy = day(number(i, 2)) &&
            month(number(i + 2, 2)) &&
            year4(number(i + 4, 4));
        final mdy = month(number(i, 2)) &&
            day(number(i + 2, 2)) &&
            year4(number(i + 4, 4));
        final ymd = year4(number(i, 4)) &&
            month(number(i + 4, 2)) &&
            day(number(i + 6, 2));
        if (dmy || mdy || ymd) {
          yield _Match(i, i + 8, _dateBits, StrengthReason.date);
        }
      }
      // С разделителями: д.м.гг(гг), дд/мм/гггг, гггг-мм-дд.
      for (final (a, b, c) in <(int, int, int)>[
        (1, 1, 2),
        (1, 1, 4),
        (1, 2, 2),
        (1, 2, 4),
        (2, 1, 2),
        (2, 1, 4),
        (2, 2, 2),
        (2, 2, 4),
        (4, 2, 2),
      ]) {
        final end = i + a + b + c + 2;
        if (end > n) continue;
        final s1 = runes[i + a];
        final s2 = runes[i + a + 1 + b];
        if (s1 != s2 || !'./-_ '.runes.contains(s1)) continue;
        final x = number(i, a);
        final y = number(i + a + 1, b);
        final z = number(i + a + b + 2, c);
        final ok = a == 4
            ? year4(x) && month(y) && day(z)
            : (day(x) && month(y) || month(x) && day(y)) &&
                (c == 2 ? z != null : year4(z));
        if (ok) {
          yield _Match(i, end, _dateBits + 2, StrengthReason.date);
        }
      }
    }
  }

  /// Служебные слова-связки (`and`, `the`, «или»): во фразе
  /// `cobalt and velvet and mantis` их повтор не в счёт, но и словом
  /// фразы они не считаются. Только от 3 букв — короче слова не берутся.
  static const Set<String> fillerWords = <String>{
    'and', 'the', 'for', 'with', 'into', 'but', 'nor', 'not', //
    'its', 'are', 'was', 'per', 'via', 'или', 'для', 'над', 'под',
    'при', 'без', 'про', 'что', 'как', 'это', 'так', 'там', 'тут',
  };

  /// [word] в нижнем регистре — связка из [fillerWords].
  static bool isFiller(String word) => fillerWords.contains(word);

  static final List<List<int>> _fillerRunes = <List<int>>[
    for (final w in fillerWords) w.runes.toList(),
  ];

  /// Разных слов EFF во фразе (без связок [fillerWords]). Кусок из
  /// латинских букв и дефисов сначала целиком делится на слова EFF от 3
  /// букв наименьшим числом слов — с разделителем-дефисом или без
  /// разделителя (`powerrackdwarfclover`, `cobalt-yo-yo-mantis`: в EFF
  /// есть слова с дефисом). Не делится — по отдельности каждый кусок букв
  /// (с делением по CamelCase); такой кусок, который не делится на слова
  /// EFF, — не слово фразы. Повтор слова не считается:
  /// «able-able-able-able» — это одно слово, а не фраза из четырёх (5.1).
  (int, int) _passphraseWords(List<int> runes) {
    final found = <List<int>>[];
    void add(List<int> token) {
      if (lists.effWords.contains(token) &&
          !_fillerRunes.any((w) => _sameRunes(w, token)) &&
          !found.any((w) => _sameRunes(w, token))) {
        found.add(token);
      } else {
        token.fillRange(0, token.length, 0);
      }
    }

    /// Слова EFF куска [start, end) целиком; `false` — не делится.
    bool split(int start, int end) {
      if (end - start < 3) return false;
      final token = KeyboardLayouts.lowerAll(runes.sublist(start, end));
      try {
        final words = _effSplit(token);
        if (words == null) return false;
        for (final (from, to) in words) {
          add(token.sublist(from, to));
        }
        return true;
      } finally {
        token.fillRange(0, token.length, 0);
      }
    }

    bool letter(int i) =>
        i < runes.length &&
        runes[i] < 0x80 &&
        KeyboardLayouts.isLetter(runes[i]);

    var start = -1;
    for (var i = 0; i <= runes.length; i++) {
      final inside = letter(i) || (i < runes.length && runes[i] == 0x2D);
      if (inside && start < 0) start = i;
      if (inside || start < 0) continue;
      if (!split(start, i)) {
        var from = -1;
        for (var k = start; k <= i; k++) {
          if (letter(k) && k < i) {
            if (from < 0) from = k;
            continue;
          }
          if (from < 0) continue;
          // CamelCase: новая часть — заглавная после строчной.
          var part = from;
          for (var q = from + 1; q < k; q++) {
            if (KeyboardLayouts.isUpper(runes[q]) &&
                KeyboardLayouts.isLower(runes[q - 1])) {
              split(part, q);
              part = q;
            }
          }
          split(part, k);
          from = -1;
        }
      }
      start = -1;
    }
    final count = found.length;
    var letters = 0;
    for (final w in found) {
      letters += w.length;
      w.fillRange(0, w.length, 0);
    }
    return (count, letters);
  }

  /// Деление [token] (нижний регистр, буквы и дефисы) на слова EFF от 3
  /// символов наименьшим числом слов; дефис между словами пропускается.
  /// `null` — не делится.
  List<(int, int)>? _effSplit(List<int> token) {
    final n = token.length;
    final best = List<int>.filled(n + 1, -1);
    final from = List<int>.filled(n + 1, -1);
    final word = List<bool>.filled(n + 1, false);
    best[0] = 0;
    for (var i = 0; i < n; i++) {
      if (best[i] < 0) continue;
      if (token[i] == 0x2D && i > 0 && word[i]) {
        if (best[i + 1] < 0 || best[i] < best[i + 1]) {
          best[i + 1] = best[i];
          from[i + 1] = i;
          word[i + 1] = false;
        }
        continue;
      }
      for (var j = i + 3; j <= n && j - i <= 32; j++) {
        if (lists.effWords.rank(token, i, j) == null) continue;
        if (best[j] < 0 || best[i] + 1 < best[j]) {
          best[j] = best[i] + 1;
          from[j] = i;
          word[j] = true;
        }
      }
    }
    if (best[n] < 0 || !word[n]) return null;
    final out = <(int, int)>[];
    for (var j = n; j > 0; j = from[j]) {
      if (word[j]) out.add((from[j], j));
    }
    return out.reversed.toList();
  }

  /// Слова EFF (от 3 букв), на которые целиком делится [token] (буквы и
  /// дефисы) наименьшим числом слов: `powerrackdwarf` → `power`, `rack`,
  /// `dwarf`. `null` — не делится. Для проверки повтора слова в
  /// мастер-пароле (строку из пароля там уже держит поле ввода).
  List<String>? effWordsOf(String token) {
    final runes = KeyboardLayouts.lowerAll(token.runes.toList());
    try {
      final split = _effSplit(runes);
      if (split == null) return null;
      return <String>[
        for (final (from, to) in split)
          String.fromCharCodes(runes.sublist(from, to)),
      ];
    } finally {
      runes.fillRange(0, runes.length, 0);
    }
  }

  static bool _sameRunes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() => 'PasswordStrength';
}
