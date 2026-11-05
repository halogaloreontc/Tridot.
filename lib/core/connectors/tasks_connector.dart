import '../formatting/due_format.dart';
import '../models/task.dart';
import '../scenario/scenario_parser.dart';
import '../services/task_service.dart';
import 'connector.dart';

/// Встроенный коннектор задач: создание, список, перенос и завершение.
///
/// Распознавание — [ScenarioParser], изменения — только через [TaskService].
/// Работает локально, без сети. Изменения задач — собственные данные
/// приложения, поэтому подтверждение ADR-004 к ним не применяется: каждое
/// действие видно в ответе и обратимо в интерфейсе.
final class TasksConnector implements Connector {
  TasksConnector({
    required TaskService taskService,
    required ScenarioParser parser,
  })  : _tasks = taskService,
        _parser = parser;

  static const String id = 'tasks';

  /// С какой оценки нечёткого поиска задача меняется без вопроса. Половины
  /// слов мало: в запросе из двух слов хватило бы одного общего глагола.
  static const double confidentScore = 0.6;

  /// Пример из подсказок интерфейса. Тест проверяет, что парсер его понимает.
  static const String exampleCommand =
      'Добавь задачу позвонить клиенту завтра в 11:00';

  final TaskService _tasks;
  final ScenarioParser _parser;

  @override
  ConnectorInfo get info => const ConnectorInfo(
        id: id,
        title: 'Задачи',
        description: 'Создаёт, показывает, переносит и завершает задачи.',
        examples: <String>[
          exampleCommand,
          'Добавь «Купить хлеб» на завтра',
          'Покажи задачи',
          'Перенеси отчёт на завтра в 15:00',
          'Заверши её',
        ],
        access: ConnectorAccess.readWrite,
      );

  @override
  ConnectorMatch? match(Utterance utterance) {
    final command = _parser.parseUtterance(utterance);
    final (commandId, confidence) = switch (command.intent) {
      CommandIntent.createTask => ('task.create', 0.9),
      CommandIntent.listTasks => ('task.list', 0.9),
      CommandIntent.rescheduleTask => ('task.reschedule', 0.85),
      CommandIntent.completeTask => ('task.complete', 0.8),
      CommandIntent.unknown => ('', 0.0),
    };
    if (command.intent == CommandIntent.unknown) return null;
    return ConnectorMatch(
      connectorId: id,
      commandId: commandId,
      confidence: confidence,
      payload: command,
    );
  }

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async {
    final command = match.payload! as ParsedCommand;
    switch (command.intent) {
      case CommandIntent.createTask:
        return _create(command, session);
      case CommandIntent.listTasks:
        return _list(session);
      case CommandIntent.completeTask:
        return _complete(command, session);
      case CommandIntent.rescheduleTask:
        return _reschedule(command, session);
      case CommandIntent.unknown:
        throw StateError('Коннектор задач не обрабатывает неизвестные команды');
    }
  }

  Future<AssistantResponse> _create(
    ParsedCommand command,
    AssistantSession session,
  ) async {
    final titleQuestion = _titleClarification(command.titleIssue);
    if (titleQuestion != null) {
      return _ask('task.create', titleQuestion);
    }
    final title = command.title;
    if (title == null || title.isEmpty) {
      return _ask(
        'task.create',
        'Как называется задача? Напишите, например: «Добавь задачу купить '
            'хлеб». Точное название можно взять в кавычки.',
      );
    }
    final dueQuestion = _dueClarification(command.dueIssue);
    if (dueQuestion != null) return _ask('task.create', dueQuestion);
    final task = await _tasks.create(
      title: title,
      dueAt: command.dueAt,
      duePrecision: command.duePrecision,
      tags: command.projects,
    );
    session.select(id, task.id);
    return AssistantResponse(
      message: 'Создал задачу «${task.title}»${_dueDescription(task, session)}'
          '${task.project == null ? '' : ' в проекте #${task.project}'}.',
      intent: 'task.create',
      status: AssistantStatus.completed,
      task: task,
    );
  }

  Future<AssistantResponse> _list(AssistantSession session) async {
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
      final due =>
        ', ${formatDue(due, next.duePrecision, session.clock.now())}',
    };
    return AssistantResponse(
      message: 'Активных задач: ${tasks.length}. '
          'Ближайшая — «${next.title}»$nextDue.',
      intent: 'task.list',
      status: AssistantStatus.completed,
    );
  }

  Future<AssistantResponse> _complete(
    ParsedCommand command,
    AssistantSession session,
  ) async {
    final target = await _resolveTarget(
      command,
      session,
      intent: 'task.complete',
      noContextQuestion:
          'Какую задачу завершить? Сначала создайте или выберите задачу.',
    );
    if (target.clarification != null) return target.clarification!;
    final task = await _tasks.complete(target.id!);
    // Завершённая задача больше не «её»: следующий перенос или завершение
    // требует нового выбора, а не тихо открывает её снова.
    session.forget(id, task.id);
    return AssistantResponse(
      message: 'Задача «${task.title}» завершена.',
      intent: 'task.complete',
      status: AssistantStatus.completed,
      task: task,
    );
  }

  Future<AssistantResponse> _reschedule(
    ParsedCommand command,
    AssistantSession session,
  ) async {
    final target = await _resolveTarget(
      command,
      session,
      intent: 'task.reschedule',
      noContextQuestion:
          'Какую задачу перенести? Пока в контексте нет выбранной задачи.',
    );
    if (target.clarification != null) return target.clarification!;
    final dueQuestion = _dueClarification(command.dueIssue);
    if (dueQuestion != null) return _ask('task.reschedule', dueQuestion);
    final dueAt = command.dueAt;
    if (dueAt == null) {
      return _ask(
        'task.reschedule',
        'На когда перенести задачу? Например: «на завтра в 15:00».',
      );
    }
    final task =
        await _tasks.reschedule(target.id!, dueAt, command.duePrecision);
    session.select(id, task.id);
    return AssistantResponse(
      message:
          'Перенёс задачу «${task.title}»${_dueDescription(task, session)}.',
      intent: 'task.reschedule',
      status: AssistantStatus.completed,
      task: task,
    );
  }

  AssistantResponse _ask(String intent, String message) => AssistantResponse(
        message: message,
        intent: intent,
        status: AssistantStatus.needsClarification,
      );

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
      case DueIssue.ambiguousHour:
        return 'Утра или вечера? Укажите время точнее, например «в 17:00» '
            'или «в 5 утра».';
    }
  }

  String? _titleClarification(TitleIssue issue) {
    switch (issue) {
      case TitleIssue.none:
        return null;
      case TitleIssue.unbalancedQuotes:
        return 'Кавычка не закрыта. Повторите команду, указав название '
            'в парных кавычках, например «Отчёт», или без кавычек.';
      case TitleIssue.multipleTitles:
        return 'В команде несколько названий. Давайте по одной задаче за раз.';
    }
  }

  /// Задача, к которой относится перенос или завершение.
  ///
  /// 1. Название в кавычках — только точное совпадение.
  /// 2. Слова без кавычек — сначала точное совпадение, затем нечёткий поиск
  ///    ([TaskService.searchActive]). Если ничего не нашлось, выбранная задача
  ///    не подставляется молча — пользователь назвал другую.
  /// 3. Без названия — выбранная задача.
  /// Без однозначного ответа — уточнение.
  Future<_Target> _resolveTarget(
    ParsedCommand command,
    AssistantSession session, {
    required String intent,
    required String noContextQuestion,
  }) async {
    final titleQuestion = _titleClarification(command.titleIssue);
    if (titleQuestion != null) return _Target.ask(_ask(intent, titleQuestion));

    final name = command.title ?? command.targetQuery;
    if (name != null) {
      final exact = await _tasks.findActiveByTitle(name);
      if (exact.length == 1) return _Target.id(exact.single.id);
      if (exact.length > 1) {
        return _Target.ask(
          _ask(
            intent,
            'Нашёл несколько задач «$name». Выберите нужную в списке.',
          ),
        );
      }
      if (command.title != null) {
        return _Target.ask(_ask(intent, 'Не нашёл активную задачу «$name».'));
      }
      final hits = await _tasks.searchActive(name);
      if (hits.isEmpty) {
        return _Target.ask(_ask(intent, 'Не нашёл активную задачу «$name».'));
      }
      final best = hits.first.score;
      final close = hits
          .where((TaskSearchHit h) => best - h.score <= 0.1 + 1e-9)
          .toList(growable: false);
      if (close.length == 1) {
        final hit = close.single;
        if (hit.score >= confidentScore) return _Target.id(hit.task.id);
        // Совпала только половина слов: «Заверши позвонить маме» при задаче
        // «Позвонить клиенту». Менять задачу по такой догадке нельзя.
        return _Target.ask(
          _ask(
            intent,
            'Вы про задачу «${hit.task.title}»? Напишите её название точнее '
            'или выберите задачу в списке.',
          ),
        );
      }
      final titles = close
          .take(3)
          .map((TaskSearchHit h) => '«${h.task.title}»')
          .join(', ');
      return _Target.ask(
        _ask(
          intent,
          'Под «$name» подходят несколько задач: $titles. '
          'Уточните название или выберите задачу в списке.',
        ),
      );
    }

    final selected = session.selectedItemFor(id);
    if (selected == null) return _Target.ask(_ask(intent, noContextQuestion));
    return _Target.id(selected);
  }

  String _dueDescription(Task task, AssistantSession session) {
    final due = task.dueAt;
    if (due == null) return '';
    return ' на ${formatDue(due, task.duePrecision, session.clock.now())}';
  }
}

final class _Target {
  const _Target.id(String this.id) : clarification = null;

  const _Target.ask(AssistantResponse this.clarification) : id = null;

  final String? id;
  final AssistantResponse? clarification;
}
