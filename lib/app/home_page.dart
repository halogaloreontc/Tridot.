import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/chats/chat_book.dart';
import '../core/chats/chat_models.dart';
import '../core/chats/chat_search.dart';
import '../core/chats/chat_store.dart';
import '../core/connectors/connector.dart';
import '../core/connectors/login_link.dart';
import '../core/connectors/manifest/connection_service.dart';
import '../core/connectors/manifest/connection.dart';
import '../core/formatting/due_format.dart';
import '../core/models/action_card.dart';
import '../core/models/bulk.dart';
import '../core/models/secure_card.dart';
import '../core/models/task.dart';
import '../core/passwords/secret_guard.dart';
import '../core/passwords/vault.dart';
import '../core/replies/reply_library.dart';
import '../core/scenario/assistant_controller.dart';
import '../core/services/clock.dart';
import '../core/services/task_service.dart';
import '../core/settings/app_settings.dart';
import '../core/stats/relay_stats.dart';
import '../core/storage/storage_info.dart';
import 'assistant_theme.dart';
import 'passwords/entry_screens.dart';
import 'passwords/generator_view.dart';
import 'passwords/passwords_kit.dart';
import 'passwords/passwords_screen.dart';
import 'passwords/secure_card_view.dart';
import 'screens/my_relay_screen.dart';
import 'screens/my_relay_tabs.dart';
import 'screens/planning_screen.dart';
import 'screens/projects_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/storage_screen.dart';
import 'shell/drawer_swipe.dart';
import 'shell/quick_actions.dart';
import 'shell/relay_drawer.dart';
import 'shell/session_header.dart';
import 'shell/session_hero.dart';
import 'shell/today_panel.dart';
import 'widgets/action_card_view.dart';
import 'widgets/bulk_checklist_card.dart';
import 'widgets/command_composer.dart';
import 'widgets/connection_screen.dart';
import 'widgets/document_view.dart';
import 'widgets/extensions_section.dart';
import 'widgets/history_rail.dart';
import 'widgets/personas_section.dart';
import 'widgets/quick_dock.dart';
import 'widgets/status_cube.dart';
import 'widgets/task_chat_header.dart';
import 'widgets/task_tile.dart';

/// Разделы оболочки «Д»: сессия (главный экран), задачи, проекты,
/// планирование и «Мой Связной».
enum AppSection { session, tasks, projects, planning, myRelay }

extension AppSectionInfo on AppSection {
  String get title => switch (this) {
        AppSection.session => 'Сессия',
        AppSection.projects => 'Проекты',
        AppSection.tasks => 'Задачи',
        AppSection.planning => 'Планирование',
        AppSection.myRelay => 'Мой Связной',
      };
}

/// Ширина, начиная с которой меню стоит постоянной колонкой слева, а
/// «Сегодня» — колонкой справа (три колонки, макет D-Desk). Уже — меню
/// выдвигается (кнопкой в шапке и свайпом вправо), а «Сегодня» отдельно
/// нет: всё оттуда — в «Мой Связной» → «Сводка».
const double wideBreakpoint = 1000;

/// Ширина, начиная с которой колонка «Сегодня» открыта сразу; уже — она
/// свёрнута, пока её не откроют кнопкой «Показать «Сегодня»» в шапке.
const double todayOpenBreakpoint = 1280;

/// Ширина, ниже которой хроника команд — одна кнопка со списком.
const double narrowBreakpoint = 700;

/// Ширина постоянного меню и колонки «Сегодня» на широком экране.
const double sidebarWidth = 280;
const double todayWidth = 340;

/// Подсказка пустой панели задач: пример команды без кавычек на своей
/// строке, чтобы он не рвался посередине.
const String emptyTasksHint =
    'Напишите в сессии, например:\nзавтра купить хлеб';

/// Наибольшая ширина колонки чата (сообщения, быстрые действия и поле
/// ввода).
const double chatColumnWidth = 760;

/// Общий отступ содержимого колонки чата от её краёв: по нему выровнены
/// текст ответов, правый край пузырей, быстрые действия и поле ввода.
const double chatInset = 16;

final class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.assistant,
    required this.tasks,
    this.clock = const SystemClock(),
    this.storage = const MemoryStorageInfo(),
    this.settingsStore,
    this.chatStore,
    this.connections = const <ConnectionService>[],
    this.passwords,
  });

  final AssistantController assistant;
  final TaskService tasks;
  final Clock clock;
  final StorageInfo storage;
  final SettingsStore? settingsStore;

  /// Навык «Пароли» (ADR-014): хранилище, буфер, запирание; `null` —
  /// хранилища нет (не загрузилась libsodium).
  final PasswordsKit? passwords;

  /// Где хранятся чаты (ADR-010). По умолчанию — в памяти, как задачи и
  /// настройки в тестах и режиме «Только в памяти».
  final ChatStore? chatStore;

  /// Подключения к приложениям (склад): «Настройки → Подключения».
  final List<ConnectionService> connections;

  @override
  State<HomePage> createState() => _HomePageState();
}

final class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();

  /// Растёт после каждого чтения задач: открытые поверх маршруты
  /// («Данные и резервная копия») перестраиваются по нему.
  final ValueNotifier<int> _dataRevision = ValueNotifier<int>(0);
  final ScrollController _chatScroll = ScrollController();

  final TextEditingController _docTitle = TextEditingController();
  final TextEditingController _docProject = TextEditingController();
  final TextEditingController _docBody = TextEditingController();
  final FocusNode _docBodyFocus = FocusNode();

  late final SettingsStore _settingsStore =
      widget.settingsStore ?? InMemorySettingsStore();

  /// Все чаты: главный и чаты задач (ADR-010).
  late final ChatBook _book = ChatBook(
    store: widget.chatStore ?? InMemoryChatStore(),
    clock: widget.clock,
  );

  /// Сообщения открытого чата.
  List<ChatMessage> get _messages => _book.current.messages;

  /// Чаты прочитаны: до этого сообщения ждут, а помощник не пишет первым.
  bool _chatsLoaded = false;

  /// Загрузка чатов: сообщение, отправленное раньше, ждёт её.
  late final Future<void> _chatsReady;

  /// Сколько раз создавался чат задачи. Обновление списка задач, начатое
  /// до создания, не удаляет новый чат ([_refresh], [ChatBook.prune]).
  int _chatCreations = 0;

  /// В главном чате только приветствие, показанное до загрузки настроек: его
  /// можно произнести голосом основного помощника из настроек.
  bool _pristineWelcome = true;

  /// Настройки загружены: до этого помощник не пишет первым.
  bool _settingsLoaded = false;

  /// Загрузка настроек: сообщение, отправленное раньше, ждёт её, чтобы
  /// ответить голосом из настроек, а не голосом по умолчанию.
  late final Future<void> _settingsReady;

  /// День, за который уже проверены просроченные задачи.
  String? _noticeChecked;

  /// «Команда обрабатывается…» от помощника, который сейчас отвечает.
  ChatMessage? _working;

  /// Чат, в котором ждут ответа [_working].
  String? _workingChatId;
  final Map<int, GlobalKey> _messageKeys = <int, GlobalKey>{};
  final List<String> _commands = <String>[];
  int? _commandCursor;

  /// Черновик, который был в поле до листания истории стрелками.
  String _draftBeforeRecall = '';
  int? _highlightedCommand;

  AppSection _section = AppSection.session;
  MyRelayTab _myRelayTab = MyRelayTab.summary;

  /// Сообщения непрочитанных чатов для точной активности в «Мой
  /// Связной»: читаются один раз при первом открытии. `null` — ещё нет.
  Map<String, List<ChatMessage>>? _storedChats;
  bool _readingStored = false;
  AssistantViewMode _mode = AssistantViewMode.dialogue;
  AppSettings _settings = const AppSettings();

  List<Task> _active = <Task>[];
  List<Task> _all = <Task>[];
  List<Task> _completed = <Task>[];
  Object? _loadError;
  bool _loaded = false;
  bool _sending = false;

  /// Колонка «Сегодня» на широком экране: `null` — пользователь не
  /// выбирал (открыта от [todayOpenBreakpoint]).
  bool? _todayOpen;

  /// Меню колонкой слева на широком экране («Свернуть панель»).
  bool _sidebarOpen = true;

  /// Фокус поиска по сессиям в меню (Ctrl K).
  final FocusNode _sessionSearch = FocusNode();

  /// Строка поиска по задачам на экране «Задачи».
  final TextEditingController _taskSearch = TextEditingController();
  String _taskQuery = '';
  CubeState _cube = CubeState.idle;

  String? _docTaskId;
  bool _docLoading = false;

  /// Сохранения документа идут строго по очереди.
  Future<void> _docSaves = Future<void>.value();

  DocumentSaveState _docState = DocumentSaveState.saved;
  DateTime? _docSavedAt;

  Timer? _cubeTimer;
  Timer? _docTimer;
  Timer? _tick;

  DateTime get _now => widget.clock.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    for (final controller in <TextEditingController>[
      _docTitle,
      _docProject,
      _docBody,
    ]) {
      controller.addListener(_onDocumentEdited);
    }
    _book.resetMain(<ChatMessage>[_welcome()]);
    for (final connection in widget.connections) {
      connection.addSessionListener(_onSessionChanged);
    }
    _settingsReady = _loadSettings();
    _chatsReady = _loadChats();
    _refresh();
    // Хранилище запирается, как только навык выключили (D18).
    final passwords = widget.passwords;
    if (passwords != null) {
      passwords.lifecycle.follow(widget.assistant.extensions);
      passwords.onSettings = _onPasswordsSettings;
      passwords.addListener(_onPasswordsChanged);
    }
  }

  /// Служебные флаги навыка «Пароли» — в settings.json (только версия
  /// файла и «хранилище было», 4.1 и D28).
  void _onPasswordsSettings({
    int? seenRev,
    bool? vaultExisted,
    String? trainingDue,
  }) {
    if (!mounted) return;
    // Дата тренировки не сдвигается раньше уже назначенной: после вопроса
    // «заметки дня» она отодвинута на 3 дня (не чаще 3 раз в неделю).
    final today = AppSettings.dayKey(_now);
    final current = _settings.passwordsTrainingDue;
    final due = trainingDue == null ||
            (current != null &&
                current.compareTo(today) > 0 &&
                current.compareTo(trainingDue) > 0)
        ? null
        : trainingDue;
    if (seenRev == null && vaultExisted == null && due == null) return;
    if (seenRev == null &&
        vaultExisted == null &&
        due == _settings.passwordsTrainingDue) {
      return;
    }
    _changeSettings(
      _settings.copyWith(
        passwordsSeenRev: seenRev,
        passwordsVaultExisted: vaultExisted,
        passwordsTrainingDue: due,
      ),
    );
  }

  Timer? _trainingTimer;
  bool _trainingAsked = false;

  /// Тренировка памяти паролей (5.8) — через «заметку дня», не в первые
  /// 30 с после запуска, не чаще раза в день и трёх раз в неделю. В
  /// `settings.json` — только дата.
  void _scheduleTrainingNotice() {
    if (_trainingTimer != null || _trainingAsked || !_passwordsEnabled) {
      return;
    }
    _trainingTimer = Timer(const Duration(seconds: 30), () {
      _trainingTimer = null;
      unawaited(_maybeTrainingNotice());
    });
  }

  Future<void> _maybeTrainingNotice() async {
    final passwords = widget.passwords;
    if (!mounted || passwords == null || !_passwordsEnabled) return;
    if (_trainingAsked) return;
    if (_sending || _bulkBusy) {
      _scheduleTrainingNotice();
      return;
    }
    final today = AppSettings.dayKey(_now);
    final due = _settings.passwordsTrainingDue;
    if (due == null || due.compareTo(today) > 0) return;
    if (passwords.isUnlocked &&
        !passwords.facade.trainingDue(passwords.vault.clock.now())) {
      return;
    }
    _trainingAsked = true;
    final response = await widget.assistant.secureCardAction(
      const SecureCardRequest(kind: SecureCardKind.training),
      SecureCardCommand.notice,
      personaId: widget.assistant.personas.notifier.id,
    );
    if (!mounted || response == null) return;
    setState(() {
      _pristineWelcome = false;
      _book.append(ChatThread.mainId, _answer(response));
    });
    _changeSettings(
      _settings.copyWith(
        passwordsTrainingDue: AppSettings.dayKey(
          _now.add(const Duration(days: 3)),
        ),
      ),
    );
  }

  void _onPasswordsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _dataRevision.dispose();
    WidgetsBinding.instance.removeObserver(this);
    widget.passwords?.removeListener(_onPasswordsChanged);
    if (widget.passwords?.onSettings == _onPasswordsSettings) {
      widget.passwords?.onSettings = null;
    }
    for (final connection in widget.connections) {
      connection.removeSessionListener(_onSessionChanged);
    }
    _cubeTimer?.cancel();
    _docTimer?.cancel();
    _docToastTimer?.cancel();
    _trainingTimer?.cancel();
    _tick?.cancel();
    // Несохранённые правки документа не теряем и при закрытии экрана.
    if (_docPending && _docTaskId != null) {
      unawaited(
        widget.tasks.updateDetails(
          _docTaskId!,
          title: _docTitle.text.trim().isEmpty ? null : _docTitle.text,
          description: _docBody.text,
          project: _docProject.text,
        ),
      );
    }
    _input.dispose();
    _taskSearch.dispose();
    _sessionSearch.dispose();
    _inputFocus.dispose();
    _chatScroll.dispose();
    _docTitle.dispose();
    _docProject.dispose();
    _docBody.dispose();
    _docBodyFocus.dispose();
    // Отложенная запись чатов — сразу, при закрытии экрана.
    unawaited(_book.flush());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Хранилище паролей: фон и «спрятано» запирают, потеря фокуса прячет
    // показанное (3.6).
    widget.passwords?.lifecycle.onAppState(state);
    if (state == AppLifecycleState.resumed) _refresh();
    if (state == AppLifecycleState.paused) _saveDocument();
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      unawaited(_book.flush());
    }
  }

  /// Закрытие окна на компьютере: отложенная запись чатов успевает
  /// закончиться до выхода (на телефоне её даёт пауза приложения). Диск не
  /// отвечает — выход не держим дольше [_exitFlushLimit].
  @override
  Future<AppExitResponse> didRequestAppExit() async {
    try {
      await widget.passwords?.lifecycle.onExit();
    } on Object {
      // Запереть не помешает выходу.
    }
    try {
      await _book.flush().timeout(_exitFlushLimit);
    } on Object {
      // Не успели или не записали: выходим всё равно.
    }
    return AppExitResponse.exit;
  }

  static const Duration _exitFlushLimit = Duration(seconds: 3);

  /// Приветствие основного помощника.
  ChatMessage _welcome() =>
      _answer(widget.assistant.welcome(), withStatus: false);

  /// Ответ помощника в историю: готовый текст и автор. Смена стиля или
  /// помощника потом его не переписывает.
  /// [withStatus] — показывать ли «Уточните»/«Ошибка» по статусу ответа
  /// (у приветствия и «обрабатывается…» статуса нет).
  ChatMessage _answer(
    AssistantResponse response, {
    bool withStatus = true,
  }) =>
      ChatMessage(
        id: _book.newMessageId(),
        author: ChatAuthor.persona,
        text: response.message,
        timestamp: _now,
        status: withStatus ? response.status : null,
        taskId: response.task?.id,
        personaId: response.personaId,
        checklist: response.checklist,
        card: response.card,
        secureCard: response.secureCard,
      );

  // ------------------------------------------------------------- данные

  Future<void> _loadSettings() async {
    final loaded = await _settingsStore.load();
    if (!mounted) return;
    // Разрешение действий для входа, которого больше нет, не переживает
    // перезапуск.
    final pruned = _prunedActions(loaded);
    final settings = pruned ?? loaded;
    if (pruned != null) unawaited(_settingsStore.save(pruned));
    _applyExtensions(settings);
    widget.assistant.personas = settings.personas;
    widget.passwords?.syncSettings(
      seenRev: settings.passwordsSeenRev,
      vaultExisted: settings.passwordsVaultExisted,
    );
    setState(() {
      _settings = settings;
      _settingsLoaded = true;
      // Приветствие до загрузки настроек звучало голосом по умолчанию.
      if (_pristineWelcome) _book.resetMain(<ChatMessage>[_welcome()]);
    });
    _maybeNotice();
  }

  /// Чаты с диска. Если в главном есть сохранённые сообщения, они
  /// заменяют приветствие; чаты задач читаются при открытии.
  Future<void> _loadChats() async {
    final restored = await _book.load();
    if (!mounted) return;
    setState(() {
      _chatsLoaded = true;
      if (restored) _pristineWelcome = false;
      _messageKeys.clear();
    });
    _maybeNotice();
  }

  /// Вход в подключение сменился (новый вход, выход, ключ устарел):
  /// «Разрешить действия» снимается сразу у ролей этого подключения
  /// (ADR-013) — разрешение привязано к входу.
  void _onSessionChanged() {
    if (!mounted) return;
    // «на связи» / «нет связи» в меню и «Сегодня».
    setState(() {});
    if (!_settingsLoaded) return;
    final pruned = _prunedActions(_settings, drop: true);
    if (pruned != null) _changeSettings(pruned);
  }

  /// Настройки без разрешений действий, которые больше не годятся:
  /// [drop] — снять у всех ролей с подключением (вход сменился), иначе —
  /// только если подключение не под тем логином или не под своим ключом.
  /// `null` — менять нечего.
  AppSettings? _prunedActions(AppSettings settings, {bool drop = false}) {
    var choice = settings.extensionChoice;
    var changed = false;
    for (final MapEntry(key: roleId, value: login)
        in choice.roleActions.entries.toList()) {
      final role = widget.assistant.extensions.role(roleId);
      final link = role?.connection;
      final service = link == null
          ? null
          : widget.connections
              .where((ConnectionService c) => c.slot.id == link.extensionId)
              .firstOrNull;
      final record = service?.record;
      final valid = !drop &&
          role?.actionHint != null &&
          record != null &&
          record.level == ConnectionLevel.staff &&
          record.failure != ConnectionFailure.expired &&
          (record.login ?? '').toLowerCase() == login.toLowerCase();
      if (!valid) {
        choice = choice.withActions(roleId, null);
        changed = true;
      }
    }
    return changed ? settings.withChoice(choice) : null;
  }

  /// Включает и выключает расширения сразу, без перезапуска: история
  /// чата, задачи, выбранная задача и черновик в поле ввода не меняются.
  void _applyExtensions(AppSettings settings) {
    widget.assistant.extensions.apply(settings.extensionChoice);
  }

  /// Новые настройки применяются сразу и ничего не сбрасывают: история
  /// (с авторами и текстами), задачи, выбор, черновик, адресат и ожидание
  /// подтверждения остаются. Ответ, который уже готовится, договаривается
  /// прежним голосом.
  void _changeSettings(AppSettings settings) {
    _applyExtensions(settings);
    widget.assistant.personas = settings.personas;
    setState(() => _settings = settings);
    unawaited(_settingsStore.save(settings));
  }

  /// Второй помощник (в соло — единственный) пишет первым о просроченных
  /// задачах: при открытии и при смене дня, не чаще раза в день. День
  /// запоминается в настройках, поэтому ни перезапуск, ни смена настроек
  /// помощников сообщение не повторяют.
  void _maybeNotice() {
    if (!mounted ||
        !_settingsLoaded ||
        !_chatsLoaded ||
        !_loaded ||
        _loadError != null) {
      return;
    }
    _maybeFirstSeen();
    // Пока готовится ответ, напоминание не вклиниваем между командой и
    // ответом: после ответа _send вызовет _refresh → _maybeNotice.
    if (_sending) return;
    final now = _now;
    final today = AppSettings.dayKey(now);
    _scheduleTrainingNotice();
    if (_noticeChecked == today) return;
    _noticeChecked = today;
    if (_settings.noticeDay == today) return;
    final overdue = _active.where((Task t) => isOverdue(t, now)).toList();
    final notice = widget.assistant.overdueNotice(overdue);
    if (notice == null) return;
    // Напоминание — в главный чат; если открыт другой, у главного точка
    // «не прочитано» в меню.
    setState(() {
      _pristineWelcome = false;
      _book.append(ChatThread.mainId, _answer(notice));
    });
    _changeSettings(_settings.copyWith(noticeDay: today));
  }

  /// Первый день с Связным для «Вместе N дней»: самая ранняя дата из
  /// задач и сессий или сегодня. Записывается один раз.
  void _maybeFirstSeen() {
    if (_settings.firstSeenDay != null) return;
    var first = _now;
    for (final task in _all) {
      if (task.createdAt.isBefore(first)) first = task.createdAt;
    }
    final chats = _book.earliestActivity;
    if (chats != null && chats.isBefore(first)) first = chats;
    _changeSettings(
      _settings.copyWith(firstSeenDay: AppSettings.dayKey(first.toLocal())),
    );
  }

  Future<void> _refresh() async {
    final creations = _chatCreations;
    var chatRemoved = false;
    try {
      final active = await widget.tasks.listActive();
      final all = await widget.tasks.listAll();
      final completed = await widget.tasks.listCompleted();
      if (!mounted) return;
      setState(() {
        _active = active;
        _all = all;
        _completed = completed;
        _loadError = null;
        _loaded = true;
        _dataRevision.value++;
        // Чаты удалённых задач удаляются; выполненных — остаются. Пока
        // список читался, могли создать чат новой задачи: тогда не трогаем.
        if (_book.loaded && creations == _chatCreations) {
          chatRemoved = _book.prune(<String>{
            for (final task in all) task.id,
          });
        }
      });
      if (chatRemoved) _onChatChanged();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error;
        _loaded = true;
      });
    }
    await _syncDocument();
    _scheduleTick();
    _maybeNotice();
  }

  /// Перерисовка к полуночи и к сроку ближайшей задачи со временем, чтобы
  /// «сегодня» и «просрочено» не устаревали, пока приложение открыто.
  void _scheduleTick() {
    _tick?.cancel();
    if (!mounted) return;
    final now = _now;
    var next = DateTime(now.year, now.month, now.day + 1);
    for (final task in _active) {
      // Для даты без времени момент — полночь, она уже в `next`.
      final due = overdueMoment(task);
      if (task.duePrecision != DuePrecision.date &&
          due != null &&
          due.isAfter(now) &&
          due.isBefore(next)) {
        next = due;
      }
    }
    _tick = Timer(next.difference(now) + const Duration(seconds: 1), () {
      if (!mounted) return;
      setState(() {});
      // Новый день: свежий список задач, и второй помощник может написать
      // о просроченных (_refresh → _maybeNotice).
      unawaited(_refresh());
    });
  }

  /// Задача, с которой работает помощник: в чате задачи — она сама, в
  /// главном — выбранная («её»).
  Task? get _selectedTask =>
      _findTask(_book.current.taskId ?? widget.assistant.selectedTaskId);

  Task? _findTask(String? id) {
    if (id == null) return null;
    for (final task in _all) {
      if (task.id == id) return task;
    }
    return null;
  }

  // ------------------------------------------------------------- команды

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || _sending) return;
    if (!_settingsLoaded || !_chatsLoaded) {
      // Настройки или чаты ещё читаются: ждём их, иначе ответит помощник
      // по умолчанию, а не выбранный, и сообщение затрётся историей с
      // диска. Повторная отправка в это время — нет.
      _sending = true;
      try {
        await _settingsReady;
      } on Object {
        // Не прочитались — отвечаем с настройками по умолчанию.
      }
      try {
        await _chatsReady;
      } on Object {
        // Чаты не прочитались — пишем в пустые.
      }
      _sending = false;
      if (!mounted) return;
    }
    _cubeTimer?.cancel();
    // Чат и голос фиксируются сейчас: ответ придёт в этот чат, даже если
    // пользователь успеет открыть другой, а смена настроек во время ответа
    // применится со следующего сообщения. Кому отвечать, решает помощник
    // сам: ведущий роли, обращение по имени и продолжение разговора с тем,
    // к кому обратились ([AssistantController.handle]).
    final chatId = _book.currentId;
    final chatTaskId = _book.current.taskId;
    // Команда из режима «Документ»: ответ — в историю сессии, а на экране
    // — короткое уведомление, документ остаётся открытым.
    final fromDocument = _mode == AssistantViewMode.document;
    // Код входа из ссылки («#qr=…») в историю чата и команд не пишем.
    // Пароль, вставленный в чат (D12), — тоже: он скрыт до истории, списка
    // команд, «обрабатывается…» и маршрутизатора, а сам токен выброшен.
    final guard = SecretGuard.redact(
      LoginLinks.redact(text),
      known: widget.assistant.knownSecret,
    );
    final shown = guard.text;
    final secret = guard.guarded;
    final command = ChatMessage(
      id: _book.newMessageId(),
      author: ChatAuthor.user,
      text: shown,
      timestamp: _now,
    );
    setState(() {
      _sending = true;
      _pristineWelcome = false;
      _cube = CubeState.working;
      _working = _answer(
        widget.assistant.working(
          secret ? shown : text,
          secretRedacted: secret,
        ),
        withStatus: false,
      );
      _workingChatId = chatId;
      _book.append(chatId, command);
      _commands.add(shown);
      _commandCursor = null;
      if (preset == null) _input.clear();
    });
    _scrollToLatest();
    await _saveDocument();
    final response = await widget.assistant.handle(
      secret ? shown : text,
      chatTaskId: chatTaskId,
      secretRedacted: secret,
    );
    if (!mounted) return;
    // «Говори короче», «давай на ты»: тот же путь, что у экрана настроек,
    // — к настройкам на сейчас, с сохранением в settings.json.
    final change = response.settingsChange;
    if (change != null) {
      _changeSettings(
        _settings.copyWith(personas: change.apply(_settings.personas)),
      );
    }
    // Ответ о новой (или уже существующей) задаче ведёт в её чат.
    final task = response.task;
    final aboutTask = response.intent == 'task.create' && task != null;
    var reply = _answer(response);
    if (aboutTask) {
      reply = reply.withLink(
        ChatLink(chatId: ChatThread.taskChatId(task.id), taskId: task.id),
      );
    }
    setState(() {
      _sending = false;
      _working = null;
      _workingChatId = null;
      _cube = cubeStateFor(response.status);
      _book.append(chatId, reply);
      if (aboutTask &&
          response.status == AssistantStatus.completed &&
          _book.taskThread(task.id) == null) {
        // Новая задача: её чат начинается с команды и ответа.
        _chatCreations++;
        _book.onTaskCreated(
          task.id,
          fromChatId: chatId,
          command: command,
          reply: reply,
        );
      }
    });
    _cubeTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted && !_sending) setState(() => _cube = CubeState.idle);
    });
    if (fromDocument &&
        _mode == AssistantViewMode.document &&
        _section == AppSection.session &&
        chatId == _book.currentId) {
      _announceReply(reply, response);
    }
    _scrollToLatest();
    _inputFocus.requestFocus();
    await _refresh();
  }

  /// Ответ на команду из режима «Документ» — коротким уведомлением над
  /// полем ввода, поверх низа документа (не закрывает поле и кнопки под
  /// ним): в ленте ответа сейчас не видно. Текст — тот же, что в ленте
  /// (уже прошёл [SecretGuard] на входе и выходной фильтр помощника). Ответ
  /// с карточкой (пароли, действие склада, список) или от навыка с
  /// секретами в уведомление не попадает: «Ответ в диалоге».
  void _announceReply(ChatMessage reply, AssistantResponse response) {
    final sensitive = reply.secureCard != null ||
        reply.card != null ||
        reply.checklist != null ||
        response.secureCard != null ||
        response.intent.startsWith('passwords') ||
        response.intent.startsWith('secret') ||
        _sensitiveConnector(widget.assistant.session.lastConnectorId);
    _docToastTimer?.cancel();
    setState(() => _docToast = sensitive ? 'Ответ в диалоге' : reply.text);
    _docToastTimer = Timer(const Duration(seconds: 4), _hideDocToast);
  }

  /// Уведомление об ответе в «Документе»: текст или `null` — не показано.
  String? _docToast;
  Timer? _docToastTimer;

  void _hideDocToast() {
    _docToastTimer?.cancel();
    _docToastTimer = null;
    if (mounted && _docToast != null) setState(() => _docToast = null);
  }

  /// Навык с секретами (пароли): его ответы не показываем уведомлением.
  bool _sensitiveConnector(String? id) {
    if (id == null) return false;
    return widget.assistant.connectors
        .any((ConnectorInfo info) => info.id == id && info.sensitive);
  }

  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _chatScroll.hasClients) _chatScroll.jumpTo(0);
    });
  }

  void _insertTemplate(CommandTemplate template) =>
      _applyTemplate(template.template);

  void _applyTemplate(String template) {
    final cursor = template.indexOf('|');
    final text = template.replaceFirst('|', '');
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
        offset: cursor < 0 ? text.length : cursor,
      ),
    );
    if (_section != AppSection.session) {
      setState(() => _section = AppSection.session);
    }
    _inputFocus.requestFocus();
  }

  String? _previousCommand() {
    if (_commands.isEmpty) return null;
    if (_commandCursor == null) _draftBeforeRecall = _input.text;
    final cursor = _commandCursor == null
        ? _commands.length - 1
        : (_commandCursor! - 1).clamp(0, _commands.length - 1);
    _commandCursor = cursor;
    return _commands[cursor];
  }

  String? _nextCommand() {
    final cursor = _commandCursor;
    if (cursor == null) return null;
    if (cursor + 1 >= _commands.length) {
      _commandCursor = null;
      return _draftBeforeRecall;
    }
    _commandCursor = cursor + 1;
    return _commands[cursor + 1];
  }

  /// Прокручивает чат к команде. Лента строится лениво, поэтому старая
  /// команда может ещё не существовать: прокручиваем шагами вверх, пока она
  /// не появится, и затем выравниваем её.
  Future<void> _jumpToCommand(int commandIndex) async {
    var seen = -1;
    var messageIndex = -1;
    for (var i = 0; i < _messages.length; i++) {
      if (!_messages[i].fromUser) continue;
      if (++seen == commandIndex) {
        messageIndex = i;
        break;
      }
    }
    if (messageIndex < 0) return;
    setState(() => _highlightedCommand = commandIndex);
    final key = _messageKeys.putIfAbsent(messageIndex, GlobalKey.new);
    for (var step = 0; step < 200 && key.currentContext == null; step++) {
      if (!_chatScroll.hasClients) return;
      final position = _chatScroll.position;
      if (position.pixels >= position.maxScrollExtent) break;
      _chatScroll.jumpTo(
        (position.pixels + position.viewportDimension * .8)
            .clamp(0, position.maxScrollExtent),
      );
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    final context = key.currentContext;
    if (context != null && context.mounted) {
      await Scrollable.ensureVisible(
        context,
        alignment: .3,
        duration: _motion(const Duration(milliseconds: 240)),
      );
    }
  }

  /// «Очистить историю сессий»: сессии и чаты задач удаляются, главный
  /// начинается с приветствия. Задачи не меняются.
  void _clearChat() {
    // Вопрос со списком снимается, отменить прежние массовые изменения
    // из чата больше нельзя.
    widget.assistant.clearConversation();
    unawaited(_book.clearAll());
    widget.assistant
      ..forgetChatSelections()
      ..enterChat();
    setState(() {
      _book.append(ChatThread.mainId, _welcome());
      _pristineWelcome = false;
      _messageKeys.clear();
      _commands.clear();
      _commandCursor = null;
      _highlightedCommand = null;
      // Чатов на диске больше нет: активность — по тому, что в памяти.
      _storedChats = <String, List<ChatMessage>>{};
    });
  }

  // --------------------------------------------------- массовые команды

  /// Ответ на карточку массовой команды готовится: кнопки не нажимаются
  /// второй раз.
  bool _bulkBusy = false;

  /// Галочка в карточке — не сообщение: вопрос ждёт ответа дальше.
  void _toggleBulkItem(BulkChecklist checklist, String taskId, bool value) {
    setState(() {
      widget.assistant.setBulkItemChecked(checklist, taskId, value);
    });
  }

  void _setAllBulkItems(BulkChecklist checklist, bool value) {
    setState(() => widget.assistant.setAllBulkItems(checklist, value));
  }

  /// «Перенести (N)» / «Отмена»: как «да» или «нет» в чате. Итог виден в
  /// самой карточке.
  Future<void> _answerBulk(BulkChecklist checklist, {required bool apply}) =>
      _bulkAction(() => widget.assistant.answerBulk(checklist, apply: apply));

  Future<void> _undoBulk(BulkChecklist checklist, String? personaId) =>
      _bulkAction(
        () => widget.assistant.undoBulk(checklist, personaId: personaId),
      );

  Future<void> _bulkAction(
    Future<AssistantResponse?> Function() action,
  ) async {
    if (_bulkBusy || _sending) return;
    setState(() => _bulkBusy = true);
    AssistantResponse? response;
    try {
      response = await action();
    } finally {
      if (mounted) setState(() => _bulkBusy = false);
    }
    if (!mounted) return;
    if (response != null) {
      setState(() => _cube = cubeStateFor(response!.status));
      _cubeTimer?.cancel();
      _cubeTimer = Timer(const Duration(milliseconds: 1600), () {
        if (mounted && !_sending) setState(() => _cube = CubeState.idle);
      });
    }
    await _refresh();
  }

  /// Кнопки карточки действия (ADR-013): ответ склада — сообщением в
  /// чат, где карточка; итог виден и в самой карточке. Пока ответ
  /// готовится, кнопки не нажимаются второй раз.
  Future<void> _cardAction(
    Future<AssistantResponse?> Function() action,
  ) async {
    if (_bulkBusy || _sending) return;
    final chatId = _book.currentId;
    setState(() => _bulkBusy = true);
    AssistantResponse? response;
    try {
      response = await action();
    } finally {
      if (mounted) setState(() => _bulkBusy = false);
    }
    if (!mounted) return;
    if (response != null) {
      final reply = _answer(response);
      setState(() {
        _cube = cubeStateFor(response!.status);
        _book.append(chatId, reply);
      });
      _cubeTimer?.cancel();
      _cubeTimer = Timer(const Duration(milliseconds: 1600), () {
        if (mounted && !_sending) setState(() => _cube = CubeState.idle);
      });
      _scrollToLatest();
    } else {
      setState(() {});
    }
  }

  // ------------------------------------------------------------- задачи

  // --------------------------------------------------------------- чаты

  /// Открывает чат задачи [task] (создаёт его при первом открытии). [mode]
  /// — режим после открытия; `null` — прежний (панель «Активные» не
  /// переключает документ на диалог). Повторное нажатие на задачу открытого
  /// чата ничего не меняет.
  void _openTaskChat(Task task, {AssistantViewMode? mode}) {
    if (_book.current.taskId == task.id) {
      // Тот же чат: только вернуться в сессию из раздела — контекст
      // помощника (ожидание ответа, «её») не сбрасывается.
      _closeDrawers();
      _showSession();
      if (mode != null && mode != _mode) _setMode(mode);
      return;
    }
    _chatCreations++;
    _switchChat(() => _book.openTask(task.id), mode: mode);
  }

  /// Открывает чат [chatId] в «Диалоге». Тот же чат в «Документе» тоже
  /// переключается на «Диалог»: в документе ленты нет, и карточка, ради
  /// которой пришли (например, из «Сводки»), иначе не видна.
  void _openChat(String chatId) {
    if (chatId == _book.currentId) {
      _closeDrawers();
      _showSession();
      if (_mode != AssistantViewMode.dialogue) {
        _setMode(AssistantViewMode.dialogue);
      }
      return;
    }
    _switchChat(() => _book.open(chatId), mode: AssistantViewMode.dialogue);
  }

  void _showSession() {
    if (_section == AppSection.session) return;
    unawaited(_saveDocument());
    setState(() => _section = AppSection.session);
  }

  /// «Назад» из чата задачи: к предыдущему чату, иначе в главный.
  void _goBack() => _switchChat(_book.back);

  /// Переключение сразу: сообщения незагруженного чата появятся, когда
  /// прочитаются.
  void _switchChat(
    Future<ChatThread> Function() open, {
    AssistantViewMode? mode,
  }) {
    _closeDrawers();
    unawaited(_saveDocument());
    final wasLoaded = _book.loaded;
    final loading = open();
    if (wasLoaded) _onChatChanged(mode: mode);
    unawaited(
      loading.then((_) {
        if (!mounted) return;
        if (wasLoaded) {
          setState(() {});
        } else {
          _onChatChanged(mode: mode);
        }
      }),
    );
  }

  /// Открыт другой чат: контекст помощника («её», ожидание вопроса),
  /// документ и лента — по нему.
  void _onChatChanged({AssistantViewMode? mode}) {
    final current = _book.current;
    widget.assistant.enterChat(
      taskId: current.taskId,
      sessionId: current.isSession ? current.id : null,
    );
    setState(() {
      _section = AppSection.session;
      if (mode != null) _mode = mode;
      _messageKeys.clear();
      _highlightedCommand = null;
      _docToast = null;
    });
    unawaited(_syncDocument());
    _scrollToLatest();
  }

  void _closeDrawers() {
    final scaffold = _scaffoldKey.currentState;
    if (scaffold == null) return;
    if (scaffold.isDrawerOpen) scaffold.closeDrawer();
  }

  /// «Выполнено» / «Вернуть в работу» в шапке чата задачи: строка об этом
  /// — в чат голосом основного помощника.
  Future<void> _setDoneFromHeader(Task task, {required bool done}) async {
    final chatId = ChatThread.taskChatId(task.id);
    try {
      final updated = done
          ? await widget.tasks.complete(task.id)
          : await widget.tasks.reopen(task.id);
      if (done) widget.assistant.forgetTask(task.id);
      final line = widget.assistant.speak(
        Reply(
          done ? 'task.completed' : 'task.reopened',
          <String, String>{'title': updated.title},
        ),
        widget.assistant.personas.responder,
        intent: done ? 'task.complete' : 'task.reopen',
      );
      if (!mounted) return;
      setState(() => _book.append(chatId, _answer(line)));
      _scrollToLatest();
    } catch (error) {
      if (mounted) _announce('Не получилось: $error');
    }
    await _refresh();
  }

  Future<void> _toggleDone(Task task) async {
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    try {
      if (task.status == TaskStatus.done) {
        await widget.tasks.reopen(task.id);
        messenger.showSnackBar(
          SnackBar(content: Text('«${task.title}» снова в работе')),
        );
      } else {
        await widget.tasks.complete(task.id);
        widget.assistant.forgetTask(task.id);
        messenger.showSnackBar(
          SnackBar(
            content: Text('«${task.title}» — готово'),
            action: SnackBarAction(
              label: 'Отменить',
              onPressed: () async {
                await widget.tasks.reopen(task.id);
                await _refresh();
              },
            ),
          ),
        );
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Не получилось: $error')));
    }
    await _refresh();
  }

  void _announce(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 3)),
      );
  }

  // ------------------------------------------------------------ документ

  /// Есть правки, которые ещё не записаны (или запись не удалась).
  bool get _docPending =>
      _docState == DocumentSaveState.dirty ||
      _docState == DocumentSaveState.failed;

  /// Снимки правок, отправленных на запись, по задачам. Пока запись идёт,
  /// документ этой задачи открывается из снимка, а не из устаревших данных.
  final Map<String, _DocSnapshot> _docInFlight = <String, _DocSnapshot>{};

  _DocSnapshot? _currentSnapshot() {
    final id = _docTaskId;
    if (id == null) return null;
    return _DocSnapshot(id, _docTitle.text, _docProject.text, _docBody.text);
  }

  /// Документ показывает выбранную задачу и переключается сразу: правки
  /// прежней задачи уходят на запись из снимка, а не из полей ввода, поэтому
  /// ничего не попадает в чужую задачу даже при медленном диске.
  Future<void> _syncDocument() async {
    final selected = _selectedTask;
    if (selected?.id == _docTaskId) return;
    _docTimer?.cancel();
    final pending = _docPending ? _currentSnapshot() : null;
    final snapshot = selected == null ? null : _docInFlight[selected.id];
    _docLoading = true;
    _docTaskId = selected?.id;
    _docTitle.text = snapshot?.title ?? selected?.title ?? '';
    _docProject.text = snapshot?.project ?? selected?.project ?? '';
    _docBody.text = snapshot?.body ?? selected?.description ?? '';
    _docLoading = false;
    setState(() {
      _docState = DocumentSaveState.saved;
      _docSavedAt = null;
    });
    if (pending != null) await _enqueueSave(pending);
  }

  void _onDocumentEdited() {
    if (_docLoading || _docTaskId == null) return;
    final task = _findTask(_docTaskId);
    if (task != null &&
        task.title == _docTitle.text &&
        (task.project ?? '') == _docProject.text &&
        task.description == _docBody.text) {
      return;
    }
    if (_docState != DocumentSaveState.dirty) {
      setState(() => _docState = DocumentSaveState.dirty);
    }
    _docTimer?.cancel();
    _docTimer = Timer(const Duration(milliseconds: 800), _saveDocument);
  }

  /// Сохраняет открытый документ, если в нём есть несохранённые правки.
  Future<void> _saveDocument() async {
    _docTimer?.cancel();
    if (!_docPending) return;
    final snapshot = _currentSnapshot();
    if (snapshot == null) return;
    if (mounted) setState(() => _docState = DocumentSaveState.saving);
    await _enqueueSave(snapshot);
  }

  /// Записи идут строго по очереди. Результат меняет состояние документа,
  /// только если открыт документ той же задачи.
  Future<void> _enqueueSave(_DocSnapshot snapshot) {
    _docInFlight[snapshot.id] = snapshot;
    final save = _docSaves.then((_) => _write(snapshot));
    _docSaves = save.catchError((Object _) {});
    return save;
  }

  Future<void> _write(_DocSnapshot snapshot) async {
    final titleMissing = snapshot.title.trim().isEmpty;
    var failed = false;
    try {
      // Пустое название не сохраняется, но заметки и проект — сохраняются.
      await widget.tasks.updateDetails(
        snapshot.id,
        title: titleMissing ? null : snapshot.title,
        description: snapshot.body,
        project: snapshot.project,
      );
    } catch (_) {
      failed = true;
    }
    if (identical(_docInFlight[snapshot.id], snapshot)) {
      _docInFlight.remove(snapshot.id);
    }
    if (!mounted) return;
    if (_docTaskId == snapshot.id) {
      final current = _currentSnapshot()!;
      final changedMeanwhile = current != snapshot;
      setState(() {
        _docState = failed
            ? DocumentSaveState.failed
            : changedMeanwhile
                ? DocumentSaveState.dirty
                : titleMissing
                    ? DocumentSaveState.titleRequired
                    : DocumentSaveState.saved;
        if (!failed) _docSavedAt = _now;
      });
      if (!failed && changedMeanwhile) {
        _docTimer = Timer(const Duration(milliseconds: 800), _saveDocument);
      }
    } else if (failed) {
      _announce('Не удалось сохранить документ задачи — правки не записаны');
    }
    if (failed) return;
    try {
      final active = await widget.tasks.listActive();
      final all = await widget.tasks.listAll();
      if (mounted) {
        setState(() {
          _active = active;
          _all = all;
        });
      }
    } catch (_) {
      // Список обновится при следующем обновлении экрана.
    }
  }

  void _setMode(AssistantViewMode mode) {
    unawaited(_saveDocument());
    _docToastTimer?.cancel();
    setState(() {
      _mode = mode;
      _docToast = null;
    });
  }

  Duration _motion(Duration duration) =>
      _settings.reduceMotion || MediaQuery.of(context).disableAnimations
          ? Duration.zero
          : duration;

  // --------------------------------------------------------------- вёрстка

  /// Колонка «Сегодня» открыта на широком экране: выбор пользователя, а
  /// пока не выбирал — открыта от [todayOpenBreakpoint].
  bool _todayShown(double width) =>
      width >= wideBreakpoint && (_todayOpen ?? width >= todayOpenBreakpoint);

  /// Меню стоит колонкой слева.
  bool _sidebarShown(double width) => width >= wideBreakpoint && _sidebarOpen;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final width = constraints.maxWidth;
        final narrow = width < narrowBreakpoint;
        final wide = width >= wideBreakpoint;
        final sidebar = _sidebarShown(width);
        // В «Мой Связной» колонки «Сегодня» нет (D-Desk-Summary): году
        // активности нужна ширина. Выбор пользователя не меняется.
        final today = _section != AppSection.myRelay && _todayShown(width);
        final drawerWidth = (width - 56).clamp(240.0, 316.0);
        // Окно стало широким при открытом выдвижном меню: убирать его сразу
        // нельзя — у маршрута осталась бы запись «закрыть меню», и «Назад»
        // перестал бы возвращать в сессию. Держим его ещё кадр и закрываем
        // как обычно.
        final keepDrawer = sidebar && _drawerOpen;
        if (keepDrawer) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final scaffold = _scaffoldKey.currentState;
            if (scaffold != null && scaffold.isDrawerOpen) {
              scaffold.closeDrawer();
            }
          });
        }
        return PopScope(
          // «Назад» на телефоне из разделов и «Мой Связной» — в сессию.
          // Открытое меню «назад» только закрывает.
          canPop: _section == AppSection.session || _drawerOpen,
          onPopInvokedWithResult: (bool didPop, Object? _) {
            if (!didPop) _goTo(AppSection.session);
          },
          child: Scaffold(
            key: _scaffoldKey,
            onDrawerChanged: (bool open) => setState(() => _drawerOpen = open),
            backgroundColor: AssistantColors.background,
            drawerEdgeDragWidth: DrawerSwipe.edge,
            drawer: sidebar && !keepDrawer
                ? null
                : Drawer(
                    width: drawerWidth,
                    backgroundColor: AssistantColors.sidebar,
                    child: SafeArea(child: _buildDrawer(wide: false)),
                  ),
            body: SafeArea(
              child: Row(
                children: <Widget>[
                  if (sidebar) ...<Widget>[
                    SizedBox(
                      width: sidebarWidth,
                      child: _buildDrawer(wide: true),
                    ),
                    const VerticalDivider(width: 1),
                  ],
                  Expanded(
                    child: _buildWorkspace(
                      narrow: narrow,
                      wide: wide,
                      sidebar: sidebar,
                      today: today,
                    ),
                  ),
                  if (today) ...<Widget>[
                    const VerticalDivider(width: 1),
                    SizedBox(
                      width: todayWidth,
                      child: _buildTodayPanel(),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Меню на телефоне открыто: «назад» закрывает его.
  bool _drawerOpen = false;

  /// Ctrl/Cmd+K — поиск по сессиям, где бы ни был фокус: обработчик
  /// клавиатуры, а не CallbackShortcuts, которые срабатывают только при
  /// фокусе внутри HomePage. Пока поверх открыт другой экран — не
  /// срабатывает.
  bool _onHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.keyK ||
        !mounted) {
      return false;
    }
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isControlPressed && !keyboard.isMetaPressed) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    _focusSessionSearch(MediaQuery.sizeOf(context).width >= wideBreakpoint);
    return true;
  }

  /// Ctrl K: курсор в поиск по сессиям (меню открывается, если закрыто).
  void _focusSessionSearch(bool wide) {
    if (wide) {
      if (_sidebarOpen) {
        // Меню уже стоит колонкой: поле на месте, кадр не нужен.
        _sessionSearch.requestFocus();
        return;
      }
      setState(() => _sidebarOpen = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sessionSearch.requestFocus();
      });
      return;
    }
    _scaffoldKey.currentState?.openDrawer();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sessionSearch.requestFocus();
    });
  }

  // ----------------------------------------------------------------- меню

  Widget _buildDrawer({required bool wide}) {
    final now = _now;
    return RelayDrawer(
      wide: wide,
      onCollapse: wide ? () => setState(() => _sidebarOpen = false) : null,
      searchFocus: _sessionSearch,
      reduceMotion: _settings.reduceMotion,
      activeSection: switch (_section) {
        AppSection.tasks => 'tasks',
        AppSection.projects => 'projects',
        AppSection.planning => 'planning',
        _ => null,
      },
      sessions: _sessionEntries(now),
      extensions: _extensionEntries(),
      onOpenMyRelay: () => _openMyRelay(MyRelayTab.summary),
      onTasks: () => _goTo(AppSection.tasks),
      onProjects: () => _goTo(AppSection.projects),
      onPlanning: () => _goTo(AppSection.planning),
      onOpenSession: _openSessionEntry,
      onNewSession: _newSession,
      search: (String query) => _book.search(
        query,
        titles: <String, String>{for (final task in _all) task.id: task.title},
      ),
      onOpenHit: (ChatSearchHit hit) => _openSessionEntry(hit.chatId),
      timeLabel: (DateTime at) => sessionTimeLabel(at, _now),
    );
  }

  /// «Недавние сессии»: главный, сессии и чаты задач с сообщениями.
  List<SessionEntry> _sessionEntries(DateTime now) {
    final inSession = _section == AppSection.session;
    return <SessionEntry>[
      for (final thread in _book.sessions())
        if (_sessionEntry(thread, now, inSession) case final SessionEntry e) e,
    ];
  }

  SessionEntry? _sessionEntry(ChatThread thread, DateTime now, bool inSession) {
    final active = inSession && _book.currentId == thread.id;
    final time = sessionTimeLabel(thread.lastActivityAt, now);
    switch (thread.kind) {
      case ChatKind.main:
        return SessionEntry(
          id: thread.id,
          title: ChatBook.titleOf(thread),
          time: time,
          itemKey: const Key('chat-main'),
          dotKey: const Key('chat-unread-main'),
          active: active,
          unread: thread.unread,
        );
      case ChatKind.session:
        return SessionEntry(
          id: thread.id,
          title: ChatBook.titleOf(thread),
          time: time,
          itemKey: Key('chat-${thread.id}'),
          dotKey: Key('chat-unread-${thread.id}'),
          active: active,
          unread: thread.unread,
        );
      case ChatKind.task:
        final task = _findTask(thread.taskId);
        if (task == null) return null;
        return SessionEntry(
          id: thread.id,
          title: task.title,
          time: time,
          itemKey: Key('chat-${task.id}'),
          dotKey: Key('chat-unread-${task.id}'),
          active: active,
          unread: thread.unread,
          muted: task.status == TaskStatus.done,
        );
    }
  }

  void _openSessionEntry(String chatId) {
    final thread = _book.thread(chatId);
    final task =
        thread?.kind == ChatKind.task ? _findTask(thread!.taskId) : null;
    if (task != null) {
      _openTaskChat(task, mode: AssistantViewMode.dialogue);
    } else {
      _openChat(chatId);
    }
  }

  /// Дерево «Расширения»: только включённые расширения со своим экраном.
  List<ExtensionEntry> _extensionEntries() {
    final passwords = widget.passwords;
    return <ExtensionEntry>[
      if (passwords != null && _passwordsEnabled)
        ExtensionEntry(
          id: AssistantController.passwordsId,
          title: 'Пароли',
          status: switch (passwords.state) {
            VaultState.notCreated => 'не создано',
            VaultState.locked => 'заперт',
            VaultState.unlocked => 'открыт',
            VaultState.disabled => 'выключен',
          },
          onTap: () {
            _closeDrawers();
            unawaited(_openPasswords());
          },
        ),
      for (final service in widget.connections)
        if (widget.assistant.extensions.isEnabled(service.slot.id))
          ExtensionEntry(
            id: service.slot.id,
            title: service.slot.title,
            status: service.connected ? 'на связи' : 'нет связи',
            statusColor: service.connected
                ? AssistantColors.success
                : AssistantColors.faint,
            dot: true,
            onTap: () {
              _closeDrawers();
              unawaited(_openConnection(service));
            },
          ),
    ];
  }

  Future<void> _openConnection(ConnectionService service) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => ConnectionScreen(
            service: service,
            onEnabledChanged: (bool value) {
              if (!mounted) return;
              _changeSettings(
                connectionChanged(
                  widget.assistant.extensions,
                  _settings,
                  service.slot.id,
                  connected: value,
                ),
              );
            },
          ),
        ),
      );

  /// «+» в меню: новая пустая сессия, режим «Диалог», курсор в поле ввода.
  void _newSession() {
    unawaited(_saveDocument());
    // Выбор («её») прежнего чата сохраняется за ним, новая сессия
    // начинается без выбора (AssistantController.enterChat).
    _switchChat(_book.newSession, mode: AssistantViewMode.dialogue);
    _inputFocus.requestFocus();
  }

  void _openMyRelay(MyRelayTab tab) {
    unawaited(_saveDocument());
    _closeDrawers();
    setState(() {
      _section = AppSection.myRelay;
      _myRelayTab = tab;
    });
    unawaited(_readStoredChats());
  }

  /// Один раз читает непрочитанные чаты: активность по сессиям точная, а
  /// не по index.json. Состояние книги не меняется.
  Future<void> _readStoredChats() async {
    if (_storedChats != null || _readingStored) return;
    _readingStored = true;
    await _chatsReady;
    final stored = await _book.readStored();
    _readingStored = false;
    if (!mounted) return;
    setState(() => _storedChats = stored);
  }

  RelayStats _relayStats() {
    final firstSeen = _settings.firstSeenDay;
    return RelayStats.compute(
      tasks: _all,
      sessionDays: _book.activityDays(
        stored: _storedChats ?? const <String, List<ChatMessage>>{},
      ),
      sessions: _book.sessionCount,
      firstSeen: firstSeen == null ? null : DateTime.tryParse(firstSeen),
      now: _now,
    );
  }

  // ------------------------------------------------------------ «Сегодня»

  /// Колонка «Сегодня» — только на компьютере. На телефоне её нет: дела
  /// на сегодня, просроченные и ждущие отметки карточки — в «Мой Связной»
  /// → «Сводка».
  Widget _buildTodayPanel() {
    final now = _now;
    final passwords = widget.passwords;
    return TodayPanel(
      now: now,
      tasks: todayTasks(_active, now),
      selectedId: _selectedTask?.id,
      loading: !_loaded,
      error: _loadError,
      onRetry: _refresh,
      emptyHint: _active.isEmpty ? emptyTasksHint : null,
      onOpenTask: (Task task) => _openTaskChat(task),
      onToggleDone: _toggleDone,
      onAllTasks: () => _goTo(AppSection.tasks),
      onClose: () => setState(() => _todayOpen = false),
      pending: <TodayPending>[
        for (final pending in _book.pendingCards(now))
          _todayPending(pending.chatId, pending.message),
      ],
      sections: <TodaySection>[
        TodaySection(
          id: 'projects',
          label: 'Проекты',
          onTap: () => _goTo(AppSection.projects),
        ),
        TodaySection(
          id: 'planning',
          label: 'Планирование',
          onTap: () => _goTo(AppSection.planning),
        ),
        if (passwords != null && _passwordsEnabled)
          TodaySection(
            id: 'passwords',
            label: 'Пароли',
            semantics: passwords.isUnlocked
                ? 'Пароли, сейф открыт'
                : 'Пароли, сейф заперт',
            onTap: () {
              _closeDrawers();
              unawaited(_openPasswords());
            },
          ),
        for (final service in widget.connections)
          if (widget.assistant.extensions.isEnabled(service.slot.id))
            TodaySection(
              id: service.slot.id,
              label: service.slot.title,
              semantics: '${service.slot.title}, '
                  '${service.connected ? 'на связи' : 'нет связи'}',
              dot: service.connected
                  ? AssistantColors.success
                  : AssistantColors.faint,
              onTap: () {
                _closeDrawers();
                unawaited(_openConnection(service));
              },
            ),
      ],
    );
  }

  TodayPending _todayPending(String chatId, ChatMessage message) {
    final card = message.card!;
    final persona = Personas.byId(message.personaId);
    final what = switch (card.kind) {
      ActionKind.post => 'Отметка прихода ждёт подтверждения',
      ActionKind.move => 'Перемещение ждёт подтверждения',
    };
    return TodayPending(
      id: card.id,
      title: what,
      subtitle: <String>[
        if (persona != null) persona.russianName,
        widget.assistant.extensions.skillTitle(card.connectorId).toLowerCase(),
      ].join(' · '),
      onTap: () => _openSessionEntry(chatId),
    );
  }

  /// «Показать «Сегодня»» в шапке (компьютер, колонка свёрнута).
  Widget _todayShowButton() => Semantics(
        label: 'Показать «Сегодня»',
        button: true,
        expanded: false,
        excludeSemantics: true,
        onTap: () => setState(() => _todayOpen = true),
        child: IconButton(
          key: const Key('today-show'),
          tooltip: 'Показать «Сегодня»',
          onPressed: () => setState(() => _todayOpen = true),
          style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
          icon: const Icon(
            Icons.view_sidebar_outlined,
            color: AssistantColors.text,
          ),
        ),
      );

  void _goTo(AppSection section) {
    unawaited(_saveDocument());
    setState(() => _section = section);
    if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
      Navigator.of(context).pop();
    }
    if (section != AppSection.session) unawaited(_refresh());
  }

  /// Выход из выбранной задачи в главном чате: выбор снимается, режим —
  /// «Диалог», курсор в поле ввода — можно сразу создавать новую задачу.
  void _exitTask() {
    unawaited(_saveDocument());
    setState(() {
      widget.assistant.clearSelection();
      _mode = AssistantViewMode.dialogue;
    });
    unawaited(_syncDocument());
    _inputFocus.requestFocus();
  }

  Widget _buildWorkspace({
    required bool narrow,
    required bool wide,
    required bool sidebar,
    required bool today,
  }) {
    if (_section == AppSection.myRelay) return _buildMyRelay();
    final selected = _selectedTask;
    final inSession = _section == AppSection.session;
    final chatTaskId = inSession ? _book.current.taskId : null;
    final inTaskChat = chatTaskId != null;
    final taskInFocus =
        !inTaskChat && inSession && selected != null && selected.isActive
            ? selected
            : null;
    final now = _now;
    final persona = _settings.personas.responder;
    final Widget? leading;
    if (inTaskChat || taskInFocus != null) {
      // В чате задачи слева — «назад» к предыдущему чату, при выбранной
      // задаче в главном — снять выбор; на телефоне он заменяет меню
      // (меню открывается и жестом от левого края).
      leading = IconButton(
        key: const Key('task-back'),
        tooltip: inTaskChat ? 'Назад' : 'Назад к сессии',
        onPressed: inTaskChat ? _goBack : _exitTask,
        style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
        icon: const Icon(Icons.chevron_left, size: 22),
      );
    } else if (!sidebar) {
      leading = IconButton(
        key: const Key('menu-button'),
        tooltip: 'Меню',
        onPressed: wide
            ? () => setState(() => _sidebarOpen = true)
            : () => _scaffoldKey.currentState?.openDrawer(),
        style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
        icon: const Icon(Icons.menu, color: AssistantColors.text),
      );
    } else {
      leading = null;
    }
    final Widget? title;
    if (inTaskChat) {
      title = _buildTaskChatHeader(chatTaskId, narrow: narrow);
    } else if (taskInFocus != null) {
      title = _TaskCrumb(
        task: taskInFocus,
        now: now,
        narrow: narrow,
        onOpenDocument: () => _setMode(AssistantViewMode.document),
        onOpenChat: () => _openTaskChat(
          taskInFocus,
          mode: AssistantViewMode.dialogue,
        ),
      );
    } else if (!inSession) {
      title = _SectionTitle(title: _section.title);
    } else {
      title = null;
    }
    final current = _book.current;
    final sessionTitle = current.kind == ChatKind.task
        ? (_findTask(current.taskId)?.title ?? 'Задача')
        : ChatBook.titleOf(current);
    final history = _historyEntries;
    // Material, а не ColoredBox: на нём рисуются подсветка и всплески
    // нажатий у ListTile и кнопок во всех разделах.
    final workspace = Material(
      color: AssistantColors.workspace,
      child: Column(
        children: <Widget>[
          SessionHeader(
            wide: wide || title != null,
            leading: leading,
            title: title,
            personaName: persona.russianName,
            onPersona: () => _openMyRelay(MyRelayTab.assistants),
            subtitle: wide ? 'сессия «$sessionTitle»' : null,
            // «Сегодня» — колонкой справа на компьютере; свёрнута — кнопка
            // в шапке. На телефоне кнопки нет: это «Мой Связной» → «Сводка».
            trailing: wide && !today ? _todayShowButton() : null,
            // Хроника команд — под названием сессии, по центру: ширину
            // ленты и поля ввода она не занимает. И в «Диалоге», и в
            // «Документе».
            below: inSession && history.isNotEmpty
                ? HistoryRail(
                    entries: history,
                    activeIndex: _highlightedCommand,
                    onSelect: _selectCommand,
                    // Полосы по одной — только на широком окне (мышь); на
                    // телефоне и планшете (палец) строка — одна кнопка
                    // списка.
                    compact: !wide,
                  )
                : null,
          ),
          const Divider(),
          Expanded(child: _buildSection()),
        ],
      ),
    );
    // Свайп вправо по сессии открывает меню (телефон). Поле ввода внизу —
    // вне жеста: там выделяют текст и двигают курсор.
    return DrawerSwipe(
      enabled: !sidebar && inSession,
      onOpen: wide
          ? () => setState(() => _sidebarOpen = true)
          : () => _scaffoldKey.currentState?.openDrawer(),
      child: workspace,
    );
  }

  /// Нажатие на полосу хроники: в «Документе» сначала «Диалог», потом
  /// переход к команде.
  void _selectCommand(int index) {
    if (_mode != AssistantViewMode.dialogue) {
      _setMode(AssistantViewMode.dialogue);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_jumpToCommand(index));
      });
      return;
    }
    unawaited(_jumpToCommand(index));
  }

  Widget _buildMyRelay() {
    final now = _now;
    final stats = _relayStats();
    final approximate = !_book.activityExact(
      _storedChats ?? const <String, List<ChatMessage>>{},
    );
    return MyRelayScreen(
      tab: _myRelayTab,
      onTabChanged: (MyRelayTab tab) => setState(() => _myRelayTab = tab),
      onBack: () => _goTo(AppSection.session),
      stats: stats.line,
      summary: RelaySummary(
        activity: stats.activityByDay,
        approximate: approximate,
        tasks: _active,
        now: now,
        pending: <TodayPending>[
          for (final pending in _book.pendingCards(now))
            _todayPending(pending.chatId, pending.message),
        ],
        onOpenTask: (Task task) =>
            _openTaskChat(task, mode: AssistantViewMode.dialogue),
        onAllTasks: () => _goTo(AppSection.tasks),
      ),
      activity: RelayActivity(
        activity: stats.activityByDay,
        approximate: approximate,
        completed: _completed,
        now: now,
        onReopen: (Task task) => unawaited(_reopenFromActivity(task)),
      ),
      assistants: RelayAssistants(
        settings: _settings,
        onChanged: _changeSettings,
        registry: widget.assistant.extensions,
        onOpenRoles: () => setState(() => _myRelayTab = MyRelayTab.settings),
      ),
      settings: SettingsScreen(
        settings: _settings,
        onChanged: _changeSettings,
        onClearChat: _clearChat,
        messageCount: _book.totalMessages,
        extensions: widget.assistant.extensions,
        connections: widget.connections,
        passwords: widget.passwords,
        showTitle: false,
        includePersonas: false,
        onOpenStorage: () => unawaited(
          Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (BuildContext context) => Scaffold(
                backgroundColor: AssistantColors.workspace,
                appBar: AppBar(
                  backgroundColor: AssistantColors.workspace,
                  title: const Text('Данные и резервная копия'),
                ),
                // Маршрут не перестраивается вместе с HomePage: список
                // архива и счётчики обновляются по [_dataRevision].
                body: ValueListenableBuilder<int>(
                  valueListenable: _dataRevision,
                  builder: (BuildContext context, int _, Widget? __) =>
                      _buildStorage(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _reopenFromActivity(Task task) async {
    String message;
    try {
      await widget.tasks.reopen(task.id);
      await _refresh();
      message = '«${task.title}» снова в работе';
    } on Object catch (error) {
      message = 'Не удалось: $error';
    }
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _buildStorage() => StorageScreen(
        info: widget.storage,
        activeCount: _active.length,
        completed: _completed,
        now: _now,
        chatCount:
            _book.threads.where((ChatThread t) => t.messageCount > 0).length,
        onReopen: (Task task) async {
          await widget.tasks.reopen(task.id);
          await _refresh();
        },
      );

  Widget _buildTaskChatHeader(String taskId, {required bool narrow}) {
    final task = _findTask(taskId);
    return TaskChatHeader(
      task: task,
      now: _now,
      narrow: narrow,
      onDone: () {
        if (task != null) unawaited(_setDoneFromHeader(task, done: true));
      },
      onReopen: () {
        if (task != null) unawaited(_setDoneFromHeader(task, done: false));
      },
      onReschedule: () {
        if (_mode != AssistantViewMode.dialogue) {
          _setMode(AssistantViewMode.dialogue);
        }
        _applyTemplate('Перенеси на |');
      },
      onOpenDocument: () => _setMode(AssistantViewMode.document),
    );
  }

  Widget _buildSection() {
    final now = _now;
    final selectedId = _selectedTask?.id;
    // Задача из списков открывается своим чатом, в режиме «Диалог»;
    // документ — кнопкой в шапке чата.
    void open(Task task) =>
        _openTaskChat(task, mode: AssistantViewMode.dialogue);
    switch (_section) {
      case AppSection.projects:
        return ProjectsScreen(
          tasks: _active,
          now: now,
          selectedId: selectedId,
          onOpenTask: open,
          onToggleDone: _toggleDone,
        );
      case AppSection.planning:
        return PlanningScreen(
          tasks: _active,
          now: now,
          selectedId: selectedId,
          onOpenTask: open,
          onToggleDone: _toggleDone,
        );
      case AppSection.tasks:
        return _buildTasksPanel(withSearch: true);
      case AppSection.session:
      case AppSection.myRelay:
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) =>
              _buildConversationColumn(constraints.maxHeight),
        );
    }
  }

  Widget _buildConversationColumn(double height) {
    final current = _book.current;
    final hero = _mode == AssistantViewMode.dialogue &&
        current.isSession &&
        current.messageCount == 0 &&
        !_sending;
    return Column(
      children: <Widget>[
        Expanded(
          child: hero
              ? SessionHero(
                  persona: _settings.personas.responder,
                  note: _settings.personas.mode == AssistantMode.duo
                      ? SessionHero.noteFor(
                          <(String, Persona)>[
                            for (final role
                                in widget.assistant.extensions.activeRoles)
                              (
                                role.title,
                                widget.assistant.extensions
                                    .ownerOf(role.id, _settings.personas),
                              ),
                          ],
                          _settings.personas.main,
                        )
                      : null,
                )
              : _mode == AssistantViewMode.dialogue
                  ? _buildDialogue()
                  : _withDocToast(
                      DocumentView(
                        task: _selectedTask,
                        now: _now,
                        titleController: _docTitle,
                        projectController: _docProject,
                        bodyController: _docBody,
                        bodyFocus: _docBodyFocus,
                        saveState: _docState,
                        savedAt: _docSavedAt,
                        onSaveNow: _saveDocument,
                        onReopen: () {
                          final task = _selectedTask;
                          if (task != null) unawaited(_toggleDone(task));
                        },
                        onOpenTasks: () => _goTo(AppSection.tasks),
                      ),
                    ),
        ),
        // Свайп вправо по полю ввода и кнопкам меню не открывает.
        DrawerSwipeBlocker(child: _buildBottomArea(height)),
      ],
    );
  }

  /// Документ и, если есть, уведомление об ответе над его низом.
  Widget _withDocToast(Widget document) {
    final toast = _docToast;
    return Stack(
      children: <Widget>[
        Positioned.fill(child: document),
        if (toast != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 8,
            child: _chatColumn(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: chatInset),
                child: _DocToast(
                  key: const Key('doc-reply-toast'),
                  text: toast,
                  onDialogue: () => _setMode(AssistantViewMode.dialogue),
                  onClose: _hideDocToast,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildChat(double viewportHeight) {
    final rows = <Widget>[];
    DateTime? day;
    final latestAnswer = _messages.lastIndexWhere((m) => !m.fromUser);
    var commandIndex = -1;
    final commandIndexOf = <int, int>{};
    // Карточка списка — под последним ответом с этим списком: после
    // «кроме …» вопрос повторяется вместе с ней.
    final lastWithChecklist = <String, int>{};
    // Карточка действия — тоже под последним ответом с ней: «да» текстом
    // повторяет просьбу нажать кнопку вместе с карточкой.
    final lastWithCard = <String, int>{};
    for (var i = 0; i < _messages.length; i++) {
      if (_messages[i].fromUser) commandIndexOf[i] = ++commandIndex;
      final checklist = _messages[i].checklist;
      if (checklist != null) lastWithChecklist[checklist.id] = i;
      final card = _messages[i].card;
      if (card != null) lastWithCard[card.id] = i;
    }
    for (var i = 0; i < _messages.length; i++) {
      final message = _messages[i];
      final messageDay = DateTime(
        message.timestamp.year,
        message.timestamp.month,
        message.timestamp.day,
      );
      if (day != messageDay) {
        day = messageDay;
        rows.add(_DaySeparator(label: _dayLabel(messageDay)));
      }
      // Строка с карточкой паролей — с ключом: новое сообщение снизу не
      // пересоздаёт её (показанный пароль не гаснет от «был показан»).
      final key = message.fromUser
          ? _messageKeys.putIfAbsent(i, GlobalKey.new)
          : message.secureCard != null
              ? ValueKey<String>('secure-row-${message.id}')
              : null;
      final (linkLabel, linkKey) = _linkOf(message);
      rows.add(
        _MessageRow(
          key: key,
          message: message,
          // В чате задачи плитка самой задачи под ответами не нужна: она в
          // шапке.
          task: message.taskId == _book.current.taskId
              ? null
              : _findTask(message.taskId),
          now: _now,
          showTime: _settings.showTimestamps,
          highlighted: commandIndexOf[i] == _highlightedCommand,
          cube: i == latestAnswer && !_sending ? _cubeWidget() : null,
          selectedId: _selectedTask?.id,
          onOpenTask: (Task task) =>
              _openTaskChat(task, mode: AssistantViewMode.dialogue),
          onToggleDone: _toggleDone,
          linkLabel: linkLabel,
          linkKey: linkKey,
          onOpenLink:
              linkLabel == null ? null : () => _followLink(message.link!),
          checklist: _checklistCard(
                message,
                i,
                lastWithChecklist,
                viewportHeight,
              ) ??
              _actionCard(message, i, lastWithCard) ??
              _secureCard(message),
        ),
      );
    }
    final working = _working;
    if (_sending && working != null && _workingChatId == _book.currentId) {
      rows.add(
        _MessageRow(
          key: const Key('working-message'),
          message: working,
          now: _now,
          showTime: false,
          cube: _cubeWidget(),
          onOpenTask: (_) {},
          onToggleDone: (_) {},
        ),
      );
    }
    return _chatColumn(
      alignment: Alignment.topCenter,
      // Полоса прокрутки вставала между сообщениями и хроникой и читалась
      // как лишняя линия; к сообщениям ведёт хроника, колесо и тачпад.
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: ListView(
          key: const Key('chat-list'),
          controller: _chatScroll,
          reverse: true,
          padding: const EdgeInsets.fromLTRB(chatInset, 16, chatInset, 16),
          children: rows.reversed.toList(),
        ),
      ),
    );
  }

  /// Подпись и ключ ссылки под сообщением или `(null, null)`: «Открыть чат
  /// задачи» в главном чате, «из чата «Главный»» под копией в чате задачи.
  /// Ссылка на открытый чат или на удалённую задачу не показывается.
  (String?, Key?) _linkOf(ChatMessage message) {
    final link = message.link;
    if (link == null || link.chatId == _book.currentId) return (null, null);
    if (link.chatId == ChatThread.mainId) {
      return ('из сессии «Главный»', const Key('chat-origin-link'));
    }
    final task = _findTask(link.taskId);
    if (task == null) return (null, null);
    final current = _book.current;
    // Копия в чате задачи ведёт в чат задачи-родителя.
    if (!current.isMain && current.parentTaskId == task.id) {
      return ('из сессии «${task.title}»', const Key('chat-origin-link'));
    }
    return ('Открыть сессию задачи', Key('open-task-chat-${task.id}'));
  }

  void _followLink(ChatLink link) {
    final task = _findTask(link.taskId);
    if (link.chatId != ChatThread.mainId && task != null) {
      _openTaskChat(task, mode: AssistantViewMode.dialogue);
    } else {
      _openChat(link.chatId);
    }
  }

  Widget _buildDialogue() {
    // Карточке списка нужна высота видимой части чата, а не экрана.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) =>
          _buildChat(constraints.maxHeight),
    );
  }

  Widget? _checklistCard(
    ChatMessage message,
    int index,
    Map<String, int> lastWithChecklist,
    double viewportHeight,
  ) {
    final checklist = message.checklist;
    if (checklist == null || lastWithChecklist[checklist.id] != index) {
      return null;
    }
    return BulkChecklistCard(
      checklist: checklist,
      busy: _bulkBusy || _sending,
      viewportHeight: viewportHeight,
      onToggle: (String id, bool value) =>
          _toggleBulkItem(checklist, id, value),
      onSetAll: (bool value) => _setAllBulkItems(checklist, value),
      onApply: () => unawaited(_answerBulk(checklist, apply: true)),
      onCancel: () => unawaited(_answerBulk(checklist, apply: false)),
      onUndo: () => unawaited(_undoBulk(checklist, message.personaId)),
    );
  }

  Widget? _actionCard(
    ChatMessage message,
    int index,
    Map<String, int> lastWithCard,
  ) {
    final card = message.card;
    if (card == null || lastWithCard[card.id] != index) return null;
    return ActionCardView(
      card: card,
      busy: _bulkBusy || _sending,
      now: () => _now,
      onConfirm: () {
        // Карточка «ушла на запись» — в историю до запроса: закрыли
        // приложение посреди записи — после перезапуска «Проверить».
        final chatId = _book.currentId;
        card.onSending = () {
          _book.touch(chatId);
          return _book.flush();
        };
        unawaited(
          _cardAction(() => widget.assistant.answerCard(card, apply: true))
              .whenComplete(() => card.onSending = null),
        );
      },
      onCancel: () => unawaited(
        _cardAction(() => widget.assistant.answerCard(card, apply: false)),
      ),
      onSettle: () => unawaited(
        _cardAction(
          () => widget.assistant.settleCard(card, personaId: message.personaId),
        ),
      ),
    );
  }

  /// Временная карточка навыка «Пароли» (D10): только в памяти, после
  /// перезапуска её нет.
  Widget? _secureCard(ChatMessage message) {
    final card = message.secureCard;
    final passwords = widget.passwords;
    if (card == null || passwords == null) return null;
    return SecureCardView(
      card: card,
      kit: passwords,
      busy: _bulkBusy || _sending,
      onCommand: (
        SecureCardRequest card,
        String action, {
        String? entryId,
        String? detail,
      }) =>
          unawaited(
        _cardAction(
          () => widget.assistant.secureCardAction(
            card,
            action,
            entryId: entryId,
            detail: detail,
            personaId: message.personaId,
          ),
        ),
      ),
    );
  }

  bool get _passwordsEnabled =>
      widget.passwords != null &&
      widget.assistant.extensions.isEnabled(AssistantController.passwordsId);

  /// «Пароль» в быстрых действиях: те же три действия, что в «+».
  Future<void> _openPasswordActions() async {
    final action = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AssistantColors.raised,
      showDragHandle: true,
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final (index, label, icon) in <(int, String, IconData)>[
              (0, 'Найти пароль', Icons.key_outlined),
              (1, 'Сгенерировать пароль', Icons.password),
              (2, 'Добавить запись', Icons.add_moderator_outlined),
            ])
              ListTile(
                key: Key('password-action-$index'),
                minTileHeight: 52,
                leading: Icon(icon),
                title: Text(label),
                onTap: () => Navigator.of(context).pop(index),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 0:
        await _openPasswords();
      case 1:
        await _openGenerator();
      case 2:
        await _openPasswords(add: true);
    }
  }

  Future<void> _openGenerator() async {
    final passwords = widget.passwords;
    if (passwords == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => GeneratorScreen(kit: passwords),
      ),
    );
  }

  Future<void> _openPasswords({bool add = false}) async {
    final passwords = widget.passwords;
    if (passwords == null) return;
    if (!add || !passwords.isUnlocked) {
      await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (BuildContext context) =>
              PasswordsScreen(kit: passwords, unlockOnly: add),
        ),
      );
    }
    if (!add || !mounted || !passwords.isUnlocked) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => EntryEditorScreen(kit: passwords),
      ),
    );
  }

  /// Колонка чата: не шире [chatColumnWidth], по центру. Одна и та же для
  /// ленты сообщений и нижней части, поэтому их края совпадают. Хроника
  /// команд — в шапке (SessionHeader.below) и ширину не занимает.
  Widget _chatColumn({
    required AlignmentGeometry alignment,
    required Widget child,
    double? maxHeight,
  }) {
    return Align(
      alignment: alignment,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: chatColumnWidth,
          maxHeight: maxHeight ?? double.infinity,
        ),
        child: child,
      ),
    );
  }

  List<HistoryEntry> get _historyEntries => <HistoryEntry>[
        for (var i = 0; i < _messages.length; i++)
          if (_messages[i].fromUser)
            HistoryEntry(
              command: _messages[i].text,
              timestamp: _timeLabel(_messages[i].timestamp),
              result: i + 1 < _messages.length && !_messages[i + 1].fromUser
                  ? _messages[i + 1].text
                  : null,
            ),
      ];

  Widget _cubeWidget() => StatusCube(
        state: _cube,
        reduceMotion: _settings.reduceMotion,
        size: 14,
      );

  /// Нижняя часть: быстрые действия и поле ввода. Занимает не больше
  /// половины доступной высоты, чтобы лента сообщений не схлопнулась
  /// (клавиатура, горизонтальная ориентация); поле ввода, если не
  /// уместилось, прокручивается. Быстрым действиям достаётся то, что
  /// осталось от поля ввода ([QuickDock]): на обычном экране они
  /// переносятся по строкам и видны все, на узком с крупным шрифтом — одна
  /// строка с горизонтальной прокруткой, всегда на виду над полем ввода.
  Widget _buildBottomArea(double available) {
    final selected = _selectedTask;
    final compact = available < 420;
    const padding = EdgeInsets.fromLTRB(chatInset, 4, chatInset, 12);
    final maxHeight = available * .55;
    return _chatColumn(
      alignment: Alignment.bottomCenter,
      maxHeight: maxHeight,
      child: Padding(
        padding: padding,
        child: QuickDock(
          budget: maxHeight - padding.vertical,
          // Крупный шрифт — кнопкам нужно больше места на две строки;
          // не хватает — одна строка с прокруткой.
          minRoom:
              104 * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0),
          // В «Документе» — только поле ввода: ни быстрых действий, ни
          // кнопок ролей.
          actions: compact || _mode != AssistantViewMode.dialogue
              ? const SizedBox.shrink()
              : QuickActions(
                  // «Задача», «Напомнить», «Пароль» — только в новой
                  // сессии (крупные круглые кнопки); потом остаются лишь
                  // кнопки выбранной задачи и ролей.
                  big: !_messages.any((ChatMessage m) => m.fromUser),
                  hasSelection: selected != null && selected.isActive,
                  // Кнопки включённых ролей («Кладовщик»): пропадают, как
                  // только роль или её навык выключили.
                  roleChips: widget.assistant.extensions.activeChips,
                  sending: _sending,
                  onSend: _send,
                  onTemplate: _applyTemplate,
                  onPassword: _passwordsEnabled ? _openPasswordActions : null,
                ),
          composer: SingleChildScrollView(
            reverse: true,
            child: CommandComposer(
              controller: _input,
              focusNode: _inputFocus,
              sending: _sending,
              mode: _mode,
              onModeChanged: _setMode,
              onSend: _send,
              onTemplate: _insertTemplate,
              // Пункты навыка «Пароли» в «+» — пока он включён.
              extraActions: _passwordsEnabled
                  ? <ComposerAction>[
                      ComposerAction(
                        'Пароли',
                        Icons.key_outlined,
                        () => unawaited(_openPasswords()),
                      ),
                      ComposerAction(
                        'Сгенерировать пароль',
                        Icons.password,
                        () => unawaited(_openGenerator()),
                      ),
                      ComposerAction(
                        'Добавить запись',
                        Icons.add_moderator_outlined,
                        () => unawaited(_openPasswords(add: true)),
                      ),
                    ]
                  : const <ComposerAction>[],
              onDocumentSource: (DocumentSource source) => _announce(
                'Подключение «${source.label}» — следующий этап: '
                'документы будут создаваться и правиться через помощника.',
              ),
              onVoice: () => _announce(
                'Голосовой режим в разработке. Пока напишите команду '
                'текстом.',
              ),
              previousCommand: _previousCommand,
              nextCommand: _nextCommand,
            ),
          ),
        ),
      ),
    );
  }

  /// Экран «Задачи»: группы активных задач и поиск по ним.
  Widget _buildTasksPanel({bool withSearch = false}) {
    final Widget body;
    if (!_loaded) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_loadError != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text('Не удалось загрузить задачи'),
              const SizedBox(height: 4),
              Text(
                '$_loadError',
                style: technicalTextStyle,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _refresh,
                child: const Text('Повторить'),
              ),
            ],
          ),
        ),
      );
    } else if (_active.isNotEmpty && _visibleTasks.isEmpty) {
      body = EmptyState(
        icon: Icons.search_off,
        title: 'Ничего не нашлось',
        hint: 'По запросу «$_taskQuery» нет активных задач',
      );
    } else if (_active.isEmpty) {
      body = const EmptyState(
        icon: Icons.check_circle_outline,
        title: 'Активных задач нет',
        hint: emptyTasksHint,
      );
    } else {
      final now = _now;
      final selectedId = _selectedTask?.id;
      body = ListView(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        children: <Widget>[
          for (final (group, items)
              in groupTasks(_visibleTasks, now)) ...<Widget>[
            SectionLabel(
              '${group.title} · ${items.length}',
              danger: group == TaskGroup.overdue,
            ),
            for (final task in items)
              TaskTile(
                task: task,
                now: now,
                selected: task.id == selectedId,
                onTap: () => _openTaskChat(task),
                onToggleDone: () => _toggleDone(task),
              ),
          ],
        ],
      );
    }
    return Material(
      key: const Key('tasks-panel'),
      color: AssistantColors.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
            // Wrap, а не Row: при крупном системном шрифте счётчик уходит
            // на вторую строку, а не сжимает заголовок до буквы в строке.
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 4,
              children: <Widget>[
                const Text(
                  'Активные',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AssistantColors.textStrong,
                  ),
                ),
                Text(
                  _panelSummary(),
                  key: const Key('tasks-panel-summary'),
                  style: technicalTextStyle,
                ),
              ],
            ),
          ),
          if (withSearch)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: _SearchField(
                controller: _taskSearch,
                onChanged: (String value) =>
                    setState(() => _taskQuery = value.trim().toLowerCase()),
              ),
            ),
          Expanded(child: body),
        ],
      ),
    );
  }

  /// Активные задачи с учётом строки поиска (название или проект).
  List<Task> get _visibleTasks {
    final query = _taskQuery;
    if (query.isEmpty) return _active;
    final tag = query.replaceFirst('#', '');
    return _active
        .where(
          (Task task) =>
              task.title.toLowerCase().contains(query) ||
              (task.project ?? '').contains(tag),
        )
        .toList(growable: false);
  }

  String _panelSummary() {
    final overdue = _active.where((Task t) => isOverdue(t, _now)).length;
    final base = '${_active.length}';
    return overdue == 0 ? base : '$base · просрочено $overdue';
  }

  String _dayLabel(DateTime day) {
    final label = formatDay(day, _now);
    return label[0].toUpperCase() + label.substring(1);
  }

  static String _timeLabel(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';
}

// ------------------------------------------------------------------ части

final class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: <Widget>[
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(label, style: technicalTextStyle),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}

/// Ссылка на другой чат под сообщением. Текст переносится: при узком
/// экране и крупном шрифте подпись не обрезается.
final class _ChatLinkChip extends StatelessWidget {
  const _ChatLinkChip({
    super.key,
    required this.label,
    required this.origin,
    required this.onTap,
  });

  final String label;

  /// Ссылка назад, в чат, где создана задача (иначе — в чат задачи).
  final bool origin;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          constraints: const BoxConstraints(minHeight: 32),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            border: Border.all(color: AssistantColors.borderSoft),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Wrap(
            spacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Icon(
                origin ? Icons.subdirectory_arrow_left : Icons.forum_outlined,
                size: 14,
                color: AssistantColors.muted,
              ),
              Text(
                label,
                style: technicalTextStyle.copyWith(color: AssistantColors.text),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _MessageRow extends StatelessWidget {
  const _MessageRow({
    super.key,
    required this.message,
    required this.now,
    required this.showTime,
    required this.onOpenTask,
    required this.onToggleDone,
    this.task,
    this.cube,
    this.highlighted = false,
    this.selectedId,
    this.checklist,
    this.linkLabel,
    this.linkKey,
    this.onOpenLink,
  });

  final ChatMessage message;

  /// Ссылка на другой чат под сообщением: подпись, ключ и действие.
  final String? linkLabel;
  final Key? linkKey;
  final VoidCallback? onOpenLink;

  /// Карточка массовой команды под текстом ответа.
  final Widget? checklist;
  final Task? task;
  final DateTime now;
  final bool showTime;
  final Widget? cube;
  final bool highlighted;
  final String? selectedId;
  final ValueChanged<Task> onOpenTask;
  final ValueChanged<Task> onToggleDone;

  @override
  Widget build(BuildContext context) {
    final fromUser = message.fromUser;
    final status = message.status;
    final label = switch (status) {
      AssistantStatus.needsClarification => 'Уточните',
      AssistantStatus.failed => 'Ошибка',
      _ => null,
    };
    final labelColor = status == AssistantStatus.failed
        ? AssistantColors.danger
        : AssistantColors.warning;
    final current = task;
    final cube = this.cube;
    final author = fromUser ? null : Personas.byId(message.personaId);
    final content = Column(
      crossAxisAlignment:
          fromUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (author != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              key: ValueKey<String>('message-author-${author.id}'),
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                PersonaMark(persona: author, size: 16),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    author.russianName,
                    overflow: TextOverflow.ellipsis,
                    style: technicalTextStyle.copyWith(
                      color: Color(author.accentColor),
                    ),
                  ),
                ),
                // Кубик — состояние именно этого ответа, поэтому стоит в
                // строке автора, а не отдельным значком слева от текста.
                if (cube != null) ...<Widget>[
                  const SizedBox(width: 8),
                  cube,
                ],
              ],
            ),
          )
        else if (cube != null)
          Padding(padding: const EdgeInsets.only(bottom: 4), child: cube),
        if (label != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              label,
              style: technicalTextStyle.copyWith(color: labelColor),
            ),
          ),
        Container(
          padding: fromUser
              ? const EdgeInsets.symmetric(horizontal: 16, vertical: 8)
              : EdgeInsets.zero,
          decoration: BoxDecoration(
            color: fromUser ? AssistantColors.bubble : Colors.transparent,
            border: fromUser
                ? Border.all(
                    color: highlighted
                        ? AssistantColors.textStrong
                        : AssistantColors.border,
                    width: highlighted ? 1 : .5,
                  )
                : null,
            borderRadius: fromUser
                ? const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                    bottomLeft: Radius.circular(16),
                    bottomRight: Radius.circular(4),
                  )
                : BorderRadius.zero,
          ),
          child: SelectableText(
            message.text,
            style: TextStyle(
              fontSize: 14,
              height: 1.5,
              color:
                  fromUser ? AssistantColors.textStrong : AssistantColors.text,
            ),
          ),
        ),
        if (checklist != null) checklist!,
        if (current != null)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: AssistantColors.raised,
              border: Border.all(color: AssistantColors.borderSoft),
              borderRadius: BorderRadius.circular(12),
            ),
            child: TaskTile(
              task: current,
              now: now,
              dense: true,
              highlightSelected: false,
              selected: current.id == selectedId,
              onTap: () => onOpenTask(current),
              onToggleDone: () => onToggleDone(current),
            ),
          ),
        if (linkLabel != null && onOpenLink != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _ChatLinkChip(
              key: linkKey,
              label: linkLabel!,
              origin: linkKey == const Key('chat-origin-link'),
              onTap: onOpenLink!,
            ),
          ),
        if (showTime)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _HomePageState._timeLabel(message.timestamp),
              style: technicalTextStyle,
            ),
          ),
      ],
    );
    // Текст ответа начинается у левого края колонки — там же, где
    // быстрые действия и поле ввода; пузырь команды кончается у правого.
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Align(
        alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: content,
        ),
      ),
    );
  }
}

final class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: AssistantColors.textStrong,
        ),
      ),
    );
  }
}

/// Задача, с которой работает помощник («её»), — в верхней панели справа
/// от заголовка: «Задачи › Подготовить презентацию · завтра в 10:00».
final class _TaskCrumb extends StatelessWidget {
  const _TaskCrumb({
    required this.task,
    required this.now,
    required this.narrow,
    required this.onOpenDocument,
    required this.onOpenChat,
  });

  final Task task;
  final DateTime now;
  final bool narrow;
  final VoidCallback onOpenDocument;

  /// Открыть чат этой задачи.
  final VoidCallback onOpenChat;

  /// Меньше — строка «Задачи › «её»» и название в две строки, как на
  /// узком экране: рядом с поиском и кнопкой панели полной строке тесно.
  static const double _fullWidth = 480;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) =>
            _build(context, narrow || constraints.maxWidth < _fullWidth),
      );

  Widget _build(BuildContext context, bool narrow) {
    final due = task.dueAt;
    const titleStyle = TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      color: AssistantColors.textStrong,
    );
    final chatButton = IconButton(
      key: const Key('open-task-chat'),
      tooltip: 'Открыть сессию задачи',
      onPressed: onOpenChat,
      iconSize: 16,
      icon: const Icon(Icons.forum_outlined),
    );
    if (narrow) {
      // Две строки помещаются в панель высотой 56, только пока шрифт не
      // крупный; иначе остаётся название задачи, подпись — в подсказке.
      final Widget crumb;
      if (MediaQuery.textScalerOf(context).scale(1) > 1.3) {
        crumb = Tooltip(
          message: 'Задачи › «её»',
          child: Text(
            task.title,
            key: const Key('selected-task-strip'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          ),
        );
      } else {
        crumb = Column(
          key: const Key('selected-task-strip'),
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          // Плотные строки: две строки и в панели над узкой колонкой
          // помещаются в её высоту при любом шрифте.
          children: <Widget>[
            Text(
              'Задачи › «её»',
              maxLines: 1,
              style: technicalTextStyle.copyWith(height: 1.2),
            ),
            Text(
              task.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: titleStyle.copyWith(height: 1.25),
            ),
          ],
        );
      }
      return Row(children: <Widget>[Expanded(child: crumb), chatButton]);
    }
    return Row(
      children: <Widget>[
        const Text('Задачи', style: titleStyle),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 6),
          child: Icon(
            Icons.chevron_right,
            size: 16,
            color: AssistantColors.muted,
          ),
        ),
        Flexible(
          child: Container(
            key: const Key('selected-task-strip'),
            height: 36,
            padding: const EdgeInsets.only(left: 10, right: 2),
            decoration: BoxDecoration(
              color: AssistantColors.panel,
              border: Border.all(color: AssistantColors.borderSoft),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(
                  Icons.push_pin_outlined,
                  size: 14,
                  color: AssistantColors.textStrong,
                ),
                const SizedBox(width: 8),
                const Text('«её»', style: technicalTextStyle),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    task.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AssistantColors.textStrong,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (due != null) ...<Widget>[
                  const SizedBox(width: 8),
                  // Срок тоже сжимается: рядом с поиском места мало.
                  Flexible(
                    child: Text(
                      formatDue(due, task.duePrecision, now),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: technicalTextStyle,
                    ),
                  ),
                ],
                chatButton,
                IconButton(
                  tooltip: 'Открыть документ задачи',
                  onPressed: onOpenDocument,
                  iconSize: 16,
                  icon: const Icon(Icons.description_outlined),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Содержимое документа задачи в момент отправки на запись.
@immutable
final class _DocSnapshot {
  const _DocSnapshot(this.id, this.title, this.project, this.body);

  final String id;
  final String title;
  final String project;
  final String body;

  @override
  bool operator ==(Object other) =>
      other is _DocSnapshot &&
      other.id == id &&
      other.title == title &&
      other.project == project &&
      other.body == body;

  @override
  int get hashCode => Object.hash(id, title, project, body);
}

/// Поиск по задачам на экране «Задачи».
final class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480, minWidth: 160),
      child: SizedBox(
        height: 44,
        child: TextField(
          key: const Key('task-search'),
          controller: controller,
          onChanged: onChanged,
          style: const TextStyle(
            fontSize: 14,
            color: AssistantColors.textStrong,
          ),
          decoration: InputDecoration(
            isDense: true,
            labelText: 'Поиск по задачам…',
            floatingLabelBehavior: FloatingLabelBehavior.never,
            labelStyle: const TextStyle(
              fontSize: 14,
              color: AssistantColors.muted,
            ),
            prefixIcon: const Icon(
              Icons.search,
              size: 16,
              color: AssistantColors.muted,
            ),
            prefixIconConstraints: const BoxConstraints(minWidth: 36),
            suffixIcon: ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (BuildContext context, TextEditingValue value, _) =>
                  value.text.isEmpty
                      ? const SizedBox.shrink()
                      : IconButton(
                          tooltip: 'Очистить поиск',
                          iconSize: 16,
                          onPressed: () {
                            controller.clear();
                            onChanged('');
                          },
                          icon: const Icon(Icons.close),
                        ),
            ),
            filled: true,
            fillColor: AssistantColors.panel,
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AssistantColors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AssistantColors.muted),
            ),
          ),
        ),
      ),
    );
  }
}

/// Уведомление об ответе на команду из «Документа»: текст ответа (не
/// больше трёх строк) или «Ответ в диалоге», кнопка «Диалог» и крестик.
final class _DocToast extends StatelessWidget {
  const _DocToast({
    super.key,
    required this.text,
    required this.onDialogue,
    required this.onClose,
  });

  final String text;
  final VoidCallback onDialogue;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      container: true,
      child: Material(
        color: AssistantColors.raised,
        elevation: 4,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: AssistantColors.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    text,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.4,
                      color: AssistantColors.textStrong,
                    ),
                  ),
                ),
              ),
              TextButton(
                key: const Key('doc-reply-dialogue'),
                onPressed: onDialogue,
                style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
                child: const Text('Диалог'),
              ),
              IconButton(
                tooltip: 'Скрыть',
                onPressed: onClose,
                style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
