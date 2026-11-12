// Книга чатов (ADR-010): главный чат всегда есть, чат задачи создаётся
// лениво, «назад», удаление чатов удалённых задач, «не прочитано».
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/chats/chat_book.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
import 'package:local_assistant/core/models/action_card.dart';
import 'package:local_assistant/core/models/secure_card.dart';
import 'package:local_assistant/core/services/clock.dart';

final class _Clock implements Clock {
  DateTime value = DateTime(2026, 11, 4, 12);

  @override
  DateTime now() => value;
}

ChatMessage _say(ChatBook book, String text, DateTime at, {bool user = true}) =>
    ChatMessage(
      id: book.newMessageId(),
      author: user ? ChatAuthor.user : ChatAuthor.persona,
      personaId: user ? null : 'rio',
      text: text,
      timestamp: at,
    );

void main() {
  late _Clock clock;
  late InMemoryChatStore store;

  setUp(() {
    clock = _Clock();
    store = InMemoryChatStore();
  });

  Future<ChatBook> book() async {
    final book = ChatBook(store: store, clock: clock);
    await book.load();
    return book;
  }

  test('главный чат есть всегда; пустой — без записи на диск', () async {
    final b = await book();
    expect(b.current.isMain, isTrue);
    expect(b.main.messages, isEmpty);
    b.resetMain(<ChatMessage>[_say(b, 'Привет', clock.value, user: false)]);
    expect(store.chatIds, isEmpty, reason: 'приветствие не пишется');
    expect(await b.load(), isFalse);
  });

  test('чат задачи создаётся лениво и пишется с первым сообщением', () async {
    final b = await book();
    final thread = await b.openTask('t1');
    expect(thread.id, 'task:t1');
    expect(b.currentId, 'task:t1');
    expect(store.chatIds, isEmpty);
    b.append('task:t1', _say(b, 'готово', clock.value));
    expect(store.chatIds, <String>['task:t1']);

    final again = await book();
    expect(again.taskThread('t1')!.loaded, isFalse);
    await again.openTask('t1');
    expect(again.current.messages.single.text, 'готово');
  });

  test('«назад» возвращает к предыдущему чату, удалённые пропускаются',
      () async {
    final b = await book();
    await b.openTask('a');
    await b.openTask('b');
    await b.openTask('c');
    expect((await b.back()).id, 'task:b');
    b.prune(<String>{'c'});
    expect(b.thread('task:b'), isNull);
    expect(b.currentId, 'main', reason: 'открытый чат удалён');
    await b.openTask('c');
    expect((await b.back()).id, 'main');
    expect((await b.back()).id, 'main', reason: 'дальше некуда');
  });

  test('стек «назад» не длиннее 20 и без повторов подряд', () async {
    final b = await book();
    for (var i = 0; i < 30; i++) {
      await b.openTask('t$i');
      await b.openTask('t$i');
    }
    var steps = 0;
    while (b.currentId != 'main' || steps == 0) {
      await b.back();
      steps++;
      if (steps > 40) break;
    }
    expect(steps, lessThanOrEqualTo(ChatBook.maxBack + 1));
  });

  test('prune удаляет чаты удалённых задач вместе с файлом', () async {
    final b = await book();
    b.ensureTaskThread('done');
    b.append('task:done', _say(b, 'готово', clock.value));
    b.ensureTaskThread('gone');
    b.append('task:gone', _say(b, 'привет', clock.value));
    b.prune(<String>{'done'});
    await Future<void>.delayed(Duration.zero);
    expect(b.taskThread('gone'), isNull);
    expect(b.taskThread('done'), isNotNull, reason: 'выполненная остаётся');
    expect(store.chatIds, <String>['task:done']);
  });

  test('recent: по последней активности, только чаты с сообщениями', () async {
    final b = await book();
    for (final (id, minute) in <(String, int)>[('a', 5), ('b', 1), ('c', 9)]) {
      b.ensureTaskThread(id);
      b.append(
        'task:$id',
        _say(b, id, clock.value.add(Duration(minutes: minute))),
      );
    }
    b.ensureTaskThread('empty');
    expect(
      b.recent().map((ChatThread t) => t.taskId),
      <String>['c', 'a', 'b'],
    );
    expect(b.recent(limit: 2).length, 2);
  });

  test('сообщение помощника в закрытый чат — «не прочитано»', () async {
    final b = await book();
    await b.openTask('t1');
    b.append('main', _say(b, 'Просрочено', clock.value, user: false));
    expect(b.main.unread, isTrue);
    b.append('main', _say(b, 'команда', clock.value));
    await b.open('main');
    expect(b.main.unread, isFalse);
    b.append('main', _say(b, 'ответ', clock.value, user: false));
    expect(b.main.unread, isFalse, reason: 'чат открыт');
  });

  test('создание задачи: копия команды и ответа, ссылки, родитель', () async {
    final b = await book();
    final command = _say(b, 'добавь задачу хлеб', clock.value);
    final reply = _say(b, 'Создал', clock.value, user: false).withLink(
      const ChatLink(chatId: 'task:t1', taskId: 't1'),
    );
    b
      ..append('main', command)
      ..append('main', reply);
    final thread = b.onTaskCreated(
      't1',
      fromChatId: 'main',
      command: command,
      reply: reply,
    );
    expect(thread.parentTaskId, isNull);
    expect(
      thread.messages.map((ChatMessage m) => m.text),
      <String>['добавь задачу хлеб', 'Создал'],
    );
    expect(thread.messages.first.id, isNot(command.id));
    expect(
      thread.messages.last.link,
      ChatLink(chatId: 'main', messageId: reply.id),
    );
    expect(thread.unread, isFalse);

    await b.openTask('t1');
    final sub = _say(b, 'добавь задачу масло', clock.value);
    final subReply = _say(b, 'Создал', clock.value, user: false);
    b.append('task:t1', sub);
    final child = b.onTaskCreated(
      't2',
      fromChatId: 'task:t1',
      command: sub,
      reply: subReply,
    );
    expect(child.parentTaskId, 't1');
    expect(child.messages.last.link!.taskId, 't1');

    await b.flush();
    final again = await book();
    expect(again.taskThread('t2')!.parentTaskId, 't1');
  });

  test('адресат у каждого чата свой и сохраняется', () async {
    final b = await book();
    await b.openTask('t1');
    b.append('task:t1', _say(b, 'x', clock.value));
    b.setAddressee('task:t1', 'noda');
    b.append('main', _say(b, 'y', clock.value));
    expect(b.main.addressee, isNull);
    final again = await book();
    expect(again.taskThread('t1')!.addressee, 'noda');
    expect(again.main.addressee, isNull);
  });

  test('clearAll: чаты задач удалены, главный пуст и открыт', () async {
    final b = await book();
    b.append('main', _say(b, 'x', clock.value));
    await b.openTask('t1');
    b.append('task:t1', _say(b, 'y', clock.value));
    expect(b.totalMessages, 2);
    await b.clearAll();
    expect(b.currentId, 'main');
    expect(b.main.messages, isEmpty);
    expect(b.taskThread('t1'), isNull);
    expect(store.chatIds, isEmpty);
  });

  test('лимит в памяти: 1000 последних', () async {
    final b = await book();
    for (var i = 0; i < 1003; i++) {
      b.append('main', _say(b, '$i', clock.value));
    }
    expect(b.main.messages.length, ChatStore.maxMessages);
    expect(b.main.messages.first.text, '3');
  });

  group('сессии (ADR-015)', () {
    test('newSession: пустая, открыта сразу, на диск — с первым сообщением',
        () async {
      final b = await book();
      final thread = await b.newSession();
      expect(thread.isSession, isTrue);
      expect(thread.id, startsWith(ChatThread.sessionPrefix));
      expect(b.currentId, thread.id);
      expect(thread.messages, isEmpty, reason: 'без приветствия');
      expect(store.chatIds, isEmpty);
      expect(ChatBook.titleOf(thread), 'Новая сессия');
      // Пустая открытая сессия не плодит новые.
      expect((await b.newSession()).id, thread.id);

      b.append(
        thread.id,
        _say(b, 'Сверить   накладные\nза ноябрь', clock.value),
      );
      expect(store.chatIds, <String>[thread.id]);
      expect(thread.title, 'Сверить накладные за ноябрь');
      b.append(thread.id, _say(b, 'вторая команда', clock.value));
      expect(thread.title, 'Сверить накладные за ноябрь', reason: 'первая');

      final again = await book();
      final restored = again.thread(thread.id)!;
      expect(restored.isSession, isTrue);
      expect(restored.title, 'Сверить накладные за ноябрь');
      await again.open(thread.id);
      expect(restored.messages, hasLength(2));
    });

    test('название сессии — до 40 знаков с «…»', () {
      final long = 'а' * 60;
      final title = ChatBook.sessionTitle(long);
      expect(title.length, ChatBook.titleLimit);
      expect(title, endsWith('…'));
    });

    test('prune не трогает сессии, clearAll удаляет', () async {
      final b = await book();
      final session = await b.newSession();
      b.append(session.id, _say(b, 'привет', clock.value));
      await b.openTask('t1');
      b.append('task:t1', _say(b, 'готово', clock.value));
      b.prune(<String>{});
      expect(b.thread(session.id), isNotNull, reason: 'сессия жива');
      expect(b.thread('task:t1'), isNull);
      await b.clearAll();
      expect(b.thread(session.id), isNull);
      expect(b.current.isMain, isTrue);
    });

    test('sessions: главный, сессии и чаты задач по активности', () async {
      final b = await book();
      final s1 = await b.newSession();
      clock.value = clock.value.add(const Duration(minutes: 1));
      b.append(s1.id, _say(b, 'раз', clock.value));
      await b.openTask('t1');
      clock.value = clock.value.add(const Duration(minutes: 1));
      b.append('task:t1', _say(b, 'два', clock.value));
      final ids = b.sessions().map((ChatThread t) => t.id).toList();
      expect(ids, <String>['task:t1', s1.id, ChatThread.mainId]);
      // Пустая сессия в списке, только пока открыта.
      final empty = await b.newSession();
      expect(b.sessions().map((ChatThread t) => t.id), contains(empty.id));
      await b.open(ChatThread.mainId);
      expect(
        b.sessions().map((ChatThread t) => t.id),
        isNot(contains(empty.id)),
      );
      expect(b.sessionCount, 2);
    });

    test('ChatCodec.fileName и метаданные сессии', () {
      expect(
        ChatCodec.fileName('session:123_ab'),
        'session-123_ab.json',
      );
      final thread = ChatThread(
        id: 'session:123_ab',
        kind: ChatKind.session,
        createdAt: DateTime(2026, 11, 4),
        title: 'Сверить',
      );
      final back = ChatThread.fromMetaJson(thread.metaJson())!;
      expect(back.kind, ChatKind.session);
      expect(back.title, 'Сверить');
      expect(
        ChatThread.fromMetaJson(<String, Object?>{
          ...thread.metaJson(),
          'id': 'main2',
        }),
        isNull,
        reason: 'у сессии id с префиксом',
      );
    });
  });

  group('поиск по сессиям', () {
    test('название и текст, без регистра, ё = е, отрывок с совпадением',
        () async {
      final b = await book();
      b.append(
        ChatThread.mainId,
        _say(b, 'Что по ПРИХОДУ 318? Ещё раз проверь', clock.value),
      );
      final session = await b.newSession();
      b.append(session.id, _say(b, 'приход ёлок', clock.value));
      final hits = await b.search('приход');
      expect(hits.map((h) => h.chatId).toSet(), <String>{
        ChatThread.mainId,
        session.id,
      });
      final main = hits.firstWhere((h) => h.chatId == ChatThread.mainId);
      expect(
        main.snippet.substring(main.matchStart, main.matchEnd).toLowerCase(),
        'приход',
      );
      expect(await b.search('елок'), hasLength(1));
      expect(await b.search('ещё'), hasLength(1));
      expect(
        await b.search('Новая сес'),
        hasLength(0),
        reason: 'есть название',
      );
      expect(await b.search('  '), isEmpty);
    });

    test('непрочитанные чаты читаются для поиска, книга не меняется', () async {
      final first = await book();
      await first.openTask('t1');
      first.append('task:t1', _say(first, 'сверить накладные', clock.value));
      await first.flush();
      final b = await book();
      expect(b.taskThread('t1')!.loaded, isFalse);
      final hits = await b.search(
        'накладн',
        titles: <String, String>{'t1': 'Сверка'},
      );
      expect(hits.single.title, 'Сверка');
      expect(b.taskThread('t1')!.loaded, isFalse, reason: 'не загружен');
    });

    test('карточки «Паролей» и действий не ищутся', () async {
      final b = await book();
      b.append(
        ChatThread.mainId,
        ChatMessage(
          id: b.newMessageId(),
          author: ChatAuthor.persona,
          personaId: 'rio',
          text: 'Пароль CANARY-7f3a показан',
          timestamp: clock.value,
          secureCard: const SecureCardRequest(kind: SecureCardKind.reveal),
        ),
      );
      expect(await b.search('CANARY'), isEmpty);
    });
  });

  test('pendingCards: только ждущие и годные к отправке', () async {
    final b = await book();
    ActionCard card(String rid) => ActionCard(
          rid: rid,
          connectorId: 'warehouse',
          kind: ActionKind.post,
          login: 'ivanov',
          name: 'Иван',
          deadline: clock.value.add(const Duration(minutes: 5)),
          lines: const <ActionCardLine>[],
          commit: const <String, Object?>{'a': 1},
          stamp: 'stamp',
        );
    final ready = card('aaaaaaaaaaaaaaaa');
    final done = card('bbbbbbbbbbbbbbbb')..state = ActionCardState.applied;
    for (final c in <ActionCard>[ready, done]) {
      b.append(
        ChatThread.mainId,
        ChatMessage(
          id: b.newMessageId(),
          author: ChatAuthor.persona,
          personaId: 'noda',
          text: 'Отметка',
          timestamp: clock.value,
          card: c,
        ),
      );
    }
    final pending = b.pendingCards(clock.value);
    expect(pending.single.message.card, same(ready));
    expect(pending.single.chatId, ChatThread.mainId);
    expect(b.pendingCards(clock.value.add(const Duration(hours: 1))), isEmpty);
  });

  group('активность сессий для «Мой Связной»', () {
    test('прочитанные — по командам пользователя, ответы не считаются',
        () async {
      final b = await book();
      b
        ..append(ChatThread.mainId, _say(b, 'раз', DateTime(2026, 11, 2, 9)))
        ..append(ChatThread.mainId, _say(b, 'два', DateTime(2026, 11, 2, 23)))
        ..append(
          ChatThread.mainId,
          _say(b, 'ответ', DateTime(2026, 11, 3, 9), user: false),
        );
      expect(b.activityDays(), <DateTime, int>{DateTime(2026, 11, 2): 2});
      expect(b.earliestActivity, isNotNull);
    });

    test('копия команды в чате новой задачи не считается второй раз', () async {
      final b = await book();
      final command = _say(b, 'добавь задачу хлеб', DateTime(2026, 11, 9, 10));
      final reply =
          _say(b, 'Создал', DateTime(2026, 11, 9, 10), user: false).withLink(
        const ChatLink(chatId: 'task:t1', taskId: 't1'),
      );
      b
        ..append(ChatThread.mainId, command)
        ..append(ChatThread.mainId, reply)
        ..onTaskCreated(
          't1',
          fromChatId: ChatThread.mainId,
          command: command,
          reply: reply,
        );
      expect(b.sessionCount, 1);
      expect(b.activityDays(), <DateTime, int>{DateTime(2026, 11, 9): 1});

      // Своя команда в чате задачи — уже отдельная активность.
      b.append('task:t1', _say(b, 'перенеси', DateTime(2026, 11, 9, 11)));
      expect(b.sessionCount, 2);
      expect(b.activityDays(), <DateTime, int>{DateTime(2026, 11, 9): 2});
    });

    test('непрочитанные: по index.json, а с readStored — точно', () async {
      clock.value = DateTime(2026, 11, 1, 10);
      final first = await book();
      await first.openTask('t1');
      first
        ..append('task:t1', _say(first, 'а', DateTime(2026, 11, 1, 10)))
        ..append('task:t1', _say(first, 'б', DateTime(2026, 11, 1, 11)));
      clock.value = DateTime(2026, 11, 3, 8);
      first.append('task:t1', _say(first, 'в', DateTime(2026, 11, 3, 8)));
      await first.flush();

      final b = await book();
      final thread = b.taskThread('t1')!;
      expect(thread.loaded, isFalse);
      final approx = b.activityDays();
      expect(approx.values.fold<int>(0, (int a, int v) => a + v), 2);
      expect(b.activityExact(const <String, List<ChatMessage>>{}), isFalse);

      final stored = await b.readStored();
      expect(thread.loaded, isFalse, reason: 'книга не меняется');
      expect(b.activityExact(stored), isTrue);
      expect(b.activityDays(stored: stored), <DateTime, int>{
        DateTime(2026, 11, 1): 2,
        DateTime(2026, 11, 3): 1,
      });
    });
  });
}
