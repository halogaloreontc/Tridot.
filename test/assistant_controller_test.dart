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

    test('слово из двух букв в названии не совпадает с длинным', () async {
      await assistant.handle('Добавь задачу налог ИП');

      final response = await assistant.handle('Перенеси ипотеку на завтра');

      expect(response.status, AssistantStatus.needsClarification);
      expect(response.message, 'Не нашёл активную задачу «Ипотеку».');
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
}
