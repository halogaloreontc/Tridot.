import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/app/widgets/status_cube.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';
import 'package:local_assistant/core/storage/task_repository.dart';

final class _BrokenRepository implements TaskRepository {
  @override
  Future<List<Task>> list() async => throw const FormatException('битый файл');

  @override
  Future<Task?> get(String id) async => null;

  @override
  Future<void> save(Task task) async {}
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
    taskService: tasks,
    parser: ScenarioParser(clock: _clock),
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
    expect(find.byKey(const Key('status-cube')), findsOneWidget);
    expect(find.byKey(const Key('history-rail')), findsOneWidget);
    expect(find.byKey(const Key('assistant-composer')), findsOneWidget);
    for (final title in <String>[
      'Обзор',
      'Проекты',
      'Задачи',
      'Планирование',
      'Хранилище',
      'Настройки',
    ]) {
      expect(find.text(title), findsWidgets, reason: title);
    }

    for (final section in AppSection.values) {
      await tester.tap(find.byKey(Key('nav-${section.name}')));
      await tester.pumpAndSettle();
      final composer = find.byKey(const Key('assistant-composer'));
      expect(
        composer,
        section == AppSection.tasks ? findsOneWidget : findsNothing,
        reason: section.name,
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

  testWidgets('пример из приветствия создаёт и выбирает задачу',
      (tester) async {
    await _pump(tester);
    expect(
      find.textContaining(AssistantController.exampleCommand),
      findsOneWidget,
    );

    await _say(tester, AssistantController.exampleCommand);

    expect(
      find.text('Создал задачу «Позвонить клиенту» на завтра в 11:00.'),
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

    await tester.tap(find.byKey(const Key('quick-Новая задача')));
    await tester.pump();
    final field = tester.widget<TextField>(
      find.byKey(const Key('assistant-input')),
    );
    expect(field.controller!.text, 'Добавь задачу «» на завтра');
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

  testWidgets('на ноутбуке список задач открывается кнопкой', (tester) async {
    await _pump(tester, size: _laptop);
    expect(find.byKey(const Key('tasks-panel')), findsNothing);

    await tester.tap(find.byKey(const Key('tasks-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tasks-panel')), findsOneWidget);
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
    expect(find.text('12:00'), findsWidgets);

    await store.save(const AppSettings(showTimestamps: false));
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, settings: store);
    expect(find.text('12:00'), findsNothing);
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

  testWidgets('микрофон при пустом поле превращается в отправку при вводе',
      (tester) async {
    await _pump(tester);
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward), findsNothing);

    await tester.tap(find.byKey(const Key('assistant-send')));
    await tester.pump();
    expect(find.textContaining('Голосовой режим в разработке'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('assistant-input')),
      'Покажи задачи',
    );
    await tester.pump();
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    expect(find.byIcon(Icons.mic_none), findsNothing);

    await tester.tap(find.byKey(const Key('assistant-send')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('Активных задач пока нет.'), findsOneWidget);
  });

  testWidgets('«+» показывает диски и шаблоны команд', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const Key('templates-button')));
    await tester.pumpAndSettle();
    expect(find.text('Google Диск'), findsOneWidget);
    expect(find.text('Яндекс Диск'), findsOneWidget);
    expect(find.text('Задача на завтра в 10:00'), findsOneWidget);

    await tester.tap(find.text('Яндекс Диск'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('«Яндекс Диск» — следующий этап'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('templates-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Задача на завтра в 10:00'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.byKey(const Key('assistant-input')),
    );
    expect(field.controller!.text, 'Добавь задачу «» на завтра в 10:00');
  });
}
