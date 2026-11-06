import '../connectors/connector.dart';
import '../connectors/tasks_connector.dart';
import '../extensions/extension_registry.dart';
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
/// Отвечает один из помощников ([personas], docs/PLANS.md, «Rio и Noda»):
/// в дуэте — основной или тот, к кому обратились по имени («Noda, …»),
/// в соло — выбранный. Голос (стиль, род, обращение, эмодзи) фиксируется
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
    if (!enabled) session.takePendingConfirmation();
  }

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

  /// Отвечает на сообщение пользователя. [addressee] — помощник,
  /// выбранный в поле ввода (только в дуэте).
  Future<AssistantResponse> handle(String message, {String? addressee}) async {
    final settings = personas;
    final (persona, text, addressed) = resolve(message, addressee: addressee);
    session
      ..voice = settings.voiceOf(persona)
      ..speaker = persona
      ..personas = settings;
    if (addressed && text.isEmpty) {
      // «Нода» без команды: отклик, ожидание подтверждения снимается,
      // как любым другим сообщением.
      session
        ..takePendingConfirmation()
        ..lastConnectorId = null;
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
    final response = await _route(text);
    final change = response.settingsChange;
    // Просьба из беседы («говори короче») — к настройкам на сейчас: если
    // их поменяли во время ответа, эти перемены не теряются. Интерфейс
    // применяет то же изменение и сохраняет его.
    if (change != null) personas = change.apply(personas);
    // Беседа может ответить от другого помощника: «пусть отвечает Рио».
    return response.withPersona(response.personaId ?? persona.id);
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

  Future<AssistantResponse> _route(String message) async {
    final connectors = _connectors;
    final utterance = Utterance.analyze(message, now: session.clock.now());
    final pending = session.takePendingConfirmation();
    final owner = pending == null
        ? null
        : connectors
            .where((Connector c) => c.info.id == pending.connectorId)
            .firstOrNull;
    if (pending != null && owner != null) {
      final reply = ConfirmationReply.of(utterance);
      if (reply != null) return _answer(owner, pending, reply);
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
      final reply = ConfirmationReply.leading(utterance);
      if (reply != null &&
          candidates.every(
            ((Connector, ConnectorMatch) c) => c.$2.implicit || c.$2.fallback,
          )) {
        return _answer(owner, pending, reply);
      }
      // «Хорошо», «спасибо» в ответ на вопрос: не согласие и не новая
      // команда. Молча снять вопрос нельзя — пользователь решит, что
      // действие выполнено. Переспрашиваем и ждём ответа дальше.
      final before = candidates.length;
      candidates.removeWhere(
        ((Connector, ConnectorMatch) c) => c.$2.acknowledgement,
      );
      if (candidates.isEmpty && before > 0) {
        session.requestConfirmation(pending);
        return session.reply(
          'common.confirm.unclear',
          intent: 'confirm.unclear',
          status: AssistantStatus.needsClarification,
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
  ) =>
      _run(
        owner,
        ConnectorMatch(
          connectorId: owner.info.id,
          commandId: pending.commandId,
          confidence: 1,
          payload: ConfirmationAnswer(pending, reply),
        ),
      );

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
}
