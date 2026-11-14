import 'chat_models.dart';

/// Найденное в сессиях место: чат, название, автор и отрывок вокруг
/// совпадения (поиск в меню, ADR-015).
///
/// Ищется только в уже очищенных текстах сообщений и названиях чатов.
/// Карточки «Паролей» ([ChatMessage.secureCard]) и само хранилище паролей
/// поиск не трогает никогда.
final class ChatSearchHit {
  const ChatSearchHit({
    required this.chatId,
    required this.title,
    required this.at,
    required this.snippet,
    required this.matchStart,
    required this.matchEnd,
    this.personaId,
    this.messageId,
    this.projectName,
  });

  /// Проект-папка чата (подпись «Проект · …» у результата); `null` — вне
  /// проектов.
  final String? projectName;

  final String chatId;

  /// Название чата, как в меню.
  final String title;

  /// Кто написал найденное сообщение; `null` — пользователь или совпало
  /// название.
  final String? personaId;

  /// Найденное сообщение; `null` — совпало название чата.
  final String? messageId;

  /// Время найденного сообщения (или последней активности чата).
  final DateTime at;

  /// Отрывок около [ChatSearch.snippetLength] знаков, с «…» по краям,
  /// если обрезан.
  final String snippet;

  /// Где в [snippet] совпадение: [matchStart] включительно, [matchEnd] —
  /// нет.
  final int matchStart;
  final int matchEnd;
}

/// Сравнение для поиска: без регистра, «ё» = «е».
abstract final class ChatSearch {
  /// Длина отрывка вокруг совпадения.
  static const int snippetLength = 60;

  /// Строка для сравнения той же длины, что исходная: позиции совпадений
  /// в ней — позиции в исходном тексте.
  static String fold(String text) => text.toLowerCase().replaceAll('ё', 'е');

  /// Отрывок [text] вокруг совпадения [start]..[end] и позиции совпадения
  /// в отрывке.
  static (String, int, int) snippet(String text, int start, int end) {
    final flat = text.replaceAll(RegExp(r'\s'), ' ');
    final room = snippetLength - (end - start);
    var from = start - (room > 0 ? room ~/ 3 : 0);
    if (from < 0) from = 0;
    var to = from + snippetLength;
    if (to < end) to = end;
    if (to > flat.length) to = flat.length;
    if (to - from < snippetLength) {
      from = to - snippetLength;
      if (from < 0) from = 0;
    }
    final head = from > 0 ? '…' : '';
    final tail = to < flat.length ? '…' : '';
    final body = flat.substring(from, to);
    return (
      '$head$body$tail',
      head.length + start - from,
      head.length + end - from,
    );
  }
}
