import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/connectors/manifest/connection.dart';
import 'package:local_assistant/core/models/assistant_types.dart';
import 'package:local_assistant/web_widget/widget_session.dart';
import 'package:local_assistant/web_widget/widget_storage.dart';

import 'fakes.dart';

void main() {
  late FakeWarehouse server;
  late FakeHost host;
  late MemoryStorage storage;
  late WidgetSession session;

  WidgetSession make({String version = '1.0.0', bool embedded = true}) {
    host = FakeHost(embedded: embedded);
    return session = WidgetSession(
      host: host,
      transport: server,
      storage: storage,
      builtInManifest: builtInSource(),
      version: version,
      updateEvery: const Duration(hours: 1),
      keyWait: const Duration(seconds: 2),
    );
  }

  setUp(() {
    server = FakeWarehouse();
    storage = MemoryStorage();
  });

  tearDown(() => session.dispose());

  Future<void> open({Map<String, Object?>? init}) async {
    session.start();
    host.emit(init ?? initMessage());
    await settle();
  }

  test('не из склада — не ждёт входа и ничего не шлёт', () {
    make(embedded: false).start();
    expect(session.phase, WidgetPhase.standalone);
    expect(host.sent, isEmpty);
  });

  test('hello → init: вход ключом без пароля склада, «кто я»', () async {
    make();
    session.start();
    expect(host.types, <String>['hello']);
    expect(host.sent.single['version'], '1.0.0');
    host.emit(initMessage());
    await settle();
    expect(session.phase, WidgetPhase.ready, reason: session.problem);
    final record = session.service!.record;
    expect(record.level, ConnectionLevel.staff);
    expect(record.tokenless, isTrue);
    expect(record.scope, 'assist');
    expect(record.login, 'ivanov');
    expect(session.who, 'Иван Петров · Кладовщик');
    final me = server.requests.lastWhere(
      (r) => r.uri.queryParameters['action'] == 'ask_me',
    );
    expect(me.headers['X-Wh-Sid'], webSid);
    expect(me.headers.containsKey('X-Wh-Token'), isFalse);
    // Ключ — только в памяти, не в хранилище браузера.
    expect(storage.values.values.join(), isNot(contains(webSid)));
  });

  test('init без ключа — понятная ошибка', () async {
    make();
    await open(init: initMessage(sid: ''));
    expect(session.phase, WidgetPhase.failed);
    expect(session.problem, contains('ключ'));
  });

  test('вопрос складу и история в хранилище под логином', () async {
    make();
    server.on('ask_stock', 200, <String, Object?>{'ok': true, 'items': []});
    await open();
    await session.send('где лежит стул венский');
    expect(server.actions, contains('ask_stock'));
    final ask = server.requests.lastWhere(
      (r) => r.uri.queryParameters['action'] == 'ask_stock',
    );
    expect(ask.headers['X-Wh-Sid'], webSid);
    expect(session.messages, hasLength(2));
    expect(session.messages.first.author, ChatAuthor.user);
    expect(session.messages.last.personaId, 'sado');
    final saved = WidgetHistory(storage, 'ivanov').load();
    expect(saved.map((m) => m.text), contains('где лежит стул венский'));
  });

  test('справка склада без сети и без путей приложения', () async {
    make();
    await open();
    final before = server.requests.length;
    await session.send('что умеет склад');
    expect(server.requests.length, before);
    final reply = session.messages.last.text;
    expect(reply, isNotEmpty);
    expect(reply, isNot(contains('Мой Связной')));
  });

  test('ключ устарел: просит новый, повторяет вопрос один раз', () async {
    make();
    server
      ..on(
        'ask_stock',
        403,
        <String, Object?>{'error': 'Войдите', 'need': 'login'},
      )
      ..on('ask_stock', 200, <String, Object?>{'ok': true, 'items': []});
    await open();
    final sending = session.send('где лежит стул венский');
    await settle();
    expect(host.types, contains('need-key'));
    host.emit(<String, Object?>{'svz': 1, 'type': 'key', 'sid': webSid2});
    await sending;
    final asks = server.requests
        .where((r) => r.uri.queryParameters['action'] == 'ask_stock')
        .toList();
    expect(asks, hasLength(2));
    expect(asks.last.headers['X-Wh-Sid'], webSid2);
    expect(session.service!.record.failure, isNull);
    expect(session.messages, hasLength(2), reason: 'один вопрос — один ответ');
  });

  test('ключ не дали — ответ «вход устарел» без путей приложения', () async {
    make();
    server.on(
      'ask_stock',
      403,
      <String, Object?>{'error': 'Войдите', 'need': 'login'},
    );
    await open();
    final sending = session.send('где лежит стул венский');
    await settle();
    host.emit(<String, Object?>{'svz': 1, 'type': 'key', 'error': 'нет'});
    await sending;
    final text = session.messages.last.text;
    expect(text, contains('страницу склада'));
    expect(text, isNot(contains('Мой Связной')));
  });

  test('выход из склада: ключ, история и запись стёрты, без запросов',
      () async {
    make();
    server.on('ask_stock', 200, <String, Object?>{'ok': true, 'items': []});
    await open();
    await session.send('где лежит стул венский');
    final before = server.requests.length;
    host.emit(<String, Object?>{'svz': 1, 'type': 'logout'});
    await settle();
    expect(session.phase, WidgetPhase.loggedOut);
    expect(session.messages, isEmpty);
    expect(server.requests.length, before, reason: 'ключ уже погашен складом');
    expect(storage.values.keys.where((k) => k.startsWith('svz:')), isEmpty);
    expect(session.service!.connected, isFalse);
  });

  test('новая версия на складе: update-ready только без дела', () async {
    make();
    server.installed = '1.0.1';
    await open();
    expect(session.pendingUpdate, '1.0.1');
    expect(host.types, contains('update-ready'));
    expect(host.sent.last['version'], '1.0.1');

    // Пока поле ввода не пусто — молчит.
    host.sent.clear();
    server.installed = '1.0.2';
    session.draft = 'где ле';
    await session.checkUpdate();
    expect(host.types, isNot(contains('update-ready')));
    session.draft = '';
    expect(host.types, contains('update-ready'));
    expect(host.sent.last['version'], '1.0.2');
  });

  test('та же версия или сборка dev — не шлёт', () async {
    make();
    server.installed = '1.0.0';
    await open();
    expect(host.types, isNot(contains('update-ready')));
    session.dispose();
    make(version: 'dev');
    server.installed = '9.9.9';
    await open();
    expect(host.types, isNot(contains('update-ready')));
  });

  group('голос', () {
    Map<String, Object?> ev(int id, String kind, [String text = '']) =>
        <String, Object?>{
          'svz': 1,
          'type': 'voice-ev',
          'id': id,
          'ev': kind,
          'text': text,
        };

    test('в браузере кнопки нет и запросов к оболочке нет', () async {
      make();
      await open();
      expect(session.voice.showButton, isFalse);
      session.startVoice();
      expect(host.types, isNot(contains('voice')));
    });

    test('Android 12+: start → partial → final → вопрос складу', () async {
      make();
      server.on('ask_stock', 200, <String, Object?>{'ok': true, 'items': []});
      await open(
        init: initMessage(
          voice: <String, Object?>{'available': true, 'reason': 'ok'},
        ),
      );
      session.startVoice();
      expect(session.listening, isTrue);
      final start = host.sent.last;
      expect(start['type'], 'voice');
      expect(start['op'], 'start');
      final id = start['id']! as int;
      host
        ..emit(ev(id - 1, 'final', 'чужой запуск'))
        ..emit(ev(id, 'partial', 'где лежит'));
      await settle();
      expect(session.partial, 'где лежит');
      host.emit(ev(id, 'final', 'где лежит стул венский'));
      await settle();
      expect(session.listening, isFalse);
      expect(session.messages.first.text, 'где лежит стул венский');
      expect(server.actions, contains('ask_stock'));
    });

    test('«назад» во время распознавания — отмена, без него — закрыть',
        () async {
      make();
      await open(
        init: initMessage(
          voice: <String, Object?>{'available': true, 'reason': 'ok'},
        ),
      );
      session.startVoice();
      host.emit(<String, Object?>{'svz': 1, 'type': 'back'});
      await settle();
      expect(host.sent.last['op'], 'cancel');
      expect(session.listening, isFalse);
      host.emit(<String, Object?>{'svz': 1, 'type': 'back'});
      await settle();
      expect(host.sent.last['type'], 'close');
    });

    test('Android ниже 12 — подсказка про клавиатуру, без запуска', () async {
      make();
      await open(
        init: initMessage(
          voice: <String, Object?>{'available': false, 'reason': 'sdk'},
        ),
      );
      expect(session.voice.showButton, isTrue);
      session.startVoice();
      expect(session.voiceNote, contains('клавиатуре'));
      expect(host.types, isNot(contains('voice')));
    });

    test('Android 12+ без распознавания на устройстве — своя подсказка',
        () async {
      make();
      await open(
        init: initMessage(
          voice: <String, Object?>{'available': false, 'reason': 'no-ondevice'},
        ),
      );
      session.startVoice();
      expect(session.voiceNote, contains('без интернета'));
      expect(session.voiceNote, isNot(contains('Android 12')));
      expect(host.types, isNot(contains('voice')));
    });

    test('Escape: идёт распознавание — отмена, без него — закрыть', () async {
      make();
      await open(
        init: initMessage(
          voice: <String, Object?>{'available': true, 'reason': 'ok'},
        ),
      );
      session.startVoice();
      session.escape();
      expect(host.sent.last['op'], 'cancel');
      session.escape();
      expect(host.sent.last['type'], 'close');
    });

    test('нет русского — скачать', () async {
      make();
      await open(
        init: initMessage(
          voice: <String, Object?>{'available': false, 'reason': 'no-lang'},
        ),
      );
      session.startVoice();
      expect(host.sent.last['op'], 'download');
      expect(session.listening, isFalse);
    });

    test('ошибка распознавания — текст подсказки', () async {
      make();
      await open(
        init: initMessage(
          voice: <String, Object?>{'available': true, 'reason': 'ok'},
        ),
      );
      session.startVoice();
      final id = host.sent.last['id']! as int;
      host.emit(<String, Object?>{
        'svz': 1,
        'type': 'voice-ev',
        'id': id,
        'ev': 'error',
        'code': 'no-speech',
      });
      await settle();
      expect(session.listening, isFalse);
      expect(session.voiceNote, contains('Не расслышал'));
    });
  });

  test('новый чат: история стирается', () async {
    make();
    await open();
    await session.send('что умеет склад');
    expect(session.messages, isNotEmpty);
    session.newChat();
    expect(session.messages, isEmpty);
    expect(WidgetHistory(storage, 'ivanov').load(), isEmpty);
    expect(
      session.messages.where((m) => m.status == AssistantStatus.failed),
      isEmpty,
    );
  });

  test('строка карточки — позиция на странице склада', () async {
    make();
    await open();
    session.openWarehouseLink('sku', '67432');
    expect(host.types.last, 'open');
    expect(host.sent.last['hash'], '#/sku/67432');
    session.openWarehouseLink('cell', 'A-1');
    expect(host.sent.last['hash'], '');
  });

  test('«Открыть склад» и «Закрыть» — сообщения странице', () async {
    make();
    await open();
    session
      ..openWarehouse()
      ..close();
    expect(
      host.types.sublist(host.types.length - 2),
      <String>['open', 'close'],
    );
  });
}
