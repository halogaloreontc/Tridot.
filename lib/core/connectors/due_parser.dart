import '../models/task.dart';

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
    this.precision = DuePrecision.dateTime,
    this.issue = DueIssue.none,
    this.spans = const <CharSpan>[],
  });

  final DateTime? dueAt;
  final DuePrecision precision;
  final DueIssue issue;

  /// Фрагменты текста, которые разбор сроков счёл своими: даты, время,
  /// «сегодня/завтра/послезавтра», «в 10 утра» вместе с предлогом перед ними
  /// («на завтра», «в 18:00», «с 15:00»). Смещения — в том тексте, который
  /// передан в [DueParser.parse]. Заполняется и при [issue] ≠ none, чтобы
  /// неверный срок не попал в название задачи. Отсортированы, не пересекаются.
  final List<CharSpan> spans;
}

/// Разбор сроков в русском тексте: только то, что можно понять однозначно.
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

  /// Существительные на «-ть», которые не глаголы: «в 2 сеть» — не время.
  static const Set<String> _nounsEndingInT = <String>{
    'сеть',
    'мать',
    'путь',
    'суть',
    'нить',
    'треть',
    'ртуть',
    'плеть',
    'медь',
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
    var dateText = normalized;
    var ambiguousHour = false;

    void consume(int start, int end) {
      spans.add(_withPreposition(normalized, words, start, end));
    }

    DueParseResult fail(DueIssue issue) =>
        DueParseResult(issue: issue, spans: _merge(spans));

    void mask(int start, int end) {
      dateText = dateText.replaceRange(start, end, ' ' * (end - start));
    }

    for (final match in _colonTime.allMatches(normalized)) {
      var hour = int.parse(match.group(1)!);
      final minute = int.parse(match.group(2)!);
      final second = match.group(3);
      final suffix = _suffixAfter(normalized, words, match.end);
      consume(match.start, suffix.isEmpty ? match.end : suffix.last.end);
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
      consume(match.start, match.end);

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
    final masked = _word.allMatches(dateText).toList(growable: false);
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
                  _isInfinitive(nextWord!)) ||
              // «в 10 или в 11», «в 9 и в 18» — перечисление времён,
              // а не «10 штук».
              nextWord == 'или' ||
              (nextWord == 'и' &&
                  afterNext != null &&
                  _hourPrepositions.contains(afterNext.group(0))) ||
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

  /// Похоже на инфинитив: «позвонить», «купить», «зайти». Нужен, чтобы
  /// «в 10 позвонить» стало временем, а «в 2 магазина» — нет.
  static bool _isInfinitive(String word) {
    if (word.length < 4 || _nounsEndingInT.contains(word)) return false;
    // «-сть» почти всегда существительное: «часть», «новость».
    if (word.endsWith('сть')) return false;
    return word.endsWith('ть') ||
        word.endsWith('ться') ||
        word.endsWith('тись') ||
        word.endsWith('йти') ||
        word.endsWith('дти');
  }

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

final class _Mention<T> {
  const _Mention(this.value, this.isSource);

  final T value;
  final bool isSource;
}
