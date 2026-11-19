import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/shell/incoming_connect.dart';
import 'package:local_assistant/app/widgets/add_app_screen.dart';
import 'package:local_assistant/app/widgets/connection_screen.dart';
import 'package:local_assistant/app/widgets/connections_host.dart';
import 'package:local_assistant/app/widgets/connections_section.dart';
import 'package:local_assistant/app/widgets/warehouse_card_view.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/manifest/app_connections.dart';
import 'package:local_assistant/core/connectors/manifest/app_profile.dart';
import 'package:local_assistant/core/connectors/manifest/connection.dart';
import 'package:local_assistant/core/connectors/manifest/connection_directory.dart';
import 'package:local_assistant/core/connectors/manifest/connection_service.dart';
import 'package:local_assistant/core/connectors/manifest/connection_slots.dart';
import 'package:local_assistant/core/connectors/manifest/connection_texts.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/models/warehouse_card.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';

import '../connectors/manifest/fixtures.dart';

/// Интерфейс подключений приложений (ADR-039, шаг 3): список
/// «Подключения», «Подключить приложение» с согласием, входящие ссылки,
/// удаление и карточка ответа с названием приложения. Приложение —
/// синтетическая CRM `testcrm`, адреса — `.example`, секреты — поддельные
/// (CANARY).
const String testCrmPath = 'test/fixtures/assistant/testcrm.json';
const String canaryToken = 'CANARY-crm-token-not-real';
const String code = '0123456789abcdef0123456789abcdef';

String crmSource() => File(testCrmPath).readAsStringSync();

/// Хранилище секретов, которое помнит удаления.
final class RecordingSecrets implements SecretStore {
  final Map<String, String> values = <String, String>{};
  final List<String> deleted = <String>[];

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async {
    deleted.add(key);
    values.remove(key);
  }
}

/// Сеть по хостам: `crm.example`, `crm2.example` (то же описание) и
/// `warehouse.example` (описание склада).
final class Routes implements HttpTransport {
  final List<HttpRequestData> requests = <HttpRequestData>[];

  @override
  Future<HttpResponseData> send(HttpRequestData request) async {
    requests.add(request);
    final host = request.uri.host;
    final path = request.uri.path;
    if (path.endsWith('assistant.json')) {
      if (host == 'crm.example' || host == 'crm2.example') {
        return HttpResponseData(statusCode: 200, body: crmSource());
      }
      if (host == 'warehouse.example') {
        return HttpResponseData(
          statusCode: 200,
          body: manifestSource(patchedManifestPath),
        );
      }
    }
    if (path.endsWith('assist.php')) {
      return HttpResponseData(
        statusCode: 200,
        body: jsonEncode(<String, Object?>{
          'ok': true,
          'q': 'тестов',
          'count': 1,
          'items': <Object?>[
            <String, Object?>{'name': 'Тестов Т. Т.', 'car': 'Тест-1'},
          ],
        }),
      );
    }
    return const HttpResponseData(statusCode: 404);
  }

  /// Запросы не за описанием: вход, действия.
  List<HttpRequestData> get actions => <HttpRequestData>[
        for (final r in requests)
          if (!r.uri.path.endsWith('assistant.json')) r,
      ];
}

/// Склад, каталог подключений, реестр и настройки — как в `HomePage`.
final class Ui {
  Ui() {
    final connector = warehouseConnector(
      path: patchedManifestPath,
      transport: transport,
      secrets: secrets,
    );
    warehouse = ConnectionService(
      connector: connector,
      transport: transport,
      secrets: secrets,
      store: store,
      clock: FixedClock(DateTime(2026, 11, 19, 10, 30)),
    );
    apps = AppConnections(
      transport: transport,
      secrets: secrets,
      store: store,
      directory: directory,
      known: <ConnectionService>[warehouse],
      clock: FixedClock(DateTime(2026, 11, 19, 10, 30)),
    );
    registry = ExtensionRegistry(connectors: _connectors());
    // Пересборка реестра, как ConnectorAssembly между ходами.
    apps.addListener(() => registry.rebuild(_connectors()));
    host = ConnectionsHost(
      apps: apps,
      registry: registry,
      settings: () => settings,
      onChanged: (AppSettings value) {
        settings = value;
        registry.apply(value.extensionChoice);
      },
    );
  }

  final Routes transport = Routes();
  final RecordingSecrets secrets = RecordingSecrets();
  final InMemoryConnectionStore store = InMemoryConnectionStore();
  late final InMemoryConnectionDirectory directory =
      InMemoryConnectionDirectory(store: store);
  late final ConnectionService warehouse;
  late final AppConnections apps;
  late final ExtensionRegistry registry;
  late final ConnectionsHost host;
  AppSettings settings = const AppSettings();

  List<Connector> _connectors() => <Connector>[
        for (final service in apps.services) service.connector,
        const CalculatorConnector(),
      ];

  /// Подключить CRM с [address] без экрана.
  Future<ConnectionService> addCrm([String address = 'crm.example']) async {
    final added = await apps.add(await apps.probe(address));
    host.setEnabled(added.service.slot.id, true);
    return added.service;
  }

  Widget app(Widget home, {bool dark = false}) => MaterialApp(
        theme: dark ? AssistantTheme.dark() : AssistantTheme.light(),
        home: home,
      );

  Widget section({bool dark = false}) => app(
        Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: ConnectionsSection(host: host),
          ),
        ),
        dark: dark,
      );
}

/// Дождаться сети и шторок: индикатор крутится — [WidgetTester.pumpAndSettle]
/// не годится.
Future<void> settle(WidgetTester tester, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  tearDown(() => ConnectionSlots.useRuntime(const <ConnectionSlot>[]));

  testWidgets('список: склад, приложение, запись с проблемой, предложение',
      (tester) async {
    final ui = Ui();
    await tester.runAsync(() async {
      await ui.apps.load();
      await ui.addCrm();
      // Запись каталога, чей профиль больше не проходит проверку.
      final json = jsonDecode(ui.directory.text!) as Map<String, Object?>;
      (json['apps']! as List<Object?>).add(<String, Object?>{
        'id': 'bad',
        'appId': 'bad',
        'base': 'https://bad.example/',
        'profile': <String, Object?>{'id': 'bad', 'name': 'пароль'},
      });
      ui.directory.text = jsonEncode(json);
      await ui.apps.load();
    });
    ui.registry.rebuild(<Connector>[
      for (final s in ui.apps.services) s.connector,
    ]);
    ui.apps.byId('testcrm')!.offered = 'новые действия: ask_orders';
    await tester.pumpWidget(ui.section());
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('connection-row-warehouse')),
      findsOneWidget,
    );
    expect(find.text('Склад'), findsOneWidget);
    final crm = find.byKey(const ValueKey<String>('connection-row-testcrm'));
    expect(crm, findsOneWidget);
    expect(
      find.descendant(of: crm, matching: find.text('Автосервис')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: crm,
        matching: find.textContaining('crm.example · Не подключён'),
      ),
      findsOneWidget,
    );
    final toggle = tester.widget<Switch>(
      find.byKey(const ValueKey<String>('connection-toggle-testcrm')),
    );
    expect(toggle.value, isTrue);
    expect(
      find.text('Приложение предлагает изменения — подключить заново'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('connection-broken-bad')),
      findsOneWidget,
    );
    expect(find.textContaining('не работает'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('connections-add')),
      findsOneWidget,
    );

    // Переключатель — выбор расширений.
    await tester.tap(
      find.byKey(const ValueKey<String>('connection-toggle-testcrm')),
    );
    await tester.pump();
    expect(ui.registry.isEnabled('testcrm'), isFalse);

    // Запись с проблемой: «Удалить» → подтверждение → нет её.
    await tester.tap(
      find.byKey(const ValueKey<String>('connection-broken-remove-bad')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('connection-remove-yes')),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(ui.apps.entries.map((DirectoryEntry e) => e.id), <String>[
      'testcrm',
    ]);
    expect(
      find.byKey(const ValueKey<String>('connection-broken-bad')),
      findsNothing,
    );
  });

  testWidgets(
      '«Подключить приложение»: адрес → согласие (хост первым, что читает, '
      'без записи) → подключено, включено, экран входа', (tester) async {
    final ui = Ui();
    await tester.runAsync(ui.apps.load);
    await tester.pumpWidget(ui.section());
    await tester.tap(find.byKey(const ValueKey<String>('connections-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('add-app-address')),
      'crm.example',
    );
    await tester.tap(find.byKey(const ValueKey<String>('add-app-next')));
    await settle(tester);

    final host = find.byKey(const ValueKey<String>('app-consent-host'));
    expect(host, findsOneWidget);
    expect(
      find.descendant(of: host, matching: find.text('crm.example')),
      findsOneWidget,
    );
    final title = find.byKey(const ValueKey<String>('app-consent-title'));
    expect(
      find.text('Так приложение называет себя: «Тестовая CRM»'),
      findsOneWidget,
    );
    expect(tester.getTopLeft(host).dy, lessThan(tester.getTopLeft(title).dy));
    expect(
      find.text('Найти клиента — «найди клиента Тестов»'),
      findsOneWidget,
    );
    expect(find.textContaining('Пароль CRM'), findsOneWidget);
    expect(
      find.text(
        'Только чтение: изменять данные в приложении Связной не будет.',
      ),
      findsOneWidget,
    );
    // О записи — ни слова, кроме «только чтение».
    expect(find.textContaining('Разрешить'), findsNothing);
    expect(find.textContaining('перемещ'), findsNothing);
    expect(find.textContaining('Подтвердить'), findsNothing);
    // До «Подключить» ничего не сохранено.
    expect(ui.apps.runtime, isEmpty);
    expect(ui.directory.text, isNull);

    await tester.tap(find.byKey(const ValueKey<String>('app-consent-yes')));
    await settle(tester);
    await tester.pumpAndSettle();

    expect(ui.apps.runtime.single.slot.id, 'testcrm');
    expect(ui.registry.isEnabled('testcrm'), isTrue);
    expect(ui.settings.extensionChoice.enabled, contains('testcrm'));
    expect(find.byType(ConnectionScreen), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Автосервис'), findsOneWidget);
    expect(find.text('Адрес автосервиса'), findsOneWidget);
    expect(find.text('Пароль CRM'), findsOneWidget);
    // Входа по ссылке и логина сотрудника в описании CRM нет.
    expect(find.text('Подключить по ссылке'), findsNothing);
    expect(find.text('Логин сотрудника'), findsNothing);
    expect(find.textContaining('склад'), findsNothing);
    // Ни входа, ни действий без человека.
    expect(ui.transport.actions, isEmpty);
  });

  testWidgets('адрес склада — к подключению склада; подключённое — к нему',
      (tester) async {
    final ui = Ui();
    await tester.runAsync(() async {
      await ui.apps.load();
      await ui.addCrm();
    });
    await tester.pumpWidget(ui.app(AddAppScreen(host: ui.host)));
    await tester.enterText(
      find.byKey(const ValueKey<String>('add-app-address')),
      'warehouse.example',
    );
    await tester.tap(find.byKey(const ValueKey<String>('add-app-next')));
    await settle(tester);
    expect(find.byKey(const ValueKey<String>('app-consent')), findsNothing);
    expect(find.byKey(const ValueKey<String>('add-app-known')), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('add-app-open-known')),
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Склад'), findsOneWidget);
    expect(find.text('Адрес склада'), findsOneWidget);
    expect(ui.apps.runtime.length, 1);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(ui.app(AddAppScreen(host: ui.host)));
    await tester.enterText(
      find.byKey(const ValueKey<String>('add-app-address')),
      'https://crm.example/',
    );
    await tester.tap(find.byKey(const ValueKey<String>('add-app-next')));
    await settle(tester);
    expect(
      find.byKey(const ValueKey<String>('add-app-existing')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('add-app-open-existing')),
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Автосервис'), findsOneWidget);
    expect(ui.apps.runtime.length, 1);
  });

  group('входящие ссылки', () {
    Future<void> incoming(
      WidgetTester tester,
      Ui ui,
      String text,
      List<String?> notes,
    ) async {
      await tester.pumpWidget(
        ui.app(
          Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () async => notes.add(
                  await handleIncomingConnect(
                    context,
                    text: text,
                    image: false,
                    warehouse: ui.warehouse,
                    host: ui.host,
                    onWarehouseEnabled: (_) {},
                  ),
                ),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await settle(tester);
    }

    String link(String base) =>
        'tridot://connect?u=${Uri.encodeComponent(base)}&qr=$code';

    testWidgets('чужое приложение — только согласие, ничего не подключено',
        (tester) async {
      final ui = Ui();
      await tester.runAsync(ui.apps.load);
      final notes = <String?>[];
      await incoming(tester, ui, link('https://crm.example/'), notes);
      expect(find.byKey(const ValueKey<String>('app-consent')), findsOneWidget);
      expect(find.text('crm.example'), findsOneWidget);
      expect(ui.apps.runtime, isEmpty);
      expect(ui.directory.text, isNull);
      expect(ui.transport.actions, isEmpty);
      // «Отмена» — так и не подключено; в поле — адрес без кода.
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(ui.apps.runtime, isEmpty);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey<String>('add-app-address')),
      );
      expect(field.controller!.text, 'https://crm.example/');
      expect(find.textContaining(code), findsNothing);
      expect(ui.transport.actions, isEmpty);
    });

    testWidgets('подключённое приложение с другого хоста не перенацеливается',
        (tester) async {
      final ui = Ui();
      await tester.runAsync(() async {
        await ui.apps.load();
        await ui.addCrm();
      });
      final notes = <String?>[];
      await incoming(tester, ui, link('https://crm2.example/'), notes);
      // Не вход в «Автосервис», а согласие на новое приложение.
      expect(
        find.byKey(const ValueKey<String>('app-link-confirm')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey<String>('app-consent')), findsOneWidget);
      expect(find.text('crm2.example'), findsOneWidget);
      expect(ui.apps.byId('testcrm')!.fixedBase!.host, 'crm.example');
      expect(ui.transport.actions, isEmpty);
    });

    testWidgets('то же приложение и хост — подтверждение входа в него',
        (tester) async {
      final ui = Ui();
      await tester.runAsync(() async {
        await ui.apps.load();
        await ui.addCrm();
      });
      final notes = <String?>[];
      await incoming(tester, ui, link('https://crm.example/'), notes);
      expect(find.byKey(const ValueKey<String>('app-consent')), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('app-link-confirm')),
        findsOneWidget,
      );
      expect(find.text('Войти в «Автосервис»?'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(notes, <String?>[null]);
      expect(ui.transport.actions, isEmpty);
    });

    testWidgets('ссылка склада — прежнее подтверждение склада', (tester) async {
      final ui = Ui();
      await tester.runAsync(ui.apps.load);
      final notes = <String?>[];
      await incoming(tester, ui, link('https://warehouse.example/'), notes);
      expect(
        find.byKey(const ValueKey<String>('warehouse-link-confirm')),
        findsOneWidget,
      );
      expect(find.text('Подключить склад?'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('app-consent')), findsNothing);
    });

    testWidgets('описание не получено — прежнее подтверждение склада',
        (tester) async {
      final ui = Ui();
      await tester.runAsync(ui.apps.load);
      final notes = <String?>[];
      // На этом хосте описания нет (сервер молчит, нет сети): как до
      // ADR-039 — ссылка идёт складу, а не на «Подключить приложение».
      await incoming(tester, ui, link('https://silent.example/'), notes);
      expect(
        find.byKey(const ValueKey<String>('warehouse-link-confirm')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey<String>('app-consent')), findsNothing);
      expect(ui.apps.runtime, isEmpty);
    });

    testWidgets('без каталога — как раньше: только склад', (tester) async {
      final ui = Ui();
      final notes = <String?>[];
      await tester.pumpWidget(
        ui.app(
          Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () async => notes.add(
                  await handleIncomingConnect(
                    context,
                    text: 'просто текст',
                    image: false,
                    warehouse: ui.warehouse,
                    onWarehouseEnabled: (_) {},
                  ),
                ),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await settle(tester);
      expect(notes, <String?>[
        'Через «Поделиться» Tridot принимает только ссылку склада.',
      ]);
    });
  });

  testWidgets('«Удалить»: подтверждение → подключения нет, секреты стёрты',
      (tester) async {
    final ui = Ui();
    late ConnectionService crm;
    await tester.runAsync(() async {
      await ui.apps.load();
      crm = await ui.addCrm();
      await ui.secrets.write('testcrm.token', canaryToken);
    });
    await tester.pumpWidget(ui.section());
    await tester
        .tap(find.byKey(const ValueKey<String>('connection-row-testcrm')));
    await tester.pumpAndSettle();
    expect(find.byType(ConnectionScreen), findsOneWidget);
    final remove = find.byKey(const ValueKey<String>('connection-remove'));
    await tester.scrollUntilVisible(
      remove,
      200,
      scrollable: find
          .descendant(
            of: find.byType(ConnectionScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('connection-remove-dialog')),
      findsOneWidget,
    );
    expect(find.text('Удалить «Автосервис»?'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('connection-remove-yes')),
    );
    await settle(tester);
    await tester.pumpAndSettle();
    expect(ui.apps.runtime, isEmpty);
    expect(ui.apps.byId('testcrm'), isNull);
    expect(ui.secrets.values.containsKey('testcrm.token'), isFalse);
    expect(
      ui.secrets.deleted,
      containsAll(<String>['testcrm.token', 'testcrm.sid']),
    );
    expect(ui.settings.extensionChoice.enabled, isNot(contains('testcrm')));
    expect(find.byType(ConnectionScreen), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('connection-row-testcrm')),
      findsNothing,
    );
    expect(crm.connected, isFalse);
  });

  group('карточка ответа: название приложения', () {
    WarehouseCard card(String connector, {String title = ''}) => WarehouseCard(
          connector: connector,
          command: 'client',
          title: title,
          say: '',
          rows: const <WarehouseRow>[
            WarehouseRow(title: 'Тестов Т. Т.', text: 'Тест-1'),
          ],
          more: true,
        );

    AppProfile profile(Map<String, Object?> app) =>
        AppProfile.parse(app).profile!;

    Future<void> show(
      WidgetTester tester,
      WarehouseCard card,
      ConnectionTexts texts, {
      bool open = true,
    }) =>
        tester.pumpWidget(
          MaterialApp(
            theme: AssistantTheme.light(),
            home: Scaffold(
              body: WarehouseCardView(
                card: card,
                texts: texts,
                onOpen: open ? () {} : null,
              ),
            ),
          ),
        );

    final cases = <(String, Map<String, Object?>, String, String, String)>[
      (
        'мужской род',
        (jsonDecode(crmSource()) as Map<String, Object?>)['app']!
            as Map<String, Object?>,
        'Автосервис',
        'Открыть автосервис',
        'Автосервис показал не всё — уточните запрос.',
      ),
      (
        'женский род',
        <String, Object?>{
          'id': 'kassa',
          'name': 'касса',
          'forms': <String, String>{
            'nom': 'касса',
            'gen': 'кассы',
            'dat': 'кассе',
            'acc': 'кассу',
            'ins': 'кассой',
            'prep': 'кассе',
          },
          'gender': 'f',
        },
        'Касса',
        'Открыть кассу',
        'Касса показала не всё — уточните запрос.',
      ),
      (
        'несклоняемое',
        <String, Object?>{'id': 'crm', 'name': 'CRM'},
        'CRM',
        'Открыть CRM',
        'Ответ CRM — не весь: уточните запрос.',
      ),
    ];
    for (final (name, app, title, open, partial) in cases) {
      testWidgets(name, (tester) async {
        final p = profile(app);
        final id = p.appId;
        await show(
          tester,
          card(id),
          ConnectionTexts.of(ConnectionSlot.generic(p, id)),
        );
        expect(find.text(title), findsOneWidget);
        expect(find.text(open), findsOneWidget);
        expect(find.text(partial), findsOneWidget);
        expect(find.textContaining('клад'), findsNothing);
        expect(find.byIcon(Icons.hub_outlined), findsOneWidget);
      });
    }

    testWidgets('склад — прежние тексты', (tester) async {
      await show(tester, card('warehouse'), ConnectionTexts.warehouse);
      expect(find.text('Склад'), findsOneWidget);
      expect(find.text('Открыть склад'), findsOneWidget);
      expect(
        find.text('Склад показал не всё — уточните запрос.'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.inventory_2_outlined), findsOneWidget);
    });

    testWidgets('подключение удалено — карточка без кнопок', (tester) async {
      await show(tester, card('gone'), ConnectionTexts.app, open: false);
      expect(find.text('Приложение'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      expect(find.text('Тестов Т. Т.'), findsOneWidget);
    });
  });
}
