import 'task.dart';

enum AssistantStatus { completed, needsClarification, failed, noAction }

final class AssistantResponse {
  const AssistantResponse({
    required this.message,
    required this.intent,
    required this.status,
    this.task,
  });

  final String message;
  final String intent;
  final AssistantStatus status;
  final Task? task;
}
