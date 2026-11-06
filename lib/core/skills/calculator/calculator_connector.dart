import '../../connectors/connector.dart';
import '../../connectors/social_prefix.dart';
import 'calculator.dart';

/// Навык «Калькулятор»: считает примеры из сообщения.
///
/// Свой разбор выражений и словесных форм ([Calculator]), точная
/// рациональная арифметика, никакого выполнения кода. Без сети и без
/// изменения данных.
final class CalculatorConnector implements Connector, ConnectorHealth {
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

  /// Считает без сети и хранилищ: всегда в порядке.
  @override
  Future<HealthReport> health() async => const HealthReport.ok();

  /// Пример в сообщении: целиком или после вступления — «привет, сколько
  /// будет 2+2», «спасибо, 3*3» ([SocialPrefix]). `null` — примера нет.
  static CalcRecognition? recognize(Utterance utterance) {
    final whole = Calculator.recognize(utterance.original);
    if (whole?.expression != null) return whole;
    final rest = SocialPrefix.rest(utterance);
    final withoutPrefix = rest == null ? null : Calculator.recognize(rest);
    if (withoutPrefix != null &&
        (whole == null || withoutPrefix.expression != null)) {
      return withoutPrefix;
    }
    return whole;
  }

  @override
  ConnectorMatch? match(Utterance utterance) {
    final recognition = recognize(utterance);
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
    final failure = result.failure;
    return session.reply(
      failure == null
          ? (result.approximate ? 'calc.result.approx' : 'calc.result')
          : Calculator.failureReply(failure),
      values: failure == null
          ? <String, String>{'expr': result.expression, 'result': result.value!}
          : Calculator.failureValues(failure),
      intent: commandId,
      status: switch (result.failure) {
        null => AssistantStatus.completed,
        CalcFailure.malformed => AssistantStatus.needsClarification,
        _ => AssistantStatus.noAction,
      },
    );
  }
}
