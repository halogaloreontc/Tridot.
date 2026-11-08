import '../scenario/scenario_parser.dart';
import '../skills/talk/talk_phrases.dart';
import 'utterance.dart';

/// Короткие фразы, понятные только в чате задачи (docs/CONNECTORS.md,
/// «Чат задачи»): задача — сам чат, поэтому объект не нужен.
///
/// - «закрой», «закрывай», «закрой её», «можно закрывать», «отметь»,
///   «выполнена», «готова» — завершить задачу чата;
/// - фраза, которая целиком — срок: «на завтра», «на пятницу в 10»,
///   «завтра в 9», «давай на понедельник» — перенести её.
///
/// В главном чате эти фразы по-прежнему не распознаются: там неясно, о
/// какой задаче речь. Фразы, которые понимает обычный разбор («готово»,
/// «перенеси на завтра»), сюда не попадают. Реплики беседы тоже: «до
/// завтра», «до понедельника» — прощание, а не перенос.
abstract final class TaskChatPhrases {
  /// Слова, без которых фраза — не просьба закрыть задачу.
  static const Set<String> _completeVerbs = <String>{
    'закрой',
    'закрывай',
    'закрываем',
    'закрыть',
    'закрывать',
    'закрыта',
    'закрыто',
    'отметь',
    'отмечай',
    'выполнена',
    'готова',
    'сделана',
    'завершена',
    'завершено',
  };

  /// Что ещё может стоять рядом: «закрой её», «можно закрывать», «ну всё,
  /// закрывай».
  static const Set<String> _completeExtras = <String>{
    'ее',
    'её',
    'это',
    'эту',
    'задачу',
    'задача',
    'можно',
    'уже',
    'ну',
    'все',
    'всё',
    'давай',
    'тогда',
    'пожалуйста',
    'спасибо',
    'как',
    'выполненной',
    'сделанной',
    'она',
    'и',
  };

  /// Служебные слова вокруг срока: «давай на понедельник», «тогда на
  /// завтра», «лучше в пятницу».
  static const Set<String> _dueExtras = <String>{
    'на',
    'давай',
    'тогда',
    'лучше',
    'пусть',
    'перенеси',
    'ну',
    'пожалуйста',
    'можно',
    'её',
    'ее',
    'будет',
  };

  /// Слова после «готово», которые не название задачи: «готово,
  /// спасибо», «сделано, ура», «выполнено, наконец-то».
  static const Set<String> _fillers = <String>{
    'спасибо',
    'спс',
    'благодарю',
    'мерси',
    'большое',
    'огромное',
    'ура',
    'урра',
    'наконец',
    'наконец-то',
    'наконецто',
    'отлично',
    'отличненько',
    'супер',
    'класс',
    'круто',
    'клево',
    'клёво',
    'хорошо',
    'замечательно',
    'прекрасно',
    'ок',
    'окей',
    'ладно',
    'фух',
    'фу',
    'уф',
    'уфф',
    'юху',
    'йес',
    'ну',
    'вот',
    'так',
    'и',
    'да',
    'ага',
    'все',
    'всё',
    'тогда',
    'пожалуйста',
    'молодец',
    'умница',
  };

  /// [query] из «готово, …» — не название задачи, а междометие или
  /// благодарность: цель — задача чата.
  static bool isFiller(String query) {
    final words = query
        .toLowerCase()
        .split(RegExp(r'[^0-9a-zа-яё-]+'))
        .where((String w) => w.isNotEmpty)
        .toList(growable: false);
    return words.isNotEmpty && words.every(_fillers.contains);
  }

  /// Команда для [utterance] в чате задачи или `null`, если фраза не из
  /// этих. Цели у команды нет: её подставит коннектор (задача чата).
  static ParsedCommand? match(Utterance utterance) {
    if (utterance.chatTaskId == null) return null;
    // «До завтра», «спокойной ночи» — беседа, даже если это целиком срок.
    if (TalkPhrases.recognize(utterance.original) != null) return null;
    if (utterance.quotedTitles.isNotEmpty ||
        utterance.hashtags.isNotEmpty ||
        utterance.unbalancedQuotes ||
        utterance.isQuestion) {
      return null;
    }
    final words = utterance.words;
    if (words.isEmpty) return null;
    final due = utterance.due;
    if (due.spans.isEmpty) {
      if (words.any(_completeVerbs.contains) &&
          words.every(
            (String w) =>
                _completeVerbs.contains(w) || _completeExtras.contains(w),
          )) {
        return const ParsedCommand(intent: CommandIntent.completeTask);
      }
      return null;
    }
    // «До понедельника», «до встречи в пятницу» — прощание: просьба
    // перенести звучит иначе («на понедельник»).
    if (words.first == 'до') return null;
    final rest = utterance.tokensOutside(due.spans);
    if (!rest.every((UtteranceToken t) => _dueExtras.contains(t.text))) {
      return null;
    }
    return ParsedCommand(
      intent: CommandIntent.rescheduleTask,
      dueAt: due.dueAt,
      duePrecision: due.dueAt == null ? null : due.precision,
      dueIssue: due.issue,
    );
  }
}
