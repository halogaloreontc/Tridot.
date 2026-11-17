// Пароль, вставленный в чат (ADR-014, раздел 5.9, раздел 11, группа 11):
// SecretGuard маскирует его, ни один коннектор фразу не получает, задача не
// создаётся; при выключенном навыке — то же; выходной фильтр ответа;
// «тихая» ошибка чувствительного коннектора.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/passwords/secret_guard.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import '../connectors/example_warehouse_connector.dart';
import '../connectors/fakes.dart';

/// Коннектор-шпион: берёт любую фразу и запоминает всё, что видел.
final class _Spy implements Connector {
  _Spy({this.network = false, this.sensitive = false, this.reply});

  final bool network;
  final bool sensitive;

  /// Что вернуть из `run`: ответ или исключение с этим текстом.
  final String? reply;
  final List<String> seen = <String>[];
  int runs = 0;

  @override
  ConnectorInfo get info => ConnectorInfo(
        id: network ? 'spy_net' : 'spy',
        title: 'Шпион',
        description: 'Видит всё.',
        requiresNetwork: network,
        sensitive: sensitive,
      );

  @override
  ConnectorMatch? match(Utterance utterance) {
    seen.add(utterance.original);
    return ConnectorMatch(
      connectorId: info.id,
      commandId: '${info.id}.any',
      confidence: network ? 0.6 : 0.4,
    );
  }

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async {
    runs++;
    final text = reply;
    if (sensitive && text != null) throw StateError(text);
    return AssistantResponse(
      message: 'Нашёл «${text ?? ''}».',
      intent: match.commandId,
      status: AssistantStatus.completed,
      values: <String, String>{'service': text ?? ''},
    );
  }
}

void main() {
  group('SecretGuard.redact', () {
    test('положительные: пароль скрыт, токен выброшен', () {
      final cases = <String, String>{
        'пароль от почты: CANARY-x': 'CANARY-x',
        'мой пароль от госуслуг = CANARY-x2': 'CANARY-x2',
        'pin: 4821': '4821',
        'пин-код от карты: 0007': '0007',
        'password: CANARY-x3': 'CANARY-x3',
        'логин ivan пароль CANARY-y': 'CANARY-y',
        'пароль "CANARY z"': 'CANARY z',
        'пароль от wifi «CANARY w1»': 'CANARY w1',
        'пароль от почты это CANARY-t': 'CANARY-t',
        'пароль от почты CANARY9x!': 'CANARY9x!',
      };
      for (final MapEntry(key: text, value: canary) in cases.entries) {
        final result = SecretGuard.redact(text);
        expect(result.guarded, isTrue, reason: text);
        expect(result.text, isNot(contains(canary)), reason: text);
        expect(result.text, contains(SecretGuard.mask), reason: text);
      }
      expect(
        SecretGuard.redact('пароль от почты: CANARY-x').text,
        'пароль от почты: ${SecretGuard.mask}',
      );
    });

    test('формы без предлога, PIN-код, кавычки без условия, длинный сервис',
        () {
      final cases = <String, String>{
        'пароль почты: CANARY-a1': 'CANARY-a1',
        'пароль wifi: CANARY-a2': 'CANARY-a2',
        'PIN-код: 4821': '4821',
        'pin-код: 4821': '4821',
        'PIN-кода от карты: 4821': '4821',
        'пароль «canary horse battery staple»': 'canary horse battery',
        'пароль от почты "canaryword"': 'canaryword',
        'пароль от моей старой рабочей почты на яндексе которую я завёл ещё '
            'в институте: canaryabcdef': 'canaryabcdef',
        'пароли: CANARY-a5': 'CANARY-a5',
        'к паролю: CANARY-a6': 'CANARY-a6',
        'pwd: CANARY-a7': 'CANARY-a7',
        'login ivan password CANARY-a8': 'CANARY-a8',
        'логин ivan и пароль CANARY-a9': 'CANARY-a9',
        'пароль：CANARY-a3': 'CANARY-a3',
      };
      for (final MapEntry(key: text, value: canary) in cases.entries) {
        final result = SecretGuard.redact(text);
        expect(result.guarded, isTrue, reason: text);
        expect(result.text, isNot(contains(canary)), reason: text);
      }
    });

    test('пароль-фраза после разделителя скрыта целиком', () {
      final result = SecretGuard.redact('пароль: canary horse battery');
      expect(result.text, 'пароль: ${SecretGuard.mask}');
      for (final word in <String>['canary', 'horse', 'battery']) {
        expect(result.text, isNot(contains(word)));
      }
    });

    test('отпечаток: пароль с «!» на конце внутри пунктуации', () {
      bool known(String token) => token == 'CANARYq1!';
      for (final text in <String>[
        'вот CANARYq1!, держи',
        'вот CANARYq1!.',
        'вот (CANARYq1!)',
        'mail:CANARYq1!',
      ]) {
        final inbound = SecretGuard.redact(text, known: known);
        expect(inbound.guarded, isTrue, reason: text);
        expect(inbound.text, isNot(contains('CANARYq1')), reason: text);
        final outbound = SecretGuard.redactKnown(text, known);
        expect(outbound.guarded, isTrue, reason: text);
        expect(outbound.text, isNot(contains('CANARYq1')), reason: text);
      }
      expect(
        SecretGuard.redactKnown('вот (CANARYq1!)', known).text,
        'вот (•••)',
      );
      expect(SecretGuard.redactKnown('mail:CANARYq1!', known).text, 'mail:•••');
    });

    test('по отпечатку при открытом хранилище — без слова «пароль»', () {
      bool known(String token) => token == 'CANARYfp77';
      final result = SecretGuard.redact(
        'вот CANARYfp77, запиши',
        known: known,
      );
      expect(result.guarded, isTrue);
      expect(result.text, 'вот ${SecretGuard.mask} запиши');
      expect(SecretGuard.redact('вот CANARYfp77, запиши').guarded, isFalse);
    });

    test('отрицательные: обычные фразы не трогаются', () {
      for (final text in <String>[
        'пароль от wifi записать в задачи',
        'сменить пароль от почты завтра',
        'сменить пароль от почты завтра в 10:00',
        'пароль — это важно',
        'пароль - это важно',
        'пароль от почты забыл',
        'забыл пароль от Яндекса',
        'дай пароль от wi-fi какой-нибудь',
        'Расскажи, как поменять пароль',
        'спиннер и пассажир',
        'купить хлеб завтра в 10:00',
        'пароль от почты ivan@mail.ru',
        'забыл логин и пароль от почты',
        'пароль почты сменить завтра в 10:00',
        'покажи пароли',
        'pin-код забыл',
      ]) {
        final result = SecretGuard.redact(text);
        expect(result.guarded, isFalse, reason: text);
        expect(result.text, text);
      }
    });

    test('похоже на пароль', () {
      for (final yes in <String>[
        'Kx9!mq2z',
        'wifi2024',
        'CANARY-x',
        'qwe!rty',
      ]) {
        expect(SecretGuard.looksLikePassword(yes), isTrue, reason: yes);
      }
      for (final no in <String>[
        'Яндекс',
        'почта',
        'какой-нибудь',
        'ivan@mail.ru',
        'https://example.org',
        '10.11.2026',
        '10:00',
      ]) {
        expect(SecretGuard.looksLikePassword(no), isFalse, reason: no);
      }
    });

    test('двоеточие схемы адреса — не разделитель', () {
      const text = 'покажи пароль от сайта https://example.com/login';
      final result = SecretGuard.redact(text);
      expect(result.guarded, isFalse);
      expect(result.text, text);
      // Адрес в названии сервиса, пароль после настоящего разделителя.
      final withSecret = SecretGuard.redact(
        'пароль от сайта https://example.com/login: CANARY-u1',
      );
      expect(
        withSecret.text,
        'пароль от сайта https://example.com/login: ${SecretGuard.mask}',
      );
      expect(
        SecretGuard.redact('пароль почты: CANARY-u2').text,
        'пароль почты: ${SecretGuard.mask}',
      );
    });

    test('отпечаток: известный пароль в середине длинного адреса', () {
      const canary = 'CANARYmid42';
      bool known(String token) => token == canary;
      const text = 'открой https://x.example/a/b/c/d/e/f/g?u=1&p=$canary'
          '&x=2&y=3&z=4 сейчас';
      final outbound = SecretGuard.redactKnown(text, known);
      expect(outbound.guarded, isTrue);
      expect(outbound.text, isNot(contains(canary)));
      expect(
        outbound.text,
        'открой https://x.example/a/b/c/d/e/f/g?u=1&p=•••&x=2&y=3&z=4 сейчас',
      );
      final inbound = SecretGuard.redact(text, known: known);
      expect(inbound.guarded, isTrue);
      expect(inbound.text, isNot(contains(canary)));
      // Тот же адрес без пароля не трогается.
      const plain = 'открой https://x.example/a/b/c/d/e/f/g?u=1&p=0'
          '&x=2&y=3&z=4 сейчас';
      expect(SecretGuard.redact(plain, known: known).guarded, isFalse);
      expect(SecretGuard.redactKnown(plain, known).guarded, isFalse);
    });

    test('отпечаток: слишком длинный составной токен скрыт целиком', () {
      var calls = 0;
      bool known(String token) {
        calls++;
        return false;
      }

      final token = List<String>.generate(400, (int i) => 'a$i').join('&');
      final outbound = SecretGuard.redactKnown('вот $token', known);
      expect(outbound.text, 'вот •••');
      final inbound = SecretGuard.redact('вот $token', known: known);
      expect(inbound.guarded, isTrue);
      expect(calls, lessThan(20000), reason: 'перебор ограничен');
    });

    test('выходной фильтр меняет совпадение на •••', () {
      bool known(String token) => token == 'CANARYout1';
      final result = SecretGuard.redactKnown('Нашёл «CANARYout1».', known);
      expect(result.guarded, isTrue);
      expect(result.text, 'Нашёл «•••».');
    });
  });

  group('маршрутизатор', () {
    final clock = FixedClock(DateTime(2026, 11, 10, 12));
    late TaskService tasks;
    late FakeHttpTransport transport;
    late _Spy spy;
    late _Spy netSpy;
    late AssistantController assistant;

    setUp(() {
      tasks = TaskService(repository: InMemoryTaskRepository(), clock: clock);
      transport = FakeHttpTransport(
        (HttpRequestData request) =>
            const HttpResponseData(statusCode: 200, body: '{}'),
      );
      spy = _Spy();
      netSpy = _Spy(network: true);
      assistant = AssistantController(
        connectors: <Connector>[
          TasksConnector(
            taskService: tasks,
            parser: ScenarioParser(clock: clock),
          ),
          ExampleWarehouseConnector(
            transport: transport,
            secrets: InMemorySecretStore(<String, String>{
              ExampleWarehouseConnector.tokenKey: 'токен',
            }),
            baseUri: Uri.parse('https://warehouse.example/api/'),
          ),
          spy,
          netSpy,
        ],
        clock: clock,
      );
    });

    for (final text in <String>[
      'пароль от почты: CANARY-x',
      'добавь задачу пароль от почты: CANARY-x',
      'логин ivan пароль CANARY-y',
      'пароль "CANARY z"',
      'пароль от почты CANARY9x!',
      'добавь задачу пароль wifi: CANARY-a2',
      'добавь задачу PIN-код: 4821',
      'добавь задачу пароль "canaryhorsestaple"',
    ]) {
      test('«$text» — ни один коннектор не вызван', () async {
        final working = assistant.working(text);
        final response = await assistant.handle(text);
        expect(response.replyId, 'secret.redacted');
        expect(response.status, AssistantStatus.noAction);
        expect(spy.seen, isEmpty);
        expect(netSpy.seen, isEmpty);
        expect(transport.requests, isEmpty);
        expect(await tasks.listAll(), isEmpty, reason: 'задача не создана');
        for (final part in <String>[
          'CANARY-x',
          'CANARY-y',
          'CANARY z',
          'CANARY9x',
          'CANARY-a2',
          '4821',
          'canaryhorsestaple',
        ]) {
          expect(response.message, isNot(contains(part)));
          expect(working.message, isNot(contains(part)));
          expect(response.values.values.join(), isNot(contains(part)));
        }
      });
    }

    test('интерфейс уже скрыл пароль — тот же ответ', () async {
      final response = await assistant.handle(
        'вот ${SecretGuard.mask}',
        secretRedacted: true,
      );
      expect(response.replyId, 'secret.redacted');
      expect(spy.seen, isEmpty);
    });

    test('адрес сайта в команде — не пароль', () async {
      final response = await assistant
          .handle('покажи пароль от сайта https://example.com/login');
      expect(response.replyId, isNot('secret.redacted'));
      expect(spy.seen, isNotEmpty);
    });

    test('обычная фраза идёт дальше', () async {
      final response = await assistant.handle('сменить пароль от почты завтра');
      expect(response.replyId, isNot('secret.redacted'));
      expect(spy.seen, isNotEmpty);
    });

    test('навык «Пароли» выключен (его ещё нет) — secret.redacted', () async {
      expect(
        assistant.extensions.isEnabled('passwords'),
        isFalse,
      );
      final response = await assistant.handle('пароль от почты: CANARY-x');
      expect(response.replyId, 'secret.redacted');
      expect(await tasks.listAll(), isEmpty);
    });

    test('отпечаток при открытом хранилище: фраза без слова «пароль»',
        () async {
      assistant.knownSecret = (String token) => token == 'CANARYfp77';
      final response = await assistant.handle('добавь задачу CANARYfp77');
      expect(response.replyId, 'secret.redacted');
      expect(await tasks.listAll(), isEmpty);
    });
  });

  group('ответы', () {
    final clock = FixedClock(DateTime(2026, 11, 10, 12));

    test('выходной фильтр: подстановка совпала по отпечатку → •••', () async {
      final spy = _Spy(reply: 'CANARYout1');
      final assistant = AssistantController(
        connectors: <Connector>[spy],
        clock: clock,
      )..knownSecret = (String token) => token == 'CANARYout1';
      final response = await assistant.handle('найди что-нибудь');
      expect(response.message, isNot(contains('CANARYout1')));
      expect(response.message, contains('•••'));
      expect(response.values['service'], '•••');
      expect(assistant.outboundLeaks, 1);
    });

    test('чувствительный коннектор упал — router.failed.quiet без текста',
        () async {
      final spy = _Spy(sensitive: true, reply: 'CANARY-in-error');
      final assistant = AssistantController(
        connectors: <Connector>[spy],
        clock: clock,
      );
      final response = await assistant.handle('найди что-нибудь');
      expect(response.replyId, 'router.failed.quiet');
      expect(response.status, AssistantStatus.failed);
      expect(response.message, isNot(contains('CANARY')));
      expect(response.values, isEmpty);
    });

    test('обычный коннектор упал — прежний router.failed с причиной', () async {
      final spy = _Failing();
      final assistant = AssistantController(
        connectors: <Connector>[spy],
        clock: clock,
      );
      final response = await assistant.handle('найди что-нибудь');
      expect(response.replyId, 'router.failed');
      expect(response.values['error'], contains('сломался'));
    });
  });
}

final class _Failing implements Connector {
  @override
  ConnectorInfo get info =>
      const ConnectorInfo(id: 'failing', title: 'Сбой', description: 'Падает.');

  @override
  ConnectorMatch? match(Utterance utterance) => const ConnectorMatch(
        connectorId: 'failing',
        commandId: 'failing.any',
        confidence: 0.9,
      );

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async =>
      throw StateError('сломался');
}
