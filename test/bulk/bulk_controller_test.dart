import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/models/bulk.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/personas/persona.dart';
import 'package:local_assistant/core/replies/reply_catalog.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

/// Массовые команды в разговоре: вопрос со списком, «кроме …», «да»,
/// отмена и снятие вопроса посторонним сообщением (ADR-004).
void main() {
  final clock = FixedClock(DateTime(2026, 11, 2, 16, 30)); // понедельник
  late InMemoryTaskRepository repository;
  late TaskService service;
  late AssistantController assistant;
  late Task bread;
  late Task report;
  late Task bill;
  late Task idea;

  setUp(() async {
    repository = InMemoryTaskRepository();
    service = TaskService(repository: repository, clock: clock);
    assistant = AssistantController(
      connectors: <Connector>[
        TasksConnector(
          taskService: service,
          parser: ScenarioParser(clock: clock),
        ),
        TalkConnector(taskService: service),
      ],
      clock: clock,
    );
    bread = await service.create(
      title: 'Купить хлеб',
      dueAt: DateTime(2026, 11, 1),
      duePrecision: DuePrecision.date,
    );
    report = await service.create(
      title: 'Сдать отчёт',
      dueAt: DateTime(2026, 11, 2, 10),
      tags: <String>['работа'],
    );
    bill = await service.create(
      title: 'Оплатить счёт',
      dueAt: DateTime(2026, 11, 2, 20),
      tags: <String>['работа'],
    );
    idea = await service.create(title: 'Придумать подарок');
  });

  Future<Task> byId(String id) async =>
      (await service.listAll()).firstWhere((Task t) => t.id == id);

  test('вопрос со списком: ничего не меняется, все отмечены', () async {
    final response = await assistant.handle('Перенеси всё на выходные');

    expect(response.status, AssistantStatus.needsClarification);
    expect(response.intent, TasksConnector.rescheduleManyCommand);
    expect(response.replyId, 'task.bulk.ask.reschedule');
    expect(
        response.message,
        'Перенести 4 задачи на 7 ноября? '
        'Лишние задачи можно снять в списке.');
    final checklist = response.checklist!;
    expect(checklist.isPending, isTrue);
    expect(checklist.items.map((BulkItem i) => i.title), <String>[
      'Купить хлеб',
      'Сдать отчёт',
      'Оплатить счёт',
      'Придумать подарок',
    ]);
    expect(checklist.items.every((BulkItem i) => i.checked), isTrue);
    expect(checklist.items.first.dueLabel, 'вчера');
    expect(checklist.items.last.dueLabel, isNull);
    expect(checklist.targetLabel, 'сб, 7 ноября');
    expect(assistant.pendingChecklist, same(checklist));
    expect((await byId(bread.id)).dueAt, DateTime(2026, 11, 1));
  });

  test('выбор по признаку и пустой выбор — понятный ответ', () async {
    final overdue = await assistant.handle('перенеси просроченные на пятницу');
    expect(
      overdue.checklist!.items.map((BulkItem i) => i.taskId),
      <String>[bread.id, report.id],
    );

    final tagged = await assistant.handle('закрой все задачи с #работа');
    expect(tagged.replyId, 'task.bulk.ask.complete');
    expect(
      tagged.checklist!.items.map((BulkItem i) => i.taskId),
      <String>[report.id, bill.id],
    );

    final none =
        await assistant.handle('перенеси все задачи с #дача на завтра');
    expect(none.status, AssistantStatus.noAction);
    expect(none.message, 'Подходящих задач с #дача нет.');
    expect(none.checklist, isNull);

    await assistant.handle('закрой все просроченные');
    await assistant.handle('да');
    final empty = await assistant.handle('закрой все просроченные');
    expect(empty.message, 'Просроченных задач нет.');
    expect(assistant.pendingChecklist, isNull);
  });

  test('«кроме …» снимает отметку и спрашивает снова, «да» — только отмеченные',
      () async {
    final ask = await assistant.handle('перенеси всё на выходные');
    final checklist = ask.checklist!;

    final except = await assistant.handle('кроме хлеба');
    expect(except.status, AssistantStatus.needsClarification);
    expect(
        except.message,
        'Снял отметку: «Купить хлеб». '
        'Перенести 3 задачи на 7 ноября? Лишние задачи можно снять в списке.');
    expect(except.checklist, same(checklist));
    expect(assistant.pendingChecklist, same(checklist));
    expect(checklist.checkedIds, <String>[report.id, bill.id, idea.id]);

    final missing = await assistant.handle('кроме молока');
    expect(missing.message, startsWith('В списке нет «молока». Перенести 3'));
    expect(assistant.pendingChecklist, same(checklist));

    // Галочка в карточке — не сообщение: вопрос ждёт ответа дальше.
    expect(assistant.setBulkItemChecked(checklist, idea.id, false), isTrue);
    expect(assistant.pendingChecklist, same(checklist));

    final done = await assistant.handle('да');
    expect(done.status, AssistantStatus.completed);
    expect(done.replyId, 'task.bulk.rescheduled.partial');
    expect(done.message, 'Перенёс на 7 ноября 2 задачи из 4.');
    expect(checklist.state, BulkChecklistState.applied);
    expect(checklist.applied, 2);
    expect(checklist.canUndo, isTrue);
    expect((await byId(report.id)).dueAt, DateTime(2026, 11, 7));
    expect((await byId(report.id)).duePrecision, DuePrecision.date);
    expect((await byId(bread.id)).dueAt, DateTime(2026, 11, 1));
    expect((await byId(idea.id)).dueAt, isNull);
    expect(assistant.pendingChecklist, isNull);
  });

  test('«только …» и «да, кроме …» оставляют вопрос в силе', () async {
    final checklist =
        (await assistant.handle('перенеси всё на завтра')).checklist!;
    final only = await assistant.handle('только отчёт и счёт');
    expect(
      only.message,
      startsWith('Оставил отмеченными только «Сдать отчёт», '
          '«Оплатить счёт». Перенести 2 задачи на завтра?'),
    );
    expect(checklist.checkedIds, <String>[report.id, bill.id]);

    await assistant.handle('да, кроме счёта');
    expect(checklist.checkedIds, <String>[report.id]);
    expect(checklist.isPending, isTrue);

    await assistant.handle('кроме отчёта');
    final none = assistant.pendingChecklist!;
    expect(none.checkedCount, 0);
    final yes = await assistant.handle('да');
    expect(yes.message, 'Не отмечено ни одной задачи — ничего не меняю.');
    expect(checklist.state, BulkChecklistState.cancelled);
    expect((await byId(report.id)).dueAt, DateTime(2026, 11, 2, 10));
  });

  test('«нет» и «отмена» — ничего не меняется', () async {
    final checklist =
        (await assistant.handle('закрой все сегодняшние')).checklist!;
    expect(checklist.items, hasLength(2));
    final no = await assistant.handle('отмена');
    expect(no.message, 'Хорошо, ничего не меняю.');
    expect(checklist.state, BulkChecklistState.cancelled);
    expect(await service.listActive(), hasLength(4));
  });

  test('постороннее сообщение снимает вопрос, карточка устаревает', () async {
    final checklist =
        (await assistant.handle('перенеси всё на выходные')).checklist!;
    final other = await assistant.handle('Добавь задачу купить молоко');
    expect(other.intent, 'task.create');
    expect(assistant.pendingChecklist, isNull);
    expect(checklist.state, BulkChecklistState.expired);
    expect(assistant.setBulkItemChecked(checklist, bread.id, false), isFalse);
    expect(await assistant.answerBulk(checklist, apply: true), isNull);

    final yes = await assistant.handle('да');
    expect(yes.intent, isNot(TasksConnector.rescheduleManyCommand));
    expect((await byId(bread.id)).dueAt, DateTime(2026, 11, 1));
  });

  test('новый массовый вопрос заменяет прежний', () async {
    final first =
        (await assistant.handle('перенеси всё на выходные')).checklist!;
    final second = (await assistant.handle('закрой всё')).checklist!;
    expect(first.state, BulkChecklistState.expired);
    expect(assistant.pendingChecklist, same(second));
  });

  test('отмена: «отмени» возвращает сроки, и без срока тоже', () async {
    await assistant.handle('перенеси всё на выходные');
    await assistant.handle('да');
    expect((await byId(idea.id)).dueAt, DateTime(2026, 11, 7));

    final undo = await assistant.handle('отмени');
    expect(undo.intent, TasksConnector.undoCommand);
    expect(undo.message, 'Вернул как было: 4 задачи.');
    expect((await byId(idea.id)).dueAt, isNull);
    expect((await byId(idea.id)).status, TaskStatus.inbox);
    expect((await byId(bread.id)).dueAt, DateTime(2026, 11, 1));
    expect((await byId(report.id)).dueAt, DateTime(2026, 11, 2, 10));
    expect((await byId(report.id)).duePrecision, DuePrecision.dateTime);

    final again = await assistant.handle('отмени');
    expect(again.replyId, 'task.bulk.undo.nothing');
  });

  test('отмена завершения возвращает задачи в работу; кнопки карточки',
      () async {
    final checklist =
        (await assistant.handle('закрой все просроченные')).checklist!;
    final applied = await assistant.answerBulk(checklist, apply: true);
    expect(applied!.message, 'Отметил выполненными 2 задачи.');
    expect(await service.listActive(), hasLength(2));
    expect(checklist.canUndo, isTrue);

    final undone = await assistant.undoBulk(checklist);
    expect(undone!.replyId, 'task.bulk.undone');
    expect(checklist.state, BulkChecklistState.undone);
    expect(checklist.canUndo, isFalse);
    expect(await service.listActive(), hasLength(4));
    expect((await byId(bread.id)).completedAt, isNull);
    expect(await assistant.undoBulk(checklist), isNull);
  });

  test('отменить можно только последнее массовое изменение', () async {
    final first =
        (await assistant.handle('перенеси всё на выходные')).checklist!;
    await assistant.handle('да');
    final second =
        (await assistant.handle('закрой все задачи с #работа')).checklist!;
    await assistant.handle('да');
    expect(first.canUndo, isFalse);
    expect(second.canUndo, isTrue);
    expect(await assistant.undoBulk(first), isNull);

    assistant.clearConversation();
    expect(second.canUndo, isFalse);
    final nothing = await assistant.handle('верни всё как было');
    expect(nothing.replyId, 'task.bulk.undo.nothing');
    expect(await service.listActive(), hasLength(2));
  });

  test('отмена не трогает задачу, которую с тех пор изменили', () async {
    final later = FixedClock(DateTime(2026, 11, 2, 17));
    await assistant.handle('перенеси все сегодняшние на завтра');
    await assistant.handle('да');
    // Задачу поправили в интерфейсе позже массового переноса.
    await TaskService(repository: repository, clock: later)
        .reschedule(report.id, DateTime(2026, 11, 5), DuePrecision.date);
    final undo = await assistant.handle('отмени');
    expect(
      undo.message,
      'Вернул как было 1 из 2: остальные задачи с тех пор меняли.',
    );
    expect((await byId(report.id)).dueAt, DateTime(2026, 11, 5));
    expect((await byId(bill.id)).dueAt, DateTime(2026, 11, 2, 20));
  });

  test('сдвиг: часы — только задачам с точным временем', () async {
    final ask = await assistant.handle('сдвинь всё на час позже');
    expect(
        ask.message,
        'Сдвинуть 2 задачи на 1 час позже? '
        'Лишние задачи можно снять в списке.');
    expect(ask.checklist!.targetLabel, 'на 1 час позже');
    await assistant.handle('да');
    expect((await byId(report.id)).dueAt, DateTime(2026, 11, 2, 11));
    expect((await byId(bill.id)).dueAt, DateTime(2026, 11, 2, 21));
    expect((await byId(bread.id)).dueAt, DateTime(2026, 11, 1));

    final days = await assistant.handle('отложи всё на 2 дня');
    expect(days.checklist!.items, hasLength(3));
  });

  test('без срока переноса — вопрос, на когда; срок в прошлом — уточнение',
      () async {
    final when = await assistant.handle('перенеси всё');
    expect(when.replyId, 'task.bulk.ask.when');
    expect(when.checklist, isNull);
    final past = await assistant.handle('перенеси всё на вчера');
    expect(past.replyId, 'task.due.inPast');
    expect(assistant.pendingChecklist, isNull);
  });

  test('задачу завершили, пока список ждал ответа', () async {
    final checklist =
        (await assistant.handle('перенеси всё на выходные')).checklist!;
    await service.complete(bread.id);
    final done = await assistant.handle('да');
    expect(done.message, 'Перенёс на 7 ноября 3 задачи из 4.');
    expect(checklist.applied, 3);
    expect((await byId(bread.id)).status, TaskStatus.done);
  });

  test('смена настроек помощников не сбрасывает вопрос; отвечает спросивший',
      () async {
    final ask = await assistant.handle('Нода, перенеси всё на выходные');
    expect(ask.personaId, Personas.noda.id);
    final checklist = ask.checklist!;
    assistant.personas = const PersonaSettings(
      styles: <String, String>{
        'rio': ReplyStyles.business,
        'noda': ReplyStyles.brief,
      },
      emoji: false,
    );
    expect(assistant.pendingChecklist, same(checklist));
    expect(assistant.setBulkItemChecked(checklist, bread.id, false), isTrue);

    final yes = await assistant.handle('да');
    expect(yes.personaId, Personas.noda.id);
    expect(yes.message, 'Перенесено на 7 ноября: 3 из 4.');
    expect(checklist.applied, 3);
  });

  test('кнопка карточки отвечает голосом спросившего', () async {
    final ask = await assistant.handle('Нода, закрой все просроченные');
    final response = await assistant.answerBulk(ask.checklist!, apply: false);
    expect(response!.personaId, Personas.noda.id);
    expect(response.replyId, 'task.bulk.declined');
    expect(await service.listActive(), hasLength(4));
  });

  test('«всё, задача закрыта» и «перенеси встречу» — не массовые', () async {
    final single = await assistant.handle('перенеси встречу на завтра');
    expect(single.intent, 'task.reschedule');
    expect(single.checklist, isNull);

    await assistant.handle('Добавь задачу «Звонок»');
    final closed = await assistant.handle('всё, задача закрыта');
    expect(closed.intent, 'task.complete');
    expect(closed.status, AssistantStatus.completed);
    expect(closed.task?.title, 'Звонок');
    expect(closed.checklist, isNull);
    expect(await service.listActive(), hasLength(4));
  });

  group('регрессии ревью', () {
    test(
        '«отмени перенос» при новом вопросе — отказ от него, '
        'прошлое изменение остаётся', () async {
      await assistant.handle('закрой все просроченные');
      final done = await assistant.handle('да');
      expect(done.message, 'Отметил выполненными 2 задачи.');
      for (final phrase in <String>[
        'отмени перенос',
        'отмени всё',
        'отмена переноса',
        'не переноси',
      ]) {
        final ask = await assistant.handle('перенеси всё на выходные');
        final checklist = ask.checklist!;
        final no = await assistant.handle(phrase);
        expect(no.replyId, 'task.bulk.declined', reason: phrase);
        expect(checklist.state, BulkChecklistState.cancelled, reason: phrase);
        expect((await byId(bread.id)).status, TaskStatus.done, reason: phrase);
        expect(await service.listActive(), hasLength(2), reason: phrase);
      }
      // Без вопроса «отмени» по-прежнему отменяет последнее изменение.
      final undo = await assistant.handle('отмени');
      expect(undo.intent, TasksConnector.undoCommand);
      expect(await service.listActive(), hasLength(4));
    });

    test('«да» с исключением словами не применяет к исключённой задаче',
        () async {
      for (final phrase in <String>[
        'да, но не хлеб',
        'да, хлеб не трогай',
        'хлеб оставь',
        'да, не трогай хлеб',
      ]) {
        final checklist =
            (await assistant.handle('перенеси всё на выходные')).checklist!;
        final again = await assistant.handle(phrase);
        expect(
          again.status,
          AssistantStatus.needsClarification,
          reason: phrase,
        );
        expect(
          again.message,
          startsWith('Снял отметку: «Купить хлеб».'),
          reason: phrase,
        );
        expect(checklist.isPending, isTrue, reason: phrase);
        expect(
          checklist.checkedIds,
          <String>[report.id, bill.id, idea.id],
          reason: phrase,
        );
        expect((await byId(bread.id)).dueAt, DateTime(2026, 11, 1));
        await assistant.handle('нет');
      }
    });

    test('«да» с непонятной оговоркой переспрашивает; «да, перенеси» — да',
        () async {
      final checklist =
          (await assistant.handle('перенеси всё на выходные')).checklist!;
      final unclear = await assistant.handle('да, хлеб тоже');
      expect(unclear.status, AssistantStatus.needsClarification);
      expect(unclear.message, startsWith('Не понял уточнение.'));
      expect(checklist.isPending, isTrue);
      expect((await byId(bread.id)).dueAt, DateTime(2026, 11, 1));

      final yes = await assistant.handle('да, переноси');
      expect(yes.status, AssistantStatus.completed);
      expect(checklist.state, BulkChecklistState.applied);
      expect((await byId(bread.id)).dueAt, DateTime(2026, 11, 7));
    });

    test('«кроме воды»: формы коротких слов, предлоги не совпадают', () async {
      final bank = await service.create(title: 'Позвонить в банк');
      final water = await service.create(title: 'Купить воду');
      final checklist =
          (await assistant.handle('перенеси всё на завтра')).checklist!;
      final except = await assistant.handle('кроме воды');
      expect(except.message, startsWith('Снял отметку: «Купить воду».'));
      expect(checklist.checkedIds, isNot(contains(water.id)));
      expect(checklist.checkedIds, contains(bank.id));

      final only = await assistant.handle('только воду');
      expect(
        only.message,
        startsWith('Оставил отмеченными только «Купить воду».'),
      );
      expect(checklist.checkedIds, <String>[water.id]);
    });

    test('исключение в самой команде: «закрой всё, кроме хлеба»', () async {
      final ask = await assistant.handle('закрой всё, кроме хлеба');
      expect(ask.intent, TasksConnector.completeManyCommand);
      expect(
        ask.message,
        startsWith('Снял отметку: «Купить хлеб». '
            'Отметить выполненными 3 задачи?'),
      );
      final checklist = ask.checklist!;
      expect(checklist.items, hasLength(4));
      expect(checklist.checkedIds, <String>[report.id, bill.id, idea.id]);
      await assistant.handle('нет');

      final moved =
          await assistant.handle('перенеси все задачи кроме отчёта на завтра');
      expect(moved.intent, TasksConnector.rescheduleManyCommand);
      expect(moved.checklist!.targetLabel, 'вт, 3 ноября');
      expect(moved.checklist!.checkedIds, <String>[bread.id, bill.id, idea.id]);
      await assistant.handle('нет');

      final tail =
          await assistant.handle('перенеси всё на завтра, кроме хлеба');
      expect(tail.checklist!.checkedIds, <String>[report.id, bill.id, idea.id]);
      await assistant.handle('нет');

      final two = await assistant
          .handle('закрой все задачи, кроме счёта и «Купить хлеб»');
      expect(two.checklist!.checkedIds, <String>[report.id, idea.id]);
      await assistant.handle('нет');
      expect(await service.listActive(), hasLength(4));
    });

    test('«перенеси задачи на завтра» — массовый вопрос, не перенос одной',
        () async {
      await assistant.handle('Добавь задачу «Звонок»');
      final ask = await assistant.handle('перенеси задачи на завтра');
      expect(ask.intent, TasksConnector.rescheduleManyCommand);
      expect(ask.checklist!.items, hasLength(5));
      final deeds = await assistant.handle('перенеси дела на завтра');
      expect(deeds.intent, TasksConnector.rescheduleManyCommand);
      await assistant.handle('нет');
      expect(
        (await service.listActive()).where((Task t) => t.dueAt != null),
        hasLength(3),
      );
    });

    test('«всё, закрой» — о задаче в разговоре, не обо всех', () async {
      await assistant.handle('Добавь задачу «Звонок»');
      final close = await assistant.handle('всё, закрой');
      expect(close.intent, isNot(TasksConnector.completeManyCommand));
      expect(close.checklist, isNull);

      await assistant.handle('Добавь задачу «Встреча»');
      final move = await assistant.handle('всё, перенеси на пятницу');
      expect(move.intent, 'task.reschedule');
      expect(move.checklist, isNull);

      final bulk = await assistant.handle('всё, перенеси все на пятницу');
      expect(bulk.intent, TasksConnector.rescheduleManyCommand);
    });
  });
}
