import '../formatting/due_format.dart';
import '../models/bulk.dart';
import '../models/task.dart';
import '../replies/reply_library.dart';
import '../scenario/scenario_parser.dart';
import '../services/task_service.dart';
import '../skills/talk/talk_phrases.dart';
import 'connector.dart';
import 'task_chat_phrases.dart';

/// Встроенный коннектор задач: создание, список, перенос и завершение.
///
/// Распознавание — [ScenarioParser], изменения — только через [TaskService].
/// Работает локально, без сети. Изменения задач — собственные данные
/// приложения, поэтому подтверждение ADR-004 к явным командам над одной
/// задачей не применяется: действие видно в ответе и обратимо в интерфейсе.
/// Подтверждение нужно завершению по сообщению о сделанном («я купил
/// хлеб»): задача угадана по словам, а не названа командой, — и массовым
/// командам («перенеси всё на выходные»): они меняют сразу много задач,
/// поэтому сначала вопрос со списком задач и галочками ([BulkChecklist]),
/// а после применения — «Отменить» (ADR-004, docs/CONNECTORS.md).
final class TasksConnector
    implements Connector, ConnectorHealth, ConfirmationFollowUp {
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

  /// Команда отмены последнего массового изменения: «отмени», кнопка
  /// «Отменить» в карточке.
  static const String undoCommand = 'task.bulk.undo';

  /// Последнее применённое массовое изменение и прежние задачи — для
  /// отмены. Одно на открытый чат: новое массовое изменение и очистка чата
  /// ([forgetUndo]) его заменяют.
  _BulkUndo? _undo;
  int _bulkSequence = 0;

  /// Отменить прежние массовые изменения больше нельзя (чат очищен).
  void forgetUndo() {
    _undo?.checklist.canUndo = false;
    _undo = null;
  }

  @override
  ConnectorInfo get info => const ConnectorInfo(
        id: id,
        title: 'Задачи',
        description: 'Создаёт, показывает, переносит и завершает задачи — '
            'по одной и сразу несколько.',
        examples: <String>[
          exampleCommand,
          'Добавь «Купить хлеб» на завтра',
          'Покажи задачи',
          'Перенеси отчёт на завтра в 15:00',
          'Заверши её',
          'Перенеси все просроченные на завтра',
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
    if (_isUndo(utterance)) {
      return const ConnectorMatch(
        connectorId: id,
        commandId: undoCommand,
        confidence: 0.85,
        payload: BulkUndoRequest(),
      );
    }
    var command = _parser.parseUtterance(utterance);
    if (command.intent == CommandIntent.unknown) {
      // В чате задачи: «закрой», «на завтра» — о ней (TaskChatPhrases).
      final inChat = TaskChatPhrases.match(utterance);
      if (inChat != null) {
        return ConnectorMatch(
          connectorId: id,
          commandId: inChat.intent == CommandIntent.completeTask
              ? 'task.complete'
              : 'task.reschedule',
          confidence: inChat.intent == CommandIntent.completeTask ? 0.8 : 0.75,
          payload: inChat,
        );
      }
    }
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
      CommandIntent.rescheduleMany => (rescheduleManyCommand, 0.9),
      CommandIntent.completeMany => (completeManyCommand, 0.9),
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
    if (payload is ConfirmationAnswer) {
      if (payload.pending.payload is BulkChecklist) {
        return _answerBulk(payload, session);
      }
      return _answer(payload, session);
    }
    if (payload is BulkUndoRequest) return _undoBulk(payload, session);
    if (payload is _BulkRefine) return _refineBulk(payload, session);
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
      case CommandIntent.rescheduleMany:
      case CommandIntent.completeMany:
        return _askBulk(command, session);
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
      // «Я купил хлеб» в чате «Купить хлеб»: задача не угадана, а названа
      // самим чатом — без вопроса.
      final chatTask = await _chatTask(session);
      if (chatTask != null &&
          chatTask.isActive &&
          await _isBestHit(chatTask, query)) {
        final task = await _tasks.complete(chatTask.id);
        session.forget(id, task.id);
        return _completed(task, session);
      }
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

  /// Задача чата, в котором пришло сообщение, или `null` (главный чат,
  /// задачу удалили).
  Future<Task?> _chatTask(AssistantSession session) async {
    final chatTaskId = session.chatTaskId;
    if (chatTaskId == null) return null;
    for (final task in await _tasks.listAll()) {
      if (task.id == chatTaskId) return task;
    }
    return null;
  }

  /// [task] среди лучших совпадений поиска по [query] (как в
  /// [_askToComplete]).
  Future<bool> _isBestHit(Task task, String query) async {
    final exact = await _tasks.findActiveByTitle(query);
    if (exact.isNotEmpty) return exact.any((Task t) => t.id == task.id);
    final hits = await _tasks.searchActive(query, verbForms: true);
    if (hits.isEmpty) return false;
    final best = hits.first.score;
    return hits.any(
      (TaskSearchHit h) => h.task.id == task.id && best - h.score <= 0.1 + 1e-9,
    );
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

  // ------------------------------------------------- массовые команды

  /// commandId массового переноса: «перенеси всё на выходные».
  static const String rescheduleManyCommand = 'task.rescheduleMany';

  /// commandId массового завершения: «закрой все просроченные».
  static const String completeManyCommand = 'task.completeMany';

  static const Set<String> _undoVerbs = <String>{
    'отмени',
    'отмените',
    'верни',
    'верните',
  };

  static const Set<String> _undoWords = <String>{
    'все',
    'это',
    'как',
    'было',
    'назад',
    'обратно',
    'последнее',
    'последний',
    'перенос',
    'изменение',
    'изменения',
    'действие',
    'отметки',
    'отметку',
    'массовое',
    'пожалуйста',
  };

  /// «Отмени», «отмени перенос», «верни всё как было»: отмена последнего
  /// массового изменения. «Верни» без «как было», «назад» или «обратно» —
  /// не отмена. Отдельное «отменить» — тоже нет: это просьба без предмета.
  static bool _isUndo(Utterance utterance) {
    final words = utterance.words;
    if (words.isEmpty || utterance.quotedTitles.isNotEmpty) return false;
    if (utterance.hashtags.isNotEmpty || utterance.due.spans.isNotEmpty) {
      return false;
    }
    final first = words.first;
    if (!_undoVerbs.contains(first)) return false;
    final rest = words.skip(1);
    if (!rest.every(_undoWords.contains)) return false;
    if (first.startsWith('верн')) {
      return rest.contains('назад') ||
          rest.contains('обратно') ||
          (rest.contains('как') && rest.contains('было'));
    }
    return true;
  }

  static const Set<String> _exceptWords = <String>{
    'кроме',
    'без',
    'исключи',
    'исключая',
    'убери',
    'сними',
  };

  static const Set<String> _onlyWords = <String>{'только', 'лишь'};

  static const Set<String> _leadingAnswers = <String>{
    'да',
    'ок',
    'окей',
    'хорошо',
    'ладно',
    'давай',
    'но',
    'а',
    'все',
    'нет',
  };

  /// Слова согласия, которые не меняют смысла «да»: «да, перенеси»,
  /// «давай, закрывай все».
  static const Set<String> _agreeWords = <String>{
    'да',
    'ага',
    'угу',
    'конечно',
    'ок',
    'окей',
    'хорошо',
    'ладно',
    'давай',
    'подтверждаю',
    'верно',
    'точно',
    'так',
    'можно',
    'пожалуйста',
    'спасибо',
    'все',
    'их',
    'эти',
    'это',
    'задачи',
    'перенеси',
    'переноси',
    'перенесите',
    'переносите',
    'сдвинь',
    'сдвигай',
    'двигай',
    'закрой',
    'закрывай',
    'заверши',
    'завершай',
    'отметь',
    'отмечай',
    'применяй',
    'применить',
    'делай',
    'действуй',
  };

  /// Глаголы после «не»: «не трогай хлеб», «хлеб не переноси».
  static const Set<String> _keepVerbs = <String>{
    'трогай',
    'трогать',
    'переноси',
    'переносить',
    'двигай',
    'двигать',
    'сдвигай',
    'закрывай',
    'закрывать',
    'отмечай',
    'отмечать',
    'завершай',
    'надо',
    'нужно',
  };

  /// «Хлеб не трогай», «хлеб оставь», «отчёт пусть останется».
  static final RegExp _keepTail = RegExp(
    r'^(.+?)\s+(?:не\s+(?:трогай|трогать|переноси|переносить|двигай|'
    r'двигать|сдвигай|закрывай|закрывать|отмечай|отмечать|завершай|надо|'
    r'нужно)|оставь(?:\s+как\s+есть)?|пусть\s+останется|пусть\s+будет)'
    r'[\s.!]*$',
    caseSensitive: false,
  );

  /// «Кроме хлеба», «да, только отчёт», «убери «Счёт»», «да, но не хлеб»,
  /// «хлеб не трогай» в ответ на вопрос массовой команды: снять или
  /// оставить отметки и спросить снова. «Отмени перенос», «не переноси» —
  /// отказ от этого вопроса, а не отмена прошлого изменения: пока вопрос
  /// ждёт ответа, «отмени …» относится к нему. «Да, перенеси» — согласие.
  @override
  ConnectorMatch? matchFollowUp(
    Utterance utterance,
    PendingConfirmation pending,
  ) {
    final checklist = pending.payload;
    if (checklist is! BulkChecklist || !checklist.isPending) return null;
    ConnectorMatch answer(ConfirmationReply reply) => ConnectorMatch(
          connectorId: id,
          commandId: pending.commandId,
          confidence: 1,
          payload: ConfirmationAnswer(pending, reply),
        );
    ConnectorMatch refine(List<String> queries, {required bool only}) =>
        ConnectorMatch(
          connectorId: id,
          commandId: pending.commandId,
          confidence: 1,
          payload: _BulkRefine(pending, queries, only: only),
        );
    final words = utterance.words;
    if (words.isEmpty) return null;
    if (_isUndo(utterance) ||
        (words.first == 'отмена' &&
            words.skip(1).every(
                  (String w) =>
                      _undoWords.contains(w) || _declineNouns.contains(w),
                ))) {
      return answer(ConfirmationReply.no);
    }
    final tokens = utterance.tokens;
    var i = 0;
    var agreed = false;
    while (i < tokens.length && _leadingAnswers.contains(tokens[i].text)) {
      if (_agreeWords.contains(tokens[i].text)) agreed = true;
      i++;
    }
    final quoted = <String>[
      for (final quote in utterance.quotedTitles) quote.text,
    ];
    if (quoted.isEmpty &&
        !utterance.isQuestion &&
        _yesFirst.contains(words.first) &&
        words.every(_agreeWords.contains)) {
      return answer(ConfirmationReply.yes);
    }
    // «Не переноси», «да, но не хлеб», «не трогай отчёт».
    if (i < tokens.length && tokens[i].text == 'не') {
      var j = i + 1;
      while (j < tokens.length && _keepVerbs.contains(tokens[j].text)) {
        j++;
      }
      final queries = j < tokens.length
          ? _queries(utterance.original.substring(tokens[j].span.start))
          : <String>[];
      final all = queries.isNotEmpty &&
          queries.every((String q) => _allWords.contains(q.toLowerCase()));
      if (queries.isEmpty && quoted.isEmpty || all) {
        // «Не переноси», «не трогай их»: отказ. «Да, но не надо» — непонятно.
        return agreed
            ? refine(const <String>[], only: false)
            : answer(
                ConfirmationReply.no,
              );
      }
      return refine(<String>[...queries, ...quoted], only: false);
    }
    final int start;
    final bool only;
    if (i < tokens.length && _exceptWords.contains(tokens[i].text)) {
      only = false;
      start = tokens[i].span.end;
    } else if (i < tokens.length && _onlyWords.contains(tokens[i].text)) {
      only = true;
      start = tokens[i].span.end;
    } else {
      // «Хлеб не трогай», «да, отчёт оставь».
      final rest = i < tokens.length
          ? utterance.original.substring(tokens[i].span.start)
          : '';
      final keep = _keepTail.firstMatch(rest.trim());
      if (keep == null) return null;
      final queries = <String>[..._queries(keep.group(1)!), ...quoted];
      if (queries.isEmpty) return null;
      return refine(queries, only: false);
    }
    // Всё после ключевого слова — части названий через запятую или «и».
    final queries = <String>[
      ..._queries(utterance.original.substring(start)),
      ...quoted,
    ];
    if (queries.isEmpty) return null;
    return refine(queries, only: only);
  }

  /// «Отмена переноса», «отмена всего»: отказ от вопроса.
  static const Set<String> _declineNouns = <String>{
    'переноса',
    'завершения',
    'всего',
    'команды',
  };

  /// Первое слово, с которым весь ответ из [_agreeWords] — согласие.
  /// «Хорошо», «ладно», «всё» в начале согласием не считаются.
  static const Set<String> _yesFirst = <String>{
    'да',
    'ага',
    'угу',
    'конечно',
    'ок',
    'окей',
    'давай',
    'подтверждаю',
  };

  /// «Их», «все» вместо названия: «не трогай их» — отказ целиком.
  static const Set<String> _allWords = <String>{
    'их',
    'все',
    'всё',
    'ничего',
    'это',
    'эти',
  };

  /// Части названий через запятую, «и», «или»; без кавычек и точек.
  static List<String> _queries(String text) {
    final rest = text.replaceAll(RegExp('[«»"“”„]'), ' ');
    return <String>[
      for (final part in rest.split(RegExp(r'[,;]|\s+и\s+|\s+или\s+')))
        if (part.trim().replaceAll(RegExp(r'[.!?\s]+$'), '')
            case final String text when text.isNotEmpty)
          text,
    ];
  }

  /// Согласие с пояснением, которое не распознано как «кроме …»: «да, хлеб
  /// тоже», «да, но без спешки». Пояснение может исключать задачу, поэтому
  /// по списку не применяем, а переспрашиваем. «Нет, …» — отказ как есть.
  @override
  ConnectorMatch? matchLeadingAnswer(
    Utterance utterance,
    PendingConfirmation pending,
    ConfirmationReply reply,
  ) {
    final checklist = pending.payload;
    if (checklist is! BulkChecklist || !checklist.isPending) return null;
    if (reply != ConfirmationReply.yes) return null;
    if (utterance.words.every(_agreeWords.contains)) return null;
    return ConnectorMatch(
      connectorId: id,
      commandId: pending.commandId,
      confidence: 1,
      payload: _BulkRefine(pending, const <String>[], only: false),
    );
  }

  /// Первый шаг массовой команды: ничего не меняет, а спрашивает со
  /// списком подходящих задач, все отмечены.
  Future<AssistantResponse> _askBulk(
    ParsedCommand command,
    AssistantSession session,
  ) async {
    final reschedule = command.intent == CommandIntent.rescheduleMany;
    final intent = reschedule ? rescheduleManyCommand : completeManyCommand;
    final dueQuestion = _dueClarification(command.dueIssue);
    if (dueQuestion != null) return _ask(session, intent, dueQuestion);
    final shift = command.shift;
    final target = command.dueAt;
    final precision = command.duePrecision ?? DuePrecision.dateTime;
    if (reschedule && target == null && shift == null) {
      return _ask(session, intent, 'task.bulk.ask.when');
    }
    final now = session.clock.now();
    final selection = command.selection ?? const BulkSelection();
    final tasks = <Task>[
      for (final task in await _tasks.listActive())
        if (selection.matches(task, now) &&
            switch ((shift, target)) {
              (final DueShift shift, _) =>
                task.dueAt != null && shift.fits(task.duePrecision),
              // Задача уже на этом сроке — переносить нечего.
              (null, final DateTime target) =>
                task.dueAt != target || task.duePrecision != precision,
              _ => true,
            })
          task,
    ];
    if (tasks.isEmpty) {
      final tags = selection.tags.map((String t) => '#$t').join(', ');
      return session.reply(
        shift != null
            ? 'task.bulk.empty.shift'
            : tags.isNotEmpty
                ? 'task.bulk.empty.tag'
                : switch (selection.kind) {
                    BulkScopeKind.all => 'task.bulk.empty.all',
                    BulkScopeKind.overdue => 'task.bulk.empty.overdue',
                    BulkScopeKind.noDue => 'task.bulk.empty.noDue',
                    BulkScopeKind.day => 'task.bulk.empty.day',
                  },
        values: <String, String>{
          if (shift == null && tags.isNotEmpty) 'tags': tags,
          if (shift == null &&
              tags.isEmpty &&
              selection.kind == BulkScopeKind.day)
            'day': formatDay(selection.day!, now),
        },
        intent: intent,
        status: AssistantStatus.noAction,
      );
    }
    final checklist = BulkChecklist(
      id: 'bulk_${now.microsecondsSinceEpoch}_${_bulkSequence++}',
      action: reschedule ? BulkAction.reschedule : BulkAction.complete,
      selection: selection,
      items: <BulkItem>[
        for (final task in tasks)
          BulkItem(
            taskId: task.id,
            title: task.title,
            dueLabel: _due(task, session),
          ),
      ],
      targetDue: shift == null ? target : null,
      targetPrecision: shift == null && target != null ? precision : null,
      shift: shift,
      targetLabel: shift?.describe() ??
          (target == null ? null : formatDueShort(target, precision, now)),
    );
    session.requestConfirmation(
      PendingConfirmation(
        connectorId: id,
        commandId: intent,
        payload: checklist,
        onDropped: () {
          if (checklist.isPending) checklist.state = BulkChecklistState.expired;
        },
      ),
    );
    final exclude = command.exclude;
    if (exclude.isEmpty) return _askChecklist(checklist, session, intent);
    // «Закрой всё, кроме хлеба»: исключённые задачи — в списке, но без
    // отметки, как после «кроме …» в ответ на вопрос.
    return _uncheck(checklist, session, intent, exclude, only: false);
  }

  /// Вопрос по списку [checklist] с числом отмеченных задач.
  AssistantResponse _askChecklist(
    BulkChecklist checklist,
    AssistantSession session,
    String intent, {
    String? prefix,
  }) {
    final count = checklist.checkedCount;
    if (count == 0) {
      return session.reply(
        'task.bulk.ask.noneChecked',
        intent: intent,
        status: AssistantStatus.needsClarification,
        checklist: checklist,
        prefix: prefix,
      );
    }
    final shift = checklist.shift;
    final due = checklist.targetDue;
    return session.reply(
      switch (checklist.action) {
        BulkAction.complete => 'task.bulk.ask.complete',
        BulkAction.reschedule when shift != null => 'task.bulk.ask.shift',
        BulkAction.reschedule => 'task.bulk.ask.reschedule',
      },
      values: <String, String>{
        'count': '$count',
        if (shift != null) 'shift': shift.describe(),
        if (shift == null && due != null)
          'due': formatDue(
            due,
            checklist.targetPrecision ?? DuePrecision.date,
            session.clock.now(),
          ),
      },
      intent: intent,
      status: AssistantStatus.needsClarification,
      checklist: checklist,
      prefix: prefix,
    );
  }

  /// «Кроме …», «только …»: поменять отметки и спросить снова. Вопрос
  /// остаётся тем же, поэтому карточка и ожидание не пересоздаются.
  Future<AssistantResponse> _refineBulk(
    _BulkRefine refine,
    AssistantSession session,
  ) async {
    final pending = refine.pending;
    final checklist = pending.payload! as BulkChecklist;
    final intent = pending.commandId;
    session.requestConfirmation(pending);
    final queries = refine.queries;
    if (queries.isEmpty) {
      // «Да, хлеб тоже»: согласие с оговоркой, которую мы не поняли.
      // Применять как есть нельзя — вдруг это исключение. Спрашиваем снова.
      return _askChecklist(
        checklist,
        session,
        intent,
        prefix: session.say('task.bulk.unclear'),
      );
    }
    return _uncheck(checklist, session, intent, queries, only: refine.only);
  }

  /// Снять отметки с задач по частям названий [queries] (или, при [only],
  /// оставить отмеченными только их) и спросить снова.
  AssistantResponse _uncheck(
    BulkChecklist checklist,
    AssistantSession session,
    String intent,
    List<String> queries, {
    required bool only,
  }) {
    final hits = <BulkItem>[
      for (final item in checklist.items)
        if (queries.any((String q) => _titleMatches(item.title, q))) item,
    ];
    if (hits.isEmpty) {
      return _askChecklist(
        checklist,
        session,
        intent,
        prefix: session.say('task.bulk.notInList', <String, String>{
          'query': queries.map((String q) => '«$q»').join(', '),
        }),
      );
    }
    for (final item in checklist.items) {
      final hit = hits.contains(item);
      if (only) {
        item.checked = hit;
      } else if (hit) {
        item.checked = false;
      }
    }
    final titles = hits.take(3).map((BulkItem i) => '«${i.title}»').join(', ') +
        (hits.length > 3 ? ' и ещё ${hits.length - 3}' : '');
    return _askChecklist(
      checklist,
      session,
      intent,
      prefix: session.say(
        only ? 'task.bulk.onlyChecked' : 'task.bulk.unchecked',
        <String, String>{'titles': titles},
      ),
    );
  }

  /// Подходит ли задача [title] к части названия [query]: подстрока или
  /// каждое слово запроса — то же слово названия в другой форме («хлеба» —
  /// «Купить хлеб», «воды» — «Купить воду»).
  static bool _titleMatches(String title, String query) {
    String norm(String text) => text.toLowerCase().replaceAll('ё', 'е');
    final t = norm(title);
    final q = norm(query).trim();
    if (q.isEmpty) return false;
    if (q.length >= 3 && t.contains(q)) return true;
    final word = RegExp(r'[\p{L}\p{N}]+', unicode: true);
    final titleWords = <String>[
      for (final m in word.allMatches(t)) m.group(0)!,
    ];
    final queryWords = <String>[
      for (final m in word.allMatches(q))
        if (m.group(0)!.length >= 2) m.group(0)!,
    ];
    if (queryWords.isEmpty) return false;
    return queryWords.every(
      (String q) => titleWords.any((String w) => sameWord(w, q)),
    );
  }

  /// Одно ли это слово в разных формах: общее начало не короче трёх букв
  /// и отличается не больше чем двумя последними буквами каждого слова.
  /// «Воду» — «воды», «хлеб» — «хлеба», но не «в» — «воды» и не «вода» —
  /// «водитель». Короткие слова (предлоги) совпадают только целиком.
  static bool sameWord(String a, String b) {
    if (a == b) return true;
    var prefix = 0;
    while (prefix < a.length && prefix < b.length && a[prefix] == b[prefix]) {
      prefix++;
    }
    if (prefix < 3) return false;
    return a.length - prefix <= 2 && b.length - prefix <= 2;
  }

  /// Ответ на вопрос массовой команды: «да» — применить к отмеченным
  /// задачам, «нет» — ничего не менять.
  Future<AssistantResponse> _answerBulk(
    ConfirmationAnswer answer,
    AssistantSession session,
  ) async {
    final pending = answer.pending;
    final checklist = pending.payload! as BulkChecklist;
    final intent = pending.commandId;
    if (!checklist.isPending) {
      return session.reply(
        'task.bulk.stale',
        intent: intent,
        status: AssistantStatus.noAction,
      );
    }
    if (!answer.confirmed || checklist.checkedCount == 0) {
      checklist.state = BulkChecklistState.cancelled;
      return session.reply(
        answer.confirmed ? 'task.bulk.noneChecked' : 'task.bulk.declined',
        intent: intent,
        status: AssistantStatus.noAction,
      );
    }
    final active = <String, Task>{
      for (final task in await _tasks.listActive()) task.id: task,
    };
    final changes = <(Task, DateTime)>[];
    for (final taskId in checklist.checkedIds) {
      final task = active[taskId];
      // Задачу успели завершить или удалить, пока список ждал ответа.
      if (task == null) continue;
      final Task updated;
      switch (checklist.action) {
        case BulkAction.complete:
          updated = await _tasks.complete(taskId);
          session.forget(id, taskId);
        case BulkAction.reschedule:
          final shift = checklist.shift;
          final due = task.dueAt;
          if (shift != null) {
            if (due == null) continue;
            updated = await _tasks.reschedule(
              taskId,
              shift.apply(due),
              task.duePrecision,
            );
          } else {
            updated = await _tasks.reschedule(
              taskId,
              checklist.targetDue!,
              checklist.targetPrecision ?? DuePrecision.date,
            );
          }
      }
      changes.add((task, updated.updatedAt));
    }
    checklist
      ..state = BulkChecklistState.applied
      ..applied = changes.length;
    if (changes.isEmpty) {
      return session.reply(
        'task.bulk.stale',
        intent: intent,
        status: AssistantStatus.noAction,
      );
    }
    // Отменить можно только последнее массовое изменение.
    forgetUndo();
    checklist.canUndo = true;
    _undo = _BulkUndo(checklist, changes);
    final count = changes.length;
    final total = checklist.items.length;
    final partial = count < total;
    final shift = checklist.shift;
    final String replyId;
    switch (checklist.action) {
      case BulkAction.complete:
        replyId = 'task.bulk.completed';
      case BulkAction.reschedule when shift != null:
        replyId = 'task.bulk.shifted';
      case BulkAction.reschedule:
        replyId = 'task.bulk.rescheduled';
    }
    return session.reply(
      partial ? '$replyId.partial' : replyId,
      values: <String, String>{
        'count': '$count',
        if (partial) 'total': '$total',
        if (checklist.action == BulkAction.reschedule && shift != null)
          'shift': shift.describe(),
        if (checklist.action == BulkAction.reschedule && shift == null)
          'due': formatDue(
            checklist.targetDue!,
            checklist.targetPrecision ?? DuePrecision.date,
            session.clock.now(),
          ),
      },
      intent: intent,
      status: AssistantStatus.completed,
    );
  }

  /// «Отмени», кнопка «Отменить»: вернуть задачам прежние сроки и статусы.
  /// Задачи, которые с тех пор меняли, не трогаются.
  Future<AssistantResponse> _undoBulk(
    BulkUndoRequest request,
    AssistantSession session,
  ) async {
    final undo = _undo;
    final wanted = request.checklist;
    if (undo == null ||
        !undo.checklist.canUndo ||
        (wanted != null && !identical(wanted, undo.checklist))) {
      return session.reply(
        'task.bulk.undo.nothing',
        intent: undoCommand,
        status: AssistantStatus.noAction,
      );
    }
    var restored = 0;
    for (final (before, updatedAt) in undo.changes) {
      final task = await _tasks.restore(before, ifUpdatedAt: updatedAt);
      if (task != null) restored++;
    }
    forgetUndo();
    undo.checklist.state = BulkChecklistState.undone;
    final total = undo.changes.length;
    return session.reply(
      restored < total ? 'task.bulk.undone.partial' : 'task.bulk.undone',
      values: <String, String>{
        'count': '$restored',
        if (restored < total) 'total': '$total',
      },
      intent: undoCommand,
      status: AssistantStatus.completed,
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

    final chatTask = await _chatTask(session);
    if (chatTask != null) {
      final other = await _otherTarget(command, chatTask, ask);
      if (other != null) return other;
      if (!chatTask.isActive) {
        // «Готово» и «перенеси на завтра» в чате выполненной задачи ничего
        // не меняют: вернуть её в работу — кнопкой в шапке чата.
        return _Target.ask(
          session.reply(
            'task.chat.alreadyDone',
            values: <String, String>{'title': chatTask.title},
            intent: intent,
            status: AssistantStatus.noAction,
            task: chatTask,
          ),
        );
      }
      return _Target.id(chatTask.id);
    }

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

  /// Чат задачи: явно названная задача.
  ///
  /// - Название в кавычках — как везде (не нашлась — «не нашёл»).
  /// - Без названия или с междометием вместо него («готово, спасибо»,
  ///   «сделано, ура» — [TaskChatPhrases.isFiller]) — задача чата (`null`).
  /// - Слова без кавычек: точное совпадение или уверенное единственное
  ///   совпадение поиска — эта задача; среди лучших совпадений задача
  ///   чата — она (`null`); иначе — тот же вопрос, что в главном чате
  ///   («не нашёл», «какую из…», «вы имели в виду…»). Задачу чата по
  ///   названию, которое ей не подходит, не меняем молча.
  Future<_Target?> _otherTarget(
    ParsedCommand command,
    Task chatTask,
    AssistantResponse Function(String, [Map<String, String>]) ask,
  ) async {
    final quoted = command.title;
    if (quoted != null) {
      final exact = await _tasks.findActiveByTitle(quoted);
      if (exact.length == 1) return _Target.id(exact.single.id);
      return _Target.ask(
        exact.isEmpty
            ? ask('task.notFound', <String, String>{'query': quoted})
            : ask('task.ask.duplicates', <String, String>{'name': quoted}),
      );
    }
    final query = command.targetQuery;
    if (query == null || TaskChatPhrases.isFiller(query)) return null;
    final exact = await _tasks.findActiveByTitle(query);
    if (exact.length == 1) return _Target.id(exact.single.id);
    if (exact.length > 1) {
      if (exact.any((Task t) => t.id == chatTask.id)) return null;
      return _Target.ask(
        ask('task.ask.duplicates', <String, String>{'name': query}),
      );
    }
    final hits = await _tasks.searchActive(query);
    if (hits.isEmpty) {
      // Выполненную задачу чата поиск по активным не найдёт: ответит
      // «уже выполнена», ничего не меняя.
      if (!chatTask.isActive) return null;
      return _Target.ask(
        ask('task.notFound', <String, String>{'query': query}),
      );
    }
    final best = hits.first.score;
    final close = hits
        .where((TaskSearchHit h) => best - h.score <= 0.1 + 1e-9)
        .toList(growable: false);
    if (close.any((TaskSearchHit h) => h.task.id == chatTask.id)) return null;
    if (close.length == 1) {
      final hit = close.single;
      if (hit.score >= confidentScore) return _Target.id(hit.task.id);
      return _Target.ask(
        ask('task.ask.didYouMean', <String, String>{'title': hit.task.title}),
      );
    }
    final titles =
        close.take(3).map((TaskSearchHit h) => '«${h.task.title}»').join(', ');
    return _Target.ask(
      ask(
        'task.ask.severalMatch',
        <String, String>{'name': query, 'candidates': titles},
      ),
    );
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

/// Отменить массовое изменение: из карточки — именно [checklist], из чата
/// («отмени») — последнее (`null`).
final class BulkUndoRequest {
  const BulkUndoRequest([this.checklist]);

  final BulkChecklist? checklist;
}

/// «Кроме …» / «только …» в ответ на вопрос массовой команды.
final class _BulkRefine {
  const _BulkRefine(this.pending, this.queries, {required this.only});

  final PendingConfirmation pending;
  final List<String> queries;
  final bool only;
}

/// Применённое массовое изменение: задачи до него и когда их изменили.
final class _BulkUndo {
  const _BulkUndo(this.checklist, this.changes);

  final BulkChecklist checklist;
  final List<(Task, DateTime)> changes;
}
