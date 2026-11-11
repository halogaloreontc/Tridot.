// Параллельные вызовы хранилища паролей (ADR-014, раздел 11, группа 3,
// исправления ревью): попытки мастер-пароля идут по одной и все попадают в
// счётчик D25; запирание посреди открытия не оставляет ключи в памяти;
// параллельные записи не затирают друг друга.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/passwords/vault.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_errors.dart';
import 'package:local_assistant/core/passwords/vault_format.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';
import 'package:path/path.dart' as p;

import 'vault_test_support.dart';

void main() {
  late SodiumVaultCrypto crypto;

  setUpAll(() async {
    crypto = await testCrypto();
  });

  Future<Object?> outcome(Future<Object?> future) =>
      future.then<Object?>((_) => null, onError: (Object e) => e);

  test('20 параллельных неверных вводов — все в счётчике, дальше пауза',
      () async {
    final store = InMemoryVaultStore();
    final first = testVault(store, crypto);
    await first.create(secret(Canary.master), params: fastKdf);
    first.lock();
    final vault = testVault(store, crypto);
    final results = await Future.wait(<Future<Object?>>[
      for (var i = 0; i < 20; i++)
        outcome(vault.unlock(secret('CANARY-wrong-$i'))),
    ]);
    expect(
      results.where((Object? r) => r == VaultError.wrongPassword),
      hasLength(VaultAttempts.freeAttempts),
    );
    expect(
      results.whereType<VaultRateLimited>(),
      hasLength(20 - VaultAttempts.freeAttempts),
    );
    expect(
      VaultAttempts.decode(store.files[FileVaultStore.attemptsName]).fails,
      VaultAttempts.freeAttempts,
    );
    // Верный пароль сразу после — тоже ждёт паузу.
    expect(
      await outcome(vault.unlock(secret(Canary.master))),
      isA<VaultRateLimited>(),
    );
    expect(vault.isUnlocked, isFalse);
  });

  test('параллельные verifyMaster — тот же счётчик', () async {
    final store = InMemoryVaultStore();
    final vault = testVault(store, crypto);
    await vault.create(secret(Canary.master), params: fastKdf);
    final results = await Future.wait(<Future<Object?>>[
      for (var i = 0; i < 8; i++)
        vault
            .verifyMaster(secret('CANARY-wrong-$i'))
            .then<Object?>((bool ok) => ok, onError: (Object e) => e),
    ]);
    expect(results.where((Object? r) => r == false), hasLength(5));
    expect(results.whereType<VaultRateLimited>(), hasLength(3));
  });

  test('попытка засчитана до вывода ключа (убили посреди Argon2id)', () async {
    final store = InMemoryVaultStore();
    final first = testVault(store, crypto);
    await first.create(secret(Canary.master), params: fastKdf);
    first.lock();
    final vault = testVault(store, crypto);
    final pending = vault.unlock(secret('CANARY-wrong'));
    // Ждём, пока появится отметка о попытке, — ключ ещё не выведен
    // (или уже: тогда в счётчике та же единица).
    for (var i = 0; i < 50; i++) {
      final fails =
          VaultAttempts.decode(store.files[FileVaultStore.attemptsName]).fails;
      if (fails > 0) break;
      await Future<void>.delayed(Duration.zero);
    }
    expect(
      VaultAttempts.decode(store.files[FileVaultStore.attemptsName]).fails,
      1,
    );
    expect(await outcome(pending), VaultError.wrongPassword);
    expect(
      VaultAttempts.decode(store.files[FileVaultStore.attemptsName]).fails,
      1,
    );
  });

  test('запирание и выключение посреди открытия — ключей в памяти нет',
      () async {
    final store = InMemoryVaultStore();
    final first = testVault(store, crypto);
    await first.create(secret(Canary.master), params: fastKdf);
    await first.addEntry(service: 'Почта', password: secret(Canary.password));
    first.lock();
    // Запираем после разного числа микрозадач: в любой точке открытия
    // итог один — заперто, записей не видно.
    var raced = 0;
    for (var yields = 0; yields < 80; yields++) {
      final vault = testVault(store, crypto);
      await vault.load();
      final pending = outcome(vault.unlock(secret(Canary.master)));
      for (var i = 0; i < yields; i++) {
        await Future<void>.value();
      }
      if (VaultAttempts.decode(store.files[FileVaultStore.attemptsName]).fails >
          0) {
        raced++; // заперли, пока шла проверка мастер-пароля
      }
      vault
        ..onAppState(VaultAppState.paused)
        ..setEnabled(false);
      final error = await pending;
      expect(vault.state, VaultState.disabled, reason: 'шаг $yields');
      expect(vault.isUnlocked, isFalse, reason: 'шаг $yields');
      expect(vault.entries, isEmpty, reason: 'шаг $yields');
      expect(vault.lockAt, isNull, reason: 'шаг $yields');
      expect(error, anyOf(isNull, VaultError.locked), reason: 'шаг $yields');
    }
    expect(raced, greaterThan(0), reason: 'окно гонки не задето');
    // Файл цел: открывается.
    final fresh = testVault(store, crypto);
    await fresh.unlock(secret(Canary.master));
    expect(fresh.entries, hasLength(1));
  });

  test('выключение посреди create — ключей в памяти нет', () async {
    final store = InMemoryVaultStore();
    final vault = testVault(store, crypto);
    await vault.load();
    final pending =
        outcome(vault.create(secret(Canary.master), params: fastKdf));
    for (var i = 0; i < 3; i++) {
      await Future<void>.value();
    }
    vault.setEnabled(false);
    final error = await pending;
    expect(error, anyOf(isNull, VaultError.locked));
    expect(vault.isUnlocked, isFalse);
    expect(vault.entries, isEmpty);
  });

  test('двойной ввод: фон во время первого Argon2id запирает оба', () async {
    final store = InMemoryVaultStore();
    final first = testVault(store, crypto);
    await first.create(secret(Canary.master), params: fastKdf);
    first.lock();
    late Vault vault;
    var paused = false;
    // Попытка засчитана (fails=1) — следующий шаг вывод ключа: уходим в фон.
    void onAttempts(VaultAttempts attempts) {
      if (attempts.fails == 1 && !paused) {
        paused = true;
        vault.onAppState(VaultAppState.paused);
      }
    }

    final hooked = _HookStore(store, onAttempts: onAttempts);
    vault = testVault(hooked, crypto);
    await vault.load();
    final one = outcome(vault.unlock(secret(Canary.master)));
    final two = outcome(vault.unlock(secret(Canary.master)));
    expect(await one, VaultError.locked);
    expect(paused, isTrue);
    expect(await two, VaultError.locked);
    expect(vault.isUnlocked, isFalse);
    expect(vault.state, VaultState.locked);
    expect(vault.lockAt, isNull);
  });

  test('фон сразу после unlock() (0 и 1 микрозадача) — заперто', () async {
    final store = InMemoryVaultStore();
    final first = testVault(store, crypto);
    await first.create(secret(Canary.master), params: fastKdf);
    first.lock();
    for (var yields = 0; yields < 2; yields++) {
      final vault = testVault(store, crypto);
      await vault.load();
      final pending = outcome(vault.unlock(secret(Canary.master)));
      for (var i = 0; i < yields; i++) {
        await Future<void>.value();
      }
      vault.onAppState(VaultAppState.paused);
      expect(await pending, VaultError.locked, reason: 'шаг $yields');
      expect(vault.isUnlocked, isFalse, reason: 'шаг $yields');
      expect(vault.lockAt, isNull, reason: 'шаг $yields');
    }
    // Ввод после запирания — открывает.
    final vault = testVault(store, crypto);
    await vault.unlock(secret(Canary.master));
    expect(vault.isUnlocked, isTrue);
  });

  test('фон сразу после create() — хранилище не остаётся открытым', () async {
    for (var yields = 0; yields < 2; yields++) {
      final store = InMemoryVaultStore();
      final vault = testVault(store, crypto);
      await vault.load();
      final pending =
          outcome(vault.create(secret(Canary.master), params: fastKdf));
      for (var i = 0; i < yields; i++) {
        await Future<void>.value();
      }
      vault.onAppState(VaultAppState.paused);
      expect(await pending, VaultError.locked, reason: 'шаг $yields');
      expect(vault.isUnlocked, isFalse, reason: 'шаг $yields');
      expect(vault.lockAt, isNull, reason: 'шаг $yields');
    }
  });

  test('две параллельные addEntry — обе в памяти и в файле', () async {
    final store = InMemoryVaultStore();
    final vault = testVault(store, crypto);
    await vault.create(secret(Canary.master), params: fastKdf);
    final ids = await Future.wait(<Future<String>>[
      vault.addEntry(service: 'Почта', password: secret('CANARY-s1')),
      vault.addEntry(service: 'Форум', password: secret('CANARY-s2')),
    ]);
    expect(vault.entries.map((VaultEntry e) => e.id), unorderedEquals(ids));
    vault.lock();
    final fresh = testVault(store, crypto);
    await fresh.unlock(secret(Canary.master));
    expect(fresh.entries.map((VaultEntry e) => e.id), unorderedEquals(ids));
  });

  test('FileVaultStore: три параллельные addEntry — все на диске', () async {
    final temp = await Directory.systemTemp.createTemp('vault_parallel_');
    addTearDown(() => temp.delete(recursive: true));
    for (var round = 0; round < 5; round++) {
      final dir = p.join(temp.path, 'r$round');
      final vault = testVault(FileVaultStore(dir), crypto);
      await vault.create(secret(Canary.master), params: fastKdf);
      final ids = await Future.wait(<Future<String>>[
        for (var i = 0; i < 3; i++)
          vault.addEntry(service: 'S$i', password: secret('CANARY-s$i')),
      ]);
      expect(vault.entries.map((VaultEntry e) => e.id), unorderedEquals(ids));
      vault.lock();
      final fresh = testVault(FileVaultStore(dir), crypto);
      await fresh.unlock(secret(Canary.master));
      expect(
        fresh.entries.map((VaultEntry e) => e.id),
        unorderedEquals(ids),
        reason: 'круг $round',
      );
      for (final id in ids) {
        (await fresh.readSecret(id)).wipe();
      }
    }
  });

  test('ошибка одной операции не останавливает очередь', () async {
    final store = InMemoryVaultStore();
    final vault = testVault(store, crypto);
    await vault.create(secret(Canary.master), params: fastKdf);
    store.failNextWrite = true;
    final failed = outcome(
      vault.addEntry(service: 'Почта', password: secret('CANARY-s1')),
    );
    final ok = vault.addEntry(service: 'Форум', password: secret('CANARY-s2'));
    expect(await failed, VaultError.io);
    final id = await ok;
    expect(vault.entries.single.id, id);
  });
}

/// Хранилище в памяти с крючком на запись счётчика попыток.
final class _HookStore implements VaultStore {
  _HookStore(this.inner, {required this.onAttempts});

  final InMemoryVaultStore inner;
  final void Function(VaultAttempts attempts) onAttempts;

  @override
  Future<void> writeAttempts(Uint8List bytes) async {
    await inner.writeAttempts(bytes);
    onAttempts(VaultAttempts.decode(bytes));
  }

  @override
  Future<Uint8List?> readAttempts() => inner.readAttempts();

  @override
  Future<bool> hasVault() => inner.hasVault();

  @override
  Future<Uint8List?> readVault() => inner.readVault();

  @override
  Future<Uint8List?> readPrevious() => inner.readPrevious();

  @override
  Future<void> writeVault(Uint8List bytes, {bool replacePrevious = false}) =>
      inner.writeVault(bytes, replacePrevious: replacePrevious);

  @override
  Future<void> writePrevious(Uint8List bytes) => inner.writePrevious(bytes);

  @override
  Future<List<int>> backupVersions() => inner.backupVersions();

  @override
  Future<Uint8List?> readBackup(int version) => inner.readBackup(version);

  @override
  Future<void> writeBackup(int version, Uint8List bytes) =>
      inner.writeBackup(version, bytes);

  @override
  Future<void> deleteBackup(int version) => inner.deleteBackup(version);

  @override
  Future<void> removeTemporary() => inner.removeTemporary();
  @override
  Future<void> archiveVault(String name) => inner.archiveVault(name);
  @override
  Future<List<String>> archived() => inner.archived();
}
