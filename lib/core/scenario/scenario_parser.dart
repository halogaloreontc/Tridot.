import '../connectors/due_parser.dart';
import '../connectors/noun_forms.dart';
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

  ParsedCommand parse(String message) =>
      parseUtterance(Utterance.analyze(message, now: _clock.now()));

  /// Разбор уже проанализированного сообщения: так коннектор не строит
  /// [Utterance] второй раз.
  ParsedCommand parseUtterance(Utterance utterance) {
    final words = utterance.words;
    if (words.isEmpty && utterance.quotedTitles.isEmpty) {
      return const ParsedCommand(intent: CommandIntent.unknown);
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
  String? _createTitle(Utterance utterance, int markerIndex, int length) {
    final tokens = utterance.tokens;
    final dueSpans = utterance.due.spans;
    final remove = <CharSpan>[
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
    final text = utterance.remainder(remove);
    if (text.isEmpty) return null;
    if (signUp) return 'Записаться $text';
    return Utterance.capitalize(NounForms.nominative(text));
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
      final text = utterance.remainder(remove);
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
    final text = utterance.remainder(remove);
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
    final text = utterance.remainder(remove);
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
    Set<String> filler,
  ) {
    final tokens = utterance.tokens;
    final complete = identical(filler, _completeFiller);
    final dueSpans = <CharSpan>[
      for (final span in utterance.due.spans)
        // «заверши задачу про 15 ноября»: дата здесь — название задачи.
        if (!complete || !_followsAbout(utterance, span)) span,
    ];
    final remove = <CharSpan>[
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
    final text = utterance.remainder(remove);
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
    if (_createWithNounVerbs.contains(word) && _nounFollows(index, words)) {
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
  static bool _isDoneWord(String word) =>
      word.startsWith('выполненн') ||
      word.startsWith('завершенн') ||
      word.startsWith('сделанн') ||
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

  bool _isList(String word, List<String> words) {
    if (word == 'запланировано') return true;
    return _listVerbs.contains(word) &&
        words.any((String w) => w.startsWith('задач') || w == 'дела');
  }
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
