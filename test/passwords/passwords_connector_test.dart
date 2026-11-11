// Навык «Пароли» (ADR-014, этап 2): ответы, карточки, подтверждения и
// маршрутизация. Хранилище — настоящее (libsodium, тестовые параметры
// Argon2id, в памяти); пароли — только канарейки.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/models/secure_card.dart';
import 'package:local_assistant/core/passwords/vault.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_facade.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/passwords/passwords_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import 'vault_test_support.dart';

/// Сетевой коннектор-шпион: запоминает каждую фразу, которую ему дали.
final class _NetworkSpy implements Connector {
  final List<String> seen = <String>[];

  @override
  ConnectorInfo get info => const ConnectorInfo(
        id: 'spy',
        title: 'Шпион',
        description: 'Ходит в сеть.',
        requiresNetwork: true,
      );

  @override
  ConnectorMatch? match(Utterance utterance) {
    seen.add(utterance.original);
    return const ConnectorMatch(
      connectorId: 'spy',
      commandId: 'spy.any',
      confidence: 0.99,
    );
  }

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async =>
      session.reply(
        'common.unknown',
        values: const <String, String>{'example': 'x'},
        intent: 'spy',
        status: AssistantStatus.completed,
      );
}

void main() {
  late SodiumVaultCrypto crypto;

  setUpAll(() async {
    crypto = await testCrypto();
  });

  late Vault vault;
  late VaultFacade facade;
  late TaskService tasks;
  late ExtensionRegistry registry;
  late AssistantController assistant;
  late bool existed;

  Future<void> setUpWith({
    bool canCopy = true,
    bool enabled = true,
    List<Connector> extra = const <Connector>[],
  }) async {
    final clock = TestClock(DateTime.utc(2026, 11, 10, 9));
    vault = testVault(InMemoryVaultStore(), crypto, clock: clock);
    await vault.load();
    facade = VaultFacade(vault);
    existed = false;
    tasks = TaskService(
      repository: InMemoryTaskRepository(),
      clock: FixedClock(clock.value),
    );
    registry = ExtensionRegistry(
      connectors: <Connector>[
        TasksConnector(
          taskService: tasks,
          parser: ScenarioParser(clock: FixedClock(clock.value)),
        ),
        PasswordsConnector(
          vault: facade,
          canCopySecrets: canCopy,
          vaultExisted: () => existed,
        ),
        ...extra,
      ],
      choice: ExtensionChoice(
        enabled: <String>{if (enabled) PasswordsConnector.id},
      ),
    );
    vault.followExtension(registry, PasswordsConnector.id);
    assistant = AssistantController(
      extensions: registry,
      clock: FixedClock(clock.value),
      knownSecret: facade.knownSecret,
    );
  }

  Future<String> seed() async {
    await vault.create(secret(Canary.master), params: fastKdf);
    final id = await vault.addEntry(
      service: 'Почта',
      login: Canary.login,
      hint: Canary.hint,
      urls: const <String>['https://mail.example.org/login'],
      password: secret(Canary.password),
      note: secret(Canary.note),
    );
    await vault.addEntry(service: 'Форум', password: secret('CANARY-f-1'));
    return id;
  }

  void expectNoSecrets(AssistantResponse response) {
    for (final canary in <String>[
      Canary.password,
      Canary.note,
      Canary.master,
      'CANARY-f-1',
    ]) {
      expect(response.message, isNot(contains(canary)));
      expect(response.values.values.join(), isNot(contains(canary)));
    }
  }

  group('паспорт', () {
    test('навык вне ролей, выключен, с секретами, кнопки — через chips', () {
      final info = PasswordsConnector().info;
      expect(info.id, 'passwords');
      expect(info.kind, ExtensionKind.skill);
      expect(info.defaultEnabled, isFalse);
      expect(info.requiresNetwork, isFalse);
      expect(info.access, ConnectorAccess.readWrite);
      expect(info.sensitive, isTrue);
      expect(info.chips.map((RoleChip c) => c.label), <String>[
        'Подсказка к паролю…',
        'Открыть пароли',
      ]);
      expect(
        Roles.all.any((RoleInfo r) => r.extensions.contains(info.id)),
        isFalse,
      );
    });

    test('примеры распознаются', () {
      final connector = PasswordsConnector();
      for (final example in connector.info.examples) {
        final match = connector.match(
          Utterance.analyze(example, now: DateTime(2026, 11, 10)),
        );
        expect(match, isNotNull, reason: example);
        expect(match!.implicit, isFalse, reason: example);
      }
    });

    test('кнопки видны, только пока навык включён', () async {
      await setUpWith(enabled: false);
      expect(
        registry.activeChips.map((RoleChip c) => c.label),
        isNot(contains('Открыть пароли')),
      );
      registry.apply(registry.choiceWith(PasswordsConnector.id, true));
      expect(
        registry.activeChips.map((RoleChip c) => c.label),
        containsAll(<String>['Подсказка к паролю…', 'Открыть пароли']),
      );
    });
  });

  group('нет хранилища и заперто', () {
    test('не создано / не найдено на устройстве (D28)', () async {
      await setUpWith();
      var response = await assistant.handle('забыл пароль от почты');
      expect(response.replyId, 'passwords.notCreated');
      expect(response.secureCard?.kind, SecureCardKind.unlock);
      existed = true;
      response = await assistant.handle('забыл пароль от почты');
      expect(response.replyId, 'passwords.notFoundOnDevice');
    });

    test('заперто: карточка «Открыть» с командой для повтора', () async {
      await setUpWith();
      await seed();
      vault.lock();
      final response = await assistant.handle('забыл пароль от почты');
      expect(response.replyId, 'passwords.locked');
      final card = response.secureCard!;
      expect(card.kind, SecureCardKind.unlock);
      expect(card.resume, PasswordCommands.hint);
      expect(card.options['query'], 'почта');
      // После открытия карточка повторяет команду.
      await vault.unlock(secret(Canary.master));
      final resumed =
          await assistant.secureCardAction(card, SecureCardCommand.resume);
      expect(resumed!.replyId, 'passwords.hint.card');
      expect(resumed.secureCard!.kind, SecureCardKind.hint);
    });

    test('без libsodium — честно «недоступно»', () async {
      final registry = ExtensionRegistry(
        connectors: <Connector>[PasswordsConnector()],
        choice: const ExtensionChoice(enabled: <String>{'passwords'}),
      );
      final assistant = AssistantController(extensions: registry);
      final response = await assistant.handle('забыл пароль от почты');
      expect(response.replyId, 'passwords.unavailable');
    });
  });

  group('открытое хранилище', () {
    test('подсказка — в карточке, в истории только название', () async {
      await setUpWith();
      final id = await seed();
      final response = await assistant.handle('забыл пароль от почты');
      expect(response.replyId, 'passwords.hint.card');
      expect(response.secureCard!.kind, SecureCardKind.hint);
      expect(response.secureCard!.entryIds, <String>[id]);
      expect(response.message, contains('Почта'));
      expect(response.message, isNot(contains(Canary.hint)));
      expect(response.message, isNot(contains(Canary.login)));
      expectNoSecrets(response);
    });

    test('флаг «подсказки в истории» — подсказка в тексте', () async {
      await setUpWith();
      await seed();
      await vault.setPrefs(
        const <String, Object?>{'hints_in_history': true},
        master: secret(Canary.master),
      );
      final response = await assistant.handle('не помню пароль от почты');
      expect(response.replyId, 'passwords.hint.inline');
      expect(response.message, contains(Canary.hint));
      expectNoSecrets(response);
    });

    test('без своей подсказки — hint.none, карточка всё равно', () async {
      await setUpWith();
      await seed();
      final response = await assistant.handle('забыл пароль от форума');
      expect(response.replyId, 'passwords.hint.none');
      expect(response.secureCard!.kind, SecureCardKind.hint);
    });

    test('нет записи — как восстановить на сайте', () async {
      await setUpWith();
      await seed();
      final response = await assistant.handle('забыл пароль от госуслуг');
      expect(response.replyId, 'passwords.notFound.recover');
      expect(response.values['query'], 'Госуслуги');
    });

    test('несколько записей — карточка выбора, выбор повторяет команду',
        () async {
      await setUpWith();
      await seed();
      final other = await vault.addEntry(
        service: 'Gmail',
        password: secret('CANARY-g-2'),
      );
      final response = await assistant.handle('забыл пароль от почты');
      expect(response.replyId, 'passwords.choose');
      final card = response.secureCard!;
      expect(card.kind, SecureCardKind.choose);
      expect(card.entryIds, hasLength(2));
      final chosen = await assistant.secureCardAction(
        card,
        SecureCardCommand.choose,
        entryId: other,
      );
      expect(chosen!.replyId, 'passwords.hint.none');
      expect(chosen.secureCard!.entryIds, <String>[other]);
    });

    test('показать текстом — сначала вопрос, «да» — карточка', () async {
      await setUpWith();
      final id = await seed();
      final ask = await assistant.handle('покажи пароль от почты');
      expect(ask.replyId, 'passwords.reveal.confirm');
      expect(ask.secureCard, isNull);
      expect(ask.values['seconds'], '15');
      final pending = assistant.session.pendingConfirmation!;
      expect(pending.itemId, id);
      expect(pending.payload, isNull);
      final yes = await assistant.handle('да');
      expect(yes.replyId, 'passwords.reveal.card');
      expect(yes.secureCard!.kind, SecureCardKind.reveal);
      expectNoSecrets(yes);
      // Показ кнопкой — в историю только факт.
      final shown = await assistant.secureCardAction(
        yes.secureCard!,
        SecureCardCommand.revealed,
        entryId: id,
      );
      expect(shown!.replyId, 'passwords.revealed');
      expectNoSecrets(shown);
    });

    test('«нет» — ничего не показано', () async {
      await setUpWith();
      await seed();
      await assistant.handle('покажи пароль от почты');
      final no = await assistant.handle('нет');
      expect(no.replyId, 'passwords.cancelled');
      expect(no.secureCard, isNull);
    });

    test('скопировать: вопрос, «да» — карточка копирования', () async {
      await setUpWith();
      await seed();
      final ask = await assistant.handle('скопируй пароль от почты');
      expect(ask.replyId, 'passwords.copy.confirm');
      final yes = await assistant.handle('да');
      expect(yes.replyId, 'passwords.copy.done');
      expect(yes.values['seconds'], '30');
      expect(yes.secureCard!.kind, SecureCardKind.copy);
      expect(yes.secureCard!.options['auto'], isTrue);
    });

    test('Windows/macOS: копирования нет (D22)', () async {
      await setUpWith(canCopy: false);
      await seed();
      final response = await assistant.handle('скопируй пароль от почты');
      expect(response.replyId, 'passwords.copy.unavailable');
      expect(assistant.session.pendingConfirmation, isNull);
    });

    test('логин — в маске; целиком — по флагу', () async {
      await setUpWith();
      await seed();
      var response = await assistant.handle('какой у меня логин от почты');
      expect(response.replyId, 'passwords.login.card');
      expect(response.values['login'], 'ca***@example.org');
      expect(response.message, isNot(contains(Canary.login)));
      expect(response.secureCard!.kind, SecureCardKind.login);
      await vault.setPrefs(
        const <String, Object?>{'login_in_replies': true},
        master: secret(Canary.master),
      );
      response = await assistant.handle('забыл логин от почты');
      expect(response.replyId, 'passwords.login.full');
      expect(response.values['login'], Canary.login);
    });

    test('удаление: текстовое «да» не удаляет, кнопка — удаляет', () async {
      await setUpWith();
      final id = await seed();
      final ask = await assistant.handle('удали пароль от почты');
      expect(ask.replyId, 'passwords.delete.confirm');
      final card = ask.secureCard!;
      expect(card.kind, SecureCardKind.delete);
      final yes = await assistant.handle('да');
      expect(yes.replyId, 'passwords.delete.button');
      expect(vault.entry(id), isNotNull);
      final done = await assistant.secureCardAction(
        card,
        SecureCardCommand.delete,
        entryId: id,
      );
      expect(done!.replyId, 'passwords.delete.done');
      expect(vault.entry(id), isNull);
      expect(assistant.session.pendingConfirmation, isNull);
    });

    test('список, добавить, сменить, запереть, открыть', () async {
      await setUpWith();
      await seed();
      var response = await assistant.handle('какие пароли сохранены');
      expect(response.replyId, 'passwords.list.count');
      expect(response.values['count'], '2');
      expect(response.secureCard!.entryIds, hasLength(2));
      response = await assistant.handle('запомни пароль от озона');
      expect(response.replyId, 'passwords.add.editor');
      expect(response.secureCard!.kind, SecureCardKind.editor);
      expect(response.secureCard!.options['service'], 'Озон');
      response = await assistant.handle('смени пароль от почты');
      expect(response.replyId, 'passwords.change.editor');
      expect(response.secureCard!.options['mode'], 'password');
      response = await assistant.handle('открой пароли');
      expect(response.replyId, 'passwords.opened');
      expect(response.values['minutes'], '5');
      response = await assistant.handle('запри пароли');
      expect(response.replyId, 'passwords.lock.done');
      expect(vault.isUnlocked, isFalse);
    });

    test('без хранилища: справка, потеря устройства, мастер-пароль', () async {
      await setUpWith();
      expect(
        (await assistant.handle('что умеешь с паролями')).replyId,
        'passwords.help',
      );
      expect(
        (await assistant.handle('потерял телефон')).replyId,
        'passwords.lostDevice',
      );
      final forgot = await assistant.handle('забыл мастер-пароль');
      expect(forgot.replyId, 'passwords.noRecovery');
      expect(forgot.secureCard!.kind, SecureCardKind.recovery);
      expect(
        (await assistant.handle('сгенерируй пароль')).replyId,
        'passwords.soon',
      );
    });

    test('сервис не назван — переспросить', () async {
      await setUpWith();
      await seed();
      final response = await assistant.handle('скопируй пароль');
      expect(response.replyId, 'passwords.which');
    });
  });

  group('маршрутизация', () {
    test('выключен: фраза о паролях — passwords.off, задача не создана',
        () async {
      await setUpWith(enabled: false);
      expect(vault.state, VaultState.disabled);
      for (final text in <String>[
        'забыл пароль от почты',
        'покажи пароль от почты',
        'запомни пароль от озона',
      ]) {
        final response = await assistant.handle(text);
        expect(response.replyId, 'passwords.off', reason: text);
      }
      expect(await tasks.listAll(), isEmpty);
      // Маркеры задачи — всё ещё задача.
      final task =
          await assistant.handle('напомни завтра сменить пароль от почты');
      expect(task.replyId, startsWith('task.created'));
    });

    test('пароль в чате при выключенном навыке — подсказка включить', () async {
      await setUpWith(enabled: false);
      final response = await assistant.handle(
        'пароль от почты: ••••••',
        secretRedacted: true,
      );
      expect(response.replyId, 'secret.redacted.off');
      await setUpWith();
      final on = await assistant.handle(
        'пароль от почты: ••••••',
        secretRedacted: true,
      );
      expect(on.replyId, 'secret.redacted');
    });

    test('явная фраза о паролях — у навыка, а не у задач', () async {
      await setUpWith();
      await seed();
      final response = await assistant.handle('добавь пароль для озона');
      expect(response.intent, PasswordCommands.add);
      expect(await tasks.listAll(), isEmpty);
    });

    test('фразы о паролях не получает ни один сетевой коннектор', () async {
      final spy = _NetworkSpy();
      await setUpWith(extra: <Connector>[spy]);
      await seed();
      for (final text in <String>[
        'забыл пароль от почты',
        'пароль',
        'напомни завтра сменить пароль от почты',
        'потерял телефон',
      ]) {
        await assistant.handle(text);
        assistant.working(text);
      }
      expect(spy.seen, isEmpty);
      // Остальное шпион получает как обычно.
      await assistant.handle('где лежит 64115');
      expect(spy.seen, isNotEmpty);
    });

    test('выключили навык посреди вопроса — ожидание снято, хранилище заперто',
        () async {
      await setUpWith();
      await seed();
      await assistant.handle('покажи пароль от почты');
      expect(assistant.session.pendingConfirmation, isNotNull);
      registry.apply(registry.choiceWith(PasswordsConnector.id, false));
      expect(assistant.session.pendingConfirmation, isNull);
      expect(vault.state, VaultState.disabled);
      final response = await assistant.handle('да');
      expect(response.replyId, isNot('passwords.reveal.card'));
    });
  });

  group('ревью этапа 2: фразы и маршрутизация', () {
    // Частые формы «где пароль», «напомни пароль», «забыл логин и пароль»:
    // их не получает сетевой коннектор, при выключенном навыке —
    // passwords.off, при включённом — сам навык.
    const phrases = <String>[
      'где пароль от почты',
      'где лежит пароль от почты',
      'найди пароль от почты',
      'склад, пароль от почты',
      'на складе пароль от почты',
      'склад пароль от wifi',
      'напомни пароль от почты',
      'напомни мне пароль от почты',
      'забыл логин и пароль от почты',
      'не помню логин и пароль от почты',
      'скинь пароль от wifi',
      'напиши пароль от wifi',
      'какой у меня пароль',
      'покажи пароль',
      'подскажи пароль от почты',
    ];

    test('включён: навык, сеть и задачи их не получают', () async {
      final spy = _NetworkSpy();
      await setUpWith(extra: <Connector>[spy]);
      await seed();
      for (final text in phrases) {
        final response = await assistant.handle(text);
        expect(response.intent, startsWith('passwords.'), reason: text);
        assistant.session.takePendingConfirmation();
      }
      expect(spy.seen, isEmpty);
      expect(await tasks.listAll(), isEmpty);
    });

    test('выключен: passwords.off, задача не создана, сеть не видела',
        () async {
      final spy = _NetworkSpy();
      await setUpWith(enabled: false, extra: <Connector>[spy]);
      for (final text in phrases) {
        final response = await assistant.handle(text);
        expect(response.replyId, 'passwords.off', reason: text);
      }
      expect(spy.seen, isEmpty);
      expect(await tasks.listAll(), isEmpty);
    });

    test('«напомни/подскажи пароль» — сначала подсказка, а не показ', () async {
      await setUpWith();
      await seed();
      for (final text in <String>[
        'напомни пароль от почты',
        'подскажи пароль от почты',
        'забыл логин и пароль от почты',
      ]) {
        final response = await assistant.handle(text);
        expect(response.replyId, 'passwords.hint.card', reason: text);
        expect(response.secureCard!.kind, SecureCardKind.hint, reason: text);
      }
    });

    test('без слова «пароль» — обычные задачи (навык выключен и включён)',
        () async {
      for (final enabled in <bool>[false, true]) {
        await setUpWith(enabled: enabled);
        for (final text in <String>[
          'купить чехол, потерял телефон',
          'позвонить в банк, не могу войти в приложение',
          'не могу зайти к маме сегодня',
          'не могу войти на склад',
          'разбил телефон, нужно купить новый',
          'как восстановить доступ к складу',
        ]) {
          final response = await assistant.handle(text);
          expect(response.replyId, isNot('passwords.off'), reason: text);
          expect(
            response.intent,
            isNot(startsWith('passwords.')),
            reason: text,
          );
        }
        expect(await tasks.listAll(), isNotEmpty, reason: '$enabled');
      }
    });

    test('сервис без хвоста и притяжательных', () async {
      await setUpWith();
      await seed();
      for (final text in <String>[
        'пароль от почты какой',
        'забыл пароль от своей почты',
      ]) {
        final response = await assistant.handle(text);
        expect(response.replyId, 'passwords.hint.card', reason: text);
      }
    });

    test('заперли между вопросом и «да» — после открытия та же запись',
        () async {
      await setUpWith();
      final id = await seed();
      final ask = await assistant.handle('покажи пароль от почты');
      expect(ask.replyId, 'passwords.reveal.confirm');
      vault.lock();
      final yes = await assistant.handle('да');
      expect(yes.replyId, 'passwords.locked');
      final card = yes.secureCard!;
      expect(card.kind, SecureCardKind.unlock);
      expect(card.resume, PasswordCommands.reveal);
      expect(card.entryIds, <String>[id]);
      expectNoSecrets(yes);
      await vault.unlock(secret(Canary.master));
      final resumed =
          await assistant.secureCardAction(card, SecureCardCommand.resume);
      expect(resumed!.replyId, 'passwords.reveal.card');
      expect(resumed.secureCard!.kind, SecureCardKind.reveal);
      expect(resumed.secureCard!.entryIds, <String>[id]);
    });

    test('заперли до выбора в карточке — после открытия та же запись',
        () async {
      await setUpWith();
      final id = await seed();
      final choose = SecureCardRequest(
        kind: SecureCardKind.choose,
        entryIds: <String>[id],
        resume: PasswordCommands.hint,
      );
      vault.lock();
      final locked = await assistant.secureCardAction(
        choose,
        SecureCardCommand.choose,
        entryId: id,
      );
      expect(locked!.replyId, 'passwords.locked');
      expect(locked.secureCard!.entryIds, <String>[id]);
      await vault.unlock(secret(Canary.master));
      final resumed = await assistant.secureCardAction(
        locked.secureCard!,
        SecureCardCommand.resume,
      );
      expect(resumed!.replyId, 'passwords.hint.card');
      expect(resumed.secureCard!.entryIds, <String>[id]);
    });
  });

  group('ревью этапа 2: слово «пароль» и сеть', () {
    // Фразы со словом «пароль», которые не разбираются в команду навыка
    // или уходят задачам: сетевой коннектор их не видит всё равно.
    const tasksPhrases = <String, String>{
      'напомни мне сменить пароль': 'Сменить пароль',
      'спросить у админа пароль от wifi': 'Спросить у админа пароль от wifi',
      'записать пароль от wifi в задачи': 'Пароль от wifi в задачи',
      'узнать пароль от wifi': 'Узнать пароль от wifi',
      'поставить пароль на wifi': 'Поставить пароль на wifi',
    };
    // Поручения про других людей и другие дела — не «забыл пароль».
    const foreign = <String>[
      'поставь пароль на роутер',
      'купи роутер и поставь пароль на wifi',
      'отправь Пете пароль от wifi',
      'скажи Пете пароль от wifi',
      'Маша просила пароль от wifi',
    ];
    const where = <String>['где мой пароль', 'где пароли'];

    for (final enabled in <bool>[true, false]) {
      test('навык ${enabled ? 'включён' : 'выключен'}: шпион не видит ничего',
          () async {
        final spy = _NetworkSpy();
        await setUpWith(enabled: enabled, extra: <Connector>[spy]);
        if (enabled) await seed();
        for (final text in <String>[
          ...tasksPhrases.keys,
          ...foreign,
          ...where,
          'сколько будет 6 паролей на 2',
        ]) {
          assistant.working(text);
          final response = await assistant.handle(text);
          assistant.session.takePendingConfirmation();
          expect(response.intent, isNot('spy'), reason: text);
        }
        expect(spy.seen, isEmpty);
        // Без слова «пароль» шпион получает фразу как обычно.
        await assistant.handle('где лежит 64115');
        expect(spy.seen, isNotEmpty);
      });

      test(
          'навык ${enabled ? 'включён' : 'выключен'}: '
          'задачи со словом «пароль» — как раньше', () async {
        await setUpWith(enabled: enabled);
        for (final MapEntry(key: text, value: title) in tasksPhrases.entries) {
          final response = await assistant.handle(text);
          expect(response.replyId, startsWith('task.created'), reason: text);
          final all = await tasks.listAll();
          expect(all.last.title, title, reason: text);
        }
        expect(await tasks.listAll(), hasLength(tasksPhrases.length));
      });

      test(
          'навык ${enabled ? 'включён' : 'выключен'}: '
          'поручения про других — не подсказка', () async {
        await setUpWith(enabled: enabled);
        if (enabled) await seed();
        for (final text in foreign) {
          final response = await assistant.handle(text);
          expect(
            response.intent,
            isNot(startsWith('passwords.')),
            reason: text,
          );
          expect(response.replyId, isNot('passwords.off'), reason: text);
          expect(
            response.replyId,
            isNot(startsWith('passwords.notFound')),
            reason: text,
          );
        }
      });
    }

    test('«где мой пароль», «где пароли» — у навыка или passwords.off',
        () async {
      await setUpWith();
      await seed();
      final hint = await assistant.handle('где мой пароль');
      expect(hint.intent, PasswordCommands.hint);
      expect(hint.replyId, 'passwords.which');
      assistant.session.takePendingConfirmation();
      final list = await assistant.handle('где пароли');
      expect(list.intent, PasswordCommands.list);
      await setUpWith(enabled: false);
      for (final text in where) {
        final response = await assistant.handle(text);
        expect(response.replyId, 'passwords.off', reason: text);
      }
      expect(await tasks.listAll(), isEmpty);
    });

    test('хвост и числа не попадают в название сервиса', () async {
      await setUpWith();
      await seed();
      for (final (text, query, absent) in <(String, String, String)>[
        ('дай пароль от wifi гостям', 'Wi-Fi', 'гостям'),
        ('дома пароль от wifi сменился', 'Wi-Fi', 'сменился'),
        ('пароль от подъезда 1234', 'подъезда', '1234'),
      ]) {
        final response = await assistant.handle(text);
        assistant.session.takePendingConfirmation();
        expect(
          response.replyId,
          startsWith('passwords.notFound'),
          reason: text,
        );
        expect(response.values['query'], query, reason: text);
        expect(response.message, isNot(contains(absent)), reason: text);
      }
      // Целиком не нашлось — ищем по первому слову.
      final first = await assistant.handle('пароль от почты рабочей');
      expect(first.replyId, 'passwords.hint.card');
    });
  });
}
