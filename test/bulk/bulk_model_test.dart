import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/formatting/due_format.dart';
import 'package:local_assistant/core/models/bulk.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/replies/builtin_replies.g.dart';
import 'package:local_assistant/core/replies/reply_template.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/scenario/bulk_parser.dart';
import 'package:local_assistant/core/connectors/utterance.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';

/// Массовые команды: выбор задач, сдвиг, разбор и запись карточки в
/// историю чата.
void main() {
  final now = DateTime(2026, 11, 2, 16, 30); // понедельник

  Task task(
    String id, {
    DateTime? due,
    DuePrecision precision = DuePrecision.date,
    List<String> tags = const <String>[],
    TaskStatus status = TaskStatus.planned,
  }) =>
      Task(
        id: id,
        title: id,
        status: status,
        priority: TaskPriority.normal,
        createdAt: now,
        updatedAt: now,
        dueAt: due,
        duePrecision: precision,
        tags: tags,
      );

  group('выбор задач', () {
    final yesterday = task('вчера', due: DateTime(2026, 11, 1));
    final todayPast = task(
      'сегодня в 9',
      due: DateTime(2026, 11, 2, 9),
      precision: DuePrecision.dateTime,
      tags: const <String>['работа'],
    );
    final today = task('сегодня', due: DateTime(2026, 11, 2));
    final friday = task(
      'пятница',
      due: DateTime(2026, 11, 6),
      tags: const <String>['работа', 'отчёты'],
    );
    final noDue = task('без срока', tags: const <String>['ремонт']);
    final done = task('сделано', status: TaskStatus.done);
    final all = <Task>[yesterday, todayPast, today, friday, noDue, done];

    List<String> pick(BulkSelection selection) => <String>[
          for (final t in all)
            if (selection.matches(t, now)) t.id,
        ];

    test('все активные — без завершённых', () {
      expect(pick(const BulkSelection()), <String>[
        'вчера',
        'сегодня в 9',
        'сегодня',
        'пятница',
        'без срока',
      ]);
    });

    test('просроченные — по правилу isOverdue', () {
      expect(
        pick(const BulkSelection(kind: BulkScopeKind.overdue)),
        <String>['вчера', 'сегодня в 9'],
      );
    });

    test('день — любой срок этого дня, без срока — только без срока', () {
      expect(
        pick(
          BulkSelection(kind: BulkScopeKind.day, day: DateTime(2026, 11, 2)),
        ),
        <String>['сегодня в 9', 'сегодня'],
      );
      expect(
        pick(const BulkSelection(kind: BulkScopeKind.noDue)),
        <String>['без срока'],
      );
    });

    test('метки сужают любой выбор, нужна каждая', () {
      expect(
        pick(const BulkSelection(tags: <String>['работа'])),
        <String>['сегодня в 9', 'пятница'],
      );
      expect(
        pick(
          const BulkSelection(
            kind: BulkScopeKind.overdue,
            tags: <String>['работа'],
          ),
        ),
        <String>['сегодня в 9'],
      );
      expect(
        pick(const BulkSelection(tags: <String>['работа', 'отчёты'])),
        <String>['пятница'],
      );
    });

    test('запись в корпусе', () {
      expect(const BulkSelection().label, 'all');
      expect(
        const BulkSelection(
          kind: BulkScopeKind.overdue,
          tags: <String>['работа'],
        ).label,
        'overdue #работа',
      );
      expect(
        BulkSelection(kind: BulkScopeKind.day, day: DateTime(2026, 11, 6))
            .label,
        'date:2026-11-06',
      );
    });
  });

  group('сдвиг', () {
    test('часы и минуты — только задачам с точным временем', () {
      const hour = DueShift(1, ShiftUnit.hours);
      expect(hour.fits(DuePrecision.dateTime), isTrue);
      expect(hour.fits(DuePrecision.date), isFalse);
      expect(hour.fits(DuePrecision.partOfDay), isFalse);
      expect(const DueShift(2, ShiftUnit.days).fits(DuePrecision.date), isTrue);
    });

    test('дни — по календарю, время сохраняется', () {
      expect(
        const DueShift(2, ShiftUnit.days).apply(DateTime(2026, 11, 30, 10)),
        DateTime(2026, 12, 2, 10),
      );
      expect(
        const DueShift(-30, ShiftUnit.minutes).apply(DateTime(2026, 11, 2, 9)),
        DateTime(2026, 11, 2, 8, 30),
      );
    });

    test('слова, запись в корпусе и разбор записи', () {
      expect(const DueShift(1, ShiftUnit.hours).describe(), 'на 1 час позже');
      expect(const DueShift(-2, ShiftUnit.days).describe(), 'на 2 дня раньше');
      expect(
        const DueShift(30, ShiftUnit.minutes).describe(),
        'на 30 минут позже',
      );
      expect(const DueShift(7, ShiftUnit.days).label, '+7d');
      expect(DueShift.parse('-30m'), const DueShift(-30, ShiftUnit.minutes));
      for (final bad in <Object?>['+0h', '1h', '+2y', null, 3]) {
        expect(DueShift.parse(bad), isNull, reason: '$bad');
      }
    });
  });

  group('разбор массовых команд', () {
    final parser = ScenarioParser(clock: FixedClock(now));

    test('признаки выбора и новый срок', () {
      final cases = <String, (CommandIntent, String, DateTime?, String?)>{
        'перенеси всё на выходные': (
          CommandIntent.rescheduleMany,
          'all',
          DateTime(2026, 11, 7),
          null,
        ),
        'все задачи на пятницу перенеси на понедельник': (
          CommandIntent.rescheduleMany,
          'date:2026-11-06',
          DateTime(2026, 11, 9),
          null,
        ),
        'перенеси всё с #работа на понедельник': (
          CommandIntent.rescheduleMany,
          'all #работа',
          DateTime(2026, 11, 9),
          null,
        ),
        'сдвинь всё на час позже': (
          CommandIntent.rescheduleMany,
          'all',
          null,
          '+1h',
        ),
        'отметь всё на сегодня выполненным': (
          CommandIntent.completeMany,
          'date:2026-11-02',
          null,
          null,
        ),
        'закрой все просроченные': (
          CommandIntent.completeMany,
          'overdue',
          null,
          null,
        ),
        'заверши всё по #ремонт': (
          CommandIntent.completeMany,
          'all #ремонт',
          null,
          null,
        ),
        'перенеси все задачи без срока на пятницу': (
          CommandIntent.rescheduleMany,
          'noDue',
          DateTime(2026, 11, 6),
          null,
        ),
      };
      for (final MapEntry(key: text, value: expected) in cases.entries) {
        final parsed = parser.parse(text);
        expect(parsed.intent, expected.$1, reason: text);
        expect(parsed.isBulk, isTrue, reason: text);
        expect(parsed.selection?.label, expected.$2, reason: text);
        expect(parsed.dueAt, expected.$3, reason: text);
        expect(parsed.shift?.label, expected.$4, reason: text);
        expect(parsed.title, isNull, reason: text);
      }
    });

    test('одна задача и разговор — не массовые команды', () {
      for (final text in <String>[
        'перенеси встречу на завтра',
        'всё, задача закрыта',
        'на завтра перенеси',
        'перенеси задачу на завтра',
        'покажи все задачи',
        'отметь всё',
        'закрой «Все задачи по ремонту»',
        'добавь задачу перенести все встречи на пятницу',
      ]) {
        final parsed = parser.parse(text);
        expect(parsed.isBulk, isFalse, reason: text);
        expect(parsed.selection, isNull, reason: text);
      }
    });

    test('два признака дня — вопрос, а не угадывание', () {
      final parsed =
          parser.parse('перенеси все задачи на пятницу на понедельник');
      expect(parsed.intent, CommandIntent.rescheduleMany);
      expect(parsed.dueIssue, DueIssue.conflictingDays);
      expect(parsed.dueAt, isNull);
    });
  });

  group('карточка в истории чата', () {
    BulkChecklist sample() => BulkChecklist(
          id: 'bulk_1',
          action: BulkAction.reschedule,
          selection: const BulkSelection(
            kind: BulkScopeKind.overdue,
            tags: <String>['работа'],
          ),
          items: <BulkItem>[
            BulkItem(taskId: 't1', title: 'Отчёт', dueLabel: 'вчера'),
            BulkItem(taskId: 't2', title: 'Счёт', checked: false),
          ],
          targetDue: DateTime(2026, 11, 7),
          targetPrecision: DuePrecision.date,
          targetLabel: 'сб, 7 ноября',
        );

    test('неотвеченный вопрос после перезапуска — устаревший', () {
      final json = jsonDecode(jsonEncode(sample().toJson()));
      final restored = BulkChecklist.fromJson(json)!;
      expect(restored.state, BulkChecklistState.expired);
      expect(restored.isPending, isFalse);
      expect(restored.canUndo, isFalse);
      expect(
        restored.items.map((BulkItem i) => i.checked),
        <bool>[true, false],
      );
      expect(restored.items.first.dueLabel, 'вчера');
      expect(restored.items.last.dueLabel, isNull);
      expect(restored.selection.label, 'overdue #работа');
      expect(restored.targetDue, DateTime(2026, 11, 7));
      expect(restored.targetLabel, 'сб, 7 ноября');
      // Устаревшую карточку нельзя менять.
      expect(restored.setChecked('t2', true), isFalse);
      expect(restored.setAll(false), isFalse);
    });

    test('применённый список сохраняет итог, но не отмену', () {
      final checklist = sample()
        ..state = BulkChecklistState.applied
        ..applied = 1
        ..canUndo = true;
      final restored = BulkChecklist.fromJson(
        jsonDecode(jsonEncode(checklist.toJson())),
      )!;
      expect(restored.state, BulkChecklistState.applied);
      expect(restored.applied, 1);
      expect(restored.canUndo, isFalse);
    });

    test('сдвиг и незнакомые значения читаются без падения', () {
      final shifted = BulkChecklist(
        id: 'bulk_2',
        action: BulkAction.reschedule,
        selection: const BulkSelection(),
        items: <BulkItem>[BulkItem(taskId: 't', title: 'Т')],
        shift: const DueShift(1, ShiftUnit.hours),
        state: BulkChecklistState.undone,
      );
      final restored = BulkChecklist.fromJson(
        jsonDecode(jsonEncode(shifted.toJson())),
      )!;
      expect(restored.shift, const DueShift(1, ShiftUnit.hours));
      expect(restored.state, BulkChecklistState.undone);

      final future = BulkChecklist.fromJson(<String, Object?>{
        'id': 'x',
        'action': 'complete',
        'selection': <String, Object?>{
          'kind': 'новый',
          'tags': <Object?>[1],
        },
        'items': <Object?>[
          <String, Object?>{'task_id': 't', 'title': 'Т'},
          'мусор',
        ],
        'state': 'неизвестно',
      })!;
      expect(future.selection.label, 'all');
      expect(future.items, hasLength(1));
      expect(future.state, BulkChecklistState.expired);
      expect(BulkChecklist.fromJson('битая запись'), isNull);
      expect(BulkChecklist.fromJson(<String, Object?>{'id': 'x'}), isNull);
    });
  });

  test('короткий срок карточки: день недели и дата', () {
    expect(
      formatDueShort(DateTime(2026, 11, 7), DuePrecision.date, now),
      'сб, 7 ноября',
    );
    expect(
      formatDueShort(DateTime(2026, 11, 3, 10), DuePrecision.dateTime, now),
      'вт, 3 ноября в 10:00',
    );
    expect(
      formatDueShort(DateTime(2027, 1, 4), DuePrecision.date, now),
      'пн, 4 января 2027',
    );
  });

  test('итоги массовых команд согласуются с числом во всех стилях', () {
    // Регрессия: «Есть! 1 задачу теперь на завтра», «1 задачу теперь
    // выполнены» в дружеском стиле.
    final bad = RegExp(
      r'(^|[^\d])(1|21) задачу теперь|(^|[^\d])(1|21) задачи? теперь выполнены',
    );
    for (final MapEntry(key: style, value: json)
        in builtInReplyCatalogs.entries) {
      final entries =
          (jsonDecode(json) as Map<String, Object?>)['entries']! as Map;
      for (final MapEntry(:key, :value) in entries.entries) {
        if (!'$key'.startsWith('task.bulk.')) continue;
        final variants = value is List ? value : <Object?>[value];
        for (final variant in variants) {
          final template = ReplyTemplate.parse('$variant');
          for (final count in <int>[1, 2, 5, 21]) {
            final text = template.render(<String, String>{
              for (final name in template.placeholders) name: 'x',
              'count': '$count',
            });
            expect(bad.hasMatch(text), isFalse, reason: '$style $key: $text');
          }
        }
      }
    }
    final friendly = ReplyTemplate.parse(
      'Готово: {count} {мн:count|задача|задачи|задач} теперь '
      '{мн:count|выполнена|выполнены|выполнены}.',
    );
    expect(
      friendly.render(<String, String>{'count': '1'}),
      'Готово: 1 задача теперь выполнена.',
    );
  });

  group('разбор: регрессии ревью', () {
    BulkParse? parse(String text) =>
        const BulkParser().parse(Utterance.analyze(text, now: now), now);

    test('«кроме …» в самой команде — исключения', () {
      expect(parse('закрой всё, кроме хлеба')!.exclude, <String>['хлеба']);
      expect(
        parse('перенеси все задачи кроме отчёта на завтра')!.exclude,
        <String>['отчёта'],
      );
      expect(
        parse('закрой всё кроме хлеба, молока и «Сдать отчёт»')!.exclude,
        <String>['Сдать отчёт', 'хлеба', 'молока'],
      );
      final tail = parse('перенеси всё на завтра, кроме хлеба')!;
      expect(tail.exclude, <String>['хлеба']);
      expect(tail.dueAt, DateTime(2026, 11, 3));
      expect(parse('закрой «Купить хлеб»'), isNull);
      expect(parse('закрой всё, кроме'), isNull);
    });

    test('множественное «задачи», «дела» без «все» — массовая команда', () {
      expect(parse('перенеси задачи на завтра'), isNotNull);
      expect(parse('закрой дела'), isNotNull);
      expect(parse('перенеси задачу на завтра'), isNull);
      expect(parse('перенеси срок задачи на завтра'), isNull);
    });

    test('«всё,» в начале — конец реплики, а не «все задачи»', () {
      expect(parse('всё, закрой'), isNull);
      expect(parse('всё — перенеси на пятницу'), isNull);
      expect(parse('всё, перенеси все на пятницу'), isNotNull);
      expect(parse('всё перенеси на пятницу'), isNotNull);
    });

    test('одно ли слово: формы и предлоги', () {
      expect(TasksConnector.sameWord('воду', 'воды'), isTrue);
      expect(TasksConnector.sameWord('хлеб', 'хлеба'), isTrue);
      expect(TasksConnector.sameWord('в', 'воды'), isFalse);
      expect(TasksConnector.sameWord('по', 'покупки'), isFalse);
      expect(TasksConnector.sameWord('вода', 'водитель'), isFalse);
    });
  });
}
