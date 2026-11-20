import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/intent/intent_fallback.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import 'fake_intent.dart';

/// Запасной слой в маршрутизаторе (ADR-041) с поддельным кодировщиком:
/// «не понял» → «Похоже, вы хотите …?», «Да» — команда правилами навыка,
/// «Нет» — отрицательный пример и журнал. Приватное до модели не доходит.
void main() {
  final now = DateTime(2026, 11, 20, 10);
  final clock = FixedClock(now);

  /// Фразы, которых правила не понимают (проверяется в [setUp]).
  const cinema = 'в субботу в 11 с детьми в кино сходить надо';
  const half = 'четырнадцать с половиной на два';
  const vague = 'ну вот это самое как его';
  const style = 'а можно как-то по-другому со мной';
  const mortgage = 'что такое ипотека?';

  late TaskService tasks;
  late FakeEncoder encoder;
  late IntentMemory memory;
  late InMemoryIntentMemoryStore store;
  late AssistantController assistant;

  AssistantController controller() => AssistantController(
        connectors: <Connector>[
          TasksConnector(
            taskService: tasks,
            parser: ScenarioParser(clock: clock),
          ),
          const CalculatorConnector(),
          TalkConnector(),
        ],
        clock: clock,
      );

  setUp(() async {
    tasks = TaskService(repository: InMemoryTaskRepository(), clock: clock);
    encoder = FakeEncoder(<String, Float32List>{
      cinema: fakeVector(<String, double>{'tasks:task.create': 1}),
      half: fakeVector(<String, double>{'calc:calc.evaluate': 1}),
      style: fakeVector(<String, double>{'talk:talk.setting': 1}),
      mortgage: fakeVector(<String, double>{'tasks:task.list': 1}),
      vague: fakeVector(<String, double>{
        'tasks:task.create': 0.75,
        'tasks:task.list': 0.66,
      }),
    });
    store = InMemoryIntentMemoryStore();
    memory = IntentMemory(store: store, clock: clock);
    assistant = controller()
      ..intent = IntentFallback(model: fakeModel(encoder), memory: memory);
    // Без запасного слоя эти фразы — «не понял».
    final plain = controller();
    for (final phrase in <String>[cinema, half, vague, style]) {
      expect(
        (await plain.handle(phrase)).replyId,
        TasksConnector.unknownReply,
        reason: phrase,
      );
    }
  });

  test('«не понял» → вопрос с кнопками «Да» и «Нет»', () async {
    final response = await assistant.handle(cinema);
    expect(response.replyId, AssistantController.intentSuggestReply);
    expect(response.status, AssistantStatus.needsClarification);
    expect(response.message, contains('создать задачу или напоминание'));
    expect(response.message, endsWith('?'));
    final options = response.clarification!.options;
    expect(options.map((ClarifyOption o) => o.label), <String>['Да', 'Нет']);
    expect(
      identical(assistant.pendingClarification, response.clarification),
      isTrue,
    );
    expect(
      await tasks.listAll(),
      isEmpty,
      reason: 'модель ничего не выполняет сама',
    );
  });

  test('«Да» — задача правилами задач, личный пример и запись в журнал',
      () async {
    await assistant.handle(cinema);
    final response = await assistant.handle('Да');
    expect(response.intent, 'task.create');
    expect(await tasks.listAll(), hasLength(1));
    final task = (await tasks.listAll()).single;
    expect(task.title.toLowerCase(), contains('кино'));
    // Срок — из фразы, разборщиком задач: суббота, 11:00.
    expect(task.dueAt?.weekday, DateTime.saturday);
    expect(task.dueAt?.hour, 11);
    expect(memory.positives.single.label, 'tasks:task.create');
    expect(memory.positives.single.vector, isNotNull);
    expect(memory.unclear.single.kind, UnclearKind.accepted);
    expect(assistant.pendingClarification, isNull);
  });

  test('«Да» калькулятору: выражение разбирает калькулятор', () async {
    await assistant.handle(half);
    final response = await assistant.handle('да');
    expect(response.intent, CalculatorConnector.commandId);
    expect(response.message, contains('14,5'));
  });

  test('второй вариант — своей кнопкой', () async {
    assistant.intent = IntentFallback(
      model: fakeModel(encoder, threshold: 0.6, perLabel: 2),
      memory: memory,
    );
    final question = await assistant.handle(vague);
    expect(question.replyId, AssistantController.intentSuggestTwoReply);
    final labels = <String>[
      for (final o in question.clarification!.options) o.label,
    ];
    expect(labels, <String>['Да', 'Посмотреть список задач', 'Нет']);
    final response = await assistant.handle('Посмотреть список задач');
    expect(response.intent, 'task.list');
    expect(memory.positives.single.label, 'tasks:task.list');
  });

  test(
      '«Нет» — отрицательный пример, журнал, обычное «не понял»; '
      'похожая фраза больше не получает той подсказки', () async {
    await assistant.handle(cinema);
    final response = await assistant.handle('нет');
    expect(response.replyId, TasksConnector.unknownReply);
    expect(await tasks.listAll(), isEmpty);
    expect(memory.negatives.single.label, 'tasks:task.create');
    expect(memory.unclear.single.kind, UnclearKind.rejected);
    final again = await assistant.handle(cinema);
    expect(again.replyId, TasksConnector.unknownReply);
    expect(memory.unclear.single.kind, UnclearKind.unknown);
  });

  test('«Нет» кнопкой — то же', () async {
    await assistant.handle(cinema);
    final response = await assistant.handle('Нет');
    expect(response.replyId, TasksConnector.unknownReply);
    expect(memory.negatives, hasLength(1));
  });

  test('другая фраза вместо ответа снимает вопрос и разбирается как обычно',
      () async {
    await assistant.handle(cinema);
    final response = await assistant.handle('покажи задачи');
    expect(response.intent, 'task.list');
    expect(assistant.pendingClarification, isNull);
    expect(memory.positives, isEmpty);
    expect(memory.negatives, isEmpty);
    expect(await tasks.listAll(), isEmpty);
  });

  test('учиться выключено — «Да» и «Нет» ничего не запоминают', () async {
    await memory.setLearning(false);
    await assistant.handle(cinema);
    await assistant.handle('да');
    expect(await tasks.listAll(), hasLength(1));
    await assistant.handle(half);
    await assistant.handle('нет');
    expect(memory.positives, isEmpty);
    expect(memory.negatives, isEmpty);
    expect(memory.unclear, hasLength(2), reason: 'журнал включён отдельно');
  });

  test('приватные фразы не доходят до модели и до журнала', () async {
    for (final phrase in <String>[
      'пароль от почты CANARY',
      'мой пин 4821 где-то записан',
      'код подтверждения 552301 пришёл',
      'не помню логин от банка',
      'Qwerty2026 вот такой',
      'паролль от вк',
    ]) {
      final response = await assistant.handle(phrase);
      expect(
        response.replyId,
        isNot(AssistantController.intentSuggestReply),
        reason: phrase,
      );
    }
    expect(encoder.seen, isEmpty);
    expect(memory.unclear, isEmpty);
    expect(store.saves, 0);
  });

  test('понятая правилами фраза модель не спрашивает', () async {
    await assistant.handle('добавь задачу купить хлеб');
    await assistant.handle('2+2');
    await assistant.handle('привет');
    expect(encoder.seen, isEmpty);
    expect(memory.unclear, isEmpty);
  });

  test('«Да», а команду из фразы не разобрать — пример команды', () async {
    await assistant.handle(style);
    final response = await assistant.handle('да');
    expect(response.replyId, AssistantController.intentHowReply);
    expect(response.message, contains('говори короче'));
    expect(memory.positives.single.label, 'talk:talk.setting');
  });

  test('справочный вопрос без справочника — тоже «не понял» для модели',
      () async {
    final plain = await controller().handle(mortgage);
    expect(plain.replyId, 'talk.question.offline');
    final response = await assistant.handle(mortgage);
    expect(response.replyId, AssistantController.intentSuggestReply);
    expect(response.message, contains('посмотреть список задач'));
    // Сам справочный вопрос модель не предлагает.
    encoder.table[mortgage] =
        fakeVector(<String, double>{'talk:talk.question': 1});
    final again = await assistant.handle(mortgage);
    expect(again.replyId, 'talk.question.offline');
  });

  test('без модели — прежний ответ, журнал ведётся', () async {
    assistant.intent = IntentFallback(memory: memory);
    final response = await assistant.handle(cinema);
    expect(response.replyId, TasksConnector.unknownReply);
    expect(memory.unclear.single.kind, UnclearKind.unknown);
  });

  test('без запасного слоя — ответ слово в слово прежний', () async {
    final plain = controller();
    final a = await plain.handle(vague);
    final b = await (controller()..intent = null).handle(vague);
    expect(b.message, a.message);
    expect(b.replyId, a.replyId);
  });

  test('сбой модели — обычное «не понял»', () async {
    encoder.fail = true;
    final response = await assistant.handle(cinema);
    expect(response.replyId, TasksConnector.unknownReply);
  });

  test('выключенный навык модель не предлагает', () async {
    final noCalc = AssistantController(
      connectors: <Connector>[
        TasksConnector(
          taskService: tasks,
          parser: ScenarioParser(clock: clock),
        ),
      ],
      clock: clock,
    )..intent = IntentFallback(model: fakeModel(encoder), memory: memory);
    final response = await noCalc.handle(half);
    expect(response.replyId, TasksConnector.unknownReply);
  });
}
