import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import '../core/app_info.dart';
import '../core/chats/chat_book.dart';
import '../core/chats/chat_models.dart';
import '../core/chats/chat_store.dart';
import '../core/formatting/due_format.dart';
import '../core/models/assistant_types.dart';
import '../core/models/bulk.dart';
import '../core/models/task.dart';
import '../core/replies/reply_library.dart';
import '../core/scenario/assistant_controller.dart';
import '../core/services/clock.dart';
import '../core/services/task_service.dart';
import '../core/extensions/extension_registry.dart';
import '../core/settings/app_settings.dart';
import '../core/storage/storage_info.dart';
import 'assistant_theme.dart';
import 'screens/overview_screen.dart';
import 'screens/planning_screen.dart';
import 'screens/projects_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/storage_screen.dart';
import 'widgets/bulk_checklist_card.dart';
import 'widgets/chat_list.dart';
import 'widgets/command_composer.dart';
import 'widgets/document_view.dart';
import 'widgets/history_rail.dart';
import 'widgets/personas_section.dart';
import 'widgets/status_cube.dart';
import 'widgets/task_chat_header.dart';
import 'widgets/task_tile.dart';

/// Разделы бокового меню.
enum AppSection { overview, projects, tasks, planning, storage, settings }

extension AppSectionInfo on AppSection {
  String get title => switch (this) {
        AppSection.overview => 'Обзор',
        AppSection.projects => 'Проекты',
        AppSection.tasks => 'Задачи',
        AppSection.planning => 'Планирование',
        AppSection.storage => 'Хранилище',
        AppSection.settings => 'Настройки',
      };

  IconData get icon => switch (this) {
        AppSection.overview => Icons.grid_view,
        AppSection.projects => Icons.tag,
        AppSection.tasks => Icons.task_alt,
        AppSection.planning => Icons.calendar_today_outlined,
        AppSection.storage => Icons.storage_outlined,
        AppSection.settings => Icons.settings_outlined,
      };
}

/// Ширина, ниже которой боковое меню прячется в выдвижную панель.
const double narrowBreakpoint = 700;

/// Ширина, начиная с которой панель задач стоит колонкой рядом с чатом.
const double panelBreakpoint = 1200;

/// Подсказка пустой панели задач: пример команды без кавычек на своей
/// строке, чтобы он не рвался посередине.
const String emptyTasksHint = 'Напишите в чате, например:\nзавтра купить хлеб';

/// Наибольшая ширина колонки чата (сообщения, «Кому», быстрые действия и
/// поле ввода) без хроники команд.
const double chatColumnWidth = 760;

/// Общий отступ содержимого колонки чата от её краёв: по нему выровнены
/// текст ответов, правый край пузырей, «Кому:», быстрые действия и поле
/// ввода.
const double chatInset = 16;

/// Ширина колонки хроники команд справа от колонки чата.
double historyRailWidth({required bool narrow}) => narrow ? 24 : 32;

/// Сколько от правого края окна до правого края хроники команд. Хроника
/// стоит вплотную к колонке чата, а колонка (вместе с хроникой) — по
/// центру области между боковым меню и панелью задач.
double historyRailRight({
  required double width,
  required double sidebarWidth,
  required double panelWidth,
  required bool narrow,
}) {
  final chat = width - sidebarWidth - panelWidth;
  final column = chatColumnWidth + historyRailWidth(narrow: narrow);
  final free = chat - column;
  return panelWidth + (free > 0 ? free / 2 : 0);
}

final class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.assistant,
    required this.tasks,
    this.clock = const SystemClock(),
    this.storage = const MemoryStorageInfo(),
    this.settingsStore,
    this.chatStore,
  });

  final AssistantController assistant;
  final TaskService tasks;
  final Clock clock;
  final StorageInfo storage;
  final SettingsStore? settingsStore;

  /// Где хранятся чаты (ADR-010). По умолчанию — в памяти, как задачи и
  /// настройки в тестах и режиме «Только в памяти».
  final ChatStore? chatStore;

  @override
  State<HomePage> createState() => _HomePageState();
}

final class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
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

  /// Кому писать в дуэте, выбор в поле ввода: `null` — основному. У
  /// каждого чата свой и сохраняется вместе с чатом
  /// ([ChatThread.addressee]). Обращение по имени («Нода, …») меняет его
  /// так же, как нажатие на переключатель
  /// ([AssistantController.addresseeAfter]): к кому обратились, тот и
  /// продолжает. Смена настроек его не трогает.
  String? get _addressee => _book.current.addressee;

  set _addressee(String? value) => _book.setAddressee(_book.currentId, value);

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

  AppSection _section = AppSection.tasks;
  AssistantViewMode _mode = AssistantViewMode.dialogue;
  AppSettings _settings = const AppSettings();

  List<Task> _active = <Task>[];
  List<Task> _all = <Task>[];
  List<Task> _completed = <Task>[];
  Object? _loadError;
  bool _loaded = false;
  bool _sending = false;
  bool _panelOpen = true;

  /// Строка поиска по задачам в верхней строке (фильтрует панель задач).
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
    for (final controller in <TextEditingController>[
      _docTitle,
      _docProject,
      _docBody,
    ]) {
      controller.addListener(_onDocumentEdited);
    }
    _book.resetMain(<ChatMessage>[_welcome()]);
    _settingsReady = _loadSettings();
    _chatsReady = _loadChats();
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cubeTimer?.cancel();
    _docTimer?.cancel();
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
      );

  bool get _duo => _settings.personas.mode == AssistantMode.duo;

  // ------------------------------------------------------------- данные

  Future<void> _loadSettings() async {
    final settings = await _settingsStore.load();
    if (!mounted) return;
    _applyExtensions(settings);
    widget.assistant.personas = settings.personas;
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

  /// Включает и выключает расширения сразу, без перезапуска: история
  /// чата, задачи, выбранная задача и черновик в поле ввода не меняются.
  void _applyExtensions(AppSettings settings) {
    widget.assistant.extensions.apply(
      ExtensionChoice(
        disabled: settings.disabledExtensions,
        enabled: settings.enabledExtensions,
      ),
    );
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
    // Пока готовится ответ, напоминание не вклиниваем между командой и
    // ответом: после ответа _send вызовет _refresh → _maybeNotice.
    if (_sending) return;
    final now = _now;
    final today = AppSettings.dayKey(now);
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
    // Чат, адресат и голос фиксируются сейчас: ответ придёт в этот чат,
    // даже если пользователь успеет открыть другой, а смена настроек во
    // время ответа применится со следующего сообщения.
    final chatId = _book.currentId;
    final chatTaskId = _book.current.taskId;
    final addressee = _duo ? _addressee : null;
    final command = ChatMessage(
      id: _book.newMessageId(),
      author: ChatAuthor.user,
      text: text,
      timestamp: _now,
    );
    setState(() {
      _sending = true;
      _pristineWelcome = false;
      _cube = CubeState.working;
      _working = _answer(
        widget.assistant.working(text, addressee: addressee),
        withStatus: false,
      );
      _workingChatId = chatId;
      _book.append(chatId, command);
      _commands.add(text);
      _commandCursor = null;
      if (preset == null) _input.clear();
    });
    _scrollToLatest();
    await _saveDocument();
    final response = await widget.assistant.handle(
      text,
      addressee: addressee,
      chatTaskId: chatTaskId,
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
      // Пока готовился ответ, адресата могли выбрать в поле: обращение
      // по имени важнее, без него выбор остаётся.
      _book.setAddressee(
        chatId,
        widget.assistant.addresseeAfter(
          response,
          current: _book.thread(chatId)?.addressee,
        ),
      );
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
    _scrollToLatest();
    _inputFocus.requestFocus();
    await _refresh();
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
    if (_section != AppSection.tasks) {
      setState(() => _section = AppSection.tasks);
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

  /// «Очистить историю чатов»: чаты задач удаляются, главный начинается с
  /// приветствия. Задачи не меняются.
  void _clearChat() {
    // Вопрос со списком снимается, отменить прежние массовые изменения
    // из чата больше нельзя.
    widget.assistant.clearConversation();
    unawaited(_book.clearAll());
    widget.assistant.enterChat();
    setState(() {
      _book.append(ChatThread.mainId, _welcome());
      _pristineWelcome = false;
      _messageKeys.clear();
      _commands.clear();
      _commandCursor = null;
      _highlightedCommand = null;
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

  // ------------------------------------------------------------- задачи

  // --------------------------------------------------------------- чаты

  /// Открывает чат задачи [task] (создаёт его при первом открытии). [mode]
  /// — режим после открытия; `null` — прежний (панель «Активные» не
  /// переключает документ на диалог). Повторное нажатие на задачу открытого
  /// чата ничего не меняет.
  void _openTaskChat(Task task, {AssistantViewMode? mode}) {
    if (_book.current.taskId == task.id && _section == AppSection.tasks) {
      _closeDrawers();
      if (mode != null && mode != _mode) _setMode(mode);
      return;
    }
    _chatCreations++;
    _switchChat(() => _book.openTask(task.id), mode: mode);
  }

  void _openChat(String chatId) {
    if (chatId == _book.currentId && _section == AppSection.tasks) {
      _closeDrawers();
      return;
    }
    _switchChat(() => _book.open(chatId), mode: AssistantViewMode.dialogue);
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
    widget.assistant.enterChat(taskId: _book.current.taskId);
    setState(() {
      _section = AppSection.tasks;
      if (mode != null) _mode = mode;
      _messageKeys.clear();
      _highlightedCommand = null;
    });
    unawaited(_syncDocument());
    _scrollToLatest();
  }

  void _closeDrawers() {
    final scaffold = _scaffoldKey.currentState;
    if (scaffold == null) return;
    if (scaffold.isEndDrawerOpen) scaffold.closeEndDrawer();
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

  void _openTasksPanel(bool wide) {
    if (wide) {
      setState(() => _panelOpen = !_panelOpen);
    } else {
      _scaffoldKey.currentState?.openEndDrawer();
    }
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
    setState(() => _mode = mode);
  }

  Duration _motion(Duration duration) =>
      _settings.reduceMotion || MediaQuery.of(context).disableAnimations
          ? Duration.zero
          : duration;

  // --------------------------------------------------------------- вёрстка

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final width = constraints.maxWidth;
        final narrow = width < narrowBreakpoint;
        final wide = width >= panelBreakpoint;
        final sidebarExpanded = width >= 1100;
        final railRight = historyRailRight(
          width: width,
          sidebarWidth: narrow ? 0 : (sidebarExpanded ? 232 : 64),
          panelWidth: wide && _panelOpen ? 321 : 0,
          narrow: narrow,
        );
        return Scaffold(
          key: _scaffoldKey,
          backgroundColor: AssistantColors.background,
          drawer: narrow
              ? Drawer(
                  backgroundColor: AssistantColors.sidebar,
                  child: SafeArea(child: _buildSidebar(expanded: true)),
                )
              : null,
          endDrawer: wide
              ? null
              : Drawer(
                  backgroundColor: AssistantColors.panel,
                  child: SafeArea(child: _buildTasksPanel()),
                ),
          body: SafeArea(
            child: Stack(
              children: <Widget>[
                Row(
                  children: <Widget>[
                    if (!narrow) _buildSidebar(expanded: sidebarExpanded),
                    Expanded(
                      child: _buildWorkspace(narrow: narrow, wide: wide),
                    ),
                  ],
                ),
                // Хроника команд: вплотную справа к колонке чата и ровно по
                // центру высоты всего экрана — зеркальная пара кубику у
                // ответа. Место под неё оставлено в колонке (_chatColumn).
                if (_section == AppSection.tasks &&
                    _mode == AssistantViewMode.dialogue)
                  Positioned(
                    top: 0,
                    bottom: 0,
                    right: railRight,
                    child: HistoryRail(
                      entries: _historyEntries,
                      activeIndex: _highlightedCommand,
                      onSelect: _jumpToCommand,
                      compact: narrow,
                      // Карточка при наведении — слева от хроники, над
                      // сообщениями, а не над панелью задач.
                      cardInset:
                          railRight + historyRailWidth(narrow: narrow) + 4,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSidebar({required bool expanded}) {
    final width = expanded ? 232.0 : 64.0;
    final items = <AppSection>[
      AppSection.overview,
      AppSection.projects,
      AppSection.tasks,
      AppSection.planning,
      AppSection.storage,
    ];
    return Container(
      key: const Key('app-sidebar'),
      width: width,
      color: AssistantColors.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.fromLTRB(expanded ? 24 : 0, 20, 16, 16),
            child: Row(
              mainAxisAlignment:
                  expanded ? MainAxisAlignment.start : MainAxisAlignment.center,
              children: <Widget>[
                const _BrandMark(),
                if (expanded) ...<Widget>[
                  const SizedBox(width: 12),
                  // При крупном шрифте в выдвижной панели название
                  // сокращается, а не вылезает за край.
                  const Flexible(
                    child: Text(
                      AppInfo.name,
                      key: ValueKey<String>('app-name'),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AssistantColors.textStrong,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: <Widget>[
                _buildChatList(expanded: expanded),
                for (final section in items)
                  _NavItem(
                    section: section,
                    expanded: expanded,
                    active: _section == section,
                    badge: section == AppSection.tasks && _active.isNotEmpty
                        ? '${_active.length}'
                        : null,
                    onTap: () => _goTo(section),
                  ),
              ],
            ),
          ),
          _NavItem(
            section: AppSection.settings,
            expanded: expanded,
            active: _section == AppSection.settings,
            onTap: () => _goTo(AppSection.settings),
          ),
          const SizedBox(height: 8),
          const Divider(),
          Tooltip(
            message: widget.storage.location ?? widget.storage.label,
            child: InkWell(
              key: const Key('storage-footer'),
              onTap: () => _goTo(AppSection.storage),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  mainAxisAlignment: expanded
                      ? MainAxisAlignment.start
                      : MainAxisAlignment.center,
                  children: <Widget>[
                    const Icon(Icons.save_outlined, size: 18),
                    if (expanded) ...<Widget>[
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          widget.storage.canBackup
                              ? 'Сохраняется на этом устройстве'
                              : 'Только в памяти',
                          style: technicalTextStyle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// «Главный» и последние чаты задач в боковом меню.
  Widget _buildChatList({required bool expanded}) {
    final inChats = _section == AppSection.tasks;
    return ChatList(
      expanded: expanded,
      mainActive: inChats && _book.current.isMain,
      mainUnread: _book.main.unread,
      entries: <ChatListEntry>[
        for (final thread in _book.recent())
          if (_findTask(thread.taskId) case final Task task)
            ChatListEntry(
              taskId: task.id,
              title: task.title,
              done: task.status == TaskStatus.done,
              unread: thread.unread,
              active: inChats && _book.currentId == thread.id,
            ),
      ],
      onOpenMain: () => _openChat(ChatThread.mainId),
      onOpenTask: (String taskId) {
        final task = _findTask(taskId);
        if (task != null) {
          _openTaskChat(task, mode: AssistantViewMode.dialogue);
        }
      },
    );
  }

  void _goTo(AppSection section) {
    unawaited(_saveDocument());
    setState(() => _section = section);
    if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
      Navigator.of(context).pop();
    }
    if (section != AppSection.tasks) unawaited(_refresh());
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

  Widget _buildWorkspace({required bool narrow, required bool wide}) {
    final selected = _selectedTask;
    final chatTaskId =
        _section == AppSection.tasks ? _book.current.taskId : null;
    final inTaskChat = chatTaskId != null;
    final taskInFocus = !inTaskChat &&
            _section == AppSection.tasks &&
            selected != null &&
            selected.isActive
        ? selected
        : null;
    // Material, а не ColoredBox: на нём рисуются подсветка и всплески
    // нажатий у ListTile и кнопок во всех разделах.
    return Material(
      color: AssistantColors.workspace,
      child: Column(
        children: <Widget>[
          SizedBox(
            height: 56,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: narrow ? 4 : 16),
              child: Row(
                children: <Widget>[
                  // В чате задачи слева — «назад» к предыдущему чату, при
                  // выбранной задаче в главном — снять выбор; на телефоне
                  // он заменяет меню.
                  if (inTaskChat || taskInFocus != null)
                    IconButton(
                      key: const Key('task-back'),
                      tooltip: inTaskChat ? 'Назад' : 'Назад к общему чату',
                      onPressed: inTaskChat ? _goBack : _exitTask,
                      style: narrow
                          ? null
                          : IconButton.styleFrom(
                              fixedSize: const Size(36, 36),
                              minimumSize: const Size(36, 36),
                              padding: EdgeInsets.zero,
                              side: const BorderSide(
                                color: AssistantColors.border,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                      icon: const Icon(Icons.chevron_left, size: 22),
                    )
                  else if (narrow)
                    IconButton(
                      key: const Key('menu-button'),
                      tooltip: 'Меню',
                      onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                      icon: const Icon(Icons.menu),
                    ),
                  SizedBox(width: narrow ? 4 : 12),
                  // Заголовок занимает всё свободное место, поэтому поиск и
                  // кнопка панели прижаты к правому краю.
                  Expanded(
                    child: inTaskChat
                        ? _buildTaskChatHeader(chatTaskId, narrow: narrow)
                        : taskInFocus == null
                            ? _SectionTitle(
                                title: _section.title,
                                subtitle: _section == AppSection.tasks &&
                                        _active.isNotEmpty &&
                                        !narrow
                                    ? '${_active.length} активных'
                                    : null,
                              )
                            : _TaskCrumb(
                                task: taskInFocus,
                                now: _now,
                                narrow: narrow,
                                onOpenDocument: () =>
                                    _setMode(AssistantViewMode.document),
                                onOpenChat: () => _openTaskChat(
                                  taskInFocus,
                                  mode: AssistantViewMode.dialogue,
                                ),
                              ),
                  ),
                  if (_section == AppSection.tasks && !narrow) ...<Widget>[
                    _SearchField(
                      controller: _taskSearch,
                      onChanged: (String value) {
                        setState(() => _taskQuery = value.trim().toLowerCase());
                        if (!wide && value.isNotEmpty) _openTasksPanel(wide);
                      },
                    ),
                    const SizedBox(width: 12),
                  ],
                  if (_section == AppSection.tasks)
                    _PanelToggle(
                      wide: wide,
                      open: wide && _panelOpen,
                      count: _active.length,
                      onPressed: () => _openTasksPanel(wide),
                    ),
                ],
              ),
            ),
          ),
          const Divider(),
          Expanded(child: _buildSection(wide: wide)),
        ],
      ),
    );
  }

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
      case AppSection.overview:
        return OverviewScreen(
          tasks: _all,
          now: now,
          selectedId: selectedId,
          onOpenTask: open,
          onToggleDone: _toggleDone,
          onGoToTasks: () => _goTo(AppSection.tasks),
        );
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
      case AppSection.storage:
        return StorageScreen(
          info: widget.storage,
          activeCount: _active.length,
          completed: _completed,
          now: now,
          chatCount:
              _book.threads.where((ChatThread t) => t.messageCount > 0).length,
          onReopen: (Task task) async {
            await widget.tasks.reopen(task.id);
            await _refresh();
          },
        );
      case AppSection.settings:
        return SettingsScreen(
          settings: _settings,
          onChanged: _changeSettings,
          onClearChat: _clearChat,
          messageCount: _book.totalMessages,
          extensions: widget.assistant.extensions,
        );
      case AppSection.tasks:
        return _buildTasksWorkspace(wide: wide);
    }
  }

  Widget _buildTasksWorkspace({required bool wide}) {
    return Row(
      children: <Widget>[
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) =>
                _buildConversationColumn(constraints.maxHeight, wide),
          ),
        ),
        if (wide && _panelOpen) ...<Widget>[
          const VerticalDivider(width: 1),
          SizedBox(width: 320, child: _buildTasksPanel()),
        ],
      ],
    );
  }

  Widget _buildConversationColumn(double height, bool wide) {
    return Column(
      children: <Widget>[
        Expanded(
          child: _mode == AssistantViewMode.dialogue
              ? _buildDialogue()
              : DocumentView(
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
                  onOpenTasks: () => _openTasksPanel(wide),
                  answer: _latestAnswer(),
                ),
        ),
        if (_duo) _buildAddresseeSwitch(),
        _buildBottomArea(height),
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
    for (var i = 0; i < _messages.length; i++) {
      if (_messages[i].fromUser) commandIndexOf[i] = ++commandIndex;
      final checklist = _messages[i].checklist;
      if (checklist != null) lastWithChecklist[checklist.id] = i;
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
      final key =
          message.fromUser ? _messageKeys.putIfAbsent(i, GlobalKey.new) : null;
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
          ),
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
      return ('из чата «Главный»', const Key('chat-origin-link'));
    }
    final task = _findTask(link.taskId);
    if (task == null) return (null, null);
    final current = _book.current;
    // Копия в чате задачи ведёт в чат задачи-родителя.
    if (!current.isMain && current.parentTaskId == task.id) {
      return ('из чата «${task.title}»', const Key('chat-origin-link'));
    }
    return ('Открыть чат задачи', Key('open-task-chat-${task.id}'));
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

  /// Колонка чата: не шире [chatColumnWidth] плюс место под хронику
  /// команд справа, по центру. Одна и та же для ленты сообщений, «Кому» и
  /// нижней части, поэтому их края совпадают. Сама хроника лежит слоем
  /// поверх экрана (см. build), чтобы стоять по центру высоты всего
  /// экрана, а не области чата.
  Widget _chatColumn({
    required AlignmentGeometry alignment,
    required Widget child,
    double? maxHeight,
  }) {
    final rail = historyRailWidth(
      narrow: MediaQuery.sizeOf(context).width < narrowBreakpoint,
    );
    return Align(
      alignment: alignment,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: chatColumnWidth + rail,
          maxHeight: maxHeight ?? double.infinity,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Expanded(child: child),
            SizedBox(width: rail),
          ],
        ),
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

  Widget _latestAnswer() {
    final index = _messages.lastIndexWhere((m) => !m.fromUser);
    if (index < 0) return const SizedBox.shrink();
    return _MessageRow(
      message: _messages[index],
      now: _now,
      showTime: _settings.showTimestamps,
      cube: _cubeWidget(),
      onOpenTask: (_) {},
      onToggleDone: (_) {},
    );
  }

  /// Нижняя часть: строка выбранной задачи, быстрые действия, поле ввода.
  /// Занимает не больше половины доступной высоты и прокручивается, чтобы
  /// лента сообщений не схлопнулась (клавиатура, горизонтальная ориентация).
  Widget _buildBottomArea(double available) {
    final selected = _selectedTask;
    final compact = available < 420;
    return _chatColumn(
      alignment: Alignment.bottomCenter,
      maxHeight: available * .55,
      child: SingleChildScrollView(
        reverse: true,
        padding: const EdgeInsets.fromLTRB(chatInset, 4, chatInset, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (!compact)
              _QuickActions(
                hasSelection: selected != null && selected.isActive,
                sending: _sending,
                onSend: _send,
                onTemplate: _applyTemplate,
              ),
            CommandComposer(
              controller: _input,
              focusNode: _inputFocus,
              sending: _sending,
              mode: _mode,
              onModeChanged: _setMode,
              onSend: _send,
              onTemplate: _insertTemplate,
              onDocumentSource: (DocumentSource source) => _announce(
                'Подключение «${source.label}» — следующий этап: '
                'документы будут создаваться и правиться через помощника.',
              ),
              onVoice: () => _announce(
                'Голосовой режим в разработке. Пока напишите команду текстом.',
              ),
              previousCommand: _previousCommand,
              nextCommand: _nextCommand,
            ),
          ],
        ),
      ),
    );
  }

  /// «Кому: Liorio | Noda» над нижней частью, вне её прокрутки: при узком
  /// экране и крупном тексте поле ввода прокручивается, а переключатель
  /// остаётся на виду и нажимается. Выбор основного — `null`: тогда
  /// после смены основного в настройках отвечает новый основной.
  Widget _buildAddresseeSwitch() {
    final main = _settings.personas.main;
    return _chatColumn(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(chatInset, 4, chatInset, 0),
        child: Align(
          alignment: Alignment.centerLeft,
          child: _AddresseeSwitch(
            main: main,
            selected: Personas.byId(_addressee) ?? main,
            onChanged: (Persona persona) => setState(
              () => _addressee = persona.id == main.id ? null : persona.id,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTasksPanel() {
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

final class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.section,
    required this.expanded,
    required this.active,
    required this.onTap,
    this.badge,
  });

  final AppSection section;
  final bool expanded;
  final bool active;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final decoration = BoxDecoration(
      color: active ? AssistantColors.raised : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
    );
    final icon = Icon(
      section.icon,
      size: 18,
      color: active ? AssistantColors.textStrong : AssistantColors.muted,
    );
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: expanded ? 12 : 8, vertical: 3),
      child: Tooltip(
        message: section.title,
        child: Semantics(
          button: true,
          selected: active,
          label: section.title,
          excludeSemantics: true,
          child: InkWell(
            key: Key('nav-${section.name}'),
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              height: 40,
              padding: EdgeInsets.symmetric(horizontal: expanded ? 12 : 0),
              decoration: decoration,
              child: expanded
                  ? Row(
                      children: <Widget>[
                        icon,
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            section.title,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: active
                                  ? AssistantColors.textStrong
                                  : AssistantColors.text,
                            ),
                          ),
                        ),
                        if (badge != null)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            decoration: BoxDecoration(
                              color: AssistantColors.bubble,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              badge!,
                              style: technicalTextStyle.copyWith(
                                color: AssistantColors.text,
                                height: 20 / 12,
                              ),
                            ),
                          ),
                      ],
                    )
                  : Center(
                      child: _CountBadge(
                        count: int.tryParse(badge ?? '') ?? 0,
                        child: icon,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

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
                    author.name,
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
    // Текст ответа начинается у левого края колонки — там же, где «Кому:»,
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
  const _SectionTitle({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Flexible(
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AssistantColors.textStrong,
            ),
          ),
        ),
        if (subtitle != null) ...<Widget>[
          const SizedBox(width: 8),
          Text(subtitle!, style: technicalTextStyle),
        ],
      ],
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
      tooltip: 'Открыть чат задачи',
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

final class _QuickActions extends StatelessWidget {
  const _QuickActions({
    required this.hasSelection,
    required this.sending,
    required this.onSend,
    required this.onTemplate,
  });

  final bool hasSelection;
  final bool sending;
  final Future<void> Function([String? preset]) onSend;
  final ValueChanged<String> onTemplate;

  @override
  Widget build(BuildContext context) {
    final actions = <(String, IconData, VoidCallback?)>[
      (
        'Покажи задачи',
        Icons.checklist,
        sending ? null : () => onSend('Покажи задачи'),
      ),
      (
        'Новая задача',
        Icons.add,
        () => onTemplate('Добавь задачу «|» на завтра'),
      ),
      if (hasSelection) ...<(String, IconData, VoidCallback?)>[
        (
          'Перенести',
          Icons.update,
          () => onTemplate('Перенеси её на завтра в |'),
        ),
        (
          'Заверши её',
          Icons.check,
          sending ? null : () => onSend('Заверши её'),
        ),
      ],
    ];
    // Перенос строк вместо горизонтальной прокрутки: все действия видны.
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (final (label, icon, action) in actions)
            OutlinedButton.icon(
              key: Key('quick-$label'),
              onPressed: action,
              icon: Icon(icon, size: 16),
              label: Text(label, style: const TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                foregroundColor: AssistantColors.text,
                side: const BorderSide(color: AssistantColors.border),
                // Та же высота и форма, что у «Кому:» над ними: на
                // настольной плотности кнопки иначе становятся ниже.
                minimumSize: const Size(0, 32),
                visualDensity: VisualDensity.standard,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                shape: const StadiumBorder(),
              ),
            ),
        ],
      ),
    );
  }
}

/// Счётчик рядом с иконкой: смещён за её край, чтобы не закрывать значок,
/// и не растёт вместе с крупным шрифтом.
final class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count, required this.child});

  final int count;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Badge(
      isLabelVisible: count > 0,
      offset: const Offset(12, -8),
      backgroundColor: AssistantColors.textStrong,
      textColor: AssistantColors.background,
      label: MediaQuery.withNoTextScaling(child: Text('$count')),
      child: child,
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

/// Знак приложения: кубик 3×3 в шахматном порядке.
final class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox(
        width: 20,
        height: 20,
        child: Column(
          children: <Widget>[
            for (var row = 0; row < 3; row++) ...<Widget>[
              if (row > 0) const SizedBox(height: 2),
              Expanded(
                child: Row(
                  children: <Widget>[
                    for (var column = 0; column < 3; column++) ...<Widget>[
                      if (column > 0) const SizedBox(width: 2),
                      // Container без потомка занимает всю ячейку; пустой
                      // DecoratedBox схлопнулся бы в ноль по высоте.
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: (row * 3 + column).isEven
                                ? AssistantColors.textStrong
                                : AssistantColors.border,
                            borderRadius: BorderRadius.circular(1),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Поиск по задачам в верхней строке: фильтрует панель задач.
final class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280, minWidth: 160),
      child: SizedBox(
        height: 36,
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

/// Кнопка панели задач: на широком экране скрывает и показывает колонку,
/// на узком — открывает выдвижную панель, а число задач стоит рядом.
final class _PanelToggle extends StatelessWidget {
  const _PanelToggle({
    required this.wide,
    required this.open,
    required this.count,
    required this.onPressed,
  });

  final bool wide;
  final bool open;
  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const Key('tasks-toggle'),
      onPressed: onPressed,
      tooltip: wide && open ? 'Скрыть панель задач' : 'Панель задач',
      style: IconButton.styleFrom(
        fixedSize: const Size(40, 40),
        minimumSize: const Size(40, 40),
        padding: EdgeInsets.zero,
        backgroundColor: open ? AssistantColors.raised : Colors.transparent,
        side: const BorderSide(color: AssistantColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      icon: _CountBadge(
        count: wide ? 0 : count,
        child: const Icon(Icons.view_sidebar_outlined, size: 18),
      ),
    );
  }
}

/// Кому писать в дуэте: две кнопки с именами помощников над полем ввода.
/// Выбор живёт только в этом чате; обращение по имени («Noda, …») важнее.
final class _AddresseeSwitch extends StatelessWidget {
  const _AddresseeSwitch({
    required this.main,
    required this.selected,
    required this.onChanged,
  });

  final Persona main;
  final Persona selected;
  final ValueChanged<Persona> onChanged;

  @override
  Widget build(BuildContext context) {
    final order = <Persona>[main, Personas.other(main)];
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Wrap(
        key: const Key('addressee-switch'),
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          const Text('Кому:', style: technicalTextStyle),
          for (final persona in order)
            Semantics(
              button: true,
              selected: persona.id == selected.id,
              label: 'Писать ${persona.name}',
              excludeSemantics: true,
              child: InkWell(
                key: Key('addressee-${persona.id}'),
                onTap: () => onChanged(persona),
                customBorder: const StadiumBorder(),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 32),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: persona.id == selected.id
                        ? AssistantColors.bubble
                        : Colors.transparent,
                    border: Border.all(
                      color: persona.id == selected.id
                          ? Color(persona.accentColor)
                          : AssistantColors.borderSoft,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      PersonaMark(persona: persona, size: 14),
                      const SizedBox(width: 4),
                      Text(
                        persona.name,
                        style: technicalTextStyle.copyWith(
                          color: persona.id == selected.id
                              ? AssistantColors.textStrong
                              : AssistantColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
