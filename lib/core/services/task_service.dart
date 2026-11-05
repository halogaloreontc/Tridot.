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
    List<String> tags = const <String>[],
  }) async {
    final normalizedTitle = _validTitle(title);
    final now = _clock.now();
    final task = Task(
      id: 'task_${now.microsecondsSinceEpoch}_${_sequence++}',
      title: normalizedTitle,
      status: dueAt == null ? TaskStatus.inbox : TaskStatus.planned,
      priority: priority,
      dueAt: dueAt,
      duePrecision: duePrecision,
      tags: _normalizeTags(tags),
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

  /// Активные задачи с таким названием без учёта регистра и «ё».
  Future<List<Task>> findActiveByTitle(String title) async {
    final wanted = _titleKey(title);
    return (await listActive())
        .where((Task task) => _titleKey(task.title) == wanted)
        .toList(growable: false);
  }

  static String _titleKey(String title) => title
      .trim()
      .toLowerCase()
      .replaceAll('ё', 'е')
      .replaceAll(RegExp(r'\s+'), ' ');

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

  /// Все задачи, кроме удалённых: и активные, и завершённые.
  Future<List<Task>> listAll() async => (await _repository.list())
      .where((Task task) => task.deletedAt == null)
      .toList(growable: false);

  /// Завершённые задачи, свежие сверху.
  Future<List<Task>> listCompleted() async {
    final done = (await listAll())
        .where((Task task) => task.status == TaskStatus.done)
        .toList();
    done.sort(
      (Task a, Task b) => (b.completedAt ?? b.updatedAt)
          .compareTo(a.completedAt ?? a.updatedAt),
    );
    return done;
  }

  /// Правка из документа задачи. Пустой [project] убирает проект.
  Future<Task> updateDetails(
    String id, {
    String? title,
    String? description,
    String? project,
  }) async {
    final task = await _requireTask(id);
    var tags = task.tags;
    if (project != null) {
      final normalized = _normalizeTags(<String>[project]);
      tags = <String>[...normalized, ...task.tags.skip(1)];
      if (normalized.isEmpty) tags = task.tags.skip(1).toList();
    }
    final updated = task.copyWith(
      title: title == null ? null : _validTitle(title),
      description: description,
      tags: tags,
      updatedAt: _clock.now(),
    );
    await _repository.save(updated);
    return updated;
  }

  /// Возвращает завершённую задачу в работу.
  Future<Task> reopen(String id) async {
    final task = await _requireTask(id);
    if (task.status != TaskStatus.done) return task;
    final updated = task.copyWith(
      status: task.dueAt == null ? TaskStatus.inbox : TaskStatus.planned,
      clearCompletedAt: true,
      updatedAt: _clock.now(),
    );
    await _repository.save(updated);
    return updated;
  }

  String _validTitle(String title) {
    final normalized = title.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(
        title,
        'title',
        'Название задачи не может быть пустым',
      );
    }
    if (normalized.length > 500) {
      throw ArgumentError.value(
        title,
        'title',
        'Название задачи длиннее 500 символов',
      );
    }
    return normalized;
  }

  /// Метки без «#», в нижнем регистре, без пустых и повторов.
  static List<String> _normalizeTags(List<String> tags) {
    final result = <String>[];
    for (final raw in tags) {
      final tag = raw.trim().replaceFirst(RegExp('^#+'), '').toLowerCase();
      if (tag.isNotEmpty && !result.contains(tag)) result.add(tag);
    }
    return result;
  }

  Future<Task> _requireTask(String id) async {
    final task = await _repository.get(id);
    if (task == null || task.deletedAt != null) {
      throw StateError('Задача не найдена');
    }
    return task;
  }
}
