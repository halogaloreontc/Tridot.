import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/screens/settings_screen.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/manifest/connection.dart';
import 'package:local_assistant/core/connectors/manifest/connection_service.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import '../connectors/fakes.dart';
import '../connectors/manifest/fixtures.dart';

/// Заведомо поддельные значения: настоящих секретов в тестах нет.
const String fakeToken = 'fake-token-not-real';
const String fakeSid = 'fake-sid-not-real';
const String code = '0123456789abcdef0123456789abcdef';

final class _Harness {
  _Harness({AppSettings settings = const AppSettings()})
      : _settings = settings {
    final clock = FixedClock(DateTime(2026, 11, 2, 16, 30));
    final tasks = TaskService(
      repository: InMemoryTaskRepository(),
      clock: clock,
    );
    final transport = FakeHttpTransport(_respond);
    final connector = warehouseConnector(
      path: patchedManifestPath,
      transport: transport,
      secrets: secrets,
    );
    service = ConnectionService(
      connector: connector,
      transport: transport,
      secrets: secrets,
      store: InMemoryConnectionStore(),
      clock: clock,
    );
    registry = ExtensionRegistry(
      connectors: <Connector>[
        TasksConnector(
          taskService: tasks,
          parser: ScenarioParser(clock: clock),
        ),
        connector,
        const CalculatorConnector(),
        TalkConnector(taskService: tasks),
      ],
      choice: settings.extensionChoice,
    );
  }

  final InMemorySecretStore secrets = InMemorySecretStore();
  late final ConnectionService service;
  late final ExtensionRegistry registry;
  AppSettings _settings;
  AppSettings get settings => _settings;

  static HttpResponseData _json(Map<String, Object?> body) =>
      HttpResponseData(statusCode: 200, body: jsonEncode(body));

  HttpResponseData _respond(HttpRequestData request) {
    if (request.uri.path.endsWith('assistant.json')) {
      return HttpResponseData(
        statusCode: 200,
        body: manifestSource(patchedManifestPath),
      );
    }
    return switch (request.uri.queryParameters['action']) {
      'qr_take' => _json(<String, Object?>{
          'ok': true,
          'token': fakeToken,
          'sid': fakeSid,
          'login': 'ivanov',
        }),
      _ => _json(<String, Object?>{'ok': true}),
    };
  }

  Widget build({Size? size, double scale = 1}) {
    final app = MaterialApp(
      theme: AssistantTheme.dark(),
      home: StatefulBuilder(
        builder: (context, setState) => Scaffold(
          body: SettingsScreen(
            settings: _settings,
            onChanged: (AppSettings value) => setState(() {
              _settings = value;
              registry.apply(value.extensionChoice);
            }),
            onClearChat: () {},
            messageCount: 1,
            extensions: registry,
            connections: <ConnectionService>[service],
          ),
        ),
      ),
    );
    if (size == null) return app;
    return MediaQuery(
      data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
      child: app,
    );
  }
}

Finder _key(String key) => find.byKey(ValueKey<String>(key));

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.pumpAndSettle();
  await tester.tap(_key(key));
  await tester.pumpAndSettle();
}

SwitchListTile _switch(WidgetTester tester, String key) =>
    tester.widget<SwitchListTile>(_key(key));

void main() {
  testWidgets('«Роли» над «Расширениями»: карточки, что входит, статус',
      (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('Роли')).dy,
      lessThan(tester.getTopLeft(find.text('Расширения')).dy),
    );
    expect(_switch(tester, 'role-personal').value, isTrue);
    expect(_switch(tester, 'role-storekeeper').value, isFalse);
    expect(
      find.text('Входит: Задачи, Калькулятор, Беседа'),
      findsOneWidget,
    );
    expect(find.text('Входит: Склад, Беседа'), findsOneWidget);
    expect(
      find.text('Кнопки: «Где лежит…», «Что пришло сегодня», «Без фото»'),
      findsOneWidget,
    );
    expect(find.text('Склад не подключён'), findsOneWidget);
    expect(find.text('Подключить склад'), findsOneWidget);
    // Склад вне роли неактивен и в «Расширениях».
    await tester.ensureVisible(_key('extension-warehouse'));
    expect(_switch(tester, 'extension-warehouse').onChanged, isNull);
  });

  testWidgets('переключатель роли: склад включается, подключения не трогает',
      (tester) async {
    final h = _Harness();
    await h.secrets.write('warehouse.token', fakeToken);
    h.service.connector.record = connectedRecord();
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    await _tap(tester, 'role-storekeeper');
    expect(h.settings.enabledRoles, <String>{Roles.storekeeperId});
    expect(h.registry.isEnabled('warehouse'), isTrue);
    expect(find.text('Подключён: ivanov · под своим логином'), findsWidgets);
    await tester.ensureVisible(_key('extension-warehouse'));
    expect(_switch(tester, 'extension-warehouse').value, isTrue);
    expect(_switch(tester, 'extension-warehouse').onChanged, isNotNull);

    await _tap(tester, 'role-storekeeper');
    expect(h.settings.enabledRoles, isEmpty);
    expect(h.registry.isEnabled('warehouse'), isFalse);
    expect(await h.secrets.read('warehouse.token'), fakeToken);
    expect(h.service.connected, isTrue);

    await _tap(tester, 'role-personal');
    expect(h.settings.disabledRoles, <String>{Roles.personalId});
    expect(h.registry.isEnabled('calc'), isFalse);
    expect(h.registry.isEnabled(TasksConnector.id), isTrue);
  });

  testWidgets('«Ведёт:» в карточке роли нет: ведущего задают обязанности',
      (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    expect(find.text('Ведёт:'), findsNothing);
    expect(
      _key('role-owner-${Roles.storekeeperId}-noda'),
      findsNothing,
    );
  });

  testWidgets('«Подключить склад» → экран подключения, вход включает роль',
      (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    await _tap(tester, 'role-connect-${Roles.storekeeperId}');
    expect(_key('connection-link'), findsOneWidget);
    expect(_key('connection-manifest-origin'), findsOneWidget);
    await tester.enterText(
      _key('connection-link'),
      'https://warehouse.example/#qr=$code',
    );
    await _tap(tester, 'connection-link-connect');
    expect(h.service.connected, isTrue);
    expect(h.settings.enabledRoles, <String>{Roles.storekeeperId});
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(_switch(tester, 'role-storekeeper').value, isTrue);
    expect(find.text('Склад не подключён'), findsNothing);
    expect(find.text('Настроить'), findsWidgets);
  });

  testWidgets('навык выключен в «Расширениях»: карточка роли говорит прямо',
      (tester) async {
    final h = _Harness(
      settings: const AppSettings(
        enabledRoles: <String>{Roles.storekeeperId},
        disabledExtensions: <String>{'warehouse'},
      ),
    );
    await h.secrets.write('warehouse.token', fakeToken);
    h.service.connector.record = connectedRecord();
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    expect(_switch(tester, 'role-storekeeper').value, isTrue);
    final note = _key('role-off-${Roles.storekeeperId}');
    expect(note, findsOneWidget);
    expect(
      tester.widget<Text>(note).data,
      startsWith('Навык «Склад» выключен в «Расширениях»'),
    );
    expect(_key('role-off-${Roles.personalId}'), findsNothing);
    expect(h.registry.activeChips, isEmpty);

    // Включили навык в «Расширениях» — пометка пропала, кнопки вернулись.
    await _tap(tester, 'extension-warehouse');
    expect(h.settings.disabledExtensions, isEmpty);
    expect(note, findsNothing);
    expect(h.registry.activeChips, hasLength(3));

    // И обратно: выключили там же — пометка появилась сразу.
    await _tap(tester, 'extension-warehouse');
    expect(h.settings.disabledExtensions, <String>{'warehouse'});
    expect(note, findsOneWidget);

    // Роль выключена — пометки нет: неактивной роли она ни к чему.
    await _tap(tester, 'role-storekeeper');
    expect(note, findsNothing);
  });

  testWidgets('навык склада называется одинаково в «Ролях» и «Расширениях»',
      (tester) async {
    final h = _Harness(
      settings: const AppSettings(
        enabledRoles: <String>{Roles.storekeeperId},
      ),
    );
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    final title = h.registry.info('warehouse')!.title;
    final includes =
        tester.widget<Text>(_key('role-includes-${Roles.storekeeperId}')).data!;
    expect(includes, 'Входит: $title, Беседа');
    // Строка подключения в «Расширениях» — с тем же названием.
    expect(
      find.descendant(
        of: _key('extension-warehouse'),
        matching: find.text(title),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Складские вопросы'), findsNothing);
    expect(h.registry.skillTitle('warehouse'), title);
  });

  for (final (name, size, scale) in <(String, Size, double)>[
    ('320x640 при масштабе 2', const Size(320, 640), 2.0),
    ('1600x900', const Size(1600, 900), 1.0),
  ]) {
    testWidgets('без переполнения: $name', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final h = _Harness(
        settings: const AppSettings(
          enabledRoles: <String>{Roles.storekeeperId},
        ),
      );
      await tester.pumpWidget(h.build(size: size, scale: scale));
      await tester.pumpAndSettle();
      for (final key in <String>[
        'role-card-${Roles.personalId}',
        'role-card-${Roles.storekeeperId}',
        'role-connect-${Roles.storekeeperId}',
      ]) {
        await tester.ensureVisible(_key(key));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: key);
      }
    });
  }

  testWidgets('«Разрешить действия»: под логином, диалог, сброс при выходе',
      (tester) async {
    final h = _Harness(
      settings: const AppSettings(enabledRoles: <String>{Roles.storekeeperId}),
    );
    await h.secrets.write('warehouse.token', fakeToken);
    h.service.connector.record = connectedRecord(
      level: ConnectionLevel.shared,
      login: null,
    );
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    // Только паролем склада — выключено и не включается.
    await tester.ensureVisible(_key('role-actions-storekeeper'));
    expect(_switch(tester, 'role-actions-storekeeper').value, isFalse);
    expect(_switch(tester, 'role-actions-storekeeper').onChanged, isNull);
    expect(find.textContaining('Нужен вход под своим логином'), findsOneWidget);

    await h.secrets.write('warehouse.sid', fakeSid);
    h.service.connector.record = connectedRecord();
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    expect(_switch(tester, 'role-actions-storekeeper').onChanged, isNotNull);
    // Включение — через диалог; «Отмена» ничего не меняет.
    await _tap(tester, 'role-actions-storekeeper');
    expect(find.byKey(const Key('role-actions-dialog')), findsOneWidget);
    expect(find.textContaining('от имени ivanov'), findsOneWidget);
    await tester.tap(find.byKey(const Key('role-actions-no')));
    await tester.pumpAndSettle();
    expect(h.settings.roleActions, isEmpty);
    await _tap(tester, 'role-actions-storekeeper');
    await tester.tap(find.byKey(const Key('role-actions-yes')));
    await tester.pumpAndSettle();
    expect(
      h.settings.roleActions,
      <String, String>{Roles.storekeeperId: 'ivanov'},
    );
    expect(_switch(tester, 'role-actions-storekeeper').value, isTrue);
    expect(
      find.text('Действия от имени ivanov. Каждое — только после '
          '«Подтвердить» на карточке.'),
      findsOneWidget,
    );
    expect(h.service.connector.info.access, ConnectorAccess.readWrite);
    // В settings.json — логин, не секрет.
    final json = jsonEncode(h.settings.toJson());
    expect(json, contains('"role_actions":{"storekeeper":"ivanov"}'));
    expect(json, isNot(contains(fakeSid)));
    expect(json, isNot(contains(fakeToken)));

    // Выключение — сразу, без диалога.
    await _tap(tester, 'role-actions-storekeeper');
    expect(h.settings.roleActions, isEmpty);
    expect(h.service.connector.info.access, ConnectorAccess.readOnly);
  });

  testWidgets('роль выключена — переключатель неактивен', (tester) async {
    final h = _Harness(
      settings: const AppSettings(
        roleActions: <String, String>{Roles.storekeeperId: 'ivanov'},
      ),
    );
    await h.secrets.write('warehouse.token', fakeToken);
    await h.secrets.write('warehouse.sid', fakeSid);
    h.service.connector.record = connectedRecord();
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    await tester.ensureVisible(_key('role-actions-storekeeper'));
    expect(_switch(tester, 'role-actions-storekeeper').onChanged, isNull);
    // Роль выключена — расширению логин не передан.
    expect(h.service.connector.info.access, ConnectorAccess.readOnly);
  });
}
