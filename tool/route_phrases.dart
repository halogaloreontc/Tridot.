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
// (`ambiguous`).
//
// Вход (stdin): JSON Lines {"id": "...", "text": "...", "now": "2026-11-02T16:30"}.
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
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
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
  return routePhrase(input['text'] as String, now);
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
  ];
}

/// Кто забрал бы фразу и разбор задач.
Map<String, Object?> routePhrase(String text, DateTime now) {
  final utterance = Utterance.analyze(text, now: now);
  final candidates = <ConnectorMatch>[];
  // Фразу о паролях или со словом «пароль» не получает ни один сетевой
  // коннектор — ни в каком виде (раздел 5.9, AssistantController).
  final passwordsPhrase = PasswordPhrases.looksLike(utterance);
  for (final connector in appConnectors(now)) {
    if (passwordsPhrase && connector.info.requiresNetwork) continue;
    // Как в корпусном тесте: ошибка коннектора — ошибка всей фразы (ответ
    // `error` из processLines), совпадение с нулевой уверенностью тоже
    // участвует в выборе.
    final match = connector.match(utterance);
    if (match == null) continue;
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
  // Явная фраза о паролях — у навыка «Пароли», как в AssistantController.
  final passwords = firm
      .where(
        (ConnectorMatch m) =>
            m.connectorId == PasswordsConnector.id && !m.implicit,
      )
      .firstOrNull;
  if (passwords != null) return (passwords.connectorId, passwords.commandId);
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
