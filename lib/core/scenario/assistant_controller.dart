import '../commands/command_catalog.dart';
import '../commands/command_suggest.dart';
import '../connectors/connector.dart';
import '../connectors/login_link.dart';
import '../connectors/tasks_connector.dart';
import '../extensions/extension_registry.dart';
import '../intent/intent_fallback.dart';
import '../jobs/extension_card.dart';
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
import 'command_frame.dart';
import 'command_spans.dart';
import 'layout_fix.dart';
import 'recognition_layers.dart';
import 'route_policy.dart';

export 'command_spans.dart';
export 'route_policy.dart';

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
/// Отвечает один из помощников ([personas], ADR-016): без обращения —
/// Связной или ведущий обязанности, чей навык забрал фразу (склад, пароли —
/// ведущий расширений, если режим его включает), а тот, к кому обратились
/// по имени («Нода, …»), — на это сообщение. Имя помощника, выключенного
/// режимом, — просто текст. Обращение по имени отмечается в ответе
/// ([AssistantResponse.addressedPersonaId]).
///
/// К кому обратились — тот и продолжает, пока разговор идёт тем же
/// навыком ([_followUp]): «Нода, расскажи шутку» → «ещё шутку» — снова
/// Нода, а «покажи задачи» после этого — уже Связной.
/// Продолжение — не дольше [followUpLimit] фраз без имени. Это короткое
/// продолжение живёт только здесь, в памяти: интерфейс его не
/// показывает и не сохраняет, смена чата его снимает. Выбора «Кому» в
/// интерфейсе нет. На «да» или «нет» отвечает тот,
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
    PersonaSettings personas = const PersonaSettings(),
    this.knownSecret,
  })  : _personas = personas,
        assert(
          connectors == null || extensions == null,
          'Передайте либо connectors, либо extensions',
        ),
        extensions = extensions ??
            ExtensionRegistry(connectors: connectors ?? const <Connector>[]),
        session = AssistantSession(clock: clock) {
    PersonaCast.configure(personas);
    session
      ..replies = this.extensions.replyLibrary
      ..extensions = this.extensions
      // Задачу завершили в её чате: в сессиях она больше не
      // «её».
      ..onForget = (String connectorId, String itemId) {
        if (connectorId == TasksConnector.id) {
          _selections.removeWhere((String? _, String id) => id == itemId);
        }
      };
    this.extensions.addListener(_onExtensionsChanged);
  }

  /// Пример из подсказок интерфейса. Тест проверяет, что парсер его понимает.
  static const String exampleCommand = TasksConnector.exampleCommand;

  /// Запасной слой понимания (ADR-045): на «не понял» правил — вопрос
  /// «Похоже, вы хотите …?», журнал непонятых фраз и личные примеры.
  /// `null` — слоя нет: ответы правил те же, что без него. Модель внутри
  /// может быть не загружена ([IntentFallback.model]) — тогда только
  /// журнал.
  IntentFallback? intent;

  /// Ожидание вопроса запасного слоя ([PendingConfirmation.commandId]).
  static const String intentSuggestCommand = 'intent.suggest';

  /// Вопрос «Похоже, вы хотите …?» с одним вариантом и с двумя.
  static const String intentSuggestReply = 'intent.suggest';
  static const String intentSuggestTwoReply = 'intent.suggest.two';

  /// «Да», а команду из фразы не разобрать: пример команды.
  static const String intentHowReply = 'intent.how';

  /// Метки, которые запасной слой не предлагает: справочный вопрос беседы
  /// честно говорит «не подскажу» — предлагать его незачем.
  static const Set<String> intentNever = <String>{'talk:talk.question'};

  /// Ответ беседы на справочный вопрос без справочника: тоже «не понял»
  /// для запасного слоя.
  static const String _offlineQuestionReply = 'talk.question.offline';

  /// Совпадения ниже этой уверенности не участвуют в споре коннекторов
  /// ([RoutePolicy.ambiguityFloor]).
  static const double ambiguityFloor = RoutePolicy.ambiguityFloor;

  /// Если два коннектора ближе друг к другу, чем на эту величину, —
  /// уточнение ([RoutePolicy.ambiguityMargin]).
  static const double ambiguityMargin = RoutePolicy.ambiguityMargin;

  /// Контекст сессии ([Utterance.recentConnectorId]) живёт столько
  /// обработанных сообщений этого чата: «сделай бэкап» через одно
  /// сообщение после разговора о паролях — ещё о паролях.
  static const int contextMessages = 2;

  /// И не дольше этого времени: через полчаса «сделай бэкап» — снова
  /// вопрос «копию чего?».
  static const Duration contextWindow = Duration(minutes: 10);

  /// Адресат «главный помощник» (Связной), выбранный явно. Это не то же, что
  /// «никого не выбрали» (`null`): явный выбор важнее ведущего обязанности
  /// (ADR-016), а без выбора фразу расширения забирает его ведущий.
  static const String mainAddressee = 'main';

  /// В поле ввода выбрали помощника явно: по имени или главного
  /// ([mainAddressee]).
  static bool isExplicitAddressee(String? addressee) =>
      addressee == mainAddressee || Personas.byId(addressee) != null;

  /// Помощник [id] с текущим именем и родом из настроек; неизвестный id —
  /// `null`.
  Persona? _member(String? id) => personas.cast.find(id);

  /// Помощник [id] с текущим именем, если он активен в текущем режиме;
  /// выключенный режимом или неизвестный — `null`.
  Persona? _activeMember(String? id) {
    final cast = personas.cast;
    final persona = cast.find(id);
    return persona != null && cast.isActive(persona.id) ? persona : null;
  }

  /// Кто спросил ([AssistantSession.pendingSpeaker]) с текущим именем;
  /// выключен режимом после вопроса — ведущий обязанности навыка
  /// [connectorId], как у карточек ([_cardSpeaker]). Не спрашивал никто —
  /// `null`.
  Persona? _activeAsker(Persona? asker, String connectorId) =>
      asker == null ? null : _cardSpeaker(asker.id, connectorId);

  /// Автор карточки [id], если он ещё активен в текущем режиме; иначе —
  /// ведущий обязанности навыка [connectorId]: карточка, нажатая после
  /// смены режима, не говорит голосом выключенного помощника.
  Persona _cardSpeaker(String? id, String connectorId) {
    final cast = personas.cast;
    final author = cast.find(id);
    return author != null && cast.isActive(author.id)
        ? author
        : extensions.ownerFor(connectorId, personas);
  }

  /// Навыки, подключения, паки и выбор пользователя.
  final ExtensionRegistry extensions;

  /// Общее состояние диалога: выбранный объект, часы, последний коннектор.
  final AssistantSession session;

  /// Настройки помощников. Новые применяются со следующего сообщения:
  /// ответ, который уже готовится, договаривается прежним голосом. Имена
  /// для обращения меняются сразу ([PersonaCast.configure]).
  PersonaSettings get personas => _personas;
  set personas(PersonaSettings value) {
    _personas = value;
    PersonaCast.configure(value);
    // Продолжение с помощником, которого режим выключил, снимается: он
    // больше не отвечает (ADR-016).
    final follow = _followUp;
    if (follow != null && _activeMember(follow.personaId) == null) {
      _followUp = null;
    }
  }

  PersonaSettings _personas;

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

  /// Счётчики выбора команд (`AppSettings.commandUsage`, ADR-020): только
  /// порядок подсказки при равной похожести ([_unknownFor]). Ставит
  /// интерфейс; только id и числа.
  Map<String, int> commandUsage = const <String, int>{};

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

  final List<void Function()> _betweenTurns = <void Function()>[];

  /// Сообщение сейчас обрабатывается ([handle] ещё не вернул ответ).
  bool get midTurn => _inFlight > 0;

  /// Выполняет [change] между ходами диалога: сразу, если сообщение не
  /// обрабатывается, иначе — как только последнее обработается. Так
  /// пересобирается реестр расширений после «Подключить» и «Удалить»
  /// приложение (ADR-043): ход, который уже идёт, договаривает с прежним
  /// набором коннекторов.
  void betweenTurns(void Function() change) {
    if (_inFlight == 0) {
      change();
      return;
    }
    _betweenTurns.add(change);
  }

  void _runBetweenTurns() {
    while (_betweenTurns.isNotEmpty && _inFlight == 0) {
      _betweenTurns.removeAt(0)();
    }
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

  /// Чат, открытый в интерфейсе: задача чата или `null` — сессия.
  String? _viewChatTaskId;

  /// Чат без задачи, открытый в интерфейсе: id сессии (`null` — ещё не
  /// сообщали).
  String? _viewSessionId;

  /// Метка задач проекта-папки открытой сессии ([enterChat]).
  String? _viewProjectTag;

  /// Чат без задачи, чей выбор сейчас в [session]; не важен, пока открыт
  /// чат задачи.
  String? _appliedSessionId;

  /// Выбор («её») каждой сессии (ключ `null` — до первого [enterChat]), пока
  /// открыт другой чат: при возврате он восстанавливается. Сессии —
  /// отдельные разговоры: задача, выбранная в одной, не «её» в другой.
  final Map<String?, String> _selections = <String?, String>{};

  /// Сколько сообщений сейчас обрабатывается.
  int _inFlight = 0;

  /// Смену чата отложили до конца ответа.
  bool _chatChangePending = false;

  /// Задача чата, открытого в интерфейсе; `null` — сессия.
  String? get chatTaskId => _viewChatTaskId;

  /// Интерфейс открыл другой чат: чат задачи [taskId], сессию
  /// [sessionId]. Вопрос, который ждал ответа, снимается (его карточка в
  /// покинутом чате устаревает): «да» в другом чате не применит чужой
  /// вопрос. Отмена массовых изменений («Отменить») остаётся. В чате задачи
  /// «её» — эта задача; в сессии — прежний выбор этой сессии.
  ///
  /// [projectTag] — метка задач проекта-папки, в котором лежит чат
  /// (ADR-018): новая задача без своей метки получает её.
  ///
  /// Если ответ ещё готовится, смена применится после него: контекст
  /// сообщения не меняется посреди ответа.
  void enterChat({String? taskId, String? sessionId, String? projectTag}) {
    // Продолжение разговора — только в том чате, где обратились.
    _followUp = null;
    _chatEpoch++;
    // Контекст сессии и «предыдущий коннектор» — только этого чата: «да»
    // и «сделай бэкап» в другом чате не опираются на чужой разговор.
    _recent = null;
    session.lastConnectorId = null;
    _viewChatTaskId = taskId;
    _viewSessionId = taskId == null ? sessionId : null;
    _viewProjectTag = projectTag;
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
    // Сессию удалили ([forgetChat]): её выбор не сохраняем.
    final forgotten =
        _appliedSessionId != null && _appliedSessionId == _forgottenSessionId;
    if (forgotten) _forgottenSessionId = null;
    if (session.chatTaskId == null && !forgotten) {
      final selected = selectedTaskId;
      if (selected == null) {
        _selections.remove(_appliedSessionId);
      } else {
        _selections[_appliedSessionId] = selected;
      }
    }
    session.chatTaskId = target;
    session.projectTag = _viewProjectTag;
    if (target != null) {
      selectTask(target);
      return;
    }
    _appliedSessionId = _viewSessionId;
    final restored = _selections[_appliedSessionId];
    if (restored != null) {
      selectTask(restored);
    } else {
      clearSelection();
    }
  }

  /// Открытую сессию перенесли в проект или из него, проекту дали или
  /// сняли метку задач: метка для новых задач — [projectTag]. Посреди
  /// ответа — после него, как [enterChat].
  void setProjectTag(String? projectTag) {
    _viewProjectTag = projectTag;
    if (_inFlight == 0) session.projectTag = projectTag;
  }

  /// Сессию [sessionId] удалили: её выбор («её») больше не нужен и не
  /// вернётся, если id когда-нибудь совпадёт.
  void forgetChat(String sessionId) {
    _selections.remove(sessionId);
    // Её выбор ещё в [session]: при переходе в другой чат он не
    // сохраняется под id удалённой сессии.
    if (sessionId == _appliedSessionId) _forgottenSessionId = sessionId;
  }

  /// Удалённая сессия, чей выбор ещё применён ([forgetChat]).
  String? _forgottenSessionId;

  /// Забывает выбор («её») всех чатов: история сессий очищена.
  void forgetChatSelections() {
    _followUp = null;
    _recent = null;
    _selections.clear();
    _forgottenSessionId = null;
    clearSelection();
  }

  /// Продолжение разговора с тем, к кому обратились по имени: помощник и
  /// навык, которым шёл разговор. Следующая фраза без имени, которую
  /// забрал тот же навык, — снова ему ([_leadByDuty]); другой навык —
  /// продолжение снимается. `connectorId == null` — обратились по имени
  /// без команды («Нода»): следующая фраза — ему, каким бы навыком она ни
  /// была. Только в памяти и только в текущем чате ([enterChat]).
  ///
  /// Продолжение короткое: не больше [followUpLimit] фраз без имени
  /// подряд, потом снова отвечает ведущий обязанности или Связной. Интерфейс
  /// продолжение не показывает — долгое «залипание» было бы невидимым
  /// адресатом.
  ({String personaId, String? connectorId, int left})? _followUp;

  /// Сколько фраз без имени после обращения по имени продолжает тот, к
  /// кому обратились: «Нода, расскажи шутку» → «ещё шутку» → «ещё» — Noda,
  /// следующая — снова по обязанностям.
  static const int followUpLimit = 2;

  /// Растёт при каждой смене чата: ответ, пришедший после смены, не
  /// заводит продолжение в новом чате.
  int _chatEpoch = 0;

  /// Кто продолжает разговор: для тестов и отладки.
  String? get followUpPersonaId => _followUp?.personaId;

  /// Продолжение после ответа [response]: обратились по имени — этот
  /// помощник продолжает навыком, которым ответил; фраза без имени ушла
  /// другому навыку (или никакому) — продолжение снимается.
  void _updateFollowUp(AssistantResponse response) {
    if (personas.teamMode == TeamMode.solo ||
        response.settingsChange?.teamMode != null) {
      _followUp = null;
      return;
    }
    final connectorId = session.lastConnectorId;
    final named = _member(response.addressedPersonaId);
    if (named != null) {
      if (named.id == personas.responder.id &&
          extensions.mainLeadsAll(personas)) {
        // Связной и так отвечает на всё.
        _followUp = null;
      } else if (response.replyId == 'common.addressed') {
        // «Нода» без команды: следующая фраза — ей, любым навыком.
        _followUp = (personaId: named.id, connectorId: null, left: 1);
      } else {
        _followUp = connectorId == null
            ? null
            : (
                personaId: named.id,
                connectorId: connectorId,
                left: followUpLimit,
              );
      }
      return;
    }
    final follow = _followUp;
    if (follow == null ||
        connectorId == null ||
        connectorId != follow.connectorId ||
        follow.left <= 1) {
      _followUp = null;
      return;
    }
    _followUp = (
      personaId: follow.personaId,
      connectorId: follow.connectorId,
      left: follow.left - 1,
    );
  }

  /// Кто ответит на [message]: обращение по имени активного помощника
  /// («Нода, …», «Связной, …») важнее адресата [addressee] из поля ввода
  /// ([mainAddressee] — Связной), а без них отвечает Связной — или ведущий
  /// обязанности, чей навык заберёт фразу ([_leadByDuty]). Имя помощника,
  /// выключенного режимом, — не обращение: отвечает Связной, а имя из начала
  /// фразы убирается (ADR-016).
  /// Возвращает помощника и текст без обращения.
  (Persona, String, bool) resolve(String message, {String? addressee}) {
    final cast = personas.cast;
    final addressing = PersonaAddressing.parse(message);
    if (addressing != null && cast.isActive(addressing.persona.id)) {
      return (cast.byId(addressing.persona.id), addressing.rest, true);
    }
    // Имя помощника, выключенного режимом, обращением не считается, но и в
    // команду не попадает: «Нода, добавь задачу хлеб» в Дуэте с Лиорио —
    // задача «Хлеб» от главного (ADR-016).
    final text = PersonaAddressing.commandText(message);
    final chosen = cast.find(addressee);
    return (
      chosen != null && cast.isActive(chosen.id) ? chosen : cast.responder,
      text,
      false,
    );
  }

  /// Отвечает на сообщение пользователя. [addressee] — помощник, которому
  /// пишут явно (только в дуэте; интерфейс его больше не передаёт, выбора
  /// «Кому» нет). Если к помощнику обратились по имени, ответ это отмечает
  /// ([AssistantResponse.addressedPersonaId]), и он продолжает разговор
  /// тем же навыком ([_followUp]).
  ///
  /// [chatTaskId] — задача чата, в котором отправлено сообщение (`null` —
  /// сессия): в чате задачи она — цель «готово», «закрой», «перенеси
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
    List<JobFile> attachments = const <JobFile>[],
    List<JobFile> recentAttachments = const <JobFile>[],
    List<SessionFileRef> recentFiles = const <SessionFileRef>[],
    bool fromVoice = false,
  }) async {
    // Кто ответит и обратились ли по имени — по настройкам на начало
    // сообщения.
    final settings = personas;
    var (persona, text, addressed) = resolve(message, addressee: addressee);
    // «Нода» без команды, затем фраза без имени — как «Нода, <фраза>».
    final waiting = _followUp;
    if (!addressed &&
        addressee == null &&
        waiting != null &&
        waiting.connectorId == null &&
        settings.teamMode != TeamMode.solo) {
      final named = _activeMember(waiting.personaId);
      if (named != null) {
        persona = named;
        addressed = true;
      }
    }
    // Явное обращение (имя в сообщении или явный адресат, в том числе
    // главный) важнее ведущего обязанности (ADR-016).
    _explicit = addressed || isExplicitAddressee(addressee);
    final epoch = _chatEpoch;
    _messageNo++;
    _inFlight++;
    session.chatTaskId = chatTaskId;
    // Файлы сообщения и недавних сообщений сессии — только для чтения
    // навыками-расширениями (карточка архиватора). Фраза с паролем их не
    // получает: её не получает ни один навык.
    session
      ..attachments = secretRedacted ? const <JobFile>[] : attachments
      ..recentAttachments =
          secretRedacted ? const <JobFile>[] : recentAttachments
      ..recentFiles = secretRedacted ? const <SessionFileRef>[] : recentFiles
      ..fromVoice = fromVoice;
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
      session
        ..attachments = const <JobFile>[]
        ..recentAttachments = const <JobFile>[]
        ..recentFiles = const <SessionFileRef>[]
        ..fromVoice = false;
      _inFlight--;
      if (_inFlight == 0) _runBetweenTurns();
      if (_inFlight == 0 && !_chatChangePending) {
        session.projectTag = _viewProjectTag;
      }
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
    // Навык мог отметить адресата сам: «спасибо, Лиорио» в ответ на вопрос
    // Ноды — дальше отвечает Лиорио, а не та, к кому обратились в начале.
    final result = !addressed || response.addressedPersonaId != null
        ? response
        : response.withAddressed(persona.id);
    // Чат сменили, пока готовился ответ: продолжение в новый чат не
    // переносится.
    if (epoch == _chatEpoch) _updateFollowUp(result);
    return result;
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

  /// Приветствие главного: он встречает в новой сессии (ADR-016). В
  /// интерфейсе сообщением не показывается (приветствие — пустая сессия,
  /// SessionHero); ключ `common.welcome` оставлен для паков реплик.
  AssistantResponse welcome() => speak(
        const Reply('common.welcome', <String, String>{
          'example': AssistantController.exampleCommand,
        }),
        personas.responder,
        intent: 'welcome',
      );

  /// Ответ на сообщение только из файлов (ADR-019): файлы сохранены в
  /// сессии, обрабатывать их пока нечем. Отвечает главный — как на
  /// реплику без обращения.
  AssistantResponse attachmentsSaved(int count) => speak(
        Reply('attachments.saved', <String, String>{'count': '$count'}),
        personas.responder,
        intent: 'attachments.saved',
      );

  /// Строка ведущего оповещений (ADR-029): «Теперь напомню о задачах
  /// уведомлением…» после разрешения уведомлений. Вне счёта реплик.
  AssistantResponse notifierSays(String id) => speak(
        Reply(id),
        personas.notifier,
        intent: id,
        countTurn: false,
      );

  /// Строка вслед за ответом голосом того, кто ответил ([personaId]):
  /// «Ссылка не открылась…» после погоды (ADR-030). Вне счёта реплик.
  AssistantResponse followUp(String id, String? personaId) => speak(
        Reply(id),
        personas.cast.byId(personaId),
        intent: id,
        status: AssistantStatus.noAction,
        countTurn: false,
      );

  /// Строка под ответом на команду с файлами: файлы сохранены в сессии.
  /// Голосом того, кто ответил ([personaId]); вне счёта реплик.
  String attachmentsNote(int count, String? personaId) => speak(
        Reply('attachments.savedNote', <String, String>{'count': '$count'}),
        personas.cast.byId(personaId),
        intent: 'attachments.saved',
        countTurn: false,
      ).message;

  /// «Команда обрабатывается…» голосом того, кто ответит на [message]: без
  /// явного обращения — ведущий обязанности, чей навык, скорее всего,
  /// заберёт фразу ([ExtensionRegistry.ownerFor]).
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
    final follow = _followUp;
    final followed = _activeMember(follow?.personaId);
    if (!addressed &&
        !isExplicitAddressee(addressee) &&
        personas.teamMode != TeamMode.solo &&
        follow != null &&
        follow.connectorId == null &&
        followed != null) {
      speaker = followed;
    } else if (!guarded &&
        !addressed &&
        !isExplicitAddressee(addressee) &&
        session.pendingConfirmation == null) {
      final likely = _likely(text);
      if (likely != null) {
        speaker = followed != null && likely.info.id == follow?.connectorId
            ? followed
            : extensions.ownerFor(likely.info.id, personas);
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

  /// Номер сообщения, которое сейчас обрабатывается ([handle]).
  int _messageNo = 0;

  /// Контекст сессии: какой коннектор последним выполнил фразу, в каком
  /// чате, когда и на каком сообщении. Только id и время, без текста, и
  /// только в памяти. Беседа ([ConnectorMatch.fallback]) тему не меняет:
  /// «спасибо» между «покажи пароли» и «сделай бэкап» контекст не сбивает.
  /// Сбрасывается на «не понял», «к чему относится команда?», скрытый
  /// пароль, уточняющий вопрос и смену чата.
  ({String chat, String connectorId, DateTime at, int message})? _recent;

  /// Чат текущего сообщения: задача или сессия.
  String get _chatKey {
    final task = session.chatTaskId;
    return task != null ? 'task:$task' : 'session:${_appliedSessionId ?? ''}';
  }

  /// Коннектор из контекста сессии для текущего сообщения или `null`:
  /// тот же чат, не дальше [contextMessages] сообщений и не старше
  /// [contextWindow].
  String? get _recentConnectorId {
    final recent = _recent;
    if (recent == null || recent.chat != _chatKey) return null;
    if (_messageNo - recent.message > contextMessages) return null;
    final age = session.clock.now().difference(recent.at);
    if (age.isNegative || age > contextWindow) return null;
    return recent.connectorId;
  }

  /// Коннектор из контекста сессии: для тестов и отладки.
  String? get recentConnectorId => _recentConnectorId;

  /// Уточняющий вопрос с вариантами, который ждёт ответа, или `null`:
  /// интерфейс показывает кнопки вариантов, пока он жив.
  Clarification? get pendingClarification {
    final payload = session.pendingConfirmation?.payload;
    return payload is Clarification ? payload : null;
  }

  /// Кто, скорее всего, заберёт [text] — по тем же правилам, что
  /// [_route], без подтверждений и без запуска. Только для голоса
  /// «обрабатывается…».
  Connector? _likely(String text) {
    final recent = _recentConnectorId;
    final utterance =
        Utterance.analyze(text, now: session.clock.now()).withChat(
      session.chatTaskId,
      awaitingAnswer: _awaitingAnswer,
      recentConnectorId: recent,
    );
    final found = <(Connector, ConnectorMatch)>[];
    final passwordsPhrase = PasswordPhrases.looksLike(utterance);
    for (final connector in _connectors) {
      if (passwordsPhrase && connector.info.requiresNetwork) continue;
      try {
        final match = connector.match(utterance);
        if (match != null) found.add((connector, match));
      } catch (_) {
        continue;
      }
    }
    final likely = RoutePolicy.pick(
      <ConnectorMatch>[for (final (_, m) in found) m],
      recentConnectorId: recent,
    ).likely;
    return _ownerOf(found, likely);
  }

  /// Подсветка команды (ADR-021): какие части [text] распознали навыки —
  /// обращение по имени, слово команды, название, срок, метки, пример.
  /// Тот же выбор навыка, что у [_route] (без контекста сессии, чата и
  /// вопросов), и разбор самого навыка ([CommandSpanSource]); ничего не
  /// запускается и не запоминается.
  ///
  /// Фраза о паролях, вставленный пароль или код входа не подсвечиваются
  /// совсем: подсветка не должна выделять секрет ни цветом, ни шрифтом.
  /// Длинный текст ([CommandSpans.maxLength]) — тоже.
  List<CommandSpan> highlight(String text) {
    if (text.trim().isEmpty || text.length > CommandSpans.maxLength) {
      return const <CommandSpan>[];
    }
    if (text.contains('•') ||
        LoginLinks.contains(text) ||
        SecretGuard.redact(text).guarded) {
      return const <CommandSpan>[];
    }
    final spans = <CommandSpan>[];
    var offset = 0;
    var body = text;
    final addressing = PersonaAddressing.parse(text);
    if (addressing != null && addressing.rest.isNotEmpty) {
      if (personas.cast.isActive(addressing.persona.id) &&
          addressing.nameEnd > addressing.nameStart) {
        spans.add(
          CommandSpan(
            addressing.nameStart,
            addressing.nameEnd,
            CommandSpanKind.address,
          ),
        );
      }
      offset = addressing.restStart;
      body = text.substring(offset);
    }
    final utterance = Utterance.analyze(body, now: session.clock.now());
    if (PasswordPhrases.looksLike(utterance)) return const <CommandSpan>[];
    final found = <(Connector, ConnectorMatch)>[];
    for (final connector in _connectors) {
      try {
        final match = connector.match(utterance);
        if (match == null || match.confidence <= 0) continue;
        if (connector.info.sensitive) return const <CommandSpan>[];
        found.add((connector, match));
      } catch (_) {
        continue;
      }
    }
    final likely = RoutePolicy.pick(
      <ConnectorMatch>[for (final (_, m) in found) m],
    ).likely;
    final owner = _ownerOf(found, likely);
    if (owner != null && likely != null && !likely.fallback) {
      List<CommandSpan> own;
      try {
        own = owner is CommandSpanSource
            ? (owner as CommandSpanSource).spansOf(utterance, likely)
            : CommandSpans.generic(utterance);
      } catch (_) {
        own = const <CommandSpan>[];
      }
      for (final span in own) {
        spans.add(span.shift(offset));
      }
    }
    return CommandSpans.normalize(spans, text.length);
  }

  /// Коннектор совпадения [match] среди [found].
  static Connector? _ownerOf(
    List<(Connector, ConnectorMatch)> found,
    ConnectorMatch? match,
  ) {
    if (match == null) return null;
    for (final (connector, candidate) in found) {
      if (identical(candidate, match)) return connector;
    }
    return null;
  }

  /// Фразу забрал навык из зоны помощника: без явного обращения отвечает
  /// ведущий этой обязанности — так Связной передаёт фразу помощнику
  /// (ADR-016). Зона неактивного помощника — у главного. Обращение по имени и
  /// явный адресат важнее; продолжение разговора тем же навыком
  /// ([_followUp]) — тоже.
  void _leadByDuty(Connector connector) {
    if (_explicit) return;
    final follow = _followUp;
    final followed = _activeMember(follow?.personaId);
    if (followed != null &&
        follow?.connectorId == connector.info.id &&
        session.personas.teamMode != TeamMode.solo) {
      session
        ..speaker = followed
        ..voice = session.personas.voiceOf(followed);
      return;
    }
    final owner = extensions.ownerFor(connector.info.id, session.personas);
    if (owner.id == session.speaker.id) return;
    session
      ..speaker = owner
      ..voice = session.personas.voiceOf(owner);
  }

  /// Первым пишет ведущий оповещений ([PersonaCast.notifier]; выключен
  /// режимом — Связной): просроченные задачи. `null`, если просроченных нет. Интерфейс в сессию это больше
  /// не пишет (строка «Просрочена N задач» в пустой сессии); ключ
  /// `task.overdue` оставлен для паков реплик.
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

  /// Ответ на вопрос подтверждения звучит от того, кто спросил,
  /// даже если адресат в поле ввода с тех пор сменился. Если в ответе
  /// назвали помощника по имени в начале ([addressed]: «Лио, да»), отвечает
  /// названный. Имя в конце ([trailing]: «да, Лиорио», «спасибо, Лио») —
  /// тоже обращение: отвечает названный. В соло все ответы — от главного.
  void _speakAsAsker(
    Persona? asker, {
    required bool addressed,
    Persona? trailing,
  }) {
    if (session.personas.teamMode == TeamMode.solo) return;
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
    int depth = 0,
    bool layers = true,
  }) async {
    // Пароль, вставленный в чат (D12): ни один коннектор фразу не
    // получает, задача не создаётся. Вопрос, если ждал ответа, остаётся.
    if (secretRedacted ||
        SecretGuard.redact(message, known: knownSecret).guarded) {
      session.lastConnectorId = null;
      _recent = null;
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
    final recent = _recentConnectorId;
    var utterance =
        Utterance.analyze(message, now: session.clock.now()).withChat(
      session.chatTaskId,
      awaitingAnswer: _awaitingAnswer || session.pendingConfirmation != null,
      recentConnectorId: recent,
    );
    // Фраза о паролях или просто со словом «пароль» (раздел 5.9): её не
    // получает ни один сетевой коннектор — ни в match, ни в уточнении
    // ответа, при любой уверенности, включён навык или нет.
    var hideFromNetwork = RecognitionLayers.hidesFromNetwork(
      utterance,
      (String text) => Utterance.analyze(text, now: session.clock.now()),
    );
    final pendingAsker = session.pendingSpeaker;
    final pending = session.takePendingConfirmation();
    final asker = pending == null
        ? null
        : _activeAsker(pendingAsker, pending.connectorId);
    final owner = pending == null
        ? null
        : connectors
            .where((Connector c) => c.info.id == pending.connectorId)
            .firstOrNull;
    // «Да, Лиорио», «спасибо, Нода»: имя в конце ответа на вопрос — тоже
    // обращение (в дуэте). Само «да» или «нет» ищем в тексте без имени.
    final parsedTrailing = pending != null &&
            owner != null &&
            !addressed &&
            session.personas.teamMode != TeamMode.solo
        ? PersonaAddressing.parseTrailing(message)
        : null;
    // Имя помощника, выключенного режимом, — просто текст.
    final trailing = parsedTrailing != null &&
            session.personas.cast.isActive(parsedTrailing.persona.id)
        ? parsedTrailing
        : null;
    final named = trailing == null
        ? null
        : session.personas.cast.byId(trailing.persona.id);
    var answerUtterance = trailing == null
        ? utterance
        : Utterance.analyze(trailing.rest, now: session.clock.now());
    // «lf», «ytn» — «да» и «нет», набранные не в той раскладке.
    if (pending != null && ConfirmationReply.of(answerUtterance) == null) {
      for (final fixed in LayoutFix.candidates(message)) {
        final answer = Utterance.analyze(fixed, now: session.clock.now());
        if (ConfirmationReply.of(answer) != null) {
          answerUtterance = answer;
          break;
        }
      }
    }
    // Ответ на «Похоже, вы хотите …?» запасного слоя (ADR-045).
    final intentQuestion = pending?.commandId == intentSuggestCommand &&
            pending?.payload is Clarification
        ? pending!.payload! as Clarification
        : null;
    if (intentQuestion?.context case final IntentOffer offer) {
      final question = intentQuestion!;
      final option = question.choose(answerUtterance);
      final typed = ConfirmationReply.of(answerUtterance);
      final refused = option?.answer == false ||
          (option == null && typed == ConfirmationReply.no);
      final chosen = switch (option?.answer) {
        true => offer.suggestion.first,
        null when option != null => offer.suggestion.second,
        null when typed == ConfirmationReply.yes => offer.suggestion.first,
        _ => null,
      };
      if (refused || chosen != null) {
        _answered = pending;
        _speakAsAsker(asker, addressed: addressed, trailing: named);
        return _markTrailing(
          refused
              ? await _rejectIntent(offer)
              : await _acceptIntent(offer, chosen!),
          named,
        );
      }
    }
    // Уточняющий вопрос с вариантами (Clarification): выбранный вариант
    // разбирается заново как его каноническая команда — со всеми
    // правилами, в том числе «фраза о паролях не уходит в сеть»; «нет» —
    // отмена; «да» — не выбор, переспросить.
    final clarification = owner != null && pending?.payload is Clarification
        ? pending!.payload! as Clarification
        : null;
    if (clarification != null) {
      final option = clarification.choose(answerUtterance);
      final typed = ConfirmationReply.of(answerUtterance);
      // Варианты «Поставить» и «Отмена» (ClarifyOption.answer) — ответ
      // «да» или «нет» владельцу; набранное «да» или «нет» — тоже.
      final answer = option?.answer ??
          switch (typed) {
            ConfirmationReply.yes when clarification.yesOption != null => true,
            ConfirmationReply.no when clarification.noOption != null => false,
            _ => null,
          };
      if (answer != null) {
        _speakAsAsker(asker, addressed: addressed, trailing: named);
        return _markTrailing(
          await _answer(
            owner!,
            pending!,
            answer ? ConfirmationReply.yes : ConfirmationReply.no,
            viaButton: option != null,
          ),
          named,
        );
      }
      if (option != null) {
        _answered = pending;
        _speakAsAsker(asker, addressed: addressed, trailing: named);
        return _markTrailing(
          await _route(option.text, addressed: addressed, depth: depth + 1),
          named,
        );
      }
      final reply = typed;
      if (reply == ConfirmationReply.no) {
        _answered = pending;
        _speakAsAsker(asker, addressed: addressed, trailing: named);
        session.lastConnectorId = null;
        return _markTrailing(
          session.reply(
            'common.clarify.cancelled',
            intent: 'clarify.cancelled',
            status: AssistantStatus.noAction,
          ),
          named,
        );
      }
      if (reply == ConfirmationReply.yes) {
        _speakAsAsker(asker, addressed: addressed, trailing: named);
        session.requestConfirmation(pending!);
        return _markTrailing(_clarifyAgain(clarification), named);
      }
    }
    // Вопрос «да или нет?» (не уточнение с вариантами).
    final confirming = clarification == null ? pending : null;
    if (confirming != null && owner != null) {
      final reply = ConfirmationReply.of(answerUtterance);
      if (reply != null) {
        _speakAsAsker(asker, addressed: addressed, trailing: named);
        return _markTrailing(await _answer(owner, confirming, reply), named);
      }
      // «Кроме хлеба», «только отчёт»: уточнение ответа, которое понимает
      // сам спросивший коннектор (ConfirmationFollowUp).
      if (owner is ConfirmationFollowUp &&
          !(hideFromNetwork && owner.info.requiresNetwork)) {
        final followUp = (owner as ConfirmationFollowUp).matchFollowUp(
          answerUtterance,
          confirming,
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
    List<(Connector, ConnectorMatch)> collect(Utterance u, bool hide) {
      final found = <(Connector, ConnectorMatch)>[];
      for (final connector in connectors) {
        if (hide && connector.info.requiresNetwork) continue;
        final ConnectorMatch? match;
        try {
          match = connector.match(u);
        } catch (error) {
          // Ошибка в одном коннекторе не должна ломать остальные.
          continue;
        }
        if (match == null || match.confidence <= 0) continue;
        found.add((connector, match));
      }
      return found;
    }

    var candidates = collect(utterance, hideFromNetwork);
    if (confirming != null && owner != null) {
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
                .matchLeadingAnswer(answerUtterance, confirming, reply)
            : null;
        if (instead != null) {
          return _markTrailing(await _run(owner, instead), named);
        }
        return _markTrailing(await _answer(owner, confirming, reply), named);
      }
    }
    if (pending != null && owner != null) {
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
          clarification != null
              ? _clarifyAgain(clarification)
              : session.reply(
                  'common.confirm.unclear',
                  intent: 'confirm.unclear',
                  status: AssistantStatus.needsClarification,
                ),
          named,
        );
      }
    }
    var decision = RoutePolicy.pick(
      <ConnectorMatch>[for (final (_, m) in candidates) m],
      recentConnectorId: recent,
    );
    // Вторая команда того же сообщения (CommandSplit): не выполняется,
    // а предлагается кнопкой под ответом на первую.
    String? rest;
    if (layers) {
      // Слои распознавания (ADR-037, RecognitionLayers): обёртка, опечатка
      // в слове срока, а если как есть не понял никто явно, — раскладка и
      // опечатка. Ответ на вопрос («да, купил хлеб») разобран выше по
      // исходной фразе.
      RouteDecision pick(List<(Connector, ConnectorMatch)> found) =>
          RoutePolicy.pick(
            <ConnectorMatch>[for (final (_, m) in found) m],
            recentConnectorId: recent,
          );
      final layered =
          RecognitionLayers.route<List<(Connector, ConnectorMatch)>>(
        message: message,
        utterance: utterance,
        hide: hideFromNetwork,
        first: (found: candidates, decision: decision),
        router: (Utterance u, bool hide) {
          final found = collect(u, hide);
          return (found: found, decision: pick(found));
        },
        analyze: (String text) =>
            _analyze(text, recent, awaiting: utterance.awaitingAnswer),
        fromVoice: session.fromVoice,
        knownSecret: knownSecret,
      );
      if (layered.repair case final String reply) {
        return _repaired(
          layered.text,
          layered.decision.winner!,
          addressed: addressed,
          depth: depth,
          reply: reply,
        );
      }
      // «Не дай мне забыть пароль от почты», «напомни-ка пароль от почты»
      // при выключенном навыке: без обёртки это явная фраза о паролях —
      // ответ «Пароли выключены», а не «не понял» и не задача.
      if (_passwordsOff && layered.text == message) {
        final framed =
            CommandFrame.strip(message, fromVoice: session.fromVoice);
        final framedPasswords = framed == null
            ? null
            : PasswordPhrases.parse(
                _analyze(framed, recent, awaiting: utterance.awaitingAnswer),
              );
        if (framedPasswords != null &&
            framedPasswords.confidence >= PasswordPhrases.firm) {
          session.lastConnectorId = null;
          return session.reply(
            'passwords.off',
            intent: 'passwords.off',
            status: AssistantStatus.noAction,
          );
        }
      }
      rest = layered.rest;
      if (layered.text != message) {
        utterance = layered.utterance;
        hideFromNetwork = layered.hide;
        candidates = layered.found;
        decision = layered.decision;
        // Фраза о паролях без обёртки при выключенном навыке — тот же
        // ответ, что и как есть, а не задача с паролем в названии.
        final framedPasswords = PasswordPhrases.parse(utterance);
        if (_passwordsOff &&
            framedPasswords != null &&
            framedPasswords.confidence >= PasswordPhrases.firm) {
          session.lastConnectorId = null;
          return session.reply(
            'passwords.off',
            intent: 'passwords.off',
            status: AssistantStatus.noAction,
          );
        }
      }
    }
    final best = decision.winner;
    if (decision.isAmbiguous) {
      session.lastConnectorId = null;
      _recent = null;
      return session.reply(
        'router.ambiguous',
        values: <String, String>{
          'first': _ownerOf(candidates, decision.first)!.info.title,
          'second': _ownerOf(candidates, decision.second)!.info.title,
        },
        intent: 'router.ambiguous',
        status: AssistantStatus.needsClarification,
      );
    }
    final bestConnector = _ownerOf(candidates, best);
    // Фраза выключенного расширения («сожми в zip» при выключенном
    // архиваторе): подсказать, где включить. Только если включённые навыки
    // не взяли её явно.
    if (best == null || best.implicit || best.fallback) {
      final off = _switchedOffOwner(utterance, hideFromNetwork);
      if (off != null) {
        session.lastConnectorId = null;
        _recent = null;
        return session.reply(
          'extension.off',
          values: <String, String>{'name': off.info.title},
          intent: 'extension.off',
          status: AssistantStatus.noAction,
        );
      }
    }
    if (best == null || bestConnector == null) {
      session.lastConnectorId = null;
      _recent = null;
      final plain = _unknownFor(message, private: hideFromNetwork);
      return depth == 0 && layers && RecognitionLayers.gaveUp(decision)
          ? _notUnderstood(message, plain, private: hideFromNetwork)
          : plain;
    }
    // Фраза понята по контексту сессии как фраза другого навыка: её
    // разбирают заново как каноническую команду (один раз).
    if (best.payload case final Reroute reroute) {
      final target = connectors.any(
        (Connector c) => c.info.id == reroute.connectorId,
      );
      if (target && depth == 0) {
        final response = await _route(
          reroute.text,
          addressed: addressed,
          depth: depth + 1,
        );
        final note = reroute.noteReplyId;
        if (note == null || response.status == AssistantStatus.failed) {
          return _offerRest(response, rest);
        }
        return _offerRest(
          response.withText(
            '${session.say(note)} ${response.message}',
            response.values,
          ),
          rest,
        );
      }
      _leadByDuty(bestConnector);
      return _offerRest(
        await _run(
          bestConnector,
          ConnectorMatch(
            connectorId: best.connectorId,
            commandId: best.commandId,
            confidence: best.confidence,
            implicit: best.implicit,
            fallback: best.fallback,
            aliased: best.aliased,
            payload: reroute.orElse,
          ),
        ),
        rest,
      );
    }

    _leadByDuty(bestConnector);
    final response = await _run(bestConnector, best);
    // «Такое не подскажу: справочника нет» — правила тоже сдались: спросить
    // запасной слой, кроме самого справочного вопроса.
    if (response.replyId == _offlineQuestionReply &&
        depth == 0 &&
        layers &&
        rest == null &&
        best.fallback) {
      return _notUnderstood(
        message,
        response,
        private: hideFromNetwork,
        exclude: <String>{'${best.connectorId}:${best.commandId}'},
      );
    }
    return _offerRest(response, rest);
  }

  /// «Не понял» правил ([plain]) и запасной слой (ADR-045): подсказка
  /// команды вопросом или [plain] с записью в журнал непонятых. Подсказка
  /// команд ADR-022 (опечатка в слове команды) — правила, она важнее.
  /// Приватная фраза — [plain], модель её не видит и журнал не пишет.
  Future<AssistantResponse> _notUnderstood(
    String message,
    AssistantResponse plain, {
    required bool private,
    Set<String> exclude = const <String>{},
  }) async {
    final fallback = intent;
    if (fallback == null || private || _privateForModel(message)) return plain;
    if (plain.replyId == unknownSuggestReply) {
      await fallback.unclear(message);
      return plain;
    }
    final offer = await _intentOffer(fallback, message, exclude: exclude);
    if (offer != null) {
      session.lastConnectorId = null;
      _recent = null;
      return offer;
    }
    await fallback.unclear(message);
    return plain;
  }

  bool _privateForModel(String text) => RecognitionLayers.privateForModel(
        text,
        analyze: (String t) => Utterance.analyze(t, now: session.clock.now()),
        knownSecret: knownSecret,
      );

  /// Вопрос «Похоже, вы хотите …?» с кнопками «Да», вторым вариантом и
  /// «Нет» или `null`, если модели нечего предложить. Сбой модели — тоже
  /// `null`: ответ правил остаётся.
  Future<AssistantResponse?> _intentOffer(
    IntentFallback fallback,
    String message, {
    Set<String> exclude = const <String>{},
  }) async {
    final IntentSuggestion? suggestion;
    try {
      suggestion = await fallback.suggest(
        message,
        connectors: <String>{
          for (final connector in _connectors)
            if (connector is IntentTarget) connector.info.id,
        },
        exclude: <String>{...intentNever, ...exclude},
      );
    } on Object {
      return null;
    }
    if (suggestion == null) return null;
    final first = suggestion.first;
    final second = suggestion.second;
    final clarification = Clarification(
      questionId: second == null ? intentSuggestReply : intentSuggestTwoReply,
      options: <ClarifyOption>[
        ClarifyOption(
          label: 'Да',
          text: '',
          answers: const <String>{'давай', 'ага', 'верно', 'конечно', 'lf'},
          connectorId: first.connectorId,
          answer: true,
        ),
        if (second != null)
          ClarifyOption(
            label: Utterance.capitalize(second.description),
            text: '',
            connectorId: second.connectorId,
          ),
        const ClarifyOption(label: 'Нет', text: 'нет', answer: false),
      ],
      context: IntentOffer(suggestion),
    );
    session.requestConfirmation(
      PendingConfirmation(
        connectorId: first.connectorId,
        commandId: intentSuggestCommand,
        payload: clarification,
      ),
    );
    return session.reply(
      clarification.questionId,
      values: <String, String>{
        'description': first.description,
        if (second != null) 'second': second.description,
      },
      intent: intentSuggestCommand,
      status: AssistantStatus.needsClarification,
      clarification: clarification,
    );
  }

  /// «Да» на подсказку: личный пример (если учиться разрешено), запись
  /// «исправлено» в журнале и команда — через правила навыка
  /// ([IntentTarget.matchAs]): слоты из фразы, недостающее навык спросит
  /// сам, запись — со своим подтверждением. Не разобрать — пример команды.
  Future<AssistantResponse> _acceptIntent(
    IntentOffer offer,
    IntentChoice choice,
  ) async {
    final suggestion = offer.suggestion;
    final connector = _connectors
        .where((Connector c) => c.info.id == choice.connectorId)
        .firstOrNull;
    session.lastConnectorId = null;
    _recent = null;
    if (connector == null ||
        connector is! IntentTarget ||
        _privateForModel(suggestion.text)) {
      return _unknown();
    }
    await intent?.accepted(suggestion, choice);
    final target = connector as IntentTarget;
    final recent = _recentConnectorId;
    Utterance analyze(String text) => _analyze(text, recent, awaiting: false);
    final match = target.matchAs(
      choice.commandId,
      analyze(suggestion.text),
      analyze,
    );
    if (match == null) {
      final example = target.intentExample(choice.commandId);
      if (example == null) return _unknown();
      return session.reply(
        intentHowReply,
        values: <String, String>{
          'description': choice.description,
          'example': example,
        },
        intent: choice.commandId,
        status: AssistantStatus.noAction,
      );
    }
    _leadByDuty(connector);
    return _run(connector, match);
  }

  /// «Нет» на подсказку: отрицательные примеры (если учиться разрешено),
  /// запись в журнале и обычное «не понял».
  Future<AssistantResponse> _rejectIntent(IntentOffer offer) async {
    session.lastConnectorId = null;
    _recent = null;
    if (!_privateForModel(offer.suggestion.text)) {
      await intent?.rejected(offer.suggestion);
    }
    return _unknown();
  }

  /// Вторая команда сообщения ([Layered.rest]) — кнопкой под ответом на
  /// первую: нажатие кладёт её в поле ввода, отправляет пользователь сам.
  /// Если первая ждёт выбора из вариантов (кнопки вопроса закрывают
  /// подсказки), вторая сразу лежит в поле ввода. Запись по второй
  /// половине без нового сообщения не выполняется никогда.
  AssistantResponse _offerRest(AssistantResponse response, String? rest) {
    if (rest == null || response.status == AssistantStatus.failed) {
      return response;
    }
    final note = session.say(compoundRestReply, <String, String>{
      'text': rest,
    });
    final withNote = response.withText(
      '${response.message} $note',
      response.values,
    );
    if (response.clarification != null || response.draft != null) {
      return response.draft != null ? withNote : withNote.withDraft(rest);
    }
    return withNote.withSuggestions(
      CommandSuggestions(<CommandSuggestion>[
        CommandSuggestion(
          entryId: compoundRestEntry,
          label: rest,
          template: rest,
        ),
      ]),
    );
  }

  /// Пояснение под ответом на первую из двух команд.
  static const String compoundRestReply = 'router.compound.rest';

  /// Id кнопки второй команды в подсказках.
  static const String compoundRestEntry = 'compound.rest';

  Utterance _analyze(String text, String? recent, {bool? awaiting}) =>
      Utterance.analyze(text, now: session.clock.now()).withChat(
        session.chatTaskId,
        awaitingAnswer: awaiting ?? _awaitingAnswer,
        recentConnectorId: recent,
      );

  /// Ответ на фразу, набранную не в той раскладке: чтение — сразу, с
  /// пояснением «понял как «…»»; запись (задача, будильник, файлы,
  /// действия склада…) — только после «Да»: исправление могло понять не
  /// то, и ошибка должна стоить вопроса, а не действия.
  Future<AssistantResponse> _repaired(
    String text,
    ConnectorMatch winner, {
    required bool addressed,
    required int depth,
    String reply = 'router.repaired',
  }) async {
    // [winner] — команда, которая выполнится: [text] уже без обёртки и с
    // исправленным сроком (_decide), и разбирается ещё раз без слоёв —
    // тем же выбором.
    if (_readOnly(winner)) {
      final response = await _route(
        text,
        addressed: addressed,
        depth: depth,
        layers: false,
      );
      if (response.status == AssistantStatus.failed) return response;
      return response.withText(
        '${session.say(reply, <String, String>{'text': text})} '
        '${response.message}',
        response.values,
      );
    }
    final clarification = Clarification(
      questionId: '$reply.confirm',
      options: <ClarifyOption>[
        ClarifyOption(
          label: 'Да',
          text: text,
          answers: const <String>{
            'выполни',
            'выполнить',
            'давай',
            'ага',
            'верно',
            'lf',
          },
          connectorId: winner.connectorId,
        ),
        const ClarifyOption(label: 'Нет', text: 'нет'),
      ],
    );
    session.requestConfirmation(
      PendingConfirmation(
        connectorId: winner.connectorId,
        commandId: winner.commandId,
        payload: clarification,
      ),
    );
    return session.reply(
      '$reply.confirm',
      values: <String, String>{'text': text},
      intent: reply,
      status: AssistantStatus.needsClarification,
      clarification: clarification,
    );
  }

  /// Команды без записи: список задач, калькулятор, беседа, погода,
  /// вопросы складу.
  static bool _readOnly(ConnectorMatch match) {
    final command = match.commandId;
    if (command == 'task.list') return true;
    if (command.startsWith('warehouse.')) {
      return !command.startsWith('warehouse.act.');
    }
    return command.startsWith('calc.') ||
        command.startsWith('talk.') ||
        command.startsWith('weather.');
  }

  /// Выключенное расширение с подсказкой ([ConnectorInfo.offHint]), которое
  /// явно узнаёт [utterance], или `null`.
  Connector? _switchedOffOwner(Utterance utterance, bool hideFromNetwork) {
    for (final connector in extensions.connectors) {
      if (!connector.info.offHint || extensions.isEnabled(connector.info.id)) {
        continue;
      }
      if (hideFromNetwork && connector.info.requiresNetwork) continue;
      try {
        final match = connector.match(utterance);
        if (match != null &&
            !match.implicit &&
            !match.fallback &&
            match.confidence >= RoutePolicy.ambiguityFloor) {
          return connector;
        }
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// Карточка расширения [extensionId] без фразы — из «+» → «Шаблоны
  /// команд». Отвечает ведущий расширения ([ExtensionRegistry.ownerFor]).
  /// Расширение выключено — `extension.off`; нет в сборке — `null`.
  AssistantResponse? openForm(String extensionId, {String? action}) {
    final connector = extensions.connectors
        .where((Connector c) => c.info.id == extensionId)
        .firstOrNull;
    if (connector == null) return null;
    final owner = extensions.ownerFor(extensionId, personas);
    session
      ..voice = personas.voiceOf(owner)
      ..speaker = owner
      ..personas = personas;
    if (!extensions.isEnabled(extensionId) || connector is! FormConnector) {
      return session
          .reply(
            'extension.off',
            values: <String, String>{'name': connector.info.title},
            intent: 'extension.off',
            status: AssistantStatus.noAction,
          )
          .withPersona(owner.id);
    }
    return (connector as FormConnector)
        .openForm(action, session)
        .withPersona(owner.id);
  }

  /// Строка о готовом результате карточки: голосом [personaId], вне счёта
  /// реплик. [name] — имя результата.
  /// [extensionId] — чья карточка: у каждого расширения своя запись
  /// `<id>.done`.
  String jobDoneNote(
    String name,
    String? personaId, {
    String extensionId = ExtensionForms.archiver,
  }) {
    final key = switch (extensionId) {
      ExtensionForms.converter => 'converter.done',
      ExtensionForms.ytdl => 'ytdl.done',
      _ => 'archiver.done',
    };
    return speak(
      Reply(key, <String, String>{'name': name}),
      personas.cast.byId(personaId),
      intent: key,
      countTurn: false,
    ).message;
  }

  /// Переспросить уточняющий вопрос с теми же вариантами.
  AssistantResponse _clarifyAgain(Clarification clarification) => session.reply(
        'common.clarify.unclear',
        values: <String, String>{'options': clarification.optionsText},
        intent: 'clarify.unclear',
        status: AssistantStatus.needsClarification,
        clarification: clarification,
      );

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
      final response = _filterOutbound(await connector.run(match, session));
      // Контекст сессии: тему задаёт выполненная команда. Беседа тему не
      // меняет; уточняющий вопрос — тема ещё не выбрана.
      if (response.clarification != null) {
        _recent = null;
      } else if (!match.fallback) {
        _recent = (
          chat: _chatKey,
          connectorId: connector.info.id,
          at: session.clock.now(),
          message: _messageNo,
        );
      }
      return response;
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

  /// «Не понял» с подсказкой (ADR-022): фразу не забрал ни один навык.
  /// Похожие команды каталога включённых навыков — «Не до конца понял.
  /// Возможно, подойдёт: …» и кнопки команд — только при опечатке в слове
  /// команды; иначе прежний ответ без кнопок. Фраза о паролях, пароль или код —
  /// прежний ответ без кнопок: слова пользователя не повторяются нигде.
  /// Ничего не запоминается.
  AssistantResponse _unknownFor(String text, {required bool private}) {
    if (private ||
        text.contains('•') ||
        LoginLinks.contains(text) ||
        CommandSuggester.isPrivate(text)) {
      return _unknown();
    }
    final catalog = CommandCatalog.build(
      connectors: connectors,
      passwordActions: false,
      formActions: false,
    );
    final found = CommandSuggester.suggest(text, catalog, usage: commandUsage);
    // Похожих команд нет (опечатки не видно) — прежний ответ без кнопок:
    // подсказка не должна становиться обычным ответом на любую фразу.
    if (found.isEmpty) return _unknown();
    final quoted = <String>[
      for (final suggestion in found) '«${suggestion.label}»',
    ];
    final options = quoted.length == 1
        ? quoted.single
        : '${quoted.sublist(0, quoted.length - 1).join(', ')} или '
            '${quoted.last}';
    return session
        .reply(
          unknownSuggestReply,
          values: <String, String>{'options': options},
          intent: 'unknown',
          status: AssistantStatus.noAction,
        )
        .withSuggestions(CommandSuggestions(found));
  }

  /// Ответ «не до конца понял» с подсказкой команд (ADR-022).
  static const String unknownSuggestReply = 'common.unknown.suggest';

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
    final speaker = _cardSpeaker(personaId, passwordsId);
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
    final asker = _activeAsker(session.pendingSpeaker, pending.connectorId) ??
        personas.responder;
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
    final asker = _activeAsker(session.pendingSpeaker, pending.connectorId) ??
        extensions.ownerFor(pending.connectorId, personas);
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
    final speaker = _cardSpeaker(personaId, card.connectorId);
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
    final speaker = _cardSpeaker(personaId, TasksConnector.id);
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
    _recent = null;
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
