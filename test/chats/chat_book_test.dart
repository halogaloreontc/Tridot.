// Книга чатов (ADR-010, ADR-015): только сессии — при старте открыта
// пустая; чат задачи создаётся лениво, «назад», удаление чатов удалённых
// задач, «не прочитано», перенос прежнего «Главного» в сессию.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/chats/chat_book.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
import 'package:local_assistant/core/models/action_card.dart';
import 'package:local_assistant/core/models/secure_card.dart';
import 'package:local_assistant/core/passwords/secret_guard.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:path/path.dart' as p;

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

  test('при старте открыта пустая сессия; пустая — без записи на диск',
      () async {
    final b = ChatBook(store: store, clock: clock);
    expect(b.current.isSession, isTrue, reason: 'и до загрузки');
    final initial = b.currentId;
    expect(await b.load(), isFalse, reason: 'переносить нечего');
    expect(b.currentId, initial);
    expect(b.current.kind, ChatKind.session);
    expect(b.current.messages, isEmpty);
    expect(ChatBook.titleOf(b.current), 'Новая сессия');
    await b.flush();
    expect(store.chatIds, isEmpty);
    expect(store.saves, 0);
    expect(
      b.threads.where((ChatThread t) => t.kind == ChatKind.main),
      isEmpty,
    );
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
    final start = b.currentId;
    await b.openTask('a');
    await b.openTask('b');
    await b.openTask('c');
    expect((await b.back()).id, 'task:b');
    b.prune(<String>{'c'});
    expect(b.thread('task:b'), isNull);
    expect(b.currentId, start, reason: 'открытый чат удалён: пустая сессия');
    await b.openTask('c');
    expect((await b.back()).id, start);
    expect((await b.back()).id, start, reason: 'дальше некуда');
    expect(
      b.threads.where((ChatThread t) => t.isSession),
      hasLength(1),
      reason: 'пустая сессия одна',
    );
  });

  test('стек «назад» не длиннее 20 и без повторов подряд', () async {
    final b = await book();
    final start = b.currentId;
    for (var i = 0; i < 30; i++) {
      await b.openTask('t$i');
      await b.openTask('t$i');
    }
    var steps = 0;
    while (b.currentId != start || steps == 0) {
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

  test('сообщение помощника в закрытый чат — «не прочитано»', () async {
    final b = await book();
    final s = b.currentId;
    b.append(s, _say(b, 'команда', clock.value));
    await b.openTask('t1');
    b.append(s, _say(b, 'Ответ', clock.value, user: false));
    expect(b.thread(s)!.unread, isTrue);
    await b.open(s);
    expect(b.thread(s)!.unread, isFalse);
    b.append(s, _say(b, 'ответ', clock.value, user: false));
    expect(b.thread(s)!.unread, isFalse, reason: 'чат открыт');
  });

  test('создание задачи: копия команды и ответа, ссылки, родитель', () async {
    final b = await book();
    final s = b.currentId;
    final command = _say(b, 'добавь задачу хлеб', clock.value);
    final reply = _say(b, 'Создал', clock.value, user: false).withLink(
      const ChatLink(chatId: 'task:t1', taskId: 't1'),
    );
    b
      ..append(s, command)
      ..append(s, reply);
    final thread = b.onTaskCreated(
      't1',
      fromChatId: s,
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
      ChatLink(chatId: s, messageId: reply.id),
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
    final s = b.currentId;
    await b.openTask('t1');
    b.append('task:t1', _say(b, 'x', clock.value));
    b.setAddressee('task:t1', 'noda');
    b.append(s, _say(b, 'y', clock.value));
    expect(b.thread(s)!.addressee, isNull);
    final again = await book();
    expect(again.taskThread('t1')!.addressee, 'noda');
    expect(again.thread(s)!.addressee, isNull);
  });

  test('clearAll: все чаты удалены, открыта новая пустая сессия', () async {
    final b = await book();
    final s = b.currentId;
    b.append(s, _say(b, 'x', clock.value));
    await b.openTask('t1');
    b.append('task:t1', _say(b, 'y', clock.value));
    expect(b.totalMessages, 2);
    await b.clearAll();
    expect(b.thread(s), isNull);
    expect(b.current.isSession, isTrue);
    expect(b.current.messages, isEmpty);
    expect(b.threads, hasLength(1));
    expect(b.taskThread('t1'), isNull);
    expect(store.chatIds, isEmpty);
    expect((await b.back()).id, b.currentId, reason: 'стек «назад» пуст');
  });

  test('лимит в памяти: 1000 последних', () async {
    final b = await book();
    for (var i = 0; i < 1003; i++) {
      b.append(b.currentId, _say(b, '$i', clock.value));
    }
    expect(b.current.messages.length, ChatStore.maxMessages);
    expect(b.current.messages.first.text, '3');
  });

  group('сессии (ADR-015)', () {
    test('newSession: пустая, открыта сразу, на диск — с первым сообщением',
        () async {
      final b = await book();
      final thread = await b.newSession();
      expect(thread.id, b.currentId, reason: 'пустая открытая — та же');
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
      expect(b.current.isSession, isTrue);
      expect(b.current.messageCount, 0);
    });

    test('sessions: сессии и чаты задач по активности, без «Главного»',
        () async {
      final b = await book();
      final s1 = await b.newSession();
      clock.value = clock.value.add(const Duration(minutes: 1));
      b.append(s1.id, _say(b, 'раз', clock.value));
      await b.openTask('t1');
      clock.value = clock.value.add(const Duration(minutes: 1));
      b.append('task:t1', _say(b, 'два', clock.value));
      final ids = b.sessions().map((ChatThread t) => t.id).toList();
      expect(ids, <String>['task:t1', s1.id]);
      // Пустая сессия в списке, только пока открыта.
      final empty = await b.newSession();
      expect(b.sessions().map((ChatThread t) => t.id), contains(empty.id));
      await b.open(s1.id);
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
    test('пустой чат задачи находится по названию задачи, пустая сессия — нет',
        () async {
      final b = await book();
      b.ensureTaskThread('t9');
      final hits = await b.search(
        'накладные',
        titles: const <String, String>{'t9': 'Сверить накладные'},
      );
      expect(hits.map((h) => h.chatId), <String>['task:t9']);
      expect(await b.search('новая сессия'), isEmpty);
    });

    test('название и текст, без регистра, ё = е, отрывок с совпадением',
        () async {
      final b = await book();
      final first = b.currentId;
      b.append(
        first,
        _say(b, 'Что по ПРИХОДУ 318? Ещё раз проверь', clock.value),
      );
      final session = await b.newSession();
      b.append(session.id, _say(b, 'приход ёлок', clock.value));
      final hits = await b.search('приход');
      expect(hits.map((h) => h.chatId).toSet(), <String>{
        first,
        session.id,
      });
      final hit = hits.firstWhere((h) => h.chatId == first);
      expect(
        hit.snippet.substring(hit.matchStart, hit.matchEnd).toLowerCase(),
        'приход',
      );
      expect(await b.search('елок'), hasLength(1));
      expect(await b.search('ещё'), hasLength(1));
      expect(
        await b.search('Новая сес'),
        hasLength(0),
        reason: 'есть название',
      );
      await b.newSession();
      expect(
        await b.search('новая'),
        isEmpty,
        reason: 'пустая «Новая сессия» не находится',
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
        b.currentId,
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
        b.currentId,
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
    expect(pending.single.chatId, b.currentId);
    expect(b.pendingCards(clock.value.add(const Duration(hours: 1))), isEmpty);
  });

  group('активность сессий для «Мой Tridot»', () {
    test('сессия только с ответами помощника не считается и после перезапуска',
        () async {
      final b = await book();
      b.append(
        b.currentId,
        _say(b, 'ответ без команды', DateTime(2026, 11, 2, 9), user: false),
      );
      await b.flush();
      expect(b.sessionCount, 0);
      final restarted = await book();
      expect(restarted.sessionCount, 0, reason: 'тот же счёт с диска');
      expect(restarted.activityDays(), isEmpty);
    });

    test('сессия с командой с диска считается до чтения', () async {
      final b = await book();
      b.append(b.currentId, _say(b, 'раз', DateTime(2026, 11, 2, 9)));
      await b.flush();
      expect(b.sessionCount, 1);
      final restarted = await book();
      expect(restarted.sessionCount, 1);
    });

    test('прочитанные — по командам пользователя, ответы не считаются',
        () async {
      final b = await book();
      final s = b.currentId;
      b
        ..append(s, _say(b, 'раз', DateTime(2026, 11, 2, 9)))
        ..append(s, _say(b, 'два', DateTime(2026, 11, 2, 23)))
        ..append(
          s,
          _say(b, 'ответ', DateTime(2026, 11, 3, 9), user: false),
        );
      expect(b.activityDays(), <DateTime, int>{DateTime(2026, 11, 2): 2});
      expect(b.earliestActivity, isNotNull);
    });

    test('копия команды в чате новой задачи не считается второй раз', () async {
      final b = await book();
      final s = b.currentId;
      final command = _say(b, 'добавь задачу хлеб', DateTime(2026, 11, 9, 10));
      final reply =
          _say(b, 'Создал', DateTime(2026, 11, 9, 10), user: false).withLink(
        const ChatLink(chatId: 'task:t1', taskId: 't1'),
      );
      b
        ..append(s, command)
        ..append(s, reply)
        ..onTaskCreated(
          't1',
          fromChatId: s,
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

  group('только сессии', () {
    test('open неизвестного чата — пустая сессия, без новых пустых', () async {
      final b = await book();
      final start = b.currentId;
      b.append(start, _say(b, 'раз', clock.value));
      final opened = await b.open('нет-такого');
      expect(opened.isSession, isTrue);
      expect(opened.messageCount, 0);
      expect(opened.id, isNot(start));
      expect((await b.open('и-такого')).id, opened.id);
    });

    test('пустая сессия одна: newSession → чат задачи → newSession', () async {
      final b = await book();
      final first = await b.newSession();
      await b.openTask('t1');
      final again = await b.newSession();
      expect(again.id, first.id, reason: 'оставленная пустая — снова она');
      expect(
        b.threads.where((ChatThread t) => t.isSession && t.messageCount == 0),
        hasLength(1),
      );
    });

    test('«назад» без стека из непустого чата — в пустую сессию', () async {
      final b = await book();
      final start = b.currentId;
      await b.openTask('t1');
      b.append('task:t1', _say(b, 'готово', clock.value));
      expect((await b.back()).id, start);
      // Стек пуст, открыта пустая — остаётся она.
      expect((await b.back()).id, start);
      b.append(start, _say(b, 'команда', clock.value));
      final next = await b.back();
      expect(next.isSession, isTrue);
      expect(next.messageCount, 0);
      expect(next.id, isNot(start));
    });

    test('prune открытого чата задачи — пустая сессия', () async {
      final b = await book();
      b.append(b.currentId, _say(b, 'раз', clock.value));
      await b.openTask('t1');
      b.append('task:t1', _say(b, 'готово', clock.value));
      expect(b.prune(<String>{}), isTrue);
      expect(b.current.isSession, isTrue);
      expect(b.current.messageCount, 0);
    });

    test('копия ответа ссылается на сессию, где создали задачу', () async {
      final b = await book();
      final s = b.currentId;
      final command = _say(b, 'Добавь задачу «Хлеб»', clock.value);
      final reply = _say(b, 'Создал', clock.value, user: false);
      b
        ..append(s, command)
        ..append(s, reply);
      final thread = b.onTaskCreated(
        't1',
        fromChatId: s,
        command: command,
        reply: reply,
      );
      expect(thread.messages.last.link!.chatId, s);
      expect(
        b.thread(thread.messages.last.link!.chatId)!.title,
        'Добавь задачу «Хлеб»',
      );
    });
  });

  group('перенос прежнего «Главного»', () {
    late Directory root;
    String chats() => p.join(root.path, 'chats');

    setUp(() {
      root = Directory.systemTemp.createTempSync('chat_book_main_');
    });
    tearDown(() => root.deleteSync(recursive: true));

    final card = ActionCard(
      rid: 'cccccccccccccccc',
      connectorId: 'warehouse',
      kind: ActionKind.post,
      login: 'ivanov',
      name: 'Иван',
      deadline: DateTime(2026, 11, 3, 10, 10),
      lines: const <ActionCardLine>[],
    );

    Map<String, Object?> msg(
      String id,
      String author,
      String text,
      String ts, {
      Map<String, Object?>? extra,
    }) =>
        <String, Object?>{
          'id': id,
          'author': author,
          if (author == 'persona') 'persona_id': 'rio',
          'text': text,
          'ts': ts,
          ...?extra,
        };

    /// Старый формат, как его писали прежние версии: index.json, main.json
    /// и чат задачи, у копии в котором ссылка на `main`.
    void writeLegacy({
      List<Map<String, Object?>>? mainMessages,
      bool withIndex = true,
      bool mainFirst = false,
    }) {
      final dir = Directory(chats())..createSync(recursive: true);
      final messages = mainMessages ??
          <Map<String, Object?>>[
            msg(
              'm1',
              'persona',
              'Я готов к работе.',
              '2026-11-01T09:00:00.000',
            ),
            msg(
              'm2',
              'user',
              'Добавь задачу «Хлеб»',
              '2026-11-03T10:00:00.000',
            ),
            msg(
              'm3',
              'persona',
              'Создал задачу «Хлеб»',
              '2026-11-03T10:00:01.000',
              extra: <String, Object?>{
                'task_id': 't1',
                'link': <String, Object?>{
                  'chat_id': 'task:t1',
                  'task_id': 't1',
                },
              },
            ),
            msg(
              'm4',
              'persona',
              'Отметка прихода',
              '2026-11-03T10:01:00.000',
              extra: <String, Object?>{'card': card.toJson()},
            ),
            msg(
              'm5',
              'persona',
              'Просрочена 1 задача',
              '2026-11-03T10:05:00.000',
            ),
          ];
      final mainMeta = <String, Object?>{
        'id': 'main',
        'kind': 'main',
        // Прежний «Главный» создавался при каждом запуске.
        'created_at': '2026-11-04T12:00:00.000',
        'last_activity_at': '2026-11-03T10:05:00.000',
        'unread': true,
        'count': messages.length,
      };
      final taskMeta = <String, Object?>{
        'id': 'task:t1',
        'kind': 'task',
        'task_id': 't1',
        'created_at': '2026-11-03T10:00:01.000',
        'last_activity_at': '2026-11-03T10:00:01.000',
        'count': 2,
      };
      File(p.join(dir.path, 'main.json')).writeAsStringSync(
        jsonEncode(<String, Object?>{
          'schema_version': 1,
          'chat': mainMeta,
          'messages': messages,
        }),
      );
      File(p.join(dir.path, 'task-t1.json')).writeAsStringSync(
        jsonEncode(<String, Object?>{
          'schema_version': 1,
          'chat': taskMeta,
          'messages': <Map<String, Object?>>[
            msg(
              'c1',
              'user',
              'Добавь задачу «Хлеб»',
              '2026-11-03T10:00:00.000',
            ),
            msg(
              'c2',
              'persona',
              'Создал задачу «Хлеб»',
              '2026-11-03T10:00:01.000',
              extra: <String, Object?>{
                'task_id': 't1',
                'link': <String, Object?>{
                  'chat_id': 'main',
                  'message_id': 'm3',
                },
              },
            ),
          ],
        }),
      );
      if (withIndex) {
        File(p.join(dir.path, 'index.json')).writeAsStringSync(
          jsonEncode(<String, Object?>{
            'schema_version': 1,
            'chats': mainFirst
                ? <Object?>[mainMeta, taskMeta]
                : <Object?>[taskMeta, mainMeta],
          }),
        );
      }
    }

    Future<ChatBook> open({String Function(String)? redact}) async {
      final b = ChatBook(
        store: JsonChatStore(chats(), debounce: Duration.zero),
        clock: clock,
        redactTitle: redact,
      );
      await b.load();
      await b.flush();
      return b;
    }

    test('«Главный» с командами — обычная сессия, ничего не потеряно',
        () async {
      writeLegacy();
      final b = await open();
      expect(
        b.threads.where((ChatThread t) => t.kind == ChatKind.main),
        isEmpty,
      );
      final s = b.thread(ChatThread.legacyMainSessionId)!;
      expect(s.kind, ChatKind.session);
      expect(s.title, 'Добавь задачу «Хлеб»');
      expect(
        s.messages.map((ChatMessage m) => m.id),
        <String>['m1', 'm2', 'm3', 'm4', 'm5'],
      );
      expect(s.messages[2].taskId, 't1');
      expect(s.messages[2].link!.chatId, 'task:t1');
      expect(s.messages[3].card!.rid, card.rid);
      expect(s.lastActivityAt, DateTime(2026, 11, 3, 10, 5));
      expect(s.createdAt, DateTime(2026, 11, 1, 9), reason: 'первое сообщение');
      expect(s.unread, isTrue);
      expect(b.current.id, isNot(s.id), reason: 'открыта новая пустая');
      expect(b.current.messageCount, 0);
      expect(b.sessions().map((ChatThread t) => t.id), contains(s.id));
      // Старые ссылки «main» ведут в перенесённую сессию.
      expect(b.resolve('main'), ChatThread.legacyMainSessionId);
      expect(b.thread('main'), same(s));

      expect(File(p.join(chats(), 'main.json')).existsSync(), isFalse);
      expect(
        File(p.join(chats(), 'archive', 'main.json')).existsSync(),
        isTrue,
        reason: 'копия старого файла — в архиве',
      );
      final file = File(p.join(chats(), 'session-main.json'));
      final decoded = jsonDecode(file.readAsStringSync()) as Map;
      expect(decoded['schema_version'], 1);
      final index =
          jsonDecode(File(p.join(chats(), 'index.json')).readAsStringSync())
              as Map;
      final ids = <Object?>[
        for (final row in index['chats'] as List) (row as Map)['id'],
      ];
      expect(ids, containsAll(<String>['session:main', 'task:t1']));
      expect(ids, isNot(contains('main')));

      // Перезапуск: без повторного переноса и дублей, то же содержимое.
      final again = await open();
      expect(
        again.threads
            .where((ChatThread t) => t.isSession && t.messageCount > 0),
        hasLength(1),
      );
      final restored = await again.open(ChatThread.legacyMainSessionId);
      expect(
        restored.messages.map((ChatMessage m) => m.id),
        <String>['m1', 'm2', 'm3', 'm4', 'm5'],
      );
      expect(restored.title, 'Добавь задачу «Хлеб»');
      final task = await again.openTask('t1');
      expect(again.resolve(task.messages.last.link!.chatId), restored.id);
    });

    test('порядок записей в index.json не важен', () async {
      writeLegacy(mainFirst: true);
      final b = await open();
      expect(b.thread(ChatThread.legacyMainSessionId), isNotNull);
      expect(b.taskThread('t1'), isNotNull);
    });

    test('«Главный» только с приветствием и напоминаниями — убран', () async {
      writeLegacy(
        mainMessages: <Map<String, Object?>>[
          msg('m1', 'persona', 'Я готов к работе.', '2026-11-01T09:00:00.000'),
          msg(
            'm2',
            'persona',
            'Просрочена 1 задача',
            '2026-11-02T09:00:00.000',
          ),
        ],
      );
      final b = await open();
      expect(b.thread(ChatThread.legacyMainSessionId), isNull);
      expect(b.resolve('main'), 'main');
      // Чат задачи — только копия команды и ответа: в меню его нет.
      expect(b.thread('task:t1'), isNotNull);
      expect(
        b.sessions().map((ChatThread t) => t.id),
        <String>[b.currentId],
      );
      expect(File(p.join(chats(), 'main.json')).existsSync(), isFalse);
      expect(File(p.join(chats(), 'session-main.json')).existsSync(), isFalse);
    });

    test('название из первой команды — без пароля', () async {
      writeLegacy(
        mainMessages: <Map<String, Object?>>[
          msg(
            'm1',
            'user',
            'пароль: CANARY-7f3e91aQ! запомни',
            '2026-11-01T09:00:00.000',
          ),
        ],
      );
      final b = await open(
        redact: (String text) => SecretGuard.redact(text).text,
      );
      final s = b.thread(ChatThread.legacyMainSessionId)!;
      expect(s.title, isNot(contains('CANARY')));
      expect(s.title, isNotEmpty);
      expect(
        File(p.join(chats(), 'index.json')).readAsStringSync(),
        isNot(contains('CANARY-7f3e91aQ')),
      );
    });

    test('пустое после очистки название — «Ранее»', () async {
      writeLegacy(
        mainMessages: <Map<String, Object?>>[
          msg('m1', 'user', '   ', '2026-11-01T09:00:00.000'),
        ],
      );
      final b = await open();
      expect(b.thread(ChatThread.legacyMainSessionId)!.title, 'Ранее');
    });

    test('сбой после записи сессии: её новые сообщения не затираются',
        () async {
      writeLegacy();
      final first = await open();
      first.append(
        ChatThread.legacyMainSessionId,
        _say(first, 'ещё команда', DateTime(2026, 11, 4, 9)),
      );
      await first.flush();
      // Как будто main.json не успел уйти в архив.
      writeLegacy();
      final index = File(p.join(chats(), 'index.json'));
      final rows =
          (jsonDecode(index.readAsStringSync()) as Map)['chats'] as List;
      final session = jsonDecode(
        File(p.join(chats(), 'session-main.json')).readAsStringSync(),
      ) as Map;
      rows.add(session['chat']);
      index.writeAsStringSync(
        jsonEncode(<String, Object?>{'schema_version': 1, 'chats': rows}),
      );

      final b = await open();
      final s = await b.open(ChatThread.legacyMainSessionId);
      expect(s.messages, hasLength(6));
      expect(s.messages.last.text, 'ещё команда');
      expect(File(p.join(chats(), 'main.json')).existsSync(), isFalse);
      expect(
        b.threads.where((ChatThread t) => t.isSession && t.messageCount > 0),
        hasLength(1),
      );
    });

    test('main.json повреждён или пропал — без сбоя, «Главный» убран',
        () async {
      writeLegacy();
      File(p.join(chats(), 'main.json')).writeAsStringSync('{не json');
      var b = await open();
      expect(b.thread(ChatThread.legacyMainSessionId), isNull);
      expect(b.taskThread('t1'), isNotNull);
      expect(b.current.isSession, isTrue);

      root.deleteSync(recursive: true);
      root.createSync();
      writeLegacy();
      File(p.join(chats(), 'main.json')).deleteSync();
      b = await open();
      expect(b.thread(ChatThread.legacyMainSessionId), isNull);
      expect(b.current.isSession, isTrue);
    });

    test('index.json потерян — пересобран по файлам и перенесён', () async {
      writeLegacy(withIndex: false);
      final b = await open();
      expect(
        b.thread(ChatThread.legacyMainSessionId)!.messages,
        hasLength(5),
      );
      expect(File(p.join(chats(), 'main.json')).existsSync(), isFalse);
    });

    test('запись сессии не удалась — main.json остаётся, перенос повторяется',
        () async {
      writeLegacy();
      // Атомарная запись session-main.json не проходит (как при полном
      // диске): на месте `.tmp` — папка.
      final blocker = Directory(p.join(chats(), 'session-main.json.tmp'))
        ..createSync();
      final first = await open();
      expect(
        first.thread(ChatThread.legacyMainSessionId)!.messages,
        hasLength(5),
        reason: 'в этом запуске история на месте',
      );
      expect(File(p.join(chats(), 'session-main.json')).existsSync(), isFalse);
      expect(
        File(p.join(chats(), 'main.json')).existsSync(),
        isTrue,
        reason: 'старый файл не в архиве, пока нет нового',
      );
      // Позже записался index.json со строкой session:main без файла.
      first.append(
        first.currentId,
        _say(first, 'другая команда', DateTime(2026, 11, 4, 9)),
      );
      await first.flush();
      expect(
        File(p.join(chats(), 'index.json')).readAsStringSync(),
        contains('session:main'),
      );

      blocker.deleteSync();
      final b = await open();
      final s = await b.open(ChatThread.legacyMainSessionId);
      expect(
        s.messages.map((ChatMessage m) => m.id),
        <String>['m1', 'm2', 'm3', 'm4', 'm5'],
      );
      expect(File(p.join(chats(), 'session-main.json')).existsSync(), isTrue);
      expect(File(p.join(chats(), 'main.json')).existsSync(), isFalse);
      expect(
        File(p.join(chats(), 'archive', 'main.json')).existsSync(),
        isTrue,
      );

      // И после ещё одного запуска история та же.
      final again = await open();
      expect(
        (await again.open(ChatThread.legacyMainSessionId)).messages,
        hasLength(5),
      );
    });

    test('в памяти: старый «Главный» переносится так же', () async {
      final memory = InMemoryChatStore();
      await memory.save(
        ChatThread(
          id: ChatThread.mainId,
          kind: ChatKind.main,
          createdAt: DateTime(2026, 11, 4, 12),
          messages: <ChatMessage>[
            ChatMessage(
              id: 'm1',
              author: ChatAuthor.user,
              text: 'Сверить накладные',
              timestamp: DateTime(2026, 11, 2, 9),
            ),
          ],
        ),
      );
      final b = ChatBook(store: memory, clock: clock);
      expect(await b.load(), isTrue);
      expect(memory.chatIds, <String>[ChatThread.legacyMainSessionId]);
      expect(memory.archivedIds, <String>[ChatThread.mainId]);
      expect(b.thread('main')!.title, 'Сверить накладные');
    });

    test('«Удалить» перенесённой сессии стирает и архив «Главного»', () async {
      final memory = InMemoryChatStore();
      await memory.save(
        ChatThread(
          id: ChatThread.mainId,
          kind: ChatKind.main,
          createdAt: DateTime(2026, 11, 4, 12),
          messages: <ChatMessage>[
            ChatMessage(
              id: 'm1',
              author: ChatAuthor.user,
              text: 'Сверить накладные',
              timestamp: DateTime(2026, 11, 2, 9),
            ),
          ],
        ),
      );
      final b = ChatBook(store: memory, clock: clock);
      await b.load();
      expect(memory.archivedIds, <String>[ChatThread.mainId]);
      await b.remove(ChatThread.legacyMainSessionId);
      await b.flush();
      expect(memory.chatIds, isEmpty);
      expect(memory.archivedIds, isEmpty, reason: 'переписки нет и в архиве');
      final again = ChatBook(store: memory, clock: clock);
      expect(await again.load(), isFalse);
      expect(again.thread(ChatThread.legacyMainSessionId), isNull);
    });

    test('то же на диске: archive/main.json не остаётся', () async {
      writeLegacy();
      final b = await open();
      final archived = File(p.join(chats(), 'archive', 'main.json'));
      expect(archived.existsSync(), isTrue);
      await b.remove(ChatThread.legacyMainSessionId);
      await b.flush();
      expect(archived.existsSync(), isFalse);
      expect(
        File(p.join(chats(), 'session-main.json')).existsSync(),
        isFalse,
      );
    });
  });

  group('действия с сессией', () {
    Future<(ChatBook, String)> session(String command) async {
      final b = await book();
      final id = b.currentId;
      b
        ..append(id, _say(b, command, clock.value))
        ..append(id, _say(b, 'Готово', clock.value, user: false));
      return (b, id);
    }

    test('переименовать: пробелы, лимит, пустое, своё название в поиске',
        () async {
      final (b, id) = await session('сверь приход 318');
      expect(b.rename(id, '  Приход\n  318   ноябрь '), isTrue);
      expect(b.thread(id)!.customTitle, 'Приход 318 ноябрь');
      expect(ChatBook.titleOf(b.thread(id)!), 'Приход 318 ноябрь');
      expect(b.rename(id, '   '), isFalse);
      expect(b.rename(id, 'я' * 61), isFalse);
      expect(b.rename(id, 'я' * 60), isTrue);
      expect(b.rename(id, 'Склад: сверка'), isTrue);
      final hits = await b.search('сверка');
      expect(hits.single.title, 'Склад: сверка');
      // То же, что первая команда, — своё название снимается.
      expect(b.rename(id, 'сверь приход 318'), isTrue);
      expect(b.thread(id)!.customTitle, isNull);
    });

    test('своё название и закрепление переживают перезапуск', () async {
      final (b, id) = await session('сверь приход 318');
      b
        ..rename(id, 'Приход 318')
        ..setPinned(id, true);
      await b.flush();
      final again = await book();
      final t = again.thread(id)!;
      expect(t.customTitle, 'Приход 318');
      expect(t.pinned, isTrue);
      expect(t.preview, 'Готово');
      expect(t.lastPersonaId, 'rio');
      expect(ChatBook.titleOf(t), 'Приход 318');
    });

    test('то же на диске: index.json и шапка файла', () async {
      final dir = await Directory.systemTemp.createTemp('book_actions_');
      addTearDown(() => dir.delete(recursive: true));
      final disk = JsonChatStore(dir.path, debounce: Duration.zero);
      final b = ChatBook(store: disk, clock: clock);
      await b.load();
      final id = b.currentId;
      b
        ..append(id, _say(b, 'сверь приход', clock.value))
        ..append(id, _say(b, 'Принят', clock.value, user: false));
      b
        ..rename(id, 'Приход')
        ..setPinned(id, true);
      await b.flush();
      final again = ChatBook(store: JsonChatStore(dir.path), clock: clock);
      await again.load();
      expect(again.thread(id)!.customTitle, 'Приход');
      expect(again.thread(id)!.pinned, isTrue);
      expect(again.thread(id)!.preview, 'Принят');
    });

    test('чат задачи и пустая сессия не переименовываются', () async {
      final b = await book();
      expect(b.rename(b.currentId, 'Пусто'), isFalse);
      expect(b.setPinned(b.currentId, true), isFalse);
      await b.openTask('t1');
      b.append('task:t1', _say(b, 'готово', clock.value));
      expect(b.rename('task:t1', 'Другое'), isFalse);
      expect(b.setPinned('task:t1', true), isTrue);
    });

    test('закреплённые: отдельно, последний закреплённый сверху', () async {
      final (b, first) = await session('первая');
      await b.newSession();
      final second = b.currentId;
      b.append(second, _say(b, 'вторая', clock.value));
      await b.newSession();
      b.setPinned(first, true);
      clock.value = clock.value.add(const Duration(minutes: 1));
      b.setPinned(second, true);
      expect(
        b.pinned().map((ChatThread t) => t.id),
        <String>[second, first],
      );
      final groups = b.groups(clock.value);
      expect(
        groups.pinned.map((ChatThread t) => t.id),
        <String>[second, first],
      );
      expect(
        groups.today.map((ChatThread t) => t.id),
        <String>[b.currentId],
        reason: 'закреплённые не повторяются, открытая пустая — на месте',
      );
      b.setPinned(first, false);
      expect(b.pinned().single.id, second);
      expect(b.groups(clock.value).today.map((t) => t.id), contains(first));
    });

    test('группы по местным датам: полночь и край недели', () {
      final now = DateTime(2026, 11, 12, 0, 5);
      expect(groupOf(DateTime(2026, 11, 12, 0, 1), now), SessionGroup.today);
      expect(
        groupOf(DateTime(2026, 11, 11, 23, 59), now),
        SessionGroup.yesterday,
      );
      expect(groupOf(DateTime(2026, 11, 10, 12), now), SessionGroup.week);
      expect(groupOf(DateTime(2026, 11, 6, 0, 1), now), SessionGroup.week);
      expect(groupOf(DateTime(2026, 11, 5, 23, 59), now), SessionGroup.earlier);
      expect(groupOf(DateTime(2025, 11, 12), now), SessionGroup.earlier);
      // Через переход на летнее/зимнее время — те же календарные дни.
      expect(
        groupOf(DateTime(2026, 3, 28, 23), DateTime(2026, 3, 30, 1)),
        SessionGroup.week,
      );
    });

    test('groups раскладывает сессии по дням активности', () async {
      final (b, today) = await session('сегодня');
      await b.newSession();
      final old = b.currentId;
      b.append(
        old,
        _say(b, 'давно', clock.value.subtract(const Duration(days: 9))),
      );
      b.thread(old)!.lastActivityAt =
          clock.value.subtract(const Duration(days: 9));
      await b.newSession();
      final groups = b.groups(clock.value);
      expect(groups.today.map((t) => t.id), containsAll(<String>[today]));
      expect(groups.earlier.map((t) => t.id), <String>[old]);
      expect(groups.yesterday, isEmpty);
      expect(groups.week, isEmpty);
    });

    test('удалить: из книги, хранилища и «назад»; задача остаётся', () async {
      final (b, id) = await session('сверь приход');
      await b.flush();
      await b.openTask('t1');
      b.append('task:t1', _say(b, 'по задаче', clock.value));
      await b.open(id);
      expect(await b.remove('task:t1'), isFalse);
      expect(b.taskThread('t1'), isNull);
      expect(store.chatIds, isNot(contains('task:t1')));
      // Открытый — удалён: открыта пустая сессия, «назад» не ведёт в него.
      expect(await b.remove(id), isTrue);
      expect(b.current.messageCount, 0);
      expect(b.current.isSession, isTrue);
      await b.back();
      expect(b.currentId, isNot(id));
      await b.flush();
      expect(store.chatIds, isEmpty);
      expect(store.archivedIds, isEmpty, reason: 'не в архив, а насовсем');
      // Чат задачи открывается снова — пустым, без старой истории.
      final again = await b.openTask('t1');
      expect(again.messages, isEmpty);
      final reload = await book();
      expect(reload.thread(id), isNull);
      expect(reload.taskThread('t1'), isNull);
    });

    test('удалить чат, пока он читается: запись не возвращает файл', () async {
      final (b, id) = await session('сверь приход');
      await b.flush();
      final again = await book();
      // Чат не прочитан: rename откладывает запись до чтения.
      expect(again.thread(id)!.loaded, isFalse);
      again.rename(id, 'Новое');
      final removing = again.remove(id);
      await removing;
      await again.flush();
      expect(store.chatIds, isEmpty);
      expect((await store.loadIndex()).map((t) => t.id), isNot(contains(id)));
    });

    test('превью: последний ответ, карточки и секреты — фразой', () async {
      final b = await book();
      final id = b.currentId;
      b.append(id, _say(b, 'покажи пароль', clock.value));
      expect(b.thread(id)!.preview, isNull, reason: 'команда — не превью');
      b.append(
        id,
        _say(b, 'Пароль от почты показан', clock.value, user: false),
        sensitive: true,
      );
      expect(b.thread(id)!.preview, 'Защищённая карточка');
      b.append(
        id,
        ChatMessage(
          id: b.newMessageId(),
          author: ChatAuthor.persona,
          personaId: 'noda',
          text: 'Пароль CANARY-5d2c',
          timestamp: clock.value,
          secureCard: const SecureCardRequest(kind: SecureCardKind.reveal),
        ),
      );
      expect(b.thread(id)!.preview, 'Защищённая карточка');
      expect(b.thread(id)!.lastPersonaId, 'noda');
      final reply = _say(b, 'Приход\nпринят', clock.value, user: false);
      b.append(id, reply);
      expect(b.thread(id)!.preview, 'Приход принят');
      expect(b.thread(id)!.lastPersonaId, 'rio');
      b.append(id, _say(b, 'спасибо', clock.value));
      expect(b.thread(id)!.preview, 'Приход принят');
      await b.flush();
      final index = (await store.loadIndex()).single;
      expect(index.preview, 'Приход принят');
      expect(jsonEncode(index.metaJson()), isNot(contains('CANARY')));
    });

    test('превью для чатов прежних версий — из файла, только в памяти',
        () async {
      final (b, id) = await session('сверь приход');
      await b.flush();
      // Как старый index.json: без превью.
      final legacy = ChatThread.fromMetaJson(
        b.thread(id)!.metaJson()
          ..remove('preview')
          ..remove('last_persona'),
      )!;
      expect(legacy.preview, isNull);
      final again = await book();
      again.thread(id)!
        ..preview = null
        ..lastPersonaId = null;
      final saves = store.saves;
      expect(await again.backfillPreviews(), isTrue);
      // Был ли старый ответ навыка с секретами, в файле не сказано: текст
      // не пересказывается, а знак ответившего восстанавливается.
      expect(again.thread(id)!.preview, isNull);
      expect(again.thread(id)!.lastPersonaId, 'rio');
      expect(again.thread(id)!.loaded, isFalse);
      expect(store.saves, saves, reason: 'без записи');
    });

    test('старый ответ навыка «Пароли» не попадает во вторую строку', () async {
      final (b, id) = await session('покажи пароль от почты');
      b.append(
        id,
        _say(
          b,
          'Пароль от «Почта-Синтетика» был показан.',
          clock.value,
          user: false,
        ),
      );
      await b.flush();
      final again = await book();
      again.thread(id)!
        ..preview = null
        ..lastPersonaId = null;
      await again.backfillPreviews();
      expect(again.thread(id)!.preview, isNull);
      expect(
        again.threads.map((ChatThread t) => t.preview ?? ''),
        isNot(contains(contains('Почта-Синтетика'))),
      );
    });

    test('старая карточка действия — нейтральная фраза', () async {
      final b = await book();
      final id = b.currentId;
      b
        ..append(id, _say(b, 'отметь приход', clock.value))
        ..append(
          id,
          ChatMessage(
            id: b.newMessageId(),
            author: ChatAuthor.persona,
            personaId: 'noda',
            text: 'Отметка',
            timestamp: clock.value,
            card: ActionCard(
              rid: 'dddddddddddddddd',
              connectorId: 'warehouse',
              kind: ActionKind.post,
              login: 'ivanov',
              name: 'Иван',
              deadline: clock.value.add(const Duration(minutes: 5)),
              lines: const <ActionCardLine>[],
              commit: const <String, Object?>{'a': 1},
              stamp: 'stamp',
            ),
          ),
        );
      await b.flush();
      final again = await book();
      again.thread(id)!.preview = null;
      expect(await again.backfillPreviews(), isTrue);
      expect(again.thread(id)!.preview, 'Карточка действия');
      expect(again.thread(id)!.lastPersonaId, 'noda');
    });

    test('длина названия — в видимых знаках, как у поля ввода', () async {
      final (b, id) = await session('сверь приход 318');
      expect(b.rename(id, '📦' * 31), isTrue, reason: '31 знак из 60');
      expect(b.thread(id)!.customTitle, '📦' * 31);
      expect(b.rename(id, '👍🏽' * 60), isTrue);
      expect(b.rename(id, '📦' * 61), isFalse);
      expect(ChatThread.cleanCustomTitle('📦' * 70), '📦' * 60);
      expect(ChatThread.titleLength('📦' * 70), 70);
    });
  });
}
