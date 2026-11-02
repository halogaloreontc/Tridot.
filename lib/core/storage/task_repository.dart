import '../models/task.dart';

abstract interface class TaskRepository {
  Future<List<Task>> list();

  Future<Task?> get(String id);

  Future<void> save(Task task);
}
