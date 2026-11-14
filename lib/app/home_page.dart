import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show OrdinalSortKey;
import 'package:flutter/services.dart';

import '../core/app_info.dart';
import '../core/chats/attachments.dart';
import '../core/chats/chat_book.dart';
import '../core/chats/chat_models.dart';
import '../core/chats/chat_projects.dart';
import '../core/chats/chat_search.dart';
import '../core/chats/chat_store.dart';
import '../core/cloud/cloud_disk.dart';
import '../core/commands/command_catalog.dart';
import '../core/commands/command_suggest.dart';
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
import '../core/skills/passwords/passwords_phrases.dart';
import '../core/stats/relay_stats.dart';
import '../core/storage/storage_info.dart';
import '../core/voice/voice_recognizer.dart';
import 'assistant_theme.dart';
import 'attachments/attachment_picker.dart';
import 'attachments/attachment_views.dart';
import 'passwords/entry_screens.dart';
import 'passwords/generator_view.dart';
import 'passwords/passwords_kit.dart';
import 'passwords/passwords_screen.dart';
import 'passwords/secure_card_view.dart';
import 'screens/my_relay_screen.dart';
import 'screens/my_relay_tabs.dart';
import 'screens/planning_screen.dart';
import 'screens/project_screen.dart';
import 'screens/projects_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/storage_screen.dart';
import 'shell/drawer_swipe.dart';
import 'shell/project_dialogs.dart';
import 'shell/quick_actions.dart';
import 'shell/relay_drawer.dart';
import 'shell/session_hold_menu.dart';
import 'shell/session_header.dart';
import 'shell/session_hero.dart';
import 'shell/today_panel.dart';
import 'voice/voice_kit.dart';
import 'voice/voice_views.dart';
import 'widgets/action_card_view.dart';
import 'widgets/bulk_checklist_card.dart';
import 'widgets/command_composer.dart';
import 'widgets/command_finder_sheet.dart';
import 'widgets/command_highlight.dart';
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
/// экран одного проекта-папки, планирование и «Мой Tridot».
enum AppSection { session, tasks, projects, project, planning, myRelay }

extension AppSectionInfo on AppSection {
  String get title => switch (this) {
        AppSection.session => 'Сессия',
        AppSection.projects => 'Проекты',
        AppSection.project => 'Проект',
        AppSection.tasks => 'Задачи',
        AppSection.planning => 'Планирование',
        AppSection.myRelay => AppInfo.hubName,
      };
}

/// Ширина, начиная с которой меню стоит постоянной колонкой слева, а
/// «Сегодня» — колонкой справа (три колонки, макет D-Desk). Уже — меню
/// выдвигается (кнопкой в шапке и свайпом вправо), а «Сегодня» отдельно
/// нет: всё оттуда — в «Мой Tridot» → «Сводка».
const double wideBreakpoint = 1000;

/// Ширина, начиная с которой колонка «Сегодня» открыта сразу; уже — она
/// свёрнута, пока её не откроют кнопкой «Показать «Сегодня»» в шапке.
const double todayOpenBreakpoint = 1280;

/// Ширина, ниже которой хроника команд — одна кнопка со списком.
const double narrowBreakpoint = 700;

/// Ширина постоянного меню и колонки «Сегодня» на широком экране.
const double sidebarWidth = 312;
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
    this.attachmentPicker = const FileSelectorAttachmentPicker(),
    this.voice,
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

  /// Выбор файлов для «+» → «Прикрепить файл» (ADR-019); в тестах —
  /// подделка.
  final AttachmentPicker attachmentPicker;

  /// Голосовой ввод (ADR-023): модель и распознаватель; `null` — на этой
  /// платформе движка нет, микрофон скрыт.
  final VoiceKit? voice;

  @override
  State<HomePage> createState() => _HomePageState();
}

final class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Поле ввода: распознанные части команды подсвечиваются по ходу
  /// набора (ADR-021).
  late final CommandInputController _input = CommandInputController(
    highlighter: widget.assistant.highlight,
  );
  final FocusNode _inputFocus = FocusNode();

  /// Подсветка отправленных команд в ленте: разбор один раз на текст
  /// сообщения, а не на каждую перерисовку.
  final Map<String, List<CommandSpan>> _spanCache =
      <String, List<CommandSpan>>{};

  /// Растёт после каждого чтения задач: открытые поверх маршруты
  /// («Данные и резервная копия») перестраиваются по нему.
  final ValueNotifier<int> _dataRevision = ValueNotifier<int>(0);
  final ScrollController _chatScroll = ScrollController();

  /// Прокрутка «Документа»: её двигает и хроника команд над ним.
  final ScrollController _docScroll = ScrollController();

  final TextEditingController _docTitle = TextEditingController();
  final TextEditingController _docProject = TextEditingController();
  final TextEditingController _docBody = TextEditingController();
  final FocusNode _docBodyFocus = FocusNode();

  late final SettingsStore _settingsStore =
      widget.settingsStore ?? InMemorySettingsStore();

  /// Все чаты: сессии и чаты задач (ADR-010, ADR-015). При старте открыта
  /// новая пустая сессия.
  late final ChatBook _book = ChatBook(
    store: widget.chatStore ?? InMemoryChatStore(),
    clock: widget.clock,
    // Название сессии из старой истории «Главного» — без секретов, как и
    // название из новой команды (_send).
    redactTitle: (String text) => SecretGuard.redact(
      LoginLinks.redact(text),
      known: widget.assistant.knownSecret,
    ).text,
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

  /// Настройки загружены: до этого помощник не пишет первым.
  bool _settingsLoaded = false;

  /// Загрузка настроек: сообщение, отправленное раньше, ждёт её, чтобы
  /// ответить голосом из настроек, а не голосом по умолчанию.
  late final Future<void> _settingsReady;

  /// «Команда обрабатывается…» от помощника, который сейчас отвечает.
  ChatMessage? _working;

  /// Чат, в котором ждут ответа [_working].
  String? _workingChatId;

  /// Файлы, выбранные для следующего сообщения (ADR-019).
  final List<_PendingFile> _pendingFiles = <_PendingFile>[];
  final Map<int, GlobalKey> _messageKeys = <int, GlobalKey>{};

  /// Команды открытого чата для ↑/↓ в поле ввода: у каждого чата своя
  /// история, а не общая на все сессии.
  List<String> get _commands => <String>[
        for (final message in _messages)
          if (message.fromUser && message.text.isNotEmpty) message.text,
      ];
  int? _commandCursor;

  /// Сообщение, к которому перешли из поиска: подсвечено, пока открыт
  /// этот чат.
  String? _highlightedMessageId;

  /// Строка сообщения из поиска — к ней прокручивается лента.
  final GlobalKey _hitRowKey = GlobalKey(debugLabel: 'search-hit-row');

  /// Сколько сессий показывает боковая панель: «Показать ещё» добавляет.
  int _sessionsShown = ChatBook.sessionsLimit;

  /// Черновик, который был в поле до листания истории стрелками.
  String _draftBeforeRecall = '';
  int? _highlightedCommand;

  AppSection _section = AppSection.session;

  /// Проект-папка, чей экран открыт ([AppSection.project]).
  String? _openProjectId;
  MyRelayTab _myRelayTab = MyRelayTab.summary;

  /// Сообщения непрочитанных чатов для точной активности в «Мой
  /// Tridot»: читаются один раз при первом открытии. `null` — ещё нет.
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

  /// Голосовой ввод (ADR-023): слушает, готовится (доступ, модель), что
  /// слышно сейчас. Звук и текст живут только в памяти.
  bool _voiceListening = false;
  bool _voiceLoading = false;
  String _voicePartial = '';

  /// Палец на микрофоне (или включено нажатием на компьютере).
  bool _voiceHeld = false;

  /// Начато нажатием (компьютер, Ctrl+Shift+M, экранный диктор), а не
  /// удержанием.
  bool _voiceToggle = false;

  /// Удержание короче [_voiceMinHold] — случайное касание.
  bool _voiceShort = false;
  Timer? _voiceShortTimer;
  static const Duration _voiceMinHold = Duration(milliseconds: 300);
  StreamSubscription<VoiceEvent>? _voiceEvents;
  bool _voiceOffering = false;

  /// Номер попытки: растёт при каждом начале и прерывании. Попытка, номер
  /// которой устарел, после любого `await` молча выходит — две попытки
  /// никогда не начинают слушать одновременно.
  int _voiceAttempt = 0;

  /// Идёт запрос доступа к микрофону: системный диалог делает приложение
  /// «неактивным», и это не повод прерывать попытку.
  bool _voiceAskingPermission = false;

  /// Подсказка голосового ввода над полем (вместо уведомления, которое
  /// закрыло бы микрофон).
  String? _voiceNotice;
  Timer? _voiceNoticeTimer;

  /// Палец держали дольше случайного касания, пока шла подготовка.
  Timer? _voiceHoldTimer;
  bool _voiceHeldLong = false;

  /// Лист загрузки скрыт, а модель ещё качается: о готовности скажем.
  bool _voiceAwaitInstall = false;

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
    widget.voice?.addListener(_onVoiceChanged);
    _preloadVoice();
    for (final controller in <TextEditingController>[
      _docTitle,
      _docProject,
      _docBody,
    ]) {
      controller.addListener(_onDocumentEdited);
    }
    // Первая пустая сессия — свой выбор («её») с самого начала: при
    // возврате в неё из чата задачи он восстановится.
    widget.assistant.enterChat(sessionId: _book.currentId);
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

  /// Пора потренировать пароль: строка в пустой сессии
  /// ([SessionHero.onTraining]). Сообщение в чат — только по нажатию.
  bool _trainingReady = false;

  /// Тренировка памяти паролей (5.8) — через «заметку дня», не в первые
  /// 30 с после запуска, не чаще раза в день и трёх раз в неделю. В
  /// `settings.json` — только дата.
  void _scheduleTrainingNotice() {
    if (_trainingTimer != null ||
        _trainingAsked ||
        _trainingReady ||
        !_passwordsEnabled) {
      return;
    }
    _trainingTimer = Timer(const Duration(seconds: 30), () {
      _trainingTimer = null;
      _checkTraining();
    });
  }

  /// Срок тренировки настал: в пустой сессии появляется строка о ней.
  void _checkTraining() {
    final passwords = widget.passwords;
    if (!mounted || passwords == null || !_passwordsEnabled) return;
    if (_trainingAsked || _trainingReady) return;
    final today = AppSettings.dayKey(_now);
    final due = _settings.passwordsTrainingDue;
    if (due == null || due.compareTo(today) > 0) return;
    if (passwords.isUnlocked &&
        !passwords.facade.trainingDue(passwords.vault.clock.now())) {
      return;
    }
    setState(() => _trainingReady = true);
  }

  /// Нажата строка «Пора потренировать пароль»: это команда человека —
  /// «Потренируй меня» уходит в открытую сессию обычным путём (сессия
  /// получает название и сохраняется, как после любой команды; вопрос и
  /// карточка — от «Паролей», карточка только в памяти). Заперто — сначала
  /// карточка открытия, после неё тренировка. Следующая — через 3 дня.
  Future<void> _startTraining() async {
    if (_trainingAsked || _sending || _bulkBusy) return;
    _trainingAsked = true;
    setState(() => _trainingReady = false);
    _changeSettings(
      _settings.copyWith(
        passwordsTrainingDue: AppSettings.dayKey(
          _now.add(const Duration(days: 3)),
        ),
      ),
    );
    await _send('Потренируй меня');
  }

  void _onPasswordsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    widget.voice?.removeListener(_onVoiceChanged);
    // Уходя, микрофон не оставляем включённым.
    _voiceShortTimer?.cancel();
    _voiceNoticeTimer?.cancel();
    _voiceHoldTimer?.cancel();
    _voiceAttempt++;
    if (_voiceListening || _voiceLoading) {
      unawaited(_voiceEvents?.cancel());
      unawaited(widget.voice?.recognizer.cancel());
    }
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
    _docScroll.dispose();
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
    if (state == AppLifecycleState.resumed) {
      _refresh();
      _preloadVoice();
    }
    if (state == AppLifecycleState.paused) _saveDocument();
    // В фоне не слушаем: распознавание прерывается без итога.
    // Системный диалог доступа к микрофону тоже делает приложение
    // неактивным — его ответа ждём, а не прерываем попытку.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        (state == AppLifecycleState.inactive && !_voiceAskingPermission)) {
      unawaited(_cancelVoice());
    }
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
        clarification: response.clarification,
        suggestions: response.suggestions,
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
    widget.assistant.commandUsage = settings.commandUsage;
    widget.passwords?.syncSettings(
      seenRev: settings.passwordsSeenRev,
      vaultExisted: settings.passwordsVaultExisted,
    );
    setState(() {
      _settings = settings;
      _settingsLoaded = true;
    });
    _dailyChecks();
    _preloadVoice();
  }

  /// Чаты с диска: метаданные сразу, сообщения — при открытии. Открытой
  /// остаётся новая пустая сессия (прежний «Главный» переносится в
  /// обычную сессию, ChatBook.load).
  Future<void> _loadChats() async {
    await _book.load();
    if (!mounted) return;
    setState(() {
      _chatsLoaded = true;
      _messageKeys.clear();
    });
    if (_book.projectsUnreadable) {
      _announce('Не удалось прочитать проекты — они целы, '
          'попробуйте перезапустить приложение');
    }
    _dailyChecks();
    // Вторая строка в меню у чатов из прежних версий — из их файлов.
    if (await _book.backfillPreviews() && mounted) setState(() {});
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
    _preloadVoice();
  }

  /// Проверки при открытии и при смене дня: первый день для «Вместе N
  /// дней» и срок тренировки паролей. Сам помощник в сессии не пишет: о
  /// просроченных говорит строка в пустой сессии ([SessionHero.overdue]).
  void _dailyChecks() {
    if (!mounted ||
        !_settingsLoaded ||
        !_chatsLoaded ||
        !_loaded ||
        _loadError != null) {
      return;
    }
    _maybeFirstSeen();
    _scheduleTrainingNotice();
  }

  /// Первый день с Tridot для «Вместе N дней»: самая ранняя дата из
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
    _dailyChecks();
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
      // Новый день: свежий список задач и строка о просроченных в пустой
      // сессии (_refresh → _dailyChecks).
      unawaited(_refresh());
    });
  }

  /// Задача, с которой работает помощник: в чате задачи — она сама, в
  /// сессии — выбранная («её»).
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
    // Файлы уходят с командой из поля ввода, не с быстрой кнопкой.
    final files = preset == null
        ? List<_PendingFile>.of(_pendingFiles)
        : const <_PendingFile>[];
    if (text.isEmpty && files.isEmpty) return;
    if (_sending) {
      // Ответ готовится в другой сессии: текст остаётся в поле, а не
      // пропадает молча.
      final working = _workingChatId;
      if (working != null && working != _book.currentId) {
        _announce('Дождитесь ответа в другой сессии');
      }
      return;
    }
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
    final commandId = _book.newMessageId();
    // Файлы — в папку сессии, до сообщения (ADR-019). Никуда, кроме неё,
    // они не уходят.
    var attachments = const <ChatAttachment>[];
    if (files.isNotEmpty) {
      setState(() {
        _sending = true;
        _workingChatId = chatId;
        _pendingFiles.clear();
      });
      final AttachmentImport imported;
      try {
        imported = await _book.attach(chatId, commandId, <(
          AttachmentSource,
          String,
        )>[
          for (final file in files) (file.source, file.name),
        ]);
      } finally {
        _sending = false;
        _workingChatId = null;
      }
      if (!mounted) return;
      attachments = imported.saved;
      _reportImport(imported, files.length);
      if (attachments.isEmpty && text.isEmpty) {
        setState(() {});
        return;
      }
      if (text.isEmpty) {
        _sendFilesOnly(chatId, commandId, attachments);
        return;
      }
    }
    final command = ChatMessage(
      id: commandId,
      author: ChatAuthor.user,
      text: shown,
      timestamp: _now,
      attachments: attachments,
    );
    setState(() {
      _sending = true;
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
      _commandCursor = null;
      if (preset == null) _input.clear();
    });
    _scrollToLatest();
    await _saveDocument();
    final handled = await widget.assistant.handle(
      secret ? shown : text,
      chatTaskId: chatTaskId,
      secretRedacted: secret,
    );
    if (!mounted) return;
    // Файлы с непонятным текстом («Смета и эскиз») — подпись к файлам, а
    // не команда: ответ тот же, что на одни файлы, без «Пока понимаю…».
    final response = attachments.isNotEmpty && handled.intent == 'unknown'
        ? widget.assistant.attachmentsSaved(attachments.length)
        : handled;
    final filesOnlyReply = !identical(response, handled);
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
    if (attachments.isNotEmpty && !filesOnlyReply) {
      reply = reply.withText(
        '${reply.text}\n\n'
        '${widget.assistant.attachmentsNote(attachments.length, reply.personaId)}',
      );
    }
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
      _book.append(chatId, reply, sensitive: _sensitiveReply(response));
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

  /// Сообщение только из файлов: в помощника команда не идёт, он честно
  /// отвечает, что файлы сохранены в сессии (ADR-019).
  void _sendFilesOnly(
    String chatId,
    String commandId,
    List<ChatAttachment> attachments,
  ) {
    final command = ChatMessage(
      id: commandId,
      author: ChatAuthor.user,
      text: '',
      timestamp: _now,
      attachments: attachments,
    );
    final response = widget.assistant.attachmentsSaved(attachments.length);
    setState(() {
      _book.append(chatId, command);
      _book.append(chatId, _answer(response));
      _commandCursor = null;
      _cube = cubeStateFor(response.status);
    });
    _cubeTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted && !_sending) setState(() => _cube = CubeState.idle);
    });
    _scrollToLatest();
    _inputFocus.requestFocus();
  }

  /// Что не прикрепилось: слишком большие файлы и сбои копирования.
  void _reportImport(AttachmentImport imported, int requested) {
    final skipped = requested - AttachmentStore.maxPerMessage;
    if (imported.tooLarge.isNotEmpty) {
      _announce(
        imported.tooLarge.length == 1
            ? 'Файл больше 25 МБ — такие пока не прикрепляются'
            : 'Файлы больше 25 МБ — такие пока не прикрепляются '
                '(${imported.tooLarge.length})',
      );
    } else if (imported.failed > 0) {
      _announce('Не удалось сохранить файл в сессии');
    } else if (skipped > 0) {
      _announce(
        'К сообщению прикрепляется не больше '
        '${AttachmentStore.maxPerMessage} файлов',
      );
    }
  }

  /// «+» → «Прикрепить файл»: системный выбор файлов. Файлы ждут
  /// отправки чипами над полем ввода.
  Future<void> _pickFiles(PickKind kind) async {
    if (!_book.store.attachments.persistent) {
      _announce('В режиме «Только в памяти» файлы не сохраняются');
      return;
    }
    final room = AttachmentStore.maxPerMessage - _pendingFiles.length;
    if (room <= 0) {
      _announce(
        'К сообщению прикрепляется не больше '
        '${AttachmentStore.maxPerMessage} файлов',
      );
      return;
    }
    final List<AttachmentSource> picked;
    try {
      picked = await widget.attachmentPicker.pick(kind);
    } on Object {
      if (mounted) _announce('Не удалось открыть выбор файлов');
      return;
    }
    if (!mounted || picked.isEmpty) return;
    final chosen = <_PendingFile>[];
    var tooLarge = 0;
    for (final source in picked) {
      int size;
      try {
        size = await source.length();
      } on Object {
        continue;
      }
      if (size > AttachmentStore.maxBytes) {
        tooLarge++;
        continue;
      }
      // Имя файла может нести токен или пароль: в чат и на диск — без
      // них.
      final name = ChatAttachment.cleanName(
        SecretGuard.redact(
          LoginLinks.redact(source.name),
          known: widget.assistant.knownSecret,
        ).text,
      );
      chosen.add(
        (
          source: source,
          name: name,
          kind: AttachmentKind.of(name, source.mimeType),
          size: size,
        ),
      );
    }
    if (!mounted) return;
    if (tooLarge > 0) {
      _announce('Файл больше 25 МБ — такие пока не прикрепляются');
    }
    if (chosen.length > room) {
      _announce(
        'К сообщению прикрепляется не больше '
        '${AttachmentStore.maxPerMessage} файлов',
      );
    }
    setState(() => _pendingFiles.addAll(chosen.take(room)));
    _inputFocus.requestFocus();
  }

  /// «+» → «Облачный диск» → «Подключить диск»: дисков ещё нет, честное
  /// пояснение и путь к файлам с устройства.
  Future<void> _explainCloudDisks() async {
    final attach = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AssistantColors.raised,
      builder: (BuildContext context) => SafeArea(
        child: Padding(
          key: const Key('cloud-disk-info'),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'Облачный диск',
                style: TextStyle(
                  fontSize: 17,
                  color: AssistantColors.textStrong,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '${CloudDisk.yandex.label} и ${CloudDisk.google.label} '
                'появятся позже. Пока файлы можно прикрепить с устройства.',
                style: const TextStyle(fontSize: 14, height: 1.4),
              ),
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Понятно'),
                  ),
                  FilledButton.icon(
                    key: const Key('cloud-disk-attach'),
                    onPressed: () => Navigator.of(context).pop(true),
                    icon: const Icon(Icons.attach_file, size: 18),
                    label: const Text('Прикрепить файл'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (attach == true && mounted) await _pickFiles(PickKind.any);
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
        _sensitiveReply(response);
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

  /// Ответ навыка с секретами (пароли, секреты, навык с пометкой
  /// `sensitive`): его текст не показываем ни уведомлением, ни второй
  /// строкой сессии в меню (ADR-010).
  bool _sensitiveReply(AssistantResponse response) =>
      response.secureCard != null ||
      response.intent.startsWith('passwords') ||
      response.intent.startsWith('secret') ||
      _sensitiveConnector(widget.assistant.session.lastConnectorId);

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

  /// Каталог команд включённых навыков для «+» и «Найти команду»
  /// (ADR-020): с выбранной задачей — и команды о ней, в сессии папки с
  /// меткой — «Задача в проект» с этой меткой.
  CommandCatalog get _catalog {
    final selected = _selectedTask;
    return CommandCatalog.build(
      connectors: widget.assistant.connectors,
      hasSelection: selected != null && selected.isActive,
      projectTag: _book.projectOf(_book.current.id)?.taskTag,
      passwordActions: widget.passwords != null,
    );
  }

  /// Выбор команды из «+» или «Найти команду»: счётчик по id (текст не
  /// хранится), затем вставка шаблона или действие.
  void _runCommand(CommandEntry entry) {
    _countCommand(entry.id);
    switch (entry.kind) {
      case CommandKind.insert:
        _applyTemplate(entry.template);
      case CommandKind.action:
        switch (entry.id) {
          case 'pw.open':
            unawaited(_openPasswords());
          case 'pw.generate':
            unawaited(_openGenerator());
          case 'pw.add':
            unawaited(_openPasswords(add: true));
        }
    }
  }

  void _countCommand(String id) {
    final usage = CommandUsage.bump(_settings.commandUsage, id);
    if (identical(usage, _settings.commandUsage)) return;
    final settings = _settings.copyWith(commandUsage: usage);
    widget.assistant.commandUsage = usage;
    setState(() => _settings = settings);
    unawaited(_settingsStore.save(settings));
  }

  Future<void> _findCommand() async {
    final entry = await showCommandFinder(context, _catalog);
    if (!mounted || entry == null) return;
    _runCommand(entry);
  }

  /// Шаблон в поле ввода; `|` — место курсора. Пустое поле шаблон
  /// заменяет, а в начатый черновик он вставляется на место курсора
  /// через пробел: набранное не теряется.
  void _applyTemplate(String template) {
    final cursor = template.indexOf('|');
    final insert = template.replaceFirst('|', '');
    final value = _input.value;
    final String text;
    final int offset;
    if (value.text.trim().isEmpty) {
      text = insert;
      offset = cursor < 0 ? text.length : cursor;
    } else {
      final selection = value.selection.isValid
          ? value.selection
          : TextSelection.collapsed(offset: value.text.length);
      final before = value.text.substring(0, selection.start);
      final after = value.text.substring(selection.end);
      final lead = before.isEmpty || RegExp(r'\s$').hasMatch(before) ? '' : ' ';
      final tail = after.isEmpty || RegExp(r'^\s').hasMatch(after) ? '' : ' ';
      text = '$before$lead$insert$tail$after';
      offset =
          before.length + lead.length + (cursor < 0 ? insert.length : cursor);
    }
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: offset),
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
    await _scrollToRow(_messageKeys.putIfAbsent(messageIndex, GlobalKey.new));
  }

  /// Прокручивает ленту к сообщению [messageId] из поиска и подсвечивает
  /// его. Сообщения уже нет (обрезано, удалено) — лента остаётся внизу.
  Future<void> _jumpToMessage(String messageId) async {
    if (!_messages.any((ChatMessage m) => m.id == messageId)) return;
    if (_mode != AssistantViewMode.dialogue) {
      _setMode(AssistantViewMode.dialogue);
    }
    setState(() {
      _highlightedCommand = null;
      _highlightedMessageId = messageId;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await _scrollToRow(_hitRowKey);
  }

  /// Лента строится лениво: строки [key] может ещё не быть — прокручиваем
  /// шагами вверх, пока она не появится, и затем выравниваем её.
  Future<void> _scrollToRow(GlobalKey key) async {
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

  /// «Очистить историю сессий»: сессии и чаты задач удаляются, открыта
  /// новая пустая сессия. Задачи не меняются.
  void _clearChat() {
    // Вопрос со списком снимается, отменить прежние массовые изменения
    // из чата больше нельзя.
    widget.assistant.clearConversation();
    unawaited(_book.clearAll());
    widget.assistant
      ..forgetChatSelections()
      ..enterChat(sessionId: _book.currentId);
    if (_section == AppSection.project &&
        _book.project(_openProjectId) == null) {
      _section = AppSection.projects;
    }
    setState(() {
      _mode = AssistantViewMode.dialogue;
      _docToast = null;
      _messageKeys.clear();
      _commandCursor = null;
      _highlightedCommand = null;
      _highlightedMessageId = null;
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
        _book.append(chatId, reply, sensitive: _sensitiveReply(response));
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
  void _openTaskChat(
    Task task, {
    AssistantViewMode? mode,
    VoidCallback? onLoaded,
  }) {
    if (_book.current.taskId == task.id) {
      // Тот же чат: только вернуться в сессию из раздела — контекст
      // помощника (ожидание ответа, «её») не сбрасывается.
      _closeDrawers();
      _showSession();
      if (mode != null && mode != _mode) _setMode(mode);
      onLoaded?.call();
      return;
    }
    _chatCreations++;
    _switchChat(
      () => _book.openTask(task.id),
      mode: mode,
      onLoaded: onLoaded,
    );
  }

  /// Открывает чат [chatId] в «Диалоге». Тот же чат в «Документе» тоже
  /// переключается на «Диалог»: в документе ленты нет, и карточка, ради
  /// которой пришли (например, из «Сводки»), иначе не видна.
  void _openChat(String chatId, {VoidCallback? onLoaded}) {
    if (_book.resolve(chatId) == _book.currentId) {
      _closeDrawers();
      _showSession();
      if (_mode != AssistantViewMode.dialogue) {
        _setMode(AssistantViewMode.dialogue);
      }
      onLoaded?.call();
      return;
    }
    _switchChat(
      () => _book.open(chatId),
      mode: AssistantViewMode.dialogue,
      onLoaded: onLoaded,
    );
  }

  void _showSession() {
    if (_section == AppSection.session) return;
    unawaited(_saveDocument());
    setState(() => _section = AppSection.session);
  }

  /// «Назад» из чата задачи: к предыдущему чату, иначе в пустую сессию.
  void _goBack() => _switchChat(_book.back);

  /// Переключение сразу: сообщения незагруженного чата появятся, когда
  /// прочитаются.
  ///
  /// [keepSection] — остаться в открытом разделе («Задачи», «Проекты»):
  /// удалили открытую сессию из панели, а смотрят не её. [onLoaded] —
  /// после того как сообщения чата прочитаны и показаны.
  void _switchChat(
    Future<ChatThread> Function() open, {
    AssistantViewMode? mode,
    bool closeDrawer = true,
    bool keepSection = false,
    VoidCallback? onLoaded,
  }) {
    if (closeDrawer) _closeDrawers();
    unawaited(_saveDocument());
    final wasLoaded = _book.loaded;
    final loading = open();
    if (wasLoaded) _onChatChanged(mode: mode, keepSection: keepSection);
    unawaited(
      loading.then((_) {
        if (!mounted) return;
        if (wasLoaded) {
          setState(() {});
        } else {
          _onChatChanged(mode: mode, keepSection: keepSection);
        }
        onLoaded?.call();
      }),
    );
  }

  /// Открыт другой чат: контекст помощника («её», ожидание вопроса),
  /// документ и лента — по нему.
  void _onChatChanged({AssistantViewMode? mode, bool keepSection = false}) {
    final current = _book.current;
    widget.assistant.enterChat(
      taskId: current.taskId,
      sessionId: current.isSession ? current.id : null,
      projectTag: _book.projectOf(current.id)?.taskTag,
    );
    setState(() {
      if (!keepSection) _section = AppSection.session;
      if (mode != null) _mode = mode;
      _messageKeys.clear();
      _highlightedCommand = null;
      _highlightedMessageId = null;
      _commandCursor = null;
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

  // ------------------------------------------------------ голосовой ввод

  /// Кнопка микрофона в поле ввода (ADR-023).
  VoiceButtonMode get _voiceMode {
    final voice = widget.voice;
    if (voice == null || voice.support == VoiceSupport.unsupported) {
      return VoiceButtonMode.hidden;
    }
    if (_voiceListening) return VoiceButtonMode.listening;
    if (_voiceLoading) return VoiceButtonMode.loading;
    if (!_settings.voiceInput || !voice.isInstalled) return VoiceButtonMode.off;
    return VoiceButtonMode.idle;
  }

  void _onVoiceChanged() {
    if (!mounted) return;
    final voice = widget.voice;
    if (_voiceAwaitInstall && voice != null && !voice.isBusy) {
      _voiceAwaitInstall = false;
      if (voice.isInstalled) {
        _voiceSay('Голосовой ввод готов');
      } else if (voice.error case final VoiceKitError error) {
        _voiceSay(error.message);
      }
    }
    setState(() {});
    _preloadVoice();
  }

  /// Модель загружается заранее, как только голосовой ввод включён и
  /// модель скачана: первое удержание микрофона не ждёт загрузки и не
  /// теряет сказанное.
  void _preloadVoice() {
    final voice = widget.voice;
    if (voice == null ||
        voice.support == VoiceSupport.unsupported ||
        !_settings.voiceInput ||
        !voice.isInstalled) {
      return;
    }
    unawaited(
      voice.ensureLoaded().then<void>(
            (_) {},
            // Ошибку покажет нажатие на микрофон.
            onError: (Object _) {},
          ),
    );
  }

  /// Нажатие на микрофон: выключен — предложение включить; на компьютере
  /// (и для экранного диктора) — начать или закончить.
  void _voiceTap() {
    switch (_voiceMode) {
      case VoiceButtonMode.hidden:
        return;
      case VoiceButtonMode.off:
        unawaited(_offerVoice());
      case VoiceButtonMode.idle:
        unawaited(_startVoice(toggle: true));
      case VoiceButtonMode.loading:
      case VoiceButtonMode.listening:
        unawaited(_stopVoice(toggle: true));
    }
  }

  /// Палец лёг на микрофон (телефон).
  void _voiceDown() {
    if (_voiceMode == VoiceButtonMode.off) {
      unawaited(_offerVoice());
      return;
    }
    unawaited(_startVoice(toggle: false));
  }

  /// Палец отпущен или жест прерван.
  void _voiceUp() => unawaited(_stopVoice(toggle: false));

  Future<void> _startVoice({required bool toggle}) async {
    final voice = widget.voice;
    if (voice == null || _sending || _voiceListening || _voiceLoading) return;
    if (!_settings.voiceInput || !voice.isInstalled) {
      await _offerVoice();
      return;
    }
    if (!_settings.voiceMicExplained) {
      // Сначала объясняем, зачем микрофон, и спрашиваем доступ. Говорить —
      // следующим нажатием: палец уже не на кнопке.
      final go = await showVoiceRationale(context);
      if (!mounted || !go) return;
      _changeSettings(_settings.copyWith(voiceMicExplained: true));
      final VoicePermission permission;
      _voiceAskingPermission = true;
      try {
        permission = await voice.recognizer.ensurePermission();
      } finally {
        _voiceAskingPermission = false;
      }
      if (!mounted) return;
      if (permission == VoicePermission.granted) {
        _voiceSay(
          toggle
              ? 'Микрофон доступен. Нажмите на него и говорите'
              : 'Микрофон доступен. Удерживайте его и говорите',
        );
      } else {
        _announceNoMicrophone();
      }
      return;
    }
    final attempt = ++_voiceAttempt;
    // Держали дольше случайного касания — значит, говорили.
    _voiceHeldLong = false;
    _voiceHoldTimer?.cancel();
    _voiceHoldTimer = Timer(_voiceMinHold, () => _voiceHeldLong = true);
    _voiceHeld = true;
    _voiceToggle = toggle;
    _voiceNoticeTimer?.cancel();
    setState(() {
      _voiceLoading = true;
      _voicePartial = '';
      _voiceNotice = null;
    });
    // Доступ спрашивается каждый раз: на Android 13+ «Только в этот раз»
    // отзывается сам.
    VoicePermission permission;
    _voiceAskingPermission = true;
    try {
      permission = await voice.recognizer.ensurePermission();
    } on Object {
      permission = VoicePermission.denied;
    } finally {
      _voiceAskingPermission = false;
    }
    if (!mounted || attempt != _voiceAttempt) return;
    if (permission != VoicePermission.granted) {
      _voiceHeld = false;
      _endVoice();
      _announceNoMicrophone();
      return;
    }
    try {
      await voice.ensureLoaded();
    } on Object catch (error) {
      if (!mounted || attempt != _voiceAttempt) return;
      _voiceHeld = false;
      _endVoice();
      _voiceSay(
        error is VoiceEngineException
            ? error.code.message
            : VoiceErrorCode.modelLoad.message,
      );
      return;
    }
    if (!mounted || attempt != _voiceAttempt) return;
    // Отпустили раньше, чем началось распознавание: не слушаем. Если
    // держали долго — значит, говорили, пока модель загружалась: честно
    // говорим, что сказанное не услышано.
    final heldLong = _voiceHeldLong;
    _voiceHoldTimer?.cancel();
    _voiceHoldTimer = null;
    if (!_voiceHeld || _sending) {
      _endVoice();
      if (!_sending && heldLong) {
        _voiceSay(
          'Распознавание ещё готовилось — сказанное не услышано. '
          'Удерживайте микрофон, пока он не станет красным',
        );
      }
      return;
    }
    final Stream<VoiceEvent> events;
    try {
      events = voice.recognizer.start();
    } on Object {
      _voiceHeld = false;
      _endVoice();
      _voiceSay(VoiceErrorCode.engine.message);
      return;
    }
    _voiceShort = !toggle;
    _voiceShortTimer?.cancel();
    _voiceShortTimer = Timer(_voiceMinHold, () => _voiceShort = false);
    setState(() {
      _voiceLoading = false;
      _voiceListening = true;
    });
    // События и конец потока касаются только своей попытки: поток прежней
    // попытки, закрывшись позже, не сбросит текущую.
    late final StreamSubscription<VoiceEvent> subscription;
    subscription = events.listen(
      (VoiceEvent event) {
        if (_voiceEvents == subscription) _onVoiceEvent(event);
      },
      onError: (Object _) {
        if (_voiceEvents != subscription) return;
        _endVoice();
        if (mounted) _voiceSay(VoiceErrorCode.engine.message);
      },
      onDone: () {
        if (_voiceEvents == subscription) _endVoice();
      },
    );
    _voiceEvents = subscription;
  }

  Future<void> _stopVoice({required bool toggle}) async {
    final voice = widget.voice;
    if (voice == null) return;
    // На компьютере кнопка переключает: отпускание мыши ничего не значит.
    if (!toggle && _voiceToggle) return;
    _voiceHeld = false;
    if (!_voiceListening) return;
    if (_voiceShort) {
      // Короткое касание: слушать нечего, итог не нужен.
      _voiceSay('Удерживайте микрофон, пока говорите');
      await _cancelVoice();
      return;
    }
    final subscription = _voiceEvents;
    try {
      await voice.recognizer.stop();
    } on Object {
      if (_voiceEvents != subscription) return;
      _endVoice();
      if (mounted) _voiceSay(VoiceErrorCode.engine.message);
    }
  }

  /// Прерывает распознавание без итога: фон, уход с экрана.
  Future<void> _cancelVoice() async {
    _voiceHeld = false;
    _voiceAttempt++;
    final active = _voiceListening || _voiceLoading;
    final subscription = _voiceEvents;
    final recognizer = widget.voice?.recognizer;
    _voiceEvents = null;
    _endVoice();
    if (!active) return;
    unawaited(subscription?.cancel());
    try {
      await recognizer?.cancel();
    } on Object {
      // Уже остановлен.
    }
  }

  void _endVoice() {
    _voiceShortTimer?.cancel();
    _voiceShortTimer = null;
    _voiceHoldTimer?.cancel();
    _voiceHoldTimer = null;
    _voiceShort = false;
    _voiceToggle = false;
    _voiceEvents = null;
    if (!mounted) return;
    if (!_voiceListening && !_voiceLoading && _voicePartial.isEmpty) return;
    setState(() {
      _voiceListening = false;
      _voiceLoading = false;
      _voicePartial = '';
    });
  }

  void _onVoiceEvent(VoiceEvent event) {
    if (!mounted) return;
    switch (event) {
      case VoicePartial(:final text):
        setState(() => _voicePartial = normalizeRecognized(text));
      case VoiceFinal(:final text):
        _endVoice();
        _insertRecognized(text);
      case VoiceError(:final code):
        _endVoice();
        _voiceSay(code.message);
    }
  }

  void _announceNoMicrophone() => _voiceSay(
        defaultTargetPlatform == TargetPlatform.android
            ? 'Нет доступа к микрофону. Разрешите его в настройках Android'
            : 'Нет доступа к микрофону. Разрешите его в настройках системы',
      );

  /// Распознанное — в поле ввода, на место курсора или через пробел после
  /// черновика. Дальше пользователь правит и отправляет сам; с «Отправлять
  /// сразу» — уходит сразу, если не похоже на пароль. Сам текст нигде не
  /// повторяется: ни в уведомлениях, ни в журнале.
  void _insertRecognized(String recognized) {
    final text = normalizeRecognized(recognized);
    if (text.isEmpty) {
      _voiceSay('Не удалось распознать речь');
      return;
    }
    final value = _input.value;
    final current = value.text;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: current.length);
    final before = current.substring(0, selection.start);
    final after = current.substring(selection.end);
    final lead = before.isEmpty || RegExp(r'\s$').hasMatch(before) ? '' : ' ';
    final trail = after.isEmpty || RegExp(r'^\s').hasMatch(after) ? '' : ' ';
    // В середине черновика заглавная не нужна.
    final piece =
        before.trim().isEmpty || RegExp(r'[.!?…]\s*$').hasMatch(before)
            ? text
            : text[0].toLowerCase() + text.substring(1);
    final inserted = '$lead$piece$trail';
    final updated = before + inserted + after;
    _input.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(
        offset: before.length + lead.length + piece.length,
      ),
    );
    _commandCursor = null;
    if (!_settings.voiceSendImmediately) return;
    if (_looksSecret(updated)) {
      _voiceSay('Похоже на пароль — проверьте текст и отправьте вручную');
      return;
    }
    if (!_sending) unawaited(_send());
  }

  /// Распознанное похоже на пароль, фразу о паролях или код входа: сразу
  /// не отправляем (SecretGuard и при отправке скроет, но пусть человек
  /// сначала увидит текст).
  bool _looksSecret(String text) {
    if (LoginLinks.contains(text)) return true;
    if (SecretGuard.redact(text, known: widget.assistant.knownSecret).guarded) {
      return true;
    }
    return PasswordPhrases.looksLike(Utterance.analyze(text, now: _now));
  }

  /// Первое нажатие на выключенный микрофон: предложение включить и
  /// загрузка модели с ходом и «Отменой».
  Future<void> _offerVoice() async {
    final voice = widget.voice;
    if (voice == null || voice.support == VoiceSupport.unsupported) return;
    if (_voiceOffering) return;
    _voiceOffering = true;
    try {
      if (voice.isInstalled) {
        // Модель есть, выключен только переключатель.
        _changeSettings(_settings.copyWith(voiceInput: true));
        _voiceSay('Голосовой ввод включён');
        return;
      }
      if (!voice.isBusy) {
        final download = await showVoiceOffer(context, voice);
        if (!mounted || !download) return;
        _changeSettings(_settings.copyWith(voiceInput: true));
        unawaited(voice.install());
      }
      final outcome = await showVoiceInstallSheet(context, voice);
      if (!mounted) return;
      switch (outcome) {
        case VoiceInstallOutcome.installed:
          _voiceSay('Голосовой ввод готов');
        case VoiceInstallOutcome.cancelled:
          _changeSettings(_settings.copyWith(voiceInput: false));
          _voiceSay(
            'Загрузка остановлена. Скачанное сохранено — продолжится с того '
            'же места',
          );
        case VoiceInstallOutcome.hidden:
          // Загрузка продолжается: о готовности или ошибке скажет поле.
          _voiceAwaitInstall = true;
        case VoiceInstallOutcome.closed:
          break;
      }
    } finally {
      _voiceOffering = false;
    }
  }

  /// Ctrl+Shift+M (на macOS — Cmd+Shift+M): начать или закончить голосовой
  /// ввод на компьютере.
  bool _voiceShortcut(KeyEvent event) {
    if (!voiceToggleByDefault) return false;
    final mode = _voiceMode;
    if (mode != VoiceButtonMode.idle &&
        mode != VoiceButtonMode.listening &&
        mode != VoiceButtonMode.loading) {
      return false;
    }
    final keyboard = HardwareKeyboard.instance;
    final modifier = defaultTargetPlatform == TargetPlatform.macOS
        ? keyboard.isMetaPressed
        : keyboard.isControlPressed;
    if (!modifier || !keyboard.isShiftPressed) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    _voiceTap();
    return true;
  }

  /// Подсказка голосового ввода — строкой над полем на 4 секунды. Сам
  /// распознанный текст сюда никогда не попадает.
  void _voiceSay(String text) {
    if (!mounted) return;
    _voiceNoticeTimer?.cancel();
    setState(() => _voiceNotice = text);
    _voiceNoticeTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _voiceNotice = null);
    });
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
        // В «Мой Tridot» колонки «Сегодня» нет (D-Desk-Summary): году
        // активности нужна ширина. Выбор пользователя не меняется.
        final today = _section != AppSection.myRelay && _todayShown(width);
        // Выдвижное меню (макет «Ж1»): до 360, справа остаётся полоса
        // затемнения не уже 30 — по ней меню закрывается.
        final drawerWidth = math.max(240.0, math.min(360.0, width - 30));
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
          // «Назад» на телефоне из разделов и «Мой Tridot» — в сессию.
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
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyM &&
        mounted &&
        _voiceShortcut(event)) {
      return true;
    }
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
      projects: <ProjectEntry>[
        for (final project in _book.projects())
          ProjectEntry(
            id: project.id,
            name: project.name,
            sessions: _book.projectSessionCount(project.id),
            active:
                _section == AppSection.project && _openProjectId == project.id,
          ),
      ],
      onOpenProject: _openProject,
      onNewProject: () => unawaited(_createProject()),
      groups: _sessionGroups(now),
      hiddenSessions: _book.groups(now, limit: _sessionsShown).hidden,
      onShowMoreSessions: () => setState(
        () => _sessionsShown += ChatBook.sessionsLimit,
      ),
      counts: _sectionCounts(now),
      extensions: _extensionEntries(),
      onOpenMyRelay: () => _openMyRelay(MyRelayTab.summary),
      onTasks: () => _goTo(AppSection.tasks),
      onProjects: () => _goTo(AppSection.projects),
      onPlanning: () => _goTo(AppSection.planning),
      onOpenSession: _openSessionEntry,
      onNewSession: _newSession,
      onSessionAction: (String id, SessionAction action) =>
          unawaited(_sessionAction(id, action)),
      search: (String query) => _book.search(
        query,
        titles: <String, String>{for (final task in _all) task.id: task.title},
      ),
      onOpenHit: (ChatSearchHit hit) =>
          _openSessionEntry(hit.chatId, messageId: hit.messageId),
      timeLabel: (DateTime at) => sessionTimeLabel(at, _now),
      assistants: _settings.personas.cast.active,
    );
  }

  /// Счётчики разделов меню — только из того, что есть: открытые и
  /// просроченные задачи, проекты с открытыми задачами, задачи со сроком
  /// сегодня и дальше. Нечего считать — без счётчика.
  SectionCounts _sectionCounts(DateTime now) {
    // «Проекты» — папки (ADR-018); метки задач — на экране «Проекты».
    final projects = _book.projects();
    final planning = upcomingCount(_active, now);
    return SectionCounts(
      tasks: _active.length,
      overdue: _active.where((Task t) => isOverdue(t, now)).length,
      projects: projects.isEmpty ? null : projects.length,
      planning: planning == 0 ? null : planning,
    );
  }

  /// Группы меню: «Закреплённые», «Сегодня», «Вчера», «На неделе»,
  /// «Ранее» (ChatBook.groups).
  List<SessionGroupEntry> _sessionGroups(DateTime now) {
    final inSession = _section == AppSection.session;
    final groups = _book.groups(now, limit: _sessionsShown);
    SessionGroupEntry group(String id, String label, List<ChatThread> list) =>
        SessionGroupEntry(
          id: id,
          label: label,
          entries: <SessionEntry>[
            for (final thread in list)
              if (_sessionEntry(thread, now, inSession, id)
                  case final SessionEntry e)
                e,
          ],
        );
    return <SessionGroupEntry>[
      group('pinned', 'Закреплённые', groups.pinned),
      group('today', 'Сегодня', groups.today),
      group('yesterday', 'Вчера', groups.yesterday),
      group('week', 'На неделе', groups.week),
      group('earlier', 'Ранее', groups.earlier),
    ];
  }

  SessionEntry? _sessionEntry(
    ChatThread thread,
    DateTime now,
    bool inSession,
    String group, {
    bool showProject = true,
  }) {
    final active = inSession && _book.currentId == thread.id;
    final time = sessionRowTimeLabel(thread.lastActivityAt, now, group);
    final persona = _settings.personas.cast.find(thread.lastPersonaId);
    final canAct = thread.messageCount > 0;
    // На экране самого проекта его название в каждой строке не нужно.
    final projectName =
        showProject ? _book.project(thread.projectId)?.name : null;
    switch (thread.kind) {
      // ChatKind.main в книге не бывает (переносится в сессию при чтении).
      case ChatKind.main:
      case ChatKind.session:
        return SessionEntry(
          id: thread.id,
          title: ChatBook.titleOf(thread),
          time: time,
          itemKey: Key('chat-${thread.id}'),
          dotKey: Key('chat-unread-${thread.id}'),
          active: active,
          unread: thread.unread,
          preview: thread.preview,
          persona: persona,
          pinned: thread.pinned,
          canAct: canAct,
          canRename: canAct,
          canMove: canAct,
          projectName: projectName,
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
          preview: thread.preview,
          persona: persona,
          pinned: thread.pinned,
          canAct: canAct,
          projectName: projectName,
        );
    }
  }

  /// Действие из меню сессии: переименовать, закрепить, удалить.
  Future<void> _sessionAction(String chatId, SessionAction action) async {
    final thread = _book.thread(chatId);
    if (thread == null) return;
    final task = thread.kind == ChatKind.task ? _findTask(thread.taskId) : null;
    final title = task?.title ?? ChatBook.titleOf(thread);
    switch (action) {
      case SessionAction.rename:
        final name = await showRenameSessionDialog(context, current: title);
        if (name == null || !mounted) return;
        setState(() => _book.rename(thread.id, name));
      case SessionAction.pin:
        setState(() => _book.setPinned(thread.id, !thread.pinned));
      case SessionAction.move:
        await _moveSession(thread);
      case SessionAction.delete:
        final confirmed = await showDeleteSessionDialog(
          context,
          title: title,
          task: thread.kind == ChatKind.task,
        );
        if (!confirmed || !mounted) return;
        final wasCurrent = await _book.remove(thread.id);
        if (!mounted) return;
        if (_workingChatId == thread.id) {
          // Ответ в удалённую сессию пропадёт (ChatBook.append — false).
          _workingChatId = null;
        }
        // Выбор («её») удалённой сессии больше не нужен.
        if (thread.isSession) widget.assistant.forgetChat(thread.id);
        if (wasCurrent) {
          // Открыта пустая сессия, как по «+»; меню остаётся открытым, а
          // раздел («Задачи» на компьютере) — тот же.
          _switchChat(
            _book.newSession,
            mode: AssistantViewMode.dialogue,
            closeDrawer: false,
            keepSection: true,
          );
        } else {
          setState(() {});
        }
    }
  }

  // ------------------------------------------------------ проекты-папки

  /// «В проект…»: лист с папками, «Новый проект…», «Убрать из проекта».
  Future<void> _moveSession(ChatThread thread) async {
    final choice = await showMoveToProjectSheet(
      context,
      projects: _book.projects(),
      currentProjectId: thread.projectId,
    );
    if (choice == null || !mounted) return;
    String? target;
    switch (choice) {
      case MoveToProject(:final projectId):
        target = projectId;
      case MoveOutOfProject():
        target = null;
      case MoveToNewProject():
        final created = await _createProject(open: false);
        if (created == null || !mounted) return;
        target = created.id;
    }
    setState(() => _book.moveToProject(thread.id, target));
    if (thread.id == _book.currentId) {
      widget.assistant.setProjectTag(_book.project(target)?.taskTag);
    }
    final name = _book.project(target)?.name;
    _announce(
      name == null
          ? 'Сессия вынесена из проекта'
          : 'Сессия — в проекте «$name»',
    );
  }

  /// «Новый проект»: окно с названием и описанием; [open] — сразу открыть
  /// его экран. [taskTag] — связать с меткой задач («Сделать папкой»).
  Future<ChatProject?> _createProject({
    bool open = true,
    String? name,
    String? taskTag,
  }) async {
    final draft = await showProjectDialog(context, name: name ?? '');
    if (draft == null || !mounted) return null;
    final project = _book.createProject(
      draft.name,
      description: draft.description,
      taskTag: taskTag,
    );
    if (project == null) return null;
    if (open) {
      _openProject(project.id);
    } else {
      setState(() {});
    }
    return project;
  }

  /// Экран проекта-папки [projectId].
  void _openProject(String projectId) {
    if (_book.project(projectId) == null) return;
    unawaited(_saveDocument());
    _closeDrawers();
    setState(() {
      _section = AppSection.project;
      _openProjectId = projectId;
    });
    unawaited(_refresh());
  }

  /// «Новая сессия в проекте»: пустая сессия сразу в этой папке.
  void _newSessionIn(String projectId) {
    unawaited(_saveDocument());
    _switchChat(
      () => _book.newSession(projectId: projectId),
      mode: AssistantViewMode.dialogue,
    );
    _inputFocus.requestFocus();
  }

  /// Меню «⋯» на экране проекта.
  Future<void> _projectAction(ChatProject project, ProjectAction action) async {
    switch (action) {
      case ProjectAction.rename:
        final name = await showRenameSessionDialog(
          context,
          current: project.name,
          title: 'Переименовать проект',
        );
        if (name == null || !mounted) return;
        setState(() => _book.renameProject(project.id, name));
      case ProjectAction.describe:
        final draft = await showProjectDialog(
          context,
          title: 'Проект',
          action: 'Сохранить',
          name: project.name,
          description: project.description,
        );
        if (draft == null || !mounted) return;
        setState(() {
          _book
            ..renameProject(project.id, draft.name)
            ..setProjectDescription(project.id, draft.description);
        });
      case ProjectAction.tag:
        final linked = <String>{
          for (final p in _book.projects())
            if (p.taskTag case final String tag) tag,
        };
        final free = <String>{
          for (final task in _active)
            if (task.project case final String tag)
              if (!linked.contains(tag)) tag,
        }.toList()
          ..sort();
        final result = await showProjectTagDialog(
          context,
          current: project.taskTag,
          suggestions: free.take(8).toList(),
        );
        if (result == null || !mounted) return;
        final other =
            result.tag == null ? null : _book.projectForTag(result.tag!);
        if (other != null && other.id != project.id) {
          _announce('Метка #${result.tag} уже у проекта «${other.name}»');
          return;
        }
        setState(() => _book.linkProjectTag(project.id, result.tag));
        if (_book.current.projectId == project.id) {
          widget.assistant.setProjectTag(result.tag);
        }
      case ProjectAction.pin:
        setState(() => _book.setProjectPinned(project.id, !project.pinned));
      case ProjectAction.delete:
        final count = _book.projectSessionCount(project.id);
        final choice = await showDeleteProjectDialog(
          context,
          name: project.name,
          sessions: count,
        );
        if (choice == null || !mounted) return;
        final deleting = choice == ProjectDeleteChoice.deleteSessions;
        // Забыть в помощнике ровно стёртые чаты: не открытую пустую сессию
        // (она остаётся), но и чаты задач проекта (их тоже стирают).
        final removed = <String>{};
        final wasCurrent = await _book.deleteProject(
          project.id,
          deleteSessions: deleting,
          removed: removed,
        );
        if (!mounted) return;
        for (final id in removed) {
          if (_workingChatId == id) _workingChatId = null;
          widget.assistant.forgetChat(id);
        }
        setState(() {
          _section = AppSection.projects;
          _openProjectId = null;
        });
        if (wasCurrent) {
          _switchChat(
            _book.newSession,
            mode: AssistantViewMode.dialogue,
            closeDrawer: false,
            keepSection: true,
          );
        } else {
          // Открытая сессия могла быть в этом проекте (и остаться, если она
          // пустая, — даже при «Удалить вместе с сессиями»): метки больше
          // нет.
          widget.assistant.setProjectTag(
            _book.projectOf(_book.currentId)?.taskTag,
          );
        }
    }
  }

  /// Открывает строку панели или результат поиска; [messageId] — к
  /// найденному сообщению: лента прокручивается к нему, оно подсвечено.
  void _openSessionEntry(String chatId, {String? messageId}) {
    final thread = _book.thread(chatId);
    final task =
        thread?.kind == ChatKind.task ? _findTask(thread!.taskId) : null;
    final VoidCallback? onLoaded = messageId == null
        ? null
        : () => WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) unawaited(_jumpToMessage(messageId));
            });
    if (task != null) {
      _openTaskChat(
        task,
        mode: AssistantViewMode.dialogue,
        onLoaded: onLoaded,
      );
    } else {
      _openChat(chatId, onLoaded: onLoaded);
    }
  }

  /// Дерево «Расширения»: только включённые расширения со своим экраном.
  List<ExtensionEntry> _extensionEntries() {
    final passwords = widget.passwords;
    return <ExtensionEntry>[
      // Порядок как в макете «Ж1»: сначала подключения (Склад), потом
      // Пароли.
      for (final service in widget.connections)
        if (widget.assistant.extensions.isEnabled(service.slot.id))
          ExtensionEntry(
            id: service.slot.id,
            title: service.slot.title,
            icon: Icons.inventory_2_outlined,
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
      if (passwords != null && _passwordsEnabled)
        ExtensionEntry(
          id: AssistantController.passwordsId,
          title: 'Пароли',
          icon: Icons.lock_outline,
          dot: true,
          // Открытое хранилище — повод обратить внимание: тёплая точка;
          // запертое, выключенное и не созданное — приглушённая.
          dotColor: passwords.state == VaultState.unlocked
              ? AssistantColors.warning
              : AssistantColors.faint,
          status: switch (passwords.state) {
            VaultState.notCreated => 'не создан',
            VaultState.locked => 'заперт',
            VaultState.unlocked => 'открыт',
            VaultState.disabled => 'выключен',
          },
          onTap: () {
            _closeDrawers();
            unawaited(_openPasswords());
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
  /// на сегодня, просроченные и ждущие отметки карточки — в «Мой Tridot»
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
    // Сигнал «ждёт подтверждения» — оповещение: подпись от ведущего
    // оповещений, значок склада — цветом ведущего расширений (ADR-016).
    final personas = _settings.personas;
    final persona = personas.notifier;
    final what = switch (card.kind) {
      ActionKind.post => 'Отметка прихода ждёт подтверждения',
      ActionKind.move => 'Перемещение ждёт подтверждения',
    };
    return TodayPending(
      id: card.id,
      title: what,
      subtitle: <String>[
        persona.russianName,
        widget.assistant.extensions.skillTitle(card.connectorId).toLowerCase(),
      ].join(' · '),
      lead: personas.extensionsLead,
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

  /// Выход из выбранной задачи в сессии: выбор снимается, режим —
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
      // задаче в сессии — снять выбор; на телефоне он заменяет меню
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
      title = _SectionTitle(
        title: _section == AppSection.project
            ? _book.project(_openProjectId)?.name ?? _section.title
            : _section.title,
      );
    } else {
      title = null;
    }
    final current = _book.current;
    // В шапке — тот, кто отвечает в этой сессии: последний ответивший, а
    // до первого ответа — кто ответит по составу.
    final responder =
        _settings.personas.cast.find(current.lastPersonaId) ?? persona;
    final canAct = current.messageCount > 0;
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
            // Задача в фокусе: меню сессии — кнопкой рядом с «Задачи ›
            // «её»», а не пропадает до «назад».
            sessionMenuBeside: taskInFocus != null,
            sessionTitle: ChatBook.titleOf(current),
            persona: responder,
            // Меню сессии — как долгое нажатие в панели. Пустую сессию
            // переименовывать и удалять ещё нечего.
            onSessionAction: canAct
                ? (SessionAction action) =>
                    unawaited(_sessionAction(current.id, action))
                : null,
            pinned: current.pinned,
            canRename: current.isSession,
            canMove: current.isSession,
            projectName: _book.projectOf(current.id)?.name,
            reduceMotion: _settings.reduceMotion,
            // «Сегодня» — колонкой справа на компьютере; свёрнута — кнопка
            // в шапке. На телефоне кнопки нет: это «Мой Tridot» → «Сводка».
            trailing: wide && !today ? _todayShowButton() : null,
          ),
          const Divider(),
          Expanded(child: _buildSection(wide: wide)),
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
      assistantsShown: _settings.personas.cast.active,
      summary: RelaySummary(
        notifier: _settings.personas.notifier,
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
        voice: widget.voice,
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

  Widget _buildSection({required bool wide}) {
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
          folders: <ProjectFolderCard>[
            for (final project in _book.projects())
              ProjectFolderCard(
                id: project.id,
                name: project.name,
                description: project.description,
                taskTag: project.taskTag,
                sessions: _book.projectSessionCount(project.id),
              ),
          ],
          onOpenFolder: _openProject,
          onNewFolder: () => unawaited(_createProject()),
          onMakeFolder: (String tag) =>
              unawaited(_createProject(name: tag, taskTag: tag)),
        );
      case AppSection.project:
        final project = _book.project(_openProjectId);
        if (project == null) {
          return ProjectsScreen(
            tasks: _active,
            now: now,
            selectedId: selectedId,
            onOpenTask: open,
            onToggleDone: _toggleDone,
          );
        }
        final tag = project.taskTag;
        return ProjectScreen(
          project: project,
          now: now,
          reduceMotion: _settings.reduceMotion,
          sessions: <SessionEntry>[
            for (final thread in _book.sessionsOf(project.id))
              if (_sessionEntry(
                thread,
                now,
                false,
                'pinned',
                showProject: false,
              )
                  case final SessionEntry e)
                e,
          ],
          tasks: tag == null
              ? const <Task>[]
              : <Task>[
                  for (final task in _active)
                    if (task.tags.contains(tag)) task,
                ],
          selectedTaskId: selectedId,
          onOpenTask: open,
          onToggleDone: _toggleDone,
          onNewSession: () => _newSessionIn(project.id),
          onOpenSession: _openSessionEntry,
          onSessionAction: (String id, SessionAction action) =>
              unawaited(_sessionAction(id, action)),
          onAction: (ProjectAction action) =>
              unawaited(_projectAction(project, action)),
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
              _buildConversationColumn(constraints.maxHeight, wide: wide),
        );
    }
  }

  /// Пустая новая сессия: знак главного, строки ведущего оповещений,
  /// строка о ролях помощников голосом главного и, пока род главного не
  /// выбран, карточка выбора.
  Widget _sessionHero(int overdue) {
    final personas = _settings.personas;
    final main = personas.responder;
    final extensions = widget.assistant.extensions;
    return SessionHero(
      persona: main,
      projectName: _book.projectOf(_book.currentId)?.name,
      notifier: personas.notifier,
      overdue: overdue,
      onOverdue: () => _openMyRelay(MyRelayTab.summary),
      onTraining: _trainingReady && _passwordsEnabled
          ? () => unawaited(_startTraining())
          : null,
      onSadoGender: personas.sadoGenderChosen
          ? null
          : (ReplyGender gender) => _changeSettings(
                _settings.copyWith(
                  personas: personas.withGender(main.id, gender),
                ),
              ),
      note: personas.teamMode != TeamMode.solo
          ? SessionHero.noteFor(
              <(String, Persona)>[
                for (final role in extensions.activeRoles)
                  (role.title, extensions.ownerOf(role.id, personas)),
              ],
              main,
              line: (String roles, Persona owner) =>
                  widget.assistant.replies.render(
                Reply('session.handoff.note', <String, String>{
                  'roles': roles,
                  'name': owner.russianName,
                }),
                personas.voiceOf(main),
              ),
            )
          : null,
    );
  }

  Widget _buildConversationColumn(double height, {required bool wide}) {
    final current = _book.current;
    // Ответ готовится в другой сессии — эта пустая сессия всё равно
    // показывает заставку.
    final hero = _mode == AssistantViewMode.dialogue &&
        current.isSession &&
        current.messageCount == 0 &&
        !(_sending && _workingChatId == current.id);
    final history = hero ? const <HistoryEntry>[] : _historyEntries;
    final rail = history.isNotEmpty;
    final now = _now;
    final overdue =
        hero ? _active.where((Task t) => isOverdue(t, now)).length : 0;
    final Widget content = hero
        ? _sessionHero(overdue)
        : _mode == AssistantViewMode.dialogue
            ? _buildDialogue(topInset: rail ? HistoryRail.overlayInset : 0)
            : _withDocToast(
                DocumentView(
                  topInset: rail ? HistoryRail.overlayInset : 0,
                  scrollController: _docScroll,
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
              );
    return Column(
      children: <Widget>[
        Expanded(
          // Хроника команд — поверх ленты (или документа) сверху по
          // центру, под шапкой: шапка остаётся одной строкой, ширину ленты
          // и поля ввода хроника не занимает. Ленте и документу сверху
          // добавлен отступ высотой с хронику — первое сообщение ею не
          // закрыто.
          child: Stack(
            children: <Widget>[
              // Экранный диктор читает хронику перед лентой: у обоих свой
              // узел и порядок, а не по положению на экране (на широком
              // окне лента начинается выше хроники).
              Positioned.fill(
                child: Semantics(
                  container: true,
                  sortKey: const OrdinalSortKey(1),
                  child: content,
                ),
              ),
              if (rail)
                Positioned(
                  top: HistoryRail.overlayTop,
                  left: 0,
                  right: 0,
                  child: Semantics(
                    container: true,
                    sortKey: const OrdinalSortKey(0),
                    child: Center(
                      child: HistoryRailPill(
                        entries: history,
                        activeIndex: _highlightedCommand,
                        onSelect: _selectCommand,
                        // Полосы по одной — только на широком окне (мышь);
                        // на телефоне и планшете (палец) — одна кнопка
                        // списка.
                        compact: !wide,
                        // Колесо и перетаскивание над хроникой двигают то,
                        // что под ней.
                        scrollController: _mode == AssistantViewMode.dialogue
                            ? _chatScroll
                            : _docScroll,
                      ),
                    ),
                  ),
                ),
            ],
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

  Widget _buildChat(double viewportHeight, {double topInset = 0}) {
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
      final hit = message.id == _highlightedMessageId;
      final row = _MessageRow(
        cast: _settings.personas.cast,
        key: key,
        message: message,
        attachments: _book.store.attachments,
        commandSpans: _commandSpansOf(message),
        // В чате задачи плитка самой задачи под ответами не нужна: она в
        // шапке.
        task: message.taskId == _book.current.taskId
            ? null
            : _findTask(message.taskId),
        now: _now,
        showTime: _settings.showTimestamps,
        highlighted: hit || commandIndexOf[i] == _highlightedCommand,
        cube: i == latestAnswer && !_sending ? _cubeWidget() : null,
        selectedId: _selectedTask?.id,
        onOpenTask: (Task task) =>
            _openTaskChat(task, mode: AssistantViewMode.dialogue),
        onToggleDone: _toggleDone,
        linkLabel: linkLabel,
        linkKey: linkKey,
        onOpenLink: linkLabel == null ? null : () => _followLink(message.link!),
        checklist: _checklistCard(
              message,
              i,
              lastWithChecklist,
              viewportHeight,
            ) ??
            _actionCard(message, i, lastWithCard) ??
            _secureCard(message) ??
            _clarifyOptions(message) ??
            (i == latestAnswer ? _suggestionChips(message) : null),
      );
      // Сообщение из поиска: к нему прокручивается лента
      // ([_jumpToMessage]).
      rows.add(
        hit
            ? KeyedSubtree(
                key: _hitRowKey,
                child: KeyedSubtree(key: Key('msg-${message.id}'), child: row),
              )
            : row,
      );
    }
    final working = _working;
    if (_sending && working != null && _workingChatId == _book.currentId) {
      rows.add(
        _MessageRow(
          cast: _settings.personas.cast,
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
          // Сверху — место под хронику команд поверх ленты: самое старое
          // сообщение при прокрутке до конца остаётся под ней, а не за ней.
          padding: EdgeInsets.fromLTRB(
            chatInset,
            topInset > 0 ? topInset : 16,
            chatInset,
            16,
          ),
          children: rows.reversed.toList(),
        ),
      ),
    );
  }

  /// Подпись и ключ ссылки под сообщением или `(null, null)`: «Открыть
  /// сессию задачи» под ответом о новой задаче, «из сессии «…»» под копией
  /// в чате задачи (сессия, где задачу создали, или задача-родитель).
  /// Ссылка на открытый чат, на удалённую задачу или на чат, которого
  /// больше нет, не показывается.
  /// Что навыки распознали в команде [message] (ADR-021): только у
  /// сообщений пользователя.
  List<CommandSpan> _commandSpansOf(ChatMessage message) {
    if (!message.fromUser || message.text.trim().isEmpty) {
      return const <CommandSpan>[];
    }
    final key = '${message.id}\u0000${message.text}';
    final cached = _spanCache[key];
    if (cached != null) return cached;
    if (_spanCache.length >= 600) _spanCache.clear();
    return _spanCache[key] = widget.assistant.highlight(message.text);
  }

  (String?, Key?) _linkOf(ChatMessage message) {
    final link = message.link;
    if (link == null) return (null, null);
    // Старые копии ссылаются на «main» — он перенесён в сессию.
    final chatId = _book.resolve(link.chatId);
    if (chatId == _book.currentId) return (null, null);
    final target = _book.thread(chatId);
    if (target != null && target.kind != ChatKind.task) {
      return (
        'из сессии «${ChatBook.titleOf(target)}»',
        const Key('chat-origin-link'),
      );
    }
    final task = _findTask(link.taskId);
    if (task == null) return (null, null);
    // Копия в чате задачи ведёт в чат задачи-родителя.
    if (_book.current.parentTaskId == task.id) {
      return ('из сессии «${task.title}»', const Key('chat-origin-link'));
    }
    return ('Открыть сессию задачи', Key('open-task-chat-${task.id}'));
  }

  void _followLink(ChatLink link) {
    final chatId = _book.resolve(link.chatId);
    final task = _findTask(link.taskId);
    if (task != null && chatId.startsWith('task:')) {
      _openTaskChat(task, mode: AssistantViewMode.dialogue);
    } else {
      _openChat(chatId);
    }
  }

  Widget _buildDialogue({double topInset = 0}) {
    // Карточке списка нужна высота видимой части чата, а не экрана.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) =>
          _buildChat(constraints.maxHeight, topInset: topInset),
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

  /// Кнопки вариантов уточняющего вопроса: пока он ждёт ответа. Нажатие
  /// отправляет подпись варианта обычным сообщением — тот же путь, что
  /// набранный текст. Только в памяти: после перезапуска остаётся текст.
  Widget? _clarifyOptions(ChatMessage message) {
    final clarification = message.clarification;
    if (clarification == null ||
        !identical(widget.assistant.pendingClarification, clarification)) {
      return null;
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (final (index, option) in clarification.options.indexed)
            OutlinedButton(
              key: ValueKey<String>('clarify-option-$index'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(40, 44),
                foregroundColor: AssistantColors.textStrong,
                side: const BorderSide(color: AssistantColors.border),
              ),
              onPressed: _sending || _bulkBusy
                  ? null
                  : () => unawaited(_send(option.label)),
              child: Text(option.label),
            ),
        ],
      ),
    );
  }

  /// Подсказка команд под ответом «не до конца понял» (ADR-022): кнопки
  /// похожих команд и последней — «Найти команду». Только под последним
  /// ответом и только в памяти. Нажатие вставляет шаблон в поле ввода
  /// (`|` — курсор), отправляет пользователь сам; счётчики выбора команд
  /// не меняются — подсказка ничего не запоминает.
  Widget? _suggestionChips(ChatMessage message) {
    final suggestions = message.suggestions;
    if (suggestions == null) return null;
    ButtonStyle style() => OutlinedButton.styleFrom(
          minimumSize: const Size(40, 44),
          foregroundColor: AssistantColors.textStrong,
          side: const BorderSide(color: AssistantColors.border),
        );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (final suggestion in suggestions.commands)
            OutlinedButton(
              key: ValueKey<String>('suggest-${suggestion.entryId}'),
              style: style(),
              onPressed: () => _applyTemplate(suggestion.template),
              child: Text(suggestion.label),
            ),
          OutlinedButton.icon(
            key: const ValueKey<String>('suggest-find'),
            style: style(),
            onPressed: () => unawaited(_findCommand()),
            icon: const Icon(Icons.search, size: 18),
            label: const Text(CommandSuggestions.findLabel),
          ),
        ],
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
  /// команд — поверх ленты сверху по центру и ширину не занимает.
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

  /// Отправка занята в открытом чате: ответ готовится здесь (или ещё
  /// читаются настройки и чаты). Ответ в другой сессии кнопку не
  /// блокирует — [_send] скажет «Дождитесь ответа в другой сессии».
  bool get _busyHere =>
      _sending && (_workingChatId == null || _workingChatId == _book.currentId);

  List<HistoryEntry> get _historyEntries => <HistoryEntry>[
        for (var i = 0; i < _messages.length; i++)
          if (_messages[i].fromUser)
            HistoryEntry(
              command: _commandLabel(_messages[i]),
              timestamp: _timeLabel(_messages[i].timestamp),
              result: i + 1 < _messages.length && !_messages[i + 1].fromUser
                  ? _messages[i + 1].text
                  : null,
            ),
      ];

  /// Команда в хронике: текст, а у сообщения только из файлов — «Фото»,
  /// «Файл: отчёт.pdf».
  static String _commandLabel(ChatMessage message) =>
      message.text.isNotEmpty || message.attachments.isEmpty
          ? message.text
          : message.attachments.first.sessionTitle;

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
                  sending: _busyHere,
                  onSend: _send,
                  onTemplate: _applyTemplate,
                  onPassword: _passwordsEnabled ? _openPasswordActions : null,
                ),
          composer: SingleChildScrollView(
            reverse: true,
            child: CommandComposer(
              controller: _input,
              focusNode: _inputFocus,
              sending: _busyHere,
              mode: _mode,
              onModeChanged: _setMode,
              onSend: _send,
              // Четыре частые команды и «Найти команду» (ADR-020);
              // действия сейфа — там же, пока навык «Пароли» включён.
              templates: _catalog.top(_settings.commandUsage),
              onCommand: _runCommand,
              onFindCommand: () => unawaited(_findCommand()),
              // Дисков пока нет: список подключённых пуст (ADR-019).
              cloudDisks: const <CloudDisk>[],
              onConnectDisk: () => unawaited(_explainCloudDisks()),
              onCloudDisk: (CloudDisk disk) => _announce(
                'Выбор файлов с диска «${disk.label}» — следующий этап',
              ),
              onAttach: (PickKind kind) => unawaited(_pickFiles(kind)),
              pending: <PendingAttachmentChip>[
                for (final file in _pendingFiles)
                  PendingAttachmentChip(
                    name: file.name,
                    kind: file.kind,
                    size: file.size,
                  ),
              ],
              onRemovePending: (int i) =>
                  setState(() => _pendingFiles.removeAt(i)),
              voiceMode: _voiceMode,
              voicePartial: _voiceListening ? _voicePartial : null,
              voiceNotice: _voiceNotice,
              onVoiceStart: _voiceDown,
              onVoiceStop: _voiceUp,
              onVoiceTap: _voiceTap,
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
                style: metaTextStyle,
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
                  style: metaTextStyle,
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
            child: Text(label, style: metaTextStyle),
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
                style: metaTextStyle.copyWith(color: AssistantColors.text),
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
    required this.cast,
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
    this.attachments,
    this.commandSpans = const <CommandSpan>[],
  });

  final ChatMessage message;

  /// Распознанные части команды пользователя: моноширинным с мягким
  /// цветом (ADR-021).
  final List<CommandSpan> commandSpans;

  /// Хранилище копий вложений: превью и «файл не найден» (ADR-019).
  final AttachmentStore? attachments;

  /// Состав помощников: старые ответы `rio`/`noda` подписаны текущими
  /// именами.
  final PersonaCast cast;

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
    final author = fromUser ? null : cast.find(message.personaId);
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
                    style: metaTextStyle.copyWith(
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
              style: metaTextStyle.copyWith(color: labelColor),
            ),
          ),
        if (attachments != null && message.attachments.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(
              bottom: message.text.isEmpty ? 0 : 6,
            ),
            child: MessageAttachments(
              attachments: message.attachments,
              store: attachments!,
              alignEnd: fromUser,
            ),
          ),
        if (message.text.isNotEmpty || message.attachments.isEmpty)
          Container(
            padding: fromUser
                ? const EdgeInsets.symmetric(horizontal: 16, vertical: 8)
                : highlighted
                    ? const EdgeInsets.only(left: 10)
                    : EdgeInsets.zero,
            decoration: BoxDecoration(
              color: fromUser ? AssistantColors.bubble : Colors.transparent,
              // Ответ, найденный поиском, — чертой слева: у него нет пузыря.
              border: fromUser
                  ? Border.all(
                      color: highlighted
                          ? AssistantColors.textStrong
                          : AssistantColors.border,
                      width: highlighted ? 1 : .5,
                    )
                  : highlighted
                      ? const Border(
                          left: BorderSide(
                            color: AssistantColors.textStrong,
                            width: 2,
                          ),
                        )
                      : null,
              borderRadius: fromUser
                  ? const BorderRadius.only(
                      topLeft: Radius.circular(16),
                      topRight: Radius.circular(16),
                      bottomLeft: Radius.circular(16),
                      bottomRight: Radius.circular(4),
                    )
                  : null,
            ),
            child: fromUser && commandSpans.isNotEmpty
                ? SelectableText.rich(
                    highlightedCommand(
                      message.text,
                      CommandSpans.normalize(
                        commandSpans,
                        message.text.length,
                      ),
                      const TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        color: AssistantColors.textStrong,
                      ),
                    ),
                  )
                : SelectableText(
                    message.text,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.5,
                      color: fromUser
                          ? AssistantColors.textStrong
                          : AssistantColors.text,
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
              style: metaTextStyle,
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
              style: metaTextStyle.copyWith(height: 1.2),
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
                const Text('«её»', style: metaTextStyle),
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
                      style: metaTextStyle,
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

/// Файл, выбранный для следующего сообщения: источник, имя для показа
/// (без секретов), вид и размер.
typedef _PendingFile = ({
  AttachmentSource source,
  String name,
  AttachmentKind kind,
  int size,
});
