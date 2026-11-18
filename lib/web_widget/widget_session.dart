import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/chats/chat_models.dart';
import '../core/connectors/connector.dart';
import '../core/connectors/http_transport.dart';
import '../core/connectors/manifest/connection.dart';
import '../core/connectors/manifest/connection_service.dart';
import '../core/connectors/manifest/connection_slots.dart';
import '../core/connectors/secret_store.dart';
import '../core/extensions/extension_registry.dart';
import '../core/models/action_card.dart';
import '../core/personas/persona.dart';
import '../core/scenario/assistant_controller.dart';
import '../core/services/clock.dart';
import '../core/services/task_service.dart';
import '../core/skills/calculator/calculator_connector.dart';
import '../core/skills/talk/talk_connector.dart';
import '../core/storage/in_memory_task_repository.dart';
import 'widget_protocol.dart';
import 'widget_storage.dart';
import 'widget_texts.dart';

/// Связь со страницей склада: `postMessage` в браузере
/// (`browser_host.dart`), подделка в тестах.
abstract interface class HostChannel {
  /// Сообщения страницы склада — уже проверенные: тот же адрес и окно
  /// родителя.
  Stream<HostEvent> get events;

  void post(Map<String, Object?> message);

  /// Помощник открыт во фрейме страницы склада того же адреса. Нет —
  /// открыли адрес помощника напрямую: входа взять неоткуда.
  bool get embedded;
}

enum WidgetPhase {
  /// Ждём `init` от страницы склада.
  waiting,

  /// Ключ получен, проверяем вход на складе.
  connecting,
  ready,

  /// Вход не удался: [WidgetSession.problem].
  failed,

  /// Сотрудник вышел из склада.
  loggedOut,

  /// Адрес помощника открыт не из склада.
  standalone,
}

/// Веб-помощник склада без интерфейса (ADR-032): вход по ключу страницы
/// склада, разговор, карточки, новый ключ на «ключ устарел», голос через
/// оболочку Android и «есть новая версия». Без `package:web` — проверяется
/// тестами на VM.
final class WidgetSession extends ChangeNotifier {
  WidgetSession({
    required this.host,
    required HttpTransport transport,
    required this.storage,
    required this.builtInManifest,
    required this.version,
    Clock clock = const SystemClock(),
    this.updateEvery = const Duration(minutes: 10),
    this.keyWait = const Duration(seconds: 15),
  })  : _transport = transport,
        _clock = clock;

  final HostChannel host;
  final KeyValueStorage storage;

  /// Встроенная копия описания склада (`assets/connectors/`).
  final String? builtInManifest;

  /// Версия этого выпуска помощника; `dev` — сборка без выпуска: новых
  /// версий не ищет.
  final String version;
  final Duration updateEvery;

  /// Сколько ждать новый ключ от страницы склада.
  final Duration keyWait;

  final HttpTransport _transport;
  final Clock _clock;

  /// Как устройство называется в списке подключённых Связных на складе.
  static const String deviceName = 'Веб-помощник';

  WidgetPhase phase = WidgetPhase.waiting;

  /// Почему не вышло войти — для экрана.
  String problem = '';

  HostInit? init;

  /// Тема склада: `light`, `dark` или пусто — как у системы. Приходит с
  /// `init` и потом отдельным `theme`, когда сотрудник её переключил.
  String theme = '';

  ConnectionService? service;
  AssistantController? controller;
  WidgetHistory? _history;
  String? _historyLogin;

  final List<ChatMessage> messages = <ChatMessage>[];

  /// Ответ готовится.
  bool busy = false;

  StreamSubscription<HostEvent>? _events;
  Timer? _updates;
  Completer<HostKey>? _keyWaiter;
  int _ids = 0;

  /// Версия на складе, если она другая; `null` — та же или не проверяли.
  String? pendingUpdate;
  String? _announced;

  /// Панель открыта.
  bool visible = true;

  // ------------------------------------------------------------- голос

  VoiceCaps get voice => init?.voice ?? const VoiceCaps();

  /// Идёт распознавание.
  bool listening = false;

  /// Что уже расслышано — в поле ввода.
  String partial = '';

  /// Подсказка под полем: «нажмите микрофон на клавиатуре», ошибка
  /// распознавания. Пусто — нет.
  String voiceNote = '';

  int _voiceId = 0;

  // --------------------------------------------------------------- ввод

  String _draft = '';

  /// Текст в поле ввода: пока он не пуст, помощник не перезагружается.
  set draft(String value) {
    _draft = value;
    if (value.trim().isEmpty) _maybeAnnounce();
  }

  String get draft => _draft;

  /// Кто вошёл — для заголовка: «Иван Петров · Кладовщик».
  String get who {
    final me = service?.record.me;
    final name = me?.name.isNotEmpty ?? false ? me!.name : init?.name ?? '';
    final role =
        me?.role.isNotEmpty ?? false ? me!.role : init?.roleLabel ?? '';
    return <String>[
      if (name.isNotEmpty) name,
      if (role.isNotEmpty) role,
    ].join(' · ');
  }

  /// Сейчас по часам помощника: метки времени в ленте.
  DateTime get now => _clock.now();

  /// Строка «думает» под вопросом, пока ждём ответа, — голосом того, кто
  /// ответит ([AssistantController.working]), как в ленте приложения.
  /// Считается один раз на ожидание, а не на каждый кадр.
  ChatMessage? get thinking {
    final assistant = controller;
    if (!busy || assistant == null) return _thinking = null;
    return _thinking ??= _working(assistant);
  }

  ChatMessage? _thinking;

  ChatMessage _working(AssistantController assistant) {
    final asked = messages.lastWhere(
      (ChatMessage m) => m.fromUser,
      orElse: () => ChatMessage(
        id: '',
        author: ChatAuthor.user,
        text: '',
        timestamp: _clock.now(),
      ),
    );
    final working = assistant.working(asked.text);
    return ChatMessage(
      id: 'working',
      author: ChatAuthor.persona,
      text: working.message,
      timestamp: _clock.now(),
      personaId: working.personaId,
    );
  }

  /// Примеры вопросов для пустого чата.
  List<String> get examples =>
      (service?.connector.examples ?? const <String>[]).take(3).toList();

  void start() {
    if (!host.embedded) {
      phase = WidgetPhase.standalone;
      notifyListeners();
      return;
    }
    _events = host.events.listen(_onEvent);
    host.post(WidgetMessages.hello(version));
  }

  @override
  void dispose() {
    _events?.cancel();
    _updates?.cancel();
    super.dispose();
  }

  Future<void> _onEvent(HostEvent event) async {
    switch (event) {
      case HostInit():
        init = event;
        theme = event.theme;
        if (event.sid.isEmpty) {
          _fail('Склад не выдал ключ помощника. Обновите страницу склада.');
          return;
        }
        await _connect(event.sid);
      case HostKey():
        final waiter = _keyWaiter;
        _keyWaiter = null;
        if (waiter != null && !waiter.isCompleted) waiter.complete(event);
      case HostTheme(:final theme):
        this.theme = theme;
        notifyListeners();
      case HostBack():
        if (listening) {
          cancelVoice();
        } else {
          close();
        }
      case HostLogout():
        await _logout();
      case HostVisible(:final on):
        visible = on;
        if (!on && listening) cancelVoice();
        if (on) unawaited(checkUpdate());
        _maybeAnnounce();
      case HostVoiceEvent():
        _onVoice(event);
    }
  }

  void _fail(String why) {
    phase = WidgetPhase.failed;
    problem = why;
    notifyListeners();
  }

  // --------------------------------------------------------------- вход

  Future<bool> _connect(String sid) async {
    final start = init;
    if (start == null) return false;
    if (phase != WidgetPhase.ready) {
      phase = WidgetPhase.connecting;
      notifyListeners();
    }
    var current = service;
    if (current == null) {
      current = await ConnectionService.restore(
        slot: ConnectionSlots.warehouse,
        transport: _transport,
        // Ключ помощника — только в памяти: страница выдаёт его заново при
        // каждом открытии.
        secrets: InMemorySecretStore(),
        store: WidgetConnectionStore(storage),
        builtIn: builtInManifest,
        clock: _clock,
        device: deviceName,
      );
      service = current;
    }
    final result = await current.connectWithKey(
      address: start.base,
      sid: sid,
      login: start.login,
      name: start.name,
      role: start.roleLabel,
    );
    if (!result.ok) {
      _fail(result.message);
      return false;
    }
    final login = current.record.login ?? start.login.toLowerCase();
    _build(current, login);
    phase = WidgetPhase.ready;
    problem = '';
    _updates ??= Timer.periodic(updateEvery, (_) => unawaited(checkUpdate()));
    notifyListeners();
    unawaited(checkUpdate());
    return true;
  }

  /// Помощник и история — под логином входа; другой логин — другой
  /// разговор.
  void _build(ConnectionService service, String login) {
    final choice = ExtensionChoice(
      enabledRoles: const <String>{Roles.storekeeperId},
      // Склад ведёт сам Связной; действия — для этого входа, а можно ли
      // их и что именно, решает склад (роль сотрудника и переключатели
      // администратора).
      roleOwners: const <String, String>{Roles.storekeeperId: 'sado'},
      roleActions: <String, String>{
        if (login.isNotEmpty) Roles.storekeeperId: login,
      },
    );
    final existing = controller;
    if (existing != null && _historyLogin == login) {
      existing.extensions.apply(choice);
      return;
    }
    final tasks = TaskService(
      repository: InMemoryTaskRepository(),
      clock: _clock,
    );
    final registry = ExtensionRegistry(
      connectors: <Connector>[
        service.connector,
        const CalculatorConnector(),
        TalkConnector(taskService: tasks),
      ],
      choice: choice,
      replyOverrides: WidgetTexts.replies,
    );
    controller = AssistantController(
      extensions: registry,
      clock: _clock,
      // Один помощник — Связной, без эмодзи: у шрифтов помощника их нет,
      // а за чужими шрифтами он не ходит.
      personas: const PersonaSettings(teamMode: TeamMode.solo, emoji: false),
    );
    _historyLogin = login;
    final history = WidgetHistory(storage, login);
    _history = history;
    messages
      ..clear()
      ..addAll(history.load());
  }

  /// Новый ключ от страницы склада; `false` — не дали.
  Future<bool> _rekey() async {
    final waiter = _keyWaiter ??= Completer<HostKey>();
    host.post(WidgetMessages.needKey());
    HostKey key;
    try {
      key = await waiter.future.timeout(keyWait);
    } on TimeoutException {
      _keyWaiter = null;
      return false;
    }
    if (key.sid.isEmpty) return false;
    return _connect(key.sid);
  }

  /// «Попробовать ещё раз» после неудачного входа.
  Future<void> retry() async {
    if (init == null || phase == WidgetPhase.connecting) return;
    phase = WidgetPhase.connecting;
    notifyListeners();
    if (!await _rekey() && phase != WidgetPhase.ready) {
      _fail(
        'Склад не выдал новый ключ помощника. Обновите страницу склада.',
      );
    }
  }

  Future<void> _logout() async {
    cancelVoice();
    await service?.logout(remote: false);
    _history?.clear();
    storage
      ..remove(WidgetConnectionStore.recordKey(ConnectionSlots.warehouse.appId))
      ..remove(
        WidgetConnectionStore.manifestKey(ConnectionSlots.warehouse.appId),
      );
    messages.clear();
    controller?.clearConversation();
    phase = WidgetPhase.loggedOut;
    notifyListeners();
  }

  bool get _expired =>
      service?.record.failure == ConnectionFailure.expired ||
      !(service?.connected ?? false);

  // ----------------------------------------------------------- разговор

  String _newId() => 'm_${_clock.now().microsecondsSinceEpoch}_${_ids++}';

  ChatMessage _answer(AssistantResponse response) => ChatMessage(
        id: _newId(),
        author: ChatAuthor.persona,
        // Ответ склада с карточкой: строки — в карточке, в пузыре итог.
        text: response.warehouse == null
            ? response.message
            : response.message.split('\n').first,
        timestamp: _clock.now(),
        status: response.status,
        personaId: response.personaId,
        card: response.card,
        warehouse: response.warehouse,
      );

  /// Сообщение сотрудника. Ключ устарел — один раз просит у страницы
  /// новый и повторяет вопрос.
  Future<void> send(String text, {bool fromVoice = false}) async {
    final assistant = controller;
    final message = text.trim();
    if (assistant == null || busy || message.isEmpty) return;
    messages.add(
      ChatMessage(
        id: _newId(),
        author: ChatAuthor.user,
        text: message,
        timestamp: _clock.now(),
      ),
    );
    busy = true;
    voiceNote = '';
    notifyListeners();
    try {
      var response = await assistant.handle(message, fromVoice: fromVoice);
      if (_expired && await _rekey()) {
        response = await (controller ?? assistant)
            .handle(message, fromVoice: fromVoice);
      }
      messages.add(_answer(response));
    } on Object {
      messages.add(
        ChatMessage(
          id: _newId(),
          author: ChatAuthor.persona,
          personaId: 'sado',
          text: 'Что-то пошло не так — повторите, пожалуйста.',
          timestamp: _clock.now(),
          status: AssistantStatus.failed,
        ),
      );
    } finally {
      busy = false;
      _save();
      notifyListeners();
      _maybeAnnounce();
    }
  }

  /// «Подтвердить» и «Отмена» на карточке действия.
  Future<void> answerCard(ActionCard card, {required bool apply}) =>
      _cardAction(() {
        if (apply) card.onSending = () async => _save();
        return controller!
            .answerCard(card, apply: apply)
            .whenComplete(() => card.onSending = null);
      });

  /// «Проверить» на карточке с неизвестным итогом.
  Future<void> settleCard(ActionCard card, {String? personaId}) =>
      _cardAction(() => controller!.settleCard(card, personaId: personaId));

  Future<void> _cardAction(
    Future<AssistantResponse?> Function() action,
  ) async {
    if (controller == null || busy) return;
    busy = true;
    notifyListeners();
    try {
      final response = await action();
      if (response != null) messages.add(_answer(response));
    } finally {
      busy = false;
      _save();
      notifyListeners();
      _maybeAnnounce();
    }
  }

  void _save() => _history?.save(messages);

  /// «Новый чат»: история и ожидающий вопрос — долой.
  void newChat() {
    if (busy) return;
    messages.clear();
    _history?.clear();
    controller
      ?..clearConversation()
      ..enterChat(sessionId: _newId());
    notifyListeners();
  }

  void close() => host.post(WidgetMessages.close());

  /// Escape на компьютере: фокус внутри фрейма, и клавишу видит помощник, а
  /// не страница склада. Идёт распознавание — сначала отменить его.
  void escape() {
    if (listening) {
      cancelVoice();
    } else {
      close();
    }
  }

  /// «Открыть склад» из карточки: главная склада, панель на телефоне
  /// сворачивается.
  void openWarehouse([String hash = '']) =>
      host.post(WidgetMessages.open(hash));

  /// Строка карточки или «Открыть в складе»: позиция или приход на
  /// странице склада, панель на телефоне сворачивается.
  void openWarehouseLink(String kind, String id) =>
      openWarehouse(WidgetMessages.linkHash(kind, id));

  // ------------------------------------------------------------- голос

  /// Кнопка микрофона.
  void startVoice() {
    final caps = voice;
    if (!caps.showButton || busy) return;
    if (caps.keyboardHint) {
      voiceNote = caps.reason == 'no-ondevice'
          ? 'На этом телефоне нет распознавания речи без интернета. '
              'Нажмите микрофон на клавиатуре.'
          : 'На этом телефоне распознавание речи — только с Android 12. '
              'Нажмите микрофон на клавиатуре.';
      notifyListeners();
      return;
    }
    if (caps.needsLanguage) {
      host.post(WidgetMessages.voice('download', ++_voiceId));
      voiceNote = 'Скачиваю русский язык для распознавания на телефоне — '
          'потом нажмите микрофон ещё раз.';
      notifyListeners();
      return;
    }
    if (listening) {
      host.post(WidgetMessages.voice('stop', _voiceId));
      return;
    }
    listening = true;
    partial = '';
    voiceNote = '';
    host.post(WidgetMessages.voice('start', ++_voiceId));
    notifyListeners();
  }

  void cancelVoice() {
    if (!listening) return;
    host.post(WidgetMessages.voice('cancel', _voiceId));
    listening = false;
    partial = '';
    notifyListeners();
    _maybeAnnounce();
  }

  void _onVoice(HostVoiceEvent event) {
    if (event.id != _voiceId) return;
    switch (event.kind) {
      case 'partial':
        if (listening) partial = event.text;
      case 'final':
        final wasListening = listening;
        listening = false;
        partial = '';
        if (wasListening && event.text.trim().isNotEmpty) {
          unawaited(send(event.text, fromVoice: true));
        }
      case 'error':
        listening = false;
        partial = '';
        voiceNote = voiceError(event.code);
      case 'state':
        if (event.text == 'end' && listening && partial.isEmpty) {
          listening = false;
        }
    }
    notifyListeners();
    _maybeAnnounce();
  }

  /// Что сказать на ошибку распознавания.
  static String voiceError(String code) => switch (code) {
        'no-speech' ||
        'no-match' =>
          'Не расслышал — нажмите микрофон и скажите ещё раз.',
        'busy' => 'Микрофон занят другим приложением.',
        'perm' ||
        'perm-denied' =>
          'Нет доступа к микрофону — разрешите его приложению склада в '
              'настройках телефона.',
        'lang' ||
        'lang-unavailable' =>
          'Русский для распознавания не установлен — нажмите микрофон, '
              'чтобы скачать.',
        _ => 'Распознавание не сработало — напишите текстом.',
      };

  // ---------------------------------------------------------- обновление

  /// Какая версия помощника установлена на складе (`assistant/current.json`).
  Future<void> checkUpdate() async {
    final start = init;
    if (start == null || version == 'dev') return;
    final Uri uri;
    try {
      uri = ConnectionService.baseOf(start.base)
          .resolve('assistant/current.json');
    } on Object {
      return;
    }
    try {
      final response = await _transport.send(
        HttpRequestData(
          method: 'GET',
          uri: uri,
          headers: const <String, String>{
            'Accept': 'application/json',
            'Cache-Control': 'no-cache',
          },
        ),
      );
      if (!response.isSuccess) return;
      final json = jsonDecode(response.body);
      final installed = json is Map ? json['version'] : null;
      if (installed is! String || installed.isEmpty) return;
      pendingUpdate = installed == version ? null : installed;
    } on Object {
      return;
    }
    _maybeAnnounce();
  }

  /// Помощник ничем не занят: ничего не отправляется, поле ввода пусто,
  /// голос не слушает, карточка не ждёт ответа.
  bool get idle =>
      !busy &&
      !listening &&
      _draft.trim().isEmpty &&
      controller?.session.pendingConfirmation == null;

  void _maybeAnnounce() {
    final next = pendingUpdate;
    if (next == null || next == _announced || !idle) return;
    _announced = next;
    host.post(WidgetMessages.updateReady(next));
  }
}
