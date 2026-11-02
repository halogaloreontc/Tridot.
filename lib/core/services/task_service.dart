import '../models/task.dart';
import '../storage/task_repository.dart';
import 'clock.dart';

final class TaskService {
  TaskService({required TaskRepository repository, required Clock clock})
      : _repository = repository,
        _clock = clock;

  final TaskRepository _repository;
  final Clock _clock;
  int _sequence = 0;

  Future<Task> create({
    required String title,
    DateTime? dueAt,
    DuePrecision duePrecision = DuePrecision.dateTime,
    TaskPriority priority = TaskPriority.normal,
  }) async {
    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty) {
      throw ArgumentError.value(
        title,
        'title',
        'Название задачи не может быть пустым',
      );
    }
    if (normalizedTitle.length > 500) {
      throw ArgumentError.value(
        title,
        'title',
        'Название задачи длиннее 500 символов',
      );
    }

    final now = _clock.now();
    final task = Task(
      id: 'task_${now.microsecondsSinceEpoch}_${_sequence++}',
      title: normalizedTitle,
      status: dueAt == null ? TaskStatus.inbox : TaskStatus.planned,
      priority: priority,
      dueAt: dueAt,
      duePrecision: duePrecision,
      createdAt: now,
      updatedAt: now,
    );
    await _repository.save(task);
    return task;
  }

  Future<List<Task>> listActive() async {
    final tasks = (await _repository.list())
        .where((Task task) => task.isActive)
        .toList(growable: false);
    tasks.sort((Task a, Task b) {
      final aDue = a.dueAt;
      final bDue = b.dueAt;
      if (aDue == null && bDue != null) return 1;
      if (aDue != null && bDue == null) return -1;
      if (aDue != null && bDue != null) {
        final byDate = aDue.compareTo(bDue);
        if (byDate != 0) return byDate;
      }
      final byPriority = b.priority.index.compareTo(a.priority.index);
      if (byPriority != 0) return byPriority;
      final byCreated = a.createdAt.compareTo(b.createdAt);
      if (byCreated != 0) return byCreated;
      return a.id.compareTo(b.id);
    });
    return tasks;
  }

  Future<Task> complete(String id) async {
    final task = await _requireTask(id);
    if (task.status == TaskStatus.done) return task;
    final now = _clock.now();
    final updated = task.copyWith(
      status: TaskStatus.done,
      completedAt: now,
      updatedAt: now,
    );
    await _repository.save(updated);
    return updated;
  }

  Future<Task> reschedule(
    String id,
    DateTime dueAt,
    DuePrecision precision,
  ) async {
    final task = await _requireTask(id);
    final updated = task.copyWith(
      dueAt: dueAt,
      duePrecision: precision,
      status: TaskStatus.planned,
      clearCompletedAt: true,
      updatedAt: _clock.now(),
    );
    await _repository.save(updated);
    return updated;
  }

  Future<Task> _requireTask(String id) async {
    final task = await _repository.get(id);
    if (task == null || task.deletedAt != null) {
      throw StateError('Задача не найдена');
    }
    return task;
  }
}
