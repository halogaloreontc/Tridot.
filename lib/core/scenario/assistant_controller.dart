import '../models/assistant_types.dart';
import '../models/task.dart';
import '../services/task_service.dart';
import 'scenario_parser.dart';

final class AssistantController {
  AssistantController({
    required TaskService taskService,
    required ScenarioParser parser,
  })  : _tasks = taskService,
        _parser = parser;

  /// Пример из подсказок интерфейса. Тест проверяет, что парсер его понимает.
  static const String exampleCommand =
      'Добавь задачу «Позвонить клиенту» на завтра в 11:00';

  final TaskService _tasks;
  final ScenarioParser _parser;
  ConversationContext _context = const ConversationContext();

  void selectTask(String id) {
    _context = _context.withLastTask(id);
  }

  Future<AssistantResponse> handle(String message) async {
    final command = _parser.parse(message);
    try {
      switch (command.intent) {
        case CommandIntent.createTask:
          return await _create(command);
        case CommandIntent.listTasks:
          return await _list();
        case CommandIntent.completeTask:
          return await _complete();
        case CommandIntent.rescheduleTask:
          return await _reschedule(command);
        case CommandIntent.unknown:
          return const AssistantResponse(
            message:
                'Пока понимаю создание, список, перенос и завершение задач. '
                'Для создания укажите название в кавычках, например: '
                '$exampleCommand',
            intent: 'unknown',
            status: AssistantStatus.noAction,
          );
      }
    } catch (error) {
      return AssistantResponse(
        message: 'Не удалось выполнить действие: $error',
        intent: command.intent.name,
        status: AssistantStatus.failed,
      );
    }
  }

  Future<AssistantResponse> _create(ParsedCommand command) async {
    final title = command.title;
    if (title == null || title.isEmpty) {
      return const AssistantResponse(
        message:
            'Как называется задача? В прототипе укажите название в кавычках.',
        intent: 'task.create',
        status: AssistantStatus.needsClarification,
      );
    }
    final dueQuestion = _dueClarification(command.dueIssue);
    if (dueQuestion != null) {
      return AssistantResponse(
        message: dueQuestion,
        intent: 'task.create',
        status: AssistantStatus.needsClarification,
      );
    }
    final task = await _tasks.create(
      title: title,
      dueAt: command.dueAt,
      duePrecision: command.duePrecision,
    );
    _context = _context.withLastTask(task.id);
    return AssistantResponse(
      message: 'Создал задачу «${task.title}»${_dueDescription(task)}.',
      intent: 'task.create',
      status: AssistantStatus.completed,
      task: task,
    );
  }

  Future<AssistantResponse> _list() async {
    final tasks = await _tasks.listActive();
    if (tasks.isEmpty) {
      return const AssistantResponse(
        message: 'Активных задач пока нет.',
        intent: 'task.list',
        status: AssistantStatus.completed,
      );
    }
    return AssistantResponse(
      message: 'Активных задач: ${tasks.length}. Они показаны в списке.',
      intent: 'task.list',
      status: AssistantStatus.completed,
    );
  }

  Future<AssistantResponse> _complete() async {
    final id = _context.lastTaskId;
    if (id == null) {
      return const AssistantResponse(
        message:
            'Какую задачу завершить? Сначала создайте или выберите задачу.',
        intent: 'task.complete',
        status: AssistantStatus.needsClarification,
      );
    }
    final task = await _tasks.complete(id);
    // Завершённая задача больше не «её»: следующий перенос или завершение
    // требует нового выбора, а не тихо открывает её снова.
    _context = _context.withoutTask();
    return AssistantResponse(
      message: 'Задача «${task.title}» завершена.',
      intent: 'task.complete',
      status: AssistantStatus.completed,
      task: task,
    );
  }

  Future<AssistantResponse> _reschedule(ParsedCommand command) async {
    final id = _context.lastTaskId;
    final dueAt = command.dueAt;
    if (id == null) {
      return const AssistantResponse(
        message:
            'Какую задачу перенести? Пока в контексте нет выбранной задачи.',
        intent: 'task.reschedule',
        status: AssistantStatus.needsClarification,
      );
    }
    final dueQuestion = _dueClarification(command.dueIssue);
    if (dueQuestion != null) {
      return AssistantResponse(
        message: dueQuestion,
        intent: 'task.reschedule',
        status: AssistantStatus.needsClarification,
      );
    }
    if (dueAt == null) {
      return const AssistantResponse(
        message: 'На когда перенести задачу? Например: «на завтра в 15:00».',
        intent: 'task.reschedule',
        status: AssistantStatus.needsClarification,
      );
    }
    final task = await _tasks.reschedule(id, dueAt, command.duePrecision);
    return AssistantResponse(
      message: 'Перенёс задачу «${task.title}»${_dueDescription(task)}.',
      intent: 'task.reschedule',
      status: AssistantStatus.completed,
      task: task,
    );
  }

  String? _dueClarification(DueIssue issue) {
    switch (issue) {
      case DueIssue.none:
        return null;
      case DueIssue.inPast:
        return 'Это время уже прошло. Укажите другое время или день, '
            'например: «на завтра в 10:00».';
      case DueIssue.invalidDate:
        return 'Такой даты нет. Укажите дату в формате ДД.ММ, например 15.11.';
      case DueIssue.conflictingDays:
        return 'В команде несколько разных дней. На какой день поставить задачу?';
    }
  }

  String _dueDescription(Task task) {
    final due = task.dueAt;
    if (due == null) return '';
    final day =
        '${due.day.toString().padLeft(2, '0')}.${due.month.toString().padLeft(2, '0')}.${due.year}';
    if (task.duePrecision == DuePrecision.date) return ' на $day';
    final time =
        '${due.hour.toString().padLeft(2, '0')}:${due.minute.toString().padLeft(2, '0')}';
    return ' на $day в $time';
  }
}
