// Хроника команд над лентой (полосы-хроника): не в шапке, а своей полосой
// под ней, по центру над сообщениями и документом, на подложке заливкой без
// рамки (ADR-027); шапка — одна строка 56; ни метка даты, ни сообщения при
// прокрутке, ни начало документа под хронику не заходят. На телефоне кнопка
// хроники открывает «барабан» (history_drum_test.dart), на компьютере
// список — та же шторка «История команд», что и в «⋯» шапки.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/app/shell/session_header.dart';
import 'package:local_assistant/app/widgets/document_view.dart';
import 'package:local_assistant/app/widgets/history_rail.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

final _clock = FixedClock(DateTime(2026, 11, 4, 12));

Future<void> _pump(WidgetTester tester, Size size) async {
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
}

Future<void> _say(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('assistant-input')), text);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

final _pill = find.byKey(const Key('history-rail-pill'));
final _drum = find.byKey(const Key('history-drum-popup'));

Finder _inFeed(String text) => find.descendant(
      of: find.byKey(const Key('chat-list')),
      matching: find.text(text),
    );

ScrollPosition _feed(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(const Key('chat-list')),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

/// Порядок обхода диктором: индекс первого узла с [label] в метке.
int _readAt(WidgetTester tester, String label) => tester.semantics
    .simulatedAccessibilityTraversal()
    .toList()
    .indexWhere((SemanticsNode n) => n.label.contains(label));

void main() {
  testWidgets('пустая сессия — хроники нет', (tester) async {
    await _pump(tester, const Size(390, 844));
    expect(find.byKey(const Key('session-hero')), findsOneWidget);
    expect(_pill, findsNothing);
    expect(find.byKey(const Key('history-rail')), findsNothing);
  });

  testWidgets('телефон: полосой над лентой под шапкой, шапка — одна строка',
      (tester) async {
    await _pump(tester, const Size(390, 844));
    for (var i = 0; i < 3; i++) {
      await _say(tester, 'Покажи задачи $i');
    }
    final header = tester.getRect(find.byType(SessionHeader));
    expect(header.height, 56);
    final pill = tester.getRect(_pill);
    expect(pill.top, greaterThanOrEqualTo(header.bottom));
    expect(pill.height, HistoryRail.height);
    expect(pill.center.dx, moreOrLessEquals(195, epsilon: 1));
    expect(
      tester.getRect(find.byKey(const Key('chat-list'))).top,
      greaterThanOrEqualTo(pill.bottom),
      reason: 'лента начинается под хроникой, а не за ней',
    );
    final decoration =
        tester.widget<DecoratedBox>(_pill).decoration as BoxDecoration;
    expect(decoration.color, AppPalette.dark.raised);
    expect(decoration.border, isNull, reason: 'заливка без рамки (ADR-027)');

    // Одна кнопка — «барабан» истории команд, выбор ведёт к команде.
    final open = find.byKey(const Key('history-rail-open'));
    expect(tester.getSize(open).height, greaterThanOrEqualTo(44));
    expect(tester.getSize(open).width, greaterThanOrEqualTo(44));
    expect(
      find.bySemanticsLabel('История команд: 3. Открыть список'),
      findsOneWidget,
    );
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(_drum, findsOneWidget);
    // Home — к самой старой, Enter — перейти к ней.
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(_drum, findsNothing);
    expect(_inFeed('Покажи задачи 0'), findsOneWidget);
    expect(
      tester.getRect(_inFeed('Покажи задачи 0')).top,
      greaterThanOrEqualTo(tester.getRect(_pill).bottom),
      reason: 'команда, к которой перешли, не под хроникой',
    );
  });

  testWidgets('прокрутка к самому старому: первое сообщение под хроникой',
      (tester) async {
    await _pump(tester, const Size(390, 700));
    for (var i = 0; i < 12; i++) {
      await _say(tester, 'Покажи задачи $i');
    }
    final list = find.descendant(
      of: find.byKey(const Key('chat-list')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(list.first).position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    final first = tester.getRect(_inFeed('Покажи задачи 0'));
    expect(first.top, greaterThanOrEqualTo(tester.getRect(_pill).bottom));
  });

  testWidgets('прокрученная лента не заходит под хронику', (tester) async {
    await _pump(tester, const Size(390, 700));
    for (var i = 0; i < 12; i++) {
      await _say(tester, 'Покажи задачи $i');
    }
    final feed = _feed(tester);
    feed.jumpTo(feed.maxScrollExtent / 2);
    await tester.pumpAndSettle();
    expect(feed.pixels, greaterThan(0));
    // Вьюпорт ленты целиком под хроникой: прокрученные сообщения
    // обрезаются по его краю, а не проходят под подложкой.
    final list = tester.getRect(find.byKey(const Key('chat-list')));
    expect(list.top, greaterThanOrEqualTo(tester.getRect(_pill).bottom));
  });

  testWidgets('метка даты над первой группой — не под хроникой',
      (tester) async {
    await _pump(tester, const Size(390, 844));
    for (var i = 0; i < 2; i++) {
      await _say(tester, 'Покажи задачи $i');
    }
    final date = find.descendant(
      of: find.byKey(const Key('chat-list')),
      matching: find.textContaining('Сегодня'),
    );
    expect(date, findsWidgets);
    expect(
      tester.getRect(date.first).top,
      greaterThanOrEqualTo(tester.getRect(_pill).bottom),
    );
  });

  testWidgets('«Документ»: хроника видна, начало документа не закрыто',
      (tester) async {
    await _pump(tester, const Size(390, 844));
    await _say(tester, 'Добавь задачу «Купить хлеб» на завтра');
    await tester.tap(find.byKey(const Key('mode-document')));
    await tester.pumpAndSettle();
    expect(find.byType(DocumentView), findsOneWidget);
    expect(_pill, findsOneWidget);
    final crumb = find.descendant(
      of: find.byType(DocumentView),
      matching: find.textContaining('Задачи'),
    );
    expect(
      tester.getRect(crumb.first).top,
      greaterThanOrEqualTo(tester.getRect(_pill).bottom),
    );
  });

  testWidgets('компьютер: полосы с подсказками, кнопка списка, «+N»',
      (tester) async {
    await _pump(tester, const Size(1440, 900));
    for (var i = 0; i < 40; i++) {
      await _say(tester, '$i+1');
    }
    expect(_pill, findsOneWidget);
    expect(tester.getSize(find.byType(SessionHeader)).height, 56);
    expect(find.byKey(const Key('history-rail-open')), findsNothing);
    expect(find.byKey(const Key('history-rail-list')), findsOneWidget);
    expect(find.byKey(const Key('history-more-open')), findsOneWidget);
    expect(find.byKey(const Key('history-39')), findsOneWidget);
    expect(find.byType(Tooltip), findsWidgets);
    // Колонка между меню и «Файлами сессии»: хроника по её центру.
    final left = tester.getRect(find.byKey(const Key('app-sidebar'))).right;
    final right =
        tester.getRect(find.byKey(const Key('session-files-panel'))).left;
    expect(
      tester.getRect(_pill).center.dx,
      moreOrLessEquals((left + right) / 2, epsilon: 1.5),
    );
  });

  testWidgets('320 px и шрифт 2x: без переполнения, цель не меньше 44',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(tester, const Size(320, 640));
    for (var i = 0; i < 30; i++) {
      await _say(tester, 'Покажи задачи $i');
    }
    expect(tester.takeException(), isNull);
    final pill = tester.getRect(_pill);
    expect(pill.left, greaterThanOrEqualTo(0));
    expect(pill.right, lessThanOrEqualTo(320));
    final open = tester.getSize(find.byKey(const Key('history-rail-open')));
    expect(open.width, greaterThanOrEqualTo(44));
    expect(open.height, greaterThanOrEqualTo(44));
  });

  testWidgets('телефон: перетаскивание над хроникой двигает ленту',
      (tester) async {
    await _pump(tester, const Size(390, 700));
    for (var i = 0; i < 12; i++) {
      await _say(tester, 'Покажи задачи $i');
    }
    final feed = _feed(tester);
    expect(feed.pixels, 0);
    await tester.dragFrom(tester.getCenter(_pill), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(feed.pixels, greaterThan(100), reason: 'нет «мёртвой» зоны');
    // Нажатие по кнопке хроники — по-прежнему у неё.
    await tester.tap(find.byKey(const Key('history-rail-open')));
    await tester.pumpAndSettle();
    expect(_drum, findsOneWidget);
  });

  testWidgets('телефон: «барабан» при открытой клавиатуре её не возвращает',
      (tester) async {
    await _pump(tester, const Size(390, 844));
    for (var i = 0; i < 3; i++) {
      await _say(tester, 'Покажи задачи $i');
    }
    await tester.tap(find.byKey(const Key('assistant-input')));
    await tester.pump();
    final composer = FocusManager.instance.primaryFocus;
    expect(composer, isNotNull);
    await tester.tap(find.byKey(const Key('history-rail-open')));
    await tester.pumpAndSettle();
    expect(_drum, findsOneWidget);
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_drum, findsNothing);
    expect(FocusManager.instance.primaryFocus, isNot(same(composer)));
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('компьютер: колесо мыши над хроникой прокручивает ленту',
      (tester) async {
    await _pump(tester, const Size(1440, 900));
    for (var i = 0; i < 20; i++) {
      await _say(tester, 'Покажи задачи $i');
    }
    final feed = _feed(tester);
    expect(feed.maxScrollExtent, greaterThan(300));
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(tester.getCenter(_pill)));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -300)));
    await tester.pumpAndSettle();
    expect(feed.pixels, moreOrLessEquals(300, epsilon: 1));
    // Мышью ленту не тянут — и хронику тоже.
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 300)));
    await tester.pumpAndSettle();
    expect(feed.pixels, 0);
  });

  testWidgets('«Документ»: перетаскивание над хроникой двигает документ',
      (tester) async {
    await _pump(tester, const Size(390, 600));
    await _say(tester, 'Добавь задачу «Купить хлеб» на завтра');
    await tester.tap(find.byKey(const Key('mode-document')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('document-editor')),
      List<String>.generate(60, (int i) => 'Строка $i').join('\n'),
    );
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final doc = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(DocumentView),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    doc.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.dragFrom(tester.getCenter(_pill), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(doc.pixels, greaterThan(100));
  });

  for (final (name, size) in <(String, Size)>[
    ('телефон', const Size(390, 844)),
    ('компьютер', const Size(1440, 900)),
  ]) {
    testWidgets('$name: диктор читает хронику перед лентой', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, size);
      for (var i = 0; i < 3; i++) {
        await _say(tester, 'Покажи задачи $i');
      }
      final rail = _readAt(tester, 'История команд');
      // Лента начинается с метки даты над группой сообщений.
      final feed = _readAt(tester, 'Сегодня, 12:00');
      expect(rail, isNonNegative);
      expect(feed, isNonNegative);
      expect(rail, lessThan(feed));
      handle.dispose();
    });
  }
}
