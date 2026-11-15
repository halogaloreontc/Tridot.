import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/app/widgets/personas_section.dart';
import 'package:local_assistant/core/app_info.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
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

import 'support/home_nav.dart';

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
  ChatStore? chats,
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
        chatStore: chats ?? InMemoryChatStore(),
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

/// Настройки помощников: «Мой Tridot» → «Помощники».
Future<void> _openSettings(WidgetTester tester) =>
    openMyRelay(tester, 'assistants');

/// Обратно в сессию.
Future<void> _openTasks(WidgetTester tester) => backToSession(tester);

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
      rows.add(
        '${author ?? 'user'}: ${widget.data ?? widget.textSpan?.toPlainText()}',
      );
      author = null;
    }
  }
  return rows.reversed.toList();
}

String _draft(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const Key('assistant-input')))
    .controller!
    .text;

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
    // Продолжение разговора с тем, к кому обратились по имени.
    'followUp': h.assistant.followUpPersonaId,
    'addressee-switch':
        find.byKey(const Key('addressee-switch')).evaluate().length,
  };
}

/// Все сохранённые чаты (ADR-010): id, родитель, адресат (старое поле:
/// интерфейс его больше не пишет) и сообщения —
/// автор, помощник, текст, ссылка. Смена настроек их не трогает.
Future<Map<String, Object?>> _chats(ChatStore store) async {
  await store.flush();
  final threads = await store.loadIndex()
    ..sort((ChatThread a, ChatThread b) => a.id.compareTo(b.id));
  return <String, Object?>{
    for (final thread in threads)
      thread.id: <String, Object?>{
        'parent': thread.parentTaskId,
        'addressee': thread.addressee,
        'messages': <String>[
          for (final m in await store.loadMessages(thread.id))
            '${m.author.name}/${m.personaId}: ${m.text} '
                '→ ${m.link?.chatId}',
        ],
      },
  };
}

/// Название задачи в шапке открытого чата задачи (`null` — главный чат).
String? _openChat(WidgetTester tester) {
  final title = find.byKey(const Key('task-chat-title'));
  if (title.evaluate().isEmpty) return null;
  return tester.widget<Text>(title).data;
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

/// Чей знак в пустой сессии (SessionHero): id помощника.
String _heroPersona(WidgetTester tester) => tester
    .widget<PersonaMark>(
      find
          .descendant(
            of: find.byKey(const Key('session-hero')),
            matching: find.byType(PersonaMark),
          )
          .first,
    )
    .persona
    .id;

void main() {
  group('Tridot: метки, имена и выбор рода Связной', () {
    // Над ответом — точка и имя цветом помощника (ADR-027), без буквы.
    String letter(WidgetTester tester, String id) {
      final row = find.byKey(ValueKey<String>('author-name-$id')).first;
      final dot = tester.widget<PersonaDot>(
        find.descendant(of: row, matching: find.byType(PersonaDot)),
      );
      expect(dot.persona.id, id);
      final name = tester
          .widget<Text>(find.descendant(of: row, matching: find.byType(Text)))
          .data!;
      return name.substring(0, 1);
    }

    testWidgets('над ответами — «С», «Л», «Н» цветом помощника',
        (tester) async {
      await _pump(tester, settings: InMemorySettingsStore());
      await _say(tester, '2+2');
      await _say(tester, 'Лиорио, 3+3');
      await _say(tester, 'Нода, 4+4');
      final history = _history(tester);
      expect(history[1], startsWith('sado: '));
      expect(history[3], startsWith('rio: '));
      expect(history[5], startsWith('noda: '));
      expect(letter(tester, 'sado'), 'С');
      expect(letter(tester, 'rio'), 'Л');
      expect(letter(tester, 'noda'), 'Н');
      final name = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('message-author-sado')),
          matching: find.text('Связной'),
        ),
      );
      expect(name.style?.color, AppPalette.dark.sado);
    });

    testWidgets('переименованная Нода: обращение и метка — по новому имени',
        (tester) async {
      final store = InMemorySettingsStore();
      await store.save(
        const AppSettings(
          personas: PersonaSettings(names: <String, String>{'noda': 'Мира'}),
        ),
      );
      await _pump(tester, settings: store);
      await _say(tester, 'Мира, 2+2');
      expect(_history(tester).last, startsWith('noda: '));
      expect(letter(tester, 'noda'), 'М');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('message-author-noda')),
          matching: find.text('Мира'),
        ),
        findsOneWidget,
      );
      // Прежнее имя — просто текст: отвечает Связной.
      await _say(tester, 'Нода, 3+3');
      expect(_history(tester).last, startsWith('sado: '));
    });

    testWidgets('переименование в «Помощниках» сразу меняет обращение',
        (tester) async {
      final store = InMemorySettingsStore();
      await _pump(tester, settings: store);
      await _openSettings(tester);
      final field = find.byKey(const ValueKey<String>('persona-name-rio'));
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      await tester.enterText(field, 'Склад');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.textContaining('занято обращением'), findsOneWidget);
      expect((await store.load()).personas.nameOf('rio'), 'Лиорио');
      await tester.enterText(field, 'Тим');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect((await store.load()).personas.nameOf('rio'), 'Тим');
      await _openTasks(tester);
      await _say(tester, 'Тим, 2+2');
      expect(_history(tester).last, startsWith('rio: '));
      expect(letter(tester, 'rio'), 'Т');
    });

    testWidgets('карточка выбора рода Связной: видна до выбора, потом исчезает',
        (tester) async {
      final store = InMemorySettingsStore();
      await _pump(tester, settings: store);
      final card = find.byKey(const Key('sado-gender-choice'));
      expect(card, findsOneWidget);
      await tester
          .tap(find.byKey(const ValueKey<String>('sado-gender-female')));
      await tester.pumpAndSettle();
      expect(card, findsNothing);
      final saved = (await store.load()).personas;
      expect(saved.sadoGenderChosen, isTrue);
      expect(saved.genderOf('sado'), ReplyGender.female);
      await _say(tester, 'Добавь задачу купить хлеб');
      expect(_history(tester).last, 'sado: Создала задачу «Купить хлеб».');

      // Род уже выбран — при новом запуске карточки нет.
      await _pump(tester, settings: store, key: UniqueKey());
      expect(card, findsNothing);
    });
  });

  group('Liorio и Noda в чате', () {
    testWidgets('пустая сессия — знак помощника; ответы подписаны',
        (tester) async {
      await _pump(tester, settings: InMemorySettingsStore());
      // Приветствие — пустая сессия, а не сообщение.
      expect(_history(tester), isEmpty);
      expect(find.textContaining('Я готов к работе'), findsNothing);
      expect(_heroPersona(tester), 'sado');
      expect(find.text('Связной'), findsWidgets);
      expect(find.text('Sado'), findsNothing, reason: 'имена кириллицей');

      await _say(tester, 'Добавь задачу купить хлеб');
      await _say(tester, 'Noda, покажи задачи');
      final history = _history(tester);
      expect(history[0], 'user: Добавь задачу купить хлеб');
      expect(history[1], 'sado: Создал задачу «Купить хлеб».');
      expect(history[2], 'user: Noda, покажи задачи');
      expect(history[3], startsWith('noda: '));
      expect(history[3], contains('«Купить хлеб»'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('подпись «Связной» с меткой «С», название Tridot в меню',
        (tester) async {
      await _pump(tester, settings: InMemorySettingsStore());
      await _say(tester, 'покажи задачи');
      final author = find.byKey(const ValueKey<String>('message-author-sado'));
      expect(author, findsOneWidget);
      expect(
        find.descendant(of: author, matching: find.text('Связной')),
        findsOneWidget,
      );
      // Точка помощника у имени — без буквы (ADR-027).
      expect(
        find.descendant(of: author, matching: find.byType(PersonaDot)),
        findsOneWidget,
      );
      // Ответ из зоны Лиорио (склад, пароли) подписан им — здесь их нет.
      expect(find.text('Rio'), findsNothing);
      expect(find.text('R'), findsNothing);
      expect(find.byKey(const ValueKey<String>('app-name')), findsOneWidget);
      expect(find.text(AppInfo.name), findsOneWidget);
      expect(find.text('Qenqrit'), findsNothing);
      expect(find.text('Помощник'), findsNothing);
    });

    testWidgets('Дуэт с Нодой из сохранённых настроек: встречает Связной',
        (tester) async {
      final store = InMemorySettingsStore();
      await store.save(
        const AppSettings(
          personas: PersonaSettings(teamMode: TeamMode.duo, duoHelper: 'noda'),
        ),
      );
      await _pump(tester, settings: store);
      expect(_history(tester), isEmpty);
      expect(_heroPersona(tester), 'sado');
      await _say(tester, 'покажи задачи');
      expect(_history(tester).last, startsWith('sado: '));
    });

    testWidgets(
        'выбора «Кому» нет: имя — для этой команды и разговора тем же '
        'навыком, в соло имя — просто текст', (tester) async {
      final store = InMemorySettingsStore();
      final h = await _pump(tester, settings: store);
      expect(find.byKey(const Key('addressee-switch')), findsNothing);
      await _say(tester, 'Нода, 2+2');
      expect(_history(tester).last, startsWith('noda: '));
      expect(_history(tester).last, contains('2 + 2 = 4'));
      await _say(tester, '3+3');
      expect(
        _history(tester).last,
        startsWith('noda: '),
        reason: 'калькулятор',
      );
      // Другая тема — отвечает Связной: невидимого адресата нет.
      await _say(tester, 'покажи задачи');
      expect(_history(tester).last, startsWith('sado: '));
      expect(h.assistant.followUpPersonaId, isNull);
      await _say(tester, 'Лиорио, 3+3');
      expect(_history(tester).last, 'rio: 3 + 3 = 6');
      expect(
        (await store.load()).toJson().toString(),
        isNot(contains('addressee')),
        reason: 'адресат не сохраняется',
      );

      await _openSettings(tester);
      await _tapSetting(tester, 'assistant-mode-solo');
      await _openTasks(tester);
      await _say(tester, 'Noda, 4+4');
      expect(_history(tester).last, startsWith('sado: '), reason: 'соло');
      expect(tester.takeException(), isNull);
    });

    testWidgets('крупный шрифт и узкий экран: подписи и обращение по имени',
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

  group('к кому обратились, тот и продолжает — тем же навыком', () {
    testWidgets('«Нода, расскажи шутку» → «ещё шутку» — Noda; другое — Связной',
        (tester) async {
      final h = await _pump(tester, settings: InMemorySettingsStore());
      await _say(tester, 'Нода, расскажи шутку');
      expect(_history(tester).last, startsWith('noda: '));
      await _say(tester, 'ещё шутку');
      expect(_history(tester).last, startsWith('noda: '));
      expect(h.assistant.followUpPersonaId, 'noda');

      for (final text in <String>['2+2', 'покажи задачи']) {
        await _say(tester, text);
        expect(_history(tester).last, startsWith('sado: '), reason: text);
      }
      expect(h.assistant.followUpPersonaId, isNull);

      await _say(tester, 'говори короче, Нода');
      expect(_history(tester).last, startsWith('noda: '));
      await _say(tester, 'Лио, 4+4');
      expect(_history(tester).last, 'rio: 4 + 4 = 8');
      await _say(tester, '5+5');
      expect(_history(tester).last, startsWith('rio: '));
      expect(tester.takeException(), isNull);
    });

    testWidgets('«Нода» без команды — следующая фраза ей', (tester) async {
      await _pump(tester, settings: InMemorySettingsStore());
      await _say(tester, 'Нода');
      expect(_history(tester).last, startsWith('noda: '));
      await _say(tester, '2+2');
      expect(_history(tester).last, startsWith('noda: '));
    });

    testWidgets(
        '«пусть отвечает Лиорио» — главный не меняется, калькулятор у Связной',
        (tester) async {
      final h = await _pump(tester, settings: InMemorySettingsStore());
      await _say(tester, 'Нода, привет');
      expect(h.assistant.followUpPersonaId, 'noda');
      await _say(tester, 'пусть отвечает Лиорио');
      expect(_history(tester).last, startsWith('noda: '));
      expect(_history(tester).last, contains('Связной'));
      await _say(tester, '2+2');
      expect(_history(tester).last, 'sado: 2 + 2 = 4');
    });

    testWidgets('«Рио де Жанейро …» — город, никто не назван', (tester) async {
      final h = await _pump(tester, settings: InMemorySettingsStore());
      await _openSettings(tester);
      await _tapSetting(tester, 'assistant-mode-duo');
      await _tapSetting(tester, 'duo-helper-noda');
      await _openTasks(tester);
      await _say(tester, 'Рио де Жанейро красивый город');
      expect(h.assistant.followUpPersonaId, isNull);
      await _say(tester, '2+2');
      expect(_history(tester).last, startsWith('sado: '));
    });

    testWidgets('«спасибо, Лиорио» на вопрос Noda — переспрашивает Liorio',
        (tester) async {
      final h = await _pump(tester, settings: InMemorySettingsStore());
      await h.tasks.create(title: 'Купить хлеб');
      await _say(tester, 'Нода, я купил хлеб');
      expect(h.assistant.followUpPersonaId, 'noda');
      await _say(tester, 'спасибо, Лиорио');
      expect(_history(tester).last, startsWith('rio: '));
      expect(h.assistant.session.pendingConfirmation, isNotNull);
      await _say(tester, 'да, Лио');
      expect(_history(tester).last, startsWith('rio: '));
      expect(await h.tasks.listActive(), isEmpty);
      await _say(tester, '2+2');
      expect(_history(tester).last, 'sado: 2 + 2 = 4');
    });

    testWidgets('новая сессия и очистка истории снимают продолжение',
        (tester) async {
      final h = await _pump(tester, settings: InMemorySettingsStore());
      await _say(tester, 'Нода, 2+2');
      expect(h.assistant.followUpPersonaId, 'noda');
      await tester.tap(find.byKey(const Key('new-session')));
      await tester.pumpAndSettle();
      expect(h.assistant.followUpPersonaId, isNull);
      await _say(tester, '3+3');
      expect(_history(tester).last, startsWith('sado: '));

      await _say(tester, 'Нода, 2+2');
      await openSettings(tester);
      await _tapSetting(tester, 'clear-chat');
      await tester
          .tap(find.byKey(const ValueKey<String>('clear-chat-confirm')));
      await tester.pumpAndSettle();
      await _openTasks(tester);
      expect(h.assistant.followUpPersonaId, isNull);
      await _say(tester, '2+2');
      expect(_history(tester).last, startsWith('sado: '));
    });

    testWidgets('на «да» отвечает спросивший', (tester) async {
      final h = await _pump(tester, settings: InMemorySettingsStore());
      await h.tasks.create(title: 'Купить хлеб');
      await _say(tester, 'Нода, я купил хлеб');
      expect(h.assistant.session.pendingConfirmation, isNotNull);
      await _say(tester, 'да');
      expect(_history(tester).last, startsWith('noda: '));
      expect(await h.tasks.listActive(), isEmpty);
    });

    testWidgets('соло: имя не закрепляется; в дуэте снова Связной',
        (tester) async {
      await _pump(tester, settings: InMemorySettingsStore());
      await _say(tester, 'Нода, 2+2');
      await _openSettings(tester);
      await _tapSetting(tester, 'assistant-mode-solo');
      await _openTasks(tester);
      await _say(tester, 'Лиорио, 3+3');
      await _say(tester, '4+4');
      expect(_history(tester).last, startsWith('sado: '));
      await _openSettings(tester);
      await _tapSetting(tester, 'assistant-mode-duo');
      await _openTasks(tester);
      // В соло «Лиорио, …» — просто текст; в дуэте калькулятор у Связной.
      await _say(tester, '5+5');
      expect(_history(tester).last, startsWith('sado: '));
    });

    testWidgets('смена режима: без имени отвечает тот, кто отвечает сейчас',
        (tester) async {
      final h = await _pump(tester, settings: InMemorySettingsStore());
      await _say(tester, 'Нода, 2+2');
      expect(h.assistant.followUpPersonaId, 'noda');
      await _openSettings(tester);
      await _tapSetting(tester, 'assistant-mode-solo');
      await _openTasks(tester);
      await _say(tester, '3+3');
      expect(_history(tester).last, startsWith('sado: '));
      await _openSettings(tester);
      await _tapSetting(tester, 'assistant-mode-trio');
      await _openTasks(tester);
      await _say(tester, '5+5');
      expect(_history(tester).last, startsWith('sado: '));
    });
  });

  group('обращение по имени на узком экране и загрузка настроек', () {
    for (final size in <Size>[
      const Size(320, 640),
      const Size(320, 568),
      const Size(320, 480),
    ]) {
      testWidgets(
          '«Нода, …» без переполнений: '
          '${size.width.toInt()}x${size.height.toInt()}, шрифт 2x',
          (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await _pump(tester, settings: InMemorySettingsStore(), size: size);
        expect(find.byKey(const Key('addressee-switch')), findsNothing);
        await _say(tester, 'Нода, 2+2');
        expect(_history(tester).last, startsWith('noda: '));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('сообщение до загрузки настроек ждёт их', (tester) async {
      final store = _SlowSettingsStore(
        const AppSettings(
          personas: PersonaSettings(teamMode: TeamMode.solo),
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
        'user: 2+2',
        startsWith('sado: '),
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
      // К Noda обратились по имени; разговор о задачах продолжает она.
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
      expect(before['followUp'], 'noda');
      expect((before['history']! as List<String>).length, 6);

      for (final key in <String>[
        'assistant-mode-solo',
        'assistant-mode-duo',
        'duo-helper-noda',
        'duo-helper-rio',
        'assistant-mode-trio',
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
        // Продолжение с Нодой снимает только Соло: она выключена и больше
        // не отвечает (ADR-016). Остальное не сбрасывается ничем.
        expect(
          <String, Object?>{...now}..remove('followUp'),
          <String, Object?>{...before}..remove('followUp'),
          reason: 'после «$key»',
        );
        if (key != 'assistant-mode-solo' && now['followUp'] != null) {
          expect(now['followUp'], 'noda', reason: 'после «$key»');
        }
      }
      expect(h.assistant.followUpPersonaId, isNull, reason: 'снято Соло');
      expect(tester.takeException(), isNull);

      // Стили вернулись к начальным, ожидание живо, на «да» — Noda.
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
            p.styleOf(Personas.sado) == 'brief',
        'Нода, говори официально': (PersonaSettings p) =>
            p.styleOf(Personas.noda) == 'business',
        'давай на ты': (PersonaSettings p) =>
            p.address == ReplyAddress.informal,
        'без смайликов': (PersonaSettings p) => !p.emoji,
        'шути больше': (PersonaSettings p) => p.jokes == JokeFrequency.normal,
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
          expect(
            h.assistant.followUpPersonaId,
            'noda',
            reason: 'обратились по имени',
          );
        }
      }
      // Продолжение Ноды короткое: «шути больше» — уже снова Связной.
      expect(_history(tester).last, startsWith('sado: '));
      expect(h.assistant.followUpPersonaId, isNull);
      await _say(tester, 'покажи задачи');
      expect(_history(tester).last, startsWith('sado: '));

      // Экран настроек показывает то же, что попросили в чате.
      await _openSettings(tester);
      final selected = find.byKey(const ValueKey<String>('style-sado-brief'));
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

    testWidgets(
        'чаты задач: смена настроек и перезапуск не трогают чаты и '
        'сообщения', (tester) async {
      final store = InMemorySettingsStore();
      final chats = InMemoryChatStore();
      final repository = InMemoryTaskRepository();
      final h = await _pump(
        tester,
        settings: store,
        repository: repository,
        chats: chats,
      );
      await _say(tester, 'Добавь задачу «Купить хлеб» на завтра');
      final bread = (await h.tasks.listActive()).single;
      final link = find.byKey(ValueKey<String>('open-task-chat-${bread.id}'));
      await tester.ensureVisible(link);
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(_openChat(tester), 'Купить хлеб');
      // В чате задачи обратились к Noda — разговор о задачах продолжает
      // она.
      await _say(tester, 'Нода, на пятницу в 10');
      await _say(tester, 'добавь задачу купить масло');
      expect(_history(tester).last, startsWith('noda: '));
      expect(h.assistant.followUpPersonaId, 'noda');
      final before = await _chats(chats);
      final history = _history(tester);
      expect(before.length, 3, reason: 'сессия и два чата задач');

      for (final key in <String>[
        'assistant-mode-solo',
        'assistant-mode-duo',
        'duo-helper-noda',
        'assistant-mode-trio',
        'style-rio-brief',
        'style-noda-business',
        'address-ty',
        'setting-emoji',
        'jokes-off',
      ]) {
        await _openSettings(tester);
        await _tapSetting(tester, key);
        await _openTasks(tester);
        expect(await _chats(chats), before, reason: 'после «$key»');
        expect(_openChat(tester), 'Купить хлеб', reason: 'после «$key»');
        expect(_history(tester), history, reason: 'после «$key»');
      }
      // Соло выключило Ноду: продолжение с ней снято и после возврата к
      // Трио не возвращается — она больше не отвечала.
      expect(h.assistant.followUpPersonaId, isNull);
      expect(tester.takeException(), isNull);

      // Перезапуск над теми же хранилищами: чаты те же, открыта новая
      // пустая сессия, прежняя — в меню.
      await _pump(
        tester,
        settings: store,
        repository: repository,
        chats: chats,
        key: const ValueKey<String>('после перезапуска'),
      );
      expect(await _chats(chats), before);
      expect(_openChat(tester), isNull);
      expect(_history(tester), isEmpty);
      final sessionId = onlySessionId(before.keys);
      final session = before[sessionId]! as Map<String, Object?>;
      await openSessionTitled(tester, 'Добавь задачу «Купить хлеб» на завтра');
      expect(
        _history(tester).length,
        (session['messages']! as List<String>).length,
      );
      await _openSettings(tester);
      await _tapSetting(tester, 'assistant-mode-solo');
      await _openTasks(tester);
      expect(await _chats(chats), before, reason: 'после перезапуска');
    });

    testWidgets('старые ответы сохраняют автора и текст', (tester) async {
      await _pump(tester, settings: InMemorySettingsStore());
      await _say(tester, 'Добавь задачу купить хлеб');
      final before = _history(tester);
      await _openSettings(tester);
      await _tapSetting(tester, 'assistant-mode-solo');
      await _tapSetting(tester, 'style-rio-business');
      await _tapSetting(tester, 'address-ty');
      await _openTasks(tester);
      expect(_history(tester), before);
      await _say(tester, 'Добавь задачу купить молоко');
      final after = _history(tester);
      expect(after.sublist(0, before.length), before);
      expect(after.last, startsWith('sado: '));
    });

    testWidgets('смена настроек и перезапуск: настройки и данные целы',
        (tester) async {
      final store = InMemorySettingsStore();
      final repository = InMemoryTaskRepository();
      await _pump(tester, settings: store, repository: repository);
      await _say(tester, 'Добавь задачу купить хлеб');
      await _openSettings(tester);
      await _tapSetting(tester, 'assistant-mode-solo');
      await _tapSetting(tester, 'style-sado-brief');
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
      // Новая пустая сессия — со знаком Связной (Соло); ответ — его голосом
      // и выбранным стилем.
      expect(_history(tester), isEmpty);
      expect(_heroPersona(tester), 'sado');
      await _say(tester, 'Добавь задачу купить молоко');
      expect(_history(tester).last, startsWith('sado: '));
    });

    testWidgets(
        'испорченный файл настроек: трио, встречает Связной, задачи целы',
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
      expect(_history(tester), isEmpty);
      expect(_heroPersona(tester), 'sado');
      expect(find.byKey(const Key('addressee-switch')), findsNothing);
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
          matching: find.byKey(const ValueKey<String>('message-author-sado')),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('drawer-my-relay')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('my-relay-tab-assistants')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _tapSetting(tester, 'assistant-mode-solo');
      await _tapSetting(tester, 'style-sado-business');
      await tester.tap(find.byKey(const Key('my-relay-back')));
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();

      final history = _history(tester);
      expect(history.last, 'sado: Создал задачу «Купить хлеб».');
      expect(
        (await h.tasks.listActive()).map((Task t) => t.title),
        <String>['Купить хлеб'],
      );
      expect(find.byKey(const Key('working-message')), findsNothing);
      repository.delay = Duration.zero;
      await _say(tester, 'Покажи задачи');
      expect(_history(tester).last, startsWith('sado: '));
      expect(tester.takeException(), isNull);
    });
  });

  group('просроченные — строкой в пустой сессии, а не сообщением', () {
    /// Знак у строки о просроченных: id помощника.
    String lineMark(WidgetTester tester) => tester
        .widget<PersonaMark>(
          find.descendant(
            of: find.byKey(const Key('session-hero-overdue')),
            matching: find.byType(PersonaMark),
          ),
        )
        .persona
        .id;

    testWidgets('при открытии: строка от второго, в сессии ничего нет',
        (tester) async {
      final store = InMemorySettingsStore();
      final repository = InMemoryTaskRepository();
      await repository.save(_overdue('Отчёт'));
      await repository.save(_overdue('Счёт'));
      await _pump(tester, settings: store, repository: repository);

      final line = find.byKey(const Key('session-hero-overdue'));
      expect(line, findsOneWidget);
      expect(find.text('Просрочены 2 задачи'), findsOneWidget);
      expect(lineMark(tester), 'noda', reason: 'второй — Noda');
      expect(_history(tester), isEmpty, reason: 'в сессию не пишется');
      expect(tester.getSize(line).height, greaterThanOrEqualTo(44));
      expect((await store.load()).noticeDay, isNull);

      await _openSettings(tester);
      for (final key in <String>[
        'assistant-mode-solo',
        'assistant-mode-duo',
        'style-noda-business',
      ]) {
        await _tapSetting(tester, key);
      }
      await _openTasks(tester);
      expect(_history(tester), isEmpty, reason: 'смена настроек не пишет');
      expect(line, findsOneWidget);
      expect(
        lineMark(tester),
        'sado',
        reason: 'в дуэте с Лиорио оповещения — у Связной',
      );

      // Перезапуск — та же строка, сообщений нет.
      await _pump(
        tester,
        settings: store,
        repository: repository,
        key: const ValueKey<String>('снова'),
      );
      expect(line, findsOneWidget);
      expect(_history(tester), isEmpty);

      // После первой команды пустой сессии (и строки) больше нет.
      await _say(tester, 'покажи задачи');
      expect(line, findsNothing);
      expect(
        _history(tester).where((String m) => m.contains('просроч')),
        hasLength(lessThanOrEqualTo(1)),
        reason: 'только ответ на «покажи задачи»',
      );
    });

    testWidgets('в соло — знак единственного помощника', (tester) async {
      final store = InMemorySettingsStore();
      await store.save(
        const AppSettings(
          personas: PersonaSettings(
            teamMode: TeamMode.solo,
            styles: <String, String>{'rio': 'neutral', 'noda': 'friendly'},
          ),
        ),
      );
      final repository = InMemoryTaskRepository();
      await repository.save(_overdue('Отчёт'));
      await _pump(tester, settings: store, repository: repository);
      expect(find.text('Просрочена 1 задача'), findsOneWidget);
      expect(lineMark(tester), 'sado');
      expect(_history(tester), isEmpty);
    });

    testWidgets('нажатие — «Мой Tridot» → «Сводка»', (tester) async {
      final repository = InMemoryTaskRepository();
      for (var i = 0; i < 5; i++) {
        await repository.save(_overdue('Дело $i'));
      }
      await _pump(
        tester,
        settings: InMemorySettingsStore(),
        repository: repository,
        size: const Size(390, 844),
      );
      expect(find.text('Просрочено 5 задач'), findsOneWidget);
      await tester.tap(find.byKey(const Key('session-hero-overdue')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('my-relay')), findsOneWidget);
      expect(find.byKey(const Key('my-relay-summary')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('смена дня во время ответа: в истории только команда и ответ',
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
      expect(_history(tester), <String>[
        'user: Добавь задачу купить хлеб',
        'sado: Создал задачу «Купить хлеб».',
      ]);
    });

    testWidgets('без просроченных — строки нет; новый день — появилась',
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
      expect(find.byKey(const Key('session-hero-overdue')), findsNothing);
      clock.value = DateTime(2026, 11, 5, 0, 0, 2);
      await tester.pump(const Duration(hours: 13));
      await tester.pumpAndSettle();
      expect(find.text('Просрочена 1 задача'), findsOneWidget);
      expect(_history(tester), isEmpty);
      expect((await store.load()).noticeDay, isNull);
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
