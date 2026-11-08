import '../formatting/due_format.dart';
import '../models/task.dart';
import '../replies/reply_library.dart';
import '../scenario/scenario_parser.dart';
import '../services/task_service.dart';
import '../skills/talk/talk_phrases.dart';
import 'connector.dart';

/// Встроенный коннектор задач: создание, список, перенос и завершение.
///
/// Распознавание — [ScenarioParser], изменения — только через [TaskService].
/// Работает локально, без сети. Изменения задач — собственные данные
/// приложения, поэтому подтверждение ADR-004 к явным командам не
/// применяется: каждое действие видно в ответе и обратимо в интерфейсе.
/// Подтверждение нужно только завершению по сообщению о сделанном
/// («я купил хлеб»): задача угадана по словам, а не названа командой.
final class TasksConnector implements Connector, ConnectorHealth {
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

  /// Ответ на фразу, которую никто не понял. Его же даёт коннектор, когда
  /// сообщение о сделанном («я купил хлеб») не подходит ни к одной задаче:
  /// тогда фраза, скорее всего, была не о задачах.
  ///
  /// Здесь — нейтральный текст; в разговоре он звучит голосом помощника
  /// ([unknown]).
  static final AssistantResponse unknownResponse = AssistantResponse(
    message: ReplyLibrary.builtIn.render(
      const Reply(unknownReply, <String, String>{'example': exampleCommand}),
      const ReplyVoice(),
    ),
    intent: 'unknown',
    status: AssistantStatus.noAction,
    replyId: unknownReply,
    values: const <String, String>{'example': exampleCommand},
  );

  static const String unknownReply = 'common.unknown';

  /// «Не понял» голосом текущего помощника.
  static AssistantResponse unknown(AssistantSession session) => session.reply(
        unknownReply,
        values: const <String, String>{'example': exampleCommand},
        intent: 'unknown',
        status: AssistantStatus.noAction,
      );

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
        kind: ExtensionKind.skill,
        // Без задач помощник теряет смысл: навык не выключается.
        required: true,
      );

  /// Задачи в порядке, если их можно прочитать.
  @override
  Future<HealthReport> health() async {
    try {
      await _tasks.listActive();
      return const HealthReport.ok();
    } on Object catch (error) {
      return HealthReport(
        HealthStatus.down,
        detail: 'не удалось прочитать задачи: $error',
      );
    }
  }

  @override
  ConnectorMatch? match(Utterance utterance) {
    final command = _parser.parseUtterance(utterance);
    final (commandId, confidence) = switch (command.intent) {
      // Без маркера — ниже явных команд любого коннектора: «через 3 дня
      // сдать отчёт» с явным сроком увереннее, чем «купить хлеб».
      CommandIntent.createTask when command.implicit => (
          'task.create',
          utterance.due.spans.isEmpty ? 0.6 : 0.75,
        ),
      CommandIntent.createTask => ('task.create', 0.9),
      CommandIntent.listTasks => ('task.list', 0.9),
      CommandIntent.rescheduleTask => ('task.reschedule', 0.85),
      CommandIntent.completeTask when command.implicit => (
          'task.complete',
          0.6,
        ),
      CommandIntent.completeTask => ('task.complete', 0.8),
      CommandIntent.unknown => ('', 0.0),
    };
    if (command.intent == CommandIntent.unknown) return null;
    if (_isTalk(utterance, command)) return null;
    return ConnectorMatch(
      connectorId: id,
      commandId: commandId,
      confidence: confidence,
      payload: command,
      implicit: command.implicit,
    );
  }

  /// Реплика беседы целиком — не задача, даже если разбор задач нашёл
  /// в ней поручение. Без маркера разбор угадывает по форме слов: «хочу
  /// посмеяться» — будто дело «Посмеяться», «расскажи прикол» — будто
  /// отчёт о сделанном. С маркером уступает только просьба о стиле ответов:
  /// «добавь смайликов в ответы» — про ответы помощника, не задача.
  /// Беседа узнаёт лишь короткую реплику целиком ([TalkPhrases]), поэтому
  /// команда с любым лишним словом («добавь задачу рассказать шутку»)
  /// остаётся задачей.
  static bool _isTalk(Utterance utterance, ParsedCommand command) {
    final talk = TalkPhrases.recognize(utterance.original);
    if (talk == null) return false;
    return command.implicit || talk.topic == TalkTopic.setting;
  }

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async {
    final payload = match.payload;
    if (payload is ConfirmationAnswer) return _answer(payload, session);
    final command = payload! as ParsedCommand;
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
      return _ask(session, 'task.create', titleQuestion);
    }
    final title = command.title;
    if (title == null || title.isEmpty) {
      return _ask(session, 'task.create', 'task.ask.title');
    }
    final dueQuestion = _dueClarification(command.dueIssue);
    if (dueQuestion != null) {
      return _ask(session, 'task.create', dueQuestion);
    }
    if (command.implicit) {
      // «Купить хлеб» без маркера при уже активной «Купить хлеб» — чаще
      // всего ответ на «Какую задачу отметить…?» или забытая задача,
      // а не просьба завести вторую такую же.
      final existing = await _tasks.findActiveByTitle(title);
      if (existing.isNotEmpty) {
        final task = existing.first;
        session.select(id, task.id);
        return session.reply(
          'task.exists',
          values: <String, String>{'title': task.title},
          intent: 'task.create',
          status: AssistantStatus.noAction,
          task: task,
        );
      }
    }
    final task = await _tasks.create(
      title: title,
      dueAt: command.dueAt,
      // Без срока точность не важна: задача хранит значение по умолчанию.
      duePrecision: command.duePrecision ?? DuePrecision.dateTime,
      tags: command.projects,
    );
    session.select(id, task.id);
    final due = _due(task, session);
    final project = task.project;
    return session.reply(
      switch ((due, project)) {
        (null, null) => 'task.created',
        (_?, null) => 'task.created.withDue',
        (null, _?) => 'task.created.withProject',
        (_?, _?) => 'task.created.withDueAndProject',
      },
      values: <String, String>{
        'title': task.title,
        if (due != null) 'due': due,
        if (project != null) 'project': project,
      },
      intent: 'task.create',
      status: AssistantStatus.completed,
      task: task,
    );
  }

  Future<AssistantResponse> _list(AssistantSession session) async {
    final tasks = await _tasks.listActive();
    if (tasks.isEmpty) {
      return session.reply(
        'task.list.empty',
        intent: 'task.list',
        status: AssistantStatus.completed,
      );
    }
    final next = tasks.first;
    final nextDue = _due(next, session);
    return session.reply(
      nextDue == null ? 'task.list' : 'task.list.withDue',
      values: <String, String>{
        'count': '${tasks.length}',
        'title': next.title,
        if (nextDue != null) 'due': nextDue,
      },
      intent: 'task.list',
      status: AssistantStatus.completed,
    );
  }

  Future<AssistantResponse> _complete(
    ParsedCommand command,
    AssistantSession session,
  ) async {
    // «Я купил хлеб», «вернул «Книгу»»: сообщение о сделанном без маркера —
    // по запросу или точному названию, но сначала вопрос.
    final query =
        command.targetQuery ?? (command.pastTense ? command.title : null);
    if (command.pastTense && query != null) {
      return _askToComplete(command, query, session);
    }
    final target = await _resolveTarget(
      command,
      session,
      intent: 'task.complete',
      noContextQuestion: 'task.ask.completeWhich',
    );
    if (target.clarification != null) return target.clarification!;
    final task = await _tasks.complete(target.id!);
    // Завершённая задача больше не «её»: следующий перенос или завершение
    // требует нового выбора, а не тихо открывает её снова.
    session.forget(id, task.id);
    return _completed(task, session);
  }

  /// «Я купил хлеб»: найти задачу и спросить, отметить ли её. Сразу
  /// ничего не меняется — задача угадана по словам.
  Future<AssistantResponse> _askToComplete(
    ParsedCommand command,
    String query,
    AssistantSession session,
  ) async {
    var tasks = await _tasks.findActiveByTitle(query);
    if (tasks.isEmpty) {
      final hits = await _tasks.searchActive(query, verbForms: true);
      if (hits.isNotEmpty) {
        final best = hits.first.score;
        tasks = <Task>[
          for (final hit in hits)
            if (best - hit.score <= 0.1 + 1e-9) hit.task,
        ];
      }
    }
    if (tasks.isEmpty) {
      // Без маркера фраза могла быть вовсе не о задачах: «я купил хлеб»
      // без такой задачи — просто рассказ.
      if (command.implicit) return unknown(session);
      return _ask(
        session,
        'task.complete',
        'task.notFound',
        <String, String>{'query': query},
      );
    }
    if (tasks.length > 1) {
      final titles =
          tasks.take(3).map((Task t) => '«${t.title}»').toList(growable: false);
      final list = titles.length == 1
          ? titles.single
          : '${titles.sublist(0, titles.length - 1).join(', ')} '
              'или ${titles.last}';
      return _ask(
        session,
        'task.complete',
        'task.ask.completeChoice',
        <String, String>{'candidates': list},
      );
    }
    final task = tasks.single;
    session.requestConfirmation(
      PendingConfirmation(
        connectorId: id,
        commandId: 'task.complete',
        itemId: task.id,
      ),
    );
    return _ask(
      session,
      'task.complete',
      'task.ask.confirmComplete',
      <String, String>{'title': task.title},
    );
  }

  /// Ответ на «Отметить «…» выполненной?».
  Future<AssistantResponse> _answer(
    ConfirmationAnswer answer,
    AssistantSession session,
  ) async {
    final pending = answer.pending;
    final taskId = pending.itemId;
    if (pending.commandId != 'task.complete' || taskId == null) {
      throw StateError('Неизвестное подтверждение ${pending.commandId}');
    }
    if (!answer.confirmed) {
      return session.reply(
        'task.confirm.declined',
        intent: 'task.complete',
        status: AssistantStatus.noAction,
      );
    }
    final active = await _tasks.listActive();
    if (!active.any((Task t) => t.id == taskId)) {
      // Задачу успели завершить или удалить в интерфейсе.
      return session.reply(
        'task.confirm.inactive',
        intent: 'task.complete',
        status: AssistantStatus.noAction,
      );
    }
    final task = await _tasks.complete(taskId);
    session.forget(id, task.id);
    return _completed(task, session);
  }

  Future<AssistantResponse> _reschedule(
    ParsedCommand command,
    AssistantSession session,
  ) async {
    final target = await _resolveTarget(
      command,
      session,
      intent: 'task.reschedule',
      noContextQuestion: 'task.ask.rescheduleWhich',
    );
    if (target.clarification != null) return target.clarification!;
    final dueQuestion = _dueClarification(command.dueIssue);
    if (dueQuestion != null) {
      return _ask(session, 'task.reschedule', dueQuestion);
    }
    final dueAt = command.dueAt;
    if (dueAt == null) {
      return _ask(session, 'task.reschedule', 'task.ask.rescheduleWhen');
    }
    final task = await _tasks.reschedule(
      target.id!,
      dueAt,
      command.duePrecision ?? DuePrecision.dateTime,
    );
    session.select(id, task.id);
    return session.reply(
      'task.rescheduled',
      values: <String, String>{
        'title': task.title,
        // Перенос всегда со сроком: без него — вопрос выше.
        'due': _due(task, session)!,
      },
      intent: 'task.reschedule',
      status: AssistantStatus.completed,
      task: task,
    );
  }

  AssistantResponse _completed(Task task, AssistantSession session) =>
      session.reply(
        'task.completed',
        values: <String, String>{'title': task.title},
        intent: 'task.complete',
        status: AssistantStatus.completed,
        task: task,
      );

  /// Уточнение из каталога ответов: [replyId] с фактами [values].
  AssistantResponse _ask(
    AssistantSession session,
    String intent,
    String replyId, [
    Map<String, String> values = const <String, String>{},
  ]) =>
      session.reply(
        replyId,
        values: values,
        intent: intent,
        status: AssistantStatus.needsClarification,
      );

  /// Запись каталога с вопросом о сроке или `null`, если со сроком всё
  /// в порядке.
  String? _dueClarification(DueIssue issue) => switch (issue) {
        DueIssue.none => null,
        DueIssue.inPast => 'task.due.inPast',
        DueIssue.invalidDate => 'task.due.invalidDate',
        DueIssue.invalidTime => 'task.due.invalidTime',
        DueIssue.conflictingDays => 'task.due.conflictingDays',
        DueIssue.conflictingTimes => 'task.due.conflictingTimes',
        DueIssue.ambiguousHour => 'task.due.ambiguousHour',
      };

  String? _titleClarification(TitleIssue issue) => switch (issue) {
        TitleIssue.none => null,
        TitleIssue.unbalancedQuotes => 'task.title.unbalancedQuotes',
        TitleIssue.multipleTitles => 'task.title.multiple',
      };

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
    AssistantResponse ask(
      String replyId, [
      Map<String, String> values = const <String, String>{},
    ]) =>
        _ask(session, intent, replyId, values);

    final titleQuestion = _titleClarification(command.titleIssue);
    if (titleQuestion != null) return _Target.ask(ask(titleQuestion));

    final name = command.title ?? command.targetQuery;
    if (name != null) {
      final exact = await _tasks.findActiveByTitle(name);
      if (exact.length == 1) return _Target.id(exact.single.id);
      if (exact.length > 1) {
        return _Target.ask(
          ask('task.ask.duplicates', <String, String>{'name': name}),
        );
      }
      if (command.title != null) {
        return _Target.ask(
          ask('task.notFound', <String, String>{'query': name}),
        );
      }
      final hits = await _tasks.searchActive(name);
      if (hits.isEmpty) {
        return _Target.ask(
          ask('task.notFound', <String, String>{'query': name}),
        );
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
          ask('task.ask.didYouMean', <String, String>{'title': hit.task.title}),
        );
      }
      final titles = close
          .take(3)
          .map((TaskSearchHit h) => '«${h.task.title}»')
          .join(', ');
      return _Target.ask(
        ask(
          'task.ask.severalMatch',
          <String, String>{'name': name, 'candidates': titles},
        ),
      );
    }

    final selected = session.selectedItemFor(id);
    if (selected == null) return _Target.ask(ask(noContextQuestion));
    return _Target.id(selected);
  }

  /// Срок задачи словами («завтра в 10:00») или `null` без срока.
  String? _due(Task task, AssistantSession session) {
    final due = task.dueAt;
    if (due == null) return null;
    return formatDue(due, task.duePrecision, session.clock.now());
  }
}

final class _Target {
  const _Target.id(String this.id) : clarification = null;

  const _Target.ask(AssistantResponse this.clarification) : id = null;

  final String? id;
  final AssistantResponse? clarification;
}
