import '../connectors/due_parser.dart';
import '../connectors/utterance.dart';
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
  });

  final CommandIntent intent;

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
        return ParsedCommand(
          intent: intent,
          title: quoted,
          targetQuery: hasQuotes
              ? null
              : _targetQuery(utterance, marker.index, _completeFiller),
          titleIssue: titleIssue,
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

  /// Вступление перед маркером: слова из [_leadIns] и срок с самого начала
  /// фразы до первого другого слова.
  List<CharSpan> _leadInSpans(Utterance utterance, int markerIndex) {
    final result = <CharSpan>[];
    for (var i = 0; i < markerIndex; i++) {
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
      final create = _createLength(word, i, words);
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
    return const _Marker.unknown();
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

  /// Сколько слов занимает маркер создания в позиции [index]; 0 — не он.
  int _createLength(String word, int index, List<String> words) {
    if (_createVerbs.contains(word)) return 1;
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
  const _Marker(this.intent, this.index, this.length);

  const _Marker.unknown()
      : intent = CommandIntent.unknown,
        index = -1,
        length = 0;

  final CommandIntent intent;

  /// Номер первого слова маркера в [Utterance.tokens].
  final int index;

  /// Сколько слов занимает маркер.
  final int length;
}
