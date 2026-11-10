import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/manifest/manifest_connector.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/personas/persona.dart';
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

final DateTime now = DateTime(2026, 11, 2, 16, 30);

HttpResponseData _fixture(String name) => HttpResponseData(
      statusCode: 200,
      body: File('test/fixtures/assistant/responses/$name.json')
          .readAsStringSync(),
    );

final class _Setup {
  _Setup({bool connected = true, ExtensionChoice? choice}) {
    final clock = FixedClock(now);
    final tasks = TaskService(
      repository: InMemoryTaskRepository(),
      clock: clock,
    );
    transport = FakeHttpTransport(
      (HttpRequestData r) => switch (r.uri.queryParameters['action']) {
        'ask_arrivals' => _fixture('ask_arrivals_today'),
        _ => _fixture('ask_stock_sku'),
      },
    );
    secrets = InMemorySecretStore(<String, String>{
      if (connected) 'warehouse.token': fakeToken,
      if (connected) 'warehouse.sid': fakeSid,
    });
    warehouse = warehouseConnector(
      path: patchedManifestPath,
      transport: transport,
      secrets: secrets,
      record: connected ? connectedRecord() : null,
    );
    registry = ExtensionRegistry(
      connectors: <Connector>[
        TasksConnector(
          taskService: tasks,
          parser: ScenarioParser(clock: clock),
        ),
        warehouse,
        const CalculatorConnector(),
        TalkConnector(taskService: tasks),
      ],
      choice: choice ??
          const ExtensionChoice(enabledRoles: <String>{Roles.storekeeperId}),
    );
    assistant = AssistantController(extensions: registry, clock: clock);
  }

  late final FakeHttpTransport transport;
  late final InMemorySecretStore secrets;
  late final ManifestConnector warehouse;
  late final ExtensionRegistry registry;
  late final AssistantController assistant;

  Future<AssistantResponse> say(String text, {String? addressee}) =>
      assistant.handle(text, addressee: addressee);

  void role(String id, bool on) =>
      registry.apply(registry.roleChoiceWith(id, on));
}

void main() {
  group('«Кладовщик» включён, склад подключён', () {
    test('голый артикул — «где лежит», «сегодня» и «вчера» — приходы',
        () async {
      final s = _Setup();
      expect((await s.say('64115')).intent, 'warehouse.where');
      expect((await s.say('где лежит 64115')).intent, 'warehouse.where');
      expect((await s.say('сегодня')).intent, 'warehouse.today');
      expect((await s.say('вчера')).intent, 'warehouse.yesterday');
      expect(
        s.transport.requests.map((r) => r.uri.queryParameters['action']),
        <String>['ask_stock', 'ask_stock', 'ask_arrivals', 'ask_arrivals'],
      );
    });

    test('задачи, калькулятор и беседа не меняются', () async {
      final s = _Setup();
      final task = await s.say('Добавь задачу купить хлеб');
      expect(task.intent, 'task.create');
      expect((await s.say('сколько будет 2+2')).intent, 'calc.evaluate');
      expect((await s.say('привет')).intent, TalkConnector.greetCommand);
      expect(
        (await s.say('Добавь задачу сверить приход на сегодня')).intent,
        'task.create',
      );
      expect(s.transport.requests, isEmpty);
    });
  });

  group('«Кладовщик» выключен', () {
    test('подключённый склад не отвечает вовсе', () async {
      final s = _Setup(choice: const ExtensionChoice());
      for (final text in <String>['64115', 'где лежит 64115', 'сегодня']) {
        final response = await s.say(text);
        expect(response.intent, isNot(startsWith('warehouse.')), reason: text);
      }
      expect(s.transport.requests, isEmpty);
      expect((await s.say('Добавь задачу купить хлеб')).intent, 'task.create');
      expect((await s.say('2+2')).intent, 'calc.evaluate');
    });

    test('снова включённая роль работает без нового входа', () async {
      final s = _Setup();
      s.role(Roles.storekeeperId, false);
      expect((await s.say('где лежит 64115')).intent, isNot('warehouse.where'));
      expect(await s.secrets.read('warehouse.token'), fakeToken);
      expect(s.warehouse.record.connected, isTrue);
      s.role(Roles.storekeeperId, true);
      final again = await s.say('где лежит 64115');
      expect(again.intent, 'warehouse.where');
      expect(again.status, AssistantStatus.completed);
    });
  });

  group('склад не подключён', () {
    test('фраза склада — подсказка «Настройки → Роли», не «не понял»',
        () async {
      final s = _Setup(connected: false);
      for (final text in <String>['где лежит 64115', '64115', 'без фото']) {
        final response = await s.say(text);
        expect(response.replyId, 'role.notConnected', reason: text);
        expect(response.status, AssistantStatus.noAction);
        expect(
          response.message,
          'Склад ещё не подключён — Настройки → Роли → Кладовщик → '
          'Подключить склад.',
        );
      }
      // Без подключения «сегодня» — не приходы.
      expect((await s.say('сегодня')).intent, isNot('warehouse.today'));
      expect(s.transport.requests, isEmpty);
    });
  });

  group('кто ведёт роль', () {
    _Setup noda() => _Setup(
          choice: const ExtensionChoice(
            enabledRoles: <String>{Roles.storekeeperId},
            roleOwners: <String, String>{Roles.storekeeperId: 'noda'},
          ),
        );

    test('фразы склада — от Noda, остальное — от основного', () async {
      final s = noda();
      expect((await s.say('где лежит 64115')).personaId, 'noda');
      expect(s.assistant.working('где лежит 64115').personaId, 'noda');
      expect((await s.say('Добавь задачу купить хлеб')).personaId, 'rio');
      expect((await s.say('2+2')).personaId, 'rio');
      expect((await s.say('привет')).personaId, 'rio');
      expect(s.assistant.working('2+2').personaId, 'rio');
    });

    test('обращение по имени и адресат в поле ввода важнее', () async {
      final s = noda();
      final named = await s.say('Лиорио, где лежит 64115');
      expect(named.intent, 'warehouse.where');
      expect(named.personaId, 'rio');
      final chosen = await s.say('где лежит 64115', addressee: 'rio');
      expect(chosen.personaId, 'rio');
      expect(
        s.assistant.working('где лежит 64115', addressee: 'rio').personaId,
        'rio',
      );
    });

    test('голос владельца: стиль Noda (дружеский)', () async {
      final s = _Setup(
        connected: false,
        choice: const ExtensionChoice(
          enabledRoles: <String>{Roles.storekeeperId},
          roleOwners: <String, String>{Roles.storekeeperId: 'noda'},
        ),
      );
      final response = await s.say('64115');
      expect(response.personaId, 'noda');
      expect(response.replyId, 'role.notConnected');
      expect(response.message, contains('загляните в Настройки → Роли'));
    });

    test('соло — единственный помощник', () async {
      final s = noda();
      s.assistant.personas = const PersonaSettings(
        mode: AssistantMode.solo,
        soloPersona: 'rio',
      );
      expect((await s.say('где лежит 64115')).personaId, 'rio');
    });
  });

  group('самоописание', () {
    test('«кто ты» и «что умеешь» говорят о складе', () async {
      final s = _Setup();
      final who = await s.say('кто ты');
      expect(who.message, endsWith('Сейчас помогаю с задачами и со складом.'));
      final can = await s.say('что ты умеешь');
      expect(can.message, contains('«Складские вопросы»'));
      expect(can.message, endsWith('Сейчас помогаю с задачами и со складом.'));
    });

    test('только «Личное» — прежний текст', () async {
      final s = _Setup(choice: const ExtensionChoice());
      final who = await s.say('кто ты');
      expect(who.message, isNot(contains('Сейчас помогаю')));
      final can = await s.say('что ты умеешь');
      expect(can.message, isNot(contains('Склад')));
    });
  });
}
