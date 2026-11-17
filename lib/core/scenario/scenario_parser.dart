import '../connectors/due_parser.dart';
import '../connectors/first_person_verbs.dart';
import '../connectors/noun_forms.dart';
import '../connectors/person_names.dart';
import '../connectors/question_phrases.dart';
import '../connectors/social_prefix.dart';
import '../connectors/speech_noise.dart';
import '../connectors/task_rephrase.dart';
import '../connectors/utterance.dart';
import '../connectors/verb_forms.dart';
import '../models/bulk.dart';
import '../models/task.dart';
import '../services/clock.dart';
import 'bulk_parser.dart';
import 'command_spans.dart';

export '../connectors/due_parser.dart' show CharSpan, DueIssue, DueParseResult;

enum CommandIntent {
  createTask,
  listTasks,
  completeTask,
  rescheduleTask,

  /// Перенос нескольких задач сразу: «перенеси всё на выходные»,
  /// «сдвинь всё на час позже» ([ParsedCommand.selection]).
  rescheduleMany,

  /// Завершение нескольких задач сразу: «закрой все просроченные».
  completeMany,
  unknown,
}

/// Проблемы с названием в кавычках.
enum TitleIssue {
  none,

  /// Кавычка открыта, но не закрыта.
  unbalancedQuotes,

  /// В команде несколько названий в кавычках.
  multipleTitles,
}

final class ParsedCommand {
  const ParsedCommand({
    required this.intent,
    this.title,
    this.targetQuery,
    this.dueAt,
    this.duePrecision,
    this.dueIssue = DueIssue.none,
    this.titleIssue = TitleIssue.none,
    this.projects = const <String>[],
    this.implicit = false,
    this.pastTense = false,
    this.selection,
    this.shift,
    this.exclude = const <String>[],
    this.certainty = 1,
    this.reminder = false,
  });

  /// Насколько разбор уверен в создании задачи: 1 — фраза ясная, меньше —
  /// пришлось угадывать (слова-шум распознавателя, «чтобы я написал» →
  /// «Написать», вопросительное слово в названии). По ней коннектор задач
  /// решает, спросить ли «Понял так: … Создать?» (docs/DECISIONS.md,
  /// ADR-023). Для остальных намерений — 1.
  final double certainty;

  /// Создание — просьба напомнить: «напомни …», «поставь напоминание …».
  /// Так звучит переспрос «Понял так: напомнить …».
  final bool reminder;

  /// Массовая команда ([CommandIntent.rescheduleMany],
  /// [CommandIntent.completeMany]): какие задачи выбраны. Метки выбора
  /// дублируются в [projects]. Для остальных намерений — `null`.
  final BulkSelection? selection;

  /// Сдвиг каждой задачи вместо нового срока: «сдвинь всё на час позже».
  /// Только у [CommandIntent.rescheduleMany], и тогда [dueAt] пуст.
  final DueShift? shift;

  /// Массовая команда: части названий после «кроме» («закрой всё, кроме
  /// хлеба»). Такие задачи в списке не отмечены.
  final List<String> exclude;

  bool get isBulk =>
      intent == CommandIntent.rescheduleMany ||
      intent == CommandIntent.completeMany;

  final CommandIntent intent;

  /// Команда без маркера: намерение понято по форме глагола. Создание —
  /// по инфинитиву в начале фразы («купить хлеб», «через 3 дня сдать
  /// отчёт»), завершение — по глаголу прошедшего времени («я купил хлеб»).
  /// Коннектор отвечает на такие команды с меньшей уверенностью, чтобы явная
  /// команда другого коннектора побеждала.
  final bool implicit;

  /// Завершение сообщением о сделанном: «я купил хлеб», «выполнил отчёт».
  /// Задача по [targetQuery] (или по [title] из кавычек: «вернул «Книгу»»)
  /// не завершается сразу: сначала вопрос «Отметить … выполненной?».
  final bool pastTense;

  /// Метки проектов из команды: «#работа» вне кавычек, без «#».
  final List<String> projects;

  /// Для создания — название новой задачи: из кавычек (как есть), а без
  /// них — остаток фразы после команды, срока, меток и вежливых слов,
  /// начало которого приведено к именительному падежу ([NounForms]):
  /// «напомни про встречу с клиентом» → «Встреча с клиентом».
  ///
  /// Для переноса и завершения — только точное название в кавычках.
  /// Название без кавычек для них — это [targetQuery].
  final String? title;

  /// Для переноса и завершения без кавычек: слова, по которым ищется задача
  /// («Перенеси отчёт на завтра» → «Отчёт», «перенеси встречу» → «Встреча»).
  /// `null`, если кроме команды,
  /// срока и слов вроде «её», «задачу» ничего не осталось — тогда
  /// контроллер берёт выбранную задачу. Для создания и списка всегда `null`.
  final String? targetQuery;
  final DateTime? dueAt;

  /// Точность [dueAt]: `null` тогда и только тогда, когда срока нет.
  final DuePrecision? duePrecision;
  final DueIssue dueIssue;
  final TitleIssue titleIssue;
}

/// Правила распознавания задачных команд.
///
/// Точное название можно дать в кавычках — это самый надёжный способ, и он
/// имеет приоритет. Без кавычек название — это остаток исходной фразы после
/// удаления маркера команды («добавь задачу», «напомни мне»), фрагментов
/// срока вместе с предлогами («на завтра в 10»), меток «#проект» и вежливых
/// слов. Удаляются только целые слова: «завтрак» — не «завтра».
/// При неоднозначности срока парсер сообщает о проблеме, а не угадывает.
final class ScenarioParser {
  ScenarioParser({required Clock clock}) : _clock = clock;

  final Clock _clock;

  /// Пока работает [spansOf]: какие слова стали названием или целью
  /// (каждый вызов [_titleText] — по порядку).
  List<(Utterance, List<UtteranceToken>)>? _probe;

  ParsedCommand parse(String message) =>
      parseUtterance(Utterance.analyze(message, now: _clock.now()));

  /// Что из [_titleText] осталось названием: текст для команды, а при
  /// работе [spansOf] — ещё и слова, из которых он собран.
  String _titleText(Utterance utterance, List<CharSpan> remove) {
    final text = utterance.remainder(remove);
    final probe = _probe;
    if (probe != null && text.isNotEmpty) {
      probe.add((utterance, utterance.tokensOutside(remove)));
    }
    return text;
  }

  /// Какие части [utterance] разбор понял (подсветка команды, ADR-021):
  /// слово команды, название или цель, срок, метки. Тот же разбор, что
  /// [parseUtterance], — ничего не угадывается отдельно. Пусто, если
  /// команды нет.
  List<CommandSpan> spansOf(Utterance utterance) {
    final probe = <(Utterance, List<UtteranceToken>)>[];
    final ParsedCommand command;
    _probe = probe;
    try {
      command = parseUtterance(utterance);
    } finally {
      _probe = null;
    }
    if (command.intent == CommandIntent.unknown) return const <CommandSpan>[];
    final tokens = utterance.tokens;
    final dueSpans = command.dueAt != null ||
            command.shift != null ||
            command.dueIssue != DueIssue.none
        ? utterance.due.spans
        : const <CharSpan>[];
    final spans = <CommandSpan>[
      for (final tag in utterance.hashtags)
        CommandSpan(tag.span.start, tag.span.end, CommandSpanKind.tag),
      for (final span in dueSpans)
        if (span.length > 0)
          CommandSpan(span.start, span.end, CommandSpanKind.due),
    ];
    final titleTokens = <UtteranceToken>[];
    if (command.title != null || command.targetQuery != null) {
      final quoted = utterance.quotedTitles;
      if (command.title != null && quoted.length == 1) {
        final span = quoted.single.span;
        if (span.length > 2) {
          spans.add(
            CommandSpan(span.start + 1, span.end - 1, CommandSpanKind.title),
          );
        }
      } else {
        // Название собрано из слов этой же фразы (не из «всё, …»).
        for (final (source, words) in probe.reversed) {
          if (!identical(source, utterance)) continue;
          for (final token in words) {
            if (Utterance.isCovered(token, dueSpans)) continue;
            titleTokens.add(token);
            spans.add(
              CommandSpan(
                token.span.start,
                token.span.end,
                CommandSpanKind.title,
              ),
            );
          }
          break;
        }
      }
    }
    if (!command.implicit) {
      final marker = _detectIntent(utterance);
      final tail = _commandTail(utterance);
      final verbs = <UtteranceToken>[];
      if (marker.found && marker.index >= 0) {
        for (var i = marker.index;
            i < marker.index + marker.length && i < tokens.length;
            i++) {
          verbs.add(tokens[i]);
        }
        final next = marker.index + marker.length;
        if (next < tokens.length && _objectNouns.contains(tokens[next].text)) {
          verbs.add(tokens[next]);
        }
      } else if (tail != null && command.intent == CommandIntent.createTask) {
        verbs.addAll(tokens.skip(tail));
      }
      for (final token in verbs) {
        if (titleTokens.contains(token)) continue;
        if (Utterance.isCovered(token, dueSpans)) continue;
        spans.add(
          CommandSpan(token.span.start, token.span.end, CommandSpanKind.verb),
        );
      }
    }
    final text = utterance.original;
    return CommandSpans.merge(
      CommandSpans.normalize(spans, text.length),
      text,
    );
  }

  /// Сомнения разбора текущей фразы ([ParsedCommand.certainty]): их
  /// копит [_createTitle], а [parseUtterance] вычитает из уверенности.
  double _doubt = 0;

  /// Создание из текущей фразы — просьба напомнить.
  bool _reminder = false;

  /// Разбор уже проанализированного сообщения: так коннектор не строит
  /// [Utterance] второй раз.
  ParsedCommand parseUtterance(Utterance utterance) {
    final savedDoubt = _doubt;
    final savedReminder = _reminder;
    _doubt = 0;
    _reminder = false;
    try {
      return _finish(utterance, _parseUtterance(utterance));
    } finally {
      _doubt = savedDoubt;
      _reminder = savedReminder;
    }
  }

  /// Последний шаг создания: вопрос — не задача («напомни, какая формула
  /// суммы»), слова-шум распознавателя убраны, имена с заглавной
  /// («Написать Андрею»), уверенность — по тому, сколько пришлось угадать.
  ParsedCommand _finish(Utterance utterance, ParsedCommand command) {
    if (command.intent != CommandIntent.createTask) return command;
    final quoted = utterance.quotedTitles.isNotEmpty;
    var title = command.title;
    var certainty = 1.0 - _doubt;
    if (!quoted) {
      // «Напомни, какой сегодня день недели» — вопрос к часам устройства.
      if (ClockQuestion.of(utterance) != null) {
        return const ParsedCommand(intent: CommandIntent.unknown);
      }
      if (_askToAssistant(utterance)) {
        return const ParsedCommand(intent: CommandIntent.unknown);
      }
      final question = QuestionPhrases.detect(utterance);
      if (question != null &&
          (question.opener != null || utterance.isQuestion) &&
          !_infinitiveBefore(utterance, question.whIndex)) {
        // «Напомни завтра в 9, какая формула суммы»: со сроком это может
        // быть и дело «узнать». Без него — вопрос, на который помощник
        // не ответит: задачей он не становится. Срок внутри вопроса
        // («напомни, какая погода завтра») — часть вопроса, а не срок.
        // «Напомни, какая погода завтра» — к «Погоде», не задача.
        if (question.remindOpener &&
            utterance.words.any((String w) => w.startsWith('погод'))) {
          return const ParsedCommand(intent: CommandIntent.unknown);
        }
        final whStart = utterance.tokens[question.whIndex].span.start;
        final dueOutside =
            utterance.due.spans.any((CharSpan span) => span.start < whStart);
        if (question.kind != QuestionKind.info ||
            !question.remindOpener ||
            command.dueAt == null ||
            !dueOutside ||
            title == null) {
          return const ParsedCommand(intent: CommandIntent.unknown);
        }
        title = 'Узнать, ${_lowerFirst(title)}';
        certainty -= 0.5;
      }
    }
    final junk = utterance.tokens
        .where((UtteranceToken t) => SpeechNoise.isJunk(t.text))
        .length;
    certainty -= 0.25 * junk;
    if (title != null && !quoted) {
      // Обёртки просьбы и местоимения (ADR-033): «Нужно позвонить» →
      // «Позвонить», «напомни про них» — без названия.
      title = TaskRephrase.title(_withoutJunk(title));
      if (title.isEmpty) {
        title = null;
      } else {
        title = PersonNames.capitalizeIn(Utterance.capitalize(title));
        if (_looksUnparsed(title)) certainty -= 0.4;
      }
    }
    if (certainty < 0) certainty = 0;
    return ParsedCommand(
      intent: command.intent,
      title: title,
      targetQuery: command.targetQuery,
      dueAt: command.dueAt,
      duePrecision: command.duePrecision,
      dueIssue: command.dueIssue,
      titleIssue: command.titleIssue,
      projects: command.projects,
      implicit: command.implicit,
      pastTense: command.pastTense,
      selection: command.selection,
      shift: command.shift,
      exclude: command.exclude,
      certainty: certainty,
      reminder: _reminder,
    );
  }

  /// Перед вопросительным словом — инфинитив: «напомни спросить, какая
  /// формула», «добавь узнать, где ключи» — это дело, а не вопрос.
  static bool _infinitiveBefore(Utterance utterance, int whIndex) {
    for (var i = 0; i < whIndex; i++) {
      final word = utterance.tokens[i].text;
      if (DueParser.isInfinitive(word) && word != 'напомнить') return true;
    }
    return false;
  }

  static String _lowerFirst(String text) =>
      text.isEmpty ? text : '${text[0].toLowerCase()}${text.substring(1)}';

  static final RegExp _spaces = RegExp(r'\s+');

  /// Название без слов-шума распознавателя: «Зэд купить хлеб» → «купить
  /// хлеб».
  static String _withoutJunk(String title) {
    final words = title.split(_spaces);
    String bare(String word) =>
        DueParser.normalizeChars(word).replaceAll(RegExp('[^а-я]'), '');
    final kept = <String>[
      for (var i = 0; i < words.length; i++)
        if (!(i == 0
            ? SpeechNoise.isLeadNoise(bare(words[i]))
            : SpeechNoise.isJunk(bare(words[i]))))
          words[i],
    ];
    if (kept.length == words.length) return title;
    return kept.join(' ').trim();
  }

  /// Слова, с которых название не начинается, если фраза понята верно:
  /// «На утро написать …», «Чтобы я …», «С утра …».
  static const Set<String> _badTitleStarts = <String>{
    'на',
    'с',
    'со',
    'в',
    'во',
    'к',
    'чтобы',
    'что',
    'я',
    'мы',
    'это',
  };

  /// Слова времени, которые остались в названии неразобранными.
  static const Set<String> _timeLeftovers = <String>{
    'утро',
    'утра',
    'утром',
    'вечер',
    'вечера',
    'вечером',
    'обед',
    'пораньше',
    'часов',
    'девять',
    'восемь',
    'десять',
    'семь',
    'полдевятого',
  };

  static bool _looksUnparsed(String title) {
    final words = <String>[
      for (final word in DueParser.normalizeChars(title).split(_spaces))
        if (word.isNotEmpty) word,
    ];
    if (words.isEmpty) return false;
    return _badTitleStarts.contains(words.first) ||
        words.any(_timeLeftovers.contains);
  }

  ParsedCommand _parseUtterance(Utterance utterance) {
    final words = utterance.words;
    if (words.isEmpty && utterance.quotedTitles.isEmpty) {
      return const ParsedCommand(intent: CommandIntent.unknown);
    }

    final bulk = const BulkParser().parse(utterance, _clock.now());
    // «Всё, закрой», «всё — перенеси на пятницу»: «всё» — конец реплики, а
    // команда — о задаче из разговора. Разбираем фразу без него.
    if (bulk == null) {
      final rest = BulkParser.withoutDiscourse(utterance);
      if (rest != null) {
        final command =
            parseUtterance(Utterance.analyze(rest, now: _clock.now()));
        if (command.intent == CommandIntent.completeTask ||
            command.intent == CommandIntent.rescheduleTask) {
          return command;
        }
      }
    }
    if (bulk != null) {
      return ParsedCommand(
        intent: bulk.action == BulkAction.reschedule
            ? CommandIntent.rescheduleMany
            : CommandIntent.completeMany,
        dueAt: bulk.dueAt,
        duePrecision: bulk.dueAt == null ? null : bulk.precision,
        dueIssue: bulk.issue,
        projects: bulk.selection.tags,
        selection: bulk.selection,
        shift: bulk.shift,
        exclude: bulk.exclude,
      );
    }
    if (_isListQuery(utterance)) {
      return const ParsedCommand(intent: CommandIntent.listTasks);
    }
    final marker = _detectIntent(utterance);
    // «Надо сходить к врачу на этой неделе, добавь», «…, не забудь»:
    // команда в конце относится ко всему, что перед ней.
    final tail = _commandTail(utterance);
    if (tail != null &&
        (!marker.found || marker.index >= tail) &&
        _tailNamesTask(utterance, tail)) {
      final command = _tailCreate(utterance, tail);
      if (command != null) return command;
    }
    if (!marker.found) {
      return _implicitCreate(utterance) ??
          _implicitComplete(utterance) ??
          const ParsedCommand(intent: CommandIntent.unknown);
    }
    final intent = marker.intent;
    final titleIssue = utterance.unbalancedQuotes
        ? TitleIssue.unbalancedQuotes
        : utterance.quotedTitles.length > 1
            ? TitleIssue.multipleTitles
            : TitleIssue.none;
    final quoted =
        titleIssue == TitleIssue.none && utterance.quotedTitles.isNotEmpty
            ? utterance.quotedTitles.single.text
            : null;
    final hasQuotes =
        utterance.quotedTitles.isNotEmpty || utterance.unbalancedQuotes;
    final due = utterance.due;

    // «Перенеси её на завтра в» — шаблон из «+», где время не дописали:
    // висящий предлог — не название и не цель, а вопрос «Во сколько?».
    final dangling = _danglingPreposition(utterance);
    final dueIssue = dangling != null &&
            due.issue == DueIssue.none &&
            due.dueAt != null &&
            due.precision == DuePrecision.date
        ? DueIssue.missingTime
        : due.issue;

    switch (intent) {
      case CommandIntent.createTask:
        return ParsedCommand(
          intent: intent,
          title: hasQuotes
              ? quoted
              : _createTitle(
                  utterance,
                  marker.index,
                  marker.length,
                  // Без срока «на» в конце может быть частью названия.
                  dangling: due.dueAt == null ? null : dangling,
                ),
          dueAt: due.dueAt,
          duePrecision: due.precision,
          dueIssue: dueIssue,
          titleIssue: titleIssue,
          projects: <String>[
            for (final tag in utterance.hashtags) tag.name,
          ],
        );
      case CommandIntent.rescheduleTask:
        if (!hasQuotes && _quantifiedTarget(utterance, marker.index)) {
          return const ParsedCommand(intent: CommandIntent.unknown);
        }
        return ParsedCommand(
          intent: intent,
          title: quoted,
          targetQuery: hasQuotes
              ? null
              : _targetQuery(
                  utterance,
                  marker.index,
                  _rescheduleFiller,
                  dangling: dangling,
                ),
          dueAt: due.dueAt,
          duePrecision: due.precision,
          dueIssue: dueIssue,
          titleIssue: titleIssue,
        );
      case CommandIntent.completeTask:
        if (!hasQuotes &&
            !isPastVerb(utterance.tokens[marker.index].text) &&
            _quantifiedTarget(utterance, marker.index)) {
          return const ParsedCommand(intent: CommandIntent.unknown);
        }
        final targetQuery = hasQuotes
            ? null
            : _targetQuery(utterance, marker.index, _completeFiller);
        return ParsedCommand(
          intent: intent,
          title: quoted,
          targetQuery: targetQuery,
          titleIssue: titleIssue,
          // «Выполнил отчёт» — сообщение о сделанном: задача по словам
          // отмечается только после подтверждения.
          pastTense: targetQuery != null &&
              isPastVerb(utterance.tokens[marker.index].text),
        );
      case CommandIntent.listTasks:
      case CommandIntent.rescheduleMany:
      case CommandIntent.completeMany:
      case CommandIntent.unknown:
        return ParsedCommand(intent: intent);
    }
  }

  /// «Напомни, как тебя зовут?», «напомни, что ты умеешь», «можешь
  /// напомнить, что у меня на завтра?» — вопрос к помощнику о нём самом
  /// или о планах, а не дело «Ты умеешь» или «У меня» на завтра. Сразу
  /// после «напомни» (и вежливых слов, срока) — вопросительное слово или
  /// «что», а за ним «ты/тебя/вы…» или «у меня/у нас» с «?».
  /// «Напомни, что ты обещал позвонить» — тоже вопрос: дела «Ты обещал»
  /// нет. «Можешь напомнить завтра, что необходимо оплатить счёт» — дело.
  bool _askToAssistant(Utterance utterance) {
    final tokens = utterance.tokens;
    var i = tokens.indexWhere(
      (UtteranceToken t) => _remindAsks.contains(t.text),
    );
    if (i < 0) return false;
    i++;
    while (i < tokens.length &&
        (_askSkip.contains(tokens[i].text) ||
            Utterance.isCovered(tokens[i], utterance.due.spans))) {
      i++;
    }
    if (i + 1 >= tokens.length) return false;
    final word = tokens[i].text;
    if (word != 'что' && !QuestionPhrases.isWhWord(word)) return false;
    final next = tokens[i + 1].text;
    if (_secondPerson.contains(next)) return true;
    return word == 'что' &&
        utterance.isQuestion &&
        next == 'у' &&
        i + 2 < tokens.length &&
        (tokens[i + 2].text == 'меня' || tokens[i + 2].text == 'нас');
  }

  static const Set<String> _remindAsks = <String>{
    'напомни',
    'напомните',
    'напомнить',
    'напомнишь',
  };

  static const Set<String> _askSkip = <String>{
    'мне',
    'нам',
    'пожалуйста',
    'плиз',
    'еще',
    'раз',
    'ка',
  };

  static const Set<String> _secondPerson = <String>{
    'ты',
    'тебя',
    'тебе',
    'тобой',
    'вы',
    'вас',
    'вам',
  };

  /// «Перенеси все просроченные», «закрой всё по отчёту»: сразу после
  /// глагола (и «задачи») — «все». Массовой команды [BulkParser] в этой
  /// фразе не нашёл, а одна задача по словам «все просроченные» — не то,
  /// о чём просили: лучше не понять, чем перенести или закрыть не то.
  /// «Всё готово по отчёту», «уже всё сделала» — «всё» до глагола, здесь
  /// не смотрится.
  bool _quantifiedTarget(Utterance utterance, int markerIndex) {
    final tokens = utterance.tokens;
    var i = markerIndex + 1;
    while (i < tokens.length && _beforeQuantifier.contains(tokens[i].text)) {
      i++;
    }
    return i < tokens.length && _quantifierWords.contains(tokens[i].text);
  }

  static const Set<String> _beforeQuantifier = <String>{
    'ка',
    'мне',
    'пожалуйста',
    'сразу',
    'задачи',
    'задачу',
    'дела',
  };

  static const Set<String> _quantifierWords = <String>{
    'все',
    'всех',
    'каждую',
    'каждый',
    'каждое',
    'любые',
  };

  /// Совместимая обёртка: только успешно разобранный срок.
  (DateTime, DuePrecision)? parseDue(String text) {
    final result = parseDueDetailed(text);
    final due = result.dueAt;
    final precision = result.precision;
    if (due == null || precision == null || result.issue != DueIssue.none) {
      return null;
    }
    return (due, precision);
  }

  /// Разбирает срок в тексте без названия в кавычках.
  DueParseResult parseDueDetailed(String text) =>
      const DueParser().parse(text, _clock.now());

  // ------------------------------------------------------------- название

  /// Слова, которые могут стоять между глаголом и названием: «добавь мне
  /// задачу», «запиши, пожалуйста, в список».
  static const Set<String> _politeWords = <String>{
    'пожалуйста',
    'пожалуйсто',
    'плиз',
    'пж',
    'пжлст',
  };

  static const Set<String> _addressees = <String>{'мне', 'нам'};

  static const Set<String> _objectNouns = <String>{
    'задачу',
    'задача',
    'задачи',
    'напоминание',
    'напоминалку',
    'напоминалка',
    'напоминалочку',
    'дело',
  };

  /// Существительные-напоминания: с ними «что»/«чтобы» после команды —
  /// союз, как после «напомни» («поставь напоминание, чтобы я …»).
  static const Set<String> _reminderNouns = <String>{
    'напоминание',
    'напоминалку',
    'напоминалка',
    'напоминалочку',
  };

  /// «Создай новую задачу», «добавь новое напоминание».
  static const Set<String> _newAdjectives = <String>{
    'новую',
    'новое',
    'новый',
    'новая',
  };

  /// Что может стоять после «в список»: «в список дел».
  static const Set<String> _listNouns = <String>{'дел', 'задач'};

  /// Разговорное вступление перед командой: «Слушай, добавь…», «Можешь
  /// добавить…», «Нет, перенеси…». Убирается только перед маркером.
  static const Set<String> _leadIns = <String>{
    ..._politeWords,
    'слушай',
    'слушайте',
    'можешь',
    'можете',
    'мог',
    'могла',
    'могли',
    'бы',
    'ты',
    'вы',
    'а',
    'и',
    'ну',
    'так',
    'давай',
    'давайте',
    'эй',
    'ок',
    'окей',
    'ладно',
    'хорошо',
    'тогда',
    'еще',
    'также',
    'нет',
    'не',
    // «Нужно поставить задачу …», «мне надо добавить …».
    'мне',
    'надо',
    'нужно',
  };

  static const Set<String> _remindVerbs = <String>{'напомни', 'напомните'};

  static const Set<String> _remindConjunctions = <String>{'что', 'чтобы'};

  /// «Запиши меня к врачу» — просьба записаться, а не задача «Меня к врачу».
  static const Set<String> _signUpVerbs = <String>{
    'запиши',
    'запишите',
    'записать',
  };

  static const Set<String> _signUpObjects = <String>{'меня', 'нас'};

  static const Set<String> _signUpPrepositions = <String>{
    'к',
    'ко',
    'на',
    'в',
    'во',
  };

  /// Название новой задачи без кавычек или `null`, если ничего не осталось.
  /// Предлог последним словом, не входящий в срок: «… на завтра в»,
  /// «перенеси её на». Время или день не дописали.
  static UtteranceToken? _danglingPreposition(Utterance utterance) {
    final tokens = utterance.tokens;
    if (tokens.length < 2) return null;
    final last = tokens.last;
    if (!_danglingWords.contains(last.text)) return null;
    if (Utterance.isCovered(last, utterance.due.spans)) return null;
    return last;
  }

  static const Set<String> _danglingWords = <String>{
    'в',
    'во',
    'на',
    'к',
    'ко',
    'до',
    'около',
  };

  String? _createTitle(
    Utterance utterance,
    int markerIndex,
    int length, {
    UtteranceToken? dangling,
  }) {
    final tokens = utterance.tokens;
    final dueSpans = utterance.due.spans;
    final remove = <CharSpan>[
      if (dangling != null) dangling.span,
      ...dueSpans,
      ..._tailSpans(utterance, markerIndex),
      ..._leadInSpans(utterance, markerIndex),
    ];
    for (var i = markerIndex; i < markerIndex + length; i++) {
      remove.add(tokens[i].span);
    }

    // Продолжение маркера: «мне», «пожалуйста», «задачу», «в список»,
    // а после «напомни» — «что»/«чтобы». Срок между ними пропускается:
    // «Добавь на завтра задачу купить хлеб».
    final markerWord = tokens[markerIndex].text;
    var remind = _remindVerbs.contains(markerWord) ||
        markerWord == 'напомнить' ||
        _reminderNouns.contains(markerWord);
    // «Напоминание на вечер купить хлеб»: команда — одно существительное.
    if (_reminderNouns.contains(markerWord)) _doubt += 0.2;
    var nounTaken = length > 1 || _reminderNouns.contains(markerWord);
    var conjunctionTaken = false;
    // «…, чтобы я написал Андрею»: глагол прошедшего времени станет
    // инфинитивом названия.
    UtteranceToken? pastVerb;
    var i = markerIndex + length;
    while (i < tokens.length) {
      final token = tokens[i];
      final word = token.text;
      if (Utterance.isCovered(token, dueSpans)) {
        i++;
        continue;
      }
      if (_politeWords.contains(word) ||
          _addressees.contains(word) ||
          SpeechNoise.isJunk(word)) {
        remove.add(token.span);
        i++;
        continue;
      }
      if (!nounTaken && _objectNouns.contains(word)) {
        remove.add(token.span);
        nounTaken = true;
        if (_reminderNouns.contains(word)) remind = true;
        i++;
        continue;
      }
      if (!nounTaken &&
          _newAdjectives.contains(word) &&
          i + 1 < tokens.length &&
          _objectNouns.contains(tokens[i + 1].text)) {
        remove
          ..add(token.span)
          ..add(tokens[i + 1].span);
        nounTaken = true;
        i += 2;
        continue;
      }
      if (!nounTaken &&
          word == 'в' &&
          i + 1 < tokens.length &&
          tokens[i + 1].text == 'список') {
        remove
          ..add(token.span)
          ..add(tokens[i + 1].span);
        nounTaken = true;
        i += 2;
        if (i < tokens.length && _listNouns.contains(tokens[i].text)) {
          remove.add(tokens[i].span);
          i++;
        }
        continue;
      }
      // «напомни не забудь купить хлеб»: «не забудь» после «напомни»
      // повторяет просьбу. После «добавь» это часть названия: «добавь не
      // забыть полить цветы» → «Не забыть полить цветы».
      if (remind &&
          word == 'не' &&
          i + 1 < tokens.length &&
          _dontForget.contains(tokens[i + 1].text)) {
        remove
          ..add(token.span)
          ..add(tokens[i + 1].span);
        i += 2;
        continue;
      }
      if (remind && !conjunctionTaken && _remindConjunctions.contains(word)) {
        remove.add(token.span);
        conjunctionTaken = true;
        i++;
        if (word == 'чтобы') {
          final (next, verb) = _subjectClause(utterance, i, remove);
          i = next;
          pastVerb = verb;
        }
        continue;
      }
      // «Напомни о том, что …», «напомни про то, что …».
      if (remind &&
          !conjunctionTaken &&
          i + 2 < tokens.length &&
          ((word == 'о' && tokens[i + 1].text == 'том') ||
              (word == 'про' && tokens[i + 1].text == 'то')) &&
          _remindConjunctions.contains(tokens[i + 2].text)) {
        remove
          ..add(token.span)
          ..add(tokens[i + 1].span)
          ..add(tokens[i + 2].span);
        conjunctionTaken = true;
        i += 3;
        continue;
      }
      break;
    }

    // «Запиши меня к врачу на пятницу» → «Записаться к врачу».
    final signUp = _signUpVerbs.contains(tokens[markerIndex].text) &&
        i + 1 < tokens.length &&
        _signUpObjects.contains(tokens[i].text) &&
        _signUpPrepositions.contains(tokens[i + 1].text);
    if (signUp) remove.add(tokens[i].span);

    _trimEdgeWords(utterance, remove, _politeWords);
    if (remind) _reminder = true;
    var text = _titleText(utterance, remove);
    if (text.isEmpty) return null;
    if (signUp) return 'Записаться $text';
    if (pastVerb != null) {
      final infinitive = VerbForms.toInfinitive(pastVerb.text);
      final first = _spaces.firstMatch(text);
      final head = first == null ? text : text.substring(0, first.start);
      if (infinitive != null &&
          DueParser.normalizeChars(head) == pastVerb.text) {
        text = _joinedInfinitives(
          '$infinitive${text.substring(head.length)}',
        );
        _doubt += 0.1;
      }
      return Utterance.capitalize(text);
    }
    return Utterance.capitalize(NounForms.nominative(text));
  }

  static const Set<String> _subjectPronouns = <String>{'я', 'мы'};

  /// После «чтобы»: «я», «я не забыл», затем глагол прошедшего времени —
  /// «чтобы я написал Андрею», «чтобы я не забыл купить молоко». Слова
  /// «я» и «не забыл» уходят из названия; глагол прошедшего времени
  /// возвращается, чтобы стать инфинитивом. Перед инфинитивом он лишний
  /// («чтобы я обещал позвонить» → «Позвонить») и тоже уходит.
  (int, UtteranceToken?) _subjectClause(
    Utterance utterance,
    int start,
    List<CharSpan> remove,
  ) {
    final tokens = utterance.tokens;
    final due = utterance.due.spans;
    var i = start;
    int skipDue(int k) {
      while (k < tokens.length && Utterance.isCovered(tokens[k], due)) {
        k++;
      }
      return k;
    }

    i = skipDue(i);
    var subject = false;
    if (i < tokens.length && _subjectPronouns.contains(tokens[i].text)) {
      remove.add(tokens[i].span);
      subject = true;
      i = skipDue(i + 1);
    }
    if (i + 1 < tokens.length &&
        tokens[i].text == 'не' &&
        _forgotForms.contains(tokens[i + 1].text)) {
      remove
        ..add(tokens[i].span)
        ..add(tokens[i + 1].span);
      return (skipDue(i + 2), null);
    }
    if (!subject || i >= tokens.length) return (i, null);
    final verb = tokens[i];
    if (!VerbForms.isPastVerb(verb.text) &&
        VerbForms.toInfinitive(verb.text) == null) {
      return (i, null);
    }
    final next = skipDue(i + 1);
    if (next < tokens.length &&
        DueParser.isInfinitive(tokens[next].text) &&
        !_keptBeforeInfinitive.contains(verb.text)) {
      remove.add(verb.span);
      return (next, null);
    }
    return (i, verb);
  }

  /// Глаголы, которые перед инфинитивом — тоже дело: «чтобы я лёг спать»
  /// → «Лечь спать», «чтобы я пошёл гулять» → «Пойти гулять».
  static const Set<String> _keptBeforeInfinitive = <String>{
    'лег',
    'легла',
    'легли',
    'пошел',
    'пошла',
    'пошли',
    'поехал',
    'поехала',
    'поехали',
    'сел',
    'села',
    'сели',
    'сходил',
    'сходила',
    'съездил',
    'съездила',
    'вышел',
    'вышла',
  };

  /// «Сходить в магазин и купил хлеб» → «… и купить хлеб»: глагол
  /// прошедшего времени после «и» — второе дело той же фразы.
  static String _joinedInfinitives(String text) {
    final words = text.split(' ');
    for (var k = 1; k < words.length; k++) {
      if (words[k - 1].toLowerCase() != 'и') continue;
      final bare = DueParser.normalizeChars(words[k]);
      if (!VerbForms.isPastVerb(bare)) continue;
      final infinitive = VerbForms.toInfinitive(bare);
      if (infinitive != null) words[k] = infinitive;
    }
    return words.join(' ');
  }

  static const Set<String> _forgotForms = <String>{
    'забыл',
    'забыла',
    'забыли',
  };

  /// Вступление перед маркером: приветствие ([SocialPrefix]), слова
  /// из [_leadIns] и срок с самого начала фразы до первого другого слова.
  List<CharSpan> _leadInSpans(Utterance utterance, int markerIndex) {
    final result = <CharSpan>[];
    var start = SocialPrefix.length(utterance);
    if (start > markerIndex) start = 0;
    for (var i = 0; i < start; i++) {
      result.add(utterance.tokens[i].span);
    }
    for (var i = start; i < markerIndex; i++) {
      final token = utterance.tokens[i];
      if (Utterance.isCovered(token, utterance.due.spans)) continue;
      if (!_leadIns.contains(token.text) &&
          !SpeechNoise.isLeadFiller(token.text)) {
        break;
      }
      result.add(token.span);
    }
    return result;
  }

  /// Убирает слова из [words] с краёв ещё не удалённого текста.
  void _trimEdgeWords(
    Utterance utterance,
    List<CharSpan> remove,
    Set<String> words,
  ) {
    var rest = utterance.tokensOutside(remove);
    while (rest.isNotEmpty && words.contains(rest.first.text)) {
      remove.add(rest.first.span);
      rest = rest.sublist(1);
    }
    while (rest.isNotEmpty && words.contains(rest.last.text)) {
      remove.add(rest.last.span);
      rest = rest.sublist(0, rest.length - 1);
    }
  }

  // ------------------------------------------------ команда в конце фразы

  /// Глаголы команды в конце фразы после запятой или тире: «…, добавь»,
  /// «…, запиши», «…, поставь плз».
  static const Set<String> _tailVerbs = <String>{
    'добавь',
    'добавьте',
    'запиши',
    'запишите',
    'поставь',
    'поставьте',
    'создай',
    'создайте',
  };

  /// Слова после глагола в конце: «добавь это», «запиши мне», «поставь плз».
  static const Set<String> _tailExtras = <String>{
    ..._politeWords,
    ..._addressees,
    'это',
    'его',
    'ее',
    'тоже',
    'туда',
    'плз',
  };

  /// Глаголы создания в инфинитиве в начале фразы перед командой в конце:
  /// «я хочу напомнить прозвонить по страховке, поставь».
  static const Set<String> _createInfinitives = <String>{
    'напомнить',
    'добавить',
    'записать',
    'поставить',
    'создать',
    'завести',
  };

  /// Номер первого слова команды в конце фразы или `null`. Перед ней —
  /// запятая или тире и хотя бы одно слово.
  int? _commandTail(Utterance utterance) {
    final tokens = utterance.tokens;
    if (tokens.length < 2 || utterance.isQuestion) return null;
    var end = tokens.length;
    while (end > 0 && _tailExtras.contains(tokens[end - 1].text)) {
      end--;
    }
    if (end == 0) return null;
    int start;
    if (_tailVerbs.contains(tokens[end - 1].text)) {
      start = end - 1;
    } else if (_dontForget.contains(tokens[end - 1].text) &&
        end >= 2 &&
        tokens[end - 2].text == 'не') {
      start = end - 2;
    } else {
      return null;
    }
    if (start == 0) return null;
    final gap = utterance.analysisText
        .substring(tokens[start - 1].span.end, tokens[start].span.start);
    if (!gap.contains(',') && !gap.contains('—') && !gap.contains('-')) {
      return null;
    }
    return start;
  }

  /// «Не забудь» и «поставь» в конце бывают и не командой: «всё понятно,
  /// не забудь», «я забыл, не забудь», «чайник, поставь». С ними фраза до
  /// хвоста — задача, только если в ней есть дело: инфинитив («купить
  /// хлеб, не забудь»), срок или название в кавычках. «Добавь», «запиши»,
  /// «создай» в конце — команда всегда.
  bool _tailNamesTask(Utterance utterance, int tail) {
    final tokens = utterance.tokens;
    if (_strictTailVerbs.contains(tokens[tail].text)) return true;
    return utterance.due.spans.isNotEmpty ||
        utterance.quotedTitles.isNotEmpty ||
        utterance.unbalancedQuotes ||
        tokens
            .take(tail)
            .any((UtteranceToken t) => DueParser.isInfinitive(t.text));
  }

  /// Глаголы в конце, которые сами по себе значат «создай задачу»: с ними
  /// фраза до хвоста — задача без других признаков дела.
  static const Set<String> _strictTailVerbs = <String>{
    'добавь',
    'добавьте',
    'запиши',
    'запишите',
    'создай',
    'создайте',
  };

  /// Команда в конце после другой команды («перенеси на завтра, не
  /// забудь», «добавь купить хлеб, запиши») — не часть названия и цели.
  List<CharSpan> _tailSpans(Utterance utterance, int markerIndex) {
    final tail = _commandTail(utterance);
    if (tail == null || tail <= markerIndex) return const <CharSpan>[];
    return <CharSpan>[
      for (final token in utterance.tokens.skip(tail)) token.span,
    ];
  }

  /// Создание по команде в конце: название — фраза до неё без вступления
  /// («надо», «мне надо», «я хочу напомнить»), срока и меток.
  ParsedCommand? _tailCreate(Utterance utterance, int tail) {
    final tokens = utterance.tokens;
    final due = utterance.due;
    final remove = <CharSpan>[
      ...due.spans,
      for (final token in tokens.skip(tail)) token.span,
    ];
    var i = SocialPrefix.length(utterance);
    if (i > tail) i = 0;
    for (var k = 0; k < i; k++) {
      remove.add(tokens[k].span);
    }
    var remind = false;
    while (i < tail) {
      final token = tokens[i];
      if (Utterance.isCovered(token, due.spans)) {
        i++;
        continue;
      }
      if (_implicitLeadIns.contains(token.text) ||
          token.text == 'я' ||
          token.text == 'мы') {
        remove.add(token.span);
        i++;
        continue;
      }
      if (token.text == 'не' &&
          i + 1 < tail &&
          _dontForget.contains(tokens[i + 1].text)) {
        remove
          ..add(token.span)
          ..add(tokens[i + 1].span);
        i += 2;
        continue;
      }
      if (_createInfinitives.contains(token.text)) {
        remind = token.text == 'напомнить';
        remove.add(token.span);
        i++;
        if (remind &&
            i < tail &&
            _remindConjunctions.contains(tokens[i].text)) {
          remove.add(tokens[i].span);
          i++;
        }
      }
      break;
    }
    final titleIssue = utterance.unbalancedQuotes
        ? TitleIssue.unbalancedQuotes
        : utterance.quotedTitles.length > 1
            ? TitleIssue.multipleTitles
            : TitleIssue.none;
    final hasQuotes =
        utterance.quotedTitles.isNotEmpty || utterance.unbalancedQuotes;
    String? title;
    if (hasQuotes) {
      title = titleIssue == TitleIssue.none
          ? utterance.quotedTitles.single.text
          : null;
    } else {
      _trimEdgeWords(utterance, remove, _politeWords);
      final text = _titleText(utterance, remove);
      if (text.isEmpty) return null;
      title = Utterance.capitalize(
        NounForms.nominative(text, allowPreposition: remind),
      );
    }
    return ParsedCommand(
      intent: CommandIntent.createTask,
      title: title,
      dueAt: due.dueAt,
      duePrecision: due.precision,
      dueIssue: due.issue,
      titleIssue: titleIssue,
      projects: <String>[for (final tag in utterance.hashtags) tag.name],
    );
  }

  // ------------------------------------------------- команды без маркера

  /// Вступление перед действием без команды: «надо купить хлеб», «мне нужно
  /// позвонить», «не забыть оплатить». Здесь «не» — часть «не забыть»,
  /// а не отрицание.
  static const Set<String> _implicitLeadIns = <String>{
    ..._politeWords,
    'надо',
    'нужно',
    'необходимо',
    'хочу',
    'хотел',
    'хотела',
    'бы',
    'мне',
    'нам',
    'будет',
    'еще',
    'также',
    'а',
    'и',
    'ну',
    'так',
    'вот',
    'ладно',
    'потом',
    'тоже',
    'кстати',
  };

  /// Вторые слова после «не» во вступлении: «не забыть», «не забудь».
  static const Set<String> _dontForget = <String>{
    'забыть',
    'забудь',
    'забудьте',
  };

  /// Инфинитивы, которые не становятся задачей без маркера.
  ///
  /// Состояние и модальность: «быть или не быть», «жить стало веселее»,
  /// «знать бы заранее» — рассуждение, а не дело. Команды самому
  /// помощнику: «показать список», «удалить задачу хлеб», «отметить хлеб» —
  /// это просьба, которую он не понял, а не новая задача «Показать список».
  /// Такую задачу можно добавить явно: «Добавь задачу отметить юбилей».
  static const Set<String> _notImplicitVerbs = <String>{
    'быть',
    'бывать',
    'жить',
    'стать',
    'хотеть',
    'хотеться',
    'мочь',
    'знать',
    'видеть',
    'спать',
    'казаться',
    'стоить',
    'показать',
    'показывать',
    'вывести',
    'выводить',
    'открыть',
    'удалить',
    'удалять',
    'стереть',
    'очистить',
    'отменить',
    'отменять',
    'найти',
    'искать',
    'отметить',
    'отмечать',
    'завершить',
    'закрыть',
  };

  /// Слова после глагола, с которыми фраза — не поручение: «купить хлеб
  /// не надо», «купить ли хлеб», «посмотреть кино было бы неплохо»,
  /// «знать надо».
  static const Set<String> _notImplicitAfterVerb = <String>{
    'не',
    'ни',
    'ли',
    'бы',
    'б',
    'было',
    'стало',
    'надо',
    'нужно',
    'хочется',
    'можно',
    'нельзя',
  };

  /// Слова о самом помощнике: «показать задачи», «вывести список» —
  /// команды, которые он не понял, а не задача.
  static bool _isAssistantNoun(String word) =>
      word.startsWith('задач') ||
      word.startsWith('списк') ||
      word == 'список' ||
      word.startsWith('напоминани');

  /// Глаголы поиска, после которых «где» или «сколько» — вопрос
  /// к помощнику: «узнать, где лежит 64115», «посмотреть, сколько
  /// венских стульев». Такие вопросы забирают другие коннекторы.
  static const Set<String> _lookupVerbs = <String>{
    'узнать',
    'посмотреть',
    'проверить',
    'глянуть',
    'подсказать',
    'сказать',
    'уточнить',
  };

  static const Set<String> _lookupQuestions = <String>{'где', 'сколько'};

  /// Создание без маркера: после вступления и срока фраза начинается
  /// с инфинитива. «Купить хлеб?» — вопрос, не задача.
  ParsedCommand? _implicitCreate(Utterance utterance) {
    if (utterance.isQuestion || utterance.unbalancedQuotes) return null;
    if (utterance.quotedTitles.isNotEmpty) {
      return _implicitQuoted(utterance) ?? _infinitiveQuoted(utterance);
    }
    final due = utterance.due;
    final tokens = utterance.tokens;
    final remove = <CharSpan>[...due.spans];
    // «Привет, купить хлеб», «пока не забыл, купить хлеб».
    var i = SocialPrefix.length(utterance);
    for (var k = 0; k < i; k++) {
      remove.add(tokens[k].span);
    }
    var dontForget = false;
    while (i < tokens.length) {
      final token = tokens[i];
      if (Utterance.isCovered(token, due.spans)) {
        i++;
        continue;
      }
      // «хм, купить хлеб»: шум перед делом, как и в надиктованном.
      if (_implicitLeadIns.contains(token.text) ||
          SpeechNoise.isLeadNoise(token.text)) {
        remove.add(token.span);
        i++;
        continue;
      }
      if (token.text == 'не' &&
          i + 1 < tokens.length &&
          _dontForget.contains(tokens[i + 1].text)) {
        remove
          ..add(token.span)
          ..add(tokens[i + 1].span);
        dontForget = true;
        i += 2;
        continue;
      }
      // «после работы зайти в аптеку», «ночью проверить …»: время, которое
      // не срок, — часть названия, но не мешает инфинитиву после него.
      final adverbial = _untimedAdverbialLength(tokens, i);
      if (adverbial > 0) {
        i += adverbial;
        continue;
      }
      break;
    }
    if (i >= tokens.length) return null;
    // «не забыть про оплату подписки через пару дней» — как «напомни про
    // оплату подписки»: название — предмет в именительном падеже.
    if (dontForget && _aboutPrepositions.contains(tokens[i].text)) {
      return _dontForgetAbout(utterance, remove);
    }
    final firstPerson = _firstPersonCreate(utterance, i, remove);
    if (firstPerson != null) return firstPerson;
    final verb = tokens[i].text;
    if (!DueParser.isInfinitive(verb) || _notImplicitVerbs.contains(verb)) {
      return null;
    }
    final after = <UtteranceToken>[
      for (final token in tokens.skip(i + 1))
        if (!Utterance.isCovered(token, due.spans) &&
            !_politeWords.contains(token.text))
          token,
    ];
    if (after.any(
      (UtteranceToken t) =>
          _notImplicitAfterVerb.contains(t.text) || _isAssistantNoun(t.text),
    )) {
      return null;
    }
    if (_lookupVerbs.contains(verb) &&
        after.isNotEmpty &&
        _lookupQuestions.contains(after.first.text)) {
      return null;
    }
    // Одно слово «купить» — не задача; «постричься» и «позвонить завтра» —
    // задача: возвратный глагол сам себе дело, срок делает его поручением.
    final reflexive = verb.endsWith('ся') || verb.endsWith('сь');
    if (after.isEmpty && !reflexive && due.spans.isEmpty) return null;
    _trimEdgeWords(utterance, remove, _politeWords);
    final text = _titleText(utterance, remove);
    if (text.isEmpty) return null;
    return ParsedCommand(
      intent: CommandIntent.createTask,
      title: Utterance.capitalize(text),
      dueAt: due.dueAt,
      duePrecision: due.precision,
      dueIssue: due.issue,
      projects: <String>[for (final tag in utterance.hashtags) tag.name],
      implicit: true,
    );
  }

  /// «Завтра я позвоню маме», «я позвоню врачу завтра в 10 утра» — дело
  /// от первого лица со сроком: глагол будущего времени из закрытой
  /// таблицы ([FirstPersonVerbs], ADR-033). Это может быть и рассказ, а не
  /// просьба, поэтому задача только с вопросом «Понял так: … Создать?»
  /// (сомнение 0,5). Без срока («я позвоню маме»), с отрицанием, в чате
  /// задачи («я сделаю это завтра» — о ней же) и с местоимением вместо
  /// дела («я напишу тебе завтра», «я сделаю это») — не задача.
  ParsedCommand? _firstPersonCreate(
    Utterance utterance,
    int index,
    List<CharSpan> remove,
  ) {
    final tokens = utterance.tokens;
    if (index + 1 >= tokens.length) return null;
    final subject = tokens[index].text;
    if (subject != 'я' && subject != 'мы') return null;
    final verb = tokens[index + 1].text;
    if (!FirstPersonVerbs.contains(verb)) return null;
    final due = utterance.due;
    if (due.spans.isEmpty || utterance.chatTaskId != null) return null;
    final rest = <String>[
      for (final token in tokens.skip(index + 2))
        if (!Utterance.isCovered(token, due.spans)) token.text,
    ];
    if (rest.isEmpty ||
        utterance.words.contains('не') ||
        rest.any(
          (String w) => _firstPersonNotTask.contains(w) || _isAssistantNoun(w),
        )) {
      return null;
    }
    final text = _titleText(utterance, remove);
    if (text.isEmpty) return null;
    _doubt += 0.5;
    return ParsedCommand(
      intent: CommandIntent.createTask,
      title: Utterance.capitalize(text),
      dueAt: due.dueAt,
      duePrecision: due.precision,
      dueIssue: due.issue,
      projects: <String>[for (final tag in utterance.hashtags) tag.name],
      implicit: true,
    );
  }

  /// Местоимения после глагола от первого лица: дело не названо («я
  /// сделаю это завтра») или это разговор («я напишу тебе завтра»).
  static const Set<String> _firstPersonNotTask = <String>{
    'это',
    'этим',
    'ее',
    'его',
    'их',
    'ей',
    'ему',
    'им',
    'тебе',
    'тебя',
    'тобой',
    'вам',
    'вас',
    'вами',
  };

  /// Обстоятельства времени, которые не сроки ([DueParser]): «ночью»,
  /// «после работы», «перед сном». Перед инфинитивом без маркера они
  /// остаются в названии: «после работы зайти в аптеку».
  static const List<List<String>> _untimedAdverbials = <List<String>>[
    <String>['ночью'],
    <String>['после', 'работы'],
    <String>['после', 'учебы'],
    <String>['после', 'школы'],
    <String>['после', 'занятий'],
    <String>['после', 'пар'],
    <String>['после', 'тренировки'],
    <String>['перед', 'сном'],
    <String>['перед', 'работой'],
    <String>['перед', 'выходом'],
    <String>['по', 'дороге', 'домой'],
    <String>['по', 'дороге', 'на', 'работу'],
  ];

  /// Сколько слов с [index] занимает обстоятельство из
  /// [_untimedAdverbials]; 0 — его нет.
  static int _untimedAdverbialLength(List<UtteranceToken> tokens, int index) {
    var best = 0;
    for (final phrase in _untimedAdverbials) {
      if (phrase.length <= best || index + phrase.length > tokens.length) {
        continue;
      }
      var match = true;
      for (var k = 0; k < phrase.length; k++) {
        if (tokens[index + k].text != phrase[k]) {
          match = false;
          break;
        }
      }
      if (match) best = phrase.length;
    }
    return best;
  }

  /// «Не забыть про оплату подписки», «не забудь о встрече с юристом» —
  /// задача, если предмет после предлога удалось привести к именительному
  /// падежу ([NounForms]): «Оплата подписки». Иначе («не забудь про меня»,
  /// «не забудь о себе») это реплика, а не задача.
  ParsedCommand? _dontForgetAbout(Utterance utterance, List<CharSpan> remove) {
    final due = utterance.due;
    _trimEdgeWords(utterance, remove, _politeWords);
    final rest = utterance.tokensOutside(remove);
    if (rest.length < 2) return null;
    if (rest.any(
      (UtteranceToken t) =>
          _notImplicitAfterVerb.contains(t.text) ||
          _isAssistantNoun(t.text) ||
          _aboutRetractions.contains(t.text),
    )) {
      return null;
    }
    // «Не забыть про него», «про это», «про всё»: местоимение — не дело.
    if (rest
        .skip(1)
        .every((UtteranceToken t) => _aboutPronouns.contains(t.text))) {
      return null;
    }
    final text = _titleText(utterance, remove);
    final title = NounForms.nominative(text);
    final preposition = rest.first.original;
    if (title.toLowerCase().startsWith('${preposition.toLowerCase()} ')) {
      return null;
    }
    return ParsedCommand(
      intent: CommandIntent.createTask,
      title: Utterance.capitalize(title),
      dueAt: due.dueAt,
      duePrecision: due.precision,
      dueIssue: due.issue,
      projects: <String>[for (final tag in utterance.hashtags) tag.name],
      implicit: true,
    );
  }

  /// Местоимения после «не забыть про/о»: «про него», «о них», «про это»,
  /// «про всё это». Предмета в них нет — фраза не задача.
  static const Set<String> _aboutPronouns = <String>{
    'меня',
    'мне',
    'тебя',
    'тебе',
    'себя',
    'себе',
    'него',
    'нем',
    'нее',
    'ней',
    'них',
    'нас',
    'вас',
    'это',
    'этом',
    'то',
    'том',
    'все',
    'всем',
    'всех',
    'всего',
    'остальное',
    'остальном',
    'другое',
    'другом',
    'такое',
    'таком',
    'что',
    'чем',
    'кого',
    'ком',
    'нибудь',
  };

  /// Слова отказа или поворота внутри «не забыть про X, а вообще ладно»:
  /// после них X — уже не просьба.
  static const Set<String> _aboutRetractions = <String>{
    'а',
    'но',
    'ладно',
    'впрочем',
    'хотя',
    'однако',
  };

  /// Инфинитив перед названием в кавычках без команды: «хочу в субботу
  /// испечь «яблочный пирог с карамелью»», «надо купить «хлеб» завтра».
  /// Как и с маркером («добавь испечь «пирог»»), название — из кавычек как
  /// есть. Других слов, кроме вступления, срока и вежливых, быть не должно.
  ParsedCommand? _infinitiveQuoted(Utterance utterance) {
    if (utterance.quotedTitles.length != 1) return null;
    final due = utterance.due;
    final quote = utterance.quotedTitles.single;
    UtteranceToken? verb;
    var i = SocialPrefix.length(utterance);
    final tokens = utterance.tokens;
    while (i < tokens.length) {
      final token = tokens[i];
      if (Utterance.isCovered(token, due.spans) ||
          _politeWords.contains(token.text) ||
          (verb == null && _implicitLeadIns.contains(token.text))) {
        i++;
        continue;
      }
      if (verb == null &&
          token.text == 'не' &&
          i + 1 < tokens.length &&
          _dontForget.contains(tokens[i + 1].text)) {
        i += 2;
        continue;
      }
      if (verb != null) return null;
      verb = token;
      i++;
    }
    // «Нужно выполнить «Отчёт» завтра» — не новая задача «Отчёт»: глагол
    // завершения перед названием говорит о самой задаче.
    if (verb == null ||
        !DueParser.isInfinitive(verb.text) ||
        _notImplicitVerbs.contains(verb.text) ||
        _completeInfinitives.contains(verb.text)) {
      return null;
    }
    // Глагол прямо перед кавычками: «испечь «пирог»», а не «купить завтра
    // «хлеб»» с чужим словом между ними.
    final gap = utterance.original.substring(verb.span.end, quote.span.start);
    if (gap.trim().isNotEmpty) return null;
    return ParsedCommand(
      intent: CommandIntent.createTask,
      title: quote.text,
      dueAt: due.dueAt,
      duePrecision: due.precision,
      dueIssue: due.issue,
      projects: <String>[for (final tag in utterance.hashtags) tag.name],
      implicit: true,
    );
  }

  /// Слова надобности во вступлении: с ними название в кавычках — новая
  /// задача («мне нужно «помыть машину» после обеда»).
  static const Set<String> _needWords = <String>{
    'надо',
    'нужно',
    'необходимо',
  };

  /// Слова о самой задаче рядом с названием в кавычках: «нужна задача
  /// „Зайти в банк“ послезавтра», «новая задача «…»».
  static const Set<String> _quotedTaskWords = <String>{
    'задача',
    'задачу',
    'напоминание',
    'нужна',
    'нужен',
    'нужно',
    'новая',
    'новую',
  };

  /// Предлоги, с которых может начинаться короткое пояснение после
  /// названия в кавычках: «через час "позвонить в клинику" по записи».
  static const Set<String> _quotedTailPrepositions = <String>{
    'по',
    'для',
    'в',
    'во',
    'на',
    'с',
    'со',
    'к',
    'ко',
    'у',
    'из',
    'от',
    'за',
    'о',
    'об',
    'про',
  };

  /// Название в кавычках без команды — новая задача, если кроме него во
  /// фразе только срок, вежливые слова и вступление:
  /// - вступление с «надо»/«нужно»/«необходимо»/«не забыть»: «мне нужно
  ///   «помыть машину» после обеда», «не забыть «Сдать отчёт»»;
  /// - или срок: ««Полить цветы» на сегодня в 12:00», «в пятницу в 18
  ///   "созвониться с клиентом"»;
  /// - или слово «задача»: «Нужна задача „Зайти в банк“ послезавтра».
  /// Тогда после кавычек допустимо короткое пояснение с предлога (до трёх
  /// слов): «через час "позвонить в клинику" по записи» — в название оно
  /// не входит, название в кавычках точное. Одни кавычки («"Кто тебя
  /// создал?"», ««купить хлеб»») и «хочу «отпуск»» — не команда.
  ParsedCommand? _implicitQuoted(Utterance utterance) {
    if (utterance.quotedTitles.length != 1) return null;
    final due = utterance.due;
    final tokens = utterance.tokens;
    final quoteEnd = utterance.quotedTitles.single.span.end;
    // Слово «надо», «задача», «не забыть» — явная просьба; один срок —
    // нет ([_quotedByDueOnly]).
    var needs = false;
    var i = SocialPrefix.length(utterance);
    int? tailStart;
    while (i < tokens.length) {
      final token = tokens[i];
      if (Utterance.isCovered(token, due.spans) ||
          _politeWords.contains(token.text)) {
        i++;
        continue;
      }
      if (_implicitLeadIns.contains(token.text)) {
        if (_needWords.contains(token.text)) needs = true;
        i++;
        continue;
      }
      if (_quotedTaskWords.contains(token.text)) {
        if (token.text.startsWith('задач') || token.text == 'напоминание') {
          needs = true;
        }
        i++;
        continue;
      }
      if (token.text == 'не' &&
          i + 1 < tokens.length &&
          _dontForget.contains(tokens[i + 1].text)) {
        needs = true;
        i += 2;
        continue;
      }
      if (tailStart == null &&
          token.span.start >= quoteEnd &&
          _quotedTailPrepositions.contains(token.text)) {
        tailStart = i;
        i++;
        continue;
      }
      if (tailStart != null && i - tailStart < 3) {
        if (token.text == 'не' || token.text == 'нет') return null;
        i++;
        continue;
      }
      return null;
    }
    if (!needs &&
        (due.spans.isEmpty ||
            !_quotedByDueOnly(utterance, hasTail: tailStart != null))) {
      return null;
    }
    return ParsedCommand(
      intent: CommandIntent.createTask,
      title: utterance.quotedTitles.single.text,
      dueAt: due.dueAt,
      duePrecision: due.precision,
      dueIssue: due.issue,
      projects: <String>[for (final tag in utterance.hashtags) tag.name],
      implicit: true,
    );
  }

  /// Название в кавычках только со сроком (без «надо», «задача») — задача,
  /// если это похоже на дело, а не на цитату: в названии нет «?» («"Кто
  /// там?" в обед»), это не приветствие («"Спокойной ночи" в 22:00»), а
  /// пояснение после кавычек ([hasTail]) допустимо, только если название
  /// начинается с инфинитива: «через час "позвонить в клинику" по записи»
  /// — задача, ««Мастер и Маргарита» завтра в кино» — нет.
  bool _quotedByDueOnly(Utterance utterance, {required bool hasTail}) {
    final title = utterance.quotedTitles.single.text;
    if (title.contains('?')) return false;
    final words = <String>[
      for (final match
          in RegExp('[a-zа-я0-9]+').allMatches(DueParser.normalizeChars(title)))
        match.group(0)!,
    ];
    if (words.isEmpty) return false;
    if (_quotedGreetings.contains(words.join(' '))) return false;
    if (hasTail && !DueParser.isInfinitive(words.first)) return false;
    return true;
  }

  /// Приветствия и пожелания в кавычках — не название задачи.
  static const Set<String> _quotedGreetings = <String>{
    'спокойной ночи',
    'доброй ночи',
    'доброе утро',
    'с добрым утром',
    'добрый день',
    'добрый вечер',
    'привет',
    'пока',
    'до свидания',
    'хорошего дня',
    'хороших выходных',
  };

  /// Слова, которые не описывают сделанное: «я уже купил хлеб».
  static const Set<String> _pastFiller = <String>{
    ..._politeWords,
    'я',
    'мы',
    'уже',
    'все',
    'вот',
    'ну',
    'а',
    'так',
    'наконец',
    'сегодня',
    'вчера',
    'позавчера',
    'утром',
    'днем',
    'вечером',
    'ночью',
    'недавно',
  };

  /// Кто-то другой, а не «я»: «мать звонила», «она купила хлеб» — рассказ,
  /// а не сообщение о сделанном.
  static const Set<String> _thirdPersons = <String>{
    'он',
    'она',
    'оно',
    'они',
    'кто',
    'мама',
    'папа',
    'мать',
    'отец',
    'сын',
    'дочь',
    'дочка',
    'брат',
    'сестра',
    'муж',
    'жена',
    'зять',
    'бабушка',
    'дедушка',
    'ребенок',
    'дети',
    'сосед',
    'соседка',
    'коллега',
    'начальник',
    'кошка',
    'собака',
    'лошадь',
  };

  /// Завершение без маркера: «я купил хлеб», «отчёт сдал». Глагол
  /// прошедшего времени стоит первым или последним среди значимых слов.
  ParsedCommand? _implicitComplete(Utterance utterance) {
    if (utterance.isQuestion ||
        utterance.unbalancedQuotes ||
        utterance.quotedTitles.length > 1) {
      return null;
    }
    final tokens = utterance.tokens;
    final remove = <CharSpan>[
      ...utterance.due.spans,
      for (final token in tokens)
        if (_pastFiller.contains(token.text)) token.span,
      // «наконец-то сдал проект».
      for (final token in tokens)
        if (token.text == 'то' &&
            token.index > 0 &&
            tokens[token.index - 1].text == 'наконец')
          token.span,
    ];
    // «и» — часть перечисления («хлеб и молоко купил»), а не вступление,
    // кроме как на краю: «и хлеб купил».
    _trimEdgeWords(utterance, remove, const <String>{'и'});
    final rest = utterance.tokensOutside(remove);
    if (rest.isEmpty) return null;
    // «Не купил хлеб» — не сделано.
    if (rest.any((UtteranceToken t) => t.text == 'не' || t.text == 'нет')) {
      return null;
    }
    if (!isPastVerb(rest.first.text) && !isPastVerb(rest.last.text)) {
      return null;
    }
    if (rest.any((UtteranceToken t) => _thirdPersons.contains(t.text))) {
      return null;
    }
    // «Хлеб купили» без «мы» — безлично или о других.
    final saysWe = utterance.tokens.any((UtteranceToken t) => t.text == 'мы');
    if (!saysWe &&
        rest.any((UtteranceToken t) => VerbForms.isPluralPastVerb(t.text))) {
      return null;
    }
    // «Я закрыла дверь», «закрыл глаза» — бытовое, а не задача
    // ([_householdObjects]).
    if (rest.any((UtteranceToken t) => _closedForms.contains(t.text)) &&
        rest.any((UtteranceToken t) => _householdObjects.contains(t.text))) {
      return null;
    }
    // «Я забыл отчёт», «потерял ключи», «любил «Отчёт»», «смотрел «Друзей»»:
    // глагол прошедшего времени, но не о сделанном деле.
    if (rest.any((UtteranceToken t) => _isNotDonePast(t.text))) return null;
    // «Вернул «Книгу в библиотеку»»: глагол сделанного и точное название.
    // Задача ищется по точному названию, но, как и без кавычек, глагол
    // угадан по форме — сначала вопрос «Отметить «…» выполненной?».
    if (utterance.quotedTitles.isNotEmpty) {
      if (rest.length != 1) return null;
      return ParsedCommand(
        intent: CommandIntent.completeTask,
        title: utterance.quotedTitles.single.text,
        implicit: true,
        pastTense: true,
      );
    }
    // «Я купил», «звонил», «поел и поспал» без предмета: по одним глаголам
    // задачу не угадать. «И» между ними — не предмет.
    if (rest.every(
      (UtteranceToken t) => t.text == 'и' || VerbForms.stem(t.text) != null,
    )) {
      return null;
    }
    final text = _titleText(utterance, remove);
    if (text.isEmpty) return null;
    return ParsedCommand(
      intent: CommandIntent.completeTask,
      targetQuery: Utterance.capitalize(text),
      implicit: true,
      pastTense: true,
    );
  }

  /// Начала глаголов прошедшего времени, которые не сообщают о сделанном
  /// деле: забыть и потерять («забыл», «потеряла», «упустил»,
  /// «пропустили», «проспал», «провалил»), чувства («любил», «обожала»,
  /// «ненавидел», «хотел», «мечтал») и восприятие или ожидание без
  /// приставки («смотрел», «видел», «слышал», «ждал», «помнил», «знал»,
  /// «думал»). С приставкой сделанного дело закончено: «посмотрел
  /// вебинар», «дождался курьера», «узнал цену».
  static const List<String> _notDonePastStems = <String>[
    'забыл',
    'позабыл',
    'потерял',
    'упустил',
    'пропустил',
    'проспал',
    'провалил',
    'люби',
    'полюбил',
    'обожал',
    'ненавидел',
    'хотел',
    'захотел',
    'мечтал',
    'смотрел',
    'видел',
    'увидел',
    'слышал',
    'услышал',
    'ждал',
    'помнил',
    'знал',
    'думал',
  ];

  static bool _isNotDonePast(String word) =>
      isPastVerb(word) && _notDonePastStems.any(word.startsWith);

  /// Похоже на глагол прошедшего времени: «купил», «сдала», «позвонили».
  /// Правила — [VerbForms.isPastVerb].
  static bool isPastVerb(String word) => VerbForms.isPastVerb(word);

  // ------------------------------------------------------- целевая задача

  /// Слова, которые не описывают саму задачу в «Заверши её», «Отметь
  /// задачу как выполненную».
  static const Set<String> _targetFiller = <String>{
    ..._politeWords,
    ..._addressees,
    'задачу',
    'задача',
    'задачи',
    // Слова, которые указывают на выбранную задачу, а не называют её:
    // «Перенеси выбранную задачу», «Заверши текущую», «эту же».
    'её',
    'ее',
    'его',
    'нее',
    'него',
    'эту',
    'это',
    'этот',
    'эта',
    'этой',
    'ту',
    'тот',
    'же',
    'самую',
    'выбранную',
    'выбранная',
    'выбранной',
    'текущую',
    'текущая',
    'текущей',
    'последнюю',
    'последняя',
    'последней',
    'я',
    'мы',
    'уже',
  };

  static const Set<String> _completeFiller = <String>{
    ..._targetFiller,
    ..._completeWords,
    ..._completeInfinitives,
    ..._markVerbs,
    ..._markInfinitives,
    ..._markedPast,
    ..._closeVerbs,
    ..._closedForms,
    ..._tickNouns,
    'закрыть',
    'как',
    'выполненная',
    'выполненное',
    'завершенное',
    'сделанное',
    'готова',
    'готовым',
    'готовой',
    'готовую',
    'готовое',
    'галочкой',
    'все',
    // Опечатка с одной «н» ([_isDoneWord]).
    'выполненым',
    'выполненой',
    'выполненую',
    'выполненая',
    'выполненое',
    'сделаным',
    'сделаной',
    'сделаную',
    'завершеным',
    'завершеной',
  };

  /// Слова о самой задаче сразу после команды переноса и завершения:
  /// «отложи напоминание про полис», «выполни пункт про оплату счетов».
  /// Дальше по фразе они — часть цели: «заверши поход в пункт выдачи».
  static const Set<String> _targetObjectNouns = <String>{
    'напоминание',
    'пункт',
  };

  /// Союзы на краю цели: «перенеси на завтра и потом на послезавтра
  /// звонить в страховую» → «Звонить в страховую».
  static const Set<String> _targetEdgeConjunctions = <String>{
    'и',
    'а',
    'или',
    'потом',
    'затем',
  };

  static const Set<String> _rescheduleFiller = <String>{
    ..._targetFiller,
  };

  /// Предлоги, после которых дата — часть цели завершения: «заверши
  /// задачу про 15 ноября».
  static const Set<String> _aboutPrepositions = <String>{
    'про',
    'о',
    'об',
    'насчет',
  };

  /// Слова «как переносить» без нового срока: «на более позднее время»,
  /// «на другой день». Помощник спросит, на когда; в цель они не входят.
  static const List<List<String>> _vagueTargets = <List<String>>[
    <String>['на', 'более', 'позднее', 'время'],
    <String>['на', 'более', 'раннее', 'время'],
    <String>['на', 'более', 'поздний', 'срок'],
    <String>['на', 'позднее', 'время'],
    <String>['на', 'другое', 'время'],
    <String>['на', 'другой', 'день'],
    <String>['на', 'попозже'],
    <String>['на', 'потом'],
    <String>['попозже'],
  ];

  /// Существительные переноса: «с перенесением на четверг», «с переносом
  /// на пятницу» — «с» здесь часть команды.
  static bool _isRescheduleNoun(String word) =>
      word == 'перенесением' || word == 'переносом';

  String? _targetQuery(
    Utterance utterance,
    int markerIndex,
    Set<String> filler, {
    UtteranceToken? dangling,
  }) {
    final tokens = utterance.tokens;
    final complete = identical(filler, _completeFiller);
    final dueSpans = <CharSpan>[
      for (final span in utterance.due.spans)
        // «заверши задачу про 15 ноября»: дата здесь — название задачи.
        if (!complete || !_followsAbout(utterance, span)) span,
    ];
    final remove = <CharSpan>[
      if (dangling != null) dangling.span,
      ...dueSpans,
      ..._tailSpans(utterance, markerIndex),
      ..._leadInSpans(utterance, markerIndex),
      tokens[markerIndex].span,
      for (final token in tokens)
        if (filler.contains(token.text)) token.span,
    ];
    if (complete) {
      for (var i = 0; i + 1 < tokens.length; i++) {
        // «отметь что сдал отчёт» — «что» и глагол сделанного.
        if (_markVerbs.contains(tokens[i].text) &&
            tokens[i + 1].text == 'что') {
          remove.add(tokens[i + 1].span);
          if (i + 2 < tokens.length && isPastVerb(tokens[i + 2].text)) {
            remove.add(tokens[i + 2].span);
          }
        }
        // «С врачом всё, сделано» → «Врачом»: «с» перед целью, которая
        // стоит до слова о готовности, — не часть названия.
        if (i == 0 &&
            (tokens[0].text == 'с' || tokens[0].text == 'со') &&
            markerIndex > 1) {
          remove.add(tokens[0].span);
        }
        // «поставь галочку на …», «поставь галочку напротив …».
        if (_tickNouns.contains(tokens[i].text)) {
          if (i > 0 && _tickVerbs.contains(tokens[i - 1].text)) {
            remove.add(tokens[i - 1].span);
          }
          final next = tokens[i + 1].text;
          if (next == 'на' || next == 'напротив' || next == 'у') {
            remove.add(tokens[i + 1].span);
          }
        }
      }
    } else {
      _removeVagueTargets(utterance, remove);
      // «с перенесением на четверг».
      if (markerIndex > 0 &&
          _isRescheduleNoun(tokens[markerIndex].text) &&
          (tokens[markerIndex - 1].text == 'с' ||
              tokens[markerIndex - 1].text == 'со')) {
        remove.add(tokens[markerIndex - 1].span);
      }
      _removeTrailingComment(utterance, remove);
      // «с встречи 12-го на 18-е»: «с» — от исходного срока, оторванного
      // от него словом цели.
      final rest = utterance.tokensOutside(remove);
      if (utterance.due.hasSource &&
          rest.length > 1 &&
          (rest.first.text == 'с' || rest.first.text == 'со')) {
        remove.add(rest.first.span);
      }
    }
    // «отложи напоминание про полис», «выполни пункт про оплату»: слово
    // о самой задаче сразу после команды — как «задачу».
    final first = utterance
        .tokensOutside(remove)
        .where((UtteranceToken t) => t.index > markerIndex)
        .firstOrNull;
    if (first != null && _targetObjectNouns.contains(first.text)) {
      remove.add(first.span);
    }
    // «перенеси на завтра и потом на послезавтра звонить»: союз между
    // сроками и целью — не цель.
    _trimEdgeWords(utterance, remove, _targetEdgeConjunctions);
    final text = _titleText(utterance, remove);
    if (text.isEmpty) return null;
    // «Перенеси встречу» → «Встреча»: поиск сравнивает слова по основе,
    // поэтому задача находится и по старому названию «Встречу». У цели
    // завершения убираются и «про», «по» («закрой задачу по подготовке
    // презентации» → «Подготовка презентации»), если слово после них
    // удалось привести.
    return Utterance.capitalize(
      complete
          ? NounForms.nominative(text, allowPo: true)
          : NounForms.nominative(text, allowPreposition: false),
    );
  }

  bool _followsAbout(Utterance utterance, CharSpan span) {
    UtteranceToken? before;
    for (final token in utterance.tokens) {
      if (token.span.end > span.start) break;
      before = token;
    }
    return before != null && _aboutPrepositions.contains(before.text);
  }

  void _removeVagueTargets(Utterance utterance, List<CharSpan> remove) {
    final tokens = utterance.tokens;
    for (final phrase in _vagueTargets) {
      for (var i = 0; i + phrase.length <= tokens.length; i++) {
        var match = true;
        for (var k = 0; k < phrase.length; k++) {
          if (tokens[i + k].text != phrase[k]) {
            match = false;
            break;
          }
        }
        if (!match) continue;
        for (var k = 0; k < phrase.length; k++) {
          remove.add(tokens[i + k].span);
        }
      }
    }
  }

  /// «перенеси встречу на 15 ноября, у меня тогда свободнее»: после срока
  /// и запятой — пояснение, а не цель. Убирается, только если слова цели
  /// стоят до срока.
  void _removeTrailingComment(Utterance utterance, List<CharSpan> remove) {
    final text = utterance.analysisText;
    for (final span in utterance.due.spans) {
      var comma = span.end;
      while (comma < text.length && text[comma] == ' ') {
        comma++;
      }
      if (comma >= text.length || text[comma] != ',') continue;
      final before = utterance
          .tokensOutside(remove)
          .where((UtteranceToken t) => t.span.end <= span.start);
      if (before.isEmpty) continue;
      for (final token in utterance.tokens) {
        if (token.span.start > comma) remove.add(token.span);
      }
      return;
    }
  }

  // ------------------------------------------------------------ намерение

  _Marker _detectIntent(Utterance utterance) {
    final words = utterance.words;
    // Фраза из одних кавычек («купить хлеб») — команды в ней нет.
    if (words.isEmpty) return const _Marker.unknown();
    // «Нет, добавь…» — поправка собеседнику, а не отрицание команды:
    // отрицанием считается только «не»/«нет» прямо перед словом.
    bool joined(int i) {
      final tokens = utterance.tokens;
      return utterance.analysisText
          .substring(tokens[i - 1].span.end, tokens[i].span.start)
          .trim()
          .isEmpty;
    }

    final startsWithNegation =
        words.first == 'не' && (words.length == 1 || joined(1));
    // Намерение определяет самый ранний маркер: «Добавь задачу выполнить
    // отчёт» — создание, а не завершение.
    for (var i = 0; i < words.length; i++) {
      final word = words[i];
      final negated =
          i > 0 && (words[i - 1] == 'не' || words[i - 1] == 'нет') && joined(i);
      final create = _isTitleHeading(utterance, i)
          ? 1
          : _createLength(utterance, word, i, words);
      if (create > 0) {
        return negated
            ? const _Marker.unknown()
            : _Marker(CommandIntent.createTask, i, create);
      }
      if (_isReschedule(word) ||
          (_rescheduleImperfective.contains(word) &&
              utterance.due.spans.isNotEmpty)) {
        return negated
            ? const _Marker.unknown()
            : _Marker(CommandIntent.rescheduleTask, i, 1);
      }
      if (_isComplete(utterance, word, i)) {
        // «Не выполнено», «Не выполнил отчёт», «Что выполнить?» — не команда.
        // Отрицание дальше по фразе относится к названию: «Заверши не
        // забыть купить хлеб».
        if (negated || startsWithNegation || utterance.isQuestion) {
          return const _Marker.unknown();
        }
        return _Marker(CommandIntent.completeTask, i, 1);
      }
      if (_isList(word, words, i)) {
        return _Marker(CommandIntent.listTasks, i, 1);
      }
    }
    return const _Marker.none();
  }

  static const Set<String> _createVerbs = <String>{
    'добавь',
    'добавьте',
    'добавить',
    'создай',
    'создайте',
    'создать',
    'запиши',
    'запишите',
    'записать',
    'напомни',
    'напомните',
  };

  /// Глаголы, которые создают задачу только вместе с существительным:
  /// «поставь задачу …», «заведи напоминание …». Без него это не команда:
  /// «поставь чайник», «сделай погромче».
  static const Set<String> _createWithNounVerbs = <String>{
    'поставь',
    'поставьте',
    'поставить',
    'заведи',
    'заведите',
    'завести',
    'сделай',
    'сделайте',
  };

  /// «Можешь», «можете», «сможешь» перед «напомнить».
  static const Set<String> _canYou = <String>{
    'можешь',
    'можете',
    'сможешь',
    'сможете',
    'мог',
    'могла',
    'могли',
    'бы',
  };

  /// Слово перед [index], не считая «мне», «пожалуйста» и шума.
  String? _previousWord(Utterance utterance, int index) {
    for (var i = index - 1; i >= 0; i--) {
      final word = utterance.tokens[i].text;
      if (_addressees.contains(word) ||
          _politeWords.contains(word) ||
          SpeechNoise.isJunk(word)) {
        continue;
      }
      return word;
    }
    return null;
  }

  /// «Напоминание завтра в 9 позвонить маме», «мне нужно напоминание на
  /// вечер, чтобы я купил хлеб»: существительное в начале (после «мне
  /// нужно», «нужен»), а за ним — дело: инфинитив или «чтобы». «Напоминание
  /// про встречу перенеси» — о существующем напоминании, не команда.
  bool _reminderLeads(Utterance utterance, int index) {
    final tokens = utterance.tokens;
    final due = utterance.due.spans;
    final start = SocialPrefix.length(utterance);
    for (var i = start < index ? start : 0; i < index; i++) {
      final token = tokens[i];
      if (Utterance.isCovered(token, due)) continue;
      if (_leadIns.contains(token.text) ||
          SpeechNoise.isLeadFiller(token.text) ||
          _newAdjectives.contains(token.text)) {
        continue;
      }
      return false;
    }
    var i = index + 1;
    while (i < tokens.length &&
        (Utterance.isCovered(tokens[i], due) ||
            _politeWords.contains(tokens[i].text) ||
            _addressees.contains(tokens[i].text) ||
            SpeechNoise.isJunk(tokens[i].text))) {
      i++;
    }
    if (i >= tokens.length) return false;
    final word = tokens[i].text;
    if (word == 'чтобы') return true;
    return DueParser.isInfinitive(word) &&
        !_notImplicitVerbs.contains(word) &&
        !_isAssistantVerb(word);
  }

  /// Глаголы о самих задачах: «напоминание перенести», «напоминание
  /// удалить» — о существующем.
  static bool _isAssistantVerb(String word) =>
      word.startsWith('перенес') ||
      word.startsWith('передвин') ||
      word.startsWith('сдвин') ||
      word.startsWith('отлож') ||
      word.startsWith('удал') ||
      word.startsWith('выполн') ||
      word.startsWith('заверш');

  /// Есть ли после глагола в позиции [index] существительное «задачу»
  /// (через «мне», «пожалуйста», «новую»): «поставь мне новую задачу».
  bool _nounFollows(Utterance utterance, int index, List<String> words) {
    final tokens = utterance.tokens;
    var budget = 4;
    for (var i = index + 1; i < words.length && budget > 0; i++) {
      final word = words[i];
      if (_objectNouns.contains(word)) return true;
      // «поставь на утро напоминание»: срок между глаголом и
      // существительным не считается.
      if (i < tokens.length &&
          Utterance.isCovered(tokens[i], utterance.due.spans)) {
        continue;
      }
      budget--;
      if (_addressees.contains(word) ||
          _politeWords.contains(word) ||
          _newAdjectives.contains(word) ||
          SpeechNoise.isJunk(word)) {
        continue;
      }
      return false;
    }
    return false;
  }

  /// «Задача: купить хлеб» — существительное с двоеточием в начале фразы
  /// работает как заголовок новой задачи.
  bool _isTitleHeading(Utterance utterance, int index) {
    if (index != 0 || !_objectNouns.contains(utterance.words[0])) return false;
    final tokens = utterance.tokens;
    if (tokens.length < 2) return false;
    return utterance.analysisText
        .substring(tokens[0].span.end, tokens[1].span.start)
        .trim()
        .startsWith(':');
  }

  /// «Поставь», «заведи» создают задачу и без «задачу», если дальше
  /// инфинитив («поставь подготовить презентацию») или название в кавычках
  /// («Поставь «Подготовить презентацию»»). «Сделай» — только с «задачу»:
  /// «сделай погромче», «сделай «Ноду» основной» — не задачи.
  static const Set<String> _createWithInfinitiveVerbs = <String>{
    'поставь',
    'поставьте',
    'поставить',
    'заведи',
    'заведите',
    'завести',
  };

  /// Инфинитивы после «поставь», с которыми это не задача, а просьба
  /// о бытовом: кухня («поставь кипятить воду», «поставь варить кашу»),
  /// стирка («поставь стирать бельё»), устройства и медиа («поставь
  /// заряжать телефон», «поставь смотреть фильм», «поставь играть музыку»).
  /// Список закрытый: «поставь подготовить отчёт», «поставь созвониться
  /// с клиентом» — задачи.
  static const Set<String> _notTaskAfterPut = <String>{
    'играть',
    'кипятить',
    'варить',
    'жарить',
    'печь',
    'запекать',
    'тушить',
    'греть',
    'нагревать',
    'подогревать',
    'разогревать',
    'размораживать',
    'остужать',
    'охлаждать',
    'мариновать',
    'настаиваться',
    'размораживаться',
    'стирать',
    'сушить',
    'полоскать',
    'отжимать',
    'заряжать',
    'качать',
    'скачивать',
    'загружать',
    'обновляться',
    'смотреть',
    'слушать',
    'крутить',
    'проигрывать',
    'воспроизводить',
    'петь',
    'звучать',
    'греться',
    'нагреваться',
    'заряжаться',
    'кипеть',
    'кипятиться',
    'вариться',
    'тушиться',
    'печься',
    'сушиться',
    'стираться',
    'остывать',
    'стоять',
    'лежать',
  };

  /// Сразу после глагола (через «мне», «пожалуйста», срок) — инфинитив-дело
  /// или название в кавычках.
  bool _taskFollows(Utterance utterance, int index) {
    final tokens = utterance.tokens;
    var i = index + 1;
    while (i < tokens.length &&
        (_addressees.contains(tokens[i].text) ||
            _politeWords.contains(tokens[i].text) ||
            SpeechNoise.isJunk(tokens[i].text) ||
            Utterance.isCovered(tokens[i], utterance.due.spans))) {
      i++;
    }
    // Ближайшее после глагола: слово или кавычки.
    final wordStart = i < tokens.length ? tokens[i].span.start : null;
    for (final quoted in utterance.quotedTitles) {
      if (quoted.span.start < tokens[index].span.end) continue;
      if (wordStart == null || quoted.span.start < wordStart) return true;
      break;
    }
    if (i >= tokens.length) return false;
    final verb = tokens[i].text;
    return DueParser.isInfinitive(verb) &&
        !_notImplicitVerbs.contains(verb) &&
        !_notTaskAfterPut.contains(verb);
  }

  /// Сколько слов занимает маркер создания в позиции [index]; 0 — не он.
  int _createLength(
    Utterance utterance,
    String word,
    int index,
    List<String> words,
  ) {
    if (_createVerbs.contains(word)) {
      return _signsUpOther(utterance, word, index) ? 0 : 1;
    }
    // «Можешь напомнить написать Андрею»: инфинитив после «можешь» —
    // та же просьба, что «напомни». Без него («надо напомнить маме про
    // лекарства») «напомнить» — само дело.
    if (word == 'напомнить' &&
        index > 0 &&
        _canYou.contains(_previousWord(utterance, index))) {
      return 1;
    }
    if (_reminderNouns.contains(word) && _reminderLeads(utterance, index)) {
      return 1;
    }
    if (_createWithNounVerbs.contains(word) &&
        _nounFollows(utterance, index, words)) {
      return 1;
    }
    // «сделай recurring по пятницам — выносить мусор»: сразу после глагола
    // повторение — это задача (docs/PLANS.md, «Повторяющиеся задачи»).
    if (_createWithNounVerbs.contains(word) &&
        utterance.due.recurring &&
        index + 1 < utterance.tokens.length &&
        Utterance.isCovered(utterance.tokens[index + 1], utterance.due.spans)) {
      return 1;
    }
    if (_createWithInfinitiveVerbs.contains(word) &&
        _taskFollows(utterance, index)) {
      return 1;
    }
    final isNewTask = word == 'новая' &&
        index + 1 < words.length &&
        words[index + 1] == 'задача';
    return isNewTask ? 2 : 0;
  }

  /// «не забыть записать ребёнка к стоматологу», «надо записать маму на
  /// приём»: инфинитив «записать» с кем-то другим и «к/на» — само дело
  /// (записать кого-то к врачу), а не просьба «запиши в задачи». Такая
  /// фраза разбирается как задача по инфинитиву: «Записать ребёнка
  /// к стоматологу». «Записать меня к врачу» — просьба записаться.
  bool _signsUpOther(Utterance utterance, String word, int index) {
    if (word != 'записать') return false;
    final tokens = utterance.tokens;
    if (index + 2 >= tokens.length) return false;
    final object = tokens[index + 1];
    if (_signUpObjects.contains(object.text) ||
        _objectNouns.contains(object.text) ||
        _politeWords.contains(object.text) ||
        _addressees.contains(object.text) ||
        object.isNumber ||
        Utterance.isCovered(object, utterance.due.spans)) {
      return false;
    }
    return _signUpPrepositions.contains(tokens[index + 2].text) &&
        !Utterance.isCovered(tokens[index + 2], utterance.due.spans);
  }

  bool _isReschedule(String word) =>
      word.startsWith('перенес') ||
      word.startsWith('передвин') ||
      word.startsWith('сдвин') ||
      word.startsWith('отлож');

  /// Несовершенный вид в просьбе: «сдвигай тренировку на среду», «переноси
  /// встречу на пятницу». Только повелительные формы («переносить» —
  /// инфинитив, «перенос» — существительное) и только со сроком: «переноси
  /// коробки аккуратно» — о вещах, а не о задаче.
  static const Set<String> _rescheduleImperfective = <String>{
    'переноси',
    'переносите',
    'сдвигай',
    'сдвигайте',
    'передвигай',
    'передвигайте',
    'откладывай',
    'откладывайте',
  };

  /// Повелительные, прошедшие и краткие формы. «Выполненные задачи»
  /// и «нужно выполнить» не считаются командой завершения.
  static const Set<String> _completeWords = <String>{
    'заверши',
    'завершите',
    'завершил',
    'завершила',
    'завершили',
    'завершено',
    'завершена',
    'выполни',
    'выполните',
    'выполнил',
    'выполнила',
    'выполнили',
    'выполнено',
    'выполнена',
    'выполненной',
    'выполненную',
    'выполненным',
    'сделанным',
    'завершенным',
    'завершенной',
    'сделал',
    'сделала',
    'сделали',
    'сделано',
    'сделана',
    'сделанной',
    'сделанную',
    'завершенную',
    'готово',
  };

  /// Инфинитив допустим только первым словом: «Завершить задачу».
  static const Set<String> _completeInfinitives = <String>{
    'завершить',
    'выполнить',
  };

  bool _isComplete(Utterance utterance, String word, int index) {
    if (_completeWords.contains(word) ||
        (index == 0 && _completeInfinitives.contains(word))) {
      return true;
    }
    final words = utterance.words;
    final tokens = utterance.tokens;
    // «Поставь галочку на звонить стоматологу».
    if (_tickVerbs.contains(word)) {
      return index + 1 < words.length && _tickNouns.contains(words[index + 1]);
    }
    // «Отметь как завершённое письмо клиенту», «пометь готовым задачу про
    // ремонт», «отметь что сдал отчёт», «отметь галочкой отчёт». Без слова
    // о готовности «отметь» — не завершение: «отметить юбилей».
    if (_markVerbs.contains(word) ||
        (index == 0 && _markInfinitives.contains(word))) {
      if (words.any(_isDoneWord)) return true;
      return index + 2 < words.length &&
          words[index + 1] == 'что' &&
          isPastVerb(words[index + 2]);
    }
    // «Отметил забрать вещи из химчистки» — сообщение, что сделано.
    if (_markedPast.contains(word)) {
      return _targetWordsAfter(utterance, index).isNotEmpty;
    }
    // «Закрой задачу …», «закрой «Заказать подарок»», «я закрыла отчёт»,
    // «всё, задача закрыта». «Закрой окно», «закрыл дверь» — бытовое,
    // а не задача: первое слово цели не из [_householdObjects].
    final close = _closeVerbs.contains(word) ||
        (index == 0 && word == 'закрыть') ||
        _closedForms.contains(word);
    if (!close) return false;
    if (utterance.quotedTitles.isNotEmpty ||
        words.any(
          (String w) => w.startsWith('задач') || w.startsWith('напоминани'),
        )) {
      return true;
    }
    if (_closedParticiples.contains(word)) return false;
    final target = _targetWordsAfter(utterance, index);
    return target.isNotEmpty &&
        !_householdObjects.contains(target.first) &&
        tokens.length > index;
  }

  /// Слова после маркера в позиции [index] без служебных и срока.
  List<String> _targetWordsAfter(Utterance utterance, int index) => <String>[
        for (final token in utterance.tokens.skip(index + 1))
          if (!_completeFiller.contains(token.text) &&
              !Utterance.isCovered(token, utterance.due.spans))
            token.text,
      ];

  /// Слова о готовности после «отметь»/«пометь».
  // «Выполненым», «сделаной» — частая опечатка с одной «н»: без неё
  // «отметь отчёт выполненым» становилось новой задачей.
  static bool _isDoneWord(String word) =>
      word.startsWith('выполнен') ||
      word.startsWith('завершен') ||
      word.startsWith('сделан') ||
      word == 'готовым' ||
      word == 'готовой' ||
      word == 'готовую' ||
      word == 'готовое' ||
      word == 'готово' ||
      word == 'галочкой' ||
      word == 'галочку';

  static const Set<String> _markVerbs = <String>{
    'отметь',
    'отметьте',
    'пометь',
    'пометьте',
  };

  static const Set<String> _markInfinitives = <String>{
    'отметить',
    'пометить',
  };

  static const Set<String> _markedPast = <String>{
    'отметил',
    'отметила',
    'пометил',
    'пометила',
  };

  static const Set<String> _tickVerbs = <String>{'поставь', 'поставьте'};

  static const Set<String> _tickNouns = <String>{
    'галочку',
    'галку',
    'плюсик',
    'отметку',
  };

  static const Set<String> _closeVerbs = <String>{'закрой', 'закройте'};

  static const Set<String> _closedParticiples = <String>{
    'закрыта',
    'закрыто',
    'закрыт',
  };

  static const Set<String> _closedForms = <String>{
    'закрыл',
    'закрыла',
    'закрыли',
    ..._closedParticiples,
  };

  /// Что закрывают в быту, а не в списке задач: «закрой окно», «закрыл
  /// дверь», «закрой вкладку». С ними «закрой» — не завершение задачи,
  /// если нет слова «задача» или названия в кавычках.
  static const Set<String> _householdObjects = <String>{
    'окно',
    'окна',
    'форточку',
    'дверь',
    'двери',
    'дверцу',
    'кран',
    'краны',
    'вкладку',
    'вкладки',
    'приложение',
    'программу',
    'браузер',
    'окошко',
    'глаза',
    'глаз',
    'рот',
    'крышку',
    'шторы',
    'жалюзи',
    'ворота',
    'калитку',
    'холодильник',
    'шкаф',
    'ящик',
    'замок',
    'ноутбук',
    'файл',
    'чат',
    'гараж',
    'машину',
    'балкон',
    'воду',
    'газ',
    'кавычку',
    'скобку',
  };

  static const Set<String> _listVerbs = <String>{
    'покажи',
    'покажите',
    'показать',
    'выведи',
    'список',
    'какие',
  };

  bool _isList(String word, List<String> words, int index) {
    if (word == 'запланировано') return true;
    // «Очисти список задач», «отправь список задач маме» — действие над
    // списком, которого помощник не умеет, а не просьба его показать.
    if (word == 'список' && words.take(index).any(_notListVerbs.contains)) {
      return false;
    }
    return _listVerbs.contains(word) &&
        words.any((String w) => w.startsWith('задач') || w == 'дела');
  }

  /// Глаголы перед «список», с которыми это не просьба показать список.
  static const Set<String> _notListVerbs = <String>{
    'очисти',
    'очистить',
    'почисти',
    'удали',
    'удалить',
    'сотри',
    'стереть',
    'сбрось',
    'сбросить',
    'убери',
    'убрать',
    'распечатай',
    'напечатай',
    'отправь',
    'отправить',
    'перешли',
    'пошли',
    'скинь',
    'сохрани',
    'сохранить',
    'скопируй',
    'скопировать',
    'экспортируй',
    'выгрузи',
    'поделись',
    'отсортируй',
    'переименуй',
  };
}

/// Вопрос о своих планах целиком: «что у меня на сегодня по плану?»,
/// «выведи весь список дел», «какие у меня встречи на завтра?», «покажи
/// список "Дом"», «список». Все слова вне срока — из закрытого словаря
/// [_listVocabulary], есть просьба показать или вопрос и есть то, что
/// показывать: задачи, дела, планы, расписание, список. Любое чужое слово —
/// и это уже не просьба о списке: «какие есть планы на выходные в городе?»,
/// «покажи список моих контактов».
bool _isListQuery(Utterance utterance) {
  if (utterance.unbalancedQuotes) return false;
  final tokens = utterance.tokensOutside(utterance.due.spans);
  final words = <String>[for (final token in tokens) token.text];
  if (words.isEmpty) return false;
  // Название списка в кавычках — только сразу после «список» или как
  // пример после «типа»: «покажи список "Дом"».
  // Срок в кавычках — просто выделение: «список дел на «сегодня»».
  for (final quote in utterance.quotedTitles) {
    final before = utterance.tokens
        .where((UtteranceToken t) => t.span.end <= quote.span.start)
        .toList(growable: false);
    if (_isQuotedDue(quote.text, utterance)) continue;
    if (before.isEmpty || !_listQuoteHeads.contains(before.last.text)) {
      return false;
    }
  }
  if (words.length == 1 && words.single == 'список') {
    return utterance.quotedTitles.isEmpty && utterance.hashtags.isEmpty;
  }
  var subject = utterance.hashtags.isNotEmpty;
  // «Список дел на сегодня» — заголовок вместо просьбы: «список» в начале
  // и ещё одно слово о задачах после него.
  var ask = utterance.isQuestion ||
      (words.first == 'список' &&
          words.skip(1).any(
                (String w) =>
                    (_listSubjects.contains(w) && !w.startsWith('спис')) ||
                    _listSubjectStem(w),
              ));
  for (var i = 0; i < words.length; i++) {
    final word = words[i];
    // «ааа покажи …», «эээ, что у меня на завтра?» — междометие.
    if (_interjection.hasMatch(word)) continue;
    if (_listSubjects.contains(word) || _listSubjectStem(word)) {
      subject = true;
      continue;
    }
    if (_listAsks.contains(word)) {
      ask = true;
      continue;
    }
    // «есть ли у меня задачи на завтра» — вопрос и без «?».
    if (word == 'ли' && i > 0 && words[i - 1] == 'есть') {
      ask = true;
      continue;
    }
    // «хочу глянуть», «мне бы посмотреть», «дай глянуть»: инфинитив —
    // просьба только после желания; сам по себе это задача.
    if (_listLookInfinitives.contains(word)) {
      if (i == 0 || !_listWishes.contains(words[i - 1])) return false;
      ask = true;
      continue;
    }
    if (!_listVocabulary.contains(word)) return false;
  }
  // «что мне нужно сделать?», «покажи всё, что нужно сделать», «что я
  // должен сделать», «что там у меня осталось?», «что у меня на завтра?»,
  // «что я записал на пятницу», «что я там планировал».
  if (!subject && words.contains('что')) {
    final mine = words.contains('у') && words.contains('меня');
    subject =
        (words.any(_listDuties.contains) && words.any(_listDoings.contains)) ||
            words.contains('осталось') ||
            words.contains('остались') ||
            words.any(_listPlanned.contains) ||
            (mine && utterance.due.spans.isNotEmpty);
  }
  return subject && ask;
}

/// Междометие из одной повторённой буквы: «ааа», «эээ», «ммм».
final RegExp _interjection = RegExp(r'^(а{2,}|э+|м{2,}|о{2,}|у{2,})$');

/// Кавычки вокруг одного срока: «на «сегодня»». Срок в кавычках не
/// разбирается ([Utterance]), поэтому кавычки здесь — только выделение.
bool _isQuotedDue(String text, Utterance utterance) {
  final normalized = DueParser.normalizeChars(text);
  final words = RegExp('[a-zа-я0-9]+').allMatches(normalized).toList();
  if (words.isEmpty) return false;
  final due = const DueParser().parse(normalized, DateTime(2000));
  return words.every(
    (RegExpMatch w) => due.spans.any(
      (CharSpan s) => s.start <= w.start && w.end <= s.end,
    ),
  );
}

/// Кто должен: «что мне нужно сделать», «что я должен сделать».
const Set<String> _listDuties = <String>{
  'мне',
  'нужно',
  'надо',
  'должен',
  'должна',
  'должны',
};

/// Что сделать: «сделать», «доделать», «что мне делать».
const Set<String> _listDoings = <String>{
  'сделать',
  'делать',
  'доделать',
  'доработать',
  'недоделать',
  'недоработать',
};

/// Что я сам запланировал: «что я записал на пятницу», «что намечено на
/// понедельник», «что я там планировал».
const Set<String> _listPlanned = <String>{
  'записал',
  'записала',
  'записали',
  'записано',
  'запланировал',
  'запланировала',
  'запланировали',
  'планировал',
  'планировала',
  'планировали',
  'наметил',
  'наметила',
  'наметили',
  'намечено',
  'назначено',
};

/// То, что показывает список: «задачи», «дела», «планы», «расписание».
const Set<String> _listSubjects = <String>{
  'дела',
  'дел',
  'делам',
  'делах',
  'план',
  'плана',
  'плану',
  'планы',
  'планов',
  'планах',
  'плане',
  'планам',
  'расписание',
  'расписании',
  'расписания',
  'календарь',
  'календаре',
  'календаря',
  'список',
  'списке',
  'списка',
  'списки',
  'встречи',
  'встреч',
  'график',
  'графике',
  'графика',
};

bool _listSubjectStem(String word) =>
    word.startsWith('задач') ||
    word.startsWith('незаверш') ||
    word.startsWith('невыполн') ||
    word.startsWith('несделан');

/// Просьба показать или вопрос: «покажи», «выведи», «глянь», «что», «какие».
const Set<String> _listAsks = <String>{
  'покажи',
  'покажите',
  'выведи',
  'выведите',
  'глянь',
  'гляньте',
  'посмотри',
  'посмотрите',
  'взгляни',
  'дай',
  'дайте',
  // «напомни, что я там планировал» — вопрос о планах, а не новая задача.
  'напомни',
  'напомните',
  'скажи',
  'подскажи',
  'что',
  'какие',
  'какой',
  'какая',
  'каких',
};

const Set<String> _listLookInfinitives = <String>{
  'посмотреть',
  'глянуть',
  'взглянуть',
  'увидеть',
};

const Set<String> _listWishes = <String>{'хочу', 'бы', 'дай', 'дайте'};

/// После этих слов в просьбе о списке может стоять кавычка.
const Set<String> _listQuoteHeads = <String>{
  'список',
  'списке',
  'списка',
  'типа',
};

/// Служебные слова вокруг просьбы о списке.
const Set<String> _listVocabulary = <String>{
  ..._listWishes,
  'ну',
  'а',
  'и',
  'так',
  'там',
  'тут',
  'у',
  'меня',
  'мой',
  'мои',
  'моя',
  'мою',
  'моем',
  'моей',
  'моих',
  'мое',
  'еще',
  'сейчас',
  'вообще',
  'ка',
  'же',
  'типа',
  'все',
  'весь',
  'вся',
  'всех',
  'осталось',
  'остались',
  'есть',
  'по',
  'в',
  'во',
  'на',
  'для',
  'то',
  'нибудь',
  'нужен',
  'того',
  'я',
  'не',
  'сделал',
  'сделала',
  ..._listDoings,
  ..._listDuties,
  ..._listPlanned,
  'день',
  'тегу',
  'тегом',
  'метке',
  'эту',
  'этой',
  'эти',
  'этот',
  'неделю',
  'неделе',
  'месяц',
  'месяце',
  'покупок',
  'пожалуйста',
  'плиз',
  'пж',
  'пжлст',
};

final class _Marker {
  const _Marker(this.intent, this.index, this.length) : found = true;

  /// Маркер есть, но команды нет: «Не выполнено», «Что выполнить?».
  const _Marker.unknown()
      : intent = CommandIntent.unknown,
        index = -1,
        length = 0,
        found = true;

  /// Маркера нет ни одного: возможно, команда без маркера.
  const _Marker.none()
      : intent = CommandIntent.unknown,
        index = -1,
        length = 0,
        found = false;

  final CommandIntent intent;

  /// Номер первого слова маркера в [Utterance.tokens].
  final int index;

  /// Сколько слов занимает маркер.
  final int length;

  /// В сообщении есть маркер какой-либо команды.
  final bool found;
}
