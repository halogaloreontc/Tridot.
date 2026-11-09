import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/personas/persona.dart';
import 'package:local_assistant/core/replies/reply_template.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';

import '../fakes.dart';
import 'fixtures.dart';

const String fakeToken = 'fake-token-not-real';

/// Склад в маршрутизаторе: ответ голосом помощника, «как дела» со сбоем.
void main() {
  final now = DateTime(2026, 11, 2, 16, 30);

  AssistantController controller(
    HttpResponseData Function(HttpRequestData r) respond,
  ) {
    final warehouse = warehouseConnector(
      transport: FakeHttpTransport(respond),
      secrets: InMemorySecretStore(<String, String>{
        'warehouse.token': fakeToken,
      }),
      record: connectedRecord(),
    );
    final registry = ExtensionRegistry(
      connectors: <Connector>[warehouse, TalkConnector()],
      choice: const ExtensionChoice(enabled: <String>{'warehouse'}),
    );
    return AssistantController(extensions: registry, clock: FixedClock(now));
  }

  HttpResponseData stock(HttpRequestData _) => HttpResponseData(
        statusCode: 200,
        body: File('test/fixtures/assistant/responses/ask_stock_more.json')
            .readAsStringSync(),
      );

  test('«где лежит 64115» — факт склада голосом Liorio и Noda', () async {
    final assistant = controller(stock);
    final rio = await assistant.handle('где лежит 64115');
    expect(rio.intent, 'warehouse.where');
    expect(rio.personaId, 'rio');
    expect(rio.message, startsWith('«товар»: 30 позиций'));
    expect(rio.message, endsWith('Показаны не все — уточните запрос.'));

    assistant.personas = const PersonaSettings(
      mainPersona: 'noda',
      address: ReplyAddress.informal,
    );
    final noda = await assistant.handle('где лежит 64115');
    expect(noda.personaId, 'noda');
    expect(noda.message, startsWith('«товар»: 30 позиций'));
    expect(noda.message, endsWith('уточни запрос.'));
    expect(noda.message, isNot(contains(fakeToken)));
  });

  test('«привет» — беседа, а не справка склада', () async {
    final reply = await controller(stock).handle('привет');
    expect(reply.intent, startsWith('talk.'));
  });

  test('«как дела» со складом без связи — «Склад» не работает', () async {
    final assistant = controller(
      (_) => throw const SocketException('нет сети'),
    );
    final failed = await assistant.handle('где лежит 64115');
    expect(failed.replyId, 'warehouse.offline');
    final status = await assistant.handle('как дела');
    expect(status.message, contains('«Склад» не работает: нет связи'));
  });

  test('ошибка сервера в ответе — текст каталога, без тела ответа', () async {
    final assistant = controller(
      (_) => HttpResponseData(
        statusCode: 500,
        body: jsonEncode(<String, Object?>{'error': 'Сбой: подробности'}),
      ),
    );
    final reply = await assistant.handle('где лежит 64115');
    expect(reply.replyId, 'warehouse.serverError');
    expect(reply.message, isNot(contains('подробности')));
  });
}
