import '../models/task.dart';
import 'verb_forms.dart';

/// Почему срок не удалось однозначно разобрать. Коннектор превращает это
/// в уточнение, а не сохраняет догадку.
enum DueIssue {
  none,

  /// Явно указанный день («сегодня», дата) или время на этот день уже прошли.
  inPast,

  /// Дата вида 31.02 не существует.
  invalidDate,

  /// Время вида 24:00, 25:10 или «в 7.5» не распознано.
  invalidTime,

  /// В команде несколько разных дней: «сегодня или завтра», «10.11 или 12.11».
  conflictingDays,

  /// В команде несколько разных времён: «в 10:00 или в 11:00».
  conflictingTimes,

  /// Час от 1 до 6 без уточнения: «к 5», «в 3». Может быть и утро,
  /// и вечер, поэтому срок не угадывается.
  ambiguousHour,
}

/// Полуоткрытый интервал символов `[start, end)` в исходном тексте сообщения.
final class CharSpan {
  const CharSpan(this.start, this.end) : assert(start <= end);

  final int start;
  final int end;

  int get length => end - start;

  bool contains(int position) => position >= start && position < end;

  /// Интервал целиком лежит внутри этого.
  bool covers(CharSpan other) => other.start >= start && other.end <= end;

  @override
  bool operator ==(Object other) =>
      other is CharSpan && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => '[$start, $end)';
}

final class DueParseResult {
  const DueParseResult({
    this.dueAt,
    this.precision,
    this.issue = DueIssue.none,
    this.spans = const <CharSpan>[],
  });

  final DateTime? dueAt;

  /// Точность [dueAt]; `null`, когда срока нет.
  final DuePrecision? precision;
  final DueIssue issue;

  /// Фрагменты текста, которые разбор сроков счёл своими: даты, время,
  /// «сегодня/завтра/послезавтра», «в 10 утра», дни недели («в следующую
  /// пятницу»), «через 3 дня», «на выходных» вместе с предлогом перед ними
  /// («на завтра», «в 18:00», «с 15:00»). Смещения — в том тексте, который
  /// передан в [DueParser.parse]. Заполняется и при [issue] ≠ none, чтобы
  /// неверный срок не попал в название задачи. Отсортированы, не пересекаются.
  final List<CharSpan> spans;
}

/// Разбор сроков в русском тексте: только то, что можно понять однозначно.
///
/// Понимает даты ДД.ММ[.ГГ], время, «сегодня/завтра/послезавтра», дни недели
/// с предлогами и сокращения пн…вс, «через N минут/часов/дней/недель/
/// месяцев», «на выходных», «в конце недели», «на следующей неделе». Правила
/// для дней недели — у [_calendarMentions] и в docs/CORPUS.md.
///
/// Работает с текстом любой формы: регистр и «ё» приводятся посимвольно без
/// изменения длины, поэтому [DueParseResult.spans] указывают прямо в исходную
/// строку. Пробелы не схлопываются — границы слов берутся по токенам.
final class DueParser {
  const DueParser();

  static final RegExp _word = RegExp('[a-zа-я0-9]+');

  /// ЧЧ:ММ с необязательными секундами. Диапазон проверяется отдельно,
  /// чтобы «25:10» стало уточнением, а не молча пропало.
  static final RegExp _colonTime =
      RegExp(r'(?<![\d.:])(\d{1,2}):(\d{2})(?::(\d{2}))?(?![\d:])');

  /// Число с точкой: дата ДД.ММ[.ГГ|.ГГГГ] или время ЧЧ.ММ — решается
  /// по контексту. Точка в конце предложения не считается частью числа.
  static final RegExp _dotted = RegExp(
    r'(?<![\d.:])(\d{1,2})\.(\d{1,2})(?:\.(\d{4}|\d{2}))?(?!\d|\.\d)',
  );

  /// Предлоги, после которых указывается исходный срок при переносе:
  /// «с 15:00 на 17:00».
  static const Set<String> _sourcePrepositions = <String>{'с', 'со', 'от'};

  /// Предлоги, которые входят во фрагмент срока, если стоят прямо перед ним.
  static const Set<String> _attachedPrepositions = <String>{
    'в',
    'во',
    'на',
    'к',
    'ко',
    'до',
    'с',
    'со',
    'от',
    'через',
    'по',
  };

  /// После этих предлогов одиночное число — час: «в 10», «к 9 утра».
  static const Set<String> _hourPrepositions = <String>{'в', 'во', 'к', 'ко'};

  /// Слова после часа: «в 9 утра», «в 7 вечера», «в 10 часов».
  static const Set<String> _hourSuffixes = <String>{
    ..._dayparts,
    ..._hourWords,
  };

  static const Set<String> _dayparts = <String>{
    'утра',
    'дня',
    'вечера',
    'ночи',
  };

  /// После этих слов может идти ещё и часть суток: «в 2 часа дня».
  static const Set<String> _hourWords = <String>{'час', 'часа', 'часов'};

  /// Вежливые слова после часа не мешают ему быть временем:
  /// «завтра в 10 пожалуйста».
  static const Set<String> _politeWords = <String>{
    'пожалуйста',
    'пожалуйсто',
    'плиз',
    'пж',
    'пжлст',
  };

  /// Единицы после числа с точкой: «1.5 кг», «3.5 метра» — количество,
  /// а не дата. Только точные формы: «гр» не должно поймать «групповой».
  static const Set<String> _units = <String>{
    'кг',
    'кило',
    'г',
    'гр',
    'мг',
    'л',
    'мл',
    'м',
    'км',
    'см',
    'мм',
    'шт',
    'т',
    'р',
    'руб',
    'раз',
    'раза',
    'метр',
    'метра',
    'метров',
    'тонна',
    'тонны',
    'тонн',
    'евро',
    'балла',
    'баллов',
    'гб',
    'мб',
  };

  /// Начала длинных единиц: «граммов», «литра», «процентов».
  static const List<String> _unitPrefixes = <String>[
    'грамм',
    'килограмм',
    'литр',
    'миллилитр',
    'сантиметр',
    'миллиметр',
    'километр',
    'штук',
    'процент',
    'рубл',
    'доллар',
  ];

  static const Map<String, int> _dayWords = <String, int>{
    'сегодня': 0,
    'завтра': 1,
    'послезавтра': 2,
  };

  /// Посимвольная нормализация: нижний регистр и «ё» → «е» без изменения
  /// длины строки. Символ, у которого нижний регистр другой длины, остаётся.
  static String normalizeChars(String text) {
    final buffer = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      var lower = char.toLowerCase();
      if (lower.length != 1) lower = char;
      buffer.write(lower == 'ё' ? 'е' : lower);
    }
    return buffer.toString();
  }

  DueParseResult parse(String text, DateTime now) {
    final normalized = normalizeChars(text);
    final today = DateTime(now.year, now.month, now.day);
    final words = _word.allMatches(normalized).toList(growable: false);

    final times = <_Mention<(int, int)>>[];
    final dates = <_Mention<DateTime>>[];
    final spans = <CharSpan>[];
    // Концы фрагментов исходного срока «с 10:00»: день сразу за ними —
    // тоже исходный («с 10:00 в пятницу на понедельник»).
    final sourceEnds = <int>{};
    // Точные моменты «через N минут/часов».
    final moments = <DateTime>[];
    var dateText = normalized;
    var ambiguousHour = false;

    void consume(int start, int end, {bool source = false}) {
      final span = _withPreposition(normalized, words, start, end);
      spans.add(span);
      if (source) sourceEnds.add(span.end);
    }

    // Дни недели, «через N …» и «сегодня/завтра»: ищутся после времени,
    // потому что «в пятницу» сегодня зависит от того, прошло ли уже
    // названное время.
    void collectDays() {
      final calendar = <_Found>[
        ..._relativeMentions(normalized, words, now),
        ..._calendarMentions(
          normalized,
          words,
          now,
          _pickDistinct(times),
          _merge(spans),
          sourceEnds,
        ),
      ];
      for (final found in calendar) {
        consume(found.start, found.end);
        final moment = found.moment;
        if (moment != null) moments.add(moment);
        final date = found.date;
        if (date != null) dates.add(_Mention(date, found.isSource));
        final time = found.time;
        if (time != null) times.add(_Mention(time, found.isSource));
      }
      for (final word in words) {
        final offset = _dayWords[word.group(0)];
        if (offset == null) continue;
        consume(word.start, word.end);
        dates.add(
          _Mention(
            DateTime(today.year, today.month, today.day + offset),
            _isSource(normalized, word.start),
          ),
        );
      }
    }

    // При ошибке во времени или дате дни всё равно занимают свои фрагменты,
    // чтобы «через 3 дня» или «завтра» не попали в название.
    DueParseResult fail(DueIssue issue) {
      collectDays();
      return DueParseResult(
        issue: issue,
        spans: _bridge(normalized, words, _merge(spans)),
      );
    }

    void mask(int start, int end) {
      dateText = dateText.replaceRange(start, end, ' ' * (end - start));
    }

    for (final match in _colonTime.allMatches(normalized)) {
      var hour = int.parse(match.group(1)!);
      final minute = int.parse(match.group(2)!);
      final second = match.group(3);
      final suffix = _suffixAfter(normalized, words, match.end);
      consume(
        match.start,
        suffix.isEmpty ? match.end : suffix.last.end,
        source: _isSource(normalized, match.start),
      );
      if (hour > 23 ||
          minute > 59 ||
          (second != null && int.parse(second) > 59)) {
        return fail(DueIssue.invalidTime);
      }
      if (suffix.isNotEmpty) {
        final adjusted = _applySuffix(hour, suffix.last.group(0)!);
        if (adjusted == null) return fail(DueIssue.invalidTime);
        hour = adjusted;
      }
      times.add(
        _Mention((hour, minute), _isSource(normalized, match.start)),
      );
      mask(match.start, match.end);
    }

    for (final match in _dotted.allMatches(dateText)) {
      // Предыдущее слово — по исходному тексту: в «в 10:00 15.11» перед
      // 15.11 стоит «00», а не «в», поэтому 15.11 — дата, а не время.
      final previous = _previousWord(normalized, match.start);
      if (previous != null &&
          (previous.startsWith('верси') || previous == 'v')) {
        continue;
      }
      // «через 1.5 часа» — количество, а не дата 1 мая.
      if (previous == 'через') continue;
      final first = int.parse(match.group(1)!);
      final secondText = match.group(2)!;
      final yearText = match.group(3);
      if (yearText == null &&
          (_isQuantity(normalized, words, match.end) ||
              _isVersion(words, match))) {
        continue;
      }
      final second = int.parse(secondText);
      final source = _sourcePrepositions.contains(previous);
      final looksLikeTime =
          yearText == null && secondText.length == 2 && first <= 23;
      consume(match.start, match.end, source: source);

      if (yearText == null && previous == 'в') {
        // После «в» число с точкой — это время: «в 19.30».
        if (!looksLikeTime || second > 59) {
          return fail(DueIssue.invalidTime);
        }
        times.add(_Mention((first, second), source));
        mask(match.start, match.end);
        continue;
      }

      final date = _resolveDate(first, second, yearText, today);
      if (date != null) {
        if (yearText != null && date.isBefore(today)) {
          return fail(DueIssue.inPast);
        }
        dates.add(_Mention(date, source));
        mask(match.start, match.end);
        continue;
      }
      if (looksLikeTime && second <= 59) {
        // «на 18.30»: такой даты нет, но это корректное время.
        times.add(_Mention((first, second), source));
        mask(match.start, match.end);
        continue;
      }
      return fail(DueIssue.invalidDate);
    }

    // Одиночный час: «в 10», «к 9 утра», «в 7 вечера». Только после «в/к»
    // и только если дальше нет обычного слова — «в 2 магазина» не время.
    // Исключение — час сразу после дня: «завтра в 10 созвон», «в следующий
    // понедельник в 9 планёрка». Здесь число уже не может быть количеством.
    final masked = _word.allMatches(dateText).toList(growable: false);
    final dayEnds = <int>{
      for (final found in <_Found>[
        ..._relativeMentions(normalized, words, now),
        ..._calendarMentions(
          normalized,
          words,
          now,
          const <(int, int)>{},
          _merge(spans),
          sourceEnds,
        ),
      ])
        if (found.date != null) found.end,
      for (final word in words)
        if (_dayWords.containsKey(word.group(0))) word.end,
    };
    bool afterDay(RegExpMatch preposition) {
      for (final end in dayEnds) {
        if (end > preposition.start) continue;
        final gap = normalized.substring(end, preposition.start).trim();
        if (gap.isEmpty || gap == ',') return true;
      }
      return false;
    }

    for (var i = 0; i < masked.length; i++) {
      final token = masked[i];
      final value = token.group(0)!;
      if (value.length > 2 || int.tryParse(value) == null) continue;
      if (i == 0 || !_hourPrepositions.contains(masked[i - 1].group(0))) {
        continue;
      }
      if (!_onlySpaces(dateText, masked[i - 1].end, token.start)) continue;
      if (_touchesNumberPunctuation(dateText, token.start, token.end)) {
        continue;
      }
      final suffix = _suffixAfter(dateText, masked, token.end);
      final next = i + 1 < masked.length ? masked[i + 1] : null;
      final nextWord = next?.group(0);
      final afterNext = i + 2 < masked.length ? masked[i + 2] : null;
      final freeAfter = next == null
          ? _onlyPunctuation(dateText, token.end, dateText.length)
          : suffix.isNotEmpty ||
              _dayWords.containsKey(nextWord) ||
              _politeWords.contains(nextWord) ||
              // «в 10 позвонить»: час перед действием.
              (_onlySpaces(dateText, token.end, next.start) &&
                  isInfinitive(nextWord!)) ||
              // «в 10 или в 11», «в 9 и в 18» — перечисление времён,
              // а не «10 штук».
              nextWord == 'или' ||
              (nextWord == 'и' &&
                  afterNext != null &&
                  _hourPrepositions.contains(afterNext.group(0))) ||
              // «в 10 в пятницу», «в 9 через 2 дня»: дальше снова срок.
              _startsDayPhrase(masked, i + 1) ||
              // «завтра в 10 созвон»: час сразу после дня.
              afterDay(masked[i - 1]) ||
              (!_onlySpaces(dateText, token.end, next.start) &&
                  _onlyPunctuation(dateText, token.end, next.start));
      if (!freeAfter) continue;
      // «позвонить в 03» — номер службы, а не время: час с ведущим нулём
      // считается временем только с уточнением «в 07 утра».
      if (suffix.isEmpty && value.length == 2 && value.startsWith('0')) {
        continue;
      }
      var hour = int.parse(value);
      if (hour > 23) continue;
      consume(token.start, suffix.isEmpty ? token.end : suffix.last.end);
      if (suffix.isNotEmpty) {
        final adjusted = _applySuffix(hour, suffix.last.group(0)!);
        if (adjusted == null) return fail(DueIssue.invalidTime);
        hour = adjusted;
      } else if (hour >= 1 && hour <= 6) {
        // «к 5» — и 05:00, и 17:00. Фрагмент уже занят, чтобы «к 5» не
        // попало в название; срок уточняется у пользователя.
        ambiguousHour = true;
      }
      times.add(_Mention((hour, 0), false));
    }

    collectDays();

    final merged = _bridge(normalized, words, _merge(spans));
    final days = _pickDistinct(dates);
    if (days.length > 1) {
      return DueParseResult(issue: DueIssue.conflictingDays, spans: merged);
    }
    final clock = _pickDistinct(times);
    if (clock.length > 1) {
      return DueParseResult(issue: DueIssue.conflictingTimes, spans: merged);
    }

    if (ambiguousHour) {
      return DueParseResult(issue: DueIssue.ambiguousHour, spans: merged);
    }

    final explicitDay = days.isEmpty ? null : days.single;
    final time = clock.isEmpty ? null : clock.single;
    if (explicitDay == null && time == null) {
      return DueParseResult(spans: merged);
    }

    if (time == null) {
      if (explicitDay!.isBefore(today)) {
        return DueParseResult(issue: DueIssue.inPast, spans: merged);
      }
      return DueParseResult(
        dueAt: explicitDay,
        precision: DuePrecision.date,
        spans: merged,
      );
    }

    final day = explicitDay ?? today;
    var result = DateTime(day.year, day.month, day.day, time.$1, time.$2);
    // «через 2 часа» в ночь перевода часов: настенное время неоднозначно,
    // поэтому берётся точный момент.
    for (final moment in moments) {
      if (moment.year == result.year &&
          moment.month == result.month &&
          moment.day == result.day &&
          moment.hour == result.hour &&
          moment.minute == result.minute) {
        result = moment;
      }
    }
    if (!result.isAfter(now)) {
      if (explicitDay != null) {
        return DueParseResult(issue: DueIssue.inPast, spans: merged);
      }
      // Только время, и оно уже прошло: ближайшее будущее — завтра.
      result = DateTime(day.year, day.month, day.day + 1, time.$1, time.$2);
    }
    return DueParseResult(
      dueAt: result,
      precision: DuePrecision.dateTime,
      spans: merged,
    );
  }

  // ------------------------------------------- дни недели и «через N …»

  /// Формы дней недели → номер дня ([DateTime.monday] … [DateTime.sunday])
  /// и предлоги, с которыми форма считается сроком. Сокращения «пн» … «вс»
  /// принимают любой из этих предлогов.
  static const Map<String, (int, Set<String>)> _weekdayForms =
      <String, (int, Set<String>)>{
    'понедельник': (DateTime.monday, _accusativePrepositions),
    'понедельника': (DateTime.monday, _genitivePrepositions),
    'понедельнику': (DateTime.monday, _dativePrepositions),
    'пн': (DateTime.monday, _anyWeekdayPreposition),
    'вторник': (DateTime.tuesday, _accusativePrepositions),
    'вторника': (DateTime.tuesday, _genitivePrepositions),
    'вторнику': (DateTime.tuesday, _dativePrepositions),
    'вт': (DateTime.tuesday, _anyWeekdayPreposition),
    'среда': (DateTime.wednesday, _accusativePrepositions),
    'среду': (DateTime.wednesday, _accusativePrepositions),
    'среды': (DateTime.wednesday, _genitivePrepositions),
    'среде': (DateTime.wednesday, _dativePrepositions),
    'ср': (DateTime.wednesday, _anyWeekdayPreposition),
    'четверг': (DateTime.thursday, _accusativePrepositions),
    'четверга': (DateTime.thursday, _genitivePrepositions),
    'четвергу': (DateTime.thursday, _dativePrepositions),
    'чт': (DateTime.thursday, _anyWeekdayPreposition),
    'пятница': (DateTime.friday, _accusativePrepositions),
    'пятницу': (DateTime.friday, _accusativePrepositions),
    'пятницы': (DateTime.friday, _genitivePrepositions),
    'пятнице': (DateTime.friday, _dativePrepositions),
    'пт': (DateTime.friday, _anyWeekdayPreposition),
    'суббота': (DateTime.saturday, _accusativePrepositions),
    'субботу': (DateTime.saturday, _accusativePrepositions),
    'субботы': (DateTime.saturday, _genitivePrepositions),
    'субботе': (DateTime.saturday, _dativePrepositions),
    'сб': (DateTime.saturday, _anyWeekdayPreposition),
    'воскресенье': (DateTime.sunday, _accusativePrepositions),
    'воскресенья': (DateTime.sunday, _genitivePrepositions),
    'воскресенью': (DateTime.sunday, _dativePrepositions),
    'вс': (DateTime.sunday, _anyWeekdayPreposition),
  };

  /// «в пятницу», «на среду», «по четверг».
  static const Set<String> _accusativePrepositions = <String>{
    'в',
    'во',
    'на',
    'по',
  };

  /// «до пятницы»; «с пятницы» — исходный срок при переносе.
  static const Set<String> _genitivePrepositions = <String>{
    'до',
    'с',
    'со',
    'от',
  };

  /// «к пятнице». «в среде» не срок: это «в среде разработки».
  static const Set<String> _dativePrepositions = <String>{'к', 'ко'};

  static const Set<String> _anyWeekdayPreposition = <String>{
    ..._accusativePrepositions,
    ..._genitivePrepositions,
    ..._dativePrepositions,
  };

  /// Именительный падеж и сокращения: «пятница 10:00», «пт 18:00».
  static const Set<String> _nominativeWeekdays = <String>{
    'понедельник',
    'вторник',
    'среда',
    'четверг',
    'пятница',
    'суббота',
    'воскресенье',
    'пн',
    'вт',
    'ср',
    'чт',
    'пт',
    'сб',
    'вс',
  };

  /// Начала слов, с которыми «среда» — окружение, а не день недели:
  /// «среда разработки», «к среде исполнения», «до среды тестирования».
  static const List<String> _environmentStems = <String>[
    'разработ',
    'обитани',
    'окружени',
    'исполнени',
    'выполнени',
    'сборк',
    'тестировани',
    'программировани',
    'развертывани',
    'обучени',
    'запуск',
  ];

  static bool _isEnvironmentNoun(String word) =>
      _environmentStems.any((String stem) => word.startsWith(stem));

  /// «следующую», «эту», «ближайшую» перед днём недели или «неделе».
  static _WeekScope? _weekModifier(String word) {
    if (word.startsWith('следующ') || word.startsWith('будущ')) {
      return _WeekScope.next;
    }
    if (word.startsWith('ближайш')) return _WeekScope.nearest;
    return _thisModifiers.contains(word) ? _WeekScope.current : null;
  }

  static const Set<String> _thisModifiers = <String>{
    'этот',
    'эту',
    'это',
    'этой',
    'этого',
    'этому',
    'эти',
    'этих',
  };

  /// Числа словами после «через». Десятки складываются с единицами:
  /// «двадцать пять». Собирательные «двое суток», «трое суток» — тоже числа.
  static const Map<String, int> _numberWords = <String, int>{
    'один': 1,
    'одну': 1,
    'одна': 1,
    'одно': 1,
    'одни': 1,
    'два': 2,
    'две': 2,
    'пару': 2,
    'двое': 2,
    'три': 3,
    'трое': 3,
    'четыре': 4,
    'четверо': 4,
    'пять': 5,
    'пятеро': 5,
    'шесть': 6,
    'шестеро': 6,
    'семь': 7,
    'семеро': 7,
    'восемь': 8,
    'девять': 9,
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
    'двадцать': 20,
    'тридцать': 30,
    'сорок': 40,
    'пятьдесят': 50,
    'шестьдесят': 60,
  };

  /// Десятки, после которых может идти единица: «двадцать пять минут».
  static const Set<String> _tensWords = <String>{
    'двадцать',
    'тридцать',
    'сорок',
    'пятьдесят',
  };

  /// Единицы после «через N».
  static const Map<String, _Unit> _relativeUnits = <String, _Unit>{
    'минуту': _Unit.minute,
    'минуты': _Unit.minute,
    'минут': _Unit.minute,
    'мин': _Unit.minute,
    'час': _Unit.hour,
    'часа': _Unit.hour,
    'часов': _Unit.hour,
    'ч': _Unit.hour,
    'день': _Unit.day,
    'дня': _Unit.day,
    'дней': _Unit.day,
    'сутки': _Unit.day,
    'суток': _Unit.day,
    'неделю': _Unit.week,
    'недели': _Unit.week,
    'недель': _Unit.week,
    'месяц': _Unit.month,
    'месяца': _Unit.month,
    'месяцев': _Unit.month,
  };

  /// Единицы, которые можно назвать без числа: «через час», «через неделю»,
  /// в том числе ласкательные: «через минутку», «через часик».
  static const Map<String, (_Unit, int)> _singleUnits = <String, (_Unit, int)>{
    'минуту': (_Unit.minute, 1),
    'минутку': (_Unit.minute, 1),
    'минуточку': (_Unit.minute, 1),
    'час': (_Unit.hour, 1),
    'часик': (_Unit.hour, 1),
    'часок': (_Unit.hour, 1),
    'полчаса': (_Unit.minute, 30),
    'полчасика': (_Unit.minute, 30),
    'день': (_Unit.day, 1),
    'денек': (_Unit.day, 1),
    'сутки': (_Unit.day, 1),
    'неделю': (_Unit.week, 1),
    'недельку': (_Unit.week, 1),
    'месяц': (_Unit.month, 1),
    'месяцок': (_Unit.month, 1),
  };

  /// «2ч», «15мин» — число вплотную к единице.
  static final RegExp _glued = RegExp(r'^(\d{1,3})(ч|мин)$');

  /// Слова сразу после единицы, с которыми «через …» — не срок:
  /// «через час пик», «через 2 часа дня».
  static const Set<String> _relativeBlockers = <String>{'пик', ..._dayparts};

  /// С [index] начинается ещё один срок: день недели, «через …» или
  /// предлог перед днём: «в 10 в пятницу», «в 10 на следующей неделе».
  static bool _startsDayPhrase(List<RegExpMatch> words, int index) {
    if (index >= words.length) return false;
    final word = words[index].group(0)!;
    if (_weekdayForms.containsKey(word) || word == 'через') return true;
    if (!_attachedPrepositions.contains(word) || index + 1 >= words.length) {
      return false;
    }
    final next = words[index + 1].group(0)!;
    return _weekdayForms.containsKey(next) ||
        _dayWords.containsKey(next) ||
        _weekModifier(next) != null ||
        next == 'выходных' ||
        next == 'выходные' ||
        next == 'конце' ||
        next == 'концу' ||
        next == 'конца';
  }

  /// Число с позиции [i]: цифрами, словами («двадцать пять»), с запятой
  /// или точкой («2,5», «1.5») или диапазоном («10-15»). Возвращает
  /// значения (два — для диапазона) и индекс последнего слова числа.
  static (List<double>, int)? _readNumber(
    String text,
    List<RegExpMatch> words,
    int i,
  ) {
    final value = words[i].group(0)!;
    if (value.length <= 3 && _allDigits.hasMatch(value)) {
      final whole = int.parse(value);
      if (i + 1 < words.length) {
        final next = words[i + 1].group(0)!;
        final between = text.substring(words[i].end, words[i + 1].start);
        if ((between == ',' || between == '.') &&
            next.length == 1 &&
            _allDigits.hasMatch(next)) {
          return (<double>[whole + int.parse(next) / 10], i + 1);
        }
        if ((between == '-' || between == '–') &&
            next.length <= 3 &&
            _allDigits.hasMatch(next)) {
          return (
            <double>[whole.toDouble(), int.parse(next).toDouble()],
            i + 1
          );
        }
      }
      return (<double>[whole.toDouble()], i);
    }
    final word = _numberWords[value];
    if (word == null) return null;
    if (_tensWords.contains(value) &&
        i + 1 < words.length &&
        _onlySpaces(text, words[i].end, words[i + 1].start)) {
      final ones = _numberWords[words[i + 1].group(0)!];
      if (ones != null && ones < 10) {
        return (<double>[(word + ones).toDouble()], i + 1);
      }
    }
    return (<double>[word.toDouble()], i);
  }

  /// Одна часть длительности с позиции [i]: «2 часа», «час», «пол часа»,
  /// «2ч». Возвращает единицу, значения и индекс последнего слова.
  static (_Unit, List<double>, int)? _readComponent(
    String text,
    List<RegExpMatch> words,
    int i,
  ) {
    if (i >= words.length) return null;
    final value = words[i].group(0)!;
    final single = _singleUnits[value];
    if (single != null) {
      return (single.$1, <double>[single.$2.toDouble()], i);
    }
    final glued = _glued.firstMatch(value);
    if (glued != null) {
      return (
        _relativeUnits[glued.group(2)!]!,
        <double>[double.parse(glued.group(1)!)],
        i,
      );
    }
    bool adjacentTo(int k) =>
        k + 1 < words.length &&
        _onlySpaces(text, words[k].end, words[k + 1].start);
    if (value == 'пол' && adjacentTo(i) && words[i + 1].group(0) == 'часа') {
      return (_Unit.minute, <double>[30], i + 1);
    }
    if ((value == 'полтора' || value == 'полторы') &&
        adjacentTo(i) &&
        _relativeUnits[words[i + 1].group(0)!] == _Unit.hour) {
      return (_Unit.minute, <double>[90], i + 1);
    }
    final number = _readNumber(text, words, i);
    if (number == null) return null;
    final (values, last) = number;
    if (!adjacentTo(last)) return null;
    final unit = _relativeUnits[words[last + 1].group(0)!];
    if (unit == null || values.any((double v) => v <= 0)) return null;
    // Дробь — только у часов: «через 2,5 часа» = 150 минут.
    if (values.any((double v) => v != v.roundToDouble())) {
      if (unit != _Unit.hour) return null;
      return (
        _Unit.minute,
        <double>[for (final v in values) (v * 60).roundToDouble()],
        last + 1,
      );
    }
    return (unit, values, last + 1);
  }

  /// «через 3 дня», «через час», «через пару недель», «через полчаса»,
  /// «через 2 часа 30 минут». Минуты и часы дают точное время, дни,
  /// недели и месяцы — день. Диапазон «через 10-15 минут» даёт два срока,
  /// и разбор переспрашивает. Минуты и часы отсчитываются по реальному
  /// времени (переход на зимнее время не сдвигает срок), дни — по
  /// календарю.
  List<_Found> _relativeMentions(
    String text,
    List<RegExpMatch> words,
    DateTime now,
  ) {
    final result = <_Found>[];
    final today = DateTime(now.year, now.month, now.day);
    for (var i = 0; i + 1 < words.length; i++) {
      if (words[i].group(0) != 'через') continue;
      if (!_onlySpaces(text, words[i].end, words[i + 1].start)) continue;
      final first = _readComponent(text, words, i + 1);
      if (first == null) continue;
      final components = <(_Unit, List<double>)>[(first.$1, first.$2)];
      var last = first.$3;
      // «через 2 часа 30 минут», «через час и 15 минут»: следующая часть —
      // только с меньшей единицей.
      while (last + 1 < words.length) {
        var next = last + 1;
        if (!_onlySpaces(text, words[last].end, words[next].start)) break;
        if (words[next].group(0) == 'и' &&
            next + 1 < words.length &&
            _onlySpaces(text, words[next].end, words[next + 1].start)) {
          next++;
        }
        final more = _readComponent(text, words, next);
        if (more == null || more.$1.index >= components.last.$1.index) break;
        components.add((more.$1, more.$2));
        last = more.$3;
      }
      // «через минуту-другую», «через час пик», «через 2 часа дня» —
      // не срок: фраза остаётся в названии целиком.
      final end = words[last].end;
      if (end < text.length && (text[end] == '-' || text[end] == '–')) {
        continue;
      }
      if (last + 1 < words.length &&
          _onlySpaces(text, end, words[last + 1].start) &&
          _relativeBlockers.contains(words[last + 1].group(0))) {
        continue;
      }
      // Диапазон допустим только в одиночной части: «через 10-15 минут».
      if (components.length > 1 &&
          components.any(((_Unit, List<double>) c) => c.$2.length > 1)) {
        continue;
      }
      final variants = components.length == 1 && first.$2.length == 2
          ? <List<(_Unit, int)>>[
              <(_Unit, int)>[(first.$1, first.$2[0].toInt())],
              <(_Unit, int)>[(first.$1, first.$2[1].toInt())],
            ]
          : <List<(_Unit, int)>>[
              <(_Unit, int)>[
                for (final c in components) (c.$1, c.$2.first.toInt()),
              ],
            ];
      final start = words[i + 1].start;
      for (final parts in variants) {
        var date = today;
        var minutes = 0;
        for (final (unit, amount) in parts) {
          switch (unit) {
            case _Unit.minute:
              minutes += amount;
            case _Unit.hour:
              minutes += amount * 60;
            case _Unit.day:
              date = DateTime(date.year, date.month, date.day + amount);
            case _Unit.week:
              date = DateTime(date.year, date.month, date.day + 7 * amount);
            case _Unit.month:
              date = _addMonths(date, amount);
          }
        }
        if (minutes == 0) {
          result.add(_Found(start, end, date: date));
          continue;
        }
        final base = date == today
            ? now
            : DateTime(
                date.year,
                date.month,
                date.day,
                now.hour,
                now.minute,
                now.second,
              );
        // Секунды отбрасываются: срок хранится с точностью до минуты.
        final exact = base.add(Duration(minutes: minutes));
        final moment = exact.subtract(
          Duration(
            seconds: exact.second,
            milliseconds: exact.millisecond,
            microseconds: exact.microsecond,
          ),
        );
        result.add(
          _Found(
            start,
            end,
            date: DateTime(moment.year, moment.month, moment.day),
            time: (moment.hour, moment.minute),
            moment: moment,
          ),
        );
      }
    }
    return result;
  }

  static final RegExp _allDigits = RegExp(r'^\d+$');

  /// Дни недели, «на следующей неделе», «на выходных», «в конце недели».
  ///
  /// День недели без уточнения — ближайший будущий. Если это сегодня, то
  /// с временем, которое ещё не прошло, — сегодня, иначе (и без времени) —
  /// через неделю: «в понедельник» в понедельник почти всегда значит
  /// следующий. «в следующую пятницу», «на следующей неделе в пятницу» —
  /// пятница следующей календарной недели (недели начинаются с
  /// понедельника). «в эту пятницу» — пятница текущей недели, даже если
  /// она уже прошла: тогда срок станет уточнением «уже прошло».
  List<_Found> _calendarMentions(
    String text,
    List<RegExpMatch> words,
    DateTime now,
    Set<(int, int)> clock,
    List<CharSpan> taken,
    Set<int> sourceEnds,
  ) {
    final today = DateTime(now.year, now.month, now.day);
    final monday =
        DateTime(today.year, today.month, today.day - today.weekday + 1);
    DateTime weekDay(int weekOffset, int weekday) => DateTime(
          monday.year,
          monday.month,
          monday.day + 7 * weekOffset + weekday - 1,
        );
    String word(int i) => words[i].group(0)!;
    bool adjacent(int left, int right) =>
        _onlySpaces(text, words[left].end, words[right].start);

    final used = <int>{};
    final result = <_Found>[];

    // «в конце недели», «к концу следующей недели» — пятница той недели.
    for (var i = 0; i + 1 < words.length; i++) {
      final value = word(i);
      if (value != 'конце' && value != 'концу' && value != 'конца') continue;
      var j = i + 1;
      var scope = _WeekScope.current;
      final modifier = _weekModifier(word(j));
      if (modifier != null && j + 1 < words.length && adjacent(i, j)) {
        scope = modifier;
        j++;
      }
      if (word(j) != 'недели' || !adjacent(j - 1, j)) continue;
      result.add(
        _Found(
          words[i].start,
          words[j].end,
          date: weekDay(scope == _WeekScope.next ? 1 : 0, DateTime.friday),
        ),
      );
      for (var k = i; k <= j; k++) {
        used.add(k);
      }
    }

    // «на следующей неделе», «следующей недели», «на следующую неделю»,
    // «на этой неделе».
    _WeekScope? weekScope;
    final weekSpans = <_Found>[];
    for (var i = 0; i + 1 < words.length; i++) {
      if (used.contains(i)) continue;
      final scope = _weekModifier(word(i));
      final next = word(i + 1);
      if (scope == null ||
          scope == _WeekScope.nearest ||
          (next != 'неделе' && next != 'недели' && next != 'неделю') ||
          !adjacent(i, i + 1)) {
        continue;
      }
      weekScope = scope;
      weekSpans.add(
        _Found(
          words[i].start,
          words[i + 1].end,
          date: scope == _WeekScope.next ? weekDay(1, DateTime.monday) : null,
        ),
      );
      used
        ..add(i)
        ..add(i + 1);
    }

    // «на выходных», «в эти выходные», «на следующих выходных».
    for (var i = 1; i < words.length; i++) {
      final value = word(i);
      if (value != 'выходных' && value != 'выходные') continue;
      var start = i;
      var scope = _WeekScope.nearest;
      final modifier = _weekModifier(word(i - 1));
      if (modifier != null && adjacent(i - 1, i)) {
        scope = modifier;
        start = i - 1;
      }
      if (start == 0 ||
          !adjacent(start - 1, start) ||
          word(start - 1) != (value == 'выходных' ? 'на' : 'в')) {
        continue;
      }
      final DateTime date;
      if (scope == _WeekScope.next) {
        date = weekDay(1, DateTime.saturday);
      } else if (today.weekday == DateTime.sunday &&
          scope == _WeekScope.nearest) {
        // В воскресенье ближайшие выходные — следующие.
        date = weekDay(1, DateTime.saturday);
      } else if (today.weekday == DateTime.sunday) {
        date = today;
      } else {
        date = weekDay(0, DateTime.saturday);
      }
      result.add(_Found(words[start].start, words[i].end, date: date));
    }

    final takenStarts = <int>{for (final span in taken) span.start};
    final weekdays = <_Found>[];
    // Индекс последнего принятого дня недели: «в среду или четверг» —
    // второй день без своего предлога всё равно день.
    int? lastWeekday;
    for (var i = 0; i < words.length; i++) {
      if (used.contains(i)) continue;
      final form = _weekdayForms[word(i)];
      if (form == null) continue;
      final (weekday, prepositions) = form;
      // «среда разработки», «к среде исполнения» — не день недели.
      if (weekday == DateTime.wednesday &&
          i + 1 < words.length &&
          adjacent(i, i + 1) &&
          _isEnvironmentNoun(word(i + 1))) {
        continue;
      }
      var start = i;
      var scope = _WeekScope.nearest;
      if (i > 0 && adjacent(i - 1, i)) {
        final modifier = _weekModifier(word(i - 1));
        if (modifier != null) {
          scope = modifier;
          start = i - 1;
        }
      }
      final preposition =
          start > 0 && adjacent(start - 1, start) ? word(start - 1) : null;
      final withPreposition =
          preposition != null && prepositions.contains(preposition);
      // Сразу за днём идёт время или дата: «пятница 10:00», «пт в 18».
      // Только без чужого предлога («в среде 10:00» — не день), не после
      // числа («60 вт в 10» — ватты) и в именительном падеже или с
      // уточнением недели: «развернуть среду в 10» — не день.
      final beforeTime = i + 1 < words.length &&
          _onlyPunctuation(text, words[i].end, words[i + 1].start) &&
          takenStarts.contains(words[i + 1].start) &&
          !_attachedPrepositions.contains(preposition) &&
          (preposition == null || !_allDigits.hasMatch(preposition)) &&
          (_nominativeWeekdays.contains(word(i)) || start != i);
      final alone = start == 0 && i == words.length - 1;
      // «в среду или четверг», «в пн, вт», «в эту субботу и воскресенье».
      final chained = lastWeekday != null &&
          start > 0 &&
          ((start - 1 == lastWeekday &&
                  text
                      .substring(words[lastWeekday].end, words[start].start)
                      .contains(',') &&
                  _onlyPunctuation(
                    text,
                    words[lastWeekday].end,
                    words[start].start,
                  )) ||
              (start - 2 == lastWeekday &&
                  (word(start - 1) == 'и' || word(start - 1) == 'или') &&
                  adjacent(start - 1, start) &&
                  _onlyPunctuation(
                    text,
                    words[lastWeekday].end,
                    words[start - 1].start,
                  )));
      if (!withPreposition && !beforeTime && !alone && !chained) continue;
      lastWeekday = i;

      final effective =
          scope == _WeekScope.nearest && weekScope != null ? weekScope : scope;
      final DateTime date;
      switch (effective) {
        case _WeekScope.next:
          date = weekDay(1, weekday);
        case _WeekScope.current:
          date = weekDay(0, weekday);
        case _WeekScope.nearest:
          var delta = (weekday - today.weekday) % 7;
          if (delta == 0) {
            final time = clock.length == 1 ? clock.single : null;
            final stillToday = time != null &&
                DateTime(today.year, today.month, today.day, time.$1, time.$2)
                    .isAfter(now);
            if (!stillToday) delta = 7;
          }
          date = DateTime(today.year, today.month, today.day + delta);
      }
      weekdays.add(
        _Found(
          words[start].start,
          words[i].end,
          date: date,
          isSource: (preposition != null &&
                  _sourcePrepositions.contains(preposition)) ||
              // «с 10:00 в пятницу на понедельник»: пятница — тоже исходный
              // срок.
              ((preposition == 'в' || preposition == 'во') &&
                  start > 1 &&
                  sourceEnds.contains(words[start - 2].end) &&
                  adjacent(start - 2, start - 1)),
        ),
      );
    }

    result.addAll(weekdays);
    // «на следующей неделе в пятницу»: неделя уточняет день и сама срока
    // не добавляет. Одна — понедельник следующей недели.
    for (final week in weekSpans) {
      if (weekdays.isNotEmpty) {
        result.add(_Found(week.start, week.end));
      } else if (week.date != null) {
        result.add(week);
      }
    }
    return result;
  }

  static DateTime _addMonths(DateTime date, int months) {
    final first = DateTime(date.year, date.month + months);
    final lastDay = DateTime(first.year, first.month + 1, 0).day;
    return DateTime(
      first.year,
      first.month,
      date.day > lastDay ? lastDay : date.day,
    );
  }

  /// Расширяет фрагмент срока предлогом прямо перед ним: «на завтра»,
  /// «в 18:00», «с 15:00», а также «к концу» перед сроком: «к концу 15.11».
  CharSpan _withPreposition(
    String text,
    List<RegExpMatch> words,
    int start,
    int end,
  ) {
    RegExpMatch? before(int position) {
      RegExpMatch? last;
      for (final word in words) {
        if (word.end > position) break;
        last = word;
      }
      return last;
    }

    var from = start;
    final previous = before(from);
    if (previous != null &&
        _onlySpaces(text, previous.end, from) &&
        previous.group(0) == 'концу') {
      final preposition = before(previous.start);
      if (preposition != null &&
          preposition.group(0) == 'к' &&
          _onlySpaces(text, preposition.end, previous.start)) {
        return CharSpan(preposition.start, end);
      }
    }
    if (previous != null &&
        _onlySpaces(text, previous.end, from) &&
        _attachedPrepositions.contains(previous.group(0))) {
      from = previous.start;
    }
    return CharSpan(from, end);
  }

  /// Уточнения сразу после часа: «утра», «часов», «часа дня». Пустой
  /// список — уточнения нет. Если их два, второе — часть суток.
  List<RegExpMatch> _suffixAfter(
    String text,
    List<RegExpMatch> words,
    int end,
  ) {
    final result = <RegExpMatch>[];
    var position = end;
    for (final word in words) {
      if (word.start < position) continue;
      if (!_onlySpaces(text, position, word.start)) break;
      final value = word.group(0)!;
      final fits = result.isEmpty
          ? _hourSuffixes.contains(value)
          : _hourWords.contains(result.single.group(0)) &&
              _dayparts.contains(value);
      if (!fits) break;
      result.add(word);
      position = word.end;
      if (result.length == 2) break;
    }
    return result;
  }

  /// Похоже на инфинитив: «позвонить», «купить», «зайти», «отнести»,
  /// «испечь». Нужен, чтобы «в 10 позвонить» стало временем, а «в 2
  /// магазина» — нет, и чтобы «купить хлеб» без команды стало задачей.
  /// Правила — [VerbForms.isInfinitive].
  static bool isInfinitive(String word) => VerbForms.isInfinitive(word);

  /// После числа с точкой стоит единица измерения: «1.5 кг», «2.5%».
  static bool _isQuantity(String text, List<RegExpMatch> words, int end) {
    var i = end;
    while (i < text.length && text[i] == ' ') {
      i++;
    }
    if (i < text.length && text[i] == '%') return true;
    for (final word in words) {
      if (word.start < end) continue;
      if (!_onlySpaces(text, end, word.start)) return false;
      final value = word.group(0)!;
      return _units.contains(value) ||
          _unitPrefixes.any((String unit) => value.startsWith(unit));
    }
    return false;
  }

  /// Номер версии после латинского слова: «python 3.12», «flutter до
  /// 3.24». Только с однозначной первой частью: «zoom в 19.30» — время,
  /// «iphone до 15.11» — дата. После «в» число с точкой всегда время.
  static bool _isVersion(List<RegExpMatch> words, RegExpMatch match) {
    if (match.group(1)!.length != 1) return false;
    final before = words
        .where((RegExpMatch w) => w.end <= match.start)
        .toList(growable: false);
    if (before.isEmpty) return false;
    final previous = before.last.group(0)!;
    if (_latin.hasMatch(previous)) return true;
    return _versionPrepositions.contains(previous) &&
        before.length > 1 &&
        _latin.hasMatch(before[before.length - 2].group(0)!);
  }

  static const Set<String> _versionPrepositions = <String>{
    'до',
    'на',
    'с',
    'со',
    'от',
  };

  static final RegExp _latin = RegExp('[a-z]');

  /// Час с уточнением «утра/дня/вечера/ночи». `null` — сочетание
  /// бессмысленно: «15 утра».
  int? _applySuffix(int hour, String suffix) {
    switch (suffix) {
      case 'утра':
        if (hour > 12) return null;
        return hour == 12 ? 0 : hour;
      case 'дня':
        if (hour == 12) return 12;
        if (hour >= 1 && hour <= 6) return hour + 12;
        return hour >= 13 && hour <= 18 ? hour : null;
      case 'вечера':
        if (hour >= 1 && hour <= 11) return hour + 12;
        return hour >= 12 && hour <= 23 ? hour : null;
      case 'ночи':
        if (hour == 12) return 0;
        if (hour <= 5) return hour;
        if (hour >= 9 && hour <= 11) return hour + 12;
        return hour >= 21 && hour <= 23 ? hour : null;
      default:
        return hour;
    }
  }

  /// Между позициями только пробелы и знаки конца фразы или перечисления.
  static bool _onlyPunctuation(String text, int start, int end) {
    for (var i = start; i < end; i++) {
      final char = text[i];
      if (char.trim().isNotEmpty && !',.;!?'.contains(char)) return false;
    }
    return true;
  }

  static bool _onlySpaces(String text, int start, int end) {
    for (var i = start; i < end; i++) {
      if (text[i].trim().isNotEmpty) return false;
    }
    return true;
  }

  /// Число вплотную к «.» или «:» с цифрой — часть другой записи.
  static bool _touchesNumberPunctuation(String text, int start, int end) {
    bool digitAt(int i) =>
        i >= 0 && i < text.length && RegExp(r'\d').hasMatch(text[i]);
    if (start > 0 && '.:'.contains(text[start - 1]) && digitAt(start - 2)) {
      return true;
    }
    return end < text.length && '.:'.contains(text[end]) && digitAt(end + 1);
  }

  /// Сортирует и сливает пересекающиеся фрагменты.
  static List<CharSpan> _merge(List<CharSpan> spans) {
    if (spans.isEmpty) return const <CharSpan>[];
    final sorted = [...spans]
      ..sort((CharSpan a, CharSpan b) => a.start.compareTo(b.start));
    final result = <CharSpan>[sorted.first];
    for (final span in sorted.skip(1)) {
      final last = result.last;
      if (span.start <= last.end) {
        result[result.length - 1] =
            CharSpan(last.start, span.end > last.end ? span.end : last.end);
      } else {
        result.add(span);
      }
    }
    return List<CharSpan>.unmodifiable(result);
  }

  /// Соединяет фрагменты, между которыми только «и»/«или»: в «в 9 и в 18»
  /// союз — часть перечисления сроков, а не начало названия.
  static List<CharSpan> _bridge(
    String text,
    List<RegExpMatch> words,
    List<CharSpan> spans,
  ) {
    if (spans.length < 2) return spans;
    final result = <CharSpan>[spans.first];
    for (final span in spans.skip(1)) {
      final last = result.last;
      final between = words
          .where((RegExpMatch w) => w.start >= last.end && w.end <= span.start)
          .toList(growable: false);
      final joins = between.length == 1 &&
          (between.single.group(0) == 'и' ||
              between.single.group(0) == 'или') &&
          _onlyPunctuation(text, last.end, between.single.start) &&
          _onlySpaces(text, between.single.end, span.start);
      if (joins) {
        result[result.length - 1] = CharSpan(last.start, span.end);
      } else {
        result.add(span);
      }
    }
    return List<CharSpan>.unmodifiable(result);
  }

  /// Различные значения без исходного срока «с …». Если указан только
  /// исходный срок, используются его значения.
  Set<T> _pickDistinct<T>(List<_Mention<T>> mentions) {
    final targets = mentions
        .where((_Mention<T> m) => !m.isSource)
        .map((_Mention<T> m) => m.value)
        .toSet();
    if (targets.isNotEmpty) return targets;
    return mentions.map((_Mention<T> m) => m.value).toSet();
  }

  DateTime? _resolveDate(int day, int month, String? yearText, DateTime today) {
    if (yearText != null) {
      final year = yearText.length == 2
          ? 2000 + int.parse(yearText)
          : int.parse(yearText);
      return _isValidDate(year, month, day) ? DateTime(year, month, day) : null;
    }
    // Без года — ближайшее будущее или сегодняшнее вхождение даты.
    // Для 29.02 это может быть через несколько лет.
    for (var year = today.year; year <= today.year + 4; year++) {
      if (!_isValidDate(year, month, day)) continue;
      final candidate = DateTime(year, month, day);
      if (!candidate.isBefore(today)) return candidate;
    }
    return null;
  }

  bool _isSource(String text, int position) =>
      _sourcePrepositions.contains(_previousWord(text, position));

  String? _previousWord(String text, int position) {
    final before = _word.allMatches(text.substring(0, position));
    return before.isEmpty ? null : before.last.group(0);
  }

  bool _isValidDate(int year, int month, int day) {
    if (month < 1 || month > 12 || day < 1) return false;
    final candidate = DateTime(year, month, day);
    return candidate.month == month && candidate.day == day;
  }
}

/// Какая неделя имеется в виду: «эту», «следующую» или ближайший день.
enum _WeekScope { current, next, nearest }

enum _Unit { minute, hour, day, week, month }

/// Срок, найденный разбором дней недели или «через N …».
final class _Found {
  const _Found(
    this.start,
    this.end, {
    this.date,
    this.time,
    this.moment,
    this.isSource = false,
  });

  final int start;
  final int end;
  final DateTime? date;
  final (int, int)? time;

  /// Точный момент для «через N минут/часов»: с ним итоговый срок не
  /// зависит от перевода часов.
  final DateTime? moment;
  final bool isSource;
}

final class _Mention<T> {
  const _Mention(this.value, this.isSource);

  final T value;
  final bool isSource;
}
