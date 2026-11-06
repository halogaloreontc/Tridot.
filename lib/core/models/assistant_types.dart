import '../personas/persona.dart';
import 'task.dart';

enum AssistantStatus { completed, needsClarification, failed, noAction }

final class AssistantResponse {
  const AssistantResponse({
    required this.message,
    required this.intent,
    required this.status,
    this.task,
    this.replyId,
    this.values = const <String, String>{},
    this.personaId,
    this.settingsChange,
  });

  /// Готовый текст для пользователя. В истории чата хранится именно он:
  /// смена стиля или помощника старые ответы не переписывает.
  final String message;
  final String intent;
  final AssistantStatus status;
  final Task? task;

  /// Запись каталога ответов, из которой получен [message]; `null` —
  /// текст коннектора не из каталога.
  final String? replyId;

  /// Факты, подставленные в запись [replyId].
  final Map<String, String> values;

  /// Кто из помощников ответил (`rio`, `noda`); `null` — ещё не назначен.
  final String? personaId;

  /// Просьба изменить настройки помощников («говори короче»): интерфейс
  /// применяет её тем же путём, что и экран настроек. `null` — настройки
  /// не меняются.
  final PersonaSettingsChange? settingsChange;

  /// Тот же ответ от помощника [personaId].
  AssistantResponse withPersona(String personaId) => AssistantResponse(
        message: message,
        intent: intent,
        status: status,
        task: task,
        replyId: replyId,
        values: values,
        personaId: personaId,
        settingsChange: settingsChange,
      );
}
