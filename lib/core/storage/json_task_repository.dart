import 'dart:convert';
import 'dart:io';

import '../models/task.dart';
import 'task_repository.dart';

/// Простое постоянное хранилище для вертикального прототипа.
/// Файл записывается атомарно; полноценная SQLite-реализация заменит его
/// без изменения TaskService и сценарного движка.
final class JsonTaskRepository implements TaskRepository {
  JsonTaskRepository(this.filePath);

  final String filePath;
  List<Task>? _cache;

  /// Очередь записей: «прочитать — изменить — записать» не перемешиваются,
  /// иначе параллельные сохранения теряют друг друга и делят один .tmp.
  Future<void> _writes = Future<void>.value();

  @override
  Future<Task?> get(String id) async {
    final tasks = await _load();
    for (final task in tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  @override
  Future<List<Task>> list() async => List<Task>.unmodifiable(await _load());

  @override
  Future<void> save(Task task) {
    final write = _writes.then((_) async {
      final tasks = await _load();
      final index = tasks.indexWhere((Task item) => item.id == task.id);
      if (index == -1) {
        tasks.add(task);
      } else {
        tasks[index] = task;
      }
      await _persist(tasks);
    });
    // Ошибка одной записи не должна блокировать следующие.
    _writes = write.catchError((Object _) {});
    return write;
  }

  Future<List<Task>> _load() async {
    if (_cache != null) return List<Task>.of(_cache!);
    final file = File(filePath);
    if (!await file.exists()) {
      _cache = <Task>[];
      return <Task>[];
    }
    final content = await file.readAsString();
    final decoded = jsonDecode(content) as Map<String, dynamic>;
    final rows = decoded['tasks'] as List<dynamic>? ?? const <dynamic>[];
    _cache = rows
        .map((dynamic row) => Task.fromJson(row as Map<String, dynamic>))
        .toList();
    return List<Task>.of(_cache!);
  }

  Future<void> _persist(List<Task> tasks) async {
    final file = File(filePath);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    final payload = <String, dynamic>{
      'schema_version': 1,
      'tasks': tasks.map((Task task) => task.toJson()).toList(),
    };
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
      flush: true,
    );
    await temporary.rename(file.path);
    _cache = List<Task>.of(tasks);
  }
}
