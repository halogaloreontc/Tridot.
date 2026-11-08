// Книга чатов (ADR-010): главный чат всегда есть, чат задачи создаётся
// лениво, «назад», удаление чатов удалённых задач, «не прочитано».
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/chats/chat_book.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
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
}
