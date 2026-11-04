import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/models/assistant_types.dart';
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
      taskService: service,
      parser: ScenarioParser(clock: fixedClock),
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
      taskService: TaskService(
        repository: _FailingTaskRepository(),
        clock: fixedClock,
      ),
      parser: ScenarioParser(clock: fixedClock),
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
}
