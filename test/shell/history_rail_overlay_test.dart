// Хроника команд поверх ленты (полосы-хроника): не в шапке, а сверху по
// центру над сообщениями и документом, на полупрозрачной подложке; шапка —
// одна строка 56; первое сообщение и начало документа ею не закрыты.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsNode;
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

  testWidgets('телефон: поверх ленты под шапкой, шапка — одна строка 56',
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
      pill.overlaps(tester.getRect(find.byKey(const Key('chat-list')))),
      isTrue,
    );
    final decoration =
        tester.widget<DecoratedBox>(_pill).decoration as BoxDecoration;
    expect(decoration.color, AssistantColors.railPill);
    expect(decoration.color!.a, lessThan(1), reason: 'полупрозрачная');
    expect(decoration.border, isNotNull);

    // Одна кнопка — «Хроника команд», выбор ведёт к команде.
    final open = find.byKey(const Key('history-rail-open'));
    expect(tester.getSize(open).height, greaterThanOrEqualTo(44));
    expect(tester.getSize(open).width, greaterThanOrEqualTo(44));
    expect(
      find.bySemanticsLabel('Хроника команд: 3. Открыть список'),
      findsOneWidget,
    );
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(find.text('Хроника команд'), findsOneWidget);
    await tester.tap(find.byKey(const Key('history-item-0')));
    await tester.pumpAndSettle();
    expect(find.text('Хроника команд'), findsNothing);
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
    // Колонка между меню и «Сегодня»: хроника по её центру.
    final left = tester.getRect(find.byKey(const Key('app-sidebar'))).right;
    final right = tester.getRect(find.byKey(const Key('today-panel'))).left;
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
    expect(find.text('Хроника команд'), findsOneWidget);
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
      final rail = _readAt(tester, 'Хроника команд');
      // Первое сообщение ленты — ответ помощника (подпись с его именем).
      final feed = _readAt(tester, 'Садо\n');
      expect(rail, isNonNegative);
      expect(feed, isNonNegative);
      expect(rail, lessThan(feed));
      handle.dispose();
    });
  }
}
