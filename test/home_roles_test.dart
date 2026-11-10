import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import 'connectors/manifest/fixtures.dart';

final _clock = FixedClock(DateTime(2026, 11, 4, 12));

/// Главный экран со складом без подключения: роли (ADR-012) и кнопки.
Future<AssistantController> _pump(
  WidgetTester tester,
  SettingsStore settings,
) async {
  tester.view.physicalSize = const Size(1300, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final tasks =
      TaskService(repository: InMemoryTaskRepository(), clock: _clock);
  final assistant = AssistantController(
    extensions: ExtensionRegistry(
      connectors: <Connector>[
        TasksConnector(
          taskService: tasks,
          parser: ScenarioParser(clock: _clock),
        ),
        warehouseConnector(path: patchedManifestPath),
        const CalculatorConnector(),
        TalkConnector(taskService: tasks),
      ],
    ),
    clock: _clock,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.dark(),
      home: HomePage(
        assistant: assistant,
        tasks: tasks,
        clock: _clock,
        settingsStore: settings,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return assistant;
}

Future<void> _say(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('assistant-input')), text);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

Future<void> _toggleStorekeeper(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('nav-settings')));
  await tester.pumpAndSettle();
  final tile = find.byKey(const ValueKey<String>('role-storekeeper'));
  await tester.ensureVisible(tile);
  await tester.pumpAndSettle();
  await tester.tap(tile);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('nav-tasks')));
  await tester.pumpAndSettle();
}

String _input(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const Key('assistant-input')))
    .controller!
    .text;

void main() {
  testWidgets('кнопки «Кладовщика»: отправить и вставить шаблон',
      (tester) async {
    final store = InMemorySettingsStore();
    await store.save(
      const AppSettings(enabledRoles: <String>{Roles.storekeeperId}),
    );
    await _pump(tester, store);
    for (final label in <String>[
      'Где лежит…',
      'Что пришло сегодня',
      'Без фото',
      'Покажи задачи',
    ]) {
      expect(find.byKey(Key('quick-$label')), findsOneWidget, reason: label);
    }
    await tester.tap(find.byKey(const Key('quick-Без фото')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Склад ещё не подключён — Настройки → Роли → Кладовщик → '
        'Подключить склад.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('quick-Где лежит…')));
    await tester.pumpAndSettle();
    expect(_input(tester), 'Где лежит ');
    expect(tester.takeException(), isNull);
  });

  testWidgets('роль включается и выключается без сброса', (tester) async {
    final store = InMemorySettingsStore();
    final assistant = await _pump(tester, store);
    expect(find.byKey(const Key('quick-Без фото')), findsNothing);

    await _say(tester, 'Добавь задачу купить хлеб');
    final selected = assistant.selectedTaskId;
    expect(selected, isNotNull);
    await _say(tester, 'где лежит 64115');
    expect(find.textContaining('Склад ещё не подключён'), findsNothing);
    await tester.enterText(
      find.byKey(const Key('assistant-input')),
      'черновик',
    );
    await tester.pump();

    await _toggleStorekeeper(tester);
    expect((await store.load()).enabledRoles, <String>{Roles.storekeeperId});
    expect(assistant.extensions.isEnabled('warehouse'), isTrue);
    expect(find.text('Добавь задачу купить хлеб'), findsWidgets);
    expect(assistant.selectedTaskId, selected, reason: 'выбор');
    expect(_input(tester), 'черновик', reason: 'черновик');
    expect(find.byKey(const Key('quick-Без фото')), findsOneWidget);

    await _say(tester, 'где лежит 64115');
    expect(find.textContaining('Склад ещё не подключён'), findsOneWidget);

    await _toggleStorekeeper(tester);
    expect((await store.load()).enabledRoles, isEmpty);
    expect(find.byKey(const Key('quick-Без фото')), findsNothing);
    expect(find.textContaining('Склад ещё не подключён'), findsOneWidget);
    expect(assistant.selectedTaskId, selected);
    expect(tester.takeException(), isNull);
  });
}
