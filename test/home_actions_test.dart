import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/manifest/connection.dart';
import 'package:local_assistant/core/connectors/manifest/connection_service.dart';
import 'package:local_assistant/core/connectors/manifest/manifest_connector.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/models/action_card.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import 'connectors/manifest/fixtures.dart';
import 'support/home_nav.dart';

final DateTime _now = DateTime(2026, 11, 10, 14, 30);
final int _epoch = _now.millisecondsSinceEpoch ~/ 1000;

/// Заведомо поддельные значения: настоящих секретов в тестах нет.
const String _fakeToken = 'fake-token-not-real';
const String _fakeSid = 'fake-sid-not-real';

HttpResponseData _json(int status, Map<String, Object?> body) =>
    HttpResponseData(statusCode: status, body: jsonEncode(body));

/// Транспорт теста: действия из [hang] не отвечают, пока не отпустят
/// [release] (запись «в пути»).
final class _Transport implements HttpTransport {
  _Transport(this.respond, this.hang);

  final HttpResponseData Function(HttpRequestData request) respond;
  final Set<String> hang;
  final List<HttpRequestData> requests = <HttpRequestData>[];
  final Completer<void> release = Completer<void>();

  @override
  Future<HttpResponseData> send(HttpRequestData request) async {
    requests.add(request);
    if (hang.contains(request.uri.queryParameters['action'])) {
      await release.future;
    }
    return respond(request);
  }
}

final class _Harness {
  _Harness({String login = 'ivanov', Set<String> hang = const <String>{}}) {
    final clock = FixedClock(_now);
    tasks = TaskService(repository: InMemoryTaskRepository(), clock: clock);
    transport = _Transport(_respond, hang);
    secrets = InMemorySecretStore(<String, String>{
      'warehouse.token': _fakeToken,
      'warehouse.sid': _fakeSid,
    });
    warehouse = warehouseConnector(
      path: actionsManifestPath,
      transport: transport,
      secrets: secrets,
      record: connectedRecord(login: login),
      builtIn: builtInManifest(),
    );
    service = ConnectionService(
      connector: warehouse,
      transport: transport,
      secrets: secrets,
      store: InMemoryConnectionStore(),
      clock: clock,
      builtIn: builtInManifest(),
    );
    assistant = AssistantController(
      extensions: ExtensionRegistry(
        connectors: <Connector>[
          TasksConnector(
            taskService: tasks,
            parser: ScenarioParser(clock: clock),
          ),
          warehouse,
          TalkConnector(taskService: tasks),
        ],
      ),
      clock: clock,
    );
  }

  late final TaskService tasks;
  late final _Transport transport;
  final InMemoryChatStore chats = InMemoryChatStore();
  late final InMemorySecretStore secrets;
  late final ManifestConnector warehouse;
  late final ConnectionService service;
  late final AssistantController assistant;
  final InMemorySettingsStore settings = InMemorySettingsStore();

  /// Действия склада; запросы описания (фоновая проверка) не в счёт.
  List<String> get actions => <String>[
        for (final r in transport.requests)
          if (r.uri.queryParameters['action'] case final String action) action,
      ];

  HttpResponseData _respond(HttpRequestData request) =>
      switch (request.uri.queryParameters['action']) {
        'act_move_check' => _json(200, <String, Object?>{
            'ok': true,
            'ready': true,
            'card': <String, Object?>{
              'sku': '64115',
              'name': 'Стул венский белый',
              'cls': 'UCENKA',
              'clsLabel': 'УЦЕНКА',
              'qty': 3,
              'from': <String, Object?>{
                'cell': '215-1-1-1',
                'now': 5,
                'after': 2,
              },
              'to': <String, Object?>{
                'cell': '215-3-2-1',
                'now': 0,
                'after': 3,
                'rows': 0,
              },
              'warn': <String>['to_empty'],
              'who': <String, Object?>{
                'login': 'ivanov',
                'name': 'Иван Петров',
              },
            },
            'commit': <String, Object?>{
              'from': '215-1-1-1',
              'to': '215-3-2-1',
              'sku': '64115',
              'cls': 'UCENKA',
              'qty': 3,
            },
            'exp': _epoch + 300,
            'stamp': 'a' * 64,
          }),
        'act_move' => _json(200, <String, Object?>{
            'ok': true,
            'done': true,
            'doc': 'ПЕР-00042',
            'from': <String, Object?>{'cell': '215-1-1-1', 'left': 2},
            'to': <String, Object?>{'cell': '215-3-2-1', 'have': 3},
          }),
        'sess_end' => _json(200, <String, Object?>{'ok': true}),
        _ => _json(400, <String, Object?>{'error': 'Неизвестное действие'}),
      };

  Future<void> pump(
    WidgetTester tester,
    AppSettings start, {
    Size size = const Size(1300, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await settings.save(start);
    await tester.pumpWidget(
      MaterialApp(
        theme: AssistantTheme.dark(),
        home: HomePage(
          assistant: assistant,
          tasks: tasks,
          clock: FixedClock(_now),
          settingsStore: settings,
          chatStore: chats,
          connections: <ConnectionService>[service],
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

Future<void> _say(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('assistant-input')), text);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

const AppSettings _allowed = AppSettings(
  enabledRoles: <String>{Roles.storekeeperId},
  roleActions: <String, String>{Roles.storekeeperId: 'ivanov'},
);

void main() {
  testWidgets('карточка в чате: «да» не пишет, «Подтвердить» — одна запись',
      (tester) async {
    final h = _Harness();
    await h.pump(tester, _allowed);
    await _say(tester, 'перемести 3 венских стула из 215-1-1-1 в 215-3-2-1');
    expect(find.byKey(const Key('action-confirm')), findsOneWidget);
    expect(find.text('215-1-1-1 — было 5, станет 2'), findsOneWidget);
    expect(h.actions, <String>['act_move_check']);

    await _say(tester, 'да');
    expect(find.textContaining('нажмите «Подтвердить»'), findsWidgets);
    // Карточка одна — под последним ответом.
    expect(find.byKey(const Key('action-confirm')), findsOneWidget);
    expect(h.actions, <String>['act_move_check']);

    await tester.tap(find.byKey(const Key('action-confirm')));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(h.actions, <String>['act_move_check', 'act_move']);
    expect(find.textContaining('ПЕР-00042'), findsWidgets);
    expect(find.byKey(const Key('action-confirm')), findsNothing);
    expect(find.text('Выполнено: ПЕР-00042'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '«Подтвердить»: карточка в истории до ответа — «Проверить» после перезапуска',
      (tester) async {
    final h = _Harness(hang: <String>{'act_move'});
    await h.pump(tester, _allowed);
    await _say(tester, 'перемести 3 венских стула из 215-1-1-1 в 215-3-2-1');
    await tester.tap(find.byKey(const Key('action-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(h.actions, <String>['act_move_check', 'act_move']);
    // Запись в пути, ответа нет: приложение закрыли — что в истории?
    // Карточка — в сессии, где дали команду.
    final sessionId = onlySessionId(h.chats.chatIds);
    final saved = await h.chats.loadMessages(sessionId);
    final card = saved.lastWhere((ChatMessage m) => m.card != null).card!;
    expect(card.state, ActionCardState.unknown);
    expect(card.canSettle, isTrue);
    // Отпустить запись: ответ приходит, история — с итогом.
    h.transport.release.complete();
    await tester.pumpAndSettle();
    final after = await h.chats.loadMessages(sessionId);
    expect(
      after.lastWhere((ChatMessage m) => m.card != null).card!.state,
      ActionCardState.applied,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'телефон: ждущая карточка склада — в «Мой Tridot» → «Сводка», '
      'нажатие ведёт в сессию с ней', (tester) async {
    final h = _Harness();
    await h.pump(tester, _allowed, size: const Size(390, 844));
    await _say(tester, 'перемести 3 венских стула из 215-1-1-1 в 215-3-2-1');
    expect(find.byKey(const Key('action-confirm')), findsOneWidget);
    expect(find.byKey(const Key('today-button')), findsNothing);
    await openSummary(tester);
    final pending = find.byWidgetPredicate(
      (Widget w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('next-pending-'),
    );
    expect(pending, findsOneWidget);
    expect(find.text('Перемещение ждёт подтверждения'), findsOneWidget);
    await tester.ensureVisible(pending);
    await tester.pumpAndSettle();
    await tester.tap(pending);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('action-confirm')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '«Документ»: ответ с карточкой — «Ответ в диалоге», карточка ждёт в '
      '«Диалоге»', (tester) async {
    final h = _Harness();
    await h.pump(tester, _allowed, size: const Size(390, 844));
    await tester.tap(find.byKey(const Key('mode-document')));
    await tester.pumpAndSettle();
    await _say(tester, 'перемести 3 венских стула из 215-1-1-1 в 215-3-2-1');
    final toast = find.byKey(const Key('doc-reply-toast'));
    expect(
      find.descendant(of: toast, matching: find.text('Ответ в диалоге')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('action-confirm')), findsNothing);
    await tester.tap(find.byKey(const Key('doc-reply-dialogue')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('action-confirm')), findsOneWidget);
    expect(h.actions, <String>['act_move_check']);
  });

  testWidgets(
      'телефон: карточка из «Документа» — «Сводка» ведёт в «Диалог» той же '
      'сессии, к «Подтвердить»', (tester) async {
    final h = _Harness();
    await h.pump(tester, _allowed, size: const Size(390, 844));
    await tester.tap(find.byKey(const Key('mode-document')));
    await tester.pumpAndSettle();
    await _say(tester, 'перемести 3 венских стула из 215-1-1-1 в 215-3-2-1');
    // Полоса ответа ушла сама.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('doc-reply-toast')), findsNothing);
    expect(find.byKey(const Key('action-confirm')), findsNothing);

    await openSummary(tester);
    final pending = find.byWidgetPredicate(
      (Widget w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('next-pending-'),
    );
    await tester.ensureVisible(pending);
    await tester.pumpAndSettle();
    await tester.tap(pending);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('action-confirm')), findsOneWidget);
    await tester.tap(find.byKey(const Key('action-confirm')));
    await tester.pumpAndSettle();
    expect(h.actions, <String>['act_move_check', 'act_move']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('вход сменился — «Разрешить действия» снимается', (tester) async {
    final h = _Harness();
    await h.pump(tester, _allowed);
    expect(h.warehouse.info.access, ConnectorAccess.readWrite);
    await h.service.logout();
    await tester.pumpAndSettle();
    final saved = await h.settings.load();
    expect(saved.roleActions, isEmpty);
    expect(h.warehouse.info.access, ConnectorAccess.readOnly);
  });

  testWidgets('после перезапуска разрешение для другого входа снято',
      (tester) async {
    final h = _Harness(login: 'petrov');
    await h.pump(tester, _allowed);
    final saved = await h.settings.load();
    expect(saved.roleActions, isEmpty);
    await _say(tester, 'проведи приход 318 в 1с');
    expect(
      outsideDrawer(find.textContaining('Действия выключены')),
      findsOneWidget,
    );
    expect(h.actions, isEmpty);
  });

  test('settings.json: role_actions читается строго', () {
    final settings = AppSettings.fromJson(<String, dynamic>{
      'enabled_roles': <String>['storekeeper'],
      'role_actions': <String, Object?>{
        'storekeeper': 'ivanov',
        'bad': 5,
        '': 'x',
        'ctl': 'a\nb',
      },
    });
    expect(settings.roleActions, <String, String>{'storekeeper': 'ivanov'});
    expect(
      AppSettings.fromJson(<String, dynamic>{'role_actions': 'x'}).roleActions,
      isEmpty,
    );
    expect(const AppSettings().toJson().containsKey('role_actions'), isFalse);
    expect(
      AppSettings.fromJson(settings.toJson()).roleActions,
      settings.roleActions,
    );
    expect(
      settings.extensionChoice.sameAs(
        settings.extensionChoice.withActions(Roles.storekeeperId, 'petrov'),
      ),
      isFalse,
    );
    expect(ActionKind.parse('move'), ActionKind.move);
  });
}
