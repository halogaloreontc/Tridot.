import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/manifest/connection.dart';
import 'package:local_assistant/core/connectors/manifest/connection_service.dart';
import 'package:local_assistant/core/connectors/manifest/connection_slots.dart';
import 'package:local_assistant/core/connectors/manifest/description_authority.dart';
import 'package:local_assistant/core/connectors/manifest/manifest_format.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/services/clock.dart';

import '../fakes.dart';
import 'fixtures.dart';

/// Заведомо поддельные значения: настоящих секретов в тестах нет.
const String fakeToken = 'fake-token-not-real';
const String fakeSid = 'fake-sid-not-real';
const String code = '0123456789abcdef0123456789abcdef';

final DateTime now = DateTime(2026, 11, 2, 16, 30);

/// Описание 1.4.56 с правками [edit] — как будто его отдал сервер.
String _variant(void Function(Map<String, Object?> json) edit) {
  final json =
      jsonDecode(manifestSource(patchedManifestPath)) as Map<String, Object?>;
  edit(json);
  return jsonEncode(json);
}

List<Object?> _commands(Map<String, Object?> json) =>
    json['commands']! as List<Object?>;

Map<String, Object?> _command(Map<String, Object?> json, String id) =>
    _commands(json).cast<Map<String, Object?>>().firstWhere(
          (Map<String, Object?> c) => c['id'] == id,
        );

/// 1.4.60: новая фраза «где искать {q}», права те же.
final String newer = _variant((Map<String, Object?> j) {
  j['version'] = '1.4.60';
  (_command(j, 'where')['say']! as List<Object?>).add('где искать {q}');
});

/// 1.4.60, но просит запись: `item_delete` в `api.only` и команда с ним.
final String widening = _variant((Map<String, Object?> j) {
  j['version'] = '1.4.60';
  ((j['api']! as Map<String, Object?>)['only']! as List<Object?>)
      .add('item_delete');
  _commands(j).add(<String, Object?>{
    'id': 'drop',
    'title': 'Удалить',
    'say': <String>['удали {q}'],
    'slots': <String, Object?>{
      'q': <String, Object?>{'type': 'text'},
    },
    'access': 'staff',
    'call': <String, Object?>{
      'action': 'item_delete',
      'body': <String, Object?>{'q': '{q}'},
    },
    'answer': <String, Object?>{'say': 'Удалено'},
  });
});

ManifestDescription _parse(String source) => ManifestDescription.parse(
      source,
      appId: ConnectionSlots.warehouse.appId,
    );

HttpResponseData _json(int status, Map<String, Object?> body) =>
    HttpResponseData(statusCode: status, body: jsonEncode(body));

void main() {
  final builtIn = _parse(manifestSource(patchedManifestPath));

  group('сравнение версий', () {
    test('по числам, недостающее — ноль, без версии — самая старая', () {
      int cmp(String? a, String? b) =>
          DescriptionAuthority.compareVersions(a, b).sign;
      expect(cmp('1.4.60', '1.4.56'), 1);
      expect(cmp('1.4.56', '1.4.56'), 0);
      expect(cmp('1.4.9', '1.4.56'), -1);
      expect(cmp('1.10', '1.9.9'), 1);
      expect(cmp('1.4', '1.4.0'), 0);
      expect(cmp('1.4.56', null), 1);
      expect(cmp(null, '1.4.56'), -1);
      expect(cmp(null, null), 0);
      expect(cmp('1.5.0-beta', '1.4.56'), 0, reason: 'не сравнима');
      expect(cmp('2', 'x'), 0);
    });
  });

  group('выбор описания', () {
    test('новее и не шире — описание сервера', () {
      final pick = DescriptionAuthority.choose(
        builtIn: builtIn,
        server: _parse(newer),
      );
      expect(pick.origin, DescriptionOrigin.server);
      expect(pick.description!.version, '1.4.60');
      expect(pick.reason, contains('новее встроенного 1.4.56'));
    });

    test('старее, та же или без версии — встроенное', () {
      for (final (source, why) in <(String, String)>[
        (_variant((j) => j['version'] = '1.4.50'), 'не новее'),
        (manifestSource(patchedManifestPath), 'не новее'),
        (manifestSource(), 'нет версии'),
      ]) {
        final pick = DescriptionAuthority.choose(
          builtIn: builtIn,
          server: _parse(source),
        );
        expect(pick.origin, DescriptionOrigin.builtIn, reason: why);
        expect(pick.description, same(builtIn));
        expect(pick.reason, contains(why));
      }
    });

    test('расширяет права — встроенное, с названием действия', () {
      final server = _parse(widening);
      expect(DescriptionAuthority.widening(builtIn, server), <String>[
        'действия, которых нет во встроенном: item_delete',
      ]);
      final pick =
          DescriptionAuthority.choose(builtIn: builtIn, server: server);
      expect(pick.origin, DescriptionOrigin.builtIn);
      expect(pick.reason, contains('item_delete'));
    });

    test('другой api.url или параметр действия — расширение прав', () {
      // Список действий тот же, а адрес уже несёт своё действие:
      // «api.php?action=item_delete&a=ask_stock».
      final server = _parse(
        _variant((Map<String, Object?> j) {
          j['version'] = '1.4.60';
          final api = j['api']! as Map<String, Object?>;
          api['url'] = 'api.php?action=item_delete';
          api['action'] = <String, Object?>{'in': 'query', 'name': 'a'};
        }),
      );
      expect(server.only, builtIn.only);
      expect(DescriptionAuthority.widening(builtIn, server), <String>[
        'другой адрес api.url',
        'другой параметр действия api.action',
      ]);
      final pick =
          DescriptionAuthority.choose(builtIn: builtIn, server: server);
      expect(pick.origin, DescriptionOrigin.builtIn);
      expect(pick.description, same(builtIn));
      expect(pick.refused, contains('api.url'));
      expect(pick.reason, contains('расширяет права'));
      // Только адрес или только имя параметра — тоже.
      for (final edit in <void Function(Map<String, Object?>)>[
        (api) => api['url'] = 'api.php?x=1',
        (api) => api['url'] = 'other.php',
        (api) => api['action'] = <String, Object?>{'name': 'do'},
      ]) {
        final changed = _parse(
          _variant((Map<String, Object?> j) {
            j['version'] = '1.4.60';
            edit(j['api']! as Map<String, Object?>);
          }),
        );
        expect(DescriptionAuthority.widening(builtIn, changed), isNotEmpty);
      }
    });

    test('другие заголовки с ключами — расширение прав', () {
      for (final edit in <void Function(Map<String, Object?>)>[
        (headers) => headers['Authorization'] = r'Bearer {$token}',
        (headers) => headers['X-Wh-Sid'] = r'{$token}',
        (headers) => headers.remove('X-Wh-Sid'),
      ]) {
        final server = _parse(
          _variant((Map<String, Object?> j) {
            j['version'] = '1.4.60';
            edit(
              (j['auth']! as Map<String, Object?>)['headers']!
                  as Map<String, Object?>,
            );
          }),
        );
        expect(DescriptionAuthority.widening(builtIn, server), <String>[
          'другие заголовки auth.headers',
        ]);
        expect(
          DescriptionAuthority.choose(builtIn: builtIn, server: server).origin,
          DescriptionOrigin.builtIn,
        );
      }
    });

    test('действие входа или выхода командой не бывает', () {
      // Сервер убрал `auth.logout` и объявил `sess_end` обычной командой:
      // фраза из чата завершала бы сеанс пользователя на сервере.
      final logoutAsCommand = _variant((Map<String, Object?> j) {
        j['version'] = '1.4.60';
        (j['auth']! as Map<String, Object?>).remove('logout');
        ((j['api']! as Map<String, Object?>)['only']! as List<Object?>)
            .add('sess_end');
        _commands(j).add(<String, Object?>{
          'id': 'bye',
          'title': 'Утро',
          'say': <String>['что пришло сегодня утром'],
          'access': 'staff',
          'call': <String, Object?>{'action': 'sess_end'},
          'answer': <String, Object?>{'say': 'Готово'},
        });
      });
      final errors = ManifestDescription.check(
        jsonDecode(logoutAsCommand),
        appId: ConnectionSlots.warehouse.appId,
      );
      expect(errors, contains(contains('api.only: «sess_end»')));
      expect(errors, contains(contains('действие входа «sess_end»')));
      expect(() => _parse(logoutAsCommand), throwsA(isA<ManifestException>()));
      // То же с получением ключа по логину и входом по ссылке.
      for (final action in <String>['auth_check', 'qr_take']) {
        final source = _variant((Map<String, Object?> j) {
          j['version'] = '1.4.60';
          final auth = j['auth']! as Map<String, Object?>;
          auth.remove('qr');
          (auth['credentials']! as Map<String, Object?>).remove('sid');
          ((j['api']! as Map<String, Object?>)['only']! as List<Object?>)
              .add(action);
        });
        expect(
          () => _parse(source),
          throwsA(isA<ManifestException>()),
          reason: action,
        );
      }
      // В своём разделе `auth` эти действия по-прежнему разрешены.
      expect(DescriptionAuthority.widening(builtIn, _parse(newer)), isEmpty);
    });

    test('не прошло проверку — встроенное и причина', () {
      final pick = DescriptionAuthority.choose(
        builtIn: builtIn,
        serverError: 'auth.qr.action',
      );
      expect(pick.origin, DescriptionOrigin.builtIn);
      expect(pick.reason, contains('не принято (auth.qr.action)'));
    });

    test('встроенного нет — сервер; нет ничего — пусто', () {
      expect(
        DescriptionAuthority.choose(server: builtIn).origin,
        DescriptionOrigin.server,
      );
      expect(DescriptionAuthority.choose().origin, DescriptionOrigin.none);
    });
  });

  group('подключение', () {
    late InMemorySecretStore secrets;
    late InMemoryConnectionStore store;
    late String served;
    late FakeHttpTransport transport;

    setUp(() {
      secrets = InMemorySecretStore();
      store = InMemoryConnectionStore();
      served = manifestSource();
      transport = FakeHttpTransport((HttpRequestData r) {
        if (r.uri.path.endsWith('assistant.json')) {
          return HttpResponseData(statusCode: 200, body: served);
        }
        return switch (r.uri.queryParameters['action']) {
          'qr_take' => _json(200, <String, Object?>{
              'ok': true,
              'token': fakeToken,
              'sid': fakeSid,
              'login': 'ivanov',
            }),
          'sess_end' => _json(200, <String, Object?>{'ok': true}),
          _ => _json(400, <String, Object?>{'error': 'Неизвестное действие'}),
        };
      });
    });

    Future<ConnectionService> restore() => ConnectionService.restore(
          slot: ConnectionSlots.warehouse,
          transport: transport,
          secrets: secrets,
          store: store,
          builtIn: manifestSource(patchedManifestPath),
          clock: FixedClock(now),
        );

    List<String?> actions() => <String?>[
          for (final r in transport.requests) r.uri.queryParameters['action'],
        ];

    test('старый сервер (без version и auth.qr): вход и выход по встроенному',
        () async {
      final service = await restore();
      expect(service.descriptionOrigin, DescriptionOrigin.builtIn);
      final result = await service.connectByLink(
        'https://warehouse.example/#qr=$code',
      );
      expect(result.ok, isTrue, reason: result.message);
      expect(service.descriptionOrigin, DescriptionOrigin.builtIn);
      expect(service.descriptionReason, contains('нет версии'));
      expect(service.description!.version, '1.4.56');
      expect(service.description!.logout, isNotNull);
      await service.logout();
      expect(actions(), containsAllInOrder(<String>['qr_take', 'sess_end']));
      expect(await secrets.read('warehouse.token'), isNull);
    });

    test('новее и не шире: описание сервера в работе и после перезапуска',
        () async {
      served = newer;
      final service = await restore();
      final result = await service.connectByLink(
        'https://warehouse.example/#qr=$code',
      );
      expect(result.ok, isTrue, reason: result.message);
      expect(service.descriptionOrigin, DescriptionOrigin.server);
      expect(
        service.connector
            .match(Utterance.analyze('где искать 64115', now: now)),
        isNotNull,
      );
      final again = await restore();
      expect(again.descriptionOrigin, DescriptionOrigin.server);
      expect(again.description!.version, '1.4.60');
    });

    test('сервер расширяет права: встроенное, запись не зовётся', () async {
      served = widening;
      final service = await restore();
      final result = await service.connectByLink(
        'https://warehouse.example/#qr=$code',
      );
      expect(result.ok, isTrue, reason: result.message);
      expect(service.descriptionOrigin, DescriptionOrigin.builtIn);
      expect(service.descriptionReason, contains('item_delete'));
      expect(service.description!.command('drop'), isNull);
      expect(
        service.connector.match(Utterance.analyze('удали 64115', now: now)),
        isNull,
      );
      final again = await restore();
      expect(again.descriptionOrigin, DescriptionOrigin.builtIn);
    });

    test('описание сервера не прошло проверку: вход по встроенному', () async {
      served = _variant((Map<String, Object?> j) {
        j['version'] = '1.4.60';
        ((j['auth']! as Map<String, Object?>)['qr']!
            as Map<String, Object?>)['action'] = 'user_set_role';
      });
      final service = await restore();
      final result = await service.connectByLink(
        'https://warehouse.example/#qr=$code',
      );
      expect(result.ok, isTrue, reason: result.message);
      expect(service.descriptionOrigin, DescriptionOrigin.builtIn);
      expect(service.manifestError, startsWith('Описание сервера не принято'));
      expect(actions(), isNot(contains('user_set_role')));
      expect(store.manifests, isEmpty, reason: 'битое в кэш не идёт');
    });

    test('чужое приложение по адресу — вход не начинается', () async {
      served = jsonEncode(<String, Object?>{
        'format': 'assistant/1',
        'app': <String, Object?>{'id': 'expeora'},
      });
      final service = await restore();
      final result = await service.connectByLink(
        'https://warehouse.example/#qr=$code',
      );
      expect(result.ok, isFalse);
      expect(result.message, startsWith('Описание не принято'));
      expect(actions(), isNot(contains('qr_take')));
      expect(service.record.connected, isFalse);
    });

    test('«Обновить описание»: новое принимается, старое — нет', () async {
      final service = await restore();
      await service.connectByLink('https://warehouse.example/#qr=$code');
      served = newer;
      final updated = await service.refreshManifest();
      expect(updated.ok, isTrue);
      expect(updated.message, contains('1.4.60'));
      expect(service.descriptionOrigin, DescriptionOrigin.server);
      served = _variant((j) => j['version'] = '1.4.50');
      final older = await service.refreshManifest();
      expect(older.ok, isTrue);
      expect(older.message, contains('не новее'));
      expect(service.descriptionOrigin, DescriptionOrigin.builtIn);
      expect(service.description!.version, '1.4.56');
      expect(service.record.level, ConnectionLevel.staff);
    });
  });

  group('описание сервера: права, кэш и перезапуск', () {
    late InMemorySecretStore secrets;
    late InMemoryConnectionStore store;

    /// Что отдаёт каждый сервер: хост → (текст описания, ETag).
    late Map<String, (String, String)> served;
    late FakeHttpTransport transport;

    setUp(() {
      secrets = InMemorySecretStore();
      store = InMemoryConnectionStore();
      served = <String, (String, String)>{};
      transport = FakeHttpTransport((HttpRequestData r) {
        if (r.uri.path.endsWith('assistant.json')) {
          final (body, etag) = served[r.uri.host]!;
          if (r.headers['If-None-Match'] == etag) {
            return const HttpResponseData(statusCode: 304, body: '');
          }
          return HttpResponseData(
            statusCode: 200,
            body: body,
            headers: <String, String>{'etag': etag},
          );
        }
        return switch (r.uri.queryParameters['action']) {
          'qr_take' => _json(200, <String, Object?>{
              'ok': true,
              'token': fakeToken,
              'sid': fakeSid,
              'login': 'ivanov',
            }),
          'ask_stock' => _json(200, <String, Object?>{
              'ok': true,
              'items': <Object?>[],
            }),
          _ => _json(200, <String, Object?>{'ok': true}),
        };
      });
    });

    Future<ConnectionService> restore() => ConnectionService.restore(
          slot: ConnectionSlots.warehouse,
          transport: transport,
          secrets: secrets,
          store: store,
          builtIn: manifestSource(patchedManifestPath),
          clock: FixedClock(now),
        );

    Utterance say(String text) => Utterance.analyze(text, now: now);

    /// Всё, что должно совпадать сейчас и после перезапуска.
    Map<String, Object?> state(ConnectionService service) => <String, Object?>{
          'origin': service.descriptionOrigin,
          'version': service.description?.version,
          'apiUrl': service.description?.apiUrl,
          'manifest': service.record.manifest.toJson(),
          'cache': store.manifests['halowarekeep'],
          'артикул': service.connector.match(say('артикул стул')) != null,
        };

    /// 1.4.60 с фразой, которой во встроенном описании нет: «артикул {q}».
    final fresh = _variant((Map<String, Object?> j) {
      j['version'] = '1.4.60';
      (_command(j, 'where')['say']! as List<Object?>).add('артикул {q}');
    });

    /// 1.5.0 с действием входа, которого приложение не знает.
    final broken = _variant((Map<String, Object?> j) {
      j['version'] = '1.5.0';
      ((j['auth']! as Map<String, Object?>)['qr']!
          as Map<String, Object?>)['action'] = 'qr_take2';
    });

    /// 1.4.61 с тем же списком действий, но адресом с чужим действием.
    final redirected = _variant((Map<String, Object?> j) {
      j['version'] = '1.4.61';
      final api = j['api']! as Map<String, Object?>;
      api['url'] = 'api.php?action=item_delete';
      api['action'] = <String, Object?>{'in': 'query', 'name': 'a'};
    });

    test('подменённый адрес API: запрос идёт только по встроенному', () async {
      served['warehouse.example'] =
          (manifestSource(patchedManifestPath), '"a"');
      final service = await restore();
      await service.connectByLink('https://warehouse.example/#qr=$code');
      served['warehouse.example'] = (redirected, '"b"');
      final result = await service.refreshManifest();
      expect(result.ok, isTrue);
      expect(result.message, isNot(contains('обновлено')));
      expect(service.descriptionOrigin, DescriptionOrigin.builtIn);
      expect(service.descriptionReason, contains('api.url'));
      expect(service.manifestError, contains('расширяет права'));
      expect(service.description!.apiUrl, 'api.php');
      transport.requests.clear();
      final assistant = AssistantController(
        extensions: ExtensionRegistry(
          connectors: <Connector>[service.connector],
          choice: const ExtensionChoice(
            enabledRoles: <String>{Roles.storekeeperId},
          ),
        ),
        clock: FixedClock(now),
      );
      final response = await assistant.handle('где лежит 64115');
      expect(response.intent, 'warehouse.where');
      final call = transport.requests
          .lastWhere((HttpRequestData r) => r.method == 'POST')
          .uri;
      expect(call.path, '/api.php');
      expect(call.queryParameters, <String, String>{'action': 'ask_stock'});
      // И после перезапуска — то же: подменённое в кэш не попало.
      final again = await restore();
      expect(again.descriptionOrigin, DescriptionOrigin.builtIn);
      expect(again.description!.apiUrl, 'api.php');
      expect(store.manifests['halowarekeep'], isNot(contains('item_delete')));
    });

    test('вход вручную: проба пароля не идёт по подменённому адресу', () async {
      served['warehouse.example'] = (redirected, '"b"');
      final service = await restore();
      final result = await service.connectManual(
        address: 'https://warehouse.example/',
        password: fakeToken,
      );
      expect(result.ok, isTrue, reason: result.message);
      for (final r in transport.requests.where((r) => r.method == 'POST')) {
        expect(r.uri.queryParameters.keys, <String>['action']);
        expect(r.uri.queryParameters['action'], isNot('item_delete'));
      }
    });

    test('не принятое описание не заменяет принятое: сейчас и после запуска',
        () async {
      // (1) Сервер отдаёт 1.4.60 — принято.
      served['warehouse.example'] = (fresh, '"v160"');
      final service = await restore();
      await service.connectByLink('https://warehouse.example/#qr=$code');
      expect(service.descriptionOrigin, DescriptionOrigin.server);
      final accepted = state(service);
      expect(accepted['version'], '1.4.60');
      expect(accepted['артикул'], isTrue);
      expect(service.record.manifest.etag, '"v160"');
      expect(
        service.record.manifest.cachedFrom,
        'https://warehouse.example/assistant.json',
      );

      // (2) Сервер перешёл на 1.5.0, которое не проходит проверку.
      served['warehouse.example'] = (broken, '"v150"');
      final refreshed = await service.refreshManifest();
      expect(refreshed.ok, isTrue);
      expect(state(service), accepted, reason: 'прежнее осталось целиком');
      expect(service.manifestError, startsWith('Описание сервера не принято'));
      expect(service.descriptionReason, contains('описание сервера 1.4.60'));
      expect(service.descriptionReason, contains('не принято'));
      expect(service.record.manifest.etag, '"v160"', reason: 'не «v150»');

      // (3) Перезапуск: то же самое.
      final again = await restore();
      expect(state(again), accepted);

      // (4) Новая проверка не получает «не изменилось» про чужой ответ.
      transport.requests.clear();
      final later = await again.refreshManifest();
      expect(later.message, isNot('Описание не изменилось.'));
      expect(
        transport.requests.single.headers['If-None-Match'],
        '"v160"',
      );
      expect(state(again), accepted);
      expect(again.manifestError, isNotNull);

      // То же с описанием, которое расширяет права.
      served['warehouse.example'] = (redirected, '"v161"');
      await again.refreshManifest();
      expect(state(again), accepted);
      expect(state(await restore()), accepted);

      // Сервер исправился — новое принимается.
      final fixed = _variant((Map<String, Object?> j) {
        j['version'] = '1.4.62';
        (_command(j, 'where')['say']! as List<Object?>).add('артикул {q}');
      });
      served['warehouse.example'] = (fixed, '"v162"');
      final updated = await again.refreshManifest();
      expect(updated.message, 'Описание обновлено: версия 1.4.62.');
      expect(again.manifestError, isNull);
      expect(again.record.manifest.etag, '"v162"');
      expect(state(await restore()), state(again));
      // И «не изменилось» теперь честное.
      expect(
        (await again.refreshManifest()).message,
        'Описание не изменилось.',
      );
    });

    test('первое описание сервера не принято: встроенное, ETag не запомнен',
        () async {
      served['warehouse.example'] = (broken, '"v150"');
      final service = await restore();
      final result =
          await service.connectByLink('https://warehouse.example/#qr=$code');
      expect(result.ok, isTrue, reason: result.message);
      expect(service.descriptionOrigin, DescriptionOrigin.builtIn);
      expect(service.record.manifest.version, '1.4.56');
      expect(service.record.manifest.etag, isNull);
      expect(service.record.manifest.cachedFrom, isNull);
      expect(store.manifests, isEmpty);
      final live = state(service);
      expect(state(await restore()), live);
      // Проверка идёт без If-None-Match: сравнивать не с чем.
      transport.requests.clear();
      await service.refreshManifest();
      expect(
        transport.requests.single.headers.containsKey('If-None-Match'),
        isFalse,
      );
      expect(state(service), live);
    });

    test('кэш привязан к серверу: другой склад чужое описание не получает',
        () async {
      served['a.example'] = (fresh, '"a160"');
      served['b.example'] = (broken, '"b150"');
      final service = await restore();
      await service.connectByLink('https://a.example/#qr=$code');
      expect(service.descriptionOrigin, DescriptionOrigin.server);
      await service.logout();
      expect(store.manifests['halowarekeep'], isNotNull, reason: 'кэш остался');

      final result = await service.connectByLink('https://b.example/#qr=$code');
      expect(result.ok, isTrue, reason: result.message);
      expect(service.record.baseUri, Uri.parse('https://b.example/'));
      expect(service.descriptionOrigin, DescriptionOrigin.builtIn);
      expect(service.description!.version, '1.4.56');
      expect(service.connector.match(say('артикул стул')), isNull);
      expect(service.record.manifest.cachedFrom, isNull);
      expect(service.record.manifest.etag, isNull);

      // После перезапуска — то же: описание a.example не управляет b.example.
      final again = await restore();
      expect(again.descriptionOrigin, DescriptionOrigin.builtIn);
      expect(again.description!.version, '1.4.56');
      expect(again.connector.match(say('артикул стул')), isNull);
      expect(again.record.manifest.toJson(), service.record.manifest.toJson());

      // Своё принятое описание b.example получает как обычно.
      final own = _variant((Map<String, Object?> j) {
        j['version'] = '1.4.70';
      });
      served['b.example'] = (own, '"b170"');
      await again.refreshManifest();
      expect(again.description!.version, '1.4.70');
      expect(
        again.record.manifest.cachedFrom,
        'https://b.example/assistant.json',
      );
      expect((await restore()).description!.version, '1.4.70');
    });

    test('кэш без привязки (до ADR-012) в работу не идёт и перекачивается',
        () async {
      store.manifests['halowarekeep'] = fresh;
      await store.save(
        connectedRecord().copyWith(
          manifest: const ManifestMeta(version: '1.4.60', etag: '"v160"'),
        ),
      );
      await secrets.write('warehouse.token', fakeToken);
      served['warehouse.example'] = (fresh, '"v160"');
      final service = await restore();
      expect(service.descriptionOrigin, DescriptionOrigin.builtIn);
      expect(service.record.manifest.etag, isNull);
      final refreshed = await service.refreshManifest();
      expect(refreshed.message, 'Описание обновлено: версия 1.4.60.');
      expect(service.descriptionOrigin, DescriptionOrigin.server);
      expect((await restore()).descriptionOrigin, DescriptionOrigin.server);
    });
  });
}
