import '../formatting/due_format.dart';
import '../models/assistant_types.dart';
import '../models/task.dart';
import '../services/clock.dart';
import '../services/task_service.dart';
import 'scenario_parser.dart';

final class AssistantController {
  AssistantController({
    required TaskService taskService,
    required ScenarioParser parser,
    Clock clock = const SystemClock(),
  })  : _tasks = taskService,
        _parser = parser,
        _clock = clock;

  /// Пример из подсказок интерфейса. Тест проверяет, что парсер его понимает.
  static const String exampleCommand =
      'Добавь задачу «Позвонить клиенту» на завтра в 11:00';

  final TaskService _tasks;
  final ScenarioParser _parser;
  final Clock _clock;
  ConversationContext _context = const ConversationContext();

  /// Задача, к которой относятся «её», «перенеси», «заверши».
  String? get selectedTaskId => _context.lastTaskId;

  void selectTask(String id) {
    _context = _context.withLastTask(id);
  }

  void clearSelection() {
    _context = _context.withoutTask();
  }

  /// Задачу завершили или удалили не через диалог.
  void forgetTask(String id) {
    if (_context.lastTaskId == id) clearSelection();
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
          return await _complete(command);
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
    final titleQuestion = _titleClarification(command.titleIssue);
    if (titleQuestion != null) {
      return AssistantResponse(
        message: titleQuestion,
        intent: 'task.create',
        status: AssistantStatus.needsClarification,
      );
    }
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
    final next = tasks.first;
    final nextDue = switch (next.dueAt) {
      null => '',
      final due => ', ${formatDue(due, next.duePrecision, _clock.now())}',
    };
    return AssistantResponse(
      message: 'Активных задач: ${tasks.length}. '
          'Ближайшая — «${next.title}»$nextDue.',
      intent: 'task.list',
      status: AssistantStatus.completed,
    );
  }

  Future<AssistantResponse> _complete(ParsedCommand command) async {
    final target = await _resolveTarget(
      command,
      intent: 'task.complete',
      noContextQuestion:
          'Какую задачу завершить? Сначала создайте или выберите задачу.',
    );
    if (target.clarification != null) return target.clarification!;
    final id = target.id!;
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
    final target = await _resolveTarget(
      command,
      intent: 'task.reschedule',
      noContextQuestion:
          'Какую задачу перенести? Пока в контексте нет выбранной задачи.',
    );
    if (target.clarification != null) return target.clarification!;
    final id = target.id!;
    final dueAt = command.dueAt;
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
    _context = _context.withLastTask(task.id);
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
      case DueIssue.invalidTime:
        return 'Не понял время. Укажите его в формате ЧЧ:ММ, например 18:30.';
      case DueIssue.conflictingDays:
        return 'В команде несколько разных дней. На какой день поставить задачу?';
      case DueIssue.conflictingTimes:
        return 'В команде несколько разных времён. На какое время поставить задачу?';
    }
  }

  String? _titleClarification(TitleIssue issue) {
    switch (issue) {
      case TitleIssue.none:
        return null;
      case TitleIssue.unbalancedQuotes:
        return 'Кавычка не закрыта. Повторите команду, указав название '
            'в парных кавычках, например «Отчёт».';
      case TitleIssue.multipleTitles:
        return 'В команде несколько названий. Давайте по одной задаче за раз.';
    }
  }

  /// Задача, к которой относится перенос или завершение: названная в кавычках
  /// или выбранная в контексте. Без однозначного ответа — уточнение.
  Future<_Target> _resolveTarget(
    ParsedCommand command, {
    required String intent,
    required String noContextQuestion,
  }) async {
    AssistantResponse ask(String message) => AssistantResponse(
          message: message,
          intent: intent,
          status: AssistantStatus.needsClarification,
        );

    final titleQuestion = _titleClarification(command.titleIssue);
    if (titleQuestion != null) return _Target.ask(ask(titleQuestion));

    final title = command.title;
    if (title != null) {
      final matches = await _tasks.findActiveByTitle(title);
      if (matches.isEmpty) {
        return _Target.ask(ask('Не нашёл активную задачу «$title».'));
      }
      if (matches.length > 1) {
        return _Target.ask(
          ask('Нашёл несколько задач «$title». Выберите нужную в списке.'),
        );
      }
      return _Target.id(matches.single.id);
    }

    final id = _context.lastTaskId;
    if (id == null) return _Target.ask(ask(noContextQuestion));
    return _Target.id(id);
  }

  String _dueDescription(Task task) {
    final due = task.dueAt;
    if (due == null) return '';
    return ' на ${formatDue(due, task.duePrecision, _clock.now())}';
  }
}

final class _Target {
  const _Target.id(String this.id) : clarification = null;

  const _Target.ask(AssistantResponse this.clarification) : id = null;

  final String? id;
  final AssistantResponse? clarification;
}
