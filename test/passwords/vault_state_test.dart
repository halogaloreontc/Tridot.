// Состояния хранилища паролей (ADR-014, раздел 11, группа 3): простой,
// предел 60 мин, paused/hidden → lock, inactive → только спрятать,
// выключение навыка через ExtensionRegistry.apply, пауза после 5 ошибок
// (переживает перезапуск и перевод часов), мастер-пароль через 72 ч.
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/passwords/secret_bytes.dart';
import 'package:local_assistant/core/passwords/vault.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_errors.dart';
import 'package:local_assistant/core/passwords/vault_format.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';
import 'package:local_assistant/core/services/clock.dart';

import 'vault_test_support.dart';

/// Часы, идущие вместе с `fakeAsync`.
final class _FakeClock implements Clock {
  _FakeClock(this.async, this.start);

  final FakeAsync async;
  final DateTime start;

  @override
  DateTime now() => start.add(async.elapsed);
}

/// Криптография, которая считает живые ключи.
final class _TrackingCrypto implements VaultCrypto {
  _TrackingCrypto(this.inner);

  final SodiumVaultCrypto inner;
  final List<VaultKey> keys = <VaultKey>[];

  int get alive => keys.where((VaultKey k) => !k.isDisposed).length;

  VaultKey _track(VaultKey key) {
    keys.add(key);
    return key;
  }

  @override
  Uint8List bytes(int length) => inner.bytes(length);
  @override
  int uniform(int upperBound) => inner.uniform(upperBound);
  @override
  Future<VaultKey> derive(
    SecretBytes password,
    Uint8List salt,
    VaultKdfParams params,
  ) async =>
      _track(await inner.derive(password, salt, params));
  @override
  Future<Duration> measure(VaultKdfParams params) => inner.measure(params);
  @override
  VaultKey randomKey() => _track(inner.randomKey());
  @override
  VaultKey importKey(SecretBytes bytes) => _track(inner.importKey(bytes));
  @override
  SecretBytes exportKey(VaultKey key) => inner.exportKey(key);
  @override
  VaultKey deriveKey(VaultKey master, int id) =>
      _track(inner.deriveKey(master, id));
  @override
  SealedBox seal(VaultKey key, Uint8List message, Uint8List ad) =>
      inner.seal(key, message, ad);
  @override
  Uint8List? open(VaultKey key, SealedBox box, Uint8List ad) =>
      inner.open(key, box, ad);
  @override
  SealedBox sealKey(VaultKey kek, VaultKey key, Uint8List ad) =>
      inner.sealKey(kek, key, ad);
  @override
  VaultKey? openKey(VaultKey kek, SealedBox box, Uint8List ad) {
    final key = inner.openKey(kek, box, ad);
    return key == null ? null : _track(key);
  }

  @override
  Uint8List keyedHash(VaultKey key, Uint8List message) =>
      inner.keyedHash(key, message);
  @override
  bool equal(Uint8List a, Uint8List b) => inner.equal(a, b);
}

/// Навык «Пароли» для реестра: только паспорт.
final class _PasswordsStub implements Connector {
  @override
  ConnectorInfo get info => const ConnectorInfo(
        id: 'passwords',
        title: 'Пароли',
        description: 'Хранилище паролей на устройстве.',
        kind: ExtensionKind.skill,
        defaultEnabled: false,
        access: ConnectorAccess.readWrite,
        sensitive: true,
      );

  @override
  ConnectorMatch? match(Utterance utterance) => null;

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async =>
      throw UnimplementedError();
}

void main() {
  late SodiumVaultCrypto sodium;
  final start = DateTime.utc(2026, 11, 10, 9);

  setUpAll(() async {
    sodium = await testCrypto();
  });

  /// Открытое хранилище внутри `fakeAsync`.
  (Vault, InMemoryVaultStore, _TrackingCrypto) openVault(
    FakeAsync async, {
    InMemoryVaultStore? store,
  }) {
    final files = store ?? InMemoryVaultStore();
    final crypto = _TrackingCrypto(sodium);
    final vault = Vault(
      store: files,
      crypto: crypto,
      clock: _FakeClock(async, start),
      allowTestingKdf: true,
    );
    if (store == null) {
      vault.create(secret(Canary.master), params: fastKdf);
    } else {
      vault.unlock(secret(Canary.master));
    }
    async.flushMicrotasks();
    expect(vault.state, VaultState.unlocked);
    return (vault, files, crypto);
  }

  test('простой 5 мин запирает, действие продлевает', () {
    fakeAsync((FakeAsync async) {
      final (vault, _, crypto) = openVault(async);
      final signals = <VaultSignal>[];
      vault.addListener(signals.add);
      async.elapse(const Duration(minutes: 4));
      vault.touch();
      async.elapse(const Duration(minutes: 4));
      expect(vault.state, VaultState.unlocked);
      async.elapse(const Duration(minutes: 1, seconds: 1));
      expect(vault.state, VaultState.locked);
      expect(signals, contains(VaultSignal.locked));
      expect(crypto.alive, 0, reason: 'все SecureKey освобождены');
      expect(vault.entries, isEmpty);
    });
  });

  test('жёсткий предел 60 мин даже при действиях', () {
    fakeAsync((FakeAsync async) {
      final (vault, _, _) = openVault(async);
      for (var i = 0; i < 14; i++) {
        async.elapse(const Duration(minutes: 4));
        vault.touch();
      }
      expect(vault.state, VaultState.unlocked);
      async.elapse(const Duration(minutes: 4, seconds: 1));
      expect(vault.state, VaultState.locked);
    });
  });

  test('простой из prefs индекса не используется, пока его нет: 5 мин', () {
    fakeAsync((FakeAsync async) {
      final (vault, _, _) = openVault(async);
      expect(vault.idleTimeout, const Duration(minutes: 5));
      expect(vault.lockAt, start.add(const Duration(minutes: 5)));
    });
  });

  test('paused и hidden запирают, inactive только прячет', () {
    fakeAsync((FakeAsync async) {
      for (final state in <VaultAppState>[
        VaultAppState.paused,
        VaultAppState.hidden,
        VaultAppState.detached,
      ]) {
        final (vault, _, crypto) = openVault(async);
        vault.onAppState(state);
        expect(vault.state, VaultState.locked, reason: state.name);
        expect(crypto.alive, 0);
      }
      final (vault, _, _) = openVault(async);
      final signals = <VaultSignal>[];
      vault.addListener(signals.add);
      vault.onAppState(VaultAppState.inactive);
      expect(vault.state, VaultState.unlocked);
      expect(signals, <VaultSignal>[VaultSignal.hide]);
    });
  });

  test('сон устройства: таймер опоздал — запирает при возврате', () {
    fakeAsync((FakeAsync async) {
      final clock = TestClock(start);
      final vault = Vault(
        store: InMemoryVaultStore(),
        crypto: sodium,
        clock: clock,
        allowTestingKdf: true,
      );
      vault.create(secret(Canary.master), params: fastKdf);
      async.flushMicrotasks();
      clock.advance(const Duration(hours: 2));
      vault.onAppState(VaultAppState.resumed);
      expect(vault.state, VaultState.locked);
    });
  });

  test('выключение навыка через ExtensionRegistry.apply: lock, файл тот же',
      () {
    fakeAsync((FakeAsync async) {
      final registry = ExtensionRegistry(
        connectors: <Connector>[_PasswordsStub()],
      );
      registry.apply(registry.choiceWith('passwords', true));
      final (vault, store, crypto) = openVault(async);
      vault.followExtension(registry, 'passwords');
      expect(vault.state, VaultState.unlocked);
      final before = Uint8List.fromList(store.files[FileVaultStore.vaultName]!);
      registry.apply(registry.choiceWith('passwords', false));
      expect(vault.state, VaultState.disabled);
      expect(crypto.alive, 0);
      expect(store.files[FileVaultStore.vaultName], before);
      Object? error;
      vault.unlock(secret(Canary.master)).catchError((Object e) {
        error = e;
        return const VaultUnlockResult(rev: 0, rolledBack: false);
      });
      async.flushMicrotasks();
      expect(error, VaultError.locked);
      registry.apply(registry.choiceWith('passwords', true));
      expect(vault.state, VaultState.locked);
    });
  });

  test('пауза после 5 ошибок, переживает перезапуск и перевод часов', () {
    fakeAsync((FakeAsync async) {
      final (first, store, _) = openVault(async);
      first.lock();
      final clock = TestClock(start);
      Vault fresh() => Vault(
            store: store,
            crypto: sodium,
            clock: clock,
            allowTestingKdf: true,
          );
      Object? attempt(Vault vault, String password) {
        Object? error;
        vault
            .unlock(secret(password))
            .then<void>((_) {}, onError: (Object e) => error = e);
        async.flushMicrotasks();
        return error;
      }

      var vault = fresh();
      for (var i = 0; i < 5; i++) {
        expect(attempt(vault, 'CANARY-wrong-$i'), VaultError.wrongPassword);
      }
      // Шестая попытка — даже верная — ждёт 30 с.
      final blocked = attempt(vault, Canary.master);
      expect(blocked, isA<VaultRateLimited>());
      expect(
        (blocked! as VaultRateLimited).until,
        start.add(const Duration(seconds: 30)),
      );
      // «Перезапуск»: новый Vault на той же папке — пауза на месте.
      vault = fresh();
      expect(attempt(vault, Canary.master), isA<VaultRateLimited>());
      // Часы назад на сутки: пауза отсчитывается заново, а не снимается.
      clock.value = start.subtract(const Duration(days: 1));
      final rolled = attempt(fresh(), Canary.master);
      expect(rolled, isA<VaultRateLimited>());
      expect(
        (rolled! as VaultRateLimited).until,
        clock.value.add(const Duration(seconds: 30)),
      );
      clock.advance(const Duration(seconds: 31));
      // Ещё ошибка — пауза удваивается.
      expect(attempt(fresh(), 'CANARY-wrong-6'), VaultError.wrongPassword);
      final doubled = attempt(fresh(), Canary.master)! as VaultRateLimited;
      expect(doubled.until, clock.value.add(const Duration(minutes: 1)));
      clock.advance(const Duration(minutes: 2));
      final ok = fresh();
      expect(attempt(ok, Canary.master), isNull);
      expect(ok.state, VaultState.unlocked);
      // Верный ввод сбрасывает счётчик.
      expect(VaultAttempts.decode(store.files['attempts.json']).fails, 0);
    });
  });

  test('пауза: 30 с, удвоение, не больше 15 мин', () {
    expect(VaultAttempts.pauseFor(4), Duration.zero);
    expect(VaultAttempts.pauseFor(5), const Duration(seconds: 30));
    expect(VaultAttempts.pauseFor(6), const Duration(minutes: 1));
    expect(VaultAttempts.pauseFor(9), const Duration(minutes: 8));
    expect(VaultAttempts.pauseFor(10), const Duration(minutes: 15));
    expect(VaultAttempts.pauseFor(50), const Duration(minutes: 15));
  });

  test('мастер-пароль обязателен через 72 ч; проверка — тот же счётчик', () {
    fakeAsync((FakeAsync async) {
      final store = InMemoryVaultStore();
      final clock = TestClock(start);
      final vault = Vault(
        store: store,
        crypto: sodium,
        clock: clock,
        allowTestingKdf: true,
        policy: const VaultPolicy(
          idle: Duration(days: 30),
          hardLimit: Duration(days: 30),
        ),
      );
      vault.create(secret(Canary.master), params: fastKdf);
      async.flushMicrotasks();
      expect(vault.masterDue, isFalse);
      clock.advance(const Duration(hours: 71));
      expect(vault.masterDue, isFalse);
      clock.advance(const Duration(hours: 1));
      expect(vault.masterDue, isTrue);
      bool? result;
      vault.verifyMaster(secret('CANARY-wrong')).then((bool r) => result = r);
      async.flushMicrotasks();
      expect(result, isFalse);
      expect(VaultAttempts.decode(store.files['attempts.json']).fails, 1);
      vault.verifyMaster(secret(Canary.master)).then((bool r) => result = r);
      async.flushMicrotasks();
      expect(result, isTrue);
      expect(vault.masterDue, isFalse);
      expect(vault.masterTypedAt, clock.value);
    });
  });

  test('без файла — notCreated, после создания — открыто', () {
    fakeAsync((FakeAsync async) {
      final vault = testVault(InMemoryVaultStore(), sodium);
      vault.load();
      async.flushMicrotasks();
      expect(vault.state, VaultState.notCreated);
      Object? error;
      vault.readSecret('x').catchError((Object e) {
        error = e;
        return VaultSecret(SecretBytes.empty(), SecretBytes.empty());
      });
      async.flushMicrotasks();
      expect(error, VaultError.locked);
    });
  });
}
