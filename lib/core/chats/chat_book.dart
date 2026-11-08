import 'dart:async';
import 'dart:math';

import '../services/clock.dart';
import 'chat_models.dart';
import 'chat_store.dart';

/// Все чаты приложения: главный и чаты задач, какой открыт и куда ведёт
/// «назад» (ADR-010).
///
/// Чистый Dart, без Flutter: интерфейс вызывает операции и перерисовывает
/// себя сам. Каждое изменение сразу уходит в [ChatStore] (тот решает,
/// когда писать на диск).
///
/// - Главный чат есть всегда.
/// - Чат задачи создаётся лениво: при первом открытии ([openTask]) или
///   когда задачу создали из чата ([onTaskCreated]). Пустой чат на диск не
///   пишется.
/// - Сообщения чата задачи читаются при первом открытии.
/// - Чат удалённой задачи удаляется ([prune]); выполненной — остаётся.
final class ChatBook {
  ChatBook({required ChatStore store, Clock clock = const SystemClock()})
      : _store = store,
        _clock = clock {
    _chats[ChatThread.mainId] = ChatThread(
      id: ChatThread.mainId,
      kind: ChatKind.main,
      createdAt: clock.now(),
    );
  }

  /// Глубина стека «назад».
  static const int maxBack = 20;

  /// Сколько чатов задач показывает боковое меню.
  static const int recentLimit = 5;

  final ChatStore _store;
  final Clock _clock;
  final Map<String, ChatThread> _chats = <String, ChatThread>{};
  final List<String> _back = <String>[];
  final Map<String, Future<void>> _loading = <String, Future<void>>{};

  /// Записи, которые ждут чтения своего чата ([_save]).
  final Set<Future<void>> _deferred = <Future<void>>{};
  final Random _random = Random();
  int _sequence = 0;
  String _currentId = ChatThread.mainId;
  Future<void>? _ready;
  bool _loaded = false;

  ChatStore get store => _store;

  /// Чаты прочитаны ([load] закончился).
  bool get loaded => _loaded;

  /// Загрузка чатов: открытие чата и запись в него ждут её.
  Future<void> get ready => _ready ?? Future<void>.value();

  ChatThread get main => _chats[ChatThread.mainId]!;

  ChatThread get current => _chats[_currentId] ?? main;

  String get currentId => _currentId;

  /// Можно ли вернуться к предыдущему чату.
  bool get canGoBack => _back.isNotEmpty || _currentId != ChatThread.mainId;

  ChatThread? thread(String chatId) => _chats[chatId];

  /// Чат задачи [taskId], если он уже есть.
  ChatThread? taskThread(String taskId) =>
      _chats[ChatThread.taskChatId(taskId)];

  Iterable<ChatThread> get threads => _chats.values;

  /// Сколько сообщений во всех чатах.
  int get totalMessages =>
      _chats.values.fold(0, (int sum, ChatThread t) => sum + t.messageCount);

  /// Новый id сообщения: `m_<микросекунды>_<номер>_<случайное>`.
  String newMessageId() =>
      'm_${_clock.now().microsecondsSinceEpoch}_${_sequence++}_'
      '${_random.nextInt(1 << 20).toRadixString(16)}';

  /// Читает метаданные всех чатов и сообщения главного. Возвращает `true`,
  /// если в главном чате были сохранённые сообщения (иначе в нём остаётся
  /// то, что было до загрузки, — обычно приветствие).
  Future<bool> load() {
    final future = _load();
    _ready = future.then((_) {});
    return future;
  }

  Future<bool> _load() async {
    var restored = false;
    try {
      for (final meta in await _store.loadIndex()) {
        if (meta.isMain) {
          main
            ..addressee = meta.addressee
            ..unread = meta.unread
            ..lastActivityAt = meta.lastActivityAt;
        } else {
          _chats.putIfAbsent(meta.id, () => meta);
        }
      }
      final messages = await _store.loadMessages(ChatThread.mainId);
      if (messages.isNotEmpty) {
        main.messages
          ..clear()
          ..addAll(messages);
        restored = true;
      }
    } on Object {
      // Хранилище не прочиталось: работаем с пустыми чатами.
    }
    _loaded = true;
    return restored;
  }

  /// Заменяет сообщения главного чата без записи: приветствие, которое
  /// показано, пока пользователь ничего не написал.
  void resetMain(List<ChatMessage> messages) {
    main.messages
      ..clear()
      ..addAll(messages);
  }

  /// Чат задачи [taskId]; создаётся, если его ещё нет. На диск пустой чат
  /// не пишется.
  ///
  /// Новый чат считается непрочитанным с диска ([ChatThread.loaded] =
  /// false): файл с его историей мог остаться без записи в index.json
  /// (сбой между записями) или уйти в архив, когда задача пропала из
  /// tasks.json. Первое открытие или первая запись сначала читают его, и
  /// история не затирается.
  ChatThread ensureTaskThread(String taskId, {String? parentTaskId}) =>
      _chats.putIfAbsent(
        ChatThread.taskChatId(taskId),
        () => ChatThread(
          id: ChatThread.taskChatId(taskId),
          kind: ChatKind.task,
          taskId: taskId,
          parentTaskId: parentTaskId,
          createdAt: _clock.now(),
          loaded: false,
        ),
      );

  /// Открывает чат задачи [taskId] (создаёт его при первом открытии).
  /// Как [open]: переключение сразу, сообщения — по готовности.
  Future<ChatThread> openTask(String taskId) {
    if (!_loaded) return ready.then((_) => openTask(taskId));
    ensureTaskThread(taskId);
    return open(ChatThread.taskChatId(taskId));
  }

  /// Открывает чат [chatId]: прежний уходит в стек «назад», «не
  /// прочитано» снимается, сообщения читаются, если ещё не прочитаны.
  /// Неизвестный чат — главный.
  ///
  /// Когда чаты уже загружены, [current] меняется сразу, до ожидания
  /// результата: интерфейс переключается без задержки, а сообщения
  /// незагруженного чата появляются, когда завершится возвращённый
  /// `Future`.
  Future<ChatThread> open(String chatId) {
    if (!_loaded) return ready.then((_) => open(chatId));
    final target = _chats[chatId] ?? main;
    if (target.id != _currentId) {
      if (_back.isEmpty || _back.last != _currentId) _back.add(_currentId);
      if (_back.length > maxBack) _back.removeAt(0);
      _currentId = target.id;
    }
    return _enter(target);
  }

  /// Предыдущий чат из стека (удалённые пропускаются), иначе главный.
  /// Переключение — сразу, как в [open].
  Future<ChatThread> back() {
    if (!_loaded) return ready.then((_) => back());
    while (_back.isNotEmpty) {
      final id = _back.removeLast();
      final thread = _chats[id];
      if (thread == null || id == _currentId) continue;
      _currentId = id;
      return _enter(thread);
    }
    _currentId = ChatThread.mainId;
    return _enter(main);
  }

  Future<ChatThread> _enter(ChatThread thread) {
    final wasUnread = thread.unread;
    thread.unread = false;
    return _ensureLoaded(thread).then((_) {
      if (wasUnread) _save(thread);
      return thread;
    });
  }

  Future<void> _ensureLoaded(ChatThread thread) {
    if (thread.loaded) return Future<void>.value();
    return _loading.putIfAbsent(thread.id, () async {
      List<ChatMessage> stored;
      try {
        stored = await _store.loadMessages(thread.id);
      } on Object {
        stored = <ChatMessage>[];
      }
      // Пока читали, в чат могли написать: сохранённое — перед новым.
      thread.messages.insertAll(0, stored);
      thread.loaded = true;
      _trim(thread);
      _loading.remove(thread.id);
    });
  }

  /// Добавляет [message] в чат [chatId]. Если чат сейчас не открыт и пишет
  /// помощник, чат отмечается непрочитанным ([notify]). Чата нет (задачу
  /// удалили) — сообщение пропадает, возвращается `false`.
  bool append(String chatId, ChatMessage message, {bool notify = true}) {
    final thread = _chats[chatId];
    if (thread == null) return false;
    thread.messages.add(message);
    _trim(thread);
    if (message.timestamp.isAfter(thread.lastActivityAt)) {
      thread.lastActivityAt = message.timestamp;
    }
    if (notify && chatId != _currentId && !message.fromUser) {
      thread.unread = true;
    }
    _save(thread);
    return true;
  }

  /// Заменяет сообщение [messageId] в чате [chatId] (например, ставит
  /// ссылку).
  bool replace(String chatId, String messageId, ChatMessage message) {
    final thread = _chats[chatId];
    if (thread == null) return false;
    final index =
        thread.messages.indexWhere((ChatMessage m) => m.id == messageId);
    if (index < 0) return false;
    thread.messages[index] = message;
    _save(thread);
    return true;
  }

  /// Задачу [taskId] создали в чате [fromChatId] командой [command] с
  /// ответом [reply]: в новом чате задачи — копии обоих (новые id), у копии
  /// ответа ссылка на исходное сообщение. Если задачу создали в чате другой
  /// задачи, она становится родителем ([ChatThread.parentTaskId]).
  ChatThread onTaskCreated(
    String taskId, {
    required String fromChatId,
    required ChatMessage command,
    required ChatMessage reply,
  }) {
    final origin = _chats[fromChatId];
    final parent = origin?.taskId;
    final thread = ensureTaskThread(taskId, parentTaskId: parent);
    final id = thread.id;
    append(id, command.copyAs(newMessageId()), notify: false);
    append(
      id,
      reply.copyAs(
        newMessageId(),
        link: ChatLink(chatId: fromChatId, messageId: reply.id, taskId: parent),
      ),
      notify: false,
    );
    return thread;
  }

  /// Меняет «Кому:» чата [chatId].
  void setAddressee(String chatId, String? addressee) {
    final thread = _chats[chatId];
    if (thread == null || thread.addressee == addressee) return;
    thread.addressee = addressee;
    _save(thread);
  }

  /// Удаляет чаты задач, которых больше нет ([liveTaskIds] — все задачи,
  /// кроме удалённых). Возвращает `true`, если удалён открытый чат (тогда
  /// открыт главный).
  bool prune(Set<String> liveTaskIds) {
    final dead = <String>[
      for (final thread in _chats.values)
        if (!thread.isMain && !liveTaskIds.contains(thread.taskId)) thread.id,
    ];
    if (dead.isEmpty) return false;
    var currentRemoved = false;
    for (final id in dead) {
      _chats.remove(id);
      _back.removeWhere((String b) => b == id);
      unawaited(_store.delete(id));
      if (id == _currentId) currentRemoved = true;
    }
    if (currentRemoved) _currentId = ChatThread.mainId;
    return currentRemoved;
  }

  /// Чаты задач с сообщениями, свежие сверху.
  List<ChatThread> recent({int limit = recentLimit}) {
    final list = <ChatThread>[
      for (final thread in _chats.values)
        if (!thread.isMain && thread.messageCount > 0) thread,
    ]..sort(
        (ChatThread a, ChatThread b) =>
            b.lastActivityAt.compareTo(a.lastActivityAt),
      );
    return list.take(limit).toList(growable: false);
  }

  /// «Очистить историю чатов»: чаты задач удаляются, главный пустеет,
  /// открыт главный. Приветствие добавляет интерфейс.
  Future<void> clearAll() {
    _chats.removeWhere((String id, ChatThread t) => !t.isMain);
    _back.clear();
    _currentId = ChatThread.mainId;
    main
      ..messages.clear()
      ..addressee = null
      ..unread = false
      ..loaded = true;
    return _store.clearAll();
  }

  /// Дописать отложенные записи, в том числе ждущие чтения своего чата.
  Future<void> flush() async {
    while (_deferred.isNotEmpty) {
      await Future.wait(List<Future<void>>.of(_deferred));
    }
    await _store.flush();
  }

  void _trim(ChatThread thread) {
    final extra = thread.messages.length - ChatStore.maxMessages;
    if (extra > 0) thread.messages.removeRange(0, extra);
  }

  void _save(ChatThread thread) {
    // Пустой чат задачи не пишется: он появится на диске с первым
    // сообщением.
    if (!thread.isMain && thread.messageCount == 0) return;
    if (!thread.loaded) {
      // Сообщения чата ещё читаются (или чат не открывали): запись — после
      // чтения, иначе сохранённая история затрётся тем, что написали в
      // этом запуске, а написанное сейчас не попадёт на диск.
      late final Future<void> deferred;
      deferred = _ensureLoaded(thread).then((_) {
        _deferred.remove(deferred);
        if (identical(_chats[thread.id], thread)) _save(thread);
      });
      _deferred.add(deferred);
      return;
    }
    unawaited(_store.save(thread));
  }
}
