import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/manifest/app_connections.dart';
import 'package:local_assistant/core/connectors/manifest/app_profile.dart';
import 'package:local_assistant/core/connectors/manifest/connection.dart';
import 'package:local_assistant/core/connectors/manifest/connection_directory.dart';
import 'package:local_assistant/core/connectors/manifest/connection_directory_io.dart';
import 'package:local_assistant/core/connectors/manifest/connection_service.dart';
import 'package:local_assistant/core/connectors/manifest/connection_slots.dart';
import 'package:local_assistant/core/connectors/manifest/connection_store_io.dart';
import 'package:local_assistant/core/connectors/manifest/description_authority.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/models/warehouse_card.dart';
import 'package:local_assistant/core/personas/duty_zones.dart';
import 'package:local_assistant/core/personas/persona_cast.dart';
import 'package:local_assistant/core/personas/persona_names.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/connector_assembly.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import 'fixtures.dart';

/// Каталог подключений, проба адреса, закреплённое описание и сборка
/// коннекторов (ADR-043, шаг 2). Приложение — синтетическая CRM
/// `testcrm`; адреса — только `.example`, секреты — заведомо поддельные
/// (CANARY).
const String testCrmPath = 'test/fixtures/assistant/testcrm.json';
const String canaryToken = 'CANARY-crm-token-not-real';
const String canarySid = 'CANARY-crm-sid-not-real';
const String canaryKey = 'CANARY-crm-key-not-real';
const String fakeWarehouseToken = 'fake-token-not-real';

final DateTime now = DateTime(2026, 11, 19, 10, 30);
const String crmHost = 'crm.example';
final Uri crmBase = Uri.parse('https://crm.example/');

Map<String, Object?> crmJson() =>
    jsonDecode(File(testCrmPath).readAsStringSync()) as Map<String, Object?>;

/// Описание CRM с правкой [edit].
String crm([void Function(Map<String, dynamic> d)? edit]) {
  final d = crmJson();
  d['version'] = '1.0.0';
  edit?.call(d);
  return jsonEncode(d);
}

Map<String, dynamic> _map(Object? value) => value as Map<String, dynamic>;
List<dynamic> _list(Object? value) => value as List<dynamic>;

/// Сеть по адресам: описание и ответы по хосту и пути.
final class RoutedTransport implements HttpTransport {
  RoutedTransport(this.routes);

  /// `host/path` → ответ.
  final Map<String, HttpResponseData Function(HttpRequestData)> routes;
  final List<HttpRequestData> requests = <HttpRequestData>[];

  @override
  Future<HttpResponseData> send(HttpRequestData request) async {
    requests.add(request);
    final key = '${request.uri.host}${request.uri.path}';
    final route = routes[key];
    if (route == null) return const HttpResponseData(statusCode: 404);
    return route(request);
  }
}

HttpResponseData json200(String body) =>
    HttpResponseData(statusCode: 200, body: body);

HttpResponseData clients(HttpRequestData _) => json200(
      jsonEncode(<String, Object?>{
        'ok': true,
        'q': 'тестов',
        'count': 1,
        'items': <Object?>[
          <String, Object?>{'name': 'Тестов Т. Т.', 'car': 'Тест-1'},
        ],
      }),
    );

/// Хранилище секретов, которое помнит удаления.
final class RecordingSecrets implements SecretStore {
  RecordingSecrets([Map<String, String> initial = const <String, String>{}])
      : values = Map<String, String>.of(initial);

  final Map<String, String> values;
  final List<String> deleted = <String>[];

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async {
    deleted.add(key);
    values.remove(key);
  }
}

void main() {
  tearDown(() => ConnectionSlots.useRuntime(const <ConnectionSlot>[]));

  late RoutedTransport transport;
  late InMemoryConnectionStore store;
  late InMemoryConnectionDirectory directory;
  late RecordingSecrets secrets;

  AppConnections hub({List<ConnectionService> known = const []}) =>
      AppConnections(
        transport: transport,
        secrets: secrets,
        store: store,
        directory: directory,
        known: known,
        clock: FixedClock(now),
      );

  setUp(() {
    transport = RoutedTransport(
      <String, HttpResponseData Function(HttpRequestData)>{
        '$crmHost/assistant.json': (_) => json200(crm()),
        '$crmHost/assist.php': clients,
      },
    );
    store = InMemoryConnectionStore();
    directory = InMemoryConnectionDirectory(store: store);
    secrets = RecordingSecrets();
  });

  group('каталог подключений', () {
    test('сохраняется и читается заново: запись, профиль, удалённые id', () {
      final profile = AppProfile.parse(crmJson()['app']).profile!;
      final snapshot = DirectorySnapshot(
        entries: <DirectoryEntry>[
          DirectoryEntry(
            id: 'testcrm',
            appId: 'testcrm',
            base: crmBase,
            addedAt: now.toUtc(),
            profile: profile,
            secretNames: const <String>['apikey', 'token'],
          ),
        ],
        retired: const <String>{'crm', 'testcrm2'},
      );
      final text = snapshot.encode();
      expect(jsonDecode(text)['format'], 'tridot-connections/1');
      expect(text, isNot(contains(canaryToken)));
      final again = DirectorySnapshot.decode(text);
      final entry = again.entries.single;
      expect(entry.id, 'testcrm');
      expect(entry.appId, 'testcrm');
      expect(entry.base, crmBase);
      expect(entry.addedAt, now.toUtc());
      expect(entry.problem, isNull);
      expect(entry.profile!.toJson(), profile.toJson());
      expect(entry.secretNames, <String>['apikey', 'token']);
      expect(again.retired, <String>{'crm', 'testcrm2'});
      expect(again.usedIds, <String>{'testcrm', 'crm', 'testcrm2'});
    });

    test('чужой формат и битый JSON — пустой каталог', () {
      expect(DirectorySnapshot.decode('{').entries, isEmpty);
      expect(
        DirectorySnapshot.decode('{"format":"other","apps":[]}').entries,
        isEmpty,
      );
      expect(DirectorySnapshot.decode(null).entries, isEmpty);
    });

    test('профиль проверяется заново: плохое имя — запись без профиля', () {
      final text = jsonEncode(<String, Object?>{
        'format': DirectorySnapshot.format,
        'apps': <Object?>[
          <String, Object?>{
            'id': 'bad',
            'appId': 'bad',
            'base': 'https://bad.example/',
            'profile': <String, Object?>{'id': 'bad', 'name': 'пароль'},
          },
          <String, Object?>{'id': 'warehouse', 'appId': 'x', 'base': 'x'},
        ],
      });
      final snapshot = DirectorySnapshot.decode(text);
      expect(snapshot.entries.single.profile, isNull);
      expect(snapshot.entries.single.problem, isNotNull);
      // Битая запись с годным по форме id: id всё равно выданный.
      expect(snapshot.retired, contains('warehouse'));
    });

    test('файлы: _directory.json, закреплённое и удаление по id', () async {
      final temp = await Directory.systemTemp.createTemp('tridot-dir-');
      addTearDown(() => temp.delete(recursive: true));
      final folder = temp.path;
      final files = JsonConnectionDirectory(folder);
      final records = JsonConnectionStore(folder);
      final profile = AppProfile.parse(crmJson()['app']).profile!;
      await files.save(
        DirectorySnapshot(
          entries: <DirectoryEntry>[
            DirectoryEntry(
              id: 'testcrm',
              appId: 'testcrm',
              base: crmBase,
              addedAt: now.toUtc(),
              profile: profile,
            ),
          ],
          retired: const <String>{'old'},
        ),
      );
      await files.savePinned('testcrm', crm());
      await records.save(ConnectionRecord(appId: 'testcrm', baseUri: crmBase));
      await records.saveManifest('testcrm', crm());
      expect(File('$folder/_directory.json').existsSync(), isTrue);
      expect(
        File('$folder/testcrm.pinned.assistant.json').existsSync(),
        isTrue,
      );
      final loaded = await JsonConnectionDirectory(folder).load();
      expect(loaded.entries.single.id, 'testcrm');
      expect(loaded.retired, <String>{'old'});
      expect(await files.loadPinned('testcrm'), crm());
      expect((await records.load('testcrm'))!.baseUri, crmBase);
      await files.deleteFiles('testcrm');
      for (final name in <String>[
        'testcrm.json',
        'testcrm.assistant.json',
        'testcrm.pinned.assistant.json',
      ]) {
        expect(File('$folder/$name').existsSync(), isFalse, reason: name);
      }
      expect(File('$folder/_directory.json').existsSync(), isTrue);
      expect(() => files.loadPinned('../x'), returnsNormally);
    });

    test('имя каталога не бывает id подключения', () {
      expect(ConnectionSlots.validId('_directory'), isFalse);
      expect(ConnectionSlots.validId('directory'), isFalse);
      expect(ConnectionSlots.validId('index'), isFalse);
    });
  });

  group('проба адреса без сохранения', () {
    test('любой app.id: описание, профиль, можно подключить', () async {
      transport.routes['$crmHost/assistant.json'] =
          (_) => json200(crm((d) => _map(d['app'])['id'] = 'severauto'));
      final result = await hub().probe('crm.example');
      expect(result.problems, isEmpty);
      expect(result.canAdd, isTrue);
      expect(result.base, crmBase);
      expect(result.description!.appId, 'severauto');
      expect(result.profile!.name, 'автосервис');
      expect(result.knownSlot, isNull);
      expect(result.existingId, isNull);
      expect(store.records, isEmpty);
      expect(directory.text, isNull);
      expect(directory.pinned, isEmpty);
    });

    test('без app.name — имя по app.title, несклоняемое', () async {
      transport.routes['$crmHost/assistant.json'] = (_) => json200(
            crm((d) {
              final app = _map(d['app']);
              for (final key in <String>['name', 'forms', 'in', 'gender']) {
                app.remove(key);
              }
              app.remove('addressing');
              app['title'] = 'CRM';
            }),
          );
      final result = await hub().probe('https://crm.example/');
      expect(result.canAdd, isTrue);
      expect(result.profile!.name, 'CRM');
      expect(result.profile!.declinable, isFalse);
    });

    test('знакомое приложение (склад) — свой слот, не новое', () async {
      transport.routes['$crmHost/assistant.json'] =
          (_) => json200(manifestSource());
      final connections = hub();
      final result = await connections.probe('https://crm.example/');
      expect(result.knownSlot?.id, ConnectionSlots.warehouse.id);
      expect(result.canAdd, isFalse);
      await expectLater(
        connections.add(result),
        throwsA(isA<AppConnectionException>()),
      );
      expect(connections.runtime, isEmpty);
      expect(directory.text, isNull);
    });

    test('404 — описания нет', () async {
      transport.routes.remove('$crmHost/assistant.json');
      final result = await hub().probe('https://crm.example/');
      expect(result.canAdd, isFalse);
      expect(result.problems.single, contains('assistant.json'));
    });

    test('слишком большое описание — не принято', () async {
      transport.routes['$crmHost/assistant.json'] =
          (_) => json200(crm((d) => d['_'] = 'я' * 200000));
      final result = await hub().probe('https://crm.example/');
      expect(result.canAdd, isFalse);
      expect(result.problems.single, contains('256 КБ'));
    });

    test('api.url на другом сервере — не принято', () async {
      transport.routes['$crmHost/assistant.json'] = (_) => json200(
            crm(
              (d) => _map(d['api'])['url'] = 'https://other.example/assist.php',
            ),
          );
      final result = await hub().probe('https://crm.example/');
      expect(result.canAdd, isFalse);
      expect(result.problems.single, contains('другом сервере'));
    });

    test('переадресация — ошибка, за ней не идём', () async {
      transport.routes['$crmHost/assistant.json'] =
          (_) => const HttpResponseData(
                statusCode: 302,
                headers: <String, String>{
                  'location': 'https://other.example/assistant.json',
                },
              );
      final result = await hub().probe('https://crm.example/');
      expect(result.canAdd, isFalse);
      expect(result.problems.single, contains('302'));
      expect(transport.requests.single.uri.host, crmHost);
    });

    test('http — только в своей сети', () async {
      final connections = hub();
      final outside = await connections.probe('http://crm.example/');
      expect(outside.canAdd, isFalse);
      expect(outside.problems.single, contains('https'));
      expect(transport.requests, isEmpty);
      transport.routes['192.168.1.5/assistant.json'] = (_) => json200(
            crm((d) => _map(d['api'])['url'] = 'assist.php'),
          );
      final local = await connections.probe('http://192.168.1.5/');
      expect(local.canAdd, isTrue);
    });

    test('ссылка входа: только адрес, код никуда не уходит', () async {
      const code = '0123456789abcdef0123456789abcdef';
      final result = await hub().probe('https://crm.example/#qr=$code');
      expect(result.base, crmBase);
      for (final request in transport.requests) {
        expect(request.uri.toString(), isNot(contains(code)));
      }
    });

    test('приватное слово в фразах — не принято', () async {
      transport.routes['$crmHost/assistant.json'] = (_) => json200(
            crm((d) {
              final command = _map(_list(d['commands']).first);
              _list(command['say']).add('пароль клиента {q}');
            }),
          );
      final result = await hub().probe('https://crm.example/');
      expect(result.canAdd, isFalse);
      expect(result.problems, contains(contains('приватные')));
    });

    test('уже подключено — тот же app.id и хост', () async {
      final connections = hub();
      await connections.add(await connections.probe('https://crm.example/'));
      final again = await connections.probe('https://crm.example/');
      expect(again.existingId, 'testcrm');
      expect(again.canAdd, isFalse);
      await expectLater(
        connections.add(again),
        throwsA(isA<AppConnectionException>()),
      );
    });
  });

  group('подключить и удалить', () {
    test('подключить: id, закреплённое — ровно показанное, запись', () async {
      final connections = hub();
      final probe = await connections.probe('https://crm.example/');
      final added = await connections.add(probe);
      final service = added.service;
      expect(service.slot.id, 'testcrm');
      expect(service.slot.runtime, isTrue);
      expect(service.slot.fileKey, 'testcrm');
      expect(directory.pinned['testcrm'], probe.description!.source);
      expect(service.descriptionOrigin, DescriptionOrigin.pinned);
      expect(service.description!.actions, isEmpty);
      expect(service.connector.info.access, ConnectorAccess.readOnly);
      expect(store.records.keys, <String>['testcrm']);
      expect((await store.load('testcrm'))!.baseUri, crmBase);
      final entry = (await directory.load()).entries.single;
      expect(entry.base, crmBase);
      expect(entry.secretNames, contains('token'));
      expect(connections.services.map((s) => s.slot.id), <String>['testcrm']);
      expect(ConnectionSlots.runtime.single.id, 'testcrm');
    });

    test('обращение занято другим приложением — профиль не принят', () async {
      final connections = hub();
      await connections.add(await connections.probe('https://crm.example/'));
      transport.routes['other.example/assistant.json'] = (_) => json200(
            crm((d) => _map(d['app'])['id'] = 'othercrm'),
          );
      final second = await connections.probe('https://other.example/');
      // Имя «автосервис» уже у первого: профиля нет.
      expect(second.profile, isNull);
      expect(second.canAdd, isFalse);
      final mine = AppProfile.parse(<String, Object?>{
        'id': 'othercrm',
        'name': 'гараж',
      }).profile!;
      final added = await connections.add(
        ProbeResult(
          base: second.base,
          description: second.description,
          profile: mine,
        ),
        profile: mine,
      );
      expect(added.service.slot.title, 'Гараж');
      expect(added.service.slot.id, 'othercrm');
    });

    test('поправленное имя с занятым словом — отказ, ничего не записано',
        () async {
      final connections = hub();
      final probe = await connections.probe('https://crm.example/');
      final taken = AppProfile(
        appId: 'testcrm',
        name: 'автосервис',
        addressing: const <String>['склад'],
      );
      await expectLater(
        connections.add(probe, profile: taken),
        throwsA(isA<AppConnectionException>()),
      );
      expect(directory.text, isNull);
      expect(connections.runtime, isEmpty);
    });

    test('удалённый id не выдаётся снова — и после перезапуска', () async {
      final first = hub();
      final a = await first.add(await first.probe('https://crm.example/'));
      expect(a.service.slot.id, 'testcrm');
      expect(await first.remove('testcrm'), isTrue);
      final b = await first.add(await first.probe('https://crm.example/'));
      expect(b.service.slot.id, 'testcrm2');
      // Второй экземпляр того же приложения на другом адресе — свой id.
      transport.routes['crm2.example/assistant.json'] = (_) => json200(
            crm((d) {
              final app = _map(d['app']);
              app['name'] = 'гараж';
              for (final key in <String>['forms', 'in', 'addressing']) {
                app.remove(key);
              }
            }),
          );
      final c = await first.add(await first.probe('https://crm2.example/'));
      expect(c.service.slot.id, 'testcrm3');
      await first.remove('testcrm2');
      final restarted = hub();
      await restarted.load();
      expect(restarted.runtime.map((s) => s.slot.id), <String>['testcrm3']);
      final d = await restarted.add(
        await restarted.probe('https://crm.example/'),
      );
      expect(d.service.slot.id, 'testcrm4');
      expect(
        (await directory.load()).retired,
        containsAll(<String>['testcrm', 'testcrm2']),
      );
    });

    test('удалить: все секреты поимённо, файлы, строка каталога', () async {
      transport.routes['$crmHost/assistant.json'] = (_) => json200(
            crm((d) {
              final auth = _map(d['auth']);
              _map(auth['headers'])['X-Crm-Key'] = r'{$apikey}';
            }),
          );
      secrets.values['warehouse.token'] = fakeWarehouseToken;
      final connections = hub();
      final added = await connections
          .add(await connections.probe('https://crm.example/'));
      expect(
        (await directory.load()).entries.single.secretNames,
        containsAll(<String>['apikey', 'token']),
      );
      final id = added.service.slot.id;
      secrets.values
        ..['$id.token'] = canaryToken
        ..['$id.sid'] = canarySid
        ..['$id.apikey'] = canaryKey;
      await store.saveManifest(id, crm());
      expect(await connections.remove(id), isTrue);
      expect(
        secrets.deleted,
        containsAll(<String>['$id.token', '$id.sid', '$id.apikey']),
      );
      expect(secrets.values.keys, <String>['warehouse.token']);
      expect(store.records, isEmpty);
      expect(store.manifests, isEmpty);
      expect(directory.pinned, isEmpty);
      final after = await directory.load();
      expect(after.entries, isEmpty);
      expect(after.retired, contains(id));
      expect(directory.text, isNot(contains('CANARY')));
      expect(connections.runtime, isEmpty);
      expect(ConnectionSlots.runtime, isEmpty);
      await expectLater(
        connections.remove(id),
        throwsA(isA<AppConnectionException>()),
      );
    });

    test('подключение из каталога не перенацеливается ссылкой', () async {
      final connections = hub();
      final added = await connections
          .add(await connections.probe('https://crm.example/'));
      final result = await added.service.connectManual(
        address: 'https://evil.example/',
        password: canaryToken,
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('другой адрес'));
      expect(result.message, isNot(contains(canaryToken)));
      expect(
        transport.requests.where((r) => r.uri.host == 'evil.example'),
        isEmpty,
      );
      expect(secrets.values, isEmpty);
    });
  });

  group('закреплённое описание — опора доверия', () {
    Future<ConnectionService> pinnedService({String? pinned}) async {
      final profile = AppProfile.parse(crmJson()['app']).profile!;
      return ConnectionService.restore(
        slot: ConnectionSlot.generic(profile, 'testcrm'),
        transport: transport,
        secrets: secrets,
        store: store,
        pinned: pinned ?? crm(),
        base: crmBase,
        clock: FixedClock(now),
      );
    }

    Future<ConnectionService> refreshed(String server) async {
      await store.save(ConnectionRecord(appId: 'testcrm', baseUri: crmBase));
      transport.routes['$crmHost/assistant.json'] = (_) => json200(server);
      final service = await pinnedService();
      await service.refreshManifest();
      return service;
    }

    test('новое без расширения прав — принято, и после перезапуска', () async {
      final service = await refreshed(
        crm((d) {
          d['version'] = '1.1.0';
          final command = _map(_list(d['commands']).first);
          _list(command['say']).add('клиенты {q}');
          command['title'] = 'Найти клиента по имени';
        }),
      );
      expect(service.descriptionOrigin, DescriptionOrigin.server);
      expect(service.offered, isNull);
      expect(service.description!.commands.first.say, contains('клиенты {q}'));
      final again = await pinnedService();
      expect(again.descriptionOrigin, DescriptionOrigin.server);
      expect(again.description!.commands.first.say, contains('клиенты {q}'));
    });

    test('новое действие — не принято: закреплённое в работе, предложение',
        () async {
      final service = await refreshed(
        crm((d) {
          d['version'] = '1.1.0';
          _list(_map(d['api'])['only']).add('ask_orders');
          final orders = Map<String, dynamic>.of(
            _map(_list(d['commands']).first),
          )
            ..['id'] = 'orders'
            ..['say'] = <String>['заказы {q}']
            ..['call'] = <String, Object?>{
              'action': 'ask_orders',
              'body': <String, Object?>{'q': '{q}'},
            };
          _list(d['commands']).add(orders);
        }),
      );
      expect(service.descriptionOrigin, DescriptionOrigin.pinned);
      expect(service.description!.command('orders'), isNull);
      expect(service.offered, contains('ask_orders'));
      expect(store.manifests, isEmpty);
      final again = await pinnedService();
      expect(again.descriptionOrigin, DescriptionOrigin.pinned);
      expect(again.description!.command('orders'), isNull);
    });

    test('новое поле в теле запроса — не принято', () async {
      final service = await refreshed(
        crm((d) {
          d['version'] = '1.1.0';
          final call = _map(_map(_list(d['commands']).first)['call']);
          _map(call['body'])['all'] = '1';
        }),
      );
      expect(service.descriptionOrigin, DescriptionOrigin.pinned);
      expect(service.offered, contains('новые поля'));
    });

    test('другой api.url — не принят', () async {
      final service = await refreshed(
        crm((d) {
          d['version'] = '1.1.0';
          _map(d['api'])['url'] = 'other.php';
        }),
      );
      expect(service.descriptionOrigin, DescriptionOrigin.pinned);
      expect(service.offered, contains('api.url'));
      expect(service.description!.apiUrl, 'assist.php');
    });

    test('вход по ссылке появился — не принят', () async {
      final service = await refreshed(
        crm((d) {
          d['version'] = '1.1.0';
          _map(d['auth'])['qr'] = <String, Object?>{
            'action': 'qr_take',
            'param': 'code',
          };
        }),
      );
      expect(service.descriptionOrigin, DescriptionOrigin.pinned);
      expect(service.offered, contains('auth.qr'));
    });

    test('приватное слово в новой фразе — не принято', () async {
      final service = await refreshed(
        crm((d) {
          d['version'] = '1.1.0';
          final command = _map(_list(d['commands']).first);
          _list(command['say']).add('пин клиента {q}');
        }),
      );
      expect(service.descriptionOrigin, DescriptionOrigin.pinned);
      expect(service.offered, contains('приватные'));
    });

    test('фраза с чужим обращением — не принята', () async {
      final service = await refreshed(
        crm((d) {
          d['version'] = '1.1.0';
          final command = _map(_list(d['commands']).first);
          _list(command['say']).add('склад {q}');
        }),
      );
      expect(service.descriptionOrigin, DescriptionOrigin.pinned);
      expect(service.offered, contains('чужого обращения'));
    });

    test('закреплённое с actions[] — действий с записью нет', () async {
      final pinned = jsonEncode(
        jsonDecode(manifestSource(actionsManifestPath)) as Map<String, Object?>
          ..['app'] = crmJson()['app'],
      );
      final service = await pinnedService(pinned: pinned);
      expect(service.description, isNotNull);
      expect(service.description!.builtIn, isFalse);
      expect(service.description!.actions, isEmpty);
      expect(service.builtIn, isNull);
      expect(service.connector.info.access, ConnectorAccess.readOnly);
    });

    test('склад: опора — встроенная копия, как раньше', () {
      final builtIn = builtInManifest();
      final pick = DescriptionAuthority.choose(
        builtIn: builtIn,
        pinned: manifest(),
        server: manifest(patchedManifestPath),
      );
      expect(pick.origin, isNot(DescriptionOrigin.pinned));
      expect(pick.reason, isNot(contains('закреплён')));
    });
  });

  group('запуск и пересборка', () {
    late ConnectionService warehouse;

    Future<ConnectionService> warehouseService() async {
      await store.save(connectedRecord());
      secrets.values['warehouse.token'] = fakeWarehouseToken;
      return ConnectionService.restore(
        slot: ConnectionSlots.warehouse,
        transport: transport,
        secrets: secrets,
        store: store,
        builtIn: manifestSource(builtInManifestPath),
        clock: FixedClock(now),
      );
    }

    setUp(() async {
      transport.routes['warehouse.example/api.php'] = (_) => json200(
            File('test/fixtures/assistant/responses/ask_stock_more.json')
                .readAsStringSync(),
          );
      warehouse = await warehouseService();
    });

    ({
      AppConnections connections,
      ExtensionRegistry registry,
      AssistantController controller,
      ConnectorAssembly assembly,
    }) wire(AppConnections connections) {
      final assembly = ConnectorAssembly(
        connections: connections,
        before: <Connector>[
          TasksConnector(
            taskService: TaskService(
              repository: InMemoryTaskRepository(),
              clock: FixedClock(now),
            ),
            parser: ScenarioParser(clock: FixedClock(now)),
          ),
        ],
      );
      final registry = ExtensionRegistry(
        connectors: assembly.build(),
        choice: const ExtensionChoice(
          enabledRoles: <String>{Roles.storekeeperId},
          enabled: <String>{'testcrm', 'testcrm2'},
        ),
      );
      final controller = AssistantController(
        extensions: registry,
        clock: FixedClock(now),
      );
      assembly.attach(registry, controller);
      return (
        connections: connections,
        registry: registry,
        controller: controller,
        assembly: assembly,
      );
    }

    test('склад и приложение из каталога после перезапуска: оба отвечают',
        () async {
      final first = hub(known: <ConnectionService>[warehouse]);
      final added = await first.add(await first.probe('https://crm.example/'));
      final id = added.service.slot.id;
      secrets.values['$id.token'] = canaryToken;
      await store.save(
        ConnectionRecord(
          appId: id,
          baseUri: crmBase,
          level: ConnectionLevel.shared,
        ),
      );
      ConnectionSlots.useRuntime(const <ConnectionSlot>[]);

      // Перезапуск: склад — как раньше, приложение — из каталога.
      final restarted =
          hub(known: <ConnectionService>[await warehouseService()]);
      await restarted.load();
      expect(
        restarted.services.map((s) => s.slot.id),
        <String>['warehouse', 'testcrm'],
      );
      final crmService = restarted.byId('testcrm')!;
      expect(crmService.descriptionOrigin, DescriptionOrigin.pinned);
      expect(crmService.connected, isTrue);
      final w = wire(restarted);
      final ids = w.registry.connectors.map((c) => c.info.id).toList();
      expect(ids, <String>['tasks', 'warehouse', 'testcrm']);
      expect(
        w.registry.replies.neutral.entries.containsKey('testcrm.answer'),
        isTrue,
      );
      expect(w.registry.rolesOf('testcrm'), isEmpty);
      expect(w.registry.isEnabled('testcrm'), isTrue);

      final stock = await w.controller.handle('где лежит 64115');
      expect(stock.intent, 'warehouse.where');
      final client = await w.controller.handle('найди клиента Тестов');
      expect(client.intent, 'testcrm.client');
      expect(client.message, contains('Тестов Т. Т.'));
      expect(client.message, isNot(contains(canaryToken)));
      // Обращение решает спор двух приложений.
      expect(
        (await w.controller.handle('в автосервисе найди 64115')).intent,
        'testcrm.client',
      );
      expect(
        (await w.controller.handle('склад, где лежит 64115')).intent,
        'warehouse.where',
      );
      // Фразы приложения ведёт ведущий расширений, как склад.
      expect(DutyZones.dutyOf('testcrm'), DutyZones.dutyOf('warehouse'));
      expect(client.personaId, stock.personaId);
      // Обращение приложения не достаётся помощнику.
      expect(PersonaNames.connectorWords, contains('сервис'));
      expect(
        PersonaNames.validate('Сервис', 'rio', PersonaCast.current),
        isNotNull,
      );
    });

    test('без своего выключателя приложение молчит: вне ролей', () async {
      final connections = hub(known: <ConnectionService>[warehouse]);
      await connections.add(await connections.probe('https://crm.example/'));
      final registry = ExtensionRegistry(
        connectors: ConnectorAssembly(connections: connections).build(),
      );
      expect(registry.rolesOf('testcrm'), isEmpty);
      expect(registry.isEnabled('testcrm'), isFalse);
      registry.apply(registry.choiceWith('testcrm', true));
      expect(registry.isEnabled('testcrm'), isTrue);
    });

    test('подключили и удалили — реестр пересобирается между ходами', () async {
      final connections = hub(known: <ConnectionService>[warehouse]);
      final w = wire(connections);
      expect(
        w.registry.connectors.map((c) => c.info.id),
        <String>['tasks', 'warehouse'],
      );
      var changes = 0;
      w.registry.addListener(() => changes++);

      // Ход идёт: склад отвечает не сразу.
      final gate = Completer<void>();
      transport.routes['warehouse.example/api.php'] = (_) => json200(
            File('test/fixtures/assistant/responses/ask_stock_more.json')
                .readAsStringSync(),
          );
      final slow = _SlowTransport(transport, gate.future);
      final slowWarehouse = await ConnectionService.restore(
        slot: ConnectionSlots.warehouse,
        transport: slow,
        secrets: secrets,
        store: store,
        builtIn: manifestSource(builtInManifestPath),
        clock: FixedClock(now),
      );
      final connections2 = hub(known: <ConnectionService>[slowWarehouse]);
      final w2 = wire(connections2);
      w2.registry.addListener(() => changes++);
      final turn = w2.controller.handle('где лежит 64115');
      await Future<void>.delayed(Duration.zero);
      expect(w2.controller.midTurn, isTrue);
      await connections2.add(await connections2.probe('https://crm.example/'));
      // Ход ещё идёт — набор прежний.
      expect(
        w2.registry.connectors.map((c) => c.info.id),
        <String>['tasks', 'warehouse'],
      );
      gate.complete();
      final reply = await turn;
      expect(reply.intent, 'warehouse.where');
      expect(w2.controller.midTurn, isFalse);
      expect(
        w2.registry.connectors.map((c) => c.info.id),
        <String>['tasks', 'warehouse', 'testcrm'],
      );
      expect(changes, 1);
      expect(
        w2.registry.replies.neutral.entries.containsKey('testcrm.answer'),
        isTrue,
      );
      final client = await w2.controller.handle('найди клиента Тестов');
      expect(client.intent, 'testcrm.client');

      // Между ходами — сразу.
      await connections2.remove('testcrm');
      expect(
        w2.registry.connectors.map((c) => c.info.id),
        <String>['tasks', 'warehouse'],
      );
      expect(
        w2.registry.replies.neutral.entries.containsKey('testcrm.answer'),
        isFalse,
      );
      final gone = await w2.controller.handle('найди клиента Тестов');
      expect(gone.intent, isNot('testcrm.client'));
      // Карточка из истории с удалённым приложением — без действий.
      expect(w2.controller.openForm('testcrm'), isNull);
      expect(DutyZones.dutyOf('testcrm'), isNot(DutyZones.dutyOf('warehouse')));
      w.assembly.detach();
      w2.assembly.detach();
    });

    test('карточка ответа удалённого приложения читается из истории', () {
      const card = WarehouseCard(
        connector: 'testcrm',
        command: 'client',
        title: 'Найти клиента',
        say: '«тестов»: 1 клиент.',
        rows: <WarehouseRow>[WarehouseRow(title: 'Тестов Т. Т.')],
      );
      final again = WarehouseCard.fromJson(card.toJson())!;
      expect(again.connector, 'testcrm');
      expect(again.rows.single.title, 'Тестов Т. Т.');
    });
  });
}

/// Сеть, которая ждёт [gate] перед ответом.
final class _SlowTransport implements HttpTransport {
  _SlowTransport(this.inner, this.gate);

  final HttpTransport inner;
  final Future<void> gate;

  @override
  Future<HttpResponseData> send(HttpRequestData request) async {
    await gate;
    return inner.send(request);
  }
}
