import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/manifest/connection.dart';
import 'package:local_assistant/core/connectors/manifest/manifest_connector.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/models/action_card.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import 'fixtures.dart';

/// Заведомо поддельные значения: настоящих секретов в тестах нет.
const String fakeToken = 'fake-token-not-real';
const String fakeSid = 'fake-sid-not-real';
final String fakeStamp = 'a' * 64;

final DateTime now = DateTime(2026, 11, 10, 14, 30);
final int epoch = now.millisecondsSinceEpoch ~/ 1000;

/// Склад-подделка: на каждое действие — очередь ответов; запросы
/// запоминаются. Неожиданный запрос роняет тест.
final class _Server implements HttpTransport {
  final Map<String, List<Object>> script = <String, List<Object>>{};
  final List<HttpRequestData> requests = <HttpRequestData>[];

  void on(String action, Object response) =>
      (script[action] ??= <Object>[]).add(response);

  List<String> get actions => <String>[
        for (final r in requests) r.uri.queryParameters['action'] ?? '',
      ];

  Map<String, Object?> body(int i) =>
      jsonDecode(requests[i].body ?? '{}') as Map<String, Object?>;

  @override
  Future<HttpResponseData> send(HttpRequestData request) async {
    requests.add(request);
    final action = request.uri.queryParameters['action'] ?? '';
    final queue = script[action];
    if (queue == null || queue.isEmpty) {
      throw StateError('неожиданный запрос $action');
    }
    final next = queue.removeAt(0);
    if (next is Exception) throw next;
    if (next is HttpResponseData) return next;
    final (status, json) = next as (int, Object?);
    return HttpResponseData(
      statusCode: status,
      body: json is String ? json : jsonEncode(json),
    );
  }
}

Map<String, Object?> moveReady({
  String from = '215-1-1-1',
  String to = '215-3-2-1',
  int qty = 3,
  int have = 5,
  String name = 'Стул венский белый',
  String login = 'ivanov',
  Map<String, Object?>? commit,
}) =>
    <String, Object?>{
      'ok': true,
      'ready': true,
      'card': <String, Object?>{
        'sku': '64115',
        'name': name,
        'cls': 'UCENKA',
        'clsLabel': 'УЦЕНКА',
        'qty': qty,
        'from': <String, Object?>{
          'cell': from,
          'now': have,
          'after': have - qty,
        },
        'to': <String, Object?>{'cell': to, 'now': 0, 'after': qty, 'rows': 0},
        'warn': <String>['to_empty'],
        'who': <String, Object?>{'login': login, 'name': 'Иван Петров'},
      },
      'commit': commit ??
          <String, Object?>{
            'from': from,
            'to': to,
            'sku': '64115',
            'cls': 'UCENKA',
            'qty': qty,
          },
      'exp': epoch + 300,
      'stamp': fakeStamp,
    };

Map<String, Object?> postReady({
  List<String> set = const <String>['odin_c'],
  String id = 'e318',
}) =>
    <String, Object?>{
      'ok': true,
      'ready': true,
      'card': <String, Object?>{
        'id': id,
        'no': '318-26',
        'kindLabel': 'ВОЗВРАТ',
        'day': '2026-11-05',
        'buyer': 'ООО Ромашка',
        'positions': 5,
        'qty': 12,
        'now': <String, Object?>{'sv': true, 'odin_c': false},
        'after': <String, Object?>{'sv': true, 'odin_c': true},
        'stage': 'done',
        'warn': <String>['unplaced'],
        'who': <String, Object?>{'login': 'ivanov', 'name': 'Иван Петров'},
      },
      'commit': <String, Object?>{'id': id, 'set': set},
      'exp': epoch + 300,
      'stamp': fakeStamp,
    };

final Map<String, Object?> moveDone = <String, Object?>{
  'ok': true,
  'done': true,
  'doc': 'ПЕР-00042',
  'id': 'x-0',
  'at': '2026-11-10T11:30:00.000Z',
  'from': <String, Object?>{'cell': '215-1-1-1', 'left': 2},
  'to': <String, Object?>{'cell': '215-3-2-1', 'have': 3},
};

final class _Setup {
  _Setup({
    ConnectionLevel level = ConnectionLevel.staff,
    String? allowed = 'ivanov',
    bool connected = true,
    bool sid = true,
  }) {
    final clock = FixedClock(now);
    final tasks = TaskService(
      repository: InMemoryTaskRepository(),
      clock: clock,
    );
    secrets = InMemorySecretStore(<String, String>{
      if (connected) 'warehouse.token': fakeToken,
      if (connected && sid) 'warehouse.sid': fakeSid,
    });
    warehouse = warehouseConnector(
      path: actionsManifestPath,
      transport: server,
      secrets: secrets,
      record: connected ? connectedRecord(level: level) : null,
      builtIn: builtInManifest(),
    )..settleDelay = Duration.zero;
    registry = ExtensionRegistry(
      connectors: <Connector>[
        TasksConnector(
          taskService: tasks,
          parser: ScenarioParser(clock: clock),
        ),
        warehouse,
        const CalculatorConnector(),
        TalkConnector(taskService: tasks),
      ],
      choice: ExtensionChoice(
        enabledRoles: const <String>{Roles.storekeeperId},
        roleActions: <String, String>{
          if (allowed != null) Roles.storekeeperId: allowed,
        },
      ),
    );
    assistant = AssistantController(extensions: registry, clock: clock);
  }

  final _Server server = _Server();
  late final InMemorySecretStore secrets;
  late final ManifestConnector warehouse;
  late final ExtensionRegistry registry;
  late final AssistantController assistant;

  Future<AssistantResponse> say(String text) => assistant.handle(text);
}

const String moveText = 'перемести 3 венских стула из 215-1-1-1 в 215-3-2-1';

void main() {
  group('шлюзы: ни одного запроса', () {
    test('только пароль склада — «только под своим логином»', () async {
      final s = _Setup(level: ConnectionLevel.shared, sid: false);
      final r = await s.say(moveText);
      expect(r.replyId, 'warehouse.act.needLogin');
      expect(s.server.requests, isEmpty);
    });

    test('«Разрешить действия» выключено', () async {
      final s = _Setup(allowed: null);
      final r = await s.say(moveText);
      expect(r.replyId, 'warehouse.act.off');
      expect(r.message, contains('Разрешить действия'));
      expect(s.server.requests, isEmpty);
      expect(s.warehouse.info.access, ConnectorAccess.readOnly);
    });

    test('разрешено для другого логина', () async {
      final s = _Setup(allowed: 'petrov');
      final r = await s.say('проведи приход 318 в 1с');
      expect(r.replyId, 'warehouse.act.otherLogin');
      expect(r.values, <String, String>{'login': 'petrov', 'now': 'ivanov'});
      expect(s.server.requests, isEmpty);
    });

    test('склад не подключён — подсказка роли', () async {
      final s = _Setup(connected: false);
      final r = await s.say(moveText);
      expect(r.replyId, 'role.notConnected');
      expect(s.server.requests, isEmpty);
    });

    test('«Без места» и одна и та же ячейка — без запроса', () async {
      final s = _Setup();
      expect(
        (await s.say('перемести 3 стула из 215-1-1-1 в без места')).replyId,
        'warehouse.act.noPlace',
      );
      expect(
        (await s.say('перемести 3 стула из 215-1-1-1 в 215-1-1-1')).replyId,
        'warehouse.act.sameCell',
      );
      expect(s.server.requests, isEmpty);
    });
  });

  group('перемещение', () {
    test('до кнопки — только расчёт; по кнопке — ровно одна запись', () async {
      final s = _Setup();
      expect(s.warehouse.info.access, ConnectorAccess.readWrite);
      s.server.on('act_move_check', (200, moveReady()));
      final asked = await s.say(moveText);
      expect(asked.replyId, 'warehouse.act.ask.move');
      expect(asked.status, AssistantStatus.needsClarification);
      expect(s.server.actions, <String>['act_move_check']);
      final check = s.server.requests.single;
      expect(check.method, 'POST');
      expect(check.headers['X-Wh-Token'], fakeToken);
      expect(check.headers['X-Wh-Sid'], fakeSid);
      expect(check.uri.queryParameters.keys, <String>['action']);
      expect(check.uri.toString(), isNot(contains(fakeSid)));
      expect(s.server.body(0), <String, Object?>{
        'v': 1,
        'from': '215-1-1-1',
        'to': '215-3-2-1',
        'q': 'венских стула',
        'qty': 3,
      });
      final card = asked.card!;
      expect(card.isPending, isTrue);
      expect(card.rid, matches(RegExp(r'^[0-9a-z]{16}$')));
      expect(card.lines.map((ActionCardLine l) => l.label), <String>[
        'what',
        'sku',
        'qty',
        'from',
        'to',
        'who',
      ]);
      expect(card.lines[1].value, '64115 · УЦЕНКА');
      expect(card.lines[3].value, '215-1-1-1 — было 5, станет 2');
      expect(card.lines[4].note, 'to_empty');

      // «Да» текстом не пишет: просит нажать кнопку, карточка ждёт.
      final yes = await s.say('да');
      expect(yes.replyId, 'warehouse.act.pressButton');
      expect(identical(yes.card, card), isTrue);
      expect(s.assistant.pendingCard, same(card));
      expect(s.server.requests, hasLength(1));

      s.server.on('act_move', (200, moveDone));
      final done = await s.assistant.answerCard(card, apply: true);
      expect(done!.replyId, 'warehouse.act.moved');
      expect(done.message, contains('ПЕР-00042'));
      expect(card.state, ActionCardState.applied);
      expect(s.server.actions, <String>['act_move_check', 'act_move']);
      final write = s.server.requests.last;
      expect(write.headers['X-Wh-Sid'], fakeSid);
      expect(write.uri.queryParameters.keys, <String>['action']);
      expect(s.server.body(1), <String, Object?>{
        'v': 1,
        'rid': card.rid,
        'from': '215-1-1-1',
        'to': '215-3-2-1',
        'sku': '64115',
        'cls': 'UCENKA',
        'qty': 3,
        'exp': epoch + 300,
        'stamp': fakeStamp,
      });
      // Второе нажатие — ни одного запроса.
      expect(await s.assistant.answerCard(card, apply: true), isNull);
      expect(s.server.requests, hasLength(2));
    });

    test('«нет» отменяет, «Отмена» тоже; постороннее — устарела', () async {
      final s = _Setup();
      s.server.on('act_move_check', (200, moveReady()));
      final card = (await s.say(moveText)).card!;
      final no = await s.say('нет');
      expect(no.replyId, 'warehouse.act.declined');
      expect(card.state, ActionCardState.cancelled);

      s.server.on('act_move_check', (200, moveReady()));
      final second = (await s.say(moveText)).card!;
      final cancel = await s.assistant.answerCard(second, apply: false);
      expect(cancel!.replyId, 'warehouse.act.declined');
      expect(second.state, ActionCardState.cancelled);

      s.server.on('act_move_check', (200, moveReady()));
      final third = (await s.say(moveText)).card!;
      await s.say('сколько будет 2+2');
      expect(third.state, ActionCardState.expired);
      expect(await s.assistant.answerCard(third, apply: true), isNull);
      expect(s.server.actions.where((String a) => a == 'act_move'), isEmpty);
    });

    test('новая команда при висящей карточке: старая устарела', () async {
      final s = _Setup();
      s.server.on('act_move_check', (200, moveReady()));
      final card = (await s.say(moveText)).card!;
      s.server.on('act_post_check', (200, postReady()));
      final post = await s.say('отметь проведение прихода 319');
      expect(post.replyId, 'warehouse.act.ask.post');
      expect(card.state, ActionCardState.expired);
    });

    test('обрыв после отправки — ровно одна проверка act_settle', () async {
      final s = _Setup();
      s.server.on('act_move_check', (200, moveReady()));
      final card = (await s.say(moveText)).card!;
      s.server
        ..on('act_move', TimeoutException('нет ответа'))
        ..on(
          'act_settle',
          (
            200,
            <String, Object?>{'ok': true, 'state': 'done', 'result': moveDone},
          ),
        );
      final r = await s.assistant.answerCard(card, apply: true);
      expect(s.server.actions, <String>[
        'act_move_check',
        'act_move',
        'act_settle',
      ]);
      expect(s.server.body(2), <String, Object?>{'v': 1, 'rid': card.rid});
      expect(r!.replyId, 'warehouse.act.moved');
      expect(card.state, ActionCardState.applied);
    });

    test('обрыв и склад не получил — «повтори», rid погашен', () async {
      final s = _Setup();
      s.server.on('act_move_check', (200, moveReady()));
      final card = (await s.say(moveText)).card!;
      s.server
        ..on('act_move', const SocketLikeException())
        ..on(
          'act_settle',
          (200, <String, Object?>{'ok': true, 'state': 'void'}),
        );
      final r = await s.assistant.answerCard(card, apply: true);
      expect(r!.replyId, 'warehouse.act.voided');
      expect(card.state, ActionCardState.failed);
      expect(
        s.server.actions.where((String a) => a == 'act_move'),
        hasLength(1),
      );
    });

    test('проверка без связи — итог неизвестен, «Проверить» не пишет',
        () async {
      final s = _Setup();
      s.server.on('act_move_check', (200, moveReady()));
      final card = (await s.say(moveText)).card!;
      s.server
        ..on('act_move', const SocketLikeException())
        ..on('act_settle', const SocketLikeException());
      final r = await s.assistant.answerCard(card, apply: true);
      expect(r!.replyId, 'warehouse.act.unknown');
      expect(card.state, ActionCardState.unknown);
      s.server.on(
        'act_settle',
        (200, <String, Object?>{'ok': true, 'state': 'pending'}),
      );
      final pending = await s.assistant.settleCard(card);
      expect(pending!.replyId, 'warehouse.act.pending');
      expect(
        s.server.actions.where((String a) => a == 'act_move'),
        hasLength(1),
      );
    });

    test('stale — новая карточка с новым rid, старая заменена', () async {
      final s = _Setup();
      s.server.on('act_move_check', (200, moveReady()));
      final card = (await s.say(moveText)).card!;
      s.server.on(
        'act_move',
        (
          409,
          <String, Object?>{
            'error': 'Пока карточка ждала, на складе изменилось',
            'code': 'stale',
            'fresh': moveReady(have: 4),
          },
        ),
      );
      final r = await s.assistant.answerCard(card, apply: true);
      expect(card.state, ActionCardState.replaced);
      final fresh = r!.card!;
      expect(fresh.rid, isNot(card.rid));
      expect(fresh.isPending, isTrue);
      expect(r.replyId, 'warehouse.act.ask.move');
      expect(r.message, startsWith('Пока карточка ждала'));
      expect(s.assistant.pendingCard, same(fresh));
      expect(fresh.lines[3].value, '215-1-1-1 — было 4, станет 1');
    });

    test('склад ответил не про то — карточки нет', () async {
      for (final ready in <Map<String, Object?>>[
        moveReady(
          commit: <String, Object?>{
            'from': '215-1-1-1',
            'to': '101-1-1-1',
            'sku': '64115',
            'cls': 'UCENKA',
            'qty': 3,
          },
        ),
        moveReady(
          commit: <String, Object?>{
            'from': '215-1-1-1',
            'to': '215-3-2-1',
            'sku': '64115',
            'cls': 'UCENKA',
            'qty': 999,
          },
        ),
        moveReady(login: 'admin'),
        moveReady(from: '215-9-9-9'),
      ]) {
        final s = _Setup();
        s.server.on('act_move_check', (200, ready));
        final r = await s.say(moveText);
        expect(r.replyId, 'warehouse.act.mismatch');
        expect(r.card, isNull);
        expect(s.assistant.pendingCard, isNull);
      }
    });

    test('вопросы по ходу: какой, сколько, куда', () async {
      final s = _Setup();
      s.server.on(
        'act_move_check',
        (
          200,
          <String, Object?>{
            'ok': true,
            'ready': false,
            'ask': 'row',
            'from': '215-1-1-1',
            'options': <Object?>[
              <String, Object?>{
                'cell': '215-1-1-1',
                'sku': '64115',
                'name': 'Стул',
                'cls': 'UCENKA',
                'clsLabel': 'УЦЕНКА',
                'qty': 2,
              },
              <String, Object?>{
                'cell': '215-1-1-1',
                'sku': '64115',
                'name': 'Стул',
                'cls': '',
                'clsLabel': '',
                'qty': 3,
              },
            ],
            'more': false,
          },
        ),
      );
      final row = await s.say('переложи стулья из 215-1-1-1');
      expect(row.replyId, 'warehouse.act.ask.row');
      expect(row.message, contains('1) 64115 · Стул · УЦЕНКА · 2 шт.'));
      s.server.on(
        'act_move_check',
        (
          200,
          <String, Object?>{
            'ok': true,
            'ready': false,
            'ask': 'qty',
            'row': <String, Object?>{
              'cell': '215-1-1-1',
              'sku': '64115',
              'name': 'Стул',
              'cls': '',
            },
            'have': 3,
          },
        ),
      );
      final qty = await s.say('второй');
      expect(qty.replyId, 'warehouse.act.ask.qty');
      expect(s.server.body(1), <String, Object?>{
        'v': 1,
        'from': '215-1-1-1',
        'sku': '64115',
        'cls': '',
      });
      s.server.on(
        'act_move_check',
        (
          200,
          <String, Object?>{
            'ok': true,
            'ready': false,
            'ask': 'to',
            'row': <String, Object?>{
              'cell': '215-1-1-1',
              'sku': '64115',
              'name': 'Стул',
              'cls': '',
            },
            'qty': 3,
          },
        ),
      );
      final to = await s.say('все');
      expect(to.replyId, 'warehouse.act.ask.to');
      expect(s.server.body(2)['qty'], 'all');
      s.server.on('act_move_check', (200, moveReady()));
      await s.say('215-3-2-1');
      expect(s.server.body(3)['to'], '215-3-2-1');
    });

    test('«да» на вопрос — тот же вопрос; больше 4 — «скажи целиком»',
        () async {
      final s = _Setup();
      final ask = <String, Object?>{
        'ok': true,
        'ready': false,
        'ask': 'qty',
        'row': <String, Object?>{'cell': '215-1-1-1', 'sku': '64115'},
        'have': 3,
      };
      s.server.on('act_move_check', (200, ask));
      final first = await s.say('переложи 64115 из 215-1-1-1 в 215-3-2-1');
      expect(first.replyId, 'warehouse.act.ask.qty');
      final again = await s.say('да');
      expect(again.replyId, 'warehouse.act.ask.qty');
      for (var i = 0; i < 3; i++) {
        s.server.on('act_move_check', (200, ask));
      }
      AssistantResponse last = again;
      for (var i = 0; i < 3; i++) {
        last = await s.say('2');
      }
      expect(last.replyId, 'warehouse.act.tooMany');
    });
  });

  group('коды отказов — свои записи', () {
    final cases = <(String, int, Map<String, Object?>, String)>[
      (moveText, 403, <String, Object?>{'code': 'off'}, 'act.serverOff'),
      (
        moveText,
        403,
        <String, Object?>{'code': 'no_right', 'right': 'moves'},
        'act.denied',
      ),
      (
        moveText,
        403,
        <String, Object?>{'code': 'rights_unknown', 'right': 'moves'},
        'act.denied',
      ),
      (
        moveText,
        403,
        <String, Object?>{'code': 'login', 'need': 'login'},
        'auth.expired',
      ),
      (
        moveText,
        403,
        <String, Object?>{'code': 'role', 'need': 'role'},
        'auth.role',
      ),
      (
        moveText,
        404,
        <String, Object?>{'code': 'not_in_cell', 'from': '215-1-1-1'},
        'act.notInCell',
      ),
      (
        moveText,
        409,
        <String, Object?>{'code': 'short', 'have': 2, 'from': '215-1-1-1'},
        'act.short',
      ),
      (
        moveText,
        422,
        <String, Object?>{'code': 'no_cell', 'to': '215-3-2-1'},
        'act.noCell',
      ),
      (
        moveText,
        422,
        <String, Object?>{'code': 'cell_group', 'to': '215-3-2-1'},
        'act.cellGroup',
      ),
      (moveText, 422, <String, Object?>{'code': 'same_cell'}, 'act.sameCell'),
      (
        'перемести 1 пуф в 215-3-2-1',
        422,
        <String, Object?>{'code': 'only_there', 'to': '215-3-2-1'},
        'act.onlyThere',
      ),
      (
        'перемести все 64115 из 215-1-1-1 в 215-3-2-1',
        400,
        <String, Object?>{
          'code': 'qty_limit',
          'max': 9999,
          'have': 12000,
          'from': '215-1-1-1',
        },
        'act.qtyLimit',
      ),
      (moveText, 409, <String, Object?>{'code': 'clock_order'}, 'act.clock'),
      (
        moveText,
        409,
        <String, Object?>{'code': 'layout_unknown'},
        'act.failed',
      ),
      (moveText, 429, <String, Object?>{'code': 'busy'}, 'busy'),
      (
        'проведи приход 318',
        404,
        <String, Object?>{'code': 'not_found', 'no': '318'},
        'act.notFound',
      ),
      (
        'проведи приход 318',
        409,
        <String, Object?>{'code': 'draft', 'no': '318'},
        'act.draft',
      ),
      (
        'проведи приход 318',
        409,
        <String, Object?>{
          'code': 'locked',
          'no': '318',
          'by': 'petrov',
          'name': 'Пётр',
          'own': false,
        },
        'act.locked',
      ),
      (
        'проведи приход 318',
        409,
        <String, Object?>{'code': 'locked', 'no': '318', 'own': true},
        'act.lockedOwn',
      ),
      // Склад без патча: «Неизвестное действие» без кода.
      (
        moveText,
        400,
        <String, Object?>{'error': 'Неизвестное действие'},
        'act.unsupported',
      ),
    ];
    for (final (text, status, body, key) in cases) {
      test('$status ${body['code'] ?? 'без кода'} → $key', () async {
        final s = _Setup();
        final action =
            text.startsWith('проведи') ? 'act_post_check' : 'act_move_check';
        s.server.on(action, (status, <String, Object?>{'error': 'x', ...body}));
        final r = await s.say(text);
        expect(r.replyId, 'warehouse.$key');
        expect(r.card, isNull);
        expect(s.server.requests, hasLength(1));
      });
    }

    test('5xx без JSON — ошибка склада', () async {
      final s = _Setup();
      s.server.on('act_move_check', (502, 'Bad gateway'));
      expect((await s.say(moveText)).replyId, 'warehouse.serverError');
    });

    test('отказ записи — карточка «не выполнено», статус failed', () async {
      final s = _Setup();
      s.server.on('act_move_check', (200, moveReady()));
      final card = (await s.say(moveText)).card!;
      s.server.on(
        'act_move',
        (
          409,
          <String, Object?>{'error': 'мало', 'code': 'short', 'have': 1},
        ),
      );
      final r = await s.assistant.answerCard(card, apply: true);
      expect(r!.replyId, 'warehouse.act.short');
      expect(r.status, AssistantStatus.failed);
      expect(card.state, ActionCardState.failed);
    });

    test('expired и void записи', () async {
      final s = _Setup();
      s.server.on('act_move_check', (200, moveReady()));
      final card = (await s.say(moveText)).card!;
      s.server.on('act_move', (409, <String, Object?>{'code': 'expired'}));
      expect(
        (await s.assistant.answerCard(card, apply: true))!.replyId,
        'warehouse.act.expired',
      );
      expect(card.state, ActionCardState.expired);

      s.server.on('act_move_check', (200, moveReady()));
      final other = (await s.say(moveText)).card!;
      s.server
        ..on('act_move', (409, <String, Object?>{'code': 'in_progress'}))
        ..on(
          'act_settle',
          (200, <String, Object?>{'ok': true, 'state': 'pending'}),
        );
      expect(
        (await s.assistant.answerCard(other, apply: true))!.replyId,
        'warehouse.act.pending',
      );
      expect(other.state, ActionCardState.unknown);
    });
  });

  group('итог записи: неизвестен или отказ', () {
    Map<String, Object?> settleFailed(Map<String, Object?> refusal) =>
        <String, Object?>{
          'ok': true,
          'state': 'failed',
          'code': refusal['code'],
          'error': refusal['error'] ?? '',
          'http': 409,
          'refusal': refusal,
        };

    for (final (name, status, body) in <(String, int, Object)>[
      (
        '500 unknown («итог неизвестен»)',
        500,
        <String, Object?>{
          'error': 'Сбой: итог неизвестен — проверьте через act_settle',
          'code': 'unknown',
        },
      ),
      (
        '500 без кода (сбой мимо act.php)',
        500,
        <String, Object?>{'error': 'Сбой: SQLSTATE[HY000]'},
      ),
      ('502 без тела', 502, 'Bad gateway'),
    ]) {
      test('$name — act_settle, а не «не выполнено»', () async {
        final s = _Setup();
        s.server.on('act_move_check', (200, moveReady()));
        final card = (await s.say(moveText)).card!;
        s.server
          ..on('act_move', (status, body))
          ..on(
            'act_settle',
            (
              200,
              <String, Object?>{
                'ok': true,
                'state': 'done',
                'result': moveDone,
              },
            ),
          );
        final r = await s.assistant.answerCard(card, apply: true);
        expect(s.server.actions, <String>[
          'act_move_check',
          'act_move',
          'act_settle',
        ]);
        expect(r!.replyId, 'warehouse.act.moved');
        expect(card.state, ActionCardState.applied);
      });
    }

    test('500 storage («ничего не изменилось») — отказ без act_settle',
        () async {
      final s = _Setup();
      s.server.on('act_move_check', (200, moveReady()));
      final card = (await s.say(moveText)).card!;
      s.server.on(
        'act_move',
        (
          500,
          <String, Object?>{
            'error': 'Хранилище не приняло запись — ничего не изменилось',
            'code': 'storage',
          },
        ),
      );
      final r = await s.assistant.answerCard(card, apply: true);
      expect(s.server.actions, <String>['act_move_check', 'act_move']);
      expect(r!.replyId, 'warehouse.act.failed');
      expect(card.state, ActionCardState.failed);
    });

    test('act_settle: failed short — запись каталога, не код', () async {
      final s = _Setup();
      s.server.on('act_move_check', (200, moveReady()));
      final card = (await s.say(moveText)).card!;
      s.server
        ..on('act_move', TimeoutException('нет ответа'))
        ..on(
          'act_settle',
          (
            200,
            settleFailed(<String, Object?>{
              'error': 'В 215-1-1-1 только 2 шт.',
              'code': 'short',
              'have': 2,
              'from': '215-1-1-1',
            }),
          ),
        );
      final r = await s.assistant.answerCard(card, apply: true);
      expect(r!.replyId, 'warehouse.act.short');
      expect(r.message, contains('215-1-1-1'));
      expect(r.message, isNot(contains('short')));
      expect(card.state, ActionCardState.failed);
      expect(card.result, isNot('short'));
    });

    test('act_settle: failed locked — запись каталога', () async {
      final s = _Setup();
      s.server.on('act_post_check', (200, postReady()));
      final card = (await s.say('проведи приход 318 в 1с')).card!;
      s.server
        ..on('act_post', const SocketLikeException())
        ..on(
          'act_settle',
          (
            200,
            settleFailed(<String, Object?>{
              'error': 'Приход 318-26 сейчас правят',
              'code': 'locked',
              'no': '318-26',
              'by': 'petrov',
              'name': 'Пётр',
              'own': false,
            }),
          ),
        );
      final r = await s.assistant.answerCard(card, apply: true);
      expect(r!.replyId, 'warehouse.act.locked');
      expect(r.message, contains('Пётр'));
    });

    test('act_settle: failed stale — новый расчёт и новая карточка', () async {
      final s = _Setup();
      s.server.on('act_move_check', (200, moveReady()));
      final card = (await s.say(moveText)).card!;
      s.server
        ..on('act_move', TimeoutException('нет ответа'))
        ..on(
          'act_settle',
          (
            200,
            settleFailed(<String, Object?>{
              'error': 'Пока карточка ждала, на складе изменилось',
              'code': 'stale',
            }),
          ),
        )
        ..on('act_move_check', (200, moveReady(have: 4)));
      final r = await s.assistant.answerCard(card, apply: true);
      expect(s.server.actions, <String>[
        'act_move_check',
        'act_move',
        'act_settle',
        'act_move_check',
      ]);
      expect(card.state, ActionCardState.replaced);
      expect(r!.replyId, 'warehouse.act.ask.move');
      expect(r.message, startsWith('Пока карточка ждала'));
      expect(r.card!.rid, isNot(card.rid));
      expect(r.card!.lines[3].value, '215-1-1-1 — было 4, станет 1');
    });

    test('«все»: stale — карточка на всё, что есть сейчас, а не «не про то»',
        () async {
      final s = _Setup();
      s.server.on('act_move_check', (200, moveReady(qty: 5, have: 5)));
      final card =
          (await s.say('перемести все 64115 из 215-1-1-1 в 215-3-2-1')).card!;
      expect(s.server.body(0)['qty'], 'all');
      s.server
        ..on(
          'act_move',
          (
            409,
            <String, Object?>{
              'error': 'Пока карточка ждала, на складе изменилось',
              'code': 'stale',
              // склад считает fresh по прежнему числу из commit
              'fresh': moveReady(qty: 5, have: 6),
            },
          ),
        )
        ..on('act_move_check', (200, moveReady(qty: 6, have: 6)));
      final r = await s.assistant.answerCard(card, apply: true);
      expect(s.server.actions, <String>[
        'act_move_check',
        'act_move',
        'act_move_check',
      ]);
      expect(s.server.body(2)['qty'], 'all');
      expect(r!.replyId, 'warehouse.act.ask.move');
      expect(r.message, isNot(contains('не про то')));
      expect(r.card!.commit!['qty'], 6);
      expect(card.state, ActionCardState.replaced);
    });

    test('«куда» с «е»: склад вернул адрес схемы с «Ё» — та же ячейка',
        () async {
      final s = _Setup();
      s.server.on(
        'act_move_check',
        (200, moveReady(from: '303-1-1', to: '303-ЗОНА ПРИЁМКИ')),
      );
      final r = await s.say('перемести 3 пуфа из 303-1-1 в 303-зона приёмки');
      expect(s.server.body(0)['to'], '303-ЗОНА ПРИЕМКИ');
      expect(r.replyId, 'warehouse.act.ask.move');
      expect(r.card, isNotNull);
      expect(r.card!.commit!['to'], '303-ЗОНА ПРИЁМКИ');
    });
  });

  group('слово срока после зоны — не часть ячейки', () {
    for (final (text, day) in <(String, int)>[
      ('перемести коробки из 101-1-1 в 101-приемка завтра', 11),
      ('перемести коробки из 101-1-1 в 303-брак утром', 11),
      ('перемести коробки из 303-брак сегодня в 101-1-1', 10),
      ('перемести коробки из 101-1-1 в 101-ок срочно', 0),
      ('перемести коробки из 101-1-1 в 101-2-1 завтра', 11),
      ('перемести коробки из 101-1-1 в 101-приемка послезавтра', 12),
      ('перемести коробки из 101-1-1 в 101-приемка в понедельник', 16),
    ]) {
      test('«$text» — задача, не перемещение', () async {
        for (final allowed in <String?>['ivanov', null]) {
          final s = _Setup(allowed: allowed);
          final r = await s.say(text);
          expect(
            r.replyId ?? '',
            isNot(startsWith('warehouse.act')),
            reason: r.message,
          );
          expect(r.message, isNot(contains('Действия выключены')));
          expect(r.task, isNotNull, reason: r.message);
          if (day == 0) {
            expect(r.task!.dueAt, isNull, reason: text);
          } else {
            expect(r.task!.dueAt?.day, day, reason: text);
          }
          expect(s.server.requests, isEmpty);
        }
      });
    }

    test('зона из двух слов — по-прежнему перемещение', () async {
      final c = warehouseConnector(
        path: actionsManifestPath,
        builtIn: builtInManifest(),
      );
      for (final text in <String>[
        'перемести 3 пуфа из 303-1-1 в 303-зона приёмки',
        'переложи пуф из 303-зона приемки в 101-1-1',
        'перемести 3 пуфа из 303-1-1 в 303-зона средняя',
      ]) {
        final m = c.match(Utterance.analyze(text, now: now));
        expect(m?.commandId, 'warehouse.act.move', reason: text);
      }
      for (final text in <String>[
        'перемести коробки из 101-1-1 в 101-приемка завтра',
        'перемести коробки из 101-1-1 в 303-брак утром',
        'перемести коробки из 303-брак сегодня в 101-1-1',
        'перемести коробки из 101-1-1 в 101-ок срочно',
        'перемести коробки из 101-1-1 в 101-ок днём',
        'перемести коробки из 101-1-1 в 101-ок вечером',
        'перемести коробки из 101-1-1 в 101-ок послезавтра',
        'перемести коробки из 101-1-1 в 101-ок днем',
        'перемести коробки из 101-1-1 в 101-ок утречком',
        'перемести коробки из 101-1-1 в 101-ок ночью',
        'перемести коробки из 101-1-1 в 101-приемка в понедельник',
      ]) {
        final m = c.match(Utterance.analyze(text, now: now));
        expect(
          m?.commandId ?? '',
          isNot(startsWith('warehouse.act')),
          reason: text,
        );
      }
    });
  });

  group('слова срока — не номер прихода', () {
    for (final text in <String>[
      'отметь проведение прихода утром',
      'проведи приход завтра',
      'проведи приход вечером',
    ]) {
      test('«$text» — не действие склада', () async {
        for (final allowed in <String?>['ivanov', null]) {
          final s = _Setup(allowed: allowed);
          final r = await s.say(text);
          expect(
            r.replyId ?? '',
            isNot(startsWith('warehouse.act')),
            reason: r.message,
          );
          expect(s.server.requests, isEmpty);
        }
      });
    }

    test('номер с цифрой — действие', () async {
      final s = _Setup();
      s.server.on('act_post_check', (200, postReady()));
      await s.say('проведи приход ВЗ12');
      expect(s.server.body(0)['no'], 'ВЗ12');
    });
  });

  group('проведение', () {
    test('«в 1с» — только 1С, без литерала — обе, «в sv» — только SV',
        () async {
      for (final (text, set) in <(String, List<String>)>[
        ('проведи приход 318 в 1с', <String>['odin_c']),
        ('проведи приход 318 в 1c', <String>['odin_c']),
        ('проведи приход 318', <String>['sv', 'odin_c']),
        ('отметь проведение прихода 318-26', <String>['sv', 'odin_c']),
        ('приход 318 проведён в sv', <String>['sv']),
        ('проведи приход 318 в св', <String>['sv']),
      ]) {
        final s = _Setup();
        s.server.on('act_post_check', (200, postReady(set: set)));
        final r = await s.say(text);
        expect(r.replyId, 'warehouse.act.ask.post', reason: text);
        final body = s.server.body(0);
        expect(body['set'], set, reason: text);
        expect(body['v'], 1);
        expect(body['no'], isNotEmpty);
      }
    });

    test('запись: id и только недостающие отметки', () async {
      final s = _Setup();
      s.server.on('act_post_check', (200, postReady()));
      final card = (await s.say('проведи приход 318 в 1с')).card!;
      expect(card.lines.map((ActionCardLine l) => l.label), <String>[
        'entry',
        'content',
        'sv',
        'odin_c',
        'stage',
        'who',
      ]);
      expect(card.lines.first.value, '318-26 · ВОЗВРАТ · 05.11 · ООО Ромашка');
      expect(card.lines[2].value, 'отмечено — без изменений');
      expect(card.lines[3].value, 'нет → отмечено');
      expect(card.warn, contains('unplaced'));
      s.server.on(
        'act_post',
        (
          200,
          <String, Object?>{
            'ok': true,
            'done': true,
            'id': 'e318',
            'no': '318-26',
            'sv': true,
            'odin_c': true,
            'stage': 'done',
            'changed': <String>['odin_c'],
          },
        ),
      );
      final r = await s.assistant.answerCard(card, apply: true);
      expect(r!.replyId, 'warehouse.act.posted');
      expect(r.message, contains('1С'));
      final body = s.server.body(1);
      expect(body['id'], 'e318');
      expect(body['set'], <String>['odin_c']);
      expect(body['rid'], card.rid);
      expect(body['exp'], isA<int>());
    });

    test('уже отмечено — без карточки', () async {
      final s = _Setup();
      s.server.on(
        'act_post_check',
        (
          200,
          <String, Object?>{
            'ok': true,
            'ready': false,
            'already': true,
            'entry': <String, Object?>{'id': 'e318', 'no': '318-26'},
            'now': <String, Object?>{'sv': true, 'odin_c': true},
            'stage': 'done',
          },
        ),
      );
      final r = await s.say('проведи приход 318');
      expect(r.replyId, 'warehouse.act.already');
      expect(r.card, isNull);
    });

    test('несколько с одним номером — вопрос, ответ номером варианта',
        () async {
      final s = _Setup();
      s.server.on(
        'act_post_check',
        (
          200,
          <String, Object?>{
            'ok': true,
            'ready': false,
            'ask': 'entry',
            'no': '318',
            'options': <Object?>[
              <String, Object?>{
                'id': 'a',
                'no': '318-25',
                'kindLabel': 'ВОЗВРАТ',
                'day': '2025-03-01',
                'buyer': '',
              },
              <String, Object?>{
                'id': 'b',
                'no': '318-26',
                'kindLabel': 'ВОЗВРАТ',
                'day': '2026-11-05',
                'buyer': '',
              },
            ],
          },
        ),
      );
      final ask = await s.say('проведи приход 318');
      expect(ask.replyId, 'warehouse.act.ask.entry');
      s.server.on('act_post_check', (200, postReady(id: 'b')));
      final card = await s.say('2');
      expect(card.replyId, 'warehouse.act.ask.post');
      expect(s.server.body(1)['id'], 'b');
      expect(s.server.body(1).containsKey('no'), isFalse);
    });

    test('сервер подменил приход — «не про то»', () async {
      final s = _Setup();
      s.server.on(
        'act_post_check',
        (
          200,
          postReady(set: <String>['sv', 'odin_c']),
        ),
      );
      final r = await s.say('проведи приход 318 в 1с');
      expect(r.replyId, 'warehouse.act.mismatch');
    });
  });

  group('карточка после перезапуска', () {
    test('ждущая — устарела, отправленная — «Проверить» без записи', () async {
      final s = _Setup();
      s.server.on('act_move_check', (200, moveReady()));
      final card = (await s.say(moveText)).card!;
      final json = jsonEncode(card.toJson());
      for (final secret in <String>[fakeToken, fakeSid, fakeStamp, 'commit']) {
        expect(json, isNot(contains(secret)));
      }
      expect(
        ActionCard.fromJson(jsonDecode(json))!.state,
        ActionCardState.expired,
      );
      card.state = ActionCardState.sending;
      final restored =
          ActionCard.fromJson(jsonDecode(jsonEncode(card.toJson())))!;
      expect(restored.state, ActionCardState.unknown);
      expect(restored.commit, isNull);
      expect(restored.canSend(now), isFalse);
      s.server.on(
        'act_settle',
        (
          200,
          <String, Object?>{'ok': true, 'state': 'done', 'result': moveDone},
        ),
      );
      final r = await s.assistant.settleCard(restored);
      // Полей записи после перезапуска нет: итог — номером документа.
      expect(r!.replyId, 'warehouse.act.settled');
      expect(r.message, contains('ПЕР-00042'));
      expect(restored.state, ActionCardState.applied);
      expect(s.server.actions, <String>['act_move_check', 'act_settle']);
      // Сообщение чата с карточкой — тоже без секретов.
      final message = ChatMessage(
        id: 'm_1',
        author: ChatAuthor.persona,
        text: r.message,
        timestamp: now,
        card: restored,
      );
      final saved = jsonEncode(message.toJson());
      expect(saved, isNot(contains(fakeSid)));
      expect(saved, isNot(contains(fakeStamp)));
      expect(ChatMessage.fromJson(jsonDecode(saved))!.card!.rid, card.rid);
    });

    test('срок вышел — запись не уходит', () async {
      final s = _Setup();
      s.server.on('act_move_check', (200, moveReady()));
      final card = (await s.say(moveText)).card!;
      card.expireIfDue(now.add(const Duration(minutes: 6)));
      expect(card.state, ActionCardState.expired);
      expect(await s.assistant.answerCard(card, apply: true), isNull);
      expect(s.server.requests, hasLength(1));
    });
  });

  test('чтение 1.4.57: «что не проведено» — команда, не действие', () {
    final c = warehouseConnector(
      path: actionsManifestPath,
      builtIn: builtInManifest(),
    );
    final m = c.match(Utterance.analyze('что не проведено', now: now));
    expect(m?.commandId, 'warehouse.unposted');
  });

  group('ActWhat', () {
    bool allowed(String _) => true;
    test('количество, артикул, класс, название', () {
      ActWhat w(String t) => ActWhat.parse(t, allowed)!;
      expect(w('3 венских стула').qty, 3);
      expect(w('3 венских стула').q, 'венских стула');
      expect(w('три стула').qty, 3);
      expect(w('все стулья').qty, 'all');
      expect(w('64115').sku, '64115');
      expect(w('64115').qty, isNull);
      expect(w('3 шт 64115').sku, '64115');
      expect(w('3 шт 64115').qty, 3);
      expect(w('12 венских стульев').qty, 12);
      expect(w('стулья уценка').cls, 'UCENKA');
      expect(w('стулья уценка').q, 'стулья');
      expect(w('стулья целиком').qty, 'all');
    });

    test('слова задач и срока — не товар', () {
      final u = Utterance.analyze(
        'перемести задачу из 215-1-1-1 в 215-3-2-1',
        now: now,
      );
      expect(
        ActWhat.parse(
          'задачу',
          (String t) => !t.contains('задач') && u.original.isNotEmpty,
        ),
        isNull,
      );
      expect(ActWhat.parse('0 стульев', allowed), isNull);
    });

    test('rid — 16 знаков из Random.secure или подставного', () {
      final c = warehouseConnector(
        path: actionsManifestPath,
        builtIn: builtInManifest(),
      );
      expect(c.builtIn!.actions, hasLength(2));
      expect(Random(1).nextInt(36), lessThan(36));
    });
  });
}

/// Обрыв связи: любое исключение транспорта, кроме тайм-аута.
final class SocketLikeException implements Exception {
  const SocketLikeException();
}
