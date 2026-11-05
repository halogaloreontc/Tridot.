import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/services/clock.dart';

/// Коннектор-заглушка: совпадает со словом [word] с уверенностью [confidence].
final class _StubConnector implements Connector {
  _StubConnector(
    this.id,
    this.word,
    this.confidence, {
    this.throwOnMatch = false,
  });

  final String id;
  final String word;
  final double confidence;
  final bool throwOnMatch;
  int runs = 0;

  @override
  ConnectorInfo get info =>
      ConnectorInfo(id: id, title: 'Заглушка $id', description: 'Тест.');

  @override
  ConnectorMatch? match(Utterance utterance) {
    if (throwOnMatch) throw StateError('сломан');
    if (!utterance.hasAnyWord(<String>{word})) return null;
    return ConnectorMatch(
      connectorId: id,
      commandId: '$id.run',
      confidence: confidence,
    );
  }

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async {
    runs++;
    session.select(id, 'item-$runs');
    return AssistantResponse(
      message: 'Выполнил $id',
      intent: match.commandId,
      status: AssistantStatus.completed,
    );
  }
}

void main() {
  final clock = FixedClock(DateTime(2026, 11, 2, 16, 30));

  test('выбирает самое уверенное совпадение', () async {
    final weak = _StubConnector('a', 'склад', 0.3);
    final strong = _StubConnector('b', 'склад', 0.9);
    final assistant = AssistantController(
      connectors: <Connector>[weak, strong],
      clock: clock,
    );

    final response = await assistant.handle('Покажи склад');

    expect(response.message, 'Выполнил b');
    expect(weak.runs, 0);
    expect(assistant.session.lastConnectorId, 'b');
  });

  test('два близких уверенных совпадения — уточнение с именами', () async {
    final a = _StubConnector('a', 'склад', 0.8);
    final b = _StubConnector('b', 'склад', 0.7);
    final assistant = AssistantController(
      connectors: <Connector>[a, b],
      clock: clock,
    );

    final response = await assistant.handle('склад');

    expect(response.status, AssistantStatus.needsClarification);
    expect(response.message, contains('«Заглушка a»'));
    expect(response.message, contains('«Заглушка b»'));
    expect(a.runs + b.runs, 0);
  });

  test('слабое второе совпадение не мешает', () async {
    final a = _StubConnector('a', 'склад', 0.6);
    final b = _StubConnector('b', 'склад', 0.45);
    final assistant = AssistantController(
      connectors: <Connector>[a, b],
      clock: clock,
    );

    final response = await assistant.handle('склад');

    expect(response.message, 'Выполнил a');
  });

  test('ничего не совпало — сообщение без обязательных кавычек', () async {
    final assistant = AssistantController(
      connectors: <Connector>[_StubConnector('a', 'склад', 0.9)],
      clock: clock,
    );

    final response = await assistant.handle('Привет');

    expect(response.status, AssistantStatus.noAction);
    expect(response.intent, 'unknown');
    expect(response.message, isNot(contains('кавычк')));
  });

  test('сломанный match одного коннектора не ломает остальные', () async {
    final assistant = AssistantController(
      connectors: <Connector>[
        _StubConnector('broken', 'склад', 0.9, throwOnMatch: true),
        _StubConnector('ok', 'склад', 0.7),
      ],
      clock: clock,
    );

    final response = await assistant.handle('склад');

    expect(response.message, 'Выполнил ok');
  });

  test('выбор объекта одного коннектора не виден как задача', () async {
    final assistant = AssistantController(
      connectors: <Connector>[_StubConnector('a', 'склад', 0.9)],
      clock: clock,
    );

    await assistant.handle('склад');

    expect(assistant.session.selectedItemFor('a'), 'item-1');
    expect(assistant.selectedTaskId, isNull);
  });

  test('повтор id коннектора — ошибка подключения', () {
    expect(
      () => AssistantController(
        connectors: <Connector>[
          _StubConnector('a', 'x', 0.5),
          _StubConnector('a', 'y', 0.5),
        ],
      ),
      throwsArgumentError,
    );
  });

  test('lastConnectorId — обработчик предыдущего сообщения', () async {
    final a = _StubConnector('a', 'склад', 0.9);
    final assistant =
        AssistantController(connectors: <Connector>[a], clock: clock);

    await assistant.handle('склад');
    expect(assistant.session.lastConnectorId, 'a');

    await assistant.handle('Привет');
    expect(assistant.session.lastConnectorId, isNull);
  });
}
