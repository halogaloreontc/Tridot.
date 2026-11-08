import '../personas/persona.dart';
import 'bulk.dart';
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
    this.addressedPersonaId,
    this.checklist,
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

  /// К кому пользователь обратился по имени в этом сообщении (только в
  /// дуэте): «Нода, расскажи шутку», «спасибо, Нода», «Нода». Интерфейс
  /// делает его адресатом чата (`AssistantController.addresseeAfter`):
  /// «к кому обратились, тот и продолжает». `null` — по имени не обращались.
  final String? addressedPersonaId;

  /// Вопрос массовой команды со списком задач: интерфейс показывает под
  /// ответом карточку с галочками. Тот же объект ждёт ответа в сессии,
  /// поэтому отметки в карточке видны ответу «да». `null` — без списка.
  final BulkChecklist? checklist;

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
        addressedPersonaId: addressedPersonaId,
        checklist: checklist,
      );

  /// Тот же ответ, в котором пользователь обратился к [personaId] по имени.
  AssistantResponse withAddressed(String personaId) => AssistantResponse(
        message: message,
        intent: intent,
        status: status,
        task: task,
        replyId: replyId,
        values: values,
        personaId: this.personaId,
        settingsChange: settingsChange,
        addressedPersonaId: personaId,
        checklist: checklist,
      );
}
