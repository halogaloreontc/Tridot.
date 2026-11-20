import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/widgets/connection_screen.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/manifest/app_connections.dart';
import 'package:local_assistant/core/connectors/manifest/app_profile.dart';
import 'package:local_assistant/core/connectors/manifest/connection.dart';
import 'package:local_assistant/core/connectors/manifest/connection_directory.dart';
import 'package:local_assistant/core/connectors/manifest/connection_service.dart';
import 'package:local_assistant/core/connectors/manifest/connection_slots.dart';
import 'package:local_assistant/core/connectors/manifest/connection_texts.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';
import 'package:local_assistant/core/services/clock.dart';

/// Тексты подключения (ADR-043, шаг 3): склад — слово в слово прежние,
/// приложение — со своим именем и родом; разбор ссылок отдаёт код, а не
/// текст склада. Приложение — синтетическая CRM `testcrm`, адреса —
/// `.example`, секреты — поддельные (CANARY).
const String testCrmPath = 'test/fixtures/assistant/testcrm.json';
const String code = '0123456789abcdef0123456789abcdef';

Map<String, Object?> crmJson() =>
    jsonDecode(File(testCrmPath).readAsStringSync()) as Map<String, Object?>;

AppProfile profileOf(Map<String, Object?> app) =>
    AppProfile.parse(app).profile!;

final AppProfile service = profileOf(crmJson()['app']! as Map<String, Object?>);

final AppProfile cash = profileOf(<String, Object?>{
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
  'in': 'в кассе',
  'gender': 'f',
});

final AppProfile crm = profileOf(<String, Object?>{'id': 'crm', 'name': 'CRM'});

ConnectionTexts textsOf(AppProfile profile, String id) =>
    ConnectionTexts.of(ConnectionSlot.generic(profile, id));

void main() {
  group('склад — прежние тексты', () {
    const t = ConnectionTexts.warehouse;

    test('слот склада — тексты склада', () {
      expect(ConnectionTexts.of(ConnectionSlots.warehouse), same(t));
      expect(t.isWarehouse, isTrue);
    });

    test('адрес и ссылка — слово в слово', () {
      expect(t.address(AddressProblem.empty), 'Укажите адрес склада.');
      expect(t.address(AddressProblem.scheme), 'Нужен адрес https://… склада.');
      expect(
        t.address(AddressProblem.httpRemote),
        'Без шифрования (http) можно только в своей сети. Для склада в '
        'интернете нужен адрес https://…',
      );
      expect(
        t.address(AddressProblem.connectBroken),
        'Ссылка «Открыть в Tridot» испорчена — сделайте новый код на складе: '
        '«Подключить Связного».',
      );
      expect(
        t.address(AddressProblem.connectCode),
        'Код в ссылке обрезан или испорчен — сделайте новый на складе.',
      );
    });

    test('вход и карточка — слово в слово', () {
      expect(t.connected('', ''), 'Склад подключён.');
      expect(t.connected('ivanov', ''), 'Склад подключён: ivanov.');
      expect(t.connectedByPassword, 'Склад подключён по паролю склада.');
      expect(t.serverSaid('нет'), 'Склад ответил: нет');
      expect(t.serverError(500), 'Склад ответил ошибкой 500.');
      expect(t.passwordLabel('Пароль CRM'), 'Пароль склада');
      expect(t.cardTitle, 'Склад');
      expect(t.cardOpen, 'Открыть склад');
      expect(t.cardOpenIn, 'Открыть в складе');
      expect(t.cardPartial, 'Склад показал не всё — уточните запрос.');
      expect(t.actionSending, 'Отправляю на склад…');
      expect(t.actionUnknown, 'Итог неизвестен — «Проверить» спросит склад');
    });

    test('разбор ссылки — код; message — текст склада, без кода', () {
      for (final (bad, problem) in <(String, AddressProblem)>[
        ('', AddressProblem.linkEmpty),
        ('просто текст', AddressProblem.notLink),
        ('https://warehouse.example/', AddressProblem.noCode),
        ('https://warehouse.example/#qr=12', AddressProblem.badCode),
        ('tridot://connect?u=x&qr=$code', AddressProblem.connectBroken),
        (
          'tridot://connect?u=${Uri.encodeComponent('https://w.example/')}'
              '&qr=12',
          AddressProblem.connectCode
        ),
      ]) {
        expect(
          () => ConnectionService.parseQrLink(bad),
          throwsA(
            isA<ConnectionAddressException>()
                .having((e) => e.problem, 'problem', problem)
                .having(
                  (e) => e.message,
                  'message',
                  ConnectionTexts.warehouse.address(problem),
                )
                .having((e) => e.message, 'без кода', isNot(contains(code))),
          ),
          reason: bad,
        );
      }
    });
  });

  group('приложение — имя, падежи, род', () {
    test('мужской род: «Автосервис»', () {
      final t = textsOf(service, 'testcrm');
      expect(t.isWarehouse, isFalse);
      expect(t.title, 'Автосервис');
      expect(t.address(AddressProblem.empty), 'Укажите адрес автосервиса.');
      expect(
        t.address(AddressProblem.connectCode),
        'Код в ссылке обрезан или испорчен — сделайте новый в автосервисе.',
      );
      expect(t.offline, 'Нет связи с автосервисом.');
      expect(t.connected('ivanov', ''), 'Автосервис подключён: ivanov.');
      expect(t.serverSaid('нет'), 'Автосервис ответил: нет');
      expect(t.passwordRejected, 'Автосервис не принял пароль.');
      expect(t.notConnectedYet, 'Автосервис ещё не подключён.');
      expect(t.addressLabel, 'Адрес автосервиса');
      expect(t.passwordLabel('Пароль CRM'), 'Пароль CRM');
      expect(t.passwordLabel(null), 'Пароль автосервиса');
      expect(t.cardTitle, 'Автосервис');
      expect(t.cardOpenIn, 'Открыть в автосервисе');
      expect(t.cardOpen, 'Открыть автосервис');
      expect(t.cardPartial, 'Автосервис показал не всё — уточните запрос.');
      expect(t.actionSending, 'Отправляю в автосервис…');
      for (final text in <String>[
        t.offlineRetry,
        t.connectFirst,
        t.noWho,
        t.cannotCheck,
        t.notThisApp(404),
        t.linkHint,
        t.logoutBody,
        t.manualHint(staff: false),
      ]) {
        expect(text.toLowerCase(), isNot(contains('склад')), reason: text);
      }
    });

    test('женский род: «Касса»', () {
      final t = textsOf(cash, 'kassa');
      expect(t.title, 'Касса');
      expect(t.connected('', ''), 'Касса подключена.');
      expect(t.serverSaid('нет'), 'Касса ответила: нет');
      expect(t.passwordRejected, 'Касса не приняла пароль.');
      expect(t.notConnectedYet, 'Касса ещё не подключена.');
      expect(t.cardPartial, 'Касса показала не всё — уточните запрос.');
      expect(t.cardOpenIn, 'Открыть в кассе');
      expect(t.cardOpen, 'Открыть кассу');
      expect(t.offline, 'Нет связи с кассой.');
    });

    test('несклоняемое «CRM»: без согласования', () {
      final t = textsOf(crm, 'crm');
      expect(t.title, 'CRM');
      expect(t.connected('', ''), 'Подключение к CRM готово.');
      expect(t.serverSaid('нет'), 'Ответ CRM: нет');
      expect(t.passwordRejected, 'Пароль для CRM не принят.');
      expect(t.notConnectedYet, 'Подключения к CRM ещё нет.');
      expect(t.cardTitle, 'CRM');
      expect(t.cardOpenIn, 'Открыть в CRM');
      expect(t.cardOpen, 'Открыть CRM');
      expect(t.cardPartial, 'Ответ CRM — не весь: уточните запрос.');
      expect(t.offline, 'Нет связи с CRM.');
    });

    test('до подключения — о «приложении»', () {
      const t = ConnectionTexts.app;
      expect(t.address(AddressProblem.empty), 'Укажите адрес приложения.');
      expect(t.cardOpen, 'Открыть приложение');
    });

    test('строка статуса — в роде приложения', () async {
      Future<String> statusOf(AppProfile profile, String id) async {
        final s = await ConnectionService.restore(
          slot: ConnectionSlot.generic(profile, id),
          transport: _Offline(),
          secrets: InMemorySecretStore(),
          store: InMemoryConnectionStore(),
          base: Uri.parse('https://crm.example/'),
          clock: FixedClock(DateTime(2026, 11, 19, 10)),
        );
        return connectionStatus(s);
      }

      expect(await statusOf(cash, 'kassa'), 'Не подключена');
      expect(await statusOf(service, 'testcrm'), 'Не подключён');
      expect(await statusOf(crm, 'crm'), 'Не подключён');
    });

    test('экран входа CRM говорит её именем', () async {
      final store = InMemoryConnectionStore();
      final s = await ConnectionService.restore(
        slot: ConnectionSlot.generic(service, 'testcrm'),
        transport: _Offline(),
        secrets: InMemorySecretStore(),
        store: store,
        pinned: jsonEncode(crmJson()),
        base: Uri.parse('https://crm.example/'),
        clock: FixedClock(DateTime(2026, 11, 19, 10)),
      );
      final empty = await s.connectManual(
        address: 'https://crm.example/',
        password: '',
      );
      expect(empty.message, 'Введите пароль автосервиса.');
      final bad = await s.connectByLink('');
      expect(bad.message, 'Вставьте ссылку входа — её даёт само приложение.');
      final address = await s.connectManual(address: '', password: 'x');
      expect(address.message, 'Укажите адрес автосервиса.');
    });
  });

  group('предложение приложения переживает перезапуск', () {
    test('offered — в каталоге, после загрузки снова в подключении', () async {
      final d = crmJson();
      var server = jsonEncode(d);
      final transport = _Routes((HttpRequestData r) {
        if (r.uri.path.endsWith('assistant.json')) {
          return HttpResponseData(statusCode: 200, body: server);
        }
        return const HttpResponseData(statusCode: 404);
      });
      final store = InMemoryConnectionStore();
      final directory = InMemoryConnectionDirectory(store: store);
      final secrets = InMemorySecretStore();
      AppConnections hub() => AppConnections(
            transport: transport,
            secrets: secrets,
            store: store,
            directory: directory,
            clock: FixedClock(DateTime(2026, 11, 19, 10)),
          );
      final first = hub();
      await first.load();
      final added = await first.add(await first.probe('crm.example'));
      // Сервер расширил права: новое действие.
      final wider = crmJson();
      wider['version'] = '1.1.0';
      ((wider['api']! as Map)['only']! as List).add('ask_orders');
      final orders = Map<String, Object?>.of(
        ((wider['commands']! as List).first as Map).cast<String, Object?>(),
      )
        ..['id'] = 'orders'
        ..['say'] = <String>['заказы {q}']
        ..['call'] = <String, Object?>{
          'action': 'ask_orders',
          'body': <String, Object?>{'q': '{q}'},
        };
      (wider['commands']! as List).add(orders);
      server = jsonEncode(wider);
      await added.service.refreshManifest();
      expect(added.service.offered, contains('ask_orders'));
      await Future<void>.delayed(Duration.zero);
      expect(directory.text, contains('"offered"'));
      expect(first.offers.keys, <String>['testcrm']);

      final second = hub();
      await second.load();
      expect(second.offers['testcrm'], contains('ask_orders'));

      // Сервер вернул прежнее: предложение снято и в каталоге.
      server = jsonEncode(d);
      await second.byId('testcrm')!.refreshManifest();
      await Future<void>.delayed(Duration.zero);
      expect(second.offers, isEmpty);
      expect(directory.text, isNot(contains('"offered"')));
      ConnectionSlots.useRuntime(const <ConnectionSlot>[]);
    });
  });
}

final class _Offline implements HttpTransport {
  @override
  Future<HttpResponseData> send(HttpRequestData request) async =>
      throw const SocketException('нет сети');
}

final class _Routes implements HttpTransport {
  _Routes(this.respond);

  final HttpResponseData Function(HttpRequestData) respond;

  @override
  Future<HttpResponseData> send(HttpRequestData request) async =>
      respond(request);
}
