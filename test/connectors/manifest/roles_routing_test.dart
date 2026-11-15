import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/manifest/connection.dart';
import 'package:local_assistant/core/connectors/manifest/manifest_connector.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/personas/persona.dart';
import 'package:local_assistant/core/replies/reply_catalog.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import '../fakes.dart';
import 'fixtures.dart';

/// Заведомо поддельные значения: настоящих секретов в тестах нет.
const String fakeToken = 'fake-token-not-real';
const String fakeSid = 'fake-sid-not-real';

final DateTime now = DateTime(2026, 11, 2, 16, 30);

HttpResponseData _fixture(String name) => HttpResponseData(
      statusCode: 200,
      body: File('test/fixtures/assistant/responses/$name.json')
          .readAsStringSync(),
    );

final class _Setup {
  _Setup({bool connected = true, ExtensionChoice? choice}) {
    final clock = FixedClock(now);
    tasks = TaskService(
      repository: InMemoryTaskRepository(),
      clock: clock,
    );
    transport = FakeHttpTransport(
      (HttpRequestData r) => switch (r.uri.queryParameters['action']) {
        'ask_arrivals' => _fixture('ask_arrivals_today'),
        _ => _fixture('ask_stock_sku'),
      },
    );
    secrets = InMemorySecretStore(<String, String>{
      if (connected) 'warehouse.token': fakeToken,
      if (connected) 'warehouse.sid': fakeSid,
    });
    warehouse = warehouseConnector(
      path: patchedManifestPath,
      transport: transport,
      secrets: secrets,
      record: connected ? connectedRecord() : null,
    );
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
      choice: choice ??
          const ExtensionChoice(enabledRoles: <String>{Roles.storekeeperId}),
    );
    assistant = AssistantController(extensions: registry, clock: clock);
  }

  late final TaskService tasks;
  late final FakeHttpTransport transport;
  late final InMemorySecretStore secrets;
  late final ManifestConnector warehouse;
  late final ExtensionRegistry registry;
  late final AssistantController assistant;

  Future<AssistantResponse> say(
    String text, {
    String? addressee,
    String? chatTaskId,
  }) =>
      assistant.handle(text, addressee: addressee, chatTaskId: chatTaskId);

  void role(String id, bool on) =>
      registry.apply(registry.roleChoiceWith(id, on));
}

void main() {
  group('«Кладовщик» включён, склад подключён', () {
    test('голый артикул — «где лежит», «сегодня» и «вчера» — приходы',
        () async {
      final s = _Setup();
      expect((await s.say('64115')).intent, 'warehouse.where');
      expect((await s.say('где лежит 64115')).intent, 'warehouse.where');
      expect((await s.say('сегодня')).intent, 'warehouse.today');
      expect((await s.say('вчера')).intent, 'warehouse.yesterday');
      expect(
        s.transport.requests.map((r) => r.uri.queryParameters['action']),
        <String>['ask_stock', 'ask_stock', 'ask_arrivals', 'ask_arrivals'],
      );
    });

    test('задачи, калькулятор и беседа не меняются', () async {
      final s = _Setup();
      final task = await s.say('Добавь задачу купить хлеб');
      expect(task.intent, 'task.create');
      expect((await s.say('сколько будет 2+2')).intent, 'calc.evaluate');
      expect((await s.say('привет')).intent, TalkConnector.greetCommand);
      expect(
        (await s.say('Добавь задачу сверить приход на сегодня')).intent,
        'task.create',
      );
      expect(s.transport.requests, isEmpty);
    });
  });

  group('«Кладовщик» выключен', () {
    test('подключённый склад не отвечает вовсе', () async {
      final s = _Setup(choice: const ExtensionChoice());
      for (final text in <String>['64115', 'где лежит 64115', 'сегодня']) {
        final response = await s.say(text);
        expect(response.intent, isNot(startsWith('warehouse.')), reason: text);
      }
      expect(s.transport.requests, isEmpty);
      expect((await s.say('Добавь задачу купить хлеб')).intent, 'task.create');
      expect((await s.say('2+2')).intent, 'calc.evaluate');
    });

    test('снова включённая роль работает без нового входа', () async {
      final s = _Setup();
      s.role(Roles.storekeeperId, false);
      expect((await s.say('где лежит 64115')).intent, isNot('warehouse.where'));
      expect(await s.secrets.read('warehouse.token'), fakeToken);
      expect(s.warehouse.record.connected, isTrue);
      s.role(Roles.storekeeperId, true);
      final again = await s.say('где лежит 64115');
      expect(again.intent, 'warehouse.where');
      expect(again.status, AssistantStatus.completed);
    });
  });

  group('склад не подключён', () {
    test(
        'фраза склада — подсказка «Мой Связной → Помощники → Роли», не «не понял»',
        () async {
      final s = _Setup(connected: false);
      for (final text in <String>['где лежит 64115', '64115', 'без фото']) {
        final response = await s.say(text);
        expect(response.replyId, 'role.notConnected', reason: text);
        expect(response.status, AssistantStatus.noAction);
        expect(
          response.message,
          'Склад ещё не подключён — Мой Связной → Помощники → Роли → Кладовщик → '
          'Подключить склад.',
        );
      }
      // Без подключения «сегодня» — не приходы.
      expect((await s.say('сегодня')).intent, isNot('warehouse.today'));
      expect(s.transport.requests, isEmpty);
    });
  });

  group('кто ведёт расширения', () {
    // Склад — расширение: без обращения отвечает ведущий расширений
    // (ADR-016). Здесь расширения переназначены Ноде.
    _Setup noda() {
      final s = _Setup();
      s.assistant.personas = const PersonaSettings(dutyExtensions: 'noda');
      return s;
    }

    test('по умолчанию склад — от Лиорио, остальное — от Связной', () async {
      final s = _Setup();
      expect((await s.say('где лежит 64115')).personaId, 'rio');
      expect(s.assistant.working('где лежит 64115').personaId, 'rio');
      expect((await s.say('Добавь задачу купить хлеб')).personaId, 'sado');
      expect((await s.say('2+2')).personaId, 'sado');
      expect((await s.say('привет')).personaId, 'sado');
      expect(s.assistant.working('2+2').personaId, 'sado');
    });

    test('прежний выбор «Кладовщика ведёт Нода» на ответы не влияет', () async {
      final s = _Setup(
        choice: const ExtensionChoice(
          enabledRoles: <String>{Roles.storekeeperId},
          roleOwners: <String, String>{Roles.storekeeperId: 'noda'},
        ),
      );
      expect((await s.say('где лежит 64115')).personaId, 'rio');
    });

    test('расширения переназначены Ноде — склад от неё', () async {
      final s = noda();
      expect((await s.say('где лежит 64115')).personaId, 'noda');
      expect(s.assistant.working('где лежит 64115').personaId, 'noda');
      expect((await s.say('Добавь задачу купить хлеб')).personaId, 'sado');
    });

    test('обращение по имени и адресат в поле ввода важнее', () async {
      final s = noda();
      final named = await s.say('Лиорио, где лежит 64115');
      expect(named.intent, 'warehouse.where');
      expect(named.personaId, 'rio');
      final chosen = await s.say('где лежит 64115', addressee: 'rio');
      expect(chosen.personaId, 'rio');
      expect(
        s.assistant.working('где лежит 64115', addressee: 'rio').personaId,
        'rio',
      );
      final sado = await s.say('Связной, где лежит 64115');
      expect(sado.personaId, 'sado');
    });

    test('голос ведущего: стиль Ноды (дружеский)', () async {
      final s = _Setup(connected: false);
      s.assistant.personas = const PersonaSettings(dutyExtensions: 'noda');
      final response = await s.say('64115');
      expect(response.personaId, 'noda');
      expect(response.replyId, 'role.notConnected');
      expect(
        response.message,
        contains('загляните в Мой Связной → Помощники → Роли'),
      );
    });

    test('дуэт с Нодой — склад у Связной, зона Лиорио вернулась к нему',
        () async {
      final s = _Setup();
      s.assistant.personas =
          const PersonaSettings(teamMode: TeamMode.duo, duoHelper: 'noda');
      expect((await s.say('где лежит 64115')).personaId, 'sado');
      expect(s.assistant.working('где лежит 64115').personaId, 'sado');
      // Имя выключенного помощника — просто текст.
      expect((await s.say('Лиорио, где лежит 64115')).personaId, 'sado');
    });

    test('соло — всё делает Связной', () async {
      final s = noda();
      s.assistant.personas = const PersonaSettings(teamMode: TeamMode.solo);
      expect((await s.say('где лежит 64115')).personaId, 'sado');
    });
  });

  group('самоописание', () {
    test('«кто ты» и «что умеешь» говорят о складе', () async {
      final s = _Setup();
      final who = await s.say('кто ты');
      expect(who.message, endsWith('Сейчас помогаю с задачами и со складом.'));
      final can = await s.say('что ты умеешь');
      expect(can.message, contains('«Склад» — например'));
      expect(can.message, startsWith('Помогаю с задачами и со складом.'));
    });

    test('только «Личное» — прежний текст', () async {
      final s = _Setup(choice: const ExtensionChoice());
      final who = await s.say('кто ты');
      expect(who.message, isNot(contains('Сейчас помогаю')));
      final can = await s.say('что ты умеешь');
      expect(can.message, isNot(contains('Склад')));
    });
  });

  group('«Кому:» важнее ведущего расширений — и Связной тоже', () {
    _Setup noda() {
      final s = _Setup();
      s.assistant.personas = const PersonaSettings(dutyExtensions: 'noda');
      return s;
    }

    const main = AssistantController.mainAddressee;

    test('явно выбранный главный отвечает на фразы расширений', () async {
      final s = noda();
      // Никого не выбрали — отвечает ведущая расширений.
      expect((await s.say('64115')).personaId, 'noda');
      // Выбрали главного в «Кому:» — отвечает Связной, и «обрабатывается…»
      // звучит его голосом.
      for (final text in <String>['Без фото', '64115', 'где лежит 64115']) {
        expect(
          (await s.say(text, addressee: main)).personaId,
          'sado',
          reason: text,
        );
        expect(
          s.assistant.working(text, addressee: main).personaId,
          'sado',
          reason: text,
        );
      }
    });

    test('«главный» — Связной в любом режиме', () async {
      final s = noda();
      s.assistant.personas =
          const PersonaSettings(teamMode: TeamMode.duo, duoHelper: 'noda');
      expect((await s.say('2+2', addressee: main)).personaId, 'sado');
      expect(AssistantController.isExplicitAddressee(main), isTrue);
      expect(AssistantController.isExplicitAddressee('rio'), isTrue);
      expect(AssistantController.isExplicitAddressee(null), isFalse);
      expect(AssistantController.isExplicitAddressee('кто-то'), isFalse);
    });

    test('без имени: зона главного — Связной, расширения — их ведущий',
        () async {
      final plain = _Setup();
      expect((await plain.say('64115')).personaId, 'rio');
      for (final text in <String>['2+2', 'привет', 'покажи задачи']) {
        expect((await plain.say(text)).personaId, 'sado', reason: text);
      }
      // Расширения ведёт Связной (дуэт с Нодой): он отвечает на всё.
      final duo = _Setup();
      duo.assistant.personas =
          const PersonaSettings(teamMode: TeamMode.duo, duoHelper: 'noda');
      expect(duo.registry.mainLeadsAll(duo.assistant.personas), isTrue);
      expect(plain.registry.mainLeadsAll(plain.assistant.personas), isFalse);
      for (final text in <String>['64115', '2+2', 'привет']) {
        expect((await duo.say(text)).personaId, 'sado', reason: text);
      }
    });

    test(
        'к кому обратились, тот и продолжает тем же навыком — и Связной '
        'при чужой зоне', () async {
      final s = noda();
      expect((await s.say('Лиорио, где лежит 64115')).personaId, 'rio');
      expect(
        s.assistant.followUpPersonaId,
        'rio',
        reason: 'иначе «64115» забрала бы Нода',
      );
      // Тот же навык склада — продолжает Лиорио, и «обрабатывается…» —
      // его голосом.
      expect(s.assistant.working('а 64116?').personaId, 'rio');
      expect((await s.say('64116')).personaId, 'rio');
      // Другой навык — продолжение снято, склад снова у ведущей.
      expect((await s.say('2+2')).personaId, 'sado');
      expect(s.assistant.followUpPersonaId, isNull);
      expect((await s.say('64115')).personaId, 'noda');
      expect((await s.say('Связной, где лежит 64115')).personaId, 'sado');
      expect(s.assistant.followUpPersonaId, 'sado');
      expect((await s.say('64116')).personaId, 'sado');
      // Расширения ведёт сам Связной: обращение к нему ничего не продолжает.
      final duo = _Setup();
      duo.assistant.personas = const PersonaSettings(teamMode: TeamMode.solo);
      await duo.say('Связной, 2+2');
      expect(duo.assistant.followUpPersonaId, isNull);
    });

    test(
        'продолжение короткое: после ${AssistantController.followUpLimit} '
        'фраз без имени — снова ведущий расширений', () async {
      final s = noda();
      final who = <String?>[
        (await s.say('Лиорио, где лежит 64115')).personaId,
        for (var n = 64116; n <= 64120; n++)
          (await s.say('где лежит $n')).personaId,
      ];
      // Обратились к Лиорио — он и ещё две фразы того же навыка; дальше
      // склад снова у Ноды, хотя навык не менялся.
      expect(who, <String?>['rio', 'rio', 'rio', 'noda', 'noda', 'noda']);
      expect(s.assistant.followUpPersonaId, isNull);
      // Новое обращение по имени — новое короткое продолжение.
      expect((await s.say('Лиорио, где лежит 64121')).personaId, 'rio');
      expect((await s.say('где лежит 64122')).personaId, 'rio');
    });
  });

  group('навык выключен в «Расширениях», роль включена', () {
    _Setup off() => _Setup(
          choice: const ExtensionChoice(
            enabledRoles: <String>{Roles.storekeeperId},
            disabled: <String>{'warehouse'},
          ),
        );

    test('кнопки склада скрыты, самоописание о складе молчит', () async {
      final s = off();
      expect(s.registry.isRoleEnabled(Roles.storekeeperId), isTrue);
      expect(s.registry.isEnabled('warehouse'), isFalse);
      expect(s.registry.activeChips, isEmpty);
      expect(s.registry.helpsWith, 'с задачами');
      expect(
        s.registry.switchedOff(Roles.storekeeper).map((e) => e.id),
        <String>['warehouse'],
      );
      final who = await s.say('кто ты');
      expect(who.message, isNot(contains('склад')));
      final can = await s.say('что ты умеешь');
      expect(can.replyId, 'talk.capabilities');
      expect(can.message, isNot(contains('Склад')));
      expect(can.message, isNot(contains('со складом')));
    });

    test('включили обратно — кнопки и самоописание вернулись', () async {
      final s = off();
      s.registry.apply(s.registry.choiceWith('warehouse', true));
      expect(
        s.registry.activeChips.map((RoleChip c) => c.label),
        <String>['Где лежит…', 'Что пришло сегодня', 'Без фото'],
      );
      expect(s.registry.helpsWith, 'с задачами и со складом');
      expect(s.registry.switchedOff(Roles.storekeeper), isEmpty);
    });

    test('без «Личного» и без склада о ролях сказать нечего', () async {
      final s = _Setup(
        choice: const ExtensionChoice(
          enabledRoles: <String>{Roles.storekeeperId},
          disabledRoles: <String>{Roles.personalId},
          disabled: <String>{'warehouse'},
        ),
      );
      expect(s.registry.helpsWith, isEmpty);
      expect((await s.say('кто ты')).message, isNot(contains('помогаю')));
    });
  });

  group('одно название навыка склада', () {
    test('«что умеешь» называет склад так же, как «Расширения»', () async {
      final s = _Setup();
      final title = s.registry.info('warehouse')!.title;
      expect(title, 'Склад');
      expect(s.registry.skillTitle('warehouse'), title);
      final can = await s.say('что ты умеешь');
      expect(can.message, contains('«$title» — например'));
      expect(can.message, isNot(contains('Складские вопросы')));
    });
  });

  group('«сегодня» и «вчера»: задачи важнее подсказки склада', () {
    Future<(_Setup, String)> withTask() async {
      final s = _Setup();
      final task = await s.tasks.create(
        title: 'Отчёт за квартал',
        dueAt: DateTime(2026, 11, 5, 10),
      );
      return (s, task.id);
    }

    test('в чате задачи голое слово переносит задачу', () async {
      for (final text in <String>[
        'сегодня',
        'Сегодня.',
        'сегодня!',
        'ну сегодня',
        'сегодня пожалуйста',
        'пожалуйста сегодня',
      ]) {
        final (s, id) = await withTask();
        s.assistant.enterChat(taskId: id);
        final response = await s.say(text, chatTaskId: id);
        expect(response.intent, 'task.reschedule', reason: text);
        final task = (await s.tasks.listActive()).single;
        expect(task.dueAt!.day, 2, reason: text);
        expect(s.transport.requests, isEmpty, reason: text);
      }
    });

    test('в главном чате подсказка действует по-прежнему', () async {
      final (s, _) = await withTask();
      expect((await s.say('сегодня')).intent, 'warehouse.today');
      expect((await s.say('вчера')).intent, 'warehouse.yesterday');
    });

    test('ответ на вопрос помощника — не вопрос складу', () async {
      final (s, _) = await withTask();
      final question = await s.say('перенеси отчёт за квартал');
      expect(question.status, AssistantStatus.needsClarification);
      final answer = await s.say('сегодня');
      expect(answer.intent, isNot(startsWith('warehouse.')));
      expect(s.transport.requests, isEmpty);
      // Вопрос позади: следующее «сегодня» — снова приходы.
      expect((await s.say('сегодня')).intent, 'warehouse.today');
    });

    test('пока помощник ждёт «да» или «нет», «сегодня» — не приходы', () async {
      final s = _Setup();
      await s.tasks.create(title: 'Купить хлеб');
      final question = await s.say('я купил хлеб');
      expect(s.assistant.session.pendingConfirmation, isNotNull);
      expect(question.status, AssistantStatus.needsClarification);
      expect((await s.say('вчера')).intent, isNot(startsWith('warehouse.')));
      expect(s.transport.requests, isEmpty);
    });

    test('разбор: в чате задачи и после вопроса склад слово не берёт', () {
      final s = _Setup();
      final plain = Utterance.analyze('сегодня', now: now);
      expect(s.warehouse.match(plain)?.commandId, 'warehouse.today');
      expect(s.warehouse.match(plain.withChat('t1')), isNull);
      expect(
        s.warehouse.match(plain.withChat(null, awaitingAnswer: true)),
        isNull,
      );
      // С обращением — всегда склад.
      final aliased = Utterance.analyze('склад, сегодня', now: now);
      expect(
        s.warehouse.match(aliased.withChat('t1'))?.commandId,
        'warehouse.today',
      );
    });
  });

  group('«как дела» при неподключённом складе', () {
    test('не сбой и не жалоба — короткая подсказка, где подключить', () async {
      final s = _Setup(connected: false);
      final response = await s.say('как дела');
      expect(response.intent, TalkConnector.howAreYouCommand);
      expect(response.status, AssistantStatus.completed);
      expect(response.replyId, 'talk.status.okPending');
      expect(s.assistant.session.pendingConfirmation, isNull);
      expect(response.message, isNot(contains('жалоб')));
      expect(response.message, isNot(contains('не работает')));
      expect(response.message, isNot(contains('все навыки и подключения')));
      expect(
        response.message,
        endsWith(
          'Склад ещё не подключён — Мой Связной → Помощники → Роли → Кладовщик → '
          'Подключить склад.',
        ),
      );
      // «да» после этого — не согласие на жалобу.
      final yes = await s.say('да');
      expect(yes.intent, isNot(TalkConnector.complaintCommand));
    });

    test('после «Выйти» (адрес остался) — так же', () async {
      final s = _Setup(connected: false);
      s.warehouse.record = connectedRecord().copyWith(
        level: ConnectionLevel.none,
        clearLogin: true,
      );
      final response = await s.say('как дела');
      expect(response.status, AssistantStatus.completed);
      expect(s.assistant.session.pendingConfirmation, isNull);
    });

    test('только «Личное» — обычное «всё в порядке»', () async {
      final s = _Setup(connected: false, choice: const ExtensionChoice());
      final response = await s.say('как дела');
      expect(response.replyId, 'talk.status.ok');
      expect(response.message, isNot(contains('Склад')));
    });

    test('настоящий сбой подключённого склада — по-прежнему проблема',
        () async {
      final s = _Setup();
      s.warehouse.record = connectedRecord().copyWith(
        failure: ConnectionFailure.offline,
        failureSince: now,
      );
      final response = await s.say('как дела');
      expect(response.status, AssistantStatus.needsClarification);
      expect(response.message, contains('«Склад» не работает'));
      expect(s.assistant.session.pendingConfirmation, isNotNull);
    });
  });

  group('«Где лежит…» без артикула', () {
    test('кнопка и сразу «Отправить» — вопрос, что искать, без запроса',
        () async {
      final s = _Setup();
      final chip = s.registry.activeChips.first;
      expect(chip.label, 'Где лежит…');
      final text = chip.text.replaceAll('|', '');
      for (final phrase in <String>[
        text,
        'где лежит',
        'Где лежит?',
        'подскажи, где лежит',
        'сколько осталось',
        'склад, найди',
      ]) {
        final response = await s.say(phrase);
        expect(response.replyId, 'warehouse.ask', reason: phrase);
        expect(response.status, AssistantStatus.needsClarification);
        expect(
          response.message,
          startsWith('Уточните, что искать: артикул или название.'),
          reason: phrase,
        );
      }
      expect(s.transport.requests, isEmpty, reason: '«лежит» не ищем');
      // Ответ артикулом — обычный поиск.
      final found = await s.say('64115');
      expect(found.intent, 'warehouse.where');
      expect(s.transport.requests, hasLength(1));
    });

    test('полные фразы и однословные начала не задеты', () async {
      final s = _Setup();
      expect((await s.say('где лежит стул')).replyId, isNot('warehouse.ask'));
      expect((await s.say('где стул')).intent, 'warehouse.where');
      expect((await s.say('сколько пришло')).intent, 'warehouse.today');
      // «где» и «найди» без обращения — слишком общие слова.
      for (final phrase in <String>['где', 'найди', 'сколько']) {
        expect(
          (await s.say(phrase)).replyId,
          isNot('warehouse.ask'),
          reason: phrase,
        );
      }
    });

    test('не подключён — подсказка, где подключить', () async {
      final s = _Setup(connected: false);
      expect((await s.say('Где лежит ')).replyId, 'role.notConnected');
    });
  });

  group('тексты «что умеешь» и «кто ты» с ролью', () {
    // Тот же набор, что запрещён каталогу вне меток {э:…}.
    final emoji = ReplyTemplate.pictographs;
    final quoted = RegExp('«[^»]*»');
    final sentenceEnd = RegExp(r'(?<=[.!?…])\s+');
    final leading = RegExp(r'^[^\p{L}]+', unicode: true);

    /// Первые слова предложений: без названий и примеров в кавычках.
    List<String> starts(String message) => <String>[
          for (final part
              in message.replaceAll(quoted, '«»').split(sentenceEnd))
            if (part.replaceFirst(leading, '').isNotEmpty)
              part
                  .replaceFirst(leading, '')
                  .split(RegExp(r'[\s,:—]'))
                  .first
                  .toLowerCase(),
        ];

    for (final style in ReplyStyles.builtIn) {
      for (final persona in <String>['rio', 'sado']) {
        test('$style, $persona: путь в «Роли», один смайлик, без повторов',
            () async {
          final s = _Setup();
          s.assistant.personas = PersonaSettings(
            // Связной отвечает без обращения в Соло.
            teamMode: persona == 'sado' ? TeamMode.solo : TeamMode.trio,
            styles: <String, String>{
              'sado': style,
              'rio': style,
              'noda': style,
            },
          );
          final can = await s.say('что ты умеешь');
          expect(can.replyId, 'talk.capabilities.roles');
          expect(can.message, contains('с задачами и со складом'));
          expect(can.message, contains('«Мой Связной → Помощники → Роли»'));
          expect(can.message, contains('«Настройки → Расширения»'));
          expect(
            can.message.indexOf('«Мой Связной → Помощники → Роли»'),
            lessThan(can.message.indexOf('«Настройки → Расширения»')),
            reason: 'сначала роли, расширения — для точной настройки',
          );
          final who = await s.say('кто ты');
          expect(who.message, contains('с задачами и со складом'));
          for (final message in <String>[can.message, who.message]) {
            expect(
              emoji.allMatches(message).length,
              lessThanOrEqualTo(1),
              reason: message,
            );
            final first = starts(message);
            expect(first.toSet().length, first.length, reason: '$first');
          }
        });
      }

      test('$style: без роли сверх «Личного» — тоже путь в «Роли»', () async {
        final s = _Setup(choice: const ExtensionChoice());
        s.assistant.personas = PersonaSettings(
          styles: <String, String>{'rio': style, 'noda': style},
        );
        final can = await s.say('что ты умеешь');
        expect(can.replyId, 'talk.capabilities');
        expect(can.message, contains('«Мой Связной → Помощники → Роли»'));
        expect(can.message, contains('«Настройки → Расширения»'));
        expect(emoji.allMatches(can.message).length, lessThanOrEqualTo(1));
        final first = starts(can.message);
        expect(first.toSet().length, first.length, reason: '$first');
      });
    }
  });
}
