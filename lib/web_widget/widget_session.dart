import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/chats/chat_book.dart';
import '../core/chats/chat_models.dart';
import '../core/chats/chat_projects.dart';
import '../core/connectors/connector.dart';
import '../core/connectors/http_transport.dart';
import '../core/connectors/manifest/connection.dart';
import '../core/connectors/manifest/connection_service.dart';
import '../core/connectors/manifest/connection_slots.dart';
import '../core/connectors/manifest/manifest_connector.dart';
import '../core/connectors/secret_store.dart';
import '../core/connectors/tasks_connector.dart';
import '../core/extensions/extension_registry.dart';
import '../core/models/action_card.dart';
import '../core/models/task.dart';
import '../core/personas/persona.dart';
import '../core/scenario/assistant_controller.dart';
import '../core/scenario/scenario_parser.dart';
import '../core/services/clock.dart';
import '../core/services/task_service.dart';
import '../core/skills/calculator/calculator_connector.dart';
import '../core/skills/talk/talk_connector.dart';
import 'widget_protocol.dart';
import 'widget_storage.dart';
import 'widget_store.dart';
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

/// Что открыто в помощнике: разговор или экран, как разделы приложения
/// (ADR-038).
enum WidgetView {
  /// Разговор ([WidgetSession.book] → `current`).
  chat,

  /// «Сегодня»: дела на сегодня и просроченные, ждущие карточки (карточка
  /// «Мой Связной» в меню).
  today,

  /// Все задачи.
  tasks,

  /// Проекты: папки и метки задач.
  projects,

  /// Экран проекта [WidgetSession.projectId]: его разговоры и задачи.
  project,

  /// Планирование: задачи по дням.
  planning,
}

/// Веб-помощник склада без интерфейса (ADR-032, ADR-038): вход по ключу
/// страницы склада, разговоры (список, проекты, переименовать, закрепить,
/// удалить, перенести), задачи (`TasksConnector`, «готово», срок),
/// напоминания при открытии, карточки, новый ключ на «ключ устарел», голос
/// через оболочку Android и «есть новая версия». Записи — в личном
/// хранилище склада `my_*` ([WidgetStore]). Без `package:web` —
/// проверяется тестами на VM.
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

  /// Записи этого входа: разговоры, проекты, задачи.
  WidgetStore? store;
  ChatBook? book;
  TaskService? tasks;
  String? _storeLogin;
  String _sid = '';

  /// Открытый разговор.
  List<ChatMessage> get messages => book?.current.messages ?? const [];

  /// Задачи для списка: активные, потом сделанные сегодня.
  List<Task> taskList = const <Task>[];

  /// Напоминания при открытии: со склада (`signal`, `my_signals`) и свои —
  /// просроченные и на сегодня задачи. Не в истории разговора.
  List<WidgetSignal> reminders = const <WidgetSignal>[];

  /// Хранилище склада включено (иначе — только этот браузер).
  bool get synced => store?.remote ?? false;

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

  // ------------------------------------------------------------ экраны

  /// Открытый экран; «Назад» склада и Escape с экрана ведут в разговор.
  WidgetView view = WidgetView.chat;

  /// Проект экрана [WidgetView.project].
  String? projectId;

  /// Открыть экран [next]; [project] — для [WidgetView.project].
  void show(WidgetView next, {String? project}) {
    view = next;
    projectId = next == WidgetView.project ? project : null;
    if (next != WidgetView.chat) unawaited(refresh());
    notifyListeners();
  }

  /// Проект со склада (`open-project`): нет в кэше — сначала
  /// синхронизация; так и не нашёлся — экран «Проекты».
  Future<void> openServerProject(String id) async {
    var current = book;
    if (current == null) return;
    if (current.project(id) == null) {
      await store?.pull();
      await _loadBook(keep: current.currentId);
      current = book!;
    }
    if (current.project(id) != null) {
      show(WidgetView.project, project: id);
    } else {
      show(WidgetView.projects);
    }
  }

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
        escape();
      case HostLogout():
        await _logout();
      case HostVisible(:final on):
        visible = on;
        if (!on && listening) cancelVoice();
        if (on) {
          unawaited(checkUpdate());
          unawaited(refresh());
        }
        _maybeAnnounce();
      case HostSignal(:final items, :final focus):
        _showSignals(items, focus: focus);
      case HostOpenChat(:final id):
        await openServerChat(id);
      case HostOpenProject(:final id):
        await openServerProject(id);
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
    _sid = sid;
    final login = current.record.login ?? start.login.toLowerCase();
    await _build(current, login);
    phase = WidgetPhase.ready;
    problem = '';
    _updates ??= Timer.periodic(updateEvery, (_) => unawaited(checkUpdate()));
    notifyListeners();
    unawaited(checkUpdate());
    return true;
  }

  /// Запрос `my_*` под ключом помощника — тем же путём и с теми же
  /// заголовками, что вопросы складу.
  Future<MyReply> _my(String action, Map<String, Object?> body) async {
    final current = service;
    final description = current?.description;
    final base = current?.record.manifestUri;
    if (description == null || base == null || _sid.isEmpty) {
      return const MyReply(0);
    }
    try {
      final response = await _transport.send(
        HttpRequestData(
          method: 'POST',
          uri: ManifestConnector.actionUri(description, base, action),
          headers: ManifestConnector.headersFor(
            description,
            <String, String>{'sid': _sid},
          ),
          body: jsonEncode(body),
          timeout: const Duration(seconds: 20),
        ),
      );
      Map<String, Object?>? json;
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, Object?>) json = decoded;
      } on Object {
        json = null;
      }
      return MyReply(response.statusCode, json);
    } on Object {
      return const MyReply(0);
    }
  }

  /// Помощник, разговоры и задачи — под логином входа; другой логин —
  /// другие записи.
  Future<void> _build(ConnectionService service, String login) async {
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
    if (existing != null && _storeLogin == login) {
      existing.extensions.apply(choice);
      store?.attach(service.lastMe, _my);
      return;
    }
    final records = WidgetStore(storage: storage, login: login, clock: _clock)
      ..onPushed = () => host.post(WidgetMessages.changed(<String>['my']));
    records.attach(service.lastMe, _my);
    await records.importHistory();
    await records.pull();
    store = records;
    _storeLogin = login;
    final taskService = TaskService(repository: records.tasks, clock: _clock);
    tasks = taskService;
    final registry = ExtensionRegistry(
      connectors: <Connector>[
        TasksConnector(
          taskService: taskService,
          parser: ScenarioParser(clock: _clock),
        ),
        service.connector,
        const CalculatorConnector(),
        TalkConnector(taskService: taskService),
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
    await _loadBook();
    await _openRecent();
    await _remind();
  }

  /// Разговоры заново из кэша (после синхронизации со складом).
  Future<void> _loadBook({String? keep}) async {
    final records = store;
    if (records == null) return;
    final next = ChatBook(store: records.chats, clock: _clock);
    await next.load();
    final all = await tasks?.listAll() ?? const <Task>[];
    next.prune(<String>{for (final t in all) t.id});
    book = next;
    await _refreshTasks();
    if (keep != null && next.thread(keep) != null) await _enter(keep);
  }

  /// Открыть последний разговор, если он был сегодня; иначе — новый.
  Future<void> _openRecent() async {
    final current = book;
    if (current == null) return;
    final now = _clock.now();
    final recent = current.sessions(limit: 1).firstOrNull;
    if (recent != null &&
        now.difference(recent.lastActivityAt) < const Duration(hours: 12)) {
      await _enter(recent.id);
    } else {
      _enterController(current.current);
    }
  }

  Future<void> _enter(String chatId) async {
    final current = book;
    if (current == null) return;
    final thread = await current.open(chatId);
    _enterController(thread);
  }

  void _enterController(ChatThread thread) {
    controller?.enterChat(
      taskId: thread.kind == ChatKind.task ? thread.taskId : null,
      sessionId: thread.isSession ? thread.id : null,
      projectTag: book?.project(thread.projectId)?.taskTag,
    );
  }

  /// Панель снова открыли: изменения со склада (другое устройство,
  /// вкладка «Проекты») и напоминания.
  Future<void> refresh() async {
    final records = store;
    if (records == null || phase != WidgetPhase.ready) return;
    await records.flush();
    if (await records.pull() && idle) {
      await _loadBook(keep: book?.currentId);
    }
    await _remind();
    notifyListeners();
  }

  Future<void> _refreshTasks() async {
    final service = tasks;
    if (service == null) return;
    final all = await service.listAll();
    final now = _clock.now();
    final active = all
        .where(
          (Task t) =>
              t.status != TaskStatus.done && t.status != TaskStatus.cancelled,
        )
        .toList()
      ..sort((Task a, Task b) {
        final da = a.dueAt;
        final db = b.dueAt;
        if (da == null && db == null) return b.createdAt.compareTo(a.createdAt);
        if (da == null) return 1;
        if (db == null) return -1;
        return da.compareTo(db);
      });
    final done = all
        .where(
          (Task t) =>
              t.status == TaskStatus.done &&
              t.completedAt != null &&
              now.difference(t.completedAt!) < const Duration(days: 1),
        )
        .toList();
    taskList = <Task>[...active, ...done];
  }

  /// Задача просрочена: срок прошёл (у даты без времени — день прошёл).
  bool overdue(Task task) {
    final due = task.dueAt;
    if (due == null || task.status == TaskStatus.done) return false;
    final now = _clock.now();
    if (task.duePrecision == DuePrecision.date) {
      final today = DateTime(now.year, now.month, now.day);
      return DateTime(due.year, due.month, due.day).isBefore(today);
    }
    return due.isBefore(now);
  }

  bool _today(Task task) {
    final due = task.dueAt?.toLocal();
    final now = _clock.now();
    return due != null &&
        due.year == now.year &&
        due.month == now.month &&
        due.day == now.day;
  }

  // ------------------------------------------------------ напоминания

  /// Напоминания при открытии: склад (`my_signals`, если включены), а без
  /// него — свои: просроченные и на сегодня.
  Future<void> _remind() async {
    final records = store;
    final server = await records?.fetchSignals();
    if (server != null) {
      final items = <WidgetSignal>[
        for (final item in server)
          if (WidgetSignal.fromJson(item) case final WidgetSignal s) s,
      ];
      _showSignals(items.where((WidgetSignal s) => !s.seen).toList());
      return;
    }
    final open = taskList
        .where((Task t) => t.status != TaskStatus.done && t.dueAt != null)
        .toList();
    final late = open.where(overdue).toList();
    final today = open.where((Task t) => !overdue(t) && _today(t)).toList();
    reminders = <WidgetSignal>[
      for (final t in <Task>[...late, ...today].take(5))
        WidgetSignal(
          id: 'local:${t.id}',
          title: t.title,
          text: overdue(t) ? 'Просрочена' : 'На сегодня',
          level: overdue(t) ? 'warn' : 'info',
          actions: <SignalAction>[
            SignalAction(
              id: 'done',
              label: 'Готово',
              my: <String, Object?>{
                'action': 'local_done',
                'body': <String, Object?>{'id': t.id},
              },
            ),
            SignalAction(id: 'tomorrow', label: 'На завтра', ack: 'snooze'),
          ],
        ),
    ];
    notifyListeners();
  }

  void _showSignals(List<WidgetSignal> items, {String focus = ''}) {
    final list = <WidgetSignal>[
      ...items.where((WidgetSignal s) => s.id == focus),
      ...items.where((WidgetSignal s) => s.id != focus),
    ];
    final known = <String>{for (final r in reminders) r.id};
    reminders = <WidgetSignal>[
      ...list,
      ...reminders.where(
        (WidgetSignal r) =>
            !r.id.startsWith('local:') && !list.any((s) => s.id == r.id),
      ),
    ].take(5).toList();
    final fresh = <String>[
      for (final s in list)
        if (!known.contains(s.id)) s.id,
    ];
    if (fresh.isNotEmpty) {
      unawaited(
        store?.ackSignals('seen', fresh).then((bool ok) {
          if (ok) host.post(WidgetMessages.changed(<String>['sig']));
        }),
      );
    }
    notifyListeners();
  }

  /// Убрать напоминание с экрана (на складе оно остаётся увиденным).
  void dismissReminder(WidgetSignal signal) {
    reminders = reminders.where((WidgetSignal r) => r.id != signal.id).toList();
    notifyListeners();
  }

  /// Кнопка напоминания. [date] — для действий с выбором даты.
  Future<void> runReminder(
    WidgetSignal signal,
    SignalAction action, {
    DateTime? date,
  }) async {
    if (action.ask case final String ask) {
      dismissReminder(signal);
      await send(ask);
      return;
    }
    final open = action.open;
    if (open != null) {
      openWarehouse(open);
      return;
    }
    final localId =
        signal.id.startsWith('local:') ? signal.id.substring(6) : null;
    if (localId != null) {
      if (action.my != null) {
        await completeTask(localId);
      } else if (action.ack == 'snooze') {
        final now = _clock.now();
        await setDue(localId, DateTime(now.year, now.month, now.day + 1));
      }
      dismissReminder(signal);
      return;
    }
    final records = store;
    if (records == null) return;
    if (action.ack case final String op) {
      if (await records.ackSignals(op, <String>[signal.id])) {
        host.post(WidgetMessages.changed(<String>['sig']));
      }
      dismissReminder(signal);
      return;
    }
    final my = action.my;
    if (my != null) {
      final body = my['body'];
      if (body is! Map) return;
      var json = jsonEncode(body);
      if (action.dateLabel != null) {
        if (date == null) return;
        final d = '${date.year.toString().padLeft(4, '0')}-'
            '${date.month.toString().padLeft(2, '0')}-'
            '${date.day.toString().padLeft(2, '0')}';
        json = json.replaceAll('{date}', d);
      }
      final ok = await records.runMy(
        my['action']! as String,
        Map<String, Object?>.from(jsonDecode(json) as Map),
      );
      if (ok) {
        await _loadBook(keep: book?.currentId);
        dismissReminder(signal);
      }
      return;
    }
    if (action.call != null) {
      // Действие склада — через карточку на странице склада: там его
      // подтверждают кнопкой.
      openWarehouse(signal.open);
    }
  }

  // --------------------------------------------- разговоры и проекты

  /// Новый разговор; [projectId] — сразу в проекте.
  Future<void> newChat({String? projectId}) async {
    final current = book;
    if (busy || current == null) return;
    final thread = await current.newSession(projectId: projectId);
    controller?.clearConversation();
    _enterController(thread);
    view = WidgetView.chat;
    notifyListeners();
  }

  Future<void> openChat(String chatId) async {
    if (busy) return;
    await _enter(chatId);
    view = WidgetView.chat;
    notifyListeners();
  }

  /// Разговор со склада (`open-chat`, «Открыть в помощнике»): нет в кэше
  /// — сначала синхронизация.
  Future<void> openServerChat(String chatId) async {
    var current = book;
    if (current == null) return;
    if (current.thread(chatId) == null) {
      await store?.pull();
      await _loadBook();
      current = book!;
    }
    if (current.thread(chatId) != null) await openChat(chatId);
  }

  bool renameChat(String chatId, String title) {
    final ok = book?.rename(chatId, title) ?? false;
    notifyListeners();
    return ok;
  }

  void pinChat(String chatId, {required bool pinned}) {
    book?.setPinned(chatId, pinned);
    notifyListeners();
  }

  Future<void> deleteChat(String chatId) async {
    final current = book;
    if (current == null || busy) return;
    final wasCurrent = await current.remove(chatId);
    if (wasCurrent) {
      controller?.clearConversation();
      _enterController(current.current);
    }
    notifyListeners();
  }

  void moveChat(String chatId, String? projectId) {
    final current = book;
    if (current == null) return;
    current.moveToProject(chatId, projectId);
    if (chatId == current.currentId) {
      controller?.setProjectTag(current.project(projectId)?.taskTag);
    }
    notifyListeners();
  }

  ChatProject? createProject(String name, {String? tag}) {
    final project = book?.createProject(name, taskTag: tag);
    notifyListeners();
    return project;
  }

  bool renameProject(String projectId, String name) {
    final ok = book?.renameProject(projectId, name) ?? false;
    notifyListeners();
    return ok;
  }

  void pinProject(String projectId, {required bool pinned}) {
    book?.setProjectPinned(projectId, pinned);
    notifyListeners();
  }

  /// Описание проекта; пустое — убрать.
  void describeProject(String projectId, String name, String? description) {
    book
      ?..renameProject(projectId, name)
      ..setProjectDescription(projectId, description);
    notifyListeners();
  }

  /// Метка задач проекта; `null` — снять связь. `false` — метка уже у
  /// другого проекта.
  bool tagProject(String projectId, String? tag) {
    final current = book;
    if (current == null) return false;
    final other = tag == null ? null : current.projectForTag(tag);
    if (other != null && other.id != projectId) return false;
    current.linkProjectTag(projectId, tag);
    if (current.current.projectId == projectId) {
      controller?.setProjectTag(tag);
    }
    notifyListeners();
    return true;
  }

  /// Удалить проект; [deleteSessions] — вместе с его разговорами, иначе
  /// они остаются без проекта. Открыт экран проекта — «Проекты».
  Future<void> deleteProject(
    String projectId, {
    bool deleteSessions = false,
  }) async {
    final current = book;
    if (current == null) return;
    final wasCurrent = await current.deleteProject(
      projectId,
      deleteSessions: deleteSessions,
    );
    if (wasCurrent) {
      controller?.clearConversation();
      _enterController(current.current);
    } else {
      controller?.setProjectTag(current.projectOf(current.currentId)?.taskTag);
    }
    if (view == WidgetView.project && this.projectId == projectId) {
      view = WidgetView.projects;
      this.projectId = null;
    }
    notifyListeners();
  }

  // ------------------------------------------------------------ задачи

  Future<void> completeTask(String id) async {
    await tasks?.complete(id);
    await _afterTask();
  }

  Future<void> reopenTask(String id) async {
    await tasks?.reopen(id);
    await _afterTask();
  }

  /// Срок задачи: дата без времени.
  Future<void> setDue(String id, DateTime day) async {
    await tasks?.reschedule(
      id,
      DateTime(day.year, day.month, day.day),
      DuePrecision.date,
    );
    await _afterTask();
  }

  /// Разговор задачи: её чат (заводится при первом открытии).
  Future<void> openTask(String id) async {
    final current = book;
    if (current == null || busy) return;
    final thread = await current.openTask(id);
    _enterController(thread);
    view = WidgetView.chat;
    notifyListeners();
  }

  Future<void> _afterTask() async {
    await _refreshTasks();
    reminders = reminders
        .where(
          (WidgetSignal r) =>
              !r.id.startsWith('local:') ||
              taskList.any(
                (Task t) =>
                    'local:${t.id}' == r.id && t.status != TaskStatus.done,
              ),
        )
        .toList();
    notifyListeners();
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
    store?.clear();
    WidgetHistory(storage, _storeLogin ?? '').clear();
    storage
      ..remove(WidgetConnectionStore.recordKey(ConnectionSlots.warehouse.appId))
      ..remove(
        WidgetConnectionStore.manifestKey(ConnectionSlots.warehouse.appId),
      );
    book = null;
    store = null;
    _storeLogin = null;
    view = WidgetView.chat;
    projectId = null;
    controller?.clearConversation();
    controller = null;
    taskList = const <Task>[];
    reminders = const <WidgetSignal>[];
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
    final chats = book;
    final message = text.trim();
    if (assistant == null || chats == null || busy || message.isEmpty) return;
    final chatId = chats.currentId;
    final command = ChatMessage(
      id: _newId(),
      author: ChatAuthor.user,
      text: message,
      timestamp: _clock.now(),
    );
    chats.append(chatId, command);
    busy = true;
    voiceNote = '';
    notifyListeners();
    try {
      var response = await assistant.handle(message, fromVoice: fromVoice);
      if (_expired && await _rekey()) {
        response = await (controller ?? assistant)
            .handle(message, fromVoice: fromVoice);
      }
      final reply = _answer(response);
      chats.append(chatId, reply);
      final task = response.task;
      if (response.intent == 'task.create' &&
          task != null &&
          response.status == AssistantStatus.completed &&
          chats.taskThread(task.id) == null) {
        chats.onTaskCreated(
          task.id,
          fromChatId: chatId,
          command: command,
          reply: reply,
        );
      }
      if (task != null || response.intent.startsWith('task.')) {
        await _afterTask();
      }
    } on Object {
      chats.append(
        chatId,
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
      notifyListeners();
      _maybeAnnounce();
    }
  }

  /// «Подтвердить» и «Отмена» на карточке действия.
  Future<void> answerCard(ActionCard card, {required bool apply}) =>
      _cardAction(() {
        if (apply) card.onSending = () async => book?.touch(book!.currentId);
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
    final chats = book;
    if (controller == null || chats == null || busy) return;
    final chatId = chats.currentId;
    busy = true;
    notifyListeners();
    try {
      final response = await action();
      if (response != null) {
        chats.append(chatId, _answer(response));
        // Записали на складе: страница склада перечитывает данные.
        if (response.status == AssistantStatus.completed) {
          host.post(WidgetMessages.changed(<String>['data']));
        }
      }
    } finally {
      busy = false;
      chats.touch(chatId);
      notifyListeners();
      _maybeAnnounce();
    }
  }

  /// Попросить у склада широкую (или обычную) панель.
  void setWide({required bool wide}) {
    host.post(WidgetMessages.layout(wide: wide));
    wideAsked = wide;
    notifyListeners();
  }

  /// Что помощник попросил у склада последним; `null` — как в `init`.
  bool? wideAsked;

  bool get canWide => (init?.canWide ?? false) && !(init?.phone ?? false);

  bool get wide => wideAsked ?? init?.wide ?? false;

  void close() => host.post(WidgetMessages.close());

  /// Escape на компьютере: фокус внутри фрейма, и клавишу видит помощник, а
  /// не страница склада. Идёт распознавание — сначала отменить его.
  void escape() {
    if (listening) {
      cancelVoice();
    } else if (view != WidgetView.chat) {
      show(WidgetView.chat);
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
