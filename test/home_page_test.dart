import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/app/widgets/status_cube.dart';
import 'package:local_assistant/core/app_info.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';
import 'package:local_assistant/core/storage/task_repository.dart';

import 'support/home_nav.dart';

final class _BrokenRepository implements TaskRepository {
  @override
  Future<List<Task>> list() async => throw const FormatException('битый файл');

  @override
  Future<Task?> get(String id) async => null;

  @override
  Future<void> save(Task task) async {}
}

/// Репозиторий с задержкой записи и возможностью один раз упасть.
final class _SlowRepository implements TaskRepository {
  final InMemoryTaskRepository _inner = InMemoryTaskRepository();

  /// Задержку включают после подготовки данных: в тестовом времени
  /// ожидание идёт только вместе с tester.pump.
  Duration delay = Duration.zero;
  bool failNext = false;
  int saves = 0;

  @override
  Future<List<Task>> list() => _inner.list();

  @override
  Future<Task?> get(String id) => _inner.get(id);

  @override
  Future<void> save(Task task) async {
    saves++;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (failNext) {
      failNext = false;
      throw StateError('диск недоступен');
    }
    await _inner.save(task);
  }
}

final _clock = FixedClock(DateTime(2026, 11, 4, 12));

const _desktop = Size(1300, 900);
const _laptop = Size(1000, 800);
const _phone = Size(390, 844);

final class _Harness {
  _Harness(this.tasks, this.assistant);

  final TaskService tasks;
  final AssistantController assistant;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  Size size = _desktop,
  TaskRepository? repository,
  TaskService? service,
  EdgeInsets viewInsets = EdgeInsets.zero,
  SettingsStore? settings,
  bool calculator = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final tasks = service ??
      TaskService(
        repository: repository ?? InMemoryTaskRepository(),
        clock: _clock,
      );
  final assistant = AssistantController(
    connectors: <Connector>[
      TasksConnector(taskService: tasks, parser: ScenarioParser(clock: _clock)),
      if (calculator) const CalculatorConnector(),
    ],
    clock: _clock,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.dark(),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(viewInsets: viewInsets),
        child: child!,
      ),
      home: HomePage(
        assistant: assistant,
        tasks: tasks,
        clock: _clock,
        settingsStore: settings,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(tasks, assistant);
}

Future<void> _say(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('assistant-input')), text);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

CubeState _cube(WidgetTester tester) =>
    tester.widget<StatusCube>(find.byType(StatusCube)).state;

Future<TaskStatus> _status(TaskService service, String id) async =>
    (await service.listAll()).firstWhere((Task t) => t.id == id).status;

void main() {
  testWidgets('основные области видны, меню на русском и рабочее',
      (tester) async {
    await _pump(tester);

    expect(find.byKey(const Key('app-sidebar')), findsOneWidget);
    // Пустая сессия — она же приветствие: сообщений нет, кубик появится с
    // первым ответом.
    expect(find.byKey(const Key('session-hero')), findsOneWidget);
    expect(find.byKey(const Key('status-cube')), findsNothing);
    expect(find.text('Главный'), findsNothing);
    // Хроника команд появляется с первой командой.
    expect(find.byKey(const Key('history-rail')), findsNothing);
    expect(find.byKey(const Key('assistant-composer')), findsOneWidget);
    for (final title in <String>[
      AppInfo.hubName,
      'Проекты',
      'Задачи',
      'Планирование',
      'Сегодня',
      'Новая сессия',
    ]) {
      expect(find.text(title), findsWidgets, reason: title);
    }
    // Шестерёнки настроек в меню нет: настройки — в «Мой Tridot».
    expect(find.byKey(const Key('nav-settings')), findsNothing);

    for (final (key, chat) in <(String, bool)>[
      ('nav-tasks', false),
      ('nav-projects', false),
      ('nav-planning', false),
      ('drawer-my-relay', false),
      // «+» из раздела — в ту же пустую сессию.
      ('new-session', true),
    ]) {
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('assistant-composer')),
        chat ? findsOneWidget : findsNothing,
        reason: key,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('на телефоне меню прячется в выдвижную панель', (tester) async {
    await _pump(tester, size: _phone);
    expect(find.byKey(const Key('app-sidebar')), findsNothing);

    await tester.tap(find.byKey(const Key('menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-planning')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('assistant-composer')), findsNothing);
    expect(find.text('Планирование'), findsWidgets);
  });

  testWidgets('текст команды сохраняется при переключении на документ',
      (tester) async {
    await _pump(tester);
    await tester.enterText(
      find.byKey(const Key('assistant-input')),
      'Черновик команды',
    );
    await tester.tap(find.byKey(const Key('mode-document')));
    await tester.pumpAndSettle();

    expect(find.text('Черновик команды'), findsOneWidget);
    expect(
      find.text('Документ открывается для выбранной задачи.'),
      findsOneWidget,
    );
  });

  testWidgets('пример команды создаёт и выбирает задачу', (tester) async {
    await _pump(tester);
    await _say(tester, AssistantController.exampleCommand);

    expect(
      outsideDrawer(
        find.text('Создал задачу «Позвонить клиенту» на завтра в 11:00.'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('selected-task-strip')), findsOneWidget);
    final field = tester.widget<TextField>(
      find.byKey(const Key('assistant-input')),
    );
    expect(field.focusNode!.hasFocus, isTrue, reason: 'фокус остаётся');
  });

  testWidgets('кубик показывает результат и затихает', (tester) async {
    await _pump(tester);
    await tester.enterText(
      find.byKey(const Key('assistant-input')),
      'Покажи задачи',
    );
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    await tester.pump();
    expect(_cube(tester), CubeState.completed);

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(_cube(tester), CubeState.idle);
    expect(StatusCube.label(CubeState.idle), 'Помощник ждёт команду');
  });

  testWidgets('быстрые действия работают с выбранной задачей', (tester) async {
    final h = await _pump(tester);
    await _say(tester, 'Добавь задачу «Купить хлеб»');

    await tester.tap(find.byKey(const Key('quick-Заверши её')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(await h.tasks.listActive(), isEmpty);
    expect(find.byKey(const Key('selected-task-strip')), findsNothing);
    // «Задача» — только в новой сессии: в этой уже есть сообщения.
    expect(find.byKey(const Key('quick-Задача')), findsNothing);
    await tester.tap(find.byKey(const Key('new-session')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('quick-Задача')));
    await tester.pump();
    final field = tester.widget<TextField>(
      find.byKey(const Key('assistant-input')),
    );
    expect(field.controller!.text, 'Добавь задачу «»');
    expect(field.controller!.selection.baseOffset, 'Добавь задачу «'.length);
  });

  testWidgets('панель задач: группы, сроки, завершение и отмена',
      (tester) async {
    final service =
        TaskService(repository: InMemoryTaskRepository(), clock: _clock);
    final report =
        await service.create(title: 'Отчёт', dueAt: DateTime(2026, 11, 5, 10));
    await service.create(title: 'Старое', dueAt: DateTime(2026, 11, 3, 9));
    await _pump(tester, service: service);
    await tapInDrawer(tester, const Key('nav-tasks'));

    expect(find.byKey(const Key('tasks-panel')), findsOneWidget);
    expect(find.text('Просрочено · 1'), findsOneWidget);
    expect(find.text('завтра в 10:00'), findsWidgets);
    expect(find.text('просрочено · вчера в 9:00'), findsWidgets);

    await tester.tap(find.byKey(ValueKey<String>('toggle-${report.id}')));
    await tester.pumpAndSettle();
    expect(await _status(service, report.id), TaskStatus.done);

    await tester.tap(find.text('Отменить'));
    await tester.pumpAndSettle();
    expect(await _status(service, report.id), TaskStatus.planned);
  });

  testWidgets('на ноутбуке «Сегодня» открывается кнопкой в шапке',
      (tester) async {
    await _pump(tester, size: _laptop);
    expect(find.byKey(const Key('today-panel')), findsNothing);
    expect(find.byKey(const Key('today-button')), findsNothing);

    await tester.tap(find.byKey(const Key('today-show')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('today-panel')), findsOneWidget);
    expect(find.byKey(const Key('today-show')), findsNothing);
    await tester.tap(find.byKey(const Key('today-collapse')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('today-panel')), findsNothing);
    expect(find.byKey(const Key('today-show')), findsOneWidget);
  });

  testWidgets('ошибка загрузки задач видна и даёт повторить', (tester) async {
    await _pump(tester, repository: _BrokenRepository());

    expect(find.text('Не удалось загрузить задачи'), findsOneWidget);
    expect(find.text('Повторить'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('документ сохраняет правки и форматирование', (tester) async {
    final h = await _pump(tester);
    await _say(tester, 'Добавь задачу «Отчёт» #работа');

    await tester.tap(find.byKey(const Key('mode-document')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('document-editor')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('document-editor')),
      'первый шаг',
    );
    await tester.pump();
    expect(find.text('Есть несохранённые изменения'), findsOneWidget);
    await tester.tap(find.byKey(const Key('format-Чекбокс')));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    final task = (await h.tasks.listActive()).single;
    expect(task.description, '- [ ] первый шаг');
    expect(task.project, 'работа');
    expect(find.textContaining('Сохранено'), findsOneWidget);
  });

  testWidgets('полоса истории ведёт к команде', (tester) async {
    await _pump(tester);
    await _say(tester, 'Покажи задачи');
    await _say(tester, 'Привет');

    expect(find.byKey(const Key('history-0')), findsOneWidget);
    expect(find.byKey(const Key('history-1')), findsOneWidget);
    expect(find.byKey(const Key('history-2')), findsNothing);

    await tester.tap(find.byKey(const Key('history-0')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('стрелка вверх возвращает прошлую команду', (tester) async {
    await _pump(tester);
    await _say(tester, 'Покажи задачи');

    await tester.tap(find.byKey(const Key('assistant-input')));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    final field = tester.widget<TextField>(
      find.byKey(const Key('assistant-input')),
    );
    expect(field.controller!.text, 'Покажи задачи');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(field.controller!.text, contains('\n'));
  });

  testWidgets('настройки скрывают время сообщений', (tester) async {
    final store = InMemorySettingsStore();
    await _pump(tester, settings: store);
    Finder time() => find.descendant(
          of: find.byKey(const Key('chat-list')),
          matching: find.text('12:00'),
        );
    await _say(tester, 'Покажи задачи');
    expect(time(), findsWidgets);

    await store.save(const AppSettings(showTimestamps: false));
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, settings: store);
    await _say(tester, 'Покажи задачи');
    expect(find.byKey(const Key('chat-list')), findsOneWidget);
    expect(time(), findsNothing);
  });

  testWidgets('нет переполнения на узком экране и крупном шрифте',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(tester, size: const Size(320, 640));
    await _say(tester, 'Добавь задачу «Купить хлеб и молоко» на завтра');
    expect(tester.takeException(), isNull);
  });

  testWidgets('нет переполнения с клавиатурой в горизонтальной ориентации',
      (tester) async {
    await _pump(
      tester,
      size: const Size(640, 360),
      viewInsets: const EdgeInsets.only(bottom: 180),
    );
    await _say(tester, 'Добавь задачу «Купить хлеб» на завтра');
    expect(tester.takeException(), isNull);
  });

  testWidgets('длинная история не вылезает за полосу', (tester) async {
    await _pump(tester, size: const Size(1000, 600));
    for (var i = 0; i < 20; i++) {
      await _say(tester, 'Привет $i');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('без голосового ввода микрофона нет, отправка — стрелкой',
      (tester) async {
    await _pump(tester);
    // Платформа без движка распознавания (voice: null): микрофон скрыт.
    expect(find.byKey(const Key('assistant-voice')), findsNothing);
    expect(find.byIcon(Icons.mic_none), findsNothing);
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('assistant-input')),
      'Покажи задачи',
    );
    await tester.pump();
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);

    await tester.tap(find.byKey(const Key('assistant-send')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(
      outsideDrawer(find.text('Активных задач пока нет.')),
      findsOneWidget,
    );
  });

  testWidgets('«+»: облачный диск, файл и шаблоны команд', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const Key('templates-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('composer-cloud')), findsOneWidget);
    expect(find.byKey(const Key('composer-attach')), findsOneWidget);
    expect(find.byKey(const Key('composer-templates')), findsOneWidget);
    expect(find.text('Прикрепить файл'), findsOneWidget);
    // Списки закрыты, пока пункт не раскрыт.
    expect(find.text('Задача на завтра в 10:00'), findsNothing);

    // Дисков нет: честное «Подключить диск» и пояснение.
    await tester.tap(find.byKey(const Key('composer-cloud')));
    await tester.pumpAndSettle();
    expect(find.text('Подключить диск'), findsOneWidget);
    await tester.tap(find.byKey(const Key('cloud-connect')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cloud-disk-info')), findsOneWidget);
    expect(
      find.textContaining('Яндекс Диск и Google Диск появятся позже'),
      findsOneWidget,
    );
    await tester.tap(find.text('Понятно'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('templates-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('composer-templates')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Задача на завтра в 10:00'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.byKey(const Key('assistant-input')),
    );
    expect(field.controller!.text, 'Добавь задачу «» на завтра в 10:00');
  });

  Future<Task> byTitle(TaskService service, String title) async =>
      (await service.listAll()).firstWhere((Task t) => t.title == title);

  Future<void> openTask(WidgetTester tester, Task task) async {
    await openDrawerIfNeeded(tester);
    await tester.tap(find.byKey(const Key('nav-tasks')));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey<String>('task-${task.id}')));
    await tester.pump();
  }

  testWidgets('пустое название не мешает сохранить заметки', (tester) async {
    final service =
        TaskService(repository: InMemoryTaskRepository(), clock: _clock);
    final alpha = await service.create(title: 'Alpha');
    final beta = await service.create(title: 'Beta');
    await _pump(tester, service: service);
    await openTask(tester, alpha);
    await tester.tap(find.byKey(const Key('mode-document')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('document-title')), '');
    await tester.enterText(
      find.byKey(const Key('document-editor')),
      'Важные заметки',
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.textContaining('должно быть название'), findsOneWidget);

    await openTask(tester, beta);
    await tester.pumpAndSettle();
    final saved = await byTitle(service, 'Alpha');
    expect(saved.description, 'Важные заметки');
  });

  testWidgets('после ошибки записи «Сохранить» повторяет запись',
      (tester) async {
    final repo = _SlowRepository();
    final service = TaskService(repository: repo, clock: _clock);
    final alpha = await service.create(title: 'Alpha');
    await _pump(tester, service: service);
    await openTask(tester, alpha);
    await tester.tap(find.byKey(const Key('mode-document')));
    await tester.pumpAndSettle();

    repo.failNext = true;
    await tester.enterText(find.byKey(const Key('document-editor')), 'текст');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Не удалось сохранить'), findsOneWidget);

    await tester.tap(find.byKey(const Key('document-save')));
    await tester.pumpAndSettle();
    expect((await byTitle(service, 'Alpha')).description, 'текст');
    expect(find.textContaining('Сохранено'), findsOneWidget);
  });

  testWidgets('быстрое переключение задач не путает документы', (tester) async {
    final repo = _SlowRepository();
    final service = TaskService(repository: repo, clock: _clock);
    final alpha = await service.create(title: 'Alpha');
    final beta = await service.create(title: 'Beta');
    final gamma = await service.create(title: 'Gamma');
    repo.delay = const Duration(milliseconds: 300);
    await _pump(tester, service: service);
    await openTask(tester, alpha);
    await tester.tap(find.byKey(const Key('mode-document')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('document-editor')), 'A');
    await openTask(tester, beta);
    await tester.pump(const Duration(milliseconds: 50));
    await openTask(tester, gamma);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    final title = tester.widget<TextField>(
      find.byKey(const Key('document-title')),
    );
    expect(title.controller!.text, 'Gamma');
    await tester.enterText(find.byKey(const Key('document-editor')), 'G');
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect((await byTitle(service, 'Alpha')).description, 'A');
    expect((await byTitle(service, 'Beta')).description, '');
    expect((await byTitle(service, 'Gamma')).description, 'G');
  });

  testWidgets('поздняя запись старой задачи не теряет правки новой',
      (tester) async {
    final repo = _SlowRepository();
    final service = TaskService(repository: repo, clock: _clock);
    final alpha = await service.create(title: 'Alpha');
    final beta = await service.create(title: 'Beta');
    repo.delay = const Duration(milliseconds: 500);
    await _pump(tester, service: service);
    await openTask(tester, alpha);
    await tester.tap(find.byKey(const Key('mode-document')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('document-editor')), 'A-notes');
    await tester.pump(const Duration(milliseconds: 850));
    // Запись Alpha ещё идёт (500 мс), а пользователь уже печатает в Beta.
    await openTask(tester, beta);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.enterText(find.byKey(const Key('document-editor')), 'B-notes');
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect((await byTitle(service, 'Alpha')).description, 'A-notes');
    expect((await byTitle(service, 'Beta')).description, 'B-notes');
  });

  testWidgets('переход по истории к старой команде за пределами экрана',
      (tester) async {
    await _pump(tester, size: const Size(1000, 600));
    for (var i = 0; i < 15; i++) {
      await _say(tester, 'Покажи задачи $i');
    }
    // В ленте, а не название сессии в меню.
    Finder first() => find.descendant(
          of: find.byKey(const Key('chat-list')),
          matching: find.text('Покажи задачи 0'),
        );
    expect(first(), findsNothing);

    await tester.tap(find.byKey(const Key('history-0')));
    await tester.pumpAndSettle();
    expect(first(), findsOneWidget);
  });

  testWidgets('стрелки не стирают черновик', (tester) async {
    await _pump(tester);
    await _say(tester, 'Покажи задачи');
    await tester.enterText(
      find.byKey(const Key('assistant-input')),
      'черновик',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    final field = tester.widget<TextField>(
      find.byKey(const Key('assistant-input')),
    );
    expect(field.controller!.text, 'черновик');
  });

  testWidgets('переключатель режимов не сжимается на узком экране',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(tester, size: const Size(320, 640));
    final size = tester.getSize(find.byKey(const Key('mode-document')));
    expect(size.height, greaterThanOrEqualTo(40));
    expect(tester.takeException(), isNull);
  });

  testWidgets('правки сохраняются при смене задачи до автосохранения',
      (tester) async {
    final repo = _SlowRepository();
    final service = TaskService(repository: repo, clock: _clock);
    final alpha = await service.create(title: 'Alpha');
    final beta = await service.create(title: 'Beta');
    repo.delay = const Duration(milliseconds: 300);
    await _pump(tester, service: service);
    await openTask(tester, alpha);
    await tester.tap(find.byKey(const Key('mode-document')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('document-editor')), 'срочно');
    await openTask(tester, beta);
    final title = tester.widget<TextField>(
      find.byKey(const Key('document-title')),
    );
    expect(title.controller!.text, 'Beta', reason: 'переключение сразу');

    // Возврат к Alpha, пока запись ещё идёт: виден снимок, а не старые данные.
    await openTask(tester, alpha);
    final body = tester.widget<TextField>(
      find.byKey(const Key('document-editor')),
    );
    expect(body.controller!.text, 'срочно');

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect((await byTitle(service, 'Alpha')).description, 'срочно');
    expect((await byTitle(service, 'Beta')).description, '');
  });

  testWidgets('поиск на экране «Задачи» фильтрует список', (tester) async {
    final service =
        TaskService(repository: InMemoryTaskRepository(), clock: _clock);
    await service.create(title: 'Отчёт за квартал', tags: <String>['работа']);
    await service.create(title: 'Купить краску', tags: <String>['дача']);
    await _pump(tester, service: service);
    await tapInDrawer(tester, const Key('nav-tasks'));

    await tester.enterText(find.byKey(const Key('task-search')), 'краск');
    await tester.pumpAndSettle();
    expect(find.text('Купить краску'), findsWidgets);
    expect(find.text('Отчёт за квартал'), findsNothing);

    await tester.enterText(find.byKey(const Key('task-search')), '#работа');
    await tester.pumpAndSettle();
    expect(find.text('Отчёт за квартал'), findsWidgets);
    expect(find.text('Купить краску'), findsNothing);

    await tester.enterText(find.byKey(const Key('task-search')), 'нет такого');
    await tester.pumpAndSettle();
    expect(find.text('Ничего не нашлось'), findsOneWidget);
  });

  testWidgets('подписи режимов есть на широком экране и скрыты на узком',
      (tester) async {
    await _pump(tester);
    expect(
      find.descendant(
        of: find.byKey(const Key('mode-dialogue')),
        matching: find.text('Диалог'),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
    await _pump(tester, size: _phone);
    expect(
      find.descendant(
        of: find.byKey(const Key('mode-dialogue')),
        matching: find.text('Диалог'),
      ),
      findsNothing,
    );
    expect(find.byKey(const Key('mode-document')), findsOneWidget);
  });

  testWidgets('последняя полоса хроники выделена цветом успеха',
      (tester) async {
    await _pump(tester);
    await _say(tester, 'Покажи задачи');
    await _say(tester, 'Привет');

    Color colorOf(String key) {
      final box = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byType(AnimatedContainer),
        ),
      );
      return (box.decoration! as BoxDecoration).color!;
    }

    expect(colorOf('history-1'), AssistantColors.success);
    expect(colorOf('history-0'), isNot(AssistantColors.success));
  });

  testWidgets('на телефоне хроника открывает список команд', (tester) async {
    await _pump(tester, size: _phone);
    await _say(tester, 'Покажи задачи');
    await _say(tester, 'Привет');

    await tester.tap(find.byKey(const Key('history-rail-open')));
    await tester.pumpAndSettle();
    expect(find.text('Хроника команд'), findsOneWidget);

    await tester.tap(find.byKey(const Key('history-item-0')));
    await tester.pumpAndSettle();
    expect(find.text('Хроника команд'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '«Сегодня» — колонкой у правого края только на компьютере, «Мой '
      'Tridot» в меню', (tester) async {
    await _pump(tester, size: _desktop);
    final panel = tester.getRect(find.byKey(const Key('today-panel')));
    expect(panel.right, _desktop.width);
    expect(find.byKey(const Key('today-button')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, size: _phone);
    expect(find.byKey(const Key('today-panel')), findsNothing);
    expect(find.byKey(const Key('today-button')), findsNothing);
    expect(find.byKey(const Key('today-show')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await _pump(tester);
    expect(
      find.descendant(
        of: find.byKey(const Key('app-sidebar')),
        matching: find.byKey(const Key('drawer-my-relay')),
      ),
      findsOneWidget,
    );
  });

  testWidgets('кнопка «назад» выводит из чата по задаче в общий чат',
      (tester) async {
    final h = await _pump(tester);
    await _say(tester, 'Добавь задачу «Отчёт» на завтра');
    expect(find.byKey(const Key('selected-task-strip')), findsOneWidget);
    expect(find.byKey(const Key('task-back')), findsOneWidget);
    await tester.tap(find.byKey(const Key('mode-document')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('task-back')));
    await tester.pumpAndSettle();
    expect(h.assistant.selectedTaskId, isNull);
    expect(find.byKey(const Key('selected-task-strip')), findsNothing);
    expect(find.byKey(const Key('task-back')), findsNothing);
    expect(find.byKey(const Key('history-rail')), findsOneWidget);
    final field = tester.widget<TextField>(
      find.byKey(const Key('assistant-input')),
    );
    expect(field.focusNode!.hasFocus, isTrue);
  });

  testWidgets('на телефоне «назад» заменяет меню, пока открыта задача',
      (tester) async {
    await _pump(tester, size: _phone);
    expect(find.byKey(const Key('menu-button')), findsOneWidget);
    await _say(tester, 'Добавь задачу «Отчёт» на завтра');
    expect(find.byKey(const Key('menu-button')), findsNothing);
    expect(find.text('Задачи › «её»'), findsOneWidget);

    await tester.tap(find.byKey(const Key('task-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('menu-button')), findsOneWidget);
  });

  testWidgets('хроника — под шапкой, по центру колонки сессии', (tester) async {
    for (final size in <Size>[_desktop, _laptop, _phone]) {
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, size: size);
      await _say(tester, 'Покажи задачи');
      await _say(tester, 'Привет');
      await _say(tester, 'Покажи задачи');

      final rail = tester.getRect(find.byKey(const Key('history-rail')));
      final persona = tester.getRect(find.byKey(const Key('session-title')));
      final composer =
          tester.getRect(find.byKey(const Key('assistant-composer')));
      // Под строкой шапки, над лентой.
      expect(
        rail.top,
        greaterThanOrEqualTo(persona.bottom),
        reason: 'ширина ${size.width}',
      );
      expect(rail.bottom, lessThan(140), reason: 'ширина ${size.width}');
      // По центру колонки сессии (между меню и «Сегодня»): там же, где
      // центр поля ввода.
      expect(
        (rail.center.dx - composer.center.dx).abs(),
        lessThan(2),
        reason: 'ширина ${size.width}',
      );
    }
  });

  group('расширения включаются и выключаются без сброса', () {
    Future<void> toggleCalculator(WidgetTester tester) async {
      await openSettings(tester);
      final tile = find.byKey(const ValueKey<String>('extension-calc'));
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await tester.pumpAndSettle();
      await backToSession(tester);
    }

    testWidgets('история, выбор, черновик и ожидание задач целы',
        (tester) async {
      final store = InMemorySettingsStore();
      final h = await _pump(tester, settings: store, calculator: true);

      await _say(tester, '2+2');
      expect(outsideDrawer(find.text('2 + 2 = 4')), findsOneWidget);
      await _say(tester, 'Добавь задачу купить хлеб');
      final selected = h.assistant.selectedTaskId;
      expect(selected, isNotNull);
      // Задачи ждут «да» на свой вопрос.
      await _say(tester, 'я купил хлеб');
      expect(
        outsideDrawer(find.textContaining('Отметить «Купить хлеб»')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('assistant-input')),
        'черновик',
      );
      await tester.pump();

      await toggleCalculator(tester);

      expect(h.assistant.extensions.isEnabled('calc'), isFalse);
      expect((await store.load()).disabledExtensions, <String>{'calc'});
      expect(
        outsideDrawer(find.text('2 + 2 = 4')),
        findsOneWidget,
        reason: 'история',
      );
      expect(find.text('Добавь задачу купить хлеб'), findsWidgets);
      expect(h.assistant.selectedTaskId, selected, reason: 'выбор');
      expect(find.byKey(const Key('selected-task-strip')), findsOneWidget);
      final field = tester.widget<TextField>(
        find.byKey(const Key('assistant-input')),
      );
      expect(field.controller!.text, 'черновик', reason: 'черновик');
      expect(
        h.assistant.session.pendingConfirmation?.connectorId,
        TasksConnector.id,
        reason: 'ожидание другого коннектора не снято',
      );

      await _say(tester, 'да');
      expect(await _status(h.tasks, selected!), TaskStatus.done);

      await _say(tester, '3+3');
      expect(find.text('3 + 3 = 6'), findsNothing, reason: 'выключен');

      await toggleCalculator(tester);
      expect((await store.load()).disabledExtensions, isEmpty);
      await _say(tester, '3+3');
      expect(outsideDrawer(find.text('3 + 3 = 6')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('выбор из сохранённых настроек применяется при запуске',
        (tester) async {
      final store = InMemorySettingsStore();
      await store.save(const AppSettings(disabledExtensions: <String>{'calc'}));
      final h = await _pump(tester, settings: store, calculator: true);
      expect(h.assistant.extensions.isEnabled('calc'), isFalse);
      expect(h.assistant.extensions.isEnabled(TasksConnector.id), isTrue);
      await _say(tester, '2+2');
      expect(find.text('2 + 2 = 4'), findsNothing);
    });

    testWidgets('задачи выключить нельзя', (tester) async {
      await _pump(tester, calculator: true);
      await openSettings(tester);
      final tile = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey<String>('extension-tasks')),
      );
      expect(tile.value, isTrue);
      expect(tile.onChanged, isNull);
    });
  });
}
