import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/manifest/connection.dart';
import 'package:local_assistant/core/connectors/manifest/connection_service.dart';
import 'package:local_assistant/core/connectors/manifest/connection_slots.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';

import '../../web_widget/fakes.dart';

/// Вход ключом, который уже получила страница склада (веб-помощник,
/// ADR-032).
void main() {
  late FakeWarehouse server;
  late InMemorySecretStore secrets;
  late InMemoryConnectionStore store;
  late ConnectionService service;

  setUp(() async {
    server = FakeWarehouse();
    secrets = InMemorySecretStore();
    store = InMemoryConnectionStore();
    service = await ConnectionService.restore(
      slot: ConnectionSlots.warehouse,
      transport: server,
      secrets: secrets,
      store: store,
      builtIn: builtInSource(),
      device: 'Веб-помощник',
    );
  });

  test('ключ помощника без пароля склада, логин и права — от склада', () async {
    final result = await service.connectWithKey(
      address: 'https://warehouse.example/sub/index.php',
      sid: webSid,
      login: 'IVANOV',
      name: 'Иван',
      role: 'Кладовщик',
    );
    expect(result.ok, isTrue, reason: result.message);
    expect(await secrets.read('warehouse.sid'), webSid);
    expect(await secrets.read('warehouse.token'), isNull);
    final record = service.record;
    expect(record.baseUri.toString(), 'https://warehouse.example/sub/');
    expect(record.level, ConnectionLevel.staff);
    expect(record.scope, 'assist');
    expect(record.tokenless, isTrue);
    expect(record.login, 'ivanov');
    expect(record.me.name, 'Иван Петров', reason: 'склад важнее страницы');
    expect(server.actions, <String>['ask_me']);
    expect(server.requests.last.headers['X-Wh-Sid'], webSid);
  });

  test('прежний ключ на складе не гасится — его заменяет склад', () async {
    await service.connectWithKey(
      address: 'https://warehouse.example/',
      sid: webSid,
    );
    await service.connectWithKey(
      address: 'https://warehouse.example/',
      sid: webSid2,
    );
    expect(server.actions, isNot(contains('auth_out')));
    expect(server.actions, isNot(contains('sess_end')));
    expect(await secrets.read('warehouse.sid'), webSid2);
  });

  test('ключ уже погашен — «устарел», без входа', () async {
    server.on(
      'ask_me',
      403,
      <String, Object?>{'error': 'Войдите', 'need': 'login'},
    );
    final result = await service.connectWithKey(
      address: 'https://warehouse.example/',
      sid: webSid,
    );
    expect(result.ok, isFalse);
    expect(service.record.failure, ConnectionFailure.expired);
  });

  test('ключ не того вида и чужой адрес — отказ без запросов', () async {
    for (final sid in <String>['', 'short', 'с пробелом и кириллицей 1234']) {
      final r = await service.connectWithKey(
        address: 'https://warehouse.example/',
        sid: sid,
      );
      expect(r.ok, isFalse, reason: sid);
    }
    final http = await service.connectWithKey(
      address: 'http://warehouse.example/',
      sid: webSid,
    );
    expect(http.ok, isFalse);
    expect(server.requests, isEmpty);
  });

  test('описание не получено — в работе встроенное, вход есть', () async {
    server.manifest = 'not json';
    final result = await service.connectWithKey(
      address: 'https://warehouse.example/',
      sid: webSid,
    );
    expect(result.ok, isTrue, reason: result.message);
    expect(service.description, isNotNull);
  });

  test('logout(remote: false) — без запроса на склад', () async {
    await service.connectWithKey(
      address: 'https://warehouse.example/',
      sid: webSid,
    );
    final before = server.requests.length;
    await service.logout(remote: false);
    expect(server.requests.length, before);
    expect(await secrets.read('warehouse.sid'), isNull);
    expect(service.connected, isFalse);
  });
}
