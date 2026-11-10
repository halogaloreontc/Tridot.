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
        'item_delete',
      ]);
      final pick =
          DescriptionAuthority.choose(builtIn: builtIn, server: server);
      expect(pick.origin, DescriptionOrigin.builtIn);
      expect(pick.reason, contains('item_delete'));
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
}
