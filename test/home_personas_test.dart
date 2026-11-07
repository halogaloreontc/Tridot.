import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/replies/reply_library.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';
import 'package:local_assistant/core/storage/task_repository.dart';

/// Часы, которые тест переводит сам: смена дня при открытом приложении.
final class _MutableClock implements Clock {
  _MutableClock(this.value);

  DateTime value;

  @override
  DateTime now() => value;
}

/// Запись задачи с задержкой: ответ помощника готовится заметное время.
final class _SlowRepository implements TaskRepository {
  final InMemoryTaskRepository _inner = InMemoryTaskRepository();
  Duration delay = Duration.zero;

  @override
  Future<List<Task>> list() => _inner.list();

  @override
  Future<Task?> get(String id) => _inner.get(id);

  @override
  Future<void> save(Task task) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    await _inner.save(task);
  }
}

final class _Harness {
  _Harness(this.tasks, this.assistant);

  final TaskService tasks;
  final AssistantController assistant;
}

const _tall = Size(1300, 2400);

Future<_Harness> _pump(
  WidgetTester tester, {
  required SettingsStore settings,
  TaskRepository? repository,
  Clock? clock,
  Size size = _tall,
  Key? key,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final time = clock ?? FixedClock(DateTime(2026, 11, 4, 12));
  final tasks = TaskService(
    repository: repository ?? InMemoryTaskRepository(),
    clock: time,
  );
  final assistant = AssistantController(
    connectors: <Connector>[
      TasksConnector(taskService: tasks, parser: ScenarioParser(clock: time)),
      const CalculatorConnector(),
      TalkConnector(taskService: tasks),
    ],
    clock: time,
  );
  await tester.pumpWidget(
    MaterialApp(
      key: key,
      theme: AssistantTheme.dark(),
      home: HomePage(
        assistant: assistant,
        tasks: tasks,
        clock: time,
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

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('nav-settings')));
  await tester.pumpAndSettle();
}

Future<void> _openTasks(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('nav-tasks')));
  await tester.pumpAndSettle();
}

Future<void> _tapSetting(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey<String>(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

/// История чата сверху вниз так, как она нарисована: автор (или `user`)
/// и готовый текст. Лента перевёрнута, поэтому порядок дерева — от
/// новых к старым.
List<String> _history(WidgetTester tester) {
  final rows = <String>[];
  String? author;
  for (final widget in tester.allWidgets) {
    final key = widget.key;
    if (key is ValueKey<String> && key.value.startsWith('message-author-')) {
      author = key.value.substring('message-author-'.length);
    }
    if (widget is SelectableText) {
      rows.add('${author ?? 'user'}: ${widget.data}');
      author = null;
    }
  }
  return rows.reversed.toList();
}

String _draft(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const Key('assistant-input')))
    .controller!
    .text;

/// Кто выбран в «Кому:» (`null` — переключателя нет).
String? _addressee(WidgetTester tester) {
  if (find.byKey(const Key('addressee-switch')).evaluate().isEmpty) {
    return null;
  }
  for (final persona in <String>['rio', 'noda']) {
    final semantics = tester.widget<Semantics>(
      find
          .ancestor(
            of: find.byKey(Key('addressee-$persona')),
            matching: find.byType(Semantics),
          )
          .first,
    );
    if (semantics.properties.selected ?? false) return persona;
  }
  return null;
}

/// Всё, что смена настроек помощников не должна трогать.
Future<Map<String, Object?>> _snapshot(
  WidgetTester tester,
  _Harness h,
) async {
  final pending = h.assistant.session.pendingConfirmation;
  final choice = h.assistant.extensions.choice;
  return <String, Object?>{
    'tasks': <Map<String, dynamic>>[
      for (final task in await h.tasks.listAll()) task.toJson(),
    ],
    'history': _history(tester),
    'selected': h.assistant.selectedTaskId,
    'strip': find.byKey(const Key('selected-task-strip')).evaluate().length,
    'draft': _draft(tester),
    'pending': pending == null
        ? null
        : '${pending.connectorId}/${pending.commandId}/${pending.itemId}',
    'disabled': choice.disabled.toList()..sort(),
    'enabled': choice.enabled.toList()..sort(),
    'composer': find.byKey(const Key('assistant-composer')).evaluate().length,
    'addressee': _addressee(tester),
  };
}

Task _overdue(String title) => Task(
      id: 'overdue-$title',
      title: title,
      status: TaskStatus.planned,
      priority: TaskPriority.normal,
      dueAt: DateTime(2026, 11, 3),
      duePrecision: DuePrecision.date,
      createdAt: DateTime(2026, 11, 1),
      updatedAt: DateTime(2026, 11, 1),
    );

void main() {
  group('Liorio и Noda в чате', () {
    testWidgets('приветствие и ответы подписаны помощником', (tester) async {
      await _pump(tester, settings: InMemorySettingsStore());
      expect(_history(tester).single, startsWith('rio: Я готов к работе.'));
      expect(find.text('Liorio'), findsWidgets);

      await _say(tester, 'Добавь задачу купить хлеб');
      await _say(tester, 'Noda, покажи задачи');
      final history = _history(tester);
      expect(history[1], 'user: Добавь задачу купить хлеб');
      expect(history[2], 'rio: Создал задачу «Купить хлеб».');
      expect(history[3], 'user: Noda, покажи задачи');
      expect(history[4], startsWith('noda: '));
      expect(history[4], contains('«Купить хлеб»'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('подпись Liorio с меткой «L», название Связной в меню',
        (tester) async {
      await _pump(tester, settings: InMemorySettingsStore());
      final author = find.byKey(const ValueKey<String>('message-author-rio'));
      expect(author, findsOneWidget);
      expect(
        find.descendant(of: author, matching: find.text('Liorio')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: author, matching: find.text('L')),
        findsOneWidget,
      );
      expect(find.text('Rio'), findsNothing);
      expect(find.text('R'), findsNothing);
      expect(find.byKey(const ValueKey<String>('app-name')), findsOneWidget);
      expect(find.text('Связной'), findsOneWidget);
      expect(find.text('Qenqrit'), findsNothing);
      expect(find.text('Помощник'), findsNothing);
    });

    testWidgets('основной из сохранённых настроек приветствует сам',
        (tester) async {
      final store = InMemorySettingsStore();
      await store.save(
        const AppSettings(personas: PersonaSettings(mainPersona: 'noda')),
      );
      await _pump(tester, settings: store);
      expect(_history(tester).single, startsWith('noda: '));
    });

    testWidgets('адресат в поле ввода: только в дуэте и только в этом чате',
        (tester) async {
      final store = InMemorySettingsStore();
      await _pump(tester, settings: store);
      expect(find.byKey(const Key('addressee-switch')), findsOneWidget);
      await tester.tap(find.byKey(const Key('addressee-noda')));
      await tester.pump();
      await _say(tester, '2+2');
      expect(_history(tester).last, startsWith('noda: '));
      // Обращение по имени важнее выбора в поле.
      await _say(tester, 'Лиорио, 3+3');
      expect(_history(tester).last, 'rio: 3 + 3 = 6');
      expect(_addressee(tester), 'rio', reason: 'к кому обратились');
      expect(
        (await store.load()).toJson().toString(),
        isNot(contains('addressee')),
        reason: 'адресат не сохраняется',
      );

      await _openSettings(tester);
      await _tapSetting(tester, 'assistant-mode-solo');
      await _openTasks(tester);
      expect(find.byKey(const Key('addressee-switch')), findsNothing);
      await _say(tester, 'Noda, 4+4');
      expect(_history(tester).last, startsWith('rio: '), reason: 'соло');
      expect(tester.takeException(), isNull);
    });

    testWidgets('крупный шрифт и узкий экран: подписи и выбор адресата',
        (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _pump(
        tester,
        settings: InMemorySettingsStore(),
        size: const Size(320, 640),
      );
      await _say(tester, 'Нода, добавь задачу «Купить хлеб и молоко»');
      expect(tester.takeException(), isNull);
      // В чате задачи на телефоне вместо меню — «назад».
      await tester.tap(find.byKey(const Key('task-back')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menu-button')));
      await tester.pumpAndSettle();
      await _openSettings(tester);
      for (final key in <String>['style-noda-business', 'address-ty']) {
        await _tapSetting(tester, key);
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('к кому обратились, тот и продолжает', () {
    testWidgets('обращение по имени переключает «Кому:» и держится в чате',
        (tester) async {
      await _pump(tester, settings: InMemorySettingsStore());
      expect(_addressee(tester), 'rio');

      await _say(tester, 'Нода, расскажи шутку');
      expect(_history(tester).last, startsWith('noda: '));
      expect(_addressee(tester), 'noda');

      for (final text in <String>['ещё шутку', '2+2', 'покажи задачи']) {
        await _say(tester, text);
        expect(_history(tester).last, startsWith('noda: '), reason: text);
        expect(_addressee(tester), 'noda', reason: text);
      }

      await _say(tester, 'спасибо, Лиорио');
      expect(_history(tester).last, startsWith('rio: '));
      expect(_addressee(tester), 'rio');
      await _say(tester, '3+3');
      expect(_history(tester).last, 'rio: 3 + 3 = 6');

      await _say(tester, 'говори короче, Нода');
      expect(_addressee(tester), 'noda');
      await _say(tester, 'Лио, 4+4');
      expect(_addressee(tester), 'rio');
      // Нажатие на переключатель работает, как раньше.
      await tester.tap(find.byKey(const Key('addressee-noda')));
      await tester.pump();
      expect(_addressee(tester), 'noda');
      await _say(tester, '5+5');
      expect(_history(tester).last, startsWith('noda: '));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        '«пусть отвечает Лиорио», когда Лиорио и так основной, — снова Liorio',
        (tester) async {
      await _pump(tester, settings: InMemorySettingsStore());
      await _say(tester, 'Нода, привет');
      expect(_addressee(tester), 'noda');
      await _say(tester, 'пусть отвечает Лиорио');
      expect(_history(tester).last, startsWith('rio: '));
      expect(_addressee(tester), 'rio');
      await _say(tester, '2+2');
      expect(_history(tester).last, 'rio: 2 + 2 = 4');
    });

    testWidgets('«Рио де Жанейро …» — город, адресат не меняется',
        (tester) async {
      await _pump(tester, settings: InMemorySettingsStore());
      await _openSettings(tester);
      await _tapSetting(tester, 'main-persona-noda');
      await _openTasks(tester);
      expect(_addressee(tester), 'noda');
      await _say(tester, 'Рио де Жанейро красивый город');
      expect(_addressee(tester), 'noda');
      await _say(tester, '2+2');
      expect(_history(tester).last, startsWith('noda: '));
    });

    testWidgets(
        '«спасибо, Лиорио» на вопрос Noda — переключает «Кому:» на Liorio',
        (tester) async {
      final h = await _pump(tester, settings: InMemorySettingsStore());
      await h.tasks.create(title: 'Купить хлеб');
      await _say(tester, 'Нода, я купил хлеб');
      expect(_addressee(tester), 'noda');
      await _say(tester, 'спасибо, Лиорио');
      expect(_history(tester).last, startsWith('rio: '));
      expect(_addressee(tester), 'rio');
      expect(h.assistant.session.pendingConfirmation, isNotNull);
      await _say(tester, 'да, Лио');
      expect(_history(tester).last, startsWith('rio: '));
      expect(await h.tasks.listActive(), isEmpty);
      await _say(tester, '2+2');
      expect(_history(tester).last, 'rio: 2 + 2 = 4');
    });

    testWidgets('новый чат сбрасывает адресата', (tester) async {
      await _pump(tester, settings: InMemorySettingsStore());
      await _say(tester, 'Нода, 2+2');
      expect(_addressee(tester), 'noda');
      await _openSettings(tester);
      await _tapSetting(tester, 'clear-chat');
      await tester
          .tap(find.byKey(const ValueKey<String>('clear-chat-confirm')));
      await tester.pumpAndSettle();
      await _openTasks(tester);
      expect(_addressee(tester), 'rio');
      await _say(tester, '2+2');
      expect(_history(tester).last, startsWith('rio: '));
    });

    testWidgets('на «да» отвечает спросивший, адресат не меняется',
        (tester) async {
      final h = await _pump(tester, settings: InMemorySettingsStore());
      await h.tasks.create(title: 'Купить хлеб');
      await _say(tester, 'Нода, я купил хлеб');
      expect(h.assistant.session.pendingConfirmation, isNotNull);
      await tester.tap(find.byKey(const Key('addressee-rio')));
      await tester.pump();
      await _say(tester, 'да');
      expect(_history(tester).last, startsWith('noda: '));
      expect(_addressee(tester), 'rio');
      expect(await h.tasks.listActive(), isEmpty);
    });

    testWidgets('соло: имя не закрепляется; в дуэте адресат прежний',
        (tester) async {
      await _pump(tester, settings: InMemorySettingsStore());
      await _say(tester, 'Нода, 2+2');
      await _openSettings(tester);
      await _tapSetting(tester, 'assistant-mode-solo');
      await _openTasks(tester);
      await _say(tester, 'Лиорио, 3+3');
      await _say(tester, '4+4');
      expect(_history(tester).last, startsWith('rio: '));
      await _openSettings(tester);
      await _tapSetting(tester, 'solo-persona-noda');
      await _tapSetting(tester, 'assistant-mode-duo');
      await _openTasks(tester);
      // В соло «Лиорио, …» — просто текст: адресат из дуэта — Noda.
      expect(_addressee(tester), 'noda');
      await _say(tester, '5+5');
      expect(_history(tester).last, startsWith('noda: '));
    });

    testWidgets(
        'смена основного: адресат, равный основному, — просто основной, '
        'выбор не сбрасывается', (tester) async {
      await _pump(tester, settings: InMemorySettingsStore());
      await _say(tester, 'Нода, 2+2');
      await _openSettings(tester);
      await _tapSetting(tester, 'main-persona-noda');
      await _openTasks(tester);
      expect(_addressee(tester), 'noda');
      await _say(tester, '3+3');
      expect(_history(tester).last, startsWith('noda: '));
      // Обращение к основному снимает выбор: дальше — тот, кто основной.
      await _say(tester, 'Нода, 4+4');
      await _openSettings(tester);
      await _tapSetting(tester, 'main-persona-rio');
      await _openTasks(tester);
      expect(_addressee(tester), 'rio');
      await _say(tester, '5+5');
      expect(_history(tester).last, startsWith('rio: '));
    });
  });

  group('адресат и загрузка настроек', () {
    for (final size in <Size>[
      const Size(320, 640),
      const Size(320, 568),
      const Size(320, 480),
    ]) {
      testWidgets(
          'выбор адресата нажимается без прокрутки: '
          '${size.width.toInt()}x${size.height.toInt()}, шрифт 2x',
          (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await _pump(tester, settings: InMemorySettingsStore(), size: size);
        // Без ensureVisible: переключатель всегда на виду.
        await tester.tap(find.byKey(const Key('addressee-noda')));
        await tester.pump();
        await _say(tester, '2+2');
        expect(_history(tester).last, startsWith('noda: '));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('нажатие на уже выбранного основного не закрепляет его',
        (tester) async {
      await _pump(tester, settings: InMemorySettingsStore());
      await tester.tap(find.byKey(const Key('addressee-rio')));
      await tester.pump();
      await _openSettings(tester);
      await _tapSetting(tester, 'main-persona-noda');
      await _openTasks(tester);
      await _say(tester, '2+2');
      expect(_history(tester).last, startsWith('noda: '));
    });

    testWidgets('сообщение до загрузки настроек ждёт их', (tester) async {
      final store = _SlowSettingsStore(
        const AppSettings(
          personas: PersonaSettings(
            mode: AssistantMode.solo,
            soloPersona: 'noda',
          ),
        ),
      );
      tester.view.physicalSize = _tall;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final time = FixedClock(DateTime(2026, 11, 4, 12));
      final tasks = TaskService(
        repository: InMemoryTaskRepository(),
        clock: time,
      );
      final assistant = AssistantController(
        connectors: <Connector>[
          TasksConnector(
            taskService: tasks,
            parser: ScenarioParser(clock: time),
          ),
          const CalculatorConnector(),
        ],
        clock: time,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AssistantTheme.dark(),
          home: HomePage(
            assistant: assistant,
            tasks: tasks,
            clock: time,
            settingsStore: store,
          ),
        ),
      );
      await tester.pump();
      await tester.enterText(find.byKey(const Key('assistant-input')), '2+2');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(_history(tester), <Object>[
        startsWith('noda: '),
        'user: 2+2',
        startsWith('noda: '),
      ]);
    });
  });

  group('смена настроек помощников ничего не сбрасывает', () {
    testWidgets(
        'все переключения: задачи, история, выбор, черновик, ожидание '
        'и расширения те же', (tester) async {
      final store = InMemorySettingsStore();
      await store.save(const AppSettings(disabledExtensions: <String>{'calc'}));
      final h = await _pump(tester, settings: store);
      await h.tasks.create(title: 'Отчёт', dueAt: DateTime(2026, 11, 5, 10));
      await _say(tester, 'Добавь задачу купить хлеб');
      // Адресат — Noda: к ней обратились по имени, дальше пишем ей.
      await _say(tester, 'Нода, покажи задачи');
      // Последнее сообщение — вопрос задач: ждём «да».
      await _say(tester, 'я купил хлеб');
      expect(h.assistant.session.pendingConfirmation, isNotNull);
      expect(_history(tester).last, startsWith('noda: '));
      await tester.enterText(
        find.byKey(const Key('assistant-input')),
        'черновик',
      );
      await tester.pump();
      final before = await _snapshot(tester, h);
      expect(before['selected'], isNotNull);
      expect(before['addressee'], 'noda');
      expect((before['history']! as List<String>).length, 7);

      for (final key in <String>[
        'assistant-mode-solo',
        'solo-persona-noda',
        'solo-persona-rio',
        'assistant-mode-duo',
        'main-persona-noda',
        'main-persona-rio',
        for (final persona in <String>['rio', 'noda'])
          for (final style in <String>[
            'friendly',
            'brief',
            'business',
            'neutral',
          ])
            'style-$persona-$style',
        'address-ty',
        'address-vy',
        'setting-emoji',
        'setting-emoji',
        'jokes-normal',
        'jokes-off',
        'jokes-rare',
      ]) {
        await _openSettings(tester);
        await _tapSetting(tester, key);
        await _openTasks(tester);
        final now = await _snapshot(tester, h);
        // В соло переключателя нет: адресат проверяется после возврата в
        // дуэт.
        if (now['addressee'] == null) now['addressee'] = before['addressee'];
        expect(now, before, reason: 'после «$key»');
      }
      expect(tester.takeException(), isNull);

      // Стили вернулись к начальным, ожидание живо, адресат — Noda.
      final saved = (await store.load()).personas;
      expect(saved.styleOf(Personas.liorio), 'neutral');
      expect(saved.styleOf(Personas.noda), 'neutral');
      await _say(tester, 'да');
      final done = (await h.tasks.listAll())
          .firstWhere((Task t) => t.title == 'Купить хлеб');
      expect(done.status, TaskStatus.done);
      expect(_history(tester).last, startsWith('noda: '));
    });

    testWidgets(
        'просьбы в беседе идут тем же путём, что экран настроек, и ничего '
        'не сбрасывают', (tester) async {
      final store = InMemorySettingsStore();
      await store.save(const AppSettings(disabledExtensions: <String>{'calc'}));
      final h = await _pump(tester, settings: store);
      await h.tasks.create(title: 'Отчёт', dueAt: DateTime(2026, 11, 5, 10));
      await _say(tester, 'Добавь задачу купить хлеб');
      final before = await _snapshot(tester, h);
      expect(before['selected'], isNotNull);

      final requests = <String, bool Function(PersonaSettings)>{
        'говори короче': (PersonaSettings p) =>
            p.styleOf(Personas.liorio) == 'brief',
        'Нода, говори официально': (PersonaSettings p) =>
            p.styleOf(Personas.noda) == 'business',
        'давай на ты': (PersonaSettings p) =>
            p.address == ReplyAddress.informal,
        'без смайликов': (PersonaSettings p) => !p.emoji,
        'шути больше': (PersonaSettings p) => p.jokes == JokeFrequency.normal,
        'Noda будь основной': (PersonaSettings p) => p.mainPersona == 'noda',
        'пусть отвечает Лиорио': (PersonaSettings p) => p.mainPersona == 'rio',
      };
      var history = _history(tester);
      for (final MapEntry(key: text, value: check) in requests.entries) {
        await _say(tester, text);
        final saved = (await store.load()).personas;
        expect(check(saved), isTrue, reason: text);
        expect(h.assistant.personas, saved, reason: text);
        final now = await _snapshot(tester, h);
        for (final key in <String>[
          'tasks',
          'selected',
          'strip',
          'draft',
          'pending',
          'disabled',
          'enabled',
          'composer',
        ]) {
          expect(now[key], before[key], reason: '$key после «$text»');
        }
        // Старые сообщения не переписаны: добавились только просьба и ответ.
        final after = _history(tester);
        expect(after.sublist(0, history.length), history, reason: text);
        expect(after.length, history.length + 2, reason: text);
        history = after;
        if (text == 'Нода, говори официально') {
          expect(_addressee(tester), 'noda', reason: 'обратились по имени');
        }
      }
      expect(_history(tester).last, startsWith('rio: '));
      // «Пусть отвечает Лиорио»: основной — Liorio, выбор Noda снят.
      expect(_addressee(tester), 'rio');
      await _say(tester, 'покажи задачи');
      expect(_history(tester).last, startsWith('rio: '));

      // Экран настроек показывает то же, что попросили в чате.
      await _openSettings(tester);
      final selected = find.byKey(const ValueKey<String>('style-rio-brief'));
      await tester.ensureVisible(selected);
      expect(
        tester
            .widget<ChoiceChip>(
              find.descendant(of: selected, matching: find.byType(ChoiceChip)),
            )
            .selected,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('старые ответы сохраняют автора и текст', (tester) async {
      await _pump(tester, settings: InMemorySettingsStore());
      await _say(tester, 'Добавь задачу купить хлеб');
      final before = _history(tester);
      await _openSettings(tester);
      await _tapSetting(tester, 'main-persona-noda');
      await _tapSetting(tester, 'style-rio-business');
      await _tapSetting(tester, 'address-ty');
      await _openTasks(tester);
      expect(_history(tester), before);
      await _say(tester, 'Добавь задачу купить молоко');
      final after = _history(tester);
      expect(after.sublist(0, before.length), before);
      expect(after.last, startsWith('noda: '));
    });

    testWidgets('смена настроек и перезапуск: настройки и данные целы',
        (tester) async {
      final store = InMemorySettingsStore();
      final repository = InMemoryTaskRepository();
      await _pump(tester, settings: store, repository: repository);
      await _say(tester, 'Добавь задачу купить хлеб');
      await _openSettings(tester);
      await _tapSetting(tester, 'main-persona-noda');
      await _tapSetting(tester, 'style-noda-brief');
      await _tapSetting(tester, 'address-ty');
      final saved = await store.load();

      // Перезапуск: новые контроллер и экран над теми же хранилищами.
      final h = await _pump(
        tester,
        settings: store,
        repository: repository,
        key: const ValueKey<String>('после перезапуска'),
      );
      expect((await store.load()).personas, saved.personas);
      expect(h.assistant.personas, saved.personas);
      expect(
        (await h.tasks.listActive()).map((Task t) => t.title),
        <String>['Купить хлеб'],
      );
      expect(
          _history(tester).single,
          'noda: Готова. Пример: '
          '${AssistantController.exampleCommand}');
    });

    testWidgets('испорченный файл настроек: дуэт, основной Liorio, задачи целы',
        (tester) async {
      final repository = InMemoryTaskRepository();
      final service = TaskService(
        repository: repository,
        clock: FixedClock(DateTime(2026, 11, 4, 12)),
      );
      await service.create(title: 'Отчёт');
      final h = await _pump(
        tester,
        settings: _BrokenSettingsStore(),
        repository: repository,
      );
      expect(h.assistant.personas, const PersonaSettings());
      expect(_history(tester).single, startsWith('rio: '));
      expect(find.byKey(const Key('addressee-switch')), findsOneWidget);
      expect(
        (await h.tasks.listActive()).map((Task t) => t.title),
        <String>['Отчёт'],
      );
    });

    testWidgets('смена настроек во время ответа: ответ договаривается',
        (tester) async {
      final repository = _SlowRepository();
      final h = await _pump(
        tester,
        settings: InMemorySettingsStore(),
        repository: repository,
      );
      await tester.enterText(
        find.byKey(const Key('assistant-input')),
        'Черновик потом',
      );
      repository.delay = const Duration(seconds: 3);
      await tester.enterText(
        find.byKey(const Key('assistant-input')),
        'Добавь задачу купить хлеб',
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(find.byKey(const Key('working-message')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('working-message')),
          matching: find.byKey(const ValueKey<String>('message-author-rio')),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('nav-settings')));
      await tester.pump();
      await _tapSetting(tester, 'main-persona-noda');
      await _tapSetting(tester, 'style-rio-business');
      await tester.tap(find.byKey(const Key('nav-tasks')));
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();

      final history = _history(tester);
      expect(history.last, 'rio: Создал задачу «Купить хлеб».');
      expect(
        (await h.tasks.listActive()).map((Task t) => t.title),
        <String>['Купить хлеб'],
      );
      expect(find.byKey(const Key('working-message')), findsNothing);
      repository.delay = Duration.zero;
      await _say(tester, 'Покажи задачи');
      expect(_history(tester).last, startsWith('noda: '));
      expect(tester.takeException(), isNull);
    });
  });

  group('второй помощник пишет первым о просроченных задачах', () {
    testWidgets('при открытии, один раз, без дублей после смены настроек',
        (tester) async {
      final store = InMemorySettingsStore();
      final repository = InMemoryTaskRepository();
      await repository.save(_overdue('Отчёт'));
      await repository.save(_overdue('Счёт'));
      await _pump(tester, settings: store, repository: repository);

      List<String> notices() => _history(tester)
          .where((String m) => m.contains('просроченные задачи'))
          .toList();
      expect(notices(), hasLength(1));
      expect(notices().single, startsWith('noda: '), reason: 'второй — Noda');
      expect(notices().single, contains('«Отчёт», «Счёт»'));
      expect((await store.load()).noticeDay, '2026-11-04');

      await _openSettings(tester);
      for (final key in <String>[
        'main-persona-noda',
        'assistant-mode-solo',
        'assistant-mode-duo',
        'style-noda-business',
      ]) {
        await _tapSetting(tester, key);
      }
      await _openTasks(tester);
      expect(notices(), hasLength(1), reason: 'смена настроек не повторяет');

      // Перезапуск в тот же день — тоже без повтора.
      await _pump(
        tester,
        settings: store,
        repository: repository,
        key: const ValueKey<String>('снова'),
      );
      expect(notices(), isEmpty);
    });

    testWidgets('в соло пишет единственный помощник', (tester) async {
      final store = InMemorySettingsStore();
      await store.save(
        const AppSettings(
          personas: PersonaSettings(
            mode: AssistantMode.solo,
            styles: <String, String>{'rio': 'neutral', 'noda': 'friendly'},
          ),
        ),
      );
      final repository = InMemoryTaskRepository();
      await repository.save(_overdue('Отчёт'));
      await _pump(tester, settings: store, repository: repository);
      expect(
        _history(tester).last,
        'rio: У вас 1 просроченная задача: «Отчёт».',
      );
    });

    testWidgets('смена дня во время ответа: напоминание после ответа',
        (tester) async {
      final clock = _MutableClock(DateTime(2026, 11, 4, 23, 59, 50));
      final repository = _SlowRepository();
      await repository.save(
        _overdue('Отчёт').copyWith(dueAt: DateTime(2026, 11, 4)),
      );
      await _pump(
        tester,
        settings: InMemorySettingsStore(),
        repository: repository,
        clock: clock,
      );
      repository.delay = const Duration(seconds: 30);
      await tester.enterText(
        find.byKey(const Key('assistant-input')),
        'Добавь задачу купить хлеб',
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      clock.value = DateTime(2026, 11, 5, 0, 0, 5);
      await tester.pump(const Duration(seconds: 15));
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      final history = _history(tester);
      expect(history.sublist(1), <Object>[
        'user: Добавь задачу купить хлеб',
        'rio: Создал задачу «Купить хлеб».',
        startsWith('noda: '),
      ]);
      expect(history.last, contains('1 просроченная задача'));
      expect(history.last, contains('«Отчёт»'));
    });

    testWidgets('без просроченных — молчит; новый день — новое сообщение',
        (tester) async {
      final clock = _MutableClock(DateTime(2026, 11, 4, 12));
      final store = InMemorySettingsStore();
      final repository = InMemoryTaskRepository();
      // Срок — сегодня без времени: просрочена станет только завтра.
      await repository.save(
        _overdue('Отчёт').copyWith(dueAt: DateTime(2026, 11, 4)),
      );
      await _pump(
        tester,
        settings: store,
        repository: repository,
        clock: clock,
      );
      expect(_history(tester), hasLength(1));
      clock.value = DateTime(2026, 11, 5, 0, 0, 2);
      await tester.pump(const Duration(hours: 13));
      await tester.pumpAndSettle();
      expect(_history(tester).last, contains('1 просроченная задача'));
      expect((await store.load()).noticeDay, '2026-11-05');
    });
  });
}

/// Хранилище настроек, которое читает испорченный файл: значения по
/// умолчанию, как у [JsonSettingsStore].
final class _BrokenSettingsStore implements SettingsStore {
  @override
  Future<AppSettings> load() async => AppSettings.fromJson(<String, dynamic>{
        'assistant_mode': 12,
        'main_persona': 'кто-то',
        'persona_styles': 'всё',
        'address': null,
        'emoji': 'да',
      });

  @override
  Future<void> save(AppSettings settings) async {}
}

/// Настройки читаются заметное время: сообщение успевают отправить раньше.
final class _SlowSettingsStore implements SettingsStore {
  _SlowSettingsStore(this._value);

  AppSettings _value;

  @override
  Future<AppSettings> load() async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    return _value;
  }

  @override
  Future<void> save(AppSettings settings) async => _value = settings;
}
