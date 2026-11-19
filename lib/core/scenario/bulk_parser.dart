import '../connectors/due_parser.dart';
import '../connectors/speech_noise.dart';
import '../connectors/utterance.dart';
import '../models/bulk.dart';
import '../models/task.dart';

/// Разбор массовой команды: что сделать, с какими задачами и куда.
final class BulkParse {
  const BulkParse({
    required this.action,
    required this.selection,
    this.dueAt,
    this.precision,
    this.issue = DueIssue.none,
    this.shift,
    this.exclude = const <String>[],
  });

  final BulkAction action;
  final BulkSelection selection;

  /// Новый срок переноса (без исходного дня): «на понедельник» в «все
  /// задачи на пятницу перенеси на понедельник».
  final DateTime? dueAt;
  final DuePrecision? precision;

  /// Проблема со сроком переноса или с днём выбора (два разных дня).
  final DueIssue issue;

  /// «на час позже»: сдвиг каждой задачи вместо нового срока.
  final DueShift? shift;

  /// Части названий задач после «кроме»: «закрой всё, кроме хлеба» —
  /// `хлеба`. Такие задачи попадают в список без отметки.
  final List<String> exclude;
}

/// Правила массовых команд над несколькими задачами (docs/CORPUS.md,
/// «Массовые команды»).
///
/// Команда — глагол переноса («перенеси», «отложи», «сдвинь») или
/// завершения («закрой», «заверши», «отметь … выполненными») и выбор задач:
/// «всё», «все задачи», «просроченные», «сегодняшние», «без срока», «на
/// пятницу» (до глагола), «с пятницы», «с #работа», «по #ремонт». Каждое
/// слово фразы должно быть частью команды, выбора, срока или вежливости:
/// «перенеси встречу на завтра» — не массовая команда, а перенос одной
/// задачи. Нужен явный признак многих задач: «все», «просроченные»,
/// «сегодняшние», «без срока» или «задачи» вместе с меткой или днём.
///
/// У переноса срок до глагола и срок с «с/со» — исходный день выбора, срок
/// после глагола — новый. «На N минут/часов/дней/недель позже (раньше)»,
/// а после «сдвинь», «отложи», «передвинь» — и без «позже», это сдвиг
/// каждой задачи. У завершения любой срок — день выбора.
final class BulkParser {
  const BulkParser();

  static const Set<String> _rescheduleVerbs = <String>{
    'перенеси',
    'перенесите',
    'перенести',
    'отложи',
    'отложите',
    'отложить',
    'сдвинь',
    'сдвиньте',
    'сдвинуть',
    'передвинь',
    'передвиньте',
    'передвинуть',
    'перекинь',
    'перекиньте',
    'перекинуть',
  };

  /// Глаголы, после которых «на N часов» — сдвиг и без «позже».
  static const Set<String> _shiftVerbs = <String>{
    'отложи',
    'отложите',
    'отложить',
    'сдвинь',
    'сдвиньте',
    'сдвинуть',
    'передвинь',
    'передвиньте',
    'передвинуть',
  };

  static const Set<String> _completeVerbs = <String>{
    'закрой',
    'закройте',
    'закрыть',
    'заверши',
    'завершите',
    'завершить',
    'отметь',
    'отметьте',
    'отметить',
  };

  /// Глаголы, которым нужно «выполненными»: «отметь всё» — ещё не
  /// завершение.
  static const Set<String> _markVerbs = <String>{
    'отметь',
    'отметьте',
    'отметить',
  };

  static const Set<String> _doneWords = <String>{
    'выполненными',
    'выполненным',
    'выполненные',
    'выполненное',
    'выполнено',
    'сделанными',
    'сделанным',
    'сделанные',
    'сделанное',
    'готовыми',
    'готовым',
    'завершенными',
    'завершенные',
  };

  static const Set<String> _quantifiers = <String>{'все', 'всех', 'весь'};

  /// Знаки после «всё», с которыми оно — не «все задачи», а «так, хватит»:
  /// «всё, закрой», «всё — перенеси на пятницу».
  static final RegExp _discourseMark = RegExp(r'^\s*[,—–!.:-]');

  /// Слова исключения: «закрой всё, кроме хлеба».
  static const Set<String> _exceptWords = <String>{'кроме', 'исключая'};

  /// Множественное число в именительном и винительном падежах: «перенеси
  /// задачи на завтра» — тоже о многих задачах. «Задач», «дел» без
  /// «всех» таким признаком не считаются.
  static const Set<String> _pluralNouns = <String>{
    'задачи',
    'дела',
    'задания',
    'напоминания',
  };

  static const Set<String> _nouns = <String>{
    'задачи',
    'задач',
    'дела',
    'дел',
    'задания',
    'заданий',
    'напоминания',
    'напоминаний',
  };

  static const Set<String> _neutralAdjectives = <String>{
    'мои',
    'свои',
    'активные',
    'открытые',
    'оставшиеся',
    'остальные',
    'текущие',
    'невыполненные',
    'незакрытые',
  };

  static const Set<String> _overdueWords = <String>{
    'просроченные',
    'просроченное',
    'просроченных',
    'просроченными',
    'просрочку',
  };

  static const Map<String, int> _dayAdjectives = <String, int>{
    'сегодняшние': 0,
    'сегодняшнее': 0,
    'сегодняшних': 0,
    'завтрашние': 1,
    'завтрашнее': 1,
    'завтрашних': 1,
    'вчерашние': -1,
    'вчерашнее': -1,
    'вчерашних': -1,
  };

  static const Set<String> _noDueNouns = <String>{
    'срока',
    'сроков',
    'даты',
    'дат',
    'дедлайна',
    'дедлайнов',
  };

  static const Set<String> _tagPrepositions = <String>{
    'с',
    'со',
    'по',
    'из',
    'в',
    'для',
    'под',
  };

  static const Set<String> _tagNouns = <String>{
    'проекта',
    'проекту',
    'проекте',
    'тега',
    'тегу',
    'тегом',
    'метки',
    'метке',
    'меткой',
    'категории',
  };

  static const Set<String> _polite = <String>{
    'пожалуйста',
    'плиз',
    'пж',
    'ка',
    'мне',
    'давай',
    'слушай',
    'ну',
    'так',
    'тогда',
    'сразу',
    'разом',
    'можешь',
    'можете',
    'надо',
    'нужно',
    'хочу',
    'как',
  };

  /// Вступления перед глаголом: «будь добр, перенеси все просроченные»,
  /// «а можешь закрыть все сегодняшние?». Без них фраза с одним чужим
  /// словом переставала быть массовой и становилась переносом одной
  /// задачи «Будь добр, все просроченные».
  static const Set<String> _leadIns = <String>{
    'а',
    'и',
    'будь',
    'будьте',
    'добр',
    'добра',
    'добры',
    'любезен',
    'любезна',
    'любезны',
    'слышь',
    'ладно',
    'хорошо',
    'итак',
    'теперь',
    'еще',
  };

  static const Set<String> _sourcePrepositions = <String>{'с', 'со', 'от'};

  static const Map<String, int> _numberWords = <String, int>{
    'один': 1,
    'одну': 1,
    'одна': 1,
    'два': 2,
    'две': 2,
    'пару': 2,
    'три': 3,
    'четыре': 4,
    'пять': 5,
    'шесть': 6,
    'семь': 7,
    'восемь': 8,
    'девять': 9,
    'десять': 10,
  };

  static const Map<String, (ShiftUnit, int)> _units =
      <String, (ShiftUnit, int)>{
    'минуту': (ShiftUnit.minutes, 1),
    'минуты': (ShiftUnit.minutes, 1),
    'минут': (ShiftUnit.minutes, 1),
    'полчаса': (ShiftUnit.minutes, 30),
    'час': (ShiftUnit.hours, 1),
    'часа': (ShiftUnit.hours, 1),
    'часов': (ShiftUnit.hours, 1),
    'день': (ShiftUnit.days, 1),
    'дня': (ShiftUnit.days, 1),
    'дней': (ShiftUnit.days, 1),
    'сутки': (ShiftUnit.days, 1),
    'суток': (ShiftUnit.days, 1),
    'неделю': (ShiftUnit.days, 7),
    'недели': (ShiftUnit.days, 7),
    'недель': (ShiftUnit.days, 7),
  };

  static const Set<String> _later = <String>{
    'позже',
    'попозже',
    'вперед',
    'дальше',
  };

  static const Set<String> _earlier = <String>{
    'раньше',
    'пораньше',
    'назад',
  };

  /// Сдвиг «на N единиц позже/раньше» после глагола переноса
  /// [verbIndex]: «сдвинь всё на час позже», «перенеси звонок на полчаса
  /// раньше». После «отложи», «сдвинь» длительность и без «позже» —
  /// сдвиг вперёд. Без направления после «перенеси» («перенеси на 2
  /// часа») — длительность без сдвига: [ShiftFound.shift] пуст, и
  /// спрашивается, на когда. `null` — сдвига во фразе нет.
  static ShiftFound? shiftAfter(List<UtteranceToken> tokens, int verbIndex) {
    final verb = tokens[verbIndex].text;
    for (var i = verbIndex + 1; i < tokens.length; i++) {
      if (tokens[i].text != 'на') continue;
      var j = i + 1;
      int? amount;
      if (j < tokens.length) {
        final word = tokens[j].text;
        amount = tokens[j].isNumber ? int.tryParse(word) : _numberWords[word];
        if (amount != null) j++;
      }
      if (j >= tokens.length) continue;
      final unit = _units[tokens[j].text];
      if (unit == null) continue;
      final (shiftUnit, factor) = unit;
      final value = (amount ?? 1) * factor;
      var end = j;
      var sign = 0;
      if (j + 1 < tokens.length) {
        final direction = tokens[j + 1].text;
        if (_later.contains(direction)) sign = 1;
        if (_earlier.contains(direction)) sign = -1;
        if (sign != 0) end = j + 1;
      }
      if (sign == 0 && _shiftVerbs.contains(verb)) sign = 1;
      if (value <= 0 || value > 9999) continue;
      return ShiftFound(
        from: i,
        to: end,
        span: CharSpan(tokens[i].span.start, tokens[end].span.end),
        shift: sign == 0 ? null : DueShift(sign * value, shiftUnit),
        directed: end > j,
      );
    }
    return null;
  }

  /// Массовая команда или `null`, если фраза о другом.
  BulkParse? parse(Utterance utterance, DateTime now) {
    if (utterance.unbalancedQuotes) return null;
    final tokens = utterance.tokens;
    // Название в кавычках — только после «кроме»: «закрой всё, кроме
    // «Купить хлеб»». Иначе это команда об одной задаче.
    final exceptAt = tokens
        .where((UtteranceToken t) => _exceptWords.contains(t.text))
        .map((UtteranceToken t) => t.span.end)
        .firstOrNull;
    for (final quote in utterance.quotedTitles) {
      if (exceptAt == null || quote.span.start < exceptAt) return null;
    }
    final verbIndex = tokens.indexWhere(
      (UtteranceToken t) =>
          _rescheduleVerbs.contains(t.text) || _completeVerbs.contains(t.text),
    );
    if (verbIndex < 0) return null;
    final verb = tokens[verbIndex].text;
    final action = _rescheduleVerbs.contains(verb)
        ? BulkAction.reschedule
        : BulkAction.complete;
    final used = List<bool>.filled(tokens.length, false);
    used[verbIndex] = true;
    final today = DateTime(now.year, now.month, now.day);

    // Сдвиг «на N единиц позже»: только у переноса, после глагола.
    DueShift? shift;
    var durationOnly = false;
    CharSpan? shiftSpan;
    if (action == BulkAction.reschedule) {
      final found = shiftAfter(tokens, verbIndex);
      if (found != null) {
        for (var k = found.from; k <= found.to; k++) {
          used[k] = true;
        }
        shiftSpan = found.span;
        shift = found.shift;
        durationOnly = found.shift == null;
      }
    }

    // Сроки: исходный день выбора или новый срок переноса.
    final verbStart = tokens[verbIndex].span.start;
    final sourceSpans = <CharSpan>[];
    final targetSpans = <CharSpan>[];
    for (final span in utterance.due.spans) {
      final covered = <int>[
        for (var i = 0; i < tokens.length; i++)
          if (Utterance.isCovered(tokens[i], <CharSpan>[span])) i,
      ];
      for (final i in covered) {
        used[i] = true;
      }
      if (shiftSpan != null &&
          span.start < shiftSpan.end &&
          shiftSpan.start < span.end) {
        continue;
      }
      final first = covered.isEmpty ? '' : tokens[covered.first].text;
      final isSource = action == BulkAction.complete ||
          span.end <= verbStart ||
          _sourcePrepositions.contains(first);
      (isSource ? sourceSpans : targetSpans).add(span);
    }

    // Выбор задач.
    var quantifier = false;
    var noun = false;
    var pluralNoun = false;
    final exclude = <String>[
      for (final quote in utterance.quotedTitles) quote.text,
    ];
    // «Всё, закрой»: «всё» перед глаголом с запятой или тире — завершение
    // реплики, а не выбор всех задач.
    if (verbIndex > 0 &&
        !used[0] &&
        tokens[0].text == 'все' &&
        _discourseMark
            .hasMatch(utterance.original.substring(tokens[0].span.end))) {
      used[0] = true;
    }
    var overdue = false;
    var noDue = false;
    var done = false;
    var dayAdjective = false;
    final sourceDays = <DateTime>{};
    for (var i = 0; i < tokens.length; i++) {
      if (used[i]) continue;
      final word = tokens[i].text;
      if (_exceptWords.contains(word)) {
        // Всё до срока, метки или конца фразы — названия: «кроме хлеба и
        // молока», «кроме отчёта на завтра».
        var j = i + 1;
        while (j < tokens.length &&
            !used[j] &&
            !_touchesHashtag(utterance, tokens[j - 1], tokens[j])) {
          j++;
        }
        if (j == i + 1 && utterance.quotedTitles.isEmpty) return null;
        exclude.addAll(_exceptionTitles(utterance, i + 1, j));
        for (var k = i; k < j; k++) {
          used[k] = true;
        }
        i = j - 1;
        continue;
      } else if (_quantifiers.contains(word)) {
        quantifier = true;
      } else if (_nouns.contains(word)) {
        noun = true;
        if (_pluralNouns.contains(word)) pluralNoun = true;
      } else if (_overdueWords.contains(word)) {
        overdue = true;
      } else if (_dayAdjectives[word] case final int offset) {
        sourceDays.add(DateTime(today.year, today.month, today.day + offset));
        dayAdjective = true;
      } else if (_doneWords.contains(word)) {
        done = true;
      } else if (word == 'без' &&
          i + 1 < tokens.length &&
          _noDueNouns.contains(tokens[i + 1].text)) {
        noDue = true;
        used[i + 1] = true;
      } else if (!_neutralAdjectives.contains(word) &&
          !_polite.contains(word) &&
          !SpeechNoise.isJunk(word) &&
          !(i < verbIndex &&
              (SpeechNoise.isLeadFiller(word) || _leadIns.contains(word))) &&
          !_beforeHashtag(utterance, i)) {
        return null;
      }
      used[i] = true;
    }
    if (_markVerbs.contains(verb) && !done) return null;
    if (action == BulkAction.reschedule && done) return null;

    var issue = DueIssue.none;
    for (final span in sourceSpans) {
      final day = _sourceDay(utterance, span, today, now);
      if (day == null) {
        issue = DueIssue.invalidDate;
      } else {
        sourceDays.add(day);
      }
    }
    final tags = <String>[
      for (final tag in utterance.hashtags)
        if (tag.name.isNotEmpty) tag.name,
    ];
    final scopes =
        (overdue ? 1 : 0) + (noDue ? 1 : 0) + (sourceDays.isNotEmpty ? 1 : 0);
    final evidence = quantifier ||
        pluralNoun ||
        overdue ||
        noDue ||
        dayAdjective ||
        noun && (tags.isNotEmpty || sourceDays.isNotEmpty);
    if (!evidence) return null;
    if (scopes > 1 || sourceDays.length > 1) issue = DueIssue.conflictingDays;
    final selection = switch ((overdue, noDue, sourceDays.length)) {
      (true, _, _) when scopes == 1 =>
        BulkSelection(kind: BulkScopeKind.overdue, tags: tags),
      (_, true, _) when scopes == 1 =>
        BulkSelection(kind: BulkScopeKind.noDue, tags: tags),
      (_, _, 1) when scopes == 1 => BulkSelection(
          kind: BulkScopeKind.day,
          day: sourceDays.single,
          tags: tags,
        ),
      _ => BulkSelection(tags: tags),
    };
    if (issue != DueIssue.none) {
      return BulkParse(
        action: action,
        selection: selection,
        issue: issue,
        exclude: exclude,
      );
    }
    if (action == BulkAction.complete) {
      return BulkParse(action: action, selection: selection, exclude: exclude);
    }
    if (shift != null || durationOnly) {
      if (targetSpans.isNotEmpty) {
        return BulkParse(
          action: action,
          exclude: exclude,
          selection: selection,
          issue: DueIssue.conflictingTimes,
        );
      }
      return BulkParse(
        action: action,
        selection: selection,
        shift: shift,
        exclude: exclude,
      );
    }
    if (targetSpans.isEmpty) {
      return BulkParse(action: action, selection: selection, exclude: exclude);
    }
    // Новый срок — по тексту без исходного дня: иначе «на пятницу …
    // на понедельник» — два разных дня.
    final text = StringBuffer();
    final analysis = utterance.analysisText;
    for (var i = 0; i < analysis.length; i++) {
      final masked = sourceSpans.any(
        (CharSpan s) => s.start <= i && i < s.end,
      );
      text.write(masked ? ' ' : analysis[i]);
    }
    final target = const DueParser().parse(text.toString(), now);
    final targetDue = target.dueAt;
    if (target.sameTime && target.issue == DueIssue.none && targetDue != null) {
      // «Перенеси всё сегодняшнее на завтра на то же время»: у каждой
      // задачи своё время — это сдвиг на столько же дней. Без исходного
      // дня сдвиг не посчитать — переспросим, на когда.
      final from = selection.day;
      final days = from == null
          ? 0
          : DateTime.utc(targetDue.year, targetDue.month, targetDue.day)
              .difference(DateTime.utc(from.year, from.month, from.day))
              .inDays;
      return BulkParse(
        action: action,
        exclude: exclude,
        selection: selection,
        shift: days == 0 ? null : DueShift(days, ShiftUnit.days),
      );
    }
    return BulkParse(
      action: action,
      exclude: exclude,
      selection: selection,
      dueAt: target.issue == DueIssue.none ? target.dueAt : null,
      precision: target.issue == DueIssue.none ? target.precision : null,
      issue: target.issue,
    );
  }

  /// Текст после начального «всё,» перед глаголом переноса или
  /// завершения: «всё, закрой» → «закрой». Иначе `null`.
  static String? withoutDiscourse(Utterance utterance) {
    final tokens = utterance.tokens;
    if (tokens.length < 2 || tokens[0].text != 'все') return null;
    final after = utterance.original.substring(tokens[0].span.end);
    if (!_discourseMark.hasMatch(after)) return null;
    final verb = tokens[1].text;
    if (!_rescheduleVerbs.contains(verb) && !_completeVerbs.contains(verb)) {
      return null;
    }
    return utterance.original.substring(tokens[1].span.start);
  }

  /// Между словами [before] и [after] стоит метка: «кроме хлеба #дом» —
  /// метка уже не часть названия.
  static bool _touchesHashtag(
    Utterance utterance,
    UtteranceToken before,
    UtteranceToken after,
  ) =>
      utterance.hashtags.any(
        (Hashtag tag) =>
            tag.span.start >= before.span.end &&
            tag.span.start < after.span.start,
      );

  /// Названия после «кроме» из слов `[from, to)`: через запятую, «и»,
  /// «или» — по одному.
  static List<String> _exceptionTitles(
    Utterance utterance,
    int from,
    int to,
  ) {
    final tokens = utterance.tokens;
    final titles = <String>[];
    var start = from;
    void flush(int end) {
      if (end <= start) return;
      titles.add(
        utterance.original
            .substring(tokens[start].span.start, tokens[end - 1].span.end)
            .replaceAll(RegExp('[«»"“”„]'), '')
            .trim(),
      );
    }

    for (var k = from; k < to; k++) {
      final word = tokens[k].text;
      if (word == 'и' || word == 'или') {
        flush(k);
        start = k + 1;
        continue;
      }
      if (k > start &&
          utterance.original
              .substring(tokens[k - 1].span.end, tokens[k].span.start)
              .contains(RegExp('[,;]'))) {
        flush(k);
        start = k;
      }
    }
    flush(to);
    return <String>[
      for (final title in titles)
        if (title.isNotEmpty) title,
    ];
  }

  /// Предлог или слово перед меткой: «с #работа», «по проекту #ремонт».
  static bool _beforeHashtag(Utterance utterance, int index) {
    final tokens = utterance.tokens;
    final word = tokens[index].text;
    bool touches(int i) {
      final end = tokens[i].span.end;
      for (final tag in utterance.hashtags) {
        if (tag.span.start < end) continue;
        if (utterance.original.substring(end, tag.span.start).trim().isEmpty) {
          return true;
        }
      }
      return false;
    }

    if (_tagNouns.contains(word)) return touches(index);
    if (!_tagPrepositions.contains(word)) return false;
    if (touches(index)) return true;
    return index + 1 < tokens.length &&
        _tagNouns.contains(tokens[index + 1].text) &&
        touches(index + 1);
  }

  /// День выбора из фрагмента срока: «на пятницу», «с пятницы», «со
  /// вчера». Прошедший день разбор сроков не принимает — «вчера» и
  /// «позавчера» считаются здесь.
  static DateTime? _sourceDay(
    Utterance utterance,
    CharSpan span,
    DateTime today,
    DateTime now,
  ) {
    final words = <String>[
      for (final token in utterance.tokens)
        if (Utterance.isCovered(token, <CharSpan>[span])) token.text,
    ];
    if (words.contains('позавчера')) {
      return DateTime(today.year, today.month, today.day - 2);
    }
    if (words.contains('вчера')) {
      return DateTime(today.year, today.month, today.day - 1);
    }
    final result = const DueParser().parse(
      utterance.analysisText.substring(span.start, span.end),
      now,
    );
    final due = result.dueAt;
    if (due == null) return null;
    return DateTime(due.year, due.month, due.day);
  }
}

/// Найденный сдвиг ([BulkParser.shiftAfter]): слова с [from] по [to]
/// включительно и их место в тексте.
final class ShiftFound {
  const ShiftFound({
    required this.from,
    required this.to,
    required this.span,
    required this.shift,
    required this.directed,
  });

  final int from;
  final int to;
  final CharSpan span;

  /// `null` — длительность без направления: «перенеси на 2 часа».
  final DueShift? shift;

  /// Направление названо словом: «позже», «раньше», «пораньше».
  final bool directed;
}
