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
    this.implicit = false,
  });

  final String id;
  final String word;
  final double confidence;
  final bool throwOnMatch;
  final bool implicit;
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
      implicit: implicit,
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

/// Коннектор с записью: на «спиши» спрашивает подтверждение, на ответ —
/// выполняет или отменяет.
final class _WriteConnector implements Connector {
  final List<ConfirmationAnswer> answers = <ConfirmationAnswer>[];

  @override
  ConnectorInfo get info => const ConnectorInfo(
        id: 'write',
        title: 'Запись',
        description: 'Тест.',
        access: ConnectorAccess.readWrite,
      );

  @override
  ConnectorMatch? match(Utterance utterance) {
    if (!utterance.hasAnyWord(<String>{'спиши'})) return null;
    return const ConnectorMatch(
      connectorId: 'write',
      commandId: 'write.off',
      confidence: 0.9,
    );
  }

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async {
    final payload = match.payload;
    if (payload is ConfirmationAnswer) {
      answers.add(payload);
      return AssistantResponse(
        message: payload.confirmed ? 'Списал' : 'Не списываю',
        intent: match.commandId,
        status: AssistantStatus.completed,
      );
    }
    session.requestConfirmation(
      const PendingConfirmation(
        connectorId: 'write',
        commandId: 'write.off',
        itemId: '64115',
      ),
    );
    return const AssistantResponse(
      message: 'Списать 64115? Ответьте «да» или «нет».',
      intent: 'write.off',
      status: AssistantStatus.needsClarification,
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

  group('подтверждение изменяющих действий', () {
    test('«да» уходит коннектору с вопросом раньше обычного разбора', () async {
      final write = _WriteConnector();
      // Заглушка откликается на «да» уверенно, но вопрос задавал не она.
      final other = _StubConnector('other', 'да', 0.95);
      final assistant = AssistantController(
        connectors: <Connector>[other, write],
        clock: clock,
      );

      await assistant.handle('спиши 64115');
      final response = await assistant.handle('да');

      expect(response.message, 'Списал');
      expect(response.intent, 'write.off');
      expect(write.answers.single.pending.itemId, '64115');
      expect(other.runs, 0);
      expect(assistant.session.lastConnectorId, 'write');
      expect(assistant.session.pendingConfirmation, isNull);

      // Ожидание снято: следующее «да» — обычная фраза.
      final again = await assistant.handle('да');
      expect(again.message, 'Выполнил other');
    });

    test('«нет» — ответ с отказом', () async {
      final write = _WriteConnector();
      final assistant = AssistantController(
        connectors: <Connector>[write],
        clock: clock,
      );

      await assistant.handle('спиши 64115');
      final response = await assistant.handle('нет');

      expect(response.message, 'Не списываю');
      expect(write.answers.single.reply, ConfirmationReply.no);
    });

    test('другое сообщение снимает ожидание', () async {
      final write = _WriteConnector();
      final assistant = AssistantController(
        connectors: <Connector>[write],
        clock: clock,
      );

      await assistant.handle('спиши 64115');
      await assistant.handle('а что на складе');
      final response = await assistant.handle('да');

      expect(response.intent, 'unknown');
      expect(write.answers, isEmpty);
    });
  });

  group('совпадение без маркера', () {
    test('уступает явному совпадению другого коннектора', () async {
      // Задачи угадали «узнать …» по инфинитиву, склад нашёл свой вопрос:
      // уверенность одинаковая, но явное совпадение побеждает без уточнения.
      final guess = _StubConnector('guess', 'узнать', 0.6, implicit: true);
      final explicit = _StubConnector('explicit', 'узнать', 0.6);
      final assistant = AssistantController(
        connectors: <Connector>[guess, explicit],
        clock: clock,
      );

      final response = await assistant.handle('узнать где лежит 64115');

      expect(response.message, 'Выполнил explicit');
      expect(guess.runs, 0);
    });

    test('уступает даже более уверенное', () async {
      final guess = _StubConnector('guess', 'узнать', 0.75, implicit: true);
      final explicit = _StubConnector('explicit', 'узнать', 0.55);
      final assistant = AssistantController(
        connectors: <Connector>[guess, explicit],
        clock: clock,
      );

      expect(
        (await assistant.handle('узнать')).message,
        'Выполнил explicit',
      );
    });

    test('без явных совпадений выполняется', () async {
      final guess = _StubConnector('guess', 'купить', 0.6, implicit: true);
      final assistant = AssistantController(
        connectors: <Connector>[guess],
        clock: clock,
      );

      expect((await assistant.handle('купить')).message, 'Выполнил guess');
    });
  });

  group('ответ с пояснением', () {
    test('«да» в начале — согласие, если дальше нет явной команды', () async {
      final write = _WriteConnector();
      final guess = _StubConnector('guess', 'списал', 0.6, implicit: true);
      final assistant = AssistantController(
        connectors: <Connector>[write, guess],
        clock: clock,
      );

      await assistant.handle('спиши 64115');
      final response = await assistant.handle('да, списал бы уже');

      expect(response.message, 'Списал');
      expect(write.answers.single.confirmed, isTrue);
      expect(guess.runs, 0);
    });

    test('«нет» в начале и явная команда дальше — новая команда', () async {
      final write = _WriteConnector();
      final other = _StubConnector('other', 'добавь', 0.9);
      final assistant = AssistantController(
        connectors: <Connector>[write, other],
        clock: clock,
      );

      await assistant.handle('спиши 64115');
      final response = await assistant.handle('нет, добавь задачу');

      expect(response.message, 'Выполнил other');
      expect(write.answers, isEmpty);
      expect(assistant.session.pendingConfirmation, isNull);
    });
  });

  test('ответ по первому слову', () {
    ConfirmationReply? leading(String text) => ConfirmationReply.leading(
          Utterance.analyze(text, now: DateTime(2026)),
        );

    expect(leading('да, купил хлеб'), ConfirmationReply.yes);
    expect(leading('Ага, спасибо большое'), ConfirmationReply.yes);
    expect(leading('нет, не купил'), ConfirmationReply.no);
    expect(leading('неа, ещё нет'), ConfirmationReply.no);
    expect(leading('не надо пока'), ConfirmationReply.no);
    expect(leading('купил хлеб'), isNull);
    expect(leading('да?'), isNull);
    expect(leading('давно купил'), isNull);
  });

  test('ответы «да» и «нет» распознаются целым сообщением', () {
    ConfirmationReply? reply(String text) =>
        ConfirmationReply.of(Utterance.analyze(text, now: DateTime(2026)));

    expect(reply('да'), ConfirmationReply.yes);
    expect(reply('Конечно, отмечай'), ConfirmationReply.yes);
    expect(reply('+'), ConfirmationReply.yes);
    expect(reply('не надо'), ConfirmationReply.no);
    expect(reply('не отмечай'), ConfirmationReply.no);
    expect(reply('Отмена'), ConfirmationReply.no);
    expect(reply('-'), ConfirmationReply.no);
    expect(reply('да, спасибо'), ConfirmationReply.yes);
    expect(reply('👍'), ConfirmationReply.yes);
    expect(reply('👍🏻'), ConfirmationReply.yes);
    expect(reply('✅'), ConfirmationReply.yes);
    expect(reply('неа'), ConfirmationReply.no);
    expect(reply('👎'), ConfirmationReply.no);
    expect(reply('нет, спасибо'), ConfirmationReply.no);
    expect(reply('спасибо'), isNull);
    expect(reply('пожалуйста'), isNull);
    expect(reply('да?'), isNull);
    expect(reply('надо'), isNull);
    expect(reply('нет, добавь задачу купить хлеб'), isNull);
    expect(reply('да, перенеси на завтра'), isNull);
  });
}
