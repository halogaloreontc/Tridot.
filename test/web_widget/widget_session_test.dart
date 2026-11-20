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
    // Склад без личного хранилища: разговор — в кэше этого браузера.
    expect(session.synced, isFalse);
    final cached = storage.values.entries
        .where((e) => e.key.startsWith('svz:chat:ivanov:'))
        .map((e) => e.value)
        .join();
    expect(cached, contains('где лежит стул венский'));
    expect(server.actions.where((a) => a.startsWith('my_')), isEmpty);
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

  test('новый разговор: прежний остаётся в списке', () async {
    make();
    await open();
    await session.send('что умеет склад');
    expect(session.messages, isNotEmpty);
    final first = session.book!.currentId;
    await session.newChat();
    expect(session.messages, isEmpty);
    expect(session.book!.currentId, isNot(first));
    expect(session.book!.sessions().map((t) => t.id), contains(first));
    await session.openChat(first);
    expect(session.messages, hasLength(2));
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

  group('полный помощник: разговоры, проекты, задачи (ADR-038)', () {
    test('hello — договор 2 и что умеет помощник', () {
      make().start();
      expect(host.sent.single['api'], 2);
      expect(host.sent.single['caps'], contains('signal'));
      expect(host.sent.single['caps'], contains('open-chat'));
      expect(host.sent.single['caps'], contains('open-project'));
    });

    test('задача фразой: TasksConnector, чат задачи, на склад my_put',
        () async {
      server.withStore();
      make();
      await open();
      expect(session.synced, isTrue);
      expect(server.actions, contains('my_sync'));
      await session.send('добавь задачу проверить акт 12-26 завтра');
      await settle();
      expect(session.taskList, hasLength(1));
      final task = session.taskList.single;
      expect(task.title.toLowerCase(), contains('проверить акт'));
      expect(session.book!.taskThread(task.id), isNotNull);
      final puts = server.bodies('my_put');
      expect(
        puts
            .where((b) => b['type'] == 'task')
            .map((b) => (b['obj']! as Map)['id']),
        contains(task.id),
      );
      // Разговор — тоже на складе: завели и дописали сообщения.
      expect(server.actions, contains('my_chat_new'));
      expect(server.actions, contains('my_chat_append'));
      expect(host.sent.where((m) => m['type'] == 'changed'), isNotEmpty);

      // «Готово» в списке — правка по полям.
      await session.completeTask(task.id);
      await settle();
      final patch = server
          .bodies('my_patch')
          .where((b) => b['type'] == 'task' && b['id'] == task.id)
          .last;
      expect((patch['set']! as Map)['status'], 'done');
    });

    test('старый склад: my_* 401 — без хранилища, ключ не устарел', () async {
      server
        ..withStore()
        ..myOk = false
        ..on('my_sync', 401, <String, Object?>{'error': 'Неверный пароль'});
      make();
      await open();
      expect(session.phase, WidgetPhase.ready);
      expect(session.synced, isFalse);
      expect(session.service!.record.failure, isNull);
      expect(host.types, isNot(contains('need-key')));
      final before = server.actions.where((a) => a.startsWith('my_')).length;
      await session.send('что умеет склад');
      await settle();
      expect(
        server.actions.where((a) => a.startsWith('my_')).length,
        before,
        reason: 'хранилище выключено до конца сеанса',
      );
      expect(session.messages, hasLength(2));
    });

    test('переименовать, закрепить, в проект, удалить', () async {
      server.withStore();
      make();
      await open();
      await session.send('что умеет склад');
      final id = session.book!.currentId;
      expect(session.renameChat(id, 'Справка склада'), isTrue);
      session.pinChat(id, pinned: true);
      final project = session.createProject('Брак Ромашка')!;
      session.moveChat(id, project.id);
      await settle();
      expect(session.book!.thread(id)!.customTitle, 'Справка склада');
      expect(session.book!.pinned().map((t) => t.id), contains(id));
      expect(session.book!.sessionsOf(project.id).map((t) => t.id), [id]);
      expect(
        server.bodies('my_put').where((b) => b['type'] == 'project'),
        isNotEmpty,
      );
      final meta = server
          .bodies('my_patch')
          .where((b) => b['type'] == 'chat' && b['id'] == id)
          .last;
      expect((meta['set']! as Map)['project_id'], project.id);
      await session.deleteChat(id);
      await settle();
      expect(session.book!.thread(id), isNull);
      expect(
        server.bodies('my_del').map((b) => b['id']),
        contains(id),
      );
    });

    test('со склада: проекты, задачи и разговоры из my_sync', () async {
      server
        ..withStore()
        ..on('my_sync', 200, <String, Object?>{
          'ok': true,
          'epoch': 'e9',
          'rev': 3,
          'mark': 'm3',
          'full': true,
          'items': <Object?>[
            <String, Object?>{
              'type': 'project',
              'obj': <String, Object?>{
                'id': 'project:1_aa',
                'name': 'Брак Ромашка',
                'task_tag': 'брак',
                'created_at': '2026-11-01T10:00:00Z',
                'updated_at': '2026-11-01T10:00:00Z',
                'status': 'active',
                'rev': 1,
              },
            },
            <String, Object?>{
              'type': 'task',
              'obj': <String, Object?>{
                'id': 'task_1_0001',
                'title': 'Отгрузить брак фабрике',
                'description': '',
                'status': 'planned',
                'priority': 'normal',
                'due_at': '2026-11-01',
                'due_precision': 'date',
                'tags': <String>[],
                'project_id': 'project:1_aa',
                'created_at': '2026-11-01T10:00:00Z',
                'updated_at': '2026-11-01T10:00:00Z',
                'completed_at': null,
                'rev': 2,
              },
            },
            <String, Object?>{
              'type': 'chat',
              'obj': <String, Object?>{
                'id': 'session:5_bb',
                'kind': 'session',
                'title': 'Разговор со склада',
                'created_at': '2026-11-01T10:00:00Z',
                'last_activity_at': '2026-11-01T10:00:00Z',
                'count': 1,
                'u': 1,
                'rev': 3,
              },
            },
          ],
          'gone': <Object?>[],
          'next': 3,
          'more': false,
        })
        ..on('my_chat_msgs', 200, <String, Object?>{
          'ok': true,
          'messages': <Object?>[
            <String, Object?>{
              'id': 'm_srv_1',
              'author': 'user',
              'text': 'где лежит стул',
              'ts': '2026-11-01T10:00:00Z',
              'seq': 1,
              'u': 1,
            },
          ],
          'u': 1,
        });
      make();
      await open();
      final book = session.book!;
      expect(book.projects().single.name, 'Брак Ромашка');
      final task = session.taskList.single;
      expect(task.tags, contains('брак'), reason: 'проект склада → метка');
      expect(session.overdue(task), isTrue);
      expect(session.reminders.map((r) => r.title), contains(task.title));
      await session.openServerChat('session:5_bb');
      expect(session.messages.single.text, 'где лежит стул');
    });

    test('напоминание от склада: показать, «видел» на склад', () async {
      server.withStore(signals: true);
      make();
      await open();
      host.emit(<String, Object?>{
        'svz': 1,
        'type': 'signal',
        'v': 1,
        'reason': 'bell',
        'focus': 'act.answer:123-26:x',
        'items': <Object?>[
          <String, Object?>{
            'id': 'act.answer:123-26:x',
            'title': 'Получен ли ответ от фабрики по акту 123-26?',
            'text': 'Отправлен 20.10',
            'actions': <Object?>[
              <String, Object?>{
                'id': 'ask',
                'label': 'Спросить помощника',
                'ask': 'что умеет склад',
              },
              <String, Object?>{
                'id': 'snooze',
                'label': 'Отложить',
                'ack': <String, Object?>{'op': 'snooze'},
              },
            ],
          },
        ],
      });
      await settle();
      expect(session.reminders.first.title, contains('123-26'));
      final ack = server.bodies('my_signal_ack');
      expect(ack.single['op'], 'seen');
      final signal = session.reminders.first;
      await session.runReminder(signal, signal.actions.last);
      expect(server.bodies('my_signal_ack').last['op'], 'snooze');
      expect(session.reminders, isEmpty);
    });

    test('прежняя история браузера — на склад одним my_import', () async {
      server.withStore();
      WidgetHistory(storage, 'ivanov').save(<ChatMessage>[
        ChatMessage(
          id: 'm_old_1',
          author: ChatAuthor.user,
          text: 'старый вопрос',
          timestamp: DateTime(2026, 11),
        ),
      ]);
      make();
      await open();
      final imp = server.bodies('my_import').single;
      expect(imp['source'], 'svz:hist');
      expect(storage.values.containsKey('svz:hist:ivanov'), isFalse);
    });

    test('без склада прежняя история — разговором в кэше', () async {
      WidgetHistory(storage, 'ivanov').save(<ChatMessage>[
        ChatMessage(
          id: 'm_old_1',
          author: ChatAuthor.user,
          text: 'старый вопрос',
          timestamp: DateTime(2026, 11),
        ),
      ]);
      make();
      await open();
      final thread = session.book!.thread('session:imp_local');
      expect(thread, isNotNull);
      expect(storage.values.containsKey('svz:hist:ivanov'), isFalse);
    });

    test(
        'open-project: проект на экране, неизвестный — «Проекты»; удалили — '
        'тоже «Проекты»', () async {
      make();
      await open();
      final project = session.createProject('Брак Ромашка')!;
      host.emit(<String, Object?>{
        'svz': 1,
        'type': 'open-project',
        'id': project.id,
      });
      await settle();
      expect(session.view, WidgetView.project);
      expect(session.projectId, project.id);
      host.emit(<String, Object?>{
        'svz': 1,
        'type': 'open-project',
        'id': 'p_missing_000',
      });
      await settle();
      expect(session.view, WidgetView.projects);
      session.show(WidgetView.project, project: project.id);
      await session.deleteProject(project.id);
      expect(session.view, WidgetView.projects);
      expect(session.book!.project(project.id), isNull);
      // «Назад» склада с экрана — в разговор, из разговора — закрыть.
      host.emit(<String, Object?>{'svz': 1, 'type': 'back'});
      await settle();
      expect(session.view, WidgetView.chat);
      expect(host.types, isNot(contains('close')));
      host.emit(<String, Object?>{'svz': 1, 'type': 'back'});
      await settle();
      expect(host.types.last, 'close');
    });

    /// Склад с проектом из «В проект»: без метки, задача — по project_id.
    void serverProject({String status = 'active'}) {
      server
        ..withStore()
        ..on('my_sync', 200, <String, Object?>{
          'ok': true,
          'epoch': 'e9',
          'rev': 2,
          'mark': 'm2',
          'full': true,
          'items': <Object?>[
            <String, Object?>{
              'type': 'project',
              'obj': <String, Object?>{
                'id': 'project:2_cc',
                'name': 'Отгрузка 12-26',
                'created_at': '2026-11-01T10:00:00Z',
                'updated_at': '2026-11-01T10:00:00Z',
                'status': status,
                'rev': 1,
              },
            },
            <String, Object?>{
              'type': 'task',
              'obj': <String, Object?>{
                'id': 'task_2_0002',
                'title': 'Проверить отгрузку 12-26',
                'description': '',
                'status': 'planned',
                'priority': 'normal',
                'tags': <String>[],
                'project_id': 'project:2_cc',
                'created_at': '2026-11-01T10:00:00Z',
                'updated_at': '2026-11-01T10:00:00Z',
                'completed_at': null,
                'rev': 2,
              },
            },
          ],
          'gone': <Object?>[],
          'next': 2,
          'more': false,
        });
    }

    test('проект без метки: задачи по project_id склада', () async {
      serverProject();
      make();
      await open();
      final task = session.taskList.single;
      expect(task.tags, isEmpty);
      expect(session.projectOfTask(task), 'project:2_cc');
    });

    test('open-project сразу за init при медленной связи — не теряется',
        () async {
      serverProject();
      server.delay = const Duration(milliseconds: 5);
      make();
      session.start();
      host
        ..emit(initMessage())
        ..emit(<String, Object?>{
          'svz': 1,
          'type': 'open-project',
          'id': 'project:2_cc',
          'task': '',
        });
      for (var i = 0; i < 100 && session.view != WidgetView.project; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(session.phase, WidgetPhase.ready);
      expect(session.view, WidgetView.project);
      expect(session.projectId, 'project:2_cc');
      // Экран проекта ещё синхронизируется — дождаться до конца теста.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await settle();
    });

    test('open-project без проекта: задача — её разговор, нет — «Проекты»',
        () async {
      serverProject();
      make();
      await open();
      host.emit(<String, Object?>{
        'svz': 1,
        'type': 'open-project',
        'id': '',
        'task': 'task_2_0002',
      });
      await settle();
      expect(session.view, WidgetView.chat);
      expect(session.book!.current.taskId, 'task_2_0002');
      host.emit(<String, Object?>{
        'svz': 1,
        'type': 'open-project',
        'id': '',
        'task': '',
      });
      await settle();
      expect(session.view, WidgetView.projects);
    });

    test('правка задачи архивного проекта не выносит её из проекта', () async {
      serverProject(status: 'archived');
      make();
      await open();
      expect(session.book!.projects(), isEmpty);
      final task = session.taskList.single;
      await session.completeTask(task.id);
      await settle();
      final sent = <Map<String, Object?>>[
        ...server.bodies('my_patch'),
        ...server.bodies('my_put'),
      ].where((b) => b['id'] == task.id).toList();
      expect(sent, isNotEmpty);
      for (final b in sent) {
        final fields = (b['set'] ?? b['obj'])! as Map;
        expect(fields['project_id'], 'project:2_cc');
      }
    });

    test('удалить сессию — «Отменить» возвращает её из корзины склада',
        () async {
      server.withStore();
      make();
      await open();
      await session.send('где лежит стул');
      await settle();
      final id = session.book!.currentId;
      await session.deleteChat(id);
      await settle();
      expect(await session.undoDelete('chat', id), isTrue);
      final undel = server.bodies('my_undel').single;
      expect(undel['type'], 'chat');
      expect(undel['id'], id);
      expect(
        server.actions.indexOf('my_del'),
        lessThan(server.actions.indexOf('my_undel')),
        reason: 'сначала удаление дошло до склада',
      );
    });

    test('метка задач проекта: занятая другим проектом — отказ', () async {
      make();
      await open();
      final a = session.createProject('Ромашка')!;
      final b = session.createProject('Лютик')!;
      expect(session.tagProject(a.id, 'romashka'), isTrue);
      expect(session.tagProject(b.id, 'romashka'), isFalse);
      session.describeProject(b.id, 'Лютик и Ко', 'Поставщик');
      expect(session.book!.project(b.id)!.name, 'Лютик и Ко');
      expect(session.book!.project(b.id)!.description, 'Поставщик');
    });
  });
}
