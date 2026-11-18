import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../core/chats/attachments.dart';
import '../core/chats/chat_models.dart';
import '../core/chats/chat_projects.dart';
import '../core/chats/chat_store.dart';
import '../core/models/task.dart';
import '../core/services/clock.dart';
import '../core/storage/task_repository.dart';
import 'widget_storage.dart';

/// Ответ склада на `my_*`: [status] 0 — нет связи.
final class MyReply {
  const MyReply(this.status, [this.json]);

  final int status;
  final Map<String, Object?>? json;

  bool get ok => status >= 200 && status < 300 && json?['ok'] == true;

  String get code => switch (json?['code']) {
        final String c => c,
        _ => '',
      };

  /// Повторить позже: нет связи, «медленнее», сервер занят.
  bool get transient => status == 0 || status == 429 || status >= 500;
}

/// Запрос `my_*` под ключом помощника.
typedef MyCall = Future<MyReply> Function(
  String action,
  Map<String, Object?> body,
);

/// Логин для ключей хранилища: как у прежней истории (`svz:hist:<логин>`).
String widgetLoginKey(String login) {
  final clean = login.toLowerCase().replaceAll(RegExp(r'[^a-z0-9._@-]'), '');
  return clean.isEmpty ? '_' : clean;
}

/// Записи сотрудника в веб-помощнике (ADR-038): разговоры, проекты,
/// задачи. Правда — личное хранилище склада `my_*` (1.4.74, README
/// склада «Договор для Связного» §7.3); `localStorage` (`svz:…:<логин>`) —
/// только кэш: страница склада стирает `svz:*` при выходе. Склад старый
/// (`ask_me` без `store`) или ответил на `my_*` 400/401/403 — помощник
/// работает на одном кэше этого браузера до конца сеанса, ключ входа при
/// этом не считается устаревшим.
final class WidgetStore {
  WidgetStore({
    required this.storage,
    required String login,
    Clock clock = const SystemClock(),
    Random? random,
  })  : login = widgetLoginKey(login),
        _clock = clock,
        _random = random ?? Random() {
    chats = WidgetChatStore._(this);
    tasks = WidgetTaskRepository._(this);
    _loadState();
  }

  final KeyValueStorage storage;
  final String login;
  final Clock _clock;
  final Random _random;

  late final WidgetChatStore chats;
  late final WidgetTaskRepository tasks;

  /// Запрос к складу; `null` — склад хранилища не даёт.
  MyCall? _call;

  /// Склад сказал, что хранилище есть (`ask_me.store.on`) и оно не
  /// выключилось в этом сеансе.
  bool get remote => _call != null && !_off;
  bool _off = false;

  /// Напоминания склада включены (`ask_me.store.signals`).
  bool signals = false;

  /// Почему хранилище склада выключилось в этом сеансе — для журнала и
  /// тестов.
  String offReason = '';

  /// Последний отказ склада по правке (`действие: статус код`). Правка
  /// остаётся в очереди и уйдёт следующей синхронизацией.
  String lastError = '';

  /// Что-то записалось на склад: странице — `changed {what: ["my"]}`.
  void Function()? onPushed;

  // ------------------------------------------------------------ ключи

  String get _prefix => widgetKeyPrefix;
  String get chatsKey => '${_prefix}chats:$login';
  String chatKey(String id) => '${_prefix}chat:$login:$id';
  String get projectsKey => '${_prefix}projects:$login';
  String get tasksKey => '${_prefix}tasks:$login';
  String get stateKey => '${_prefix}my:$login';
  String get historyKey => '${_prefix}hist:$login';

  /// Все ключи этого входа — для выхода из склада.
  void clear() {
    for (final id in _readIndex().keys) {
      storage.remove(chatKey(id));
    }
    for (final key in <String>[
      chatsKey,
      projectsKey,
      tasksKey,
      stateKey,
      historyKey,
    ]) {
      storage.remove(key);
    }
    _state = _SyncState();
  }

  // -------------------------------------------------- состояние синхр.

  _SyncState _state = _SyncState();

  void _loadState() {
    final text = storage.read(stateKey);
    if (text == null) return;
    try {
      final json = jsonDecode(text);
      if (json is Map) _state = _SyncState.fromJson(json);
    } on Object {
      _state = _SyncState();
    }
  }

  void _saveState() => _write(stateKey, jsonEncode(_state.toJson()));

  /// Записать в `localStorage`; нет места — убрать кэш сообщений других
  /// разговоров и попробовать ещё раз. Не вышло — кэша нет, правда на
  /// складе.
  bool _write(String key, String value) {
    try {
      storage.write(key, value);
      return true;
    } on Object {
      for (final id in _readIndex().keys) {
        final other = chatKey(id);
        if (other != key) storage.remove(other);
      }
      try {
        storage.write(key, value);
        return true;
      } on Object {
        return false;
      }
    }
  }

  Map<String, Map<String, Object?>> _readIndex() {
    final text = storage.read(chatsKey);
    if (text == null) return <String, Map<String, Object?>>{};
    try {
      final json = jsonDecode(text);
      if (json is! Map) return <String, Map<String, Object?>>{};
      return <String, Map<String, Object?>>{
        for (final MapEntry(:key, :value) in json.entries)
          if (key is String && value is Map)
            key: Map<String, Object?>.from(value),
      };
    } on Object {
      return <String, Map<String, Object?>>{};
    }
  }

  void _writeIndex(Map<String, Map<String, Object?>> index) =>
      _write(chatsKey, jsonEncode(index));

  /// `op` записи: 16 знаков `[a-z0-9]` — повтор безвреден.
  String _op() {
    const abc = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return String.fromCharCodes(
      List<int>.generate(16, (_) => abc.codeUnitAt(_random.nextInt(36))),
    );
  }

  String _iso(DateTime at) => at.toUtc().toIso8601String();

  // ------------------------------------------------------------- вход

  /// Склад ответил `ask_me`: [me] — его ответ. Есть `store.on` — дальше
  /// работаем со складом через [call]; нет — только кэш.
  void attach(Map<String, Object?>? me, MyCall call) {
    final store = me?['store'];
    final on = store is Map && store['on'] == true;
    signals = store is Map && store['signals'] == true;
    _call = on ? call : null;
    _off = false;
    offReason = on ? '' : 'нет store в ask_me';
  }

  Future<MyReply> _send(String action, Map<String, Object?> body) async {
    final call = _call;
    if (call == null || _off) return const MyReply(0);
    MyReply reply;
    try {
      reply = await call(action, body);
    } on Object {
      reply = const MyReply(0);
    }
    // Старый склад (400 «Неизвестное действие», 401 «Неверный пароль»),
    // нет прав на хранилище (403) — хранилище выключено до конца сеанса.
    // Это не «ключ устарел»: вход и вопросы складу работают как прежде.
    final unknown = reply.status == 400 && reply.code.isEmpty;
    if (reply.status == 401 || reply.status == 403 || unknown) {
      _off = true;
      offReason = '$action: ${reply.status} ${reply.code}'.trim();
    }
    return reply;
  }

  // ------------------------------------------------------- с сервера

  /// Прежняя история браузера (`svz:hist:<логин>`): на склад одним
  /// `my_import`, без склада — в разговор кэша. Потом ключ убирается.
  Future<void> importHistory() async {
    final legacy = WidgetHistory(storage, login);
    final messages = legacy.load();
    if (messages.isEmpty) {
      if (storage.read(historyKey) != null) legacy.clear();
      return;
    }
    if (remote) {
      final reply = await _send('my_import', <String, Object?>{
        'source': 'svz:hist',
        'messages': <Object?>[
          for (final m in messages.length > 200
              ? messages.sublist(messages.length - 200)
              : messages)
            m.toJson(),
        ],
        'title': 'Разговор в браузере',
        'op': _op(),
      });
      // gone — разговор импорта удалили на складе: копию не возвращаем.
      // Склад сам узнаёт повтор импорта (идемпотентно).
      if (reply.ok || reply.code == 'gone' || reply.json?['gone'] == true) {
        legacy.clear();
        return;
      }
      // Хранилище выключилось (старый склад, нет прав) — в разговор кэша.
      if (!_off) return;
    }
    final at = messages.first.timestamp;
    final thread = ChatThread(
      id: '${ChatThread.sessionPrefix}imp_local',
      kind: ChatKind.session,
      createdAt: at,
      lastActivityAt: messages.last.timestamp,
      title: 'Разговор в браузере',
    )..messages.addAll(messages);
    thread.loaded = true;
    await chats.save(thread);
    legacy.clear();
  }

  /// `my_sync`: изменения с прошлого раза (или всё, `full`) — в кэш. Свои
  /// неотправленные правки побеждают: они уйдут следующей [flush].
  /// `true` — что-то изменилось.
  Future<bool> pull() async {
    if (!remote) return false;
    var changed = false;
    for (var page = 0; page < 20; page++) {
      final reply = await _send('my_sync', <String, Object?>{
        if (_state.epoch.isNotEmpty) 'epoch': _state.epoch,
        'since': _state.since,
        if (_state.mark.isNotEmpty) 'mark': _state.mark,
        'limit': 500,
      });
      final json = reply.json;
      if (!reply.ok || json == null) return changed;
      final full = json['full'] == true;
      final items = <(String, Map<String, Object?>)>[
        if (json['items'] case final List<Object?> list)
          for (final item in list)
            if (item is Map && item['type'] is String && item['obj'] is Map)
              (
                item['type']! as String,
                Map<String, Object?>.from(item['obj']! as Map),
              ),
      ];
      final gone = <(String, String)>[
        if (json['gone'] case final List<Object?> list)
          for (final item in list)
            if (item is Map && item['type'] is String && item['id'] is String)
              (item['type']! as String, item['id']! as String),
      ];
      _apply(items, gone, full: full && page == 0);
      changed = changed || items.isNotEmpty || gone.isNotEmpty || full;
      _state
        ..epoch = '${json['epoch'] ?? ''}'
        ..since = switch (json['next']) {
          final int n => n,
          _ => _state.since,
        }
        ..mark = '${json['mark'] ?? ''}';
      _saveState();
      if (json['more'] != true) break;
    }
    return changed;
  }

  void _apply(
    List<(String, Map<String, Object?>)> items,
    List<(String, String)> gone, {
    required bool full,
  }) {
    final projects = <String, ChatProject>{
      for (final p in chats._projects()) p.id: p,
    };
    final taskMap = <String, Task>{for (final t in tasks._all()) t.id: t};
    final previousTasks = Map<String, Task>.of(taskMap);
    final index = _readIndex();
    if (full) {
      // Всё заново: остаются только свои неотправленные.
      _state.known.clear();
      projects
          .removeWhere((String id, _) => !_state.dirtyProjects.contains(id));
      taskMap.removeWhere((String id, _) => !_state.dirtyTasks.contains(id));
      for (final id in index.keys.toList()) {
        if (_state.dirtyChats.contains(id)) continue;
        index.remove(id);
        storage.remove(chatKey(id));
      }
    }
    final serverProjects = <String, Map<String, Object?>>{};
    for (final (type, obj) in items) {
      final id = obj['id'];
      if (id is! String) continue;
      final rev = obj['rev'];
      if (rev is int) _state.known[id] = rev;
      switch (type) {
        case 'project':
          serverProjects[id] = obj;
          if (_state.dirtyProjects.contains(id)) continue;
          final status = obj['status'];
          final project = ChatProject.fromJson(obj);
          if (project == null || (status is String && status != 'active')) {
            projects.remove(id);
          } else {
            projects[id] = project;
          }
          _state.pushedProjects[id] = _projectHash(project);
        case 'task':
          if (_state.dirtyTasks.contains(id)) continue;
          final task = _taskFrom(obj, projects);
          if (task == null) {
            // Не разобрали — прежняя копия лучше, чем ничего.
            final old = previousTasks[id];
            if (old != null) taskMap[id] = old;
            continue;
          }
          taskMap[id] = task;
          final pid = obj['project_id'];
          if (pid is String) {
            _state.taskProject[id] = pid;
          } else {
            _state.taskProject.remove(id);
          }
        case 'chat':
          if (_state.dirtyChats.contains(id)) continue;
          final thread = ChatThread.fromMetaJson(obj);
          if (thread == null) continue;
          final u = obj['u'];
          final old = _state.chatU[id];
          // Сообщения изменились на складе (другое устройство) — кэш
          // сообщений перечитается при открытии.
          if (u is int && old != u) {
            storage.remove(chatKey(id));
            _state.chatU[id] = u;
          }
          index[id] = thread.metaJson()
            ..['count'] = obj['count'] is int ? obj['count'] : 0;
          _state.pushedMeta[id] = _metaHash(thread);
      }
    }
    for (final (type, id) in gone) {
      _state.known.remove(id);
      switch (type) {
        case 'project':
          projects.remove(id);
          _state.dirtyProjects.remove(id);
        case 'task':
          taskMap.remove(id);
          _state.dirtyTasks.remove(id);
          // Чат задачи — вместе с ней.
          final chatId = ChatThread.taskChatId(id);
          index.remove(chatId);
          storage.remove(chatKey(chatId));
        case 'chat':
          index.remove(id);
          storage.remove(chatKey(id));
          _state.dirtyChats.remove(id);
      }
    }
    chats._writeProjects(projects.values.toList());
    tasks._writeAll(taskMap.values.toList());
    _writeIndex(index);
  }

  Task? _taskFrom(Map<String, Object?> obj, Map<String, ChatProject> projects) {
    try {
      final json = Map<String, dynamic>.from(obj);
      json['deleted_at'] = null;
      var task = Task.fromJson(json);
      // Проект склада — метка задач Связного (ADR-018): первая метка.
      final pid = obj['project_id'];
      final tag = pid is String ? projects[pid]?.taskTag : null;
      if (tag != null && !task.tags.contains(tag)) {
        task = task.copyWith(tags: <String>[tag, ...task.tags]);
      }
      return task;
    } on Object {
      return null;
    }
  }

  static String _projectHash(ChatProject? p) =>
      p == null ? '' : jsonEncode(p.toJson());

  static String _metaHash(ChatThread t) => jsonEncode(<String, Object?>{
        'title': t.title,
        'custom_title': t.customTitle,
        'pinned_at': t.pinnedAt?.toIso8601String(),
        'project_id': t.projectId,
        'preview': t.preview,
        'last_persona': t.lastPersonaId,
        'own_talk': t.ownTalk,
      });

  /// Сообщения разговора со склада (последние 100) — когда в кэше их нет.
  Future<List<ChatMessage>> fetchMessages(String chatId) async {
    if (!remote) return <ChatMessage>[];
    final reply = await _send('my_chat_msgs', <String, Object?>{
      'chat': chatId,
      'limit': 100,
    });
    if (!reply.ok) return <ChatMessage>[];
    final list = reply.json?['messages'];
    final out = <ChatMessage>[
      if (list is List)
        for (final m in list)
          if (ChatMessage.fromJson(m) case final ChatMessage x) x,
    ];
    if (out.isNotEmpty) _state.pushedMessage[chatId] = out.last.id;
    if (reply.json?['u'] case final int u) _state.chatU[chatId] = u;
    _saveState();
    return out;
  }

  // --------------------------------------------------------- на склад

  void _dirty(Set<String> set, String id) {
    set.add(id);
    _saveState();
    _schedule();
  }

  void _deleted(String type, String id) {
    _state.dirtyProjects.remove(id);
    _state.dirtyTasks.remove(id);
    _state.dirtyChats.remove(id);
    if (_state.known.containsKey(id) || type == 'chat') {
      _state.deletes.add('$type|$id');
    }
    _saveState();
    _schedule();
  }

  bool _scheduled = false;
  Future<void> _flushing = Future<void>.value();

  void _schedule() {
    if (_scheduled || !remote) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      unawaited(flush());
    });
  }

  /// Отправить неотправленное. Нет связи — останется до следующего раза.
  Future<void> flush() {
    final next = _flushing.then((_) => _flush());
    _flushing = next.catchError((Object _) {});
    return next;
  }

  Future<void> _flush() async {
    if (!remote) return;
    var pushed = false;
    bool stop(MyReply r) => r.transient || _off;
    // Правка дошла (или объекта на складе больше нет). Иначе метка
    // «грязное» остаётся: полная синхронизация не сотрёт локальную копию.
    bool settled(String what, MyReply r) {
      if (r.ok || r.code == 'gone') return true;
      lastError = '$what: ${r.status} ${r.code}'.trim();
      return false;
    }

    for (final key in _state.deletes.toList()) {
      final [type, id] = key.split('|');
      final reply = await _send('my_del', <String, Object?>{
        'type': type,
        'id': id,
        if (type == 'project') 'chats': 'keep',
        'op': _op(),
      });
      if (stop(reply)) return _done(pushed);
      if (!settled('my_del', reply) && reply.status != 404) continue;
      _state.deletes.remove(key);
      _state.known.remove(id);
      pushed = pushed || reply.ok;
    }

    final projects = {for (final p in chats._projects()) p.id: p};
    for (final id in _state.dirtyProjects.toList()) {
      final p = projects[id];
      if (p == null) {
        _state.dirtyProjects.remove(id);
        continue;
      }
      final fields = <String, Object?>{
        'name': p.name,
        'description': p.description ?? '',
        'task_tag': p.taskTag,
        'pinned_at': p.pinnedAt == null ? null : _iso(p.pinnedAt!),
      };
      final reply = await _putOrPatch(
        'project',
        id,
        <String, Object?>{
          'id': id,
          ...fields,
          'created_at': _iso(p.createdAt),
          'src': 'tridot',
        },
        fields,
        p.updatedAt,
      );
      if (stop(reply)) return _done(pushed);
      if (!settled('project $id', reply)) continue;
      _state.dirtyProjects.remove(id);
      _state.pushedProjects[id] = _projectHash(p);
      pushed = pushed || reply.ok;
    }

    final taskMap = {for (final t in tasks._all()) t.id: t};
    for (final id in _state.dirtyTasks.toList()) {
      final t = taskMap[id];
      if (t == null) {
        _state.dirtyTasks.remove(id);
        continue;
      }
      final projectId = _projectIdFor(t, projects.values);
      final json = t.toJson();
      final fields = <String, Object?>{
        for (final f in const <String>[
          'title',
          'description',
          'status',
          'priority',
          'due_at',
          'due_precision',
          'tags',
          'notes',
          'items',
        ])
          f: json[f] ?? (f == 'notes' || f == 'items' ? <Object?>[] : null),
        'project_id': projectId,
      };
      final reply = await _putOrPatch(
        'task',
        id,
        <String, Object?>{
          ...json,
          'project_id': projectId,
          'src': 'tridot',
        }..remove('deleted_at'),
        fields,
        t.updatedAt,
      );
      if (stop(reply)) return _done(pushed);
      if (!settled('task $id', reply)) continue;
      _state.dirtyTasks.remove(id);
      if (projectId == null) {
        _state.taskProject.remove(id);
      } else {
        _state.taskProject[id] = projectId;
      }
      if (reply.code == 'gone') tasks._drop(id);
      pushed = pushed || reply.ok;
    }

    final index = _readIndex();
    for (final id in _state.dirtyChats.toList()) {
      final meta = index[id];
      final thread = meta == null ? null : ChatThread.fromMetaJson(meta);
      if (thread == null) {
        _state.dirtyChats.remove(id);
        continue;
      }
      final messages = chats._cachedMessages(id) ?? <ChatMessage>[];
      final created = await _ensureChat(thread);
      if (stop(created)) return _done(pushed);
      if (created.code == 'gone') {
        // Разговор удалили на складе: здесь его тоже нет.
        _state.dirtyChats.remove(id);
        chats._forget(id);
        continue;
      }
      final hash = _metaHash(thread);
      if (_state.pushedMeta[id] != hash) {
        final reply = await _send('my_patch', <String, Object?>{
          'type': 'chat',
          'id': id,
          'at': _iso(thread.lastActivityAt),
          'set': <String, Object?>{
            if (thread.title != null) 'title': thread.title,
            'custom_title': thread.customTitle,
            'pinned_at':
                thread.pinnedAt == null ? null : _iso(thread.pinnedAt!),
            'project_id': thread.projectId,
            'preview': thread.preview ?? '',
            'last_persona': thread.lastPersonaId,
            'own_talk': thread.ownTalk,
          },
          'op': _op(),
        });
        if (stop(reply)) return _done(pushed);
        if (reply.ok) {
          _state.pushedMeta[id] = hash;
          pushed = true;
        } else {
          settled('chat $id', reply);
        }
      }
      final last = _state.pushedMessage[id];
      // Последнее отправленное ушло из кэша — шлём всё: повтор по id
      // безвреден, а старые неотправленные не теряются.
      var from = last == null
          ? 0
          : messages.indexWhere((ChatMessage m) => m.id == last) + 1;
      while (from < messages.length) {
        final chunk = messages.sublist(from, min(from + 50, messages.length));
        final reply = await _send('my_chat_append', <String, Object?>{
          'chat': id,
          'messages': <Object?>[for (final m in chunk) _wire(m)],
          'create': <String, Object?>{
            'kind': thread.kind == ChatKind.task ? 'task' : 'session',
            if (thread.taskId != null) 'task_id': thread.taskId,
          },
          'op': _op(),
        });
        if (stop(reply)) return _done(pushed);
        if (!reply.ok) {
          settled('chat $id', reply);
          break;
        }
        if (reply.json?['u'] case final int u) _state.chatU[id] = u;
        from += chunk.length;
        _state.pushedMessage[id] = chunk.last.id;
        pushed = true;
      }
      if (from >= messages.length && _state.pushedMeta[id] == hash) {
        _state.dirtyChats.remove(id);
      }
      _saveState();
    }
    _done(pushed);
  }

  void _done(bool pushed) {
    _saveState();
    if (pushed) onPushed?.call();
  }

  /// Сообщение для склада: без вложений-файлов (только имя), без
  /// подписей карточек (склад вычищает их и сам).
  static Map<String, Object?> _wire(ChatMessage m) => m.toJson();

  Future<MyReply> _ensureChat(ChatThread thread) async {
    if (_state.known.containsKey(thread.id)) return const MyReply(200);
    final reply = await _send('my_chat_new', <String, Object?>{
      'id': thread.id,
      'kind': thread.kind == ChatKind.task ? 'task' : 'session',
      if (thread.title != null) 'title': thread.title,
      if (thread.projectId != null) 'project': thread.projectId,
      if (thread.taskId != null) 'task_id': thread.taskId,
      'op': _op(),
    });
    if (reply.ok) {
      final obj = reply.json?['obj'];
      _state.known[thread.id] =
          obj is Map && obj['rev'] is int ? obj['rev']! as int : 0;
    }
    return reply;
  }

  /// Новая запись — `my_put`; известная — `my_patch` по полям со временем
  /// правки (у каждого поля побеждает последняя правка).
  Future<MyReply> _putOrPatch(
    String type,
    String id,
    Map<String, Object?> obj,
    Map<String, Object?> fields,
    DateTime at,
  ) async {
    Future<MyReply> patch() => _send('my_patch', <String, Object?>{
          'type': type,
          'id': id,
          'at': _iso(at),
          'set': fields,
          'op': _op(),
        });
    MyReply reply;
    if (_state.known.containsKey(id)) {
      reply = await patch();
      if (reply.status == 404) {
        _state.known.remove(id);
        reply = await _send('my_put', <String, Object?>{
          'type': type,
          'obj': obj,
          'op': _op(),
        });
      }
    } else {
      reply = await _send('my_put', <String, Object?>{
        'type': type,
        'obj': obj,
        'op': _op(),
      });
      // Уже есть на складе (другое устройство, повтор) — правка по полям.
      if (reply.code == 'stale') reply = await patch();
    }
    final out = reply.json?['obj'];
    if (out is Map && out['rev'] is int) _state.known[id] = out['rev']! as int;
    return reply;
  }

  String? _projectIdFor(Task task, Iterable<ChatProject> projects) {
    final tag = task.tags.firstOrNull;
    if (tag != null) {
      for (final p in projects) {
        if (p.taskTag == tag) return p.id;
      }
    }
    final kept = _state.taskProject[task.id];
    return projects.any((ChatProject p) => p.id == kept) ? kept : null;
  }

  // ------------------------------------------------------ напоминания

  /// `my_signals` для разговора; `null` — нет хранилища или ошибка.
  Future<List<Map<String, Object?>>?> fetchSignals() async {
    if (!remote || !signals) return null;
    final reply = await _send('my_signals', <String, Object?>{
      'v': 1,
      'channel': 'chat',
      'limit': 20,
      'tz': -_clock.now().timeZoneOffset.inMinutes,
    });
    final items = reply.json?['items'];
    if (!reply.ok || items is! List) return null;
    return <Map<String, Object?>>[
      for (final item in items)
        if (item is Map) Map<String, Object?>.from(item),
    ];
  }

  /// `my_signal_ack`: `seen`, `snooze`, `dismiss`.
  Future<bool> ackSignals(String op, List<String> ids) async {
    if (!remote || ids.isEmpty) return false;
    final reply = await _send('my_signal_ack', <String, Object?>{
      'v': 1,
      'op': op,
      'ids': ids.take(50).toList(),
      'tz': -_clock.now().timeZoneOffset.inMinutes,
    });
    return reply.ok;
  }

  /// Действие напоминания `my`: только правка задачи и новая задача.
  Future<bool> runMy(String action, Map<String, Object?> body) async {
    if (!remote || (action != 'my_patch' && action != 'my_put')) return false;
    final reply = await _send(action, <String, Object?>{...body, 'op': _op()});
    if (reply.ok) {
      await pull();
      onPushed?.call();
    }
    return reply.ok;
  }
}

/// Что помощник помнит о складе для синхронизации (`svz:my:<логин>`).
final class _SyncState {
  _SyncState();

  factory _SyncState.fromJson(Map<Object?, Object?> json) {
    Set<String> set(Object? v) =>
        <String>{if (v is List) ...v.whereType<String>()};
    Map<String, T> map<T>(Object? v) => <String, T>{
          if (v is Map)
            for (final MapEntry(:key, :value) in v.entries)
              if (key is String && value is T) key: value,
        };
    return _SyncState()
      ..epoch = json['epoch'] is String ? json['epoch']! as String : ''
      ..since = json['since'] is int ? json['since']! as int : 0
      ..mark = json['mark'] is String ? json['mark']! as String : ''
      ..known.addAll(map<int>(json['known']))
      ..chatU.addAll(map<int>(json['u']))
      ..pushedMessage.addAll(map<String>(json['last']))
      ..pushedMeta.addAll(map<String>(json['meta']))
      ..pushedProjects.addAll(map<String>(json['proj']))
      ..taskProject.addAll(map<String>(json['tp']))
      ..dirtyChats.addAll(set(json['dc']))
      ..dirtyTasks.addAll(set(json['dt']))
      ..dirtyProjects.addAll(set(json['dp']))
      ..deletes.addAll(set(json['del']));
  }

  String epoch = '';
  int since = 0;
  String mark = '';

  /// Записи, которые есть на складе: id → rev.
  final Map<String, int> known = <String, int>{};
  final Map<String, int> chatU = <String, int>{};
  final Map<String, String> pushedMessage = <String, String>{};
  final Map<String, String> pushedMeta = <String, String>{};
  final Map<String, String> pushedProjects = <String, String>{};

  /// Проект задачи на складе, когда метки нет.
  final Map<String, String> taskProject = <String, String>{};
  final Set<String> dirtyChats = <String>{};
  final Set<String> dirtyTasks = <String>{};
  final Set<String> dirtyProjects = <String>{};

  /// `тип|id` к удалению.
  final Set<String> deletes = <String>{};

  Map<String, Object?> toJson() => <String, Object?>{
        'epoch': epoch,
        'since': since,
        'mark': mark,
        'known': known,
        'u': chatU,
        'last': pushedMessage,
        'meta': pushedMeta,
        'proj': pushedProjects,
        'tp': taskProject,
        'dc': dirtyChats.toList(),
        'dt': dirtyTasks.toList(),
        'dp': dirtyProjects.toList(),
        'del': deletes.toList(),
      };
}

/// Разговоры и проекты для `ChatBook` — кэш в `localStorage`, правки — на
/// склад ([WidgetStore.flush]). Сообщения в кэше — последние
/// [cacheMessages] каждого разговора; на складе — до 1000.
final class WidgetChatStore implements ChatStore {
  WidgetChatStore._(this._owner);

  final WidgetStore _owner;

  static const int cacheMessages = 200;

  @override
  final AttachmentStore attachments = InMemoryAttachmentStore();

  KeyValueStorage get _storage => _owner.storage;

  @override
  Future<List<ChatThread>> loadIndex() async => <ChatThread>[
        for (final meta in _owner._readIndex().values)
          if (ChatThread.fromMetaJson(meta) case final ChatThread t) t,
      ];

  List<ChatMessage>? _cachedMessages(String chatId) {
    final text = _storage.read(_owner.chatKey(chatId));
    if (text == null) return null;
    return ChatCodec.decodeThread(text)?.$2;
  }

  @override
  Future<List<ChatMessage>> loadMessages(String chatId) async {
    final cached = _cachedMessages(chatId);
    if (cached != null) return cached;
    final fetched = await _owner.fetchMessages(chatId);
    if (fetched.isNotEmpty) {
      final meta = _owner._readIndex()[chatId];
      final thread = meta == null ? null : ChatThread.fromMetaJson(meta);
      if (thread != null) {
        thread
          ..messages.addAll(fetched)
          ..loaded = true;
        _cache(thread);
      }
    }
    return fetched;
  }

  void _cache(ChatThread thread) {
    final all = thread.messages;
    final ChatThread copy;
    if (all.length > cacheMessages) {
      copy = ChatThread.fromMetaJson(thread.metaJson())!
        ..messages.addAll(all.sublist(all.length - cacheMessages))
        ..loaded = true;
    } else {
      copy = thread;
    }
    _owner._write(_owner.chatKey(thread.id), ChatCodec.encodeThread(copy));
  }

  @override
  Future<void> save(ChatThread thread) async {
    _cache(thread);
    final index = _owner._readIndex();
    index[thread.id] = thread.metaJson()..['count'] = thread.messages.length;
    _owner
      .._writeIndex(index)
      .._dirty(_owner._state.dirtyChats, thread.id);
  }

  /// Чат задачи, которой больше нет: только кэш, на складе его убирает
  /// сама задача.
  @override
  Future<void> delete(String chatId) async => _forget(chatId);

  void _forget(String chatId) {
    final index = _owner._readIndex()..remove(chatId);
    _owner._writeIndex(index);
    _storage.remove(_owner.chatKey(chatId));
  }

  /// «Удалить» в меню: и на складе (корзина склада — 30 дней).
  @override
  Future<void> erase(String chatId) async {
    _forget(chatId);
    _owner._deleted('chat', chatId);
  }

  @override
  Future<void> clearAll() async {
    for (final id in _owner._readIndex().keys) {
      await erase(id);
    }
  }

  List<ChatProject> _projects() {
    final text = _storage.read(_owner.projectsKey);
    if (text == null) return <ChatProject>[];
    return ChatProjectCodec.decode(text) ?? <ChatProject>[];
  }

  void _writeProjects(List<ChatProject> projects) =>
      _owner._write(_owner.projectsKey, ChatProjectCodec.encode(projects));

  @override
  Future<List<ChatProject>> loadProjects() async => _projects();

  @override
  Future<void> saveProjects(List<ChatProject> projects) async {
    final before = {for (final p in _projects()) p.id: p};
    _writeProjects(projects);
    final state = _owner._state;
    for (final p in projects) {
      if (state.pushedProjects[p.id] != WidgetStore._projectHash(p)) {
        state.dirtyProjects.add(p.id);
      }
    }
    for (final id in before.keys) {
      if (!projects.any((ChatProject p) => p.id == id)) {
        _owner._deleted('project', id);
      }
    }
    _owner
      .._saveState()
      .._schedule();
  }

  @override
  Future<void> flush() => _owner.flush();
}

/// Задачи помощника: кэш `svz:tasks:<логин>`, правки — на склад.
final class WidgetTaskRepository implements TaskRepository {
  WidgetTaskRepository._(this._owner);

  final WidgetStore _owner;

  List<Task> _all() {
    final text = _owner.storage.read(_owner.tasksKey);
    if (text == null) return <Task>[];
    try {
      final json = jsonDecode(text);
      if (json is! Map || json['tasks'] is! List) return <Task>[];
      return <Task>[
        for (final row in json['tasks'] as List)
          if (row is Map)
            if (_parse(row) case final Task t) t,
      ];
    } on Object {
      return <Task>[];
    }
  }

  static Task? _parse(Map<Object?, Object?> row) {
    try {
      return Task.fromJson(Map<String, dynamic>.from(row));
    } on Object {
      return null;
    }
  }

  void _writeAll(List<Task> tasks) => _owner._write(
        _owner.tasksKey,
        jsonEncode(<String, Object?>{
          'v': 1,
          'tasks': <Object?>[for (final t in tasks) t.toJson()],
        }),
      );

  void _drop(String id) =>
      _writeAll(_all()..removeWhere((Task t) => t.id == id));

  @override
  Future<List<Task>> list() async => _all();

  @override
  Future<Task?> get(String id) async =>
      _all().where((Task t) => t.id == id).firstOrNull;

  @override
  Future<void> save(Task task) async {
    final all = _all();
    final i = all.indexWhere((Task t) => t.id == task.id);
    if (i < 0) {
      all.add(task);
    } else {
      all[i] = task;
    }
    _writeAll(all);
    _owner._dirty(_owner._state.dirtyTasks, task.id);
  }
}
