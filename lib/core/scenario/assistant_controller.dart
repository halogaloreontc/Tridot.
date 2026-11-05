import '../connectors/connector.dart';
import '../connectors/tasks_connector.dart';
import '../services/clock.dart';

/// Маршрутизатор сообщений между коннекторами.
///
/// На каждое сообщение один раз строит [Utterance], спрашивает каждый
/// коннектор `match`, выбирает самое уверенное совпадение и запускает его
/// `run`. Если два разных коннектора одинаково уверены, просит уточнить,
/// а не выбирает наугад. Интерфейс работает только с этим классом.
final class AssistantController {
  AssistantController({
    required List<Connector> connectors,
    Clock clock = const SystemClock(),
  })  : _connectors = List<Connector>.unmodifiable(connectors),
        session = AssistantSession(clock: clock) {
    final ids = <String>{};
    for (final connector in _connectors) {
      if (!ids.add(connector.info.id)) {
        throw ArgumentError.value(
          connector.info.id,
          'connectors',
          'Коннектор с таким id уже подключён',
        );
      }
    }
  }

  /// Пример из подсказок интерфейса. Тест проверяет, что парсер его понимает.
  static const String exampleCommand = TasksConnector.exampleCommand;

  /// Совпадения ниже этой уверенности не участвуют в споре коннекторов.
  static const double ambiguityFloor = 0.5;

  /// Если два коннектора ближе друг к другу, чем на эту величину, —
  /// уточнение.
  static const double ambiguityMargin = 0.15;

  final List<Connector> _connectors;

  /// Общее состояние диалога: выбранный объект, часы, последний коннектор.
  final AssistantSession session;

  List<ConnectorInfo> get connectors => <ConnectorInfo>[
        for (final connector in _connectors) connector.info,
      ];

  /// Задача, к которой относятся «её», «перенеси», «заверши».
  String? get selectedTaskId => session.selectedItemFor(TasksConnector.id);

  void selectTask(String id) => session.select(TasksConnector.id, id);

  void clearSelection() => session.clearSelection();

  /// Задачу завершили или удалили не через диалог.
  void forgetTask(String id) => session.forget(TasksConnector.id, id);

  Future<AssistantResponse> handle(String message) async {
    final utterance = Utterance.analyze(message, now: session.clock.now());
    final candidates = <(Connector, ConnectorMatch)>[];
    for (final connector in _connectors) {
      final ConnectorMatch? match;
      try {
        match = connector.match(utterance);
      } catch (error) {
        // Ошибка в одном коннекторе не должна ломать остальные.
        continue;
      }
      if (match == null || match.confidence <= 0) continue;
      candidates.add((connector, match));
    }
    if (candidates.isEmpty) {
      session.lastConnectorId = null;
      return _unknown();
    }

    // Устойчивая сортировка: при равной уверенности побеждает коннектор,
    // подключённый раньше (но тогда сработает уточнение ниже).
    final ranked = candidates.indexed.toList()
      ..sort((a, b) {
        final byConfidence = b.$2.$2.confidence.compareTo(a.$2.$2.confidence);
        return byConfidence != 0 ? byConfidence : a.$1.compareTo(b.$1);
      });
    final (bestConnector, best) = ranked.first.$2;
    for (final (_, (other, otherMatch)) in ranked.skip(1)) {
      if (other.info.id == bestConnector.info.id) continue;
      if (best.confidence >= ambiguityFloor &&
          otherMatch.confidence >= ambiguityFloor &&
          best.confidence - otherMatch.confidence <= ambiguityMargin) {
        session.lastConnectorId = null;
        return AssistantResponse(
          message: 'Не понял, к чему относится команда: '
              '«${bestConnector.info.title}» или «${other.info.title}»? '
              'Уточните, пожалуйста.',
          intent: 'router.ambiguous',
          status: AssistantStatus.needsClarification,
        );
      }
      break;
    }

    try {
      return await bestConnector.run(best, session);
    } catch (error) {
      return AssistantResponse(
        message: 'Не удалось выполнить действие: $error',
        intent: best.commandId,
        status: AssistantStatus.failed,
      );
    } finally {
      session.lastConnectorId = bestConnector.info.id;
    }
  }

  AssistantResponse _unknown() => const AssistantResponse(
        message: 'Пока понимаю создание, список, перенос и завершение задач. '
            'Например: $exampleCommand',
        intent: 'unknown',
        status: AssistantStatus.noAction,
      );
}
