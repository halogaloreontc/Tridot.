// Проекты-папки на главном экране (ADR-018): создать проект из панели,
// начать в нём сессию, перенести сессию долгим нажатием, удалить проект с
// выносом сессий, метка задач проекта и перезапуск.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/core/chats/chat_book.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import 'support/home_nav.dart';

final class _Harness {
  _Harness(this.tasks, this.chats, this.assistant);

  final TaskService tasks;
  final InMemoryChatStore chats;
  final AssistantController assistant;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  Size size = const Size(1300, 1000),
  InMemoryChatStore? chats,
  InMemoryTaskRepository? repository,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final time = FixedClock(DateTime(2026, 11, 4, 12));
  final tasks = TaskService(
    repository: repository ?? InMemoryTaskRepository(),
    clock: time,
  );
  final assistant = AssistantController(
    connectors: <Connector>[
      TasksConnector(taskService: tasks, parser: ScenarioParser(clock: time)),
      TalkConnector(taskService: tasks),
    ],
    clock: time,
  );
  final store = chats ?? InMemoryChatStore();
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.dark(),
      home: HomePage(
        assistant: assistant,
        tasks: tasks,
        clock: time,
        settingsStore: InMemorySettingsStore(),
        chatStore: store,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(tasks, store, assistant);
}

Future<void> _say(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('assistant-input')), text);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

/// Подпись проекта у строки сессии [id] в панели.
Finder _projectMark(String id) => find.descendant(
      of: find.byKey(const Key('app-sidebar')),
      matching: find.byKey(Key('chat-project-$id')),
    );

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// «Новый проект» в панели: окно с названием (и описанием).
Future<void> _createProject(
  WidgetTester tester,
  String name, {
  String description = '',
}) async {
  await tapInDrawer(tester, const Key('project-new'));
  await tester.enterText(find.byKey(const Key('project-name-field')), name);
  if (description.isNotEmpty) {
    await tester.enterText(
      find.byKey(const Key('project-description-field')),
      description,
    );
  }
  await tester.pump();
  await _tap(tester, find.byKey(const Key('project-save')));
}

/// Id единственного проекта в хранилище.
Future<String> _projectId(InMemoryChatStore store) async =>
    (await store.loadProjects()).single.id;

void main() {
  testWidgets(
      'проект из панели → «Новая сессия в проекте» → команда: сессия в '
      'проекте и в «Сегодня» с подписью', (tester) async {
    final h = await _pump(tester);
    await _createProject(tester, 'Ремонт', description: 'Кухня и ванная');
    final id = await _projectId(h.chats);

    // Открыт экран проекта.
    expect(find.byKey(const Key('project-screen')), findsOneWidget);
    expect(find.byKey(const Key('project-title')), findsOneWidget);
    expect(find.text('Кухня и ванная'), findsOneWidget);
    expect(find.byKey(const Key('project-empty')), findsOneWidget);
    expect(find.byKey(Key('project-$id')), findsOneWidget);

    await _tap(tester, find.byKey(const Key('project-new-session')));
    // Пустая сессия уже в проекте: подпись на заставке и в шапке.
    expect(find.byKey(const Key('hero-project')), findsOneWidget);
    expect(find.text('Проект «Ремонт»'), findsOneWidget);
    expect(find.byKey(const Key('session-project')), findsOneWidget);

    await _say(tester, 'Добавь задачу «Купить плитку»');
    final threads = await h.chats.loadIndex();
    final session = threads.singleWhere((ChatThread t) => t.isSession);
    expect(session.projectId, id);
    // В «Сегодня» — со значком папки и названием проекта.
    expect(_projectMark(session.id), findsOneWidget);
    // Задача из сессии проекта: её чат тоже в проекте.
    final task = threads.singleWhere((ChatThread t) => !t.isSession);
    expect(task.projectId, id);

    // На экране проекта — эта сессия.
    await tapInDrawer(tester, Key('project-$id'));
    expect(find.byKey(Key('project-session-${session.id}')), findsOneWidget);
    expect(find.byKey(const Key('project-empty')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('долгое нажатие → «В проект…» → проект; «Убрать из проекта»',
      (tester) async {
    final h = await _pump(tester);
    await _say(tester, 'Добавь задачу «Хлеб»');
    final session =
        (await h.chats.loadIndex()).singleWhere((ChatThread t) => t.isSession);
    await _createProject(tester, 'Дом');
    final id = await _projectId(h.chats);

    final row = find.byKey(Key('chat-${session.id}'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.longPress(row);
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const Key('session-menu-move')));
    expect(find.byKey(const Key('move-sheet')), findsOneWidget);
    expect(find.byKey(const Key('move-out')), findsNothing);
    await _tap(tester, find.byKey(Key('move-to-$id')));

    expect(_projectMark(session.id), findsOneWidget);
    var stored = (await h.chats.loadIndex())
        .singleWhere((ChatThread t) => t.id == session.id);
    expect(stored.projectId, id);

    // Тем же меню — из проекта обратно.
    await tester.longPress(find.byKey(Key('chat-${session.id}')));
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const Key('session-menu-move')));
    await _tap(tester, find.byKey(const Key('move-out')));
    expect(_projectMark(session.id), findsNothing);
    stored = (await h.chats.loadIndex())
        .singleWhere((ChatThread t) => t.id == session.id);
    expect(stored.projectId, isNull);
  });

  testWidgets('меню шапки: «В проект…» → «Новый проект…»', (tester) async {
    final h = await _pump(tester);
    await _say(tester, 'привет');
    await _tap(tester, find.byKey(const Key('session-title')));
    await _tap(tester, find.byKey(const Key('session-menu-move')));
    await _tap(tester, find.byKey(const Key('move-new-project')));
    await tester.enterText(
      find.byKey(const Key('project-name-field')),
      'Покупки',
    );
    await tester.pump();
    await _tap(tester, find.byKey(const Key('project-save')));
    final id = await _projectId(h.chats);
    final session =
        (await h.chats.loadIndex()).singleWhere((ChatThread t) => t.isSession);
    expect(session.projectId, id);
    // Сессия осталась открытой, в шапке — проект.
    expect(find.byKey(const Key('session-project')), findsOneWidget);
  });

  testWidgets('удалить проект: сессии выносятся и остаются', (tester) async {
    final h = await _pump(tester);
    await _createProject(tester, 'Ремонт');
    final id = await _projectId(h.chats);
    await _tap(tester, find.byKey(const Key('project-new-session')));
    await _say(tester, 'Добавь задачу «Плитка»');
    final session =
        (await h.chats.loadIndex()).singleWhere((ChatThread t) => t.isSession);

    await tapInDrawer(tester, Key('project-$id'));
    await _tap(tester, find.byKey(const Key('project-menu')));
    await _tap(tester, find.byKey(const Key('project-menu-delete')));
    expect(find.textContaining('1 сессия'), findsOneWidget);
    await _tap(tester, find.byKey(const Key('project-delete-move-out')));

    expect(await h.chats.loadProjects(), isEmpty);
    expect(find.byKey(Key('project-$id')), findsNothing);
    final stored = (await h.chats.loadIndex())
        .singleWhere((ChatThread t) => t.id == session.id);
    expect(stored.projectId, isNull);
    expect(stored.messageCount, greaterThan(0));
    expect(find.byKey(Key('chat-${session.id}')), findsOneWidget);
  });

  testWidgets('удалить проект вместе с сессиями', (tester) async {
    final h = await _pump(tester);
    await _createProject(tester, 'Ремонт');
    final id = await _projectId(h.chats);
    await _tap(tester, find.byKey(const Key('project-new-session')));
    await _say(tester, 'Добавь задачу «Плитка»');
    await tapInDrawer(tester, Key('project-$id'));
    await _tap(tester, find.byKey(const Key('project-menu')));
    await _tap(tester, find.byKey(const Key('project-menu-delete')));
    await _tap(tester, find.byKey(const Key('project-delete-with-sessions')));
    expect(
      (await h.chats.loadIndex()).where((ChatThread t) => t.isSession),
      isEmpty,
    );
    // Задача осталась.
    expect((await h.tasks.listActive()).single.title, 'Плитка');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'метка «Сделать папкой»: задача из сессии папки получает метку, '
      'папка показывает задачи метки', (tester) async {
    final h = await _pump(tester);
    await _say(tester, 'Добавь задачу «Отчёт» #работа');
    await tapInDrawer(tester, const Key('nav-projects'));
    await _tap(tester, find.byKey(const ValueKey<String>('tag-работа')));
    await _tap(tester, find.byKey(const Key('make-folder-работа')));
    // Название подставлено из метки.
    await _tap(tester, find.byKey(const Key('project-save')));
    final project = (await h.chats.loadProjects()).single;
    expect(project.name, 'работа');
    expect(project.taskTag, 'работа');
    expect(find.byKey(const Key('project-tag')), findsOneWidget);
    expect(find.text('Отчёт'), findsOneWidget);

    await _tap(tester, find.byKey(const Key('project-new-session')));
    await _say(tester, 'Добавь задачу «Созвон»');
    final created = (await h.tasks.listActive())
        .singleWhere((Task t) => t.title == 'Созвон');
    expect(created.tags, <String>['работа']);
  });

  testWidgets(
      'удалить папку с меткой вместе с сессиями, когда открыта пустая '
      'сессия папки: метка больше не подставляется', (tester) async {
    final h = await _pump(tester);
    await _say(tester, 'Добавь задачу «Отчёт» #работа');
    await tapInDrawer(tester, const Key('nav-projects'));
    await _tap(tester, find.byKey(const ValueKey<String>('tag-работа')));
    await _tap(tester, find.byKey(const Key('make-folder-работа')));
    await _tap(tester, find.byKey(const Key('project-save')));
    final id = await _projectId(h.chats);
    await _tap(tester, find.byKey(const Key('project-new-session')));
    await _say(tester, 'Добавь задачу «Созвон»');
    // Ещё одна «Новая сессия в проекте»: открыта пустая сессия папки.
    await tapInDrawer(tester, Key('project-$id'));
    await _tap(tester, find.byKey(const Key('project-new-session')));
    await tapInDrawer(tester, Key('project-$id'));
    await _tap(tester, find.byKey(const Key('project-menu')));
    await _tap(tester, find.byKey(const Key('project-menu-delete')));
    await _tap(tester, find.byKey(const Key('project-delete-with-sessions')));
    expect(await h.chats.loadProjects(), isEmpty);

    // Открытая пустая сессия осталась, но уже вне папки: задача без метки.
    final response = await h.assistant.handle('Добавь задачу «Хлеб»');
    expect(response.task?.title, 'Хлеб');
    expect(response.task?.tags, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('на экране проекта у сессий нет подписи этого проекта',
      (tester) async {
    final h = await _pump(tester);
    await _createProject(tester, 'Ремонт');
    final id = await _projectId(h.chats);
    await _tap(tester, find.byKey(const Key('project-new-session')));
    await _say(tester, 'Добавь задачу «Плитка»');
    final session =
        (await h.chats.loadIndex()).singleWhere((ChatThread t) => t.isSession);
    // В панели подпись есть.
    expect(_projectMark(session.id), findsOneWidget);
    await tapInDrawer(tester, Key('project-$id'));
    final row = find.byKey(Key('project-session-${session.id}'));
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.text('Ремонт')),
      findsNothing,
    );
    expect(
      find.descendant(of: row, matching: find.byIcon(Icons.folder_outlined)),
      findsNothing,
    );
  });

  testWidgets('перезапуск: проект и его сессии на месте', (tester) async {
    final store = InMemoryChatStore();
    final repository = InMemoryTaskRepository();
    await _pump(tester, chats: store, repository: repository);
    await _createProject(tester, 'Ремонт');
    final id = await _projectId(store);
    await _tap(tester, find.byKey(const Key('project-new-session')));
    await _say(tester, 'Добавь задачу «Плитка»');

    await tester.pumpWidget(const SizedBox());
    await _pump(tester, chats: store, repository: repository);
    expect(find.byKey(Key('project-$id')), findsOneWidget);
    final session =
        (await store.loadIndex()).singleWhere((ChatThread t) => t.isSession);
    expect(_projectMark(session.id), findsOneWidget);
    await tapInDrawer(tester, Key('project-$id'));
    expect(find.byKey(Key('project-session-${session.id}')), findsOneWidget);
    expect(ChatBook.sessionsLimit, greaterThan(0));
  });

  testWidgets(
      'телефон 320 px, шрифт 2x: панель с проектами и экран проекта '
      'без переполнений', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final h = await _pump(tester, size: const Size(320, 640));
    await _createProject(
      tester,
      'Очень длинное название проекта для проверки',
      description: 'Описание проекта, тоже довольно длинное',
    );
    final id = await _projectId(h.chats);
    expect(tester.takeException(), isNull);
    await _tap(tester, find.byKey(const Key('project-new-session')));
    await _say(tester, 'Добавь задачу «Плитка»');
    await tapInDrawer(tester, Key('project-$id'));
    await _tap(tester, find.byKey(const Key('project-menu')));
    expect(tester.takeException(), isNull);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
  });
}
