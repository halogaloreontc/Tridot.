// «+» → «Шаблоны команд» (ADR-020): четыре частые команды и «Найти
// команду», счётчики выбора в settings.json, вставка в начатый черновик,
// поиск по всем командам включённых навыков.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/core/commands/command_catalog.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

Future<InMemorySettingsStore> _pump(
  WidgetTester tester, {
  AppSettings settings = const AppSettings(),
  double width = 390,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final clock = FixedClock(DateTime(2026, 11, 13, 12));
  final tasks = TaskService(repository: InMemoryTaskRepository(), clock: clock);
  final assistant = AssistantController(
    connectors: <Connector>[
      TasksConnector(taskService: tasks, parser: ScenarioParser(clock: clock)),
      const CalculatorConnector(),
      TalkConnector(taskService: tasks),
    ],
    clock: clock,
  );
  final store = InMemorySettingsStore();
  await store.save(settings);
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.dark(),
      home: HomePage(
        assistant: assistant,
        tasks: tasks,
        clock: clock,
        settingsStore: store,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

Future<void> _openTemplates(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('templates-button')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('composer-templates')));
  await tester.pumpAndSettle();
}

Future<void> _pickTop(WidgetTester tester, String id) async {
  await _openTemplates(tester);
  await tester.tap(find.byKey(Key('command-top-$id')));
  await tester.pumpAndSettle();
}

Future<void> _openFinder(WidgetTester tester, [String? query]) async {
  await _openTemplates(tester);
  await tester.tap(find.byKey(const Key('command-find')));
  await tester.pumpAndSettle();
  if (query != null) {
    await tester.enterText(find.byKey(const Key('command-search')), query);
    await tester.pumpAndSettle();
  }
}

/// Id частых команд в листе «+» сверху вниз.
List<String> _topIds(WidgetTester tester) {
  final finder = find.byWidgetPredicate(
    (Widget w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('command-top-'),
  );
  final rows = <(double, String)>[
    for (final element in finder.evaluate())
      (
        tester.getTopLeft(find.byWidget(element.widget)).dy,
        (element.widget.key! as ValueKey<String>)
            .value
            .substring('command-top-'.length),
      ),
  ]..sort(((double, String) a, (double, String) b) => a.$1.compareTo(b.$1));
  return <String>[for (final row in rows) row.$2];
}

TextEditingController _input(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const Key('assistant-input')))
    .controller!;

void main() {
  testWidgets('«Шаблоны команд»: четыре частые и «Найти команду»',
      (WidgetTester tester) async {
    await _pump(tester);
    await _openTemplates(tester);
    expect(_topIds(tester), CommandCatalog.defaultTop);
    expect(find.byKey(const Key('command-find')), findsOneWidget);
    expect(find.text('Найти команду'), findsOneWidget);
  });

  testWidgets('выбор вставляет шаблон и считается; «Посчитать» поднимается',
      (WidgetTester tester) async {
    final store = await _pump(tester);
    for (var i = 0; i < 3; i++) {
      await _pickTop(tester, 'calc.eval');
      expect(_input(tester).text, 'Сколько будет ');
      expect(_input(tester).selection.baseOffset, 'Сколько будет '.length);
      _input(tester).clear();
      await tester.pump();
    }
    expect((await store.load()).commandUsage, <String, int>{'calc.eval': 3});
    await _openTemplates(tester);
    expect(_topIds(tester).first, 'calc.eval');
    // В настройках только id и число: ни текста команды, ни черновика.
    expect(
      (await store.load()).toJson()['command_usage'],
      <String, int>{'calc.eval': 3},
    );
  });

  testWidgets('сохранённые счётчики задают порядок после перезапуска',
      (WidgetTester tester) async {
    await _pump(
      tester,
      settings: const AppSettings(
        commandUsage: <String, int>{'talk.joke': 5, 'task.list': 2},
      ),
    );
    await _openTemplates(tester);
    expect(
      _topIds(tester),
      <String>['talk.joke', 'task.list', 'task.new', 'task.tomorrow10'],
    );
  });

  testWidgets('вставка в начатый черновик его не стирает',
      (WidgetTester tester) async {
    await _pump(tester);
    await tester.enterText(find.byKey(const Key('assistant-input')), 'хлеб');
    await tester.pump();
    await _pickTop(tester, 'task.new');
    final input = _input(tester);
    expect(input.text, 'хлеб Добавь задачу «»');
    // Курсор — между кавычками, на месте «|».
    expect(input.selection.baseOffset, 'хлеб Добавь задачу «'.length);
  });

  testWidgets('«Найти команду»: поиск, выбор и счётчик',
      (WidgetTester tester) async {
    final store = await _pump(tester);
    await _openFinder(tester);
    expect(find.byKey(const Key('command-finder')), findsOneWidget);
    expect(find.byKey(const Key('command-category-tasks')), findsOneWidget);
    // Сейфа и склада нет: навыки не подключены.
    expect(find.byKey(const Key('command-category-vault')), findsNothing);

    await tester.enterText(find.byKey(const Key('command-search')), 'склад');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('command-empty')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('command-search')), 'ШУТК');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('command-entry-talk.joke')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('command-finder')), findsNothing);
    expect(_input(tester).text, 'Расскажи шутку');
    expect((await store.load()).commandUsage, <String, int>{'talk.joke': 1});
  });

  testWidgets('без выбранной задачи «Перенести выбранную» не предлагается',
      (WidgetTester tester) async {
    await _pump(tester);
    await _openFinder(tester, 'выбранную');
    expect(find.byKey(const Key('command-entry-plan.move')), findsNothing);
  });

  testWidgets('с выбранной задачей — «Перенести выбранную» без времени',
      (WidgetTester tester) async {
    await _pump(tester);
    await tester.enterText(
      find.byKey(const Key('assistant-input')),
      'Добавь задачу «Отчёт» на завтра в 10:00',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('assistant-send')));
    await tester.pumpAndSettle();
    await _openFinder(tester, 'выбранную');
    await tester.tap(find.byKey(const Key('command-entry-plan.move')));
    await tester.pumpAndSettle();
    expect(_input(tester).text, 'Перенеси её на ');
    // Отправили, не дописав, — висящее «на» не цель: помощник спросит,
    // на когда, а не будет искать задачу «На».
    await tester.tap(find.byKey(const Key('assistant-send')));
    await tester.pumpAndSettle();
    expect(find.textContaining('«На»'), findsNothing);
    expect(find.textContaining('На когда перенести задачу?'), findsOneWidget);
  });

  testWidgets('узкий экран 360: лист «+» и «Найти команду» без переполнения',
      (WidgetTester tester) async {
    await _pump(tester, width: 360);
    await _openTemplates(tester);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('command-find')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('command-finder')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('подсказка команд вместо «не понял» (ADR-022)', () {
    Future<void> send(WidgetTester tester, String text) async {
      await tester.enterText(find.byKey(const Key('assistant-input')), text);
      await tester.pump();
      await tester.tap(find.byKey(const Key('assistant-send')));
      await tester.pumpAndSettle();
    }

    testWidgets('опечатка: кнопки команд, выбор вставляет шаблон',
        (WidgetTester tester) async {
      final store = await _pump(tester);
      await send(tester, 'сделй задачу купить хлеб');
      expect(find.textContaining('Не до конца понял'), findsOneWidget);
      expect(find.byKey(const Key('suggest-task.new')), findsOneWidget);
      expect(find.byKey(const Key('suggest-find')), findsOneWidget);

      await tester.tap(find.byKey(const Key('suggest-task.new')));
      await tester.pumpAndSettle();
      final input = _input(tester);
      // Слова пользователя — названием, курсор в конце; не отправлено.
      expect(input.text, 'Добавь задачу «купить хлеб»');
      expect(input.selection.baseOffset, input.text.length);
      expect(find.text('Создал задачу «Купить хлеб».'), findsNothing);
      // Выбор подсказки ничего не запоминает.
      expect((await store.load()).commandUsage, isEmpty);
    });

    testWidgets('кнопки — только под последним ответом',
        (WidgetTester tester) async {
      await _pump(tester);
      await send(tester, 'расскаж шутку');
      expect(find.byKey(const Key('suggest-talk.joke')), findsOneWidget);
      await send(tester, 'покажи задачи');
      expect(find.byKey(const Key('suggest-talk.joke')), findsNothing);
      expect(find.byKey(const Key('suggest-find')), findsNothing);
    });

    testWidgets('бессмыслица и фраза без опечатки — ни одной кнопки',
        (WidgetTester tester) async {
      await _pump(tester);
      for (final text in <String>['ывапр олдж', 'сколько тебе лет']) {
        await send(tester, text);
        expect(find.textContaining('Не до конца понял'), findsNothing);
        expect(
          find.byWidgetPredicate(
            (Widget w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('suggest-'),
          ),
          findsNothing,
          reason: text,
        );
      }
    });

    testWidgets('«Найти команду» под подсказкой открывает список',
        (WidgetTester tester) async {
      await _pump(tester);
      await send(tester, 'расскаж шутку');
      await tester.tap(find.byKey(const Key('suggest-find')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('command-finder')), findsOneWidget);
    });

    testWidgets('понятая фраза — без кнопок', (WidgetTester tester) async {
      await _pump(tester);
      await send(tester, 'дабавь задчу хлеб');
      expect(find.byKey(const Key('suggest-find')), findsNothing);
    });

    testWidgets('фраза о пароле — без кнопок', (WidgetTester tester) async {
      await _pump(tester);
      await send(tester, 'забыл пороль от почты');
      expect(find.byKey(const Key('suggest-find')), findsNothing);
      expect(find.textContaining('Не до конца понял'), findsNothing);
    });
  });
}
