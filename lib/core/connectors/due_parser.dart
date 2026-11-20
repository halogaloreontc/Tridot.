import '../models/task.dart';
import 'number_words.dart';
import 'speech_noise.dart';
import 'spoken_time.dart';
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

  /// День есть, а время не дописали: «перенеси её на завтра в» (шаблон
  /// из «+»). Ставит разбор команды, а не разбор срока.
  missingTime,
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
    this.hasSource = false,
    this.recurring = false,
    this.sameTime = false,
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

  /// Во фразе есть исходный срок переноса: «с 12-го на 18-е», «с завтра
  /// на пятницу».
  final bool hasSource;

  /// Срок назван повторением: «по пятницам», «каждую пятницу». Повторяющихся
  /// задач пока нет — срок равен ближайшему такому дню (docs/PLANS.md).
  final bool recurring;

  /// Время названо как «то же»: «на завтра на то же время». В [dueAt] —
  /// нынешнее время; перенос берёт время самой задачи.
  final bool sameTime;
}

/// Разбор сроков в русском тексте: только то, что можно понять однозначно.
///
/// Понимает даты ДД.ММ[.ГГ] и «15 ноября [2027]», время, «сегодня/завтра/
/// послезавтра», дни недели с предлогами и сокращения пн…вс, «через N минут/
/// часов/дней/недель/месяцев», «на выходных», «в конце недели», «на следующей
/// неделе», «в начале/середине/конце месяца». Правила для дней недели —
/// у [_calendarMentions] и в docs/CORPUS.md.
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

  /// Уточнения часа без предлога после дня: «завтра 9 утра». «Дня» сюда
  /// не входит: «завтра 2 дня» — скорее длительность.
  static const Set<String> _bareHourSuffixes = <String>{
    'утра',
    'вечера',
    'ночи',
  };

  /// После этих слов может идти ещё и часть суток: «в 2 часа дня».
  /// «К 3 часам», «к двум часам дня» — дательный после «к».
  static const Set<String> _hourWords = <String>{
    'час',
    'часа',
    'часов',
    'часам',
  };

  /// «Часов в шесть», «часиков в десять», «часика в два» — примерно.
  static const Set<String> _hedgeHourWords = <String>{
    'час',
    'часа',
    'часов',
    'часика',
    'часиков',
  };

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

  /// Прошедшие дни: срок только после «на» или «с» («перенеси на вчера» —
  /// уже прошло).
  static const Map<String, int> _pastDayWords = <String, int>{
    'вчера': -1,
    'позавчера': -2,
  };

  /// Окончания порядкового числа дня после дефиса: «20-е», «12-го», «к
  /// 20-му».
  /// Число месяца с окончанием вплотную: «5го», «15ое».
  static final RegExp _gluedOrdinal =
      RegExp(r'^(\d{1,2})(го|ого|му|ому|е|ое)$');

  static const Set<String> _ordinalEndings = <String>{
    'е',
    'ое',
    'го',
    'ого',
    'му',
    'ому',
  };

  /// Посимвольная нормализация: нижний регистр и «ё» → «е» без изменения
  /// длины строки. Символ, у которого нижний регистр другой длины, остаётся.
  /// [text] с временем словами, заменённым цифрами той же длины:
  /// «в восемь тридцать утра» → «в 8:30           утра».
  static String _spellDigits(String text, List<SpokenTimeMatch> spoken) {
    if (spoken.isEmpty) return text;
    final buffer = StringBuffer();
    var position = 0;
    for (final match in spoken) {
      buffer
        ..write(text.substring(position, match.start))
        ..write(match.digits.padRight(match.end - match.start));
      position = match.end;
    }
    buffer.write(text.substring(position));
    return buffer.toString();
  }

  /// Фрагменты срока вместе со словом «ровно», «примерно» сразу перед
  /// ними: «ровно в шесть» не оставит «Ровно» в названии.
  static List<CharSpan> _hedged(
    String text,
    List<RegExpMatch> words,
    List<CharSpan> spans,
  ) {
    if (spans.isEmpty) return spans;
    return <CharSpan>[
      for (final span in spans)
        () {
          for (var i = 0; i < words.length; i++) {
            final word = words[i];
            if (word.end > span.start) break;
            if (!_onlySpaces(text, word.end, span.start)) continue;
            if (_clockHedges.contains(word.group(0))) {
              return CharSpan(word.start, span.end);
            }
            // «Часов в шесть», «часа в два» — примерно в шесть; «8 часов в
            // пятницу» — длительность, она остаётся в названии.
            final previous = i > 0 ? words[i - 1].group(0)! : '';
            if (_hedgeHourWords.contains(word.group(0)) &&
                _hedgedHour.hasMatch(text.substring(span.start, span.end)) &&
                !_allDigits.hasMatch(previous) &&
                !_numberWords.containsKey(previous)) {
              return CharSpan(word.start, span.end);
            }
          }
          return span;
        }(),
    ];
  }

  /// «в 18 30 забрать заказ» — так распознаватель и спешащий человек пишут
  /// «18:30». Пробел меняется на двоеточие (длина та же), только после
  /// «в/к/до/на», с минутами 00–59 и если дальше не слово счёта: «в 2 50
  /// рублей», «на 10 15 человек» — числа, а не время. Минуты с нулём
  /// впереди («в 21 00 таблетки») — время при любом слове дальше.
  static String _spacedClock(String text) => text.replaceAllMapped(
        _spacedTime,
        (Match m) {
          final hour = int.parse(m.group(2)!);
          final minute = int.parse(m.group(3)!);
          final after = m.group(4);
          // «В 21 00 таблетки»: минуты с нулём впереди — так числа не
          // считают («в 2 50 рублей»), это время.
          final free = after == null ||
              m.group(3)!.startsWith('0') ||
              _bareHourSuffixes.contains(after) ||
              _hourSuffixes.contains(after) ||
              _dayWords.containsKey(after) ||
              _politeWords.contains(after) ||
              isInfinitive(after) ||
              after == 'напомни' ||
              after == 'и';
          if (hour > 23 || minute > 59 || !free) return m.group(0)!;
          final colon = m.group(1)!.length + m.group(2)!.length;
          return m.group(0)!.replaceRange(colon, colon + 1, ':');
        },
      );

  /// «Минут через двадцать», «часа через два» — единица впереди, как
  /// «через минут двадцать»: слова меняются местами (длина та же), если
  /// после «через» — число.
  static String _unitFirst(String text) => text.replaceAllMapped(
        _unitBeforeThrough,
        (Match m) => '${m.group(3)}${m.group(2)}${m.group(1)}',
      );

  static final RegExp _unitBeforeThrough = RegExp(
    r'(?<![а-я])(минут|минуты|часа|часов|дня|дней|недели|недель)(\s+)(через)'
    r'(?=\s+(?:\d|пар|полтор|один|одну|две|два|три|четыре|пять|шесть|семь|'
    r'восемь|девять|десять|пятнадцать|двадцать|тридцать|сорок|пятьдесят))',
  );

  static final RegExp _spacedTime = RegExp(
    r'((?:^|(?<=\s))(?:в|во|к|ко|до|на)\s)(\d{1,2}) (\d{2})(?![\d:.,])'
    r'(?:\s*[,.!?]?\s*([a-zа-я]+))?',
  );

  /// Фрагменты срока, расширенные на время словами целиком: цифры «9»
  /// заняли только начало слова «девять».
  static List<CharSpan> _spoken(
    List<CharSpan> spans,
    List<SpokenTimeMatch> spoken,
  ) {
    if (spoken.isEmpty) return spans;
    return <CharSpan>[
      for (final span in spans)
        () {
          var start = span.start;
          var end = span.end;
          for (final match in spoken) {
            if (match.start < end && span.start < match.end) {
              if (match.start < start) start = match.start;
              if (match.end > end) end = match.end;
            }
          }
          return CharSpan(start, end);
        }(),
    ];
  }

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
    // Время словами («в девять», «полдевятого») разбирается как цифры той
    // же длины: фрагменты срока по-прежнему указывают в исходную строку,
    // а в конце расширяются на всё слово ([_spoken]).
    final spoken = SpokenTime.find(normalizeChars(text));
    final normalized = _unitFirst(
      _spacedClock(_spellDigits(normalizeChars(text), spoken)),
    );
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
    var recurring = false;
    var sameTime = false;
    // Номера в [times] времён без уточнения «утра/вечера»: их уточняет часть
    // суток («вечером в 8» — 20:00). Среди них — час 1–6 без уточнения
    // («к 5»), который без части суток неоднозначен.
    final unqualified = <int>{};
    final ambiguous = <int>{};
    // Номера одиночных часов без минут: «в 8», «к 5».
    final bare = <int>{};
    // «утром», «днём», «после обеда», «вечером».
    final parts = _partMentions(normalized, words);
    final partKinds = <PartOfDay>{for (final found in parts) found.part};
    final part = partKinds.length == 1 ? partKinds.single : null;
    // «В обед» кончается в 15:00, а не в 17:00, как «днём».
    final lunch = part != null && parts.every((_PartFound p) => p.lunch);
    final partEndHour = part == null ? null : (lunch ? 15 : part.endHour);
    // «15 ноября», «31 февраля» (несуществующая — уточнение invalidDate).
    final monthDates = <_Found>[
      ..._monthMentions(normalized, words, today),
      ..._dayOfMonthMentions(normalized, words, today),
      ..._newYearMentions(normalized, words, today),
    ];
    // Ошибка в дате или времени: разбор доходит до конца, чтобы все
    // фрагменты срока заняли свои места и не попали в название. Если неверны
    // и дата, и время, побеждает дата: «31 февраля в 25:00» — invalidDate.
    DueIssue? pending;
    void defer(DueIssue issue) {
      const order = <DueIssue>[
        DueIssue.invalidDate,
        DueIssue.invalidTime,
        DueIssue.inPast,
      ];
      final current = pending;
      if (current == null || order.indexOf(issue) < order.indexOf(current)) {
        pending = issue;
      }
    }

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
        ...monthDates,
        ..._relativeMentions(normalized, words, now),
        ..._agoMentions(normalized, words, today),
        ..._calendarMentions(
          normalized,
          words,
          now,
          _weekdayClock(_pickDistinct(times), partEndHour),
          _merge(spans),
          sourceEnds,
        ),
      ];
      for (final found in calendar) {
        consume(found.start, found.end);
        if (found.recurring) recurring = true;
        final moment = found.moment;
        if (moment != null) moments.add(moment);
        final date = found.date;
        if (date != null) dates.add(_Mention(date, found.isSource));
        final time = found.time;
        if (time != null) times.add(_Mention(time, found.isSource));
      }
      // «на вчера», «с позавчера»: прошедший день только с предлогом —
      // иначе «вчера» не срок («вчера звонил»).
      for (var k = 1; k < words.length; k++) {
        final offset = _pastDayWords[words[k].group(0)];
        final preposition = words[k - 1].group(0);
        if (offset == null ||
            !_onlySpaces(normalized, words[k - 1].end, words[k].start) ||
            !(preposition == 'на' ||
                _sourcePrepositions.contains(preposition))) {
          continue;
        }
        consume(words[k].start, words[k].end);
        dates.add(
          _Mention(
            DateTime(today.year, today.month, today.day + offset),
            _isSource(normalized, words[k].start),
          ),
        );
      }
      // «на завтрашний день», «к сегодняшнему дню»: день в прилагательном,
      // точность — день. «Завтрашний день рождения» — событие, не срок.
      for (var k = 2; k < words.length; k++) {
        final offset = _dayNounAdjectives[words[k - 1].group(0)];
        if (offset == null ||
            !_dayNouns.contains(words[k].group(0)) ||
            !_attachedPrepositions.contains(words[k - 2].group(0)) ||
            !_onlySpaces(normalized, words[k - 2].end, words[k - 1].start) ||
            !_onlySpaces(normalized, words[k - 1].end, words[k].start)) {
          continue;
        }
        if (k + 1 < words.length &&
            _partBlockersAfter.contains(words[k + 1].group(0))) {
          continue;
        }
        consume(words[k - 1].start, words[k].end);
        dates.add(
          _Mention(
            DateTime(today.year, today.month, today.day + offset),
            _isSource(normalized, words[k - 1].start),
          ),
        );
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
      // Часть суток занимает свой фрагмент без предлога: «в пятницу
      // вечером» — предлог уже у дня.
      for (final found in parts) {
        spans.add(CharSpan(found.start, found.end));
        final offset = found.dayOffset;
        if (offset != null) {
          dates.add(
            _Mention(
              DateTime(today.year, today.month, today.day + offset),
              false,
            ),
          );
        }
      }
    }

    // При ошибке во времени или дате дни всё равно занимают свои фрагменты,
    // чтобы «через 3 дня» или «завтра» не попали в название.
    DueParseResult done({
      DateTime? dueAt,
      DuePrecision? precision,
      DueIssue issue = DueIssue.none,
      required List<CharSpan> spans,
    }) =>
        DueParseResult(
          dueAt: dueAt,
          precision: precision,
          issue: issue,
          spans: _hedged(normalized, words, _spoken(spans, spoken)),
          hasSource: dates.any((_Mention<DateTime> m) => m.isSource) ||
              times.any((_Mention<(int, int)> m) => m.isSource),
          recurring: recurring,
          sameTime: sameTime,
        );

    DueParseResult fail(DueIssue issue) {
      collectDays();
      return done(
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
        defer(DueIssue.invalidTime);
        mask(match.start, match.end);
        continue;
      }
      if (suffix.isNotEmpty) {
        final adjusted = _applySuffix(hour, suffix.last.group(0)!);
        if (adjusted == null) {
          defer(DueIssue.invalidTime);
          mask(match.start, match.end);
          continue;
        }
        hour = adjusted;
      } else {
        // «без четверти пять», «полшестого» — как «в 5»: утро или вечер,
        // решает часть суток или вопрос. Набранное «в 4:45» и «в шесть
        // ноль пять» — как сказано.
        if (hour >= 1 &&
            hour <= 6 &&
            spoken.any(
              (SpokenTimeMatch s) =>
                  s.twelveHour && s.start <= match.start && match.start < s.end,
            )) {
          ambiguous.add(times.length);
        }
        unqualified.add(times.length);
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
          defer(DueIssue.invalidTime);
          mask(match.start, match.end);
          continue;
        }
        unqualified.add(times.length);
        times.add(_Mention((first, second), source));
        mask(match.start, match.end);
        continue;
      }

      final date = _resolveDate(first, second, yearText, today);
      if (date != null) {
        if (yearText != null && date.isBefore(today)) {
          defer(DueIssue.inPast);
          mask(match.start, match.end);
          continue;
        }
        dates.add(_Mention(date, source));
        mask(match.start, match.end);
        continue;
      }
      if (looksLikeTime && second <= 59) {
        // «на 18.30»: такой даты нет, но это корректное время.
        unqualified.add(times.length);
        times.add(_Mention((first, second), source));
        mask(match.start, match.end);
        continue;
      }
      defer(DueIssue.invalidDate);
      mask(match.start, match.end);
    }
    // Дата словами занята целиком: число в «к 5 ноября» — не час.
    for (final found in monthDates) {
      mask(found.start, found.end);
      if (found.invalid) defer(DueIssue.invalidDate);
    }

    // «Через неделю в это же время», «на завтра на то же время»: время —
    // нынешнее (у переноса — время самой задачи, [DueParseResult.sameTime]).
    for (var k = 0; k + 3 < words.length; k++) {
      if (!_sameTimePrepositions.contains(words[k].group(0)) ||
          !_sameTimePronouns.contains(words[k + 1].group(0)) ||
          words[k + 2].group(0) != 'же' ||
          words[k + 3].group(0) != 'время') {
        continue;
      }
      consume(words[k].start, words[k + 3].end);
      mask(words[k].start, words[k + 3].end);
      times.add(_Mention((now.hour, now.minute), false));
      sameTime = true;
      break;
    }

    // Одиночный час: «в 10», «к 9 утра», «в 7 вечера». Только после «в/к»
    // и только если дальше нет обычного слова — «в 2 магазина» не время.
    // Исключение — час сразу после дня: «завтра в 10 созвон», «в следующий
    // понедельник в 9 планёрка». Здесь число уже не может быть количеством.
    final masked = _word.allMatches(dateText).toList(growable: false);
    final postpone = _postpones(words);
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
      for (final found in monthDates)
        if (found.date != null) found.end,
      for (final word in words)
        if (_dayWords.containsKey(word.group(0))) word.end,
      for (final found in parts)
        if (found.dayOffset != null) found.end,
    };
    // «завтра вечером в 8 встреча»: часть суток сразу после дня тоже день.
    // Одна часть суток днём не считается: в «вечером в 2 магазина» число —
    // количество, а не час.
    for (final found in parts) {
      final chained = dayEnds.any((int end) {
        if (end > found.start) return false;
        final gap = normalized.substring(end, found.start).trim();
        return gap.isEmpty || gap == ',';
      });
      if (chained) dayEnds.add(found.end);
    }
    // Час сразу после одной части суток: «утром в 5 пробежка», «вечером
    // в 8 встреча». Число здесь может быть и количеством («вечером в 2
    // магазина», «днём в 10 классе»), поэтому часом оно считается, только
    // если попадает в часть суток и дальше не слово, согласованное
    // с числом.
    bool afterPart(RegExpMatch preposition, int hour, String? nextWord) {
      if (part == null) return false;
      final adjusted = _applySuffix(hour, part.hourSuffix);
      if (adjusted == null || !part.admitsHour(adjusted)) return false;
      if (nextWord != null && _countedNoun(nextWord, hour)) return false;
      for (final found in parts) {
        if (found.end > preposition.start) continue;
        final gap = normalized.substring(found.end, preposition.start).trim();
        if (gap.isEmpty || gap == ',') return true;
      }
      return false;
    }

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
      if (_touchesNumberPunctuation(dateText, token.start, token.end)) {
        continue;
      }
      final suffix = _suffixAfter(dateText, masked, token.end);
      final hasPreposition = i > 0 &&
          (_hourPrepositions.contains(masked[i - 1].group(0)) ||
              _clockAfterNa(
                masked[i - 1].group(0)!,
                value,
                suffix,
                postpone: postpone,
              ) ||
              // «завтра на 10 позвонить»: «на» с часом сразу после дня —
              // время, а не «на 10 минут». После глагола отсрочки тоже:
              // «сдвинь созвон на завтра на 11».
              (masked[i - 1].group(0) == 'на' &&
                  suffix.isEmpty &&
                  afterDay(masked[i - 1]) &&
                  !_naCounted(masked, i))) &&
          _onlySpaces(dateText, masked[i - 1].end, token.start);
      // «на завтра 9 утра», «в пятницу 7 вечера»: час без предлога сразу
      // после дня — только с «утра», «вечера», «ночи».
      if (!hasPreposition &&
          !(suffix.isNotEmpty &&
              _bareHourSuffixes.contains(suffix.last.group(0)) &&
              dayEnds.any((int end) {
                if (end > token.start) return false;
                final gap = normalized.substring(end, token.start).trim();
                return gap.isEmpty || gap == ',';
              }))) {
        continue;
      }
      final next = i + 1 < masked.length ? masked[i + 1] : null;
      final nextWord = next?.group(0);
      final afterNext = i + 2 < masked.length ? masked[i + 2] : null;
      final freeAfter = next == null
          ? _onlyPunctuation(dateText, token.end, dateText.length)
          : suffix.isNotEmpty ||
              _dayWords.containsKey(nextWord) ||
              _politeWords.contains(nextWord) ||
              // «в 8 вечером», «в 2 после обеда».
              parts.any((_PartFound p) => p.start == next.start) ||
              // «в 10 позвонить»: час перед действием.
              (_onlySpaces(dateText, token.end, next.start) &&
                  isInfinitive(nextWord!)) ||
              // «в 10 по мск»: часовой пояс — ещё часть времени.
              (nextWord == 'по' &&
                  afterNext != null &&
                  _moscowWords.contains(afterNext.group(0))) ||
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
              afterPart(masked[i - 1], int.parse(value), nextWord) ||
              (!_onlySpaces(dateText, token.end, next.start) &&
                  _onlyPunctuation(dateText, token.end, next.start));
      if (!freeAfter) continue;
      // «позвонить в 03» — номер службы, а не время: час с ведущим нулём
      // считается временем только с уточнением «в 07 утра».
      if (suffix.isEmpty && value.length == 2 && value.startsWith('0')) {
        continue;
      }
      var hour = int.parse(value);
      if (hour > 23) {
        // «в 25 часов», «в 30 вечера» — неверное время, а не номер: число
        // с уточнением часа. Без уточнения («в 25») — возможно, номер.
        if (suffix.isNotEmpty &&
            !_hoursAsDuration(dateText, masked, suffix, hour)) {
          consume(token.start, suffix.last.end);
          defer(DueIssue.invalidTime);
        }
        continue;
      }
      // «в 17 часов 20 минут» — минуты после часа.
      var minute = 0;
      var timeEnd = suffix.isEmpty ? token.end : suffix.last.end;
      final hourAt = suffix.isEmpty ? -1 : masked.indexOf(suffix.first);
      if (hourAt > 0 &&
          _hourWords.contains(suffix.first.group(0)) &&
          hourAt + 2 < masked.length &&
          _onlySpaces(dateText, masked[hourAt].end, masked[hourAt + 1].start) &&
          _onlySpaces(
            dateText,
            masked[hourAt + 1].end,
            masked[hourAt + 2].start,
          ) &&
          masked[hourAt + 2].group(0)!.startsWith('минут')) {
        final minutes = int.tryParse(masked[hourAt + 1].group(0)!);
        if (minutes != null && minutes <= 59) {
          minute = minutes;
          timeEnd = masked[hourAt + 2].end;
        }
      }
      final zoneAt = suffix.isEmpty ? i + 1 : masked.indexOf(suffix.last) + 1;
      if (zoneAt > 0 &&
          zoneAt + 1 < masked.length &&
          masked[zoneAt].group(0) == 'по' &&
          _moscowWords.contains(masked[zoneAt + 1].group(0))) {
        timeEnd = masked[zoneAt + 1].end;
      }
      consume(token.start, timeEnd);
      if (suffix.isNotEmpty) {
        final adjusted = _applySuffix(hour, suffix.last.group(0)!);
        if (adjusted == null) {
          defer(DueIssue.invalidTime);
          continue;
        }
        hour = adjusted;
        // «В 3 часа», «к трём часам» без части суток — как «к 3»: и ночь,
        // и день. С минутами («в 3 часа 20 минут») — как сказано.
        if (suffix.length == 1 &&
            _hourWords.contains(suffix.single.group(0)) &&
            timeEnd == suffix.single.end &&
            hour >= 1 &&
            hour <= 6) {
          ambiguous.add(times.length);
          unqualified.add(times.length);
          bare.add(times.length);
        }
      } else {
        // «к 5» — и 05:00, и 17:00. Фрагмент уже занят, чтобы «к 5» не
        // попало в название; срок уточняется у пользователя, если его
        // не уточняет часть суток («к 5 вечером»).
        if (hour >= 1 && hour <= 6) ambiguous.add(times.length);
        unqualified.add(times.length);
        bare.add(times.length);
      }
      times.add(_Mention((hour, minute), false));
    }

    // Часть суток уточняет время без «утра/вечера»: «завтра вечером в 8» —
    // 20:00, «утром в 5» — 05:00. Несовместимое («утром в 20:00») остаётся
    // как написано: точное время важнее.
    if (part != null) {
      for (final index in unqualified) {
        final mention = times[index];
        // «утром в 12» — полдень, а не полночь, как «в 12 утра».
        if (part == PartOfDay.morning && mention.value.$1 == 12) continue;
        final adjusted = _applySuffix(mention.value.$1, part.hourSuffix);
        if (adjusted == null || !part.admitsHour(adjusted)) {
          // «вечером в 1», «вечером в 12», «днём в 10»: час не попадает
          // в часть суток. Одиночный час переспрашивается, а не становится
          // дневным; «утром в 20:00» с минутами остаётся как написано.
          if (bare.contains(index)) ambiguous.add(index);
          continue;
        }
        times[index] = _Mention((adjusted, mention.value.$2), mention.isSource);
        ambiguous.remove(index);
      }
    }
    final ambiguousHour = ambiguous.isNotEmpty;

    final issue = pending;
    if (issue != null) return fail(issue);

    collectDays();

    final merged = _bridge(normalized, words, _merge(spans));
    final days = _pickDistinct(dates);
    if (days.length > 1) {
      return done(issue: DueIssue.conflictingDays, spans: merged);
    }
    final clock = _pickDistinct(times);
    // «утром или вечером» — тоже несколько времён.
    if (clock.length > 1 || partKinds.length > 1) {
      return done(issue: DueIssue.conflictingTimes, spans: merged);
    }

    if (ambiguousHour) {
      return done(issue: DueIssue.ambiguousHour, spans: merged);
    }

    final explicitDay = days.isEmpty ? null : days.single;
    final time = clock.isEmpty ? null : clock.single;
    if (explicitDay == null && time == null && part == null) {
      return done(spans: merged);
    }

    if (time == null && part != null) {
      // Часть суток без точного времени: условный час части и точность
      // partOfDay. Прошедшей часть считается с её концом: «вечером»
      // в 19:30 — ещё сегодня. Как с часом: без дня прошедшая часть —
      // завтра («утром» в 16:30), с явным днём — «уже прошло».
      if (explicitDay != null && explicitDay.isBefore(today)) {
        return done(issue: DueIssue.inPast, spans: merged);
      }
      var day = explicitDay ?? today;
      final end = DateTime(day.year, day.month, day.day, partEndHour!);
      if (!end.isAfter(now)) {
        if (explicitDay != null) {
          return done(issue: DueIssue.inPast, spans: merged);
        }
        day = DateTime(day.year, day.month, day.day + 1);
      } else if (explicitDay == null &&
          part == PartOfDay.evening &&
          !end.subtract(const Duration(hours: 1)).isAfter(now)) {
        // Последний час вечера без дня — уже следующий вечер: «вечером»
        // в 23:30 — завтра, а не «сегодня в 19:00», которое через
        // полчаса станет просроченным. «Днём» в 16:30 — ещё сегодня.
        day = DateTime(day.year, day.month, day.day + 1);
      } else if (explicitDay == null &&
          part == PartOfDay.morning &&
          !DateTime(day.year, day.month, day.day, part.hour).isAfter(now)) {
        // «С утра» без дня, когда условный час утра уже прошёл (в 9:31) —
        // следующее утро: «сегодня в 9:00» родилось бы просроченным, и
        // напоминание не пришло бы вовсе.
        day = DateTime(day.year, day.month, day.day + 1);
      }
      return done(
        dueAt: DateTime(day.year, day.month, day.day, part.hour),
        precision: DuePrecision.partOfDay,
        spans: merged,
      );
    }

    if (time == null) {
      if (explicitDay!.isBefore(today)) {
        return done(issue: DueIssue.inPast, spans: merged);
      }
      return done(
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
        return done(issue: DueIssue.inPast, spans: merged);
      }
      // Только время, и оно уже прошло: ближайшее будущее — завтра.
      result = DateTime(day.year, day.month, day.day + 1, time.$1, time.$2);
    }
    return done(
      dueAt: result,
      precision: DuePrecision.dateTime,
      spans: merged,
    );
  }

  // ------------------------------------------------------- части суток

  /// Части суток наречием: «утром», «днём», «вечером», ласкательные
  /// «утречком», «вечерком». «Ночью» сроком не считается: это и поздний
  /// вечер, и раннее утро — остаётся в названии. «После работы»,
  /// «к вечеру» — тоже пока не сроки; «в обед» — в [_partMentions].
  static const Map<String, PartOfDay> _partWords = <String, PartOfDay>{
    'утром': PartOfDay.morning,
    'утречком': PartOfDay.morning,
    'днем': PartOfDay.day,
    'вечером': PartOfDay.evening,
    'вечерком': PartOfDay.evening,
  };

  /// «ближе к вечеру», «ближе к утру», «ближе к обеду».
  static const Map<String, PartOfDay> _closerParts = <String, PartOfDay>{
    'вечеру': PartOfDay.evening,
    'утру': PartOfDay.morning,
    'обеду': PartOfDay.day,
  };

  /// Слова перед частью суток, с которыми она не срок: «с утром» («с днём
  /// рождения»), «за вечером», «каждым утром», «перед вечером».
  static const Set<String> _partBlockersBefore = <String>{
    'с',
    'со',
    'за',
    'перед',
    'под',
    'над',
    'каждым',
    'целым',
    'тем',
    'одним',
    'другим',
    'следующим',
  };

  /// Части суток существительным после «на»: «перенеси на вечер», «на утро
  /// пятницы». «На день» сроком не считается: «на день рождения», «на один
  /// день».
  static const Map<String, PartOfDay> _partNouns = <String, PartOfDay>{
    'утро': PartOfDay.morning,
    'вечер': PartOfDay.evening,
  };

  /// «К вечеру пятницы», «к утру понедельника» — часть суток названного
  /// дня. Без дня «к вечеру» — не срок (решение корпуса, b3 nl-012).
  static const Map<String, PartOfDay> _partDatives = <String, PartOfDay>{
    'утру': PartOfDay.morning,
    'вечеру': PartOfDay.evening,
  };

  /// Прилагательные дня перед «утро»/«вечер» после «на»: «на завтрашнее
  /// утро», «на завтрашний вечер», «на сегодняшний вечер».
  static const Map<String, int> _dayAdjectives = <String, int>{
    'сегодняшнее': 0,
    'сегодняшний': 0,
    'завтрашнее': 1,
    'завтрашний': 1,
    'послезавтрашнее': 2,
    'послезавтрашний': 2,
  };

  /// Прилагательные дня перед «день» с предлогом: «на завтрашний день»,
  /// «к сегодняшнему дню», «до послезавтрашнего дня».
  static const Map<String, int> _dayNounAdjectives = <String, int>{
    'сегодняшний': 0,
    'сегодняшнему': 0,
    'сегодняшнего': 0,
    'завтрашний': 1,
    'завтрашнему': 1,
    'завтрашнего': 1,
    'послезавтрашний': 2,
    'послезавтрашнему': 2,
    'послезавтрашнего': 2,
  };

  static const Set<String> _dayNouns = <String>{'день', 'дню', 'дня'};

  /// Исходная часть суток перед «на вечер»: «с утра на вечер» — это
  /// откуда переносят, не срок.
  static const Set<String> _sourceParts = <String>{
    'утра',
    'вечера',
    'обеда',
  };

  /// Слова сразу после «на вечер», «на утро», с которыми это срок: конец
  /// фразы, день («на вечер завтра»), предлог или союз. Иначе это событие:
  /// «билеты на вечер встречи выпускников».
  static const Set<String> _partNounFollowers = <String>{
    'чтобы',
    'что',
    'напомни',
    'напомнить',
    'напоминание',
    'напоминалку',
    'мне',
    'нам',
    'в',
    'во',
    'на',
    'к',
    'и',
    'или',
    'а',
    'но',
    'для',
    'с',
    'со',
    'по',
    'у',
    'после',
    'через',
    'пожалуйста',
  };

  /// Основы названий месяцев. Месяц без числа перед ним («в ноябре
  /// вечером», «ноябрь») разбор не понимает, и часть суток рядом с ним не
  /// срок, иначе срок вышел бы уверенно неверным. «5 ноября» — дата
  /// ([_monthMentions]).
  static const List<String> _monthStems = <String>[
    'январ',
    'феврал',
    'март',
    'апрел',
    'мая',
    'мае',
    'июн',
    'июл',
    'август',
    'сентябр',
    'октябр',
    'ноябр',
    'декабр',
  ];

  /// Слова дня, которые разбор не понимает: «вчера», месяц без числа.
  /// Рядом с ними часть суток не срок. «5-го», «15 числа» теперь
  /// понимаются и без предлога ([_dayOfMonthMentions]).
  static bool _unparsedDayWord(String word) =>
      word == 'вчера' ||
      word == 'позавчера' ||
      _monthStems.any(word.startsWith);

  /// После «с утра» — конец диапазона: «с утра на вечер», «с утра до
  /// обеда», «с утра и до ночи».
  static const Set<String> _morningRangeAfter = <String>{
    'на',
    'до',
    'и',
    'по',
  };

  /// Перед «с утра» — не срок: «весь день с утра», «целый день с утра»,
  /// «болит с утра».
  static const Set<String> _morningRangeBefore = <String>{
    'весь',
    'целый',
    'день',
    'еще',
    'уже',
    'самого',
  };

  /// «С утра пораньше» — то же утро.
  static const Set<String> _earlyWords = <String>{'пораньше', 'пораньку'};

  /// Слова после части суток, с которыми она не срок: «днём рождения»,
  /// «днём раньше».
  static const Set<String> _partBlockersAfter = <String>{
    'рождения',
    'раньше',
    'позже',
    'ранее',
  };

  /// Слово после «в N» похоже на существительное при числе: «в 10 классе»,
  /// «в 3 кабинете», «в 5 магазинах», «в 2 магазина».
  static bool _countedNoun(String word, int number) {
    if (!RegExp(r'^[а-я]+$').hasMatch(word) || word.length < 3) return false;
    if (word.endsWith('е') ||
        word.endsWith('ах') ||
        word.endsWith('ях') ||
        word.endsWith('ов') ||
        word.endsWith('ев')) {
      return true;
    }
    return number >= 2 &&
        number <= 4 &&
        (word.endsWith('а') || word.endsWith('я'));
  }

  /// Части суток в тексте: «утром», «вечером», «после обеда», «этим
  /// вечером» (вместе с «этим»).
  static List<_PartFound> _partMentions(String text, List<RegExpMatch> words) {
    String word(int i) => words[i].group(0)!;
    bool adjacent(int left, int right) =>
        _onlySpaces(text, words[left].end, words[right].start);
    final result = <_PartFound>[];
    // Рядом с частью суток дата, которую разбор не понимает: «5 ноября
    // вечером», «вечером 5-го», «вчера вечером».
    // Месяц сразу после числа — понятая дата: «5 ноября вечером».
    bool unparsedAt(int k) {
      if (!_unparsedDayWord(word(k))) return false;
      return !(_monthNumbers.containsKey(word(k)) &&
          k > 0 &&
          adjacent(k - 1, k) &&
          _monthDay(word(k - 1)) != null);
    }

    bool nextToUnparsedDay(int first, int last) {
      if (first > 0 && adjacent(first - 1, first) && unparsedAt(first - 1)) {
        return true;
      }
      if (last + 1 >= words.length || !adjacent(last, last + 1)) return false;
      if (unparsedAt(last + 1)) return true;
      return _allDigits.hasMatch(word(last + 1)) &&
          last + 2 < words.length &&
          adjacent(last + 1, last + 2) &&
          unparsedAt(last + 2);
    }

    for (var i = 0; i < words.length; i++) {
      // «в обед» — середина дня: условные 13:00, кончается в 15:00. «На
      // обед», «сходить на обед» — само событие, не срок.
      if (word(i) == 'обед' &&
          i > 0 &&
          adjacent(i - 1, i) &&
          (word(i - 1) == 'в' || word(i - 1) == 'во')) {
        if (nextToUnparsedDay(i - 1, i)) continue;
        result.add(
          _PartFound(
            words[i - 1].start,
            words[i].end,
            PartOfDay.day,
            lunch: true,
          ),
        );
        continue;
      }
      // «К вечеру пятницы»: часть суток дня в родительном падеже.
      final dative = _partDatives[word(i)];
      if (dative != null &&
          i > 0 &&
          i + 1 < words.length &&
          adjacent(i - 1, i) &&
          adjacent(i, i + 1) &&
          (word(i - 1) == 'к' || word(i - 1) == 'ко') &&
          _weekdayForms[word(i + 1)]?.$2 == _genitivePrepositions) {
        result.add(_PartFound(words[i - 1].start, words[i].end, dative));
        continue;
      }
      // «на вечер», «на утро пятницы», «с утра на вечер».
      final noun = _partNouns[word(i)];
      final followed = noun != null &&
          (i + 1 >= words.length ||
              !_onlySpaces(text, words[i].end, words[i + 1].start) ||
              _partNounFollowers.contains(word(i + 1)) ||
              // «напоминание на утро написать Андрею», «на вечер чтобы я
              // купил хлеб»: дальше само дело.
              isInfinitive(word(i + 1)) ||
              SpeechNoise.isJunk(word(i + 1)) ||
              _dayWords.containsKey(word(i + 1)) ||
              _weekdayForms[word(i + 1)]?.$2 == _genitivePrepositions);
      // «на завтрашнее утро», «на завтрашний вечер»: день — в прилагательном.
      // Прилагательное само говорит о времени, поэтому после него может
      // стоять и цель: «перенеси на завтрашний вечер звонок». Слово в
      // родительном падеже после — событие: «на завтрашний вечер встречи
      // выпускников» — не срок.
      final dayOffset =
          noun != null && i > 1 ? _dayAdjectives[word(i - 1)] : null;
      if (dayOffset != null &&
          adjacent(i - 1, i) &&
          adjacent(i - 2, i - 1) &&
          word(i - 2) == 'на') {
        final genitiveAfter =
            i + 1 < words.length && _genitiveEnding.hasMatch(word(i + 1));
        if ((!followed && genitiveAfter) || nextToUnparsedDay(i, i)) continue;
        result.add(
          _PartFound(
            words[i - 2].start,
            words[i].end,
            noun!,
            dayOffset: dayOffset,
          ),
        );
        continue;
      }
      if (noun != null && i > 0 && adjacent(i - 1, i) && word(i - 1) == 'на') {
        if (!followed || nextToUnparsedDay(i, i)) continue;
        var start = i - 1;
        if (start >= 2 &&
            adjacent(start - 1, start) &&
            adjacent(start - 2, start - 1) &&
            _sourceParts.contains(word(start - 1)) &&
            (word(start - 2) == 'с' || word(start - 2) == 'со')) {
          start -= 2;
        }
        result.add(_PartFound(words[start].start, words[i].end, noun));
        continue;
      }
      // «с утра», «с утра пораньше», «завтра с утра»: утро как срок.
      // «С утра на вечер» и «с утра до вечера» — откуда и докуда, а «весь
      // день с утра» — не срок.
      if ((word(i) == 'утра' || word(i) == 'утречка') &&
          i > 0 &&
          adjacent(i - 1, i) &&
          (word(i - 1) == 'с' || word(i - 1) == 'со') &&
          !(i + 1 < words.length && _morningRangeAfter.contains(word(i + 1))) &&
          !(i > 1 && _morningRangeBefore.contains(word(i - 2)))) {
        var last = i;
        if (last + 1 < words.length &&
            adjacent(last, last + 1) &&
            _earlyWords.contains(word(last + 1))) {
          last++;
        }
        if (nextToUnparsedDay(i - 1, last)) continue;
        result.add(
          _PartFound(words[i - 1].start, words[last].end, PartOfDay.morning),
        );
        i = last;
        continue;
      }
      // «ближе к вечеру», «ближе к обеду» — та же часть суток. Голое «к
      // вечеру» — крайний срок, оно пока не срок (см. [_partWords]).
      if (word(i) == 'ближе' &&
          i + 2 < words.length &&
          adjacent(i, i + 1) &&
          adjacent(i + 1, i + 2) &&
          (word(i + 1) == 'к' || word(i + 1) == 'ко')) {
        final closer = _closerParts[word(i + 2)];
        if (closer != null && !nextToUnparsedDay(i, i + 2)) {
          result.add(
            _PartFound(
              words[i].start,
              words[i + 2].end,
              closer,
              lunch: closer == PartOfDay.day,
            ),
          );
          i += 2;
          continue;
        }
      }
      var part = _partWords[word(i)];
      var last = i;
      if (part == null &&
          word(i) == 'после' &&
          i + 1 < words.length &&
          word(i + 1) == 'обеда' &&
          adjacent(i, i + 1)) {
        part = PartOfDay.afternoon;
        last = i + 1;
        // «после обеда с клиентом» — после события, а не время.
        if (last + 1 < words.length &&
            (word(last + 1) == 'с' || word(last + 1) == 'со')) {
          continue;
        }
      }
      if (part == null) continue;
      if (i > 0 &&
          adjacent(i - 1, i) &&
          _partBlockersBefore.contains(word(i - 1))) {
        continue;
      }
      if (last + 1 < words.length &&
          adjacent(last, last + 1) &&
          _partBlockersAfter.contains(word(last + 1))) {
        continue;
      }
      final start =
          i > 0 && adjacent(i - 1, i) && word(i - 1) == 'этим' ? i - 1 : i;
      if (nextToUnparsedDay(start, last)) continue;
      result.add(_PartFound(words[start].start, words[last].end, part));
      i = last;
    }
    return result;
  }

  /// Время для правила «сегодняшний день недели»: с частью суток без часа
  /// день ещё сегодняшний, пока часть не кончилась («в пятницу вечером»
  /// в пятницу днём — сегодня).
  static Set<(int, int)> _weekdayClock(Set<(int, int)> clock, int? endHour) {
    if (clock.isNotEmpty || endHour == null) return clock;
    return <(int, int)>{(endHour - 1, 59)};
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

  /// Дни недели во множественном числе после «по»: «по пятницам».
  static const Map<String, int> _recurringWeekdays = <String, int>{
    'понедельникам': DateTime.monday,
    'вторникам': DateTime.tuesday,
    'средам': DateTime.wednesday,
    'четвергам': DateTime.thursday,
    'пятницам': DateTime.friday,
    'субботам': DateTime.saturday,
    'воскресеньям': DateTime.sunday,
  };

  /// «каждую пятницу», «каждый понедельник», «каждое воскресенье».
  static const Set<String> _everyWords = <String>{
    'каждую',
    'каждый',
    'каждое',
    'каждая',
  };

  /// Слова повторения перед «по пятницам»: «recurring по пятницам»,
  /// «еженедельно по пятницам» — часть срока.
  static const Set<String> _recurrenceWords = <String>{
    'recurring',
    'еженедельно',
    'регулярно',
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
    // «на след неделе» — сокращение, как пишут в спешке.
    if (word.startsWith('следующ') ||
        word.startsWith('будущ') ||
        word == 'след') {
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
    // «Через сутки» — ровно 24 часа, с тем же временем, а не «на завтра».
    'сутки': (_Unit.hour, 24),
    'неделю': (_Unit.week, 1),
    'недельку': (_Unit.week, 1),
    'месяц': (_Unit.month, 1),
    'месяцок': (_Unit.month, 1),
  };

  /// «в 10 по мск», «в 9 по Москве»: время уже местное — пояс не меняет.
  static const Set<String> _moscowWords = <String>{
    'мск',
    'москве',
    'московскому',
  };

  /// Слова приблизительности или точности перед временем: «ровно в шесть»,
  /// «примерно в 10» — часть срока, а не названия.
  /// Срок — час после «в/к»: «в шесть», «в 6».
  static final RegExp _hedgedHour = RegExp(r'^(?:в|во|к|ко)\s+\d');

  static const Set<String> _clockHedges = <String>{
    'ровно',
    'примерно',
    'приблизительно',
    // «…, лучше в среду», «желательно до пятницы» — оговорка срока.
    'лучше',
    'желательно',
  };

  /// «в это же время», «на то же время».
  static const Set<String> _sameTimePrepositions = <String>{'в', 'во', 'на'};
  static const Set<String> _sameTimePronouns = <String>{'это', 'то'};

  /// «через час с небольшим», «через неделю с лишним».
  static const Set<String> _approximately = <String>{
    'небольшим',
    'лишним',
    'хвостиком',
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
    bool monthDate(int k) =>
        k + 1 < words.length &&
        _monthDay(words[k].group(0)!) != null &&
        _monthNumbers.containsKey(words[k + 1].group(0));
    // «в 10 15 ноября».
    if (monthDate(index)) return true;
    if (!_attachedPrepositions.contains(word) || index + 1 >= words.length) {
      return false;
    }
    final next = words[index + 1].group(0)!;
    return monthDate(index + 1) ||
        _monthParts.containsKey(next) ||
        _weekdayForms.containsKey(next) ||
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
    // «через часа полтора», «через минут десять», «через дня три» —
    // единица перед числом: так говорят о приблизительном сроке.
    final inverted = _relativeUnits[value];
    if (inverted != null && value.length > 1 && adjacentTo(i)) {
      final next = words[i + 1].group(0)!;
      if ((next == 'полтора' || next == 'полторы') && inverted == _Unit.hour) {
        return (_Unit.minute, <double>[90], i + 1);
      }
      final number = _readNumber(text, words, i + 1);
      if (number != null &&
          number.$1.every((double v) => v > 0 && v == v.roundToDouble()) &&
          !(adjacentTo(number.$2) &&
              _relativeUnits.containsKey(words[number.$2 + 1].group(0)))) {
        return (inverted, number.$1, number.$2);
      }
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

  /// Месяцы в родительном падеже после числа: «15 ноября».
  static const Map<String, int> _monthNumbers = <String, int>{
    'января': 1,
    'февраля': 2,
    'марта': 3,
    'апреля': 4,
    'мая': 5,
    'июня': 6,
    'июля': 7,
    'августа': 8,
    'сентября': 9,
    'октября': 10,
    'ноября': 11,
    'декабря': 12,
  };

  /// Число дня перед месяцем: одна-две цифры без ведущего нуля
  /// у однозначных («05 ноября» тоже число дня).
  static int? _monthDay(String word) {
    if (word.isEmpty || word.length > 2 || !_allDigits.hasMatch(word)) {
      return null;
    }
    return int.parse(word);
  }

  /// Даты словами: «15 ноября», «до 20 декабря», «16 апреля 2027 [года]».
  /// Без года — ближайшая не раньше сегодняшнего дня, как у ДД.ММ: «25
  /// октября» в ноябре — следующего года. Несуществующая дата («31
  /// февраля», «30 февраля в 10», «45 марта») — фрагмент с
  /// [_Found.invalid]: срок становится уточнением invalidDate, а дата
  /// не попадает в название.
  List<_Found> _monthMentions(
    String text,
    List<RegExpMatch> words,
    DateTime today,
  ) {
    final result = <_Found>[];
    for (var i = 0; i + 1 < words.length; i++) {
      final day = _monthDay(words[i].group(0)!);
      final month = _monthNumbers[words[i + 1].group(0)];
      if (day == null ||
          month == null ||
          !_onlySpaces(text, words[i].end, words[i + 1].start)) {
        continue;
      }
      // «12.5 ноября», «10:15 ноября» — часть другой записи.
      if (_touchesNumberPunctuation(text, words[i].start, words[i].end)) {
        continue;
      }
      var last = i + 1;
      String? yearText;
      // Год: «2026», «1999», «2026г» слитно; любое четырёхзначное число —
      // со словом «года» или «г»: «15 ноября 1850 года». Прошедший год —
      // inPast, несуществующая дата («29 февраля 2100 года») — invalidDate,
      // как у «15.11.1999»; год не остаётся в названии.
      final yearWord = last + 1 < words.length &&
              _onlySpaces(text, words[last].end, words[last + 1].start)
          ? _yearWord.firstMatch(words[last + 1].group(0)!)
          : null;
      final yearMarked = yearWord != null &&
          (yearWord.group(2) != null ||
              (last + 2 < words.length &&
                  _onlySpaces(
                    text,
                    words[last + 1].end,
                    words[last + 2].start,
                  ) &&
                  (words[last + 2].group(0) == 'года' ||
                      words[last + 2].group(0) == 'г')));
      if (yearWord != null &&
          (yearMarked || _plainYear.hasMatch(yearWord.group(1)!))) {
        yearText = yearWord.group(1);
        last++;
        if (yearWord.group(2) == null &&
            last + 1 < words.length &&
            _onlySpaces(text, words[last].end, words[last + 1].start) &&
            (words[last + 1].group(0) == 'года' ||
                words[last + 1].group(0) == 'г')) {
          last++;
        }
      }
      final date = _resolveDate(day, month, yearText, today);
      final source = _isSource(text, words[i].start);
      // «с 15 на 17 марта»: у исходного числа месяц общий с новым сроком.
      if (!source &&
          i >= 3 &&
          words[i - 1].group(0) == 'на' &&
          _sourcePrepositions.contains(words[i - 3].group(0)) &&
          _onlySpaces(text, words[i - 3].end, words[i - 2].start) &&
          _onlySpaces(text, words[i - 2].end, words[i - 1].start) &&
          _onlySpaces(text, words[i - 1].end, words[i].start) &&
          !_touchesNumberPunctuation(
            text,
            words[i - 2].start,
            words[i - 2].end,
          )) {
        final sourceDay = _monthDay(words[i - 2].group(0)!);
        final sourceDate = sourceDay == null
            ? null
            : _resolveDate(sourceDay, month, yearText, today);
        if (sourceDate != null) {
          result.add(
            _Found(
              words[i - 2].start,
              words[i - 2].end,
              date: sourceDate,
              isSource: true,
            ),
          );
        }
      }
      result.add(
        date == null
            ? _Found(words[i].start, words[last].end, invalid: true)
            : _Found(
                words[i].start,
                words[last].end,
                date: date,
                isSource: source,
              ),
      );
      i = last;
    }
    return result;
  }

  /// Год после даты словами: «2026» или слитно «2026г».
  static final RegExp _yearWord = RegExp(r'^(\d{4})(г)?$');

  /// «В Новый год», «к Новому году», «до нового года», «в нг» — 1 января
  /// (ближайшее, сегодня — если сегодня 1 января). Только после предлога
  /// «в/на/к/до»: «новый год прошёл весело» — не срок.
  static List<_Found> _newYearMentions(
    String text,
    List<RegExpMatch> words,
    DateTime today,
  ) {
    String word(int i) => words[i].group(0)!;
    bool adjacent(int left, int right) =>
        _onlySpaces(text, words[left].end, words[right].start);
    final date =
        today.month == 1 && today.day == 1 ? today : DateTime(today.year + 1);
    final result = <_Found>[];
    for (var i = 1; i < words.length; i++) {
      final preposition = word(i - 1);
      if (!_newYearPrepositions.contains(preposition) || !adjacent(i - 1, i)) {
        continue;
      }
      var last = -1;
      if (word(i) == 'нг') {
        last = i;
      } else if (i + 1 < words.length &&
          adjacent(i, i + 1) &&
          _newYearForms[word(i)] == word(i + 1)) {
        last = i + 1;
      }
      if (last < 0) continue;
      result.add(_Found(words[i].start, words[last].end, date: date));
      i = last;
    }
    return result;
  }

  static const Set<String> _newYearPrepositions = <String>{
    'в',
    'на',
    'к',
    'ко',
    'до',
  };

  /// «Новый год» в падежах после предлогов: прилагательное → существительное.
  static const Map<String, String> _newYearForms = <String, String>{
    'новый': 'год',
    'новому': 'году',
    'нового': 'года',
  };

  /// Год без «года»: только похожий на год — 1900…2199. Другое число
  /// после даты («15 ноября 5000 рублей») годом не считается.
  static final RegExp _plainYear = RegExp(r'^(?:19|20|21)\d\d$');

  /// Число месяца без названия месяца: «на 20 число», «на 20-е», «на 18-е
  /// число», «до 20-го», «к 20-му» — срок; «с 12-го», «с 12-го числа» —
  /// исходный срок переноса. День — в этом месяце, если ещё не прошёл,
  /// иначе в следующем (в месяце без такого числа — в ближайшем, где оно
  /// есть). Без предлога «12-го» — исходный срок, только если во фразе
  /// есть и новый («с встречи 12-го на 18-е»); иначе это не срок («созвон
  /// 5-го вечером» — разбор такой даты не угадывает).
  List<_Found> _dayOfMonthMentions(
    String text,
    List<RegExpMatch> words,
    DateTime today,
  ) {
    String word(int i) => words[i].group(0)!;
    bool adjacent(int left, int right) =>
        _onlySpaces(text, words[left].end, words[right].start);
    DateTime? resolve(int day) {
      for (var offset = 0; offset <= 2; offset++) {
        final candidate = DateTime(today.year, today.month + offset, day);
        if (candidate.day != day) continue;
        if (offset == 0 && candidate.isBefore(today)) continue;
        return candidate;
      }
      return null;
    }

    final result = <_Found>[];
    final bare = <_Found>[];
    for (var i = 0; i < words.length; i++) {
      final value = word(i);
      // «5го», «15ое» — окончание вплотную, как пишут в спешке.
      final glued = _gluedOrdinal.firstMatch(value);
      // «К первому числу», «до пятого числа» — порядковое словом, только
      // со словом «число».
      final spelled = glued == null ? NumberWords.ordinal(value) : null;
      if (spelled != null) {
        if (i + 1 >= words.length ||
            !adjacent(i, i + 1) ||
            !_monthDayNouns.contains(word(i + 1))) {
          continue;
        }
      } else if (glued == null &&
          (value.length > 2 || !_allDigits.hasMatch(value))) {
        continue;
      }
      final day = spelled?.$1 ?? int.parse(glued?.group(1) ?? value);
      if (day < 1 || day > 31) continue;
      if (_touchesNumberPunctuation(text, words[i].start, words[i].end)) {
        continue;
      }
      var last = i;
      String? ending = glued?.group(2) ?? spelled?.$2;
      final end = words[i].end;
      if (glued == null &&
          i + 1 < words.length &&
          end < text.length &&
          (text[end] == '-' || text[end] == '–') &&
          words[i + 1].start == end + 1 &&
          _ordinalEndings.contains(word(i + 1))) {
        ending = word(i + 1);
        last = i + 1;
      }
      var noun = false;
      if (last + 1 < words.length &&
          adjacent(last, last + 1) &&
          _monthDayNouns.contains(word(last + 1))) {
        noun = true;
        last++;
      }
      if (ending == null && !noun) continue;
      final preposition = i > 0 && adjacent(i - 1, i) ? word(i - 1) : null;
      final genitive = ending == 'го' || ending == 'ого';
      final accusative = ending == 'е' ||
          ending == 'ое' ||
          (ending == null && word(last) == 'число');
      final dative = ending == 'му' ||
          ending == 'ому' ||
          (ending == null && word(last) == 'числу');
      final date = resolve(day);
      final source = _sourcePrepositions.contains(preposition);
      if ((preposition == 'на' && accusative) ||
          (preposition == 'до' && genitive) ||
          ((preposition == 'к' || preposition == 'ко') && dative) ||
          (source && genitive)) {
        result.add(
          date == null
              ? _Found(words[i].start, words[last].end, invalid: true)
              : _Found(
                  words[i].start,
                  words[last].end,
                  date: date,
                  isSource: source,
                ),
        );
        i = last;
        continue;
      }
      if ((genitive || (ending == null && word(last) == 'числа')) &&
          date != null &&
          (preposition == null ||
              !_attachedPrepositions.contains(preposition))) {
        bare.add(
          _Found(words[i].start, words[last].end, date: date, isSource: true),
        );
        i = last;
      }
    }
    if (result.any((_Found f) => !f.isSource && !f.invalid)) {
      result.addAll(bare);
    } else if (result.isEmpty && bare.length == 1) {
      // «Напомни 15-го записаться», «5го оплатить кредит», «15 числа
      // заплатить»: единственное число месяца без предлога — сам срок.
      // Рядом с другим днём («встречу 12-го на 18-е») — исходный.
      final only = bare.single;
      result.add(_Found(only.start, only.end, date: only.date));
    }
    return result;
  }

  static const Set<String> _monthDayNouns = <String>{
    'число',
    'числа',
    'числу',
  };

  /// «на 5 дней назад», «на неделю назад» — прошедший день: перенос туда —
  /// «уже прошло».
  List<_Found> _agoMentions(
    String text,
    List<RegExpMatch> words,
    DateTime today,
  ) {
    final result = <_Found>[];
    for (var i = 0; i + 1 < words.length; i++) {
      if (words[i].group(0) != 'на' ||
          !_onlySpaces(text, words[i].end, words[i + 1].start)) {
        continue;
      }
      final component = _readComponent(text, words, i + 1);
      if (component == null) continue;
      final (unit, values, last) = component;
      if (values.length != 1 ||
          last + 1 >= words.length ||
          words[last + 1].group(0) != 'назад' ||
          !_onlySpaces(text, words[last].end, words[last + 1].start)) {
        continue;
      }
      final amount = values.single.toInt();
      // «на 2 часа назад» — тоже прошлое: вчерашний день достаточно,
      // чтобы срок стал «уже прошло».
      final date = switch (unit) {
        _Unit.minute ||
        _Unit.hour =>
          DateTime(today.year, today.month, today.day - 1),
        _Unit.day => DateTime(today.year, today.month, today.day - amount),
        _Unit.week => DateTime(today.year, today.month, today.day - 7 * amount),
        _Unit.month => _addMonths(today, -amount),
      };
      result.add(_Found(words[i + 1].start, words[last + 1].end, date: date));
    }
    return result;
  }

  /// «через 3 дня», «через час», «через пару недель», «через полчаса»,
  /// «через 2 часа 30 минут». Минуты и часы дают точное время, дни,
  /// недели и месяцы — день. Диапазон «через 10-15 минут» даёт два срока,
  /// и разбор переспрашивает. Минуты и часы отсчитываются по реальному
  /// времени (переход на зимнее время не сдвигает срок), дни — по
  /// календарю.
  /// Минуты числом или словами сразу после [last] («час сорок», «два
  /// часа 15»): (минуты, номер последнего слова) или `null`.
  static (int, int)? _bareMinutes(
    String text,
    List<RegExpMatch> words,
    int last,
  ) {
    final first = last + 1;
    if (first >= words.length ||
        !_onlySpaces(text, words[last].end, words[first].start)) {
      return null;
    }
    int? value;
    var end = first;
    final digits = int.tryParse(words[first].group(0)!);
    if (digits != null) {
      value = digits;
    } else {
      final spelled = NumberWords.find(
        text.substring(words[first].start),
      ).firstOrNull;
      if (spelled == null || spelled.start != 0) return null;
      value = spelled.value;
      final stop = words[first].start + spelled.end;
      while (end + 1 < words.length && words[end + 1].end <= stop) {
        end++;
      }
    }
    if (value < 1 || value > 59) return null;
    final after = end + 1;
    if (after < words.length &&
        _onlySpaces(text, words[end].end, words[after].start)) {
      final word = words[after].group(0)!;
      if (!isInfinitive(word) && !_bareMinutesFollowers.contains(word)) {
        return null;
      }
    }
    return (value, end);
  }

  static const Set<String> _bareMinutesFollowers = <String>{
    'надо',
    'нужно',
    'напомни',
    'мне',
  };

  List<_Found> _relativeMentions(
    String text,
    List<RegExpMatch> words,
    DateTime now,
  ) {
    final result = <_Found>[];
    final today = DateTime(now.year, now.month, now.day);
    // «отложи на 3 дня», «сдвинь на час»: после глагола отсрочки «на N …»
    // — то же, что «через N …».
    final postpone = _postpones(words);
    for (var i = 0; i + 1 < words.length; i++) {
      final head = words[i].group(0);
      if (head != 'через' && !(postpone && head == 'на')) continue;
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
      // «Через час сорок», «через два часа двадцать» — минуты без слова
      // «минут» после часов. Дальше — конец, знак или инфинитив: «через
      // час двадцать человек» — не срок минут.
      if (components.last.$1 == _Unit.hour) {
        final minutes = _bareMinutes(text, words, last);
        if (minutes != null) {
          components.add((_Unit.minute, <double>[minutes.$1.toDouble()]));
          last = minutes.$2;
        }
      }
      // «через час с небольшим», «через неделю с лишним» — тот же срок,
      // приблизительно: уточнение не попадает в название.
      if (head == 'через' &&
          last + 2 < words.length &&
          words[last + 1].group(0) == 'с' &&
          _approximately.contains(words[last + 2].group(0)) &&
          _onlySpaces(text, words[last].end, words[last + 1].start) &&
          _onlySpaces(text, words[last + 1].end, words[last + 2].start)) {
        last += 2;
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

  /// После «на N» — единица или счётное слово: «завтра на 10 минут», «на 2
  /// дня», «на 3 человек». Тогда «на N» — не час.
  static bool _naCounted(List<RegExpMatch> words, int index) {
    if (index + 1 >= words.length) return false;
    final next = words[index + 1].group(0)!;
    return _relativeUnits.containsKey(next) ||
        _singleUnits.containsKey(next) ||
        _units.contains(next) ||
        _unitPrefixes.any(next.startsWith) ||
        next.startsWith('человек') ||
        next.startsWith('персон');
  }

  /// «на 15 часов», «на 7 вечера», «на 2 часа дня» — время на часах, а не
  /// длительность: час 13–23 со словом «час(а/ов)» или час с частью суток
  /// («утра», «вечера», «ночи», «часа дня»). «На 3 дня», «на 2 часа» —
  /// длительность, не время. После глагола отсрочки «на 15 часов» — сдвиг
  /// ([_postpones]).
  static bool _clockAfterNa(
    String preposition,
    String value,
    List<RegExpMatch> suffix, {
    required bool postpone,
  }) {
    if (preposition != 'на' || suffix.isEmpty) return false;
    final first = suffix.first.group(0)!;
    if (suffix.length == 2) return true;
    // «бронь отеля на 2 ночи» — число ночей, а не 02:00; время — «на 2
    // часа ночи» или «в 2 ночи».
    if (first == 'ночи') return false;
    if (_bareHourSuffixes.contains(first)) return true;
    if (!_hourWords.contains(first) || postpone) return false;
    final hour = int.tryParse(value);
    return hour != null && hour >= 13 && hour <= 23;
  }

  /// Во фразе есть просьба отсрочить: «отложи», «откладывай», «сдвинь»,
  /// «сдвигай», «передвинь» или инфинитив после «можешь/можно»
  /// («можешь отложить встречу на 3 дня»). После неё «на 3 дня» — сдвиг от
  /// текущего момента, как «через 3 дня». Глагол внутри названия задачи
  /// («добавь задачу сдвинуть встречу на 2 часа», «отложить деньги на 3
  /// дня», «отложенный платёж») — не просьба: там «на N …» — длительность.
  /// «Перенеси на 2 часа» сюда не входит: это скорее «на 2 часа дня».
  static bool _postpones(List<RegExpMatch> words) {
    for (var i = 0; i < words.length; i++) {
      final value = words[i].group(0)!;
      if (_postponeImperatives.contains(value)) return true;
      if (_postponeInfinitives.contains(value) &&
          i > 0 &&
          _postponeModals.contains(words[i - 1].group(0))) {
        return true;
      }
    }
    return false;
  }

  /// Повелительные формы отсрочки: «отложи», «сдвиньте», «давай сдвинем».
  static const Set<String> _postponeImperatives = <String>{
    'отложи',
    'отложите',
    'отложим',
    'откладывай',
    'откладывайте',
    'сдвинь',
    'сдвиньте',
    'сдвинем',
    'сдвигай',
    'сдвигайте',
    'передвинь',
    'передвиньте',
    'передвинем',
    'передвигай',
    'передвигайте',
  };

  static const Set<String> _postponeInfinitives = <String>{
    'отложить',
    'откладывать',
    'сдвинуть',
    'сдвигать',
    'передвинуть',
    'передвигать',
  };

  /// Просьба с инфинитивом: «можешь отложить», «можно сдвинуть».
  static const Set<String> _postponeModals = <String>{
    'можешь',
    'можете',
    'сможешь',
    'сможете',
    'можно',
  };

  static final RegExp _allDigits = RegExp(r'^\d+$');

  /// Окончание, похожее на родительный падеж: «(вечер) встречи».
  static final RegExp _genitiveEnding = RegExp(r'[аяиы]$');

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

    // «в конце недели», «к концу следующей недели» — пятница той недели;
    // «в начале (следующей) недели» — понедельник, «в середине недели» —
    // среда. Без уточнения начало и середина — ближайшие: в четверг
    // «в начале недели» — уже следующий понедельник.
    for (var i = 0; i + 1 < words.length; i++) {
      final value = word(i);
      final weekday = _weekParts[value];
      if (weekday == null) continue;
      if (weekday != DateTime.friday &&
          (i == 0 ||
              !adjacent(i - 1, i) ||
              !_weekPartPrepositions.contains(word(i - 1)))) {
        continue;
      }
      var j = i + 1;
      var scope = _WeekScope.current;
      var named = false;
      final modifier = _weekModifier(word(j));
      if (modifier != null && j + 1 < words.length && adjacent(i, j)) {
        scope = modifier;
        named = true;
        j++;
      }
      if (word(j) != 'недели' || !adjacent(j - 1, j)) continue;
      final week = scope == _WeekScope.next ||
              (!named && weekday != DateTime.friday && today.weekday > weekday)
          ? 1
          : 0;
      result.add(
        _Found(
          words[i].start,
          words[j].end,
          date: weekDay(week, weekday),
        ),
      );
      for (var k = i; k <= j; k++) {
        used.add(k);
      }
    }

    // «в начале месяца», «в середине месяца», «к концу месяца», «в конце
    // следующего месяца». Без уточнения: начало — 1-е число ближайшего ещё
    // не начавшегося месяца, середина — 15-е этого месяца, а если оно
    // прошло, — следующего, конец — последний день этого месяца.
    for (var i = 0; i + 1 < words.length; i++) {
      if (used.contains(i)) continue;
      final kind = _monthParts[word(i)];
      if (kind == null) continue;
      // Срок — только после предлога срока, и у каждого падежа свой:
      // «в начале», «к началу», «до конца», «на конец месяца». «С начала
      // месяца», «после середины месяца», «отчёт о конце месяца», «для
      // конца месяца» или без предлога — не срок: фраза остаётся в
      // названии целиком.
      final preposition = i == 0 || !adjacent(i - 1, i) ? null : word(i - 1);
      if (preposition == null ||
          !(_monthPartPrepositions[word(i)]?.contains(preposition) ?? false)) {
        continue;
      }
      var j = i + 1;
      _WeekScope? scope;
      if (word(j) == 'текущего') {
        scope = _WeekScope.current;
        j++;
      } else {
        final modifier = _weekModifier(word(j));
        if (modifier != null && modifier != _WeekScope.nearest) {
          scope = modifier;
          j++;
        }
      }
      if (j >= words.length ||
          word(j) != 'месяца' ||
          !adjacent(i, i + 1) ||
          !adjacent(j - 1, j)) {
        continue;
      }
      DateTime monthDay(int offset, int day) =>
          DateTime(today.year, today.month + offset, day);
      final date = switch ((kind, scope)) {
        (_MonthPart.start, _WeekScope.current) => monthDay(0, 1),
        (_MonthPart.start, _) => monthDay(1, 1),
        (_MonthPart.middle, _WeekScope.next) => monthDay(1, 15),
        (_MonthPart.middle, _WeekScope.current) => monthDay(0, 15),
        (_MonthPart.middle, _) =>
          today.day <= 15 ? monthDay(0, 15) : monthDay(1, 15),
        (_MonthPart.end, _WeekScope.next) => monthDay(2, 0),
        (_MonthPart.end, _) => monthDay(1, 0),
      };
      result.add(
        _Found(
          words[i].start,
          words[j].end,
          date: date,
          isSource: _isSource(text, words[i].start),
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
      // «на этой неделе», «на эту неделю» без дня — пятница этой недели,
      // а в субботу и воскресенье — её воскресенье. Без предлога («отчёт
      // этой недели») — не срок.
      final thisWeek = scope == _WeekScope.current &&
          i > 0 &&
          adjacent(i - 1, i) &&
          (word(i - 1) == 'на' || word(i - 1) == 'в' || word(i - 1) == 'во');
      weekSpans.add(
        _Found(
          words[i].start,
          words[i + 1].end,
          date: scope == _WeekScope.next
              ? weekDay(1, DateTime.monday)
              : thisWeek
                  ? weekDay(
                      0,
                      today.weekday <= DateTime.friday
                          ? DateTime.friday
                          : DateTime.sunday,
                    )
                  : null,
        ),
      );
      used
        ..add(i)
        ..add(i + 1);
    }

    // «на выходных», «в эти выходные», «на следующих выходных», «на
    // выходной».
    for (var i = 1; i < words.length; i++) {
      final value = word(i);
      if (value != 'выходных' && value != 'выходные' && value != 'выходной') {
        continue;
      }
      var start = i;
      var scope = _WeekScope.nearest;
      final modifier = _weekModifier(word(i - 1));
      if (modifier != null && adjacent(i - 1, i)) {
        scope = modifier;
        start = i - 1;
      }
      if (start == 0 ||
          !adjacent(start - 1, start) ||
          (value == 'выходных'
              ? word(start - 1) != 'на'
              : word(start - 1) != 'в' && word(start - 1) != 'на')) {
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
    final takenEnds = <int>{for (final span in taken) span.end};
    final weekdays = <_Found>[];

    // Ближайший такой день: сегодня — только если названное время ещё
    // не прошло, иначе через неделю.
    DateTime nearest(int weekday) {
      var delta = (weekday - today.weekday) % 7;
      if (delta == 0) {
        final time = clock.length == 1 ? clock.single : null;
        final stillToday = time != null &&
            DateTime(today.year, today.month, today.day, time.$1, time.$2)
                .isAfter(now);
        if (!stillToday) delta = 7;
      }
      return DateTime(today.year, today.month, today.day + delta);
    }

    // Повторение: «по пятницам», «каждую пятницу», «recurring по
    // пятницам», «по понедельникам и средам». Повторяющихся задач пока нет:
    // срок — ближайший такой день, как у «в пятницу».
    int? lastRecurring;
    for (var i = 0; i < words.length; i++) {
      if (used.contains(i)) continue;
      final plural = _recurringWeekdays[word(i)];
      final single = _weekdayForms[word(i)];
      int? weekday;
      var start = i;
      if (plural != null &&
          i > 0 &&
          adjacent(i - 1, i) &&
          word(i - 1) == 'по') {
        weekday = plural;
        start = i - 1;
      } else if (plural != null &&
          lastRecurring != null &&
          i - 2 == lastRecurring &&
          (word(i - 1) == 'и' || word(i - 1) == 'или') &&
          adjacent(i - 1, i)) {
        weekday = plural;
      } else if (plural != null &&
          lastRecurring != null &&
          i - 1 == lastRecurring &&
          text.substring(words[i - 1].end, words[i].start).contains(',') &&
          _onlyPunctuation(text, words[i - 1].end, words[i].start)) {
        weekday = plural;
      } else if (single != null &&
          single.$2 == _accusativePrepositions &&
          i > 0 &&
          adjacent(i - 1, i) &&
          _everyWords.contains(word(i - 1))) {
        weekday = single.$1;
        start = i - 1;
      }
      if (weekday == null) continue;
      if (start > 0 &&
          adjacent(start - 1, start) &&
          _recurrenceWords.contains(word(start - 1))) {
        start--;
      }
      lastRecurring = i;
      for (var k = start; k <= i; k++) {
        used.add(k);
      }
      weekdays.add(
        _Found(
          words[start].start,
          words[i].end,
          date: nearest(weekday),
          recurring: true,
        ),
      );
    }

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
      // «на вечер пятницы», «на утро понедельника»: родительный падеж
      // после части суток.
      final afterPartNoun = prepositions == _genitivePrepositions &&
          start > 1 &&
          adjacent(start - 2, start - 1) &&
          ((_partNouns.containsKey(preposition) && word(start - 2) == 'на') ||
              (_partDatives.containsKey(preposition) &&
                  (word(start - 2) == 'к' || word(start - 2) == 'ко')));
      // «на следующую неделю вторник»: день сразу за неделей.
      final afterWeek = start > 0 &&
          weekSpans.any((_Found w) => w.end == words[start - 1].end) &&
          _onlyPunctuation(text, words[start - 1].end, words[start].start) &&
          prepositions == _accusativePrepositions;
      // «на 15:00 пятницы»: родительный падеж сразу за временем.
      final afterTime = start == i &&
          start > 0 &&
          prepositions == _genitivePrepositions &&
          takenEnds.contains(words[start - 1].end) &&
          adjacent(start - 1, start);
      final withPreposition = afterPartNoun ||
          afterWeek ||
          afterTime ||
          (preposition != null && prepositions.contains(preposition));
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
          date = nearest(weekday);
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

  /// Части недели и их день: «в начале недели» — понедельник.
  static const Map<String, int> _weekParts = <String, int>{
    'конце': DateTime.friday,
    'концу': DateTime.friday,
    'конца': DateTime.friday,
    'начале': DateTime.monday,
    'началу': DateTime.monday,
    'середине': DateTime.wednesday,
    'середину': DateTime.wednesday,
  };

  /// Предлоги перед началом и серединой недели: «с начала недели» — не
  /// срок.
  static const Set<String> _weekPartPrepositions = <String>{
    'в',
    'во',
    'к',
    'ко',
    'на',
  };

  /// «в начале», «в середине», «в конце» месяца.
  static const Map<String, _MonthPart> _monthParts = <String, _MonthPart>{
    'начале': _MonthPart.start,
    'началу': _MonthPart.start,
    'начала': _MonthPart.start,
    'начало': _MonthPart.start,
    'середине': _MonthPart.middle,
    'середины': _MonthPart.middle,
    'середину': _MonthPart.middle,
    'конце': _MonthPart.end,
    'концу': _MonthPart.end,
    'конца': _MonthPart.end,
    'конец': _MonthPart.end,
  };

  /// Предлоги срока перед каждой формой части месяца (docs/CORPUS.md):
  /// «в начале», «к началу», «до начала», «на начало». «В середине» и «к
  /// середине» — одна форма.
  static const Map<String, Set<String>> _monthPartPrepositions =
      <String, Set<String>>{
    'начале': <String>{'в', 'во'},
    'началу': <String>{'к', 'ко'},
    'начала': <String>{'до'},
    'начало': <String>{'на'},
    'середине': <String>{'в', 'во', 'к', 'ко'},
    'середины': <String>{'до'},
    'середину': <String>{'на'},
    'конце': <String>{'в', 'во'},
    'концу': <String>{'к', 'ко'},
    'конца': <String>{'до'},
    'конец': <String>{'на'},
  };

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
      // «перенеси на через 2 дня»: лишнее «на» перед «через».
      final extra = before(from);
      if (previous.group(0) == 'через' &&
          extra != null &&
          extra.group(0) == 'на' &&
          _onlySpaces(text, extra.end, from)) {
        from = extra.start;
      }
    }
    return CharSpan(from, end);
  }

  /// Уточнения сразу после часа: «утра», «часов», «часа дня». Пустой
  /// список — уточнения нет. Если их два, второе — часть суток.
  /// «В 48 часов», «уложиться в 24 часа», «к 25 часов эфира» — срок
  /// работы или количество часов, а не время на часах: фраза остаётся
  /// в названии и не даёт `invalidTime`. Так читается число больше 23
  /// со словом «час(а/ов)», если после него идёт обычное слово («часов
  /// эфира») или число кратно суткам (24, 48, 72…). «В 25 часов», «в 30
  /// вечера» — по-прежнему неверное время.
  bool _hoursAsDuration(
    String text,
    List<RegExpMatch> words,
    List<RegExpMatch> suffix,
    int hour,
  ) {
    if (!_hourWords.contains(suffix.first.group(0)) || suffix.length > 1) {
      return false;
    }
    if (hour % 24 == 0) return true;
    final index = words.indexOf(suffix.last);
    if (index < 0 || index + 1 >= words.length) return false;
    final next = words[index + 1];
    final value = next.group(0)!;
    return _onlySpaces(text, suffix.last.end, next.start) &&
        !_dayWords.containsKey(value) &&
        !_politeWords.contains(value) &&
        !_startsDayPhrase(words, index + 1) &&
        !isInfinitive(value) &&
        value != 'или' &&
        value != 'и';
  }

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

/// Часть суток, найденная в тексте, с фрагментом.
final class _PartFound {
  const _PartFound(
    this.start,
    this.end,
    this.part, {
    this.lunch = false,
    this.dayOffset,
  });

  final int start;
  final int end;
  final PartOfDay part;

  /// «В обед»: условное время дня (13:00), но кончается раньше — в 15:00.
  final bool lunch;

  /// День из прилагательного перед частью суток: «на завтрашнее утро» — 1.
  final int? dayOffset;
}

/// Уточнение часа частью суток: «вечером в 8» — как «в 8 вечера».
extension on PartOfDay {
  String get hourSuffix => switch (this) {
        PartOfDay.morning => 'утра',
        PartOfDay.day || PartOfDay.afternoon => 'дня',
        PartOfDay.evening => 'вечера',
      };

  /// Час, уточнённый частью суток, в неё попадает: «вечером в 8» — 20:00
  /// подходит, «вечером в 1» — 13:00 нет.
  bool admitsHour(int hour) => switch (this) {
        PartOfDay.morning => hour >= 4 && hour <= 12,
        PartOfDay.day => hour >= 12 && hour <= 17,
        PartOfDay.afternoon => hour >= 12 && hour <= 18,
        PartOfDay.evening => hour >= 17 && hour <= 23,
      };
}

/// Какая неделя имеется в виду: «эту», «следующую» или ближайший день.
enum _WeekScope { current, next, nearest }

enum _Unit { minute, hour, day, week, month }

/// Часть месяца: «в начале», «в середине», «в конце».
enum _MonthPart { start, middle, end }

/// Срок, найденный разбором дней недели или «через N …».
final class _Found {
  const _Found(
    this.start,
    this.end, {
    this.date,
    this.time,
    this.moment,
    this.isSource = false,
    this.invalid = false,
    this.recurring = false,
  });

  final int start;
  final int end;
  final DateTime? date;

  /// Повторение: «по пятницам», «каждую пятницу».
  final bool recurring;
  final (int, int)? time;

  /// Точный момент для «через N минут/часов»: с ним итоговый срок не
  /// зависит от перевода часов.
  final DateTime? moment;
  final bool isSource;

  /// Несуществующая дата: «31 февраля».
  final bool invalid;
}

final class _Mention<T> {
  const _Mention(this.value, this.isSource);

  final T value;
  final bool isSource;
}
