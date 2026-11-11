// Хранилище, этап 2 (ADR-014): защитные настройки в индексе (раздел 9),
// варианты ввода мастер-пароля (D25), «начать заново» в архив (5.11),
// новая заметка, ссылки фасада для поиска.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/passwords/master_variants.dart';
import 'package:local_assistant/core/passwords/secret_bytes.dart';
import 'package:local_assistant/core/passwords/vault.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_errors.dart';
import 'package:local_assistant/core/passwords/vault_facade.dart';
import 'package:local_assistant/core/passwords/vault_prefs.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';

import 'vault_test_support.dart';

String _text(SecretBytes bytes) => utf8.decode(bytes.unsafeBytes);

void main() {
  late SodiumVaultCrypto crypto;

  setUpAll(() async {
    crypto = await testCrypto();
  });

  group('защитные настройки', () {
    test('значения по умолчанию раздела 9', () {
      const empty = <String, Object?>{};
      expect(VaultPrefs.autolockMinutes.of(empty), 5);
      expect(VaultPrefs.masterEveryHours.of(empty), 72);
      expect(VaultPrefs.revealSeconds.of(empty), 15);
      expect(VaultPrefs.clipboardSeconds.of(empty), 30);
      expect(VaultPrefs.hintsInHistory.of(empty), isFalse);
      expect(VaultPrefs.loginInReplies.of(empty), isFalse);
      expect(VaultPrefs.repromptImportant.of(empty), isTrue);
      // Мусор — значение по умолчанию.
      expect(VaultPrefs.autolockMinutes.of(const {'autolock_min': 999}), 5);
      expect(
        VaultPrefs.hintsInHistory.of(const {'hints_in_history': 'да'}),
        isFalse,
      );
    });

    test('что считается ослаблением', () {
      const current = <String, Object?>{};
      for (final weaker in <Map<String, Object?>>[
        <String, Object?>{'autolock_min': 30},
        <String, Object?>{'master_every_h': 168},
        <String, Object?>{'reveal_s': 30},
        <String, Object?>{'clipboard_s': 90},
        <String, Object?>{'hints_in_history': true},
        <String, Object?>{'login_in_replies': true},
        <String, Object?>{'reprompt_important': false},
      ]) {
        expect(VaultPrefs.weakens(current, weaker), isTrue, reason: '$weaker');
      }
      for (final stronger in <Map<String, Object?>>[
        <String, Object?>{'autolock_min': 1},
        <String, Object?>{'master_every_h': 24},
        <String, Object?>{'reveal_s': 10},
        <String, Object?>{'clipboard_s': 15},
        <String, Object?>{'hints_in_history': false},
      ]) {
        expect(
          VaultPrefs.weakens(current, stronger),
          isFalse,
          reason: '$stronger',
        );
      }
      expect(
        () => VaultPrefs.check(const <String, Object?>{'autolock_min': 7}),
        throwsArgumentError,
      );
      expect(
        () => VaultPrefs.check(const <String, Object?>{'evil': true}),
        throwsArgumentError,
      );
    });

    test('ужесточение — без мастер-пароля, ослабление — только с ним',
        () async {
      final store = InMemoryVaultStore();
      final vault = testVault(store, crypto);
      await vault.create(secret(Canary.master), params: fastKdf);
      await vault.setPrefs(const <String, Object?>{'autolock_min': 1});
      expect(vault.idleTimeout, const Duration(minutes: 1));
      expect(vault.prefsWeaken(const {'autolock_min': 30}), isTrue);
      await expectLater(
        vault.setPrefs(const <String, Object?>{'autolock_min': 30}),
        throwsArgumentError,
      );
      await expectLater(
        vault.setPrefs(
          const <String, Object?>{'hints_in_history': true},
          master: secret('CANARY-wrong-1'),
        ),
        throwsA(VaultError.wrongPassword),
      );
      expect(VaultPrefs.hintsInHistory.of(vault.prefs), isFalse);
      await vault.setPrefs(
        const <String, Object?>{'hints_in_history': true, 'autolock_min': 30},
        master: secret(Canary.master),
      );
      expect(VaultPrefs.hintsInHistory.of(vault.prefs), isTrue);
      expect(vault.idleTimeout, const Duration(minutes: 30));
      // Настройки — внутри зашифрованного индекса: после перезапуска те
      // же, а в файле их не прочитать.
      final again = testVault(store, crypto);
      await again.unlock(secret(Canary.master));
      expect(VaultPrefs.hintsInHistory.of(again.prefs), isTrue);
      final file = utf8.decode((await store.readVault())!);
      expect(file, isNot(contains('hints_in_history')));
      expect(file, isNot(contains('autolock')));
    });

    test('неверный мастер-пароль при ослаблении идёт в общий счётчик',
        () async {
      final store = InMemoryVaultStore();
      final vault = testVault(store, crypto);
      await vault.create(secret(Canary.master), params: fastKdf);
      for (var i = 0; i < 5; i++) {
        await expectLater(
          vault.setPrefs(
            const <String, Object?>{'reveal_s': 30},
            master: secret('CANARY-wrong-$i'),
          ),
          throwsA(VaultError.wrongPassword),
        );
      }
      await expectLater(
        vault.setPrefs(
          const <String, Object?>{'reveal_s': 30},
          master: secret(Canary.master),
        ),
        throwsA(isA<VaultRateLimited>()),
      );
    });
  });

  group('варианты ввода мастер-пароля (D25)', () {
    test('раскладка, Caps Lock, первая буква, пробелы', () {
      final variants = MasterVariants.of(secret(' Rjnbr2019'));
      final texts = variants.map(_text).toList();
      expect(texts, contains(' Котик2019'));
      expect(texts, contains(' rJNBR2019'));
      expect(texts, contains('Rjnbr2019'));
      expect(texts, isNot(contains(' Rjnbr2019')));
      expect(texts.length, lessThanOrEqualTo(MasterVariants.limit));
      expect(texts.toSet().length, texts.length);
      expect(MasterVariants.of(secret('1234')), isEmpty);
    });

    test('Caps Lock — вход и одна попытка счётчика', () async {
      final store = InMemoryVaultStore();
      final vault = testVault(store, crypto);
      await vault.create(secret('Canary-Master-q7'), params: fastKdf);
      vault.lock();
      final result = await vault.unlock(secret('cANARY-mASTER-Q7'));
      expect(result.variantHit, isTrue);
      expect(vault.isUnlocked, isTrue);
      expect(VaultAttempts.decode(await store.readAttempts()).fails, 0);
      vault.lock();
      // Другая раскладка.
      final layout = await vault.unlock(secret(swapLayout('Canary-Master-q7')));
      expect(layout.variantHit, isTrue);
      vault.lock();
      // Верный ввод — без варианта.
      final exact = await vault.unlock(secret('Canary-Master-q7'));
      expect(exact.variantHit, isFalse);
      vault.lock();
      await expectLater(
        vault.unlock(secret('CANARY-wrong-xx')),
        throwsA(VaultError.wrongPassword),
      );
      expect(VaultAttempts.decode(await store.readAttempts()).fails, 1);
    });
  });

  test('«начать заново»: файл в архиве байт в байт, можно создать новое',
      () async {
    final store = InMemoryVaultStore();
    final clock = TestClock(DateTime.utc(2026, 11, 10, 9));
    final vault = testVault(store, crypto, clock: clock);
    await vault.create(secret(Canary.master), params: fastKdf);
    await vault.addEntry(service: 'Почта', password: secret(Canary.password));
    final before = (await store.readVault())!;
    final name = await vault.startOver();
    expect(name, 'forgotten-2026-11-10.relayvault');
    expect(vault.state, VaultState.notCreated);
    expect(await store.readPrevious(), isNull);
    expect(await store.archived(), <String>[name!]);
    expect(store.files['archive/$name'], before);
    await vault.create(secret('CANARY-master-new-2'), params: fastKdf);
    expect(vault.entries, isEmpty);
    expect(await vault.startOver(), 'forgotten-2026-11-10-2.relayvault');
  });

  test('«начать заново» на диске: archive/ с правами 700, .prev удалён',
      () async {
    final root = await Directory.systemTemp.createTemp('vault_archive_');
    addTearDown(() => root.delete(recursive: true));
    final store = FileVaultStore('${root.path}/vault');
    final vault = testVault(store, crypto);
    await vault.create(secret(Canary.master), params: fastKdf);
    await vault.addEntry(service: 'Почта', password: secret(Canary.password));
    final before = (await store.readVault())!;
    final name = (await vault.startOver())!;
    expect(await store.hasVault(), isFalse);
    expect(await store.readPrevious(), isNull);
    expect(await store.archived(), <String>[name]);
    expect(
      File('${root.path}/vault/archive/$name').readAsBytesSync(),
      before,
    );
    if (Platform.isLinux || Platform.isMacOS) {
      final mode = (await Directory('${root.path}/vault/archive').stat()).mode;
      expect(mode & 0x3F, 0, reason: 'archive/ — только владельцу');
    }
    await expectLater(store.archiveVault('../x'), throwsA(VaultError.io));
  });

  test('новая заметка: пароль прежний, srev растёт', () async {
    final vault = testVault(InMemoryVaultStore(), crypto);
    await vault.create(secret(Canary.master), params: fastKdf);
    final id = await vault.addEntry(
      service: 'Почта',
      password: secret(Canary.password),
      note: secret(Canary.note),
    );
    await vault.updateNote(id, secret('CANARY-note-2'));
    final read = await vault.readSecret(id);
    expect(_text(read.password), Canary.password);
    expect(_text(read.note), 'CANARY-note-2');
    read.wipe();
    expect(vault.entry(id)!.srev, 2);
  });

  test('фасад: названия для поиска — сервис, синонимы, хосты адресов',
      () async {
    final vault = testVault(InMemoryVaultStore(), crypto);
    final facade = VaultFacade(vault);
    await vault.create(secret(Canary.master), params: fastKdf);
    final id = await vault.addEntry(
      service: 'Почта',
      login: 'ivanov@mail.ru',
      urls: const <String>['https://www.mail.ru/login?x=1'],
      password: secret(Canary.password),
    );
    final ref = facade.ref(id)!;
    expect(ref.names, <String>['Почта', 'mail.ru']);
    expect(ref.hasLogin, isTrue);
    expect(ref.maskedLogin, 'iv***@mail.ru');
    expect(
      VaultFacade.hostOf('android://hash@com.vkontakte.android'),
      'com.vkontakte.android',
    );
    expect(facade.revealSeconds, 15);
    expect(facade.clipboardSeconds, 30);
    expect(facade.idleMinutes, 5);
    expect('$ref', 'VaultEntryRef($id)');
  });
}
