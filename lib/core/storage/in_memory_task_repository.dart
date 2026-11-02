import '../models/task.dart';
import 'task_repository.dart';

final class InMemoryTaskRepository implements TaskRepository {
  final Map<String, Task> _tasks = <String, Task>{};

  @override
  Future<Task?> get(String id) async => _tasks[id];

  @override
  Future<List<Task>> list() async => List<Task>.unmodifiable(_tasks.values);

  @override
  Future<void> save(Task task) async {
    _tasks[task.id] = task;
  }
}
