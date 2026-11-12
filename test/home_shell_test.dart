// Оболочка «Д» на главном экране: «Лиорио ▾» → «Мой Связной · Помощники»,
// «+ Сессия», «Сегодня N» с точкой просрочки, жесты от краёв экрана, поиск
// по сессиям из меню, телефон и крупный шрифт без переполнений.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/app/screens/my_relay_screen.dart';
import 'package:local_assistant/app/shell/relay_drawer.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import 'support/home_nav.dart';

final _clock = FixedClock(DateTime(2026, 11, 9, 12, 40));

Future<TaskService> _pump(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  SettingsStore? settingsStore,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final tasks = TaskService(
    repository: InMemoryTaskRepository(),
    clock: _clock,
  );
  final assistant = AssistantController(
    connectors: <Connector>[
      TasksConnector(taskService: tasks, parser: ScenarioParser(clock: _clock)),
      TalkConnector(taskService: tasks),
    ],
    clock: _clock,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.dark(),
      home: HomePage(
        assistant: assistant,
        tasks: tasks,
        clock: _clock,
        settingsStore: settingsStore ?? InMemorySettingsStore(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return tasks;
}

Future<void> _say(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('assistant-input')), text);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('«Лиорио ▾» открывает «Мой Связной» на вкладке «Помощники»',
      (tester) async {
    await _pump(tester);
    expect(
      find.descendant(
        of: find.byKey(const Key('persona-switch')),
        matching: find.text('Лиорио'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('persona-switch')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('my-relay')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('main-persona-noda')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('assistants-journal-planned')), findsOneWidget);
    await tester.tap(find.byKey(const Key('my-relay-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('assistant-composer')), findsOneWidget);
  });

  testWidgets('«Сегодня N»: число, точка просрочки, панель справа',
      (tester) async {
    final tasks = await _pump(tester);
    await tasks.create(title: 'Позвонить', dueAt: DateTime(2026, 11, 9, 11));
    await tasks.create(title: 'Сверить', dueAt: DateTime(2026, 11, 9, 16));
    await tasks.create(title: 'Потом', dueAt: DateTime(2026, 11, 12));
    await _say(tester, 'привет');
    expect(
      tester.widget<Text>(find.byKey(const Key('today-count'))).data,
      '2',
    );
    expect(find.byKey(const Key('today-overdue-dot')), findsOneWidget);
    await openToday(tester);
    expect(find.byKey(const Key('today-panel')), findsOneWidget);
    expect(find.text('11:00, просрочено'), findsOneWidget);
    expect(find.text('Потом'), findsNothing);
  });

  testWidgets('жест от левого края — меню, от правого — «Сегодня»',
      (tester) async {
    await _pump(tester);
    await tester.dragFrom(const Offset(4, 400), const Offset(260, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsOneWidget);
    await tester.tapAt(const Offset(380, 400));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsNothing);
    await tester.dragFrom(const Offset(386, 400), const Offset(-280, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('today-panel')), findsOneWidget);
  });

  testWidgets(
      '«+ Сессия»: пустая сессия, «Что сделать?», название — '
      'первая команда', (tester) async {
    await _pump(tester);
    await _say(tester, 'привет');
    await tapInDrawer(tester, const Key('new-session'));
    expect(find.text('Что сделать?'), findsOneWidget);
    expect(find.byKey(const Key('session-hero')), findsOneWidget);
    // Крупные кнопки: подпись под кругом.
    expect(find.text('Задача'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('quick-Задача'))).width,
      76,
    );
    await _say(tester, 'Сверить накладные за ноябрь');
    expect(find.text('Что сделать?'), findsNothing);
    expect(
      tester.getSize(find.byKey(const Key('quick-Задача'))).height,
      44,
      reason: 'после команды — «пилюли»',
    );
    await openDrawerIfNeeded(tester);
    expect(find.text('Сверить накладные за ноябрь'), findsWidgets);
    expect(find.byKey(const Key('chat-main')), findsOneWidget);
    // Главный на месте, с прежней историей.
    await tester.tap(find.byKey(const Key('chat-main')));
    await tester.pumpAndSettle();
    expect(find.text('привет'), findsWidgets);
  });

  testWidgets('поиск по сессиям из меню открывает найденную', (tester) async {
    await _pump(tester, size: const Size(1300, 900));
    await _say(tester, 'запомни: приход 318 от поставщика');
    await tester.tap(find.byKey(const Key('new-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-search')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('session-search')), 'приход');
    await tester.pump(RelayDrawer.searchDelay);
    await tester.pumpAndSettle();
    expect(find.text('Найдено в сессиях · 1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('search-hit-main')));
    await tester.pumpAndSettle();
    expect(find.text('Что сделать?'), findsNothing, reason: 'открыт главный');
    expect(find.text('запомни: приход 318 от поставщика'), findsWidgets);
  });

  testWidgets('широкий экран: три колонки, «Сегодня» сворачивается',
      (tester) async {
    await _pump(tester, size: const Size(1440, 900));
    expect(find.byKey(const Key('app-sidebar')), findsOneWidget);
    expect(find.byKey(const Key('today-panel')), findsOneWidget);
    expect(find.byKey(const Key('menu-button')), findsNothing);
    expect(find.byKey(const Key('session-subtitle')), findsOneWidget);
    await tester.tap(find.byKey(const Key('today-collapse')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('today-panel')), findsNothing);
    await tester.tap(find.byKey(const Key('sidebar-collapse')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsNothing);
    await tester.tap(find.byKey(const Key('menu-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsOneWidget);
  });

  for (final size in const <Size>[Size(320, 640), Size(390, 844)]) {
    testWidgets(
        '${size.width.toInt()}x${size.height.toInt()}, шрифт 2x: шапка, '
        'меню, «Сегодня», «Мой Связной» без переполнений', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final tasks = await _pump(tester, size: size);
      await tasks.create(
        title: 'Позвонить поставщику про длинную накладную',
        dueAt: DateTime(2026, 11, 9, 11),
      );
      await _say(tester, 'Добавь задачу «Купить хлеб и молоко» на сегодня');
      expect(tester.takeException(), isNull, reason: 'сессия');
      await openDrawerIfNeeded(tester);
      expect(tester.takeException(), isNull, reason: 'меню');
      await tester.tap(find.byKey(const Key('session-search')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'поиск');
      await tester.tap(find.byKey(const Key('session-search-cancel')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('drawer-my-relay')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '«Мой Связной»');
      for (final tab in <String>['activity', 'assistants', 'settings']) {
        final target = find.byKey(Key('my-relay-tab-$tab'));
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: tab);
      }
      await backToSession(tester);
      final back = find.byKey(const Key('task-back'));
      if (back.evaluate().isNotEmpty) {
        await tester.tap(back);
        await tester.pumpAndSettle();
      }
      await openToday(tester);
      expect(find.byKey(const Key('today-panel')), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '«Сегодня»');
    });
  }

  testWidgets(
      '«Мой Связной»: строка статистики из локальных данных, первый день '
      'записан, «Настройки» — вкладкой', (tester) async {
    final store = InMemorySettingsStore();
    final tasks = await _pump(tester, settingsStore: store);
    expect((await store.load()).firstSeenDay, '2026-11-09');
    final task = await tasks.create(title: 'Сверить накладные');
    await tasks.complete(task.id);
    await _say(tester, 'привет');
    await tapInDrawer(tester, const Key('drawer-my-relay'));
    expect(
      tester
          .widget<RelayStatsLine>(find.byKey(const Key('my-relay-stats')))
          .stats,
      'Вместе 1 день · сессий 1 · задач закрыто 1 · серия 1 день',
    );
    expect(find.byKey(const Key('activity-grid')), findsOneWidget);
    // В меню нет шестерёнки настроек: они во вкладке.
    expect(find.byKey(const Key('nav-settings')), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('my-relay-tab-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('my-relay-tab-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-storage')), findsOneWidget);
  });
}
