import '../connectors/due_parser.dart';
import '../connectors/speech_noise.dart';
import '../connectors/spoken_time.dart';

/// Чистка распознанного текста, общая для любого распознавателя (Vosk
/// и распознаватель телефона, ADR-023): убирает обрывки вроде «зэд» и
/// «ээ», повтор слова подряд («напомни напомни») и пишет время цифрами
/// («в девять» → «в 9», «полдевятого» → «8:30»), как его набрали бы
/// вручную. Текст в кавычках не трогается. Работает только в памяти и
/// ничего не записывает.
abstract final class VoiceText {
  static final RegExp _token = RegExp(r'\S+');
  static final RegExp _letters = RegExp('[^a-zа-я0-9-]');

  static String clean(String text) {
    if (text.trim().isEmpty) return text;
    final quoted = _quotedRanges(text);
    bool inQuotes(int position) => quoted.any(
          ((int, int) r) => position >= r.$1 && position < r.$2,
        );

    // Время словами — цифрами: позиции те же, что в нормализованном тексте.
    final spoken = <SpokenTimeMatch>[
      for (final match in SpokenTime.find(DueParser.normalizeChars(text)))
        if (!inQuotes(match.start)) match,
    ];
    final withDigits = StringBuffer();
    var position = 0;
    for (final match in spoken) {
      withDigits
        ..write(text.substring(position, match.start))
        ..write(match.digits);
      position = match.end;
    }
    withDigits.write(text.substring(position));
    final timed = withDigits.toString();

    final timedQuotes = _quotedRanges(timed);
    final words = <String>[];
    String? previous;
    var first = true;
    for (final match in _token.allMatches(timed)) {
      final word = match.group(0)!;
      final insideQuotes = timedQuotes.any(
        ((int, int) r) => match.start >= r.$1 && match.start < r.$2,
      );
      final bare = DueParser.normalizeChars(word).replaceAll(_letters, '');
      if (!insideQuotes) {
        if (SpeechNoise.isJunk(bare)) continue;
        // Одиночное «э» и «мм», «эм» — междометия только в начале фразы:
        // «э напомни», но «сверло 6 мм».
        if (first && (bare == 'э' || SpeechNoise.isLeadNoise(bare))) {
          continue;
        }
        // «напомни напомни», «на на завтра» — повтор распознавателя.
        // Числа повторяются по делу: «двадцать один ноль ноль», «2 2».
        if (previous != null &&
            bare.isNotEmpty &&
            bare == previous &&
            !_isNumberWord(bare)) {
          continue;
        }
      }
      words.add(word);
      previous = bare;
      first = false;
    }
    return _dropFinalDot(_quantities(words).join(' '));
  }

  static final RegExp _digits = RegExp(r'^[0-9:]+$');

  static bool _isNumberWord(String bare) =>
      _digits.hasMatch(bare) ||
      _units.containsKey(bare) ||
      _teens.containsKey(bare) ||
      _tens.containsKey(bare);

  /// Точка в конце от распознавания телефона (оно расставляет знаки) не
  /// нужна в поле ввода; «?» и «!» остаются — по ним видно вопрос.
  static String _dropFinalDot(String text) {
    if (text.endsWith('...') || !text.endsWith('.')) return text;
    return text.substring(0, text.length - 1).trimRight();
  }

  static const Map<String, int> _units = <String, int>{
    'ноль': 0,
    'один': 1,
    'одна': 1,
    'одну': 1,
    'одно': 1,
    'два': 2,
    'две': 2,
    'три': 3,
    'четыре': 4,
    'пять': 5,
    'шесть': 6,
    'семь': 7,
    'восемь': 8,
    'девять': 9,
  };

  static const Map<String, int> _teens = <String, int>{
    'десять': 10,
    'одиннадцать': 11,
    'двенадцать': 12,
    'тринадцать': 13,
    'четырнадцать': 14,
    'пятнадцать': 15,
    'шестнадцать': 16,
    'семнадцать': 17,
    'восемнадцать': 18,
    'девятнадцать': 19,
  };

  static const Map<String, int> _tens = <String, int>{
    'двадцать': 20,
    'тридцать': 30,
    'сорок': 40,
    'пятьдесят': 50,
  };

  static final RegExp _unit = RegExp(r'^(минут|секунд|час|раз[а]?$|процент)');

  /// Число словами перед единицей — цифрами: «пять минут» → «5 минут»,
  /// «двадцать пять секунд» → «25 секунд», «одну минуту» → «1 минуту».
  /// Одно «один» без единицы, порядковые и «полчаса» не трогаются.
  static List<String> _quantities(List<String> words) {
    String bare(String word) =>
        DueParser.normalizeChars(word).replaceAll(_letters, '');
    final result = <String>[];
    var i = 0;
    while (i < words.length) {
      final first = bare(words[i]);
      int? value;
      var used = 0;
      final ten = _tens[first];
      if (ten != null) {
        value = ten;
        used = 1;
        if (i + 1 < words.length) {
          final unit = _units[bare(words[i + 1])];
          if (unit != null && unit > 0) {
            value = ten + unit;
            used = 2;
          }
        }
      } else if (_units[first] ?? _teens[first] case final int number) {
        value = number;
        used = 1;
      }
      if (value != null &&
          i + used < words.length &&
          _unit.hasMatch(bare(words[i + used]))) {
        result.add('$value');
        i += used;
        continue;
      }
      result.add(words[i]);
      i++;
    }
    return result;
  }

  /// Участки в кавычках «…», "…", „…“.
  static List<(int, int)> _quotedRanges(String text) {
    final result = <(int, int)>[];
    const pairs = <String, String>{'«': '»', '"': '"', '„': '“', '“': '”'};
    var i = 0;
    while (i < text.length) {
      final close = pairs[text[i]];
      if (close == null) {
        i++;
        continue;
      }
      final end = text.indexOf(close, i + 1);
      if (end < 0) break;
      result.add((i, end + 1));
      i = end + 1;
    }
    return result;
  }
}
