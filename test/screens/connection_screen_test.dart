import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/widgets/extensions_section.dart';
import 'package:local_assistant/app/widgets/roles_section.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/manifest/connection.dart';
import 'package:local_assistant/core/connectors/manifest/connection_service.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';

import '../connectors/fakes.dart';
import '../connectors/manifest/fixtures.dart';

/// Заведомо поддельные значения: настоящих секретов в тестах нет.
const String fakeToken = 'fake-token-not-real';
const String fakeSid = 'fake-sid-not-real';
const String code = '0123456789abcdef0123456789abcdef';

HttpResponseData _json(int status, Map<String, Object?> body) =>
    HttpResponseData(statusCode: status, body: jsonEncode(body));

final class _Harness {
  _Harness({String manifestBody = '', this.brokenStorage = false})
      : _manifestBody = manifestBody {
    final transport = FakeHttpTransport(_respond);
    final SecretStore keys =
        brokenStorage ? _BrokenSecretStore(secrets) : secrets;
    final connector = warehouseConnector(
      path: currentManifestPath,
      transport: transport,
      secrets: keys,
    );
    service = ConnectionService(
      connector: connector,
      transport: transport,
      secrets: keys,
      store: store,
      clock: FixedClock(DateTime(2026, 11, 2, 16, 30)),
    );
    registry = ExtensionRegistry(
      connectors: <Connector>[connector, const CalculatorConnector()],
    );
    this.transport = transport;
  }

  final String _manifestBody;

  /// Хранилище секретов не пишет и не удаляет (нет места или прав).
  final bool brokenStorage;
  final String manifestPath = patchedManifestPath;
  final InMemorySecretStore secrets = InMemorySecretStore();
  final InMemoryConnectionStore store = InMemoryConnectionStore();
  late final ConnectionService service;
  late final ExtensionRegistry registry;
  late final FakeHttpTransport transport;
  AppSettings settings = const AppSettings();

  HttpResponseData _respond(HttpRequestData request) {
    if (request.uri.path.endsWith('assistant.json')) {
      return HttpResponseData(
        statusCode: 200,
        body: _manifestBody.isEmpty
            ? manifestSource(manifestPath)
            : _manifestBody,
      );
    }
    return switch (request.uri.queryParameters['action']) {
      'qr_take' => _json(200, <String, Object?>{
          'ok': true,
          'token': fakeToken,
          'sid': fakeSid,
          'login': 'ivanov',
        }),
      'ask_stock' => request.headers['X-Wh-Token'] == fakeToken
          ? _json(200, <String, Object?>{'ok': true, 'items': <Object?>[]})
          : _json(401, <String, Object?>{'error': 'Неверный пароль'}),
      'sess_end' => _json(200, <String, Object?>{'ok': true, 'ended': true}),
      _ => _json(400, <String, Object?>{'error': 'Неизвестное действие'}),
    };
  }

  Widget build() => MaterialApp(
        theme: AssistantTheme.dark(),
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            // «Роли» — во вкладке «Помощники», «Расширения» — в «Настройках»;
            // здесь они рядом: роль включает навыки расширений.
            body: Builder(
              builder: (BuildContext context) {
                void onChanged(AppSettings value) => setState(() {
                      settings = value;
                      registry.apply(value.extensionChoice);
                    });
                return SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      RolesSection(
                        registry: registry,
                        settings: settings,
                        onChanged: onChanged,
                        connections: <ConnectionService>[service],
                      ),
                      ExtensionsSection(
                        registry: registry,
                        settings: settings,
                        onChanged: onChanged,
                        connections: <ConnectionService>[service],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );
}

/// Пишет и удаляет с ошибкой, читает из [_inner].
final class _BrokenSecretStore implements SecretStore {
  _BrokenSecretStore(this._inner);

  final SecretStore _inner;

  @override
  Future<String?> read(String key) => _inner.read(key);

  @override
  Future<void> write(String key, String value) async =>
      throw const FileSystemException('нет места');

  @override
  Future<void> delete(String key) async =>
      throw const FileSystemException('нет прав');
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey<String>(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String text) async {
  final finder = find.byKey(ValueKey<String>(key));
  await tester.ensureVisible(finder);
  await tester.enterText(finder, text);
}

SwitchListTile _switch(WidgetTester tester) => tester.widget<SwitchListTile>(
      find.byKey(const ValueKey<String>('extension-warehouse')),
    );

String _fieldText(WidgetTester tester, String key) => tester
    .widget<TextField>(find.byKey(ValueKey<String>(key)))
    .controller!
    .text;

void main() {
  testWidgets('не подключён: статус и неактивный переключатель',
      (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.build());
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('extension-warehouse')),
    );
    expect(
      find.textContaining('Не подключён — сначала подключите'),
      findsOneWidget,
    );
    // Склад входит в роль «Кладовщик» (ADR-012): пока она выключена,
    // переключатель неактивен.
    expect(find.textContaining('Входит в роль «Кладовщик»'), findsOneWidget);
    expect(_switch(tester).onChanged, isNull);
    expect(_switch(tester).value, isFalse);
    expect(
      find.byKey(const ValueKey<String>('extension-configure-warehouse')),
      findsOneWidget,
    );
  });

  testWidgets('вставка ссылки → подключён, включён; выход → выключен',
      (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.build());
    await _tap(tester, 'extension-configure-warehouse');
    expect(find.textContaining('Скопировать ссылку'), findsOneWidget);
    expect(
      find.textContaining('не открывайте ссылку «#qr=»'),
      findsOneWidget,
    );
    // В складе до 1.4.56 кнопки нет: экран так и говорит.
    expect(find.textContaining('старше 1.4.56'), findsOneWidget);
    expect(find.textContaining('подключите его вручную'), findsOneWidget);

    await _enter(
      tester,
      'connection-link',
      'https://warehouse.example/#qr=$code',
    );
    await _tap(tester, 'connection-link-connect');
    expect(
      find.text('Подключён: ivanov · под своим логином'),
      findsOneWidget,
    );
    expect(find.text('Версия описания: 1.4.56'), findsOneWidget);
    expect(_fieldText(tester, 'connection-link'), isEmpty);
    // Вход включает роль «Кладовщик» (ADR-012): склад включён через неё.
    expect(h.settings.enabledRoles, contains(Roles.storekeeperId));
    expect(h.registry.isEnabled('warehouse'), isTrue);
    expect(await h.secrets.read('warehouse.token'), fakeToken);

    // Ни в settings.json, ни в состоянии подключения секретов нет.
    // Файлы — настоящий ввод-вывод: вне поддельного времени теста.
    final saved = await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('settings');
      try {
        final file = '${dir.path}/settings.json';
        await JsonSettingsStore(file).save(h.settings);
        return File(file).readAsStringSync();
      } finally {
        await dir.delete(recursive: true);
      }
    });
    for (final text in <String>[saved!, ...h.store.records.values]) {
      expect(text, isNot(contains(fakeToken)));
      expect(text, isNot(contains(fakeSid)));
      expect(text, isNot(contains(code)));
    }
    expect(saved, contains(Roles.storekeeperId));
    expect(find.textContaining(fakeToken), findsNothing);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(_switch(tester).value, isTrue);
    expect(_switch(tester).onChanged, isNotNull);
    // Статус — в строке расширения, а в карточке роли — карточка
    // подключения (ADR-031).
    expect(
      find.text('Подключён: ivanov · под своим логином'),
      findsOneWidget,
    );
    expect(find.text('Вошли: ivanov'), findsOneWidget);

    await _tap(tester, 'extension-configure-warehouse');
    await _tap(tester, 'connection-logout');
    expect(find.textContaining('будут удалены с устройства'), findsOneWidget);
    await _tap(tester, 'connection-logout-confirm');
    expect(await h.secrets.read('warehouse.token'), isNull);
    expect(await h.secrets.read('warehouse.sid'), isNull);
    // Выход роль не выключает: склад отвечает «ещё не подключён».
    expect(h.settings.enabledRoles, contains(Roles.storekeeperId));
    expect(h.registry.isEnabled('warehouse'), isTrue);
    expect(find.text('Не подключён'), findsOneWidget);
    // Описание 1.4.56 умеет выход на сервере.
    expect(
      h.transport.requests.last.uri.queryParameters['action'],
      'sess_end',
    );
  });

  testWidgets('вручную с неверным паролем: сообщение, поля очищены',
      (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.build());
    await _tap(tester, 'extension-configure-warehouse');
    await _enter(tester, 'connection-address', 'warehouse.example');
    await _enter(tester, 'connection-password', 'wrong-fake');
    await _tap(tester, 'connection-manual-connect');
    expect(find.text('Склад не принял пароль.'), findsOneWidget);
    expect(_fieldText(tester, 'connection-password'), isEmpty);
    expect(h.service.connected, isFalse);

    await _enter(tester, 'connection-password', fakeToken);
    await _tap(tester, 'connection-manual-connect');
    expect(find.text('Подключён по паролю склада'), findsOneWidget);
    expect(_fieldText(tester, 'connection-password'), isEmpty);
    expect(
      find.byKey(const ValueKey<String>('connection-staff-connect')),
      findsOneWidget,
    );
    expect(h.service.record.level, ConnectionLevel.shared);
  });

  testWidgets('битое описание — «Описание не принято»', (tester) async {
    final h = _Harness(manifestBody: '{"format":"assistant/2"}');
    await tester.pumpWidget(h.build());
    await _tap(tester, 'extension-configure-warehouse');
    await _enter(
      tester,
      'connection-link',
      'https://warehouse.example/#qr=$code',
    );
    await _tap(tester, 'connection-link-connect');
    expect(find.textContaining('Описание не принято'), findsOneWidget);
    expect(h.service.connected, isFalse);
    expect(h.settings.enabledExtensions, isEmpty);
  });

  for (final (name, size, scale) in <(String, Size, double)>[
    ('320x640 при масштабе 2', const Size(320, 640), 2.0),
    ('1600x900', const Size(1600, 900), 1.0),
  ]) {
    testWidgets('без переполнения: $name', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final h = _Harness();
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(scale),
          ),
          child: h.build(),
        ),
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('extension-warehouse')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _tap(tester, 'extension-configure-warehouse');
      await _enter(
        tester,
        'connection-link',
        'https://warehouse.example/#qr=$code',
      );
      await _tap(tester, 'connection-link-connect');
      await _tap(tester, 'connection-examples');
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('connection-logout')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(h.service.connected, isTrue);
    });
  }

  testWidgets('320x640 при масштабе 2: итог виден у кнопки, подписи целиком',
      (tester) async {
    const size = Size(320, 640);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final h = _Harness();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(2),
        ),
        child: h.build(),
      ),
    );
    await _tap(tester, 'extension-configure-warehouse');
    // Подписи над полями, без «Пароль скла…».
    for (final label in <String>[
      'Пароль склада',
      'Логин сотрудника',
      'Пароль сотрудника',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }

    bool onScreen(Finder finder) {
      final rect = tester.getRect(finder);
      return rect.top >= 0 && rect.bottom <= size.height;
    }

    await _enter(tester, 'connection-link', 'https://warehouse.example/#qr=12');
    await _tap(tester, 'connection-link-connect');
    final message = find.byKey(const ValueKey<String>('connection-message'));
    expect(find.textContaining('обрезан или испорчен'), findsOneWidget);
    expect(onScreen(message), isTrue);

    await _enter(tester, 'connection-address', 'warehouse.example');
    await _enter(tester, 'connection-password', 'wrong-fake');
    await _tap(tester, 'connection-manual-connect');
    expect(find.text('Склад не принял пароль.'), findsOneWidget);
    expect(onScreen(message), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('хранилище не пишет: сообщение, экран не завис', (tester) async {
    final h = _Harness(brokenStorage: true);
    await tester.pumpWidget(h.build());
    await _tap(tester, 'extension-configure-warehouse');
    await _enter(
      tester,
      'connection-link',
      'https://warehouse.example/#qr=$code',
    );
    await _tap(tester, 'connection-link-connect');
    expect(find.textContaining('Не получилось сохранить'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    final connect = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey<String>('connection-link-connect')),
    );
    expect(connect.onPressed, isNotNull);
    expect(h.service.connected, isFalse);
    expect(find.textContaining(fakeToken), findsNothing);
  });

  testWidgets('выход не удалил пароль: сообщение у кнопки, не завис',
      (tester) async {
    final h = _Harness(brokenStorage: true);
    await h.secrets.write('warehouse.token', fakeToken);
    h.service.connector.record = ConnectionRecord(
      appId: 'halowarekeep',
      baseUri: Uri.parse('https://warehouse.example/'),
      level: ConnectionLevel.shared,
    );
    await tester.pumpWidget(h.build());
    await _tap(tester, 'extension-configure-warehouse');
    await _tap(tester, 'connection-logout');
    await _tap(tester, 'connection-logout-confirm');
    expect(find.textContaining('Не получилось удалить пароль'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(h.service.connected, isTrue);
    final logout = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey<String>('connection-logout')),
    );
    expect(logout.onPressed, isNotNull);
  });
}
