import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/manifest/connection.dart';
import 'package:local_assistant/core/connectors/manifest/connection_service.dart';
import 'package:local_assistant/core/connectors/manifest/connection_slots.dart';
import 'package:local_assistant/core/connectors/manifest/manifest_connector.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';
import 'package:local_assistant/core/services/clock.dart';

import '../fakes.dart';
import 'fixtures.dart';

/// Заведомо поддельные значения: настоящих секретов в тестах нет.
const String fakeToken = 'fake-token-not-real';
const String fakeSid = 'fake-sid-not-real';
const String code = '0123456789abcdef0123456789abcdef';
const String link = 'https://warehouse.example/#qr=$code';

final DateTime now = DateTime(2026, 11, 2, 16, 30);

HttpResponseData json(int status, Map<String, Object?> body) =>
    HttpResponseData(statusCode: status, body: jsonEncode(body));

/// Поддельный склад: описание и действия по `?action=`.
final class FakeWarehouse {
  FakeWarehouse({this.manifestPath = currentManifestPath});

  String manifestPath;
  final Map<String, HttpResponseData Function(Map<String, Object?> body)>
      actions = <String, HttpResponseData Function(Map<String, Object?>)>{};
  int manifestStatus = 200;

  late final FakeHttpTransport transport = FakeHttpTransport(_respond);

  HttpResponseData _respond(HttpRequestData request) {
    if (request.uri.path.endsWith('assistant.json')) {
      if (request.headers['If-None-Match'] == '"v1"') {
        return const HttpResponseData(statusCode: 304);
      }
      if (manifestStatus != 200) {
        return HttpResponseData(statusCode: manifestStatus);
      }
      return HttpResponseData(
        statusCode: 200,
        headers: const <String, String>{'etag': '"v1"'},
        body: manifestSource(manifestPath),
      );
    }
    final action = request.uri.queryParameters['action']!;
    final handler = actions[action];
    if (handler == null) {
      return json(400, <String, Object?>{'error': 'Неизвестное действие'});
    }
    return handler(
      request.body == null
          ? const <String, Object?>{}
          : jsonDecode(request.body!) as Map<String, Object?>,
    );
  }

  List<String?> get calledActions => <String?>[
        for (final r in transport.requests) r.uri.queryParameters['action'],
      ];
}

void main() {
  late FakeWarehouse server;
  late InMemorySecretStore secrets;
  late InMemoryConnectionStore store;
  late ConnectionService service;

  ConnectionService make({String path = currentManifestPath}) {
    final connector = warehouseConnector(
      path: path,
      transport: server.transport,
      secrets: secrets,
    );
    return ConnectionService(
      connector: connector,
      transport: server.transport,
      secrets: secrets,
      store: store,
      clock: FixedClock(now),
    );
  }

  setUp(() {
    server = FakeWarehouse();
    secrets = InMemorySecretStore();
    store = InMemoryConnectionStore();
    service = make();
  });

  /// Ни в состоянии, ни в кэше, ни в тексте нет секретов.
  void noSecretsStored([List<String> messages = const <String>[]]) {
    for (final text in <String>[
      ...store.records.values,
      ...messages,
      service.record.toJson().toString(),
    ]) {
      expect(text, isNot(contains(fakeToken)));
      expect(text, isNot(contains(fakeSid)));
      expect(text, isNot(contains(code)));
    }
  }

  group('ссылка входа', () {
    test('адрес и код', () {
      final parsed = ConnectionService.parseQrLink(link);
      expect(parsed.base.toString(), 'https://warehouse.example/');
      expect(parsed.code, code);
      expect(parsed.toString(), isNot(contains(code)));
    });

    test('заглавные, &qr=, index.html, порт и путь', () {
      final parsed = ConnectionService.parseQrLink(
        'https://Warehouse.Example:8443/wh/index.html?x=1#a=1&qr=${code.toUpperCase()}',
      );
      expect(parsed.base.toString(), 'https://warehouse.example:8443/wh/');
      expect(parsed.code, code);
    });

    test('http — только своя сеть', () {
      expect(
        ConnectionService.parseQrLink('http://192.168.1.5/#qr=$code')
            .base
            .toString(),
        'http://192.168.1.5/',
      );
      expect(
        ConnectionService.parseQrLink('http://localhost:8080/#qr=$code')
            .base
            .port,
        8080,
      );
      expect(
        () =>
            ConnectionService.parseQrLink('http://warehouse.example/#qr=$code'),
        throwsA(isA<ConnectionAddressException>()),
      );
    });

    test('плохие ссылки', () {
      for (final bad in <String>[
        '',
        'просто текст',
        'https://warehouse.example/',
        'https://warehouse.example/#qr=123',
        'https://warehouse.example/#qr=${'z' * 32}',
        'ftp://warehouse.example/#qr=$code',
        'https://user:pw@warehouse.example/#qr=$code',
      ]) {
        expect(
          () => ConnectionService.parseQrLink(bad),
          throwsA(isA<ConnectionAddressException>()),
          reason: bad,
        );
      }
    });

    test('адрес вручную: без схемы — https, страница — её папка', () {
      expect(
        ConnectionService.baseOf('warehouse.example').toString(),
        'https://warehouse.example/',
      );
      expect(
        ConnectionService.baseOf('https://warehouse.example/wh/api.php?a=1')
            .toString(),
        'https://warehouse.example/wh/',
      );
      expect(ConnectionService.isLocalHost('172.20.0.1'), isTrue);
      expect(ConnectionService.isLocalHost('172.32.0.1'), isFalse);
    });
  });

  group('вход по ссылке', () {
    void qrOk() {
      server.actions['qr_take'] = (Map<String, Object?> body) {
        expect(body, <String, Object?>{'code': code});
        return json(200, <String, Object?>{
          'ok': true,
          'token': fakeToken,
          'sid': fakeSid,
          'login': 'ivanov',
        });
      };
    }

    for (final path in <String>[currentManifestPath, patchedManifestPath]) {
      test('успех: секреты в SecretStore, остальное без них ($path)', () async {
        server.manifestPath = path;
        qrOk();
        final result = await service.connectByLink(link);
        expect(result.ok, isTrue, reason: result.message);
        expect(result.message, 'Склад подключён: ivanov.');
        expect(await secrets.read('warehouse.token'), fakeToken);
        expect(await secrets.read('warehouse.sid'), fakeSid);
        expect(service.record.level, ConnectionLevel.staff);
        expect(service.record.login, 'ivanov');
        expect(service.record.baseUri.toString(), 'https://warehouse.example/');
        expect(service.record.manifest.etag, '"v1"');
        expect(
          service.record.manifest.label,
          path == patchedManifestPath ? '1.4.56' : hasLength(8),
        );
        expect(store.manifests['halowarekeep'], manifestSource(path));
        // qr_take — открытое действие: без пароля склада.
        final take = server.transport.requests.last;
        expect(take.uri.queryParameters['action'], 'qr_take');
        expect(take.headers.containsKey('X-Wh-Token'), isFalse);
        noSecretsStored(<String>[result.message]);
      });
    }

    test('410 и 429 — тексты, ничего не сохранено', () async {
      for (final (status, text) in <(int, String)>[
        (410, 'Код устарел'),
        (429, 'подождите десять минут'),
        (400, 'обрезана'),
      ]) {
        server.actions['qr_take'] =
            (_) => json(status, <String, Object?>{'error': 'нет'});
        final result = await service.connectByLink(link);
        expect(result.ok, isFalse);
        expect(result.message, contains(text));
        expect(await secrets.read('warehouse.token'), isNull);
        expect(service.connected, isFalse);
      }
    });

    test('хранилище не записало: понятная ошибка, ничего не подключено',
        () async {
      final broken = _BrokenSecretStore(failWrite: true);
      final s = ConnectionService(
        connector: warehouseConnector(
          path: patchedManifestPath,
          transport: server.transport,
          secrets: broken,
        ),
        transport: server.transport,
        secrets: broken,
        store: store,
      );
      server.actions['qr_take'] = (_) => json(200, <String, Object?>{
            'ok': true,
            'token': fakeToken,
            'sid': fakeSid,
            'login': 'ivanov',
          });
      final result = await s.connectByLink(link);
      expect(result.ok, isFalse);
      expect(result.message, contains('Не получилось сохранить'));
      expect(result.message, isNot(contains(fakeToken)));
      expect(s.connected, isFalse);
      expect(broken.values, isEmpty);
    });

    test('описание 1.4.56 говорит своими текстами ошибок', () async {
      server.manifestPath = patchedManifestPath;
      server.actions['qr_take'] =
          (_) => json(410, <String, Object?>{'error': 'нет'});
      final result = await service.connectByLink(link);
      expect(result.message, contains('сотрудника нет или он ждёт роли'));
    });

    test('нет описания, чужое описание, нет связи', () async {
      server.manifestStatus = 404;
      expect(
        (await service.connectByLink(link)).message,
        contains('нет описания помощника'),
      );
      server.manifestStatus = 200;
      final offline = make();
      final broken = ConnectionService(
        connector: offline.connector,
        transport: FakeHttpTransport(
          (_) => throw const SocketException('нет сети'),
        ),
        secrets: secrets,
        store: store,
      );
      expect(
        (await broken.connectByLink(link)).message,
        contains('Нет связи'),
      );
      expect(server.calledActions, isNot(contains('qr_take')));
    });
  });

  group('вход вручную', () {
    void stock({int status = 200}) {
      server.actions['ask_stock'] = (Map<String, Object?> body) {
        expect(body, <String, Object?>{'q': '0'});
        return json(status, <String, Object?>{
          'ok': status == 200,
          'items': <Object?>[],
        });
      };
    }

    test('пароль склада: проверка безвредным чтением, уровень shared',
        () async {
      stock();
      final result = await service.connectManual(
        address: 'warehouse.example',
        password: fakeToken,
      );
      expect(result.ok, isTrue, reason: result.message);
      expect(service.record.level, ConnectionLevel.shared);
      expect(service.record.login, isNull);
      expect(await secrets.read('warehouse.sid'), isNull);
      final probe = server.transport.requests.last;
      expect(probe.headers['X-Wh-Token'], fakeToken);
      noSecretsStored(<String>[result.message]);
    });

    test('неверный пароль — ничего не сохранено', () async {
      stock(status: 401);
      final result = await service.connectManual(
        address: 'https://warehouse.example/',
        password: 'wrong-fake',
      );
      expect(result.ok, isFalse);
      expect(result.message, 'Склад не принял пароль.');
      expect(await secrets.read('warehouse.token'), isNull);
      expect(store.records, isEmpty);
    });

    test('логин: auth_check → личный ключ, пароль не хранится', () async {
      stock();
      server.actions['auth_check'] = (Map<String, Object?> body) {
        expect(body, <String, Object?>{'login': 'Ivanov', 'pass': 'fake-pw'});
        return json(200, <String, Object?>{
          'ok': true,
          'known': true,
          'left': 5,
          'sid': fakeSid,
        });
      };
      final result = await service.connectManual(
        address: 'warehouse.example',
        password: fakeToken,
        login: 'Ivanov',
        pass: 'fake-pw',
      );
      expect(result.ok, isTrue, reason: result.message);
      expect(service.record.level, ConnectionLevel.staff);
      expect(service.record.login, 'ivanov');
      expect(await secrets.read('warehouse.sid'), fakeSid);
      expect(await secrets.read('warehouse.pass'), isNull);
      for (final text in store.records.values) {
        expect(text, isNot(contains('fake-pw')));
      }
      noSecretsStored(<String>[result.message]);
    });

    test('неверный логин: осталось попыток, блокировка', () async {
      stock();
      for (final (answer, text) in <(Map<String, Object?>, String)>[
        (
          <String, Object?>{'ok': false, 'known': true, 'left': 3, 'sid': ''},
          'осталось 3 попытки',
        ),
        (<String, Object?>{'ok': false, 'known': false}, 'Неверный логин'),
        (
          <String, Object?>{'ok': false, 'known': true, 'locked': 41},
          'подождите 41 секунду',
        ),
      ]) {
        server.actions['auth_check'] = (_) => json(200, answer);
        final result = await service.connectManual(
          address: 'warehouse.example',
          password: fakeToken,
          login: 'ivanov',
          pass: 'bad-fake',
        );
        expect(result.ok, isFalse);
        expect(result.message, contains(text));
        expect(await secrets.read('warehouse.token'), isNull);
      }
    });

    test('пароль принят только при 2xx и JSON: иначе ничего не сохранено',
        () async {
      for (final (status, body, text) in <(int, String, String)>[
        (302, '', 'не склад или он переехал'),
        (404, '<html>', 'не склад или он переехал'),
        (403, '<html>', 'ошибкой 403'),
        (400, '<html>', 'ошибкой 400'),
        (429, '', 'подождать'),
        (200, '<html>', 'не JSON'),
        (200, '[]', 'не JSON'),
        (200, '{"ok":false}', 'не принял пароль'),
      ]) {
        server.actions['ask_stock'] =
            (_) => HttpResponseData(statusCode: status, body: body);
        final result = await service.connectManual(
          address: 'warehouse.example',
          password: 'wrong-fake',
        );
        expect(result.ok, isFalse, reason: '$status $body');
        expect(result.message, contains(text), reason: '$status $body');
        expect(await secrets.read('warehouse.token'), isNull);
        expect(service.connected, isFalse);
        expect(store.records, isEmpty);
      }
    });

    test('без команды по паролю склада пароль не проверить — не сохранён',
        () async {
      final changed = jsonDecode(manifestSource(patchedManifestPath))
          as Map<String, Object?>;
      for (final command in changed['commands']! as List<Object?>) {
        final c = command! as Map<String, Object?>;
        if (c['call'] != null) c['access'] = 'staff';
      }
      final dir = Directory.systemTemp.createTempSync('manifest');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/assistant.json';
      File(path).writeAsStringSync(jsonEncode(changed));
      server.manifestPath = path;
      final result = await service.connectManual(
        address: 'warehouse.example',
        password: fakeToken,
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('Пароль не проверить'));
      expect(await secrets.read('warehouse.token'), isNull);
      expect(server.calledActions, isNot(contains('ask_stock')));
    });

    test('«Войти под логином» после входа по паролю', () async {
      stock();
      await service.connectManual(
        address: 'warehouse.example',
        password: fakeToken,
      );
      server.actions['auth_check'] = (_) => json(200, <String, Object?>{
            'ok': true,
            'known': true,
            'sid': fakeSid,
          });
      final result = await service.loginStaff(login: 'petrov', pass: 'pw');
      expect(result.ok, isTrue);
      expect(service.record.level, ConnectionLevel.staff);
      expect(await secrets.read('warehouse.sid'), fakeSid);
    });
  });

  group('выход', () {
    Future<void> connect() async {
      await secrets.write('warehouse.token', fakeToken);
      await secrets.write('warehouse.sid', fakeSid);
      service.connector.record = connectedRecord();
    }

    test('описание 1.4.56: sess_end с ключом, секреты удалены', () async {
      service = make(path: patchedManifestPath);
      await connect();
      server.actions['sess_end'] =
          (_) => json(200, <String, Object?>{'ok': true, 'ended': true});
      await service.logout();
      final end = server.transport.requests.single;
      expect(end.uri.queryParameters['action'], 'sess_end');
      expect(end.headers['X-Wh-Token'], fakeToken);
      expect(end.headers['X-Wh-Sid'], fakeSid);
      expect(end.timeout, ConnectionService.logoutTimeout);
      expect(await secrets.read('warehouse.token'), isNull);
      expect(await secrets.read('warehouse.sid'), isNull);
      expect(service.connected, isFalse);
      expect(service.record.login, isNull);
      // Адрес остаётся: подключиться снова проще.
      expect(service.record.baseUri, warehouseBase);
    });

    test('ошибка sess_end не мешает выйти', () async {
      service = make(path: patchedManifestPath);
      await connect();
      server.actions['sess_end'] =
          (_) => json(500, <String, Object?>{'error': 'Сбой'});
      await service.logout();
      expect(await secrets.read('warehouse.token'), isNull);
      final offline = ConnectionService(
        connector: warehouseConnector(
          path: patchedManifestPath,
          secrets: secrets,
        ),
        transport: FakeHttpTransport(
          (_) => throw const SocketException('нет сети'),
        ),
        secrets: secrets,
        store: store,
      );
      await secrets.write('warehouse.token', fakeToken);
      await secrets.write('warehouse.sid', fakeSid);
      offline.connector.record = connectedRecord();
      await offline.logout();
      expect(await secrets.read('warehouse.sid'), isNull);
    });

    test('хранилище не удаляет: ошибка, подключение не снято', () async {
      final broken = _BrokenSecretStore(failDelete: true)
        ..values['warehouse.token'] = fakeToken;
      final s = ConnectionService(
        connector:
            warehouseConnector(secrets: broken, record: connectedRecord()),
        transport: server.transport,
        secrets: broken,
        store: store,
      );
      await expectLater(s.logout(), throwsA(isA<ConnectionStorageException>()));
      expect(s.connected, isTrue);
      try {
        await s.logout();
      } on ConnectionStorageException catch (error) {
        expect(error.message, isNot(contains(fakeToken)));
      }
    });

    test('текущее описание: выход только на устройстве', () async {
      await connect();
      await service.logout();
      expect(server.transport.requests, isEmpty);
      expect(await secrets.read('warehouse.token'), isNull);
      expect(await secrets.read('warehouse.sid'), isNull);
      final health = await service.connector.health();
      expect(health.status, HealthStatus.notConnected);
    });
  });

  group('описание', () {
    test('304 — не изменилось, битое — не заменяет прежнее', () async {
      service.connector.record = connectedRecord();
      final first = await service.refreshManifest();
      expect(first.ok, isTrue);
      expect(service.record.manifest.etag, '"v1"');
      final again = await service.refreshManifest();
      expect(again.message, 'Описание не изменилось.');

      final broken = ConnectionService(
        connector: service.connector,
        transport: FakeHttpTransport(
          (_) => const HttpResponseData(
            statusCode: 200,
            body: '{"format":"assistant/2"}',
          ),
        ),
        secrets: secrets,
        store: store,
      );
      service.connector.record =
          service.record.copyWith(manifest: const ManifestMeta());
      final before = service.connector.description;
      final result = await broken.refreshManifest();
      expect(result.ok, isFalse);
      expect(result.message, startsWith('Описание не принято'));
      expect(broken.manifestError, startsWith('Описание не принято'));
      expect(service.connector.description, same(before));
    });

    test('восстановление: кэш, иначе встроенная копия', () async {
      store.manifests['halowarekeep'] = manifestSource(patchedManifestPath);
      // Кэш годится только серверу, с которого взят (`cached_from`).
      await store.save(
        connectedRecord().copyWith(
          manifest: ManifestMeta(
            cachedFrom: warehouseBase.resolve('assistant.json').toString(),
          ),
        ),
      );
      final restored = await ConnectionService.restore(
        slot: ConnectionSlots.warehouse,
        transport: server.transport,
        secrets: secrets,
        store: store,
        builtIn: manifestSource(),
      );
      expect(restored.description!.version, '1.4.56');
      expect(restored.connected, isTrue);

      store.manifests['halowarekeep'] = 'битый';
      final fallback = await ConnectionService.restore(
        slot: ConnectionSlots.warehouse,
        transport: server.transport,
        secrets: secrets,
        store: store,
        builtIn: manifestSource(),
      );
      expect(fallback.description!.version, isNull);
      expect(
        fallback.connector
            .match(Utterance.analyze('где лежит 64115', now: now)),
        isNotNull,
      );
    });

    test('после успешного ответа старое описание проверяется в фоне', () async {
      await secrets.write('warehouse.token', fakeToken);
      service.connector.record = connectedRecord();
      server.actions['ask_stock'] =
          (_) => json(200, <String, Object?>{'ok': true, 'items': <Object?>[]});
      final connector = service.connector;
      await connector.run(
        connector.match(Utterance.analyze('где лежит 64115', now: now))!,
        AssistantSession(clock: FixedClock(now)).._useWarehouse(connector),
      );
      await pumpEventQueue();
      expect(
        server.transport.requests.map((r) => r.uri.path),
        contains('/assistant.json'),
      );
    });
  });

  test('JSON-хранилище: файлы по id приложения, без секретов', () async {
    final dir = await Directory.systemTemp.createTemp('connections');
    addTearDown(() => dir.delete(recursive: true));
    final json = JsonConnectionStore(dir.path);
    await json.save(connectedRecord());
    await json.saveManifest('halowarekeep', manifestSource());
    expect(File('${dir.path}/halowarekeep.json').existsSync(), isTrue);
    expect(
      File('${dir.path}/halowarekeep.assistant.json').readAsStringSync(),
      manifestSource(),
    );
    final loaded = (await json.load('halowarekeep'))!;
    expect(loaded.login, 'ivanov');
    expect(loaded.level, ConnectionLevel.staff);
    expect(await json.load('expeora'), isNull);
    expect(() => json.load('../evil'), throwsArgumentError);
  });
}

extension on AssistantSession {
  /// Записи каталога склада: без них `run` не скажет ответ.
  void _useWarehouse(ManifestConnector connector) {
    replies = replies.withEntries(
      connector.info.replies,
      protectedIds: connector.info.protectedReplies,
    );
  }
}

/// Хранилище секретов, которое не может писать или удалять (нет места,
/// нет прав).
final class _BrokenSecretStore implements SecretStore {
  _BrokenSecretStore({this.failWrite = false, this.failDelete = false});

  final bool failWrite;
  final bool failDelete;
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw const FileSystemException('нет места');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failDelete) throw const FileSystemException('нет прав');
    values.remove(key);
  }
}
