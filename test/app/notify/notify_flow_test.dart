import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/app/notify/notify_channel.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/notify/reminder_plan.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import '../../support/fake_notify.dart';

/// Пятница, 12:00.
final _clock = FixedClock(DateTime(2026, 11, 13, 12));

final class _Home {
  _Home(this.tasks, this.settings, this.notify);

  final TaskService tasks;
  final InMemorySettingsStore settings;
  final FakeNotify notify;
}

Future<_Home> _pump(
  WidgetTester tester,
  FakeNotify notify, {
  ThemeData? theme,
  AppSettings settings = const AppSettings(),
}) async {
  tester.view.physicalSize = const Size(400, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final tasks =
      TaskService(repository: InMemoryTaskRepository(), clock: _clock);
  final store = InMemorySettingsStore();
  await store.save(settings);
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
      theme: theme ?? AssistantTheme.dark(),
      home: HomePage(
        assistant: assistant,
        tasks: tasks,
        clock: _clock,
        settingsStore: store,
        notify: notify,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Home(tasks, store, notify);
}

Future<void> _say(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('assistant-input')), text);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

Future<void> _resume(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpAndSettle();
}

final Finder _sheet = find.byKey(const Key('notify-sheet'));

void main() {
  testWidgets('первая задача со сроком — объяснение один раз, «Разрешить»',
      (tester) async {
    final home = await _pump(tester, FakeNotify());
    // При запуске не спрашиваем.
    expect(_sheet, findsNothing);
    await _say(tester, 'купить хлеб');
    expect(_sheet, findsNothing, reason: 'задача без срока');
    await _say(tester, 'позвонить маме завтра в 10');
    expect(_sheet, findsOneWidget);
    expect(find.text('Напоминания вовремя'), findsOneWidget);
    expect(
      find.textContaining('Они создаются на этом устройстве и никуда не '
          'отправляются.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('notify-allow')));
    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);
    expect(home.notify.requests, 1);
    expect(
      find.textContaining('напомню о задачах уведомлением'),
      findsOneWidget,
    );
    final settings = await home.settings.load();
    expect(settings.notifyExplained, isTrue);
    expect(settings.notifyDismissedDay, isNull);
    // Расписание — с новой задачей на завтра в 10:00.
    final plan = home.notify.synced.last;
    expect(plan.map((Reminder r) => (r.title, r.at)), <(String, DateTime)>[
      ('Позвонить маме', DateTime(2026, 11, 14, 10)),
    ]);
    // Уже разрешено — больше не спрашиваем.
    await _say(tester, 'сдать отчёт в понедельник в 9');
    expect(_sheet, findsNothing);
    expect(home.notify.synced.last, hasLength(2));
  });

  testWidgets('«Не сейчас» — в этот день лист больше не появляется',
      (tester) async {
    final home = await _pump(tester, FakeNotify());
    await _say(tester, 'позвонить маме завтра в 10');
    await tester.tap(find.byKey(const Key('notify-later')));
    await tester.pumpAndSettle();
    expect(home.notify.requests, 0);
    expect(
      (await home.settings.load()).notifyDismissedDay,
      AppSettings.dayKey(_clock.now()),
    );
    await _say(tester, 'сдать отчёт в понедельник в 9');
    expect(_sheet, findsNothing);
  });

  testWidgets('выключено в настройках — «Открыть настройки», возврат',
      (tester) async {
    final notify = FakeNotify(afterRequest: NotifyPermission.permanentlyDenied);
    await _pump(tester, notify);
    await _say(tester, 'позвонить маме завтра в 10');
    await tester.tap(find.byKey(const Key('notify-allow')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('notify-open-settings')), findsOneWidget);
    expect(find.byKey(const Key('notify-hint')), findsOneWidget);
    await tester.tap(find.byKey(const Key('notify-open-settings')));
    await tester.pumpAndSettle();
    expect(notify.settingsOpened, 1);
    // Включили в настройках системы и вернулись.
    notify.permission = NotifyPermission.granted;
    final before = notify.synced.length;
    await _resume(tester);
    expect(_sheet, findsNothing);
    // Возврат в приложение — расписание заново (новый план не нужен).
    expect(notify.synced.length, greaterThanOrEqualTo(before));
  });

  testWidgets('выключено в системе ещё до объяснения — лист с настройками',
      (tester) async {
    final notify = FakeNotify(permission: NotifyPermission.permanentlyDenied);
    final home = await _pump(tester, notify);
    await _say(tester, 'позвонить маме завтра в 10');
    expect(_sheet, findsOneWidget);
    expect(find.byKey(const Key('notify-open-settings')), findsOneWidget);
    await tester.tap(find.byKey(const Key('notify-open-settings')));
    await tester.pumpAndSettle();
    expect(notify.settingsOpened, 1);
    expect(notify.requests, 0);
    // Включили в системе и вернулись — лист закрылся, объяснение засчитано.
    notify.permission = NotifyPermission.granted;
    await _resume(tester);
    expect(_sheet, findsNothing);
    expect((await home.settings.load()).notifyExplained, isTrue);
  });

  testWidgets('объясняли, но выключено в системе — строка, не лист',
      (tester) async {
    final notify = FakeNotify(permission: NotifyPermission.permanentlyDenied);
    final home = await _pump(
      tester,
      notify,
      settings: const AppSettings(notifyExplained: true),
    );
    await _say(tester, 'позвонить маме завтра в 10');
    expect(_sheet, findsNothing);
    expect(find.textContaining('Уведомления выключены'), findsOneWidget);
    // Не чаще раза в день.
    await _say(tester, 'сдать отчёт в понедельник в 9');
    expect(find.textContaining('Уведомления выключены'), findsOneWidget);
    expect(
      (await home.settings.load()).notifyDismissedDay,
      AppSettings.dayKey(_clock.now()),
    );
  });

  testWidgets('разрешено, но без точного времени — второй шаг', (tester) async {
    final notify = FakeNotify(exact: ExactAlarm.denied);
    await _pump(tester, notify);
    await _say(tester, 'позвонить маме завтра в 10');
    await tester.tap(find.byKey(const Key('notify-allow')));
    await tester.pumpAndSettle();
    expect(find.text('Точно в срок'), findsOneWidget);
    await tester.tap(find.byKey(const Key('notify-exact-allow')));
    await tester.pumpAndSettle();
    expect(notify.exactOpened, 1);
    notify.exact = ExactAlarm.granted;
    await _resume(tester);
    expect(_sheet, findsNothing);
    expect(find.textContaining('несколько минут позже'), findsNothing);
  });

  testWidgets('«Пусть так» — строка о неточном времени', (tester) async {
    final notify = FakeNotify(exact: ExactAlarm.denied);
    await _pump(tester, notify);
    await _say(tester, 'позвонить маме завтра в 10');
    await tester.tap(find.byKey(const Key('notify-allow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('notify-exact-skip')));
    await tester.pumpAndSettle();
    expect(find.textContaining('несколько минут позже'), findsOneWidget);
  });

  testWidgets('нажатое уведомление открывает чат задачи', (tester) async {
    final notify = FakeNotify(permission: NotifyPermission.granted);
    final home = await _pump(tester, notify);
    await _say(tester, 'позвонить маме завтра в 10');
    final task = (await home.tasks.listActive()).single;
    notify.opened.add(task.id);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('task-chat-title')), findsOneWidget);
  });

  testWidgets('без уведомлений на устройстве — ни листа, ни расписания',
      (tester) async {
    final notify = FakeNotify(supported: false);
    await _pump(tester, notify);
    await _say(tester, 'позвонить маме завтра в 10');
    expect(_sheet, findsNothing);
    expect(notify.synced, isEmpty);
  });

  testWidgets('лист в светлой теме', (tester) async {
    await _pump(tester, FakeNotify(), theme: AssistantTheme.light());
    await _say(tester, 'позвонить маме завтра в 10');
    expect(_sheet, findsOneWidget);
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  });
}
