import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/login_link.dart';
import 'package:local_assistant/core/connectors/manifest/connection.dart';
import 'package:local_assistant/core/connectors/manifest/manifest_connector.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/personas/persona.dart';
import 'package:local_assistant/core/replies/reply_template.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import '../fakes.dart';
import 'fixtures.dart';

/// Заведомо поддельные значения: настоящих секретов в тестах нет.
const String fakeToken = 'fake-token-not-real';
const String fakeSid = 'fake-sid-not-real';
const String code = '0123456789abcdef0123456789abcdef';

/// Склад рядом с задачами, калькулятором и беседой: обращение «склад, …»
/// не отнимает чужие фразы, здоровье после устаревшего ключа, голос
/// цены, ссылка входа в чате.
void main() {
  final now = DateTime(2026, 11, 2, 16, 30);

  HttpResponseData stock(HttpRequestData _) => HttpResponseData(
        statusCode: 200,
        body: File('test/fixtures/assistant/responses/ask_stock_more.json')
            .readAsStringSync(),
      );

  (AssistantController, ManifestConnector) build({
    bool warehouse = true,
    HttpResponseData Function(HttpRequestData r)? respond,
    bool sid = false,
  }) {
    final clock = FixedClock(now);
    final tasks = TaskService(
      repository: InMemoryTaskRepository(),
      clock: clock,
    );
    final connector = warehouseConnector(
      transport: FakeHttpTransport(respond ?? stock),
      secrets: InMemorySecretStore(<String, String>{
        'warehouse.token': fakeToken,
        if (sid) 'warehouse.sid': fakeSid,
      }),
      record: connectedRecord(
        level: sid ? ConnectionLevel.staff : ConnectionLevel.shared,
      ),
    );
    final registry = ExtensionRegistry(
      connectors: <Connector>[
        TasksConnector(
          taskService: tasks,
          parser: ScenarioParser(clock: clock),
        ),
        connector,
        const CalculatorConnector(),
        TalkConnector(taskService: tasks),
      ],
      // Склад входит в роль «Кладовщик» (ADR-012): включён вместе с ней.
      choice: ExtensionChoice(
        enabledRoles: <String>{if (warehouse) Roles.storekeeperId},
      ),
    );
    return (
      AssistantController(extensions: registry, clock: clock),
      connector,
    );
  }

  group('«склад, …» с командой задач или репликой — не товар', () {
    // Совпадение склада для фразы: null — склад её не берёт.
    final connector = warehouseConnector(record: connectedRecord());
    ConnectorMatch? match(String text) =>
        connector.match(Utterance.analyze(text, now: now));

    for (final phrase in <String>[
      'склад, напомни купить хлеб',
      'на складе напомни проверить стулья',
      'склад, напомнить купить хлеб',
      'склад, запиши купить хлеб',
      'склад, добавь задачу проверить стулья',
      'склад, готово',
      'склад, спасибо',
      'склад, да',
      'склад, нет',
      'склад, пока',
      'склад, здравствуй',
      'склад, хорошо',
      'склад, ок',
      'склад, спасибо большое',
    ]) {
      test('«$phrase» — не склад', () {
        expect(match(phrase), isNull);
      });
    }

    for (final (phrase, command) in <(String, String)>[
      ('склад, стул венский', 'warehouse.where'),
      ('на складе стулья', 'warehouse.where'),
      ('склад, 64115', 'warehouse.where'),
      ('склад, где лежит 64115', 'warehouse.where'),
    ]) {
      test('«$phrase» — $command', () {
        expect(match(phrase)?.commandId, command);
      });
    }

    test('маршрутизация та же, что без склада', () async {
      for (final phrase in <String>[
        'склад, напомни купить хлеб',
        'на складе напомни проверить стулья',
        'склад, запиши купить хлеб',
        'склад, готово',
        'склад, спасибо',
      ]) {
        final (off, _) = build(warehouse: false);
        final (on, _) = build();
        final without = await off.handle(phrase);
        final with_ = await on.handle(phrase);
        expect(with_.intent, without.intent, reason: phrase);
        expect(with_.intent, isNot('router.ambiguous'), reason: phrase);
        expect(with_.intent, isNot(startsWith('warehouse.')), reason: phrase);
      }
    });
  });

  test('ключ устарел: ответ без ключа не делает склад здоровым', () async {
    final (assistant, connector) = build(
      sid: true,
      respond: (HttpRequestData r) =>
          r.uri.queryParameters['action'] == 'ask_arrivals'
              ? HttpResponseData(
                  statusCode: 403,
                  body: jsonEncode(<String, Object?>{
                    'error': 'Нужен вход',
                    'need': 'login',
                  }),
                )
              : stock(r),
    );
    final expired = await assistant.handle('что пришло сегодня');
    expect(expired.replyId, 'warehouse.auth.expired');
    expect((await connector.health()).status, HealthStatus.degraded);

    final found = await assistant.handle('где лежит 64115');
    expect(found.intent, 'warehouse.where');
    expect(connector.record.failure, ConnectionFailure.expired);
    final health = await connector.health();
    expect(health.status, HealthStatus.degraded);
    expect(health.detail, contains('нужен новый вход'));
    final status = await assistant.handle('как дела');
    expect(status.message, contains('нужен новый вход'));
  });

  test('ключ снова годен: команда с ключом снимает «устарел»', () async {
    final (assistant, connector) = build(
      sid: true,
      respond: (HttpRequestData r) => HttpResponseData(
        statusCode: 200,
        body: File('test/fixtures/assistant/responses/ask_arrivals_today.json')
            .readAsStringSync(),
      ),
    );
    connector.record = connector.record.copyWith(
      failure: ConnectionFailure.expired,
      failureSince: now,
    );
    await assistant.handle('что пришло сегодня');
    expect(connector.record.failure, isNull);
  });

  test('цена — голосом помощника: на «ты» без «вы»', () async {
    final (assistant, _) = build();
    assistant.personas = const PersonaSettings(
      teamMode: TeamMode.duo,
      duoHelper: 'noda',
      address: ReplyAddress.informal,
    );
    final price = await assistant.handle('сколько стоит 64115');
    expect(price.replyId, 'warehouse.price');
    expect(price.message, contains('посмотри'));
    expect(price.message, isNot(contains('откройте')));
    expect(price.message, isNot(contains('помощник')));
  });

  group('ссылка входа в чате', () {
    const link = 'https://wh.example/#qr=$code';

    for (final warehouse in <bool>[true, false]) {
      test('подсказка, куда её нести (склад ${warehouse ? 'вкл' : 'выкл'})',
          () async {
        final (assistant, _) = build(
          warehouse: warehouse,
          respond: (_) => throw StateError('сеть не нужна'),
        );
        final reply = await assistant.handle(link);
        expect(reply.replyId, 'common.loginLink');
        expect(reply.message, contains('Настройки → Подключения'));
        expect(reply.message, isNot(contains(code)));
      });
    }

    test('код не попадает в историю: redact', () {
      expect(LoginLinks.contains(link), isTrue);
      expect(LoginLinks.redact(link), 'https://wh.example/#qr=…');
      expect(LoginLinks.redact('вот $link и всё'), isNot(contains(code)));
      expect(LoginLinks.contains('где лежит 64115'), isFalse);
      expect(LoginLinks.contains('https://wh.example/'), isFalse);
    });
  });
}
