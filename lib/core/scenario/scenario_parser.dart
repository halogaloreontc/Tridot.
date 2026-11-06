import '../connectors/due_parser.dart';
import '../connectors/social_prefix.dart';
import '../connectors/utterance.dart';
import '../connectors/verb_forms.dart';
import '../models/task.dart';
import '../services/clock.dart';

export '../connectors/due_parser.dart' show CharSpan, DueIssue, DueParseResult;

enum CommandIntent {
  createTask,
  listTasks,
  completeTask,
  rescheduleTask,
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
  });

  final CommandIntent intent;

  /// Команда без маркера: намерение понято по форме глагола. Создание —
  /// по инфинитиву в начале фразы («купить хлеб», «через 3 дня сдать
  /// отчёт»), завершение — по глаголу прошедшего времени («я купил хлеб»).
  /// Коннектор отвечает на такие команды с меньшей уверенностью, чтобы явная
  /// команда другого коннектора побеждала.
  final bool implicit;

  /// Завершение сообщением о сделанном: «я купил хлеб», «выполнил отчёт».
  /// Задача по [targetQuery] не завершается сразу: сначала вопрос
  /// «Отметить … выполненной?».
  final bool pastTense;

  /// Метки проектов из команды: «#работа» вне кавычек, без «#».
  final List<String> projects;

  /// Для создания — название новой задачи: из кавычек, а без них — остаток
  /// фразы после команды, срока, меток и вежливых слов.
  ///
  /// Для переноса и завершения — только точное название в кавычках.
  /// Название без кавычек для них — это [targetQuery].
  final String? title;

  /// Для переноса и завершения без кавычек: слова, по которым ищется задача
  /// («Перенеси отчёт на завтра» → «Отчёт»). `null`, если кроме команды,
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

  ParsedCommand parse(String message) =>
      parseUtterance(Utterance.analyze(message, now: _clock.now()));

  /// Разбор уже проанализированного сообщения: так коннектор не строит
  /// [Utterance] второй раз.
  ParsedCommand parseUtterance(Utterance utterance) {
    final words = utterance.words;
    if (words.isEmpty && utterance.quotedTitles.isEmpty) {
      return const ParsedCommand(intent: CommandIntent.unknown);
    }

    final marker = _detectIntent(utterance);
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

    switch (intent) {
      case CommandIntent.createTask:
        return ParsedCommand(
          intent: intent,
          title: hasQuotes
              ? quoted
              : _createTitle(utterance, marker.index, marker.length),
          dueAt: due.dueAt,
          duePrecision: due.precision,
          dueIssue: due.issue,
          titleIssue: titleIssue,
          projects: <String>[
            for (final tag in utterance.hashtags) tag.name,
          ],
        );
      case CommandIntent.rescheduleTask:
        return ParsedCommand(
          intent: intent,
          title: quoted,
          targetQuery: hasQuotes
              ? null
              : _targetQuery(utterance, marker.index, _rescheduleFiller),
          dueAt: due.dueAt,
          duePrecision: due.precision,
          dueIssue: due.issue,
          titleIssue: titleIssue,
        );
      case CommandIntent.completeTask:
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
      case CommandIntent.unknown:
        return ParsedCommand(intent: intent);
    }
  }

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
    'дело',
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

  /// Название новой задачи без кавычек или `null`, если ничего не осталось.
  String? _createTitle(Utterance utterance, int markerIndex, int length) {
    final tokens = utterance.tokens;
    final dueSpans = utterance.due.spans;
    final remove = <CharSpan>[
      ...dueSpans,
      ..._leadInSpans(utterance, markerIndex),
    ];
    for (var i = markerIndex; i < markerIndex + length; i++) {
      remove.add(tokens[i].span);
    }

    // Продолжение маркера: «мне», «пожалуйста», «задачу», «в список»,
    // а после «напомни» — «что»/«чтобы». Срок между ними пропускается:
    // «Добавь на завтра задачу купить хлеб».
    final remind = _remindVerbs.contains(tokens[markerIndex].text);
    var nounTaken = length > 1; // «новая задача» уже содержит существительное
    var conjunctionTaken = false;
    var i = markerIndex + length;
    while (i < tokens.length) {
      final token = tokens[i];
      final word = token.text;
      if (Utterance.isCovered(token, dueSpans)) {
        i++;
        continue;
      }
      if (_politeWords.contains(word) || _addressees.contains(word)) {
        remove.add(token.span);
        i++;
        continue;
      }
      if (!nounTaken && _objectNouns.contains(word)) {
        remove.add(token.span);
        nounTaken = true;
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
      if (remind && !conjunctionTaken && _remindConjunctions.contains(word)) {
        remove.add(token.span);
        conjunctionTaken = true;
        i++;
        continue;
      }
      break;
    }

    _trimEdgeWords(utterance, remove, _politeWords);
    final text = utterance.remainder(remove);
    return text.isEmpty ? null : Utterance.capitalize(text);
  }

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
      if (!_leadIns.contains(token.text)) break;
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
    if (utterance.isQuestion ||
        utterance.quotedTitles.isNotEmpty ||
        utterance.unbalancedQuotes) {
      return null;
    }
    final due = utterance.due;
    final tokens = utterance.tokens;
    final remove = <CharSpan>[...due.spans];
    // «Привет, купить хлеб», «пока не забыл, купить хлеб».
    var i = SocialPrefix.length(utterance);
    for (var k = 0; k < i; k++) {
      remove.add(tokens[k].span);
    }
    while (i < tokens.length) {
      final token = tokens[i];
      if (Utterance.isCovered(token, due.spans)) {
        i++;
        continue;
      }
      if (_implicitLeadIns.contains(token.text)) {
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
        i += 2;
        continue;
      }
      break;
    }
    if (i >= tokens.length) return null;
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
    final text = utterance.remainder(remove);
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
    'и',
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
        utterance.quotedTitles.isNotEmpty ||
        utterance.unbalancedQuotes) {
      return null;
    }
    final remove = <CharSpan>[
      ...utterance.due.spans,
      for (final token in utterance.tokens)
        if (_pastFiller.contains(token.text)) token.span,
    ];
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
    // «Я купил», «звонил» без предмета: по одному глаголу задачу не угадать.
    if (rest.every((UtteranceToken t) => VerbForms.stem(t.text) != null)) {
      return null;
    }
    final text = utterance.remainder(remove);
    if (text.isEmpty) return null;
    return ParsedCommand(
      intent: CommandIntent.completeTask,
      targetQuery: Utterance.capitalize(text),
      implicit: true,
      pastTense: true,
    );
  }

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
    'как',
    'отметь',
    'отметьте',
    'отметить',
    'пометь',
    'пометить',
    'выполненная',
    'готова',
  };

  static const Set<String> _rescheduleFiller = <String>{
    ..._targetFiller,
  };

  String? _targetQuery(
    Utterance utterance,
    int markerIndex,
    Set<String> filler,
  ) {
    final remove = <CharSpan>[
      ...utterance.due.spans,
      ..._leadInSpans(utterance, markerIndex),
      utterance.tokens[markerIndex].span,
      for (final token in utterance.tokens)
        if (filler.contains(token.text)) token.span,
    ];
    final text = utterance.remainder(remove);
    return text.isEmpty ? null : Utterance.capitalize(text);
  }

  // ------------------------------------------------------------ намерение

  _Marker _detectIntent(Utterance utterance) {
    final words = utterance.words;
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
      final create =
          _isTitleHeading(utterance, i) ? 1 : _createLength(word, i, words);
      if (create > 0) {
        return negated
            ? const _Marker.unknown()
            : _Marker(CommandIntent.createTask, i, create);
      }
      if (_isReschedule(word)) {
        return negated
            ? const _Marker.unknown()
            : _Marker(CommandIntent.rescheduleTask, i, 1);
      }
      if (_isComplete(word, i)) {
        // «Не выполнено», «Не выполнил отчёт», «Что выполнить?» — не команда.
        // Отрицание дальше по фразе относится к названию: «Заверши не
        // забыть купить хлеб».
        if (negated || startsWithNegation || utterance.isQuestion) {
          return const _Marker.unknown();
        }
        return _Marker(CommandIntent.completeTask, i, 1);
      }
      if (_isList(word, words)) return _Marker(CommandIntent.listTasks, i, 1);
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

  /// Есть ли после глагола в позиции [index] существительное «задачу»
  /// (через «мне», «пожалуйста», «новую»): «поставь мне новую задачу».
  bool _nounFollows(int index, List<String> words) {
    for (var i = index + 1; i < words.length && i <= index + 3; i++) {
      final word = words[i];
      if (_objectNouns.contains(word)) return true;
      if (_addressees.contains(word) ||
          _politeWords.contains(word) ||
          _newAdjectives.contains(word)) {
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

  /// Сколько слов занимает маркер создания в позиции [index]; 0 — не он.
  int _createLength(String word, int index, List<String> words) {
    if (_createVerbs.contains(word)) return 1;
    if (_createWithNounVerbs.contains(word) && _nounFollows(index, words)) {
      return 1;
    }
    final isNewTask = word == 'новая' &&
        index + 1 < words.length &&
        words[index + 1] == 'задача';
    return isNewTask ? 2 : 0;
  }

  bool _isReschedule(String word) =>
      word.startsWith('перенес') ||
      word.startsWith('передвин') ||
      word.startsWith('сдвин') ||
      word.startsWith('отлож');

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

  bool _isComplete(String word, int index) =>
      _completeWords.contains(word) ||
      (index == 0 && _completeInfinitives.contains(word));

  static const Set<String> _listVerbs = <String>{
    'покажи',
    'покажите',
    'показать',
    'выведи',
    'список',
    'какие',
  };

  bool _isList(String word, List<String> words) {
    if (word == 'запланировано') return true;
    return _listVerbs.contains(word) &&
        words.any((String w) => w.startsWith('задач') || w == 'дела');
  }
}

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
