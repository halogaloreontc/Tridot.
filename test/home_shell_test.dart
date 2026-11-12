// Оболочка «Д» на главном экране: «Лиорио ▾» → «Мой Связной · Помощники»,
// «+» (новая сессия), «Сегодня» — колонкой на компьютере и «Сводкой» на
// телефоне, свайп вправо по сессии открывает меню, хроника команд под
// шапкой, чистый «Документ», поиск по сессиям из меню, телефон и крупный
// шрифт без переполнений.
import 'package:flutter/gestures.dart';
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

  testWidgets(
      'телефон: кнопки и панели «Сегодня» нет — всё в «Мой Связной» → '
      '«Сводка», сегодняшние не обрезаются', (tester) async {
    final tasks = await _pump(tester);
    await tasks.create(title: 'Позвонить', dueAt: DateTime(2026, 11, 9, 11));
    for (var i = 1; i <= 6; i++) {
      await tasks.create(
        title: 'Сверить $i',
        dueAt: DateTime(2026, 11, 9, 13 + i),
      );
    }
    await tasks.create(title: 'Потом', dueAt: DateTime(2026, 11, 12));
    await _say(tester, 'привет');
    expect(find.byKey(const Key('today-button')), findsNothing);
    expect(find.byKey(const Key('today-show')), findsNothing);
    expect(find.byKey(const Key('today-panel')), findsNothing);
    await openSummary(tester);
    expect(
      tester.widget<Text>(find.byKey(const Key('summary-today'))).data,
      'сегодня: просрочена 1 задача',
    );
    expect(find.text('11:00, просрочено'), findsOneWidget);
    // Все 7 дел на сегодня — больше пяти, и ни одно не обрезано; «Потом»
    // — следом.
    for (final task in await tasks.listActive()) {
      expect(
        find.byKey(Key('next-task-${task.id}')),
        findsOneWidget,
        reason: task.title,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('свайп вправо по сессии открывает меню, влево — закрывает',
      (tester) async {
    await _pump(tester);
    // От края — как раньше (жест Scaffold).
    await tester.dragFrom(const Offset(4, 400), const Offset(260, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsOneWidget);
    await tester.tapAt(const Offset(380, 400));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsNothing);
    // С середины пустой сессии.
    await tester.dragFrom(const Offset(160, 300), const Offset(160, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsOneWidget);
    // Влево по открытому меню — закрывается.
    await tester.dragFrom(const Offset(250, 400), const Offset(-240, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsNothing);
    // Влево по сессии — ничего: справа панели больше нет.
    await tester.dragFrom(const Offset(380, 300), const Offset(-280, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsNothing);
    expect(find.byKey(const Key('today-panel')), findsNothing);
  });

  testWidgets(
      'свайп по ленте и тексту сообщения — меню; вертикальный — прокрутка',
      (tester) async {
    await _pump(tester);
    for (var i = 0; i < 12; i++) {
      await _say(tester, 'запомни: строка $i');
    }
    // Свайп, начатый на тексте сообщения (SelectableText), открывает меню.
    final bubble = find.text('запомни: строка 11').first;
    await tester.dragFrom(
      tester.getCenter(bubble) - const Offset(60, 0),
      const Offset(180, 0),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsOneWidget);
    await tester.tapAt(const Offset(380, 400));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsNothing);
    // Прокрутка ленты вверх-вниз меню не открывает.
    final list = find.byKey(const Key('chat-list'));
    final scroll = tester.state<ScrollableState>(
      find.descendant(of: list, matching: find.byType(Scrollable)).first,
    );
    await tester.drag(list, const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, greaterThan(0));
    expect(find.byKey(const Key('app-sidebar')), findsNothing);
  });

  testWidgets('палец задержали, потом повели — это выделение, а не свайп',
      (tester) async {
    await _pump(tester);
    await _say(tester, 'запомни: длинная строка для выделения');
    final bubble = find.text('запомни: длинная строка для выделения').first;
    final gesture = await tester.startGesture(
      tester.getCenter(bubble) - const Offset(80, 0),
    );
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(120, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsNothing);
  });

  testWidgets('свайп по полю ввода меню не открывает', (tester) async {
    await _pump(tester);
    await tester.enterText(
      find.byKey(const Key('assistant-input')),
      'длинный черновик команды',
    );
    await tester.pump();
    final field = tester.getRect(find.byKey(const Key('assistant-input')));
    await tester.dragFrom(
      Offset(field.left + 20, field.center.dy),
      const Offset(200, 0),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsNothing);
    // И по кнопкам под полем — тоже.
    final send = tester.getRect(find.byKey(const Key('assistant-composer')));
    await tester.dragFrom(
      Offset(send.left + 8, send.bottom - 8),
      const Offset(200, 0),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsNothing);
  });

  testWidgets('свайп в «Документе» тоже открывает меню', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const Key('mode-document')));
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(120, 300), const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsOneWidget);
  });

  testWidgets(
      '«Документ» задачи: свайп по тексту документа открывает меню, по полю '
      'с курсором — нет', (tester) async {
    await _pump(tester);
    await _say(tester, 'добавь задачу сверить приход 318');
    await tester.tap(find.byKey(const Key('mode-document')));
    await tester.pumpAndSettle();
    final editor = find.byKey(const Key('document-editor'));
    final body = tester.getRect(editor);
    final start = Offset(120, body.center.dy);
    await tester.dragFrom(start, const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsOneWidget);
    await tester.tapAt(const Offset(380, 400));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsNothing);
    // В поле поставили курсор — палец там двигает курсор и выделение.
    await tester.tap(editor);
    await tester.pumpAndSettle();
    await tester.dragFrom(
      Offset(120, tester.getRect(editor).top + 30),
      const Offset(200, 0),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsNothing);
  });

  testWidgets('между краем Scaffold и свайпом нет «мёртвой» полосы',
      (tester) async {
    await _pump(tester);
    for (final x in <double>[4, 20, 23.5, 24, 26, 28, 30, 120]) {
      await tester.dragFrom(Offset(x, 400), const Offset(200, 0));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('app-sidebar')),
        findsOneWidget,
        reason: '$x',
      );
      await tester.tapAt(const Offset(380, 400));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-sidebar')), findsNothing, reason: '$x');
    }
  });

  testWidgets('компьютер: перетаскивание мышью меню не открывает',
      (tester) async {
    await _pump(tester, size: const Size(1100, 800));
    await tester.tap(find.byKey(const Key('sidebar-collapse')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsNothing);
    await tester.dragFrom(
      const Offset(300, 300),
      const Offset(300, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsNothing);
  });

  testWidgets(
      'хроника команд — под шапкой по центру, поле ввода — во всю колонку',
      (tester) async {
    await _pump(tester);
    expect(find.byKey(const Key('history-rail')), findsNothing);
    for (final text in <String>['привет', '2+2', 'запомни: хлеб']) {
      await _say(tester, text);
    }
    final rail = tester.getRect(find.byKey(const Key('history-rail')));
    final header = tester.getRect(find.byKey(const Key('persona-switch')));
    expect(rail.top, greaterThanOrEqualTo(header.bottom));
    expect(rail.top, lessThan(56 + 8));
    expect(rail.height, greaterThanOrEqualTo(44));
    expect(rail.center.dx, moreOrLessEquals(195, epsilon: 1));
    expect(find.byKey(const Key('history-2')), findsOneWidget);
    // Поле ввода — от отступа до отступа, места справа под хронику нет.
    final composer =
        tester.getRect(find.byKey(const Key('assistant-composer')));
    expect(composer.left, moreOrLessEquals(16, epsilon: 1));
    expect(composer.right, moreOrLessEquals(390 - 16, epsilon: 1));
    // На телефоне хроника — кнопка «Хроника команд».
    await tester.tap(find.byKey(const Key('history-rail-open')));
    await tester.pumpAndSettle();
    expect(find.text('Хроника команд'), findsOneWidget);
    expect(find.byKey(const Key('history-item-0')), findsOneWidget);
    await tester.tap(find.byKey(const Key('history-item-0')));
    await tester.pumpAndSettle();
    expect(find.text('Хроника команд'), findsNothing);
  });

  testWidgets('телефон: одна-две команды — кнопка хроники не уже 44 px',
      (tester) async {
    await _pump(tester);
    for (final text in <String>['привет', '2+2']) {
      await _say(tester, text);
      final button = tester.getSize(find.byKey(const Key('history-rail-open')));
      expect(button.width, greaterThanOrEqualTo(44), reason: text);
      expect(button.height, greaterThanOrEqualTo(44), reason: text);
    }
    final button = tester.getRect(find.byKey(const Key('history-rail-open')));
    expect(button.center.dx, moreOrLessEquals(195, epsilon: 1));
  });

  testWidgets('планшет пальцем (800 px): хроника — одна кнопка списка',
      (tester) async {
    await _pump(tester, size: const Size(800, 1100));
    for (final text in <String>['привет', '2+2', 'запомни: хлеб']) {
      await _say(tester, text);
    }
    final button = tester.getSize(find.byKey(const Key('history-rail-open')));
    expect(button.width, greaterThanOrEqualTo(44));
    expect(button.height, greaterThanOrEqualTo(44));
    await tester.tap(find.byKey(const Key('history-rail-open')));
    await tester.pumpAndSettle();
    expect(find.text('Хроника команд'), findsOneWidget);
  });

  testWidgets(
      'компьютер: 40 команд — «+N» и кнопка списка открывают «Хроника '
      'команд» со всеми, старая команда достижима', (tester) async {
    await _pump(tester, size: const Size(1440, 900));
    for (var i = 0; i < 40; i++) {
      await _say(tester, '$i+1');
    }
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('history-rail-open')), findsNothing);
    expect(find.byKey(const Key('history-0')), findsNothing);
    final list = find.byKey(const Key('history-rail-list'));
    final size = tester.getSize(list);
    expect(size.width, greaterThanOrEqualTo(44));
    expect(size.height, greaterThanOrEqualTo(44));
    expect(
      find.bySemanticsLabel(RegExp('Хроника команд: 40')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'Ещё \d+ команд')),
      findsOneWidget,
    );
    // «+N» — тоже кнопка списка.
    await tester.tap(find.byKey(const Key('history-more-open')));
    await tester.pumpAndSettle();
    expect(find.text('Хроника команд'), findsOneWidget);
    // Самая старая — в конце списка: долистать пальцем.
    final sheet = find.byType(BottomSheet);
    await tester.dragUntilVisible(
      find.byKey(const Key('history-item-0')),
      sheet,
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    final item = tester.getRect(find.byKey(const Key('history-item-0')));
    expect(item.bottom, lessThanOrEqualTo(900));
    await tester.tap(find.byKey(const Key('history-item-0')));
    await tester.pumpAndSettle();
    expect(find.text('Хроника команд'), findsNothing);
    expect(find.text('0+1'), findsOneWidget);
    // Кнопка списка справа от полос.
    await tester.tap(list);
    await tester.pumpAndSettle();
    expect(find.text('Хроника команд'), findsOneWidget);
  });

  testWidgets('много команд на 320 px: хроника не переполняется, «+N»',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(tester, size: const Size(320, 640));
    for (var i = 0; i < 40; i++) {
      await _say(tester, '$i+1');
    }
    expect(tester.takeException(), isNull);
    final rail = tester.getRect(find.byKey(const Key('history-rail')));
    expect(rail.left, greaterThanOrEqualTo(0));
    expect(rail.right, lessThanOrEqualTo(320));
    expect(find.byKey(const Key('history-more')), findsOneWidget);
    expect(find.byKey(const Key('history-39')), findsOneWidget);
    expect(find.byKey(const Key('history-0')), findsNothing);
  });

  testWidgets(
      '«Документ» чистый: документ, поле ввода и хроника; ответ — '
      'уведомлением и в истории', (tester) async {
    await _pump(tester);
    await _say(tester, 'привет');
    await tester.tap(find.byKey(const Key('mode-document')));
    await tester.pumpAndSettle();
    expect(
      find.text('Документ открывается для выбранной задачи.'),
      findsOneWidget,
    );
    for (final key in <String>[
      'chat-list',
      'quick-actions',
      'quick-rows',
      'quick-strip',
      'addressee-switch',
    ]) {
      expect(find.byKey(Key(key)), findsNothing, reason: key);
    }
    // Последнего ответа под документом больше нет.
    expect(find.textContaining('Я готов к работе'), findsNothing);
    expect(find.byKey(const Key('history-rail')), findsOneWidget);
    expect(find.byKey(const Key('assistant-composer')), findsOneWidget);

    await _say(tester, 'покажи задачи');
    final toast = find.byKey(const Key('doc-reply-toast'));
    expect(toast, findsOneWidget);
    final reply = tester
        .widget<Text>(
          find.descendant(of: toast, matching: find.byType(Text)).first,
        )
        .data!;
    expect(reply, isNot('Ответ в диалоге'));
    expect(reply, contains('задач'));
    // Уведомление не закрывает поле ввода.
    expect(
      tester.getRect(toast).bottom,
      lessThanOrEqualTo(
        tester.getRect(find.byKey(const Key('assistant-composer'))).top,
      ),
    );
    expect(find.byKey(const Key('document-view')), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    expect(toast, findsNothing);
    await tester.tap(find.byKey(const Key('mode-dialogue')));
    await tester.pumpAndSettle();
    // Ответ — в истории сессии.
    expect(find.text(reply), findsWidgets);
    expect(find.text('покажи задачи'), findsWidgets);
  });

  testWidgets(
      '«+»: пустая сессия, «Что сделать?», «Задача» и «Напомнить» — только '
      'в ней, название — первая команда', (tester) async {
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
      find.byKey(const Key('quick-Задача')),
      findsNothing,
      reason: 'после первой команды «Задачи» и «Напомнить» нет',
    );
    expect(find.byKey(const Key('quick-Напомнить')), findsNothing);
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
    expect(find.byKey(const Key('today-show')), findsNothing);
    expect(find.byKey(const Key('today-button')), findsNothing);
    await tester.tap(find.byKey(const Key('today-collapse')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('today-panel')), findsNothing);
    // Свёрнута — маленькая кнопка у правого края шапки.
    final show = find.byKey(const Key('today-show'));
    expect(find.byTooltip('Показать «Сегодня»'), findsOneWidget);
    expect(tester.getRect(show).right, greaterThan(1440 - 24));
    await tester.tap(show);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('today-panel')), findsOneWidget);
    expect(show, findsNothing);
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
        'меню, «Мой Связной» и «Сводка» без переполнений', (tester) async {
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
      await openSummary(tester);
      expect(find.byKey(const Key('summary-today')), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '«Сводка»');
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
