import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/manifest/connection.dart';
import 'package:local_assistant/core/connectors/manifest/connection_service.dart';
import 'package:local_assistant/core/connectors/manifest/connection_slots.dart';
import 'package:local_assistant/core/connectors/manifest/description_authority.dart';
import 'package:local_assistant/core/connectors/manifest/manifest_connector.dart';
import 'package:local_assistant/core/connectors/manifest/manifest_format.dart';
import 'package:local_assistant/core/connectors/manifest/warehouse_signals.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/models/warehouse_card.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import 'fixtures.dart';

/// Заведомо поддельные значения: настоящих секретов в тестах нет.
const String fakeToken = 'fake-token-not-real';
const String fakeSid = 'fake-sid-not-real';
const String code = '0123456789abcdef0123456789abcdef';

final DateTime now = DateTime(2026, 11, 15, 14, 5);

/// Склад DepotDesk 1.4.62 по сценарию: ответы по `?action=`, запросы
/// запоминаются.
final class _Server implements HttpTransport {
  final Map<String, List<(int, Object?)>> script =
      <String, List<(int, Object?)>>{};
  final List<HttpRequestData> requests = <HttpRequestData>[];
  String manifest = manifestSource(builtInManifestPath);

  void on(String action, int status, Object? json) =>
      (script[action] ??= <(int, Object?)>[]).add((status, json));

  List<String> get actions => <String>[
        for (final r in requests)
          if (!r.uri.path.endsWith('assistant.json'))
            r.uri.queryParameters['action'] ?? '',
      ];

  Map<String, Object?> bodyOf(String action) {
    final r = requests.lastWhere(
      (HttpRequestData r) => r.uri.queryParameters['action'] == action,
    );
    return jsonDecode(r.body ?? '{}') as Map<String, Object?>;
  }

  @override
  Future<HttpResponseData> send(HttpRequestData request) async {
    requests.add(request);
    if (request.uri.path.endsWith('assistant.json')) {
      return HttpResponseData(statusCode: 200, body: manifest);
    }
    final action = request.uri.queryParameters['action'] ?? '';
    final queue = script[action];
    if (queue == null || queue.isEmpty) {
      return HttpResponseData(
        statusCode: 400,
        body: jsonEncode(<String, Object?>{'error': 'Неизвестное действие'}),
      );
    }
    final (status, json) = queue.removeAt(0);
    return HttpResponseData(statusCode: status, body: jsonEncode(json));
  }
}

final class _Setup {
  _Setup({
    ConnectionRecord? record,
    bool connected = true,
    String? allowed,
  }) {
    final clock = FixedClock(now);
    secrets = InMemorySecretStore(<String, String>{
      if (connected) 'warehouse.token': fakeToken,
      if (connected) 'warehouse.sid': fakeSid,
    });
    final builtIn = builtInManifest(builtInManifestPath);
    warehouse = ManifestConnector(
      slot: ConnectionSlots.warehouse,
      description: builtIn,
      transport: server,
      secrets: secrets,
      record: connected ? record ?? connectedRecord() : null,
      builtIn: builtIn,
    );
    service = ConnectionService(
      connector: warehouse,
      transport: server,
      secrets: secrets,
      store: store,
      clock: clock,
      builtIn: builtIn,
      device: 'Связной · Android',
    );
    final tasks = TaskService(
      repository: InMemoryTaskRepository(),
      clock: clock,
    );
    final registry = ExtensionRegistry(
      connectors: <Connector>[
        TasksConnector(
          taskService: tasks,
          parser: ScenarioParser(clock: clock),
        ),
        warehouse,
        TalkConnector(taskService: tasks),
      ],
      choice: ExtensionChoice(
        enabledRoles: const <String>{Roles.storekeeperId},
        roleActions: <String, String>{
          if (allowed != null) Roles.storekeeperId: allowed,
        },
      ),
    );
    assistant = AssistantController(extensions: registry, clock: clock);
  }

  final _Server server = _Server();
  final InMemoryConnectionStore store = InMemoryConnectionStore();
  late final InMemorySecretStore secrets;
  late final ManifestConnector warehouse;
  late final ConnectionService service;
  late final AssistantController assistant;

  Future<AssistantResponse> say(String text) => assistant.handle(text);
}

String connectLink([String base = 'https://warehouse.example/']) =>
    'tridot://connect?u=${Uri.encodeComponent(base)}&qr=$code';

void main() {
  group('встроенное описание DepotDesk 1.4.62 (ADR-031)', () {
    final builtIn = builtInManifest(builtInManifestPath);

    test('app.id depotdesk и прежний halowarekeep — одно приложение', () {
      expect(builtIn.appId, 'depotdesk');
      expect(builtIn.version, '1.4.62');
      expect(ConnectionSlots.warehouse.acceptsApp('depotdesk'), isTrue);
      expect(ConnectionSlots.warehouse.acceptsApp('halowarekeep'), isTrue);
      expect(ConnectionSlots.warehouse.acceptsApp('expeora'), isFalse);
      // Чужое приложение не принято.
      final json = jsonDecode(manifestSource(builtInManifestPath))
          as Map<String, Object?>;
      (json['app']! as Map<String, Object?>)['id'] = 'shop';
      expect(
        ManifestDescription.check(
          json,
          appIds: ConnectionSlots.warehouse.appIds,
        ),
        contains(contains('app.id')),
      );
    });

    test('ключ помощника, выход auth_out, «кто я» — из описания', () {
      expect(builtIn.qr!.body, <String, String>{'scope': 'assist'});
      expect(builtIn.qr!.device, 'device');
      expect(builtIn.credentials['sid']!.get!.body['scope'], 'assist');
      expect(builtIn.signOut!.action, 'auth_out');
      expect(builtIn.logout!.action, 'sess_end');
      expect(builtIn.me!.action, 'ask_me');
      expect(builtIn.only, containsAll(<String>['ask_me', 'ask_price']));
    });

    test('сервер той же версии (app.id depotdesk) — в работе встроенное', () {
      final server = manifest(builtInManifestPath);
      final pick = DescriptionAuthority.choose(
        builtIn: builtIn,
        server: server,
      );
      // Та же версия — в работе встроенное.
      expect(pick.origin, DescriptionOrigin.builtIn);
    });

    test('постоянные поля входа — только scope «assist»', () {
      Map<String, Object?> json() =>
          jsonDecode(manifestSource(builtInManifestPath))
              as Map<String, Object?>;
      Map<String, Object?> auth(Map<String, Object?> j) =>
          j['auth']! as Map<String, Object?>;
      final wide = json();
      ((auth(wide)['qr']! as Map<String, Object?>)['body']!
          as Map<String, Object?>)['scope'] = 'app';
      expect(
        ManifestDescription.check(wide),
        contains(contains('auth.qr.body.scope')),
      );
      final login = json();
      ((((auth(login)['credentials']! as Map<String, Object?>)['sid']!
              as Map<String, Object?>)['get']! as Map<String, Object?>)['body']!
          as Map<String, Object?>)['role'] = 'admin';
      expect(
        ManifestDescription.check(login),
        contains(contains('body.role')),
      );
      final drop = json();
      (((auth(drop)['credentials']! as Map<String, Object?>)['sid']!
              as Map<String, Object?>)['drop']!
          as Map<String, Object?>)['action'] = 'user_delete';
      expect(
        ManifestDescription.check(drop),
        contains(contains('drop.action: действие «user_delete»')),
      );
      final me = json();
      (auth(me)['me']! as Map<String, Object?>)['action'] = 'act_move';
      expect(
        ManifestDescription.check(me),
        contains(contains('auth.me.action')),
      );
    });

    test('сервер с другим телом входа по ссылке шире — отвергнут', () {
      final json = jsonDecode(manifestSource(builtInManifestPath))
          as Map<String, Object?>;
      json['version'] = '1.4.70';
      ((json['auth']! as Map<String, Object?>)['qr']! as Map<String, Object?>)
          .remove('body');
      final server = ManifestDescription.parse(
        jsonEncode(json),
        appIds: ConnectionSlots.warehouse.appIds,
      );
      final pick = DescriptionAuthority.choose(
        builtIn: builtIn,
        server: server,
      );
      expect(pick.origin, DescriptionOrigin.builtIn);
      expect(pick.refused, contains('auth.qr'));
    });
  });

  group('ссылка «Открыть в Tridot»', () {
    test('годная: адрес из u, код, пометка помощника', () {
      final link = ConnectionService.parseQrLink(
        connectLink('https://Warehouse.Example/wh/'),
      );
      expect(link.base.toString(), 'https://warehouse.example/wh/');
      expect(link.code, code);
      expect(link.toString(), isNot(contains(code)));
      expect(
        ConnectionService.parseQrLink(
          '${connectLink('http://192.168.1.5/')}&for=assist',
        ).base.toString(),
        'http://192.168.1.5/',
      );
    });

    test('плохие — отказ без кода в тексте', () {
      final u = Uri.encodeComponent('https://warehouse.example/');
      for (final bad in <String>[
        'tridot://other?u=$u&qr=$code',
        'tridot://connect/path?u=$u&qr=$code',
        'tridot://user@connect?u=$u&qr=$code',
        'tridot://connect:9?u=$u&qr=$code',
        'tridot://connect?u=$u&qr=$code#x',
        'tridot://connect?u=$u&qr=$code&x=1',
        'tridot://connect?u=$u&qr=$code&qr=$code',
        'tridot://connect?u=$u&qr=${code.toUpperCase()}',
        'tridot://connect?u=$u&qr=123',
        'tridot://connect?u=$u&qr=$code&for=app',
        'tridot://connect?qr=$code',
        'tridot://connect?u=${Uri.encodeComponent('warehouse.example')}&qr=$code',
        'tridot://connect?u=${Uri.encodeComponent('http://warehouse.example/')}&qr=$code',
        'tridot://connect?u=${Uri.encodeComponent('ftp://warehouse.example/')}&qr=$code',
        'tridot://connect?u=${Uri.encodeComponent('https://warehouse.example/?a=1')}&qr=$code',
        'tridot://connect?u=${Uri.encodeComponent('https://warehouse.example/#qr=1')}&qr=$code',
        'tridot://connect?u=${Uri.encodeComponent('https://a:b@warehouse.example/')}&qr=$code',
        'tridot://connect?u=$u&qr=$code${' ' * 3}x',
        'tridot://connect?u=$u&qr=$code&pad=${'a' * 3000}',
      ]) {
        expect(
          () => ConnectionService.parseQrLink(bad),
          throwsA(
            isA<ConnectionAddressException>().having(
              (ConnectionAddressException e) => e.message,
              'message',
              isNot(contains(code)),
            ),
          ),
          reason: bad,
        );
      }
    });
  });

  group('вход по QR: ключ только для помощника', () {
    test('шлёт scope и название устройства; запись — без секретов', () async {
      final s = _Setup(connected: false);
      s.server
        ..on('qr_take', 200, <String, Object?>{
          'ok': true,
          'token': fakeToken,
          'sid': fakeSid,
          'login': 'ivanov',
          'scope': 'assist',
          'name': 'Иван Петров',
        })
        ..on('ask_me', 200, <String, Object?>{
          'ok': true,
          'login': 'ivanov',
          'name': 'Иван Петров',
          'role': 'store',
          'roleLabel': 'Кладовщик',
          'all': false,
          'perms': <String>['moves'],
          'can': <Object?>[
            <String, Object?>{
              'id': 'act_move',
              'title': 'Переносить товар между ячейками',
            },
          ],
          'actions': true,
        });
      final result = await s.service.connectByLink(connectLink());
      expect(result.ok, isTrue, reason: result.message);
      expect(
        result.message,
        'Склад подключён: ivanov (Иван Петров, Кладовщик).',
      );
      expect(s.server.bodyOf('qr_take'), <String, Object?>{
        'scope': 'assist',
        'device': 'Связной · Android',
        'code': code,
      });
      // «Кто я» — с паролем и ключом, пустым телом.
      final me = s.server.requests.last;
      expect(me.headers['X-Wh-Sid'], fakeSid);
      final record = s.service.record;
      expect(record.assistKey, isTrue);
      expect(record.me.name, 'Иван Петров');
      expect(record.me.role, 'Кладовщик');
      expect(record.me.perms, <String>['moves']);
      expect(record.me.has('moves'), isTrue);
      expect(record.me.has('post'), isFalse);
      expect(record.me.can, <String>['Переносить товар между ячейками']);
      final saved = s.store.records.values.join();
      expect(saved, contains('"scope":"assist"'));
      expect(saved, contains('Кладовщик'));
      for (final secret in <String>[fakeToken, fakeSid, code]) {
        expect(saved, isNot(contains(secret)));
      }
      // После перезапуска — то же.
      final back = ConnectionRecord.fromJson(
        'halowarekeep',
        jsonDecode(s.store.records.values.single),
      );
      expect(back.me.perms, <String>['moves']);
      expect(back.scope, 'assist');
    });

    test('склад старше 1.4.62 поле scope не знает — ключ полный', () async {
      final s = _Setup(connected: false);
      s.server.on('qr_take', 200, <String, Object?>{
        'ok': true,
        'token': fakeToken,
        'sid': fakeSid,
        'login': 'ivanov',
      });
      final result = await s.service.connectByLink(connectLink());
      expect(result.ok, isTrue);
      expect(s.service.record.assistKey, isFalse);
      // «Кто я» склад не знает: 400 — подключение остаётся.
      expect(s.service.connected, isTrue);
      expect(s.service.record.me.known, isFalse);
    });

    test('склад без пароля для помощника (tokenless): только личный ключ',
        () async {
      final s = _Setup(connected: false);
      s.server
        ..on('qr_take', 200, <String, Object?>{
          'ok': true,
          'sid': fakeSid,
          'login': 'ivanov',
          'scope': 'assist',
          'tokenless': true,
        })
        ..on('ask_me', 200, <String, Object?>{
          'ok': true,
          'login': 'ivanov',
          'all': true,
        })
        ..on('ask_stock', 200, <String, Object?>{'ok': true, 'items': []});
      final result = await s.service.connectByLink(connectLink());
      expect(result.ok, isTrue, reason: result.message);
      expect(await s.secrets.read('warehouse.token'), isNull);
      expect(await s.secrets.read('warehouse.sid'), fakeSid);
      final record = s.service.record;
      expect(record.tokenless, isTrue);
      expect(record.level, ConnectionLevel.staff);
      final me = s.server.requests.last;
      expect(me.headers.containsKey('X-Wh-Token'), isFalse);
      expect(me.headers['X-Wh-Sid'], fakeSid);
      // Вопрос складу — тоже без пароля склада, с ключом.
      await s.say('где лежит стул венский');
      final ask = s.server.requests.last;
      expect(ask.uri.queryParameters['action'], 'ask_stock');
      expect(ask.headers.containsKey('X-Wh-Token'), isFalse);
      expect(ask.headers['X-Wh-Sid'], fakeSid);
      final back = ConnectionRecord.fromJson(
        'depotdesk',
        jsonDecode(s.store.records.values.single),
      );
      expect(back.tokenless, isTrue);
    });

    test('без пароля склада и не ключ помощника — отказ', () async {
      final s = _Setup(connected: false);
      s.server.on('qr_take', 200, <String, Object?>{
        'ok': true,
        'sid': fakeSid,
        'login': 'ivanov',
      });
      final result = await s.service.connectByLink(connectLink());
      expect(result.ok, isFalse);
      expect(s.service.connected, isFalse);
    });

    test('новый QR заменяет вход: прежний ключ снят на складе', () async {
      const newSid = 'fake-sid-new-not-real';
      final s = _Setup();
      s.server
        ..on('auth_out', 200, <String, Object?>{'ok': true, 'out': true})
        ..on('qr_take', 200, <String, Object?>{
          'ok': true,
          'sid': newSid,
          'login': 'ivanov',
          'scope': 'assist',
          'tokenless': true,
        });
      final result = await s.service.connectByLink(
        connectLink('https://other-warehouse.example/'),
      );
      expect(result.ok, isTrue, reason: result.message);
      final out = s.server.requests.firstWhere(
        (HttpRequestData r) => r.uri.queryParameters['action'] == 'auth_out',
      );
      // Прежний ключ — на прежний склад, со своими ключами.
      expect(out.uri.host, 'warehouse.example');
      expect(out.headers['X-Wh-Sid'], fakeSid);
      expect(await s.secrets.read('warehouse.sid'), newSid);
      expect(await s.secrets.read('warehouse.token'), isNull);
      expect(s.service.record.baseUri!.host, 'other-warehouse.example');
    });

    test('вход по логину: склад сказал tokenless — пароль склада не хранится',
        () async {
      final s = _Setup(connected: false);
      s.server
        ..on('ask_stock', 200, <String, Object?>{'ok': true, 'items': []})
        ..on('auth_check', 200, <String, Object?>{
          'ok': true,
          'known': true,
          'sid': fakeSid,
          'scope': 'assist',
          'tokenless': true,
        });
      final result = await s.service.connectManual(
        address: 'warehouse.example',
        password: fakeToken,
        login: 'ivanov',
        pass: 'test-pass',
      );
      expect(result.ok, isTrue, reason: result.message);
      expect(await s.secrets.read('warehouse.token'), isNull);
      expect(s.service.record.tokenless, isTrue);
      expect(s.service.record.assistKey, isTrue);
    });

    test('выход: auth_out с ключом, ключи удалены', () async {
      final s = _Setup();
      s.server.on('auth_out', 200, <String, Object?>{'ok': true, 'out': true});
      await s.service.logout();
      expect(s.server.actions, <String>['auth_out']);
      expect(s.server.requests.single.headers['X-Wh-Sid'], fakeSid);
      expect(await s.secrets.read('warehouse.sid'), isNull);
      expect(s.service.connected, isFalse);
    });

    test('выход: склад без auth_out (400) — на устройстве всё равно', () async {
      final s = _Setup();
      await s.service.logout();
      expect(s.server.actions, <String>['auth_out']);
      expect(await s.secrets.read('warehouse.token'), isNull);
    });

    test('вход по логину: scope assist в теле auth_check', () async {
      final s = _Setup(connected: false);
      s.server
        ..on('ask_stock', 200, <String, Object?>{'ok': true, 'items': []})
        ..on('auth_check', 200, <String, Object?>{
          'ok': true,
          'known': true,
          'sid': fakeSid,
        });
      final result = await s.service.connectManual(
        address: 'warehouse.example',
        password: fakeToken,
        login: 'Ivanov',
        pass: 'test-pass',
      );
      expect(result.ok, isTrue, reason: result.message);
      expect(s.server.bodyOf('auth_check'), <String, Object?>{
        'login': 'Ivanov',
        'pass': 'test-pass',
        'scope': 'assist',
      });
    });
  });

  group('ответы и отказы', () {
    test('«где лежит» — карточка: строки и ячейки', () async {
      final s = _Setup();
      s.server.on('ask_stock', 200, <String, Object?>{
        'ok': true,
        'q': '64115',
        'count': 1,
        'qty': 7,
        'items': <Object?>[
          <String, Object?>{
            'sku': '64115',
            'name': 'Стул венский',
            'qty': 7,
            'cells': <Object?>[
              <String, Object?>{
                'cell': '215-1-1-1',
                'clsLabel': 'годен',
                'qty': 5,
              },
              <String, Object?>{'cell': '215-3-2-1', 'clsLabel': '', 'qty': 2},
            ],
          },
        ],
        'more': false,
      });
      final r = await s.say('где лежит 64115');
      final card = r.warehouse!;
      expect(card.command, 'where');
      expect(card.title, 'Где лежит товар');
      expect(card.rows.single.title, '64115');
      expect(card.rows.single.badge, '7 шт.');
      expect(card.rows.single.linkKind, 'sku');
      expect(card.rows.single.rows.first.title, '215-1-1-1');
      expect(card.rows.single.rows.first.linkKind, 'cell');
      // Текст остаётся для голоса и истории.
      expect(r.message, contains('215-1-1-1'));
      // В истории — без адреса склада и без ключей.
      final message = ChatMessage(
        id: 'm_1',
        author: ChatAuthor.persona,
        text: r.message,
        timestamp: now,
        warehouse: card,
      );
      final json = jsonEncode(message.toJson());
      expect(json, isNot(contains('warehouse.example')));
      expect(json, isNot(contains(fakeSid)));
      final back = ChatMessage.fromJson(jsonDecode(json))!;
      expect(back.warehouse!.rows.single.rows, hasLength(2));
    });

    test('битая карточка в истории — сообщение без неё', () {
      expect(WarehouseCard.fromJson(<String, Object?>{'command': 1}), isNull);
      final card = WarehouseCard.fromJson(<String, Object?>{
        'connector': 'warehouse',
        'command': 'where',
        'title': 'x\u202e${'y' * 300}',
        'say': 'ok',
        'rows': <Object?>[
          <String, Object?>{'title': 'a', 'link_kind': 'javascript'},
        ],
      })!;
      expect(card.title.length, WarehouseCard.maxText);
      expect(card.title, isNot(contains('\u202e')));
      expect(card.rows.single.linkKind, isEmpty);
    });

    test('цена: склад без ask_price — запись каталога «price»', () async {
      final s = _Setup();
      final r = await s.say('сколько стоит 64115');
      expect(s.server.actions, <String>['ask_price']);
      expect(r.replyId, 'warehouse.price');
    });

    test('цена со склада: ask_price', () async {
      final s = _Setup();
      s.server.on('ask_price', 200, <String, Object?>{
        'ok': true,
        'q': '64115',
        'count': 1,
        'costShown': false,
        'items': <Object?>[
          <String, Object?>{
            'sku': '64115',
            'name': 'Стул',
            'qty': 2,
            'price': 1500,
          },
        ],
      });
      final r = await s.say('сколько стоит 64115');
      expect(r.replyId, 'warehouse.answer');
      expect(r.warehouse!.rows.single.badge, '1 500 ₽');
    });

    test('«кто я» — роль и что можно', () async {
      final s = _Setup();
      s.server.on('ask_me', 200, <String, Object?>{
        'ok': true,
        'login': 'ivanov',
        'name': 'Иван Петров',
        'roleLabel': 'Кладовщик',
        'all': false,
        'perms': <String>['moves'],
        'can': <Object?>[
          <String, Object?>{'title': 'Переносить товар между ячейками'},
        ],
      });
      final r = await s.say('кто я');
      expect(r.intent, 'warehouse.me');
      expect(r.message, contains('Иван Петров (ivanov)'));
      expect(r.message, contains('«Кладовщик»'));
      expect(r.message, contains('Переносить товар'));
    });

    test('«не проведено» — нет SV · нет 1С из полей сервера', () async {
      final s = _Setup();
      s.server.on('ask_unposted', 200, <String, Object?>{
        'ok': true,
        'days': 30,
        'count': 1,
        'qty': 4,
        'items': <Object?>[
          <String, Object?>{
            'id': 'e1',
            'no': '318-26',
            'kindLabel': 'Возврат',
            'day': '2026-11-05',
            'buyer': 'ООО Ромашка',
            'sv': true,
            'odin_c': false,
            'positions': 2,
            'qty': 4,
          },
        ],
      });
      final r = await s.say('что не проведено');
      final row = r.warehouse!.rows.single;
      expect(row.note, 'нет 1С');
      expect(row.badge, '2 позиции · 4 шт.');
    });

    for (final (need, reply) in <(String, String)>[
      ('perm', 'warehouse.auth.perm'),
      ('off', 'warehouse.auth.off'),
      ('role', 'warehouse.auth.role'),
    ]) {
      test('403 need:$need → $reply', () async {
        final s = _Setup();
        s.server.on('ask_arrivals', 403, <String, Object?>{
          'error': 'нет',
          'need': need,
        });
        final r = await s.say('что пришло сегодня');
        expect(r.replyId, reply);
      });
    }

    test('ключ устарел (403 need:login с ключом) — «войти снова»', () async {
      final s = _Setup();
      s.server.on('ask_arrivals', 403, <String, Object?>{
        'error': 'нет',
        'need': 'login',
      });
      final r = await s.say('что пришло сегодня');
      expect(r.replyId, 'warehouse.auth.expired');
      expect(r.message, contains('Помощники → Роли → Кладовщик'));
    });

    test('склад без ask_unposted — «склад пока не умеет»', () async {
      final s = _Setup();
      final r = await s.say('что не проведено');
      expect(r.replyId, 'warehouse.unsupported');
      expect(r.message, contains('что не проведено'));
    });
  });

  group('перемещение: откуда и права', () {
    test('без «откуда» — вопрос без сервера, ответ — расчёт с from', () async {
      final s = _Setup(allowed: 'ivanov');
      final asked = await s.say('перемести 3 венских стула в 215-3-2-1');
      expect(asked.replyId, 'warehouse.act.ask.from');
      expect(s.server.actions, isEmpty);
      s.server.on('act_move_check', 422, <String, Object?>{
        'error': 'нет',
        'code': 'short',
        'from': '215-1-1-1',
        'have': 1,
      });
      final next = await s.say('из 215-1-1-1');
      expect(next.replyId, 'warehouse.act.short');
      expect(s.server.bodyOf('act_move_check')['from'], '215-1-1-1');
      expect(s.server.bodyOf('act_move_check')['to'], '215-3-2-1');
    });

    test('права известны и права нет — «нет права» без запроса', () async {
      final s = _Setup(
        allowed: 'ivanov',
        record: connectedRecord().copyWith(
          me: ConnectionMe(perms: const <String>['price'], at: now),
        ),
      );
      final r = await s.say(
        'перемести 3 венских стула из 215-1-1-1 в 215-3-2-1',
      );
      expect(r.replyId, 'warehouse.act.denied');
      expect(r.message, contains('перемещать товар'));
      expect(s.server.actions, isEmpty);
    });

    test('действия выключены на складе — сразу «выключены»', () async {
      final s = _Setup(
        allowed: 'ivanov',
        record: connectedRecord().copyWith(
          me: ConnectionMe(all: true, actions: false, at: now),
        ),
      );
      final r = await s.say('проведи приход 318');
      expect(r.replyId, 'warehouse.act.serverOff');
      expect(s.server.actions, isEmpty);
    });

    test('права запомнены давно — решает склад: действия уже включили',
        () async {
      final s = _Setup(
        allowed: 'ivanov',
        record: connectedRecord().copyWith(
          me: ConnectionMe(
            all: true,
            actions: false,
            at: now.subtract(const Duration(hours: 1)),
          ),
        ),
      );
      final r = await s.say('проведи приход 318');
      expect(r.replyId, isNot('warehouse.act.serverOff'));
      expect(s.server.actions, contains('act_post_check'));
    });
  });

  group('сигналы склада: только пока приложение открыто', () {
    final timers = <(Duration, void Function())>[];

    Timer fakeTimer(Duration d, void Function() f) {
      timers.add((d, f));
      return _NoTimer();
    }

    setUp(timers.clear);

    Map<String, Object?> arrivals(List<String> ids) => <String, Object?>{
          'ok': true,
          'count': ids.length,
          'qty': ids.length * 2,
          'items': <Object?>[
            for (final id in ids) <String, Object?>{'id': id},
          ],
        };

    test('новые приходы — onNews; pause снимает таймер', () async {
      final s = _Setup();
      final signals = WarehouseSignals(
        service: s.service,
        transport: s.server,
        secrets: s.secrets,
        clock: FixedClock(now),
        timer: fakeTimer,
      );
      final news = <WarehouseSignal>[];
      signals.onNews = news.add;
      s.server
        ..on('ask_arrivals', 200, arrivals(<String>['a']))
        ..on('ask_unposted', 200, <String, Object?>{'ok': true, 'count': 2})
        ..on('ask_arrivals', 200, arrivals(<String>['a', 'b']))
        ..on('ask_unposted', 200, <String, Object?>{'ok': true, 'count': 2});
      signals.resume();
      expect(timers.single.$1, Duration.zero);
      await signals.tick();
      // Первый опрос — без «новых»: это то, что было.
      expect(news, isEmpty);
      expect(signals.last!.arrivals, 1);
      expect(
          s.service.signal,
          'Сегодня 1 приход · не проведено 2 · '
          'проверено в 14:05');
      expect(timers.last.$1, const Duration(minutes: 1));
      await signals.tick();
      expect(news.single.newArrivals, 1);
      signals.pause();
      expect(signals.running, isFalse);
      final before = timers.length;
      await signals.tick();
      // На паузе таймер не ставится.
      expect(timers.length, before);
    });

    test('сбой — пауза вдвое, 429 — сразу 15 минут', () async {
      final s = _Setup();
      final signals = WarehouseSignals(
        service: s.service,
        transport: s.server,
        secrets: s.secrets,
        clock: FixedClock(now),
        timer: fakeTimer,
      )..resume();
      s.server
        ..on('ask_arrivals', 500, <String, Object?>{'error': 'x'})
        ..on('ask_arrivals', 500, <String, Object?>{'error': 'x'})
        ..on('ask_arrivals', 429, <String, Object?>{'error': 'x'});
      await signals.tick();
      expect(signals.delay, const Duration(minutes: 2));
      await signals.tick();
      expect(signals.delay, const Duration(minutes: 4));
      await signals.tick();
      expect(signals.delay, const Duration(minutes: 15));
      signals.dispose();
    });

    test('ключ отключили на складе (403 need:login) — «устарел», тишина',
        () async {
      final s = _Setup();
      final signals = WarehouseSignals(
        service: s.service,
        transport: s.server,
        secrets: s.secrets,
        clock: FixedClock(now),
        timer: fakeTimer,
      )..resume();
      s.server.on('ask_me', 403, <String, Object?>{
        'error': 'x',
        'need': 'login',
      });
      await signals.tick();
      expect(s.service.record.failure, ConnectionFailure.expired);
      final sent = s.server.requests.length;
      await signals.tick();
      await signals.tick();
      // Мёртвым ключом больше не стучимся.
      expect(s.server.requests.length, sent);
      signals.dispose();
    });

    test('403 на приходы — ключ устарел; другой 403 — пауза вдвое', () async {
      final s = _Setup(
        record: connectedRecord().copyWith(
          me: ConnectionMe(all: true, at: now),
        ),
      );
      final signals = WarehouseSignals(
        service: s.service,
        transport: s.server,
        secrets: s.secrets,
        clock: FixedClock(now),
        timer: fakeTimer,
      )..resume();
      s.server
        ..on('ask_arrivals', 403, <String, Object?>{
          'error': 'x',
          'need': 'perm',
        })
        ..on('ask_arrivals', 403, <String, Object?>{
          'error': 'x',
          'need': 'login',
        });
      await signals.tick();
      expect(signals.delay, const Duration(minutes: 2));
      expect(s.service.record.failure, isNull);
      await signals.tick();
      expect(s.service.record.failure, ConnectionFailure.expired);
      signals.dispose();
    });

    test('права освежаются: при возврате на экран и раз в полчаса', () async {
      final s = _Setup(
        record: connectedRecord().copyWith(
          me: ConnectionMe(
            all: true,
            actions: false,
            at: now.subtract(const Duration(minutes: 5)),
          ),
        ),
      );
      final signals = WarehouseSignals(
        service: s.service,
        transport: s.server,
        secrets: s.secrets,
        clock: FixedClock(now),
        timer: fakeTimer,
      );
      s.server
        ..on('ask_me', 200, <String, Object?>{
          'ok': true,
          'login': 'ivanov',
          'all': true,
          'actions': true,
        })
        ..on('ask_arrivals', 200, arrivals(<String>['a']))
        ..on('ask_arrivals', 200, arrivals(<String>['a']));
      signals.resume();
      await signals.tick();
      expect(s.service.record.me.actions, isTrue);
      expect(s.server.actions.where((String a) => a == 'ask_me'), hasLength(1));
      // Следующий опрос — права свежие, не спрашиваем.
      await signals.tick();
      expect(s.server.actions.where((String a) => a == 'ask_me'), hasLength(1));
      signals.dispose();
    });

    test('без логина — ни одного запроса', () async {
      final s = _Setup(
        record: connectedRecord(level: ConnectionLevel.shared, login: null),
      );
      final signals = WarehouseSignals(
        service: s.service,
        transport: s.server,
        secrets: s.secrets,
        timer: fakeTimer,
      )..resume();
      await signals.tick();
      expect(s.server.actions, isEmpty);
      expect(signals.last, isNull);
      signals.dispose();
    });
  });
}

final class _NoTimer implements Timer {
  @override
  void cancel() {}

  @override
  bool get isActive => false;

  @override
  int get tick => 0;
}
