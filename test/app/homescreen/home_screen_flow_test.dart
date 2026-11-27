// Виджеты рабочего стола на главном экране (ADR-034): когда уходит снимок
// «Сегодня», как применяются отметки с виджета и что делают «открыть
// поле» и «начать слушать».
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/app/homescreen/home_screen_channel.dart';
import 'package:local_assistant/app/notify/notify_channel.dart';
import 'package:local_assistant/app/security/app_lock.dart';
import 'package:local_assistant/app/security/device_auth.dart';
import 'package:local_assistant/app/voice/voice_kit.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/notify/reminder_plan.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';
import 'package:local_assistant/core/voice/voice_recognizer.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_home_screen.dart';
import '../../support/fake_notify.dart';
import '../../support/fake_voice.dart';
import '../../support/home_nav.dart';

/// Понедельник, 16 ноября 2026, 12:00.
final _clock = FixedClock(DateTime(2026, 11, 16, 12));

const _inputKey = Key('assistant-input');

/// Системная проверка личности: ответ — когда тест разрешит.
final class _GatedAuth implements DeviceAuth {
  Completer<void> gate = Completer<void>();
  int asked = 0;

  @override
  Future<DeviceAuthStatus> status() async =>
      const DeviceAuthStatus(supported: true, credential: true);

  @override
  Future<DeviceAuthResult> authenticate(String reason) async {
    asked++;
    await gate.future;
    return DeviceAuthResult.ok;
  }

  @override
  Future<void> secureWindow(bool on) async {}
}

/// Настройки, которые читаются, только когда тест разрешит (медленный
/// диск при холодном запуске).
final class _SlowSettingsStore implements SettingsStore {
  final Completer<void> gate = Completer<void>();
  AppSettings _value = const AppSettings();

  @override
  Future<AppSettings> load() async {
    await gate.future;
    return _value;
  }

  @override
  Future<void> save(AppSettings settings) async => _value = settings;
}

final class _Home {
  _Home(
    this.tasks,
    this.settings,
    this.homeScreen,
    this.notify,
    this.assistant,
  );

  final AssistantController assistant;
  final TaskService tasks;
  final SettingsStore settings;
  final FakeHomeScreen homeScreen;
  final FakeNotify notify;
}

final _navigator = GlobalKey<NavigatorState>();

Future<_Home> _pump(
  WidgetTester tester,
  FakeHomeScreen homeScreen, {
  AppSettings settings = const AppSettings(),
  Future<void> Function(TaskService tasks)? prepare,
  VoiceKit? voice,
  AppLockController? lock,
  SettingsStore? settingsStore,
}) async {
  tester.view.physicalSize = const Size(400, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final tasks =
      TaskService(repository: InMemoryTaskRepository(), clock: _clock);
  await prepare?.call(tasks);
  final store = settingsStore ?? InMemorySettingsStore();
  await store.save(settings);
  final notify = FakeNotify(permission: NotifyPermission.granted);
  final assistant = AssistantController(
    extensions: ExtensionRegistry(
      connectors: <Connector>[
        TasksConnector(
          taskService: tasks,
          parser: ScenarioParser(clock: _clock),
        ),
      ],
    ),
    clock: _clock,
  );
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: _navigator,
      theme: AssistantTheme.dark(),
      builder: lock == null
          ? null
          : (BuildContext context, Widget? child) =>
              AppLockGate(controller: lock, child: child!),
      home: HomePage(
        assistant: assistant,
        tasks: tasks,
        clock: _clock,
        settingsStore: store,
        notify: notify,
        homeScreen: homeScreen,
        voice: voice,
        appLock: lock,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Home(tasks, store, homeScreen, notify, assistant);
}

Future<void> _say(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(_inputKey), text);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

/// Состояние приложения [states] по очереди; в конце теста — снова «на
/// экране», чтобы следующий начинал с него.
void _lifecycle(WidgetTester tester, List<AppLifecycleState> states) {
  addTearDown(
    () => tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed),
  );
  states.forEach(tester.binding.handleAppLifecycleStateChanged);
}

/// Приложение ушло в фон.
const List<AppLifecycleState> _toBackground = <AppLifecycleState>[
  AppLifecycleState.inactive,
  AppLifecycleState.hidden,
  AppLifecycleState.paused,
];

/// Приложение вернулось на экран.
const List<AppLifecycleState> _toForeground = <AppLifecycleState>[
  AppLifecycleState.hidden,
  AppLifecycleState.inactive,
  AppLifecycleState.resumed,
];

FocusNode _composer(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(_inputKey)).focusNode!;

/// Отметка на виджете через пять минут после создания задач.
final DateTime _tap = _clock.now().add(const Duration(minutes: 5));

HomeScreenOp _done(int seq, Task task) => HomeScreenOp(
      seq: seq,
      kind: HomeScreenOpKind.done,
      taskId: task.id,
      at: _tap,
    );

/// Голосовой ввод на подделках: модель уже скачана.
Future<(VoiceKit, FakeVoiceRecognizer)> _voice(
  WidgetTester tester, {
  FakeVoiceRecognizer? recognizer,
}) async {
  final temp = Directory.systemTemp.createTempSync('home_screen_flow');
  addTearDown(() => temp.deleteSync(recursive: true));
  final dir = p.join(temp.path, 'assistant', 'voice');
  final bytes = List<int>.generate(4000, (int i) => i % 251);
  final spec = fakeVoiceSpec(bytes);
  installFakeModelSync(dir, spec);
  final fake = recognizer ?? FakeVoiceRecognizer();
  final kit = fakeVoiceKit(
    recognizer: fake,
    downloader: FakeFileDownloader(bytes),
    spec: spec,
    dir: dir,
  );
  addTearDown(kit.dispose);
  await tester.runAsync(kit.refresh);
  return (kit, fake);
}

/// Готов к разговору: включён и про микрофон уже объяснено.
const _voiceReady = AppSettings(voiceInput: true, voiceMicExplained: true);

void main() {
  group('снимок', () {
    testWidgets('уходит после загрузки и после каждой перемены в задачах',
        (tester) async {
      final home = await _pump(tester, FakeHomeScreen());
      final fake = home.homeScreen;
      expect(fake.synced, hasLength(1));
      expect(fake.last['mode'], 'text');
      expect(fake.frame['count'], 0);
      expect(fake.frame['summary'], 'дел нет');
      expect(fake.titles, isEmpty);

      await _say(tester, 'позвонить маме сегодня в 18');
      expect(fake.synced, hasLength(2));
      expect(fake.titles, <String>['Позвонить маме']);
      expect(fake.frame['count'], 1);
      final rows = fake.frame['rows']! as List<Object?>;
      expect((rows.single! as Map<String, Object?>)['due'], '18:00');

      // Перемен нет — тот же снимок второй раз не отправляется.
      await _say(tester, 'покажи задачи');
      _lifecycle(tester, <AppLifecycleState>[
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      await tester.pumpAndSettle();
      expect(fake.synced, hasLength(2));

      // Запись в задачу видна на виджете (ADR-033).
      await _say(tester, 'запиши, что её номер 22-17');
      expect(fake.synced, hasLength(3));
      final tasks = fake.last['tasks']! as List<Object?>;
      expect(
        (tasks.single! as Map<String, Object?>)['note'],
        contains('22-17'),
      );
    });

    testWidgets('«Показывать текст задач» выключили — в снимке одни числа',
        (tester) async {
      final home = await _pump(
        tester,
        FakeHomeScreen(),
        prepare: (TaskService tasks) => tasks.create(
          title: 'Тайное дело',
          dueAt: DateTime(2026, 11, 16, 18),
        ),
      );
      final fake = home.homeScreen;
      expect(fake.titles, <String>['Тайное дело']);
      await openSettingsCategory(tester, 'widgets');
      final toggle = find.byKey(const ValueKey<String>('homescreen-show-text'));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect((await home.settings.load()).homeScreenShowText, isFalse);
      expect(fake.last['mode'], 'counts');
      expect(fake.last['tasks'], isEmpty);
      expect(fake.frame['rows'], isEmpty);
      expect(fake.frame['count'], 1);
      expect(fake.synced.last.encode(), isNot(contains('Тайное')));
    });

    testWidgets('вход по отпечатку — одни числа, что бы ни стояло в настройке',
        (tester) async {
      final home = await _pump(
        tester,
        FakeHomeScreen(),
        settings: const AppSettings(appLock: true),
        prepare: (TaskService tasks) => tasks.create(
          title: 'Тайное дело',
          dueAt: DateTime(2026, 11, 15, 18),
        ),
      );
      final fake = home.homeScreen;
      expect(fake.synced, hasLength(1));
      expect(fake.last['mode'], 'counts');
      expect(fake.frame['alert'], 'просрочена 1 задача');
      expect(fake.synced.single.encode(), isNot(contains('Тайное')));
    });

    testWidgets('микрофон на виджете — только если голосовой ввод есть',
        (tester) async {
      final without = await _pump(tester, FakeHomeScreen());
      expect(without.homeScreen.last['voice'], isFalse);
      final (kit, _) = await _voice(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      final with_ = await _pump(tester, FakeHomeScreen(), voice: kit);
      expect(with_.homeScreen.last['voice'], isTrue);
    });

    testWidgets('виджет только что поставили — снимок уходит заново',
        (tester) async {
      final home = await _pump(tester, FakeHomeScreen());
      final fake = home.homeScreen;
      expect(fake.synced, hasLength(1));
      fake.wanted.add(null);
      await tester.pumpAndSettle();
      expect(fake.synced, hasLength(2));
      expect(fake.synced.last.encode(), fake.synced.first.encode());
    });

    testWidgets('не Android — ни снимка, ни очереди', (tester) async {
      final home = await _pump(tester, FakeHomeScreen(supported: false));
      await _say(tester, 'позвонить маме сегодня в 18');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      home.homeScreen.launched.add(HomeScreenLaunch.compose);
      await tester.pumpAndSettle();
      expect(home.homeScreen.calls, isEmpty);
      expect(_composer(tester).hasFocus, isFalse);
      expect(await home.tasks.listActive(), hasLength(1));
    });
  });

  group('отметки с виджета', () {
    late Task bread;
    late Task report;

    Future<void> prepare(TaskService tasks) async {
      bread = await tasks.create(
        title: 'Купить хлеб',
        dueAt: DateTime(2026, 11, 16, 18),
      );
      report = await tasks.create(
        title: 'Сдать отчёт',
        dueAt: DateTime(2026, 11, 16, 19),
      );
    }

    testWidgets('при запуске: очередь, потом задачи, снимок и подтверждение',
        (tester) async {
      final fake = FakeHomeScreen();
      late final TaskService service;
      final home = await _pump(
        tester,
        fake,
        prepare: (TaskService tasks) async {
          service = tasks;
          await prepare(tasks);
          fake.queue.add(_done(7, bread));
        },
      );
      expect(identical(service, home.tasks), isTrue);
      // Первое чтение задач — уже после отметки: снимок один и без неё.
      expect(fake.calls, <String>['pending', 'sync', 'ack:7']);
      expect(fake.titles, <String>['Сдать отчёт']);
      expect(fake.queue, isEmpty);
      final done = (await home.tasks.find(bread.id))!;
      expect(done.status, TaskStatus.done);
      expect(done.completedAt, _tap);
      // Напоминание о выполненной задаче снято.
      expect(
        home.notify.synced.last.map((Reminder r) => r.taskId),
        <String>[report.id],
      );
      // Тихо: ни сообщения в чат, ни уведомления.
      expect(find.byType(SnackBar), findsNothing);
      expect(find.textContaining('Купить хлеб'), findsNothing);
    });

    testWidgets('настройки ещё читаются — подтверждение ждёт снимка',
        (tester) async {
      final fake = FakeHomeScreen();
      final slow = _SlowSettingsStore();
      final home = await _pump(
        tester,
        fake,
        settingsStore: slow,
        prepare: (TaskService tasks) async {
          await prepare(tasks);
          fake.queue.add(_done(3, bread));
        },
      );
      // Задача уже выполнена, но снимка без неё у системы ещё нет:
      // подтверждать рано — строка вернулась бы на виджет.
      expect((await home.tasks.find(bread.id))!.status, TaskStatus.done);
      expect(fake.calls, <String>['pending']);
      slow.gate.complete();
      await tester.pumpAndSettle();
      expect(fake.calls, <String>['pending', 'sync', 'ack:3']);
      expect(fake.titles, <String>['Сдать отчёт']);
    });

    testWidgets('приложение открыто — отметка применяется сразу',
        (tester) async {
      final fake = FakeHomeScreen();
      final home = await _pump(tester, fake, prepare: prepare);
      expect(fake.calls, <String>['pending', 'sync']);
      expect(fake.titles, <String>['Купить хлеб', 'Сдать отчёт']);
      fake.calls.clear();
      fake.queue.add(_done(1, bread));
      fake.changed.add(null);
      await tester.pumpAndSettle();
      expect(fake.calls, <String>['pending', 'sync', 'ack:1']);
      expect(fake.titles, <String>['Сдать отчёт']);
      expect((await home.tasks.listActive()).map((Task t) => t.id), <String>[
        report.id,
      ]);
    });

    testWidgets('возврат на экран: отмена отметки возвращает задачу',
        (tester) async {
      final fake = FakeHomeScreen();
      final home = await _pump(tester, fake, prepare: prepare);
      fake.queue.add(_done(1, bread));
      fake.changed.add(null);
      await tester.pumpAndSettle();
      expect(fake.titles, <String>['Сдать отчёт']);
      fake.calls.clear();
      // Приложение в фоне; на виджете отменили отметку.
      _lifecycle(tester, _toBackground);
      fake.queue.add(
        HomeScreenOp(
          seq: 2,
          kind: HomeScreenOpKind.undo,
          taskId: bread.id,
          at: _tap.add(const Duration(seconds: 2)),
          doneAt: _tap,
        ),
      );
      _lifecycle(tester, _toForeground);
      await tester.pumpAndSettle();
      expect(fake.calls, <String>['pending', 'sync', 'ack:2']);
      expect(fake.titles, <String>['Купить хлеб', 'Сдать отчёт']);
      expect((await home.tasks.find(bread.id))!.isActive, isTrue);
    });

    testWidgets('пропущенная отметка подтверждается, снимок не повторяется',
        (tester) async {
      final fake = FakeHomeScreen();
      await _pump(tester, fake, prepare: prepare);
      fake.calls.clear();
      fake.queue.add(
        HomeScreenOp(
          seq: 4,
          kind: HomeScreenOpKind.done,
          taskId: 'task_gone',
          at: _clock.now(),
        ),
      );
      fake.changed.add(null);
      await tester.pumpAndSettle();
      expect(fake.calls, <String>['pending', 'ack:4']);
      expect(fake.queue, isEmpty);
    });

    testWidgets('два сигнала подряд — разборы идут по очереди, без повторов',
        (tester) async {
      final fake = FakeHomeScreen();
      final home = await _pump(tester, fake, prepare: prepare);
      fake.calls.clear();
      fake.queue.add(_done(1, bread));
      fake.changed.add(null);
      // Вторая отметка пришла, пока первая ещё применяется.
      fake.queue.add(_done(2, report));
      fake.changed.add(null);
      await tester.pumpAndSettle();
      expect(await home.tasks.listActive(), isEmpty);
      expect(fake.acked.last, 2);
      expect(fake.queue, isEmpty);
      expect(fake.titles, isEmpty);
      // Ни одна задача не выполнена дважды.
      expect(await home.tasks.listCompleted(), hasLength(2));
      expect(
        fake.calls.where((String c) => c == 'pending').length,
        lessThanOrEqualTo(2),
      );
    });

    testWidgets('помощник больше не считает выполненную задачу «ею»',
        (tester) async {
      final fake = FakeHomeScreen();
      final home = await _pump(tester, fake);
      await _say(tester, 'сдать отчёт сегодня в 19');
      final task = (await home.tasks.listActive()).single;
      expect(home.assistant.selectedTaskId, task.id);
      fake.queue.add(_done(1, task));
      fake.changed.add(null);
      await tester.pumpAndSettle();
      expect((await home.tasks.find(task.id))!.status, TaskStatus.done);
      expect(home.assistant.selectedTaskId, isNull);
    });
  });

  group('«Что сделать?» на виджете', () {
    testWidgets('приложение открыто — поле ввода с клавиатурой',
        (tester) async {
      final home = await _pump(tester, FakeHomeScreen());
      expect(_composer(tester).hasFocus, isFalse);
      home.homeScreen.launched.add(HomeScreenLaunch.compose);
      await tester.pumpAndSettle();
      expect(_composer(tester).hasPrimaryFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
    });

    testWidgets('холодный запуск с виджета — сразу поле ввода', (tester) async {
      final fake = FakeHomeScreen()..launch = HomeScreenLaunch.compose;
      await _pump(tester, fake);
      expect(_composer(tester).hasPrimaryFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      // Один раз: повторный вопрос системе ничего не даёт.
      expect(fake.launch, isNull);
    });

    testWidgets('из чата задачи — в новую сессию, не в задачу', (tester) async {
      final home = await _pump(tester, FakeHomeScreen());
      await _say(tester, 'позвонить маме завтра в 10');
      final task = (await home.tasks.listActive()).single;
      home.notify.opened.add(task.id);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-chat-title')), findsOneWidget);
      home.homeScreen.launched.add(HomeScreenLaunch.compose);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-chat-title')), findsNothing);
      expect(_composer(tester).hasPrimaryFocus, isTrue);
      // Написанное — новое дело, а не запись в ту задачу.
      await _say(tester, 'купить хлеб');
      final titles = (await home.tasks.listActive()).map((Task t) => t.title);
      expect(titles, containsAll(<String>['Позвонить маме', 'Купить хлеб']));
      expect((await home.tasks.find(task.id))!.notes, isEmpty);
    });

    testWidgets('из «Мой Связной» и при открытом меню — тоже в поле',
        (tester) async {
      final home = await _pump(tester, FakeHomeScreen());
      await openMyRelay(tester);
      expect(find.byKey(_inputKey), findsNothing);
      home.homeScreen.launched.add(HomeScreenLaunch.compose);
      await tester.pumpAndSettle();
      expect(_composer(tester).hasPrimaryFocus, isTrue);

      FocusManager.instance.primaryFocus?.unfocus();
      await openDrawerIfNeeded(tester);
      expect(find.byKey(const Key('app-sidebar')), findsOneWidget);
      home.homeScreen.launched.add(HomeScreenLaunch.compose);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-sidebar')), findsNothing);
      expect(_composer(tester).hasPrimaryFocus, isTrue);
    });

    testWidgets(
        'поверх открыт другой экран — ни его, ни чат под ним не трогаем',
        (tester) async {
      final home = await _pump(tester, FakeHomeScreen());
      await _say(tester, 'позвонить маме завтра в 10');
      final task = (await home.tasks.listActive()).single;
      home.notify.opened.add(task.id);
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final other = FocusNode();
      addTearDown(other.dispose);
      unawaited(
        _navigator.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (BuildContext context) => Scaffold(
              body: TextField(focusNode: other),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      home.homeScreen.launched.add(HomeScreenLaunch.compose);
      await tester.pumpAndSettle();
      expect(find.byKey(_inputKey), findsNothing);
      expect(tester.testTextInput.isVisible, isFalse);
      // Экран закрыли: чат задачи на месте, клавиатура не выскакивает.
      _navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-chat-title')), findsOneWidget);
      expect(_composer(tester).hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
    });

    testWidgets('приложение ещё в фоне — ждёт выхода на экран', (tester) async {
      final home = await _pump(tester, FakeHomeScreen());
      _lifecycle(tester, _toBackground);
      // Нажатие на виджете приходит раньше, чем приложение покажется.
      home.homeScreen.launched.add(HomeScreenLaunch.compose);
      await tester.pumpAndSettle();
      expect(_composer(tester).hasFocus, isFalse);
      _lifecycle(tester, _toForeground);
      await tester.pumpAndSettle();
      expect(_composer(tester).hasPrimaryFocus, isTrue);
    });

    testWidgets('не дождались и ушли — потом клавиатура не выскакивает',
        (tester) async {
      final home = await _pump(tester, FakeHomeScreen());
      _lifecycle(tester, _toBackground);
      home.homeScreen.launched.add(HomeScreenLaunch.compose);
      await tester.pump();
      // Показалось и тут же снова ушло в фон, не успев стать активным.
      _lifecycle(tester, <AppLifecycleState>[
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]);
      await tester.pump();
      _lifecycle(tester, _toForeground);
      await tester.pumpAndSettle();
      expect(_composer(tester).hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
    });

    testWidgets('прошла минута — нажатие устарело', (tester) async {
      final home = await _pump(tester, FakeHomeScreen());
      _lifecycle(tester, <AppLifecycleState>[AppLifecycleState.inactive]);
      home.homeScreen.launched.add(HomeScreenLaunch.compose);
      await tester.pump(const Duration(seconds: 61));
      _lifecycle(tester, <AppLifecycleState>[AppLifecycleState.resumed]);
      await tester.pumpAndSettle();
      expect(_composer(tester).hasFocus, isFalse);
    });

    testWidgets('приложение заперто — поле откроется после входа',
        (tester) async {
      final auth = _GatedAuth();
      final lock = AppLockController(auth: auth, enabled: true);
      addTearDown(lock.dispose);
      final fake = FakeHomeScreen()..launch = HomeScreenLaunch.compose;
      await _pump(
        tester,
        fake,
        settings: const AppSettings(appLock: true),
        lock: lock,
      );
      expect(lock.locked, isTrue);
      expect(find.byKey(const ValueKey<String>('app-lock')), findsOneWidget);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(auth.asked, 1);
      auth.gate.complete();
      await tester.pumpAndSettle();
      expect(lock.locked, isFalse);
      expect(_composer(tester).hasPrimaryFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
    });
  });

  group('микрофон на виджете', () {
    testWidgets('голосовой ввод готов — сразу слушает, клавиатуры нет',
        (tester) async {
      final (kit, recognizer) = await _voice(tester);
      final home = await _pump(
        tester,
        FakeHomeScreen(),
        settings: _voiceReady,
        voice: kit,
      );
      home.homeScreen.launched.add(HomeScreenLaunch.voice);
      await tester.pump();
      await tester.pump();
      await pumpUntilVoice(tester, () => recognizer.startCalls == 1);
      expect(recognizer.isListening, isTrue);
      expect(_composer(tester).hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
      // Повторное нажатие, пока слушает, ничего не ломает.
      home.homeScreen.launched.add(HomeScreenLaunch.voice);
      await tester.pump();
      await tester.pump();
      expect(recognizer.startCalls, 1);
      expect(recognizer.isListening, isTrue);
      // Сказанное попадает в поле новой сессии.
      recognizer.finalText = 'купить хлеб';
      await tester.tap(find.byKey(const Key('assistant-voice')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byKey(_inputKey)).controller!.text,
        'Купить хлеб',
      );
    });

    testWidgets('холодный запуск: настройки читаются до микрофона',
        (tester) async {
      final (kit, recognizer) = await _voice(tester);
      final fake = FakeHomeScreen()..launch = HomeScreenLaunch.voice;
      await _pump(tester, fake, settings: _voiceReady, voice: kit);
      await pumpUntilVoice(tester, () => recognizer.startCalls == 1);
      // Голосовой ввод включён в настройках — предложения включить нет.
      expect(find.text('Включить голосовой ввод?'), findsNothing);
      await tester.tap(find.byKey(const Key('assistant-voice')));
      await tester.pumpAndSettle();
    });

    testWidgets('голосовой ввод не включён — предложение включить',
        (tester) async {
      final (kit, recognizer) = await _voice(tester);
      final home = await _pump(tester, FakeHomeScreen(), voice: kit);
      home.homeScreen.launched.add(HomeScreenLaunch.voice);
      await tester.pumpAndSettle();
      // Модель уже есть: включается переключатель, слушать — следующим
      // нажатием.
      expect(find.text('Голосовой ввод включён'), findsOneWidget);
      expect(recognizer.startCalls, 0);
      expect((await home.settings.load()).voiceInput, isTrue);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('нет доступа к микрофону — подсказка, не слушает',
        (tester) async {
      final (kit, recognizer) = await _voice(
        tester,
        recognizer: FakeVoiceRecognizer(permission: VoicePermission.denied),
      );
      final home = await _pump(
        tester,
        FakeHomeScreen(),
        settings: _voiceReady,
        voice: kit,
      );
      home.homeScreen.launched.add(HomeScreenLaunch.voice);
      await tester.pump();
      await tester.pump();
      await pumpUntilVoice(tester, () => recognizer.permissionCalls > 0);
      await tester.pump();
      expect(recognizer.startCalls, 0);
      expect(find.textContaining('Нет доступа к микрофону'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('голосового ввода на устройстве нет — остаётся поле',
        (tester) async {
      final home = await _pump(tester, FakeHomeScreen());
      home.homeScreen.launched.add(HomeScreenLaunch.voice);
      await tester.pumpAndSettle();
      expect(_composer(tester).hasPrimaryFocus, isTrue);
    });

    testWidgets('поверх открыт другой экран — микрофон не включается',
        (tester) async {
      final (kit, recognizer) = await _voice(tester);
      final home = await _pump(
        tester,
        FakeHomeScreen(),
        settings: _voiceReady,
        voice: kit,
      );
      unawaited(
        _navigator.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (BuildContext context) =>
                const Scaffold(body: Text('другой экран')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      home.homeScreen.launched.add(HomeScreenLaunch.voice);
      await tester.pump();
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      expect(recognizer.permissionCalls, 0);
      expect(recognizer.startCalls, 0);
      _navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(recognizer.startCalls, 0);
    });

    testWidgets('в фоне микрофон не включается, на экране — включается',
        (tester) async {
      final (kit, recognizer) = await _voice(tester);
      final home = await _pump(
        tester,
        FakeHomeScreen(),
        settings: _voiceReady,
        voice: kit,
      );
      _lifecycle(tester, _toBackground);
      home.homeScreen.launched.add(HomeScreenLaunch.voice);
      await tester.pump();
      await tester.pump();
      expect(recognizer.permissionCalls, 0);
      expect(recognizer.startCalls, 0);
      _lifecycle(tester, _toForeground);
      await tester.pump();
      await tester.pump();
      await pumpUntilVoice(tester, () => recognizer.startCalls == 1);
      await tester.tap(find.byKey(const Key('assistant-voice')));
      await tester.pumpAndSettle();
    });
  });
}
