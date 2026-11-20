import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, listEquals, setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/app_info.dart';
import '../core/build_flags.dart';
import '../core/chats/attachments.dart';
import '../core/chats/chat_book.dart';
import '../core/chats/chat_models.dart';
import '../core/chats/chat_projects.dart';
import '../core/chats/chat_search.dart';
import '../core/chats/chat_store.dart';
import '../core/chats/session_files.dart';
import '../core/cloud/cloud_disk.dart';
import '../core/commands/command_catalog.dart';
import '../core/commands/command_suggest.dart';
import '../core/connectors/connector.dart';
import '../core/connectors/login_link.dart';
import '../core/connectors/manifest/connection_service.dart';
import '../core/connectors/manifest/connection.dart';
import '../core/connectors/manifest/connection_slots.dart';
import '../core/connectors/manifest/connection_texts.dart';
import '../core/connectors/manifest/manifest_text.dart';
import '../core/formatting/due_format.dart';
import '../core/homescreen/home_screen_actions.dart';
import '../core/homescreen/home_screen_snapshot.dart';
import '../core/jobs/extension_card.dart';
import '../core/jobs/job_runner.dart';
import '../core/models/action_card.dart';
import '../core/models/bulk.dart';
import '../core/models/secure_card.dart';
import '../core/models/task.dart';
import '../core/notify/reminder_plan.dart';
import '../core/passwords/secret_guard.dart';
import '../core/passwords/vault.dart';
import '../core/replies/reply_library.dart';
import '../core/scenario/assistant_controller.dart';
import '../core/services/clock.dart';
import '../core/services/task_service.dart';
import '../core/settings/app_settings.dart';
import '../core/skills/archiver/zip_ops.dart';
import '../core/skills/converter/convert_targets.dart';
import '../core/skills/converter/ffmpeg_job.dart';
import '../core/skills/converter/image_convert.dart';
import '../core/skills/converter/platform_media_job.dart';
import '../core/models/launch_request.dart';
import '../core/skills/weather/open_meteo_client.dart';
import '../core/skills/ytdl/ytdl_formats.dart';
import '../core/skills/ytdl/ytdl_job.dart';
import '../core/skills/passwords/passwords_phrases.dart';
import '../core/skills/talk/talk_connector.dart';
import '../core/stats/relay_stats.dart';
import '../core/storage/storage_info.dart';
import '../core/voice/voice_recognizer.dart';
import 'assistant_theme.dart';
import 'layout.dart';
import 'widgets/app_dialog.dart';
import 'attachments/attachment_picker.dart';
import 'attachments/attachment_views.dart';
import 'extensions/tool_kit.dart';
import 'extensions/ytdl_kit.dart';
import 'files/file_opener.dart';
import 'homescreen/home_screen_channel.dart';
import 'jobs/job_cards.dart';
import 'jobs/job_hub.dart';
import 'jobs/job_picker.dart';
import 'notify/notify_channel.dart';
import 'notify/notify_views.dart';
import 'passwords/entry_screens.dart';
import 'security/app_lock.dart';
import 'security/device_auth.dart';
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
import 'shell/session_files_panel.dart';
import 'shell/session_header.dart';
import 'shell/session_hero.dart';
import 'shell/today_panel.dart';
import 'extensions/weather_kit.dart';
import 'extensions/weather_screen.dart';
import 'intent/intent_kit.dart';
import 'intent/intent_views.dart';
import 'voice/voice_kit.dart';
import 'voice/voice_views.dart';
import 'widgets/action_card_view.dart';
import 'widgets/bulk_checklist_card.dart';
import 'widgets/chat_feed_rhythm.dart';
import 'widgets/command_composer.dart';
import 'widgets/command_finder_sheet.dart';
import 'widgets/command_highlight.dart';
import 'widgets/connection_screen.dart';
import 'widgets/document_view.dart';
import 'widgets/extensions_section.dart';
import 'widgets/history_rail.dart';
import 'widgets/message_row.dart';
import 'widgets/quick_dock.dart';
import 'widgets/status_cube.dart';
import 'widgets/task_chat_header.dart';
import 'widgets/grouped.dart';
import 'widgets/task_tile.dart';
import 'widgets/weather_card_view.dart';
import 'widgets/warehouse_card_view.dart';
import 'widgets/connections_host.dart';
import 'shell/incoming_connect.dart';
import '../core/connectors/manifest/app_connections.dart';
import 'widgets/qr_scan_sheet.dart';
import 'links/incoming_links.dart';
import 'links/link_opener.dart';
import '../core/connectors/manifest/warehouse_signals.dart';
import 'widgets/whole_word_text.dart';
import 'network_status.dart';
import 'widgets/network_capsule.dart';

/// Разделы оболочки «Д»: сессия (главный экран), задачи, проекты,
/// экран одного проекта-папки, планирование и «Мой Связной».
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
/// нет: всё оттуда — в «Мой Связной» → «Сводка».
const double wideBreakpoint = 1000;

/// Ширина, начиная с которой колонка «Сегодня» открыта сразу; уже — она
/// свёрнута, пока её не откроют кнопкой «Показать «Сегодня»» в шапке.
const double todayOpenBreakpoint = 1280;

/// Ширина, ниже которой окно — узкое (телефон): «⋯» прячется, пока в
/// шапке задача.
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
const double chatInset = AppSpace.pageH;

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
    this.intent,
    this.jobRunner,
    this.jobPicker = const FileSelectorJobPicker(),
    this.fileOpener,
    this.jobPlatform,
    this.tempRoot,
    this.ffmpeg,
    this.nativeMedia,
    this.ytdl,
    this.weather,
    this.notify,
    this.homeScreen,
    this.appLock,
    this.incoming,
    this.signals = const <WarehouseSignals>[],
    this.network,
    this.appConnections,
    this.onAppearanceChanged,
    this.onReduceMotionChanged,
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

  /// Связь со складом (ADR-040): без неё над полем ввода — капсула «Нет
  /// сети»; `null` — капсулы нет.
  final NetworkStatus? network;

  /// Каталог подключений (ADR-043): «Подключения», «Подключить
  /// приложение», входящие ссылки чужих приложений. `null` — только
  /// подключения из [connections] (тесты, прежнее поведение).
  final AppConnections? appConnections;

  /// Выбор файлов для «+» → «Прикрепить файл» (ADR-019); в тестах —
  /// подделка.
  final AttachmentPicker attachmentPicker;

  /// Голосовой ввод (ADR-023): модель и распознаватель; `null` — на этой
  /// платформе движка нет, микрофон скрыт.
  final VoiceKit? voice;

  /// Модель понимания (ADR-045): «Настройки → Понимание фраз»; `null` —
  /// раздела нет.
  final IntentKit? intent;

  /// Исполнитель задач расширений (архиватор); по умолчанию — изоляты.
  final JobRunner? jobRunner;

  /// Выбор файлов и мест для карточек расширений; в тестах — подделка.
  final JobFilePicker jobPicker;

  /// «Открыть» и «Открыть папку» у результата; по умолчанию — системные.
  final FileOpener? fileOpener;

  /// Платформа для карточек расширений; по умолчанию — это устройство.
  final JobPlatform? jobPlatform;

  /// Временная папка приложения; по умолчанию — path_provider.
  final Future<String> Function()? tempRoot;

  /// ffmpeg для конвертера (ADR-024): скачивается по кнопке в «Настройки
  /// → Расширения → Конвертер»; `null` — платформа без ffmpeg (Android,
  /// macOS): там звук и видео делает система ([nativeMedia]).
  final ToolKit? ffmpeg;

  /// Конвертер звука и видео средствами системы (ADR-026): MediaCodec и
  /// LAME на телефоне, AVFoundation на Mac; `null` — его нет, тогда там
  /// конвертируются только картинки.
  final NativeMedia? nativeMedia;

  /// Загрузчик видео (ADR-024, шаг 3): yt-dlp и папка загрузок; `null` —
  /// в этой сборке или на этой платформе загрузчика нет (Android, macOS,
  /// сборка для Google Play).
  final YtdlKit? ytdl;

  /// Погода (ADR-030): настройки, карточка и открытие своей страницы или
  /// приложения; `null` — навыка нет (тесты).
  final WeatherKit? weather;

  /// Вход в приложение по отпечатку / Face ID (ADR-025); `null` — нет.
  final AppLockController? appLock;

  /// «Открыть в Tridot» и «Поделиться» ссылкой или QR склада (ADR-031);
  /// `null` — нет (тесты, Windows, Linux).
  final IncomingLinks? incoming;

  /// Сигналы склада, только пока приложение на экране (ADR-031).
  final List<WarehouseSignals> signals;

  /// Системные уведомления о задачах и будильник (ADR-029); `null` — их
  /// нет (тесты, Windows, Linux).
  final NotifyPlatform? notify;

  /// Виджеты рабочего стола (ADR-034): снимок «Сегодня», отметки с
  /// виджета, «открыть поле» и «начать слушать»; `null` — их нет (тесты,
  /// всё, кроме Android).
  final HomeScreenPlatform? homeScreen;

  /// Оформление сменилось в настройках (или прочитано с диска): приложение
  /// перекрашивает тему ([AppAppearance], ADR-027).
  final ValueChanged<AppAppearance>? onAppearanceChanged;

  /// «Меньше анимации» сменилось (или прочитано): смена темы — без
  /// перетекания цветов (§5.6).
  final ValueChanged<bool>? onReduceMotionChanged;

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

  /// Заехал ли контент раздела под шапку: только тогда под ней линия
  /// (§4.1) — на пустой сессии и в начале ленты шапки не отделить.
  final ValueNotifier<bool> _underHeader = ValueNotifier<bool>(false);
  Object? _headerView;
  final ScrollController _chatScroll = ScrollController();

  /// Прокрутка «Документа».
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

  /// Задачи расширений (архиватор, конвертер): состояние карточек и их
  /// сохранение. Картинки и ZIP — в изолятах, звук и видео — процессом
  /// ffmpeg.
  late final JobHub _jobHub = JobHub(
    runner: widget.jobRunner ?? _defaultJobRunner(),
    persist: (String chatId) {
      _book.touch(chatId);
      unawaited(_book.flush());
    },
    now: () => _now,
  );

  JobRunner _defaultJobRunner() {
    final isolates = IsolateJobRunner(<String, JobWork>{
      ExtensionForms.archiver: ZipOps.run,
      ExtensionForms.converter: ConvertOps.run,
    });
    final ffmpeg = widget.ffmpeg;
    final processes = FfmpegJobRunner(
      ffmpegPath: () async => ffmpeg?.verifiedPath(),
    );
    // Загрузчик видео — только вне сборки для Google Play и только там,
    // где он есть (ADR-024): в сборке для Play его код выбрасывается.
    final ytdl = kPlayBuild ? null : widget.ytdl;
    final downloads = ytdl == null
        ? null
        : YtdlJobRunner(
            ytdlpPath: () async => ytdl.tool.verifiedPath(),
            ffmpegPath: () async => ffmpeg?.verifiedPath(),
          );
    final native = widget.nativeMedia?.runner;
    final platform = widget.jobPlatform ?? currentJobPlatform();
    // Звук и видео: на телефоне и Mac — система, на компьютере — ffmpeg.
    final nativePlatform =
        platform == JobPlatform.android || platform == JobPlatform.macos;
    return JobRunnerRouter((JobRequest request) {
      if (request.extensionId == ExtensionForms.ytdl) {
        return downloads ?? isolates;
      }
      if (request.extensionId != ExtensionForms.converter ||
          ConvertOps.usesDart(request)) {
        return isolates;
      }
      if (nativePlatform) return native ?? isolates;
      return processes;
    });
  }

  late final JobPlatform _jobPlatform =
      widget.jobPlatform ?? currentJobPlatform();

  /// Карточки расширений в ленте.
  late final JobCards _jobCards = JobCards(
    hub: _jobHub,
    platform: _jobPlatform,
    picker: widget.jobPicker,
    opener: widget.fileOpener ?? FileOpener(platform: _jobPlatform),
    attachments: () => _book.store.attachments,
    tools: () => <String>{
      if (widget.ffmpeg?.isInstalled ?? false) ConvertTargets.ffmpeg,
      ...?widget.nativeMedia?.caps.toTools(),
      if (widget.ytdl?.tool.isInstalled ?? false) YtdlFormats.tool,
    },
    downloadsDir: widget.ytdl == null ? null : () => widget.ytdl!.folder(),
    // Карточка выключенного расширения остаётся в чате, но не запускается.
    isEnabled: (String id) => widget.assistant.extensions.isEnabled(id),
    tempRoot:
        widget.tempRoot ?? () async => (await getTemporaryDirectory()).path,
    onFinished: _onJobFinished,
    onMessage: (String text) {
      if (mounted) _announce(text);
    },
    formDefaults: () => _settings.formDefaults,
    onFormDefault: _rememberFormDefault,
  );

  /// Последний выбор в карточке (качество, сжатие) — в настройки: новая
  /// карточка начнёт с него.
  void _rememberFormDefault(String key, String value) {
    if (_settings.formDefaults[key] == value) return;
    final settings = _settings.copyWith(
      formDefaults: AppSettings.cleanFormDefaults(<String, String>{
        ..._settings.formDefaults,
        key: value,
      }),
    );
    _settings = settings;
    unawaited(_settingsStore.save(settings));
  }

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

  /// Голосовой ввод (ADR-023): слушает, готовится (доступ, модель), что
  /// слышно сейчас. Звук и текст живут только в памяти.
  bool _voiceListening = false;
  bool _voiceLoading = false;
  String _voicePartial = '';

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

  /// Автостоп (ADR-023): микрофон включается нажатием, и его легко
  /// забыть включённым. Тишина — промежуточный текст не менялся
  /// [_voiceSilence] (а речи ещё не было — [_voiceNoSpeech]); слушает
  /// дольше [_voiceMaxListen] — тоже стоп. Стоп — с итогом, как нажатие.
  Timer? _voiceSilenceTimer;
  Timer? _voiceMaxTimer;
  static const Duration _voiceSilence = Duration(seconds: 8);
  static const Duration _voiceNoSpeech = Duration(seconds: 10);
  static const Duration _voiceMaxListen = Duration(seconds: 60);

  /// Почему микрофон выключился сам: строка для подсказки, когда придёт
  /// итог.
  String? _voiceAutoStop;

  /// Лист загрузки скрыт, а модель ещё качается: о готовности скажем.
  bool _voiceAwaitInstall = false;

  /// Колонка «Сегодня» на широком экране: `null` — пользователь не
  /// выбирал (открыта от [todayOpenBreakpoint]).
  bool? _todayOpen;

  /// Колонка «Файлы сессии» на компьютере: `null` — пока не выбирал
  /// (открыта от [todayOpenBreakpoint]).
  bool? _filesOpen;

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
    // «Удали этот файл» (ADR-028): навык спрашивает, удаляет лента.
    widget.assistant.session.fileRemover = _fileRemover;
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
    _followSessions();
    widget.appConnections?.addListener(_onAppsChanged);
    _jobHub.addListener(_onJobsChanged);
    _book.onThreadLoaded = _sweepInterruptedJobs;
    widget.ffmpeg?.addListener(_onJobsChanged);
    widget.ytdl?.tool.addListener(_onJobsChanged);
    _settingsReady = _loadSettings();
    _chatsReady = _loadChats();
    // Сначала отметки с виджета, потом первое чтение задач (ADR-034).
    unawaited(_drainHomeScreen());
    _openedTask = _notify.openedTask.listen(
      (String taskId) => unawaited(_openNotifiedTask(taskId)),
    );
    unawaited(_openLaunchTask());
    _listenHomeScreen();
    // Склад (ADR-031): ссылка «Открыть в Tridot» — окно подтверждения;
    // сигналы — только пока приложение на экране.
    final incoming = widget.incoming;
    if (incoming != null) {
      _incoming = incoming.items.listen(
        (IncomingItem item) => unawaited(_onIncoming(item)),
      );
      unawaited(_openLaunchLink(incoming));
    }
    for (final signals in widget.signals) {
      signals
        ..onNews = _onWarehouseNews
        ..resume();
    }
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

  // -------------------------------------------- уведомления (ADR-029)

  NotifyPlatform get _notify => widget.notify ?? const UnsupportedNotify();

  StreamSubscription<String>? _openedTask;

  StreamSubscription<IncomingItem>? _incoming;

  /// Открывает страницу склада: у погоды — свой, иначе — системный.
  late final LinkOpener _links =
      widget.weather?.links ?? LinkOpener(platform: currentJobPlatform());

  ConnectionService? _connectionOf(String id) => widget.connections
      .where((ConnectionService c) => c.slot.id == id)
      .firstOrNull;

  /// Подключения, чей вход слушаем ([_onSessionChanged]): и те, что
  /// подключили, пока приложение открыто (ADR-043).
  final Set<ConnectionService> _sessionFollowed = <ConnectionService>{};

  void _followSessions() {
    final live = widget.connections.toSet();
    for (final gone in _sessionFollowed.difference(live).toList()) {
      gone.removeSessionListener(_onSessionChanged);
      _sessionFollowed.remove(gone);
    }
    for (final added in live.difference(_sessionFollowed)) {
      added.addSessionListener(_onSessionChanged);
      _sessionFollowed.add(added);
    }
  }

  /// Подключили или удалили приложение: слушать его вход, меню и списки —
  /// заново.
  void _onAppsChanged() {
    _followSessions();
    if (mounted) setState(() {});
  }

  /// Экраны подключений (ADR-043); `null` — каталога нет.
  late final ConnectionsHost? _connectionsHost =
      switch (widget.appConnections) {
    final AppConnections apps => ConnectionsHost(
        apps: apps,
        registry: widget.assistant.extensions,
        settings: () => _settings,
        onChanged: (AppSettings value) {
          if (mounted) _changeSettings(value);
        },
      ),
    null => null,
  };

  /// Тексты карточки подключения [id]: склад — прежние, приложение — со
  /// своим именем; подключение удалено — о «приложении» (ADR-043).
  ConnectionTexts _textsOf(String id) =>
      _connectionOf(id)?.texts ??
      (id == ConnectionSlots.warehouse.id
          ? ConnectionTexts.warehouse
          : ConnectionTexts.app);

  void _quietNote(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 5)),
    );
  }

  Future<void> _openLaunchLink(IncomingLinks incoming) async {
    await _settingsReady;
    final item = await incoming.initial();
    if (item != null) await _onIncoming(item);
  }

  /// Ссылка или QR склада извне: строгий разбор, окно подтверждения с
  /// хостом и только потом вход. Картинка — разбор QR на устройстве, копия
  /// удаляется.
  Future<void> _onIncoming(IncomingItem item) async {
    var text = item.text;
    if (item.kind == IncomingKind.image) {
      text = await decodeQrImage(item.path!);
      await IncomingLinks.forget(item);
    }
    if (!mounted) return;
    final service = _connectionOf('warehouse');
    await _settingsReady;
    if (!mounted) return;
    // Склад — как раньше; чужое приложение — только через согласие
    // (ADR-043, lib/app/shell/incoming_connect.dart).
    final note = await handleIncomingConnect(
      context,
      text: text,
      image: item.kind == IncomingKind.image,
      warehouse: service,
      host: _connectionsHost,
      onWarehouseEnabled: (bool value) {
        if (!mounted || service == null) return;
        _changeSettings(
          connectionChanged(
            widget.assistant.extensions,
            _settings,
            service.slot.id,
            connected: value,
          ),
        );
      },
    );
    if (note != null) _quietNote(note);
  }

  /// Новые приходы, пока приложение открыто: тихая строка, без
  /// уведомлений системы.
  void _onWarehouseNews(WarehouseSignal signal) {
    if (!mounted) return;
    final n = signal.newArrivals;
    _quietNote(
      widget.assistant.session.say(
        'warehouse.signal.arrivals',
        <String, String>{
          // «3 новых прихода», «5 новых приходов»: «На складе новое: …».
          'list': n == 1
              ? 'новый приход'
              : askPlural(n, 'новый приход,новых прихода,новых приходов'),
        },
      ),
    );
  }

  /// Расписание, отданное системе последним: тот же план не шлётся
  /// повторно.
  List<Reminder>? _syncedPlan;
  Set<String> _syncedSnoozable = const <String>{};

  /// Лист «Напоминания вовремя» открыт.
  bool _notifyAsking = false;

  /// Расписание напоминаний — заново из активных задач. Только после
  /// загрузки задач и настроек; тот же план не отправляется второй раз.
  void _syncReminders() {
    if (!_notify.supported || !_loaded || !_settingsLoaded) return;
    final plan = ReminderPlan.from(
      _active,
      now: _now,
      persona: _settings.personas.notifier.russianName,
      dateOnlyHour:
          _settings.notifyDateOnly ? _settings.notifyDateOnlyHour : null,
    );
    final snoozable = ReminderPlan.snoozable(_active, now: _now);
    final synced = _syncedPlan;
    if (synced != null &&
        listEquals(synced, plan) &&
        setEquals(_syncedSnoozable, snoozable)) {
      return;
    }
    _syncedPlan = plan;
    _syncedSnoozable = snoozable;
    unawaited(_notify.sync(plan, snoozable: snoozable));
  }

  /// Ответ создал задачу или перенёс её на будущее: в первый раз —
  /// объяснить, зачем уведомления, и спросить (не при запуске и не чаще
  /// раза в день после «Не сейчас»).
  Future<void> _askNotifyFor(AssistantResponse response) async {
    final due = response.task?.dueAt;
    if (!_notify.supported ||
        _notifyAsking ||
        response.status != AssistantStatus.completed ||
        due == null ||
        !due.isAfter(_now)) {
      return;
    }
    if (_settings.notifyDismissedDay == AppSettings.dayKey(_now)) return;
    final status = await _notify.status();
    if (!mounted) return;
    final chatId = _book.currentId;
    if (status == NotifyPermission.permanentlyDenied &&
        _settings.notifyExplained) {
      // Уже объясняли, а уведомления выключены в настройках системы: одна
      // строка в день вместо листа.
      _changeSettings(
        _settings.copyWith(notifyDismissedDay: AppSettings.dayKey(_now)),
      );
      _notifierLine(chatId, 'notify.off');
      return;
    }
    // Выключены в системе ещё до первого объяснения (Android 12 и раньше,
    // Mac после переустановки): лист сам откроется на «Открыть настройки».
    if (!status.canAsk && status != NotifyPermission.permanentlyDenied) {
      return;
    }
    _notifyAsking = true;
    final NotifyOutcome outcome;
    try {
      outcome = await showNotifyRationale(
        context,
        platform: _notify,
        notifier: _settings.personas.notifier,
      );
    } finally {
      _notifyAsking = false;
    }
    if (!mounted) return;
    _changeSettings(
      _settings.copyWith(
        notifyExplained: true,
        notifyDismissedDay:
            outcome == NotifyOutcome.granted ? null : AppSettings.dayKey(_now),
      ),
    );
    if (outcome == NotifyOutcome.granted) {
      _syncedPlan = null;
      _syncReminders();
      _notifierLine(chatId, 'notify.granted');
      if (await _notify.exactStatus() == ExactAlarm.denied && mounted) {
        _notifierLine(chatId, 'notify.exactOff');
      }
    }
  }

  /// Строка ведущего оповещений в чат [chatId].
  void _notifierLine(String chatId, String replyId) {
    final line = _answer(widget.assistant.notifierSays(replyId));
    setState(() => _book.append(chatId, line));
    _scrollToLatest();
  }

  /// Нажато уведомление о задаче: открыть её чат.
  Future<void> _openNotifiedTask(String taskId) async {
    try {
      await _chatsReady;
    } on Object {
      // Чаты не прочитались — откроем, что есть.
    }
    if (!mounted) return;
    var task = _findTask(taskId);
    if (task == null) {
      await _refresh();
      if (!mounted) return;
      task = _findTask(taskId);
    }
    if (task == null) return;
    _openTaskChat(task, mode: AssistantViewMode.dialogue);
  }

  /// Приложение открыли нажатием на уведомление.
  Future<void> _openLaunchTask() async {
    final taskId = await _notify.takeLaunchTask();
    if (taskId != null) await _openNotifiedTask(taskId);
  }

  // ------------------------------------- виджеты рабочего стола (ADR-034)

  HomeScreenPlatform get _homeScreen =>
      widget.homeScreen ?? const UnsupportedHomeScreen();

  final List<StreamSubscription<Object?>> _homeScreenEvents =
      <StreamSubscription<Object?>>[];

  /// Замок, за которым следит ожидающее нажатие с виджета.
  AppLockController? _homeLock;

  /// Состояние приложения: `null` — система ещё не сообщала (считается,
  /// что приложение на экране).
  AppLifecycleState? _lifecycle = WidgetsBinding.instance.lifecycleState;

  void _listenHomeScreen() {
    final homeScreen = _homeScreen;
    if (!homeScreen.supported) return;
    _homeScreenEvents
      ..add(homeScreen.launches.listen(_onHomeScreenLaunch))
      ..add(
        homeScreen.pendingChanged.listen(
          (_) => unawaited(_drainHomeScreen()),
        ),
      )
      ..add(
        homeScreen.snapshotWanted.listen((_) {
          // Виджет только что поставили: снимок нужен, даже если он не
          // менялся.
          _syncedHomeScreen = null;
          _syncHomeScreen();
        }),
      );
    _homeLock = widget.appLock?..addListener(_onHomeLockChanged);
    unawaited(_takeHomeScreenLaunch());
  }

  /// Снимок, отданный системе последним: тот же не шлётся повторно.
  String? _syncedHomeScreen;
  bool? _syncedHomeVoice;

  /// Последняя отправка снимка: подтверждение отметок ждёт её.
  Future<void> _homeScreenSent = Future<void>.value();

  /// Микрофон на виджете нужен: голосовой ввод на устройстве есть.
  bool get _homeScreenVoice {
    final voice = widget.voice;
    return voice != null && voice.support != VoiceSupport.unsupported;
  }

  /// Снимок «Сегодня» для виджетов — заново из активных задач. Только
  /// после загрузки задач и настроек; тот же снимок не отправляется второй
  /// раз. Текст задач в нём — только с «Показывать текст задач» и без
  /// входа по отпечатку: иначе одни числа.
  void _syncHomeScreen() {
    final homeScreen = _homeScreen;
    if (!homeScreen.supported ||
        !_loaded ||
        !_settingsLoaded ||
        _loadError != null) {
      return;
    }
    final voice = _homeScreenVoice;
    final snapshot = HomeScreenPlan.from(
      _active,
      now: _now,
      showText: _settings.homeScreenText,
      voice: voice,
    );
    final encoded = snapshot.encode();
    _syncedHomeVoice = voice;
    if (encoded == _syncedHomeScreen) return;
    _syncedHomeScreen = encoded;
    _homeScreenSent = homeScreen.sync(snapshot).catchError((Object _) {});
  }

  bool _homeDraining = false;
  bool _homeDrainAgain = false;

  /// Отметки с виджета и свежий список задач, строго по порядку: очередь
  /// → задачи → чтение (с ним уходит новый снимок) → подтверждение. Без
  /// сообщения в чат и без уведомления: человек отметил задачу сам и не в
  /// приложении. Два разбора сразу не идут — второй встаёт следом.
  ///
  /// Где виджетов нет, это просто чтение задач.
  Future<void> _drainHomeScreen() async {
    final homeScreen = _homeScreen;
    if (!homeScreen.supported) {
      await _refresh();
      return;
    }
    if (_homeDraining) {
      _homeDrainAgain = true;
      return;
    }
    _homeDraining = true;
    try {
      do {
        _homeDrainAgain = false;
        var ops = const <HomeScreenOp>[];
        try {
          ops = await homeScreen.pending();
        } on Object {
          // Очередь не прочиталась — останется до другого раза.
        }
        if (!mounted) return;
        final applied = await HomeScreenActions.apply(ops, widget.tasks);
        if (!mounted) return;
        applied.completed.forEach(widget.assistant.forgetTask);
        await _refresh();
        if (!mounted) return;
        final upTo = applied.upTo;
        if (upTo != null) {
          // Подтверждение — только после снимка без этих задач, иначе
          // строка на миг вернулась бы на виджет. Снимок ждёт настроек
          // (показывать ли текст), значит, и подтверждение — тоже.
          try {
            await _settingsReady;
          } on Object {
            // Не прочитались — снимок уйдёт, когда прочитаются.
          }
          if (!mounted) return;
          _syncHomeScreen();
          await _homeScreenSent;
          await homeScreen.ack(upTo);
        }
      } while (_homeDrainAgain && mounted);
    } on Object {
      // Не подтвердили — очередь придёт ещё раз, повтор ничего не изменит.
    } finally {
      _homeDraining = false;
    }
  }

  /// Нажатие на виджете, которое ещё не выполнено: приложение не на
  /// экране, заперто или настройки ещё читаются.
  HomeScreenLaunch? _homeLaunch;
  Timer? _homeLaunchTimer;

  /// Дольше нажатие не ждёт: микрофон не должен включиться спустя минуты.
  static const Duration _homeLaunchLimit = Duration(seconds: 60);

  Future<void> _takeHomeScreenLaunch() async {
    final launch = await _homeScreen.takeLaunch();
    if (launch != null && mounted) _onHomeScreenLaunch(launch);
  }

  void _onHomeScreenLaunch(HomeScreenLaunch launch) {
    _homeLaunch = launch;
    _homeLaunchTimer?.cancel();
    _homeLaunchTimer = Timer(_homeLaunchLimit, _dropHomeScreenLaunch);
    unawaited(_tryHomeScreenLaunch());
  }

  void _dropHomeScreenLaunch() {
    _homeLaunch = null;
    _homeLaunchTimer?.cancel();
    _homeLaunchTimer = null;
  }

  void _onHomeLockChanged() {
    if (_homeLaunch != null) unawaited(_tryHomeScreenLaunch());
  }

  /// Выполняет ждущее нажатие, когда всё готово: настройки и чаты
  /// прочитаны (иначе голосовой ввод выглядел бы выключенным),
  /// приложение на экране (в фоне микрофон не слушает) и не заперто.
  /// Не готово — нажатие ждёт следующего повода: возврата на экран или
  /// открытия замка.
  Future<void> _tryHomeScreenLaunch() async {
    if (_homeLaunch == null) return;
    try {
      await _settingsReady;
    } on Object {
      // Не прочитались — с настройками по умолчанию.
    }
    try {
      await _chatsReady;
    } on Object {
      // Чаты не прочитались — в пустую сессию.
    }
    if (!mounted) return;
    final launch = _homeLaunch;
    if (launch == null) return;
    final state = _lifecycle;
    if (state != null && state != AppLifecycleState.resumed) return;
    if (widget.appLock?.locked ?? false) return;
    _dropHomeScreenLaunch();
    _composeFromHomeScreen(voice: launch == HomeScreenLaunch.voice);
  }

  /// «Что сделать?» и микрофон на виджете: пустая сессия и сразу поле
  /// ввода с клавиатурой или голосовой ввод. Единственный случай, когда
  /// клавиатура на телефоне открывается без нажатия на поле: человек
  /// только что нажал на поле виджета ([_focusInputWithKeyboard]).
  ///
  /// Всегда новая или пустая сессия, а не чат задачи: «что сделать» — это
  /// новое дело, а не запись в открытую задачу.
  void _composeFromHomeScreen({required bool voice}) {
    // Поверх открыт другой экран (сейф, карточка подключения, лист):
    // приложение просто вышло на экран. Закрывать чужой экран нельзя — в
    // нём может быть недописанное.
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    _switchChat(_book.newSession, mode: AssistantViewMode.dialogue);
    if (voice) {
      switch (_voiceMode) {
        case VoiceButtonMode.off:
          unawaited(_offerVoice());
          return;
        case VoiceButtonMode.idle:
          unawaited(_startVoice());
          return;
        case VoiceButtonMode.loading:
        case VoiceButtonMode.listening:
          return;
        case VoiceButtonMode.hidden:
          // Голосового ввода нет — остаётся поле.
          break;
      }
    }
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) return;
        _inputFocus.requestFocus();
      })
      ..ensureVisualUpdate();
  }

  @override
  void dispose() {
    if (identical(widget.assistant.session.fileRemover, _fileRemover)) {
      widget.assistant.session.fileRemover = null;
    }
    unawaited(_openedTask?.cancel());
    unawaited(_incoming?.cancel());
    for (final subscription in _homeScreenEvents) {
      unawaited(subscription.cancel());
    }
    _homeLaunchTimer?.cancel();
    _homeLock?.removeListener(_onHomeLockChanged);
    for (final signals in widget.signals) {
      signals.pause();
      if (signals.onNews == _onWarehouseNews) signals.onNews = null;
    }
    widget.ffmpeg?.removeListener(_onJobsChanged);
    widget.ytdl?.tool.removeListener(_onJobsChanged);
    _jobHub
      ..removeListener(_onJobsChanged)
      ..dispose();
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    widget.voice?.removeListener(_onVoiceChanged);
    // Уходя, микрофон не оставляем включённым.
    _voiceNoticeTimer?.cancel();
    _voiceSilenceTimer?.cancel();
    _voiceMaxTimer?.cancel();
    _voiceAttempt++;
    if (_voiceListening || _voiceLoading) {
      unawaited(_voiceEvents?.cancel());
      unawaited((_voiceRecognizer ?? widget.voice?.active)?.cancel());
    }
    _dataRevision.dispose();
    _underHeader.dispose();
    WidgetsBinding.instance.removeObserver(this);
    widget.passwords?.removeListener(_onPasswordsChanged);
    if (widget.passwords?.onSettings == _onPasswordsSettings) {
      widget.passwords?.onSettings = null;
    }
    widget.appConnections?.removeListener(_onAppsChanged);
    for (final connection in _sessionFollowed) {
      connection.removeSessionListener(_onSessionChanged);
    }
    _sessionFollowed.clear();
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
    _lifecycle = state;
    // Хранилище паролей: фон и «спрятано» запирают, потеря фокуса прячет
    // показанное (3.6).
    widget.passwords?.lifecycle.onAppState(state);
    // Сигналы склада — только пока приложение на экране (ADR-031).
    for (final signals in widget.signals) {
      if (state == AppLifecycleState.resumed) {
        signals.resume();
      } else if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.hidden ||
          state == AppLifecycleState.detached) {
        signals.pause();
      }
    }
    if (state == AppLifecycleState.resumed) {
      // Отметки с виджета — до свежего списка задач (ADR-034).
      unawaited(_drainHomeScreen());
      _preloadVoice();
      // После системной загрузки русского языка распознавание телефона
      // могло стать готовым.
      unawaited(widget.voice?.refreshDevice());
      // Нажатие на виджете ждало, пока приложение выйдет на экран. Замок
      // узнаёт о возврате тем же событием — пусть сначала решит он.
      if (_homeLaunch != null) scheduleMicrotask(_tryHomeScreenLaunch);
    }
    if (state == AppLifecycleState.paused) {
      _saveDocument();
      // Ушли, не дождавшись: микрофон через минуту сам не включится.
      // Системный запрос отпечатка — не уход.
      if (!SystemAuthGuard.busy) _dropHomeScreenLaunch();
    }
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
    // Идущие задачи останавливаются: ffmpeg и yt-dlp — отдельные
    // процессы и без этого работали бы после выхода, а карточка
    // показывала бы «Прервано». Временные файлы убирает отмена.
    _jobHub.cancelAll();
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
        // Ответ склада с карточкой (ADR-031): строки — в карточке, в
        // пузыре только итог.
        text: response.warehouse == null
            ? response.message
            : response.message.split('\n').first,
        timestamp: _now,
        status: withStatus ? response.status : null,
        taskId: response.task?.id,
        personaId: response.personaId,
        checklist: response.checklist,
        card: response.card,
        secureCard: response.secureCard,
        clarification: response.clarification,
        suggestions: response.suggestions,
        job: response.job,
        weather: response.weather,
        warehouse: response.warehouse,
      );

  // --------------------------------------------------------------- погода

  /// Карточки погоды, которые сейчас обновляются.
  final Set<String> _weatherRefreshing = <String>{};

  /// Открыть страницу или приложение погоды после живого ответа; не
  /// открылось — строка тем же голосом следом (ADR-030).
  Future<void> _launchWeather(
    LaunchRequest request,
    String chatId,
    String? personaId,
  ) async {
    final kit = widget.weather;
    final outcome =
        kit == null ? WeatherLaunch.linkFailed : await kit.launch(request);
    _weatherFollowUp(outcome, chatId, personaId);
  }

  void _weatherFollowUp(
    WeatherLaunch outcome,
    String chatId,
    String? personaId,
  ) {
    final id = outcome.followUpId;
    if (id == null || !mounted) return;
    setState(() {
      _book.append(chatId, _answer(widget.assistant.followUp(id, personaId)));
    });
    _scrollToLatest();
  }

  Future<void> _openWeatherSettings() async {
    final kit = widget.weather;
    if (kit == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => WeatherScreen(kit: kit),
      ),
    );
  }

  /// «Обновить»: новый снимок в том же сообщении, чат сохраняется.
  Future<void> _refreshWeather(String chatId, ChatMessage message) async {
    final kit = widget.weather;
    final place = message.weather?.forecast?.place;
    if (kit == null || place == null) return;
    setState(() => _weatherRefreshing.add(message.id));
    final result = await kit.refresh(place);
    if (!mounted) return;
    setState(() {
      _weatherRefreshing.remove(message.id);
      final forecast = result.forecast;
      if (forecast != null) {
        _book.replace(
          chatId,
          message.id,
          message.withWeather(
            message.weather!.refreshed(forecast, stale: result.stale),
          ),
        );
      }
    });
    if (result.forecast == null || result.stale) {
      _announce(
        weatherErrorText(result.error ?? WeatherError.failed),
      );
    }
  }

  /// Карточка ответа склада (ADR-031): «Открыть склад» — страница
  /// склада из подключения, только https.
  Widget? _warehouseCard(ChatMessage message) {
    final card = message.warehouse;
    if (card == null) return null;
    final base = _connectionOf(card.connector)?.record.baseUri;
    return WarehouseCardView(
      key: ValueKey<String>('warehouse-${message.id}'),
      card: card,
      texts: _textsOf(card.connector),
      // Итог уже в пузыре над карточкой — второй раз его не пишем.
      showSay: card.say.trim() != message.text.trim(),
      onOpen: base == null || base.scheme != 'https'
          ? null
          : () => unawaited(_links.openUrl(base.toString())),
    );
  }

  Widget? _weatherCard(ChatMessage message) {
    final card = message.weather;
    if (card == null) return null;
    final kit = widget.weather;
    final chatId = _book.currentId;
    final link = kit?.settings.link;
    return WeatherCardView(
      key: ValueKey<String>('weather-${message.id}'),
      card: card,
      compact: MediaQuery.sizeOf(context).width < wideBreakpoint,
      busy: _weatherRefreshing.contains(message.id),
      onRefresh: kit == null
          ? null
          : () => unawaited(_refreshWeather(chatId, message)),
      onMore: kit == null || link == null
          ? null
          : () => unawaited(
                kit.launch(LaunchRequest.url(link)).then(
                      (WeatherLaunch o) =>
                          _weatherFollowUp(o, chatId, message.personaId),
                    ),
              ),
      onOpenSite: kit == null
          ? null
          : () => unawaited(kit.links.openUrl(OpenMeteo.siteUrl)),
      onOpenAgain: kit == null
          ? null
          : () => unawaited(
                kit.openAgain().then(
                      (WeatherLaunch o) =>
                          _weatherFollowUp(o, chatId, message.personaId),
                    ),
              ),
      onSetup: kit == null ? null : () => unawaited(_openWeatherSettings()),
    );
  }

  // --------------------------------------------------- карточки расширений

  void _onJobsChanged() {
    if (mounted) setState(() {});
  }

  /// Задача карточки закончилась: короткое сообщение, если результат
  /// готов, а чат не на экране.
  void _onJobFinished(String chatId, ExtensionCard card) {
    if (!mounted) return;
    if (card.state == CardState.done &&
        (chatId != _book.currentId || _section != AppSection.session) &&
        card.outputs.isNotEmpty) {
      _announce(
        widget.assistant.jobDoneNote(
          card.outputs.first.split(RegExp(r'[/\\]')).last,
          null,
          extensionId: card.extensionId,
        ),
      );
    }
  }

  /// Файлы сессии [chatId] для карточек: из недавних сообщений, новые
  /// первыми не идут — по порядку.
  List<JobFile> _sessionFiles(String chatId, {String? skipMessageId}) {
    final thread = _book.thread(chatId);
    if (thread == null) return const <JobFile>[];
    final files = <JobFile>[
      for (final message in thread.messages)
        if (message.id != skipMessageId)
          for (final attachment in message.attachments)
            JobFile(
              path: attachment.path,
              name: attachment.name,
              attachment: true,
            ),
    ];
    return files.length <= 20 ? files : files.sublist(files.length - 20);
  }

  /// «Файлы сессии» [chatId] для навыков, новые первыми: по ним «удали
  /// этот файл» находит результат карточки или вложение (ADR-028).
  List<SessionFileRef> _recentFiles(String chatId) {
    final thread = _book.thread(chatId);
    if (thread == null) return const <SessionFileRef>[];
    final lists = SessionFiles.of(thread);
    final files = <SessionFile>[...lists.outputs, ...lists.attachments]
      ..sort((SessionFile a, SessionFile b) => b.at.compareTo(a.at));
    return <SessionFileRef>[
      for (final file in files.take(20))
        SessionFileRef(
          id: file.id,
          name: file.name,
          output: file.isOutput,
          path: file.absolute,
          extensionId: file.extensionId,
          messageId: file.messageId,
        ),
    ];
  }

  late final SessionFileRemover _fileRemover =
      _SessionFileRemover(_removeSessionFile);

  /// Удаляет файл сессии после подтверждения: результат — с диска и из
  /// карточки, вложение — из сообщения вместе с копией приложения.
  /// Исходник пользователя не трогается: у вложения это чужой файл, а
  /// результат карточки — новый файл, сделанный приложением. Папку
  /// результата (распакованный архив) так не удалить.
  Future<bool> _removeSessionFile(SessionFileRef ref) async {
    final chatId = _workingChatId ?? _book.currentId;
    final thread = _book.thread(chatId);
    final messageId = ref.messageId;
    if (thread == null || messageId == null) return false;
    if (!ref.output) {
      final attachmentId = ref.id.startsWith('att:') ? ref.id.substring(4) : '';
      final removed = _book.removeAttachment(chatId, messageId, attachmentId);
      if (removed && mounted) setState(() {});
      return removed;
    }
    final path = ref.path;
    final job = thread.messages
        .where((ChatMessage m) => m.id == messageId)
        .firstOrNull
        ?.job;
    if (path == null || job == null || !job.outputs.contains(path)) {
      return false;
    }
    try {
      final type = await FileSystemEntity.type(path);
      if (type == FileSystemEntityType.directory) return false;
      if (type != FileSystemEntityType.notFound) await File(path).delete();
    } on FileSystemException {
      return false;
    }
    job.outputs = <String>[
      for (final output in job.outputs)
        if (output != path) output,
    ];
    _book.touch(chatId);
    unawaited(_book.flush());
    if (mounted) setState(() {});
    return true;
  }

  /// «Удалить» в меню «Файлов сессии»: тот же вопрос, что у фразы «удали
  /// этот файл», — в чате, с кнопками «Удалить» и «Отмена».
  void _deleteFromPanel(SessionFile file) {
    if (_sending) return;
    // На телефоне панель выдвижная: вопрос — в ленте под ней.
    if (_scaffoldKey.currentState?.isEndDrawerOpen ?? false) {
      _scaffoldKey.currentState?.closeEndDrawer();
    }
    unawaited(_send('удали файл «${file.name}»'));
  }

  /// Чат прочитан с диска: хвосты задач, прерванных перезапуском
  /// (`.part`, временные папки рядом с исходником), убираются сразу.
  void _sweepInterruptedJobs(ChatThread thread) {
    for (final message in thread.messages) {
      final card = message.job;
      if (card != null && card.state == CardState.interrupted) {
        _jobHub.sweepInterrupted(thread.id, card);
      }
    }
  }

  Widget? _jobCard(ChatMessage message) {
    final card = message.job;
    if (card == null) return null;
    final chatId = _book.currentId;
    return _jobCards.build(
      chatId,
      card,
      busy: _sending,
      sessionFiles: _sessionFiles(chatId),
    );
  }

  /// Карточка расширения из «+» → «Шаблоны команд»: ответ Лиорио с пустой
  /// формой, без фразы пользователя.
  void _openForm(String extensionId, [String? action]) {
    final response = widget.assistant.openForm(extensionId, action: action);
    if (response == null) return;
    final chatId = _book.currentId;
    setState(() {
      _book.append(chatId, _answer(response));
    });
    _scrollToLatest();
  }

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
    _applyAppLock(settings);
    widget.onAppearanceChanged?.call(settings.appearance);
    widget.onReduceMotionChanged?.call(settings.reduceMotion);
    widget.voice?.choice = settings.voiceEngine;
    unawaited(widget.intent?.apply(settings));
    setState(() {
      _settings = settings;
      _settingsLoaded = true;
    });
    _dailyChecks();
    _preloadVoice();
    _syncReminders();
    _syncHomeScreen();
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
    // Знак ответившего у чатов из прежних версий — из их файлов.
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
    _applyAppLock(settings);
    if (settings.appearance != _settings.appearance) {
      widget.onAppearanceChanged?.call(settings.appearance);
    }
    if (settings.reduceMotion != _settings.reduceMotion) {
      widget.onReduceMotionChanged?.call(settings.reduceMotion);
    }
    widget.voice?.choice = settings.voiceEngine;
    unawaited(widget.intent?.apply(settings));
    setState(() => _settings = settings);
    unawaited(_settingsStore.save(settings));
    _preloadVoice();
    _syncReminders();
    _syncHomeScreen();
  }

  /// Вход в приложение по отпечатку / Face ID: настройки — в замок. Замок
  /// выключился сам (пропала блокировка экрана) — это и в настройки.
  void _applyAppLock(AppSettings settings) {
    final lock = widget.appLock;
    if (lock == null) return;
    lock.configure(
      enabled: settings.appLock,
      after: Duration(seconds: settings.appLockAfter),
    );
    lock.onDisabled = () {
      if (!mounted || !_settings.appLock) return;
      _changeSettings(_settings.copyWith(appLock: false));
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text(
            'Блокировка экрана выключена — вход в приложение по отпечатку '
            'отключён.',
          ),
        ),
      );
    };
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
      _syncReminders();
      _syncHomeScreen();
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
    // Надиктовано и отправлено без правки: разбор строже переспрашивает
    // («Понял так: …»).
    final voiced = _voiceText;
    final fromVoice = preset == null && voiced != null && voiced.trim() == text;
    // Файлы уходят с командой из поля ввода, не с быстрой кнопкой.
    final files = preset == null
        ? List<_PendingFile>.of(_pendingFiles)
        : const <_PendingFile>[];
    if (text.isEmpty && files.isEmpty) return;
    // Клавиатура после ответа остаётся, только если человек печатал:
    // быстрая кнопка, голос и ответ, пришедший в другом разделе или под
    // открытым экраном, её не открывают.
    final refocus = _inputFocus.hasFocus;
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
        _sendFilesOnly(chatId, commandId, attachments, refocus: refocus);
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
    _voiceText = null;
    final handled = await widget.assistant.handle(
      secret ? shown : text,
      chatTaskId: chatTaskId,
      secretRedacted: secret,
      attachments: <JobFile>[
        for (final attachment in attachments)
          JobFile(
            path: attachment.path,
            name: attachment.name,
            attachment: true,
          ),
      ],
      recentAttachments: _sessionFiles(chatId, skipMessageId: commandId),
      recentFiles: secret ? const <SessionFileRef>[] : _recentFiles(chatId),
      fromVoice: fromVoice,
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
    if (response.intent == 'unknown') unawaited(_offerIntent());
    // «Исправить» на «Понял так: …»: понятая команда — в поле ввода, курсор
    // в конце; черновик, который человек успел набрать, не затирается.
    final draft = response.draft;
    if (draft != null &&
        _input.text.trim().isEmpty &&
        chatId == _book.currentId) {
      _input.value = TextEditingValue(
        text: draft,
        selection: TextSelection.collapsed(offset: draft.length),
      );
    }
    // Своя страница или приложение погоды: только у живого ответа, в
    // истории запроса нет.
    if (response.launch case final LaunchRequest launch) {
      unawaited(_launchWeather(launch, chatId, reply.personaId));
    }
    if (fromDocument &&
        _mode == AssistantViewMode.document &&
        _section == AppSection.session &&
        chatId == _book.currentId) {
      _announceReply(reply, response);
    }
    _scrollToLatest();
    // «Открой мой Связной»: ответ остаётся в сессии, а раздел открывается —
    // если человек всё ещё в этой сессии и никуда не ушёл, пока ждал.
    if (response.intent == TalkConnector.openHubCommand &&
        _section == AppSection.session &&
        chatId == _book.currentId) {
      _openMyRelay(MyRelayTab.summary);
    }
    _refocusInput(refocus, chatId);
    await _refresh();
    if (mounted) await _askNotifyFor(response);
  }

  /// Вернуть фокус полю после ответа — только тому, кто печатал, и только
  /// если он всё ещё в этой сессии, без меню и экранов поверх. Иначе
  /// клавиатура выскочила бы сама: по возвращении из «Мой Связной» или
  /// поверх формы на другом экране, у которой поле отнял бы фокус.
  void _refocusInput(bool refocus, String chatId) {
    if (!refocus ||
        !mounted ||
        _section != AppSection.session ||
        chatId != _book.currentId ||
        (_scaffoldKey.currentState?.isDrawerOpen ?? false) ||
        // «Файлы сессии» справа — тоже не маршрут: клавиатура закрыла бы
        // открытую панель.
        (_scaffoldKey.currentState?.isEndDrawerOpen ?? false) ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return;
    }
    _inputFocus.requestFocus();
  }

  /// Сообщение только из файлов: в помощника команда не идёт, он честно
  /// отвечает, что файлы сохранены в сессии (ADR-019).
  void _sendFilesOnly(
    String chatId,
    String commandId,
    List<ChatAttachment> attachments, {
    required bool refocus,
  }) {
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
    _refocusInput(refocus, chatId);
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
    // После системного выбора файлов клавиатура сама не выскакивает: на
    // телефоне она закрыла бы чипы вложений над полем.
    _focusInputWithKeyboard();
  }

  /// «+» → «Облачный диск» → «Подключить диск»: дисков ещё нет, честное
  /// пояснение и путь к файлам с устройства.
  Future<void> _explainCloudDisks() async {
    final attach = await showAppSheet<bool>(
      context: context,
      builder: (BuildContext context) => AppSheet(
        key: const Key('cloud-disk-info'),
        icon: Icons.cloud_outlined,
        iconColor: context.colors.tileBlue,
        title: const WholeWordText('Облачный диск'),
        body: Text(
          '${CloudDisk.yandex.label} и ${CloudDisk.google.label} '
          'появятся позже. Пока файлы можно прикрепить с устройства.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const ActionLabel('Понятно'),
          ),
          FilledButton.icon(
            key: const Key('cloud-disk-attach'),
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.attach_file, size: 18),
            label: const Text('Прикрепить файл'),
          ),
        ],
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
          case 'ext.archiver.zip':
            _openForm(ExtensionForms.archiver, ExtensionForms.zip);
          case 'ext.archiver.extract':
            _openForm(ExtensionForms.archiver, ExtensionForms.extract);
          case 'ext.archiver.list':
            _openForm(ExtensionForms.archiver, ExtensionForms.list);
          case 'ext.converter':
            _openForm(ExtensionForms.converter);
          case 'ext.ytdl':
            if (!kPlayBuild) _openForm(ExtensionForms.ytdl);
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
    // Задачи удаляемых чатов не работают дальше (ffmpeg, yt-dlp,
    // распаковка в папку удалённой сессии).
    _jobHub.cancelAll();
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
    if (scaffold.isEndDrawerOpen) scaffold.closeEndDrawer();
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

  /// Пункт чек-листа задачи из документа (ADR-033).
  Future<void> _toggleItem(Task task, int index) async {
    try {
      await widget.tasks.toggleItem(task.id, index);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не получилось: $error')),
      );
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
    if (!_settings.voiceInput || !voice.isReady) return VoiceButtonMode.off;
    return VoiceButtonMode.idle;
  }

  void _onVoiceChanged() {
    if (!mounted) return;
    final voice = widget.voice;
    if (_voiceAwaitInstall &&
        voice != null &&
        !voice.isBusy &&
        !voice.isDeviceDownloading) {
      _voiceAwaitInstall = false;
      if (voice.isReady) {
        _voiceSay('Голосовой ввод готов');
      } else if (voice.engine == VoiceEngine.vosk && voice.error != null) {
        final error = voice.error!;
        _voiceSay(error.message);
      }
    }
    setState(() {});
    _preloadVoice();
    // Микрофон на виджете — только пока голосовой ввод на устройстве есть.
    if (_homeScreenVoice != _syncedHomeVoice) _syncHomeScreen();
  }

  /// Модель загружается заранее, как только голосовой ввод включён и
  /// модель скачана: первое нажатие на микрофон не ждёт загрузки.
  void _preloadVoice() {
    final voice = widget.voice;
    if (voice == null ||
        voice.support == VoiceSupport.unsupported ||
        !_settings.voiceInput ||
        !voice.isReady) {
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

  /// Нажатие на микрофон, долгое нажатие на пустое поле, Ctrl+Shift+M:
  /// выключен — предложение включить; готов — начать слушать; готовится —
  /// отменить (сказать ещё ничего не успели); слушает — закончить с
  /// итогом.
  void _voiceTap() {
    switch (_voiceMode) {
      case VoiceButtonMode.hidden:
        return;
      case VoiceButtonMode.off:
        unawaited(_offerVoice());
      case VoiceButtonMode.idle:
        unawaited(_startVoice());
      case VoiceButtonMode.loading:
        unawaited(_cancelVoice());
      case VoiceButtonMode.listening:
        unawaited(_stopVoice());
    }
  }

  Future<void> _startVoice() async {
    final voice = widget.voice;
    if (voice == null || _sending || _voiceListening || _voiceLoading) return;
    if (!_settings.voiceInput || !voice.isReady) {
      await _offerVoice();
      return;
    }
    if (!_settings.voiceMicExplained) {
      // Сначала объясняем, зачем микрофон, и спрашиваем доступ. Говорить —
      // следующим нажатием: человек ещё читает объяснение.
      final go = await showVoiceRationale(context);
      if (!mounted || !go) return;
      _changeSettings(_settings.copyWith(voiceMicExplained: true));
      final VoicePermission permission;
      _voiceAskingPermission = true;
      try {
        permission = await voice.active.ensurePermission();
      } finally {
        _voiceAskingPermission = false;
      }
      if (!mounted) return;
      if (permission == VoicePermission.granted) {
        _voiceSay('Микрофон доступен. Нажмите на него и говорите');
      } else {
        _announceNoMicrophone();
      }
      return;
    }
    final attempt = ++_voiceAttempt;
    _voiceAutoStop = null;
    _voiceNoticeTimer?.cancel();
    setState(() {
      _voiceLoading = true;
      _voicePartial = '';
      _voicePartialRaw = '';
      _voiceNotice = null;
    });
    // Доступ спрашивается каждый раз: на Android 13+ «Только в этот раз»
    // отзывается сам.
    VoicePermission permission;
    _voiceAskingPermission = true;
    try {
      permission = await voice.active.ensurePermission();
    } on Object {
      permission = VoicePermission.denied;
    } finally {
      _voiceAskingPermission = false;
    }
    if (!mounted || attempt != _voiceAttempt) return;
    if (permission != VoicePermission.granted) {
      _endVoice();
      _announceNoMicrophone();
      return;
    }
    try {
      await voice.ensureLoaded();
    } on Object catch (error) {
      if (!mounted || attempt != _voiceAttempt) return;
      _endVoice();
      _voiceSay(
        error is VoiceEngineException
            ? error.code.message
            : VoiceErrorCode.modelLoad.message,
      );
      return;
    }
    // Отменили, пока готовилось (номер попытки устарел), или ушло
    // сообщение — не слушаем и молчим: сказать ещё ничего не успели.
    if (!mounted || attempt != _voiceAttempt) return;
    if (_sending) {
      _endVoice();
      return;
    }
    final Stream<VoiceEvent> events;
    final recognizer = _voiceRecognizer = voice.active;
    try {
      events = recognizer.start();
    } on Object {
      _endVoice();
      _voiceSay(VoiceErrorCode.engine.message);
      return;
    }
    setState(() {
      _voiceLoading = false;
      _voiceListening = true;
    });
    _armVoiceSilence(attempt, _voiceNoSpeech);
    _voiceMaxTimer?.cancel();
    _voiceMaxTimer = Timer(_voiceMaxListen, () {
      _autoStopVoice(attempt, 'Микрофон выключен: прошла минута');
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

  /// Тишина: таймер заново при каждом новом промежуточном тексте.
  void _armVoiceSilence(int attempt, Duration after) {
    _voiceSilenceTimer?.cancel();
    _voiceSilenceTimer = Timer(after, () {
      _autoStopVoice(attempt, 'Микрофон выключен: долго не было речи');
    });
  }

  /// Автостоп — с итогом, как нажатие «стоп»; подсказка — почему.
  void _autoStopVoice(int attempt, String reason) {
    if (!mounted || attempt != _voiceAttempt || !_voiceListening) return;
    _voiceAutoStop = reason;
    unawaited(_stopVoice());
  }

  /// «Стоп»: распознаватель отдаёт итог, он попадает в поле.
  Future<void> _stopVoice() async {
    final voice = widget.voice;
    if (voice == null || !_voiceListening) return;
    _voiceSilenceTimer?.cancel();
    _voiceMaxTimer?.cancel();
    final subscription = _voiceEvents;
    try {
      await (_voiceRecognizer ?? voice.active).stop();
    } on Object {
      if (_voiceEvents != subscription) return;
      _endVoice();
      if (mounted) _voiceSay(VoiceErrorCode.engine.message);
    }
  }

  /// Прерывает распознавание без итога: фон, уход с экрана.
  Future<void> _cancelVoice() async {
    _voiceAttempt++;
    _voiceAutoStop = null;
    final active = _voiceListening || _voiceLoading;
    final subscription = _voiceEvents;
    final recognizer = _voiceRecognizer ?? widget.voice?.active;
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
    _voiceSilenceTimer?.cancel();
    _voiceSilenceTimer = null;
    _voiceMaxTimer?.cancel();
    _voiceMaxTimer = null;
    _voiceEvents = null;
    if (!mounted) return;
    if (!_voiceListening && !_voiceLoading && _voicePartial.isEmpty) return;
    setState(() {
      _voiceListening = false;
      _voiceLoading = false;
      _voicePartial = '';
      _voicePartialRaw = '';
    });
  }

  void _onVoiceEvent(VoiceEvent event) {
    if (!mounted) return;
    switch (event) {
      case VoicePartial(:final text):
        final partial = normalizeRecognized(text);
        // Тишина считается от последнего нового слова — по сырому тексту:
        // чистка схлопывает повторы («слово слово»), а речь всё равно идёт.
        final raw = text.trim();
        if (raw.isNotEmpty && raw != _voicePartialRaw) {
          _armVoiceSilence(_voiceAttempt, _voiceSilence);
        }
        _voicePartialRaw = raw;
        setState(() => _voicePartial = partial);
      case VoiceFinal(:final text):
        final reason = _voiceAutoStop;
        _voiceAutoStop = null;
        _endVoice();
        if (reason != null && normalizeRecognized(text).isEmpty) {
          _voiceSay('Микрофон выключен: речи не слышно');
          return;
        }
        // Подсказка «почему выключился» — до вставки: предупреждение
        // «Похоже на пароль» важнее и заменит её.
        if (reason != null) _voiceSay(reason);
        _insertRecognized(text);
      case VoiceError(:final code):
        _voiceAutoStop = null;
        _endVoice();
        final voice = widget.voice;
        if (voice != null &&
            (code == VoiceErrorCode.languageUnsupported ||
                code == VoiceErrorCode.languageUnavailable)) {
          // Следующее нажатие возьмёт другой движок; эта попытка не
          // переключается на ходу.
          voice.reportDeviceError(code);
          if (code == VoiceErrorCode.languageUnsupported &&
              voice.engine == VoiceEngine.vosk &&
              voice.isInstalled) {
            _voiceSay(
              'Распознавание телефона не знает русский. Включено '
              'распознавание Tridot',
            );
            return;
          }
        }
        _voiceSay(code.message);
    }
  }

  void _announceNoMicrophone() => _voiceSay(
        defaultTargetPlatform == TargetPlatform.android
            ? 'Нет доступа к микрофону. Разрешите его в настройках Android'
            : 'Нет доступа к микрофону. Разрешите его в настройках системы',
      );

  /// Распознаватель текущей попытки: смена движка в настройках не
  /// переключает уже начатую.
  VoiceRecognizer? _voiceRecognizer;

  /// Последний промежуточный текст распознавателя как есть, до чистки.
  String _voicePartialRaw = '';

  /// Текст поля ввода сразу после вставки распознанного: если его
  /// отправят без правки, сообщение — голосовое ([AssistantSession.fromVoice]).
  String? _voiceText;

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
    _voiceText = updated;
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

  /// Первое «не понял» без модели понимания: один раз предложить скачать
  /// «Лёгкую» (ADR-045). Любой ответ — больше само не предлагается.
  Future<void> _offerIntent() async {
    final intent = widget.intent;
    if (intent == null ||
        !_settingsLoaded ||
        _settings.intentOffered ||
        _settings.intentTier != IntentTier.off ||
        intent.installed != null ||
        intent.isBusy ||
        intent.running) {
      return;
    }
    _changeSettings(_settings.copyWith(intentOffered: true));
    final download = await showIntentOffer(context, intent);
    if (!mounted || !download) return;
    _changeSettings(_settings.copyWith(intentTier: IntentTier.light));
    unawaited(intent.install(IntentTier.light));
    _announce('Модель понимания скачивается. Ход загрузки — в «Настройки → '
        'Понимание фраз»');
  }

  /// Первое нажатие на выключенный микрофон: предложение включить и
  /// загрузка модели с ходом и «Отменой».
  Future<void> _offerVoice() async {
    final voice = widget.voice;
    if (voice == null || voice.support == VoiceSupport.unsupported) return;
    if (_voiceOffering) return;
    _voiceOffering = true;
    try {
      if (voice.engine == VoiceEngine.device && !voice.isReady) {
        await _offerDeviceLanguage(voice);
        return;
      }
      if (voice.engine == VoiceEngine.device && !_settings.voiceInput) {
        // Телефон сам знает русский: загрузок нет, только согласие.
        final enable = await showDeviceVoiceOffer(context);
        if (!mounted || !enable) return;
        _changeSettings(_settings.copyWith(voiceInput: true));
        _voiceSay('Голосовой ввод включён');
        return;
      }
      if (voice.isReady) {
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

  /// Распознавание телефона выбрано, а русский не скачан: системная
  /// загрузка только после «Скачать»; о готовности скажет поле ввода.
  Future<void> _offerDeviceLanguage(VoiceKit voice) async {
    if (voice.deviceStatus == DeviceVoiceStatus.pending ||
        voice.isDeviceDownloading) {
      _voiceSay('Android скачивает русский язык. Голосовой ввод заработает '
          'после загрузки');
      return;
    }
    final download = await showDeviceLanguageOffer(context);
    if (!mounted || !download) return;
    _changeSettings(_settings.copyWith(voiceInput: true));
    _voiceAwaitInstall = true;
    final outcome = await voice.downloadDeviceLanguage();
    if (!mounted) return;
    switch (outcome) {
      case DeviceDownloadSuccess():
        // «Голосовой ввод готов» скажет _onVoiceChanged.
        break;
      case DeviceDownloadScheduled():
      case DeviceDownloadProgress():
        _voiceAwaitInstall = false;
        _voiceSay(deviceLanguageScheduledNotice);
      case DeviceDownloadError():
        _voiceAwaitInstall = false;
        _voiceSay(deviceLanguageErrorNotice);
    }
  }

  /// Ctrl+Shift+M (на macOS — Cmd+Shift+M): начать или закончить голосовой
  /// ввод с клавиатуры — на компьютере и с подключённой к телефону.
  bool _voiceShortcut(KeyEvent event) {
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

  /// Колонка «Файлы сессии» открыта на широком экране — по тому же
  /// правилу, что «Сегодня».
  bool _filesShown(double width) =>
      width >= wideBreakpoint && (_filesOpen ?? width >= todayOpenBreakpoint);

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
        // В сессии справа — «Файлы сессии» (ADR-028), в разделах задач —
        // «Сегодня».
        final inSession = _section == AppSection.session;
        final today =
            _section != AppSection.myRelay && !inSession && _todayShown(width);
        final files = inSession && _filesShown(width);
        // Выдвижное меню (макет «Ж1»): до 360, справа остаётся полоса
        // затемнения не уже 30 — по ней меню закрывается.
        final drawerWidth = math.max(240.0, math.min(360.0, width - 30));
        // Окно стало широким при открытом выдвижном меню: убирать его сразу
        // нельзя — у маршрута осталась бы запись «закрыть меню», и «Назад»
        // перестал бы возвращать в сессию. Держим его ещё кадр и закрываем
        // как обычно.
        final keepDrawer = sidebar && _drawerOpen;
        // То же с правой панелью: окно стало широким — файлы уходят в
        // колонку, а выдвижная панель закрывается своим порядком.
        final keepEnd = wide && _endDrawerOpen;
        if (keepDrawer || keepEnd) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final scaffold = _scaffoldKey.currentState;
            if (scaffold == null) return;
            if (keepDrawer && scaffold.isDrawerOpen) scaffold.closeDrawer();
            if (keepEnd && scaffold.isEndDrawerOpen) {
              scaffold.closeEndDrawer();
            }
          });
        }
        return PopScope(
          // «Назад» на телефоне из разделов и «Мой Связной» — в сессию.
          // Открытое меню «назад» только закрывает.
          canPop:
              _section == AppSection.session || _drawerOpen || _endDrawerOpen,
          onPopInvokedWithResult: (bool didPop, Object? _) {
            if (!didPop) _goTo(AppSection.session);
          },
          child: Scaffold(
            key: _scaffoldKey,
            onDrawerChanged: _onDrawerChanged,
            onEndDrawerChanged: _onEndDrawerChanged,
            backgroundColor: context.colors.background,
            drawerEdgeDragWidth: DrawerSwipe.edge,
            drawer: sidebar && !keepDrawer
                ? null
                : Drawer(
                    width: drawerWidth,
                    backgroundColor: context.colors.sidebar,
                    child: SafeArea(child: _buildDrawer(wide: false)),
                  ),
            // «Файлы сессии» на телефоне — выдвижная панель справа, только
            // в сессии (ADR-028).
            endDrawer: inSession && (!wide || keepEnd)
                ? Drawer(
                    width: drawerWidth,
                    backgroundColor: context.colors.background,
                    semanticLabel: 'Файлы сессии',
                    child: SafeArea(
                      child: _buildSessionFilesPanel(drawer: true),
                    ),
                  )
                : null,
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
                      today: today || files,
                    ),
                  ),
                  if (today) ...<Widget>[
                    const VerticalDivider(width: 1),
                    SizedBox(
                      width: todayWidth,
                      child: _buildTodayPanel(),
                    ),
                  ],
                  if (files) ...<Widget>[
                    const VerticalDivider(width: 1),
                    SizedBox(
                      width: todayWidth,
                      child: _buildSessionFilesPanel(drawer: false),
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

  /// Меню открылось или закрылось. Поле ввода отпускает фокус: иначе после
  /// закрытия меню экран вернул бы его полю, и клавиатура выскочила бы
  /// сама.
  void _onDrawerChanged(bool open) {
    if (open) _inputFocus.unfocus();
    setState(() => _drawerOpen = open);
  }

  /// «Файлы сессии» на телефоне открыты: «назад» закрывает их.
  bool _endDrawerOpen = false;

  /// Правая панель открылась или закрылась — с полем ввода так же, как у
  /// меню: закрытие не возвращает клавиатуру.
  void _onEndDrawerChanged(bool open) {
    if (open) _inputFocus.unfocus();
    setState(() => _endDrawerOpen = open);
  }

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
        // Задачи удаляемого чата останавливаются: иначе ffmpeg и yt-dlp
        // работали бы дальше, а распаковка писала бы в папку удалённой
        // сессии.
        _jobHub.cancelChat(_book.resolve(thread.id));
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
    _focusInputWithKeyboard();
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
            icon: service.slot.runtime
                ? Icons.hub_outlined
                : Icons.inventory_2_outlined,
            status: service.connected ? 'на связи' : 'нет связи',
            statusColor: service.connected
                ? context.colors.success
                : context.colors.faint,
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
              ? context.colors.warning
              : context.colors.faint,
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
      _connectionsHost?.open(context, service) ??
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

  /// «+» в меню: новая пустая сессия, режим «Диалог»; на компьютере —
  /// курсор в поле ввода.
  void _newSession() {
    unawaited(_saveDocument());
    // Выбор («её») прежнего чата сохраняется за ним, новая сессия
    // начинается без выбора (AssistantController.enterChat).
    _switchChat(_book.newSession, mode: AssistantViewMode.dialogue);
    _focusInputWithKeyboard();
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
                  ? context.colors.success
                  : context.colors.faint,
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
          icon: Icon(
            Icons.view_sidebar_outlined,
            color: context.colors.text,
          ),
        ),
      );

  void _goTo(AppSection section) {
    unawaited(_saveDocument());
    setState(() => _section = section);
    final scaffold = _scaffoldKey.currentState;
    if ((scaffold?.isDrawerOpen ?? false) ||
        (scaffold?.isEndDrawerOpen ?? false)) {
      Navigator.of(context).pop();
    }
    if (section != AppSection.session) unawaited(_refresh());
  }

  /// Выход из выбранной задачи в сессии: выбор снимается, режим —
  /// «Диалог», на компьютере — курсор в поле ввода: можно сразу создавать
  /// новую задачу.
  void _exitTask() {
    unawaited(_saveDocument());
    setState(() {
      widget.assistant.clearSelection();
      _mode = AssistantViewMode.dialogue;
    });
    unawaited(_syncDocument());
    _focusInputWithKeyboard();
  }

  /// Курсор в поле ввода без нажатия на него — только там, где клавиатура
  /// физическая (компьютер). На телефоне и планшете фокус открыл бы
  /// экранную клавиатуру, о которой не просили («Новая сессия», выход из
  /// задачи, возврат из выбора файлов): там поле ждёт нажатия.
  void _focusInputWithKeyboard() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return;
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        _inputFocus.requestFocus();
    }
  }

  Widget _buildWorkspace({
    required bool narrow,
    required bool wide,
    required bool sidebar,
    required bool today,
  }) {
    if (_section == AppSection.myRelay) {
      return _drawerSwipe(_buildMyRelay(), wide: wide, sidebar: sidebar);
    }
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
        icon: Icon(Icons.menu, color: context.colors.text),
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
    } else if (const <AppSection>{
      AppSection.tasks,
      AppSection.projects,
      AppSection.planning,
    }.contains(_section)) {
      // У этих разделов — крупный заголовок на самом экране (§4.2):
      // второй маленький в шапке дублировал бы его.
      title = const SizedBox.shrink(key: Key('section-title-empty'));
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
    // Лента и документ — на листе; списки (задачи, проекты, планирование)
    // — на фоне сгруппированного экрана (ADR-027).
    // Другой раздел, сессия или режим — линию под шапкой решит его
    // прокрутка; до неё — без линии.
    final view = (_section, _book.currentId, _mode);
    if (view != _headerView) {
      _headerView = view;
      _underHeader.value = false;
    }
    final workspace = Material(
      color: inSession ? context.colors.workspace : context.colors.background,
      child: Column(
        children: <Widget>[
          SessionHeader(
            wide: wide || title != null,
            leading: leading,
            title: title,
            // Задача в фокусе: меню сессии — кнопкой рядом с «Задача» и
            // её названием, а не пропадает до «назад».
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
            // в шапке. На телефоне кнопки нет: это «Мой Связной» → «Сводка».
            // Задача в фокусе на узком экране: в шапке и так «назад»,
            // задача, её сессия и меню — «⋯» не помещается; «Файлы
            // сессии» остаются.
            trailing: _headerTrailing(
              wide: wide,
              today: today,
              more: !(narrow && taskInFocus != null),
            ),
            // Кубик — в шапке и только пока помощник работает или
            // показывает итог: у ответов в ленте его нет (ADR-027).
            cube: _cube != CubeState.idle &&
                    inSession &&
                    (_workingChatId == null ||
                        _workingChatId == _book.currentId)
                ? _cubeWidget()
                : null,
          ),
          ValueListenableBuilder<bool>(
            valueListenable: _underHeader,
            builder: (BuildContext context, bool under, _) => Divider(
              key: const Key('header-divider'),
              color: under ? null : Colors.transparent,
            ),
          ),
          Expanded(
            child: NotificationListener<Notification>(
              onNotification: _trackUnderHeader,
              child: _buildSection(wide: wide),
            ),
          ),
        ],
      ),
    );
    return _drawerSwipe(
      workspace,
      wide: wide,
      sidebar: sidebar,
      // Свайп влево по сессии на телефоне — «Файлы сессии».
      onOpenEnd: inSession && !wide ? () => _openSessionFiles(wide) : null,
    );
  }

  /// Свайп вправо по рабочей области открывает меню (телефон) — в сессии,
  /// разделах и «Мой Связной». Одной полосы у края мало: на Android с
  /// жестовой навигацией там свайп забирает система как «Назад», и из
  /// раздела он вёл бы в сессию, а не в меню. Поле ввода внизу — вне
  /// жеста: там выделяют текст и двигают курсор.
  Widget _drawerSwipe(
    Widget child, {
    required bool wide,
    required bool sidebar,
    VoidCallback? onOpenEnd,
  }) {
    return DrawerSwipe(
      enabled: !sidebar,
      onOpenEnd: onOpenEnd,
      onOpen: wide
          ? () => setState(() => _sidebarOpen = true)
          : () => _scaffoldKey.currentState?.openDrawer(),
      child: child,
    );
  }

  /// Контент заехал под шапку: у верхнего края что-то скрыто. Лента
  /// перевёрнута (новое внизу) — там верх это «после».
  bool _trackUnderHeader(Notification n) {
    final ScrollMetrics m;
    final int depth;
    if (n is ScrollNotification) {
      (m, depth) = (n.metrics, n.depth);
    } else if (n is ScrollMetricsNotification) {
      (m, depth) = (n.metrics, n.depth);
    } else {
      return false;
    }
    if (depth != 0 || m.axis != Axis.vertical) return false;
    final hidden = switch (m.axisDirection) {
      AxisDirection.up => m.extentAfter,
      _ => m.extentBefore,
    };
    final under = hidden > 0.5;
    // Уведомление приходит и посреди раскладки (лента сменила высоту и
    // докатывается до края): тогда — после кадра, а не в нём.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) _underHeader.value = under;
      });
    } else {
      _underHeader.value = under;
    }
    return false;
  }

  /// Справа в шапке: «⋯» сессии ([more]), «Файлы сессии» и, на
  /// компьютере со свёрнутой колонкой, «Показать «Сегодня»».
  Widget? _headerTrailing({
    required bool wide,
    required bool today,
    bool more = true,
  }) {
    final inSession = _section == AppSection.session;
    final menu = more ? _sessionMoreButton() : null;
    // В сессии справа — «Файлы сессии»: на телефоне кнопка, когда файлы
    // есть, а без «⋯» (задача в фокусе, [more] нет) — всегда: «⋯ → Файлы
    // сессии» тогда нет, и панель открывается из шапки, а не только
    // свайпом; на компьютере — пока колонка свёрнута. В разделах —
    // «Показать «Сегодня»».
    final Widget? show;
    if (inSession) {
      show = (wide ? !today : _filesOfSession.any || !more)
          ? _filesShowButton(wide)
          : null;
    } else {
      show = wide && !today ? _todayShowButton() : null;
    }
    if (menu == null) return show;
    if (show == null) return menu;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: inSession ? <Widget>[show, menu] : <Widget>[menu, show],
    );
  }

  /// Выбор в «История команд»: в «Документе» сначала «Диалог», потом
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
        completed: _completed,
        onReopen: (Task task) => unawaited(_reopenFromSummary(task)),
      ),
      assistants: RelayAssistants(
        settings: _settings,
        onChanged: _changeSettings,
        registry: widget.assistant.extensions,
        connections: widget.connections,
        connectionsHost: _connectionsHost,
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
        intent: widget.intent,
        ffmpeg: widget.ffmpeg,
        nativeMedia: widget.nativeMedia?.caps ?? NativeMediaCaps.none,
        ytdl: widget.ytdl,
        weather: widget.weather,
        appLock: widget.appLock,
        notify: widget.notify,
        homeScreen: widget.homeScreen,
        showTitle: false,
        onOpenAssistants: () =>
            setState(() => _myRelayTab = MyRelayTab.assistants),
        onOpenStorage: () => unawaited(
          Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (BuildContext context) => Scaffold(
                backgroundColor: context.colors.background,
                appBar: AppBar(
                  backgroundColor: context.colors.background,
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

  Future<void> _reopenFromSummary(Task task) async {
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
    // Совсем низкое окно (телефон боком с клавиатурой) — без полосы
    // хроники: место нужнее ленте, список команд остаётся в «⋯».
    final rail = history.isNotEmpty && height >= HistoryRail.minColumnHeight;
    final now = _now;
    // Строка действий начатой переписки; на низком окне её нет, как и
    // быстрых действий у поля ввода.
    final floating =
        hero || height < 420 ? const <QuickRowItem>[] : _floatingItems();
    final overdue =
        hero ? _active.where((Task t) => isOverdue(t, now)).length : 0;
    final Widget content = hero
        ? _sessionHero(overdue)
        : _mode == AssistantViewMode.dialogue
            ? _buildDialogue(
                bottomInset:
                    floating.isEmpty ? 0 : QuickActionsRow.height + AppSpace.xs,
              )
            : _withDocToast(
                DocumentView(
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
                  onToggleItem: (int index) {
                    final task = _selectedTask;
                    if (task != null) unawaited(_toggleItem(task, index));
                  },
                ),
              );
    return Column(
      children: <Widget>[
        // Хроника команд — своей полосой под шапкой, по центру, над лентой
        // (или документом): шапка остаётся одной строкой, ширину ленты и
        // поля ввода хроника не занимает, а сообщения и метка даты под неё
        // не заходят — ни у начала ленты, ни при прокрутке.
        if (rail)
          Padding(
            key: const Key('history-rail-strip'),
            padding: const EdgeInsets.only(
              top: HistoryRail.stripTop,
              bottom: HistoryRail.stripBottom,
            ),
            child: Center(
              child: HistoryRailPill(
                entries: history,
                activeIndex: _highlightedCommand,
                onSelect: _selectCommand,
                // Полосы по одной — только на широком окне (мышь); на
                // телефоне и планшете (палец) — одна кнопка списка.
                compact: !wide,
                reduceMotion: _settings.reduceMotion,
                // Колесо и перетаскивание над хроникой двигают ленту под
                // ней: у полосы нет «мёртвой» зоны.
                scrollController: _mode == AssistantViewMode.dialogue
                    ? _chatScroll
                    : _docScroll,
              ),
            ),
          ),
        Expanded(
          child: floating.isEmpty
              ? content
              : Stack(
                  children: <Widget>[
                    Positioned.fill(child: content),
                    // Начатая переписка: действия — одной строкой поверх
                    // ленты над полем ввода, без фона (ADR-027).
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _chatColumn(
                        alignment: Alignment.bottomCenter,
                        child: _floatingRow(floating),
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

  /// «⋯» в шапке сессии: «История команд» — тот же список, что у хроники
  /// над лентой (ADR-027), и «Файлы сессии» (ADR-028). Пусто, пока нет ни
  /// команд, ни файлов.
  Widget? _sessionMoreButton() {
    if (_section != AppSection.session) return null;
    final history = _historyEntries;
    if (history.isEmpty && !_filesOfSession.any) return null;
    final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
    return PopupMenuButton<String>(
      key: const Key('session-more'),
      tooltip: 'Ещё',
      icon: Icon(Icons.more_horiz, color: context.colors.accent),
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
      onSelected: (String value) async {
        if (value == 'files') {
          _openSessionFiles(wide);
          return;
        }
        if (value != 'history') return;
        final index = await showCommandHistory(
          context,
          entries: history,
          reduceMotion: _settings.reduceMotion,
        );
        if (index != null && mounted) _selectCommand(index);
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        if (history.isNotEmpty)
          PopupMenuItem<String>(
            key: const Key('menu-history'),
            value: 'history',
            child: Row(
              children: <Widget>[
                const Expanded(child: Text('История команд')),
                const SizedBox(width: AppSpace.s),
                Icon(Icons.history, size: 20, color: context.colors.icon),
              ],
            ),
          ),
        PopupMenuItem<String>(
          key: const Key('menu-files'),
          value: 'files',
          child: Row(
            children: <Widget>[
              const Expanded(child: Text('Файлы сессии')),
              const SizedBox(width: AppSpace.s),
              Icon(
                Icons.folder_open_outlined,
                size: 20,
                color: context.colors.icon,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------ «Файлы сессии»

  /// Файлы открытого чата (ADR-028): проекция его сообщений, без своего
  /// хранения — готовая карточка или новое вложение видны сразу.
  ///
  ///
  /// Шапка, «⋯» и сама панель читают её в одной перестройке не раз:
  /// проекция пересчитывается, только когда изменился чат, его сообщения
  /// (сообщения неизменяемы — сравнение по ссылке) или состояние карточки
  /// расширения (она меняется на месте). Тот же список между
  /// перестройками — панель не перепроверяет диск зря.
  _SessionFileLists get _filesOfSession {
    final thread = _book.current;
    final memo = _filesMemo;
    if (memo != null &&
        identical(memo.thread, thread) &&
        _sameFilesKey(memo.key, thread.messages)) {
      return memo.lists;
    }
    final lists = _SessionFileLists(SessionFiles.of(thread));
    _filesMemo = (
      thread: thread,
      key: <Object?>[
        for (final m in thread.messages) ...<Object?>[
          m,
          m.job?.state,
          m.job?.outputs,
        ],
      ],
      lists: lists,
    );
    return lists;
  }

  ({ChatThread thread, List<Object?> key, _SessionFileLists lists})? _filesMemo;

  static bool _sameFilesKey(List<Object?> key, List<ChatMessage> messages) {
    if (key.length != messages.length * 3) return false;
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      if (!identical(key[3 * i], m) ||
          key[3 * i + 1] != m.job?.state ||
          !identical(key[3 * i + 2], m.job?.outputs)) {
        return false;
      }
    }
    return true;
  }

  /// Открыть «Файлы сессии»: на телефоне — выдвижная панель справа, на
  /// компьютере — колонка. Поле ввода отпускает фокус заранее: закрытая
  /// панель вернула бы его полю, и клавиатура выскочила бы сама.
  void _openSessionFiles(bool wide) {
    FocusManager.instance.primaryFocus?.unfocus();
    if (wide) {
      setState(() => _filesOpen = true);
      return;
    }
    _scaffoldKey.currentState?.openEndDrawer();
  }

  /// «Показать в сообщении»: панель на телефоне закрывается, лента — к
  /// сообщению с подсветкой (в «Документе» — сначала «Диалог»).
  void _showFileInMessage(String messageId) {
    final scaffold = _scaffoldKey.currentState;
    if (scaffold != null && scaffold.isEndDrawerOpen) {
      scaffold.closeEndDrawer();
    }
    unawaited(_jumpToMessage(messageId));
  }

  Widget _buildSessionFilesPanel({required bool drawer}) {
    final lists = _filesOfSession;
    return SessionFilesPanel(
      outputs: lists.files.outputs,
      attachments: lists.files.attachments,
      store: _book.store.attachments,
      opener: _jobCards.opener,
      now: _now,
      onShowInMessage: _showFileInMessage,
      onMessage: _announce,
      onDelete: _deleteFromPanel,
      closeTooltip: drawer ? 'Закрыть' : 'Свернуть «Файлы сессии»',
      onClose: drawer
          ? () => _scaffoldKey.currentState?.closeEndDrawer()
          : () => setState(() => _filesOpen = false),
    );
  }

  /// «Файлы сессии» в шапке: на телефоне — пока файлы есть, на компьютере
  /// — пока колонка свёрнута.
  Widget _filesShowButton(bool wide) => IconButton(
        key: const Key('session-files'),
        tooltip: 'Файлы сессии',
        onPressed: () => _openSessionFiles(wide),
        style: IconButton.styleFrom(
          minimumSize: const Size(AppSize.minTap - 4, AppSize.minTap - 4),
        ),
        icon: Icon(Icons.folder_open_outlined, color: context.colors.text),
      );

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

  Widget _buildChat(double viewportHeight, {double bottomInset = 0}) {
    final rows = <Widget>[];
    var commandIndex = -1;
    final commandIndexOf = <int, int>{};
    for (var i = 0; i < _messages.length; i++) {
      if (_messages[i].fromUser) commandIndexOf[i] = ++commandIndex;
    }
    // Карточки списка и действия — только под последним ответом с ними.
    final lastWithChecklist =
        lastIndexById(_messages, (ChatMessage m) => m.checklist?.id);
    final lastWithCard =
        lastIndexById(_messages, (ChatMessage m) => m.card?.id);
    // Ритм ленты (ADR-027): метки времени, имена и промежутки —
    // [ChatFeedRhythm], общий с веб-виджетом.
    final rhythm = ChatFeedRhythm();
    for (var i = 0; i < _messages.length; i++) {
      final message = _messages[i];
      final at = message.timestamp;
      final author = message.fromUser
          ? null
          : _settings.personas.cast.find(message.personaId);
      final beat = rhythm.next(
        at: at,
        fromUser: message.fromUser,
        authorId: author?.id,
      );
      if (beat.newGroup) {
        rows.add(
          ChatGroupTime(
            key: ValueKey<String>('group-time-${message.id}'),
            label: groupTimeLabel(at, _now),
            first: rows.isEmpty,
          ),
        );
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
      final ci = commandIndexOf[i];
      final task = message.taskId == _book.current.taskId
          ? null
          : _findTask(message.taskId);
      final checklist = _checklistCard(
            message,
            i,
            lastWithChecklist,
            viewportHeight,
          ) ??
          _actionCard(message, i, lastWithCard) ??
          _secureCard(message) ??
          _jobCard(message) ??
          _weatherCard(message) ??
          _warehouseCard(message) ??
          _clarifyOptions(message);
      final row = MessageRow(
        cast: _settings.personas.cast,
        key: key,
        message: message,
        attachmentsView: message.attachments.isEmpty
            ? null
            : MessageAttachments(
                attachments: message.attachments,
                store: _book.store.attachments,
                alignEnd: message.fromUser,
              ),
        commandSpans: _commandSpansOf(message),
        // В чате задачи плитка самой задачи под ответами не нужна: она в
        // шапке.
        task: task,
        now: _now,
        showTime: _settings.showTimestamps,
        showAuthor: beat.showAuthor,
        topGap: beat.topGap,
        reduceMotion: _settings.reduceMotion,
        // Подсветка — у найденного поиском сообщения и у команды,
        // выбранной в «История команд»: без выбора (оба `null`) ничего не
        // подсвечено.
        highlighted: hit || (ci != null && ci == _highlightedCommand),
        selectedId: _selectedTask?.id,
        onOpenTask: (Task task) =>
            _openTaskChat(task, mode: AssistantViewMode.dialogue),
        onToggleDone: _toggleDone,
        linkLabel: linkLabel,
        linkKey: linkKey,
        onOpenLink: linkLabel == null ? null : () => _followLink(message.link!),
        checklist: checklist,
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
      rhythm.placed(
        hadCard: checklist != null || task != null || linkLabel != null,
      );
    }
    final working = _working;
    if (_sending && working != null && _workingChatId == _book.currentId) {
      final author = _settings.personas.cast.find(working.personaId);
      final beat = rhythm.working(authorId: author?.id);
      rows.add(
        MessageRow(
          cast: _settings.personas.cast,
          key: const Key('working-message'),
          message: working,
          now: _now,
          showTime: false,
          showAuthor: beat.showAuthor,
          topGap: beat.topGap,
          thinking: true,
          onOpenTask: (_) {},
          onToggleDone: (_) {},
        ),
      );
    }
    // Верхний край ленты гаснет на высоту строки текста (16 × 1.4 с
    // учётом размера шрифта, не меньше 16): обрезанная строка под
    // хроникой команд пропадает целиком, а не торчит половиной букв.
    final topFade = math.max(
      AppSpace.m,
      MediaQuery.textScalerOf(context).scale(16) * 1.4,
    );
    return _chatColumn(
      alignment: Alignment.topCenter,
      // Полосы прокрутки нет: лента — лист для чтения, к сообщениям ведут
      // поиск, «История команд», колесо и тачпад.
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: _fadeUnderRow(
          bottomInset,
          topFade,
          ListView(
            key: const Key('chat-list'),
            controller: _chatScroll,
            reverse: true,
            // Под строкой действий ([_floatingRow]) последнее сообщение не
            // прячется: лента поднимает его над строкой.
            padding: EdgeInsets.fromLTRB(
              chatInset,
              topFade,
              chatInset,
              AppSpace.m + bottomInset,
            ),
            children: rows.reversed.toList(),
          ),
        ),
      ),
    );
  }

  /// Лента под строкой действий гаснет: строка без фона, и прокрученный
  /// текст не просвечивает между кнопками обрывками букв (ADR-027). Сверху
  /// лента тоже гаснет на [topFade] — высоту строки, равную её верхнему
  /// полю: строка, прокрученная под край, исчезает плавно, а не обрубком
  /// букв под хроникой команд (поправка «плотнее»).
  static Widget _fadeUnderRow(double height, double topFade, Widget child) {
    return ShaderMask(
      key: const Key('chat-fade'),
      blendMode: BlendMode.dstIn,
      shaderCallback: (Rect bounds) {
        final total = bounds.height;
        if (total <= height + topFade) {
          return const LinearGradient(
            colors: <Color>[Colors.black, Colors.black],
          ).createShader(bounds);
        }
        final top = topFade / total;
        if (height <= 0) {
          return LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: const <Color>[Colors.transparent, Colors.black],
            stops: <double>[0, top],
          ).createShader(bounds);
        }
        final clear = (total - height + AppSpace.xs) / total;
        final solid = (total - height - AppSpace.m) / total;
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const <Color>[
            Colors.transparent,
            Colors.black,
            Colors.black,
            Colors.transparent,
            Colors.transparent,
          ],
          stops: <double>[
            0,
            top,
            solid.clamp(top, 1.0),
            clear.clamp(top, 1.0),
            1,
          ],
        ).createShader(bounds);
      },
      child: child,
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

  Widget _buildDialogue({double bottomInset = 0}) {
    // Карточке списка нужна высота видимой части чата, а не экрана.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) =>
          _buildChat(constraints.maxHeight, bottomInset: bottomInset),
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
      texts: _textsOf(card.connectorId),
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
    final enabled = !(_sending || _bulkBusy);
    // «Создать», «Удалить», «Поставить» — главное действие вопроса:
    // залитая кнопка; остальные — контурные.
    Widget button(int index, ClarifyOption option) {
      final key = ValueKey<String>('clarify-option-$index');
      final onPressed = enabled ? () => unawaited(_send(option.label)) : null;
      final child = Text(option.label, textAlign: TextAlign.center);
      if (option.answer ?? false) {
        return FilledButton(
          key: key,
          style: FilledButton.styleFrom(minimumSize: const Size(40, 44)),
          onPressed: onPressed,
          child: child,
        );
      }
      return OutlinedButton(
        key: key,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(40, 44),
          foregroundColor: context.colors.textStrong,
        ),
        onPressed: onPressed,
        child: child,
      );
    }

    final options = clarification.options;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // Не помещаются в строку (крупный текст, узкий экран) — столбиком
          // во всю ширину, а не лесенкой разной длины.
          final style = Theme.of(context).textTheme.labelLarge;
          final scaler = MediaQuery.textScalerOf(context);
          var width = 0.0;
          for (final option in options) {
            final painter = TextPainter(
              text: TextSpan(text: option.label, style: style),
              textDirection: TextDirection.ltr,
              textScaler: scaler,
              maxLines: 1,
            )..layout();
            width += painter.width + 48 + 8;
            painter.dispose();
          }
          if (width - 8 <= constraints.maxWidth) {
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final (index, option) in options.indexed)
                  button(index, option),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final (index, option) in options.indexed) ...<Widget>[
                if (index > 0) const SizedBox(height: 8),
                button(index, option),
              ],
            ],
          );
        },
      ),
    );
  }

  /// В сессии ещё нет ни одного сообщения пользователя: только здесь
  /// крупные быстрые действия, кнопки ролей и паролей (ADR-027).
  bool get _isNewChat => !_messages.any((ChatMessage m) => m.fromUser);

  /// Кнопки строки действий начатой переписки ([QuickActionsRow]):
  /// действия выбранной задачи и подсказка команд под ответом «не до конца
  /// понял» (ADR-022) — пока этот ответ последний. Кнопки ролей и паролей
  /// здесь не повторяются: они — в новой сессии.
  List<QuickRowItem> _floatingItems() {
    if (_isNewChat || _mode != AssistantViewMode.dialogue) {
      return const <QuickRowItem>[];
    }
    final selected = _selectedTask;
    final busy = _busyHere;
    final last = _messages.isEmpty ? null : _messages.last;
    // Последний ответ ждёт своего выбора («Понял так: … Создать?»,
    // «Удалить «…»?»): его кнопки — единственные, чужие действия под ними
    // только путают.
    if (last != null && !last.fromUser && _clarifyOptions(last) != null) {
      return const <QuickRowItem>[];
    }
    final suggestions =
        last == null || last.fromUser || busy ? null : last.suggestions;
    return <QuickRowItem>[
      // Подсказка ведёт: она отвечает на только что сказанное.
      if (suggestions != null) ...<QuickRowItem>[
        for (final suggestion in suggestions.commands)
          (
            ValueKey<String>('suggest-${suggestion.entryId}'),
            (
              suggestion.label,
              Icons.edit_outlined,
              () => _applyTemplate(suggestion.template),
            ),
          ),
        (
          const ValueKey<String>('suggest-find'),
          (
            CommandSuggestions.findLabel,
            Icons.search,
            () => unawaited(_findCommand()),
          ),
        ),
      ],
      if (selected != null && selected.isActive) ...<QuickRowItem>[
        (
          const Key('quick-Перенести'),
          (
            'Перенести',
            Icons.update,
            () => _applyTemplate('Перенеси её на завтра в |'),
          ),
        ),
        (
          const Key('quick-Заверши её'),
          (
            'Заверши её',
            Icons.check,
            busy ? null : () => unawaited(_send('Заверши её')),
          ),
        ),
      ],
    ];
  }

  /// Строка действий начатой переписки: прячется, пока пользователь
  /// набирает текст или говорит, — тогда она не нужна и не мешает.
  Widget _floatingRow(List<QuickRowItem> items) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[_input, _inputFocus]),
      builder: (BuildContext context, Widget? _) {
        final typing = _inputFocus.hasFocus && _input.text.trim().isNotEmpty;
        final show = items.isNotEmpty && !typing && !_voiceListening;
        final instant =
            _settings.reduceMotion || MediaQuery.disableAnimationsOf(context);
        return AnimatedSwitcher(
          duration: instant ? Duration.zero : const Duration(milliseconds: 160),
          child: show
              ? Padding(
                  key: const ValueKey<String>('quick-float-on'),
                  padding: const EdgeInsets.only(bottom: AppSpace.xxs),
                  child: QuickActionsRow(
                    items: items,
                    inset: chatInset,
                    label: _selectedTask != null && _selectedTask!.isActive
                        ? 'Действия с задачей'
                        : 'Подсказки команд',
                  ),
                )
              : const SizedBox.shrink(key: ValueKey<String>('quick-float-off')),
        );
      },
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
                minTileHeight: AppSize.rowMin,
                leading: Icon(icon),
                title: WholeWordText(label),
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
  /// команд — своей полосой над лентой по центру и ширину не занимает.
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
              timestamp: chatTimeLabel(_messages[i].timestamp),
              result: i + 1 < _messages.length && !_messages[i + 1].fromUser
                  ? _messages[i + 1].text
                  : null,
            ),
      ];

  /// Команда в «История команд»: текст, а у сообщения только из файлов — «Фото»,
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
          // Начатая переписка — тоже: её действия — одной строкой поверх
          // ленты ([_floatingRow]).
          actions: compact || _mode != AssistantViewMode.dialogue || !_isNewChat
              ? const SizedBox.shrink()
              : QuickActions(
                  // «Задача», «Напомнить», «Пароль» — только в новой
                  // сессии (крупные круглые кнопки); потом остаются лишь
                  // кнопки выбранной задачи и ролей.
                  big: true,
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
            child: _withNetwork(
              CommandComposer(
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
                onVoiceTap: _voiceTap,
                onVoiceLongPress: _voiceTap,
                onVoiceCancel: () => unawaited(_cancelVoice()),
                previousCommand: _previousCommand,
                nextCommand: _nextCommand,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Поле ввода и над ним — капсула «Нет сети» (ADR-040).
  Widget _withNetwork(Widget composer) {
    final network = widget.network;
    if (network == null) return composer;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[NetworkCapsule(status: network), composer],
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
          padding: const EdgeInsets.all(AppSpace.m),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text('Не удалось загрузить задачи'),
              const SizedBox(height: 4),
              Text(
                '$_loadError',
                style: metaStyle(context),
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
      // Группы задач — сгруппированными панелями (ADR-027).
      body = ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: <Widget>[
          for (final (group, items) in groupTasks(_visibleTasks, now))
            InsetGroup(
              header: '${group.title} · ${items.length}',
              headerDanger: group == TaskGroup.overdue,
              children: <Widget>[
                for (final task in items)
                  TaskTile(
                    task: task,
                    now: now,
                    selected: task.id == selectedId,
                    onTap: () => _openTaskChat(task),
                    onToggleDone: () => _toggleDone(task),
                  ),
              ],
            ),
        ],
      );
    }
    return Material(
      key: const Key('tasks-panel'),
      color: context.colors.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            // Wrap, а не Row: при крупном системном шрифте счётчик уходит
            // на вторую строку, а не сжимает заголовок до буквы в строке.
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 4,
              children: <Widget>[
                Semantics(
                  header: true,
                  child: WholeWordText(
                    'Задачи',
                    style: Theme.of(context).textTheme.displaySmall!.copyWith(
                          color: context.colors.textStrong,
                        ),
                  ),
                ),
                Text(
                  _panelSummary(),
                  key: const Key('tasks-panel-summary'),
                  style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                        color: context.colors.muted,
                      ),
                ),
              ],
            ),
          ),
          if (withSearch)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
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
}

// ------------------------------------------------------------------ части

/// Файлы сессии: результаты и вложения ([SessionFiles.of]).
final class _SessionFileLists {
  const _SessionFileLists(this.files);

  final ({List<SessionFile> outputs, List<SessionFile> attachments}) files;

  bool get any => files.outputs.isNotEmpty || files.attachments.isNotEmpty;
}

final class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      color: context.colors.textStrong,
    );
    return Semantics(
      header: true,
      // Одно слово («Планирование») уменьшается целиком, название проекта
      // из нескольких слов режется многоточием.
      child: title.trim().contains(' ')
          ? Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            )
          : fitSingleWord(title, style: style),
    );
  }
}

/// Задача, с которой работает помощник, — в шапке: «Задача» мелко и под
/// ней название (ADR-027); на широком окне — со сроком и кнопками чата и
/// документа задачи.
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

  /// Меньше — без срока и кнопки документа, как на узком экране: рядом с
  /// поиском и кнопкой панели полной строке тесно.
  static const double _fullWidth = 480;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) =>
            _build(context, narrow || constraints.maxWidth < _fullWidth),
      );

  Widget _build(BuildContext context, bool narrow) {
    final due = task.dueAt;
    final titleStyle = Theme.of(context)
        .textTheme
        .titleMedium!
        .copyWith(color: context.colors.textStrong, height: 1.25);
    final chatButton = IconButton(
      key: const Key('open-task-chat'),
      tooltip: 'Открыть сессию задачи',
      onPressed: onOpenChat,
      iconSize: 22,
      color: context.colors.accent,
      icon: const Icon(Icons.forum_outlined),
    );
    final caption = !narrow && due != null
        ? 'Задача · ${formatDue(due, task.duePrecision, now)}'
        : 'Задача';
    // Две строки помещаются в шапку высотой 56, только пока шрифт не
    // крупный; иначе остаётся название задачи, подпись — в подсказке.
    final Widget crumb;
    if (MediaQuery.textScalerOf(context).scale(1) > 1.3) {
      crumb = Tooltip(
        message: caption,
        // Первое слово — целиком (на 320 px со шрифтом 200 % было
        // «Купит…»): не влезает — уменьшается, остальное — «…».
        child: WholeWordText(
          task.title,
          key: const Key('selected-task-strip'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          firstWordOnly: true,
          style: titleStyle,
        ),
      );
    } else {
      crumb = Column(
        key: const Key('selected-task-strip'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: metaStyle(context).copyWith(
              height: 1.2,
              color: context.colors.muted,
            ),
          ),
          WholeWordText(
            task.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            firstWordOnly: true,
            style: titleStyle,
          ),
        ],
      );
    }
    return Row(
      children: <Widget>[
        Expanded(child: crumb),
        chatButton,
        if (!narrow)
          IconButton(
            tooltip: 'Открыть документ задачи',
            onPressed: onOpenDocument,
            iconSize: 22,
            color: context.colors.accent,
            icon: const Icon(Icons.description_outlined),
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

/// Поиск по задачам на экране «Задачи»: поле поиска сгруппированного
/// экрана (ADR-027).
final class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, minWidth: 160),
        child: SearchField(
          key: const Key('task-search'),
          controller: controller,
          onChanged: onChanged,
          hint: 'Поиск по задачам',
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
        color: context.colors.raised,
        elevation: 0,
        shadowColor: context.colors.shadow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.group),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    text,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.4,
                      color: context.colors.textStrong,
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

/// [SessionFileRemover] ленты: удаление делает [HomePage].
final class _SessionFileRemover implements SessionFileRemover {
  const _SessionFileRemover(this._remove);

  final Future<bool> Function(SessionFileRef file) _remove;

  @override
  Future<bool> remove(SessionFileRef file) => _remove(file);
}
