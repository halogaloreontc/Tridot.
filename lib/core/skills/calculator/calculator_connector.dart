import '../../connectors/connector.dart';
import 'calculator.dart';

/// Навык «Калькулятор»: считает примеры из сообщения.
///
/// Свой разбор выражений и словесных форм ([Calculator]), точная
/// рациональная арифметика, никакого выполнения кода. Без сети и без
/// изменения данных.
final class CalculatorConnector implements Connector {
  const CalculatorConnector();

  static const String id = 'calc';

  static const String commandId = 'calc.evaluate';

  /// Уверенность с маркером («сколько будет», «посчитай», «= ?»).
  static const double explicitConfidence = 0.9;

  /// Сообщение целиком — пример («2+2*2», «15% от 2400»).
  static const double expressionConfidence = 0.85;

  /// Маркер есть, но пример не разобран: уточнение. Ниже порога спора
  /// коннекторов и помечено `implicit`, чтобы уступить любой команде.
  static const double malformedConfidence = 0.45;

  @override
  ConnectorInfo get info => const ConnectorInfo(
        id: id,
        title: 'Калькулятор',
        description: 'Считает примеры: проценты, степени, корни, '
            'дроби — точно и без интернета.',
        examples: <String>[
          'сколько будет 2+2*2',
          '15% от 2400',
          'корень из 144',
          '3,5 умножить на 12',
          'посчитай (10 + 5) / 3',
        ],
        kind: ExtensionKind.skill,
      );

  @override
  ConnectorMatch? match(Utterance utterance) {
    final recognition = Calculator.recognize(utterance.original);
    if (recognition == null) return null;
    final parsed = recognition.expression != null;
    return ConnectorMatch(
      connectorId: id,
      commandId: commandId,
      confidence: !parsed
          ? malformedConfidence
          : recognition.explicit
              ? explicitConfidence
              : expressionConfidence,
      payload: recognition,
      implicit: !parsed,
    );
  }

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async {
    final recognition = match.payload! as CalcRecognition;
    final result = Calculator.evaluateRecognition(recognition);
    return AssistantResponse(
      message: result.message,
      intent: commandId,
      status: switch (result.failure) {
        null => AssistantStatus.completed,
        CalcFailure.malformed => AssistantStatus.needsClarification,
        _ => AssistantStatus.noAction,
      },
    );
  }
}
