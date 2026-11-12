import 'dart:async';
import 'dart:math';

import '../models/action_card.dart';
import '../services/clock.dart';
import 'chat_models.dart';
import 'chat_search.dart';
import 'chat_store.dart';

/// Карточка действия, которая ждёт «Подтвердить»: где она и какая.
typedef PendingCard = ({String chatId, String messageId, ChatMessage message});

/// Все чаты приложения: сессии и чаты задач, какой открыт и куда ведёт
/// «назад» (ADR-010, ADR-015).
///
/// Чистый Dart, без Flutter: интерфейс вызывает операции и перерисовывает
/// себя сам. Каждое изменение сразу уходит в [ChatStore] (тот решает,
/// когда писать на диск).
///
/// - Только сессии: чата «Главный» нет. Открыт всегда какой-то чат; при
///   старте — новая пустая сессия ([current]). Пустая сессия на диск не
///   пишется и в памяти не больше одной ([newSession]).
/// - Сессия — отдельный разговор без задачи: [prune] её не трогает,
///   название — первая команда.
/// - Чат задачи создаётся лениво: при первом открытии ([openTask]) или
///   когда задачу создали из чата ([onTaskCreated]). Пустой чат на диск не
///   пишется.
/// - Сообщения чатов читаются при первом открытии.
/// - Чат удалённой задачи удаляется ([prune]); выполненной — остаётся.
/// - Прежний «Главный» из старых файлов при [load] становится обычной
///   сессией [ChatThread.legacyMainSessionId] (если в нём были команды) и
///   уходит в архив хранилища.
final class ChatBook {
  /// [redactTitle] очищает название, которое берётся из сохранённой
  /// команды при переносе прежнего «Главного» (секреты, коды входа).
  ChatBook({
    required ChatStore store,
    Clock clock = const SystemClock(),
    String Function(String text)? redactTitle,
  })  : _store = store,
        _clock = clock,
        _redactTitle = redactTitle ?? _keep {
    _currentId = _createSession().id;
  }

  static String _keep(String text) => text;

  /// Название перенесённого «Главного», если первая команда пустая после
  /// очистки.
  static const String legacyTitle = 'Ранее';

  /// Глубина стека «назад».
  static const int maxBack = 20;

  /// Сколько чатов задач показывает боковое меню.
  static const int recentLimit = 5;

  /// Сколько сессий показывает меню в «Недавних сессиях».
  static const int sessionsLimit = 20;

  /// Длина названия сессии из первой команды.
  static const int titleLimit = 40;

  final ChatStore _store;
  final Clock _clock;
  final String Function(String text) _redactTitle;
  final Map<String, ChatThread> _chats = <String, ChatThread>{};
  final List<String> _back = <String>[];
  final Map<String, Future<void>> _loading = <String, Future<void>>{};

  /// Записи, которые ждут чтения своего чата ([_save]).
  final Set<Future<void>> _deferred = <Future<void>>{};
  final Random _random = Random();
  int _sequence = 0;
  late String _currentId;
  Future<void>? _ready;
  bool _loaded = false;

  ChatStore get store => _store;

  /// Чаты прочитаны ([load] закончился).
  bool get loaded => _loaded;

  /// Загрузка чатов: открытие чата и запись в него ждут её.
  Future<void> get ready => _ready ?? Future<void>.value();

  /// Открытый чат: есть всегда (в крайнем случае — пустая сессия).
  ChatThread get current => _chats[_currentId] ?? _chats[_emptySessionId()]!;

  String get currentId => _currentId;

  /// Чат [chatId]; старая ссылка на «Главный» ведёт в перенесённую сессию
  /// ([resolve]).
  ChatThread? thread(String chatId) => _chats[resolve(chatId)];

  /// Id чата, куда на самом деле ведёт [chatId]: старые копии в чатах
  /// задач ссылаются на `main`, а он перенесён в
  /// [ChatThread.legacyMainSessionId].
  String resolve(String chatId) => chatId == ChatThread.mainId &&
          _chats.containsKey(ChatThread.legacyMainSessionId)
      ? ChatThread.legacyMainSessionId
      : chatId;

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

  /// Читает метаданные всех чатов (сообщения — при открытии). Открытой
  /// остаётся пустая сессия, созданная при старте. Возвращает `true`, если
  /// прежний «Главный» перенесён в сессию ([_migrateLegacyMain]).
  Future<bool> load() {
    final future = _load();
    _ready = future.then((_) {});
    return future;
  }

  Future<bool> _load() async {
    var migrated = false;
    try {
      ChatThread? legacy;
      for (final meta in await _store.loadIndex()) {
        if (meta.kind == ChatKind.main) {
          legacy = meta;
        } else {
          _chats.putIfAbsent(meta.id, () => meta);
        }
      }
      // Порядок записей в index.json не важен: перенос — после всех.
      if (legacy != null) migrated = await _migrateLegacyMain(legacy);
    } on Object {
      // Хранилище не прочиталось: работаем с пустыми чатами.
    }
    _loaded = true;
    return migrated;
  }

  /// Прежний «Главный» ([ChatKind.main]) → обычная сессия
  /// [ChatThread.legacyMainSessionId], без потери данных:
  ///
  /// - есть команды пользователя — сессия с теми же сообщениями (те же id
  ///   и порядок, карточки, ссылки, задачи), «не прочитано» и временем
  ///   последней активности; название — первая команда (очищенная,
  ///   [titleLimit]), иначе [legacyTitle]; создана — не позже первого
  ///   сообщения (у «Главного» `created_at` — время последнего запуска);
  /// - только приветствия и напоминания (или файл не читается) — ничего;
  /// - затем `main.json` уходит в архив хранилища ([ChatStore.delete]) и из
  ///   index.json.
  ///
  /// Повторяется без вреда: сбой между записью сессии и архивом — при
  /// следующем запуске сессия уже есть на диске (её новые сообщения не
  /// трогаются), остаётся убрать `main.json`. `main.json` уходит в архив,
  /// только когда `session-main.json` прочитан с диска с сообщениями:
  /// запись не удалась (нет места, нет прав — [ChatStore.flush] об этом не
  /// сообщает) — `main.json` остаётся, и перенос повторится при следующем
  /// запуске. Запись сессии в index.json без файла за ней (сбой записи)
  /// тоже переносится заново.
  Future<bool> _migrateLegacyMain(ChatThread meta) async {
    List<ChatMessage> messages;
    try {
      messages = await _store.loadMessages(ChatThread.mainId);
    } on Object {
      messages = <ChatMessage>[];
    }
    final firstUser = messages.where((ChatMessage m) => m.fromUser).firstOrNull;
    if (firstUser == null) {
      // Только приветствия и напоминания: переносить нечего.
      await _store.delete(ChatThread.mainId);
      return false;
    }
    const id = ChatThread.legacyMainSessionId;
    if (_chats.containsKey(id) && await _storedMessages(id) > 0) {
      // Перенос уже был, не успели убрать `main.json`.
      await _store.delete(ChatThread.mainId);
      return false;
    }
    var created = meta.createdAt;
    if (messages.first.timestamp.isBefore(created)) {
      created = messages.first.timestamp;
    }
    var last = meta.lastActivityAt;
    if (messages.last.timestamp.isAfter(last)) last = messages.last.timestamp;
    final title = sessionTitle(_redactTitle(firstUser.text));
    final session = ChatThread(
      id: id,
      kind: ChatKind.session,
      createdAt: created,
      lastActivityAt: last,
      addressee: meta.addressee,
      title: title.isEmpty ? legacyTitle : title,
      unread: meta.unread,
      messages: messages,
    );
    _chats[id] = session;
    // Сначала новая сессия на диске, потом — архив старого файла.
    await _store.save(session);
    await _store.flush();
    if (await _storedMessages(id) > 0) {
      await _store.delete(ChatThread.mainId);
    }
    return true;
  }

  /// Сколько сообщений чата [chatId] читается из хранилища (0 — файла нет
  /// или он не читается).
  Future<int> _storedMessages(String chatId) async {
    try {
      return (await _store.loadMessages(chatId)).length;
    } on Object {
      return 0;
    }
  }

  /// Новая пустая сессия в памяти (на диск — с первым сообщением).
  ChatThread _createSession() {
    final now = _clock.now();
    final id = '${ChatThread.sessionPrefix}${now.microsecondsSinceEpoch}_'
        '${_random.nextInt(1 << 20).toRadixString(16)}';
    return _chats[id] =
        ChatThread(id: id, kind: ChatKind.session, createdAt: now);
  }

  /// Пустая сессия: открытая, если она пуста, иначе уже созданная раньше,
  /// иначе новая. Пустых сессий в памяти не больше одной.
  String _emptySessionId() {
    final open = _chats[_currentId];
    if (open != null && open.isSession && open.messageCount == 0) {
      return open.id;
    }
    for (final thread in _chats.values) {
      if (thread.isSession && thread.messageCount == 0) return thread.id;
    }
    return _createSession().id;
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
  /// Неизвестный чат — пустая сессия.
  ///
  /// Когда чаты уже загружены, [current] меняется сразу, до ожидания
  /// результата: интерфейс переключается без задержки, а сообщения
  /// незагруженного чата появляются, когда завершится возвращённый
  /// `Future`.
  Future<ChatThread> open(String chatId) {
    if (!_loaded) return ready.then((_) => open(chatId));
    final target = _chats[resolve(chatId)] ?? _chats[_emptySessionId()]!;
    if (target.id != _currentId) {
      if (_back.isEmpty || _back.last != _currentId) _back.add(_currentId);
      if (_back.length > maxBack) _back.removeAt(0);
      _currentId = target.id;
    }
    return _enter(target);
  }

  /// Предыдущий чат из стека (удалённые пропускаются), иначе пустая
  /// сессия (открытая пустая — остаётся). Переключение — сразу, как в
  /// [open].
  Future<ChatThread> back() {
    if (!_loaded) return ready.then((_) => back());
    while (_back.isNotEmpty) {
      final id = _back.removeLast();
      final thread = _chats[id];
      if (thread == null || id == _currentId) continue;
      _currentId = id;
      return _enter(thread);
    }
    _currentId = _emptySessionId();
    return _enter(current);
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
    if (thread.isSession && thread.title == null && message.fromUser) {
      final title = sessionTitle(message.text);
      if (title.isNotEmpty) thread.title = title;
    }
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

  /// Меняет сохранённого адресата чата [chatId] (старое поле: выбора
  /// «Кому» в интерфейсе больше нет, и он его не пишет).
  void setAddressee(String chatId, String? addressee) {
    final thread = _chats[chatId];
    if (thread == null || thread.addressee == addressee) return;
    thread.addressee = addressee;
    _save(thread);
  }

  /// Сохранить чат [chatId] как есть: сообщения не менялись, но
  /// изменилось их содержимое (карточка действия ушла на запись). Нет
  /// такого чата — ничего. Сразу на диск — [flush].
  void touch(String chatId) {
    final thread = _chats[chatId];
    if (thread != null) _save(thread);
  }

  /// Удаляет чаты задач, которых больше нет ([liveTaskIds] — все задачи,
  /// кроме удалённых). Сессии не трогает. Возвращает `true`, если удалён
  /// открытый чат (тогда открыта пустая сессия).
  bool prune(Set<String> liveTaskIds) {
    final dead = <String>[
      for (final thread in _chats.values)
        if (thread.kind == ChatKind.task &&
            !liveTaskIds.contains(thread.taskId))
          thread.id,
    ];
    if (dead.isEmpty) return false;
    var currentRemoved = false;
    for (final id in dead) {
      _chats.remove(id);
      _back.removeWhere((String b) => b == id);
      unawaited(_store.delete(id));
      if (id == _currentId) currentRemoved = true;
    }
    if (currentRemoved) _currentId = _emptySessionId();
    return currentRemoved;
  }

  /// «+» в меню: пустая сессия открывается сразу (прежний чат — в стек
  /// «назад»). Без приветствия; на диск — с первым сообщением. Если
  /// открытая сессия ещё пуста, остаётся она же; пустая сессия,
  /// оставленная раньше, используется снова.
  Future<ChatThread> newSession() {
    if (!_loaded) return ready.then((_) => newSession());
    final current = this.current;
    if (current.isSession && current.messageCount == 0) {
      return Future<ChatThread>.value(current);
    }
    return open(_emptySessionId());
  }

  /// Название чата для меню и поиска: у сессии — первая команда или
  /// «Новая сессия». Чату задачи название даёт задача ([taskTitle]).
  static String titleOf(ChatThread thread, {String? taskTitle}) =>
      switch (thread.kind) {
        ChatKind.main ||
        ChatKind.session =>
          thread.title ?? ChatThread.untitledSession,
        ChatKind.task => taskTitle ?? 'Задача',
      };

  /// Название сессии из команды: до [titleLimit] знаков, с «…».
  static String sessionTitle(String command) {
    final flat = command.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.length <= titleLimit) return flat;
    return '${flat.substring(0, titleLimit - 1).trimRight()}…';
  }

  /// «Недавние сессии» в меню: сессии и чаты задач с сообщениями, свежие
  /// сверху. Открытый чат — всегда в списке.
  List<ChatThread> sessions({int limit = sessionsLimit}) {
    final list = <ChatThread>[
      for (final thread in _chats.values)
        if (thread.messageCount > 0 || thread.id == _currentId) thread,
    ]..sort(
        (ChatThread a, ChatThread b) =>
            b.lastActivityAt.compareTo(a.lastActivityAt),
      );
    final shown = list.take(limit).toList();
    if (!shown.contains(current)) shown.add(current);
    return shown;
  }

  /// Сколько чатов с хотя бы одной своей командой пользователя (среди
  /// прочитанных) или с сообщениями (среди непрочитанных). Копия команды в
  /// чате новой задачи ([onTaskCreated]) — не своя: она уже посчитана в
  /// чате, где её написали. Непрочитанный чат задачи без своих сообщений
  /// поверх этих двух копий не считается.
  int get sessionCount => _chats.values.where((ChatThread t) {
        final messages = t.messages;
        for (var i = 0; i < messages.length; i++) {
          if (messages[i].fromUser && !isCopiedCommand(messages, i)) {
            return true;
          }
        }
        return !t.loaded && _storedHasOwn(t);
      }).length;

  /// Сколько сообщений непрочитанного чата [thread] лежит только на диске.
  static int _storedCount(ChatThread thread) =>
      thread.loaded ? 0 : thread.messageCount - thread.messages.length;

  /// На диске у непрочитанного чата, вероятно, есть свои команды: у чата
  /// задачи — сверх двух копий из [onTaskCreated].
  /// У сессии — по названию: оно появляется с первой командой ([append]),
  /// а сессия без команд (только ответы помощника) названия не получает.
  /// Так счёт одинаков до и после перезапуска.
  static bool _storedHasOwn(ChatThread thread) => switch (thread.kind) {
        ChatKind.task => _storedCount(thread) > 2,
        _ => _storedCount(thread) > 0 && thread.title != null,
      };

  /// Команда [messages]`[i]` — копия из [onTaskCreated]: за ней идёт копия
  /// ответа со ссылкой на исходное сообщение ([ChatLink.messageId]).
  /// Исходный ответ ссылается на чат задачи без сообщения.
  static bool isCopiedCommand(List<ChatMessage> messages, int i) {
    if (!messages[i].fromUser || i + 1 >= messages.length) return false;
    final next = messages[i + 1];
    return !next.fromUser && next.link?.messageId != null;
  }

  /// Карточки действий, которые ждут «Подтвердить» и ещё могут уйти на
  /// запись, — из прочитанных чатов, последняя версия каждой карточки.
  List<PendingCard> pendingCards(DateTime now) {
    final found = <String, PendingCard>{};
    for (final thread in _chats.values) {
      for (final message in thread.messages) {
        final ActionCard? card = message.card;
        if (card == null) continue;
        if (card.canSend(now)) {
          found[card.id] = (
            chatId: thread.id,
            messageId: message.id,
            message: message,
          );
        } else {
          found.remove(card.id);
        }
      }
    }
    return found.values.toList(growable: false);
  }

  /// Поиск по сессиям: названия чатов и тексты сообщений, без регистра,
  /// «ё» = «е». Сообщения с карточкой «Паролей» и карточками действий
  /// пропускаются, пустые сессии — тоже (у них нет ничего, кроме «Новая
  /// сессия»). Состояние книги не меняется: непрочитанные чаты читаются из
  /// хранилища только для поиска. [titles] — названия чатов задач по id
  /// задачи.
  Future<List<ChatSearchHit>> search(
    String query, {
    Map<String, String> titles = const <String, String>{},
    int limit = 50,
  }) async {
    final needle = ChatSearch.fold(query.trim());
    if (needle.isEmpty) return const <ChatSearchHit>[];
    final hits = <ChatSearchHit>[];
    final threads = List<ChatThread>.of(_chats.values)
      ..sort(
        (ChatThread a, ChatThread b) =>
            b.lastActivityAt.compareTo(a.lastActivityAt),
      );
    for (final thread in threads) {
      if (hits.length >= limit) break;
      // Пустая сессия — не результат («Новая сессия» без истории). Пустой
      // чат задачи находится по названию задачи.
      if (thread.isSession && thread.messageCount == 0) continue;
      final title = titleOf(thread, taskTitle: titles[thread.taskId]);
      final titleAt = ChatSearch.fold(title).indexOf(needle);
      List<ChatMessage> messages;
      if (thread.loaded) {
        messages = List<ChatMessage>.of(thread.messages);
      } else {
        try {
          messages = <ChatMessage>[
            ...await _store.loadMessages(thread.id),
            ...thread.messages,
          ];
        } on Object {
          messages = List<ChatMessage>.of(thread.messages);
        }
      }
      ChatSearchHit? hit;
      for (final message in messages.reversed) {
        if (message.secureCard != null || message.card != null) continue;
        final at = ChatSearch.fold(message.text).indexOf(needle);
        if (at < 0) continue;
        final (snippet, start, end) =
            ChatSearch.snippet(message.text, at, at + needle.length);
        hit = ChatSearchHit(
          chatId: thread.id,
          title: title,
          personaId: message.fromUser ? null : message.personaId,
          messageId: message.id,
          at: message.timestamp,
          snippet: snippet,
          matchStart: start,
          matchEnd: end,
        );
        break;
      }
      if (hit == null && titleAt >= 0) {
        hit = ChatSearchHit(
          chatId: thread.id,
          title: title,
          at: thread.lastActivityAt,
          snippet: title,
          matchStart: titleAt,
          matchEnd: titleAt + needle.length,
        );
      }
      if (hit != null) hits.add(hit);
    }
    return hits;
  }

  /// Дни, когда в сессиях писали команды: локальная дата в полночь →
  /// число команд пользователя. Прочитанные чаты считаются по сообщениям,
  /// непрочитанные — по [stored] (сообщения с диска по id чата), а если
  /// их там нет — приблизительно: день создания и день последней
  /// активности по index.json, по одной отметке.
  Map<DateTime, int> activityDays({
    Map<String, List<ChatMessage>> stored = const <String, List<ChatMessage>>{},
  }) {
    final result = <DateTime, int>{};
    void mark(DateTime at) {
      final local = at.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      result[day] = (result[day] ?? 0) + 1;
    }

    void markOwn(List<ChatMessage> messages) {
      for (var i = 0; i < messages.length; i++) {
        // Копия команды в чате новой задачи уже отмечена там, где её
        // написали.
        if (messages[i].fromUser && !isCopiedCommand(messages, i)) {
          mark(messages[i].timestamp);
        }
      }
    }

    for (final thread in _chats.values) {
      final fromDisk = stored[thread.id];
      final List<ChatMessage>? messages = thread.loaded
          ? thread.messages
          : fromDisk == null
              ? null
              : <ChatMessage>[...fromDisk, ...thread.messages];
      if (messages != null) {
        markOwn(messages);
        continue;
      }
      // Новые сообщения в памяти — точно, сохранённые — по index.json.
      markOwn(thread.messages);
      if (_storedHasOwn(thread)) {
        mark(thread.createdAt);
        final first = thread.createdAt.toLocal();
        final last = thread.lastActivityAt.toLocal();
        if (first.year != last.year ||
            first.month != last.month ||
            first.day != last.day) {
          mark(thread.lastActivityAt);
        }
      }
    }
    return result;
  }

  /// Сообщения с диска всех непрочитанных чатов — для точной
  /// [activityDays]. Состояние книги не меняется; чат, который не
  /// прочитался, пропускается (останется приблизительным).
  Future<Map<String, List<ChatMessage>>> readStored() async {
    final result = <String, List<ChatMessage>>{};
    for (final thread in List<ChatThread>.of(_chats.values)) {
      if (thread.loaded || thread.messageCount == 0) continue;
      try {
        result[thread.id] = await _store.loadMessages(thread.id);
      } on Object {
        // Битый файл: этот чат считается по index.json.
      }
    }
    return result;
  }

  /// Все ли чаты с сообщениями прочитаны или есть в [stored].
  bool activityExact(Map<String, List<ChatMessage>> stored) =>
      _chats.values.every(
        (ChatThread t) =>
            t.loaded || t.messageCount == 0 || stored.containsKey(t.id),
      );

  /// Самая ранняя дата чатов с сообщениями; `null` — таких нет.
  DateTime? get earliestActivity {
    DateTime? best;
    for (final thread in _chats.values) {
      if (thread.messageCount == 0) continue;
      var at = thread.createdAt;
      if (thread.messages.isNotEmpty &&
          thread.messages.first.timestamp.isBefore(at)) {
        at = thread.messages.first.timestamp;
      }
      if (best == null || at.isBefore(best)) best = at;
    }
    return best;
  }

  /// Чаты задач с сообщениями, свежие сверху.
  List<ChatThread> recent({int limit = recentLimit}) {
    final list = <ChatThread>[
      for (final thread in _chats.values)
        if (thread.kind == ChatKind.task && thread.messageCount > 0) thread,
    ]..sort(
        (ChatThread a, ChatThread b) =>
            b.lastActivityAt.compareTo(a.lastActivityAt),
      );
    return list.take(limit).toList(growable: false);
  }

  /// «Очистить историю сессий»: все сессии и чаты задач удаляются,
  /// открыта новая пустая сессия.
  Future<void> clearAll() {
    _chats.clear();
    _back.clear();
    _currentId = _createSession().id;
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
    // Пустой чат не пишется: он появится на диске с первым сообщением.
    if (thread.messageCount == 0) return;
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
