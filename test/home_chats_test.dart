// История чатов и чат задачи на главном экране (ADR-010): чат задачи
// открывается из панели и списков, шапка закрывает и возвращает задачу,
// ответ о новой задаче ведёт в её чат, «назад», перезапуск восстанавливает
// сообщения, меню «Чаты», узкий экран и крупный шрифт.
import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/app/widgets/bulk_checklist_card.dart';
import 'package:local_assistant/core/chats/attachments.dart';
import 'package:local_assistant/core/chats/chat_book.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/chats/chat_projects.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/models/bulk.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';
import 'package:local_assistant/core/storage/task_repository.dart';

import 'support/home_nav.dart';

final class _Clock implements Clock {
  _Clock(this.value);

  DateTime value;

  @override
  DateTime now() => value;
}

/// Запись задачи с задержкой: ответ готовится заметное время.
final class _SlowRepository implements TaskRepository {
  final InMemoryTaskRepository _inner = InMemoryTaskRepository();
  Duration delay = Duration.zero;

  @override
  Future<List<Task>> list() => _inner.list();

  @override
  Future<Task?> get(String id) => _inner.get(id);

  @override
  Future<void> save(Task task) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    await _inner.save(task);
  }
}

final class _Harness {
  _Harness(this.tasks, this.assistant, this.chats);

  final TaskService tasks;
  final AssistantController assistant;
  final ChatStore chats;

  Future<Task> byTitle(String title) async =>
      (await tasks.listAll()).firstWhere((Task t) => t.title == title);
}

const _desktop = Size(1300, 1000);

Future<_Harness> _pump(
  WidgetTester tester, {
  Size size = _desktop,
  ChatStore? chats,
  TaskRepository? repository,
  SettingsStore? settings,
  Clock? clock,
  Key? key,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final time = clock ?? FixedClock(DateTime(2026, 11, 4, 12));
  final tasks = TaskService(
    repository: repository ?? InMemoryTaskRepository(),
    clock: time,
  );
  final assistant = AssistantController(
    connectors: <Connector>[
      TasksConnector(taskService: tasks, parser: ScenarioParser(clock: time)),
      const CalculatorConnector(),
      TalkConnector(taskService: tasks),
    ],
    clock: time,
  );
  final store = chats ?? InMemoryChatStore();
  await tester.pumpWidget(
    MaterialApp(
      key: key,
      theme: AssistantTheme.dark(),
      home: HomePage(
        assistant: assistant,
        tasks: tasks,
        clock: time,
        settingsStore: settings ?? InMemorySettingsStore(),
        chatStore: store,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(tasks, assistant, store);
}

Future<void> _say(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('assistant-input')), text);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

/// Задача на экране «Задачи».
Finder _inPanel(Task task) => find.descendant(
      of: find.byKey(const Key('tasks-panel')),
      matching: find.byKey(ValueKey<String>('task-${task.id}')),
    );

/// Открыть задачу с экрана «Задачи» (меню → «Задачи» → задача).
Future<void> _openFromTasks(WidgetTester tester, Task task) async {
  await tapInDrawer(tester, const Key('nav-tasks'));
  await _tap(tester, _inPanel(task));
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Лента открытого чата сверху вниз: автор (или `user`) и текст.
List<String> _history(WidgetTester tester) {
  final rows = <String>[];
  String? author;
  for (final widget in tester.allWidgets) {
    final key = widget.key;
    if (key is ValueKey<String> && key.value.startsWith('message-author-')) {
      author = key.value.substring('message-author-'.length);
    }
    if (widget is SelectableText) {
      rows.add(
        '${author ?? 'user'}: ${widget.data ?? widget.textSpan?.toPlainText()}',
      );
      author = null;
    }
  }
  return rows.reversed.toList();
}

/// Перечитать задачи, созданные в обход чата: уход из раздела и возврат
/// в (пустую) сессию.
Future<void> _reload(WidgetTester tester) async {
  await tapInDrawer(tester, const Key('nav-projects'));
  await tapInDrawer(tester, const Key('new-session'));
}

String? _headerTitle(WidgetTester tester) {
  final title = find.byKey(const Key('task-chat-title'));
  if (title.evaluate().isEmpty) return null;
  return tester.widget<Text>(title).data;
}

String? _headerStatus(WidgetTester tester) {
  final status = find.byKey(const Key('task-chat-status'));
  if (status.evaluate().isEmpty) return null;
  return tester.widget<Text>(status).data;
}

void main() {
  testWidgets('нажатие на задачу в «Активных» открывает её чат', (
    tester,
  ) async {
    final h = await _pump(tester);
    final bread = await h.tasks.create(title: 'Купить хлеб');
    await h.tasks.create(title: 'Отчёт', dueAt: DateTime(2026, 11, 5, 10));
    await _say(tester, 'покажи задачи');
    final mainHistory = _history(tester);

    await _openFromTasks(tester, bread);
    expect(find.byKey(const Key('task-chat-header')), findsOneWidget);
    expect(_headerTitle(tester), 'Купить хлеб');
    expect(_headerStatus(tester), 'В работе');
    expect(_history(tester), isEmpty, reason: 'новый чат пуст');
    expect(h.assistant.chatTaskId, bread.id);

    // В чате задачи «готово» закрывает её, без вопроса «какую?».
    await _say(tester, 'готово');
    expect((await h.byTitle('Купить хлеб')).status, TaskStatus.done);
    expect((await h.byTitle('Отчёт')).isActive, isTrue);
    expect(_history(tester).first, 'user: готово');
    expect(_headerStatus(tester), 'Выполнена');
    expect(find.byKey(const Key('task-chat-reopen')), findsOneWidget);

    // «Назад» — в сессию, откуда пришли, её история на месте.
    await _tap(tester, find.byKey(const Key('task-back')));
    expect(find.byKey(const Key('task-chat-header')), findsNothing);
    expect(_history(tester), mainHistory);
    expect(h.assistant.chatTaskId, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('задача из «Планирования» открывается чатом в режиме «Диалог»', (
    tester,
  ) async {
    final h = await _pump(tester);
    final report =
        await h.tasks.create(title: 'Отчёт', dueAt: DateTime(2026, 11, 5, 10));
    await _tap(tester, find.byKey(const Key('nav-planning')));
    await _tap(tester, find.byKey(ValueKey<String>('task-${report.id}')));
    expect(_headerTitle(tester), 'Отчёт');
    expect(find.byKey(const Key('assistant-composer')), findsOneWidget);
    expect(find.byKey(const Key('chat-list')), findsOneWidget);
  });

  testWidgets('шапка: «Выполнено» и «Вернуть в работу» пишут строку в чат', (
    tester,
  ) async {
    final h = await _pump(tester);
    final bread = await h.tasks.create(title: 'Купить хлеб');
    await _reload(tester);
    await _openFromTasks(tester, bread);

    await _tap(tester, find.byKey(const Key('task-chat-done')));
    expect((await h.byTitle('Купить хлеб')).status, TaskStatus.done);
    expect(_history(tester), <String>['sado: Задача «Купить хлеб» завершена.']);
    expect(_headerStatus(tester), 'Выполнена');

    await _tap(tester, find.byKey(const Key('task-chat-reopen')));
    expect((await h.byTitle('Купить хлеб')).isActive, isTrue);
    expect(_history(tester).last, 'sado: Задача «Купить хлеб» снова в работе.');
    expect(_headerStatus(tester), 'В работе');

    // «Перенести…» вставляет в поле начало команды.
    await _tap(tester, find.byKey(const Key('task-chat-reschedule')));
    final field = tester.widget<TextField>(
      find.byKey(const Key('assistant-input')),
    );
    expect(field.controller!.text, 'Перенеси на ');
    await _say(tester, 'Перенеси на завтра');
    expect((await h.byTitle('Купить хлеб')).dueAt, DateTime(2026, 11, 5));
  });

  testWidgets('ответ о новой задаче ведёт в её чат с копией разговора', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _say(tester, 'Добавь задачу «Купить хлеб» на завтра');
    final task = await h.byTitle('Купить хлеб');
    final main = _history(tester);
    expect(main.length, 2, reason: 'команда и ответ, без приветствия');

    await _tap(
      tester,
      find.byKey(ValueKey<String>('open-task-chat-${task.id}')),
    );
    expect(_headerTitle(tester), 'Купить хлеб');
    expect(_history(tester), main, reason: 'команда и ответ');
    expect(find.byKey(const Key('chat-origin-link')), findsOneWidget);
    expect(
      find.text('из сессии «Добавь задачу «Купить хлеб» на завтра»'),
      findsOneWidget,
    );
    expect(find.textContaining('Главный'), findsNothing);

    // Новая задача из чата задачи получает свой чат с родителем.
    await _say(tester, 'добавь задачу купить масло');
    final butter = await h.byTitle('Купить масло');
    expect(_headerTitle(tester), 'Купить хлеб', reason: 'чат тот же');
    await _tap(
      tester,
      find.byKey(ValueKey<String>('open-task-chat-${butter.id}')),
    );
    expect(_headerTitle(tester), 'Купить масло');
    expect(find.text('из сессии «Купить хлеб»'), findsOneWidget);

    // «Назад» — в чат «Купить хлеб», затем в сессию, где его создали.
    await _tap(tester, find.byKey(const Key('task-back')));
    expect(_headerTitle(tester), 'Купить хлеб');
    await _tap(tester, find.byKey(const Key('task-back')));
    expect(_headerTitle(tester), isNull);
    expect(_history(tester), main);

    // Ссылка «из сессии «…»» тоже ведёт обратно.
    await _tap(
      tester,
      find.byKey(ValueKey<String>('open-task-chat-${task.id}')),
    );
    await _tap(tester, find.byKey(const Key('chat-origin-link')));
    expect(_headerTitle(tester), isNull);
    expect(_history(tester), main);
  });

  testWidgets('перезапуск восстанавливает чаты; карточка — устаревшая', (
    tester,
  ) async {
    final chats = InMemoryChatStore();
    final repository = InMemoryTaskRepository();
    final settings = InMemorySettingsStore();
    const tall = Size(1300, 2400);
    final h = await _pump(
      tester,
      size: tall,
      chats: chats,
      repository: repository,
      settings: settings,
    );
    await _say(tester, 'Добавь задачу «Купить хлеб»');
    await _say(tester, 'Добавь задачу «Отчёт» на завтра');
    await _say(tester, 'перенеси всё на выходные');
    expect(find.byType(BulkChecklistCard), findsOneWidget);
    final main = _history(tester);
    final bread = await h.byTitle('Купить хлеб');
    await _openFromTasks(tester, bread);
    await _say(tester, 'Нода, на завтра');
    final breadChat = _history(tester);
    expect(breadChat.last, startsWith('noda: '));

    await _pump(
      tester,
      size: tall,
      chats: chats,
      repository: repository,
      settings: settings,
      key: const ValueKey<String>('после перезапуска'),
    );
    // После перезапуска — новая пустая сессия, прежняя — в меню.
    expect(_headerTitle(tester), isNull);
    expect(find.byKey(const Key('session-hero')), findsOneWidget);
    expect(_history(tester), isEmpty);
    await openSessionTitled(tester, 'Добавь задачу «Купить хлеб»');
    expect(_history(tester), main);
    final card = tester.widget<BulkChecklistCard>(
      find.byType(BulkChecklistCard),
    );
    expect(card.checklist.state, BulkChecklistState.expired);

    await _openFromTasks(tester, bread);
    expect(_history(tester), breadChat);
    // Выбора «Кому» нет: после перезапуска ни к кому не «приклеено».
    expect(find.byKey(const Key('addressee-switch')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('удалённая задача: её чат удаляется, выполненная — остаётся', (
    tester,
  ) async {
    final repository = InMemoryTaskRepository();
    final h = await _pump(tester, repository: repository);
    await _say(tester, 'Добавь задачу «Купить хлеб»');
    await _say(tester, 'Добавь задачу «Отчёт»');
    final bread = await h.byTitle('Купить хлеб');
    final report = await h.byTitle('Отчёт');
    await h.tasks.complete(report.id);
    await repository.save(bread.copyWith(deletedAt: DateTime(2026, 11, 4)));
    await _tap(tester, find.byKey(const Key('nav-projects')));
    await _tap(tester, find.byKey(const Key('new-session')));
    final store = h.chats as InMemoryChatStore;
    expect(store.chatIds, isNot(contains(ChatThread.taskChatId(bread.id))));
    expect(store.chatIds, contains(ChatThread.taskChatId(report.id)));
    // Не стёрт, а в архиве: вдруг задача пропала с потерянным tasks.json.
    expect(store.archivedIds, contains(ChatThread.taskChatId(bread.id)));
  });

  testWidgets('меню «Чаты»: последние чаты по активности и новое сообщение', (
    tester,
  ) async {
    final clock = _Clock(DateTime(2026, 11, 4, 12));
    final h = await _pump(tester, clock: clock);
    await h.tasks.create(title: 'Старое', dueAt: DateTime(2026, 11, 5));
    await _say(tester, 'Добавь задачу «Купить хлеб»');
    clock.value = DateTime(2026, 11, 4, 12, 5);
    await _say(tester, 'Добавь задачу «Отчёт»');
    final bread = await h.byTitle('Купить хлеб');
    final report = await h.byTitle('Отчёт');

    double top(String taskId) =>
        tester.getTopLeft(find.byKey(Key('chat-$taskId'))).dy;
    expect(find.byKey(const Key('chat-main')), findsNothing);
    expect(find.text('Главный'), findsNothing);
    // В чатах задач пока только копии команды из сессии: строк для них
    // нет, команды видны в самой сессии.
    expect(find.byKey(Key('chat-${bread.id}')), findsNothing);
    expect(find.byKey(Key('chat-${report.id}')), findsNothing);
    expect(sessionEntries(), findsOneWidget);

    await _openFromTasks(tester, report);
    clock.value = DateTime(2026, 11, 4, 12, 7);
    await _say(tester, 'на пятницу');
    await _openFromTasks(tester, bread);
    expect(_headerTitle(tester), 'Купить хлеб');
    clock.value = DateTime(2026, 11, 4, 12, 10);
    await _say(tester, 'на пятницу');
    expect(top(bread.id), lessThan(top(report.id)), reason: 'свежий выше');

    // Новый день: о просроченной говорит строка в пустой сессии; в
    // сессии ничего не пишется, точек «новое сообщение» нет.
    clock.value = DateTime(2026, 11, 6, 9);
    await _tap(tester, find.byKey(const Key('nav-projects')));
    await _tap(tester, find.byKey(Key('chat-${bread.id}')));
    expect(_headerTitle(tester), 'Купить хлеб');
    final unread = find.byWidgetPredicate(
      (Widget w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('chat-unread-'),
    );
    expect(unread, findsNothing);
    expect(_history(tester).join('\n'), isNot(contains('«Старое»')));
    await _tap(tester, find.byKey(const Key('new-session')));
    expect(find.byKey(const Key('session-hero-overdue')), findsOneWidget);
    expect(find.text('Просрочена 1 задача'), findsOneWidget);
    expect(_history(tester), isEmpty);
    await openSessionTitled(tester, 'Добавь задачу «Купить хлеб»');
    expect(_history(tester).join('\n'), isNot(contains('«Старое»')));
    expect(unread, findsNothing);
  });

  testWidgets('ответ после ухода из чата приходит в свой чат', (tester) async {
    final repository = _SlowRepository();
    final h = await _pump(tester, repository: repository);
    final bread = await h.tasks.create(title: 'Купить хлеб');
    final report = await h.tasks.create(title: 'Отчёт');
    await _reload(tester);
    await _openFromTasks(tester, bread);
    repository.delay = const Duration(seconds: 2);
    await tester.enterText(find.byKey(const Key('assistant-input')), 'готово');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    // Пока ответ готовится, пользователь открыл другой чат.
    await tester.tap(find.byKey(const Key('nav-tasks')));
    await tester.pump();
    await tester.tap(_inPanel(report));
    await tester.pump();
    expect(_headerTitle(tester), 'Отчёт');
    expect(find.byKey(const Key('working-message')), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect((await h.byTitle('Купить хлеб')).status, TaskStatus.done);
    expect((await h.byTitle('Отчёт')).isActive, isTrue);
    expect(_history(tester), isEmpty, reason: 'ответ не в чужом чате');
    expect(find.byKey(Key('chat-unread-${bread.id}')), findsOneWidget);
    await _tap(tester, find.byKey(Key('chat-${bread.id}')));
    expect(_history(tester).first, 'user: готово');
    expect(_history(tester).last, startsWith('sado: '));
  });

  testWidgets('320 px и крупный шрифт: шапка — меню, без переполнений', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final h = await _pump(tester, size: const Size(320, 640));
    await _say(tester, 'Добавь задачу «Купить хлеб и молоко на неделю»');
    final task = await h.byTitle('Купить хлеб и молоко на неделю');
    await _tap(
      tester,
      find.byKey(ValueKey<String>('open-task-chat-${task.id}')),
    );
    expect(find.byKey(const Key('task-chat-header')), findsOneWidget);
    expect(find.byKey(const Key('task-chat-done')), findsNothing);

    await _tap(tester, find.byKey(const Key('task-chat-menu')));
    await _tap(tester, find.byKey(const Key('task-chat-done')));
    expect((await h.byTitle(task.title)).status, TaskStatus.done);
    expect(_history(tester).last, contains('завершена'));
    // Своя реплика в чате задачи: теперь он и в меню.
    await _say(tester, 'спасибо');

    // Меню «Чаты» в выдвижной панели.
    await _tap(tester, find.byKey(const Key('task-back')));
    await _tap(tester, find.byKey(const Key('menu-button')));
    expect(sessionEntries(), findsOneWidget);
    await _tap(tester, find.byKey(Key('chat-${task.id}')));
    expect(find.byKey(const Key('task-chat-header')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // Шапка выбирает раскладку по ширине, которая ей досталась (рядом поиск
  // и кнопка панели), а не по ширине окна.
  for (final size in const <Size>[
    Size(700, 700),
    Size(900, 700),
    Size(1000, 800),
    Size(1150, 800),
    Size(1440, 900),
  ]) {
    testWidgets(
        'шапка чата задачи ${size.width.toInt()}×${size.height.toInt()}: '
        'название видно, без переполнений', (tester) async {
      final h = await _pump(tester, size: size);
      await _say(
        tester,
        'добавь задачу «Подготовить квартальный отчёт для бухгалтерии и '
        'согласовать» на завтра в 15:00',
      );
      final task = await h.byTitle(
        'Подготовить квартальный отчёт для бухгалтерии и согласовать',
      );
      expect(tester.takeException(), isNull, reason: 'главный чат');
      await _tap(
        tester,
        find.byKey(ValueKey<String>('open-task-chat-${task.id}')),
      );
      void check(String state) {
        expect(tester.takeException(), isNull, reason: state);
        final title = find.byKey(const Key('task-chat-title'));
        expect(title, findsOneWidget, reason: state);
        expect(
          tester.getSize(title).width,
          greaterThanOrEqualTo(120),
          reason: '$state: название не сжато до буквы',
        );
        final header = tester.getRect(
          find.byKey(const Key('task-chat-header')),
        );
        for (final key in const <Key>[
          Key('task-chat-done'),
          Key('task-chat-reopen'),
          Key('task-chat-menu'),
        ]) {
          final finder = find.byKey(key);
          if (finder.evaluate().isEmpty) continue;
          final rect = tester.getRect(finder);
          expect(
            rect.right,
            lessThanOrEqualTo(header.right + 0.5),
            reason: '$state: $key за краем шапки',
          );
        }
      }

      check('в работе');
      await _say(tester, 'готово');
      expect((await h.byTitle(task.title)).status, TaskStatus.done);
      check('выполнена');
      final reopen = find.byKey(const Key('task-chat-reopen'));
      if (reopen.evaluate().isNotEmpty) {
        await _tap(tester, reopen);
        expect((await h.byTitle(task.title)).isActive, isTrue);
      }
    });
  }

  testWidgets('меню колонкой (1000 px): сессия задачи с точкой', (
    tester,
  ) async {
    final repository = _SlowRepository();
    final h = await _pump(
      tester,
      size: const Size(1000, 700),
      repository: repository,
    );
    await _say(tester, 'добавь задачу купить хлеб');
    final bread = await h.byTitle('Купить хлеб');
    final item = find.byKey(Key('chat-${bread.id}'));
    expect(item, findsNothing, reason: 'только копия команды — строки нет');
    await _tap(
      tester,
      find.byKey(ValueKey<String>('open-task-chat-${bread.id}')),
    );
    expect(_headerTitle(tester), 'Купить хлеб');
    expect(item, findsOneWidget, reason: 'открытый чат задачи — в меню');

    repository.delay = const Duration(seconds: 2);
    await tester.enterText(find.byKey(const Key('assistant-input')), 'готово');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    await tester.tap(drawerEntry('добавь задачу купить хлеб').first);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('task-chat-header')), findsNothing);
    expect(find.byKey(Key('chat-unread-${bread.id}')), findsOneWidget);

    await _tap(tester, item);
    expect(_history(tester), contains('user: готово'));
    expect(find.byKey(Key('chat-unread-${bread.id}')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  group('только сессии, без «Главного»', () {
    testWidgets('старт — пустая сессия; «+» её не множит; подпись сессии', (
      tester,
    ) async {
      final h = await _pump(tester);
      expect(find.byKey(const Key('session-hero')), findsOneWidget);
      expect(_history(tester), isEmpty);
      expect(find.textContaining('Главный'), findsNothing);
      expect(sessionEntries(), findsOneWidget);
      String? headerTitle() =>
          tester.widget<Text>(find.byKey(const Key('session-title-text'))).data;
      expect(headerTitle(), 'Новая сессия');
      expect(
        find.descendant(
          of: find.byKey(const Key('session-title')),
          matching: find.byIcon(Icons.keyboard_arrow_down),
        ),
        findsNothing,
        reason: 'у пустой сессии меню нет',
      );
      await _tap(tester, find.byKey(const Key('new-session')));
      expect(sessionEntries(), findsOneWidget, reason: 'та же пустая');
      final input = tester.widget<TextField>(
        find.byKey(const Key('assistant-input')),
      );
      expect(
        input.focusNode!.hasFocus,
        isFalse,
        reason: 'на телефоне клавиатура сама не выскакивает',
      );
      await _say(tester, 'Покажи задачи');
      expect(headerTitle(), 'Покажи задачи');
      final store = h.chats as InMemoryChatStore;
      expect(store.chatIds.single, startsWith(ChatThread.sessionPrefix));
    });

    testWidgets(
        'старый «Главный» — сессия под первой командой; ссылка из '
        'чата задачи ведёт в неё', (tester) async {
      final store = InMemoryChatStore();
      final repository = InMemoryTaskRepository();
      final created = DateTime(2026, 11, 3, 10);
      await repository.save(
        Task(
          id: 't1',
          title: 'Хлеб',
          status: TaskStatus.planned,
          priority: TaskPriority.normal,
          createdAt: created,
          updatedAt: created,
        ),
      );
      ChatMessage message(
        String id,
        ChatAuthor author,
        String text, {
        ChatLink? link,
      }) =>
          ChatMessage(
            id: id,
            author: author,
            personaId: author == ChatAuthor.persona ? 'rio' : null,
            text: text,
            timestamp: created,
            link: link,
          );
      // Файлы прежней версии: «Главный» и чат задачи со ссылкой на него.
      await store.save(
        ChatThread(
          id: ChatThread.mainId,
          kind: ChatKind.main,
          createdAt: DateTime(2026, 11, 4, 12),
          lastActivityAt: created,
          messages: <ChatMessage>[
            message('m1', ChatAuthor.persona, 'Я готов к работе.'),
            message('m2', ChatAuthor.user, 'Добавь задачу «Хлеб»'),
            message(
              'm3',
              ChatAuthor.persona,
              'Создал задачу «Хлеб».',
              link: const ChatLink(chatId: 'task:t1', taskId: 't1'),
            ),
          ],
        ),
      );
      await store.save(
        ChatThread(
          id: 'task:t1',
          kind: ChatKind.task,
          taskId: 't1',
          createdAt: created,
          messages: <ChatMessage>[
            message('c1', ChatAuthor.user, 'Добавь задачу «Хлеб»'),
            message(
              'c2',
              ChatAuthor.persona,
              'Создал задачу «Хлеб».',
              link: const ChatLink(chatId: 'main', messageId: 'm3'),
            ),
          ],
        ),
      );

      await _pump(tester, chats: store, repository: repository);
      expect(find.byKey(const Key('session-hero')), findsOneWidget);
      expect(store.chatIds, isNot(contains(ChatThread.mainId)));
      expect(store.chatIds, contains(ChatThread.legacyMainSessionId));
      expect(store.archivedIds, contains(ChatThread.mainId));

      await openSessionTitled(tester, 'Добавь задачу «Хлеб»');
      final migrated = _history(tester);
      expect(migrated, <String>[
        'rio: Я готов к работе.',
        'user: Добавь задачу «Хлеб»',
        'rio: Создал задачу «Хлеб».',
      ]);
      await _tap(tester, find.byKey(const Key('open-task-chat-t1')));
      expect(_headerTitle(tester), 'Хлеб');
      expect(find.text('из сессии «Добавь задачу «Хлеб»»'), findsOneWidget);
      await _tap(tester, find.byKey(const Key('chat-origin-link')));
      expect(_headerTitle(tester), isNull);
      expect(_history(tester), migrated);
      expect(find.textContaining('Главный'), findsNothing);
    });

    testWidgets('«Очистить историю»: всё стёрто, открыта пустая сессия', (
      tester,
    ) async {
      final h = await _pump(tester);
      await _say(tester, 'Добавь задачу «Купить хлеб»');
      await _tap(tester, find.byKey(const Key('new-session')));
      await _say(tester, 'покажи задачи');
      await openSettings(tester);
      final clear = find.byKey(const ValueKey<String>('clear-chat'));
      await _tap(tester, clear);
      await _tap(
        tester,
        find.byKey(const ValueKey<String>('clear-chat-confirm')),
      );
      await backToSession(tester);
      expect(find.byKey(const Key('session-hero')), findsOneWidget);
      expect(_history(tester), isEmpty);
      expect((h.chats as InMemoryChatStore).chatIds, isEmpty);
      expect(sessionEntries(), findsOneWidget);
      expect(find.text('Добавь задачу «Купить хлеб»'), findsNothing);
      // Задачи на месте.
      expect((await h.tasks.listActive()).single.title, 'Купить хлеб');
    });
  });

  testWidgets('закрытие окна ждёт отложенную запись чатов', (tester) async {
    final store = _GatedStore();
    await _pump(tester, chats: store);
    await _say(tester, 'добавь задачу купить хлеб');
    var exited = false;
    final exit = tester.binding.handleRequestAppExit().then((response) {
      exited = true;
      return response;
    });
    await tester.pump();
    expect(store.flushes, greaterThan(0));
    expect(exited, isFalse, reason: 'запись ещё идёт');
    store.gate.complete();
    await tester.pump();
    expect(await exit, AppExitResponse.exit);
    expect(exited, isTrue);
  });

  group('действия с сессией из меню', () {
    Future<void> hold(WidgetTester tester, Finder row) async {
      await openDrawerIfNeeded(tester);
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.longPress(row);
      await tester.pumpAndSettle();
    }

    testWidgets(
        'переименовать: своё название в меню, поиске и после '
        'перезапуска', (tester) async {
      final store = InMemoryChatStore();
      await _pump(tester, chats: store, size: const Size(390, 844));
      await _say(tester, '2+2');
      final id = onlySessionId(store.chatIds);
      final row = find.byKey(Key('chat-$id'));
      await hold(tester, row);
      await tester.tap(find.byKey(const Key('session-menu-rename')));
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('rename-field'));
      expect(tester.widget<TextField>(field).controller!.text, '2+2');
      await tester.enterText(field, '   ');
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('rename-save')))
            .onPressed,
        isNull,
        reason: 'пустое не сохраняется',
      );
      await tester.enterText(field, '  Счёт   на складе ');
      await tester.pump();
      await tester.tap(find.byKey(const Key('rename-save')));
      await tester.pumpAndSettle();
      expect(drawerEntry('Счёт на складе'), findsOneWidget);
      expect(drawerEntry('2+2'), findsNothing);
      // Меню осталось открытым.
      expect(find.byKey(const Key('app-sidebar')), findsOneWidget);

      await tester.tap(find.byKey(const Key('session-search')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('session-search')), 'складе');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('search-hit-$id')), findsOneWidget);
      await tester.tap(find.byKey(const Key('session-search-cancel')));
      await tester.pumpAndSettle();

      // Перезапуск: новый экран над тем же хранилищем.
      await _pump(
        tester,
        chats: store,
        size: const Size(390, 844),
        key: UniqueKey(),
      );
      await openDrawerIfNeeded(tester);
      expect(drawerEntry('Счёт на складе'), findsOneWidget);
    });

    testWidgets('закрепить: «Закреплённые» сверху, открепить — обратно',
        (tester) async {
      final store = InMemoryChatStore();
      await _pump(tester, chats: store);
      await _say(tester, '2+2');
      final first = onlySessionId(store.chatIds);
      await tapInDrawer(tester, const Key('new-session'));
      await _say(tester, '3+3');
      expect(find.byKey(const Key('drawer-group-pinned')), findsNothing);
      await hold(tester, find.byKey(Key('chat-$first')));
      expect(find.text('Закрепить'), findsOneWidget);
      await tester.tap(find.byKey(const Key('session-menu-pin')));
      await tester.pumpAndSettle();
      final pinned = find.byKey(const Key('drawer-group-pinned'));
      expect(pinned, findsOneWidget);
      expect(
        tester.getRect(find.byKey(Key('chat-$first'))).top,
        lessThan(
          tester.getRect(find.byKey(const Key('drawer-group-today'))).top,
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      final saved = (await store.loadIndex())
          .singleWhere((ChatThread t) => t.id == first);
      expect(saved.pinned, isTrue);
      // Правая кнопка мыши на компьютере — то же меню.
      await tester.tap(find.byKey(Key('chat-$first')), buttons: 2);
      await tester.pumpAndSettle();
      expect(find.text('Открепить'), findsOneWidget);
      await tester.tap(find.byKey(const Key('session-menu-pin')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('drawer-group-pinned')), findsNothing);
    });

    testWidgets('удалить открытую: открыта новая пустая, меню не закрылось',
        (tester) async {
      final store = InMemoryChatStore();
      await _pump(tester, chats: store, size: const Size(390, 844));
      await _say(tester, '2+2');
      final id = onlySessionId(store.chatIds);
      await hold(tester, find.byKey(Key('chat-$id')));
      await tester.tap(find.byKey(const Key('session-menu-delete')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('delete-text'))).data,
        'Удалить сессию «2+2»? Это нельзя отменить.',
      );
      // «Отмена» — ничего не удалено.
      await tester.tap(find.byKey(const Key('delete-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('chat-$id')), findsOneWidget);
      await hold(tester, find.byKey(Key('chat-$id')));
      await tester.tap(find.byKey(const Key('session-menu-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('chat-$id')), findsNothing);
      expect(find.byKey(const Key('app-sidebar')), findsOneWidget);
      expect(store.chatIds, isEmpty);
      expect(store.archivedIds, isEmpty);
      await tester.tapAt(const Offset(380, 400));
      await tester.pumpAndSettle();
      expect(_history(tester), isEmpty, reason: 'открыта пустая сессия');
      expect(find.byKey(const Key('session-hero')), findsOneWidget);
    });

    testWidgets('удалили сессию, где создали задачу: ссылки «из сессии» нет',
        (tester) async {
      final store = InMemoryChatStore();
      final h = await _pump(tester, chats: store);
      await _say(tester, 'Добавь задачу «Купить хлеб»');
      final bread = await h.byTitle('Купить хлеб');
      final id =
          store.chatIds.singleWhere((String c) => c.startsWith('session:'));
      await _openFromTasks(tester, bread);
      expect(find.byKey(const Key('chat-origin-link')), findsOneWidget);
      await hold(tester, find.byKey(Key('chat-$id')));
      await tester.tap(find.byKey(const Key('session-menu-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-confirm')));
      await tester.pumpAndSettle();
      expect(_headerTitle(tester), 'Купить хлеб', reason: 'чат задачи открыт');
      expect(find.byKey(const Key('chat-origin-link')), findsNothing);
      expect(_history(tester), isNotEmpty, reason: 'копии в чате задачи целы');
    });

    testWidgets('удалить переписку задачи: задача остаётся, чат — пустой',
        (tester) async {
      final store = InMemoryChatStore();
      final h = await _pump(tester, chats: store);
      await _say(tester, 'Добавь задачу «Купить хлеб»');
      final bread = await h.byTitle('Купить хлеб');
      // Своя реплика в чате задачи — у него появляется строка в меню.
      await _openFromTasks(tester, bread);
      await _say(tester, 'спасибо');
      final row = find.byKey(Key('chat-${bread.id}'));
      await hold(tester, row);
      expect(find.byKey(const Key('session-menu-rename')), findsNothing);
      await tester.tap(find.byKey(const Key('session-menu-delete')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('delete-text'))).data,
        'Удалить сессию «Купить хлеб»? Это нельзя отменить. '
        'Задача останется.',
      );
      await tester.tap(find.byKey(const Key('delete-confirm')));
      await tester.pumpAndSettle();
      expect(row, findsNothing);
      expect((await h.byTitle('Купить хлеб')).isActive, isTrue);
      expect(store.chatIds, isNot(contains('task:${bread.id}')));
      // Ссылка из сессии на чат задачи по-прежнему открывает его — пустым.
      await _openFromTasks(tester, bread);
      expect(_headerTitle(tester), 'Купить хлеб');
      expect(_history(tester), isEmpty);
    });
  });

  group('логика сессий (аудит чатов)', () {
    Future<void> hold(WidgetTester tester, Finder row) async {
      await openDrawerIfNeeded(tester);
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.longPress(row);
      await tester.pumpAndSettle();
    }

    String? headerTitle(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const Key('session-title-text'))).data;

    Future<void> openHeaderMenu(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('session-title')));
      await tester.pumpAndSettle();
    }

    testWidgets('шапка: название сессии, меню — переименовать', (
      tester,
    ) async {
      final store = InMemoryChatStore();
      await _pump(tester, chats: store, size: const Size(390, 844));
      await _say(tester, '2+2');
      expect(headerTitle(tester), '2+2');
      final id = onlySessionId(store.chatIds);
      await openHeaderMenu(tester);
      await tester.tap(find.byKey(const Key('session-menu-rename')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('rename-field')), 'Счёт');
      await tester.pump();
      await tester.tap(find.byKey(const Key('rename-save')));
      await tester.pumpAndSettle();
      expect(headerTitle(tester), 'Счёт');
      await openDrawerIfNeeded(tester);
      expect(
        find.descendant(
          of: find.byKey(Key('chat-$id')),
          matching: find.text('Счёт'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('my-relay')), findsNothing);
    });

    for (final size in <Size>[const Size(390, 844), _desktop]) {
      testWidgets(
          'задача в фокусе (${size.width.toInt()} px): меню сессии в шапке '
          'остаётся', (tester) async {
        final store = InMemoryChatStore();
        await _pump(tester, chats: store, size: size);
        await _say(
          tester,
          'Добавь задачу купить краску завтра в 10 #ремонт',
        );
        // Новая задача выбрана («её»): в шапке «Задачи › «её»» и рядом —
        // меню сессии.
        expect(find.byKey(const Key('selected-task-strip')), findsWidgets);
        expect(find.byKey(const Key('session-title')), findsOneWidget);
        await openHeaderMenu(tester);
        expect(find.byKey(const Key('session-menu-rename')), findsOneWidget);
        expect(find.byKey(const Key('session-menu-delete')), findsOneWidget);
        await tester.tap(find.byKey(const Key('session-menu-rename')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('rename-field')), 'Ремонт');
        await tester.pump();
        await tester.tap(find.byKey(const Key('rename-save')));
        await tester.pumpAndSettle();
        final id = onlySessionId(store.chatIds);
        await openDrawerIfNeeded(tester);
        expect(
          find.descendant(
            of: find.byKey(Key('chat-$id')),
            matching: find.text('Ремонт'),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('шапка: «Удалить» — открыта пустая сессия', (tester) async {
      final store = InMemoryChatStore();
      await _pump(tester, chats: store);
      await _say(tester, '2+2');
      await openHeaderMenu(tester);
      await tester.tap(find.byKey(const Key('session-menu-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-confirm')));
      await tester.pumpAndSettle();
      expect(headerTitle(tester), 'Новая сессия');
      expect(find.byKey(const Key('session-hero')), findsOneWidget);
      expect(store.chatIds, isEmpty);
    });

    testWidgets('шапка: подписан тот, кто отвечает в этой сессии', (
      tester,
    ) async {
      await _pump(tester);
      String persona() => tester
          .widget<Text>(
            find
                .descendant(
                  of: find.byKey(const Key('session-persona')),
                  matching: find.byType(Text),
                )
                .last,
          )
          .data!;
      expect(persona(), 'Связной');
      await _say(tester, 'Нода, 2+2');
      expect(_history(tester).last, startsWith('noda: '));
      expect(persona(), 'Нода');
      // Новая сессия — снова тот, кто ответит по составу.
      await tapInDrawer(tester, const Key('new-session'));
      expect(persona(), 'Связной');
    });

    testWidgets('поиск открывает сессию у найденного сообщения', (
      tester,
    ) async {
      await _pump(tester, size: const Size(390, 844));
      await _say(tester, '1+1');
      await _say(tester, 'черника');
      for (var i = 2; i < 18; i++) {
        await _say(tester, '$i+$i');
      }
      await tapInDrawer(tester, const Key('new-session'));
      expect(find.byKey(const Key('session-hero')), findsOneWidget);
      await openDrawerIfNeeded(tester);
      await tester.tap(find.byKey(const Key('session-search')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('session-search')),
        'черника',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      final hit = find.byWidgetPredicate(
        (Widget w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('search-hit-'),
      );
      expect(hit, findsOneWidget);
      await tester.tap(hit);
      await tester.pumpAndSettle();
      final row = find.byWidgetPredicate(
        (Widget w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('msg-'),
      );
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('черника')),
        findsOneWidget,
      );
      // Строка видна на экране, а не внизу ленты за краем.
      final rect = tester.getRect(row);
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(844));
      expect(find.text('17+17'), findsNothing, reason: 'низ ленты ушёл');
    });

    testWidgets('ответ в другой сессии: заставка и честное «дождитесь»', (
      tester,
    ) async {
      final repository = _SlowRepository();
      await _pump(tester, repository: repository);
      repository.delay = const Duration(seconds: 2);
      await tester.enterText(
        find.byKey(const Key('assistant-input')),
        'добавь задачу купить хлеб',
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      await tester.tap(find.byKey(const Key('new-session')));
      await tester.pump();
      expect(
        find.byKey(const Key('session-hero')),
        findsOneWidget,
        reason: 'новая сессия — с заставкой, хоть ответ и готовится',
      );
      await tester.enterText(find.byKey(const Key('assistant-input')), '2+2');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(find.text('Дождитесь ответа в другой сессии'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('assistant-input')))
            .controller!
            .text,
        '2+2',
        reason: 'текст не пропал',
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      await _say(tester, '2+2');
      expect(_history(tester).first, 'user: 2+2');
    });

    testWidgets('↑ в поле ввода — команды этой сессии, а не всех', (
      tester,
    ) async {
      await _pump(tester);
      await _say(tester, '2+2');
      await tapInDrawer(tester, const Key('new-session'));
      final input = find.byKey(const Key('assistant-input'));
      String text() => tester.widget<TextField>(input).controller!.text;
      await tester.tap(input);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(text(), isEmpty, reason: 'в новой сессии команд нет');
      await _say(tester, '3+3');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(text(), '3+3');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(text(), '3+3', reason: '«2+2» — из другой сессии');
      await openSessionTitled(tester, '2+2');
      await tester.tap(input);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(text(), '2+2');
    });

    testWidgets('удалили открытую сессию из панели — раздел «Задачи» открыт', (
      tester,
    ) async {
      final store = InMemoryChatStore();
      await _pump(tester, chats: store);
      await _say(tester, '2+2');
      final id = onlySessionId(store.chatIds);
      await tapInDrawer(tester, const Key('nav-tasks'));
      expect(find.byKey(const Key('tasks-panel')), findsOneWidget);
      await hold(tester, find.byKey(Key('chat-$id')));
      await tester.tap(find.byKey(const Key('session-menu-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-confirm')));
      await tester.pumpAndSettle();
      expect(store.chatIds, isEmpty);
      expect(find.byKey(const Key('tasks-panel')), findsOneWidget);
    });

    testWidgets('сессии сверх 50 — «Показать ещё»', (tester) async {
      final store = InMemoryChatStore();
      final clock = _Clock(DateTime(2026, 11, 4, 12));
      final book = ChatBook(store: store, clock: clock);
      await book.load();
      final ids = <String>[];
      for (var i = 0; i < 55; i++) {
        clock.value = DateTime(2026, 11, 4, 11).subtract(Duration(hours: i));
        await book.newSession();
        book.append(
          book.currentId,
          ChatMessage(
            id: book.newMessageId(),
            author: ChatAuthor.user,
            text: 'команда $i',
            timestamp: DateTime(2026, 11, 4, 11).subtract(Duration(hours: i)),
          ),
        );
        ids.add(book.currentId);
      }
      await book.flush();
      await _pump(tester, chats: store, size: const Size(390, 844));
      await openDrawerIfNeeded(tester);
      final more = find.byKey(const Key('sessions-more'));
      final scrollable = find
          .descendant(
            of: find.byKey(const Key('drawer-scroll')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(more, 400, scrollable: scrollable);
      // 55 сессий и открытая пустая: 50 видно, 6 — за «ещё».
      expect(
        find.descendant(of: more, matching: find.text('Показать ещё 6')),
        findsOneWidget,
      );
      expect(find.byKey(Key('chat-${ids.last}')), findsNothing);
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(more, findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(Key('chat-${ids.last}')),
        400,
        scrollable: scrollable,
      );
      expect(find.byKey(Key('chat-${ids.last}')), findsOneWidget);
    });
  });
}

/// Хранилище, у которого запись заканчивается по команде теста.
final class _GatedStore implements ChatStore {
  final InMemoryChatStore _inner = InMemoryChatStore();
  final Completer<void> gate = Completer<void>();
  int flushes = 0;

  @override
  Future<List<ChatThread>> loadIndex() => _inner.loadIndex();

  @override
  Future<List<ChatMessage>> loadMessages(String chatId) =>
      _inner.loadMessages(chatId);

  @override
  Future<void> save(ChatThread thread) => _inner.save(thread);

  @override
  Future<void> delete(String chatId) => _inner.delete(chatId);

  @override
  Future<void> erase(String chatId) => _inner.erase(chatId);

  @override
  Future<void> clearAll() => _inner.clearAll();

  @override
  Future<List<ChatProject>> loadProjects() => _inner.loadProjects();

  @override
  Future<void> saveProjects(List<ChatProject> projects) =>
      _inner.saveProjects(projects);

  @override
  AttachmentStore get attachments => _inner.attachments;

  @override
  Future<void> flush() {
    flushes++;
    return gate.future;
  }
}
