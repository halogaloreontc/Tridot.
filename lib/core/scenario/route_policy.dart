import '../connectors/connector.dart';

/// Итог выбора маршрутизатора ([RoutePolicy.pick]).
final class RouteDecision {
  const RouteDecision._({this.winner, this.first, this.second});

  /// Никто не откликнулся.
  const RouteDecision.none() : this._();

  /// Фразу забирает [winner].
  const RouteDecision.winner(ConnectorMatch winner) : this._(winner: winner);

  /// Два коннектора одинаково уверены: помощник переспросит.
  const RouteDecision.ambiguous(ConnectorMatch first, ConnectorMatch second)
      : this._(first: first, second: second);

  /// Кто забирает фразу; `null` — никто или спор ([isAmbiguous]).
  final ConnectorMatch? winner;

  /// Самое уверенное совпадение спора.
  final ConnectorMatch? first;

  /// Второе совпадение спора — другого коннектора.
  final ConnectorMatch? second;

  bool get isAmbiguous => first != null;

  /// Самое вероятное совпадение: победитель или первый из спора. Для
  /// голоса «обрабатывается…».
  ConnectorMatch? get likely => winner ?? first;
}

/// Правила выбора коннектора — одни на всё приложение. Их вызывают
/// маршрутизатор ([AssistantController]), голос «обрабатывается…»,
/// корпусный тест и tool/route_phrases.dart: четыре копии правил
/// расходились бы.
///
/// 1. Совпадения с уверенностью 0 и ниже не участвуют.
/// 2. Совпадение на крайний случай ([ConnectorMatch.fallback], беседа)
///    уступает любому другому.
/// 3. Совпадение без маркера ([ConnectorMatch.implicit]) уступает явному
///    совпадению другого коннектора.
/// 4. Явная фраза о паролях — у навыка «Пароли» (раздел 6): «добавь пароль
///    для озона» — не задача.
/// 5. Фраза с обращением к приложению ([ConnectorMatch.aliased]: «в
///    автосервисе …», «склад, …») — у тех, к кому обратились: остальные
///    совпадения отбрасываются (ADR-039).
/// 6. Самое уверенное совпадение побеждает; при равной уверенности —
///    коннектор, подключённый раньше (порядок [candidates]).
/// 7. Если уверенность двух разных коннекторов выше [ambiguityFloor] и
///    отличается не больше чем на [ambiguityMargin] — спор: помощник
///    переспрашивает. Но если один из них только что работал в этом чате
///    ([recentConnectorId], контекст сессии), выигрывает он: «и сделай
///    ещё» после ответа склада — складу.
abstract final class RoutePolicy {
  /// Совпадения ниже этой уверенности не участвуют в споре коннекторов.
  static const double ambiguityFloor = 0.5;

  /// Если два коннектора ближе друг к другу, чем на эту величину, —
  /// уточнение.
  static const double ambiguityMargin = 0.15;

  /// Id навыка «Пароли» (ADR-014).
  static const String passwordsId = 'passwords';

  /// Выбор среди [candidates] — совпадений в порядке подключения
  /// коннекторов. [recentConnectorId] — коннектор, который недавно отвечал
  /// в этом чате (контекст сессии), или `null`.
  static RouteDecision pick(
    List<ConnectorMatch> candidates, {
    String? recentConnectorId,
  }) {
    var found = <ConnectorMatch>[
      for (final match in candidates)
        if (match.confidence > 0) match,
    ];
    if (found.isEmpty) return const RouteDecision.none();
    if (found.any((ConnectorMatch m) => !m.fallback)) {
      found = found.where((ConnectorMatch m) => !m.fallback).toList();
    }
    if (found.any((ConnectorMatch m) => !m.implicit)) {
      found = found.where((ConnectorMatch m) => !m.implicit).toList();
    }
    if (found.any(
      (ConnectorMatch m) => m.connectorId == passwordsId && !m.implicit,
    )) {
      found = found
          .where((ConnectorMatch m) => m.connectorId == passwordsId)
          .toList();
    }
    if (found.any((ConnectorMatch m) => m.aliased)) {
      found = found.where((ConnectorMatch m) => m.aliased).toList();
    }
    // Устойчивая сортировка: при равной уверенности — раньше подключённый.
    final ranked = found.indexed.toList()
      ..sort((a, b) {
        final byConfidence = b.$2.confidence.compareTo(a.$2.confidence);
        return byConfidence != 0 ? byConfidence : a.$1.compareTo(b.$1);
      });
    final best = ranked.first.$2;
    for (final (_, other) in ranked.skip(1)) {
      if (other.connectorId == best.connectorId) continue;
      if (best.confidence >= ambiguityFloor &&
          other.confidence >= ambiguityFloor &&
          best.confidence - other.confidence <= ambiguityMargin) {
        if (recentConnectorId == best.connectorId) {
          return RouteDecision.winner(best);
        }
        if (recentConnectorId == other.connectorId) {
          return RouteDecision.winner(other);
        }
        return RouteDecision.ambiguous(best, other);
      }
      break;
    }
    return RouteDecision.winner(best);
  }
}
