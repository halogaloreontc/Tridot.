/// Время на часах словами: «в девять», «к восьми утра», «в восемь
/// тридцать», «полдевятого», «в половине девятого», «без пятнадцати
/// девять», «в полдень». Так его пишет распознаватель голоса, а разбор срока понимает
/// цифры.
///
/// Только находит такие места: что с ними делать, решает вызывающий.
/// Разбор срока ([DueParser]) подставляет цифры той же длины, чтобы
/// фрагменты срока указывали в исходную строку; нормализация голоса
/// показывает «в 9», «8:30» в пузыре сообщения. Текст —
/// нормализованный: нижний регистр, «е» вместо «ё».
abstract final class SpokenTime {
  static final RegExp _word = RegExp('[a-zа-я0-9]+');

  /// Предлоги, после которых число словами — час: «в девять», «к восьми»,
  /// «до десяти», «на десять» (срок «завтра на 10» разбирает [DueParser]).
  static const Set<String> _prepositions = <String>{
    'в',
    'во',
    'к',
    'ко',
    'до',
    'около',
    'на',
    'с',
    'со',
    'от',
    'по',
  };

  /// Часы в именительном («в девять») и родительном/дательном падеже
  /// («к девяти», «до восьми»).
  static const Map<String, int> _hours = <String, int>{
    'один': 1,
    'одного': 1,
    'два': 2,
    'двух': 2,
    'три': 3,
    'трех': 3,
    'четыре': 4,
    'четырех': 4,
    'пять': 5,
    'пяти': 5,
    'шесть': 6,
    'шести': 6,
    'семь': 7,
    'семи': 7,
    'восемь': 8,
    'восьми': 8,
    'девять': 9,
    'девяти': 9,
    'десять': 10,
    'десяти': 10,
    'одиннадцать': 11,
    'одиннадцати': 11,
    'двенадцать': 12,
    'двенадцати': 12,
    'тринадцать': 13,
    'тринадцати': 13,
    'четырнадцать': 14,
    'четырнадцати': 14,
    'пятнадцать': 15,
    'пятнадцати': 15,
    'шестнадцать': 16,
    'шестнадцати': 16,
    'семнадцать': 17,
    'семнадцати': 17,
    'восемнадцать': 18,
    'восемнадцати': 18,
    'девятнадцать': 19,
    'девятнадцати': 19,
    'двадцать': 20,
    'двадцати': 20,
  };

  /// Второе слово часа после «двадцать»: «в двадцать два».
  static const Map<String, int> _twentyUnits = <String, int>{
    'один': 1,
    'одного': 1,
    'два': 2,
    'двух': 2,
    'три': 3,
    'трех': 3,
  };

  /// «Час» как час — только с частью суток: «в час дня», «к часу ночи».
  /// Без неё «в час» — скорее длительность или «в час пик».
  static const Set<String> _oneHour = <String>{'час', 'часу'};

  static const Set<String> _dayparts = <String>{'дня', 'ночи'};

  /// Минуты после часа: «в восемь тридцать», «в девять сорок пять».
  static const Map<String, int> _minuteTens = <String, int>{
    'десять': 10,
    'пятнадцать': 15,
    'двадцать': 20,
    'тридцать': 30,
    'сорок': 40,
    'пятьдесят': 50,
  };

  static const Map<String, int> _minuteUnits = <String, int>{
    'пять': 5,
    'один': 1,
    'две': 2,
    'три': 3,
    'четыре': 4,
    'шесть': 6,
    'семь': 7,
    'восемь': 8,
    'девять': 9,
  };

  static const Set<String> _hourNouns = <String>{'час', 'часа', 'часов'};

  static const Set<String> _minuteNouns = <String>{
    'минут',
    'минуты',
    'минута',
    'минуту',
  };

  /// Порядковые в родительном: «полдевятого», «в половине девятого».
  static const Map<String, int> _ordinals = <String, int>{
    'первого': 1,
    'второго': 2,
    'третьего': 3,
    'четвертого': 4,
    'пятого': 5,
    'шестого': 6,
    'седьмого': 7,
    'восьмого': 8,
    'девятого': 9,
    'десятого': 10,
    'одиннадцатого': 11,
    'двенадцатого': 12,
  };

  /// Полдень и полночь: «в полдень» — 12:00, «к полуночи» — 0:00.
  static const Map<String, int> _noon = <String, int>{
    'полдень': 12,
    'полудню': 12,
    'полудня': 12,
    'полночь': 0,
    'полуночи': 0,
  };

  /// Предлоги перед «полднем»: «после полудня» — не ровно 12:00.
  static const Set<String> _noonPrepositions = <String>{
    'в',
    'к',
    'ко',
    'до',
    'около',
    'на',
  };

  /// Минуты до часа: «без пятнадцати девять», «без четверти восемь».
  static const Map<String, int> _minutesBefore = <String, int>{
    'пяти': 5,
    'десяти': 10,
    'пятнадцати': 15,
    'четверти': 15,
    'двадцати': 20,
  };

  /// Слово длительности после числа: «минут», «секунды», «дней»,
  /// «недели», «раза». «Дня» — и длительность, и часть суток, его
  /// решает предлог.
  static bool _isDuration(String word) =>
      word.startsWith('минут') ||
      word.startsWith('секунд') ||
      word.startsWith('недел') ||
      word.startsWith('месяц') ||
      const <String>{'день', 'дней', 'раз', 'раза'}.contains(word);

  /// Время словами в [text]: где оно и какое.
  static List<SpokenTimeMatch> find(String text) {
    final words = _word.allMatches(text).toList(growable: false);
    String at(int i) => words[i].group(0)!;
    bool adjacent(int left, int right) =>
        text.substring(words[left].end, words[right].start).trim().isEmpty;
    bool next(int i) => i + 1 < words.length && adjacent(i, i + 1);

    final result = <SpokenTimeMatch>[];
    for (var i = 0; i < words.length; i++) {
      final word = at(i);
      // «пятнадцатого ноября», «двадцать пятого декабря» — число месяца.
      final day = _dayOrdinal(words, i, at, next);
      if (day != null) {
        result.add(
          SpokenTimeMatch.date(words[i].start, words[day.$2].end, day.$1),
        );
        i = day.$2;
        continue;
      }
      // «полдевятого», «пол девятого».
      if (word.startsWith('пол') && word.length > 3) {
        final ordinal = _ordinals[word.substring(3)];
        if (ordinal != null) {
          result.add(_half(words[i].start, words[i].end, ordinal));
          continue;
        }
      }
      // «в полдень», «к полуночи», «до полудня» — после предлога.
      // «до обеда» — к полудню; «с утра до обеда» — промежуток, не срок.
      final beforeLunch = word == 'обеда' &&
          i > 0 &&
          at(i - 1) == 'до' &&
          !(i > 1 && (at(i - 2) == 'утра' || at(i - 2) == 'утречка'));
      final noon = beforeLunch ? 12 : _noon[word];
      if (noon != null &&
          i > 0 &&
          adjacent(i - 1, i) &&
          _noonPrepositions.contains(at(i - 1))) {
        result.add(
          SpokenTimeMatch(words[i].start, words[i].end, noon, 0, named: true),
        );
        continue;
      }
      if ((word == 'пол' ||
              word == 'половине' ||
              word == 'половина' ||
              word == 'половину') &&
          next(i)) {
        final ordinal = _ordinals[at(i + 1)];
        if (ordinal != null) {
          result.add(_half(words[i].start, words[i + 1].end, ordinal));
          i++;
          continue;
        }
      }
      // «без пятнадцати девять», «без двадцати пяти восемь».
      if (word == 'без' && next(i)) {
        var k = i + 1;
        var before = _minutesBefore[at(k)];
        if (before == 20 && next(k) && at(k + 1) == 'пяти') {
          before = 25;
          k++;
        }
        if (before != null && next(k)) {
          final hourWord = at(k + 1);
          final hour = hourWord == 'час' ? 1 : _hours[hourWord];
          if (hour != null && hour <= 12) {
            final previous = hour == 1 ? 12 : hour - 1;
            result.add(
              SpokenTimeMatch(
                words[i].start,
                words[k + 1].end,
                previous,
                60 - before,
                twelveHour: true,
              ),
            );
            i = k + 1;
            continue;
          }
        }
      }
      if (!_prepositions.contains(word) || !next(i)) continue;
      var k = i + 1;
      final hourWord = at(k);
      int? hour;
      if (_oneHour.contains(hourWord)) {
        if (!next(k) || !_dayparts.contains(at(k + 1))) continue;
        hour = 1;
      } else {
        hour = _hours[hourWord];
      }
      if (hour == null) continue;
      if (hour == 20 && next(k) && _twentyUnits.containsKey(at(k + 1))) {
        hour += _twentyUnits[at(k + 1)]!;
        k++;
      }
      // «на пять минут», «на двадцать пять секунд», «до десяти дней» —
      // длительность, а не час.
      if (next(k) && _isDuration(at(k + 1))) continue;
      // «на два дня» — срок, «в два дня» — 14:00.
      if (word == 'на' && next(k) && at(k + 1) == 'дня') continue;
      if (next(k) &&
          (_minuteUnits.containsKey(at(k + 1)) ||
              _minuteTens.containsKey(at(k + 1))) &&
          k + 2 < words.length &&
          adjacent(k + 1, k + 2) &&
          _isDuration(at(k + 2))) {
        continue;
      }
      final start = words[k - (hour > 20 ? 1 : 0)].start;
      var end = words[k].end;
      // «в девять часов тридцать минут», «в восемь тридцать».
      var m = k + 1;
      if (m < words.length &&
          adjacent(m - 1, m) &&
          _hourNouns.contains(at(m))) {
        m++;
      }
      int? minute;
      if (m < words.length && adjacent(m - 1, m)) {
        final tens = _minuteTens[at(m)];
        // «в шесть ноль пять» — 6:05, «в двадцать один ноль ноль» — 21:00.
        if (at(m) == 'ноль' && m + 1 < words.length && adjacent(m, m + 1)) {
          final unit = at(m + 1) == 'ноль'
              ? 0
              : at(m + 1) == 'два'
                  ? 2
                  : _minuteUnits[at(m + 1)];
          if (unit != null) {
            minute = unit;
            m++;
            if (m + 1 < words.length &&
                adjacent(m, m + 1) &&
                _minuteNouns.contains(at(m + 1))) {
              m++;
            }
            end = words[m].end;
          }
        } else if (tens != null) {
          minute = tens;
          if (tens >= 20 &&
              m + 1 < words.length &&
              adjacent(m, m + 1) &&
              _minuteUnits.containsKey(at(m + 1))) {
            minute += _minuteUnits[at(m + 1)]!;
            m++;
          }
          if (m + 1 < words.length &&
              adjacent(m, m + 1) &&
              _minuteNouns.contains(at(m + 1))) {
            m++;
          }
          end = words[m].end;
        }
      }
      result.add(SpokenTimeMatch(start, end, hour, minute));
      i = minute == null ? k : m;
    }
    return result;
  }

  /// Порядковые числа месяца в родительном падеже.
  static const Map<String, int> _dayOrdinals = <String, int>{
    'первого': 1,
    'второго': 2,
    'третьего': 3,
    'четвертого': 4,
    'пятого': 5,
    'шестого': 6,
    'седьмого': 7,
    'восьмого': 8,
    'девятого': 9,
    'десятого': 10,
    'одиннадцатого': 11,
    'двенадцатого': 12,
    'тринадцатого': 13,
    'четырнадцатого': 14,
    'пятнадцатого': 15,
    'шестнадцатого': 16,
    'семнадцатого': 17,
    'восемнадцатого': 18,
    'девятнадцатого': 19,
    'двадцатого': 20,
    'тридцатого': 30,
  };

  static const Set<String> _monthsGenitive = <String>{
    'января',
    'февраля',
    'марта',
    'апреля',
    'мая',
    'июня',
    'июля',
    'августа',
    'сентября',
    'октября',
    'ноября',
    'декабря',
  };

  /// Число месяца словами перед названием месяца: (число, номер последнего
  /// слова числа). Без месяца «пятого» — скорее час («полпятого»).
  static (int, int)? _dayOrdinal(
    List<RegExpMatch> words,
    int i,
    String Function(int) at,
    bool Function(int) next,
  ) {
    var value = _dayOrdinals[at(i)];
    var last = i;
    if (value == null) {
      final tens = switch (at(i)) {
        'двадцать' => 20,
        'тридцать' => 30,
        _ => null,
      };
      if (tens == null || !next(i)) return null;
      final unit = _dayOrdinals[at(i + 1)];
      if (unit == null || unit > 9 || (tens == 30 && unit > 1)) return null;
      value = tens + unit;
      last = i + 1;
    }
    if (!next(last) || !_monthsGenitive.contains(at(last + 1))) return null;
    return (value, last);
  }

  static SpokenTimeMatch _half(int start, int end, int ordinal) =>
      SpokenTimeMatch(
        start,
        end,
        ordinal == 1 ? 12 : ordinal - 1,
        30,
        twelveHour: true,
      );
}

/// Время словами в тексте: [start]–[end] — слова времени без предлога.
/// Число месяца словами — тоже здесь ([SpokenTimeMatch.date]).
final class SpokenTimeMatch {
  const SpokenTimeMatch(
    this.start,
    this.end,
    this.hour,
    this.minute, {
    this.named = false,
    this.twelveHour = false,
  }) : day = null;

  /// Число месяца словами: «пятнадцатого ноября» → «15» перед «ноября».
  const SpokenTimeMatch.date(this.start, this.end, int this.day)
      : hour = 0,
        minute = null,
        named = false,
        twelveHour = false;

  final int start;
  final int end;
  final int hour;

  /// Минуты, если названы: «в восемь тридцать». `null` — только час.
  final int? minute;

  /// Число месяца, если это дата, а не время.
  final int? day;

  /// Время названо словом, а не числом: «полдень», «полночь». Голосовой
  /// текст его не переписывает цифрами — «в полдень» и так понятно.
  final bool named;

  /// Разговорная форма на двенадцатичасовом циферблате: «полшестого»,
  /// «без четверти пять» — утро это или вечер, из неё не видно.
  final bool twelveHour;

  /// «9», «8:30», «15» (число месяца).
  String get digits => day != null
      ? '$day'
      : minute == null
          ? '$hour'
          : '$hour:${minute!.toString().padLeft(2, '0')}';
}
