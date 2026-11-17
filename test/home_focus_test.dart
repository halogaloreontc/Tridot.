// Фокус поля ввода на телефоне: клавиатура открывается, только когда о
// ней просили. Ответ, пришедший в другом разделе или под открытым
// экраном, меню, закрытая клавиатура — не повод открыть её снова.
// Единственное исключение — поле «Что сделать?» на виджете рабочего стола
// (ADR-034): человек нажал на поле, только не в приложении.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/app/homescreen/home_screen_channel.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/task_repository.dart';

import 'support/fake_home_screen.dart';

final _clock = FixedClock(DateTime(2026, 11, 9, 12, 40));

const _inputKey = Key('assistant-input');

/// Хранилище задач, запись в которое ждёт [gate]: ответ на «добавь
/// задачу» приходит, когда тест решит.
final class _GatedRepository implements TaskRepository {
  final Map<String, Task> _tasks = <String, Task>{};
  Completer<void>? gate;

  @override
  Future<Task?> get(String id) async => _tasks[id];

  @override
  Future<List<Task>> list() async => List<Task>.unmodifiable(_tasks.values);

  @override
  Future<void> save(Task task) async {
    final wait = gate;
    if (wait != null) await wait.future;
    _tasks[task.id] = task;
  }
}

final _navigator = GlobalKey<NavigatorState>();

Future<_GatedRepository> _pump(
  WidgetTester tester, {
  HomeScreenPlatform? homeScreen,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final repository = _GatedRepository();
  final tasks = TaskService(repository: repository, clock: _clock);
  final assistant = AssistantController(
    connectors: <Connector>[
      TasksConnector(taskService: tasks, parser: ScenarioParser(clock: _clock)),
      TalkConnector(taskService: tasks),
    ],
    clock: _clock,
  );
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: _navigator,
      theme: AssistantTheme.dark(),
      home: HomePage(
        assistant: assistant,
        tasks: tasks,
        clock: _clock,
        settingsStore: InMemorySettingsStore(),
        homeScreen: homeScreen,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repository;
}

FocusNode _composer(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(_inputKey)).focusNode!;

/// Пока ответ готовится, кубик крутится и `pumpAndSettle` не дождётся.
Future<void> _pumpFor(WidgetTester tester, [int frames = 20]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Команда, набранная в поле: клавиатура открыта, как у человека.
Future<void> _typeAndSend(WidgetTester tester, String text) async {
  await tester.tap(find.byKey(_inputKey));
  await tester.pump();
  await tester.enterText(find.byKey(_inputKey), text);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.pump();
}

/// Экранная клавиатура то открыта, то закрыта: так её видит приложение
/// по нижнему отступу окна.
Future<void> _keyboard(WidgetTester tester, {required bool shown}) async {
  tester.view.viewInsets = FakeViewPadding(bottom: shown ? 300 : 0);
  if (!shown) tester.testTextInput.hide();
  await tester.pump();
}

void main() {
  testWidgets('набрали и отправили — клавиатура остаётся для следующей',
      (tester) async {
    await _pump(tester);
    await _typeAndSend(tester, 'привет');
    await _pumpFor(tester);
    await tester.pumpAndSettle();
    expect(_composer(tester).hasFocus, isTrue);
  });

  testWidgets(
      'ответ пришёл, пока открыт «Мой Связной», — по возвращении клавиатура '
      'не выскакивает', (tester) async {
    final repository = await _pump(tester);
    repository.gate = Completer<void>();
    await _typeAndSend(tester, 'добавь задачу купить хлеб');
    await _pumpFor(tester, 3);
    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await _pumpFor(tester, 5);
    await tester.tap(find.byKey(const Key('drawer-my-relay')));
    await _pumpFor(tester, 5);
    expect(find.byKey(_inputKey), findsNothing);
    repository.gate!.complete();
    await _pumpFor(tester);
    await tester.tap(find.byKey(const Key('my-relay-back')));
    await _pumpFor(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(_inputKey), findsOneWidget);
    expect(_composer(tester).hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('ответ не отнимает фокус у поля на открытом поверх экране',
      (tester) async {
    final repository = await _pump(tester);
    repository.gate = Completer<void>();
    await _typeAndSend(tester, 'добавь задачу купить хлеб');
    await _pumpFor(tester, 3);
    final other = FocusNode();
    addTearDown(other.dispose);
    unawaited(
      _navigator.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => Scaffold(
            body: TextField(focusNode: other, autofocus: true),
          ),
        ),
      ),
    );
    await _pumpFor(tester, 5);
    expect(other.hasPrimaryFocus, isTrue);
    repository.gate!.complete();
    await _pumpFor(tester);
    expect(other.hasPrimaryFocus, isTrue);
    _navigator.currentState!.pop();
    await tester.pumpAndSettle();
  });

  testWidgets('клавиатуру закрыли — поле отпускает фокус', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(_inputKey));
    await _keyboard(tester, shown: true);
    expect(_composer(tester).hasPrimaryFocus, isTrue);
    await _keyboard(tester, shown: false);
    expect(_composer(tester).hasFocus, isFalse);
  });

  testWidgets(
      'клавиатуру закрыли, открыли и закрыли меню — клавиатура не '
      'возвращается', (tester) async {
    await _pump(tester);
    await _typeAndSend(tester, 'привет');
    await _keyboard(tester, shown: true);
    await _pumpFor(tester);
    await tester.pumpAndSettle();
    await _keyboard(tester, shown: false);
    await tester.dragFrom(const Offset(150, 300), const Offset(220, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsOneWidget);
    await tester.tapAt(const Offset(380, 400));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsNothing);
    expect(_composer(tester).hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('меню открыли с открытой клавиатурой — закрыли без неё',
      (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(_inputKey));
    await _keyboard(tester, shown: true);
    expect(_composer(tester).hasPrimaryFocus, isTrue);
    await tester.dragFrom(const Offset(150, 300), const Offset(220, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsOneWidget);
    await _keyboard(tester, shown: false);
    await tester.tapAt(const Offset(380, 400));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-sidebar')), findsNothing);
    expect(_composer(tester).hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets(
      'ответ пришёл, пока открыты «Файлы сессии», — клавиатура не '
      'выскакивает поверх панели', (tester) async {
    final repository = await _pump(tester);
    repository.gate = Completer<void>();
    await _typeAndSend(tester, 'добавь задачу купить хлеб');
    await _pumpFor(tester, 3);
    tester.state<ScaffoldState>(find.byType(Scaffold).first).openEndDrawer();
    await _pumpFor(tester, 5);
    expect(find.byKey(const Key('session-files-panel')), findsOneWidget);
    repository.gate!.complete();
    await _pumpFor(tester);
    await tester.pumpAndSettle();
    expect(_composer(tester).hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('телефон: «Новая сессия» в меню — без клавиатуры',
      (tester) async {
    await _pump(tester);
    await _typeAndSend(tester, 'привет');
    await _pumpFor(tester);
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await _keyboard(tester, shown: false);
    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-session')));
    await tester.pumpAndSettle();
    expect(_composer(tester).hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets(
      'телефон: поле «Что сделать?» на виджете — единственный случай, когда '
      'клавиатура открывается без нажатия на поле в приложении',
      (tester) async {
    final widgets = FakeHomeScreen();
    await _pump(tester, homeScreen: widgets);
    await _typeAndSend(tester, 'привет');
    await _pumpFor(tester);
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await _keyboard(tester, shown: false);
    // «Новая сессия» в меню — без клавиатуры, как и раньше.
    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-session')));
    await tester.pumpAndSettle();
    expect(_composer(tester).hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    // Нажали поле на виджете — клавиатура открыта.
    widgets.launched.add(HomeScreenLaunch.compose);
    await tester.pumpAndSettle();
    expect(_composer(tester).hasPrimaryFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    // Закрыли клавиатуру — дальше всё по-прежнему: меню её не возвращает.
    await _keyboard(tester, shown: true);
    await _keyboard(tester, shown: false);
    expect(_composer(tester).hasFocus, isFalse);
    await tester.dragFrom(const Offset(150, 300), const Offset(220, 0));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(380, 400));
    await tester.pumpAndSettle();
    expect(_composer(tester).hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('телефон: отметка на виджете и новый снимок — без клавиатуры',
      (tester) async {
    final widgets = FakeHomeScreen();
    await _pump(tester, homeScreen: widgets);
    expect(_composer(tester).hasFocus, isFalse);
    // Задачу отметили на виджете, системе понадобился снимок: приложение
    // работает молча, поле ввода не трогает.
    widgets.changed.add(null);
    widgets.wanted.add(null);
    await tester.pumpAndSettle();
    expect(_composer(tester).hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets(
    'компьютер: «Новая сессия» — курсор сразу в поле',
    (tester) async {
      await _pump(tester);
      await _typeAndSend(tester, 'привет');
      await _pumpFor(tester);
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-session')));
      await tester.pumpAndSettle();
      expect(_composer(tester).hasFocus, isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );
}
