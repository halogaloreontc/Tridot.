import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import 'example_warehouse_connector.dart';
import 'fakes.dart';

void main() {
  final now = DateTime(2026, 11, 2, 16, 30);
  final clock = FixedClock(now);
  late FakeHttpTransport transport;
  late InMemorySecretStore secrets;
  late ExampleWarehouseConnector warehouse;
  late AssistantController assistant;
  late TaskService tasks;

  setUp(() {
    transport = FakeHttpTransport(
      (HttpRequestData request) => const HttpResponseData(
        statusCode: 200,
        body: '{"cell": "A-03-2", "quantity": 12}',
      ),
    );
    secrets = InMemorySecretStore(<String, String>{
      ExampleWarehouseConnector.tokenKey: 'секрет',
    });
    warehouse = ExampleWarehouseConnector(
      transport: transport,
      secrets: secrets,
      baseUri: Uri.parse('https://warehouse.example/api/'),
    );
    tasks = TaskService(repository: InMemoryTaskRepository(), clock: clock);
    assistant = AssistantController(
      connectors: <Connector>[
        TasksConnector(
          taskService: tasks,
          parser: ScenarioParser(clock: clock),
        ),
        warehouse,
      ],
      clock: clock,
    );
  });

  test('каждый пример из паспорта распознаётся', () {
    for (final example in warehouse.info.examples) {
      final match = warehouse.match(Utterance.analyze(example, now: now));
      expect(match?.commandId, 'warehouse.locate', reason: example);
    }
  });

  test('match не берёт чужие фразы', () {
    for (final text in <String>[
      'Добавь задачу проверить заказ 64115',
      'Где мои задачи?',
      'Перенеси отчёт на 15.11',
    ]) {
      expect(
        warehouse.match(Utterance.analyze(text, now: now)),
        isNull,
        reason: text,
      );
    }
  });

  test('код не читается как дата или время', () {
    final utterance = Utterance.analyze('Где лежит 64115', now: now);

    expect(utterance.codes, <String>['64115']);
    expect(utterance.due.dueAt, isNull);
    expect(utterance.due.spans, isEmpty);
  });

  test('отвечает ячейкой и шлёт токен в заголовке', () async {
    final response = await assistant.handle('Где лежит 64115?');

    expect(response.status, AssistantStatus.completed);
    expect(
      response.message,
      'Артикул 64115 лежит в ячейке A-03-2, остаток 12 шт.',
    );
    final request = transport.requests.single;
    expect(request.method, 'GET');
    expect(
      request.uri.toString(),
      'https://warehouse.example/api/items/64115/location',
    );
    expect(request.headers['Authorization'], 'Bearer секрет');
    expect(assistant.session.lastConnectorId, ExampleWarehouseConnector.id);
  });

  test('без токена не ходит в сеть', () async {
    await secrets.delete(ExampleWarehouseConnector.tokenKey);

    final response = await assistant.handle('Где лежит 64115');

    expect(response.status, AssistantStatus.noAction);
    expect(transport.requests, isEmpty);
  });

  test('404 — товара нет, 401 — ошибка токена', () async {
    transport = FakeHttpTransport(
      (HttpRequestData r) => const HttpResponseData(statusCode: 404),
    );
    var connector = ExampleWarehouseConnector(
      transport: transport,
      secrets: secrets,
      baseUri: Uri.parse('https://warehouse.example/api/'),
    );
    var response = await AssistantController(connectors: <Connector>[connector])
        .handle('Где лежит 64115');
    expect(response.status, AssistantStatus.completed);
    expect(response.message, 'Артикул 64115 на складе не найден.');

    connector = ExampleWarehouseConnector(
      transport: FakeHttpTransport(
        (HttpRequestData r) => const HttpResponseData(statusCode: 401),
      ),
      secrets: secrets,
      baseUri: Uri.parse('https://warehouse.example/api/'),
    );
    response = await AssistantController(connectors: <Connector>[connector])
        .handle('Где лежит 64115');
    expect(response.status, AssistantStatus.failed);
  });

  test('испорченный ответ превращается в failed, а не в исключение', () async {
    final connector = ExampleWarehouseConnector(
      transport: FakeHttpTransport(
        (HttpRequestData r) =>
            const HttpResponseData(statusCode: 200, body: 'не json'),
      ),
      secrets: secrets,
      baseUri: Uri.parse('https://warehouse.example/api/'),
    );

    final response = await AssistantController(
      connectors: <Connector>[connector],
    ).handle('Где лежит 64115');

    expect(response.status, AssistantStatus.failed);
    expect(response.intent, 'warehouse.locate');
  });

  test('несколько кодов — уточнение без запроса', () async {
    final response = await assistant.handle('Где лежат 64115 и 64116');

    expect(response.status, AssistantStatus.needsClarification);
    expect(response.message, contains('64115 или 64116'));
    expect(transport.requests, isEmpty);
  });

  test('задачи с кодом по-прежнему уходят коннектору задач', () async {
    final response =
        await assistant.handle('Добавь задачу проверить заказ 64115');

    expect(response.intent, 'task.create');
    expect(response.task?.title, 'Проверить заказ 64115');
    expect(transport.requests, isEmpty);
  });

  test('код примера в docs/CONNECTORS.md совпадает с этим файлом', () {
    final source = File('test/connectors/example_warehouse_connector.dart')
        .readAsLinesSync()
        .skipWhile((String line) => line.startsWith('//'))
        .join('\n')
        .trim();
    final doc = File('docs/CONNECTORS.md').readAsStringSync();

    expect(doc, contains(source));
  });
}
