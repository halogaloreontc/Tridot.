// Этап 3 (часть 1): «Проверить себя», тренировка памяти (5.8), проверка
// надёжности (5.5) в хранилище и навыке, генератор в чате. Хранилище —
// настоящее (libsodium, тестовые параметры Argon2id, в памяти); пароли —
// только канарейки. В ответах навыка и истории — только числа и названия.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/models/secure_card.dart';
import 'package:local_assistant/core/passwords/keyboard_layouts.dart';
import 'package:local_assistant/core/passwords/password_audit.dart';
import 'package:local_assistant/core/passwords/password_strength.dart';
import 'package:local_assistant/core/passwords/password_training.dart';
import 'package:local_assistant/core/passwords/vault.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_facade.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/passwords/passwords_connector.dart';

import 'vault_test_support.dart';

void main() {
  late SodiumVaultCrypto crypto;

  setUpAll(() async {
    crypto = await testCrypto();
  });

  group('расписание тренировки', () {
    final now = DateTime.utc(2026, 11, 10, 9);

    test('1 → 3 → 7 → … → 120, ошибка → 1, с помощью — без роста', () {
      var train = TrainingSchedule.start(now);
      expect(TrainingSchedule.nextOf(train), now.add(const Duration(days: 1)));
      final days = <int>[];
      for (var i = 0; i < 8; i++) {
        train = TrainingSchedule.next(train, TrainingOutcome.correct, now);
        days.add(TrainingSchedule.daysUntil(train, now));
      }
      expect(days, <int>[3, 7, 14, 30, 60, 120, 120, 120]);
      expect(TrainingSchedule.streakOf(train), 8);
      final helped = TrainingSchedule.next(train, TrainingOutcome.helped, now);
      expect(TrainingSchedule.daysUntil(helped, now), 120);
      expect(TrainingSchedule.streakOf(helped), 8);
      final wrong = TrainingSchedule.next(train, TrainingOutcome.wrong, now);
      expect(TrainingSchedule.daysUntil(wrong, now), 1);
      expect(TrainingSchedule.streakOf(wrong), 0);
      expect(TrainingSchedule.stepOf(wrong), 0);
    });

    test('«Не сейчас» — завтра, «Больше не спрашивать» — вне тренировки', () {
      final train = TrainingSchedule.start(now);
      final later = now.add(const Duration(days: 5));
      final skipped =
          TrainingSchedule.next(train, TrainingOutcome.skipped, later);
      expect(TrainingSchedule.daysUntil(skipped, later), 1);
      final stopped =
          TrainingSchedule.next(train, TrainingOutcome.stopped, later);
      expect(TrainingSchedule.isOff(stopped), isTrue);
      expect(TrainingSchedule.isDue(stopped, later), isFalse);
    });

    test('ограничение попыток: 5 за 10 минут на запись', () {
      final limiter = RecallLimiter();
      const t0 = Duration(hours: 1);
      for (var i = 0; i < 5; i++) {
        expect(limiter.take('a', t0), isTrue);
      }
      expect(limiter.take('a', t0), isFalse);
      expect(limiter.take('b', t0), isTrue);
      expect(limiter.left('a', t0), 0);
      expect(
        limiter.take('a', t0 + const Duration(minutes: 10)),
        isTrue,
      );
    });

    test('settings.json: только дата тренировки', () {
      const settings = AppSettings(passwordsTrainingDue: '2026-11-12');
      final json = settings.toJson();
      expect(json['passwords.training_due'], '2026-11-12');
      expect(
        AppSettings.fromJson(json).passwordsTrainingDue,
        '2026-11-12',
      );
      expect(
        AppSettings.fromJson(<String, dynamic>{
          'passwords.training_due': 'Почта',
        }).passwordsTrainingDue,
        isNull,
      );
    });
  });

  group('хранилище: «Проверить себя» и проверка', () {
    late TestClock clock;
    late Vault vault;

    Future<String> seed({bool important = true}) async {
      clock = TestClock(DateTime.utc(2026, 11, 10, 9));
      vault = testVault(InMemoryVaultStore(), crypto, clock: clock)
        ..assessor = PasswordAssessor(PasswordStrength(testWordlists()));
      await vault.load();
      await vault.create(secret(Canary.master), params: fastKdf);
      return vault.addEntry(
        service: 'Почта',
        login: Canary.login,
        hint: 'как в детстве',
        password: secret(Canary.password),
        important: important,
      );
    }

    test('верно, раскладка, регистр, прежний пароль, не совпадает', () async {
      // Обычная запись: свой предел 5 попыток ([RecallLimiter]); важная
      // тратит общий предел догадок (тест D2 в oracle_gate_test).
      final id = await seed(important: false);
      expect(
        await vault.recall(id, secret(Canary.password)),
        RecallVerdict.correct,
      );
      final layout = String.fromCharCodes(
        Canary.password.runes.map(KeyboardLayouts.swap),
      );
      expect(
        await vault.recall(id, secret(layout)),
        RecallVerdict.almostLayout,
      );
      final caps = String.fromCharCodes(
        Canary.password.runes.map(KeyboardLayouts.flipCase),
      );
      expect(await vault.recall(id, secret(caps)), RecallVerdict.almostCase);
      await vault.updatePassword(id, secret('CANARY-new-pw-7'));
      expect(
        await vault.recall(id, secret(Canary.password)),
        RecallVerdict.oldOne,
      );
      // Пятая попытка за 10 минут — последняя.
      expect(
        await vault.recall(id, secret('CANARY-nope')),
        RecallVerdict.wrong,
      );
      expect(
        await vault.recall(id, secret('CANARY-new-pw-7')),
        RecallVerdict.limited,
      );
      clock.advance(const Duration(minutes: 11));
      expect(
        await vault.recall(id, secret('CANARY-new-pw-7')),
        RecallVerdict.correct,
      );
      vault.lock();
    });

    test('ответ не зависит от «близости»: почти верный ввод — «не совпадает»',
        () async {
      final id = await seed();
      final oneOff = '${Canary.password.substring(0, 14)}x';
      expect(await vault.recall(id, secret(oneOff)), RecallVerdict.wrong);
      expect(await vault.recall(id, secret('')), RecallVerdict.wrong);
      vault.lock();
    });

    test('запирание сбрасывает счётчик попыток; заперто — locked', () async {
      final id = await seed();
      vault.lock();
      await expectLater(
        vault.recall(id, secret(Canary.password)),
        throwsA(isA<Object>()),
      );
    });

    test('важная запись — сразу в тренировке; итог пишется в train', () async {
      final id = await seed();
      final facade = VaultFacade(vault);
      // Часы не двигаем: иначе хранилище запрётся по пределу 60 мин.
      final tomorrow = clock.now().add(const Duration(days: 1));
      expect(facade.trainingDue(clock.now()), isFalse);
      expect(facade.trainingDue(tomorrow), isTrue);
      expect(facade.trainingQueue(tomorrow).single.id, id);
      await vault.recordTraining(id, TrainingOutcome.correct);
      expect(facade.training(id, clock.now()), (1, 3));
      await vault.recordTraining(id, TrainingOutcome.stopped);
      expect(facade.trainingQueue(tomorrow), isEmpty);
      // «Больше не спрашивать» не снимает «Важный»: это ослабило бы
      // переспрос (3.6) без мастер-пароля.
      expect(vault.entry(id)!.important, isTrue);
      vault.lock();
    });

    test('оценка, флаги и fp_loose при добавлении и проверке', () async {
      final id = await seed();
      final mail = vault.entry(id)!;
      expect(mail.score, isNotNull);
      expect(mail.fpLoose, isNotNull);
      final weak = await vault.addEntry(
        service: 'Форум',
        password: secret('qwerty123'),
      );
      expect(vault.entry(weak)!.flags, contains(EntryFlags.weak));
      expect(vault.entry(weak)!.flags, contains(EntryFlags.short));
      // Почти повтор: тот же пароль с другим хвостом из цифр.
      final a =
          await vault.addEntry(service: 'Кино', password: secret('Kotik2019'));
      final b =
          await vault.addEntry(service: 'Игры', password: secret('kotik2020'));
      // Точный повтор.
      final c = await vault.addEntry(
        service: 'Почта 2',
        password: secret(Canary.password),
      );
      // Подсказка раскрывает пароль.
      final leak = await vault.addEntry(
        service: 'Банк',
        password: secret('Zq8-barsik-Lm3'),
        hint: 'кличка barsik',
      );
      final facade = VaultFacade(vault);
      // Важная «Почта» без свежего мастер-пароля в повторы не входит
      // (15.2): иначе «добавить запись с догадкой → проверка» — оракул.
      final guarded = await facade.audit(clock.now());
      expect(guarded.reused, 0);
      expect(await vault.verifyMaster(secret(Canary.master)), isTrue);
      final report = await facade.audit(clock.now());
      expect(report.total, 6);
      expect(report.reused, 1);
      expect(report.reusedPlaces, 2);
      expect(report.similar, 1);
      expect(report.weak, greaterThanOrEqualTo(3));
      expect(report.hintLeaks, 1);
      expect(report.ids, containsAll(<String>[weak, a, b, c, id, leak]));
      expect('$report', 'VaultCheckReport(6)');
      // Через два года — старые (важная — уже через 180 дней).
      final now = clock.now();
      expect(facade.checkReport(now.add(const Duration(days: 200))).old, 1);
      expect(facade.checkReport(now.add(const Duration(days: 600))).old, 6);
      vault.lock();
    });

    test('вернулись к прежнему паролю — флаг returnedOld', () async {
      final id = await seed();
      expect(await vault.verifyMaster(secret(Canary.master)), isTrue);
      await vault.updatePassword(id, secret('CANARY-second-3'));
      await vault.updatePassword(id, secret(Canary.password));
      expect(vault.entry(id)!.flags, contains(EntryFlags.returnedOld));
      final groups = CheckGroups.of(vault.entries, clock.now());
      expect(groups.returnedOld, <String>[id]);
      vault.lock();
    });
  });

  group('навык: генератор, проверка, тренировка', () {
    late Vault vault;
    late VaultFacade facade;
    late AssistantController assistant;
    late TestClock clock;

    Future<String> setUp0() async {
      clock = TestClock(DateTime.utc(2026, 11, 10, 9));
      vault = testVault(InMemoryVaultStore(), crypto, clock: clock)
        ..assessor = PasswordAssessor(PasswordStrength(testWordlists()));
      await vault.load();
      facade = VaultFacade(vault);
      final registry = ExtensionRegistry(
        connectors: <Connector>[PasswordsConnector(vault: facade)],
        choice: const ExtensionChoice(enabled: <String>{'passwords'}),
      );
      vault.followExtension(registry, PasswordsConnector.id);
      assistant = AssistantController(
        extensions: registry,
        clock: FixedClock(clock.value),
        knownSecret: facade.knownSecret,
      );
      await vault.create(secret(Canary.master), params: fastKdf);
      final id = await vault.addEntry(
        service: 'Почта',
        login: Canary.login,
        hint: Canary.hint,
        password: secret(Canary.password),
        note: secret(Canary.note),
        important: true,
      );
      await vault.addEntry(service: 'Форум', password: secret('qwerty123'));
      await vault.addEntry(service: 'Кино', password: secret(Canary.password));
      return id;
    }

    void expectClean(AssistantResponse response) {
      for (final canary in <String>[
        Canary.password,
        Canary.note,
        Canary.master,
        Canary.hint,
        'qwerty123',
      ]) {
        expect(response.message, isNot(contains(canary)));
        expect(response.values.values.join(), isNot(contains(canary)));
        expect('${response.secureCard?.options}', isNot(contains(canary)));
      }
    }

    test('«сгенерируй пароль на 24 символа без символов» — только карточка',
        () async {
      await setUp0();
      vault.lock();
      final response = await assistant
          .handle('сгенерируй пароль на 24 символа без символов');
      expect(response.replyId, 'passwords.generate.ready');
      expect(response.secureCard!.kind, SecureCardKind.generate);
      expect(response.secureCard!.options['mode'], 'characters');
      expect(response.secureCard!.options['length'], 24);
      expect(response.secureCard!.options['symbols'], isFalse);
      expect(response.message, contains('бит'));
      final words = await assistant.handle('придумай пароль из 6 слов');
      expect(words.secureCard!.options['mode'], 'words');
      expect(words.secureCard!.options['words'], 6);
      expect(words.message, contains('очень высокая'));
    });

    test('«проверь мои пароли»: в истории только числа', () async {
      await setUp0();
      // Важная запись без свежего мастер-пароля в повторы не входит.
      final guarded = await assistant.handle('проверь мои пароли');
      expect(guarded.values['reused'], '0');
      expect(await vault.verifyMaster(secret(Canary.master)), isTrue);
      final response = await assistant.handle('проверь мои пароли');
      expect(response.replyId, 'passwords.check.summary');
      expect(response.values['total'], '3');
      expect(response.values['reused'], '1');
      expect(response.values['places'], '2');
      expect(response.message, isNot(contains('Форум')));
      expect(response.message, isNot(contains('Кино')));
      expect(response.secureCard!.kind, SecureCardKind.check);
      expectClean(response);
      vault.lock();
      final locked = await assistant.handle('есть ли слабые пароли');
      expect(locked.replyId, 'passwords.locked');
      expect(locked.secureCard!.resume, 'passwords.check');
    });

    test('«потренируй меня»: важная запись, итог — без пароля', () async {
      final id = await setUp0();
      final ask = await assistant.handle('потренируй меня');
      expect(ask.replyId, 'passwords.train.ask');
      expect(ask.values['service'], 'Почта');
      expect(ask.secureCard!.kind, SecureCardKind.training);
      expect(ask.secureCard!.entryIds, <String>[id]);
      expectClean(ask);
      await vault.recordTraining(id, TrainingOutcome.correct);
      final done = await assistant.secureCardAction(
        ask.secureCard!,
        SecureCardCommand.trained,
        entryId: id,
        detail: 'correct',
      );
      expect(done!.replyId, 'passwords.train.correct');
      expect(done.message, contains('серия 1'));
      expect(done.message, contains('3 дн.'));
      expectClean(done);
      final named =
          await assistant.handle('проверь, помню ли я пароль от почты');
      expect(named.replyId, 'passwords.train.ask');
    });

    test('«проверь, помню ли я пароль от госуслуг» — названная запись',
        () async {
      final mail = await setUp0();
      final gov = await vault.addEntry(
        service: 'Госуслуги',
        password: secret('CANARY-gov-Tq5'),
        important: true,
      );
      final first = await assistant.handle('потренируй меня');
      expect(first.secureCard!.entryIds, <String>[mail]);
      final named =
          await assistant.handle('проверь, помню ли я пароль от госуслуг');
      expect(named.replyId, 'passwords.train.ask');
      expect(named.values['service'], 'Госуслуги');
      expect(named.secureCard!.entryIds, <String>[gov]);
      expect(named.message, isNot(contains('CANARY')));
    });

    test('«мне нужен пароль от почты» — подсказка, а не генератор', () async {
      await setUp0();
      final response = await assistant.handle('мне нужен пароль от почты');
      expect(response.intent, PasswordCommands.hint);
      expect(response.secureCard!.kind, SecureCardKind.hint);
      final other =
          await assistant.handle('маша просила придумать пароль для wifi');
      expect(other.intent, isNot(PasswordCommands.generate));
      expect(other.secureCard?.kind, isNot(SecureCardKind.generate));
    });

    test('без важных записей — как отметить', () async {
      final id = await setUp0();
      await vault.updateInfo(
        id,
        important: false,
        master: secret(Canary.master),
      );
      final response = await assistant.handle('потренируй меня');
      expect(response.replyId, 'passwords.train.none');
    });

    test('лестница подсказок: в истории только номер ступени', () async {
      final id = await setUp0();
      final hint = await assistant.handle('забыл пароль от почты');
      expect(hint.secureCard!.kind, SecureCardKind.hint);
      final step = await assistant.secureCardAction(
        hint.secureCard!,
        SecureCardCommand.hintStep,
        entryId: id,
        detail: '2',
      );
      expect(step!.replyId, 'passwords.hint.used');
      expect(step.message, 'Подсказка к «Почта»: использована ступень 2.');
      expectClean(step);
      final junk = await assistant.secureCardAction(
        hint.secureCard!,
        SecureCardCommand.hintStep,
        entryId: id,
        detail: Canary.password,
      );
      expect(junk!.replyId, 'passwords.help');
      expectClean(junk);
    });

    test('«заметка дня»: заперто — без названия, открыто — вопрос', () async {
      await setUp0();
      vault.lock();
      const card = SecureCardRequest(kind: SecureCardKind.training);
      final locked =
          await assistant.secureCardAction(card, SecureCardCommand.notice);
      expect(locked!.replyId, 'passwords.train.due');
      expect(locked.message, isNot(contains('Почта')));
      expect(locked.secureCard!.kind, SecureCardKind.unlock);
      expect(locked.secureCard!.resume, 'passwords.train');
    });
  });
}
