// Ворота сравнения с охраняемыми важными записями (3.6, 15.2): пока важная
// запись ждёт свежего мастер-пароля, введённый человеком текст сверяется с
// её паролем только через предел догадок (одна догадка за попытку, 5 за
// 10 минут). Каждый путь, где раньше был оракул, — отдельный тест, и
// общий тест атаки: 64 догадки по всем путям сразу не находят пароль.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/passwords/clipboard_guard.dart';
import 'package:local_assistant/app/passwords/passwords_kit.dart';
import 'package:local_assistant/app/passwords/passwords_platform.dart';
import 'package:local_assistant/app/passwords/passwords_settings_screen.dart';
import 'package:local_assistant/core/passwords/hint_guard.dart';
import 'package:local_assistant/core/passwords/import_rules.dart';
import 'package:local_assistant/core/passwords/vault.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_errors.dart';
import 'package:local_assistant/core/passwords/vault_facade.dart';
import 'package:local_assistant/core/passwords/vault_format.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/services/clock.dart';

import 'vault_test_support.dart';

void main() {
  late SodiumVaultCrypto crypto;

  setUpAll(() async {
    crypto = await testCrypto();
  });

  late TestClock clock;
  late Vault vault;
  late PasswordsKit kit;

  /// Хранилище с важной «Почтой» (пароль [Canary.password]) и обычным
  /// «Форумом». Создание — не подтверждение: «Почта» сразу охраняется.
  Future<String> setUpVault() async {
    clock = TestClock();
    vault = testVault(InMemoryVaultStore(), crypto, clock: clock);
    kit = PasswordsKit(
      vault: vault,
      platform: PasswordsPlatform.linux,
      kdfForTesting: fastKdf,
      wordlists: testWordlists(),
      clipboard: ClipboardGuard(
        platform: PasswordsPlatform.linux,
        cipher: crypto,
        write: (String text) async {},
        read: () async => null,
      ),
    );
    await vault.load();
    await vault.create(secret(Canary.master), params: fastKdf);
    final id = await vault.addEntry(
      service: 'Почта',
      login: Canary.login,
      hint: 'как в детстве',
      password: secret(Canary.password),
      important: true,
    );
    await vault.addEntry(
      service: 'Форум',
      password: secret('CANARY-forum-Kp2'),
    );
    return id;
  }

  void tearDownVault() {
    vault.lock();
    kit.dispose();
  }

  group('ворота Vault.entriesMatching', () {
    test('без предела охраняемые не сравниваются; мастер-пароль — 60 с',
        () async {
      final id = await setUpVault();
      final entry = vault.entry(id)!;
      expect(vault.isGuarded(entry), isTrue);
      final plain = vault.entriesMatching(secret(Canary.password));
      expect(plain.entries, isEmpty);
      expect(plain.complete, isFalse);
      final forum = vault.entriesMatching(secret('CANARY-forum-Kp2'));
      expect(forum.entries.single.service, 'Форум');
      expect(forum.complete, isFalse);
      // С пределом — одна догадка, и она честная.
      final spent =
          vault.entriesMatching(secret(Canary.password), spendGuess: true);
      expect(spent.entries.single.id, id);
      expect(spent.complete, isTrue);
      // Мастер-пароль — 60 с без охраны, потом снова.
      expect(await vault.verifyMaster(secret(Canary.master)), isTrue);
      expect(vault.isGuarded(entry), isFalse);
      expect(vault.entriesMatching(secret(Canary.password)).entries, [entry]);
      clock.advance(const Duration(seconds: 61));
      expect(vault.isGuarded(entry), isTrue);
      expect(vault.entriesMatching(secret(Canary.password)).entries, isEmpty);
      tearDownVault();
    });

    test('предел: 5 разных догадок за 10 минут, повтор — бесплатно', () async {
      await setUpVault();
      for (var i = 0; i < Vault.guessLimit; i++) {
        expect(
          vault
              .entriesMatching(secret('CANARY-g$i'), spendGuess: true)
              .complete,
          isTrue,
        );
      }
      expect(
        vault.entriesMatching(secret('CANARY-g0'), spendGuess: true).complete,
        isTrue,
      );
      final denied =
          vault.entriesMatching(secret(Canary.password), spendGuess: true);
      expect(denied.complete, isFalse);
      expect(denied.entries, isEmpty);
      clock.advance(Vault.guessWindow);
      expect(
        vault
            .entriesMatching(secret(Canary.password), spendGuess: true)
            .entries,
        hasLength(1),
      );
      // Запирание сбрасывает и подтверждение, и догадки.
      vault.lock();
      expect(
        vault.entriesMatching(secret(Canary.password)).entries,
        isEmpty,
      );
      kit.dispose();
    });

    test('переспрос выключен — важные не охраняются', () async {
      final id = await setUpVault();
      await vault.setPrefs(
        <String, Object?>{'reprompt_important': false},
        master: secret(Canary.master),
      );
      clock.advance(const Duration(minutes: 5));
      expect(vault.isGuarded(vault.entry(id)!), isFalse);
      expect(vault.matchesKnownSecret(Canary.password), isTrue);
      tearDownVault();
    });
  });

  group('N1: подсказка важной записи без мастер-пароля', () {
    test('reviewSave(hint, "", id) — needsConfirm, пароль не сверяется',
        () async {
      final id = await setUpVault();
      // Атакующий: подсказки-куски пароля и мимо — ответ один и тот же,
      // сколько бы ни спрашивал; попытки не тратятся.
      final probes = <String>[
        for (var i = 0; i + 4 <= Canary.password.length; i++)
          Canary.password.substring(i, i + 4),
        'zzzz',
        'qqqq',
        Canary.password,
      ];
      for (var round = 0; round < 3; round++) {
        for (final probe in probes) {
          final review = await kit.reviewSave(probe, '', id: id);
          expect(review.hint.block, HintProblem.needsConfirm, reason: probe);
        }
      }
      // Предел не тронут: честная догадка по-прежнему доступна.
      expect(
        vault.entriesMatching(secret('CANARY-x'), spendGuess: true).complete,
        isTrue,
      );
      // Ядро тоже не даёт: подсказку охраняемой записи — после мастер-пароля.
      await expectLater(
        vault.updateInfo(id, hint: Canary.password.substring(0, 4)),
        throwsStateError,
      );
      // С мастер-паролем — честная проверка куска.
      expect(await kit.confirm(Canary.master), isTrue);
      expect(
        (await kit.reviewSave(Canary.password.substring(4, 9), '', id: id))
            .hint
            .block,
        HintProblem.sharedFragment,
      );
      await vault.updateInfo(id, hint: 'про собаку');
      expect(vault.entry(id)!.hint, 'про собаку');
      tearDownVault();
    });
  });

  group('N2: чат и выходной фильтр', () {
    test('пароль охраняемой важной записи — не оракул «скрыл / не скрыл»',
        () async {
      await setUpVault();
      final facade = VaultFacade(vault);
      expect(facade.knownSecret(Canary.password), isFalse);
      expect(facade.knownSecret('CANARY-forum-Kp2'), isTrue);
      final assistant = AssistantController(
        connectors: const [],
        clock: FixedClock(DateTime(2026, 11, 11, 12)),
        knownSecret: facade.knownSecret,
      );
      final important = await assistant.handle('напомни ${Canary.password}');
      final decoy = await assistant.handle('напомни CANARY-pw-0000x');
      expect(important.replyId, decoy.replyId);
      expect(important.replyId, isNot('secret.redacted'));
      // Обычная запись — по-прежнему скрыта.
      final forum = await assistant.handle('напомни CANARY-forum-Kp2');
      expect(forum.replyId, 'secret.redacted');
      // Правила по виду («пароль: …») работают для любых значений.
      final typed = await assistant.handle('пароль: ${Canary.password}');
      expect(typed.replyId, 'secret.redacted');
      // После мастер-пароля — снова и для важных.
      expect(await vault.verifyMaster(secret(Canary.master)), isTrue);
      expect(facade.knownSecret(Canary.password), isTrue);
      tearDownVault();
    });
  });

  group('N3: пароль и подсказка — две догадки', () {
    test('каждая разная догадка тратит свою попытку', () async {
      await setUpVault();
      for (var i = 0; i < Vault.guessLimit - 1; i++) {
        await kit.reviewSave('', 'CANARY-guess-$i');
      }
      // Пятая — пароль; на подсказку попытки нет: «подтвердите».
      final review = await kit.reviewSave(Canary.password, 'Zx7#qQ!w2LmT');
      expect(review.unchecked, isFalse);
      expect(review.hint.block, HintProblem.needsConfirm);
      tearDownVault();
    });

    test('с мастер-паролем — обе проверки честные', () async {
      await setUpVault();
      expect(await kit.confirm(Canary.master), isTrue);
      final review = await kit.reviewSave(Canary.password, 'Zx7#qQ!w2LmT');
      expect(review.hint.block, HintProblem.equalsPassword);
      tearDownVault();
    });
  });

  group('N4: повтор — только после мастер-пароля', () {
    test('копия: неверный мастер-пароль — тот же ответ для любого пароля',
        () async {
      final id = await setUpVault();
      const reused = 'CANARY-Vq8#mT2!zK9pL-wR4';
      const strong = 'CANARY-Hn5@cW7!pX3rT-dG8';
      // Пароль важной записи — годный по виду пароль копии (правка важной
      // — после мастер-пароля).
      expect(await kit.confirm(Canary.master), isTrue);
      await vault.updatePassword(id, secret(reused));
      clock.advance(const Duration(minutes: 2));
      for (final separate in <String>[reused, strong]) {
        await expectLater(
          kit.exportBackup('CANARY-wrong-m', separate: separate),
          throwsA(
            isA<VaultError>().having(
              (VaultError e) => e.code,
              'code',
              VaultErrorCode.wrongPassword,
            ),
          ),
        );
        clock.advance(const Duration(minutes: 10));
      }
      // Верный мастер-пароль — и повтор с важной записью виден.
      await expectLater(
        kit.exportBackup(Canary.master, separate: reused),
        throwsA(isA<BackupProblem>()),
      );
      tearDownVault();
    });

    test('смена мастер-пароля: сначала текущий, потом повтор', () async {
      await setUpVault();
      const reused = 'CANARY-Vq8#mT2!zK9pL-wR4';
      expect(await kit.confirm(Canary.master), isTrue);
      await vault.updatePassword(
        vault.entries.firstWhere((VaultEntry e) => e.important).id,
        secret(reused),
      );
      clock.advance(const Duration(minutes: 2));
      await expectLater(
        kit.changeMaster('CANARY-wrong-m', reused),
        throwsA(isA<VaultError>()),
      );
      await expectLater(
        kit.changeMaster(Canary.master, reused),
        throwsA(
          isA<PasswordProblem>().having(
            (PasswordProblem p) => p.text,
            'text',
            contains('уже стоит у одной из записей'),
          ),
        ),
      );
      // Мастер-пароль не сменился.
      expect(await vault.verifyMaster(secret(Canary.master)), isTrue);
      tearDownVault();
    });
  });

  testWidgets('настройки: «Сменить мастер-пароль» — сначала текущий',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final id = await setUpVault();
    const reused = 'CANARY-Vq8#mT2!zK9pL-wR4';
    expect(await kit.confirm(Canary.master), isTrue);
    await vault.updatePassword(id, secret(reused));
    clock.advance(const Duration(minutes: 2));
    await tester.pumpWidget(
      MaterialApp(
        theme: AssistantTheme.dark(),
        home: PasswordsSettingsScreen(kit: kit),
      ),
    );
    Future<void> submit(String current) async {
      await tester
          .tap(find.byKey(const ValueKey<String>('prefs-change-master')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('change-current')),
        current,
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('change-next')),
        reused,
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('change-repeat')),
        reused,
      );
      await tester.tap(find.byKey(const ValueKey<String>('change-submit')));
      await tester.pumpAndSettle();
    }

    // Неверный текущий: про повтор ни слова — ответ не зависит от нового.
    await submit('CANARY-wrong-m');
    expect(find.text('Мастер-пароль не подошёл.'), findsOneWidget);
    expect(find.textContaining('уже стоит'), findsNothing);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    clock.advance(const Duration(minutes: 10));
    await submit(Canary.master);
    expect(find.textContaining('уже стоит у одной из записей'), findsOne);
    expect(await vault.verifyMaster(secret(Canary.master)), isTrue);
    vault.lock();
    await tester.pumpWidget(const SizedBox.shrink());
    kit.dispose();
  });

  group('прочие пути', () {
    test('CSV: охраняемая важная — всегда «другой пароль»', () async {
      await setUpVault();
      ImportItem item(String password) => ImportItem(
            service: 'Почта',
            login: Canary.login,
            password: secret(password),
          );
      final matches = vault.matchImport(<ImportItem>[
        item(Canary.password),
        item('CANARY-guess-1'),
      ]);
      expect(
        matches.map((ImportMatch m) => m.status),
        <ImportStatus>[ImportStatus.conflict, ImportStatus.conflict],
      );
      expect(await vault.verifyMaster(secret(Canary.master)), isTrue);
      expect(
        vault.matchImport(<ImportItem>[item(Canary.password)]).single.status,
        ImportStatus.same,
      );
      tearDownVault();
    });

    test('проверка: повторы с охраняемой важной не показываются', () async {
      await setUpVault();
      final probe = await vault.addEntry(
        service: 'Проба',
        password: secret(Canary.password),
      );
      expect(kit.groups().reused, isEmpty);
      expect(VaultFacade(vault).checkReport().reused, 0);
      expect(await vault.verifyMaster(secret(Canary.master)), isTrue);
      expect(kit.groups().reused.single, contains(probe));
      tearDownVault();
    });

    test('смена пароля важной: «вернулись к прежнему» не сравнивается',
        () async {
      final id = await setUpVault();
      // Без мастер-пароля пароль важной записи не меняется вовсе (D3).
      await expectLater(
        vault.updatePassword(id, secret('CANARY-second-3')),
        throwsStateError,
      );
      expect(vault.entry(id)!.flags, isNot(contains('returnedOld')));
      tearDownVault();
    });
  });

  test('атака: 64 догадки по всем путям — не больше 5 честных ответов',
      () async {
    final id = await setUpVault();
    final facade = VaultFacade(vault);
    final guesses = <String>[
      for (var i = 0; i < 64; i++) 'CANARY-cand-$i',
    ]..[37] = Canary.password;
    // Отклик каждого пути на догадку — то, что видит атакующий.
    final paths = <String, Future<Object?> Function(String)>{
      'sameAs': (String g) async => kit.sameAs(g).length,
      'knownSecret': (String g) async => facade.knownSecret(g),
      'reusedProblem': (String g) async => kit.reusedProblem(g),
      'reviewSave.password': (String g) async {
        final r = await kit.reviewSave('', g);
        return '${r.same.length}/${r.unchecked}';
      },
      'reviewSave.hint': (String g) async =>
          (await kit.reviewSave(g, '')).hint.block,
      'reviewSave.hint+id': (String g) async =>
          (await kit.reviewSave(g, '', id: id)).hint.block,
      'reviewSave.both': (String g) async {
        final r = await kit.reviewSave(g, 'Zx7#qQ!w2LmT');
        return '${r.hint.block}/${r.same.length}/${r.unchecked}';
      },
      'matchImport': (String g) async => vault
          .matchImport(<ImportItem>[
            ImportItem(
              service: 'Почта',
              login: Canary.login,
              password: secret(g),
            ),
          ])
          .single
          .status,
      'audit': (String g) async {
        final probe =
            await vault.addEntry(service: 'Проба', password: secret(g));
        final reused = kit.groups().reused.length;
        await vault.deleteEntry(probe);
        return reused;
      },
    };
    for (final MapEntry(key: name, value: ask) in paths.entries) {
      final answers = <Object?>[];
      for (final g in guesses) {
        answers.add(await ask(g));
      }
      // Ответ на пароль отличается от ответа на соседние догадки только
      // там, где предел его пропустил.
      final mine = answers[37];
      final others = <Object?>{
        for (var i = 0; i < answers.length; i++)
          if (i != 37 && i > 5) answers[i],
      };
      expect(others, hasLength(1), reason: name);
      expect(others, contains(mine), reason: name);
    }
    // Ни один путь не отличил пароль: попытки кончились на первых пяти
    // догадках (а «подсказка записи» и пачки их не тратят вовсе).
    expect(
      vault.entriesMatching(secret(Canary.password), spendGuess: true).complete,
      isFalse,
    );
    tearDownVault();
  });
}
