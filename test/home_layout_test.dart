// Вёрстка главного экрана на типичных размерах окна настольного приложения:
// ничего не переполняется и не уходит за край окна, края колонки чата
// совпадают, хроника команд стоит поверх ленты под шапкой по центру (шапка
// — одна строка 56) и ширину у поля ввода не отнимает, карточка хроники не залезает на панель задач, кубик
// состояния стоит в строке автора ответа.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/app/shell/session_header.dart';
import 'package:local_assistant/app/widgets/status_cube.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

final _clock = FixedClock(DateTime(2026, 11, 6, 13, 3));

/// Размеры окон Mac: 13", 14", 15", 16" и узкое окно.
const _sizes = <Size>[
  Size(1280, 800),
  Size(1440, 900),
  Size(1512, 982),
  Size(1728, 1117),
  Size(1150, 800),
  Size(900, 700),
  Size(390, 844),
];

Future<TaskService> _pump(WidgetTester tester, Size size) async {
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
  return tasks;
}

Future<void> _say(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('assistant-input')), text);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

/// Разговор пользователя со скриншота: беседа, список, создание задачи.
const _script = <String>[
  'привет, как себя чувствуешь?',
  'а, хорошо',
  'Покажи задачи',
  'поставь задачу разместить стулья феррара 66580 в ячейки 1с',
];

void _expectInside(Rect inner, Rect outer, String what) {
  expect(
    inner.left >= outer.left - .5 &&
        inner.top >= outer.top - .5 &&
        inner.right <= outer.right + .5 &&
        inner.bottom <= outer.bottom + .5,
    isTrue,
    reason: '$what $inner выходит за $outer',
  );
}

void main() {
  for (final size in _sizes) {
    final label = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('$label: всё в окне, края колонки чата совпадают',
        (tester) async {
      await _pump(tester, size);
      for (final line in _script) {
        await _say(tester, line);
      }
      // Переполнение RenderFlex роняет тест само; на всякий случай явно.
      expect(tester.takeException(), isNull);

      final window = Offset.zero & size;
      // Справа в сессии — «Файлы сессии» (ADR-028).
      final panel = find.byKey(const Key('session-files-panel'));
      if (size.width >= todayOpenBreakpoint) {
        _expectInside(tester.getRect(panel), window, 'файлы сессии');
      } else {
        expect(panel, findsNothing, reason: 'узкое окно: колонка свёрнута');
      }

      final composer = tester.getRect(
        find.byKey(const Key('assistant-composer')),
      );
      _expectInside(composer, window, 'поле ввода');
      // Хроника — над лентой под шапкой, в окне (ADR-027, поправка);
      // история команд — ещё и в «⋯» шапки.
      final pill = find.byKey(const Key('history-rail-pill'));
      expect(pill, findsOneWidget);
      _expectInside(tester.getRect(pill), window, 'хроника');
      // На узком экране с задачей в фокусе в шапке «назад», задача и меню
      // сессии — «⋯» там нет.
      if (find.byKey(const Key('task-back')).evaluate().isEmpty ||
          size.width >= narrowBreakpoint) {
        final more = tester.getRect(find.byKey(const Key('session-more')));
        _expectInside(more, window, '«⋯» шапки');
      } else {
        expect(find.byKey(const Key('session-more')), findsNothing);
      }
      expect(find.byKey(const Key('addressee-switch')), findsNothing);
      // «Задача» и «Напомнить» — только в новой сессии.
      expect(find.byKey(const Key('quick-Задача')), findsNothing);

      // Колонка сессии — между меню и «Файлами сессии».
      final sidebar = find.byKey(const Key('app-sidebar'));
      final left =
          sidebar.evaluate().isEmpty ? 0.0 : tester.getRect(sidebar).right;
      // Меню колонкой — 312 (макет «Ж1»).
      if (sidebar.evaluate().isNotEmpty) {
        expect(tester.getSize(sidebar).width, sidebarWidth, reason: label);
        expect(sidebarWidth, 312);
      }
      final right =
          panel.evaluate().isEmpty ? size.width : tester.getRect(panel).left;
      final centre = (left + right) / 2;
      // Поле ввода — по центру колонки, без места под хронику справа.
      expect(composer.center.dx, moreOrLessEquals(centre, epsilon: 1));
      expect(
        composer.width,
        moreOrLessEquals(
          (right - left - 1).clamp(0, chatColumnWidth) - 2 * chatInset,
          epsilon: 2,
        ),
      );
      // Шапка — одна строка.
      final header = tester.getRect(find.byType(SessionHeader));
      expect(header.height, 56);

      // Ответ начинается у левого края колонки — там же, где поле ввода;
      // кубика в ленте нет (он в шапке, пока помощник работает).
      final author =
          find.byKey(const ValueKey<String>('message-author-sado')).first;
      expect(tester.getRect(author).left, moreOrLessEquals(composer.left));
      expect(
        find.descendant(
          of: find.byKey(const Key('chat-list')),
          matching: find.byType(StatusCube),
        ),
        findsNothing,
      );

      // Пузырь последней команды кончается у правого края поля ввода.
      final bubble = find
          .ancestor(
            of: find.text(_script.last),
            matching: find.byType(Container),
          )
          .first;
      expect(tester.getRect(bubble).right, moreOrLessEquals(composer.right));
    });
  }

  testWidgets('выдвижное меню: до 360, справа полоса не уже 30',
      (tester) async {
    for (final (width, drawer) in <(double, double)>[
      (390, 360),
      (430, 360),
      (320, 290),
    ]) {
      await _pump(tester, Size(width, 844));
      tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const Key('app-sidebar'))).width,
        drawer,
        reason: '$width',
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('«поставь задачу …» создаёт задачу, артикул — не срок',
      (tester) async {
    final tasks = await _pump(tester, const Size(1440, 900));
    await _say(tester, _script.last);
    final all = await tasks.listAll();
    expect(all, hasLength(1));
    expect(all.single.title, 'Разместить стулья феррара 66580 в ячейки 1с');
    expect(all.single.dueAt, isNull);
    expect(all.single.isActive, isTrue);
    expect(find.textContaining('не понял'), findsNothing);
  });

  testWidgets('пустая панель подсказывает пример без кавычек', (tester) async {
    await _pump(tester, const Size(1440, 900));
    // «Сегодня» — у разделов задач (ADR-028).
    await tester.tap(find.byKey(const Key('nav-tasks')));
    await tester.pumpAndSettle();
    final hint = find.descendant(
      of: find.byKey(const Key('today-panel')),
      matching: find.text(emptyTasksHint),
    );
    expect(hint, findsOneWidget);
    expect(emptyTasksHint, isNot(contains('«')));
    expect(emptyTasksHint, isNot(contains('…')));
    final panel = tester.getRect(find.byKey(const Key('today-panel')));
    _expectInside(tester.getRect(hint), panel, 'подсказка');
    // Пример целиком на своей строке: две строки текста, не три.
    final lineHeight = tester.getRect(find.text('На сегодня дел нет')).height;
    expect(tester.getRect(hint).height, lessThan(lineHeight * 3));
  });

  testWidgets('индикатор работы убирается после ответа', (tester) async {
    await _pump(tester, const Size(1440, 900));
    await tester.enterText(
      find.byKey(const Key('assistant-input')),
      'Покажи задачи',
    );
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('working-message')), findsNothing);
    // Помощник ждёт — кубика нет ни в ленте, ни в шапке (ADR-027).
    expect(find.byType(StatusCube), findsNothing);
  });

  testWidgets('крупный шрифт: заголовок панели не рассыпается по буквам',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final tasks = await _pump(tester, const Size(1440, 900));
    await tester.runAsync(
      () => tasks.create(
        title: 'Купить хлеб',
        dueAt: DateTime(2026, 11, 5, 10),
      ),
    );
    await _say(tester, 'Покажи задачи');
    await tester.tap(find.byKey(const Key('nav-tasks')));
    await tester.pumpAndSettle();
    final title = tester.getRect(
      find.descendant(
        of: find.byKey(const Key('today-panel')),
        matching: find.text('Сегодня'),
      ),
    );
    final summary = tester.getRect(
      find.byKey(const Key('today-summary')),
    );
    // Одна строка заголовка: высота меньше двух строк счётчика.
    expect(title.height, lessThan(summary.height * 2));
    _expectInside(
      summary,
      tester.getRect(find.byKey(const Key('today-panel'))),
      'счётчик',
    );
    expect(tester.takeException(), isNull);
  });
}
