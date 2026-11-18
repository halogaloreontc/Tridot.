import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/web_widget/widget_storage.dart';
import 'package:local_assistant/web_widget/widget_store.dart';

void main() {
  late MemoryStorage storage;
  late List<(String, Map<String, Object?>)> calls;
  late List<MyReply> replies;

  Future<MyReply> call(String action, Map<String, Object?> body) async {
    calls.add((action, body));
    return replies.isEmpty
        ? const MyReply(200, <String, Object?>{'ok': true})
        : replies.removeAt(0);
  }

  Task task(String id, {String title = 'Проверить акт'}) => Task(
        id: id,
        title: title,
        status: TaskStatus.inbox,
        priority: TaskPriority.normal,
        createdAt: DateTime.utc(2026, 11, 18, 9),
        updatedAt: DateTime.utc(2026, 11, 18, 9),
      );

  WidgetStore make({bool on = true}) => WidgetStore(
        storage: storage,
        login: 'Ivanov',
      )..attach(
          <String, Object?>{
            if (on) 'store': <String, Object?>{'v': 1, 'on': true},
          },
          call,
        );

  setUp(() {
    storage = MemoryStorage();
    calls = <(String, Map<String, Object?>)>[];
    replies = <MyReply>[];
  });

  test('без store в ask_me — только кэш, на склад ни одного запроса', () async {
    final store = make(on: false);
    await store.tasks.save(task('task_1_0'));
    await store.flush();
    expect(store.remote, isFalse);
    expect(calls, isEmpty);
    expect(await store.tasks.get('task_1_0'), isNotNull);
    expect(storage.values.keys, everyElement(startsWith('svz:')));
  });

  test('запись уже есть на складе (stale) — правка по полям', () async {
    final store = make();
    replies.add(
      const MyReply(409, <String, Object?>{'ok': false, 'code': 'stale'}),
    );
    await store.tasks.save(task('task_1_0'));
    await store.flush();
    expect(calls.map((c) => c.$1), <String>['my_put', 'my_patch']);
    expect((calls.last.$2['set']! as Map)['title'], 'Проверить акт');
  });

  test('нет связи — правка ждёт и уходит со следующей попыткой', () async {
    final store = make();
    replies.add(const MyReply(0));
    await store.tasks.save(task('task_1_0'));
    // Первая попытка (сразу после записи) — без связи; следующая — уходит.
    await store.flush();
    expect(calls.map((c) => c.$1), <String>['my_put', 'my_put']);
    // Неотправленное переживает перезагрузку фрейма.
    final state = jsonDecode(storage.values['svz:my:ivanov']!) as Map;
    expect(state['dt'], isEmpty);
  });

  test('403 — хранилище выключено, дальше без запросов', () async {
    final store = make();
    replies.add(
      const MyReply(403, <String, Object?>{'ok': false, 'need': 'login'}),
    );
    await store.tasks.save(task('task_1_0'));
    await store.flush();
    expect(store.remote, isFalse);
    expect(store.offReason, contains('403'));
    await store.tasks.save(task('task_2_0'));
    await store.flush();
    expect(calls, hasLength(1));
  });

  test('my_sync: gone убирает задачу и её разговор', () async {
    final store = make();
    await store.tasks.save(task('task_1_0'));
    await store.flush();
    calls.clear();
    replies.add(
      const MyReply(200, <String, Object?>{
        'ok': true,
        'epoch': 'e1',
        'rev': 5,
        'mark': 'm',
        'full': false,
        'items': <Object?>[],
        'gone': <Object?>[
          <String, Object?>{'type': 'task', 'id': 'task_1_0', 'rev': 5},
        ],
        'next': 5,
        'more': false,
      }),
    );
    expect(await store.pull(), isTrue);
    expect(await store.tasks.get('task_1_0'), isNull);
    expect(calls.single.$2['since'], 0);
  });

  test('выход: все ключи этого входа стёрты', () async {
    final store = make(on: false);
    await store.tasks.save(task('task_1_0'));
    store.clear();
    expect(storage.values.keys.where((k) => k.contains('ivanov')), isEmpty);
  });
}
