import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/skills/data/data_connector.dart';
import 'package:local_assistant/core/skills/passwords/passwords_phrases.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';

import '../passwords/vault_test_support.dart';

/// Часы, которые тест двигает сам.
final class _Clock implements Clock {
  _Clock(this.value);

  DateTime value;

  @override
  DateTime now() => value;
}

/// Навык «Пароли» без хранилища: разбор — настоящий ([PasswordPhrases]),
/// выполнение только запоминает команду.
final class _Passwords implements Connector {
  final List<String> ran = <String>[];

  @override
  ConnectorInfo get info => const ConnectorInfo(
        id: 'passwords',
        title: 'Пароли',
        description: 'Тест.',
        kind: ExtensionKind.skill,
        defaultEnabled: false,
        sensitive: true,
      );

  @override
  ConnectorMatch? match(Utterance utterance) {
    final command = PasswordPhrases.parse(utterance);
    if (command == null) return null;
    return ConnectorMatch(
      connectorId: 'passwords',
      commandId: command.cmd,
      confidence: command.confidence,
      implicit: command.implicit,
    );
  }

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async {
    ran.add(match.commandId);
    return AssistantResponse(
      message: 'Сейф: ${match.commandId}',
      intent: match.commandId,
      status: AssistantStatus.completed,
    );
  }
}

/// Сетевое подключение, которое ничего не берёт, но запоминает каждую
/// фразу, которую ему показали.
final class _Network implements Connector {
  final List<String> seen = <String>[];

  @override
  ConnectorInfo get info => const ConnectorInfo(
        id: 'net',
        title: 'Сеть',
        description: 'Тест.',
        requiresNetwork: true,
      );

  @override
  ConnectorMatch? match(Utterance utterance) {
    seen.add(utterance.original);
    return null;
  }

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) =>
      throw StateError('не должен запускаться');
}

void main() {
  late _Clock clock;
  late _Passwords passwords;
  late _Network network;
  late AssistantController assistant;

  void build({bool passwordsOn = true}) {
    clock = _Clock(DateTime(2026, 11, 13, 12));
    passwords = _Passwords();
    network = _Network();
    final registry = ExtensionRegistry(
      connectors: <Connector>[
        network,
        const CalculatorConnector(),
        TalkConnector(),
        passwords,
        const DataConnector(),
      ],
      choice: ExtensionChoice(
        enabled: <String>{if (passwordsOn) 'passwords'},
      ),
    );
    assistant = AssistantController(extensions: registry, clock: clock);
  }

  setUp(build);

  group('уточняющий вопрос', () {
    test('«сделай бэкап» — вопрос с вариантами, а не «не понял»', () async {
      final response = await assistant.handle('сделай бэкап');

      expect(response.replyId, 'data.clarify.backup');
      expect(response.message, 'Копию чего: паролей или всех данных?');
      expect(response.status, AssistantStatus.needsClarification);
      final clarification = response.clarification!;
      expect(
        clarification.options.map((ClarifyOption o) => o.label),
        <String>['Пароли', 'Все данные'],
      );
      expect(identical(assistant.pendingClarification, clarification), isTrue);
    });

    test('«Пароли» — копия сейфа; вопрос снят', () async {
      await assistant.handle('сделай бэкап');
      final response = await assistant.handle('Пароли');

      expect(passwords.ran, <String>['passwords.backup']);
      expect(response.intent, 'passwords.backup');
      expect(assistant.pendingClarification, isNull);
    });

    test('кнопка — то же, что набранная подпись', () async {
      final asked = await assistant.handle('восстанови из копии');
      final label = asked.clarification!.options.first.label;
      // Кнопка отправляет свою подпись обычным сообщением.
      await assistant.handle(label);

      expect(passwords.ran, <String>['passwords.restore']);
    });

    test('слово варианта: «копию паролей», «давай сейф»', () async {
      await assistant.handle('сделай бэкап');
      await assistant.handle('копию паролей');
      await assistant.handle('открой хранилище');
      await assistant.handle('давай сейф');

      expect(passwords.ran, <String>['passwords.backup', 'passwords.open']);
    });

    test('«второе» — все данные', () async {
      await assistant.handle('сделай бэкап');
      final response = await assistant.handle('второе');

      expect(response.intent, 'data.backup');
      expect(response.message, contains('«Данные и резервная копия»'));
      expect(passwords.ran, isEmpty);
    });

    test('«все данные» и «2»', () async {
      await assistant.handle('восстанови из бэкапа');
      expect((await assistant.handle('все данные')).intent, 'data.restore');
      // Только что говорили о данных — следующий вопрос не нужен; новый
      // разговор.
      build();
      await assistant.handle('открой хранилище');
      expect((await assistant.handle('2')).intent, 'data.open');
    });

    test('«да» — не выбор: переспрос с теми же вариантами', () async {
      final asked = await assistant.handle('сделай бэкап');
      final again = await assistant.handle('да');

      expect(again.replyId, 'common.clarify.unclear');
      expect(again.message, contains('«Пароли» или «Все данные»'));
      expect(again.status, AssistantStatus.needsClarification);
      expect(identical(again.clarification, asked.clarification), isTrue);
      expect(passwords.ran, isEmpty);

      // Вопрос в силе.
      await assistant.handle('пароли');
      expect(passwords.ran, <String>['passwords.backup']);
    });

    test('«хорошо» — тоже переспрос, вопрос в силе', () async {
      await assistant.handle('сделай бэкап');
      final again = await assistant.handle('хорошо');

      expect(again.replyId, 'common.clarify.unclear');
      expect(assistant.pendingClarification, isNotNull);
    });

    test('«нет» — отмена, ничего не делается', () async {
      await assistant.handle('сделай бэкап');
      final response = await assistant.handle('нет');

      expect(response.replyId, 'common.clarify.cancelled');
      expect(response.status, AssistantStatus.noAction);
      expect(assistant.pendingClarification, isNull);
      expect(passwords.ran, isEmpty);
    });

    test('посторонняя команда снимает вопрос и выполняется', () async {
      await assistant.handle('сделай бэкап');
      final response = await assistant.handle('сколько будет 2+2');

      expect(response.intent, CalculatorConnector.commandId);
      expect(assistant.pendingClarification, isNull);
      // «Пароли» теперь — обычная фраза, а не ответ.
      expect((await assistant.handle('второе')).intent, isNot('data.backup'));
    });

    test('вопрос с обоими вариантами или отрицанием — не выбор', () async {
      await assistant.handle('сделай бэкап');
      final both = await assistant.handle('и пароли, и все данные');
      expect(both.intent, isNot('passwords.backup'));
      expect(passwords.ran, isEmpty);

      await assistant.handle('сделай бэкап');
      await assistant.handle('не пароли');
      expect(passwords.ran, isEmpty);
    });

    test('смена чата снимает вопрос', () async {
      await assistant.handle('сделай бэкап');
      assistant.enterChat(sessionId: 's2');

      expect(assistant.pendingClarification, isNull);
      await assistant.handle('пароли');
      expect(passwords.ran, isNot(contains('passwords.backup')));
    });

    test('навык «Пароли» выключен — без вопроса, про все данные', () async {
      build(passwordsOn: false);
      final response = await assistant.handle('сделай бэкап');

      expect(response.intent, 'data.backup');
      expect(response.clarification, isNull);
      expect(assistant.pendingClarification, isNull);
    });

    test('выбранный вариант не показывается сетевому подключению', () async {
      await assistant.handle('сделай бэкап');
      await assistant.handle('пароли');

      expect(passwords.ran, <String>['passwords.backup']);
      // Каноническая фраза о сейфе — фраза о паролях (раздел 5.9).
      expect(network.seen, isNot(contains('сделай резервную копию сейфа')));
      expect(
        network.seen.where((String t) => t.contains('сейф')),
        isEmpty,
      );
    });

    test('в вариантах — только шаблоны, не фраза пользователя', () async {
      // Пароль с подсказкой «пароль» скрывает SecretGuard — до коннекторов
      // он не доходит. Слово-канарейка без такой подсказки — обычный
      // текст фразы, но и оно не попадает в варианты.
      for (final text in <String>[
        'сделай копию хранилища, пароль ${Canary.password}',
        'Лиорио, открой хранилище ${Canary.note}',
        'сделай бэкап ${Canary.hint}',
      ]) {
        final response = await assistant.handle(text);
        for (final secret in <String>[...Canary.secrets, Canary.hint]) {
          expect(response.message, isNot(contains(secret)), reason: text);
          for (final option
              in response.clarification?.options ?? const <ClarifyOption>[]) {
            expect(option.text, isNot(contains(secret)), reason: text);
            expect(option.label, isNot(contains(secret)), reason: text);
          }
        }
        assistant.enterChat(sessionId: text);
      }
    });
  });

  group('новая просьба после вопроса — не выбор варианта', () {
    // Слово варианта («пароль», «все», «данные», «сейф») внутри другой
    // команды не делает её ответом: вопрос снимается, фраза разбирается
    // как обычно.
    for (final (name, text) in <(String, String)>[
      for (final t in <String>[
        'покажи пароль от почты',
        'удали пароль почты',
        'смени пароль от почты',
        'пароль от почты',
        'какой пароль от почты',
        'закрой сейф',
        'пароли qwerty12',
        'удали все данные',
        'покажи задачи',
        'покажи все задачи',
        'хорошо, все',
      ])
        (t, t),
      // Имя теста — без значения секрета.
      ('мой пароль <канарейка>', 'мой пароль ${Canary.password}'),
    ]) {
      test(name, () async {
        await assistant.handle('сделай бэкап');
        final response = await assistant.handle(text);

        expect(response.intent, isNot('passwords.backup'), reason: text);
        expect(response.intent, isNot('data.backup'), reason: text);
        expect(passwords.ran, isNot(contains('passwords.backup')));
        expect(response.message, isNot(contains(Canary.password)));
      });
    }

    test('«закрой сейф» после вопроса запирает сейф', () async {
      await assistant.handle('сделай бэкап');
      await assistant.handle('закрой сейф');

      expect(passwords.ran, <String>['passwords.lock']);
      expect(assistant.pendingClarification, isNull);
    });
  });

  group('контекст сессии', () {
    test('после разговора о паролях «сделай бэкап» — копия сейфа', () async {
      await assistant.handle('открой сейф');
      final response = await assistant.handle('сделай бэкап');

      expect(passwords.ran, <String>['passwords.open', 'passwords.backup']);
      expect(response.message, startsWith('Понял как копию паролей.'));
      expect(response.clarification, isNull);
      expect(assistant.recentConnectorId, 'passwords');
    });

    test('«хранилище» после паролей — сейф', () async {
      await assistant.handle('запри сейф');
      final response = await assistant.handle('открой хранилище');

      expect(passwords.ran, <String>['passwords.lock', 'passwords.open']);
      expect(response.message, startsWith('Понял: речь о сейфе с паролями.'));
    });

    test('беседа между ними контекст не сбивает', () async {
      await assistant.handle('открой сейф');
      await assistant.handle('спасибо');
      await assistant.handle('сделай бэкап');

      expect(passwords.ran.last, 'passwords.backup');
    });

    test('после разговора о данных — без вопроса', () async {
      await assistant.handle('открой данные приложения');
      final response = await assistant.handle('сделай бэкап');

      expect(response.intent, 'data.backup');
      expect(response.clarification, isNull);
    });

    test('другая команда меняет тему', () async {
      await assistant.handle('открой сейф');
      await assistant.handle('сколько будет 2+2');
      expect(assistant.recentConnectorId, 'calc');
      final response = await assistant.handle('сделай бэкап');

      expect(response.replyId, 'data.clarify.backup');
    });

    test('окно — два сообщения: третье уже спрашивает', () async {
      await assistant.handle('открой сейф');
      // Беседа тему не меняет, но сообщения считаются.
      await assistant.handle('спасибо');
      expect(assistant.recentConnectorId, 'passwords');
      await assistant.handle('привет');
      final response = await assistant.handle('сделай бэкап');

      expect(response.replyId, 'data.clarify.backup');
    });

    test('окно — не дольше 10 минут', () async {
      await assistant.handle('открой сейф');
      clock.value = clock.value.add(
        AssistantController.contextWindow + const Duration(minutes: 1),
      );
      final response = await assistant.handle('сделай бэкап');

      expect(response.replyId, 'data.clarify.backup');
      expect(passwords.ran, <String>['passwords.open']);
    });

    test('смена чата снимает контекст и «предыдущий коннектор»', () async {
      await assistant.handle('открой сейф');
      assistant.enterChat(sessionId: 's2');

      expect(assistant.recentConnectorId, isNull);
      expect(assistant.session.lastConnectorId, isNull);
      final response = await assistant.handle('сделай бэкап');
      expect(response.replyId, 'data.clarify.backup');
    });

    test('«не понял» снимает контекст', () async {
      await assistant.handle('открой сейф');
      await assistant.handle('абракадабра');
      final response = await assistant.handle('сделай бэкап');

      expect(response.replyId, 'data.clarify.backup');
    });

    test('уточняющий вопрос — тема не выбрана, контекста нет', () async {
      await assistant.handle('сделай бэкап');

      expect(assistant.recentConnectorId, isNull);
      // Повтор той же фразы — снова вопрос, а не «все данные».
      final again = await assistant.handle('сделай бэкап');
      expect(again.replyId, 'data.clarify.backup');
    });

    test('явный объект важнее контекста', () async {
      await assistant.handle('открой сейф');
      final response = await assistant.handle(
        'сделай резервную копию всех данных',
      );

      expect(response.intent, 'data.backup');
      expect(passwords.ran, <String>['passwords.open']);
    });

    test('навык «Пароли» выключили — контекст не ведёт в выключенный',
        () async {
      await assistant.handle('открой сейф');
      assistant.extensions.apply(const ExtensionChoice());
      final response = await assistant.handle('сделай бэкап');

      expect(response.intent, 'data.backup');
      expect(passwords.ran, <String>['passwords.open']);
    });
  });
}
