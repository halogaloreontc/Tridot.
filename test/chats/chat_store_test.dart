// Хранилище чатов (ADR-010): формат, атомарная запись, терпимая загрузка,
// лимит сообщений. Общий набор проверок — для файлов и для памяти.
// Фикстура `_main` — прежний формат «Главного» (kind main): хранилище
// по-прежнему читает и пишет его как есть, перенос в сессию делает
// ChatBook (chat_book_test.dart, «перенос прежнего «Главного»»).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/chats/chat_book.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
import 'package:local_assistant/core/models/assistant_types.dart';
import 'package:local_assistant/core/models/bulk.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:path/path.dart' as p;

final _t0 = DateTime(2026, 11, 4, 12);

ChatMessage _message(int i, {ChatAuthor author = ChatAuthor.user}) =>
    ChatMessage(
      id: 'm_$i',
      author: author,
      personaId: author == ChatAuthor.persona ? 'noda' : null,
      text: 'Сообщение $i',
      timestamp: _t0.add(Duration(minutes: i)),
    );

BulkChecklist _checklist() => BulkChecklist(
      id: 'bulk_1',
      action: BulkAction.reschedule,
      selection: const BulkSelection(),
      items: <BulkItem>[
        BulkItem(taskId: 't1', title: 'Хлеб'),
        BulkItem(taskId: 't2', title: 'Отчёт', dueLabel: 'завтра'),
      ],
      targetDue: DateTime(2026, 11, 7),
      targetLabel: 'сб, 7 ноября',
    );

ChatThread _main(List<ChatMessage> messages) => ChatThread(
      id: ChatThread.mainId,
      kind: ChatKind.main,
      createdAt: _t0,
      lastActivityAt: messages.isEmpty ? _t0 : messages.last.timestamp,
      messages: messages,
    );

ChatThread _task(String taskId, List<ChatMessage> messages, {String? parent}) =>
    ChatThread(
      id: ChatThread.taskChatId(taskId),
      kind: ChatKind.task,
      taskId: taskId,
      parentTaskId: parent,
      createdAt: _t0,
      lastActivityAt: messages.isEmpty ? _t0 : messages.last.timestamp,
      addressee: 'noda',
      unread: true,
      messages: messages,
    );

/// Проверки, одинаковые для [JsonChatStore] и [InMemoryChatStore].
void runChatStoreContract(
  String name,
  Future<ChatStore> Function() create,
  Future<ChatStore> Function(ChatStore) reopen,
) {
  group('контракт ChatStore: $name', () {
    test('erase: ни файла, ни архива, ни записи в индексе', () async {
      final store = await create();
      await store.save(_task('t1', <ChatMessage>[_message(1)]));
      await store.save(_task('t2', <ChatMessage>[_message(2)]));
      await store.flush();
      // Один — в архив (как prune), оба — стереть.
      await store.delete('task:t2');
      await store.erase('task:t1');
      await store.erase('task:t2');
      await store.flush();
      final again = await reopen(store);
      expect(await again.loadIndex(), isEmpty);
      expect(await again.loadMessages('task:t1'), isEmpty);
      expect(
        await again.loadMessages('task:t2'),
        isEmpty,
        reason: 'и из архива не возвращается',
      );
    });

    test('erase отменяет отложенную запись того же чата', () async {
      final store = await create();
      await store.save(_task('t1', <ChatMessage>[_message(1)]));
      await store.erase('task:t1');
      await store.flush();
      final again = await reopen(store);
      expect(await again.loadIndex(), isEmpty);
      expect(await again.loadMessages('task:t1'), isEmpty);
    });

    test('новые поля шапки: своё название, закрепление, превью', () async {
      final store = await create();
      final pinnedAt = _t0.add(const Duration(hours: 1));
      await store.save(
        ChatThread(
          id: '${ChatThread.sessionPrefix}x',
          kind: ChatKind.session,
          createdAt: _t0,
          title: 'добавь задачу',
          customTitle: 'Отчёт за неделю',
          pinnedAt: pinnedAt,
          preview: 'Сводка готова',
          lastPersonaId: 'noda',
          messages: <ChatMessage>[_message(1)],
        ),
      );
      await store.flush();
      final meta = (await (await reopen(store)).loadIndex()).single;
      expect(meta.customTitle, 'Отчёт за неделю');
      expect(meta.pinnedAt, pinnedAt);
      expect(meta.pinned, isTrue);
      expect(meta.preview, 'Сводка готова');
      expect(meta.lastPersonaId, 'noda');
    });
    test('пусто при первом запуске', () async {
      final store = await create();
      expect(await store.loadIndex(), isEmpty);
      expect(await store.loadMessages(ChatThread.mainId), isEmpty);
    });

    test('все поля переживают перезапуск; карточка — устаревшая', () async {
      final store = await create();
      final checklist = _checklist();
      final reply = ChatMessage(
        id: 'm_2',
        author: ChatAuthor.persona,
        personaId: 'rio',
        text: 'Перенести эти 2 задачи?',
        timestamp: _t0.add(const Duration(minutes: 1)),
        status: AssistantStatus.needsClarification,
        taskId: 't1',
        checklist: checklist,
        link: const ChatLink(chatId: 'task:t1', messageId: 'm_1', taskId: 't1'),
      );
      await store.save(_main(<ChatMessage>[_message(1), reply]));
      await store.save(
        _task('t1', <ChatMessage>[_message(3)], parent: 'p1'),
      );
      await store.flush();

      final again = await reopen(store);
      final index = {
        for (final thread in await again.loadIndex()) thread.id: thread,
      };
      expect(index.keys, unorderedEquals(<String>['main', 'task:t1']));
      final task = index['task:t1']!;
      expect(task.kind, ChatKind.task);
      expect(task.taskId, 't1');
      expect(task.parentTaskId, 'p1');
      expect(task.addressee, 'noda');
      expect(task.unread, isTrue);
      expect(task.messageCount, 1);
      expect(task.loaded, isFalse);
      expect(index['main']!.messageCount, 2);

      final messages = await again.loadMessages(ChatThread.mainId);
      expect(messages.length, 2);
      final restored = messages.last;
      expect(restored.id, 'm_2');
      expect(restored.author, ChatAuthor.persona);
      expect(restored.personaId, 'rio');
      expect(restored.text, 'Перенести эти 2 задачи?');
      expect(restored.timestamp, reply.timestamp);
      expect(restored.status, AssistantStatus.needsClarification);
      expect(restored.taskId, 't1');
      expect(restored.link, reply.link);
      expect(
        restored.checklist!.items.map((BulkItem i) => i.title),
        <String>['Хлеб', 'Отчёт'],
      );
      expect(restored.checklist!.state, BulkChecklistState.expired);
      expect(messages.first.fromUser, isTrue);
    });

    test('лимит: из 1005 сообщений остаются последние 1000', () async {
      final store = await create();
      await store.save(
        _main(<ChatMessage>[for (var i = 0; i < 1005; i++) _message(i)]),
      );
      await store.flush();
      final again = await reopen(store);
      final messages = await again.loadMessages(ChatThread.mainId);
      expect(messages.length, ChatStore.maxMessages);
      expect(messages.first.id, 'm_5');
      expect(messages.last.id, 'm_1004');
      expect((await again.loadIndex()).single.messageCount, 1000);
    });

    test('удаление чата и очистка', () async {
      final store = await create();
      await store.save(_main(<ChatMessage>[_message(1)]));
      await store.save(_task('t1', <ChatMessage>[_message(2)]));
      await store.save(_task('t2', <ChatMessage>[_message(3)]));
      await store.flush();
      await store.delete('task:t1');
      await store.flush();
      var again = await reopen(store);
      expect(
        (await again.loadIndex()).map((ChatThread t) => t.id),
        unorderedEquals(<String>['main', 'task:t2']),
      );
      // Чат удалённой задачи — в архиве: задача вернулась (tasks.json
      // восстановили) — история тоже.
      expect(
        (await again.loadMessages('task:t1')).map((ChatMessage m) => m.id),
        <String>['m_2'],
      );

      await again.clearAll();
      await again.flush();
      again = await reopen(again);
      expect(await again.loadIndex(), isEmpty);
      expect(await again.loadMessages(ChatThread.mainId), isEmpty);
      expect(await again.loadMessages('task:t1'), isEmpty);
      expect(await again.loadMessages('task:t2'), isEmpty);
    });
  });
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('chats_test_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  String chats() => p.join(root.path, 'assistant', 'chats');

  runChatStoreContract(
    'JsonChatStore',
    () async => JsonChatStore(chats()),
    (ChatStore _) async => JsonChatStore(chats()),
  );
  runChatStoreContract(
    'InMemoryChatStore',
    () async => InMemoryChatStore(),
    (ChatStore store) async => store,
  );

  group('JsonChatStore на диске', () {
    test('старый index.json без новых полей и битые новые поля читаются',
        () async {
      Directory(chats()).createSync(recursive: true);
      File(p.join(chats(), 'index.json')).writeAsStringSync(
        jsonEncode(<String, Object?>{
          'schema_version': 1,
          'chats': <Object?>[
            <String, Object?>{
              'id': 'session:old',
              'kind': 'session',
              'created_at': _t0.toIso8601String(),
              'last_activity_at': _t0.toIso8601String(),
              'title': 'старая сессия',
              'count': 2,
            },
            <String, Object?>{
              'id': 'session:bad',
              'kind': 'session',
              'created_at': _t0.toIso8601String(),
              'title': 'битые поля',
              'custom_title': 42,
              'pinned_at': 'не дата',
              'preview': <String>['x'],
              'last_persona': false,
              'count': 1,
            },
            <String, Object?>{
              'id': 'session:blank',
              'kind': 'session',
              'created_at': _t0.toIso8601String(),
              'custom_title': '   ',
              'preview': '  первая\n строка  ',
              'count': 1,
            },
          ],
        }),
      );
      final index = {
        for (final t in await JsonChatStore(chats()).loadIndex()) t.id: t,
      };
      expect(index.length, 3);
      for (final id in <String>['session:old', 'session:bad']) {
        final t = index[id]!;
        expect(t.customTitle, isNull, reason: id);
        expect(t.pinnedAt, isNull, reason: id);
        expect(t.preview, isNull, reason: id);
        expect(t.lastPersonaId, isNull, reason: id);
      }
      expect(index['session:old']!.title, 'старая сессия');
      expect(index['session:blank']!.customTitle, isNull);
      expect(index['session:blank']!.preview, 'первая строка');
    });

    test('у чата задачи своё название не читается', () {
      final thread = ChatThread.fromMetaJson(<String, Object?>{
        'id': 'task:t1',
        'kind': 'task',
        'task_id': 't1',
        'created_at': _t0.toIso8601String(),
        'custom_title': 'чужое',
        'pinned_at': _t0.toIso8601String(),
      })!;
      expect(thread.customTitle, isNull);
      expect(thread.pinned, isTrue, reason: 'закреплять чат задачи можно');
    });

    test('index.json потерян: шапки файлов сохраняют новые поля', () async {
      final store = JsonChatStore(chats(), debounce: Duration.zero);
      await store.save(
        ChatThread(
          id: '${ChatThread.sessionPrefix}y',
          kind: ChatKind.session,
          createdAt: _t0,
          customTitle: 'Склад',
          pinnedAt: _t0,
          preview: 'Принято',
          lastPersonaId: 'rio',
          messages: <ChatMessage>[_message(1)],
        ),
      );
      await store.flush();
      File(p.join(chats(), 'index.json')).deleteSync();
      final meta = (await JsonChatStore(chats()).loadIndex()).single;
      expect(meta.customTitle, 'Склад');
      expect(meta.pinnedAt, _t0);
      expect(meta.preview, 'Принято');
      expect(meta.lastPersonaId, 'rio');
    });

    test('erase стирает файл и архив с диска', () async {
      final store = JsonChatStore(chats(), debounce: Duration.zero);
      await store.save(_task('t1', <ChatMessage>[_message(1)]));
      await store.save(_task('t2', <ChatMessage>[_message(2)]));
      await store.flush();
      await store.delete('task:t2');
      await store.flush();
      expect(File(store.archivePathOf('task:t2')).existsSync(), isTrue);
      await store.erase('task:t1');
      await store.erase('task:t2');
      await store.flush();
      expect(File(store.pathOf('task:t1')).existsSync(), isFalse);
      expect(File(store.archivePathOf('task:t2')).existsSync(), isFalse);
      final index = jsonDecode(
        File(p.join(chats(), 'index.json')).readAsStringSync(),
      ) as Map<String, Object?>;
      expect(index['chats'], isEmpty);
    });

    test('формат: index.json и файл на чат, без .tmp', () async {
      final store = JsonChatStore(chats());
      await store.save(_main(<ChatMessage>[_message(1)]));
      await store.save(_task('task_1_0', <ChatMessage>[_message(2)]));
      await store.flush();
      final names = Directory(chats())
          .listSync()
          .map((FileSystemEntity e) => p.basename(e.path))
          .toList()
        ..sort();
      expect(names, <String>['index.json', 'main.json', 'task-task_1_0.json']);
      final index = jsonDecode(
        File(p.join(chats(), 'index.json')).readAsStringSync(),
      ) as Map<String, Object?>;
      expect(index['schema_version'], 1);
      expect((index['chats']! as List<Object?>).length, 2);
      final main = jsonDecode(
        File(p.join(chats(), 'main.json')).readAsStringSync(),
      ) as Map<String, Object?>;
      expect(main['schema_version'], 1);
      expect((main['chat']! as Map<String, Object?>)['id'], 'main');
      final message =
          (main['messages']! as List<Object?>).single! as Map<String, Object?>;
      expect(message.keys, <String>['id', 'author', 'text', 'ts']);
    });

    test('опасные символы в id задачи не выходят из папки', () {
      expect(ChatCodec.fileName('task:../x/y'), 'task-___x_y.json');
      expect(ChatCodec.fileName('main'), 'main.json');
    });

    test('отложенная запись: несколько сохранений — одна запись', () async {
      final store = JsonChatStore(
        chats(),
        debounce: const Duration(milliseconds: 50),
      );
      final thread = _main(<ChatMessage>[_message(1)]);
      await store.save(thread);
      thread.messages.add(_message(2));
      await store.save(thread);
      expect(File(p.join(chats(), 'main.json')).existsSync(), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await store.flush();
      final again = JsonChatStore(chats());
      await again.loadIndex();
      expect((await again.loadMessages('main')).length, 2);
    });

    test('обрыв записи: подложенный .tmp не портит старый файл', () async {
      final store = JsonChatStore(chats());
      await store.save(_main(<ChatMessage>[_message(1)]));
      await store.flush();
      File(p.join(chats(), 'main.json.tmp')).writeAsStringSync('{"обрыв');
      final again = JsonChatStore(chats());
      await again.loadIndex();
      expect((await again.loadMessages('main')).single.id, 'm_1');
      // Следующая запись перезаписывает .tmp и не оставляет его.
      await again.save(_main(<ChatMessage>[_message(1), _message(2)]));
      await again.flush();
      expect(File(p.join(chats(), 'main.json.tmp')).existsSync(), isFalse);
    });

    test('битый index.json → .broken и пересборка по файлам чатов', () async {
      final store = JsonChatStore(chats());
      await store.save(_main(<ChatMessage>[_message(1)]));
      await store.save(_task('t1', <ChatMessage>[_message(2), _message(3)]));
      await store.flush();
      File(p.join(chats(), 'index.json')).writeAsStringSync('не json');

      final again = JsonChatStore(chats());
      final index = {
        for (final thread in await again.loadIndex()) thread.id: thread,
      };
      expect(index.keys, unorderedEquals(<String>['main', 'task:t1']));
      expect(index['task:t1']!.messageCount, 2);
      expect(index['task:t1']!.addressee, 'noda');
      expect(File(p.join(chats(), 'index.json.broken')).existsSync(), isTrue);

      // Второй раз .broken уже есть — новый с отметкой времени.
      File(p.join(chats(), 'index.json')).writeAsStringSync('[]');
      await JsonChatStore(chats()).loadIndex();
      final broken = Directory(chats())
          .listSync()
          .map((FileSystemEntity e) => p.basename(e.path))
          .where((String n) => n.startsWith('index.json.broken'))
          .toList();
      expect(broken.length, 2);
    });

    test('index.json новой версии формата не читается как свой', () async {
      final store = JsonChatStore(chats());
      await store.save(_main(<ChatMessage>[_message(1)]));
      await store.flush();
      File(p.join(chats(), 'index.json'))
          .writeAsStringSync('{"schema_version": 2, "chats": []}');
      final index = await JsonChatStore(chats()).loadIndex();
      expect(index.single.id, 'main', reason: 'пересобран по файлам');
    });

    test('битый файл чата → .broken, чат пустой, остальные и tasks.json целы',
        () async {
      final tasks = File(p.join(root.path, 'assistant', 'tasks.json'));
      await tasks.parent.create(recursive: true);
      tasks.writeAsStringSync('{"schema_version":1,"tasks":[]}');
      final store = JsonChatStore(chats());
      await store.save(_main(<ChatMessage>[_message(1)]));
      await store.save(_task('t1', <ChatMessage>[_message(2)]));
      await store.flush();
      File(p.join(chats(), 'task-t1.json')).writeAsStringSync('{"битый');

      final again = JsonChatStore(chats());
      await again.loadIndex();
      expect(await again.loadMessages('task:t1'), isEmpty);
      expect((await again.loadMessages('main')).single.id, 'm_1');
      expect(File(p.join(chats(), 'task-t1.json.broken')).existsSync(), isTrue);
      expect(
        tasks.readAsStringSync(),
        '{"schema_version":1,"tasks":[]}',
      );
    });

    test('битое сообщение пропускается, остальные читаются', () async {
      final store = JsonChatStore(chats());
      await store.save(_main(<ChatMessage>[_message(1), _message(2)]));
      await store.flush();
      final file = File(p.join(chats(), 'main.json'));
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      (json['messages']! as List<Object?>).insert(1, <String, Object?>{
        'id': 'x',
      });
      file.writeAsStringSync(jsonEncode(json));
      final messages = await JsonChatStore(chats()).loadMessages('main');
      expect(messages.map((ChatMessage m) => m.id), <String>['m_1', 'm_2']);
    });

    test('параллельные записи идут по очереди и не теряются', () async {
      final store = JsonChatStore(chats(), debounce: Duration.zero);
      final futures = <Future<void>>[
        for (var i = 0; i < 20; i++)
          store.save(_task('t$i', <ChatMessage>[_message(i)])),
      ];
      await Future.wait(futures);
      await store.flush();
      final again = JsonChatStore(chats());
      expect((await again.loadIndex()).length, 20);
      for (var i = 0; i < 20; i++) {
        expect((await again.loadMessages('task:t$i')).single.id, 'm_$i');
      }
      expect(
        Directory(chats())
            .listSync()
            .where((FileSystemEntity e) => e.path.endsWith('.tmp')),
        isEmpty,
      );
    });

    test('файл не UTF-8 → .broken, а не перезапись без копии', () async {
      final store = JsonChatStore(chats());
      final history = <ChatMessage>[
        ChatMessage(
          id: 'm_ru',
          author: ChatAuthor.user,
          text: 'Привет, мир',
          timestamp: _t0,
        ),
      ];
      await store.save(_main(history));
      await store.flush();
      final file = File(p.join(chats(), 'main.json'));
      final bytes = file.readAsBytesSync();
      // Обрыв посреди кириллической буквы: второй байт из двух потерян.
      final cut = utf8.encode('{"schema_version":1,"chat":{"id":"main","п');
      file.writeAsBytesSync(cut.sublist(0, cut.length - 1));
      expect(bytes, isNotEmpty);

      final again = JsonChatStore(chats(), debounce: Duration.zero);
      await again.loadIndex();
      expect(await again.loadMessages('main'), isEmpty);
      expect(File(p.join(chats(), 'main.json.broken')).existsSync(), isTrue);
      await again.save(_main(<ChatMessage>[_message(9)]));
      await again.flush();
      expect(
        File(p.join(chats(), 'main.json.broken')).readAsBytesSync(),
        cut.sublist(0, cut.length - 1),
        reason: 'повреждённая история отложена, а не затёрта',
      );
    });

    test('index.json не UTF-8 → .broken и пересборка, чаты задач на месте',
        () async {
      final store = JsonChatStore(chats());
      await store.save(_main(<ChatMessage>[_message(1)]));
      await store.save(_task('t1', <ChatMessage>[_message(2)]));
      await store.flush();
      File(p.join(chats(), 'index.json'))
          .writeAsBytesSync(<int>[0x7b, 0xff, 0xfe]);

      final again = JsonChatStore(chats());
      expect(
        (await again.loadIndex()).map((ChatThread t) => t.id),
        unorderedEquals(<String>['main', 'task:t1']),
      );
      expect(File(p.join(chats(), 'index.json.broken')).existsSync(), isTrue);
      expect((await again.loadMessages('task:t1')).single.id, 'm_2');
    });

    test('файл чата без записи в index.json не затирается', () async {
      final clock = FixedClock(_t0);
      final store = JsonChatStore(chats(), debounce: Duration.zero);
      var book = ChatBook(store: store, clock: clock);
      await book.load();
      book.append(book.currentId, _message(1));
      await book.flush();
      final index = File(p.join(chats(), 'index.json')).readAsStringSync();
      book
        ..ensureTaskThread('t1')
        ..append('task:t1', _message(2).copyAs('m_task'));
      await book.flush();
      // Сбой между записью файла чата и index.json.
      File(p.join(chats(), 'index.json')).writeAsStringSync(index);

      book = ChatBook(
        store: JsonChatStore(chats(), debounce: Duration.zero),
        clock: clock,
      );
      await book.load();
      expect(book.taskThread('t1'), isNotNull, reason: 'найден по файлу');
      final thread = await book.openTask('t1');
      expect(thread.messages.map((ChatMessage m) => m.id), <String>['m_task']);
      book.append('task:t1', _message(3));
      await book.flush();
      final messages = await JsonChatStore(chats()).loadMessages('task:t1');
      expect(messages.map((ChatMessage m) => m.id), <String>['m_task', 'm_3']);
    });

    test('чат удалённой задачи — в архиве; задача вернулась — история тоже',
        () async {
      final clock = FixedClock(_t0);
      var book = ChatBook(
        store: JsonChatStore(chats(), debounce: Duration.zero),
        clock: clock,
      );
      await book.load();
      book
        ..ensureTaskThread('t1')
        ..append('task:t1', _message(1));
      await book.flush();
      // tasks.json потерян: задач нет, чат уходит из списка.
      book.prune(<String>{});
      await book.flush();
      expect(File(p.join(chats(), 'task-t1.json')).existsSync(), isFalse);
      expect(
        File(p.join(chats(), 'archive', 'task-t1.json')).existsSync(),
        isTrue,
      );

      // tasks.json вернули: чат задачи открывается со своей историей.
      book = ChatBook(
        store: JsonChatStore(chats(), debounce: Duration.zero),
        clock: clock,
      );
      await book.load();
      final thread = await book.openTask('t1');
      expect(thread.messages.map((ChatMessage m) => m.id), <String>['m_1']);

      // «Очистить историю» стирает и архив.
      book.prune(<String>{});
      await book.flush();
      await book.clearAll();
      expect(Directory(p.join(chats(), 'archive')).existsSync(), isFalse);
    });

    test('сообщения, написанные пока чат читается, сохраняются', () async {
      final clock = FixedClock(_t0);
      final store = JsonChatStore(chats(), debounce: Duration.zero);
      var book = ChatBook(store: store, clock: clock);
      await book.load();
      book
        ..ensureTaskThread('t1')
        ..append('task:t1', _message(1).copyAs('старое'));
      await book.flush();

      book = ChatBook(
        store: JsonChatStore(chats(), debounce: Duration.zero),
        clock: clock,
      );
      await book.load();
      final opening = book.openTask('t1');
      book
        ..append('task:t1', _message(2).copyAs('во время загрузки'))
        ..append('task:t1', _message(3).copyAs('ответ'))
        ..setAddressee('task:t1', 'rio');
      await opening;
      await book.flush();
      expect(
        book.current.messages.map((ChatMessage m) => m.id),
        <String>['старое', 'во время загрузки', 'ответ'],
      );

      book = ChatBook(store: JsonChatStore(chats()), clock: clock);
      await book.load();
      final thread = await book.openTask('t1');
      expect(
        thread.messages.map((ChatMessage m) => m.id),
        <String>['старое', 'во время загрузки', 'ответ'],
      );
      expect(thread.addressee, 'rio');
    });

    test('папку нельзя создать — ошибка не роняет приложение', () async {
      final blocker = File(p.join(root.path, 'blocker'))..writeAsStringSync('');
      final store = JsonChatStore(p.join(blocker.path, 'chats'));
      await store.save(_main(<ChatMessage>[_message(1)]));
      await store.flush();
      expect(await store.loadIndex(), isEmpty);
      expect(await store.loadMessages('main'), isEmpty);
    });
  });
}
