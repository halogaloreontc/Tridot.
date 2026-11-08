// Чат задачи: задача — неявный контекст (docs/CONNECTORS.md, «Чат задачи»,
// ADR-010). «Готово», «закрой», «на завтра» относятся к ней без вопроса,
// остальные команды работают как в главном чате.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/task_chat_phrases.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/models/bulk.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

final _now = DateTime(2026, 11, 4, 12);
final _clock = FixedClock(_now);

final class _Fixture {
  _Fixture(this.tasks, this.assistant, this.bread, this.report, this.milk);

  final TaskService tasks;
  final AssistantController assistant;
  final Task bread;
  final Task report;
  final Task milk;

  Future<Task> get(String id) async =>
      (await tasks.listAll()).firstWhere((Task t) => t.id == id);

  Future<AssistantResponse> say(String text, {String? chat}) =>
      assistant.handle(text, chatTaskId: chat);
}

Future<_Fixture> _fixture() async {
  final tasks =
      TaskService(repository: InMemoryTaskRepository(), clock: _clock);
  final assistant = AssistantController(
    connectors: <Connector>[
      TasksConnector(taskService: tasks, parser: ScenarioParser(clock: _clock)),
      const CalculatorConnector(),
      TalkConnector(taskService: tasks),
    ],
    clock: _clock,
  );
  final bread = await tasks.create(title: 'Купить хлеб');
  final report = await tasks.create(
    title: 'Отчёт за квартал',
    dueAt: DateTime(2026, 11, 5, 10),
  );
  final milk = await tasks.create(title: 'Купить молоко');
  return _Fixture(tasks, assistant, bread, report, milk);
}

void main() {
  group('завершение задачи чата без вопроса', () {
    for (final phrase in <String>[
      'готово',
      'сделано',
      'выполнено',
      'заверши',
      'отметь выполненной',
      'закрой',
      'закрывай',
      'закрой её',
      'можно закрывать',
      'отметь',
      'готово, спасибо',
      'сделано, ура',
      'я купил хлеб',
    ]) {
      test('«$phrase»', () async {
        final f = await _fixture();
        final response = await f.say(phrase, chat: f.bread.id);
        expect(response.intent, 'task.complete', reason: response.message);
        expect(response.status, AssistantStatus.completed);
        expect((await f.get(f.bread.id)).status, TaskStatus.done);
        expect((await f.get(f.milk.id)).isActive, isTrue);
        expect((await f.get(f.report.id)).isActive, isTrue);
        expect(f.assistant.session.pendingConfirmation, isNull);
      });
    }
  });

  group('перенос задачи чата', () {
    for (final (phrase, due) in <(String, DateTime)>[
      ('перенеси на завтра', DateTime(2026, 11, 5)),
      ('на завтра', DateTime(2026, 11, 5)),
      ('на пятницу в 10', DateTime(2026, 11, 6, 10)),
      ('давай на понедельник', DateTime(2026, 11, 9)),
      ('завтра в 9', DateTime(2026, 11, 5, 9)),
    ]) {
      test('«$phrase»', () async {
        final f = await _fixture();
        final response = await f.say(phrase, chat: f.report.id);
        expect(response.intent, 'task.reschedule', reason: response.message);
        expect(response.status, AssistantStatus.completed);
        expect((await f.get(f.report.id)).dueAt, due);
        expect((await f.get(f.bread.id)).dueAt, isNull);
      });
    }
  });

  test('названа другая задача — меняется она', () async {
    final f = await _fixture();
    await f.say('закрой «Купить молоко»', chat: f.bread.id);
    expect((await f.get(f.milk.id)).status, TaskStatus.done);
    expect((await f.get(f.bread.id)).isActive, isTrue);

    await f.say('перенеси отчёт за квартал на пятницу', chat: f.bread.id);
    expect((await f.get(f.report.id)).dueAt, DateTime(2026, 11, 6));
    expect((await f.get(f.bread.id)).dueAt, isNull);

    final missing = await f.say('закрой «Нет такой»', chat: f.bread.id);
    expect(missing.status, AssistantStatus.needsClarification);
    expect((await f.get(f.bread.id)).isActive, isTrue);
  });

  test(
      'названная задача не нашлась или их несколько — вопрос, а не задача '
      'чата', () async {
    final f = await _fixture();
    await f.tasks.create(title: 'Отчёт за год');
    for (final phrase in <String>[
      'заверши отчёт',
      'закрой отчёт',
      'перенеси отчёт на завтра',
      'заверши задачу позвонить маме',
      'перенеси звонок на завтра',
    ]) {
      final response = await f.say(phrase, chat: f.bread.id);
      expect(
        response.status,
        AssistantStatus.needsClarification,
        reason: '$phrase → ${response.message}',
      );
      final bread = await f.get(f.bread.id);
      expect(bread.isActive, isTrue, reason: phrase);
      expect(bread.dueAt, isNull, reason: phrase);
    }
    final several = await f.say('заверши отчёт', chat: f.bread.id);
    expect(several.replyId, 'task.ask.severalMatch');
    final missing =
        await f.say('заверши задачу позвонить маме', chat: f.bread.id);
    expect(missing.replyId, 'task.notFound');
    // Название самой задачи чата — по-прежнему она.
    await f.say('закрой хлеб', chat: f.bread.id);
    expect((await f.get(f.bread.id)).status, TaskStatus.done);
  });

  test('прощание в чате задачи — беседа, а не перенос', () async {
    final f = await _fixture();
    for (final phrase in <String>['до завтра', 'до понедельника']) {
      final response = await f.say(phrase, chat: f.bread.id);
      expect(response.intent, isNot('task.reschedule'), reason: phrase);
      expect((await f.get(f.bread.id)).dueAt, isNull, reason: phrase);
    }
    final bye = await f.say('до завтра', chat: f.bread.id);
    expect(bye.intent, startsWith('talk.'));
  });

  test('задачу закрыли в её чате — в главном она больше не «её»', () async {
    final f = await _fixture();
    final created = await f.say('добавь задачу купить сыр');
    final cheese = created.task!.id;
    expect(f.assistant.selectedTaskId, cheese);
    f.assistant.enterChat(taskId: cheese);
    await f.say('готово', chat: cheese);
    expect((await f.get(cheese)).status, TaskStatus.done);
    f.assistant.enterChat();
    expect(f.assistant.selectedTaskId, isNull);
    final move = await f.say('перенеси её на завтра');
    expect(move.status, AssistantStatus.needsClarification);
    expect((await f.get(cheese)).dueAt, isNull);
  });

  test('новая задача из чата задачи: цель чата не меняется', () async {
    final f = await _fixture();
    final created = await f.say('добавь задачу купить сыр', chat: f.bread.id);
    expect(created.intent, 'task.create');
    expect(created.task?.title, 'Купить сыр');
    await f.say('готово', chat: f.bread.id);
    expect((await f.get(f.bread.id)).status, TaskStatus.done);
    expect((await f.get(created.task!.id)).isActive, isTrue);
  });

  test('калькулятор, беседа и массовые команды — как в главном', () async {
    final f = await _fixture();
    expect((await f.say('2+2', chat: f.bread.id)).message, '2 + 2 = 4');
    final talk = await f.say('привет', chat: f.bread.id);
    expect(talk.intent, startsWith('talk.'));
    final bulk = await f.say('перенеси всё на выходные', chat: f.bread.id);
    expect(bulk.checklist, isNotNull);
    expect(bulk.checklist!.items.length, 3);
    expect((await f.get(f.bread.id)).dueAt, isNull, reason: 'ждёт «да»');
  });

  test('в главном чате «закрой» и «на завтра» по-прежнему не поняты', () async {
    final f = await _fixture();
    f.assistant.selectTask(f.bread.id);
    for (final phrase in <String>['закрой', 'на завтра', 'на пятницу в 10']) {
      final response = await f.say(phrase);
      expect(response.intent, 'unknown', reason: phrase);
    }
    expect((await f.get(f.bread.id)).isActive, isTrue);
    expect((await f.get(f.bread.id)).dueAt, isNull);
  });

  test('выполненная задача чата: «готово» и перенос ничего не меняют',
      () async {
    final f = await _fixture();
    await f.say('готово', chat: f.bread.id);
    for (final phrase in <String>['готово', 'перенеси на завтра', 'закрой']) {
      final response = await f.say(phrase, chat: f.bread.id);
      expect(response.replyId, 'task.chat.alreadyDone', reason: phrase);
      expect(response.message, 'Задача «Купить хлеб» уже выполнена.');
      expect(response.status, AssistantStatus.noAction);
    }
    final bread = await f.get(f.bread.id);
    expect(bread.status, TaskStatus.done);
    expect(bread.dueAt, isNull);
  });

  test('смена чата снимает вопрос: «да» в другом чате не применяет его',
      () async {
    final f = await _fixture();
    final ask = await f.say('закрой все задачи');
    final checklist = ask.checklist!;
    expect(f.assistant.session.pendingConfirmation, isNotNull);
    f.assistant.enterChat(taskId: f.bread.id);
    expect(f.assistant.session.pendingConfirmation, isNull);
    expect(checklist.state, BulkChecklistState.expired);
    await f.say('да', chat: f.bread.id);
    expect((await f.get(f.milk.id)).isActive, isTrue);
    expect((await f.get(f.report.id)).isActive, isTrue);
  });

  test('выбор главного чата восстанавливается после чата задачи', () async {
    final f = await _fixture();
    f.assistant.selectTask(f.report.id);
    f.assistant.enterChat(taskId: f.bread.id);
    expect(f.assistant.selectedTaskId, f.bread.id);
    expect(f.assistant.chatTaskId, f.bread.id);
    f.assistant.enterChat();
    expect(f.assistant.selectedTaskId, f.report.id);
    expect(f.assistant.chatTaskId, isNull);
  });

  test('смена чата во время ответа применяется после него', () async {
    final f = await _fixture();
    final future = f.say('готово', chat: f.bread.id);
    f.assistant.enterChat();
    await future;
    expect((await f.get(f.bread.id)).status, TaskStatus.done);
    expect(f.assistant.session.chatTaskId, isNull);
  });

  group('TaskChatPhrases', () {
    Utterance chat(String text) =>
        Utterance.analyze(text, now: _now).withChat('t');

    test('только в чате задачи', () {
      expect(
        TaskChatPhrases.match(Utterance.analyze('закрой', now: _now)),
        isNull,
      );
      expect(TaskChatPhrases.match(chat('закрой')), isNotNull);
    });

    test('не срок и не просьба закрыть — не своё', () {
      for (final phrase in <String>[
        'на завтра купить молоко',
        'закрой окно',
        'на завтра?',
        'отметь «Хлеб»',
        'завтра #работа',
        'давай',
      ]) {
        expect(TaskChatPhrases.match(chat(phrase)), isNull, reason: phrase);
      }
    });
  });
}
