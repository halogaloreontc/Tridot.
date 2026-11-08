import '../connectors/connector.dart';
import '../connectors/tasks_connector.dart';
import '../extensions/extension_registry.dart';
import '../models/bulk.dart';
import '../models/task.dart';
import '../personas/persona.dart';
import '../personas/persona_address.dart';
import '../replies/reply_library.dart';
import '../services/clock.dart';

/// Маршрутизатор сообщений между коннекторами.
///
/// На каждое сообщение один раз строит [Utterance], спрашивает каждый
/// коннектор `match`, выбирает самое уверенное совпадение и запускает его
/// `run`. Если два разных коннектора одинаково уверены, просит уточнить,
/// а не выбирает наугад. Интерфейс работает только с этим классом.
///
/// Если коннектор ждёт подтверждения ([AssistantSession.pendingConfirmation])
/// и сообщение — «да» или «нет» ([ConfirmationReply.of]), ответ уходит
/// этому коннектору до обычного разбора. Ответ с пояснением («да, купил
/// хлеб», [ConfirmationReply.leading]) уходит ему же, если ни один
/// коннектор не нашёл в сообщении явной команды. Любое другое сообщение
/// снимает ожидание — кроме отклика, похожего на согласие («хорошо»,
/// «спасибо», [ConnectorMatch.acknowledgement]): на него помощник
/// переспрашивает «да» или «нет», ничего не делает, и вопрос остаётся в
/// силе ещё на одно сообщение. Совпадение без маркера ([ConnectorMatch.implicit])
/// уступает явному совпадению другого коннектора, а совпадение на крайний
/// случай ([ConnectorMatch.fallback], беседа) — любому другому совпадению.
///
/// Спрашиваются только включённые расширения ([ExtensionRegistry]). Их
/// можно включать и выключать на ходу: задачи, выбор и история не
/// сбрасываются, снимается только ожидание подтверждения выключенного
/// коннектора.
///
/// Отвечает один из помощников ([personas], docs/PLANS.md, «Liorio и Noda»):
/// в дуэте — основной, адресат из поля ввода или тот, к кому обратились по
/// имени («Noda, …»), в соло — выбранный. Обращение по имени в дуэте
/// отмечается в ответе ([AssistantResponse.addressedPersonaId]), и
/// интерфейс делает названного адресатом чата ([addresseeAfter]): к кому
/// обратились, тот и продолжает. На «да» или «нет» в дуэте отвечает тот,
/// кто спросил ([AssistantSession.pendingSpeaker]), если в ответе никого
/// не назвали по имени. Голос (стиль, род, обращение, эмодзи) фиксируется
/// в начале сообщения: смена настроек посреди ответа применится со
/// следующего. Тексты — из каталога ответов ([AssistantSession.replies]).
final class AssistantController {
  /// [connectors] — все включены; [extensions] — реестр с выбором
  /// пользователя. Передаётся что-то одно.
  AssistantController({
    List<Connector>? connectors,
    ExtensionRegistry? extensions,
    Clock clock = const SystemClock(),
    this.personas = const PersonaSettings(),
  })  : assert(
          connectors == null || extensions == null,
          'Передайте либо connectors, либо extensions',
        ),
        extensions = extensions ??
            ExtensionRegistry(connectors: connectors ?? const <Connector>[]),
        session = AssistantSession(clock: clock) {
    session
      ..replies = this.extensions.replyLibrary
      ..extensions = this.extensions;
    this.extensions.addListener(_onExtensionsChanged);
  }

  /// Пример из подсказок интерфейса. Тест проверяет, что парсер его понимает.
  static const String exampleCommand = TasksConnector.exampleCommand;

  /// Совпадения ниже этой уверенности не участвуют в споре коннекторов.
  static const double ambiguityFloor = 0.5;

  /// Если два коннектора ближе друг к другу, чем на эту величину, —
  /// уточнение.
  static const double ambiguityMargin = 0.15;

  /// Навыки, подключения, паки и выбор пользователя.
  final ExtensionRegistry extensions;

  /// Общее состояние диалога: выбранный объект, часы, последний коннектор.
  final AssistantSession session;

  /// Настройки помощников. Новые применяются со следующего сообщения:
  /// ответ, который уже готовится, договаривается прежним голосом.
  PersonaSettings personas;

  /// Каталоги ответов вместе со стилями включённых паков.
  ReplyLibrary get replies => session.replies;

  /// Включённые сейчас коннекторы.
  List<Connector> get _connectors => extensions.enabledConnectors;

  /// Паспорта включённых коннекторов.
  List<ConnectorInfo> get connectors => <ConnectorInfo>[
        for (final connector in _connectors) connector.info,
      ];

  /// Выключенный коннектор не получит «да» на свой вопрос: ожидание
  /// снимается сразу. Остальное (выбор, ожидание других) не трогаем.
  void _onExtensionsChanged() {
    session.replies = extensions.replyLibrary;
    final pending = session.pendingConfirmation;
    if (pending == null) return;
    final enabled = _connectors.any(
      (Connector c) => c.info.id == pending.connectorId,
    );
    if (!enabled) session.takePendingConfirmation()?.onDropped?.call();
  }

  /// Ожидание, на которое ответили в текущем сообщении: его не нужно
  /// объявлять снятым ([PendingConfirmation.onDropped]).
  PendingConfirmation? _answered;

  /// Задача, к которой относятся «её», «перенеси», «заверши».
  String? get selectedTaskId => session.selectedItemFor(TasksConnector.id);

  void selectTask(String id) => session.select(TasksConnector.id, id);

  void clearSelection() => session.clearSelection();

  /// Задачу завершили или удалили не через диалог.
  void forgetTask(String id) => session.forget(TasksConnector.id, id);

  /// Кто ответит на [message]: в дуэте обращение по имени («Noda, …»)
  /// важнее адресата [addressee] из поля ввода, а без них отвечает
  /// основной. В соло — всегда выбранный помощник, имя — просто текст.
  /// Возвращает помощника и текст без обращения.
  (Persona, String, bool) resolve(String message, {String? addressee}) {
    final settings = personas;
    if (settings.mode == AssistantMode.solo) {
      return (settings.solo, message, false);
    }
    final addressing = PersonaAddressing.parse(message);
    if (addressing != null) return (addressing.persona, addressing.rest, true);
    return (Personas.byId(addressee) ?? settings.main, message, false);
  }

  /// Адресат чата после ответа [response]; [current] — адресат до
  /// сообщения (`null` — основной). В дуэте обращение по имени делает
  /// названного адресатом, как выбор в поле ввода: следующие сообщения без
  /// имени получает он. Основной — снова `null`. Просьба сменить основного
  /// («пусть отвечает Лиорио») тоже возвращает `null`: дальше отвечает новый
  /// основной. В соло адресат не используется и не меняется.
  String? addresseeAfter(AssistantResponse response, {String? current}) {
    final settings = personas;
    if (settings.mode == AssistantMode.solo) return current;
    if (response.settingsChange?.mainPersona != null) return null;
    final addressed = Personas.byId(response.addressedPersonaId);
    if (addressed == null) return current;
    return addressed.id == settings.main.id ? null : addressed.id;
  }

  /// Отвечает на сообщение пользователя. [addressee] — помощник,
  /// выбранный в поле ввода (только в дуэте). Если к помощнику обратились
  /// по имени, ответ это отмечает ([AssistantResponse.addressedPersonaId]).
  Future<AssistantResponse> handle(String message, {String? addressee}) async {
    // Кто ответит и обратились ли по имени — по настройкам на начало
    // сообщения.
    final settings = personas;
    final (persona, text, addressed) = resolve(message, addressee: addressee);
    final before = session.pendingConfirmation;
    _answered = null;
    final response = await _handle(settings, persona, text, addressed);
    // Вопрос сняли без ответа (другое сообщение): его карточка устарела.
    if (before != null &&
        !identical(session.pendingConfirmation, before) &&
        !identical(_answered, before)) {
      before.onDropped?.call();
    }
    // Навык мог отметить адресата сам: «Нода, пусть отвечает Лио» — дальше
    // отвечает Liorio, а не та, к кому обратились в начале.
    if (!addressed || response.addressedPersonaId != null) return response;
    return response.withAddressed(persona.id);
  }

  Future<AssistantResponse> _handle(
    PersonaSettings settings,
    Persona persona,
    String text,
    bool addressed,
  ) async {
    session
      ..voice = settings.voiceOf(persona)
      ..speaker = persona
      ..personas = settings;
    if (addressed && text.isEmpty) {
      // «Нода» без команды: отклик, ожидание подтверждения снимается,
      // как любым другим сообщением.
      session.lastConnectorId = null;
      session.takePendingConfirmation();
      return session
          .reply(
            'common.addressed',
            values: const <String, String>{
              'example': AssistantController.exampleCommand,
            },
            intent: 'unknown',
            status: AssistantStatus.noAction,
          )
          .withPersona(persona.id);
    }
    final response = await _route(text, addressed: addressed);
    final change = response.settingsChange;
    // Просьба из беседы («говори короче») — к настройкам на сейчас: если
    // их поменяли во время ответа, эти перемены не теряются. Интерфейс
    // применяет то же изменение и сохраняет его.
    if (change != null) personas = change.apply(personas);
    // Беседа может ответить от другого помощника: «пусть отвечает Лиорио»,
    // на «да» отвечает спросивший (_speakAsAsker).
    return response.withPersona(response.personaId ?? session.speaker.id);
  }

  /// Приветствие основного (в соло — единственного) помощника.
  AssistantResponse welcome() => speak(
        const Reply('common.welcome', <String, String>{
          'example': AssistantController.exampleCommand,
        }),
        personas.responder,
        intent: 'welcome',
      );

  /// «Команда обрабатывается…» голосом того, кто ответит на [message].
  AssistantResponse working(String message, {String? addressee}) => speak(
        const Reply('common.working'),
        resolve(message, addressee: addressee).$1,
        intent: 'working',
        countTurn: false,
      );

  /// Первым пишет второй помощник (в соло — единственный): просроченные
  /// задачи. `null`, если просроченных нет.
  AssistantResponse? overdueNotice(List<Task> overdue) {
    if (overdue.isEmpty) return null;
    return speak(
      Reply('task.overdue', <String, String>{
        'count': '${overdue.length}',
        'titles': overdue.take(3).map((Task t) => '«${t.title}»').join(', ') +
            (overdue.length > 3 ? ' и ещё ${overdue.length - 3}' : ''),
      }),
      personas.notifier,
      intent: 'task.overdue',
    );
  }

  /// Реплика из каталога голосом [persona] вне разговора: голос текущего
  /// ответа ([AssistantSession.voice]) не меняется.
  AssistantResponse speak(
    Reply reply,
    Persona persona, {
    required String intent,
    AssistantStatus status = AssistantStatus.completed,
    bool countTurn = true,
  }) =>
      AssistantResponse(
        message: session.replies.render(
          reply,
          personas.voiceOf(persona),
          turn: countTurn ? session.turn++ : session.turn,
        ),
        intent: intent,
        status: status,
        replyId: reply.id,
        values: reply.values,
        personaId: persona.id,
      );

  /// Ответ на вопрос подтверждения в дуэте звучит от того, кто спросил,
  /// даже если адресат в поле ввода с тех пор сменился. Если в ответе
  /// назвали помощника по имени в начале ([addressed]: «Лио, да»), отвечает
  /// названный. Имя в конце ([trailing]: «да, Лиорио», «спасибо, Лио») —
  /// тоже обращение: отвечает названный. В соло помощник один — тот, что
  /// в настройках сейчас.
  void _speakAsAsker(
    Persona? asker, {
    required bool addressed,
    Persona? trailing,
  }) {
    if (session.personas.mode != AssistantMode.duo) return;
    final speaker = trailing ?? (addressed ? null : asker);
    if (speaker == null) return;
    session
      ..speaker = speaker
      ..voice = session.personas.voiceOf(speaker);
  }

  /// Ответ на вопрос подтверждения с именем в конце отмечает названного
  /// адресатом, как обращение в начале ([handle]).
  static AssistantResponse _markTrailing(
    AssistantResponse response,
    Persona? trailing,
  ) =>
      trailing == null ? response : response.withAddressed(trailing.id);

  Future<AssistantResponse> _route(
    String message, {
    required bool addressed,
  }) async {
    final connectors = _connectors;
    final utterance = Utterance.analyze(message, now: session.clock.now());
    final asker = session.pendingSpeaker;
    final pending = session.takePendingConfirmation();
    final owner = pending == null
        ? null
        : connectors
            .where((Connector c) => c.info.id == pending.connectorId)
            .firstOrNull;
    // «Да, Лиорио», «спасибо, Нода»: имя в конце ответа на вопрос — тоже
    // обращение (в дуэте). Само «да» или «нет» ищем в тексте без имени.
    final trailing = pending != null &&
            owner != null &&
            !addressed &&
            session.personas.mode == AssistantMode.duo
        ? PersonaAddressing.parseTrailing(message)
        : null;
    final named = trailing?.persona;
    final answerUtterance = trailing == null
        ? utterance
        : Utterance.analyze(trailing.rest, now: session.clock.now());
    if (pending != null && owner != null) {
      final reply = ConfirmationReply.of(answerUtterance);
      if (reply != null) {
        _speakAsAsker(asker, addressed: addressed, trailing: named);
        return _markTrailing(await _answer(owner, pending, reply), named);
      }
      // «Кроме хлеба», «только отчёт»: уточнение ответа, которое понимает
      // сам спросивший коннектор (ConfirmationFollowUp).
      if (owner is ConfirmationFollowUp) {
        final followUp = (owner as ConfirmationFollowUp).matchFollowUp(
          answerUtterance,
          pending,
        );
        if (followUp != null) {
          _speakAsAsker(asker, addressed: addressed, trailing: named);
          return _markTrailing(await _run(owner, followUp), named);
        }
      }
    }
    final candidates = <(Connector, ConnectorMatch)>[];
    for (final connector in connectors) {
      final ConnectorMatch? match;
      try {
        match = connector.match(utterance);
      } catch (error) {
        // Ошибка в одном коннекторе не должна ломать остальные.
        continue;
      }
      if (match == null || match.confidence <= 0) continue;
      candidates.add((connector, match));
    }
    if (pending != null && owner != null) {
      // «Да, купил хлеб», «нет, не купил»: ответ с пояснением. Если в
      // пояснении явная команда («нет, добавь задачу молоко»), это уже
      // новое сообщение, а не ответ.
      final reply = ConfirmationReply.leading(answerUtterance);
      if (reply != null &&
          candidates.every(
            ((Connector, ConnectorMatch) c) => c.$2.implicit || c.$2.fallback,
          )) {
        _speakAsAsker(asker, addressed: addressed, trailing: named);
        // Владелец может не принять согласие с оговоркой («да, но хлеб не
        // трогай» в ответ на список задач) и переспросить.
        final instead = owner is ConfirmationFollowUp
            ? (owner as ConfirmationFollowUp)
                .matchLeadingAnswer(answerUtterance, pending, reply)
            : null;
        if (instead != null) {
          return _markTrailing(await _run(owner, instead), named);
        }
        return _markTrailing(await _answer(owner, pending, reply), named);
      }
      // «Хорошо», «спасибо» в ответ на вопрос: не согласие и не новая
      // команда. Молча снять вопрос нельзя — пользователь решит, что
      // действие выполнено. Переспрашиваем и ждём ответа дальше.
      final before = candidates.length;
      candidates.removeWhere(
        ((Connector, ConnectorMatch) c) => c.$2.acknowledgement,
      );
      if (candidates.isEmpty && before > 0) {
        // Переспрашивает тот, кто спросил (или названный по имени).
        _speakAsAsker(asker, addressed: addressed, trailing: named);
        session.requestConfirmation(pending);
        return _markTrailing(
          session.reply(
            'common.confirm.unclear',
            intent: 'confirm.unclear',
            status: AssistantStatus.needsClarification,
          ),
          named,
        );
      }
    }
    if (candidates.isEmpty) {
      session.lastConnectorId = null;
      return _unknown();
    }
    // Совпадение на крайний случай (беседа) уступает любому другому.
    if (candidates.any(((Connector, ConnectorMatch) c) => !c.$2.fallback)) {
      candidates.removeWhere(
        ((Connector, ConnectorMatch) c) => c.$2.fallback,
      );
    }
    // Совпадение без маркера уступает явному совпадению другого коннектора.
    if (candidates.any(((Connector, ConnectorMatch) c) => !c.$2.implicit)) {
      candidates.removeWhere(
        ((Connector, ConnectorMatch) c) => c.$2.implicit,
      );
    }

    // Устойчивая сортировка: при равной уверенности побеждает коннектор,
    // подключённый раньше (но тогда сработает уточнение ниже).
    final ranked = candidates.indexed.toList()
      ..sort((a, b) {
        final byConfidence = b.$2.$2.confidence.compareTo(a.$2.$2.confidence);
        return byConfidence != 0 ? byConfidence : a.$1.compareTo(b.$1);
      });
    final (bestConnector, best) = ranked.first.$2;
    for (final (_, (other, otherMatch)) in ranked.skip(1)) {
      if (other.info.id == bestConnector.info.id) continue;
      if (best.confidence >= ambiguityFloor &&
          otherMatch.confidence >= ambiguityFloor &&
          best.confidence - otherMatch.confidence <= ambiguityMargin) {
        session.lastConnectorId = null;
        return session.reply(
          'router.ambiguous',
          values: <String, String>{
            'first': bestConnector.info.title,
            'second': other.info.title,
          },
          intent: 'router.ambiguous',
          status: AssistantStatus.needsClarification,
        );
      }
      break;
    }

    return _run(bestConnector, best);
  }

  Future<AssistantResponse> _answer(
    Connector owner,
    PendingConfirmation pending,
    ConfirmationReply reply,
  ) {
    _answered = pending;
    return _run(
      owner,
      ConnectorMatch(
        connectorId: owner.info.id,
        commandId: pending.commandId,
        confidence: 1,
        payload: ConfirmationAnswer(pending, reply),
      ),
    );
  }

  Future<AssistantResponse> _run(
    Connector connector,
    ConnectorMatch match,
  ) async {
    try {
      return await connector.run(match, session);
    } catch (error) {
      return session.reply(
        'router.failed',
        values: <String, String>{'error': '$error'},
        intent: match.commandId,
        status: AssistantStatus.failed,
      );
    } finally {
      session.lastConnectorId = connector.info.id;
    }
  }

  AssistantResponse _unknown() => TasksConnector.unknown(session);

  // ------------------------------------------------- массовые команды

  /// Список массовой команды, который ждёт ответа, или `null`.
  BulkChecklist? get pendingChecklist {
    final payload = session.pendingConfirmation?.payload;
    return payload is BulkChecklist ? payload : null;
  }

  /// Галочка в карточке: не сообщение, ожидание ответа не снимается.
  /// Отметки меняются только у вопроса, который ещё ждёт ответа.
  bool setBulkItemChecked(BulkChecklist checklist, String taskId, bool value) =>
      identical(pendingChecklist, checklist) &&
      checklist.setChecked(taskId, value);

  /// «Выбрать все» / «Снять все» в карточке.
  bool setAllBulkItems(BulkChecklist checklist, bool value) =>
      identical(pendingChecklist, checklist) && checklist.setAll(value);

  /// Кнопка «Перенести (N)» / «Отметить (N)» ([apply]) или «Отмена» в
  /// карточке: то же, что ответ «да» или «нет» в чате, и отвечает тот, кто
  /// спросил. `null` — вопрос уже не ждёт ответа (устарел или отвечен).
  Future<AssistantResponse?> answerBulk(
    BulkChecklist checklist, {
    required bool apply,
  }) async {
    final pending = session.pendingConfirmation;
    if (pending == null || !identical(pending.payload, checklist)) return null;
    final owner = _connectors
        .where((Connector c) => c.info.id == pending.connectorId)
        .firstOrNull;
    if (owner == null) return null;
    final asker = session.pendingSpeaker ?? personas.responder;
    session.takePendingConfirmation();
    _voiceOf(asker);
    final response = await _answer(
      owner,
      pending,
      apply ? ConfirmationReply.yes : ConfirmationReply.no,
    );
    return response.withPersona(asker.id);
  }

  /// Кнопка «Отменить» под применённой карточкой: вернуть сроки и статусы
  /// задач как было. Говорит помощник [personaId] (автор карточки).
  /// `null` — отменять уже нечего.
  Future<AssistantResponse?> undoBulk(
    BulkChecklist checklist, {
    String? personaId,
  }) async {
    if (!checklist.canUndo) return null;
    final tasks = _connectors.whereType<TasksConnector>().firstOrNull;
    if (tasks == null) return null;
    final speaker = Personas.byId(personaId) ?? personas.responder;
    _voiceOf(speaker);
    final response = await _run(
      tasks,
      ConnectorMatch(
        connectorId: TasksConnector.id,
        commandId: TasksConnector.undoCommand,
        confidence: 1,
        payload: BulkUndoRequest(checklist),
      ),
    );
    return response.withPersona(speaker.id);
  }

  /// Чат очищен: вопрос, который ждал ответа, снят, а отменить прежние
  /// массовые изменения из чата больше нельзя.
  void clearConversation() {
    session.takePendingConfirmation()?.onDropped?.call();
    for (final connector in _connectors.whereType<TasksConnector>()) {
      connector.forgetUndo();
    }
  }

  void _voiceOf(Persona speaker) {
    final settings = personas;
    session
      ..personas = settings
      ..speaker = speaker
      ..voice = settings.voiceOf(speaker);
  }
}
