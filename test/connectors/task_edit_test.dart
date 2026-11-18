import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/task_edit_phrases.dart';
import 'package:local_assistant/core/connectors/task_rephrase.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

/// Правки текущей и названной задачи, заметки и перефразирование
/// (ADR-033).
void main() {
  group('TaskRephrase.title', () {
    test('обёртки просьбы снимаются перед делом', () {
      expect(TaskRephrase.title('Нужно позвонить Андрею'), 'Позвонить Андрею');
      expect(TaskRephrase.title('что надо бы купить хлеб.'), 'Купить хлеб');
      expect(TaskRephrase.title('я позвонил маме'), 'Позвонить маме');
      expect(
        TaskRephrase.title('доделать по складу реестр стринтина!'),
        'Доделать по складу реестр стринтина',
      );
    });

    test('без уверенного правила — слова пользователя, но чисто', () {
      expect(TaskRephrase.title('что их 22 шт'), 'Что их 22 шт');
      expect(TaskRephrase.title('  отчёт 2026,  '), 'Отчёт 2026');
    });

    test('одно местоимение — не название', () {
      expect(TaskRephrase.title('Них'), '');
      expect(TaskRephrase.title('про них'), '');
      expect(TaskRephrase.title('это'), '');
    });
  });

  group('TaskRephrase.note', () {
    test('фраза владельца — строка фактов', () {
      expect(
        TaskRephrase.note('их 22шт в ок, 1шт в уценке под артикулом 67782'),
        '22 шт в ОК, 1 шт в уценке, арт. 67782',
      );
    });

    test('числа не меняются, единицы и артикул — коротко', () {
      expect(TaskRephrase.note('там 5 штук, артикул A-17'), '5 шт, арт. A-17');
      expect(TaskRephrase.note('поставщик перезвонит'), 'поставщик перезвонит');
      expect(TaskRephrase.note('коробка ок.'), 'коробка ОК');
    });
  });

  group('TaskEditPhrases.parse', () {
    final now = DateTime(2026, 11, 2, 16, 30);
    TaskEdit? parse(String text, {String? recent}) => TaskEditPhrases.parse(
          Utterance.analyze(text, now: now)
              .withChat(null, recentConnectorId: recent),
        );

    test('заметка с названной задачей', () {
      final edit = parse(
        'в эссен запиши, что их 22шт в ок, 1шт в уценке под артикулом 67782',
      )!;
      expect(edit.kind, TaskEditKind.note);
      expect(edit.target, 'эссен');
      expect(edit.text, '22 шт в ОК, 1 шт в уценке, арт. 67782');
    });

    test('срок без названия', () {
      final edit = parse('Поставь время 11:00')!;
      expect(edit.kind, TaskEditKind.due);
      expect(edit.target, isNull);
      expect(edit.dueAt, DateTime(2026, 11, 3, 11));
    });

    test('одна дата — только в разговоре о задаче', () {
      expect(parse('на завтра'), isNull);
      expect(parse('на завтра', recent: 'tasks')!.bare, isTrue);
      expect(parse('сегодня', recent: 'tasks'), isNull);
    });

    test('не правки: создание, будильник, вопрос', () {
      expect(parse('напомни купить хлеб в 9'), isNull);
      expect(parse('поставь будильник на 7'), isNull);
      expect(parse('поставь задачу купить хлеб на завтра'), isNull);
      expect(parse('добавь задачу купить хлеб'), isNull);
      expect(parse('что записать в эссен?'), isNull);
    });
  });

  group('в чате', () {
    late TaskService tasks;
    late AssistantController assistant;
    final clock = FixedClock(DateTime(2026, 11, 2, 9, 30));

    setUp(() {
      tasks = TaskService(repository: InMemoryTaskRepository(), clock: clock);
      assistant = AssistantController(
        connectors: <Connector>[
          TasksConnector(
            taskService: tasks,
            parser: ScenarioParser(clock: clock),
          ),
          TalkConnector(taskService: tasks),
        ],
        clock: clock,
      );
    });

    test('«Напомни X» без времени — вопрос «Когда?», потом время', () async {
      final created = await assistant
          .handle('Напомни, доделать по складу реестр стринтина');
      expect(created.task?.title, 'Доделать по складу реестр стринтина');
      expect(created.replyId, 'task.created.askWhen');
      expect(
        created.clarification!.options.map((ClarifyOption o) => o.label),
        <String>['Сегодня вечером', 'Завтра утром', 'Выбрать время'],
      );
      final timed = await assistant.handle('Поставь время 11:00');
      expect(timed.status, AssistantStatus.completed);
      final task = (await tasks.listActive()).single;
      expect(task.dueAt, DateTime(2026, 11, 2, 11));
      expect(timed.message, contains('сегодня в 11:00'));
    });

    test('кнопка «Завтра утром» ставит срок той же задаче', () async {
      await assistant.handle('Напомни позвонить поставщику');
      final answered = await assistant.handle('Завтра утром');
      expect(answered.status, AssistantStatus.completed);
      final all = await tasks.listActive();
      expect(all, hasLength(1));
      expect(all.single.dueAt, DateTime(2026, 11, 3, 9));
      // Срок в кнопке — числами («3 ноября в 9:00»), поэтому время точное.
      expect(all.single.duePrecision, DuePrecision.dateTime);
    });

    test('чат задачи: «напомни про них» — не задача «Них»', () async {
      final essen = await tasks.create(title: 'Эссен');
      assistant.enterChat(taskId: essen.id);
      final asked =
          await assistant.handle('напомни про них', chatTaskId: essen.id);
      expect(asked.replyId, 'task.remind.when');
      expect(await tasks.listActive(), hasLength(1));
      await assistant.handle('в пятницу утром', chatTaskId: essen.id);
      final task = (await tasks.listActive()).single;
      expect(task.dueAt, DateTime(2026, 11, 6, 9));
    });

    test('заметка в названную задачу — в неё, а не новая задача', () async {
      await tasks.create(title: 'Эссен');
      final added = await assistant.handle(
        'в эссен запиши, что их 22шт в ок, 1шт в уценке под артикулом 67782',
      );
      expect(
        added.message,
        endsWith('в «Эссен»: 22 шт в ОК, 1 шт в уценке, арт. 67782.'),
      );
      final task = (await tasks.listActive()).single;
      expect(task.notes.single.text, '22 шт в ОК, 1 шт в уценке, арт. 67782');
      expect(task.notes.single.at, clock.now());
    });

    test('падеж названия: «по эссену отметь, что…»', () async {
      await tasks.create(title: 'Эссен');
      await assistant.handle('по эссену отметь, что всё пришло');
      expect((await tasks.listActive()).single.notes.single.text, 'всё пришло');
    });

    test('несколько подходящих задач — вопрос с кнопками', () async {
      await tasks.create(title: 'Эссен склад');
      await tasks.create(title: 'Эссен офис');
      final asked = await assistant.handle('в эссен запиши, что пришло 3 шт');
      expect(asked.status, AssistantStatus.needsClarification);
      expect(
        asked.clarification!.options.map((ClarifyOption o) => o.label),
        containsAll(<String>['Эссен склад', 'Эссен офис']),
      );
      await assistant.handle('Эссен офис');
      final office = (await tasks.listActive())
          .firstWhere((Task t) => t.title == 'Эссен офис');
      expect(office.notes.single.text, 'пришло 3 шт');
    });

    test('заметка после другого разговора — «в задачу или новая?»', () async {
      await assistant.handle('Добавь задачу «Отчёт»');
      await assistant.handle('как дела?');
      final asked =
          await assistant.handle('запиши, что нужно приложить акт сверки');
      expect(asked.replyId, 'task.note.where');
      expect(
        asked.clarification!.options.map((ClarifyOption o) => o.label),
        <String>['В «Отчёт»', 'Новая'],
      );
      final created = await assistant.handle('Новая');
      expect(created.task?.title, 'Приложить акт сверки');
      expect(await tasks.listActive(), hasLength(2));
    });

    test('сразу после создания заметка — в эту задачу', () async {
      await assistant.handle('Добавь задачу «Отчёт»');
      await assistant.handle('добавь, что нужен акт сверки');
      expect(
        (await tasks.listActive()).single.notes.single.text,
        'нужен акт сверки',
      );
    });

    test('без задачи заметка-дело становится задачей', () async {
      final created = await assistant.handle('запиши, что надо купить хлеб');
      expect(created.task?.title, 'Купить хлеб');
    });

    test('пункты и новое название', () async {
      await assistant.handle('Добавь задачу «Покупки»');
      await assistant.handle('добавь пункты молоко, хлеб и сыр');
      await assistant.handle('переименуй в Покупки на выходные');
      final task = (await tasks.listActive()).single;
      expect(task.title, 'Покупки на выходные');
      expect(
        task.items.map((TaskItem i) => i.text),
        <String>['Молоко', 'Хлеб', 'Сыр'],
      );
    });

    test('«напомни про X» при активной X — её срок, без второй', () async {
      await tasks.create(title: 'Эссен');
      await assistant.handle('напомни про эссен завтра в 10');
      final all = await tasks.listActive();
      expect(all, hasLength(1));
      expect(all.single.dueAt, DateTime(2026, 11, 3, 10));
    });
  });

  group('хранение', () {
    test('заметки и пункты переживают JSON, старый файл — без них', () {
      final now = DateTime(2026, 11, 2, 9);
      final task = Task(
        id: 't1',
        title: 'Эссен',
        status: TaskStatus.inbox,
        priority: TaskPriority.normal,
        createdAt: now,
        updatedAt: now,
        notes: <TaskNote>[TaskNote(text: '22 шт в ОК', at: now)],
        items: const <TaskItem>[TaskItem(text: 'Молоко', done: true)],
      );
      final back = Task.fromJson(
        jsonDecode(jsonEncode(task.toJson())) as Map<String, dynamic>,
      );
      expect(back.notes.single.text, '22 шт в ОК');
      expect(back.notes.single.at, now);
      expect(back.items.single.done, isTrue);

      final old = task.toJson()
        ..remove('notes')
        ..remove('items');
      final migrated = Task.fromJson(old);
      expect(migrated.notes, isEmpty);
      expect(migrated.items, isEmpty);

      final broken = task.toJson()
        ..['notes'] = <Object?>[
          <String, Object?>{'text': '', 'at': 'x'},
          42,
        ];
      expect(Task.fromJson(broken).notes, isEmpty);
    });
  });

  group('«Когда напомнить?» по времени суток (ReminderChoices)', () {
    late _Clock clock;
    late TaskService tasks;
    late AssistantController assistant;

    void at(int hour, [int minute = 0, int day = 2]) =>
        clock.now_ = DateTime(2026, 11, day, hour, minute);

    setUp(() {
      clock = _Clock(DateTime(2026, 11, 2, 16, 30));
      tasks = TaskService(repository: InMemoryTaskRepository(), clock: clock);
      assistant = AssistantController(
        connectors: <Connector>[
          TasksConnector(
            taskService: tasks,
            parser: ScenarioParser(clock: clock),
          ),
          TalkConnector(taskService: tasks),
        ],
        clock: clock,
      );
    });

    Future<List<String>> labels() async {
      final asked = await assistant.handle('Напомни позвонить поставщику');
      return <String>[
        for (final option in asked.clarification!.options) option.label,
      ];
    }

    test('днём — вечер сегодня и утро завтра', () async {
      at(16, 30);
      expect(
        await labels(),
        <String>['Сегодня вечером', 'Завтра утром', 'Выбрать время'],
      );
    });

    test('с 18:00 — через час; после 21:00 — завтра утром и вечером', () async {
      at(18, 40);
      expect(
        await labels(),
        <String>['Через час', 'Завтра утром', 'Выбрать время'],
      );
      final hour = await assistant.handle('Через час');
      expect(hour.status, AssistantStatus.completed);
      expect(
        (await tasks.listActive()).single.dueAt,
        DateTime(2026, 11, 2, 19, 40),
      );

      at(23, 30);
      final asked = await assistant.handle('Напомни купить корм');
      expect(
        <String>[for (final o in asked.clarification!.options) o.label],
        <String>['Завтра утром', 'Завтра вечером', 'Выбрать время'],
        reason: '«через час» в 23:30 — напоминание ночью',
      );
    });

    test('ночью «утром» — сегодняшнее утро', () async {
      at(1, 10, 3);
      expect(await labels(), <String>['Утром', 'Вечером', 'Выбрать время']);
      await assistant.handle('Утром');
      expect(
        (await tasks.listActive()).single.dueAt,
        DateTime(2026, 11, 3, 9),
      );
    });

    test('кнопка нажата поздно — вопрос, а не прошедший срок', () async {
      at(16, 30);
      final asked = await assistant.handle('Напомни позвонить поставщику');
      final evening = asked.clarification!.options.first;
      expect(evening.label, 'Сегодня вечером');
      // Кнопку нажали в 20:30: «сегодня вечером» было бы 19:00 — прошло.
      at(20, 30);
      final late = await assistant.handle(evening.text);
      expect(late.status, isNot(AssistantStatus.completed));
      expect((await tasks.listActive()).single.dueAt, isNull);
    });

    test('после 21:00 набранное «сегодня» не выбирает «Завтра вечером»',
        () async {
      at(22, 15);
      await assistant.handle('Напомни позвонить поставщику');
      await assistant.handle('сегодня');
      final due = (await tasks.listActive()).single.dueAt;
      expect(due, isNot(DateTime(2026, 11, 3, 19)));
    });

    test('после полуночи «Завтра утром» не уезжает на день', () async {
      at(22, 15);
      final asked = await assistant.handle('Напомни позвонить поставщику');
      final morning = asked.clarification!.options.first;
      expect(morning.label, 'Завтра утром');
      at(0, 10, 3);
      await assistant.handle(morning.text);
      expect(
        (await tasks.listActive()).single.dueAt,
        DateTime(2026, 11, 3, 9),
      );
    });
  });
}

final class _Clock implements Clock {
  _Clock(this.now_);

  DateTime now_;

  @override
  DateTime now() => now_;
}
