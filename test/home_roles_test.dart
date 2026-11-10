import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';
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

import 'connectors/fakes.dart';
import 'connectors/manifest/fixtures.dart';

final _clock = FixedClock(DateTime(2026, 11, 4, 12));

/// Заведомо поддельные значения: настоящих секретов в тестах нет.
const String _fakeToken = 'fake-token-not-real';
const String _fakeSid = 'fake-sid-not-real';

/// Запросы к складу в последнем [_pump] с `connected: true`.
late FakeHttpTransport _transport;

/// Главный экран со складом без подключения: роли (ADR-012) и кнопки.
/// [connected] — склад подключён и отвечает пустым списком.
Future<AssistantController> _pump(
  WidgetTester tester,
  SettingsStore settings, {
  Size size = const Size(1300, 900),
  double textScale = 1,
  bool connected = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final tasks =
      TaskService(repository: InMemoryTaskRepository(), clock: _clock);
  _transport = FakeHttpTransport(
    (_) => const HttpResponseData(
      statusCode: 200,
      body: '{"ok":true,"items":[],"total":0}',
    ),
  );
  final assistant = AssistantController(
    extensions: ExtensionRegistry(
      connectors: <Connector>[
        TasksConnector(
          taskService: tasks,
          parser: ScenarioParser(clock: _clock),
        ),
        if (connected)
          warehouseConnector(
            path: patchedManifestPath,
            transport: _transport,
            secrets: InMemorySecretStore(<String, String>{
              'warehouse.token': _fakeToken,
              'warehouse.sid': _fakeSid,
            }),
            record: connectedRecord(),
          )
        else
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

/// Кто выбран в «Кому:»; `null` — никто.
String? _addressee(WidgetTester tester) {
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

/// Автор последнего ответа в ленте (`rio`, `noda`).
String? _lastAuthor(WidgetTester tester) {
  // Лента перевёрнута: первый в дереве — самый новый.
  for (final widget in tester.allWidgets) {
    final key = widget.key;
    if (key is ValueKey<String> && key.value.startsWith('message-author-')) {
      return key.value.substring('message-author-'.length);
    }
  }
  return null;
}

Future<void> _tapQuick(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(Key('quick-$label')));
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

/// Кнопка целиком на экране и нажимается.
void _expectReachable(WidgetTester tester, String label, Size screen) {
  final finder = find.byKey(Key('quick-$label'));
  expect(finder, findsOneWidget, reason: label);
  final rect = tester.getRect(finder);
  expect(
    Offset.zero & screen,
    predicate<Rect>(
      (Rect all) =>
          rect.left >= all.left &&
          rect.top >= all.top &&
          rect.right <= all.right &&
          rect.bottom <= all.bottom,
      'вмещает $rect',
    ),
    reason: label,
  );
  expect(finder.hitTestable(), findsOneWidget, reason: '$label: не нажать');
}

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

  group('«Кому:» и ведущий роли', () {
    Future<InMemorySettingsStore> nodaLeads() async {
      final store = InMemorySettingsStore();
      await store.save(
        const AppSettings(
          enabledRoles: <String>{Roles.storekeeperId},
          roleOwners: <String, String>{Roles.storekeeperId: 'noda'},
        ),
      );
      return store;
    }

    testWidgets('никого не выбрали — никто не выделен, отвечает ведущая роли',
        (tester) async {
      await _pump(tester, await nodaLeads(), connected: true);
      expect(_addressee(tester), isNull);
      expect(find.byKey(const Key('addressee-by-role')), findsOneWidget);
      await _tapQuick(tester, 'Без фото');
      expect(_lastAuthor(tester), 'noda');
      await _say(tester, '2+2');
      expect(_lastAuthor(tester), 'rio', reason: '«Личное» ведёт основной');
      expect(_addressee(tester), isNull);
    });

    testWidgets('выбранный основной отвечает и на фразы роли Noda',
        (tester) async {
      await _pump(tester, await nodaLeads(), connected: true);
      await tester.tap(find.byKey(const Key('addressee-rio')));
      await tester.pump();
      expect(_addressee(tester), 'rio');
      expect(find.byKey(const Key('addressee-by-role')), findsNothing);
      await _tapQuick(tester, 'Без фото');
      expect(_lastAuthor(tester), 'rio');
      await _say(tester, '64115');
      expect(_lastAuthor(tester), 'rio');
      expect(_addressee(tester), 'rio');
      expect(_transport.requests, hasLength(2));
      // Нажатие на выбранного снимает выбор: снова «по роли».
      await tester.tap(find.byKey(const Key('addressee-rio')));
      await tester.pump();
      expect(_addressee(tester), isNull);
      await _say(tester, '64115');
      expect(_lastAuthor(tester), 'noda');
      // Noda в «Кому:» — она отвечает и на задачи.
      await tester.tap(find.byKey(const Key('addressee-noda')));
      await tester.pump();
      expect(_addressee(tester), 'noda');
      await _say(tester, '2+2');
      expect(_lastAuthor(tester), 'noda');
    });

    testWidgets('выбор основного — «основной», а не имя', (tester) async {
      final store = await nodaLeads();
      final assistant = await _pump(tester, store, connected: true);
      await tester.tap(find.byKey(const Key('addressee-rio')));
      await tester.pump();
      // Основной сменился в настройках: выбран и отвечает новый основной.
      await tester.tap(find.byKey(const Key('nav-settings')));
      await tester.pumpAndSettle();
      final main = find.byKey(const ValueKey<String>('main-persona-noda'));
      await tester.ensureVisible(main);
      await tester.pumpAndSettle();
      await tester.tap(main);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-tasks')));
      await tester.pumpAndSettle();
      expect(assistant.personas.main.id, 'noda');
      expect(_addressee(tester), 'noda');
      await _say(tester, '2+2');
      expect(_lastAuthor(tester), 'noda');
    });

    testWidgets('«Лиорио, …» при роли Noda — дальше отвечает Liorio',
        (tester) async {
      await _pump(tester, await nodaLeads(), connected: true);
      await _say(tester, 'Лиорио, где лежит 64115');
      expect(_lastAuthor(tester), 'rio');
      expect(_addressee(tester), 'rio');
      await _say(tester, '64115');
      expect(_lastAuthor(tester), 'rio');
    });

    testWidgets('все роли ведёт основной — он и выбран, подписи нет',
        (tester) async {
      final store = InMemorySettingsStore();
      await store.save(
        const AppSettings(enabledRoles: <String>{Roles.storekeeperId}),
      );
      await _pump(tester, store, connected: true);
      expect(_addressee(tester), 'rio');
      expect(find.byKey(const Key('addressee-by-role')), findsNothing);
      await _tapQuick(tester, 'Без фото');
      expect(_lastAuthor(tester), 'rio');
      // Нажатие на и так выбранного ничего не снимает.
      await tester.tap(find.byKey(const Key('addressee-rio')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('addressee-rio')));
      await tester.pump();
      expect(_addressee(tester), 'rio');
    });
  });

  testWidgets('склад выключен в «Расширениях»: кнопок роли нет',
      (tester) async {
    final store = InMemorySettingsStore();
    await store.save(
      const AppSettings(
        enabledRoles: <String>{Roles.storekeeperId},
        disabledExtensions: <String>{'warehouse'},
      ),
    );
    final assistant = await _pump(tester, store, connected: true);
    expect(assistant.extensions.isRoleEnabled(Roles.storekeeperId), isTrue);
    for (final label in <String>[
      'Где лежит…',
      'Что пришло сегодня',
      'Без фото',
    ]) {
      expect(find.byKey(Key('quick-$label')), findsNothing, reason: label);
    }
    expect(find.byKey(const Key('quick-Покажи задачи')), findsOneWidget);
    await _say(tester, 'кто ты');
    expect(find.textContaining('со складом'), findsNothing);
    expect(_transport.requests, isEmpty);
  });

  group('кнопки роли на узком экране и крупном шрифте', () {
    const roleChips = <String>['Где лежит…', 'Что пришло сегодня', 'Без фото'];
    const taskChips = <String>['Покажи задачи', 'Новая задача'];

    Future<InMemorySettingsStore> storekeeper() async {
      final store = InMemorySettingsStore();
      await store.save(
        const AppSettings(enabledRoles: <String>{Roles.storekeeperId}),
      );
      return store;
    }

    testWidgets('320x640, шрифт 2x: одна строка, видно, что прокручивается',
        (tester) async {
      const size = Size(320, 640);
      await _pump(
        tester,
        await storekeeper(),
        size: size,
        textScale: 2,
        connected: true,
      );
      expect(tester.takeException(), isNull);
      final strip = find.byKey(const Key('quick-strip'));
      expect(strip, findsOneWidget);
      // Главная кнопка роли видна сразу, целиком, под «Кому:» и над полем.
      _expectReachable(tester, 'Где лежит…', size);
      final first = tester.getRect(find.byKey(const Key('quick-Где лежит…')));
      expect(
        first.top,
        greaterThanOrEqualTo(
          tester.getRect(find.byKey(const Key('addressee-switch'))).bottom,
        ),
      );
      expect(first.bottom, lessThan(size.height));
      // Полоса прокрутки видна всегда, строка длиннее экрана.
      final bar = tester.widget<Scrollbar>(
        find.ancestor(of: strip, matching: find.byType(Scrollbar)).first,
      );
      expect(bar.thumbVisibility, isTrue);
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: strip, matching: find.byType(Scrollable)),
          )
          .position;
      expect(position.maxScrollExtent, greaterThan(0));
      expect(
        find.descendant(of: strip, matching: find.byType(OutlinedButton)),
        findsNWidgets(roleChips.length + taskChips.length),
      );
      // Все кнопки в одной строке: ни одна не уехала под «Кому:».
      for (final label in <String>[...roleChips, ...taskChips]) {
        final rect = tester.getRect(find.byKey(Key('quick-$label')));
        expect(rect.top, first.top, reason: label);
      }
      // Нажимается и вставляет шаблон.
      await tester.tap(find.byKey(const Key('quick-Где лежит…')));
      await tester.pumpAndSettle();
      expect(_input(tester), 'Где лежит ');
      // До остальных — прокруткой строки.
      for (final label in <String>['Без фото', 'Новая задача']) {
        await tester.dragUntilVisible(
          find.byKey(Key('quick-$label')).hitTestable(),
          strip,
          const Offset(-80, 0),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(Key('quick-$label')));
        await tester.pumpAndSettle();
        // Тестовый шрифт шире настоящего: кнопка может быть шире экрана,
        // поэтому здесь проверяем только, что она нажимается.
        expect(
          find.byKey(Key('quick-$label')).hitTestable(),
          findsOneWidget,
          reason: label,
        );
        expect(tester.getRect(find.byKey(Key('quick-$label'))).top, first.top);
      }
      await tester.ensureVisible(find.byKey(const Key('quick-Без фото')));
      await tester.pumpAndSettle();
      await _tapQuick(tester, 'Без фото');
      expect(_transport.requests, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    for (final (size, scale) in <(Size, double)>[
      (const Size(1440, 900), 1.0),
      (const Size(1300, 900), 1.0),
      (const Size(390, 844), 1.0),
      (const Size(1440, 900), 2.0),
    ]) {
      testWidgets(
          'обычный размер ${size.width.toInt()}x${size.height.toInt()}, '
          'шрифт ${scale}x: все кнопки переносятся и видны', (tester) async {
        await _pump(
          tester,
          await storekeeper(),
          size: size,
          textScale: scale,
          connected: true,
        );
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('quick-strip')), findsNothing);
        expect(find.byKey(const Key('quick-rows')), findsOneWidget);
        for (final label in <String>[...taskChips, ...roleChips]) {
          _expectReachable(tester, label, size);
        }
      });
    }

    testWidgets(
        '320x640, обычный шрифт: строки; что не уместилось — прокруткой с '
        'видимой полосой', (tester) async {
      const size = Size(320, 640);
      await _pump(tester, await storekeeper(), size: size, connected: true);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('quick-strip')), findsNothing);
      final rows = find.byKey(const Key('quick-rows'));
      final bar = tester.widget<Scrollbar>(
        find.ancestor(of: rows, matching: find.byType(Scrollbar)).first,
      );
      expect(bar.thumbVisibility, isTrue);
      for (final label in <String>[...taskChips, ...roleChips]) {
        await tester.ensureVisible(find.byKey(Key('quick-$label')));
        await tester.pumpAndSettle();
        _expectReachable(tester, label, size);
      }
      // Кнопки не заходят ни под «Кому:», ни на поле ввода.
      final area = tester.getRect(
        find.ancestor(of: rows, matching: find.byType(Scrollable)).first,
      );
      expect(
        area.top,
        greaterThanOrEqualTo(
          tester.getRect(find.byKey(const Key('addressee-switch'))).bottom,
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('320x640, шрифт 2x, без роли: кнопки задач — той же строкой',
        (tester) async {
      await _pump(
        tester,
        InMemorySettingsStore(),
        size: const Size(320, 640),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('quick-strip')), findsOneWidget);
      final first = find.byKey(const Key('quick-Покажи задачи'));
      expect(first.hitTestable(), findsOneWidget);
      expect(
        tester.getRect(first).top,
        greaterThanOrEqualTo(
          tester.getRect(find.byKey(const Key('addressee-switch'))).bottom,
        ),
      );
    });
  });
}
