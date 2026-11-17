// Отметки с виджета рабочего стола (ADR-034): как очередь «выполнено» и
// «отмена» применяется к задачам и что бывает при расхождениях.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/homescreen/home_screen_actions.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';
import 'package:local_assistant/core/storage/task_repository.dart';

final class _Clock implements Clock {
  _Clock(this.value);

  DateTime value;

  @override
  DateTime now() => value;
}

/// Хранилище, которое по просьбе теста не записывает.
final class _FailingRepository implements TaskRepository {
  final InMemoryTaskRepository _inner = InMemoryTaskRepository();
  bool fail = false;

  @override
  Future<Task?> get(String id) => _inner.get(id);

  @override
  Future<List<Task>> list() => _inner.list();

  @override
  Future<void> save(Task task) async {
    if (fail) throw StateError('диск');
    await _inner.save(task);
  }
}

/// Задачи созданы в 9:00, отметки на виджете — после 10:00.
final DateTime _created = DateTime(2026, 11, 16, 9);
final DateTime _tap = DateTime(2026, 11, 16, 10, 0, 5);

HomeScreenOp _done(int seq, String task, {DateTime? at}) => HomeScreenOp(
      seq: seq,
      kind: HomeScreenOpKind.done,
      taskId: task,
      at: at ?? _tap,
    );

HomeScreenOp _undo(int seq, String task, {DateTime? at, DateTime? doneAt}) =>
    HomeScreenOp(
      seq: seq,
      kind: HomeScreenOpKind.undo,
      taskId: task,
      at: at ?? _tap.add(const Duration(seconds: 2)),
      doneAt: doneAt ?? _tap,
    );

void main() {
  late _Clock clock;
  late InMemoryTaskRepository repository;
  late TaskService tasks;

  setUp(() {
    clock = _Clock(_created);
    repository = InMemoryTaskRepository();
    tasks = TaskService(repository: repository, clock: clock);
  });

  Future<Task> create(String title) => tasks.create(
        title: title,
        dueAt: DateTime(2026, 11, 16, 18),
      );

  test('«выполнено» — задача выполнена временем нажатия', () async {
    final task = await create('Купить хлеб');
    // Приложение открыли и применили очередь через час после нажатия.
    clock.value = DateTime(2026, 11, 16, 11);
    final applied = await HomeScreenActions.apply(
      <HomeScreenOp>[_done(7, task.id)],
      tasks,
    );
    expect(applied.upTo, 7);
    expect(applied.completed, <String>[task.id]);
    expect(applied.changed, isTrue);
    final after = (await tasks.find(task.id))!;
    expect(after.status, TaskStatus.done);
    expect(after.completedAt, _tap);
    expect(after.updatedAt, _tap);
    expect(await tasks.listActive(), isEmpty);
  });

  test('задачи нет, удалена, выполнена или отменена — пропуск', () async {
    final gone = await create('Удалённая');
    await repository.save(gone.copyWith(deletedAt: _created));
    final done = await create('Уже выполнена');
    await tasks.complete(done.id);
    final off = await create('Отменена');
    await repository.save(off.copyWith(status: TaskStatus.cancelled));
    final applied = await HomeScreenActions.apply(
      <HomeScreenOp>[
        _done(1, 'task_missing'),
        _done(2, gone.id),
        _done(3, done.id),
        _done(4, off.id),
      ],
      tasks,
    );
    // Пропущенное тоже подтверждается: повторять его незачем.
    expect(applied.upTo, 4);
    expect(applied.completed, isEmpty);
    expect(applied.changed, isFalse);
    expect((await tasks.find(done.id))!.completedAt, _created);
    expect((await repository.get(off.id))!.status, TaskStatus.cancelled);
  });

  test('задачу правили после нажатия — правка важнее', () async {
    final task = await create('Сдать отчёт');
    // Срок перенесли в приложении уже после нажатия на виджете.
    clock.value = _tap.add(const Duration(minutes: 1));
    await tasks.reschedule(
      task.id,
      DateTime(2026, 11, 17, 10),
      DuePrecision.dateTime,
    );
    final applied = await HomeScreenActions.apply(
      <HomeScreenOp>[_done(1, task.id)],
      tasks,
    );
    expect(applied.upTo, 1);
    expect(applied.completed, isEmpty);
    expect((await tasks.find(task.id))!.isActive, isTrue);
  });

  test('«отмена» возвращает задачу, выполненную той самой отметкой', () async {
    final task = await create('Купить хлеб');
    await HomeScreenActions.apply(<HomeScreenOp>[_done(1, task.id)], tasks);
    clock.value = DateTime(2026, 11, 16, 11);
    final applied = await HomeScreenActions.apply(
      <HomeScreenOp>[_undo(2, task.id)],
      tasks,
    );
    expect(applied.upTo, 2);
    expect(applied.reopened, <String>[task.id]);
    final after = (await tasks.find(task.id))!;
    expect(after.status, TaskStatus.planned);
    expect(after.completedAt, isNull);
    expect(after.updatedAt, _tap.add(const Duration(seconds: 2)));
  });

  test('«отмена» чужой отметки, активной или пропавшей задачи — пропуск',
      () async {
    // Выполнена в приложении, а не на виджете: время другое.
    final inApp = await create('В приложении');
    clock.value = DateTime(2026, 11, 16, 10, 30);
    await tasks.complete(inApp.id);
    final active = await create('Активная');
    final applied = await HomeScreenActions.apply(
      <HomeScreenOp>[
        _undo(1, inApp.id),
        _undo(2, active.id),
        _undo(3, 'task_missing'),
        // Без времени отметки отменять нечего.
        HomeScreenOp(
          seq: 4,
          kind: HomeScreenOpKind.undo,
          taskId: inApp.id,
          at: _tap,
        ),
      ],
      tasks,
    );
    expect(applied.upTo, 4);
    expect(applied.reopened, isEmpty);
    expect((await tasks.find(inApp.id))!.status, TaskStatus.done);
    expect((await tasks.find(active.id))!.isActive, isTrue);
  });

  test('очередь доставлена дважды — второй раз ничего не меняет', () async {
    final a = await create('Первая');
    final b = await create('Вторая');
    final ops = <HomeScreenOp>[
      _done(1, a.id),
      _done(2, b.id),
      _undo(3, b.id),
    ];
    clock.value = DateTime(2026, 11, 16, 11);
    final first = await HomeScreenActions.apply(ops, tasks);
    expect(first.upTo, 3);
    expect(first.completed, <String>[a.id]);
    expect(first.reopened, <String>[b.id]);
    final stateA = (await tasks.find(a.id))!;
    final stateB = (await tasks.find(b.id))!;
    clock.value = DateTime(2026, 11, 16, 12);
    final second = await HomeScreenActions.apply(ops, tasks);
    expect(second.upTo, 3);
    expect(second.changed, isFalse);
    final againA = (await tasks.find(a.id))!;
    final againB = (await tasks.find(b.id))!;
    expect(againA.status, TaskStatus.done);
    expect(againA.completedAt, stateA.completedAt);
    expect(againA.updatedAt, stateA.updatedAt);
    expect(againB.isActive, isTrue);
    expect(againB.updatedAt, stateB.updatedAt);
  });

  test('отметили, отменили и отметили снова — задача выполнена', () async {
    final task = await create('Купить хлеб');
    final again = _tap.add(const Duration(seconds: 3));
    clock.value = DateTime(2026, 11, 16, 11);
    final applied = await HomeScreenActions.apply(
      <HomeScreenOp>[
        // Порядок — по номерам, как бы ни пришло.
        _done(3, task.id, at: again),
        _done(1, task.id),
        _undo(2, task.id),
      ],
      tasks,
    );
    expect(applied.upTo, 3);
    expect(applied.completed, <String>[task.id]);
    expect(applied.reopened, isEmpty);
    final after = (await tasks.find(task.id))!;
    expect(after.status, TaskStatus.done);
    expect(after.completedAt, again);
  });

  test('неизвестное действие пропускается и подтверждается', () async {
    final task = await create('Купить хлеб');
    final applied = await HomeScreenActions.apply(
      <HomeScreenOp>[
        HomeScreenOp(seq: 5, kind: null, taskId: task.id, at: _tap),
      ],
      tasks,
    );
    expect(applied.upTo, 5);
    expect((await tasks.find(task.id))!.isActive, isTrue);
  });

  test('запись не сохранилась — она и следующие остаются в очереди', () async {
    final failing = _FailingRepository();
    final service = TaskService(repository: failing, clock: clock);
    final a = await service.create(title: 'Первая');
    final b = await service.create(title: 'Вторая');
    final c = await service.create(title: 'Третья');
    final ops = <HomeScreenOp>[_done(1, a.id), _done(2, b.id), _done(3, c.id)];
    await HomeScreenActions.apply(<HomeScreenOp>[ops.first], service);
    failing.fail = true;
    final applied = await HomeScreenActions.apply(ops, service);
    // Первая уже выполнена (пропуск), вторая не записалась.
    expect(applied.upTo, 1);
    expect(applied.completed, isEmpty);
    failing.fail = false;
    final retry = await HomeScreenActions.apply(ops, service);
    expect(retry.upTo, 3);
    expect(retry.completed, <String>[b.id, c.id]);
  });

  test('пустая очередь — подтверждать нечего', () async {
    final applied = await HomeScreenActions.apply(
      const <HomeScreenOp>[],
      tasks,
    );
    expect(applied.upTo, isNull);
    expect(applied.changed, isFalse);
  });

  group('запись из канала', () {
    test('«выполнено» и «отмена»', () {
      final done = HomeScreenOp.parse(<Object?, Object?>{
        'seq': 12,
        'op': 'done',
        'task': 'task_1',
        'at': 1763300000000,
      })!;
      expect(done.seq, 12);
      expect(done.kind, HomeScreenOpKind.done);
      expect(done.taskId, 'task_1');
      expect(done.at, DateTime.fromMillisecondsSinceEpoch(1763300000000));
      expect(done.doneAt, isNull);
      final undo = HomeScreenOp.parse(<Object?, Object?>{
        'seq': 13,
        'op': 'undo',
        'task': 'task_1',
        'at': 1763300002000,
        'doneAt': 1763300000000,
      })!;
      expect(undo.kind, HomeScreenOpKind.undo);
      expect(undo.doneAt, done.at);
    });

    test('незнакомое действие — запись без вида; мусор — не запись', () {
      final unknown = HomeScreenOp.parse(<Object?, Object?>{
        'seq': 1,
        'op': 'snooze',
        'task': 'task_1',
        'at': 1,
      })!;
      expect(unknown.kind, isNull);
      for (final junk in <Object?>[
        null,
        'done',
        <Object?, Object?>{'op': 'done', 'task': 'task_1', 'at': 1},
        <Object?, Object?>{'seq': 1, 'op': 'done', 'at': 1},
        <Object?, Object?>{'seq': 1, 'op': 'done', 'task': '', 'at': 1},
        <Object?, Object?>{'seq': 1, 'op': 'done', 'task': 'task_1'},
        <Object?, Object?>{'seq': '1', 'op': 'done', 'task': 't', 'at': 1},
      ]) {
        expect(HomeScreenOp.parse(junk), isNull, reason: '$junk');
      }
    });
  });

  test('TaskService: complete и reopen берут время нажатия', () async {
    final task = await create('Купить хлеб');
    clock.value = DateTime(2026, 11, 16, 12);
    final done = await tasks.complete(task.id, at: _tap);
    expect(done.completedAt, _tap);
    expect(done.updatedAt, _tap);
    // Уже выполненную второй раз не трогает.
    expect((await tasks.complete(task.id)).completedAt, _tap);
    final open = await tasks.reopen(task.id, at: _tap);
    expect(open.updatedAt, _tap);
    // Без времени — часы, как раньше.
    final again = await tasks.complete(task.id);
    expect(again.completedAt, DateTime(2026, 11, 16, 12));
    expect(await tasks.find('task_missing'), isNull);
  });
}
