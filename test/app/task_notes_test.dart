import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/widgets/document_view.dart';
import 'package:local_assistant/app/widgets/task_notes.dart';
import 'package:local_assistant/app/widgets/task_tile.dart';
import 'package:local_assistant/core/models/task.dart';

/// Заметки и пункты задачи из чата на экране (ADR-033): строка задачи,
/// документ задачи — в обеих темах.
void main() {
  final now = DateTime(2026, 11, 2, 15, 0);
  final task = Task(
    id: 't1',
    title: 'Эссен',
    status: TaskStatus.inbox,
    priority: TaskPriority.normal,
    createdAt: now,
    updatedAt: now,
    notes: <TaskNote>[
      TaskNote(text: '22 шт в ОК, 1 шт в уценке, арт. 67782', at: now),
      TaskNote(text: 'поставщик перезвонит', at: DateTime(2026, 10, 30, 9)),
    ],
    items: const <TaskItem>[
      TaskItem(text: 'Молоко', done: true),
      TaskItem(text: 'Хлеб'),
    ],
  );

  test('кратко: число заметок и пунктов', () {
    expect(taskExtrasSummary(task), '2 заметки\u00a0· пункты 1/2');
    expect(
      taskExtrasSummary(
        Task(
          id: 't2',
          title: 'Пусто',
          status: TaskStatus.inbox,
          priority: TaskPriority.normal,
          createdAt: now,
          updatedAt: now,
        ),
      ),
      '',
    );
  });

  for (final (name, theme) in <(String, ThemeData Function())>[
    ('тёмная', AssistantTheme.dark),
    ('светлая', AssistantTheme.light),
  ]) {
    testWidgets('$name: строка задачи показывает заметки и пункты',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme(),
          home: Scaffold(body: TaskTile(task: task, now: now)),
        ),
      );
      expect(
        find.textContaining('2 заметки\u00a0· пункты 1/2'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('$name: документ — пункты, заметки со временем, отметка',
        (WidgetTester tester) async {
      final toggled = <int>[];
      final title = TextEditingController(text: task.title);
      final project = TextEditingController();
      final body = TextEditingController();
      final focus = FocusNode();
      addTearDown(() {
        title.dispose();
        project.dispose();
        body.dispose();
        focus.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: theme(),
          home: Scaffold(
            body: DocumentView(
              task: task,
              now: now,
              titleController: title,
              projectController: project,
              bodyController: body,
              bodyFocus: focus,
              saveState: DocumentSaveState.saved,
              savedAt: null,
              onSaveNow: () {},
              onReopen: () {},
              onOpenTasks: () {},
              onToggleItem: toggled.add,
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('task-notes')), findsOneWidget);
      expect(find.text('Заметки из чата'), findsOneWidget);
      expect(
        find.text('22 шт в ОК, 1 шт в уценке, арт. 67782'),
        findsOneWidget,
      );
      expect(find.text('15:00'), findsOneWidget);
      expect(find.text('30.10'), findsOneWidget);
      expect(find.text('Молоко'), findsOneWidget);
      await tester.tap(find.byKey(const Key('task-item-1')));
      expect(toggled, <int>[1]);
      expect(tester.takeException(), isNull);
    });
  }
}
