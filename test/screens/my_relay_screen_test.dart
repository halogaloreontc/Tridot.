// «Мой Tridot» (макет «Д»): шапка со строкой статистики, вкладки,
// сетка активности 16/52 недели, «Сейчас и дальше», карточки помощников.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/screens/my_relay_screen.dart';
import 'package:local_assistant/app/screens/my_relay_tabs.dart';
import 'package:local_assistant/app/shell/today_panel.dart';
import 'package:local_assistant/app/widgets/activity_grid.dart';
import 'package:local_assistant/core/app_info.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/replies/reply_library.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import '../connectors/manifest/fixtures.dart';

// Понедельник, 9 ноября 2026.
final DateTime now = DateTime(2026, 11, 9, 12, 40);
final FixedClock _clock = FixedClock(now);

Task task(
  String id, {
  TaskStatus status = TaskStatus.planned,
  DateTime? dueAt,
  DateTime? completedAt,
}) =>
    Task(
      id: id,
      title: 'Задача $id',
      status: status,
      priority: TaskPriority.normal,
      createdAt: DateTime(2026, 9, 1),
      updatedAt: DateTime(2026, 9, 1),
      dueAt: dueAt,
      completedAt: completedAt,
    );

Future<void> pumpBox(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.dark(),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

int cellCount() => find
    .byWidgetPredicate(
      (Widget w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('activity-2'),
    )
    .evaluate()
    .length;

void main() {
  group('ActivityGrid', () {
    testWidgets('16 недель: клетки по сегодня, будущих нет', (tester) async {
      await pumpBox(
        tester,
        ActivityGrid(counts: const <DateTime, int>{}, now: now),
      );
      // Понедельник — последний столбец содержит только сегодня.
      expect(cellCount(), 15 * 7 + 1);
      expect(find.byKey(const Key('activity-2026-11-9')), findsOneWidget);
      expect(find.byKey(const Key('activity-2026-11-10')), findsNothing);
      expect(find.text('16 недель · 0 дней'), findsOneWidget);
    });

    testWidgets('52 недели и уровни цвета heat0..3', (tester) async {
      await pumpBox(
        tester,
        ActivityGrid(
          counts: <DateTime, int>{
            DateTime(2026, 11, 9): 5,
            DateTime(2026, 11, 8): 2,
            DateTime(2026, 11, 7): 1,
          },
          now: now,
          weeks: 52,
        ),
        size: const Size(1440, 900),
      );
      expect(cellCount(), 51 * 7 + 1);
      Color colorOf(String key) =>
          ((tester.widget<Container>(find.byKey(Key(key))).decoration!
                  as BoxDecoration)
              .color)!;
      expect(colorOf('activity-2026-11-9'), AssistantColors.heat3);
      expect(colorOf('activity-2026-11-8'), AssistantColors.heat2);
      expect(colorOf('activity-2026-11-7'), AssistantColors.heat1);
      expect(colorOf('activity-2026-11-6'), AssistantColors.heat0);
      expect(find.text('52 недели · 3 дня'), findsOneWidget);
    });

    test('подпись для диктора — по тем же данным', () {
      expect(
        activitySemantics(const <DateTime, int>{}, now, 16),
        'Активность за 16 недель: активных дней нет',
      );
      expect(
        activitySemantics(
          <DateTime, int>{
            DateTime(2026, 10, 20): 1,
            DateTime(2026, 11, 2): 1,
            DateTime(2026, 11, 9): 3,
            // Вне сетки: не считается.
            DateTime(2025, 1, 1): 9,
          },
          now,
          16,
        ),
        'Активность за 16 недель: 3 активных дня, с 20 октября; '
        'чаще всего — в ноябре (2 дня)',
      );
    });
  });

  group('MyRelayScreen', () {
    testWidgets('шапка, строка статистики и вкладки', (tester) async {
      var tab = MyRelayTab.summary;
      var back = 0;
      await pumpBox(
        tester,
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) =>
              MyRelayScreen(
            tab: tab,
            onTabChanged: (MyRelayTab t) => setState(() => tab = t),
            onBack: () => back++,
            stats: 'Вместе 2 дня · сессий 3 · задач закрыто 1 · серия 1 день',
            summary: const Text('сводка'),
            activity: const Text('активность'),
            assistants: const Text('помощники'),
            settings: const Text('настройки'),
          ),
        ),
      );
      expect(find.text(AppInfo.hubName), findsOneWidget);
      expect(
        tester
            .widget<RelayStatsLine>(find.byKey(const Key('my-relay-stats')))
            .stats,
        'Вместе 2 дня · сессий 3 · задач закрыто 1 · серия 1 день',
      );
      expect(find.text('сводка'), findsOneWidget);
      // Узкий экран: вкладки прокручиваются, а не обрезаются.
      await tester
          .ensureVisible(find.byKey(const Key('my-relay-tab-settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('my-relay-tab-settings')));
      await tester.pumpAndSettle();
      expect(tab, MyRelayTab.settings);
      expect(find.text('настройки'), findsOneWidget);
      await tester.tap(find.byKey(const Key('my-relay-back')));
      expect(back, 1);
    });

    testWidgets('320 px и шрифт ×2 — без переполнений', (tester) async {
      await pumpBox(
        tester,
        MyRelayScreen(
          tab: MyRelayTab.summary,
          onTabChanged: (_) {},
          onBack: () {},
          stats: 'Вместе 28 дней · сессий 180 · задач закрыто 64 · '
              'серия 5 дней',
          summary: RelaySummary(
            activity: <DateTime, int>{DateTime(2026, 11, 9): 2},
            tasks: <Task>[task('a', dueAt: DateTime(2026, 11, 9, 11))],
            now: now,
            pending: const <TodayPending>[],
            onOpenTask: (_) {},
            onAllTasks: () {},
          ),
          activity: const SizedBox(),
          assistants: const SizedBox(),
          settings: const SizedBox(),
        ),
        size: const Size(320, 640),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('activity-grid')), findsOneWidget);
    });
  });

  group('Сводка', () {
    testWidgets('телефон — 16 недель, компьютер — 52', (tester) async {
      Widget summary() => RelaySummary(
            activity: const <DateTime, int>{},
            tasks: const <Task>[],
            now: now,
            pending: const <TodayPending>[],
            onOpenTask: (_) {},
            onAllTasks: () {},
          );
      await pumpBox(tester, summary());
      expect(cellCount(), 15 * 7 + 1);
      expect(find.byKey(const Key('summary-next-empty')), findsOneWidget);

      await pumpBox(tester, summary(), size: const Size(1440, 900));
      expect(cellCount(), 51 * 7 + 1);
    });

    testWidgets('«Сейчас и дальше»: просроченные первыми, ждущие карточки',
        (tester) async {
      final opened = <Task>[];
      var all = 0;
      var pendingTaps = 0;
      await pumpBox(
        tester,
        RelaySummary(
          activity: const <DateTime, int>{},
          tasks: <Task>[
            task('later', dueAt: DateTime(2026, 11, 12, 10)),
            task('today', dueAt: DateTime(2026, 11, 9, 16)),
            task('late', dueAt: DateTime(2026, 11, 9, 11)),
            task('nodate'),
            task(
              'done',
              status: TaskStatus.done,
              dueAt: DateTime(2026, 11, 9, 9),
              completedAt: DateTime(2026, 11, 9, 9),
            ),
          ],
          now: now,
          pending: <TodayPending>[
            TodayPending(
              id: 'card-1',
              title: 'Отметка прихода ждёт подтверждения',
              subtitle: 'Нода · склад',
              onTap: () => pendingTaps++,
            ),
          ],
          onOpenTask: opened.add,
          onAllTasks: () => all++,
        ),
      );
      final rows = tester
          .widgetList<Widget>(
            find.byWidgetPredicate(
              (Widget w) =>
                  w.key is ValueKey<String> &&
                  (w.key! as ValueKey<String>).value.startsWith('next-'),
            ),
          )
          .map((Widget w) => (w.key! as ValueKey<String>).value)
          .toList();
      expect(rows, <String>[
        'next-task-late',
        'next-task-today',
        'next-task-later',
        'next-pending-card-1',
      ]);
      final late = tester.widget<Text>(find.text('11:00, просрочено'));
      expect(late.style?.color, AssistantColors.danger);

      await tester.tap(find.byKey(const Key('next-task-today')));
      expect(opened.single.id, 'today');
      await tester.tap(find.byKey(const Key('next-pending-card-1')));
      expect(pendingTaps, 1);
      await tester.tap(find.byKey(const Key('summary-all-tasks')));
      expect(all, 1);
    });
  });

  testWidgets('Активность: год и «Вернуть» у выполненных', (tester) async {
    final reopened = <Task>[];
    final done = task(
      'd1',
      status: TaskStatus.done,
      completedAt: DateTime(2026, 11, 8, 10),
    );
    await pumpBox(
      tester,
      RelayActivity(
        activity: <DateTime, int>{DateTime(2026, 11, 8): 1},
        completed: <Task>[done],
        now: now,
        onReopen: reopened.add,
      ),
    );
    expect(cellCount(), 51 * 7 + 1);
    expect(
      find.byKey(const ValueKey<String>('activity-done-d1')),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('activity-done-d1')),
        matching: find.byTooltip('Вернуть в работу'),
      ),
    );
    expect(reopened.single.id, 'd1');
  });

  group('Помощники', () {
    Future<List<AppSettings>> pumpAssistants(
      WidgetTester tester,
      AppSettings settings, {
      VoidCallback? onOpenRoles,
      Size size = const Size(390, 844),
    }) async {
      final changes = <AppSettings>[];
      final tasks =
          TaskService(repository: InMemoryTaskRepository(), clock: _clock);
      final registry = ExtensionRegistry(
        connectors: <Connector>[
          TasksConnector(
            taskService: tasks,
            parser: ScenarioParser(clock: _clock),
          ),
          warehouseConnector(record: connectedRecord()),
          TalkConnector(taskService: tasks),
        ],
        choice: settings.extensionChoice,
      );
      await pumpBox(
        tester,
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) =>
              RelayAssistants(
            settings: settings,
            onChanged: (AppSettings s) => setState(() {
              changes.add(s);
              settings = s;
            }),
            registry: registry,
            onOpenRoles: onOpenRoles ?? () {},
          ),
        ),
        size: size,
      );
      return changes;
    }

    testWidgets('карточки Связной, Лиорио и Ноды с их настройками',
        (tester) async {
      await pumpAssistants(tester, const AppSettings());
      for (final id in <String>['sado', 'rio', 'noda']) {
        expect(find.byKey(Key('persona-card-$id')), findsOneWidget);
      }
      String role(String id) =>
          tester.widget<Text>(find.byKey(Key('persona-role-$id'))).data!;
      // Род Связной ещё не выбран — подпись без рода.
      expect(role('sado'), 'главное: беседа, задачи, планы');
      expect(role('rio'), 'ведёт расширения');
      expect(role('noda'), 'ведёт оповещения');
      expect(find.text('на вы'), findsNWidgets(3));
      // У Связной переключателя нет: он всегда включён.
      expect(find.byKey(const Key('persona-active-sado')), findsNothing);
      expect(find.byKey(const Key('persona-active-rio')), findsOneWidget);
      expect(find.byKey(const Key('persona-active-noda')), findsOneWidget);
      expect(
        find.byKey(const Key('assistants-journal-planned')),
        findsOneWidget,
      );
      // Полные настройки — ниже, те же ключи, что в разделе «Помощники».
      expect(
        find.byKey(const ValueKey<String>('personas-section')),
        findsOneWidget,
      );
    });

    testWidgets('род Связной выбран — «главный помощник» / «главная помощница»',
        (tester) async {
      for (final (gender, text) in <(ReplyGender, String)>[
        (ReplyGender.male, 'главный помощник'),
        (ReplyGender.female, 'главная помощница'),
      ]) {
        await pumpAssistants(
          tester,
          AppSettings(
            personas: PersonaSettings(
              genders: <String, ReplyGender>{'sado': gender},
            ),
          ),
        );
        expect(
          tester.widget<Text>(find.byKey(const Key('persona-role-sado'))).data,
          text,
        );
      }
    });

    testWidgets('обе обязанности у Лиорио: у Ноды — «без обязанностей»',
        (tester) async {
      await pumpAssistants(
        tester,
        const AppSettings(
          personas: PersonaSettings(dutyNotifications: 'rio'),
        ),
      );
      String role(String id) =>
          tester.widget<Text>(find.byKey(Key('persona-role-$id'))).data!;
      expect(role('rio'), 'ведёт расширения и оповещения');
      expect(role('noda'), 'без обязанностей');
    });

    testWidgets('от 900 px карточки в ряд, уже — столбцом', (tester) async {
      Offset at(String id) =>
          tester.getTopLeft(find.byKey(Key('persona-card-$id')));
      await pumpAssistants(
        tester,
        const AppSettings(),
        size: const Size(1200, 900),
      );
      expect(at('sado').dy, at('rio').dy);
      expect(at('rio').dy, at('noda').dy);
      expect(at('sado').dx, lessThan(at('rio').dx));
      expect(at('rio').dx, lessThan(at('noda').dx));
      await pumpAssistants(
        tester,
        const AppSettings(),
        size: const Size(800, 900),
      );
      expect(at('sado').dx, at('rio').dx);
      expect(at('sado').dy, lessThan(at('rio').dy));
      expect(at('rio').dy, lessThan(at('noda').dy));
    });

    testWidgets('переключатели помощников выставляют режим', (tester) async {
      final changes = await pumpAssistants(tester, const AppSettings());
      await tester.tap(find.byKey(const Key('persona-active-noda')));
      await tester.pumpAndSettle();
      expect(changes.last.personas.teamMode, TeamMode.duo);
      expect(changes.last.personas.duoHelper, 'rio');
      expect(
        tester.widget<Text>(find.byKey(const Key('persona-role-noda'))).data,
        'выключена · режим «Дуэт»',
      );
      await tester.tap(find.byKey(const Key('persona-active-rio')));
      await tester.pumpAndSettle();
      expect(changes.last.personas.teamMode, TeamMode.solo);
      expect(
        tester.widget<Text>(find.byKey(const Key('persona-role-rio'))).data,
        'выключен · режим «Соло»',
      );
      await tester.tap(find.byKey(const Key('persona-active-noda')));
      await tester.pumpAndSettle();
      expect(changes.last.personas.teamMode, TeamMode.duo);
      expect(changes.last.personas.duoHelper, 'noda');
      await tester.tap(find.byKey(const Key('persona-active-rio')));
      await tester.pumpAndSettle();
      expect(changes.last.personas.teamMode, TeamMode.trio);
    });

    testWidgets('«Ведёт: Кладовщик» у ведущей расширений Ноды открывает роли',
        (tester) async {
      var roles = 0;
      await pumpAssistants(
        tester,
        const AppSettings(
          enabledRoles: <String>{'storekeeper'},
          personas: PersonaSettings(dutyExtensions: 'noda'),
        ),
        onOpenRoles: () => roles++,
      );
      final row = find.byKey(const Key('persona-roles-noda'));
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('Кладовщик')),
        findsOneWidget,
      );
      await tester.tap(row);
      expect(roles, 1);
    });

    testWidgets('«Ведёт» для диктора — кнопка', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpAssistants(
        tester,
        const AppSettings(
          enabledRoles: <String>{'storekeeper'},
          personas: PersonaSettings(dutyExtensions: 'noda'),
        ),
        onOpenRoles: () {},
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('Ведёт: Кладовщик')),
        isSemantics(
          label: 'Ведёт: Кладовщик',
          hint: 'Открыть роли в настройках',
          isButton: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('320 px и шрифт ×2 — без переполнений', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      await pumpAssistants(tester, const AppSettings());
      expect(tester.takeException(), isNull);
    });
  });
}
