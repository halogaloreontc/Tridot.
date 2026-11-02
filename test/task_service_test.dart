import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

void main() {
  test('отклоняет пустое название', () async {
    final service = TaskService(
      repository: InMemoryTaskRepository(),
      clock: FixedClock(DateTime(2026, 11, 2)),
    );

    expect(() => service.create(title: '   '), throwsArgumentError);
  });

  test('повторное завершение идемпотентно', () async {
    final clock = FixedClock(DateTime(2026, 11, 2, 12));
    final service =
        TaskService(repository: InMemoryTaskRepository(), clock: clock);
    final task = await service.create(title: 'Задача');

    final first = await service.complete(task.id);
    final second = await service.complete(task.id);

    expect(second.completedAt, first.completedAt);
    expect(second.updatedAt, first.updatedAt);
  });

  test('перенос завершённой задачи очищает отметку завершения', () async {
    final service = TaskService(
      repository: InMemoryTaskRepository(),
      clock: FixedClock(DateTime(2026, 11, 2, 12)),
    );
    final task = await service.create(title: 'Задача');
    await service.complete(task.id);

    final moved = await service.reschedule(
      task.id,
      DateTime(2026, 11, 3, 10),
      DuePrecision.dateTime,
    );

    expect(moved.status, TaskStatus.planned);
    expect(moved.completedAt, isNull);
  });
}
