import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/manifest/connection.dart';
import 'package:local_assistant/core/connectors/manifest/connection_slots.dart';
import 'package:local_assistant/core/connectors/manifest/manifest_connector.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/replies/reply_library.dart';
import 'package:local_assistant/core/services/clock.dart';

import '../fakes.dart';
import 'fixtures.dart';

/// Заведомо поддельные секреты: настоящих в тестах нет.
const String fakeToken = 'fake-token-not-real';
const String fakeSid = 'fake-sid-not-real';

final DateTime now = DateTime(2026, 11, 2, 16, 30);

String response(String name) =>
    File('test/fixtures/assistant/responses/$name.json').readAsStringSync();

HttpResponseData ok(String name) =>
    HttpResponseData(statusCode: 200, body: response(name));

HttpResponseData json(int status, Map<String, Object?> body) =>
    HttpResponseData(statusCode: status, body: jsonEncode(body));

InMemorySecretStore secrets({bool sid = true}) => InMemorySecretStore(
      <String, String>{
        'warehouse.token': fakeToken,
        if (sid) 'warehouse.sid': fakeSid,
      },
    );

AssistantSession session() {
  final registry = ExtensionRegistry(
    connectors: <Connector>[warehouseConnector()],
  );
  return AssistantSession(clock: FixedClock(now), replies: registry.replies);
}

void main() {
  final connector = warehouseConnector();

  ConnectorMatch? match(String text) =>
      connector.match(Utterance.analyze(text, now: now));

  group('паспорт', () {
    test('подключение, только чтение, выключено до входа', () {
      final info = connector.info;
      expect(info.id, 'warehouse');
      expect(info.kind, ExtensionKind.connector);
      expect(info.requiresNetwork, isTrue);
      expect(info.access, ConnectorAccess.readOnly);
      expect(info.defaultEnabled, isFalse);
      expect(info.replies.keys, everyElement(startsWith('warehouse.')));
      expect(info.protectedReplies, contains('warehouse.notConnected'));
    });

    test('каждый пример распознаётся своей командой', () {
      expect(connector.info.examples, isNotEmpty);
      for (final example in connector.info.examples) {
        expect(match(example), isNotNull, reason: example);
      }
      expect(connector.info.examples.first, 'где лежит 64115');
    });

    test('записи каталога разбираются и не спорят со встроенными', () {
      expect(
        () => ExtensionRegistry(connectors: <Connector>[connector]),
        returnsNormally,
      );
    });
  });

  group('match: таблица фраз', () {
    final table = <String, (String?, double?)>{
      'где лежит 64115': ('warehouse.where', 0.9),
      'Где стул венский?': ('warehouse.where', 0.75),
      '64115 где лежит': ('warehouse.where', 0.9),
      'найди 64115': ('warehouse.where', 0.75),
      'сколько венских стульев': ('warehouse.count', 0.75),
      'сколько осталось 64115': ('warehouse.count', 0.9),
      'сколько стоит 64115': ('warehouse.price', 0.9),
      'что в ячейке 215-1-1-1': ('warehouse.cell', 0.9),
      'стеллаж 215-3': ('warehouse.cell', 0.75),
      '215-1-1-1': ('warehouse.cell', 0.85),
      'без места': ('warehouse.cell', 0.85),
      '64115': ('warehouse.where', 0.7),
      'что пришло сегодня': ('warehouse.today', 0.9),
      'что пришло вчера': ('warehouse.yesterday', 0.9),
      'за неделю': ('warehouse.week', 0.9),
      'приходы без фото': ('warehouse.nophoto', 0.9),
      'где нет фото': ('warehouse.nophoto', 0.9),
      'что умеет склад': ('warehouse.help', 0.9),
      'привет, где лежит 64115': ('warehouse.where', 0.9),
      'покажи мне, где лежит 64115': ('warehouse.where', 0.9),
      'кстати, где лежит 64115': ('warehouse.where', 0.9),
      'на складе где стул венский': ('warehouse.where', 0.8),
      'склад, сегодня': ('warehouse.today', 0.95),
      'склад, помощь': ('warehouse.help', 0.95),
      'на складе стул венский': ('warehouse.where', 0.8),
      // Отрицательные: чужие фразы склад не берёт.
      'сегодня': (null, null),
      'вчера': (null, null),
      'помощь': (null, null),
      'команды': (null, null),
      'привет': (null, null),
      'что ты умеешь': (null, null),
      'сколько будет 2+2': (null, null),
      'сколько будет два плюс два': (null, null),
      'сколько у меня задач': (null, null),
      'найди задачу отчёт': (null, null),
      'Добавь задачу проверить, где лежит 64115': (null, null),
      'через 2 часа позвонить': (null, null),
      'найди время завтра': (null, null),
      'где лежит 15.11': (null, null),
      'сколько тебе лет': (null, null),
      'сколько мне лет': (null, null),
      'сколько времени': (null, null),
      'где ты': (null, null),
      '215 - 3': (null, null),
      '64115-01': (null, null),
      'стул венский': (null, null),
      'как дела': (null, null),
    };
    for (final MapEntry(key: text, value: (command, confidence))
        in table.entries) {
      test(text, () {
        final found = match(text);
        expect(found?.commandId, command);
        if (confidence != null) {
          expect(found!.confidence, closeTo(confidence, 1e-9));
          expect(found.connectorId, 'warehouse');
          expect(found.implicit, isFalse);
          expect(found.fallback, isFalse);
        }
      });
    }

    test('поля и способ разбора — в payload', () {
      final where = match('где лежит 64115')!.payload! as ManifestPayload;
      expect(where.command, 'where');
      expect(where.slots, <String, String>{'q': '64115'});
      expect(where.how, 'say');
      final code = match('64115')!.payload! as ManifestPayload;
      expect(code.how, 'fallback');
      final cell = match('стеллаж 215-3')!.payload! as ManifestPayload;
      expect(cell.slots, <String, String>{'cell': '215-3'});
      final aliased =
          match('на складе где стул венский')!.payload! as ManifestPayload;
      expect(aliased.aliased, isTrue);
    });

    test('слишком длинное сообщение не разбирается', () {
      expect(match('где лежит ${'стул ' * 50}'), isNull);
    });

    test('без описания — ничего', () {
      final empty = ManifestConnector(
        slot: ConnectionSlots.warehouse,
        transport: const OfflineTransport(),
        secrets: InMemorySecretStore(),
      );
      expect(
        empty.match(Utterance.analyze('где лежит 64115', now: now)),
        isNull,
      );
      expect(empty.info.examples, isEmpty);
    });
  });

  group('run', () {
    Future<(AssistantResponse, FakeHttpTransport, ManifestConnector)> run(
      String text,
      HttpResponseData Function(HttpRequestData request) respond, {
      SecretStore? store,
      String path = currentManifestPath,
      ConnectionRecord? record,
    }) async {
      final transport = FakeHttpTransport(respond);
      final c = warehouseConnector(
        path: path,
        transport: transport,
        secrets: store ?? secrets(),
        record: record ?? connectedRecord(),
      );
      final m = c.match(Utterance.analyze(text, now: now))!;
      final reply = await c.run(m, session());
      return (reply, transport, c);
    }

    void noSecrets(AssistantResponse reply) {
      for (final text in <String>[reply.message, ...reply.values.values]) {
        expect(text, isNot(contains(fakeToken)));
        expect(text, isNot(contains(fakeSid)));
      }
    }

    test('где лежит: запрос, заголовки, тело и строки ответа', () async {
      final (reply, transport, _) =
          await run('где лежит 64115', (_) => ok('ask_stock_sku'));
      final request = transport.requests.single;
      expect(request.method, 'POST');
      expect(
        request.uri.toString(),
        'https://warehouse.example/api.php?action=ask_stock',
      );
      expect(request.headers['X-Wh-Token'], fakeToken);
      // Остатки — уровень shared: личный ключ не нужен и не уходит.
      expect(request.headers.containsKey('X-Wh-Sid'), isFalse);
      expect(request.headers['Content-Type'], 'application/json');
      expect(jsonDecode(request.body!), <String, Object?>{'q': '64115'});
      expect(request.timeout, ManifestConnector.requestTimeout);
      expect(reply.status, AssistantStatus.completed);
      expect(reply.intent, 'warehouse.where');
      expect(reply.replyId, 'warehouse.answer');
      expect(
        reply.message,
        '«64115»: 2 позиции, всего 1 234,5 шт.\n'
        '• 64115 — Стул венский — 1 200 шт.\n'
        '   – 215-1-1-1 — годен — 1 000 шт.\n'
        '   – 215-1-1-2 — уценка — 200 шт.\n'
        '• без артикула — Стул венский (без бирки) — 34,5 шт.\n'
        '   – БЕЗ МЕСТА — 34,5 шт.',
      );
      noSecrets(reply);
    });

    test('сколько: вложенный список складов', () async {
      final (reply, _, _) =
          await run('остаток 64115', (_) => ok('ask_stock_sku'));
      expect(reply.message, startsWith('«64115»: всего 1 234,5 шт. — 2 '));
      expect(reply.message, contains('   – склад Основной — 1 200 шт.'));
    });

    test('больше 8 строк — «и ещё N» и «Показаны не все»', () async {
      final (reply, _, _) = await run('где товар', (_) => ok('ask_stock_more'));
      final lines = reply.message.split('\n');
      expect(lines.where((String l) => l.startsWith('• ')), hasLength(8));
      expect(lines, contains('и ещё 22'));
      expect(lines.last, 'Показаны не все — уточните запрос.');
    });

    test('пусто — текст empty описания', () async {
      final (reply, _, _) =
          await run('где лежит абв', (_) => ok('ask_stock_none'));
      expect(reply.replyId, 'warehouse.empty');
      expect(
        reply.message,
        '«абв» на складе нет — ни по артикулу, ни по названию.',
      );
    });

    test('голый код и пустой ответ — примеры вопросов', () async {
      final (reply, _, _) = await run('64115', (_) => ok('ask_stock_none'));
      expect(reply.replyId, 'warehouse.fallbackEmpty');
      expect(reply.message, contains('Спросите, например: «где лежит 64115»'));
    });

    test('ячейка: тело с кодом заглавными, note строки', () async {
      final (reply, transport, _) =
          await run('что в ячейке 215-1-1-1', (_) => ok('ask_cell_exact'));
      expect(
        transport.requests.single.uri.queryParameters['action'],
        'ask_cell',
      );
      expect(jsonDecode(transport.requests.single.body!), <String, Object?>{
        'cell': '215-1-1-1',
      });
      expect(
        reply.message,
        '215-1-1-1: 1 строка, 5 шт. — 1 ячейка\n'
        '• 64115 — Стул венский — 5 шт. (215-1-1-1 · годен)',
      );
    });

    test('приходы сегодня: личный ключ, даты и пояс', () async {
      final (reply, transport, _) =
          await run('что пришло сегодня', (_) => ok('ask_arrivals_today'));
      final request = transport.requests.single;
      expect(request.uri.queryParameters['action'], 'ask_arrivals');
      expect(request.headers['X-Wh-Sid'], fakeSid);
      expect(jsonDecode(request.body!), <String, Object?>{
        'from': '2026-11-02',
        'to': '2026-11-02',
        'tz': '${-now.timeZoneOffset.inMinutes}',
        'zone': '',
      });
      expect(
        reply.message,
        'Сегодня 2 прихода, 21 шт.\n'
        '• П-12 — Реестр · 09:15 — 1 позиция (возврат)\n'
        '• без номера — Разовый · 11:00 — 5 позиций',
      );
    });

    test(r'за неделю: с $today-6, дата прошлого года — с годом', () async {
      final (reply, transport, _) =
          await run('за неделю', (_) => ok('ask_arrivals_week'));
      final body = jsonDecode(transport.requests.single.body!) as Map;
      expect(body['from'], '2026-10-27');
      expect(body['to'], '2026-11-02');
      expect(reply.message, contains('Реестр · 30.12.2025 10:00'));
    });

    test('вчера и пусто', () async {
      final (reply, transport, _) =
          await run('что пришло вчера', (_) => ok('ask_arrivals_empty'));
      expect(
        (jsonDecode(transport.requests.single.body!) as Map)['from'],
        '2026-11-01',
      );
      expect(reply.message, 'Вчера приходов не было.');
    });

    test('без фото: days числом, unless и badge', () async {
      final (reply, transport, _) =
          await run('приходы без фото', (_) => ok('ask_nophoto'));
      final body = jsonDecode(transport.requests.single.body!) as Map;
      expect(body['days'], 30);
      expect(body['days'], isA<int>());
      expect(
        reply.message,
        'За 30 дней без снимков — 1 приход, 2 позиции.\n'
        '• П-3 — Реестр · 20.10 — 2 из 5 (64115, 64116 · скан не '
        'прикреплён)',
      );
    });

    test('цена и справка — без сети', () async {
      final (price, transport, _) = await run(
        'сколько стоит 64115',
        (_) => throw StateError('сеть не нужна'),
      );
      // Голос помощника из каталога, а не текст описания на «вы».
      expect(price.replyId, 'warehouse.price');
      expect(price.message, startsWith('Цены я пока не называю'));
      expect(price.message, isNot(contains('помощник')));
      expect(transport.requests, isEmpty);
      final (help, _, _) = await run(
        'что умеет склад',
        (_) => throw StateError('сеть не нужна'),
      );
      expect(help.replyId, 'warehouse.help');
      expect(help.message, contains('где лежит товар — «где лежит 64115»'));
      expect(help.message, isNot(contains('что ты умеешь')));
    });

    test('без пароля — ни одного запроса', () async {
      final (reply, transport, _) = await run(
        'где лежит 64115',
        (_) => throw StateError('сеть не нужна'),
        store: InMemorySecretStore(),
      );
      expect(reply.replyId, 'warehouse.notConnected');
      expect(reply.status, AssistantStatus.noAction);
      expect(transport.requests, isEmpty);
    });

    test('приходы без личного ключа — ни одного запроса', () async {
      final (reply, transport, _) = await run(
        'что пришло сегодня',
        (_) => throw StateError('сеть не нужна'),
        store: secrets(sid: false),
      );
      expect(reply.replyId, 'warehouse.auth.staff');
      expect(transport.requests, isEmpty);
    });

    group('ошибки', () {
      Future<AssistantResponse> fail(
        String text,
        HttpResponseData Function(HttpRequestData r) respond, {
        bool sid = true,
      }) async =>
          (await run(text, respond, store: secrets(sid: sid))).$1;

      test('401 — пароль не принят', () async {
        final reply = await fail(
          'где лежит 64115',
          (_) => json(401, <String, Object?>{'error': 'Неверный пароль'}),
        );
        expect(reply.replyId, 'warehouse.auth.token');
        expect(reply.status, AssistantStatus.failed);
        noSecrets(reply);
      });

      test('403 need:login с ключом — ключ устарел', () async {
        final reply = await fail(
          'что пришло сегодня',
          (_) => json(403, <String, Object?>{
            'error': 'Нужен вход под своим логином',
            'need': 'login',
          }),
        );
        expect(reply.replyId, 'warehouse.auth.expired');
      });

      test('403 need:role', () async {
        final reply = await fail(
          'что пришло сегодня',
          (_) => json(403, <String, Object?>{'error': 'ждёт', 'need': 'role'}),
        );
        expect(reply.replyId, 'warehouse.auth.role');
      });

      test('400 с текстом — «Склад ответил»', () async {
        final reply = await fail(
          'ячейка 215-3',
          (_) => json(400, <String, Object?>{'error': 'Нужен код ячейки'}),
        );
        expect(reply.replyId, 'warehouse.serverSaid');
        expect(reply.message, 'Склад ответил: Нужен код ячейки');
        expect(reply.status, AssistantStatus.completed);
      });

      test('429 — подождать', () async {
        final reply = await fail(
          'где лежит 64115',
          (_) => json(429, <String, Object?>{'error': 'Слишком много'}),
        );
        expect(reply.replyId, 'warehouse.busy');
      });

      test('500 и 502 с HTML — ошибка сервера', () async {
        for (final r in <HttpResponseData>[
          json(500, <String, Object?>{'error': 'Сбой: …'}),
          const HttpResponseData(statusCode: 502, body: '<html>Bad</html>'),
          const HttpResponseData(statusCode: 200, body: '<html>ok</html>'),
        ]) {
          final reply = await fail('где лежит 64115', (_) => r);
          expect(reply.replyId, 'warehouse.serverError');
          expect(reply.status, AssistantStatus.failed);
        }
      });

      test('обрыв и тайм-аут', () async {
        final offline = await fail(
          'где лежит 64115',
          (_) => throw const SocketException('нет сети'),
        );
        expect(offline.replyId, 'warehouse.offline');
        final timeout = await fail(
          'где лежит 64115',
          (_) => throw TimeoutException('долго'),
        );
        expect(timeout.replyId, 'warehouse.timeout');
      });
    });

    test('ответ голосом Noda на «ты»: обёртка каталога, факт как есть',
        () async {
      final transport = FakeHttpTransport((_) => ok('ask_stock_more'));
      final c = warehouseConnector(
        transport: transport,
        secrets: secrets(),
        record: connectedRecord(),
      );
      final s = session()
        ..voice = const ReplyVoice(
          gender: ReplyGender.female,
          address: ReplyAddress.informal,
        );
      final reply = await c.run(
        c.match(Utterance.analyze('где товар', now: now))!,
        s,
      );
      expect(reply.message, startsWith('«товар»: 30 позиций'));
      expect(reply.message, endsWith('Показаны не все — уточни запрос.'));
    });
  });

  group('здоровье', () {
    test('по исходам запросов, без сети', () async {
      final transport = FakeHttpTransport((_) => ok('ask_stock_sku'));
      final store = secrets();
      final records = <ConnectionRecord>[];
      final c = warehouseConnector(
        transport: transport,
        secrets: store,
        record: connectedRecord(),
      )..onRecordChanged = records.add;
      Future<HealthReport> after(HttpResponseData Function() respond) async {
        final t = FakeHttpTransport((_) => respond());
        final probe = ManifestConnector(
          slot: ConnectionSlots.warehouse,
          description: c.description,
          transport: t,
          secrets: store,
          record: c.record,
        )..onRecordChanged = (ConnectionRecord r) => c.record = r;
        await probe.run(
          probe.match(Utterance.analyze('где лежит 64115', now: now))!,
          session(),
        );
        return c.health();
      }

      expect((await c.health()).status, HealthStatus.ok);
      await c.run(
        c.match(Utterance.analyze('где лежит 64115', now: now))!,
        session(),
      );
      expect(records.last.lastOk, now);
      final healthy = await c.health();
      expect(healthy.status, HealthStatus.ok);
      expect(healthy.since, now);

      var report = await after(() => throw const SocketException('нет'));
      expect(report.status, HealthStatus.down);
      expect(report.detail, 'нет связи с сервером');
      expect(report.since, now);

      report = await after(() => json(401, <String, Object?>{}));
      expect(report.detail, 'не принял пароль');

      report = await after(() => json(503, <String, Object?>{}));
      expect(report.status, HealthStatus.degraded);

      report = await after(() => ok('ask_stock_sku'));
      expect(report.status, HealthStatus.ok);
      expect(transport.requests, hasLength(1));
    });

    test('не подключён — down', () async {
      final c = warehouseConnector();
      final report = await c.health();
      expect(report.status, HealthStatus.down);
      expect(report.detail, 'не подключён');
    });
  });
}
