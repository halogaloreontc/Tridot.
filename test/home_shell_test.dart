// Оболочка «Д» на главном экране: «Связной ▾» → «Мой Связной · Помощники»,
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
  testWidgets(
      'название сессии в шапке — меню сессии, а не настройки помощников',
      (tester) async {
    await _pump(tester);
    // Под названием — кто отвечает; пустую сессию меню не открывает.
    expect(
      find.descendant(
        of: find.byKey(const Key('session-title')),
        matching: find.text('Связной'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('session-title')),
        matching: find.text('Новая сессия'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('session-title')));
    await tester.pumpAndSettle();
    expect(find.text('Переименовать'), findsNothing);
    expect(find.byKey(const Key('my-relay')), findsNothing);

    await _say(tester, 'привет');
    await tester.tap(find.byKey(const Key('session-title')));
    await tester.pumpAndSettle();
    expect(find.text('Переименовать'), findsOneWidget);
    expect(find.text('Закрепить'), findsOneWidget);
    expect(find.text('Удалить'), findsOneWidget);
    expect(find.byKey(const Key('my-relay')), findsNothing);
    await tester.tapAt(const Offset(195, 600));
    await tester.pumpAndSettle();
    expect(find.text('Переименовать'), findsNothing);
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

  testWidgets(
      '«Мой Связной»: свайп вправо не от края открывает меню — край на '
      'Android забирает «Назад»', (tester) async {
    await _pump(tester);
    Future<void> swipeOpens(Offset from) async {
      await tester.dragFrom(from, const Offset(220, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-sidebar')), findsOneWidget);
      await tester.tapAt(const Offset(380, 400));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-sidebar')), findsNothing);
    }

    await openMyRelay(tester);
    // «Сводка» — первая вкладка: с середины экрана.
    await swipeOpens(const Offset(150, 400));
    for (final tab in <String>['assistants', 'settings']) {
      await openMyRelay(tester, tab);
      // Шапка с названием — на любой вкладке.
      final header = tester.getCenter(find.byKey(const Key('my-relay-back')));
      await swipeOpens(Offset(150, header.dy));
    }
    // На дальней вкладке вправо по телу — тоже меню: вкладки на телефоне
    // листают сегменты, а не палец.
    await openMyRelay(tester, 'settings');
    await swipeOpens(const Offset(150, 500));
  });

  testWidgets('Задачи, Проекты, Планирование: свайп вправо открывает меню',
      (tester) async {
    await _pump(tester);
    for (final section in <String>['tasks', 'projects', 'planning']) {
      await tapInDrawer(tester, Key('nav-$section'));
      expect(find.byKey(const Key('app-sidebar')), findsNothing);
      await tester.dragFrom(const Offset(150, 400), const Offset(220, 0));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('app-sidebar')),
        findsOneWidget,
        reason: section,
      );
      await tester.tapAt(const Offset(380, 400));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('«открой мой Связной» и прежнее «мой Tridot» открывают раздел',
      (tester) async {
    await _pump(tester);
    for (final phrase in <String>['открой мой Связной', 'мой Tridot']) {
      await _say(tester, phrase);
      expect(find.byKey(const Key('my-relay')), findsOneWidget, reason: phrase);
      expect(find.byKey(const Key('my-relay-summary')), findsOneWidget);
      await backToSession(tester);
      expect(find.byKey(const Key('my-relay')), findsNothing);
      expect(find.textContaining('Открываю «Мой Связной»'), findsWidgets);
    }
  });

  testWidgets('«Мой Связной»: свайп вправо с любой вкладки открывает меню',
      (tester) async {
    await _pump(tester);
    await tapInDrawer(tester, const Key('drawer-my-relay'));
    for (final tab in <String>['summary', 'assistants', 'settings']) {
      await tester.ensureVisible(find.byKey(Key('my-relay-tab-$tab')));
      await tester.tap(find.byKey(Key('my-relay-tab-$tab')));
      await tester.pumpAndSettle();
      // «Сводка»: сетка входит целиком и вбок не прокручивается — свайп
      // и по ней открывает меню.
      for (final y in <double>[250, 700]) {
        await tester.dragFrom(Offset(150, y), const Offset(220, 0));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('app-sidebar')),
          findsOneWidget,
          reason: '$tab, y=$y',
        );
        await tester.tapAt(const Offset(380, 400));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('my-relay')), findsOneWidget);
      }
      // Выбранный сегмент — полужирный: вкладка свайпом не сменилась.
      final label = tester.widget<Text>(
        find.descendant(
          of: find.byKey(Key('my-relay-tab-$tab')),
          matching: find.byType(Text),
        ),
      );
      expect(label.style!.fontWeight, FontWeight.w600, reason: tab);
    }
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
      'история команд — хроника над лентой и «⋯» шапки, поле ввода — во '
      'всю колонку', (tester) async {
    await _pump(tester);
    expect(find.byKey(const Key('session-more')), findsNothing);
    for (final text in <String>['привет', '2+2', 'запомни: хлеб']) {
      await _say(tester, text);
    }
    expect(find.byKey(const Key('history-rail')), findsOneWidget);
    final more = tester.getRect(find.byKey(const Key('session-more')));
    expect(more.bottom, lessThanOrEqualTo(56));
    expect(more.width, greaterThanOrEqualTo(48));
    expect(more.right, greaterThan(390 - 56));
    // Поле ввода — от поля до поля ленты (20).
    final composer =
        tester.getRect(find.byKey(const Key('assistant-composer')));
    expect(composer.left, moreOrLessEquals(chatInset, epsilon: 1));
    expect(composer.right, moreOrLessEquals(390 - chatInset, epsilon: 1));
    await openCommandHistory(tester);
    expect(find.text('История команд'), findsOneWidget);
    expect(find.byKey(const Key('history-item-2')), findsOneWidget);
    final item = tester.getSize(find.byKey(const Key('history-item-0')));
    expect(item.height, greaterThanOrEqualTo(52));
    await tester.tap(find.byKey(const Key('history-item-0')));
    await tester.pumpAndSettle();
    expect(find.text('История команд'), findsNothing);
  });

  testWidgets(
      'компьютер: 40 команд — «История команд» со всеми, старая команда '
      'достижима', (tester) async {
    await _pump(tester, size: const Size(1440, 900));
    for (var i = 0; i < 40; i++) {
      await _say(tester, '$i+1');
    }
    expect(tester.takeException(), isNull);
    await openCommandHistory(tester);
    expect(find.text('История команд'), findsOneWidget);
    // Самая старая — в конце списка: долистать.
    final sheet = find.byKey(const Key('history-sheet'));
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
    expect(find.text('История команд'), findsNothing);
    // В ленте (то же — название сессии в меню).
    expect(
      find.descendant(
        of: find.byKey(const Key('chat-list')),
        matching: find.text('0+1'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('много команд на 320 px и шрифте 200 %: без переполнения',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(tester, size: const Size(320, 640));
    for (var i = 0; i < 40; i++) {
      await _say(tester, '$i+1');
    }
    expect(tester.takeException(), isNull);
    await openCommandHistory(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('history-item-39')), findsOneWidget);
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
    expect(find.byKey(const Key('session-more')), findsOneWidget);
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
    // Плитки: значок и подпись, равными долями строки (ADR-027).
    expect(find.text('Задача'), findsOneWidget);
    final tile = tester.getSize(find.byKey(const Key('quick-Задача')));
    expect(tile.height, greaterThanOrEqualTo(72));
    expect(tile.width, greaterThanOrEqualTo(72));
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
    expect(find.text('Главный'), findsNothing);
    expect(sessionEntries(), findsNWidgets(2));
    // Прежняя сессия на месте — под своей первой командой, с историей.
    await openSessionTitled(tester, 'привет');
    expect(
      find.descendant(
        of: find.byKey(const Key('chat-list')),
        matching: find.text('привет'),
      ),
      findsOneWidget,
    );
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
    final hit = find.byWidgetPredicate(
      (Widget w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('search-hit-session:'),
    );
    expect(hit, findsOneWidget);
    await tester.tap(hit);
    await tester.pumpAndSettle();
    expect(
      find.text('Что сделать?'),
      findsNothing,
      reason: 'открыта найденная',
    );
    expect(find.text('запомни: приход 318 от поставщика'), findsWidgets);
  });

  testWidgets(
      'широкий экран: три колонки, справа «Файлы сессии», в задачах '
      '«Сегодня»; обе сворачиваются', (tester) async {
    await _pump(tester, size: const Size(1440, 900));
    expect(find.byKey(const Key('app-sidebar')), findsOneWidget);
    // В сессии справа — «Файлы сессии» (ADR-028).
    expect(find.byKey(const Key('session-files-panel')), findsOneWidget);
    expect(find.byKey(const Key('today-panel')), findsNothing);
    expect(find.byKey(const Key('menu-button')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('session-title')),
        matching: find.byIcon(Icons.keyboard_arrow_down),
      ),
      findsNothing,
      reason: 'пустая сессия — без меню',
    );
    expect(find.byKey(const Key('today-show')), findsNothing);
    expect(find.byKey(const Key('session-files')), findsNothing);
    await tester.tap(find.byKey(const Key('session-files-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-files-panel')), findsNothing);
    // Свёрнута — кнопка у правого края шапки.
    final files = find.byKey(const Key('session-files'));
    expect(tester.getRect(files).right, greaterThan(1440 - 24));
    await tester.tap(files);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-files-panel')), findsOneWidget);
    expect(files, findsNothing);

    // «Сегодня» — у разделов задач.
    await tester.tap(find.byKey(const Key('nav-tasks')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('today-panel')), findsOneWidget);
    expect(find.byKey(const Key('session-files-panel')), findsNothing);
    expect(find.byKey(const Key('today-show')), findsNothing);
    expect(find.byKey(const Key('today-button')), findsNothing);
    await tester.tap(find.byKey(const Key('today-collapse')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('today-panel')), findsNothing);
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
      for (final tab in <String>['assistants', 'settings']) {
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
