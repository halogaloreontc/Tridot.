import 'utterance.dart';

/// Разговорное вступление перед командой: приветствие, благодарность,
/// короткий отклик, обращение к помощнику, «пока не забыл».
///
/// «Ну привет, добавь задачу хлеб», «привет, Нода, добавь задачу хлеб»,
/// «привет, как дела, добавь задачу хлеб», «отлично, добавь задачу
/// молоко», «привет, пока не забыл купить хлеб», «спасибо, сколько будет
/// 3*3» — команда без вступления. Такая фраза — команда, а не реплика
/// беседы: беседа берёт сообщение, только если в нём нет команды.
abstract final class SocialPrefix {
  /// Приветствие и благодарность одним словом: разделитель после них не
  /// нужен («привет добавь задачу»).
  static const Set<String> _socialWords = <String>{
    'привет',
    'приветик',
    'приветствую',
    'здравствуй',
    'здравствуйте',
    'здрасте',
    'здрасьте',
    'хай',
    'йо',
    'салют',
    'спасибо',
    'спс',
    'благодарю',
  };

  /// Отклик одним словом: вступление, только если за ним знак
  /// («отлично, добавь…»). Без знака это может быть частью названия:
  /// «хорошо выспаться».
  static const Set<String> _reactionWords = <String>{
    'ок',
    'окей',
    'да',
    'ага',
    'угу',
    'нет',
    'конечно',
    'хорошо',
    'ладно',
    'отлично',
    'супер',
    'круто',
    'класс',
    'классно',
    'здорово',
    'понял',
    'поняла',
    'понятно',
    'ясно',
  };

  /// Слова, которые ничего не значат в начале: «ну привет», «эй, привет».
  static const Set<String> _fillers = <String>{'ну', 'эй', 'а', 'и'};

  /// «Добрый день», «доброе утро» — приветствие из двух слов.
  static const Set<String> _goodWords = <String>{'добрый', 'доброе', 'доброй'};

  static const Set<String> _dayParts = <String>{
    'день',
    'утро',
    'вечер',
    'ночи',
  };

  /// «Пока не забыл», «пока помню» — вступление, а не прощание.
  static const Set<String> _forgotWords = <String>{
    'забыл',
    'забыла',
    'забыли',
  };

  /// Имена помощников: после приветствия — обращение («привет, Нода, …»).
  static const Set<String> _names = <String>{'rio', 'noda', 'рио', 'нода'};

  /// «Как дела», «как ты» после приветствия.
  static const Set<String> _howWords = <String>{'дела', 'ты', 'вы', 'жизнь'};

  static final RegExp _separator = RegExp(r'[,!.:;—–-]');

  /// Сколько первых слов [utterance] — вступление. 0 — вступления нет.
  static int length(Utterance utterance) {
    final tokens = utterance.tokens;
    final original = utterance.original;
    bool separated(int i) =>
        i + 1 < tokens.length &&
        _separator.hasMatch(
          original.substring(tokens[i].span.end, tokens[i + 1].span.start),
        );
    var i = 0;
    var end = 0;
    var greeted = false;
    while (i < tokens.length) {
      final word = tokens[i].text;
      final next = i + 1 < tokens.length ? tokens[i + 1].text : null;
      if (_fillers.contains(word)) {
        i++;
        continue;
      }
      if (word == 'всем' && next == 'привет') {
        i += 2;
      } else if ((word == 'спасибо' && next == 'большое') ||
          (word == 'большое' && next == 'спасибо')) {
        i += 2;
      } else if (_socialWords.contains(word)) {
        i++;
      } else if (_goodWords.contains(word) &&
          next != null &&
          _dayParts.contains(next)) {
        i += 2;
      } else if (word == 'пока' && next == 'помню') {
        i += 2;
      } else if (word == 'пока' &&
          next == 'не' &&
          i + 2 < tokens.length &&
          _forgotWords.contains(tokens[i + 2].text)) {
        i += 3;
      } else if (greeted && _names.contains(word)) {
        i++;
      } else if (greeted &&
          word == 'как' &&
          next != null &&
          _howWords.contains(next)) {
        i += 2;
      } else if (_reactionWords.contains(word) && separated(i)) {
        i++;
      } else {
        break;
      }
      greeted = true;
      end = i;
    }
    return end;
  }

  /// Текст [utterance] после вступления — для разбора, которому нужен
  /// сам текст (калькулятор). `null` — вступления нет или после него
  /// ничего не осталось.
  static String? rest(Utterance utterance) {
    final count = length(utterance);
    if (count == 0 || count >= utterance.tokens.length) return null;
    final text = utterance.original
        .substring(utterance.tokens[count - 1].span.end)
        .replaceFirst(_leading, '');
    return text.trim().isEmpty ? null : text;
  }

  /// Знаки между вступлением и командой. Минус перед числом не трогаем:
  /// «привет, -2+3».
  static final RegExp _leading = RegExp(r'^[\s,!.:;…]*(?:[—–-](?=\s))?\s*');
}
