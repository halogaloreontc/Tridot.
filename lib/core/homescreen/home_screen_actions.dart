/// Отметки с виджета рабочего стола (ADR-034): «выполнено» и его отмена.
///
/// Виджет работает, когда приложение закрыто, а файл задач пишет только
/// само приложение (у хранилища кэш в памяти — второй писатель затёр бы
/// его). Поэтому нажатие на виджете попадает в очередь на устройстве, а
/// применяет её приложение: при запуске, при возврате на экран и сразу,
/// если оно открыто.
library;

import '../models/task.dart';
import '../services/task_service.dart';

/// Что сделали на виджете.
enum HomeScreenOpKind { done, undo }

/// Одна запись очереди.
final class HomeScreenOp {
  const HomeScreenOp({
    required this.seq,
    required this.kind,
    required this.taskId,
    required this.at,
    this.doneAt,
  });

  /// Номер записи: растёт с каждой новой. Подтверждение — «всё до него».
  final int seq;

  /// `null` — действие, которого эта версия не знает: пропускается.
  final HomeScreenOpKind? kind;

  final String taskId;

  /// Когда нажали.
  final DateTime at;

  /// Для отмены: время отметки, которую отменяют ([at] той записи).
  final DateTime? doneAt;

  /// Запись из канала; `null` — не запись (нет номера, задачи или времени).
  static HomeScreenOp? parse(Object? value) {
    if (value is! Map) return null;
    final seq = value['seq'];
    final task = value['task'];
    final at = value['at'];
    final doneAt = value['doneAt'];
    if (seq is! int || task is! String || task.isEmpty || at is! int) {
      return null;
    }
    return HomeScreenOp(
      seq: seq,
      kind: switch (value['op']) {
        'done' => HomeScreenOpKind.done,
        'undo' => HomeScreenOpKind.undo,
        _ => null,
      },
      taskId: task,
      at: DateTime.fromMillisecondsSinceEpoch(at),
      doneAt:
          doneAt is int ? DateTime.fromMillisecondsSinceEpoch(doneAt) : null,
    );
  }
}

/// Итог применения очереди.
final class HomeScreenApplied {
  const HomeScreenApplied({
    this.upTo,
    this.completed = const <String>[],
    this.reopened = const <String>[],
  });

  /// До какого номера очередь разобрана (применено или пропущено):
  /// подтвердить системе. `null` — разбирать было нечего.
  final int? upTo;

  /// Задачи, которые стали выполненными.
  final List<String> completed;

  /// Задачи, которые вернулись в работу.
  final List<String> reopened;

  bool get changed => completed.isNotEmpty || reopened.isNotEmpty;
}

/// Применяет очередь отметок к задачам.
abstract final class HomeScreenActions {
  /// Записи [ops] по порядку номеров. Повторное применение ничего не
  /// меняет: очередь доставляется «хотя бы раз».
  ///
  /// «Выполнено»:
  /// - задачи нет или она удалена, уже выполнена или отменена — пропуск;
  /// - задачу меняли после нажатия ([Task.updatedAt] позже) — пропуск:
  ///   поздняя правка в приложении важнее, строка вернётся на виджет;
  /// - иначе — выполнена временем нажатия.
  ///
  /// «Отмена» возвращает задачу в работу, только если она выполнена именно
  /// той отметкой (время совпадает); иначе — пропуск.
  ///
  /// Запись не удалось сохранить — разбор останавливается на ней: она и
  /// следующие останутся в очереди до другого раза.
  static Future<HomeScreenApplied> apply(
    Iterable<HomeScreenOp> ops,
    TaskService tasks,
  ) async {
    final ordered = ops.toList()
      ..sort((HomeScreenOp a, HomeScreenOp b) => a.seq.compareTo(b.seq));
    int? upTo;
    final completed = <String>[];
    final reopened = <String>[];
    for (final op in ordered) {
      try {
        switch (op.kind) {
          case HomeScreenOpKind.done:
            if (await _complete(op, tasks)) {
              reopened.remove(op.taskId);
              completed.add(op.taskId);
            }
          case HomeScreenOpKind.undo:
            if (await _reopen(op, tasks)) {
              completed.remove(op.taskId);
              reopened.add(op.taskId);
            }
          case null:
            break;
        }
      } on Object {
        break;
      }
      upTo = op.seq;
    }
    return HomeScreenApplied(
      upTo: upTo,
      completed: completed,
      reopened: reopened,
    );
  }

  static Future<bool> _complete(HomeScreenOp op, TaskService tasks) async {
    final task = await tasks.find(op.taskId);
    if (task == null || !task.isActive) return false;
    if (task.updatedAt.isAfter(op.at)) return false;
    await tasks.complete(op.taskId, at: op.at);
    return true;
  }

  static Future<bool> _reopen(HomeScreenOp op, TaskService tasks) async {
    final doneAt = op.doneAt;
    if (doneAt == null) return false;
    final task = await tasks.find(op.taskId);
    if (task == null || task.status != TaskStatus.done) return false;
    if (task.completedAt?.millisecondsSinceEpoch !=
        doneAt.millisecondsSinceEpoch) {
      return false;
    }
    // Временем нажатия: отметка, поставленная после отмены, не должна
    // выглядеть более ранней, чем эта правка.
    await tasks.reopen(op.taskId, at: op.at);
    return true;
  }
}
