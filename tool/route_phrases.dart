// Прогоняет фразы через маршрутизатор с коннекторами приложения и печатает,
// кто и какой командой их забрал бы, и разбор ScenarioParser.
//
// Коннекторы — как в test/scenario_corpus_test.dart (_connectorFactories):
// приложения из lib/main.dart (задачи, калькулятор, беседа) и склад по
// описанию assistant/1 из test/fixtures/assistant/halowarekeep.json. В
// приложении склад выключен, пока его не подключат, но корпусный тест с
// ним спорит: фраза, которую он перехватит, упадёт в тесте, поэтому и
// проверка должна его видеть. Правила
// выбора — как в AssistantController: «на крайний случай» (fallback) уступает
// любому совпадению, без маркера (implicit) — явному, при близкой уверенности
// двух коннекторов помощник переспрашивает (`ambiguous`).
//
// Вход (stdin): JSON Lines {"id": "...", "text": "...", "now": "2026-11-02T16:30"}.
// Выход (stdout): JSON Lines {"id", "connector", "command", "matches",
// "parse"}: connector — id победителя, `ambiguous` или null (никто не
// откликнулся); command — его commandId; matches — все совпадения
// {connector, command, confidence, implicit, fallback} по убыванию
// уверенности; parse — поля tool/parse_phrases.dart.
//
// Запуск из корня проекта: dart run tool/route_phrases.dart < phrases.jsonl
// Использует tools/corpus_gen (проверка фраз с одним разметчиком).
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import '../test/connectors/manifest/fixtures.dart';
import 'parse_phrases.dart';

Future<void> main() => processLines(
      (Map<String, dynamic> input, DateTime now) =>
          routePhrase(input['text'] as String, now),
    );

/// Коннекторы корпусного теста в его порядке (_connectorFactories в
/// test/scenario_corpus_test.dart): при равной уверенности побеждает раньше
/// подключённый. Задачи — в памяти, склад — без сети: `match` не делает
/// ввода-вывода.
List<Connector> appConnectors(DateTime now) {
  final clock = FixedClock(now);
  final tasks = TaskService(repository: InMemoryTaskRepository(), clock: clock);
  return <Connector>[
    TasksConnector(taskService: tasks, parser: ScenarioParser(clock: clock)),
    warehouseConnector(),
    const CalculatorConnector(),
    TalkConnector(taskService: tasks),
  ];
}

/// Кто забрал бы фразу и разбор задач.
Map<String, Object?> routePhrase(String text, DateTime now) {
  final utterance = Utterance.analyze(text, now: now);
  final candidates = <ConnectorMatch>[];
  for (final connector in appConnectors(now)) {
    final ConnectorMatch? match;
    try {
      match = connector.match(utterance);
    } on Object {
      // Как в маршрутизаторе: ошибка одного коннектора не ломает остальные.
      continue;
    }
    if (match == null || match.confidence <= 0) continue;
    candidates.add(match);
  }
  // Устойчивая сортировка: при равной уверенности — раньше подключённый.
  final all = candidates.indexed.toList()
    ..sort((a, b) {
      final byConfidence = b.$2.confidence.compareTo(a.$2.confidence);
      return byConfidence != 0 ? byConfidence : a.$1.compareTo(b.$1);
    });
  final ranked = <ConnectorMatch>[for (final (_, m) in all) m];
  final (connector, command) = route(ranked);
  return <String, Object?>{
    'connector': connector,
    'command': command,
    'matches': <Map<String, Object?>>[
      for (final m in ranked)
        <String, Object?>{
          'connector': m.connectorId,
          'command': m.commandId,
          'confidence': m.confidence,
          'implicit': m.implicit,
          'fallback': m.fallback,
        },
    ],
    'parse': parsedFields(text, now),
  };
}

/// Метка «помощник переспросит, какой коннектор имелся в виду».
const String ambiguous = 'ambiguous';

/// Выбор маршрутизатора среди совпадений, отсортированных по убыванию
/// уверенности: id коннектора и commandId победителя, ([ambiguous], null)
/// или (null, null), если никто не откликнулся.
(String?, String?) route(List<ConnectorMatch> ranked) {
  if (ranked.isEmpty) return (null, null);
  var firm = ranked;
  if (firm.any((ConnectorMatch m) => !m.fallback)) {
    firm = firm.where((ConnectorMatch m) => !m.fallback).toList();
  }
  if (firm.any((ConnectorMatch m) => !m.implicit)) {
    firm = firm.where((ConnectorMatch m) => !m.implicit).toList();
  }
  final best = firm.first;
  for (final other in firm.skip(1)) {
    if (other.connectorId == best.connectorId) continue;
    if (best.confidence >= AssistantController.ambiguityFloor &&
        other.confidence >= AssistantController.ambiguityFloor &&
        best.confidence - other.confidence <=
            AssistantController.ambiguityMargin) {
      return (ambiguous, null);
    }
    break;
  }
  return (best.connectorId, best.commandId);
}
