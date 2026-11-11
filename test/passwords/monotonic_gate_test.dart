// Сроки открытого хранилища не зависят от перевода системных часов (N1):
// окно подтверждения мастер-паролем, предел догадок ворот, предел
// «Проверить себя» и автозапирание меряются монотонными часами (и
// стенными — где «прошло больше» строже). Часы назад охрану не снимают,
// вперёд — предел догадок не сбрасывают.
//
// Правка записи — одна операция хранилища (N3): поля, пароль и заметка
// ложатся вместе или не ложатся вовсе; редактор и импорт спрашивают
// мастер-пароль заранее, если окна осталось меньше запаса.
// Значения — синтетические CANARY.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/passwords/clipboard_guard.dart';
import 'package:local_assistant/app/passwords/entry_screens.dart';
import 'package:local_assistant/app/passwords/passwords_kit.dart';
import 'package:local_assistant/app/passwords/passwords_platform.dart';
import 'package:local_assistant/core/passwords/password_training.dart';
import 'package:local_assistant/core/passwords/vault.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';

import 'vault_test_support.dart';

void main() {
  late SodiumVaultCrypto crypto;

  setUpAll(() async {
    crypto = await testCrypto();
  });

  late TestClock clock;
  late Vault vault;
  late PasswordsKit kit;
  late InMemoryVaultStore store;

  /// Важная «Почта» и обычный «Форум»; [policy] — сроки автозапирания.
  Future<(String, String)> setUpVault({
    VaultPolicy policy = const VaultPolicy(),
  }) async {
    clock = TestClock();
    store = InMemoryVaultStore();
    vault = testVault(store, crypto, clock: clock, policy: policy);
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
    final mail = await vault.addEntry(
      service: 'Почта',
      login: 'user@mail.example',
      password: secret(Canary.password),
      note: secret(Canary.note),
      important: true,
    );
    final forum = await vault.addEntry(
      service: 'Форум',
      password: secret('CANARY-forum-Kp2'),
    );
    return (mail, forum);
  }

  void tearDownVault() {
    vault.lock();
    kit.dispose();
  }

  Future<void> confirm() async {
    expect(await vault.verifyMaster(secret(Canary.master)), isTrue);
  }

  group('N1: окно подтверждения', () {
    test('часы назад — охраняется сразу', () async {
      final (mail, _) = await setUpVault();
      await confirm();
      expect(vault.isGuarded(vault.entry(mail)!), isFalse);
      clock.jump(const Duration(seconds: -1));
      expect(vault.isGuarded(vault.entry(mail)!), isTrue);
      clock.jump(const Duration(hours: -5));
      expect(vault.isGuarded(vault.entry(mail)!), isTrue);
      expect(kit.needsReprompt(mail), isTrue, reason: 'показ переспросит');
      tearDownVault();
    });

    test('часы стоят, монотонное время идёт — окно кончается', () async {
      final (mail, _) = await setUpVault();
      await confirm();
      clock.elapsed += const Duration(seconds: 61);
      expect(vault.isGuarded(vault.entry(mail)!), isTrue);
      tearDownVault();
    });

    test('часы вперёд — тоже охраняется (строже из двух)', () async {
      final (mail, _) = await setUpVault();
      await confirm();
      clock.jump(const Duration(minutes: 2));
      expect(vault.isGuarded(vault.entry(mail)!), isTrue);
      tearDownVault();
    });

    test('запас: за 10 с до конца окна редактор уже спрашивает', () async {
      final (mail, _) = await setUpVault();
      await confirm();
      clock.advance(const Duration(seconds: 51));
      final entry = vault.entry(mail)!;
      expect(vault.isGuarded(entry), isFalse);
      expect(vault.isGuarded(entry, margin: PasswordsKit.saveMargin), isTrue);
      expect(kit.needsReprompt(mail), isFalse);
      expect(kit.needsReprompt(mail, margin: PasswordsKit.saveMargin), isTrue);
      tearDownVault();
    });
  });

  group('N1: предел догадок и «Проверить себя»', () {
    test('часы вперёд не возвращают догадки ворот', () async {
      await setUpVault();
      for (var i = 0; i < Vault.guessLimit; i++) {
        final probe = secret('CANARY-guess-$i');
        expect(vault.entriesMatching(probe, spendGuess: true).complete, isTrue);
        probe.wipe();
      }
      expect(vault.guessesLeft, 0);
      clock.jump(const Duration(days: 1));
      expect(vault.guessesLeft, 0);
      final next = secret('CANARY-guess-next');
      expect(vault.entriesMatching(next, spendGuess: true).complete, isFalse);
      clock.jump(const Duration(days: -3));
      expect(vault.guessesLeft, 0);
      // Прошло 10 минут по монотонным часам — предел снова есть.
      clock.elapsed += Vault.guessWindow;
      expect(vault.guessesLeft, Vault.guessLimit);
      expect(vault.entriesMatching(next, spendGuess: true).complete, isTrue);
      next.wipe();
      tearDownVault();
    });

    test('«Проверить себя» охраняемой: часы вперёд предел не сбрасывают',
        () async {
      final (mail, _) = await setUpVault();
      for (var i = 0; i < Vault.guessLimit; i++) {
        expect(
          await vault.recall(mail, secret('CANARY-try-$i')),
          RecallVerdict.wrong,
        );
      }
      expect(
        await vault.recall(mail, secret('CANARY-try-x')),
        RecallVerdict.limited,
      );
      clock.jump(const Duration(hours: 2));
      expect(vault.recallLeft(mail), 0);
      expect(
        await vault.recall(mail, secret(Canary.password)),
        RecallVerdict.limited,
      );
      tearDownVault();
    });

    test('«Проверить себя» обычной: часы вперёд предел не сбрасывают',
        () async {
      final (_, forum) = await setUpVault(
        policy: const VaultPolicy(
          idle: Duration(days: 30),
          hardLimit: Duration(days: 30),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await vault.recall(forum, secret('CANARY-try-$i'));
      }
      expect(vault.recallLeft(forum), 0);
      clock.jump(const Duration(hours: 1));
      expect(vault.recallLeft(forum), 0);
      expect(
        await vault.recall(forum, secret('CANARY-forum-Kp2')),
        RecallVerdict.limited,
      );
      clock.elapsed += const Duration(minutes: 10);
      expect(vault.recallLeft(forum), 5);
      tearDownVault();
    });
  });

  group('N1: автозапирание', () {
    test('часы назад простой не продлевают', () async {
      await setUpVault();
      clock.advance(const Duration(minutes: 4));
      clock.jump(const Duration(days: -1));
      vault.checkTimeouts();
      expect(vault.state, VaultState.unlocked);
      clock.elapsed += const Duration(minutes: 1, seconds: 1);
      vault.checkTimeouts();
      expect(vault.state, VaultState.locked);
    });

    test('часы назад жёсткий предел не продлевают', () async {
      await setUpVault(
        policy: const VaultPolicy(
          idle: Duration(days: 30),
          hardLimit: Duration(minutes: 60),
        ),
      );
      clock.jump(const Duration(days: -2));
      clock.elapsed += const Duration(minutes: 61);
      vault.onAppState(VaultAppState.resumed);
      expect(vault.state, VaultState.locked);
    });

    test('сон: стенные часы ушли вперёд — запирает при возврате', () async {
      await setUpVault();
      clock.jump(const Duration(hours: 2));
      vault.onAppState(VaultAppState.resumed);
      expect(vault.state, VaultState.locked);
    });
  });

  group('N3: правка — одна операция', () {
    test('окно кончилось — StateError, файл и запись не тронуты', () async {
      final (mail, _) = await setUpVault();
      await confirm();
      clock.advance(const Duration(seconds: 61));
      final before = vault.entry(mail)!;
      final file = Uint8List.fromList(store.files[FileVaultStore.vaultName]!);
      await expectLater(
        vault.updateEntry(
          mail,
          service: 'Почта-2',
          password: secret('CANARY-new-pw-Zx81'),
          note: secret('CANARY-new-note'),
        ),
        throwsStateError,
      );
      final after = vault.entry(mail)!;
      expect(after.service, before.service);
      expect(after.srev, before.srev);
      expect(store.files[FileVaultStore.vaultName], file);
      tearDownVault();
    });

    test('поля, пароль и заметка — одной записью файла', () async {
      final (mail, _) = await setUpVault();
      await confirm();
      final before = vault.entry(mail)!;
      final rev = vault.rev!;
      await vault.updateEntry(
        mail,
        service: 'Почта-2',
        login: 'other@mail.example',
        password: secret('CANARY-new-pw-Zx81'),
        note: secret('CANARY-new-note'),
      );
      final after = vault.entry(mail)!;
      expect(vault.rev, rev + 1, reason: 'одна запись хранилища');
      expect(after.service, 'Почта-2');
      expect(after.login, 'other@mail.example');
      expect(after.srev, before.srev + 1);
      expect(after.fpOld.first, before.fp);
      final secretNow = await vault.readSecret(mail);
      expect(
        utf8.decode(secretNow.password.unsafeBytes),
        'CANARY-new-pw-Zx81',
      );
      expect(utf8.decode(secretNow.note.unsafeBytes), 'CANARY-new-note');
      secretNow.wipe();
      tearDownVault();
    });

    test('сбой записи посреди правки — ничего не меняется', () async {
      clock = TestClock();
      final failing = FailingVaultStore();
      vault = testVault(failing, crypto, clock: clock);
      await vault.load();
      await vault.create(secret(Canary.master), params: fastKdf);
      final id = await vault.addEntry(
        service: 'Почта',
        password: secret(Canary.password),
      );
      failing.fail = true;
      await expectLater(
        vault.updateEntry(
          id,
          service: 'Почта-2',
          password: secret('CANARY-new-pw-Zx81'),
        ),
        throwsA(anything),
      );
      expect(vault.entry(id)!.service, 'Почта');
      failing.fail = false;
      final secretNow = await vault.readSecret(id);
      expect(utf8.decode(secretNow.password.unsafeBytes), Canary.password);
      secretNow.wipe();
      vault.lock();
    });

    testWidgets('редактор: окна меньше запаса — спрашивает мастер-пароль',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (mail, _) = await setUpVault();
      await confirm();
      clock.advance(const Duration(seconds: 52));
      await tester.pumpWidget(
        MaterialApp(
          theme: AssistantTheme.dark(),
          home: EntryEditorScreen(kit: kit, id: mail),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('editor-service')),
        'Почта-2',
      );
      await tester.tap(find.byKey(const ValueKey<String>('editor-save')));
      await tester.pumpAndSettle();
      expect(find.text('Важная запись'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey<String>('master-dialog-field')),
        Canary.master,
      );
      await tester.tap(find.byKey(const ValueKey<String>('master-dialog-ok')));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(vault.entry(mail)!.service, 'Почта-2');
      expect(find.byType(EntryEditorScreen), findsNothing);
      tearDownVault();
      await tester.pumpWidget(const SizedBox());
    });
  });
}
