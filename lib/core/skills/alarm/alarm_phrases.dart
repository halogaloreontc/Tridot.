import '../../connectors/social_prefix.dart';
import '../../connectors/utterance.dart';

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

  static final RegExp _token = RegExp(r'\d{1,2}[:.]\d{2}|[a-zа-я0-9]+');

  static const Set<String> _alarmNouns = <String>{
    'будильник',
    'будильника',
    'будильнику',
    'будильником',
  };

  static const Set<String> _timerNouns = <String>{
    'таймер',
    'таймера',
    'таймеру',
    'таймером',
  };

  static const Set<String> _wakeVerbs = <String>{
    'разбуди',
    'разбудите',
    'разбудишь',
  };

  static const Set<String> _stopwatchVerbs = <String>{
    'засеки',
    'засекай',
    'засеките',
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
  };

  /// Слова перед будильником, которые не меняют смысла.
  static const Set<String> _leadFillers = <String>{
    'пожалуйста',
    'плиз',
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
    'один': 1,
    'одну': 1,
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
    'пятнадцать': 15,
    'двадцать': 20,
    'тридцать': 30,
    'сорок': 40,
    'сорока': 40,
    'пятьдесят': 50,
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
    final tokens = <String>[
      for (final match in _token.allMatches(text))
        if (match.start >= from) match.group(0)!,
    ];
    if (tokens.isEmpty || tokens.contains('не') || tokens.contains('нет')) {
      return null;
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
      } else if (_wakeVerbs.contains(word)) {
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
    if (kind == null || anchor > 5) return null;
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
    if (utterance.isQuestion && !setVerb) return null;
    final reader = _Reader(
      tokens.sublist(anchor + 1),
      timer: kind == AlarmKind.timer,
    );
    reader.read();
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
    if (days.isNotEmpty) {
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

  /// Числа «7», «семь», «двадцать пять».
  static int? number(String word) => int.tryParse(word) ?? _numberWords[word];
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
  final Set<int> days = <int>{};
  Duration? relative;
  Duration? duration;

  /// Остались непонятные слова.
  bool leftover = false;

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
      if (!_step()) {
        if (!AlarmPhrases._tailFillers.contains(_word)) leftover = true;
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

  /// «7», «7:30», «семь», «7 часов 30 минут», «7 30».
  bool _time() {
    final word = _word;
    if (word == null || hour != null) return false;
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
    // «7 30», «7 часов 30 минут», «семь тридцать».
    final m = AlarmPhrases.number(_word ?? '');
    if (m != null && m < 60 && m >= 0 && (_word!.length == 2 || m >= 10)) {
      minute = m;
      _i++;
      if (const <String>{'минут', 'минуты', 'минута'}.contains(_word)) _i++;
    }
    return true;
  }

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
    'час': 3600,
    'часа': 3600,
    'часов': 3600,
    'ч': 3600,
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
          continue;
        }
        break;
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
      final unit = _unitSeconds[_peek(used) ?? ''];
      if (unit == null) break;
      total += value * unit;
      _i += used + 1;
      any = true;
      if (_word == 'и') _i++;
    }
    return any ? Duration(seconds: total) : null;
  }
}
