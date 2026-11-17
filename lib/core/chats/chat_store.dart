import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:path/path.dart' as p;

import '../services/clock.dart';
import 'attachments.dart';
import 'chat_models.dart';
import 'chat_projects.dart';

/// Где живут чаты и их сообщения (ADR-010, docs/ARCHITECTURE.md, «История
/// чатов»).
///
/// Метаданные всех чатов читаются сразу ([loadIndex]), сообщения — по
/// одному чату, когда его открывают ([loadMessages]). Запись может быть
/// отложенной: [flush] дописывает всё, что ещё не записано.
abstract interface class ChatStore {
  /// Сколько последних сообщений хранится в одном чате. Более старые
  /// молча отбрасываются при записи и при чтении.
  static const int maxMessages = 1000;

  /// Метаданные всех сохранённых чатов, без сообщений
  /// ([ChatThread.loaded] = false). Нет данных — пустой список.
  Future<List<ChatThread>> loadIndex();

  /// Сообщения чата [chatId] (не больше [maxMessages], последние).
  /// Нет файла или он повреждён — пустой список. Чат, ушедший в архив
  /// ([delete]), возвращается из архива.
  Future<List<ChatMessage>> loadMessages(String chatId);

  /// Записать чат [thread] (сообщения и метаданные). Реализация может
  /// отложить запись; содержимое берётся в момент записи.
  Future<void> save(ChatThread thread);

  /// Убрать чат задачи, которой больше нет (или прежний «Главный» после
  /// переноса в сессию). Сообщения не стираются, а уходят в архив: если
  /// задача вернётся (tasks.json восстановили из копии), [loadMessages]
  /// снова найдёт её историю.
  Future<void> delete(String chatId);

  /// Стереть чат [chatId] насовсем: файл, архив и запись в index.json
  /// («Удалить» в меню сессии). В отличие от [delete], вернуть его нельзя:
  /// пользователь сам попросил удалить. Отложенная запись этого чата
  /// отменяется.
  Future<void> erase(String chatId);

  /// Удалить все чаты вместе с архивом. Проекты-папки ([loadProjects])
  /// остаются: очищается история, а не их список (ADR-018).
  Future<void> clearAll();

  /// Проекты-папки из `projects/projects.json` (ADR-018). Нет файла —
  /// пустой список; повреждённый файл (не UTF-8, не JSON, не та
  /// структура) откладывается в сторону, и список тоже пуст. Файл есть,
  /// но не прочитался (ошибка файловой системы: файл заблокирован, нет
  /// доступа) — исключение: «папок нет» тогда сказать нельзя, иначе
  /// следующая запись затёрла бы их.
  Future<List<ChatProject>> loadProjects();

  /// Записать все проекты-папки [projects] (целиком, атомарно).
  Future<void> saveProjects(List<ChatProject> projects);

  /// Копии прикреплённых файлов (ADR-019): [erase] стирает и их,
  /// [clearAll] — все, [delete] (архив чата задачи) — не трогает.
  AttachmentStore get attachments;

  /// Дописать отложенные записи и дождаться их.
  Future<void> flush();
}

/// Формат файлов чатов, общий для [JsonChatStore] и [InMemoryChatStore].
abstract final class ChatCodec {
  static const int schemaVersion = 1;

  /// Файл чата: шапка с метаданными и последние [ChatStore.maxMessages]
  /// сообщений.
  static String encodeThread(ChatThread thread) {
    final messages = thread.messages;
    final from = messages.length > ChatStore.maxMessages
        ? messages.length - ChatStore.maxMessages
        : 0;
    final kept = messages.sublist(from);
    final meta = thread.metaJson()..['count'] = kept.length;
    return jsonEncode(<String, Object?>{
      'schema_version': schemaVersion,
      'chat': meta,
      'messages': <Map<String, Object?>>[
        for (final message in kept) message.toJson(),
      ],
    });
  }

  /// Шапка и сообщения файла чата или `null`, если файл не читается
  /// (не JSON, новая версия формата, не та структура).
  static (ChatThread, List<ChatMessage>)? decodeThread(String content) {
    final Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      return null;
    }
    if (decoded is! Map || !_knownVersion(decoded['schema_version'])) {
      return null;
    }
    final thread = ChatThread.fromMetaJson(decoded['chat']);
    final rows = decoded['messages'];
    if (thread == null || rows is! List) return null;
    final messages = <ChatMessage>[
      for (final row in rows)
        if (ChatMessage.fromJson(row) case final ChatMessage message) message,
    ];
    final from = messages.length > ChatStore.maxMessages
        ? messages.length - ChatStore.maxMessages
        : 0;
    return (thread, messages.sublist(from));
  }

  static String encodeIndex(Iterable<Map<String, Object?>> chats) =>
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'schema_version': schemaVersion,
        'chats': chats.toList(),
      });

  /// Метаданные чатов из index.json или `null`, если файл повреждён.
  /// Отдельные битые записи пропускаются.
  static List<ChatThread>? decodeIndex(String content) {
    final Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      return null;
    }
    if (decoded is! Map || !_knownVersion(decoded['schema_version'])) {
      return null;
    }
    final rows = decoded['chats'];
    if (rows is! List) return null;
    final seen = <String>{};
    return <ChatThread>[
      for (final row in rows)
        if (ChatThread.fromMetaJson(row) case final ChatThread thread
            when seen.add(thread.id))
          thread,
    ];
  }

  static bool _knownVersion(Object? version) =>
      version is int && version >= 1 && version <= schemaVersion;

  /// Имя файла чата: `task-<id задачи>.json`, `session-<x>.json` (прежний
  /// «Главный» — `main.json`). Символы кроме латиницы, цифр, «_» и «-»
  /// заменяются на «_».
  static String fileName(String chatId) {
    final base = chatId.startsWith('task:')
        ? 'task-${chatId.substring('task:'.length)}'
        : chatId.startsWith(ChatThread.sessionPrefix)
            ? 'session-${chatId.substring(ChatThread.sessionPrefix.length)}'
            : chatId;
    return '${base.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_')}.json';
  }
}

/// Чаты только в памяти: тесты и режим «Только в памяти». Хранит те же
/// тексты файлов, что [JsonChatStore], поэтому «перезапуск» (новый экран
/// над тем же хранилищем) восстанавливает чаты так же, как с диска:
/// карточки, ждавшие ответа, становятся устаревшими.
final class InMemoryChatStore implements ChatStore {
  InMemoryChatStore({AttachmentStore? attachments})
      : attachments = attachments ?? InMemoryAttachmentStore();

  @override
  final AttachmentStore attachments;

  final Map<String, String> _files = <String, String>{};
  final Map<String, String> _archive = <String, String>{};
  final Map<String, Map<String, Object?>> _index =
      <String, Map<String, Object?>>{};

  /// Текст projects.json; `null` — файла нет.
  String? projectsFile;

  /// Сколько раз чат записывался (для тестов).
  int saves = 0;

  /// Сохранённые id чатов.
  Iterable<String> get chatIds => _files.keys;

  @override
  Future<List<ChatThread>> loadIndex() async =>
      ChatCodec.decodeIndex(ChatCodec.encodeIndex(_index.values)) ??
      <ChatThread>[];

  /// Id чатов в архиве.
  Iterable<String> get archivedIds => _archive.keys;

  @override
  Future<List<ChatMessage>> loadMessages(String chatId) async {
    var content = _files[chatId];
    if (content == null) {
      content = _archive.remove(chatId);
      if (content == null) return <ChatMessage>[];
      _files[chatId] = content;
    }
    return ChatCodec.decodeThread(content)?.$2 ?? <ChatMessage>[];
  }

  @override
  Future<void> save(ChatThread thread) async {
    saves++;
    _files[thread.id] = ChatCodec.encodeThread(thread);
    final count = thread.messages.length;
    _index[thread.id] = thread.metaJson()
      ..['count'] =
          count > ChatStore.maxMessages ? ChatStore.maxMessages : count;
  }

  @override
  Future<void> delete(String chatId) async {
    final content = _files.remove(chatId);
    if (content != null) _archive[chatId] = content;
    _index.remove(chatId);
  }

  @override
  Future<void> erase(String chatId) async {
    _files.remove(chatId);
    _archive.remove(chatId);
    _index.remove(chatId);
    await attachments.eraseChat(chatId);
  }

  @override
  Future<void> clearAll() async {
    _files.clear();
    _archive.clear();
    _index.clear();
    await attachments.clearAll();
  }

  @override
  Future<List<ChatProject>> loadProjects() async {
    final content = projectsFile;
    if (content == null) return <ChatProject>[];
    return ChatProjectCodec.decode(content) ?? <ChatProject>[];
  }

  @override
  Future<void> saveProjects(List<ChatProject> projects) async {
    projectsFile = ChatProjectCodec.encode(projects);
  }

  @override
  Future<void> flush() async {}
}

/// Чаты в папке `<Документы>/assistant/chats/`: `index.json` и файл на
/// чат (`session-<id>.json`, `task-<id>.json`; `main.json` прежнего
/// «Главного» только читается при переносе и уходит в `archive/`,
/// ADR-010).
///
/// - Запись атомарная (`<файл>.tmp` → `rename`), по очереди; ошибка одной
///   записи не мешает следующим и не роняет приложение.
/// - [save] откладывает запись на [debounce]: несколько ответов подряд —
///   одна запись. Сначала файлы чатов, затем index.json.
/// - Повреждённый файл (не JSON, не UTF-8, не та структура)
///   переименовывается в `<файл>.broken` (если такой уже есть —
///   `<файл>.broken-<время>`), чат начинается пустым; повреждённый
///   index.json пересобирается по шапкам файлов чатов.
/// - Файл чата, которого нет в index.json (сбой между записью файла и
///   индекса), при чтении индекса добавляется в него по своей шапке.
/// - Чат удалённой задачи уходит в `archive/` ([delete]) и возвращается
///   оттуда, если задача снова появится.
/// - «Удалить» в меню сессии стирает файл и архив насовсем ([erase]).
/// - tasks.json и settings.json этот класс не трогает: у него своя папка.
final class JsonChatStore implements ChatStore {
  JsonChatStore(
    this.directory, {
    this.debounce = const Duration(milliseconds: 500),
    Clock clock = const SystemClock(),
  })  : _clock = clock,
        attachments = IoAttachmentStore(directory);

  /// Папка чатов.
  final String directory;

  /// Вложения — в `<папка чатов>/files/` (ADR-019).
  @override
  final IoAttachmentStore attachments;

  /// Задержка отложенной записи.
  final Duration debounce;

  final Clock _clock;

  /// Метаданные чатов для index.json.
  final Map<String, Map<String, Object?>> _index =
      <String, Map<String, Object?>>{};

  /// Чаты, которые ещё не записаны.
  final Map<String, ChatThread> _dirty = <String, ChatThread>{};

  Timer? _timer;

  /// Очередь записей.
  Future<void> _writes = Future<void>.value();

  String get indexPath => p.join(directory, 'index.json');

  /// Файл проектов-папок (ADR-018).
  String get projectsPath =>
      p.join(directory, ChatProjectCodec.folder, ChatProjectCodec.fileName);

  /// Где файл проектов лежал в сборках до переноса в подпапку: читается,
  /// только если нового файла ещё нет (и его копия `.broken`, которую
  /// оставила откаченная версия).
  String get legacyProjectsPath => p.join(directory, ChatProjectCodec.fileName);

  /// Папка архива: чаты задач, которых больше нет в tasks.json.
  String get archiveDirectory => p.join(directory, 'archive');

  String archivePathOf(String chatId) =>
      p.join(archiveDirectory, ChatCodec.fileName(chatId));

  String pathOf(String chatId) => p.join(directory, ChatCodec.fileName(chatId));

  @override
  Future<List<ChatThread>> loadIndex() async {
    List<ChatThread>? threads;
    try {
      final file = File(indexPath);
      if (await file.exists()) {
        final content = await _readText(file);
        threads = content == null ? null : ChatCodec.decodeIndex(content);
        if (threads == null) await _quarantine(file);
      }
      if (threads == null) {
        threads = await _rebuildIndex();
      } else {
        threads.addAll(await _rebuildIndex(skip: threads));
      }
    } on Object catch (error) {
      _log('не удалось прочитать чаты', error);
      threads = <ChatThread>[];
    }
    _index
      ..clear()
      ..addAll(<String, Map<String, Object?>>{
        for (final thread in threads) thread.id: thread.metaJson(),
      });
    return threads;
  }

  /// Метаданные по шапкам файлов чатов: все (index.json потерян или
  /// повреждён) или только файлов, которых нет в [skip] (файл записан, а
  /// index.json — нет).
  Future<List<ChatThread>> _rebuildIndex({
    List<ChatThread> skip = const <ChatThread>[],
  }) async {
    final folder = Directory(directory);
    if (!await folder.exists()) return <ChatThread>[];
    final known = <String>{
      for (final thread in skip) ChatCodec.fileName(thread.id),
    };
    final threads = <ChatThread>[];
    final files = await folder
        .list()
        .where(
          (FileSystemEntity e) =>
              e is File &&
              e.path.endsWith('.json') &&
              p.basename(e.path) != 'index.json' &&
              p.basename(e.path) != ChatProjectCodec.fileName &&
              !known.contains(p.basename(e.path)),
        )
        .cast<File>()
        .toList();
    files.sort((File a, File b) => a.path.compareTo(b.path));
    for (final file in files) {
      final content = await _readText(file);
      final decoded = content == null ? null : ChatCodec.decodeThread(content);
      if (decoded == null ||
          ChatCodec.fileName(decoded.$1.id) != p.basename(file.path)) {
        await _quarantine(file);
        continue;
      }
      final (meta, messages) = decoded;
      threads.add(
        ChatThread(
          id: meta.id,
          kind: meta.kind,
          taskId: meta.taskId,
          parentTaskId: meta.parentTaskId,
          createdAt: meta.createdAt,
          lastActivityAt: meta.lastActivityAt,
          addressee: meta.addressee,
          title: meta.title,
          customTitle: meta.customTitle,
          pinnedAt: meta.pinnedAt,
          preview: meta.preview,
          lastPersonaId: meta.lastPersonaId,
          unread: meta.unread,
          projectId: meta.projectId,
          ownTalk:
              meta.kind == ChatKind.task && ChatThread.hasOwnTalk(messages),
          loaded: false,
          storedCount: messages.length,
        ),
      );
    }
    return threads;
  }

  @override
  Future<List<ChatMessage>> loadMessages(String chatId) async {
    // Ещё не записанный чат читается из памяти: открыть его можно сразу
    // после ответа, не дожидаясь записи.
    final dirty = _dirty[chatId];
    if (dirty != null && dirty.loaded) {
      return List<ChatMessage>.of(dirty.messages);
    }
    try {
      await _writes;
      final file = File(pathOf(chatId));
      if (!await file.exists()) {
        // Задача вернулась (tasks.json восстановили): чат — из архива.
        final archived = File(archivePathOf(chatId));
        if (!await archived.exists()) return <ChatMessage>[];
        await archived.rename(file.path);
      }
      final content = await _readText(file);
      final decoded = content == null ? null : ChatCodec.decodeThread(content);
      if (decoded == null || decoded.$1.id != chatId) {
        await _quarantine(file);
        return <ChatMessage>[];
      }
      return decoded.$2;
    } on Object catch (error) {
      _log('не удалось прочитать чат $chatId', error);
      return <ChatMessage>[];
    }
  }

  @override
  Future<void> save(ChatThread thread) {
    _dirty[thread.id] = thread;
    final count = thread.messages.length;
    _index[thread.id] = thread.metaJson()
      ..['count'] =
          count > ChatStore.maxMessages ? ChatStore.maxMessages : count;
    _timer?.cancel();
    if (debounce == Duration.zero) return flush();
    _timer = Timer(debounce, () => unawaited(flush()));
    return Future<void>.value();
  }

  @override
  Future<void> delete(String chatId) {
    _dirty.remove(chatId);
    _index.remove(chatId);
    final index = ChatCodec.encodeIndex(_index.values);
    return _enqueue(() async {
      final file = File(pathOf(chatId));
      if (await file.exists()) {
        // Не стирать: задача могла пропасть из-за потерянного tasks.json.
        await Directory(archiveDirectory).create(recursive: true);
        await file.rename(archivePathOf(chatId));
      }
      await _writeAtomic(indexPath, index);
    });
  }

  @override
  Future<void> erase(String chatId) {
    // Сначала — из отложенных: иначе следующая запись вернула бы файл.
    _dirty.remove(chatId);
    _index.remove(chatId);
    final index = ChatCodec.encodeIndex(_index.values);
    return _enqueue(() async {
      for (final path in <String>[pathOf(chatId), archivePathOf(chatId)]) {
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
      await _writeAtomic(indexPath, index);
      await attachments.eraseChat(chatId);
    });
  }

  @override
  Future<void> clearAll() {
    _timer?.cancel();
    _dirty.clear();
    _index.clear();
    return _enqueue(() async {
      final folder = Directory(directory);
      if (!await folder.exists()) return;
      final archive = Directory(archiveDirectory);
      if (await archive.exists()) await archive.delete(recursive: true);
      await attachments.clearAll();
      await for (final entity in folder.list()) {
        // Проекты-папки остаются: очищается история сессий.
        if (p.basename(entity.path) == ChatProjectCodec.fileName) continue;
        if (entity is File &&
            (entity.path.endsWith('.json') ||
                entity.path.endsWith('.json.tmp'))) {
          await entity.delete();
        }
      }
    });
  }

  @override
  Future<List<ChatProject>> loadProjects() async {
    await _writes;
    final file = File(projectsPath);
    if (!await file.exists()) return _loadLegacyProjects();
    // Ошибка файловой системы — наружу (см. [ChatStore.loadProjects]).
    final content = await _readText(file);
    final projects = content == null ? null : ChatProjectCodec.decode(content);
    if (projects == null) {
      await _quarantine(file);
      return <ChatProject>[];
    }
    return projects;
  }

  /// Папки из прежнего места: `projects.json` в самой папке чатов или его
  /// копия `projects.json.broken`, если старая версия отложила его при
  /// пересборке index.json. Только чтение: следующая запись — уже в
  /// подпапку. Не разбирается — папок нет (старые файлы не трогаются).
  Future<List<ChatProject>> _loadLegacyProjects() async {
    for (final path in <String>[
      legacyProjectsPath,
      '$legacyProjectsPath.broken',
    ]) {
      final file = File(path);
      if (!await file.exists()) continue;
      final content = await _readText(file);
      final projects =
          content == null ? null : ChatProjectCodec.decode(content);
      if (projects != null) return projects;
    }
    return <ChatProject>[];
  }

  @override
  Future<void> saveProjects(List<ChatProject> projects) {
    final content = ChatProjectCodec.encode(projects);
    return _enqueue(() => _writeAtomic(projectsPath, content));
  }

  @override
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    if (_dirty.isEmpty) return _writes;
    // Содержимое — на момент записи: всё, что добавили до неё, попадёт.
    final files = <String, String>{
      for (final thread in _dirty.values)
        pathOf(thread.id): ChatCodec.encodeThread(thread),
    };
    _dirty.clear();
    final index = ChatCodec.encodeIndex(_index.values);
    return _enqueue(() async {
      for (final MapEntry(key: path, value: content) in files.entries) {
        await _writeAtomic(path, content);
      }
      await _writeAtomic(indexPath, index);
    });
  }

  Future<void> _enqueue(Future<void> Function() job) {
    final write = _writes.then((_) => job());
    _writes = write.catchError((Object error) {
      _log('не удалось записать чаты', error);
    });
    return _writes;
  }

  Future<void> _writeAtomic(String path, String content) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final temporary = File('$path.tmp');
    await temporary.writeAsString(content, flush: true);
    await temporary.rename(path);
  }

  /// Текст файла или `null`, если это не UTF-8 (файл повреждён: его
  /// откладывают в `.broken`, а не перезаписывают).
  Future<String?> _readText(File file) async {
    try {
      return utf8.decode(await file.readAsBytes());
    } on FormatException {
      return null;
    }
  }

  /// Повреждённый файл — в сторону, а не удалять: его можно разобрать
  /// вручную.
  Future<void> _quarantine(File file) async {
    try {
      var target = '${file.path}.broken';
      if (await File(target).exists()) {
        target = '$target-${_clock.now().microsecondsSinceEpoch}';
      }
      await file.rename(target);
    } on Object catch (error) {
      _log('не удалось отложить повреждённый файл ${file.path}', error);
    }
  }

  void _log(String what, Object error) =>
      developer.log('$what: $error', name: 'chats');
}
