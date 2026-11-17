// Логика сессий в боковой панели (аудит чатов): чаты задач только с копией
// команды не засоряют «Сессии», сессии сверх лимита не пропадают («Показать
// ещё»), «+» поднимает пустую сессию в «Сегодня», поиск без дублей из
// чатов задач, выбор («её») удалённой сессии забывается.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/chats/chat_book.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

final class _Clock implements Clock {
  DateTime value = DateTime(2026, 11, 4, 12);

  @override
  DateTime now() => value;
}

ChatMessage _say(ChatBook book, String text, DateTime at, {bool user = true}) =>
    ChatMessage(
      id: book.newMessageId(),
      author: user ? ChatAuthor.user : ChatAuthor.persona,
      personaId: user ? null : 'sado',
      text: text,
      timestamp: at,
    );

/// Команда «Добавь задачу [title]» в сессии [sessionId] с ответом и чатом
/// новой задачи [taskId] — как это делает главный экран.
void _createTask(
  ChatBook book,
  String sessionId,
  String taskId,
  String title,
  DateTime at,
) {
  final command = _say(book, 'Добавь задачу $title', at);
  final link = ChatLink(chatId: ChatThread.taskChatId(taskId), taskId: taskId);
  final reply =
      _say(book, 'Создал задачу «$title»', at, user: false).withLink(link);
  book
    ..append(sessionId, command)
    ..append(sessionId, reply)
    ..onTaskCreated(
      taskId,
      fromChatId: sessionId,
      command: command,
      reply: reply,
    );
}

List<String> _ids(List<ChatThread> list) =>
    <String>[for (final thread in list) thread.id];

void main() {
  late _Clock clock;

  setUp(() => clock = _Clock());

  group('чаты задач среди сессий', () {
    test('три задачи из одной сессии — одна строка, своя реплика — вторая',
        () async {
      final store = InMemoryChatStore();
      final b = ChatBook(store: store, clock: clock);
      await b.load();
      final session = b.currentId;
      for (final (id, title) in <(String, String)>[
        ('a', 'хлеб'),
        ('b', 'молоко'),
        ('c', 'сыр'),
      ]) {
        _createTask(b, session, id, title, clock.value);
      }
      expect(_ids(b.groups(clock.value).today), <String>[session]);
      expect(b.groups(clock.value).hidden, 0);
      expect(b.taskThread('a')!.ownTalk, isFalse);

      // Ответ помощника (напоминание) своей репликой не считается.
      b.append('task:b', _say(b, 'Напоминаю', clock.value, user: false));
      expect(_ids(b.groups(clock.value).today), <String>[session]);

      clock.value = clock.value.add(const Duration(minutes: 5));
      b.append('task:b', _say(b, 'на пятницу', clock.value));
      expect(b.taskThread('b')!.ownTalk, isTrue);
      expect(
        _ids(b.groups(clock.value).today),
        <String>['task:b', session],
      );

      // Перезапуск: признак — в index.json.
      await b.flush();
      final again = ChatBook(store: store, clock: clock);
      await again.load();
      expect(
        _ids(again.groups(clock.value).today).where((String id) {
          return id.startsWith('task:');
        }),
        <String>['task:b'],
      );
      expect(again.taskThread('a')!.ownTalk, isFalse);
    });

    test('открытый чат задачи — в списке, даже без своей реплики', () async {
      final b = ChatBook(store: InMemoryChatStore(), clock: clock);
      await b.load();
      final session = b.currentId;
      _createTask(b, session, 'a', 'хлеб', clock.value);
      await b.openTask('a');
      expect(_ids(b.groups(clock.value).today), contains('task:a'));
      await b.open(session);
      expect(_ids(b.groups(clock.value).today), isNot(contains('task:a')));
    });

    test('старый index.json без признака: по числу сообщений, потом точно',
        () async {
      final dir = Directory.systemTemp.createTempSync('chats_own_talk');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = JsonChatStore(dir.path);
      final b = ChatBook(store: store, clock: clock);
      await b.load();
      final session = b.currentId;
      _createTask(b, session, 'a', 'хлеб', clock.value);
      // Помощник дописал в чат задачи: сообщений три, своих реплик нет.
      b.append('task:a', _say(b, 'Напоминаю', clock.value, user: false));
      await b.flush();
      // Убираем признак, как в файлах прежних версий.
      for (final name in <String>['index.json', 'task-a.json']) {
        final file = File('${dir.path}/$name');
        if (!file.existsSync()) continue;
        file.writeAsStringSync(
          file
              .readAsStringSync()
              .replaceAll(RegExp(r'"own_talk":\s*false,\s*'), ''),
        );
      }
      final again = ChatBook(store: JsonChatStore(dir.path), clock: clock);
      await again.load();
      expect(again.taskThread('a')!.ownTalk, isTrue, reason: 'догадка: 3 > 2');
      await again.openTask('a');
      expect(again.taskThread('a')!.ownTalk, isFalse, reason: 'прочитан');
    });

    test('копия команды из задачи в задаче — не своя реплика', () async {
      final b = ChatBook(store: InMemoryChatStore(), clock: clock);
      await b.load();
      final session = b.currentId;
      _createTask(b, session, 'a', 'хлеб', clock.value);
      await b.openTask('a');
      // Подзадача создана командой в чате задачи «a»: там — своя реплика,
      // в чате подзадачи — только копия.
      _createTask(b, 'task:a', 'b', 'батон', clock.value);
      expect(b.taskThread('a')!.ownTalk, isTrue);
      expect(b.taskThread('b')!.ownTalk, isFalse);
      expect(b.taskThread('b')!.parentTaskId, 'a');
    });
  });

  group('лимит панели', () {
    test('60 сессий: видно 50, остальные — «Показать ещё»', () async {
      final b = ChatBook(store: InMemoryChatStore(), clock: clock);
      await b.load();
      final base = clock.value;
      for (var i = 0; i < 60; i++) {
        clock.value = base.subtract(Duration(hours: i + 1));
        await b.newSession();
        b.append(
          b.currentId,
          _say(b, 'команда $i', base.subtract(Duration(hours: i + 1))),
        );
      }
      // Открыта новая пустая — она всегда видна.
      clock.value = base;
      await b.newSession();
      int count(SessionGroups g) =>
          g.today.length +
          g.yesterday.length +
          g.week.length +
          g.earlier.length;
      final first = b.groups(clock.value);
      // 60 сессий и открытая пустая: 50 в лимите, 11 — за ним.
      expect(count(first), 50);
      expect(first.hidden, 11);
      final more = b.groups(clock.value, limit: 100);
      expect(count(more), 61);
      expect(more.hidden, 0);
    });

    test('открытая сессия за лимитом — видна, «ещё» её не считает', () async {
      final b = ChatBook(store: InMemoryChatStore(), clock: clock);
      await b.load();
      final base = clock.value;
      final ids = <String>[];
      for (var i = 0; i < 5; i++) {
        clock.value = base.subtract(Duration(hours: i + 1));
        await b.newSession();
        b.append(
          b.currentId,
          _say(b, 'команда $i', base.subtract(Duration(hours: i + 1))),
        );
        ids.add(b.currentId);
      }
      clock.value = base;
      await b.open(ids.last);
      final g = b.groups(clock.value, limit: 2);
      expect(_ids(g.today), contains(ids.last));
      expect(g.today.length, 3);
      expect(g.hidden, 2);
    });
  });

  group('пустая сессия — всегда «сейчас»', () {
    test('оставленная вчера пустая сессия по «+» — в «Сегодня», наверху',
        () async {
      clock.value = DateTime(2026, 11, 3, 18);
      final b = ChatBook(store: InMemoryChatStore(), clock: clock);
      await b.load();
      final empty = b.currentId;
      await b.newSession();
      expect(b.currentId, empty);
      // Вчера: ушли в чат задачи, пустая сессия осталась в памяти.
      await b.openTask('t');
      b.append('task:t', _say(b, 'на завтра', clock.value));
      clock.value = DateTime(2026, 11, 4, 9);
      b.append('task:t', _say(b, 'на пятницу', clock.value));
      await b.newSession();
      expect(b.currentId, empty, reason: 'та же пустая, не вторая');
      final g = b.groups(clock.value);
      expect(_ids(g.today), <String>[empty, 'task:t']);
      expect(g.yesterday, isEmpty);
      expect(b.current.createdAt, clock.value);
    });

    test('23:50 → 00:10: «+» в той же пустой сессии — уже сегодня', () async {
      clock.value = DateTime(2026, 11, 3, 23, 50);
      final b = ChatBook(store: InMemoryChatStore(), clock: clock);
      await b.load();
      final empty = b.currentId;
      clock.value = DateTime(2026, 11, 4, 0, 10);
      // Даже без «+» пустая сессия стоит в «Сегодня».
      expect(_ids(b.groups(clock.value).today), <String>[empty]);
      await b.newSession();
      expect(b.currentId, empty);
      expect(b.current.lastActivityAt, clock.value);
      // Первая команда — время её, а не вчерашнее создание.
      b.append(empty, _say(b, '2+2', clock.value));
      expect(_ids(b.groups(clock.value).today), <String>[empty]);
      expect(b.groups(clock.value).yesterday, isEmpty);
    });

    test('у сессии с сообщениями время не меняется', () async {
      final b = ChatBook(store: InMemoryChatStore(), clock: clock);
      await b.load();
      final at = clock.value;
      b.append(b.currentId, _say(b, '2+2', at));
      b.current.touchEmpty(at.add(const Duration(days: 1)));
      expect(b.current.lastActivityAt, at);
    });
  });

  test('поиск: команда, создавшая задачу, — один результат', () async {
    final b = ChatBook(store: InMemoryChatStore(), clock: clock);
    await b.load();
    final session = b.currentId;
    _createTask(b, session, 'a', 'хлеб', clock.value);
    final hits = await b.search(
      'добавь задачу хлеб',
      titles: const <String, String>{'a': 'Хлеб'},
    );
    expect(hits.map((h) => h.chatId), <String>[session]);
    // Ответ «Создал задачу» — тоже только в сессии.
    final replies = await b.search('создал задачу');
    expect(replies.map((h) => h.chatId), <String>[session]);
    // Своя реплика в чате задачи находится.
    await b.openTask('a');
    b.append('task:a', _say(b, 'добавь задачу хлеб ещё раз', clock.value));
    final again = await b.search('ещё раз');
    expect(again.map((h) => h.chatId), <String>['task:a']);
    // Чат задачи по-прежнему находится по названию задачи.
    final byTitle = await b.search(
      'хлеб',
      titles: const <String, String>{'a': 'Хлеб'},
    );
    expect(byTitle.map((h) => h.chatId), containsAll(<String>['task:a']));
  });

  test('удалённая сессия: её выбор («её») не возвращается', () async {
    final tasks = TaskService(
      repository: InMemoryTaskRepository(),
      clock: clock,
    );
    final assistant = AssistantController(
      connectors: <Connector>[
        TasksConnector(
          taskService: tasks,
          parser: ScenarioParser(clock: clock),
        ),
      ],
      clock: clock,
    );
    final task = await tasks.create(title: 'Хлеб');
    assistant
      ..enterChat(sessionId: 'session:a')
      ..selectTask(task.id)
      ..enterChat(sessionId: 'session:b');
    expect(assistant.selectedTaskId, isNull);
    assistant.enterChat(sessionId: 'session:a');
    expect(assistant.selectedTaskId, task.id, reason: 'выбор сессии сохранён');

    // Удалили сессию, пока она открыта, и открыли другую.
    assistant
      ..forgetChat('session:a')
      ..enterChat(sessionId: 'session:b')
      ..enterChat(sessionId: 'session:a');
    expect(assistant.selectedTaskId, isNull);

    // Удалили закрытую сессию.
    assistant
      ..enterChat(sessionId: 'session:d')
      ..selectTask(task.id)
      ..enterChat(sessionId: 'session:c')
      ..forgetChat('session:d')
      ..enterChat(sessionId: 'session:d');
    expect(assistant.selectedTaskId, isNull);
    // Остальные сессии свой выбор помнят.
    assistant
      ..selectTask(task.id)
      ..enterChat(sessionId: 'session:c')
      ..enterChat(sessionId: 'session:d');
    expect(assistant.selectedTaskId, task.id);
  });
}
