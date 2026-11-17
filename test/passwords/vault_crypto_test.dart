// Крипто хранилища паролей (ADR-014, раздел 11, группа 1): векторы
// Argon2id и XChaCha20-Poly1305, обёртка ключа, неверный пароль, порча
// любого байта, пересадка секрета, уникальность nonce, границы KDF.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/passwords/secret_bytes.dart';
import 'package:local_assistant/core/passwords/vault.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_errors.dart';
import 'package:local_assistant/core/passwords/vault_format.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';
import 'package:sodium/sodium_sumo.dart';

import 'vault_test_support.dart';

Uint8List _hex(String hex) => Uint8List.fromList(<int>[
      for (var i = 0; i + 1 < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

String _toHex(List<int> bytes) =>
    bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

Map<String, Object?> _json(Uint8List bytes) =>
    jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;

Uint8List _bytes(Map<String, Object?> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

void main() {
  late SodiumSumo sodium;
  late SodiumVaultCrypto crypto;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    crypto = await testCrypto();
  });

  group('векторы', () {
    // Эталонные векторы libsodium 1.0.22 (test/default/pwhash_argon2id.c и
    // .exp, получены эталонной реализацией Argon2). Векторы RFC 9106
    // используют секрет K и данные X, которых нет в crypto_pwhash.
    test('Argon2id13: эталонные векторы libsodium', () {
      final vectors = <(String, int, String, int, int, int, String)>[
        (
          'a347ae92bce9f80f6f595a4480fc9c2fe7e7d7148d371e9487d75f5c23008ffae0'
              '65577a928febd9b1973a5a95073acdbeb6a030cfc0d79caa2dc5cd011cef02c08d'
              'a232d76d52dfbca38ca8dcbd665b17d1665f7cf5fe59772ec909733b24de97d6f5'
              '8d220b20c60d7c07ec1fd93c52c31020300c6c1facd77937a597c7a6',
          127,
          '5541fbc995d5c197ba290346d2c559dedf405cf97e5f95482143202f9e74f5c2',
          155,
          5,
          7256678,
          '18acec5d6507739f203d1f5d9f1d862f7c2cdac4f19d2bdff64487e60d969e3ced'
              '615337b9eec6ac4461c6ca07f0939741e57c24d0005c7ea171a0ee1e7348249d'
              '135b38f222e4dad7b9a033ed83f5ca27277393e316582033c74affe2566a2bea'
              '47f91f0fd9fe49ece7e1f79f3ad6e9b23e0277c8ecc4b313225748dd2a80f567'
              '9534a0700e246a79a49b3f74eb89ec6205fe1eeb941c73b1fcf1',
        ),
        (
          'e125cee61c8cb7778d9e5ad0a6f5d978ce9f84de213a8556d9ffe202020ab4a6ed'
              '9074a4eb3416f9b168f137510f3a30b70b96cbfa219ff99f6c6eaffb15c06b60e0'
              '0cc2890277f0fd3c622115772f7048adaebed86e',
          86,
          'f1192dd5dc2368b9cd421338b22433455ee0a3699f9379a08b9650ea2c126f0d',
          250,
          4,
          7849083,
          '26bab5f101560e48c711da4f05e81f5a3802b7a93d5155b9cab153069cc42b8e9f'
              '910bfead747652a0708d70e4de0bada37218bd203a1201c36b42f9a269b675b1'
              'f30cfc36f35a3030e9c7f57dfba0d341a974c1886f708c3e8297efbfe411bb9d'
              '51375264bd7c70d57a8a56fc9de2c1c97c08776803ec2cd0140bba8e61dc0f4a'
              'd3d3d1a89b4b710af81bfe35a0eea193e18a6da0f5ec05542c9eefc4584458e1'
              'da715611ba09617384748bd43b9bf1f3a6df4ecd091d0875e08d6e2fd8a5c7ce'
              '08904b5160cd38167b76ec76ef2d310049055a564da23d4ebd2b87e421cc33c4'
              '01e12d5cd8d936c9baf75ebdfb557d342d2858fc781da31860',
        ),
      ];
      for (final (pw, pwLen, salt, outLen, ops, mem, expected) in vectors) {
        final key = sodium.crypto.pwhash.callRaw(
          outLen: outLen,
          password: Int8List.fromList(_hex(pw).sublist(0, pwLen)),
          salt: _hex(salt).sublist(0, 16),
          opsLimit: ops,
          memLimit: mem,
          alg: CryptoPwhashAlgorithm.argon2id13,
        );
        expect(_toHex(key.extractBytes()), expected);
        key.dispose();
      }
    });

    test('VaultKdf — именно Argon2id13 с заданными параметрами', () async {
      final salt = Uint8List.fromList(List<int>.generate(16, (int i) => i));
      final password = secret('CANARY-kdf');
      const params = VaultKdfParams(ops: 3, mem: 8 * 1024 * 1024);
      final key = await crypto.derive(password, salt, params);
      final ours = crypto.exportKey(key);
      Uint8List reference(CryptoPwhashAlgorithm alg) {
        final k = sodium.crypto.pwhash.callRaw(
          outLen: 32,
          password: Int8List.fromList(utf8.encode('CANARY-kdf')),
          salt: salt,
          opsLimit: 3,
          memLimit: 8 * 1024 * 1024,
          alg: alg,
        );
        final bytes = k.extractBytes();
        k.dispose();
        return bytes;
      }

      expect(ours.unsafeBytes, reference(CryptoPwhashAlgorithm.argon2id13));
      expect(
        ours.unsafeBytes,
        isNot(reference(CryptoPwhashAlgorithm.argon2i13)),
      );
      key.dispose();
      ours.wipe();
      password.wipe();
    });

    test('в изоляте — тот же ключ, пароль не затёрт у вызывающего', () async {
      final isolated = await testCrypto(isolated: true);
      final salt = Uint8List(16);
      final password = secret('CANARY-iso');
      final a = await isolated.derive(password, salt, fastKdf);
      final b = await crypto.derive(password, salt, fastKdf);
      expect(
        isolated.exportKey(a).unsafeBytes,
        crypto.exportKey(b).unsafeBytes,
      );
      expect(password.isWiped, isFalse);
      a.dispose();
      b.dispose();
    });

    test('XChaCha20-Poly1305 IETF: вектор draft-irtf-cfrg-xchacha A.3.1', () {
      final key = crypto.importKey(
        SecretBytes.adopt(
          Uint8List.fromList(List<int>.generate(32, (int i) => 0x80 + i)),
        ),
      );
      final nonce = _hex('070000004041424344454647'
          '48494a4b4c4d4e4f50515253');
      final ad = _hex('50515253c0c1c2c3c4c5c6c7');
      final message = Uint8List.fromList(
        ascii.encode(
          "Ladies and Gentlemen of the class of '99: If I could offer you "
          'only one tip for the future, sunscreen would be it.',
        ),
      );
      const expected =
          'f8ebea4875044066fc162a0604e171feecfb3d20425248563bcfd5a155dcc47b'
          'bda70b86e5ab9b55002bd1274c02db35321acd7af8b2e2d25015e136b7679458'
          'e9f43243bf719d639badb5feac03f80a19a96ef10cb1d15333a837b90946ba38'
          '54ee74da3f2585efc7e1e170e17e15e563e77601f4f85cafa8e5877614e143e6'
          '8420';
      final opened = crypto.open(key, SealedBox(nonce, _hex(expected)), ad);
      expect(opened, message);
      // Тег не сходится при другом AD и при изменённом байте.
      expect(
        crypto.open(key, SealedBox(nonce, _hex(expected)), Uint8List(0)),
        isNull,
      );
      final broken = _hex(expected)..[0] ^= 1;
      expect(crypto.open(key, SealedBox(nonce, broken), ad), isNull);
      key.dispose();
    });

    test('nonce уникален на 10 000 шифрований', () {
      final key = crypto.randomKey();
      final seen = <String>{};
      for (var i = 0; i < 10000; i++) {
        final box = crypto.seal(key, Uint8List(1), Uint8List(0));
        expect(box.nonce, hasLength(24));
        seen.add(base64.encode(box.nonce));
      }
      expect(seen, hasLength(10000));
      key.dispose();
    });

    test('обёртка ключа: снимается только своим KEK и своим AD', () {
      final kek = crypto.randomKey();
      final other = crypto.randomKey();
      final vk = crypto.randomKey();
      final ad = Uint8List.fromList(ascii.encode('header|wrap_pw'));
      final wrap = crypto.sealKey(kek, vk, ad);
      final back = crypto.openKey(kek, wrap, ad)!;
      expect(
        crypto.exportKey(back).unsafeBytes,
        crypto.exportKey(vk).unsafeBytes,
      );
      expect(crypto.openKey(other, wrap, ad), isNull);
      expect(
        crypto.openKey(
          kek,
          wrap,
          Uint8List.fromList(ascii.encode('header|wrap_bio')),
        ),
        isNull,
      );
      for (final key in <VaultKey>[kek, other, vk, back]) {
        key.dispose();
      }
    });

    test('подключи crypto_kdf различны и детерминированы', () {
      final vk = crypto.randomKey();
      final ring = VaultKeyRing.from(crypto, vk);
      final a = crypto.exportKey(ring.index).unsafeBytes;
      final b = crypto.exportKey(ring.secret).unsafeBytes;
      expect(a, isNot(b));
      expect(crypto.exportKey(crypto.deriveKey(vk, 1)).unsafeBytes, a);
      ring.dispose();
      expect(vk.isDisposed, isTrue);
    });
  });

  group('конверт хранилища', () {
    late InMemoryVaultStore store;
    late Vault vault;
    late String entryId;
    late String secondId;

    setUp(() async {
      store = InMemoryVaultStore();
      vault = testVault(store, crypto);
      await vault.load();
      await vault.create(secret(Canary.master), params: fastKdf);
      entryId = await vault.addEntry(
        service: 'Почта',
        login: Canary.login,
        hint: Canary.hint,
        password: secret(Canary.password),
        note: secret(Canary.note),
      );
      secondId = await vault.addEntry(
        service: 'Форум',
        password: secret('CANARY-other-pw'),
      );
      vault.lock();
    });

    Future<Vault> reopen() async {
      final fresh = testVault(store, crypto);
      await fresh.load();
      return fresh;
    }

    test('неверный мастер-пароль → wrongPassword', () async {
      final fresh = await reopen();
      await expectLater(
        fresh.unlock(secret('CANARY-wrong')),
        throwsA(VaultError.wrongPassword),
      );
      expect(fresh.state, VaultState.locked);
      final ok = await fresh.unlock(secret(Canary.master));
      expect(ok.rolledBack, isFalse);
      // Уже открыто — ввод всё равно проверяется.
      await expectLater(
        fresh.unlock(secret('CANARY-wrong')),
        throwsA(VaultError.wrongPassword),
      );
      expect(fresh.state, VaultState.unlocked);
      final value = await fresh.readSecret(entryId);
      expect(utf8.decode(value.password.unsafeBytes), Canary.password);
      expect(utf8.decode(value.note.unsafeBytes), Canary.note);
      value.wipe();
    });

    test('любой изменённый байт заголовка, индекса или секрета — ошибка',
        () async {
      final original = (await store.readVault())!;
      final json = _json(original);
      // Каждое поле заголовка входит в AD обёртки.
      final mutations = <String, void Function(Map<String, Object?>)>{
        'vault_id': (Map<String, Object?> j) =>
            j['vault_id'] = base64.encode(Uint8List(16)..[0] = 1),
        'ops': (Map<String, Object?> j) =>
            (j['kdf']! as Map<String, Object?>)['ops'] = 2,
        'mem': (Map<String, Object?> j) =>
            (j['kdf']! as Map<String, Object?>)['mem'] = 128 * 1024,
        'salt': (Map<String, Object?> j) => (j['kdf']!
            as Map<String, Object?>)['salt'] = base64.encode(Uint8List(16)),
        'kind': (Map<String, Object?> j) => j['kind'] = 'backup',
      };
      for (final MapEntry(:key, :value) in mutations.entries) {
        final copy = _json(original);
        value(copy);
        store.files[FileVaultStore.vaultName] = _bytes(copy);
        final fresh = await reopen();
        await expectLater(
          fresh.unlock(secret(Canary.master)),
          throwsA(
            isA<VaultError>().having(
              (VaultError e) => e.code,
              'code',
              anyOf(
                VaultErrorCode.wrongPassword,
                VaultErrorCode.corrupt,
                VaultErrorCode.kdfInvalid,
              ),
            ),
          ),
          reason: key,
        );
      }
      // Байты шифротекстов: обёртка, индекс, секрет.
      String flip(String b64) {
        final bytes = base64.decode(b64);
        bytes[bytes.length ~/ 2] ^= 0x01;
        return base64.encode(bytes);
      }

      final wrap = _json(original);
      final w = wrap['wrap_pw']! as Map<String, Object?>;
      w['c'] = flip(w['c']! as String);
      store.files[FileVaultStore.vaultName] = _bytes(wrap);
      await expectLater(
        (await reopen()).unlock(secret(Canary.master)),
        throwsA(VaultError.wrongPassword),
      );

      final index = _json(original);
      final i = index['index']! as Map<String, Object?>;
      i['c'] = flip(i['c']! as String);
      store.files[FileVaultStore.vaultName] = _bytes(index);
      await expectLater(
        (await reopen()).unlock(secret(Canary.master)),
        throwsA(VaultError.corrupt),
      );

      final secrets = _json(original);
      final s = (secrets['secrets']! as Map<String, Object?>)[entryId]!
          as Map<String, Object?>;
      s['c'] = flip(s['c']! as String);
      store.files[FileVaultStore.vaultName] = _bytes(secrets);
      final fresh = await reopen();
      await fresh.unlock(secret(Canary.master));
      await expectLater(fresh.readSecret(entryId), throwsA(VaultError.corrupt));
      // Нетронутая запись читается.
      (await fresh.readSecret(secondId)).wipe();
      expect(json, isNotEmpty);
    });

    test('секрет, пересаженный в другую запись, → corrupt', () async {
      final json = _json((await store.readVault())!);
      final secrets = json['secrets']! as Map<String, Object?>;
      final first = secrets[entryId]! as Map<String, Object?>;
      final second = secrets[secondId]! as Map<String, Object?>;
      secrets[secondId] = <String, Object?>{...first, 'r': second['r']};
      store.files[FileVaultStore.vaultName] = _bytes(json);
      final fresh = await reopen();
      await fresh.unlock(secret(Canary.master));
      await expectLater(
        fresh.readSecret(secondId),
        throwsA(VaultError.corrupt),
      );
    });

    test('параметры KDF ниже пола и выше потолка → kdfInvalid', () {
      KdfRecord record(int ops, int mem) =>
          KdfRecord(ops: ops, mem: mem, salt: Uint8List(16));
      const mib = 1024 * 1024;
      for (final (ops, mem) in <(int, int)>[
        (2, 31 * mib),
        (1, 64 * mib),
        (11, 64 * mib),
        (3, 1025 * mib),
      ]) {
        expect(
          () => VaultKdfParams.checkLoaded(record(ops, mem)),
          throwsA(VaultError.kdfInvalid),
          reason: '$ops/$mem',
        );
      }
      expect(VaultKdfParams.checkLoaded(record(2, 32 * mib)).mem, 32 * mib);
      expect(VaultKdfParams.checkLoaded(record(10, 1024 * mib)).ops, 10);
      // Копия: потолок 256 МиБ и не больше четверти памяти устройства.
      expect(
        () => VaultKdfParams.checkLoaded(record(4, 512 * mib), backup: true),
        throwsA(VaultError.kdfInvalid),
      );
      expect(
        () => VaultKdfParams.checkLoaded(
          record(4, 200 * mib),
          backup: true,
          totalMemory: 512 * mib,
        ),
        throwsA(VaultError.kdfInvalid),
      );
    });

    test('файл с завышенной памятью отвергается без вывода ключа', () async {
      final json = _json((await store.readVault())!);
      (json['kdf']! as Map<String, Object?>)['mem'] = 4096 * 1024 * 1024;
      store.files[FileVaultStore.vaultName] = _bytes(json);
      final watch = Stopwatch()..start();
      await expectLater(
        (await reopen()).unlock(secret(Canary.master)),
        throwsA(VaultError.kdfInvalid),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('тестовые параметры из файла без флага отвергаются', () async {
      final strict = Vault(store: store, crypto: crypto);
      await strict.load();
      await expectLater(
        strict.unlock(secret(Canary.master)),
        throwsA(VaultError.kdfInvalid),
      );
      // Создать с ними без флага тоже нельзя.
      final empty = Vault(store: InMemoryVaultStore(), crypto: crypto);
      await empty.load();
      await expectLater(
        empty.create(secret(Canary.master), params: fastKdf),
        throwsArgumentError,
      );
    });

    test('копия параметров: не слабее хранилища, пол 64 МиБ / ops 4', () {
      const mib = 1024 * 1024;
      expect(
        VaultKdfParams.forBackup(const VaultKdfParams(ops: 3, mem: 64 * mib)),
        const VaultKdfParams(ops: 4, mem: 64 * mib),
      );
      expect(
        VaultKdfParams.forBackup(const VaultKdfParams(ops: 5, mem: 512 * mib)),
        const VaultKdfParams(ops: 5, mem: 256 * mib),
      );
      expect(
        VaultKdfParams.forBackup(const VaultKdfParams(ops: 2, mem: 32 * mib)),
        const VaultKdfParams(ops: 4, mem: 64 * mib),
      );
    });
  });

  group('калибровка', () {
    const mib = 1024 * 1024;
    Future<Duration> Function(VaultKdfParams) linear(int msPer64MiBOps3) =>
        (VaultKdfParams p) async => Duration(
              milliseconds:
                  (msPer64MiBOps3 * (p.mem / (64 * mib)) * (p.ops / 3)).round(),
            );

    test('быстрый десктоп: память растёт до 256 МиБ, затем ops', () async {
      final params = await VaultKdfParams.calibrate(measure: linear(60));
      expect(params.mem, 256 * mib);
      expect(params.ops, 4);
    });

    test('цель 0,7–1,0 с: не выходит за секунду', () async {
      final params = await VaultKdfParams.calibrate(measure: linear(300));
      final time = await linear(300)(params);
      expect(time, lessThanOrEqualTo(const Duration(seconds: 1)));
      expect(params.mem, 128 * mib);
    });

    test('медленное устройство остаётся на полу', () async {
      final params = await VaultKdfParams.calibrate(measure: linear(2000));
      expect(params, VaultKdfParams.floor);
      final low = await VaultKdfParams.calibrate(
        measure: linear(2000),
        device: VaultDevice.mobile,
        totalMemory: 2 * 1024 * mib,
      );
      expect(low, VaultKdfParams.lowMemoryFloor);
    });

    test('телефон: 64 МиБ, 128 МиБ при 4 ГБ памяти', () async {
      final small = await VaultKdfParams.calibrate(
        measure: linear(50),
        device: VaultDevice.mobile,
        totalMemory: 3 * 1024 * mib,
      );
      expect(small.mem, 64 * mib);
      final big = await VaultKdfParams.calibrate(
        measure: linear(50),
        device: VaultDevice.mobile,
        totalMemory: 4 * 1024 * mib,
      );
      expect(big.mem, 128 * mib);
    });
  });
}
