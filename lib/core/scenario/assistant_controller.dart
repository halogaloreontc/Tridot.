import '../connectors/connector.dart';
import '../connectors/login_link.dart';
import '../connectors/tasks_connector.dart';
import '../extensions/extension_registry.dart';
import '../models/action_card.dart';
import '../models/bulk.dart';
import '../models/secure_card.dart';
import '../models/task.dart';
import '../passwords/secret_guard.dart';
import '../personas/persona.dart';
import '../personas/persona_address.dart';
import '../replies/reply_library.dart';
import '../services/clock.dart';
import '../skills/passwords/passwords_phrases.dart';

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
    this.knownSecret,
  })  : assert(
          connectors == null || extensions == null,
          'Передайте либо connectors, либо extensions',
        ),
        extensions = extensions ??
            ExtensionRegistry(connectors: connectors ?? const <Connector>[]),
        session = AssistantSession(clock: clock) {
    session
      ..replies = this.extensions.replyLibrary
      ..extensions = this.extensions
      // Задачу завершили в её чате: в главном она больше не «её».
      ..onForget = (String connectorId, String itemId) {
        if (connectorId == TasksConnector.id && _mainSelection == itemId) {
          _mainSelection = null;
        }
      };
    this.extensions.addListener(_onExtensionsChanged);
  }

  /// Пример из подсказок интерфейса. Тест проверяет, что парсер его понимает.
  static const String exampleCommand = TasksConnector.exampleCommand;

  /// Совпадения ниже этой уверенности не участвуют в споре коннекторов.
  static const double ambiguityFloor = 0.5;

  /// Если два коннектора ближе друг к другу, чем на эту величину, —
  /// уточнение.
  static const double ambiguityMargin = 0.15;

  /// Адресат «основной помощник», выбранный в поле ввода явно. Это не то
  /// же, что «никого не выбрали» (`null`): явный выбор важнее ведущего
  /// роли (ADR-012), а без выбора фразу навыка роли забирает её ведущий.
  /// Основной здесь — тот, кто основной сейчас: после смены основного в
  /// настройках отвечает новый.
  static const String mainAddressee = 'main';

  /// В поле ввода выбрали помощника явно: по имени или основного
  /// ([mainAddressee]).
  static bool isExplicitAddressee(String? addressee) =>
      addressee == mainAddressee || Personas.byId(addressee) != null;

  /// Навыки, подключения, паки и выбор пользователя.
  final ExtensionRegistry extensions;

  /// Общее состояние диалога: выбранный объект, часы, последний коннектор.
  final AssistantSession session;

  /// Настройки помощников. Новые применяются со следующего сообщения:
  /// ответ, который уже готовится, договаривается прежним голосом.
  PersonaSettings personas;

  /// Совпадает ли токен по отпечатку с паролем записи открытого хранилища
  /// (`VaultFacade.knownSecret`). По нему [SecretGuard] ловит пароль без
  /// слова «пароль», а выходной фильтр — пароль в тексте ответа.
  FingerprintMatcher? knownSecret;

  /// Сколько раз выходной фильтр скрыл пароль в ответе. Это ошибка
  /// навыка (пароль оказался в названии или логине): тест канарейки
  /// требует ноль.
  int outboundLeaks = 0;

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

  // ------------------------------------------------------------ чаты

  /// Чат, открытый в интерфейсе: задача чата или `null` — главный.
  String? _viewChatTaskId;

  /// Выбор («её») главного чата, пока открыт чат задачи: при возврате в
  /// главный он восстанавливается.
  String? _mainSelection;

  /// Сколько сообщений сейчас обрабатывается.
  int _inFlight = 0;

  /// Смену чата отложили до конца ответа.
  bool _chatChangePending = false;

  /// Задача чата, открытого в интерфейсе; `null` — главный.
  String? get chatTaskId => _viewChatTaskId;

  /// Интерфейс открыл другой чат: чат задачи [taskId] или главный
  /// (`null`). Вопрос, который ждал ответа, снимается (его карточка в
  /// покинутом чате устаревает): «да» в другом чате не применит чужой
  /// вопрос. Отмена массовых изменений («Отменить») остаётся. В чате задачи
  /// «её» — эта задача; в главном — прежний выбор главного чата.
  ///
  /// Если ответ ещё готовится, смена применится после него: контекст
  /// сообщения не меняется посреди ответа.
  void enterChat({String? taskId}) {
    _viewChatTaskId = taskId;
    _awaitingAnswer = false;
    session.takePendingConfirmation()?.onDropped?.call();
    if (_inFlight > 0) {
      _chatChangePending = true;
      return;
    }
    _applyChat();
  }

  void _applyChat() {
    final target = _viewChatTaskId;
    if (session.chatTaskId == null) _mainSelection = selectedTaskId;
    session.chatTaskId = target;
    if (target != null) {
      selectTask(target);
    } else if (_mainSelection != null) {
      selectTask(_mainSelection!);
    } else {
      clearSelection();
    }
  }

  /// Кто ответит на [message]: в дуэте обращение по имени («Noda, …»)
  /// важнее адресата [addressee] из поля ввода ([mainAddressee] —
  /// основной), а без них отвечает основной — или ведущий роли, чей навык
  /// заберёт фразу ([_leadByRole]). В соло — всегда выбранный помощник, имя — просто текст.
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
  /// сообщения (`null` — никого не выбирали). В дуэте обращение по имени
  /// делает названного адресатом, как выбор в поле ввода: следующие
  /// сообщения без имени получает он. Основной — снова `null`, пока все
  /// роли ведёт он сам (тогда он и так отвечает на всё); если какую-то
  /// роль ведёт второй помощник — [mainAddressee], иначе следующую фразу
  /// этой роли забрал бы её ведущий, а не тот, к кому обратились. Просьба
  /// сменить основного («пусть отвечает Лиорио») возвращает `null`: дальше
  /// отвечает новый основной. В соло адресат не используется и не
  /// меняется.
  String? addresseeAfter(AssistantResponse response, {String? current}) {
    final settings = personas;
    if (settings.mode == AssistantMode.solo) return current;
    if (response.settingsChange?.mainPersona != null) return null;
    final addressed = Personas.byId(response.addressedPersonaId);
    if (addressed == null) return current;
    if (addressed.id != settings.main.id) return addressed.id;
    return extensions.mainLeadsAll(settings) ? null : mainAddressee;
  }

  /// Кто показан выбранным в «Кому:» при адресате [addressee]: тот, кто
  /// ответит на следующее сообщение без имени. `null` — никого не выбрали,
  /// а какую-то роль ведёт не основной: отвечает ведущий роли, чей навык
  /// заберёт фразу, и заранее его не назвать. Переключатель не показывает
  /// выбранным того, кто может не ответить. [settings] — настройки
  /// интерфейса, если они новее, чем у маршрутизатора.
  Persona? shownAddressee(String? addressee, {PersonaSettings? settings}) {
    settings ??= personas;
    final chosen = Personas.byId(addressee);
    if (chosen != null) return chosen;
    if (addressee == mainAddressee) return settings.main;
    return extensions.mainLeadsAll(settings) ? settings.main : null;
  }

  /// Отвечает на сообщение пользователя. [addressee] — помощник,
  /// выбранный в поле ввода (только в дуэте). Если к помощнику обратились
  /// по имени, ответ это отмечает ([AssistantResponse.addressedPersonaId]).
  ///
  /// [chatTaskId] — задача чата, в котором отправлено сообщение (`null` —
  /// главный чат): в чате задачи она — цель «готово», «закрой», «перенеси
  /// на завтра» без вопроса «какую?» (docs/CONNECTORS.md, «Чат задачи»).
  ///
  /// [secretRedacted] — интерфейс уже скрыл в [message] пароль
  /// ([SecretGuard]): фразу не получает ни один коннектор, ответ —
  /// `secret.redacted`.
  Future<AssistantResponse> handle(
    String message, {
    String? addressee,
    String? chatTaskId,
    bool secretRedacted = false,
  }) async {
    // Кто ответит и обратились ли по имени — по настройкам на начало
    // сообщения.
    final settings = personas;
    final (persona, text, addressed) = resolve(message, addressee: addressee);
    // Явное обращение (имя в сообщении или адресат в поле ввода, в том
    // числе явно выбранный основной) важнее владельца роли (ADR-012).
    _explicit = addressed || isExplicitAddressee(addressee);
    _inFlight++;
    session.chatTaskId = chatTaskId;
    if (chatTaskId != null) selectTask(chatTaskId);
    final before = session.pendingConfirmation;
    _answered = null;
    final AssistantResponse response;
    try {
      response = await _handle(
        settings,
        persona,
        text,
        addressed,
        secretRedacted: secretRedacted,
      );
    } finally {
      _inFlight--;
      if (_inFlight == 0 && _chatChangePending) {
        _chatChangePending = false;
        // Ответ пришёл в покинутый чат: его вопрос там и остаётся.
        session.takePendingConfirmation()?.onDropped?.call();
        _applyChat();
      }
    }
    // Вопрос сняли без ответа (другое сообщение): его карточка устарела.
    if (before != null &&
        !identical(session.pendingConfirmation, before) &&
        !identical(_answered, before)) {
      before.onDropped?.call();
    }
    _awaitingAnswer = response.status == AssistantStatus.needsClarification;
    // Навык мог отметить адресата сам: «Нода, пусть отвечает Лио» — дальше
    // отвечает Liorio, а не та, к кому обратились в начале.
    if (!addressed || response.addressedPersonaId != null) return response;
    return response.withAddressed(persona.id);
  }

  Future<AssistantResponse> _handle(
    PersonaSettings settings,
    Persona persona,
    String text,
    bool addressed, {
    bool secretRedacted = false,
  }) async {
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
    final response = await _route(
      text,
      addressed: addressed,
      secretRedacted: secretRedacted,
    );
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

  /// «Команда обрабатывается…» голосом того, кто ответит на [message]: в
  /// дуэте без явного обращения — владелец роли, чей навык, скорее всего,
  /// заберёт фразу.
  AssistantResponse working(
    String message, {
    String? addressee,
    bool secretRedacted = false,
  }) {
    final (persona, text, addressed) = resolve(message, addressee: addressee);
    var speaker = persona;
    // Фразу с паролем не получает ни один коннектор, даже для голоса.
    final guarded =
        secretRedacted || SecretGuard.redact(text, known: knownSecret).guarded;
    if (!guarded &&
        !addressed &&
        !isExplicitAddressee(addressee) &&
        session.pendingConfirmation == null &&
        personas.mode == AssistantMode.duo) {
      final likely = _likely(text);
      if (likely != null) {
        speaker = extensions.ownerFor(likely.info.id, personas) ?? speaker;
      }
    }
    return speak(
      const Reply('common.working'),
      speaker,
      intent: 'working',
      countTurn: false,
    );
  }

  /// Обратились ли в текущем сообщении к помощнику явно: по имени или
  /// выбором в поле ввода.
  bool _explicit = false;

  /// Предыдущий ответ был вопросом ([Utterance.awaitingAnswer]).
  bool _awaitingAnswer = false;

  /// Кто, скорее всего, заберёт [text] — по тем же правилам, что
  /// [_route], без подтверждений и без запуска. Только для голоса
  /// «обрабатывается…».
  Connector? _likely(String text) {
    final utterance = Utterance.analyze(text, now: session.clock.now())
        .withChat(session.chatTaskId, awaitingAnswer: _awaitingAnswer);
    final found = <(Connector, ConnectorMatch)>[];
    final passwordsPhrase = PasswordPhrases.looksLike(utterance);
    for (final connector in _connectors) {
      if (passwordsPhrase && connector.info.requiresNetwork) continue;
      try {
        final match = connector.match(utterance);
        if (match != null && match.confidence > 0) {
          found.add((connector, match));
        }
      } catch (_) {
        continue;
      }
    }
    if (found.any(((Connector, ConnectorMatch) c) => !c.$2.fallback)) {
      found.removeWhere(((Connector, ConnectorMatch) c) => c.$2.fallback);
    }
    if (found.any(((Connector, ConnectorMatch) c) => !c.$2.implicit)) {
      found.removeWhere(((Connector, ConnectorMatch) c) => c.$2.implicit);
    }
    if (found.isEmpty) return null;
    var best = found.first;
    for (final candidate in found.skip(1)) {
      if (candidate.$2.confidence > best.$2.confidence) best = candidate;
    }
    return best.$1;
  }

  /// Фразу забрал навык роли: в дуэте без явного обращения отвечает тот,
  /// кто ведёт роль (ADR-012). Обращение по имени и адресат в поле ввода
  /// важнее; в соло помощник один.
  void _leadByRole(Connector connector) {
    if (_explicit || session.personas.mode != AssistantMode.duo) return;
    final owner = extensions.ownerFor(connector.info.id, session.personas);
    if (owner == null || owner.id == session.speaker.id) return;
    session
      ..speaker = owner
      ..voice = session.personas.voiceOf(owner);
  }

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
    bool secretRedacted = false,
  }) async {
    // Пароль, вставленный в чат (D12): ни один коннектор фразу не
    // получает, задача не создаётся. Вопрос, если ждал ответа, остаётся.
    if (secretRedacted ||
        SecretGuard.redact(message, known: knownSecret).guarded) {
      session.lastConnectorId = null;
      // Навык выключен — подсказать, где его включить.
      return session.reply(
        _passwordsOff ? 'secret.redacted.off' : 'secret.redacted',
        intent: 'secret.redacted',
        status: AssistantStatus.noAction,
      );
    }
    // Ссылку входа вставили в чат, а не в настройки: подсказать, куда
    // её нести. Ни один коннектор её не получает; вопрос, если ждал
    // ответа, остаётся.
    if (LoginLinks.contains(message)) {
      session.lastConnectorId = null;
      return session.reply(
        'common.loginLink',
        intent: 'loginLink',
        status: AssistantStatus.noAction,
      );
    }
    final connectors = _connectors;
    final utterance =
        Utterance.analyze(message, now: session.clock.now()).withChat(
      session.chatTaskId,
      awaitingAnswer: _awaitingAnswer || session.pendingConfirmation != null,
    );
    // Фраза о паролях или просто со словом «пароль» (раздел 5.9): её не
    // получает ни один сетевой коннектор — ни в match, ни в уточнении
    // ответа, при любой уверенности, включён навык или нет.
    final hideFromNetwork = PasswordPhrases.looksLike(utterance);
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
      if (owner is ConfirmationFollowUp &&
          !(hideFromNetwork && owner.info.requiresNetwork)) {
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
    // Разобранная фраза о паролях при выключенном навыке не становится
    // задачей.
    final passwordsPhrase = PasswordPhrases.parse(utterance);
    if (passwordsPhrase != null &&
        passwordsPhrase.confidence >= PasswordPhrases.firm &&
        _passwordsOff) {
      session.lastConnectorId = null;
      return session.reply(
        'passwords.off',
        intent: 'passwords.off',
        status: AssistantStatus.noAction,
      );
    }
    final candidates = <(Connector, ConnectorMatch)>[];
    for (final connector in connectors) {
      if (hideFromNetwork && connector.info.requiresNetwork) continue;
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
        final instead = owner is ConfirmationFollowUp &&
                !(hideFromNetwork && owner.info.requiresNetwork)
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

    // Явная фраза о паролях — у навыка «Пароли» (раздел 6): «добавь
    // пароль для озона» — не задача «Пароль для озона».
    if (candidates.any(
      ((Connector, ConnectorMatch) c) =>
          c.$1.info.id == passwordsId && !c.$2.implicit,
    )) {
      candidates.removeWhere(
        ((Connector, ConnectorMatch) c) => c.$1.info.id != passwordsId,
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

    _leadByRole(bestConnector);
    return _run(bestConnector, best);
  }

  Future<AssistantResponse> _answer(
    Connector owner,
    PendingConfirmation pending,
    ConfirmationReply reply, {
    bool viaButton = false,
  }) {
    _answered = pending;
    return _run(
      owner,
      ConnectorMatch(
        connectorId: owner.info.id,
        commandId: pending.commandId,
        confidence: 1,
        payload: ConfirmationAnswer(pending, reply, viaButton: viaButton),
      ),
    );
  }

  Future<AssistantResponse> _run(
    Connector connector,
    ConnectorMatch match,
  ) async {
    try {
      return _filterOutbound(await connector.run(match, session));
    } catch (error) {
      // Навык с секретами: текст исключения мог нести пароль (D13).
      if (connector.info.sensitive) {
        return session.reply(
          'router.failed.quiet',
          intent: match.commandId,
          status: AssistantStatus.failed,
        );
      }
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

  /// Выходной фильтр (раздел 5.9): при открытом хранилище текст ответа и
  /// подставленные факты проверяются по отпечаткам паролей. Совпадение
  /// заменяется на `•••` и считается ошибкой ([outboundLeaks]).
  AssistantResponse _filterOutbound(AssistantResponse response) {
    final known = knownSecret;
    if (known == null) return response;
    var leaked = false;
    var message = response.message;
    final values = <String, String>{};
    for (final MapEntry(:key, :value) in response.values.entries) {
      final checked = SecretGuard.redactKnown(value, known);
      if (checked.guarded) {
        leaked = true;
        message = message.replaceAll(value, checked.text);
      }
      values[key] = checked.text;
    }
    final text = SecretGuard.redactKnown(message, known);
    if (!leaked && !text.guarded) return response;
    outboundLeaks++;
    return response.withText(text.text, values);
  }

  /// Id навыка «Пароли» (ADR-014).
  static const String passwordsId = 'passwords';

  /// Навык «Пароли» есть в сборке, но выключен: фразы о паролях получают
  /// `passwords.off`, а не становятся задачами (D18).
  bool get _passwordsOff =>
      extensions.info(passwordsId) != null &&
      !extensions.isEnabled(passwordsId);

  /// Нажатие во временной карточке навыка «Пароли» ([SecureCardCommand]):
  /// выбор записи, «Удалить», повтор команды после открытия хранилища,
  /// отметка «пароль был показан». Говорит помощник [personaId] (автор
  /// карточки). `null` — навык выключен.
  Future<AssistantResponse?> secureCardAction(
    SecureCardRequest card,
    String action, {
    String? entryId,
    String? detail,
    String? personaId,
  }) async {
    final owner = _connectors
        .where((Connector c) => c.info.id == passwordsId)
        .firstOrNull;
    if (owner == null) return null;
    final speaker = Personas.byId(personaId) ?? personas.responder;
    _voiceOf(speaker);
    final response = await _run(
      owner,
      ConnectorMatch(
        connectorId: owner.info.id,
        commandId: '$passwordsId.card',
        confidence: 1,
        payload: SecureCardCommand(
          card,
          action,
          entryId: entryId,
          detail: detail,
        ),
      ),
    );
    return response.withPersona(speaker.id);
  }

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

  // ------------------------------------------- действия с записью

  /// Карточка действия, которая ждёт «Подтвердить», или `null`.
  ActionCard? get pendingCard {
    final payload = session.pendingConfirmation?.payload;
    return payload is ActionCard ? payload : null;
  }

  /// Кнопка «Подтвердить» ([apply]) или «Отмена» на карточке действия
  /// (ADR-013). Только так действие с записью и выполняется: ответ «да»
  /// текстом лишь просит нажать кнопку. Отвечает тот, кто спросил.
  /// `null` — карточка уже не ждёт ответа (устарела, отвечена, нажата
  /// второй раз): ни одного запроса.
  Future<AssistantResponse?> answerCard(
    ActionCard card, {
    required bool apply,
  }) async {
    final pending = session.pendingConfirmation;
    if (pending == null || !identical(pending.payload, card)) return null;
    if (!card.isPending) return null;
    final owner = _connectors
        .where((Connector c) => c.info.id == pending.connectorId)
        .firstOrNull;
    if (owner == null) return null;
    final asker = session.pendingSpeaker ?? personas.responder;
    // Ожидание снимается до запроса: второе нажатие не найдёт карточку.
    session.takePendingConfirmation();
    _voiceOf(asker);
    final response = await _answer(
      owner,
      pending,
      apply ? ConfirmationReply.yes : ConfirmationReply.no,
      viaButton: true,
    );
    return response.withPersona(asker.id);
  }

  /// «Проверить» под карточкой с неизвестным итогом: спросить склад, чем
  /// кончилось. Запись не повторяется. `null` — проверять нечего.
  Future<AssistantResponse?> settleCard(
    ActionCard card, {
    String? personaId,
  }) async {
    if (!card.canSettle) return null;
    final owner = _connectors
        .where((Connector c) => c.info.id == card.connectorId)
        .firstOrNull;
    if (owner == null) return null;
    final speaker = Personas.byId(personaId) ?? personas.responder;
    _voiceOf(speaker);
    final response = await _run(
      owner,
      ConnectorMatch(
        connectorId: owner.info.id,
        commandId: '${owner.info.id}.act.settle',
        confidence: 1,
        payload: ActionCardSettle(card),
      ),
    );
    return response.withPersona(speaker.id);
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
