import '../../connectors/number_words.dart';
import '../../connectors/social_prefix.dart';
import '../../connectors/utterance.dart';
import '../../connectors/verb_forms.dart';

/// Будильник или таймер.
enum AlarmKind { alarm, timer }

/// Чем кончился разбор фразы о будильнике или таймере.
enum AlarmIssue {
  /// Всё ясно: можно ставить.
  none,

  /// Время не названо или названо непонятно: «поставь будильник».
  noTime,

  /// Длительность таймера не названа или больше суток.
  noDuration,

  /// Будильник дальше чем через сутки («в пятницу в 7»): в «Часах» нельзя
  /// выбрать день — предлагается напоминание.
  date,

  /// «Сегодня в 7», а 7:00 уже прошло.
  past,
}

/// Разобранная просьба: будильник в «Часах» или таймер (ADR-029).
///
/// Только числа и подпись из кавычек: [AlarmPhrases.parse] не делает
/// ввода-вывода.
final class AlarmRequest {
  const AlarmRequest({
    required this.kind,
    this.hour,
    this.minute,
    this.days = const <int>[],
    this.seconds,
    this.label,
    this.at,
    this.issue = AlarmIssue.none,
  });

  final AlarmKind kind;

  /// Час и минута будильника (0–23, 0–59).
  final int? hour;
  final int? minute;

  /// Повтор по дням недели: 1 — понедельник … 7 — воскресенье, по порядку.
  /// Пусто — один раз.
  final List<int> days;

  /// Длительность таймера в секундах (1…86 400).
  final int? seconds;

  /// Подпись будильника или таймера из кавычек: «спортзал».
  final String? label;

  /// Ближайший момент звонка будильника (для [AlarmIssue.date] — день,
  /// на который его просили).
  final DateTime? at;

  final AlarmIssue issue;

  bool get isTimer => kind == AlarmKind.timer;

  /// Id команды для корпуса и ответа.
  String get commandId => switch (issue) {
        AlarmIssue.none =>
          isTimer ? AlarmPhrases.timerCommand : AlarmPhrases.setCommand,
        AlarmIssue.date => AlarmPhrases.dateCommand,
        AlarmIssue.noTime ||
        AlarmIssue.noDuration ||
        AlarmIssue.past =>
          AlarmPhrases.clarifyCommand,
      };

  /// Время будильника «7:00», «19:30».
  String get timeText =>
      hour == null ? '' : '$hour:${(minute ?? 0).toString().padLeft(2, '0')}';

  /// Длительность таймера словами: «5 минут», «1 час 30 минут».
  String get durationText => AlarmPhrases.durationText(seconds ?? 0);

  /// Дни повтора словами: «по будням», «по выходным», «каждый день»,
  /// «по понедельникам и средам». Пусто — без повтора.
  String get daysText => AlarmPhrases.daysText(days);

  AlarmRequest copyWith({
    int? hour,
    int? minute,
    int? seconds,
    DateTime? at,
    AlarmIssue? issue,
  }) =>
      AlarmRequest(
        kind: kind,
        hour: hour ?? this.hour,
        minute: minute ?? this.minute,
        days: days,
        seconds: seconds ?? this.seconds,
        label: label,
        at: at ?? this.at,
        issue: issue ?? this.issue,
      );

  @override
  String toString() => 'AlarmRequest($kind, $timeText, days=$days, '
      'seconds=$seconds, label=$label, issue=$issue)';
}

/// Фразы навыка «Будильник» (ADR-029): «поставь будильник на 7», «разбуди
/// меня в 6:30», «будильник по будням на 7», «таймер на 5 минут»,
/// «засеки 10 минут».
///
/// Не его: «купить будильник», «починить будильник», «напомни поставить
/// будильник», «надо завести будильник» (задачи), «будильник не
/// прозвенел» (беседа). Перед словом «будильник» допускаются только
/// глагол «поставить» и вежливые слова, после — только время, дни и
/// подпись; со словом «не» фраза не его.
abstract final class AlarmPhrases {
  static const String setCommand = 'alarm.set';
  static const String timerCommand = 'alarm.timer';
  static const String dateCommand = 'alarm.date';
  static const String clarifyCommand = 'alarm.clarify';

  /// Самый длинный таймер «Часов» — сутки.
  static const int maxTimerSeconds = 86400;

  /// Время «7:30», дробь «1,5» (длительность таймера), слова и числа.
  static final RegExp _token =
      RegExp(r'\d{1,2}[:.]\d{2}|\d+[,.]\d(?!\d)|[a-zа-я0-9]+');

  static const Set<String> _alarmNouns = <String>{
    'будильник',
    'будильника',
    'будильнику',
    'будильником',
  };

  static const Set<String> _timerNouns = <String>{
    'таймер',
    'таймерок',
    'таймерочек',
    'таймера',
    'таймеру',
    'таймером',
    // «Запусти отсчёт на четверть часа».
    'отсчет',
  };

  static const Set<String> _wakeVerbs = <String>{
    'разбуди',
    'разбудите',
    'разбудишь',
  };

  /// «Подними меня в 6:15», «буди меня по субботам в 9»: «разбуди» — только
  /// рядом с «меня/нас» («подними цену», «буди детей» — не будильник).
  static const Set<String> _objectWakeVerbs = <String>{
    'подними',
    'поднимите',
    'буди',
    'будите',
  };

  static const Set<String> _wakeObjects = <String>{'меня', 'нас'};

  static const Set<String> _stopwatchVerbs = <String>{
    'засеки',
    'засекай',
    'засеките',
    // «Отсчитай мне сорок пять секунд».
    'отсчитай',
    'отсчитайте',
  };

  /// «Поставь», «заведи», «установи», «сделай», «включи», «запусти».
  static const Set<String> _setVerbs = <String>{
    'поставь',
    'поставьте',
    'поставить',
    'поставишь',
    'поставите',
    'заведи',
    'заведите',
    'завести',
    'установи',
    'установите',
    'установить',
    'сделай',
    'сделайте',
    'включи',
    'включите',
    'запусти',
    'запустите',
    'запустить',
    // Разговорное: «врубай будильник», «замути таймерок», «ставь на 7».
    'вруби',
    'врубай',
    'включай',
    'замути',
    'заводи',
    'ставь',
  };

  /// Слова перед будильником, которые не меняют смысла.
  static const Set<String> _leadFillers = <String>{
    'пожалуйста',
    'плиз',
    'пж',
    'плз',
    // «И ещё таймер на 10 минут».
    'и',
    'мне',
    'нам',
    'ну',
    'а',
    'ка',
    'давай',
    'давайте',
    'можешь',
    'можете',
    'ли',
    'хочу',
    'еще',
    'новый',
    'один',
    'слушай',
    // «Нужен будильник на семь», «мне нужен таймер на пять минут».
    'нужен',
    'нужна',
    'нужно',
  };

  static const Set<String> _tailFillers = <String>{
    'пожалуйста',
    'плиз',
    'пж',
    'плз',
    'мне',
    'меня',
    'нас',
    'будильник',
    'таймер',
    'часов',
    'часа',
    'час',
    'ровно',
    'с',
    'подписью',
    'надписью',
    'названием',
    'текстом',
    'меткой',
  };

  static const Map<String, int> _numberWords = <String, int>{
    'ноль': 0,
    'один': 1,
    'одну': 1,
    'одна': 1,
    'два': 2,
    'две': 2,
    'три': 3,
    'четыре': 4,
    'пять': 5,
    'шесть': 6,
    'семь': 7,
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
    'сорока': 40,
    'пятьдесят': 50,
    // «К девяти вечера», «к семи»: час после «к».
    'двух': 2,
    'трех': 3,
    'четырех': 4,
    'пяти': 5,
    'шести': 6,
    'семи': 7,
    'восьми': 8,
    'девяти': 9,
    'десяти': 10,
    'одиннадцати': 11,
    'двенадцати': 12,
  };

  /// «Полседьмого»: час, к которому идёт половина.
  static const Map<String, int> _ordinalHours = <String, int>{
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

  static const Map<String, int> _weekdayAccusative = <String, int>{
    'понедельник': 1,
    'вторник': 2,
    'среду': 3,
    'четверг': 4,
    'пятницу': 5,
    'субботу': 6,
    'воскресенье': 7,
  };

  static const Map<String, int> _weekdayPlural = <String, int>{
    'понедельникам': 1,
    'вторникам': 2,
    'средам': 3,
    'четвергам': 4,
    'пятницам': 5,
    'субботам': 6,
    'воскресеньям': 7,
  };

  /// Разбор [utterance] на момент [now]; `null` — фраза не о будильнике
  /// и не о таймере.
  static AlarmRequest? parse(Utterance utterance, DateTime now) {
    final text = utterance.analysisText;
    // Вступление «привет, …» снимается так же, как у других навыков.
    final prefix = SocialPrefix.length(utterance);
    final from = prefix == 0 || prefix >= utterance.tokens.length
        ? 0
        : utterance.tokens[prefix - 1].span.end;
    var tokens = <String>[
      for (final match in _token.allMatches(text))
        if (match.start >= from) match.group(0)!,
    ];
    if (tokens.isEmpty) return null;
    tokens = _compactNumbers(tokens);
    // «Таймер на 4 минуты, яйца варю»: пояснение после запятой без чисел
    // и слов срока — не часть просьбы.
    tokens = _withoutRemark(text, from, tokens);
    // «…в шесть утра чтоб звенело» — то же, что «разбуди».
    final ring = _ringClause(tokens);
    if (ring != null) tokens = ring;
    // «У меня рейс ранний, в шесть утра …»: причина впереди.
    tokens = _withoutLeadRemark(text, from, tokens);
    // «Мне бы не проспать завтра в 6:15» — просьба разбудить.
    final oversleep = _oversleep(tokens);
    if (oversleep != null) tokens = oversleep;
    if (tokens.contains('не')) return null;
    // «Поставь будильник на 7, хотя нет, на 7:30» — время — последнее.
    final corrected = _corrected(tokens);
    if (corrected != null) tokens = corrected;
    if (tokens.contains('нет')) {
      // «Нет, на 6:45» сразу после ответа о будильнике — новое время.
      return utterance.recentConnectorId == recentId
          ? _continuation(tokens, utterance, now)
          : null;
    }
    // Где слово-якорь: «будильник», «таймер», «разбуди», «засеки».
    var anchor = -1;
    AlarmKind? kind;
    var wake = false;
    for (var i = 0; i < tokens.length; i++) {
      final word = tokens[i];
      if (_alarmNouns.contains(word)) {
        kind = AlarmKind.alarm;
      } else if (_timerNouns.contains(word)) {
        kind = AlarmKind.timer;
      } else if (_wakeVerbs.contains(word) ||
          (_objectWakeVerbs.contains(word) &&
              ((i + 1 < tokens.length &&
                      _wakeObjects.contains(tokens[i + 1])) ||
                  (i > 0 && _wakeObjects.contains(tokens[i - 1]))))) {
        kind = AlarmKind.alarm;
        wake = true;
      } else if (_stopwatchVerbs.contains(word)) {
        kind = AlarmKind.timer;
        wake = true;
      } else {
        continue;
      }
      anchor = i;
      break;
    }
    if (kind == null) {
      return utterance.recentConnectorId == recentId
          ? _continuation(tokens, utterance, now)
          : null;
    }
    if (kind == AlarmKind.alarm) {
      final first = _wakeFirst(tokens, anchor, utterance, now);
      if (first != null) return first;
    }
    // «По субботам буди меня в 9», «мне завтра рано вставать, разбуди в
    // 5:20»: день или повтор до якоря — туда же, что и после него.
    final moved = _leadDays(tokens, anchor, kind);
    if (moved != null) {
      tokens = moved.$1;
      anchor = moved.$2;
    }
    if (anchor > 5) return null;
    var setVerb = wake;
    for (final word in tokens.take(anchor)) {
      if (_setVerbs.contains(word)) {
        setVerb = true;
      } else if (!_leadFillers.contains(word)) {
        // «Купить будильник», «напомни поставить будильник»: не просьба
        // поставить.
        return null;
      }
    }
    // «Таймерок секунд на тридцать замути», «будильник на 7 поставь» —
    // глагол в конце.
    var after = tokens.sublist(anchor + 1);
    if (after.length > 1 && _setVerbs.contains(after.last)) {
      after = after.sublist(0, after.length - 1);
      setVerb = true;
    }
    if (utterance.isQuestion && !setVerb) return null;
    var reader = _Reader(after, timer: kind == AlarmKind.timer);
    reader.read();
    // «Таймер на 7 минут чай заварить»: зачем таймер — в конце, без
    // запятой.
    if (kind == AlarmKind.timer && reader.leftover) {
      final purpose = _withoutPurpose(after);
      if (purpose != null) reader = purpose;
    }
    // Число, которое не вошло ни во время, ни в длительность («на 5 и 6»,
    // «в 7 через 2 дня»): лучше спросить, чем молча поставить не то.
    if (reader.strayNumber && setVerb) {
      return AlarmRequest(
        kind: kind,
        issue:
            kind == AlarmKind.timer ? AlarmIssue.noDuration : AlarmIssue.noTime,
      );
    }
    // Время после будильника не названо, а вместо него — посторонние слова
    // («будильник не прозвенел», «поставь будильник на полку»): не его.
    if (reader.leftover && !reader.hasTime && !reader.hasDuration) {
      return null;
    }
    if (reader.leftover && !setVerb) return null;
    if (!setVerb && !reader.hasTime && !reader.hasDuration) return null;
    final label = utterance.quotedTitles.isEmpty
        ? null
        : _label(utterance.quotedTitles.first.text);
    if (kind == AlarmKind.timer) {
      final seconds = reader.duration?.inSeconds;
      if (seconds == null || seconds <= 0 || seconds > maxTimerSeconds) {
        return AlarmRequest(
          kind: kind,
          label: label,
          issue: AlarmIssue.noDuration,
        );
      }
      return AlarmRequest(kind: kind, seconds: seconds, label: label);
    }
    return _alarm(reader, now, label);
  }

  /// Длительность таймера без хвоста-цели: в хвосте не меньше двух слов и
  /// есть инфинитив («чай заварить», «чтобы яйца сварить»), нет чисел и
  /// слов отмены. `null` — хвоста нет или без него длительность не
  /// читается.
  static _Reader? _withoutPurpose(List<String> words) {
    for (var cut = 1; cut < words.length; cut++) {
      final tail = words.sublist(cut);
      // Одно слово хвоста («…, отменить») — скорее другая просьба: цель —
      // дело с предметом («чай заварить») или «чтобы …».
      if (tail.length < 2 ||
          !tail.any(VerbForms.isInfinitive) ||
          tail.any(
            (String w) =>
                number(w) != null ||
                RegExp(r'\d').hasMatch(w) ||
                _remarkStops.contains(w) ||
                _cancelInfinitives.contains(w),
          )) {
        continue;
      }
      final reader = _Reader(words.sublist(0, cut), timer: true)..read();
      if (reader.hasDuration && !reader.leftover && !reader.strayNumber) {
        return reader;
      }
    }
    return null;
  }

  /// Хвост «отменить», «выключить» — не цель таймера, а другая просьба.
  static const Set<String> _cancelInfinitives = <String>{
    'отменить',
    'выключить',
    'удалить',
    'убрать',
    'остановить',
    'сбросить',
    'поменять',
    'изменить',
  };

  /// Слова, с которыми пояснение после запятой — часть просьбы: отказ,
  /// поправка («…, не надо», «…, хотя нет, на 8»).
  static const Set<String> _remarkStops = <String>{
    'не',
    'нет',
    'неа',
    'хотя',
    'точнее',
    'вернее',
    'ой',
    'или',
    'отмени',
    'отмена',
    'стоп',
  };

  /// [tokens] без пояснения после последней запятой: в нём нет ни числа,
  /// ни слова, которое понимает разбор времени, ни отказа и поправки
  /// ([_remarkStops]). До запятой должно что-то остаться.
  static List<String> _withoutRemark(
    String text,
    int from,
    List<String> tokens,
  ) {
    final comma = text.lastIndexOf(',');
    if (comma <= from) return tokens;
    final tail = <String>[
      for (final match in _token.allMatches(text.substring(comma)))
        match.group(0)!,
    ];
    if (tail.isEmpty || tail.length > 4 || tail.length >= tokens.length) {
      return tokens;
    }
    // До запятой — время или длительность числом: «засеки, как я опять
    // опоздаю» — не просьба с пояснением.
    final head = tokens.sublist(0, tokens.length - tail.length);
    if (!head.any(
      (String w) => number(w) != null || RegExp(r'\d').hasMatch(w),
    )) {
      return tokens;
    }
    if (tail.any(
      (String w) =>
          _remarkStops.contains(w) ||
          _alarmNouns.contains(w) ||
          _timerNouns.contains(w) ||
          _wakeVerbs.contains(w) ||
          _setVerbs.contains(w) ||
          number(w) != null ||
          RegExp(r'\d').hasMatch(w),
    )) {
      return tokens;
    }
    final reader = _Reader(tail, timer: false)..read();
    if (reader.hasTime ||
        reader.days.isNotEmpty ||
        reader.dayOffset != null ||
        reader.weekday != null ||
        reader.daypart != null) {
      return tokens;
    }
    return head;
  }

  /// «…, чтоб звенело», «чтобы будильник прозвенел» в конце — просьба
  /// разбудить: заменяется на «разбуди». `null` — такого нет.
  static List<String>? _ringClause(List<String> tokens) {
    for (var i = tokens.length - 1; i >= 1; i--) {
      if (tokens[i] != 'чтоб' && tokens[i] != 'чтобы') continue;
      final rest = tokens.sublist(i + 1);
      if (rest.isEmpty || rest.length > 3) return null;
      if (!rest.any(_ringVerbs.contains)) return null;
      if (!rest.every(
        (String w) =>
            _ringVerbs.contains(w) ||
            _alarmNouns.contains(w) ||
            w == 'он' ||
            w == 'меня' ||
            w == 'мне',
      )) {
        return null;
      }
      return <String>[...tokens.take(i), 'разбуди'];
    }
    return null;
  }

  static const Set<String> _ringVerbs = <String>{
    'звенел',
    'звенело',
    'зазвенел',
    'зазвенело',
    'прозвенел',
    'прозвенело',
    'звонил',
    'звонило',
    'зазвонил',
    'зазвонило',
    'разбудил',
    'разбудило',
  };

  /// Причина до первой запятой — «у меня рейс ранний, в шесть утра …» —
  /// снимается, если в ней нет ни числа, ни дня, ни слов будильника и
  /// подъёма, ни отказа, а после неё есть якорь будильника.
  static List<String> _withoutLeadRemark(
    String text,
    int from,
    List<String> tokens,
  ) {
    final comma = text.indexOf(',', from);
    if (comma < 0) return tokens;
    final lead = <String>[
      for (final match in _token.allMatches(text.substring(from, comma)))
        match.group(0)!,
    ];
    if (lead.isEmpty || lead.length > 6 || lead.length >= tokens.length) {
      return tokens;
    }
    if (lead.any(
      (String w) =>
          number(w) != null ||
          RegExp(r'\d').hasMatch(w) ||
          _remarkStops.contains(w) ||
          w == 'не' ||
          _alarmNouns.contains(w) ||
          _timerNouns.contains(w) ||
          _wakeVerbs.contains(w) ||
          _objectWakeVerbs.contains(w) ||
          _stopwatchVerbs.contains(w) ||
          _setVerbs.contains(w) ||
          _wakeClause.contains(w) ||
          const <String>{'сегодня', 'завтра', 'послезавтра', 'по'}
              .contains(w) ||
          _weekdayAccusative.containsKey(w),
    )) {
      return tokens;
    }
    final rest = tokens.sublist(lead.length);
    if (!rest.any(
      (String w) =>
          _alarmNouns.contains(w) ||
          _timerNouns.contains(w) ||
          _wakeVerbs.contains(w),
    )) {
      return tokens;
    }
    return rest;
  }

  /// День или повтор до якоря будильника — «по субботам буди меня в 9»,
  /// «мне завтра рано вставать, разбуди в 5:20» — переносится сразу за
  /// якорь. До якоря, кроме дня, — только глагол «поставь», вежливые слова
  /// и слова о подъёме ([_wakeClause]); времени до якоря нет. `null` —
  /// переносить нечего.
  static (List<String>, int)? _leadDays(
    List<String> tokens,
    int anchor,
    AlarmKind kind,
  ) {
    if (anchor < 1) return null;
    final keep = <String>[];
    final days = <String>[];
    for (final word in tokens.take(anchor)) {
      if (_setVerbs.contains(word) || _leadFillers.contains(word)) {
        keep.add(word);
      } else if (!_wakeClause.contains(word)) {
        days.add(word);
      }
    }
    if (days.isEmpty) return null;
    // «На девяносто секунд засекай»: длительность до якоря таймера.
    if (kind == AlarmKind.timer) {
      final duration = _Reader(days, timer: true)..read();
      if (duration.leftover || duration.strayNumber || !duration.hasDuration) {
        return null;
      }
      return (
        <String>[...keep, tokens[anchor], ...days, ...tokens.skip(anchor + 1)],
        keep.length,
      );
    }
    final reader = _Reader(days, timer: false)..read();
    if (reader.leftover ||
        reader.strayNumber ||
        reader.hasTime ||
        reader.hasDuration) {
      return null;
    }
    if (reader.days.isEmpty &&
        reader.dayOffset == null &&
        reader.weekday == null) {
      return null;
    }
    return (
      <String>[...keep, tokens[anchor], ...days, ...tokens.skip(anchor + 1)],
      keep.length,
    );
  }

  /// Id навыка «Часы» в контексте сессии ([Utterance.recentConnectorId]).
  static const String recentId = 'alarm';

  /// Обрывок сразу после ответа о будильнике или таймере: «7:30», «а на 9
  /// можно?», «нет, на 6:45» — будильник на новое время; «ещё на 5
  /// минут», «а ещё таймер на 15 минут» — таймер. Кроме времени или
  /// длительности — только слова из [_continuationWords]; «не» — никогда
  /// («не на 7» — не просьба). Ставится, как всегда, только после
  /// «Поставить».
  static AlarmRequest? _continuation(
    List<String> tokens,
    Utterance utterance,
    DateTime now,
  ) {
    final rest = <String>[
      for (final word in tokens)
        if (!_continuationWords.contains(word)) word,
    ];
    if (rest.isEmpty || rest.length > 4) return null;
    // Голое число («15») — не время: только «7:30», «на 9», «в 7 утра».
    // «Полвосьмого», «без четверти семь» — время и без предлога.
    final marked = rest.any(
      (String w) =>
          _Reader._clock.hasMatch(w) ||
          _Reader._timePrepositions.contains(w) ||
          _Reader._dayparts.contains(w) ||
          w == 'без' ||
          (w.startsWith('пол') && _ordinalHours.containsKey(w.substring(3))),
    );
    final clock = _Reader(rest, timer: false)..read();
    // «И на выходные тоже на девять» — день с временем вместе.
    if (marked && clock.hasTime && !clock.leftover && !clock.strayNumber) {
      return _alarm(clock, now, null);
    }
    final timer = _Reader(rest, timer: true)..read();
    final seconds = timer.duration?.inSeconds;
    if (timer.hasDuration &&
        !timer.leftover &&
        !timer.strayNumber &&
        seconds != null &&
        seconds > 0 &&
        seconds <= maxTimerSeconds &&
        rest.any(_Reader._unitSeconds.containsKey)) {
      return AlarmRequest(kind: AlarmKind.timer, seconds: seconds);
    }
    return null;
  }

  /// Слова продолжения вокруг времени: «а», «нет», «можно», «лучше».
  static const Set<String> _continuationWords = <String>{
    'а',
    'слушай',
    'сделай',
    'поставь',
    'тоже',
    'также',
    'и',
    'нет',
    'неа',
    'ой',
    'ну',
    'давай',
    'лучше',
    'тогда',
    'хотя',
    'еще',
    'можно',
    'пожалуйста',
    'плиз',
  };

  /// «Мне бы не проспать завтра в 6:15», «чтобы не проспать в 7»: «не
  /// проспать» — якорь «разбуди». `null` — такого нет.
  static List<String>? _oversleep(List<String> tokens) {
    final at = tokens.indexOf('проспать');
    if (at < 1 || tokens[at - 1] != 'не') return null;
    final head = tokens.take(at - 1);
    if (!head.every(_oversleepLead.contains)) return null;
    return <String>['разбуди', ...tokens.skip(at + 1)];
  }

  static const Set<String> _oversleepLead = <String>{
    'мне',
    'нам',
    'бы',
    'чтобы',
    'чтоб',
    'главное',
    'помоги',
    'хочу',
    'как',
    'только',
  };

  /// «Поставь будильник на 7, хотя нет, на 7:30», «на 7, нет, на 8»:
  /// слова до поправки ([_correctionMarks]) после якоря отбрасываются, если
  /// после неё — одно время. `null` — поправки нет.
  static List<String>? _corrected(List<String> tokens) {
    final at = tokens.indexWhere(_correctionMarks.contains);
    if (at < 2) return null;
    var tail = at + 1;
    while (tail < tokens.length && _correctionMarks.contains(tokens[tail])) {
      tail++;
    }
    final after = tokens.sublist(tail);
    if (after.isEmpty) return null;
    final reader = _Reader(after, timer: false)..read();
    if (!reader.hasTime || reader.leftover || reader.strayNumber) return null;
    // Якорь — до поправки: «будильник», «разбуди».
    var anchor = -1;
    for (var i = 0; i < at; i++) {
      final word = tokens[i];
      if (_alarmNouns.contains(word) || _wakeVerbs.contains(word)) {
        anchor = i;
        break;
      }
    }
    if (anchor < 0) return null;
    return <String>[...tokens.take(anchor + 1), ...after];
  }

  static const Set<String> _correctionMarks = <String>{
    'хотя',
    'нет',
    'точнее',
    'вернее',
    'ой',
  };

  /// «Мне вставать в 5:40, поставь будильник», «завтра подъём в 6,
  /// заведи будильник»: время — в начале, о подъёме, а просьба —
  /// в конце. Кроме времени, в начале — только слова о подъёме
  /// ([_wakeClause]).
  static AlarmRequest? _wakeFirst(
    List<String> tokens,
    int anchor,
    Utterance utterance,
    DateTime now,
  ) {
    // «…, разбуди» в конце — просьба сама по себе; «…, поставь будильник»
    // — только после слов о подъёме.
    final wakeAnchor = _wakeVerbs.contains(tokens[anchor]);
    final setAnchor = anchor >= 2 && _setVerbs.contains(tokens[anchor - 1]);
    if (anchor < 1 || (!wakeAnchor && !setAnchor)) return null;
    if (!tokens.skip(anchor + 1).every(_tailFillers.contains)) return null;
    final head = tokens
        .take(wakeAnchor || !setAnchor ? anchor : anchor - 1)
        .toList(growable: false);
    final wakeWords = head.any(_wakeClause.contains);
    if (!wakeAnchor && !wakeWords) return null;
    final reader = _Reader(
      <String>[
        for (final word in head)
          if (!_wakeClause.contains(word) && !_leadFillers.contains(word)) word,
      ],
      timer: false,
    );
    reader.read();
    if (reader.strayNumber || !reader.hasTime) return null;
    // «Завтра к поезду встать в 4:20, поставь будильник»: лишние слова о
    // подъёме не мешают явной просьбе с будильником.
    if (reader.leftover && !(setAnchor && wakeWords)) return null;
    final label = utterance.quotedTitles.isEmpty
        ? null
        : _label(utterance.quotedTitles.first.text);
    return _alarm(reader, now, label);
  }

  static const Set<String> _wakeClause = <String>{
    'вставать',
    'встать',
    'встаю',
    'проснуться',
    'просыпаться',
    'просыпаюсь',
    'подъем',
    'подниматься',
    'рано',
    'надо',
    'нужно',
    'мне',
    'нам',
  };

  static AlarmRequest _alarm(_Reader reader, DateTime now, String? label) {
    final days = reader.days.toList()..sort();
    final relative = reader.relative;
    if (relative != null) {
      final at = now.add(relative);
      final atMinute = DateTime(at.year, at.month, at.day, at.hour, at.minute);
      return AlarmRequest(
        kind: AlarmKind.alarm,
        hour: at.hour,
        minute: at.minute,
        days: days,
        label: label,
        at: atMinute,
        issue: relative > const Duration(hours: 24)
            ? AlarmIssue.date
            : AlarmIssue.none,
      );
    }
    final hour = reader.hour24;
    final minute = reader.minute ?? 0;
    if (hour == null || hour > 23 || minute > 59) {
      return AlarmRequest(
        kind: AlarmKind.alarm,
        days: days,
        label: label,
        issue: AlarmIssue.noTime,
      );
    }
    final today = DateTime(now.year, now.month, now.day, hour, minute);
    DateTime at;
    var issue = AlarmIssue.none;
    final weekday = reader.weekday;
    final offset = reader.dayOffset;
    final monthDay = reader.monthDay;
    if (monthDay != null && days.isEmpty && weekday == null && offset == null) {
      // Ближайшее такое число: в этом месяце или в следующем.
      at = DateTime(now.year, now.month, monthDay, hour, minute);
      for (var ahead = 1;
          ahead <= 2 && (!at.isAfter(now) || at.day != monthDay);
          ahead++) {
        at = DateTime(now.year, now.month + ahead, monthDay, hour, minute);
      }
    } else if (days.isNotEmpty) {
      at = today.isAfter(now) ? today : _addDays(today, 1);
    } else if (weekday != null) {
      var ahead = (weekday - now.weekday) % 7;
      if (ahead == 0 && !today.isAfter(now)) ahead = 7;
      at = _addDays(today, ahead);
    } else if (offset != null) {
      at = _addDays(today, offset);
      if (!at.isAfter(now)) issue = AlarmIssue.past;
    } else {
      // «На 7» без дня — ближайшие 7:00 в пределах суток.
      at = today.isAfter(now) ? today : _addDays(today, 1);
    }
    if (issue == AlarmIssue.none &&
        days.isEmpty &&
        at.difference(now) > const Duration(hours: 24)) {
      issue = AlarmIssue.date;
    }
    return AlarmRequest(
      kind: AlarmKind.alarm,
      hour: hour,
      minute: minute,
      days: days,
      label: label,
      at: at,
      issue: issue,
    );
  }

  static DateTime _addDays(DateTime day, int days) => DateTime(
        day.year,
        day.month,
        day.day + days,
        day.hour,
        day.minute,
      );

  /// Подпись в одну строку, не длиннее 40 знаков.
  static String? _label(String text) {
    final clean = text
        .replaceAll(RegExp(r'[\u0000-\u001f\u007f-\u009f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (clean.isEmpty) return null;
    if (clean.runes.length <= 40) return clean;
    return String.fromCharCodes(clean.runes.take(40));
  }

  /// «5 минут», «1 час», «1 час 30 минут», «45 секунд», «2 минуты 30
  /// секунд».
  static String durationText(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final rest = seconds % 60;
    final parts = <String>[
      if (hours > 0) '$hours ${_plural(hours, 'час', 'часа', 'часов')}',
      if (minutes > 0)
        '$minutes ${_plural(minutes, 'минуту', 'минуты', 'минут')}',
      if (rest > 0) '$rest ${_plural(rest, 'секунду', 'секунды', 'секунд')}',
    ];
    return parts.isEmpty ? '0 секунд' : parts.join(' ');
  }

  static String _plural(int n, String one, String few, String many) {
    final mod10 = n % 10;
    final mod100 = n % 100;
    if (mod10 == 1 && mod100 != 11) return one;
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return few;
    return many;
  }

  static const List<String> _pluralDays = <String>[
    'понедельникам',
    'вторникам',
    'средам',
    'четвергам',
    'пятницам',
    'субботам',
    'воскресеньям',
  ];

  /// Дни повтора словами.
  static String daysText(List<int> days) {
    if (days.isEmpty) return '';
    final set = days.toSet();
    if (set.length == 7) return 'каждый день';
    if (set.length == 5 && set.containsAll(<int>[1, 2, 3, 4, 5])) {
      return 'по будням';
    }
    if (set.length == 2 && set.containsAll(<int>[6, 7])) return 'по выходным';
    final names = <String>[for (final day in days) _pluralDays[day - 1]];
    if (names.length == 1) return 'по ${names.single}';
    return 'по ${names.sublist(0, names.length - 1).join(', ')} '
        'и ${names.last}';
  }

  /// Числа «7», «семь», «девяносто» ([NumberWords]).
  static int? number(String word) =>
      int.tryParse(word) ?? _numberWords[word] ?? NumberWords.value(word);

  /// Составные числа словами — одним числом: «сто двадцать секунд» →
  /// «120 секунд», «сорок пять» → «45». Одиночные слова остаются: их
  /// читает [_Reader] («семь тридцать» — час и минуты). «Секунд на
  /// тридцать» — единица впереди, как «на тридцать секунд».
  static List<String> _compactNumbers(List<String> tokens) {
    final joined = tokens.join(' ');
    final found = NumberWords.find(joined);
    final result = <String>[];
    if (found.isEmpty) {
      result.addAll(tokens);
    } else {
      var position = 0;
      var index = 0;
      for (final token in tokens) {
        final start = position;
        position += token.length + 1;
        while (index < found.length && found[index].end <= start) {
          index++;
        }
        final match = index < found.length ? found[index] : null;
        if (match == null || start < match.start || start >= match.end) {
          result.add(token);
          continue;
        }
        final words = joined.substring(match.start, match.end).split(' ');
        if (words.length < 2) {
          result.add(token);
        } else if (start == match.start) {
          result.add('${match.value}');
        }
      }
    }
    // «Секунд на тридцать», «минут на пять»: единица перед «на N».
    for (var i = 0; i + 2 < result.length; i++) {
      if (_Reader._unitSeconds.containsKey(result[i]) &&
          result[i + 1] == 'на' &&
          number(result[i + 2]) != null) {
        final unit = result[i];
        result
          ..[i] = 'на'
          ..[i + 1] = result[i + 2]
          ..[i + 2] = unit;
      }
    }
    return result;
  }
}

/// Читает слова после якоря: время, день, повтор, длительность.
final class _Reader {
  _Reader(this.words, {required this.timer});

  final List<String> words;

  /// Читается таймер: числа — длительность («1:30» — час тридцать), а не
  /// время.
  final bool timer;
  int _i = 0;

  int? hour;
  int? minute;

  /// «утра», «вечера», «дня», «ночи».
  String? daypart;

  int? dayOffset;
  int? weekday;

  /// Число месяца словом: «двадцать пятого» — 25.
  int? monthDay;
  final Set<int> days = <int>{};
  Duration? relative;
  Duration? duration;

  /// Остались непонятные слова.
  bool leftover = false;

  /// Среди непонятых слов есть число: время или длительность прочитаны не
  /// целиком.
  bool strayNumber = false;

  bool get hasTime => hour != null || relative != null;
  bool get hasDuration => duration != null;

  /// Час по 24-часовой шкале с учётом части суток.
  int? get hour24 {
    final h = hour;
    if (h == null) return null;
    switch (daypart) {
      case 'утра':
      case 'утром':
        return h == 12 ? 0 : h;
      case 'вечера':
      case 'вечером':
        return h < 12 ? h + 12 : h;
      case 'дня':
      case 'днем':
        return h <= 5 ? h + 12 : h;
      case 'ночи':
      case 'ночью':
        if (h == 12) return 0;
        return h >= 6 && h < 12 ? h + 12 : h;
    }
    return h;
  }

  String? get _word => _i < words.length ? words[_i] : null;
  String? _peek(int ahead) =>
      _i + ahead < words.length ? words[_i + ahead] : null;

  static final RegExp _clock = RegExp(r'^(\d{1,2})[:.](\d{2})$');

  static final RegExp _fraction = RegExp(r'^\d+[,.]\d$');

  static const Set<String> _timePrepositions = <String>{
    'на',
    'в',
    'во',
    'к',
    'ко',
    'около',
  };

  static const Set<String> _dayparts = <String>{
    'утра',
    'утром',
    'вечера',
    'вечером',
    'дня',
    'днем',
    'ночи',
    'ночью',
  };

  void read() {
    while (_i < words.length) {
      final start = _i;
      if (!_step()) {
        _i = start;
        final word = _word!;
        if (!AlarmPhrases._tailFillers.contains(word)) leftover = true;
        if (AlarmPhrases.number(word) != null || _clock.hasMatch(word)) {
          strayNumber = true;
        }
        _i++;
      }
    }
  }

  /// Одно понятное сочетание с текущего слова; `false` — не понято.
  bool _step() {
    final word = _word!;
    switch (word) {
      case 'сегодня':
        dayOffset = 0;
        _i++;
        return true;
      case 'завтра':
        dayOffset = 1;
        _i++;
        return true;
      case 'послезавтра':
        dayOffset = 2;
        _i++;
        return true;
      case 'ежедневно':
        days.addAll(<int>[1, 2, 3, 4, 5, 6, 7]);
        _i++;
        return true;
      case 'каждый' when _peek(1) == 'день':
        days.addAll(<int>[1, 2, 3, 4, 5, 6, 7]);
        _i += 2;
        return true;
      case 'каждое' when _peek(1) == 'утро':
        days.addAll(<int>[1, 2, 3, 4, 5, 6, 7]);
        _i += 2;
        return true;
      case 'по':
        return _repeat();
      case 'через':
        _i++;
        final value = _duration();
        if (value == null) return false;
        relative = value;
        return true;
      case 'полчаса' when timer:
        _i++;
        duration = (duration ?? Duration.zero) + const Duration(minutes: 30);
        return true;
    }
    if (_dayparts.contains(word) && hour != null) {
      daypart = word;
      _i++;
      return true;
    }
    if (_halfPast()) return true;
    // «Двадцать пятого мне вставать в семь» — число месяца словом.
    if (!timer && monthDay == null) {
      final ordinal = NumberWords.dayOrdinalAt(words, _i);
      if (ordinal != null &&
          ordinal.$2 == 'ого' &&
          ordinal.$1 >= 1 &&
          ordinal.$1 <= 31) {
        monthDay = ordinal.$1;
        _i = ordinal.$3 + 1;
        return true;
      }
    }
    if (_timePrepositions.contains(word)) {
      final next = _peek(1);
      if (next != null) {
        final weekday = AlarmPhrases._weekdayAccusative[next];
        if (weekday != null && (word == 'в' || word == 'во')) {
          this.weekday = weekday;
          _i += 2;
          return true;
        }
      }
      // «На выходные на девять» — суббота и воскресенье.
      if (word == 'на' && next == 'выходные') {
        days.addAll(<int>[6, 7]);
        _i += 2;
        return true;
      }
      // «на завтра в 7», «на сегодня»: день разберёт следующий шаг.
      if (const <String>{'сегодня', 'завтра', 'послезавтра'}.contains(next)) {
        _i++;
        return true;
      }
      _i++;
      if (_halfPast() || _timeOrDuration()) return true;
      _i--;
      return false;
    }
    return _timeOrDuration();
  }

  /// «Полседьмого», «пол седьмого», «половина седьмого» — 6:30.
  bool _halfPast() {
    final word = _word;
    if (timer || hour != null || word == null) return false;
    if (word.startsWith('пол') && word.length > 3) {
      final ordinal = AlarmPhrases._ordinalHours[word.substring(3)];
      if (ordinal != null) {
        hour = ordinal == 1 ? 12 : ordinal - 1;
        minute = 30;
        _i++;
        return true;
      }
    }
    if (const <String>{'пол', 'половина', 'половине', 'половину'}
        .contains(word)) {
      final ordinal = AlarmPhrases._ordinalHours[_peek(1) ?? ''];
      if (ordinal != null) {
        hour = ordinal == 1 ? 12 : ordinal - 1;
        minute = 30;
        _i += 2;
        return true;
      }
    }
    return false;
  }

  /// «По будням», «по выходным», «по понедельникам и средам».
  bool _repeat() {
    final next = _peek(1);
    if (next == 'будням' || next == 'будним') {
      days.addAll(<int>[1, 2, 3, 4, 5]);
      _i += next == 'будним' && _peek(2) == 'дням' ? 3 : 2;
      return true;
    }
    // «По рабочим дням» — то же, что «по будням».
    if (next == 'рабочим' && _peek(2) == 'дням') {
      days.addAll(<int>[1, 2, 3, 4, 5]);
      _i += 3;
      return true;
    }
    if (next == 'выходным') {
      days.addAll(<int>[6, 7]);
      _i += _peek(2) == 'дням' ? 3 : 2;
      return true;
    }
    final day = AlarmPhrases._weekdayPlural[next];
    if (day == null) return false;
    days.add(day);
    _i += 2;
    // «… и средам», «…, пятницам»
    while (_word == 'и' || AlarmPhrases._weekdayPlural.containsKey(_word)) {
      if (_word == 'и') {
        final more = AlarmPhrases._weekdayPlural[_peek(1) ?? ''];
        if (more == null) break;
        days.add(more);
        _i += 2;
      } else {
        days.add(AlarmPhrases._weekdayPlural[_word]!);
        _i++;
      }
    }
    return true;
  }

  /// Время будильника или длительность таймера с текущего слова.
  bool _timeOrDuration() {
    if (!timer) return _time();
    final start = _i;
    final value = _duration();
    if (value != null) {
      duration = (duration ?? Duration.zero) + value;
      return true;
    }
    _i = start;
    return false;
  }

  /// «7», «7:30», «семь», «7 часов 30 минут», «7 30», «пять сорок пять»,
  /// «шесть ноль пять», «без четверти семь».
  bool _time() {
    final word = _word;
    if (word == null || hour != null) return false;
    if (word == 'без') return _minutesTo();
    final clock = _clock.firstMatch(word);
    if (clock != null) {
      hour = int.parse(clock.group(1)!);
      minute = int.parse(clock.group(2)!);
      _i++;
      return true;
    }
    final h = AlarmPhrases.number(word);
    if (h == null || h > 24) return false;
    hour = h == 24 ? 0 : h;
    _i++;
    if (const <String>{'час', 'часа', 'часов'}.contains(_word)) _i++;
    // «7 30», «7 часов 30 минут», «семь тридцать», «пять сорок пять»,
    // «шесть ноль пять».
    final m = AlarmPhrases.number(_word ?? '');
    final next = AlarmPhrases.number(_peek(1) ?? '');
    if (m == 0 && _word == 'ноль' && next != null && next > 0 && next < 10) {
      minute = next;
      _i += 2;
    } else if (_word == 'ноль' && _peek(1) == 'ноль') {
      // «Девять ноль-ноль», «восемнадцать ноль ноль».
      minute = 0;
      _i += 2;
    } else if (m != null &&
        m < 60 &&
        m >= 0 &&
        (_word!.length == 2 || m >= 10)) {
      minute = m;
      _i++;
      // «сорок пять»: десятки словом и единицы следом.
      if (m >= 20 &&
          m % 10 == 0 &&
          _numberWord(_word) &&
          next != null &&
          next > 0 &&
          next < 10) {
        minute = m + next;
        _i++;
      }
    }
    if (minute != null &&
        const <String>{'минут', 'минуты', 'минута'}.contains(_word)) {
      _i++;
    }
    return true;
  }

  static bool _numberWord(String? word) =>
      word != null && AlarmPhrases._numberWords.containsKey(word);

  /// Минуты до часа после «без»: «без четверти семь» — 6:45, «без десяти
  /// восемь», «без двадцати пяти девять», «без 15 7».
  bool _minutesTo() {
    final start = _i;
    _i++;
    var minutes = _minutesBefore[_word ?? ''];
    if (minutes == null) {
      final n = int.tryParse(_word ?? '');
      if (n == null || n <= 0 || n >= 60) {
        _i = start;
        return false;
      }
      minutes = n;
    }
    _i++;
    // «без двадцати пяти»
    if (minutes == 20 && _minutesBefore[_word ?? ''] == 5) {
      minutes = 25;
      _i++;
    }
    if (const <String>{'минут', 'минуты'}.contains(_word)) _i++;
    final h = AlarmPhrases.number(_word ?? '');
    if (h == null || h < 1 || h > 24) {
      _i = start;
      return false;
    }
    _i++;
    if (const <String>{'час', 'часа', 'часов'}.contains(_word)) _i++;
    final previous = h - 1;
    hour = previous == 0 ? 12 : previous;
    minute = 60 - minutes;
    return true;
  }

  static const Map<String, int> _minutesBefore = <String, int>{
    'четверти': 15,
    'одной': 1,
    'минуты': 1,
    'двух': 2,
    'трех': 3,
    'четырех': 4,
    'пяти': 5,
    'десяти': 10,
    'пятнадцати': 15,
    'двадцати': 20,
  };

  static const Map<String, int> _unitSeconds = <String, int>{
    'секунда': 1,
    'секунду': 1,
    'секунды': 1,
    'секунд': 1,
    'сек': 1,
    'минута': 60,
    'минуту': 60,
    'минуты': 60,
    'минут': 60,
    'мин': 60,
    // «На 3 минутки», «на минутку».
    'минутка': 60,
    'минутку': 60,
    'минутки': 60,
    'минуток': 60,
    'час': 3600,
    'часа': 3600,
    'часов': 3600,
    'ч': 3600,
    'часик': 3600,
    'часика': 3600,
    'часиков': 3600,
  };

  /// «5 минут», «полчаса», «полтора часа», «час», «1:30» (часы и
  /// минуты), «2 часа 15 минут», «минуту».
  Duration? _duration() {
    var total = 0;
    var any = false;
    while (_i < words.length) {
      final word = words[_i];
      if (word == 'полчаса') {
        total += 1800;
        _i++;
        any = true;
        continue;
      }
      // «Четверть часа», «четверть часика».
      if (word == 'четверть' && (_peek(1) == 'часа' || _peek(1) == 'часика')) {
        total += 900;
        _i += 2;
        any = true;
        continue;
      }
      if ((word == 'полтора' || word == 'полторы') && _peek(1) != null) {
        final unit = _unitSeconds[_peek(1)!];
        if (unit == null) break;
        total += unit * 3 ~/ 2;
        _i += 2;
        any = true;
        continue;
      }
      final unitOnly = _unitSeconds[word];
      if (unitOnly != null && !any && word != 'ч' && word != 'мин') {
        // «на час», «на минуту»
        if (word == 'час' || word == 'минуту' || word == 'секунду') {
          total += unitOnly;
          _i++;
          any = true;
          _afterHours = word == 'час';
          continue;
        }
        break;
      }
      // «На 1,5 часа», «2.5 минуты»: дробь перед единицей.
      final fraction = _fraction.firstMatch(word);
      final fractionUnit = _unitSeconds[_peek(1) ?? ''];
      if (fraction != null && fractionUnit != null) {
        final value = double.parse(word.replaceAll(',', '.'));
        total += (value * fractionUnit).round();
        _i += 2;
        any = true;
        if (_word == 'и') _i++;
        continue;
      }
      final clock = _clock.firstMatch(word);
      if (clock != null && !any && _unitSeconds[_peek(1) ?? ''] == null) {
        // «таймер на 1:30» — час тридцать (у будильника «7:30» — время,
        // его читает [_time]).
        total +=
            int.parse(clock.group(1)!) * 3600 + int.parse(clock.group(2)!) * 60;
        _i++;
        any = true;
        break;
      }
      final n = AlarmPhrases.number(word);
      if (n == null) break;
      var value = n;
      var used = 1;
      // «двадцать пять минут»
      final second = AlarmPhrases.number(_peek(1) ?? '');
      if (n >= 20 && n % 10 == 0 && second != null && second < 10) {
        value += second;
        used = 2;
      }
      // «Две с половиной минуты», «3 с половиной часа» — плюс половина
      // единицы.
      var half = 0;
      if (_peek(used) == 'с' &&
          _peek(used + 1) == 'половиной' &&
          _unitSeconds[_peek(used + 2) ?? ''] != null) {
        half = _unitSeconds[_peek(used + 2)!]! ~/ 2;
        used += 2;
      }
      final unit = _unitSeconds[_peek(used) ?? ''];
      if (unit == null) {
        // «на час двадцать», «два часа десять»: минуты без слова после
        // часов.
        if (_afterHours &&
            value > 0 &&
            value < 60 &&
            used + _i == words.length) {
          total += value * 60;
          _i += used;
        }
        break;
      }
      total += value * unit + half;
      _i += used + 1;
      any = true;
      _afterHours = unit == 3600;
      if (_word == 'и') _i++;
    }
    _afterHours = false;
    return any ? Duration(seconds: total) : null;
  }

  /// Последним в длительности прочитан час: число следом — минуты.
  bool _afterHours = false;
}
