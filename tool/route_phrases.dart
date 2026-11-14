// Прогоняет фразы через маршрутизатор с коннекторами приложения и печатает,
// кто и какой командой их забрал бы, и разбор ScenarioParser.
//
// Коннекторы — как в test/scenario_corpus_test.dart (_connectorFactories):
// приложения из lib/main.dart (задачи, калькулятор, беседа) и склад по
// описанию assistant/1 из test/fixtures/assistant/halowarekeep.json (действия
// с записью — из встроенной копии 1.4.57, ADR-013). В
// приложении склад выключен, пока его не подключат, но корпусный тест с
// ним спорит: фраза, которую он перехватит, упадёт в тесте, поэтому и
// проверка должна его видеть. Навык «Пароли» (ADR-014) в приложении по
// умолчанию выключен, а в корпусном тесте включён всегда — здесь тоже;
// хранилища нет (`match` от него не зависит, как в тесте). Правила
// выбора — как в AssistantController: фразу о паролях
// (PasswordPhrases.looksLike) не видит ни один сетевой коннектор (раздел
// 5.9), явная фраза о паролях — у навыка «Пароли», «на крайний случай»
// (fallback) уступает любому совпадению, без маркера (implicit) — явному,
// при близкой уверенности двух коннекторов помощник переспрашивает
// (`ambiguous`) — общая функция RoutePolicy.pick. Поле `after` строки —
// коннектор из контекста сессии (Utterance.recentConnectorId): при нём
// «Данные» отдают фразу сейфу (Reroute), и ответ — разбор канонической
// фразы, как в маршрутизаторе.
//
// Вход (stdin): JSON Lines {"id": "...", "text": "...", "now": "2026-11-02T16:30",
// "after": "passwords"} (after — необязательно).
// Выход (stdout): JSON Lines {"id", "connector", "command", "matches",
// "parse"}: connector — id победителя, `ambiguous` или null (никто не
// откликнулся); command — его commandId; matches — все совпадения
// {connector, command, confidence, implicit, fallback} по убыванию
// уверенности; parse — поля tool/parse_phrases.dart.
//
// Запуск из корня проекта: dart run tool/route_phrases.dart < phrases.jsonl
// Использует tools/corpus_gen: проверка фраз с одним разметчиком и promote
// (каждая новая строка корпуса). Расхождений с корпусным тестом здесь быть
// не должно: ошибка коннектора — ответ `error`, строки с `roles` и
// `connected` не разбираются (см. [routeInput]).
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/personas/persona_address.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/skills/data/data_connector.dart';
import 'package:local_assistant/core/skills/passwords/passwords_connector.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import '../test/connectors/manifest/fixtures.dart';
import 'parse_phrases.dart';

Future<void> main() => processLines(routeInput);

/// Строка входа → ответ [routePhrase]. Поля `roles` и `connected`
/// корпусный тест собирает через ExtensionRegistry, а здесь их нет:
/// такую строку не разбираем вовсе (ответ `error`, и promote оставляет её
/// `accepted`), чтобы не выдать вердикт, который разойдётся с тестом.
Map<String, Object?> routeInput(Map<String, dynamic> input, DateTime now) {
  for (final field in const <String>['roles', 'connected']) {
    if (input.containsKey(field)) {
      throw UnsupportedError('поле $field не поддерживается: проверьте '
          'строку корпусным тестом');
    }
  }
  return routePhrase(
    input['text'] as String,
    now,
    after: input['after'] as String?,
  );
}

/// Коннекторы корпусного теста в его порядке (_connectorFactories в
/// test/scenario_corpus_test.dart): при равной уверенности побеждает раньше
/// подключённый. Задачи — в памяти, склад — без сети: `match` не делает
/// ввода-вывода.
List<Connector> appConnectors(DateTime now) {
  final clock = FixedClock(now);
  final tasks = TaskService(repository: InMemoryTaskRepository(), clock: clock);
  return <Connector>[
    TasksConnector(taskService: tasks, parser: ScenarioParser(clock: clock)),
    warehouseConnector(builtIn: builtInManifest()),
    const CalculatorConnector(),
    TalkConnector(taskService: tasks),
    PasswordsConnector(),
    const DataConnector(),
  ];
}

/// Кто забрал бы фразу и разбор задач. [after] — коннектор из контекста
/// сессии или `null`.
Map<String, Object?> routePhrase(
  String message,
  DateTime now, {
  String? after,
}) {
  // Обращение по имени в начале («Связной, …») маршрутизатор снимает до
  // разбора (AssistantController.resolve), корпусный тест — тоже.
  final text = PersonaAddressing.commandText(message);
  final utterance = Utterance.analyze(text, now: now)
      .withChat(null, recentConnectorId: after);
  final candidates = <ConnectorMatch>[];
  // Фразу о паролях или со словом «пароль» не получает ни один сетевой
  // коннектор — ни в каком виде (раздел 5.9, AssistantController).
  final passwordsPhrase = PasswordPhrases.looksLike(utterance);
  for (final connector in appConnectors(now)) {
    if (passwordsPhrase && connector.info.requiresNetwork) continue;
    // Как в корпусном тесте: ошибка коннектора — ошибка всей фразы (ответ
    // `error` из processLines).
    final match = connector.match(utterance);
    if (match == null) continue;
    candidates.add(match);
  }
  final decision = RoutePolicy.pick(candidates, recentConnectorId: after);
  final winner = decision.winner;
  // Фраза понята по контексту как фраза другого навыка: ответ — разбор
  // канонической фразы (один раз, как в маршрутизаторе).
  if (winner?.payload case final Reroute reroute) {
    final resolved = routePhrase(reroute.text, now);
    return <String, Object?>{...resolved, 'reroute': reroute.text};
  }
  // Устойчивая сортировка: при равной уверенности — раньше подключённый.
  final all = candidates.indexed.toList()
    ..sort((a, b) {
      final byConfidence = b.$2.confidence.compareTo(a.$2.confidence);
      return byConfidence != 0 ? byConfidence : a.$1.compareTo(b.$1);
    });
  final ranked = <ConnectorMatch>[for (final (_, m) in all) m];
  return <String, Object?>{
    'connector': decision.isAmbiguous ? ambiguous : winner?.connectorId,
    'command': winner?.commandId,
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
