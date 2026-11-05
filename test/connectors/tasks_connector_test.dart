import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

void main() {
  final now = DateTime(2026, 11, 2, 16, 30);
  final connector = TasksConnector(
    taskService: TaskService(
      repository: InMemoryTaskRepository(),
      clock: FixedClock(now),
    ),
    parser: ScenarioParser(clock: FixedClock(now)),
  );

  test('каждый пример из паспорта распознаётся', () {
    for (final example in connector.info.examples) {
      final match = connector.match(Utterance.analyze(example, now: now));
      expect(match, isNotNull, reason: example);
      expect(match!.connectorId, TasksConnector.id);
    }
  });

  test('чужие фразы не берёт', () {
    for (final text in <String>['Привет', 'Где лежит 64115', '']) {
      expect(
        connector.match(Utterance.analyze(text, now: now)),
        isNull,
        reason: text,
      );
    }
  });
}
