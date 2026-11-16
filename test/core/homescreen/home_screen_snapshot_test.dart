// Снимок для виджетов рабочего стола (ADR-034): порядок и подписи строк,
// режим «только числа», кадры по времени и формат для канала.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/homescreen/home_screen_snapshot.dart';
import 'package:local_assistant/core/models/task.dart';

/// Понедельник, 16 ноября 2026, 12:00.
final DateTime _now = DateTime(2026, 11, 16, 12);

Task _task(
  String id, {
  DateTime? due,
  DuePrecision precision = DuePrecision.dateTime,
  TaskStatus status = TaskStatus.planned,
  String? title,
  List<String> notes = const <String>[],
}) =>
    Task(
      id: id,
      title: title ?? 'Задача $id',
      status: status,
      priority: TaskPriority.normal,
      dueAt: due,
      duePrecision: precision,
      createdAt: _now,
      updatedAt: _now,
      notes: <TaskNote>[
        for (final text in notes) TaskNote(text: text, at: _now),
      ],
    );

HomeScreenSnapshot _snap(
  List<Task> tasks, {
  DateTime? now,
  bool showText = true,
  bool voice = true,
}) =>
    HomeScreenPlan.from(
      tasks,
      now: now ?? _now,
      showText: showText,
      voice: voice,
    );

List<String> _ids(HomeScreenFrame frame) =>
    <String>[for (final row in frame.rows) row.task.id];

List<String> _dues(HomeScreenFrame frame) =>
    <String>[for (final row in frame.rows) row.due];

/// Кадр снимка [json] на момент [at] — так его выбирает Android: последний
/// с `from` не позже текущего времени.
Map<String, Object?> _pick(Map<String, Object?> json, DateTime at) {
  final ms = at.millisecondsSinceEpoch;
  final frames =
      (json['frames']! as List<Object?>).cast<Map<String, Object?>>();
  return frames
      .lastWhere((Map<String, Object?> f) => (f['from']! as int) <= ms);
}

/// Вид кадра без начала: то, что рисует виджет.
String _view(Map<String, Object?> json, Map<String, Object?> frame) {
  final tasks = (json['tasks']! as List<Object?>).cast<Map<String, Object?>>();
  final rows = (frame['rows']! as List<Object?>).cast<Map<String, Object?>>();
  return <Object?>[
    frame['count'],
    frame['summary'],
    frame['alert'],
    for (final row in rows)
      '${tasks[row['t']! as int]['id']}|${row['due']}|${row['overdue']}|'
          '${row['counted']}',
  ].join(' ; ');
}

String _direct(List<Task> tasks, DateTime at) {
  final frame = HomeScreenPlan.frameAt(tasks, at, showText: true);
  return <Object?>[
    frame.count,
    frame.summary,
    frame.alert,
    for (final row in frame.rows)
      '${row.task.id}|${row.due}|${row.overdue}|${row.counted}',
  ].join(' ; ');
}

void main() {
  group('строки', () {
    // Порядок TaskService.listActive: по сроку, без срока — в конце.
    final tasks = <Task>[
      _task('old', due: DateTime(2026, 11, 15, 10)),
      _task('day', due: DateTime(2026, 11, 16), precision: DuePrecision.date),
      _task('nine', due: DateTime(2026, 11, 16, 9)),
      _task(
        'eve',
        due: DateTime(2026, 11, 16, PartOfDay.evening.hour),
        precision: DuePrecision.partOfDay,
      ),
      _task('tom', due: DateTime(2026, 11, 17, 10)),
      _task('fri', due: DateTime(2026, 11, 20), precision: DuePrecision.date),
      _task('none'),
    ];

    test('просроченные, на сегодня, ближайшие; без срока — нет', () {
      final frame = _snap(tasks).frames.first;
      expect(_ids(frame), <String>['old', 'nine', 'day', 'eve', 'tom', 'fri']);
      expect(_dues(frame), <String>[
        'вчера в 10:00',
        '9:00',
        'без времени',
        'вечером',
        'завтра в 10:00',
        '20 ноября',
      ]);
      expect(
        <bool>[for (final row in frame.rows) row.overdue],
        <bool>[true, true, false, false, false, false],
      );
      expect(
        <bool>[for (final row in frame.rows) row.counted],
        <bool>[true, true, true, true, false, false],
      );
      expect(frame.count, 4);
      expect(frame.summary, '4 дела');
      expect(frame.alert, 'просрочены 2 задачи');
      // Цвета диктор не видит: «просрочено» — в подписи для чтения.
      expect(frame.rows.first.say, 'вчера в 10:00, просрочено');
      expect(frame.rows[2].say, isNull);
    });

    test('выполненные, отменённые и удалённые на виджет не попадают', () {
      final frame = _snap(<Task>[
        _task('done', due: _now, status: TaskStatus.done),
        _task('off', due: _now, status: TaskStatus.cancelled),
        _task('live', due: DateTime(2026, 11, 16, 18)),
      ]).frames.first;
      expect(_ids(frame), <String>['live']);
      expect(frame.count, 1);
      expect(frame.summary, '1 дело');
      expect(frame.alert, isNull);
    });

    test('ближайшие — по сроку, даже если список пришёл не по порядку', () {
      final frame = _snap(<Task>[
        _task('later', due: DateTime(2026, 11, 25, 10)),
        _task('sooner', due: DateTime(2026, 11, 18, 10)),
        _task('today', due: DateTime(2026, 11, 16, 15)),
      ]).frames.first;
      expect(_ids(frame), <String>['today', 'sooner', 'later']);
      expect(frame.count, 1);
    });

    test('строк не больше двенадцати, а число дел — всё', () {
      final many = <Task>[
        for (var i = 0; i < 20; i++)
          _task('t$i', due: DateTime(2026, 11, 16, 13, i)),
      ];
      final frame = _snap(many).frames.first;
      expect(frame.rows, hasLength(HomeScreenPlan.maxRows));
      expect(_ids(frame).first, 't0');
      expect(frame.count, 20);
      expect(frame.summary, '20 дел');
    });

    test('просрочено — по точности срока', () {
      final frame = _snap(<Task>[
        _task(
          'yesterday',
          due: DateTime(2026, 11, 15),
          precision: DuePrecision.date,
        ),
        _task(
          'morning',
          due: DateTime(2026, 11, 16, PartOfDay.morning.hour),
          precision: DuePrecision.partOfDay,
        ),
        _task(
          'today',
          due: DateTime(2026, 11, 16),
          precision: DuePrecision.date,
        ),
        // Ровно сейчас — ещё не просрочено.
        _task('now', due: _now),
      ]).frames.first;
      expect(
        <(String, String, bool)>[
          for (final row in frame.rows) (row.task.id, row.due, row.overdue),
        ],
        <(String, String, bool)>[
          ('yesterday', 'вчера', true),
          ('morning', 'утром', true),
          ('today', 'без времени', false),
          ('now', '12:00', false),
        ],
      );
      expect(frame.alert, 'просрочены 2 задачи');
    });

    test('название и последняя запись — в одну строку и не длиннее меры', () {
      final frame = _snap(<Task>[
        _task(
          'a',
          due: DateTime(2026, 11, 16, 15),
          title: 'Сдать\nреестр\t по складу',
          notes: <String>['первая', '22 шт в ОК,\n1 шт  в уценке'],
        ),
        _task(
          'b',
          due: DateTime(2026, 11, 16, 16),
          title: 'я' * 300,
          notes: <String>['з' * 300],
        ),
        _task('c', due: DateTime(2026, 11, 16, 17)),
      ]).frames.first;
      final a = frame.rows[0].task;
      expect(a.title, 'Сдать реестр по складу');
      expect(a.note, '22 шт в ОК, 1 шт в уценке');
      final b = frame.rows[1].task;
      expect(b.title.runes.length, HomeScreenPlan.maxTitle);
      expect(b.title, endsWith('…'));
      expect(b.note!.runes.length, HomeScreenPlan.maxNote);
      expect(b.note, endsWith('…'));
      expect(frame.rows[2].task.note, isNull);
    });
  });

  group('только числа', () {
    test('ни названий, ни id, ни записей в снимке нет', () {
      final snapshot = _snap(
        <Task>[
          _task(
            'secret-id',
            due: DateTime(2026, 11, 15, 10),
            title: 'Тайное название',
            notes: <String>['Тайная запись'],
          ),
          _task('other-id', due: DateTime(2026, 11, 16, 18), title: 'Второе'),
        ],
        showText: false,
      );
      expect(snapshot.tasks, isEmpty);
      for (final frame in snapshot.frames) {
        expect(frame.rows, isEmpty);
      }
      final first = snapshot.frames.first;
      expect(first.count, 2);
      expect(first.summary, '2 дела');
      expect(first.alert, 'просрочена 1 задача');
      final encoded = snapshot.encode();
      expect(encoded, contains('"mode":"counts"'));
      for (final leak in <String>[
        'Тайн',
        'Второе',
        'secret-id',
        'other-id',
        'вчера',
        '18:00',
      ]) {
        expect(encoded, isNot(contains(leak)), reason: leak);
      }
      // Числа по времени всё равно меняются: в 18:00 — вторая просрочена.
      expect(snapshot.frames, hasLength(2));
      expect(snapshot.frames[1].alert, 'просрочены 2 задачи');
    });

    test('дел нет', () {
      final frame = _snap(const <Task>[], showText: false).frames.single;
      expect(frame.count, 0);
      expect(frame.summary, 'дел нет');
      expect(frame.alert, isNull);
    });
  });

  group('кадры', () {
    test('срок со временем: до срока, после, «вчера», дата, год', () {
      final snapshot = _snap(<Task>[
        _task('t', due: DateTime(2026, 11, 16, 18)),
      ]);
      expect(
        <(DateTime?, String, bool, int)>[
          for (final frame in snapshot.frames)
            (
              frame.from,
              frame.rows.single.due,
              frame.rows.single.overdue,
              frame.count,
            ),
        ],
        <(DateTime?, String, bool, int)>[
          (null, '18:00', false, 1),
          // Просрочена строго после срока.
          (DateTime(2026, 11, 16, 18, 0, 0, 1), '18:00', true, 1),
          (DateTime(2026, 11, 17), 'вчера в 18:00', true, 1),
          (DateTime(2026, 11, 18), '16 ноября в 18:00', true, 1),
          (DateTime(2027), '16 ноября 2026 в 18:00', true, 1),
        ],
      );
      expect(snapshot.until, isNull);
      expect(snapshot.frames[1].alert, 'просрочена 1 задача');
    });

    test('ближайшая задача на день: послезавтра, завтра, сегодня, вчера', () {
      final snapshot = _snap(<Task>[
        _task('d', due: DateTime(2026, 11, 19), precision: DuePrecision.date),
      ]);
      expect(
        <(DateTime?, String, bool, bool, String)>[
          for (final frame in snapshot.frames)
            (
              frame.from,
              frame.rows.single.due,
              frame.rows.single.overdue,
              frame.rows.single.counted,
              frame.summary,
            ),
        ],
        <(DateTime?, String, bool, bool, String)>[
          (null, '19 ноября', false, false, 'дел нет'),
          (DateTime(2026, 11, 17), 'послезавтра', false, false, 'дел нет'),
          (DateTime(2026, 11, 18), 'завтра', false, false, 'дел нет'),
          (DateTime(2026, 11, 19), 'без времени', false, true, '1 дело'),
          (DateTime(2026, 11, 20), 'вчера', true, true, '1 дело'),
          (DateTime(2026, 11, 21), '19 ноября', true, true, '1 дело'),
          (DateTime(2027), '19 ноября 2026', true, true, '1 дело'),
        ],
      );
    });

    test('часть суток просрочена с её концом', () {
      final snapshot = _snap(<Task>[
        _task(
          'p',
          due: DateTime(2026, 11, 16, PartOfDay.afternoon.hour),
          precision: DuePrecision.partOfDay,
        ),
      ]);
      expect(snapshot.frames[0].rows.single.overdue, isFalse);
      expect(snapshot.frames[0].rows.single.due, 'после обеда');
      expect(snapshot.frames[1].from, DateTime(2026, 11, 16, 18));
      expect(snapshot.frames[1].rows.single.overdue, isTrue);
    });

    test('Новый год: год в подписи появляется и пропадает', () {
      final snapshot = _snap(<Task>[
        _task(
          'j',
          due: DateTime(2027, 1, 10),
          precision: DuePrecision.date,
        ),
      ]);
      final byFrom = <DateTime?, String>{
        for (final frame in snapshot.frames) frame.from: frame.rows.single.due,
      };
      expect(byFrom[null], '10 января 2027');
      expect(byFrom[DateTime(2027)], '10 января');
      expect(byFrom[DateTime(2027, 1, 12)], '10 января');
      expect(byFrom[DateTime(2028)], '10 января 2027');
    });

    test('одинаковые подряд сливаются', () {
      // Только числа: полуночи за два дня до срока и через два после вида
      // не меняют.
      final snapshot = _snap(
        <Task>[
          _task('d', due: DateTime(2026, 11, 21), precision: DuePrecision.date),
        ],
        showText: false,
      );
      expect(
        <(DateTime?, int, String?)>[
          for (final frame in snapshot.frames)
            (frame.from, frame.count, frame.alert),
        ],
        <(DateTime?, int, String?)>[
          (null, 0, null),
          (DateTime(2026, 11, 21), 1, null),
          (DateTime(2026, 11, 22), 1, 'просрочена 1 задача'),
        ],
      );
    });

    test('задачи за двенадцатой строкой кадров не добавляют', () {
      final tasks = <Task>[
        for (var i = 0; i < 12; i++)
          _task(
            'day$i',
            due: DateTime(2026, 11, 16),
            precision: DuePrecision.date,
          ),
        // Дальние: в строки не попадают, число дел не меняют до 1 декабря.
        for (var i = 0; i < 30; i++)
          _task('far$i', due: DateTime(2026, 12, 1 + i, 10)),
      ];
      final snapshot = _snap(tasks);
      expect(snapshot.frames[0].rows, hasLength(12));
      expect(snapshot.frames[1].from, DateTime(2026, 11, 17));
      expect(snapshot.frames[2].from, DateTime(2026, 11, 18));
      expect(snapshot.frames[3].from, DateTime(2026, 12));
      expect(snapshot.tasks, hasLength(12));
    });

    test('кадров больше сорока — остальное отбрасывается, есть срок годности',
        () {
      final tasks = <Task>[
        for (var i = 1; i <= 60; i++)
          _task('t$i', due: DateTime(2026, 11, 16, 12, i)),
      ];
      final snapshot = _snap(tasks, showText: false);
      expect(snapshot.frames, hasLength(HomeScreenPlan.maxFrames));
      expect(snapshot.frames.last.from, DateTime(2026, 11, 16, 12, 39, 0, 1));
      expect(snapshot.frames.last.alert, 'просрочено 39 задач');
      expect(snapshot.until, DateTime(2026, 11, 16, 12, 40, 0, 1));
      expect(
        snapshot.toJson()['until'],
        DateTime(2026, 11, 16, 12, 40, 0, 1).millisecondsSinceEpoch,
      );
    });

    test('перемены: только будущие, по возрастанию, без повторов', () {
      final moments = HomeScreenPlan.boundaries(
        <Task>[
          _task('a', due: DateTime(2026, 11, 16, 18)),
          _task('b', due: DateTime(2026, 11, 16, 20)),
          _task('none'),
        ],
        _now,
      );
      expect(moments, <DateTime>[
        DateTime(2026, 11, 16, 18, 0, 0, 1),
        DateTime(2026, 11, 16, 20, 0, 0, 1),
        DateTime(2026, 11, 17),
        DateTime(2026, 11, 18),
        DateTime(2027),
      ]);
    });

    test('кадр, выбранный по времени, совпадает с расчётом на этот момент', () {
      final tasks = <Task>[
        _task('old', due: DateTime(2026, 11, 14, 9)),
        _task('day', due: DateTime(2026, 11, 16), precision: DuePrecision.date),
        _task('t1', due: DateTime(2026, 11, 16, 15, 30)),
        _task(
          'eve',
          due: DateTime(2026, 11, 16, PartOfDay.evening.hour),
          precision: DuePrecision.partOfDay,
        ),
        _task('t2', due: DateTime(2026, 11, 17, 8)),
        _task(
          'morn',
          due: DateTime(2026, 11, 18, PartOfDay.morning.hour),
          precision: DuePrecision.partOfDay,
        ),
        _task('wk', due: DateTime(2026, 11, 20), precision: DuePrecision.date),
        _task('ny', due: DateTime(2027, 1, 2, 11)),
      ];
      final json = _snap(tasks).toJson();
      expect(json['until'], isNull);
      // Каждые 37 минут на два месяца вперёд — через все перемены.
      for (var at = _now;
          at.isBefore(DateTime(2027, 1, 16));
          at = at.add(const Duration(minutes: 37))) {
        expect(_view(json, _pick(json, at)), _direct(tasks, at), reason: '$at');
      }
      // И ровно на переменах: за миллисекунду до, в момент и после.
      for (final moment in HomeScreenPlan.boundaries(tasks, _now)) {
        for (final shift in <int>[-1, 0, 1]) {
          final at = moment.add(Duration(milliseconds: shift));
          expect(
            _view(json, _pick(json, at)),
            _direct(tasks, at),
            reason: '$at',
          );
        }
      }
    });
  });

  group('формат для канала', () {
    final tasks = <Task>[
      _task(
        'task_1',
        due: DateTime(2026, 11, 15),
        precision: DuePrecision.date,
        title: 'Сдать реестр по складу',
        notes: <String>['22 шт в ОК, 1 шт в уценке, арт. 67782'],
      ),
      _task(
        'task_2',
        due: DateTime(2026, 11, 16, PartOfDay.evening.hour),
        precision: DuePrecision.partOfDay,
        title: 'Купить хлеб',
      ),
    ];

    test('таблица задач и кадры со ссылками на неё', () {
      final json = jsonDecode(_snap(tasks).encode()) as Map<String, Object?>;
      expect(json['v'], 1);
      expect(json['mode'], 'text');
      expect(json['voice'], isTrue);
      expect(json.containsKey('until'), isTrue);
      expect(json['until'], isNull);
      expect(json['tasks'], <Object?>[
        <String, Object?>{
          'id': 'task_1',
          'title': 'Сдать реестр по складу',
          'note': '22 шт в ОК, 1 шт в уценке, арт. 67782',
        },
        <String, Object?>{'id': 'task_2', 'title': 'Купить хлеб', 'note': null},
      ]);
      final frames =
          (json['frames']! as List<Object?>).cast<Map<String, Object?>>();
      expect(frames.first, <String, Object?>{
        'from': 0,
        'count': 2,
        'summary': '2 дела',
        'alert': 'просрочена 1 задача',
        'rows': <Object?>[
          <String, Object?>{
            't': 0,
            'due': 'вчера',
            'overdue': true,
            'counted': true,
            'say': 'вчера, просрочено',
          },
          <String, Object?>{
            't': 1,
            'due': 'вечером',
            'overdue': false,
            'counted': true,
          },
        ],
      });
      expect(frames[1]['from'], DateTime(2026, 11, 17).millisecondsSinceEpoch);
      expect(frames[1]['alert'], 'просрочены 2 задачи');
      // Начала кадров строго растут.
      final starts = <int>[for (final frame in frames) frame['from']! as int];
      expect(starts, List<int>.of(starts)..sort());
      expect(starts.toSet(), hasLength(starts.length));
    });

    test('без голосового ввода — voice: false', () {
      expect(_snap(tasks, voice: false).toJson()['voice'], isFalse);
    });

    test('тот же вид — та же строка: повторно не отправляется', () {
      final first = _snap(tasks).encode();
      expect(_snap(tasks).encode(), first);
      // Позже, но до первой перемены — снимок тот же.
      expect(_snap(tasks, now: DateTime(2026, 11, 16, 23, 59)).encode(), first);
      // После полуночи — уже другой.
      expect(
        _snap(tasks, now: DateTime(2026, 11, 17, 0, 0, 1)).encode(),
        isNot(first),
      );
    });
  });
}
