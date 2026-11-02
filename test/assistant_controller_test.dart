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
}
