// Оболочка «Д»: регрессии после ревью — свой выбор («её») у каждой сессии,
// живой архив в «Данных», шапка и «пилюли» на широком экране, подпись
// «Сегодня» и «Диалог / Документ» на телефоне, год активности без
// обрезки, строка статистики и вкладки «Мой Связной», Ctrl+K, «назад» при
// открытом меню, кнопки для диктора.
import 'package:flutter/material.dart';
import 'dart:ui' show Tristate;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
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

import 'support/app_fonts.dart';
import 'support/home_nav.dart';

final _clock = FixedClock(DateTime(2026, 11, 9, 12, 40));

Future<(TaskService, AssistantController)> _pump(
  WidgetTester tester, {
  Size size = const Size(390, 844),
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
        settingsStore: InMemorySettingsStore(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (tasks, assistant);
}

Future<void> _say(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('assistant-input')), text);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

/// Кнопки для диктора без действия «нажать»: такие нельзя нажать
/// двойным касанием в TalkBack и VoiceOver.
List<String> _buttonsWithoutTap(WidgetTester tester) {
  final missing = <String>[];
  void visit(SemanticsNode node) {
    final data = node.getSemanticsData();
    final disabled = data.flagsCollection.isEnabled == Tristate.isFalse;
    if (data.flagsCollection.isButton &&
        !disabled &&
        !data.hasAction(SemanticsAction.tap)) {
      missing.add(data.label);
    }
    node.visitChildren((SemanticsNode child) {
      visit(child);
      return true;
    });
  }

  visit(
    tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!,
  );
  return missing;
}

void main() {
  // Ширина подписей и вкладок — по настоящим шрифтам приложения.
  setUpAll(loadAppFonts);

  testWidgets('задача из одной сессии — не «её» в главном и в другой сессии',
      (tester) async {
    final (tasks, assistant) = await _pump(tester);
    await _say(tester, 'привет');
    await tapInDrawer(tester, const Key('new-session'));
    await _say(tester, 'добавь задачу купить хлеб');
    final bread = (await tasks.listActive()).single;
    expect(assistant.selectedTaskId, bread.id);

    await tapInDrawer(tester, const Key('chat-main'));
    expect(assistant.selectedTaskId, isNull);
    expect(find.byKey(const Key('quick-Заверши её')), findsNothing);
    await _say(tester, 'Заверши её');
    expect((await tasks.listActive()).single.id, bread.id, reason: 'не done');

    // Вернулись в ту сессию — её задача снова «её».
    await openDrawerIfNeeded(tester);
    await tester.tap(
      find.byWidgetPredicate(
        (Widget w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('chat-session:'),
      ),
    );
    await tester.pumpAndSettle();
    expect(assistant.selectedTaskId, bread.id);
  });

  testWidgets('«Данные»: «Вернуть» из архива сразу обновляет список',
      (tester) async {
    final (tasks, _) = await _pump(tester);
    final task = await tasks.create(title: 'Сверить накладные');
    await tasks.complete(task.id);
    await _say(tester, 'привет');
    await openSettings(tester);
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('settings-storage')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('settings-storage')));
    await tester.pumpAndSettle();
    final archived = find.byKey(ValueKey<String>('archive-${task.id}'));
    expect(archived, findsOneWidget);
    expect(find.text('Архив выполненных · 1'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey<String>('toggle-${task.id}')));
    await tester.pumpAndSettle();
    expect(await tasks.listCompleted(), isEmpty);
    expect(archived, findsNothing, reason: 'архив не устарел');
    expect(find.text('Архив выполненных · 0'), findsOneWidget);
  });

  testWidgets('широкий экран: «Сегодня» у правого края, «пилюли» по тексту',
      (tester) async {
    await _pump(tester, size: const Size(1440, 900));
    await _say(tester, 'привет');
    final header = tester.getRect(find.byKey(const Key('session-subtitle')));
    final today = tester.getRect(find.byKey(const Key('today-button')));
    final column = tester.getRect(find.byKey(const Key('assistant-composer')));
    expect(today.left, greaterThan(header.right));
    expect(
      today.right,
      greaterThan(column.right - 40),
      reason: 'кнопка прижата вправо, без пустоты после неё',
    );
    final pill = tester.getSize(find.byKey(const Key('quick-Задача')));
    expect(pill.height, 44);
    expect(pill.width, lessThan(200), reason: 'своей ширины, не на треть');
    expect(find.byKey(const Key('quick-pills-centered')), findsOneWidget);
  });

  testWidgets('телефон 390: подписи «Сегодня», «Диалог» и «Документ» видны',
      (tester) async {
    await _pump(tester);
    expect(
      find.descendant(
        of: find.byKey(const Key('today-button')),
        matching: find.text('Сегодня'),
      ),
      findsOneWidget,
    );
    expect(find.text('Диалог'), findsOneWidget);
    expect(find.text('Документ'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('телефон 320: только иконки, без переполнений', (tester) async {
    await _pump(tester, size: const Size(320, 640));
    expect(
      find.descendant(
        of: find.byKey(const Key('today-button')),
        matching: find.text('Сегодня'),
      ),
      findsNothing,
    );
    expect(find.text('Диалог'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('«Мой Связной» на компьютере: без «Сегодня», год целиком',
      (tester) async {
    await _pump(tester, size: const Size(1440, 900));
    expect(find.byKey(const Key('today-panel')), findsOneWidget);
    await tester.tap(find.byKey(const Key('drawer-my-relay')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('today-panel')), findsNothing);
    final scroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const Key('activity-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scroll.position.maxScrollExtent, 0, reason: '52 недели помещаются');
    // «Ср» не обрезана клеткой 12: подпись своей высоты.
    final label = find.byKey(const Key('activity-weekday-2'));
    expect(tester.getSize(label).height, greaterThan(12));
    // Вернулись в сессию — колонка «Сегодня» снова на месте.
    await tester.tap(find.byKey(const Key('chat-main')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('today-panel')), findsOneWidget);
  });

  testWidgets('«Мой Связной» на телефоне: статистика парами, вкладки-сегменты',
      (tester) async {
    await _pump(tester);
    await tapInDrawer(tester, const Key('drawer-my-relay'));
    final stats = find.byKey(const Key('my-relay-stats'));
    final lines = find.descendant(of: stats, matching: find.byType(RichText));
    expect(lines, findsNWidgets(2));
    expect(
      tester.widget<RichText>(lines.first).text.toPlainText(),
      startsWith('Вместе'),
    );
    expect(
      tester.widget<RichText>(lines.last).text.toPlainText(),
      startsWith('задач закрыто'),
    );
    final avatars = tester.getRect(find.byType(RelayAvatars).first);
    expect(
      tester.getRect(stats).top,
      greaterThan(avatars.bottom - 1),
      reason: 'своими строками под шапкой',
    );
    final first = tester.getRect(find.byKey(const Key('my-relay-tab-summary')));
    expect(first.left, greaterThanOrEqualTo(16), reason: 'отступ слева');
    // Не поместились — прокручиваются, и последняя тоже с отступом 16.
    await tester.drag(
      find.byKey(const Key('my-relay-tabs')),
      const Offset(-400, 0),
    );
    await tester.pumpAndSettle();
    final last = tester.getRect(find.byKey(const Key('my-relay-tab-settings')));
    expect(last.right, lessThanOrEqualTo(390 - 16 + 0.5));
    expect(first.height, 44);
    await tester.tap(find.byKey(const Key('my-relay-tab-settings')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('settings-storage')),
      findsWidgets,
    );
  });

  testWidgets('Ctrl+K сразу после запуска и после Esc ставит курсор в поиск',
      (tester) async {
    await _pump(tester, size: const Size(1440, 900));
    FocusNode searchFocus() => tester
        .widget<TextField>(find.byKey(const Key('session-search')))
        .focusNode!;

    Future<void> ctrlK() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    await ctrlK();
    expect(searchFocus().hasFocus, isTrue, reason: 'после запуска');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(searchFocus().hasFocus, isFalse);
    await ctrlK();
    expect(searchFocus().hasFocus, isTrue, reason: 'после Esc');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-tasks')));
    await tester.pumpAndSettle();
    await ctrlK();
    expect(searchFocus().hasFocus, isTrue, reason: 'после «Задач»');
  });

  testWidgets('«назад» при открытом меню только закрывает меню',
      (tester) async {
    await _pump(tester);
    await tapInDrawer(tester, const Key('nav-tasks'));
    expect(find.byKey(const Key('assistant-composer')), findsNothing);
    await openDrawerIfNeeded(tester);
    expect(find.byKey(const Key('app-sidebar')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsNothing);
    expect(
      find.byKey(const Key('assistant-composer')),
      findsNothing,
      reason: 'остались в «Задачах»',
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('assistant-composer')), findsOneWidget);
  });

  testWidgets('меню открыто, окно стало широким — «назад» ведёт в сессию',
      (tester) async {
    await _pump(tester, size: const Size(800, 900));
    await tapInDrawer(tester, const Key('nav-tasks'));
    await openDrawerIfNeeded(tester);
    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();
    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(handled, isTrue);
    expect(find.byKey(const Key('assistant-composer')), findsOneWidget);
  });

  testWidgets('кнопки оболочки нажимаются из диктора', (tester) async {
    final handle = tester.ensureSemantics();
    final (tasks, _) = await _pump(tester);
    await tasks.create(title: 'Позвонить', dueAt: DateTime(2026, 11, 9, 16));
    await _say(tester, 'привет');
    expect(_buttonsWithoutTap(tester), isEmpty, reason: 'сессия');
    await openDrawerIfNeeded(tester);
    expect(_buttonsWithoutTap(tester), isEmpty, reason: 'меню');
    await tester.tap(find.byKey(const Key('drawer-my-relay')));
    await tester.pumpAndSettle();
    expect(_buttonsWithoutTap(tester), isEmpty, reason: '«Мой Связной»');
    await tester.tap(find.byKey(const Key('my-relay-back')));
    await tester.pumpAndSettle();
    await openToday(tester);
    expect(_buttonsWithoutTap(tester), isEmpty, reason: '«Сегодня»');
    handle.dispose();
  });
}
