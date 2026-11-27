// Защита сейфа устройством, код восстановления, ПИН-код и биометрия по
// желанию (ADR-025). Значения только синтетические: пароли — CANARY,
// ПИН-код считается в canaryPin().
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/passwords/secret_bytes.dart';
import 'package:local_assistant/core/passwords/secret_guard.dart';
import 'package:local_assistant/core/passwords/vault.dart';
import 'package:local_assistant/core/passwords/vault_codes.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_device_key.dart';
import 'package:local_assistant/core/passwords/vault_errors.dart';
import 'package:local_assistant/core/passwords/vault_format.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';

import 'vault_test_support.dart';

Map<String, Object?> _json(Uint8List bytes) =>
    jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;

Uint8List _bytes(Map<String, Object?> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

String _text(SecretBytes bytes) => utf8.decode(bytes.unsafeBytes);

void main() {
  late SodiumVaultCrypto crypto;

  setUpAll(() async {
    crypto = await testCrypto();
  });

  /// Новый защищённый сейф с одной записью; код восстановления — текстом.
  Future<(Vault, InMemoryVaultStore, FakeDeviceKey, String, TestClock)>
      protectedVault({FakeDeviceKey? key}) async {
    final store = InMemoryVaultStore();
    final device = key ?? FakeDeviceKey();
    final clock = TestClock();
    final vault = testVault(store, crypto, deviceKey: device, clock: clock);
    final code = await vault.createProtected(params: fastKdf);
    final text = _text(code);
    code.wipe();
    await vault.addEntry(
      service: 'Почта',
      password: secret(Canary.password),
      note: secret(Canary.note),
    );
    return (vault, store, device, text, clock);
  }

  Future<String> readPassword(Vault vault) async {
    final secret = await vault.readSecret(vault.entries.single.id);
    final text = _text(secret.password);
    secret.wipe();
    return text;
  }

  group('код восстановления', () {
    test('25 знаков Crockford пятью группами, каждый раз новый', () {
      final a = RecoveryCode.generate(crypto);
      final b = RecoveryCode.generate(crypto);
      expect(
        RegExp(r'^([0-9A-HJKMNP-TV-Z]{5}-){4}[0-9A-HJKMNP-TV-Z]{5}$')
            .hasMatch(_text(a)),
        isTrue,
      );
      expect(_text(a), isNot(_text(b)));
      a.wipe();
      b.wipe();
    });

    test('ввод приводится к виду кода: регистр, O/0, I/L/1, пробелы', () {
      const display = 'ABCDE-FGH01-JKMNP-QRSTV-WXYZ0';
      SecretBytes? canon(String input) => RecoveryCode.canonical(secret(input));
      expect(_text(canon(display)!), 'ABCDEFGH01JKMNPQRSTVWXYZ0');
      expect(
        _text(canon('abcde fghO1 jkmnp qrstv wxyzo')!),
        'ABCDEFGH01JKMNPQRSTVWXYZ0',
      );
      expect(
        _text(canon('ABCDE-FGHOI-JKMNP-QRSTV-WXYZL')!),
        'ABCDEFGH01JKMNPQRSTVWXYZ1',
      );
      expect(canon('ABCDE-FGH01-JKMNP-QRSTV'), isNull, reason: 'короткий');
      expect(canon('ABCDE-FGH01-JKMNP-QRSTV-WXYZU'), isNull, reason: 'U');
      expect(canon('${display}0'), isNull, reason: 'длинный');
    });

    test('набранное в русской раскладке переводится по клавишам', () {
      // «F» в русской раскладке — «А».
      final canon = RecoveryCode.canonical(
        secret('ААААА-11111-22222-33333-44444'),
      )!;
      expect(_text(canon), 'FFFFF11111222223333344444');
    });

    test('похоже на код: группы через дефис и сплошные 25 знаков', () {
      expect(
        RecoveryCode.looksLike('код ABCDE-FGH01-JKMNP-QRSTV-WXYZ0'),
        isTrue,
      );
      expect(RecoveryCode.looksLike('abcde fgh01 jkmnp qrstv wxyz0'), isTrue);
      expect(RecoveryCode.looksLike('ABCDEFGH01JKMNPQRSTVWXYZ0'), isTrue);
      expect(RecoveryCode.looksLike('привет, как дела'), isFalse);
      expect(
        RecoveryCode.looksLike('abcdefghijklmnopqrstuvwxy'),
        isFalse,
        reason: 'одни буквы — слово, не код',
      );
    });
  });

  group('защита устройством', () {
    test('создание: слот dev, pw_kind rc, код не подтверждён', () async {
      final (vault, store, device, code, _) = await protectedVault();
      final json = _json((await store.readVault())!);
      expect(json['v'], VaultFormat.version);
      expect(json['pw_kind'], VaultFormat.pwRecovery);
      expect((json['slots']! as Map<String, Object?>).keys, <String>['dev']);
      expect(device.aliases, hasLength(1));
      expect(vault.isProtected, isTrue);
      expect(vault.recoveryConfirmed, isFalse);
      await vault.confirmRecovery();
      expect(vault.recoveryConfirmed, isTrue);
      expect(code, hasLength(29));
    });

    test('запереть и открыть без ввода, пока ключ устройства на месте',
        () async {
      final (vault, store, device, _, _) = await protectedVault();
      vault.lock();
      final info = await vault.lockInfo();
      expect(info!.device, isTrue);
      expect(info.usesMaster, isFalse);
      final again = testVault(store, crypto, deviceKey: device);
      final result = await again.unlockDevice();
      expect(result.recovered, isFalse);
      expect(await readPassword(again), Canary.password);
      expect(device.prompts, 0);
    });

    test('без ключа устройства не открыть: другое устройство', () async {
      final (vault, store, _, _, _) = await protectedVault();
      vault.lock();
      final original = (await store.readVault())!;
      final other = testVault(store, crypto, deviceKey: FakeDeviceKey());
      await expectLater(
        other.unlockDevice(),
        throwsA(VaultError.deviceKeyLost),
      );
      // Здесь ключа нет и не будет: слот в этой копии снят.
      expect((await other.lockInfo())!.device, isFalse);
      store.files[FileVaultStore.vaultName] = original;
      final otherKind = testVault(
        store,
        crypto,
        deviceKey: FakeDeviceKey(kind: VaultDeviceKinds.fileKey),
      );
      await expectLater(
        otherKind.unlockDevice(),
        throwsA(VaultError.deviceKeyLost),
      );
    });

    test('ключ потерян: слот снят, открывает код, ключ создан заново',
        () async {
      final (vault, store, device, code, _) = await protectedVault();
      vault.lock();
      final old = device.aliases.single;
      device.lose(old);
      final again = testVault(store, crypto, deviceKey: device);
      await expectLater(
        again.unlockDevice(),
        throwsA(VaultError.deviceKeyLost),
      );
      expect((await again.lockInfo())!.device, isFalse);
      // Код в другом написании: строчные, без дефисов, O вместо 0.
      final typed =
          code.toLowerCase().replaceAll('-', ' ').replaceAll('0', 'o');
      final result = await again.unlock(secret(typed));
      expect(result.recovered, isTrue);
      expect(await readPassword(again), Canary.password);
      expect(device.aliases, hasLength(1));
      expect(device.aliases.single, isNot(old));
      again.lock();
      await testVault(store, crypto, deviceKey: device).unlockDevice();
    });

    test('сбой хранилища ключей не разрушает: ключ не удалён, копии целы',
        () async {
      final (vault, store, device, _, _) = await protectedVault();
      vault.lock();
      final alias = device.aliases.single;
      // Временный сбой (DPAPI, Keystore занят) — deviceKey, слот на месте.
      device.nextMac = DeviceKeyFailure.unavailable;
      await expectLater(
        testVault(store, crypto, deviceKey: device).unlockDevice(),
        throwsA(VaultError.deviceKey),
      );
      final info = await testVault(store, crypto, deviceKey: device).lockInfo();
      expect(info!.device, isTrue);
      // Сбой, названный «потерей»: слот снят только из основного файла,
      // ключ не удалён, vault.prev со слотом остаётся для отката.
      final before = store.files[FileVaultStore.vaultName]!;
      device.nextMac = DeviceKeyFailure.lost;
      await expectLater(
        testVault(store, crypto, deviceKey: device).unlockDevice(),
        throwsA(VaultError.deviceKeyLost),
      );
      expect(device.aliases, contains(alias));
      final prev = store.files[FileVaultStore.previousName]!;
      expect(_json(prev)['slots'], contains('dev'));
      store.files[FileVaultStore.vaultName] = before;
      final back = testVault(store, crypto, deviceKey: device);
      await back.unlockDevice();
      expect(await readPassword(back), Canary.password);
    });

    test('подмена слота (имя ключа, вид) не открывает', () async {
      final (vault, store, device, _, _) = await protectedVault();
      vault.lock();
      final original = (await store.readVault())!;
      final extra = await device.create();
      final json = _json(original);
      final slots = json['slots']! as Map<String, Object?>;
      final dev = Map<String, Object?>.of(slots['dev']! as Map<String, Object?>)
        ..['alias'] = extra;
      store.files[FileVaultStore.vaultName] = _bytes(<String, Object?>{
        ...json,
        'slots': <String, Object?>{'dev': dev},
      });
      await expectLater(
        testVault(store, crypto, deviceKey: device).unlockDevice(),
        throwsA(VaultError.corrupt),
      );
    });

    test('неверный код — счётчик D25, паузы как у мастер-пароля', () async {
      final (vault, store, device, _, clock) = await protectedVault();
      vault.lock();
      final again = testVault(store, crypto, deviceKey: device, clock: clock);
      for (var i = 0; i < 4; i++) {
        await expectLater(
          again.unlock(secret('ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ-ZZZZ$i')),
          throwsA(VaultError.wrongPassword),
        );
      }
      await expectLater(
        again.unlock(secret('ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ-ZZZZ9')),
        throwsA(VaultError.wrongPassword),
      );
      expect(
        again.unlock(secret('ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ-ZZZZ8')),
        throwsA(isA<VaultRateLimited>()),
      );
      // Не код вовсе — попытку не тратит.
      expect(
        VaultAttempts.decode(await store.readAttempts()).fails,
        5,
      );
    });

    test('новый код: прежний больше не открывает, prev перезаписан', () async {
      final (vault, store, device, code, _) = await protectedVault();
      final fresh = await vault.regenerateRecovery(const DeviceProof());
      expect(fresh.rotated, isTrue);
      final next = _text(fresh.code);
      fresh.code.wipe();
      expect(next, isNot(code));
      expect(vault.recoveryConfirmed, isFalse);
      vault.lock();
      device.lose(device.aliases.single);
      final again = testVault(store, crypto, deviceKey: device);
      await expectLater(
        again.unlock(secret(code)),
        throwsA(VaultError.wrongPassword),
      );
      // Копия в .prev — тоже уже с новым кодом.
      final prev = InMemoryVaultStore()
        ..files[FileVaultStore.vaultName] = (await store.readPrevious())!;
      await expectLater(
        testVault(prev, crypto, deviceKey: device).unlock(secret(code)),
        throwsA(VaultError.wrongPassword),
      );
      final result = await again.unlock(secret(next));
      expect(result.recovered, isTrue);
    });

    test(
        'новый код меняет ключ сейфа: старая копия + старый код — не к '
        'новым данным', () async {
      final (vault, store, device, code, _) = await protectedVault();
      // Старая копия файла (синхронизация, копия папки) до смены кода.
      final stale = Uint8List.fromList(store.files[FileVaultStore.vaultName]!);
      final oldAlias = device.aliases.single;
      final fresh = await vault.regenerateRecovery(const DeviceProof());
      fresh.code.wipe();
      expect(device.aliases.contains(oldAlias), isFalse);
      await vault.addEntry(
        service: 'Банк',
        password: secret('CANARY-pw-new-Q3m'),
      );
      vault.lock();
      // Ключ сейфа из старой копии старым кодом…
      final old = InMemoryVaultStore()..files[FileVaultStore.vaultName] = stale;
      final oldVault = testVault(old, crypto, deviceKey: FakeDeviceKey());
      await oldVault.unlock(secret(code));
      // …не подходит к новому файлу: подставим текущие шифротексты.
      final current = _json(store.files[FileVaultStore.vaultName]!);
      final mixed = _json(stale)
        ..['secrets'] = current['secrets']
        ..['index'] = current['index'];
      final probe = InMemoryVaultStore()
        ..files[FileVaultStore.vaultName] = _bytes(mixed);
      await expectLater(
        testVault(probe, crypto, deviceKey: FakeDeviceKey())
            .unlock(secret(code)),
        throwsA(anyOf(VaultError.corrupt, VaultError.wrongPassword)),
      );
      // Новый сейф по-прежнему открывается устройством.
      final again = testVault(store, crypto, deviceKey: device);
      await again.unlockDevice();
      expect(again.entries, hasLength(2));
    });

    test('новый код при ПИН-коде: ПИН-код сохранён, ключ сейфа новый',
        () async {
      final (vault, store, device, _, _) = await protectedVault();
      await vault.enablePin(secret(canaryPin()));
      final oldPin = device.aliases.single;
      final fresh =
          await vault.regenerateRecovery(PinProof(secret(canaryPin())));
      expect(fresh.rotated, isTrue);
      fresh.code.wipe();
      expect(device.aliases.contains(oldPin), isFalse);
      vault.lock();
      final again = testVault(store, crypto, deviceKey: device);
      expect((await again.lockInfo())!.pin, isTrue);
      await again.unlockPin(secret(canaryPin()));
      expect(await readPassword(again), Canary.password);
    });

    test('новый код при ПИН-коде, подтверждённый отпечатком: ключ прежний',
        () async {
      final (vault, _, device, _, _) = await protectedVault();
      device.bio = true;
      await vault.enablePin(secret(canaryPin()));
      await vault.enableBio('включить');
      final fresh = await vault.regenerateRecovery(const BioProof('код'));
      expect(fresh.rotated, isFalse);
      fresh.code.wipe();
    });

    test('сбой записи .bak после записи файла: новый код всё равно выдан',
        () async {
      final store = FailingVaultStore();
      final device = FakeDeviceKey();
      final vault = testVault(store, crypto, deviceKey: device);
      (await vault.createProtected(params: fastKdf)).wipe();
      await store.inner.writeBackup(1, (await store.readVault())!);
      store.failBackup = true;
      final fresh = await vault.regenerateRecovery(const DeviceProof());
      final code = _text(fresh.code);
      fresh.code.wipe();
      vault.lock();
      device.lose(device.aliases.single);
      final again = testVault(store, crypto, deviceKey: device);
      expect((await again.unlock(secret(code))).recovered, isTrue);
    });

    test('смены мастер-пароля и «перешифровать всё» у такого сейфа нет',
        () async {
      final (vault, _, _, code, _) = await protectedVault();
      expect(
        () => vault.changeMaster(
          current: secret(code),
          next: secret(Canary.master),
          params: fastKdf,
        ),
        throwsStateError,
      );
      expect(() => vault.reencryptAll(secret(code)), throwsStateError);
      expect(vault.masterDue, isFalse);
    });

    test('подтверждение устройством: только у сейфа со слотом dev', () async {
      final (vault, _, _, _, _) = await protectedVault();
      expect(await vault.verify(const DeviceProof()), isTrue);
      await vault.enablePin(secret(canaryPin()));
      expect(() => vault.verify(const DeviceProof()), throwsArgumentError);
    });
  });

  group('переход с мастер-пароля', () {
    test('мастер-пароль один раз → новый ключ, слот dev и код', () async {
      final store = InMemoryVaultStore();
      final legacy = testVault(store, crypto);
      await legacy.create(secret(Canary.master), params: fastKdf);
      await legacy.addEntry(
        service: 'Почта',
        password: secret(Canary.password),
      );
      legacy.lock();
      final before = (await store.readVault())!;

      final device = FakeDeviceKey();
      final vault = testVault(store, crypto, deviceKey: device);
      expect((await vault.lockInfo())!.usesMaster, isTrue);
      final result = await vault.unlock(secret(Canary.master));
      final code = _text(result.recoveryCode!);
      result.recoveryCode!.wipe();
      expect(vault.isProtected, isTrue);
      expect(vault.recoveryConfirmed, isFalse);
      expect(await readPassword(vault), Canary.password);
      vault.lock();

      final json = _json((await store.readVault())!);
      expect(json['pw_kind'], VaultFormat.pwRecovery);
      expect(device.aliases, hasLength(1));
      // Мастер-пароль больше не открывает ни файл, ни .prev.
      final again = testVault(store, crypto, deviceKey: device);
      await expectLater(
        again.unlock(secret(Canary.master)),
        throwsA(VaultError.wrongPassword),
      );
      expect(
        _json((await store.readPrevious())!)['pw_kind'],
        VaultFormat.pwRecovery,
      );
      // Ключ сейфа новый: старая копия файла (мастер-пароль) его не даёт.
      final oldEnvelope = VaultEnvelope.decode(before);
      final kek = await crypto.derive(
        secret(Canary.master),
        oldEnvelope.kdf.salt,
        fastKdf,
      );
      final oldVk = crypto.openKey(
        kek,
        oldEnvelope.wrapPw,
        VaultKeys.wrapPwAdFor(oldEnvelope),
      )!;
      kek.dispose();
      final ring = VaultKeyRing.from(crypto, oldVk);
      final now = VaultEnvelope.decode((await store.readVault())!);
      expect(
        crypto.open(
          ring.index,
          now.index,
          VaultKeys.indexAd(VaultKeys.header(now), now.rev),
        ),
        isNull,
      );
      ring.dispose();
      await again.unlockDevice();
      again.lock();
      // Код открывает.
      device.lose(device.aliases.single);
      final viaCode = testVault(store, crypto, deviceKey: device);
      expect((await viaCode.unlock(secret(code))).recovered, isTrue);
    });

    test('ключ устройства не создать — открыт по-старому, переход потом',
        () async {
      final store = InMemoryVaultStore();
      final legacy = testVault(store, crypto);
      await legacy.create(secret(Canary.master), params: fastKdf);
      legacy.lock();
      final device = FakeDeviceKey()..failCreate = true;
      final vault = testVault(store, crypto, deviceKey: device);
      final result = await vault.unlock(secret(Canary.master));
      expect(result.recoveryCode, isNull);
      expect(vault.isUnlocked, isTrue);
      expect(vault.isProtected, isFalse);
      vault.lock();
      device.failCreate = false;
      final later = await vault.unlock(secret(Canary.master));
      expect(later.recoveryCode, isNotNull);
      later.recoveryCode!.wipe();
      expect(vault.isProtected, isTrue);
    });

    test('сейф v2 с мастер-паролем читается как v3 (pw_kind master)', () async {
      final store = InMemoryVaultStore();
      final legacy = testVault(store, crypto);
      await legacy.create(secret(Canary.master), params: fastKdf);
      legacy.lock();
      final json = _json((await store.readVault())!);
      expect(json['pw_kind'], VaultFormat.pwMaster);
      expect(json.containsKey('slots'), isFalse);
    });
  });

  group('ПИН-код сейфа', () {
    test('включить: dev исчез, без ПИН-кода не открыть, ПИН-код открывает',
        () async {
      final (vault, store, device, _, _) = await protectedVault();
      final devAlias = device.aliases.single;
      await vault.enablePin(secret(canaryPin()));
      expect(device.aliases.contains(devAlias), isFalse);
      vault.lock();
      final info = (await vault.lockInfo())!;
      expect(info.device, isFalse);
      expect(info.pin, isTrue);
      final again = testVault(store, crypto, deviceKey: device);
      expect(again.unlockDevice, throwsArgumentError);
      await again.unlockPin(secret(canaryPin()));
      expect(await readPassword(again), Canary.password);
    });

    test('слабые и неполные ПИН-коды не принимаются', () {
      String? problem(String text) => VaultPin.problem(secret(text));
      for (final weak in <String>[
        '111111',
        '123456',
        '987654',
        '123123',
        '121212',
        '112233',
        '654321',
        '12345',
        '1234567',
        '12a456',
      ]) {
        expect(problem(weak), isNotNull, reason: 'слабый ПИН-код');
      }
      expect(problem(canaryPin()), isNull);
    });

    test('неверный ПИН-код: попытка засчитана до Argon2id', () async {
      final (vault, store, device, _, _) = await protectedVault();
      await vault.enablePin(secret(canaryPin()));
      vault.lock();
      int? seen;
      device.onMac = () => seen =
          PinAttempts.decode(store.files[FileVaultStore.pinAttemptsName]).fails;
      final again = testVault(store, crypto, deviceKey: device);
      await expectLater(
        again.unlockPin(secret(wrongPin())),
        throwsA(VaultError.wrongPassword),
      );
      // Ключ устройства спрашивают после Argon2id — счётчик уже +1.
      expect(seen, 1);
      expect((await again.pinAttempts()).fails, 1);
      // Не 6 цифр — не ПИН-код: попытку не тратит.
      await expectLater(
        again.unlockPin(secret('12')),
        throwsA(VaultError.wrongPassword),
      );
      expect((await again.pinAttempts()).fails, 1);
    });

    test('паузы с 5-й ошибки, часы назад не снимают, 10-я закрывает путь',
        () async {
      final (vault, store, device, code, clock) = await protectedVault();
      await vault.enablePin(secret(canaryPin()));
      vault.lock();
      final pinAlias = device.aliases.single;
      final again = testVault(store, crypto, deviceKey: device, clock: clock);
      Future<void> wrong() => expectLater(
            again.unlockPin(secret(wrongPin())),
            throwsA(VaultError.wrongPassword),
          );
      for (var i = 0; i < 4; i++) {
        await wrong();
      }
      expect((await again.pinAttempts()).fails, 4);
      await wrong(); // 5-я: пауза 30 с
      await expectLater(
        again.unlockPin(secret(canaryPin())),
        throwsA(isA<VaultRateLimited>()),
      );
      clock.jump(const Duration(hours: -2));
      await expectLater(
        again.unlockPin(secret(canaryPin())),
        throwsA(isA<VaultRateLimited>()),
        reason: 'перевод часов назад паузу не снимает',
      );
      clock.advance(const Duration(seconds: 31));
      await wrong(); // 6-я: 1 мин
      clock.advance(const Duration(minutes: 1, seconds: 1));
      await wrong(); // 7-я: 5 мин
      clock.advance(const Duration(minutes: 5, seconds: 1));
      await wrong(); // 8-я: 15 мин
      clock.advance(const Duration(minutes: 15, seconds: 1));
      await wrong(); // 9-я: 1 ч
      expect((await again.pinAttempts()).left, 1);
      clock.advance(const Duration(hours: 1, seconds: 1));
      await expectLater(
        again.unlockPin(secret(wrongPin())),
        throwsA(VaultError.pinLocked),
      );
      // Путь по ПИН-коду закрыт: ключ удалён, слота нет, верный ПИН-код
      // уже ничего не открывает.
      expect(device.aliases.contains(pinAlias), isFalse);
      expect((await again.lockInfo())!.pin, isFalse);
      await expectLater(
        again.unlockPin(secret(canaryPin())),
        throwsA(VaultError.pinLocked),
      );
      // Код восстановления открывает, ключ устройства — заново.
      final result = await again.unlock(secret(code));
      expect(result.recovered, isTrue);
      expect(again.protection!.device, isTrue);
      await again.enablePin(secret(canaryPin(1)));
      expect((await again.pinAttempts()).fails, 0);
    });

    test('верный ПИН-код обнуляет счётчик', () async {
      final (vault, store, device, _, clock) = await protectedVault();
      await vault.enablePin(secret(canaryPin()));
      vault.lock();
      final again = testVault(store, crypto, deviceKey: device, clock: clock);
      for (var i = 0; i < 3; i++) {
        await expectLater(
          again.unlockPin(secret(wrongPin(i))),
          throwsA(VaultError.wrongPassword),
        );
      }
      await again.unlockPin(secret(canaryPin()));
      expect((await again.pinAttempts()).fails, 0);
    });

    test('ключ ПИН-кода пропал — не попытка, открывает код', () async {
      final (vault, store, device, _, _) = await protectedVault();
      await vault.enablePin(secret(canaryPin()));
      vault.lock();
      device.lose(device.aliases.single);
      final again = testVault(store, crypto, deviceKey: device);
      await expectLater(
        again.unlockPin(secret(canaryPin())),
        throwsA(VaultError.deviceKeyLost),
      );
      expect(
        PinAttempts.decode(await store.readPinAttempts()).fails,
        0,
      );
    });

    test('смена ПИН-кода: прежний ключ удалён, прежний ПИН-код не подходит',
        () async {
      final (vault, store, device, _, _) = await protectedVault();
      await vault.enablePin(secret(canaryPin()));
      final first = device.aliases.single;
      final before = (await store.readVault())!;
      await vault.changePin(secret(canaryPin()), secret(canaryPin(2)));
      expect(device.aliases.contains(first), isFalse);
      vault.lock();
      final again = testVault(store, crypto, deviceKey: device);
      await expectLater(
        again.unlockPin(secret(canaryPin())),
        throwsA(VaultError.wrongPassword),
      );
      await again.unlockPin(secret(canaryPin(2)));
      again.lock();
      // Старая копия файла с прежним слотом: ключа больше нет.
      final old = InMemoryVaultStore()
        ..files[FileVaultStore.vaultName] = before;
      await expectLater(
        testVault(old, crypto, deviceKey: device)
            .unlockPin(secret(canaryPin())),
        throwsA(VaultError.deviceKeyLost),
      );
      // prev — уже новая версия.
      expect(
        VaultEnvelope.decode((await store.readPrevious())!).slots['pin']!.alias,
        isNot(first),
      );
    });

    test('смена ПИН-кода с неверным текущим — ничего не меняется', () async {
      final (vault, _, device, _, _) = await protectedVault();
      await vault.enablePin(secret(canaryPin()));
      final alias = device.aliases.single;
      await expectLater(
        vault.changePin(secret(wrongPin()), secret(canaryPin(2))),
        throwsA(VaultError.wrongPassword),
      );
      expect(device.aliases, <String>{alias});
    });

    test('выключить: только с подтверждением, сейф снова на ключе устройства',
        () async {
      final (vault, store, device, _, _) = await protectedVault();
      await vault.enablePin(secret(canaryPin()));
      await expectLater(
        vault.disablePin(PinProof(secret(wrongPin()))),
        throwsA(VaultError.wrongPassword),
      );
      await vault.disablePin(PinProof(secret(canaryPin())));
      expect(vault.protection!.device, isTrue);
      expect(vault.protection!.pin, isFalse);
      vault.lock();
      await testVault(store, crypto, deviceKey: device).unlockDevice();
    });

    test('ПИН-код там, где ключ лежит файлом, недоступен', () async {
      final (vault, _, _, _, _) = await protectedVault(
        key: FakeDeviceKey(
          kind: VaultDeviceKinds.fileKey,
          pinAllowed: false,
        ),
      );
      expect(vault.pinAllowed, isFalse);
      expect(() => vault.enablePin(secret(canaryPin())), throwsStateError);
    });

    test('копия закрывается кодом, но никогда ПИН-кодом', () async {
      final (vault, _, _, code, _) = await protectedVault();
      await vault.enablePin(secret(canaryPin()));
      expect(
        () => vault.exportBackup(proof: PinProof(secret(canaryPin()))),
        throwsArgumentError,
      );
      final bytes = await vault.exportBackup(
        master: secret(code),
        params: fastKdf,
      );
      final read = await vault.readBackup(
        bytes,
        secret(code.toLowerCase().replaceAll('-', '')),
      );
      expect(read.items, hasLength(1));
      read.wipe();
      // С отдельным паролем копии — подтверждение ПИН-кодом годится.
      final separate = await vault.exportBackup(
        proof: PinProof(secret(canaryPin())),
        passphrase: secret(Canary.master),
        params: fastKdf,
      );
      final viaPass = await vault.readBackup(separate, secret(Canary.master));
      expect(viaPass.items, hasLength(1));
      viaPass.wipe();
      expect(_json(separate).containsKey('slots'), isFalse);
    });
  });

  group('биометрия сейфа', () {
    test('включить: системный запрос, dev исчез; открыть — снова запрос',
        () async {
      final (vault, store, device, _, _) = await protectedVault();
      await vault.enableBio('Включить вход по отпечатку');
      expect(device.prompts, 1);
      expect(device.bioAliases, hasLength(1));
      expect(vault.protection!.device, isFalse);
      vault.lock();
      final again = testVault(store, crypto, deviceKey: device);
      await again.unlockBio('Открыть сейф');
      expect(device.prompts, 2);
      expect(device.lastReason, 'Открыть сейф');
      expect(await readPassword(again), Canary.password);
    });

    test('отмена — не попытка и ничего не меняет', () async {
      final (vault, store, device, _, _) = await protectedVault();
      device.nextPrompt = DeviceKeyFailure.canceled;
      await expectLater(
        vault.enableBio('Включить'),
        throwsA(const VaultFailure(VaultErrorCode.bioCanceled)),
      );
      expect(vault.protection!.device, isTrue);
      expect(device.bioAliases, isEmpty);
      await vault.enableBio('Включить');
      vault.lock();
      device.nextPrompt = DeviceKeyFailure.canceled;
      final again = testVault(store, crypto, deviceKey: device);
      await expectLater(
        again.unlockBio('Открыть'),
        throwsA(const VaultFailure(VaultErrorCode.bioCanceled)),
      );
      expect((await again.lockInfo())!.bio, isTrue);
      await again.unlockBio('Открыть');
    });

    test('ПИН-код и биометрия вместе — открывает любой', () async {
      final (vault, store, device, _, _) = await protectedVault();
      await vault.enablePin(secret(canaryPin()));
      await vault.enableBio('Включить');
      final info = vault.protection!;
      expect(info.pin && info.bio && !info.device, isTrue);
      vault.lock();
      final a = testVault(store, crypto, deviceKey: device);
      await a.unlockBio('Открыть');
      a.lock();
      final b = testVault(store, crypto, deviceKey: device);
      await b.unlockPin(secret(canaryPin()));
    });

    test('добавили отпечаток: слот снят, открывает ПИН-код или код', () async {
      final (vault, store, device, code, _) = await protectedVault();
      await vault.enablePin(secret(canaryPin()));
      await vault.enableBio('Включить');
      vault.lock();
      device.invalidateBio();
      final again = testVault(store, crypto, deviceKey: device);
      await expectLater(
        again.unlockBio('Открыть'),
        throwsA(const VaultFailure(VaultErrorCode.bioInvalidated)),
      );
      expect((await again.lockInfo())!.bio, isFalse);
      expect(device.bioAliases, isEmpty);
      await again.unlockPin(secret(canaryPin()));
      again.lock();
      // И код по-прежнему открывает (ПИН-код и биометрия сняты).
      final viaCode = testVault(store, crypto, deviceKey: device);
      expect((await viaCode.unlock(secret(code))).recovered, isTrue);
      expect(viaCode.protection!.pin, isFalse);
    });

    test('выключить — только с подтверждением; без ПИН-кода — снова dev',
        () async {
      final (vault, _, device, _, _) = await protectedVault();
      await vault.enableBio('Включить');
      device.nextPrompt = DeviceKeyFailure.canceled;
      await expectLater(
        vault.disableBio(const BioProof('Выключить')),
        throwsA(const VaultFailure(VaultErrorCode.bioCanceled)),
      );
      expect(vault.protection!.bio, isTrue);
      await vault.disableBio(const BioProof('Выключить'));
      expect(vault.protection!.device, isTrue);
      expect(device.bioAliases, isEmpty);
    });
  });

  group('формат слотов', () {
    Future<Map<String, Object?>> withPin() async {
      final (vault, store, _, _, _) = await protectedVault();
      await vault.enablePin(secret(canaryPin()));
      vault.lock();
      return _json((await store.readVault())!);
    }

    void expectCorrupt(Map<String, Object?> json) => expect(
          () => VaultEnvelope.decode(_bytes(json)),
          throwsA(VaultError.corrupt),
        );

    test('dev вместе с pin — испорчен', () async {
      final json = await withPin();
      final slots = json['slots']! as Map<String, Object?>;
      final pin = Map<String, Object?>.of(slots['pin']! as Map<String, Object?>)
        ..remove('kdf');
      expectCorrupt(<String, Object?>{
        ...json,
        'slots': <String, Object?>{...slots, 'dev': pin},
      });
    });

    test('неизвестный вид ключа, слот без kdf, слот копии — испорчен',
        () async {
      final json = await withPin();
      final slots = json['slots']! as Map<String, Object?>;
      final pin = slots['pin']! as Map<String, Object?>;
      expectCorrupt(<String, Object?>{
        ...json,
        'slots': <String, Object?>{
          'pin': <String, Object?>{...pin, 'kind': 'cloud'},
        },
      });
      expectCorrupt(<String, Object?>{
        ...json,
        'slots': <String, Object?>{
          'pin': <String, Object?>{
            for (final e in pin.entries)
              if (e.key != 'kdf') e.key: e.value,
          },
        },
      });
      expectCorrupt(<String, Object?>{...json, 'kind': 'backup'});
      expectCorrupt(<String, Object?>{
        for (final e in json.entries)
          if (e.key != 'pw_kind') e.key: e.value,
      });
      expectCorrupt(<String, Object?>{...json, 'pw_kind': 'master'});
    });

    test('файл новее приложения — tooNew', () async {
      final json = await withPin();
      expect(
        () => VaultEnvelope.decode(
          _bytes(<String, Object?>{...json, 'v': VaultFormat.version + 1}),
        ),
        throwsA(VaultError.tooNew),
      );
    });
  });

  group('утечки', () {
    test('чат не оракул ПИН-кода: какой набор совпал — не видно, бюджет',
        () async {
      final (vault, store, device, _, _) = await protectedVault();
      await vault.enablePin(secret(canaryPin()));
      vault.lock();
      final again = testVault(store, crypto, deviceKey: device);
      await again.unlockPin(secret(canaryPin()));
      // Много кандидатов в одном сообщении: скрыты все наборы из 6 цифр.
      final text = '${wrongPin()} ${canaryPin()} ${wrongPin(1)} привет';
      final guard = SecretGuard.redact(text, known: again.matchesKnownSecret);
      expect(guard.guarded, isTrue);
      expect(guard.text.contains(canaryPin()), isFalse);
      expect(guard.text.contains(wrongPin()), isFalse);
      expect(guard.text.contains(wrongPin(1)), isFalse);
      expect(guard.text.contains('привет'), isTrue);
      // Повтор тех же наборов бюджет не тратит.
      expect(again.matchesKnownSecret(canaryPin()), isTrue);
      expect(again.matchesKnownSecret(wrongPin()), isFalse);
      expect(again.matchesKnownSecret(canaryPin()), isTrue);
      // Перебор: после [Vault.pinGuardBudget] разных неверных наборов
      // ПИН-код в чате больше не распознаётся — подсказки нет.
      for (var n = 2; n < Vault.pinGuardBudget + 2; n++) {
        again.matchesKnownSecret(wrongPin(n));
      }
      expect(again.matchesKnownSecret(canaryPin()), isFalse);
      // Верный ввод ПИН-кода снова включает распознавание.
      again.lock();
      await again.unlockPin(secret(canaryPin()));
      expect(again.matchesKnownSecret(canaryPin()), isTrue);
    });

    test('ни ПИН-кода, ни кода восстановления в файлах сейфа и счётчиках',
        () async {
      final (vault, store, _, code, _) = await protectedVault();
      await vault.enablePin(secret(canaryPin()));
      await expectLater(
        vault.verify(PinProof(secret(wrongPin()))),
        completion(isFalse),
      );
      vault.lock();
      final canonical = code.replaceAll('-', '');
      for (final MapEntry(:key, :value) in store.files.entries) {
        for (final needle in <String>[
          canaryPin(),
          wrongPin(),
          code,
          canonical,
          Canary.password,
          Canary.note,
        ]) {
          for (final form in Canary.encodings(needle)) {
            expect(containsBytes(value, form), isFalse, reason: key);
          }
        }
      }
    });
  });
}
