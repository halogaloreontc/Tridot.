import 'keyboard_layouts.dart';

/// Режим генератора (5.4). Только английские слова EFF и случайные
/// символы: русских режимов нет (решение владельца №6).
enum GeneratorMode { words, characters }

/// Параметры генератора без секретов: их можно положить в карточку и в
/// `payload` команды. Энтропия зависит только от параметров, не от
/// значения, поэтому её знает и навык, не видя пароля.
final class GeneratorOptions {
  const GeneratorOptions({
    this.mode = GeneratorMode.words,
    this.length = defaultLength,
    this.lower = true,
    this.upper = true,
    this.digits = true,
    this.symbols = true,
    this.noLookAlike = false,
    this.words = defaultWords,
    this.separator = '-',
    this.capital = true,
    this.digitCount = 2,
  });

  static const int minLength = 8;
  static const int maxLength = 64;
  static const int defaultLength = 20;
  static const int minWords = 3;
  static const int maxWords = 10;
  static const int defaultWords = 5;

  /// Разделители слов на выбор.
  static const List<String> separators = <String>['-', '.', '_', ' ', ''];

  static const String lowerSet = 'abcdefghijklmnopqrstuvwxyz';
  static const String upperSet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  static const String digitSet = '0123456789';
  static const String symbolSet = '!#\$%&*+-=?@^_~';

  /// Похожие на вид символы: `0O1lI|`.
  static const String lookAlike = '0O1lI|';

  final GeneratorMode mode;

  /// Символов (режим [GeneratorMode.characters]).
  final int length;
  final bool lower;
  final bool upper;
  final bool digits;
  final bool symbols;
  final bool noLookAlike;

  /// Слов (режим [GeneratorMode.words]).
  final int words;
  final String separator;

  /// Одно слово — с заглавной буквы.
  final bool capital;

  /// Цифр в конце (0–4).
  final int digitCount;

  /// Режим «только буквы и цифры».
  bool get alphanumeric => !symbols;

  GeneratorOptions copyWith({
    GeneratorMode? mode,
    int? length,
    bool? lower,
    bool? upper,
    bool? digits,
    bool? symbols,
    bool? noLookAlike,
    int? words,
    String? separator,
    bool? capital,
    int? digitCount,
  }) =>
      GeneratorOptions(
        mode: mode ?? this.mode,
        length: length ?? this.length,
        lower: lower ?? this.lower,
        upper: upper ?? this.upper,
        digits: digits ?? this.digits,
        symbols: symbols ?? this.symbols,
        noLookAlike: noLookAlike ?? this.noLookAlike,
        words: words ?? this.words,
        separator: separator ?? this.separator,
        capital: capital ?? this.capital,
        digitCount: digitCount ?? this.digitCount,
      ).normalized();

  /// В допустимых пределах: длина 8–64, слов 3–10, хотя бы один класс.
  GeneratorOptions normalized() {
    final anyClass = lower || upper || digits || symbols;
    return GeneratorOptions(
      mode: mode,
      length: length.clamp(minLength, maxLength),
      lower: anyClass ? lower : true,
      upper: upper,
      digits: digits,
      symbols: symbols,
      noLookAlike: noLookAlike,
      words: words.clamp(minWords, maxWords),
      separator: separators.contains(separator) ? separator : '-',
      capital: capital,
      digitCount: digitCount.clamp(0, 4),
    );
  }

  /// Классы символов, каждый — набор без «похожих», если просили.
  List<String> get classes => <String>[
        if (lower) _filter(lowerSet),
        if (upper) _filter(upperSet),
        if (digits) _filter(digitSet),
        if (symbols) _filter(symbolSet),
      ];

  String _filter(String set) => noLookAlike
      ? String.fromCharCodes(
          set.runes.where((int r) => !lookAlike.runes.contains(r)),
        )
      : set;

  /// Энтропия в битах. Символы: точное число строк длины [length], где
  /// есть каждый выбранный класс (формула включений-исключений: генератор
  /// перегенерирует строки без какого-то класса, поэтому все допустимые
  /// строки равновероятны). Слова: `words·log2(7776)` + выбор слова с
  /// заглавной + цифры.
  double get bits {
    if (mode == GeneratorMode.words) {
      final effBits = PasswordMath.log2(7776);
      return words * effBits +
          (capital ? PasswordMath.log2(words.toDouble()) : 0) +
          digitCount * PasswordMath.log2(10);
    }
    final sets = classes;
    final sizes = <int>[for (final s in sets) s.length];
    final total = sizes.fold(0, (int a, int b) => a + b);
    // Σ по подмножествам S классов: (−1)^|S| · (total − |S|)^L.
    var count = 0.0;
    for (var mask = 0; mask < (1 << sizes.length); mask++) {
      var removed = 0;
      var bitsSet = 0;
      for (var i = 0; i < sizes.length; i++) {
        if (mask & (1 << i) != 0) {
          removed += sizes[i];
          bitsSet++;
        }
      }
      final base = (total - removed).toDouble();
      var power = 1.0;
      for (var i = 0; i < length; i++) {
        power *= base;
      }
      count += bitsSet.isOdd ? -power : power;
    }
    return count <= 1 ? 0 : PasswordMath.log2(count);
  }

  /// Подсказка по структуре (5.4): без самих слов и символов.
  String get structureHint {
    if (mode == GeneratorMode.words) {
      final sep = switch (separator) {
        '-' => 'через дефис',
        '.' => 'через точку',
        '_' => 'через подчёркивание',
        ' ' => 'через пробел',
        _ => 'слитно',
      };
      final parts = <String>[
        '$words ${_wordsForm(words)} $sep',
        if (capital) 'одно с заглавной',
        if (digitCount > 0) 'в конце $digitCount ${_digitsForm(digitCount)}',
      ];
      return parts.join(', ');
    }
    final kinds = <String>[
      if (lower) 'строчные',
      if (upper) 'прописные',
      if (digits) 'цифры',
      if (symbols) 'символы',
    ];
    return '$length ${_charsForm(length)}: ${kinds.join(', ')}';
  }

  static String _wordsForm(int n) =>
      _plural(n, 'английское слово', 'английских слова', 'английских слов');

  static String _digitsForm(int n) => _plural(n, 'цифра', 'цифры', 'цифр');

  static String _charsForm(int n) =>
      _plural(n, 'символ', 'символа', 'символов');

  static String _plural(int n, String one, String few, String many) {
    final mod100 = n % 100;
    final mod10 = n % 10;
    if (mod100 >= 11 && mod100 <= 14) return many;
    if (mod10 == 1) return one;
    if (mod10 >= 2 && mod10 <= 4) return few;
    return many;
  }

  /// Для карточки и `payload` (без секретов).
  Map<String, Object?> toJson() => <String, Object?>{
        'mode': mode.name,
        'length': length,
        'lower': lower,
        'upper': upper,
        'digits': digits,
        'symbols': symbols,
        'noLookAlike': noLookAlike,
        'words': words,
        'separator': separator,
        'capital': capital,
        'digitCount': digitCount,
      };

  static GeneratorOptions fromJson(Map<String, Object?> json) {
    const d = GeneratorOptions();
    T pick<T>(String key, T fallback) {
      final v = json[key];
      return v is T ? v : fallback;
    }

    return GeneratorOptions(
      mode: json['mode'] == GeneratorMode.characters.name
          ? GeneratorMode.characters
          : GeneratorMode.words,
      length: pick<int>('length', d.length),
      lower: pick<bool>('lower', d.lower),
      upper: pick<bool>('upper', d.upper),
      digits: pick<bool>('digits', d.digits),
      symbols: pick<bool>('symbols', d.symbols),
      noLookAlike: pick<bool>('noLookAlike', d.noLookAlike),
      words: pick<int>('words', d.words),
      separator: pick<String>('separator', d.separator),
      capital: pick<bool>('capital', d.capital),
      digitCount: pick<int>('digitCount', d.digitCount),
    ).normalized();
  }

  @override
  String toString() => 'GeneratorOptions(${mode.name})';
}

/// Оценка надёжности словами (0–4) и пороги в битах (5.5).
abstract final class StrengthScale {
  /// < 28 → 0, < 36 → 1, < 60 → 2, < 80 → 3, иначе 4.
  static int scoreOf(double bits) {
    if (bits < 28) return 0;
    if (bits < 36) return 1;
    if (bits < 60) return 2;
    if (bits < 80) return 3;
    return 4;
  }

  static String label(int score) => switch (score) {
        0 => 'очень слабая',
        1 => 'слабая',
        2 => 'средняя',
        3 => 'высокая',
        _ => 'очень высокая',
      };
}
