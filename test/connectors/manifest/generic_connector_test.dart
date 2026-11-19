import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/manifest/connection.dart';
import 'package:local_assistant/core/connectors/manifest/connection_slots.dart';
import 'package:local_assistant/core/connectors/manifest/manifest_connector.dart';
import 'package:local_assistant/core/connectors/manifest/manifest_format.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/scenario/route_policy.dart';
import 'package:local_assistant/core/services/clock.dart';

import '../fakes.dart';
import 'fixtures.dart';

/// Синтетическая CRM `testcrm` (ADR-039): слот из профиля описания,
/// чтение через [ManifestConnector] и спор со складом. Данные выдуманы,
/// секреты — заведомо поддельные. В корпус testcrm не входит.
const String testCrmPath = 'test/fixtures/assistant/testcrm.json';
const String fakeCrmToken = 'fake-crm-token-not-real';

final DateTime now = DateTime(2026, 11, 2, 16, 30);
final Uri crmBase = Uri.parse('https://crm.example/');

ManifestDescription crmDescription() => ManifestDescription.parse(
      File(testCrmPath).readAsStringSync(),
      appId: 'testcrm',
    );

ConnectionSlot crmSlot() =>
    ConnectionSlot.generic(crmDescription().profile!, 'testcrm');

ManifestConnector crmConnector({
  HttpTransport? transport,
  SecretStore? secrets,
  bool connected = true,
}) {
  final slot = crmSlot();
  return ManifestConnector(
    slot: slot,
    description: crmDescription(),
    transport: transport ?? const OfflineTransport(),
    secrets: secrets ??
        InMemorySecretStore(<String, String>{slot.tokenKey: fakeCrmToken}),
    record: connected
        ? ConnectionRecord(appId: 'testcrm', baseUri: crmBase, login: 'tester')
        : null,
  );
}

void main() {
  ConnectorMatch? match(ManifestConnector c, String text) =>
      c.match(Utterance.analyze(text, now: now));

  AssistantSession session(List<Connector> connectors) => AssistantSession(
        clock: FixedClock(now),
        replies: ExtensionRegistry(connectors: connectors).replies,
      );

  group('коннектор по слоту из профиля', () {
    test('паспорт: id, название, записи каталога', () {
      final c = crmConnector();
      expect(c.info.id, 'testcrm');
      expect(c.info.title, 'Автосервис');
      expect(c.info.access, ConnectorAccess.readOnly);
      expect(c.info.replies.keys, everyElement(startsWith('testcrm.')));
      expect(
        () => ExtensionRegistry(
          connectors: <Connector>[warehouseConnector(), c],
        ),
        returnsNormally,
      );
    });

    test('команда чтения: запрос, заголовок и ответ', () async {
      final transport = FakeHttpTransport(
        (_) => HttpResponseData(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{
            'ok': true,
            'q': 'Тестов',
            'count': 2,
            'items': <Object?>[
              <String, Object?>{'name': 'Тестов Т. Т.', 'car': 'Тест-1'},
              <String, Object?>{'name': 'Тестова А. А.', 'car': 'Тест-2'},
            ],
          }),
        ),
      );
      final c = crmConnector(transport: transport);
      final m = match(c, 'найди клиента Тестов')!;
      expect(m.connectorId, 'testcrm');
      expect(m.commandId, 'testcrm.client');
      final reply = await c.run(m, session(<Connector>[c]));
      final request = transport.requests.single;
      expect(
        request.uri.toString(),
        'https://crm.example/assist.php?action=ask_client',
      );
      expect(request.headers['X-Crm-Token'], fakeCrmToken);
      expect(jsonDecode(request.body!), <String, Object?>{'q': 'тестов'});
      expect(reply.status, AssistantStatus.completed);
      expect(reply.replyId, 'testcrm.answer');
      expect(reply.message, startsWith('«Тестов»: 2 клиента.'));
      expect(reply.message, contains('Тестов Т. Т.'));
      expect(reply.message, isNot(contains(fakeCrmToken)));
    });

    test('ошибка сервера — голосом «Tridot» с именем приложения', () async {
      final transport = FakeHttpTransport(
        (_) => HttpResponseData(
          statusCode: 400,
          body: jsonEncode(<String, Object?>{'error': 'плохой запрос'}),
        ),
      );
      final c = crmConnector(transport: transport);
      final reply = await c.run(
        match(c, 'найди клиента Тестов')!,
        session(<Connector>[c]),
      );
      expect(reply.replyId, 'testcrm.serverSaid');
      expect(reply.message, 'Автосервис ответил: плохой запрос');
    });

    test('без подключения — путь к подключению приложения', () async {
      final c = crmConnector(connected: false);
      final reply = await c.run(
        match(c, 'найди клиента Тестов')!,
        session(<Connector>[c]),
      );
      expect(reply.replyId, 'testcrm.notConnected');
      expect(
        reply.message,
        'Автосервис не подключён. Подключите его: Мой Связной → Помощники → '
        'Подключения → Автосервис.',
      );
    });

    test('справка своими фразами и обращение', () {
      final c = crmConnector();
      expect(match(c, 'что умеет автосервис')?.commandId, 'testcrm.help');
      expect(match(c, 'помощь по автосервису')?.commandId, 'testcrm.help');
      final addressed = match(c, 'в автосервисе найди клиента Тестов')!;
      expect(addressed.commandId, 'testcrm.client');
      expect(addressed.aliased, isTrue);
      expect(match(c, 'сервис, клиент Тестов')?.aliased, isTrue);
      expect(match(c, 'найди клиента Тестов')?.aliased, isFalse);
    });
  });

  group('два приложения: обращение решает спор', () {
    final warehouse = warehouseConnector(record: connectedRecord());
    final crm = crmConnector();

    RouteDecision route(String text) => RoutePolicy.pick(<ConnectorMatch>[
          for (final c in <ManifestConnector>[warehouse, crm])
            if (match(c, text) case final ConnectorMatch m) m,
        ]);

    test('без обращения и при равной уверенности — уточнение', () {
      final decision = route('найди 64115');
      expect(decision.isAmbiguous, isTrue);
      expect(
        <String>{
          decision.first!.connectorId,
          decision.second!.connectorId,
        },
        <String>{'warehouse', 'testcrm'},
      );
    });

    test('с обращением — тому, к кому обратились', () {
      expect(route('в автосервисе найди 64115').winner?.connectorId, 'testcrm');
      expect(route('сервис, найди 64115').winner?.connectorId, 'testcrm');
      expect(route('на складе найди 64115').winner?.connectorId, 'warehouse');
      expect(route('склад, найди 64115').winner?.connectorId, 'warehouse');
    });

    test('обращение важнее уверенности', () {
      final decision = RoutePolicy.pick(const <ConnectorMatch>[
        ConnectorMatch(
          connectorId: 'warehouse',
          commandId: 'warehouse.where',
          confidence: 0.95,
        ),
        ConnectorMatch(
          connectorId: 'testcrm',
          commandId: 'testcrm.client',
          confidence: 0.8,
          aliased: true,
        ),
      ]);
      expect(decision.winner?.connectorId, 'testcrm');
    });

    test('после правила паролей', () {
      final decision = RoutePolicy.pick(const <ConnectorMatch>[
        ConnectorMatch(
          connectorId: RoutePolicy.passwordsId,
          commandId: 'passwords.add',
          confidence: 0.9,
        ),
        ConnectorMatch(
          connectorId: 'testcrm',
          commandId: 'testcrm.client',
          confidence: 0.95,
          aliased: true,
        ),
      ]);
      expect(decision.winner?.connectorId, RoutePolicy.passwordsId);
    });
  });

  test('слот склада по-прежнему константа', () {
    expect(
      identical(ConnectionSlots.all.single, ConnectionSlots.warehouse),
      isTrue,
    );
  });
}
