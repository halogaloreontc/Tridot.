import '../connectors/connector.dart';
import '../connectors/tasks_connector.dart';
import '../services/clock.dart';

/// Маршрутизатор сообщений между коннекторами.
///
/// На каждое сообщение один раз строит [Utterance], спрашивает каждый
/// коннектор `match`, выбирает самое уверенное совпадение и запускает его
/// `run`. Если два разных коннектора одинаково уверены, просит уточнить,
/// а не выбирает наугад. Интерфейс работает только с этим классом.
///
/// Если коннектор ждёт подтверждения ([AssistantSession.pendingConfirmation])
/// и сообщение — «да» или «нет» ([ConfirmationReply.of]), ответ уходит
/// этому коннектору до обычного разбора. Ответ с пояснением («да, купил
/// хлеб», [ConfirmationReply.leading]) уходит ему же, если ни один
/// коннектор не нашёл в сообщении явной команды. Любое другое сообщение
/// снимает ожидание. Совпадение без маркера ([ConnectorMatch.implicit])
/// уступает явному совпадению другого коннектора.
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
    final pending = session.takePendingConfirmation();
    final owner = pending == null
        ? null
        : _connectors
            .where((Connector c) => c.info.id == pending.connectorId)
            .firstOrNull;
    if (pending != null && owner != null) {
      final reply = ConfirmationReply.of(utterance);
      if (reply != null) return _answer(owner, pending, reply);
    }
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
    if (pending != null && owner != null) {
      // «Да, купил хлеб», «нет, не купил»: ответ с пояснением. Если в
      // пояснении явная команда («нет, добавь задачу молоко»), это уже
      // новое сообщение, а не ответ.
      final reply = ConfirmationReply.leading(utterance);
      if (reply != null &&
          candidates.every(((Connector, ConnectorMatch) c) => c.$2.implicit)) {
        return _answer(owner, pending, reply);
      }
    }
    if (candidates.isEmpty) {
      session.lastConnectorId = null;
      return _unknown();
    }
    // Совпадение без маркера уступает явному совпадению другого коннектора.
    if (candidates.any(((Connector, ConnectorMatch) c) => !c.$2.implicit)) {
      candidates.removeWhere(
        ((Connector, ConnectorMatch) c) => c.$2.implicit,
      );
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

    return _run(bestConnector, best);
  }

  Future<AssistantResponse> _answer(
    Connector owner,
    PendingConfirmation pending,
    ConfirmationReply reply,
  ) =>
      _run(
        owner,
        ConnectorMatch(
          connectorId: owner.info.id,
          commandId: pending.commandId,
          confidence: 1,
          payload: ConfirmationAnswer(pending, reply),
        ),
      );

  Future<AssistantResponse> _run(
    Connector connector,
    ConnectorMatch match,
  ) async {
    try {
      return await connector.run(match, session);
    } catch (error) {
      return AssistantResponse(
        message: 'Не удалось выполнить действие: $error',
        intent: match.commandId,
        status: AssistantStatus.failed,
      );
    } finally {
      session.lastConnectorId = connector.info.id;
    }
  }

  AssistantResponse _unknown() => TasksConnector.unknownResponse;
}
