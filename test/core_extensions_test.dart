import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';
import 'package:local_assistant/core/storage/json_task_repository.dart';
import 'package:local_assistant/core/storage/storage_info.dart';

void main() {
  final clock = FixedClock(DateTime(2026, 11, 4, 12, 30, 5));
  late TaskService service;

  setUp(() {
    service = TaskService(repository: InMemoryTaskRepository(), clock: clock);
  });

  test('метки проектов нормализуются', () async {
    final task = await service.create(
      title: 'Отчёт',
      tags: <String>['#Работа', 'работа', ' ', 'Q4'],
    );
    expect(task.tags, <String>['работа', 'q4']);
    expect(task.project, 'работа');
  });

  test('документ меняет название, описание и проект', () async {
    final task = await service.create(title: 'Черновик', tags: ['a', 'b']);
    final updated = await service.updateDetails(
      task.id,
      title: '  Итог  ',
      description: '- [ ] пункт',
      project: '#Дом',
    );
    expect(updated.title, 'Итог');
    expect(updated.description, '- [ ] пункт');
    expect(updated.tags, <String>['дом', 'b']);

    final cleared = await service.updateDetails(task.id, project: '');
    expect(cleared.tags, <String>['b']);
    expect(
      () => service.updateDetails(task.id, title: '   '),
      throwsArgumentError,
    );
  });

  test('завершённую задачу можно вернуть в работу', () async {
    final task = await service.create(title: 'X', dueAt: DateTime(2026, 11, 5));
    await service.complete(task.id);
    expect(await service.listCompleted(), hasLength(1));

    final reopened = await service.reopen(task.id);
    expect(reopened.status, TaskStatus.planned);
    expect(reopened.completedAt, isNull);
    expect(await service.listActive(), hasLength(1));
    expect(await service.listAll(), hasLength(1));
  });

  group('файлы', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('ext_'));
    tearDown(() async => dir.delete(recursive: true));

    test('настройки сохраняются и переживают битый файл', () async {
      final store = JsonSettingsStore('${dir.path}/settings.json');
      expect((await store.load()).showTimestamps, isTrue);
      await store.save(const AppSettings(reduceMotion: true));
      expect((await store.load()).reduceMotion, isTrue);

      await File('${dir.path}/settings.json').writeAsString('{битый');
      expect((await store.load()).reduceMotion, isFalse);
    });

    test('параллельные записи задач не теряют друг друга', () async {
      final path = '${dir.path}/tasks.json';
      final svc =
          TaskService(repository: JsonTaskRepository(path), clock: clock);
      final a = await svc.create(title: 'A');
      final b = await svc.create(title: 'B');

      await Future.wait(<Future<Object?>>[
        svc.updateDetails(a.id, description: 'ВАЖНЫЕ ЗАМЕТКИ'),
        svc.complete(b.id),
      ]);

      final reloaded = await JsonTaskRepository(path).list();
      final byId = {for (final t in reloaded) t.id: t};
      expect(byId[a.id]!.description, 'ВАЖНЫЕ ЗАМЕТКИ');
      expect(byId[b.id]!.status, TaskStatus.done);
      expect(await File('$path.tmp').exists(), isFalse);
    });

    test('настройки: параллельное сохранение и неверные типы', () async {
      final store = JsonSettingsStore('${dir.path}/settings.json');
      await Future.wait(<Future<void>>[
        store.save(const AppSettings(reduceMotion: true)),
        store.save(const AppSettings(showTimestamps: false)),
      ]);
      expect((await store.load()).showTimestamps, isFalse);

      await File('${dir.path}/settings.json')
          .writeAsString('{"reduce_motion": "да", "show_timestamps": 1}');
      final loaded = await store.load();
      expect(loaded.reduceMotion, isFalse);
      expect(loaded.showTimestamps, isTrue);
    });

    test('резервная копия кладётся рядом с файлом задач', () async {
      final path = '${dir.path}/tasks.json';
      final info = JsonStorageInfo(path, clock: clock);
      expect(await info.sizeBytes(), isNull);
      expect(info.backup, throwsStateError);

      final repo = JsonTaskRepository(path);
      await TaskService(repository: repo, clock: clock).create(title: 'A');
      final copy = await info.backup();
      expect(copy, '${dir.path}/tasks.backup-20261104-123005.json');
      expect(await File(copy).readAsString(), await File(path).readAsString());
      expect(await info.sizeBytes(), greaterThan(0));
    });
  });
}
