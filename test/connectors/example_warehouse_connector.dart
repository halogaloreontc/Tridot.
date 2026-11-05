// Пример коннектора из docs/CONNECTORS.md. Код в документе — копия этого
// файла; тесты рядом проверяют, что пример работает.
import 'dart:convert';

import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';

/// Что `match` разобрал из фразы и передаёт в `run`.
final class LocateRequest {
  const LocateRequest(this.codes);

  /// Артикулы из фразы. Больше одного — `run` переспросит.
  final List<String> codes;
}

/// «Пример склада»: только чтение, отвечает на «где лежит {код}».
final class ExampleWarehouseConnector implements Connector {
  ExampleWarehouseConnector({
    required HttpTransport transport,
    required SecretStore secrets,
    required Uri baseUri,
  })  : _transport = transport,
        _secrets = secrets,
        _baseUri = baseUri;

  static const String id = 'warehouse_example';

  /// Ключ токена в [SecretStore]: `<id коннектора>.<имя>`.
  static const String tokenKey = '$id.token';

  final HttpTransport _transport;
  final SecretStore _secrets;
  final Uri _baseUri;

  static const Set<String> _questionWords = <String>{'где'};

  static const Set<String> _locateVerbs = <String>{
    'лежит',
    'лежат',
    'хранится',
    'хранятся',
    'находится',
    'находятся',
  };

  @override
  ConnectorInfo get info => const ConnectorInfo(
        id: id,
        title: 'Пример склада',
        description: 'Подсказывает, в какой ячейке лежит товар по артикулу.',
        examples: <String>[
          'Где лежит 64115',
          'где хранится артикул 64115?',
          '64115 где лежит',
        ],
        requiresNetwork: true,
        access: ConnectorAccess.readOnly,
      );

  @override
  ConnectorMatch? match(Utterance utterance) {
    final codes = utterance.codes;
    if (codes.isEmpty) return null;
    final asksWhere = utterance.hasAnyWord(_questionWords);
    final saysLies = utterance.hasAnyWord(_locateVerbs);
    if (!asksWhere && !saysLies) return null;
    // Фраза целиком о складе: начинается с «где» или с кода и содержит
    // и вопрос, и глагол. Иначе «где лежит» может быть частью другой
    // команды («Добавь задачу проверить, где лежит 64115») — тогда уверенность
    // средняя, и команда с явным глаголом уверенно победит.
    final first = utterance.tokens.first.text;
    final wholePhrase = first == 'где' || codes.contains(first);
    return ConnectorMatch(
      connectorId: id,
      commandId: 'warehouse.locate',
      confidence: asksWhere && saysLies && wholePhrase ? 0.9 : 0.6,
      payload: LocateRequest(codes),
    );
  }

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async {
    final request = match.payload! as LocateRequest;
    if (request.codes.length > 1) {
      return AssistantResponse(
        message: 'Какой артикул найти: ${request.codes.join(' или ')}?',
        intent: match.commandId,
        status: AssistantStatus.needsClarification,
      );
    }
    final code = request.codes.single;
    final token = await _secrets.read(tokenKey);
    if (token == null) {
      return AssistantResponse(
        message: 'Склад не подключён: токен склада не задан.',
        intent: match.commandId,
        status: AssistantStatus.noAction,
      );
    }
    final response = await _transport.send(
      HttpRequestData(
        method: 'GET',
        uri: _baseUri.resolve('items/${Uri.encodeComponent(code)}/location'),
        headers: <String, String>{
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
      ),
    );
    if (response.statusCode == 404) {
      return AssistantResponse(
        message: 'Артикул $code на складе не найден.',
        intent: match.commandId,
        status: AssistantStatus.completed,
      );
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      return AssistantResponse(
        message: 'Склад не принял токен. Подключите склад заново.',
        intent: match.commandId,
        status: AssistantStatus.failed,
      );
    }
    if (!response.isSuccess) {
      return AssistantResponse(
        message: 'Склад ответил ошибкой ${response.statusCode}.',
        intent: match.commandId,
        status: AssistantStatus.failed,
      );
    }
    // Неверный JSON бросит исключение — маршрутизатор вернёт `failed`.
    final json = jsonDecode(response.body) as Map<String, Object?>;
    final cell = json['cell'] as String;
    final quantity = json['quantity'] as int;
    return AssistantResponse(
      message: 'Артикул $code лежит в ячейке $cell, остаток $quantity шт.',
      intent: match.commandId,
      status: AssistantStatus.completed,
    );
  }
}
