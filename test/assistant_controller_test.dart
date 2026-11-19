import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';
import 'package:local_assistant/core/storage/task_repository.dart';

final class _FailingTaskRepository implements TaskRepository {
  @override
  Future<List<Task>> list() async => <Task>[];

  @override
  Future<Task?> get(String id) async => null;

  @override
  Future<void> save(Task task) async {
    throw StateError('Хранилище недоступно');
  }
}

void main() {
  late InMemoryTaskRepository repository;
  late TaskService service;
  late AssistantController assistant;

  setUp(() {
    repository = InMemoryTaskRepository();
    final fixedClock = FixedClock(DateTime(2026, 11, 2, 16, 30));
    service = TaskService(repository: repository, clock: fixedClock);
    assistant = AssistantController(
      connectors: <Connector>[
        TasksConnector(
          taskService: service,
          parser: ScenarioParser(clock: fixedClock),
        ),
      ],
      clock: fixedClock,
    );
  });

  test('проходит сквозной сценарий: создать, перенести, завершить', () async {
    final created =
        await assistant.handle('Добавь задачу «Отчёт» на завтра в 10:00');
    expect(created.status, AssistantStatus.completed);
    expect(created.task?.status, TaskStatus.planned);

    final moved = await assistant.handle('Перенеси её на сегодня в 18:00');
    expect(moved.status, AssistantStatus.completed);
    expect(moved.task?.dueAt, DateTime(2026, 11, 2, 18));

    final done = await assistant.handle('Заверши её');
    expect(done.status, AssistantStatus.completed);
    expect(done.task?.status, TaskStatus.done);
    expect(done.task?.completedAt, DateTime(2026, 11, 2, 16, 30));
    expect(await service.listActive(), isEmpty);
  });

  group('метка проекта-папки (ADR-018)', () {
    test('задача в сессии проекта без своей метки получает метку проекта',
        () async {
      assistant.enterChat(sessionId: 'session:1', projectTag: 'дом');
      final created = await assistant.handle('Добавь задачу «Плитка»');
      expect(created.status, AssistantStatus.completed);
      expect(created.task?.tags, <String>['дом']);
    });

    test('своя метка в команде важнее метки проекта', () async {
      assistant.enterChat(sessionId: 'session:1', projectTag: 'дом');
      final created = await assistant.handle('Добавь задачу «Отчёт» #работа');
      expect(created.task?.tags, <String>['работа']);
    });

    test('вне проекта и после смены чата метки нет', () async {
      assistant.enterChat(sessionId: 'session:1', projectTag: 'дом');
      assistant.enterChat(sessionId: 'session:2');
      final created = await assistant.handle('Добавь задачу «Хлеб»');
      expect(created.task?.tags, isEmpty);
    });

    test('setProjectTag: сессию перенесли в проект', () async {
      assistant
        ..enterChat(sessionId: 'session:1')
        ..setProjectTag('дача');
      final created = await assistant.handle('Добавь задачу «Забор»');
      expect(created.task?.tags, <String>['дача']);
      assistant.setProjectTag(null);
      final plain = await assistant.handle('Добавь задачу «Ворота»');
      expect(plain.task?.tags, isEmpty);
    });
  });

  group('разговорная обёртка (CommandFrame)', () {
    test('«будь добр, …» — задача без обёртки в названии', () async {
      final created = await assistant
          .handle('будь добр, запиши встречу с клиентом завтра в 15:00');
      expect(created.status, AssistantStatus.completed);
      expect(created.task?.title, 'Встреча с клиентом');
      expect(created.task?.dueAt, DateTime(2026, 11, 3, 15));
    });

    test('ответ на вопрос разбирается по исходной фразе', () async {
      await assistant.handle('Добавь задачу «Купить хлеб»');
      final asked = await assistant.handle('я купил хлеб');
      expect(asked.status, AssistantStatus.needsClarification);
      // «нет, …» — ответ «нет», а не команда без обёртки.
      final answer = await assistant.handle('нет, не купил');
      expect(answer.status, isNot(AssistantStatus.completed));
      expect(
        (await service.listActive()).single.title,
        'Купить хлеб',
        reason: 'задача не закрыта',
      );
    });
  });

  group('не та раскладка (LayoutFix)', () {
    test('чтение — сразу, с пояснением', () async {
      await assistant.handle('Добавь задачу «Отчёт»');
      final list = await assistant.handle('gjrf;b pflfxb');
      expect(list.intent, 'task.list');
      expect(list.message, startsWith('Набрано в английской раскладке'));
      expect(list.message, contains('«покажи задачи»'));
    });

    test('запись — только после «да»', () async {
      final asked =
          await assistant.handle('yfgjvyb pfdnhf d 10 gjpdjybnm vfvt');
      expect(asked.status, AssistantStatus.needsClarification);
      expect(asked.replyId, 'router.repaired.confirm');
      expect(
        asked.message,
        contains('«напомни завтра в 10 позвонить маме»'),
      );
      expect(
        asked.clarification?.options.map((o) => o.label),
        <String>['Да', 'Нет'],
      );
      expect(await repository.list(), isEmpty);
      final created = await assistant.handle('да');
      expect(created.status, AssistantStatus.completed);
      expect(created.task?.title, 'Позвонить маме');
      expect(created.task?.dueAt, DateTime(2026, 11, 3, 10));
    });

    test('«нет» и «ytn» — отмена; «lf» — «да»', () async {
      await assistant.handle('yfgjvyb pfdnhf d 10 gjpdjybnm vfvt');
      final cancelled = await assistant.handle('нет');
      expect(cancelled.status, AssistantStatus.noAction);
      expect(await repository.list(), isEmpty);

      await assistant.handle('yfgjvyb pfdnhf d 10 gjpdjybnm vfvt');
      final layoutNo = await assistant.handle('ytn');
      expect(layoutNo.status, AssistantStatus.noAction);
      expect(await repository.list(), isEmpty);

      await assistant.handle('yfgjvyb pfdnhf d 10 gjpdjybnm vfvt');
      final layoutYes = await assistant.handle('lf');
      expect(layoutYes.task?.title, 'Позвонить маме');
    });

    test('английская фраза — не понята, без исправления', () async {
      final response = await assistant.handle('buy milk tomorrow');
      expect(response.intent, 'unknown');
      expect(response.message, isNot(contains('раскладке')));
    });
  });

  group('опечатки (TypoFix)', () {
    test('чтение — сразу, с пояснением', () async {
      await assistant.handle('Добавь задачу «Отчёт»');
      final list = await assistant.handle('пакажи заадчи');
      expect(list.intent, 'task.list');
      expect(list.message, startsWith('Похоже на опечатку'));
      expect(list.message, contains('«покажи задачи»'));
    });

    test('опечатка в сроке при понятой команде — срок на месте', () async {
      final created =
          await assistant.handle('напоми заввтра в 10 позвонить маме');
      expect(created.status, AssistantStatus.completed);
      expect(created.task?.title, 'Позвонить маме');
      expect(created.task?.dueAt, DateTime(2026, 11, 3, 10));
    });

    test('запись по исправленной фразе — только после «да»', () async {
      await service.create(title: 'Отчёт');
      final asked = await assistant.handle('заакрой все просроченне');
      expect(asked.replyId, 'router.typo.confirm');
      expect((await service.listActive()), hasLength(1));
      await assistant.handle('нет');
      expect((await service.listActive()), hasLength(1));
    });
  });

  group('дело от первого лица (ADR-033)', () {
    test('без команды — только с вопросом «Создать?»', () async {
      final asked = await assistant.handle('завтра я позвоню маме');
      expect(asked.status, AssistantStatus.needsClarification);
      expect(asked.message, contains('Позвонить маме'));
      expect(await repository.list(), isEmpty);
      final created = await assistant.handle('Создать');
      expect(created.status, AssistantStatus.completed);
      expect(created.task?.title, 'Позвонить маме');
      expect(created.task?.dueAt, DateTime(2026, 11, 3));
    });

    test('с командой — сразу задача с инфинитивом', () async {
      final created =
          await assistant.handle('напомни завтра, что я позвоню маме');
      expect(created.status, AssistantStatus.completed);
      expect(created.task?.title, 'Позвонить маме');
    });

    test('в чате задачи «я сделаю это завтра» — не новая задача', () async {
      final task = (await assistant.handle('Добавь задачу «Отчёт»')).task!;
      assistant.enterChat(taskId: task.id);
      await assistant.handle('я сделаю это завтра');
      expect(await repository.list(), hasLength(1));
    });
  });

  test('запрашивает контекст вместо угадывания задачи', () async {
    final response = await assistant.handle('Заверши её');

    expect(response.status, AssistantStatus.needsClarification);
    expect(await repository.list(), isEmpty);
  });

  test('сообщает о поддерживаемых возможностях при неизвестной команде',
      () async {
    final response = await assistant.handle('Расскажи что-нибудь');

    expect(response.status, AssistantStatus.noAction);
    expect(response.intent, 'unknown');
  });

  test('возвращает ошибку вместо необработанного исключения хранилища',
      () async {
    final fixedClock = FixedClock(DateTime(2026, 11, 2, 16, 30));
    final failingAssistant = AssistantController(
      connectors: <Connector>[
        TasksConnector(
          taskService: TaskService(
            repository: _FailingTaskRepository(),
            clock: fixedClock,
          ),
          parser: ScenarioParser(clock: fixedClock),
        ),
      ],
      clock: fixedClock,
    );

    final response = await failingAssistant.handle('Добавь задачу «Отчёт»');

    expect(response.status, AssistantStatus.failed);
    expect(response.message, contains('Хранилище недоступно'));
  });

  test('пример из подсказки интерфейса создаёт задачу', () async {
    final response = await assistant.handle(AssistantController.exampleCommand);

    expect(response.status, AssistantStatus.completed);
    expect(response.task?.title, 'Позвонить клиенту');
    expect(response.task?.dueAt, DateTime(2026, 11, 3, 11));
  });

  test('слово «завершить» в названии не завершает предыдущую задачу', () async {
    final first = await assistant.handle('Добавь задачу «Позвонить клиенту»');
    final second = await assistant.handle('Добавь задачу «Завершить отчёт»');

    expect(second.intent, 'task.create');
    expect(second.task?.title, 'Завершить отчёт');
    final active = await service.listActive();
    expect(
      active.map((Task t) => t.id),
      containsAll(<String>[first.task!.id, second.task!.id]),
    );
  });

  test('прошедшее время «сегодня» требует уточнения и ничего не создаёт',
      () async {
    final response =
        await assistant.handle('Добавь задачу «Звонок» сегодня в 9:00');

    expect(response.status, AssistantStatus.needsClarification);
    expect(await repository.list(), isEmpty);
  });

  group('сдвиг одной задачи «на час позже»', () {
    test('сдвигает от срока самой задачи', () async {
      await assistant.handle('Добавь задачу «Звонок маме» на завтра в 10:00');

      final moved =
          await assistant.handle('перенеси звонок маме на час попозже');

      expect(moved.status, AssistantStatus.completed);
      expect(moved.task?.dueAt, DateTime(2026, 11, 3, 11));
      expect(moved.task?.duePrecision, DuePrecision.dateTime);
    });

    test('«на полчаса раньше» выбранной задачи', () async {
      await assistant.handle('Добавь задачу «Визит» на завтра в 10:00');

      final moved = await assistant.handle('сдвинь её на полчаса раньше');

      expect(moved.task?.dueAt, DateTime(2026, 11, 3, 9, 30));
    });

    test('у задачи без срока — вопрос, на когда', () async {
      await assistant.handle('Добавь задачу «Звонок маме»');

      final moved = await assistant.handle('перенеси на час позже');

      expect(moved.status, AssistantStatus.needsClarification);
      expect((await repository.list()).single.dueAt, isNull);
    });

    test('часы у задачи на день — вопрос, дни — сдвиг', () async {
      await assistant.handle('Добавь задачу «Отчёт» на пятницу');

      final hours = await assistant.handle('перенеси на 2 часа позже');
      expect(hours.status, AssistantStatus.needsClarification);

      final days = await assistant.handle('перенеси отчёт на 2 дня позже');
      expect(days.status, AssistantStatus.completed);
      expect(days.task?.dueAt, DateTime(2026, 11, 8));
      expect(days.task?.duePrecision, DuePrecision.date);
    });

    test('сдвиг в прошлое — не молча', () async {
      await assistant.handle('Добавь задачу «Отчёт» на завтра в 10:00');

      final moved = await assistant.handle('перенеси отчёт на 2 дня раньше');

      expect(moved.status, AssistantStatus.needsClarification);
      expect(
        (await repository.list()).single.dueAt,
        DateTime(2026, 11, 3, 10),
      );
    });
  });

  test('«на завтра на то же время» берёт время задачи', () async {
    await assistant.handle('Добавь задачу «Звонок юристу» на сегодня в 18:00');

    final moved = await assistant
        .handle('перенеси звонок юристу на завтра на то же время');

    expect(moved.status, AssistantStatus.completed);
    expect(moved.task?.dueAt, DateTime(2026, 11, 3, 18));
  });

  test('после завершения «её» больше не указывает на задачу', () async {
    await assistant.handle('Добавь задачу «Отчёт» на завтра');
    await assistant.handle('Заверши её');

    final moved = await assistant.handle('Перенеси её на завтра в 12:00');

    expect(moved.status, AssistantStatus.needsClarification);
    final tasks = await repository.list();
    expect(tasks.single.status, TaskStatus.done);
  });

  test('перенос по названию меняет названную задачу, а не выбранную', () async {
    final report = await assistant.handle('Добавь задачу «Отчёт»');
    final bread = await assistant.handle('Добавь задачу «Купить хлеб»');

    final moved = await assistant.handle('Перенеси задачу «отчёт» на завтра');

    expect(moved.status, AssistantStatus.completed);
    expect(moved.task?.id, report.task!.id);
    expect((await repository.get(bread.task!.id))?.dueAt, isNull);
  });

  test('завершение несуществующей задачи по названию требует уточнения',
      () async {
    final bread = await assistant.handle('Добавь задачу «Купить хлеб»');

    final response = await assistant.handle('Заверши задачу «Отчёт»');

    expect(response.status, AssistantStatus.needsClarification);
    expect((await repository.get(bread.task!.id))?.isActive, isTrue);
  });

  test('отрицание не завершает задачу из контекста', () async {
    final bread = await assistant.handle('Добавь задачу «Купить хлеб»');

    final response = await assistant.handle('Нет, не выполнено');

    expect(response.status, AssistantStatus.noAction);
    expect((await repository.get(bread.task!.id))?.isActive, isTrue);
  });

  test('несколько задач с одним названием требуют выбора', () async {
    await assistant.handle('Добавь задачу «Звонок»');
    await assistant.handle('Добавь задачу «Звонок»');

    final response = await assistant.handle('Заверши задачу «Звонок»');

    expect(response.status, AssistantStatus.needsClarification);
    expect(await service.listActive(), hasLength(2));
  });

  test('завершение другой задачи по названию сохраняет выбранную', () async {
    await assistant.handle('Добавь задачу «B»');
    final a = await assistant.handle('Добавь задачу «A»');

    await assistant.handle('Заверши задачу «B»');

    expect(assistant.selectedTaskId, a.task!.id);
  });

  group('названия без кавычек', () {
    test('создаёт задачу из обычной фразы', () async {
      final response = await assistant.handle(
        'Добавь задачу позвонить клиенту завтра в 10',
      );

      expect(response.status, AssistantStatus.completed);
      expect(response.task?.title, 'Позвонить клиенту');
      expect(response.task?.dueAt, DateTime(2026, 11, 3, 10));
    });

    test('без названия спрашивает его и не требует кавычек', () async {
      final response = await assistant.handle('добавь задачу');

      expect(response.status, AssistantStatus.needsClarification);
      expect(response.message, contains('Как называется задача?'));
      expect(response.message, isNot(contains('укажите название в кавычках')));
      expect(await repository.list(), isEmpty);
    });

    test('неизвестная команда не называет кавычки обязательными', () async {
      final response = await assistant.handle('Расскажи что-нибудь');

      expect(response.message, isNot(contains('в кавычках')));
    });
  });

  group('часть суток', () {
    test('срок «завтра вечером» показывается словами', () async {
      final response =
          await assistant.handle('Добавь купить хлеб завтра вечером');

      expect(response.status, AssistantStatus.completed);
      expect(response.task?.title, 'Купить хлеб');
      expect(response.task?.dueAt, DateTime(2026, 11, 3, 19));
      expect(response.task?.duePrecision, DuePrecision.partOfDay);
      expect(
        response.message,
        'Создал задачу «Купить хлеб» на завтра вечером.',
      );
    });

    test('перенос на часть суток', () async {
      await assistant.handle('Добавь задачу сдать отчёт');
      final moved = await assistant.handle('Перенеси отчёт на пятницу утром');

      expect(moved.task?.dueAt, DateTime(2026, 11, 6, 9));
      expect(moved.task?.duePrecision, DuePrecision.partOfDay);
      expect(moved.message, contains('6 ноября утром'));
    });
  });

  group('поиск целевой задачи', () {
    test('переносит задачу по словам без кавычек', () async {
      final report = await assistant.handle('Добавь задачу сдать отчёт');
      await assistant.handle('Добавь задачу купить хлеб');

      final moved = await assistant.handle('Перенеси отчёт на завтра');

      expect(moved.status, AssistantStatus.completed);
      expect(moved.task?.id, report.task!.id);
      expect(moved.task?.dueAt, DateTime(2026, 11, 3));
    });

    test('завершает задачу по другой форме слова', () async {
      final bread = await assistant.handle('Добавь задачу купить хлеба');
      await assistant.handle('Добавь задачу сдать отчёт');

      final done = await assistant.handle('Заверши купить хлеб');

      expect(done.status, AssistantStatus.completed);
      expect(done.task?.id, bread.task!.id);
    });

    test('точное совпадение важнее нечёткого', () async {
      await assistant.handle('Добавь задачу отчёт по продажам');
      final exact = await assistant.handle('Добавь задачу отчёт');

      final done = await assistant.handle('Заверши отчёт');

      expect(done.status, AssistantStatus.completed);
      expect(done.task?.id, exact.task!.id);
    });

    test('несколько похожих задач — уточнение со списком', () async {
      await assistant.handle('Добавь задачу отчёт по продажам');
      await assistant.handle('Добавь задачу отчёт по закупкам');
      await assistant.handle('Добавь задачу купить хлеб');

      final response = await assistant.handle('Заверши отчёт');

      expect(response.status, AssistantStatus.needsClarification);
      expect(response.message, contains('«Отчёт по продажам»'));
      expect(response.message, contains('«Отчёт по закупкам»'));
      expect(response.message, isNot(contains('Купить хлеб')));
      expect(await service.listActive(), hasLength(3));
    });

    test('ненайденный запрос не подменяется выбранной задачей', () async {
      final bread = await assistant.handle('Добавь задачу купить хлеб');
      expect(assistant.selectedTaskId, bread.task!.id);

      final response = await assistant.handle('Заверши отчёт');

      expect(response.status, AssistantStatus.needsClarification);
      expect(response.message, 'Не нашёл активную задачу «Отчёт».');
      expect((await repository.get(bread.task!.id))?.isActive, isTrue);
    });

    test('«её» по-прежнему означает выбранную задачу', () async {
      final bread = await assistant.handle('Добавь задачу купить хлеб');

      final done = await assistant.handle('Отметь её как выполненную');

      expect(done.status, AssistantStatus.completed);
      expect(done.task?.id, bread.task!.id);
    });

    test('короткие служебные слова не дают совпадения', () async {
      await assistant.handle('Добавь задачу сходить в магазин');

      final response = await assistant.handle('Заверши в');

      expect(response.status, AssistantStatus.needsClarification);
      expect(await service.listActive(), hasLength(1));
    });

    for (final phrase in <String>[
      'Перенеси выбранную задачу на завтра',
      'перенеси последнюю задачу на завтра',
      'Перенеси эту же задачу на завтра',
      'Перенеси текущую на завтра',
    ]) {
      test('«$phrase» относится к выбранной задаче', () async {
        await assistant.handle('Добавь задачу выбрать подарок');
        final report = await assistant.handle('Добавь задачу отчёт');

        final moved = await assistant.handle(phrase);

        expect(moved.status, AssistantStatus.completed, reason: moved.message);
        expect(moved.task?.id, report.task!.id);
        expect(moved.task?.dueAt, DateTime(2026, 11, 3));
      });
    }

    test('«Заверши текущую задачу» завершает выбранную', () async {
      final report = await assistant.handle('Добавь задачу отчёт');

      final done = await assistant.handle('Заверши текущую задачу');

      expect(done.status, AssistantStatus.completed);
      expect(done.task?.id, report.task!.id);
    });

    test('задача со старым названием в винительном находится', () async {
      // Название сохранено до приведения к именительному: «Встречу …».
      final old = await service.create(title: 'Встречу с клиентом');
      final short = await service.create(title: 'Маму поздравить');

      final moved = await assistant.handle('Перенеси встречу на завтра');
      expect(moved.status, AssistantStatus.completed);
      expect(moved.task?.id, old.id);

      final again = await assistant.handle('Перенеси маму на пятницу');
      expect(again.status, AssistantStatus.completed);
      expect(again.task?.id, short.id);
    });

    test('новое название в именительном находится по старой форме', () async {
      final created = await assistant.handle('Напомни про встречу с клиентом');
      expect(created.task?.title, 'Встреча с клиентом');

      final done = await assistant.handle('Заверши встречу с клиентом');
      expect(done.status, AssistantStatus.completed);
      expect(done.task?.id, created.task!.id);
    });

    test('слово из двух букв в названии не совпадает с длинным', () async {
      await assistant.handle('Добавь задачу налог ИП');

      final response = await assistant.handle('Перенеси ипотеку на завтра');

      expect(response.status, AssistantStatus.needsClarification);
      expect(response.message, 'Не нашёл активную задачу «Ипотека».');
      expect((await service.listActive()).single.dueAt, isNull);
    });

    test('числа совпадают только целиком', () async {
      await assistant.handle('Добавь задачу отчёт 2');
      final year = await assistant.handle('Добавь задачу отчёт 2027');

      final done = await assistant.handle('Заверши отчёт 2027');

      expect(done.status, AssistantStatus.completed);
      expect(done.task?.id, year.task!.id);
    });

    test('совпадение половины слов — вопрос, а не изменение', () async {
      await assistant.handle('Добавь задачу позвонить клиенту');

      final response = await assistant.handle('Заверши позвонить маме');

      expect(response.status, AssistantStatus.needsClarification);
      expect(response.message, contains('«Позвонить клиенту»'));
      expect(await service.listActive(), hasLength(1));
    });

    test('«выполненным» завершает задачу по словам', () async {
      final call = await assistant.handle('Добавь задачу звонок маме');
      await assistant.handle('Добавь задачу отчёт');

      final done = await assistant.handle('отметь звонок маме выполненным');

      expect(done.status, AssistantStatus.completed);
      expect(done.task?.id, call.task!.id);
    });
  });

  group('сроки в обычной речи', () {
    test('«в 2 часа дня» — 14:00 и без «дня» в названии', () async {
      final response = await assistant.handle('добавь собрание в 2 часа дня');

      expect(response.task?.title, 'Собрание');
      expect(response.task?.dueAt, DateTime(2026, 11, 3, 14));
    });

    test('час без уточнения 1–6 переспрашивается', () async {
      final response = await assistant.handle('добавь задачу приехать к 5');

      expect(response.status, AssistantStatus.needsClarification);
      expect(response.message, contains('Утра или вечера?'));
      expect(await repository.list(), isEmpty);
    });

    test('«Нет, добавь…» — поправка, а не отрицание', () async {
      final response = await assistant.handle('нет, добавь задачу купить хлеб');

      expect(response.status, AssistantStatus.completed);
      expect(response.task?.title, 'Купить хлеб');
    });
  });

  group('команды без маркера', () {
    test('инфинитив в начале создаёт задачу', () async {
      final response = await assistant.handle('надо купить хлеб');

      expect(response.status, AssistantStatus.completed);
      expect(response.message, 'Создал задачу «Купить хлеб».');
      expect(response.task?.title, 'Купить хлеб');
    });

    test('инфинитив после срока создаёт задачу со сроком', () async {
      final response = await assistant.handle('через 3 дня сдать отчёт');

      expect(response.task?.title, 'Сдать отчёт');
      expect(response.task?.dueAt, DateTime(2026, 11, 5));
    });

    test('вопрос и существительное в начале — не задача', () async {
      for (final phrase in <String>['купить хлеб?', 'тетрадь купить']) {
        final response = await assistant.handle(phrase);
        expect(response.intent, 'unknown', reason: phrase);
      }
      expect(await repository.list(), isEmpty);
    });

    test('уверенность ниже явной команды', () {
      final connector = TasksConnector(
        taskService: service,
        parser: ScenarioParser(clock: FixedClock(DateTime(2026, 11, 2, 16))),
      );
      double confidence(String text) => connector
          .match(Utterance.analyze(text, now: DateTime(2026, 11, 2, 16)))!
          .confidence;

      expect(confidence('купить хлеб'), 0.6);
      expect(confidence('завтра купить хлеб'), 0.75);
      expect(confidence('добавь купить хлеб'), 0.9);
      expect(confidence('я купил хлеб'), 0.6);
    });
  });

  group('завершение по сообщению о сделанном', () {
    late Task bread;
    late Task report;

    setUp(() async {
      bread = (await assistant.handle('Добавь задачу купить хлеб')).task!;
      report = (await assistant.handle('Добавь задачу сдать отчёт')).task!;
    });

    Future<bool> isActive(Task task) async =>
        (await repository.get(task.id))!.isActive;

    test('спрашивает и ничего не меняет', () async {
      final response = await assistant.handle('я купил хлеб');

      expect(response.status, AssistantStatus.needsClarification);
      expect(response.intent, 'task.complete');
      expect(response.message, 'Отметить «Купить хлеб» выполненной?');
      expect(await isActive(bread), isTrue);
      expect(assistant.session.pendingConfirmation?.itemId, bread.id);
    });

    for (final yes in <String>[
      'да',
      'Да!',
      'ага',
      'угу',
      'конечно',
      'отмечай',
      'да, отмечай',
      '+',
    ]) {
      test('«$yes» завершает задачу', () async {
        await assistant.handle('я купил хлеб');

        final response = await assistant.handle(yes);

        expect(response.status, AssistantStatus.completed);
        expect(response.message, 'Задача «Купить хлеб» завершена.');
        expect(response.task?.id, bread.id);
        expect(await isActive(bread), isFalse);
        expect(await isActive(report), isTrue);
        expect(assistant.session.pendingConfirmation, isNull);
      });
    }

    const refusals = <String>['нет', 'не надо', 'отмена', '-', 'Нет, спасибо'];
    for (final no in refusals) {
      test('«$no» оставляет задачу', () async {
        await assistant.handle('я купил хлеб');

        final response = await assistant.handle(no);

        expect(response.message, 'Хорошо, не отмечаю.');
        expect(response.status, AssistantStatus.noAction);
        expect(await isActive(bread), isTrue);
      });
    }

    test('другое сообщение снимает вопрос и разбирается как обычно', () async {
      await assistant.handle('я купил хлеб');

      final created = await assistant.handle('Добавь задачу позвонить маме');
      final stale = await assistant.handle('да');

      expect(created.status, AssistantStatus.completed);
      expect(created.task?.title, 'Позвонить маме');
      expect(stale.intent, 'unknown');
      expect(await isActive(bread), isTrue);
    });

    test('вопрос живёт одно сообщение', () async {
      await assistant.handle('я купил хлеб');
      await assistant.handle('покажи задачи');

      final response = await assistant.handle('да');

      expect(response.intent, 'unknown');
      expect(await isActive(bread), isTrue);
    });

    test('«да» без вопроса — не команда', () async {
      final response = await assistant.handle('да');

      expect(response.intent, 'unknown');
      expect(await isActive(bread), isTrue);
      expect(await isActive(report), isTrue);
    });

    test('вопрос и отказ не меняют выбранную задачу', () async {
      expect(assistant.selectedTaskId, report.id);

      await assistant.handle('я купил хлеб');
      expect(assistant.selectedTaskId, report.id);
      await assistant.handle('нет');
      expect(assistant.selectedTaskId, report.id);
      await assistant.handle('я купил хлеб');
      await assistant.handle('да');
      expect(assistant.selectedTaskId, report.id);
    });

    test('глагол сравнивается по основе', () async {
      final response = await assistant.handle('отчёт сдал');

      expect(response.message, 'Отметить «Сдать отчёт» выполненной?');
      expect((await assistant.handle('угу')).task?.id, report.id);
    });

    test('общий глагол без общего предмета не совпадает', () async {
      final response = await assistant.handle('купила молоко');

      expect(response.intent, 'unknown');
      expect(response.status, AssistantStatus.noAction);
      expect(assistant.session.pendingConfirmation, isNull);
    });

    test('без подходящей задачи — обычный ответ «не понял»', () async {
      final response = await assistant.handle('я позвонил маме');

      expect(response.intent, 'unknown');
      expect(response.message, TasksConnector.unknownResponse.message);
      expect(assistant.session.pendingConfirmation, isNull);
    });

    test('несколько подходящих задач — список без ожидания', () async {
      final bread2 =
          (await assistant.handle('Добавь задачу купить хлеб бабушке')).task!;

      final response = await assistant.handle('я купил хлеб');

      expect(response.status, AssistantStatus.needsClarification);
      expect(response.message, contains('«Купить хлеб»'));
      expect(response.message, contains('«Купить хлеб бабушке»'));
      expect(response.message, isNot(contains('Сдать отчёт')));
      expect(assistant.session.pendingConfirmation, isNull);

      final answer = await assistant.handle('да');
      expect(answer.intent, 'unknown');
      expect(await isActive(bread), isTrue);
      expect(await isActive(bread2), isTrue);
    });

    test('явный глагол в прошедшем времени тоже спрашивает', () async {
      final slides =
          (await assistant.handle('Добавь задачу сделать презентацию')).task!;

      final response = await assistant.handle('сделал презентацию');

      expect(response.message, 'Отметить «Сделать презентацию» выполненной?');
      expect((await assistant.handle('да')).task?.id, slides.id);
    });

    test('глагол сделанного и название в кавычках — тоже вопрос', () async {
      final book =
          (await assistant.handle('Добавь задачу «Книгу в библиотеку»')).task!;

      final response = await assistant.handle('Вернул «Книгу в библиотеку»');

      expect(response.status, AssistantStatus.needsClarification);
      expect(response.message, 'Отметить «Книгу в библиотеку» выполненной?');
      expect(await isActive(book), isTrue);
      expect((await assistant.handle('да')).task?.id, book.id);
      expect(await isActive(book), isFalse);
    });

    for (final text in <String>[
      'я забыл «Сдать отчёт»',
      'я потерял «Сдать отчёт»',
      'я любил «Сдать отчёт»',
      'я смотрел «Сдать отчёт»',
      'я забыл сдать отчёт',
      'поел и поспал',
      'я сдал и ушёл',
    ]) {
      test('«$text» — не сообщение о сделанном', () async {
        final response = await assistant.handle(text);

        expect(response.intent, 'unknown');
        expect(await isActive(report), isTrue);
        expect(assistant.session.pendingConfirmation, isNull);
      });
    }

    test('задачу завершили до ответа — ничего не делает', () async {
      await assistant.handle('я купил хлеб');
      await service.complete(bread.id);

      final response = await assistant.handle('да');

      expect(response.status, AssistantStatus.noAction);
      expect(response.message, 'Эта задача уже не активна.');
    });

    for (final yes in <String>['да, купил хлеб', 'да спасибо', '👍', 'Ок']) {
      test('«$yes» — согласие с пояснением или знаком', () async {
        await assistant.handle('я купил хлеб');

        final response = await assistant.handle(yes);

        expect(response.status, AssistantStatus.completed);
        expect(response.task?.id, bread.id);
        expect(await isActive(bread), isFalse);
      });
    }

    for (final no in <String>['нет, не купил', 'неа', '👎']) {
      test('«$no» — отказ с пояснением или знаком', () async {
        await assistant.handle('я купил хлеб');

        final response = await assistant.handle(no);

        expect(response.message, 'Хорошо, не отмечаю.');
        expect(await isActive(bread), isTrue);
      });
    }

    test('«нет, добавь …» — новая команда, а не отказ', () async {
      await assistant.handle('я купил хлеб');

      final response = await assistant.handle('нет, добавь задачу молоко');

      expect(response.status, AssistantStatus.completed);
      expect(response.task?.title, 'Молоко');
      expect(await isActive(bread), isTrue);
      expect(assistant.session.pendingConfirmation, isNull);
    });

    test('«кстати» после вопроса не создаёт задачу', () async {
      await assistant.handle('отчёт сдал');

      final response = await assistant.handle('кстати');

      expect(response.intent, 'unknown');
      expect(await repository.list(), hasLength(2));
      expect(assistant.session.pendingConfirmation, isNull);
    });

    test('существительное на «-ть» в запросе — предмет, а не глагол', () async {
      await assistant.handle('Добавь задачу посмотреть фильм');
      await assistant.handle('Добавь задачу оплатить интернет');

      for (final phrase in <String>[
        'купил кровать',
        'посмотрел новость',
        'оплатил часть',
      ]) {
        final response = await assistant.handle(phrase);
        expect(response.intent, 'unknown', reason: phrase);
        expect(assistant.session.pendingConfirmation, isNull, reason: phrase);
      }
    });

    test('другой глагол с тем же предметом не совпадает', () async {
      final response = await assistant.handle('съел хлеб');

      expect(response.intent, 'unknown');
      expect(assistant.session.pendingConfirmation, isNull);
    });

    test('глагол без предмета и рассказ о других — не вопрос', () async {
      for (final phrase in <String>[
        'я купил',
        'сдал',
        'вчера сдал',
        'хлеб купили',
        'мама купила хлеб',
      ]) {
        final response = await assistant.handle(phrase);
        expect(response.intent, 'unknown', reason: phrase);
        expect(assistant.session.pendingConfirmation, isNull, reason: phrase);
      }
      expect(await isActive(bread), isTrue);
    });

    test('ответ названием на «Какую задачу…?» не создаёт дубль', () async {
      final bread2 =
          (await assistant.handle('Добавь задачу купить хлеб бабушке')).task!;
      final question = await assistant.handle('я купил хлеб');
      expect(question.message, contains('Напишите «Заверши»'));

      final answer = await assistant.handle('купить хлеб');

      expect(answer.status, AssistantStatus.noAction);
      expect(
        answer.message,
        'Задача «Купить хлеб» уже есть. Чтобы отметить её выполненной, '
        'напишите «Заверши её».',
      );
      expect(await repository.list(), hasLength(3));
      expect(assistant.selectedTaskId, bread.id);

      final done = await assistant.handle('Заверши её');
      expect(done.task?.id, bread.id);
      expect(await isActive(bread), isFalse);
      expect(await isActive(bread2), isTrue);
    });
  });
}
