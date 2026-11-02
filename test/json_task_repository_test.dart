import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/storage/json_task_repository.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('assistant_test_');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('сохраняет задачу и восстанавливает её после перезапуска репозитория',
      () async {
    final path = '${directory.path}/tasks.json';
    final repository = JsonTaskRepository(path);
    final task = Task(
      id: 'task_1',
      title: 'Проверка',
      status: TaskStatus.planned,
      priority: TaskPriority.high,
      dueAt: DateTime(2026, 11, 3, 11),
      createdAt: DateTime(2026, 11, 2),
      updatedAt: DateTime(2026, 11, 2),
    );

    await repository.save(task);
    final restored = JsonTaskRepository(path);

    expect((await restored.get('task_1'))?.title, 'Проверка');
    expect((await restored.get('task_1'))?.priority, TaskPriority.high);
    expect(await File('$path.tmp').exists(), isFalse);
  });
}
