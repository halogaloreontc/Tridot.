import 'package:characters/characters.dart';

import 'chat_models.dart';

/// Вторая строка сессии в меню: что ответил помощник последним (ADR-010).
///
/// Только из уже сохранённого текста (он прошёл SecretGuard и выходной
/// фильтр помощника). Карточка «Паролей», карточка действия и список
/// массовой команды в меню не пересказываются — вместо них нейтральная
/// фраза. Чистый Dart.
abstract final class ChatPreview {
  /// Вместо временной карточки «Паролей» и ответов навыков с секретами.
  static const String secure = 'Защищённая карточка';

  /// Вместо карточки действия с записью (ADR-013).
  static const String action = 'Карточка действия';

  /// Вместо списка массовой команды.
  static const String checklist = 'Список задач';

  /// Длина строки, дальше — «…».
  static const int limit = 80;

  /// Строка для ответа [message]; `null` — это не ответ помощника
  /// (команды пользователя и служебные строки превью не дают).
  static String? of(ChatMessage message, {bool sensitive = false}) {
    if (message.author != ChatAuthor.persona) return null;
    if (sensitive || message.secureCard != null) return secure;
    if (message.card != null) return action;
    if (message.checklist != null) return checklist;
    return line(message.text);
  }

  /// Текст одной строкой: пробелы и переводы строк схлопнуты, не длиннее
  /// [limit] знаков. Пустой — `null`.
  static String? line(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return null;
    // Считаем видимые знаки: эмодзи не режется пополам.
    final chars = flat.characters;
    if (chars.length <= limit) return flat;
    return '${chars.take(limit - 1).toString().trimRight()}…';
  }
}
