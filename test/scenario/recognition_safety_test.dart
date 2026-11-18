// Находки ревью слоёв распознавания (ADR-037): запись — только после «Да»
// по той команде, что выполнится; фразы о паролях, ПИН и кодах не
// исправляются и не повторяются в чате; обёртка не делает из них дел.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/skills/passwords/passwords_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

void main() {
  final clock = FixedClock(DateTime(2026, 11, 2, 16, 30));
  late TaskService tasks;
  late AssistantController assistant;

  void setUpWith({bool passwords = false}) {
    tasks = TaskService(repository: InMemoryTaskRepository(), clock: clock);
    final registry = ExtensionRegistry(
      connectors: <Connector>[
        TasksConnector(
          taskService: tasks,
          parser: ScenarioParser(clock: clock),
        ),
        const CalculatorConnector(),
        PasswordsConnector(),
      ],
      choice: ExtensionChoice(
        enabled: <String>{if (passwords) PasswordsConnector.id},
      ),
    );
    assistant = AssistantController(extensions: registry, clock: clock);
  }

  setUp(setUpWith);

  test(
      'не та раскладка: запись проверяется по команде, которая выполнится, '
      'а не по выбору до обёртки', () async {
    final task = await tasks.create(title: 'Отчёт');
    // «перекинь отчет на завтра, а 2*3 сколько?»: как есть — пример
    // калькулятора, без обёртки — перенос задачи.
    final asked =
        await assistant.handle('gthtrbym jnxtn yf pfdnhf? f 2*3 crjkmrj&');
    expect(asked.replyId, 'router.repaired.confirm');
    expect((await tasks.find(task.id))!.dueAt, isNull);
    await assistant.handle('нет');
    expect((await tasks.find(task.id))!.dueAt, isNull);
  });

  test('«Пароли» выключены: фраза о пароле в обёртке — не задача', () async {
    for (final text in <String>[
      'не дай забыть пароль от почты CANARYbird',
      'не дай мне забыть пароль от почты',
      'напомни-ка пароль от почты',
    ]) {
      final response = await assistant.handle(text);
      // Пароль во фразе ловит SecretGuard раньше: тоже без задачи.
      expect(
        response.replyId,
        anyOf('passwords.off', 'secret.redacted.off'),
        reason: text,
      );
      expect(response.message, isNot(contains('CANARY')), reason: text);
    }
    expect(await tasks.listActive(), isEmpty);
  });

  test('ПИН и коды не повторяются в пояснении «понял как …»', () async {
    for (final text in <String>[
      'пакажи заадчи, мой пин 4821',
      'gjrf;b pflfxb? vjq gby 4821',
      'пакажи заадчи, код от домофона 4821',
      'gjrf;b pflfxb password CANARYbird',
    ]) {
      final response = await assistant.handle(text);
      expect(response.message, isNot(contains('4821')), reason: text);
      expect(response.message, isNot(contains('CANARY')), reason: text);
      expect(response.message, isNot(contains('canary')), reason: text);
    }
  });

  test('«не дай мне забыть пин от карты …» — не задача с ПИН', () async {
    final response =
        await assistant.handle('не дай мне забыть пин от карты 4821');
    expect(response.message, isNot(contains('4821')));
    expect(await tasks.listActive(), isEmpty);
  });
}
