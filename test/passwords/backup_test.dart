// Резервная копия `.relaybak` (ADR-014, 4.3, 5.7, 15.4; раздел 11,
// группы 9 и 19в–г): выгрузка и восстановление на «новом устройстве»,
// слияние и конфликты, «Заменить всё» с архивом, поддельная копия.
// Пароли — только синтетические канарейки.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/passwords/import_rules.dart';
import 'package:local_assistant/core/passwords/password_audit.dart';
import 'package:local_assistant/core/passwords/password_training.dart';
import 'package:local_assistant/core/passwords/secret_bytes.dart';
import 'package:local_assistant/core/passwords/vault.dart';
import 'package:local_assistant/core/passwords/vault_backup.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_errors.dart';
import 'package:local_assistant/core/passwords/vault_format.dart';
import 'package:local_assistant/core/passwords/vault_prefs.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';

import 'vault_test_support.dart';

/// Криптография, которая считает выводы ключа (Argon2id).
final class _CountingCrypto implements VaultCrypto {
  _CountingCrypto(this.inner);

  final VaultCrypto inner;
  int derives = 0;

  @override
  Future<VaultKey> derive(
    SecretBytes password,
    Uint8List salt,
    VaultKdfParams params,
  ) {
    derives++;
    return inner.derive(password, salt, params);
  }

  @override
  Future<Duration> measure(VaultKdfParams params) => inner.measure(params);
  @override
  Uint8List bytes(int length) => inner.bytes(length);
  @override
  int uniform(int upperBound) => inner.uniform(upperBound);
  @override
  VaultKey randomKey() => inner.randomKey();
  @override
  VaultKey importKey(SecretBytes bytes) => inner.importKey(bytes);
  @override
  SecretBytes exportKey(VaultKey key) => inner.exportKey(key);
  @override
  VaultKey deriveKey(VaultKey master, int id) => inner.deriveKey(master, id);
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
  VaultKey? openKey(VaultKey kek, SealedBox box, Uint8List ad) =>
      inner.openKey(kek, box, ad);
  @override
  Uint8List keyedHash(VaultKey key, Uint8List message) =>
      inner.keyedHash(key, message);
  @override
  bool equal(Uint8List a, Uint8List b) => inner.equal(a, b);
}

void main() {
  late SodiumVaultCrypto crypto;

  setUpAll(() async {
    crypto = await testCrypto();
  });

  Future<Vault> newVault([VaultStore? store, VaultCrypto? with_]) async {
    final vault = testVault(store ?? InMemoryVaultStore(), with_ ?? crypto);
    await vault.load();
    return vault;
  }

  Future<Vault> filled() async {
    final vault = await newVault();
    await vault.create(secret(Canary.master), params: fastKdf);
    final mail = await vault.addEntry(
      service: 'Почта',
      login: Canary.login,
      hint: Canary.hint,
      urls: <String>['https://mail.example'],
      password: secret(Canary.password),
      note: secret(Canary.note),
      important: true,
    );
    expect(await vault.verifyMaster(secret(Canary.master)), isTrue);
    await vault.updatePassword(mail, secret('CANARY-pw-mail-new'));
    await vault.addEntry(service: 'Форум', password: secret('CANARY-pw-same'));
    await vault.addEntry(service: 'Чат', password: secret('CANARY-pw-same'));
    return vault;
  }

  Future<String> passwordOf(Vault vault, String id) async {
    final secret = await vault.readSecret(id);
    try {
      return utf8.decode(secret.password.unsafeBytes);
    } finally {
      secret.wipe();
    }
  }

  String idOf(Vault vault, String service) =>
      vault.entries.firstWhere((VaultEntry e) => e.service == service).id;

  test('копия: свой конверт, kind backup, без wrap_bio, имя файла', () async {
    final vault = await filled();
    final bytes = await vault.exportBackup(master: secret(Canary.master));
    final envelope = VaultEnvelope.decode(bytes);
    expect(envelope.kind, VaultFormat.kindBackup);
    expect(envelope.wrapBio, isNull);
    expect(envelope.secrets.length, 3);
    final own = VaultEnvelope.decode((await vault.store.readVault())!);
    expect(envelope.vaultId, isNot(own.vaultId));
    expect(envelope.kdf.salt, isNot(own.kdf.salt));
    for (final canary in <String>[
      ...Canary.secrets,
      Canary.login,
      Canary.hint,
    ]) {
      for (final form in Canary.encodings(canary)) {
        expect(containsBytes(bytes, form), isFalse, reason: canary);
      }
    }
    expect(
      VaultBackup.fileName(DateTime(2026, 11, 10)),
      'svyaznoy-paroli-2026-11-10.relaybak',
    );
  });

  test('параметры копии не слабее хранилища (3.2)', () {
    const mib = VaultKdfParams.mib;
    expect(
      VaultKdfParams.forBackup(const VaultKdfParams(ops: 3, mem: 256 * mib)),
      const VaultKdfParams(ops: 4, mem: 256 * mib),
    );
    expect(
      VaultKdfParams.forBackup(const VaultKdfParams(ops: 3, mem: 46 * mib)),
      const VaultKdfParams(ops: 4, mem: 64 * mib),
    );
    expect(
      VaultKdfParams.forBackup(const VaultKdfParams(ops: 6, mem: 512 * mib)),
      const VaultKdfParams(ops: 6, mem: 256 * mib),
    );
  });

  test('выгрузка — только с верным мастер-паролем', () async {
    final vault = await filled();
    await expectLater(
      vault.exportBackup(master: secret('CANARY-wrong')),
      throwsA(VaultError.wrongPassword),
    );
    vault.lock();
    await expectLater(
      vault.exportBackup(master: secret(Canary.master)),
      throwsA(VaultError.locked),
    );
  });

  test('«новое устройство»: создать из копии — пароли, повторы, прежний',
      () async {
    final vault = await filled();
    final bytes = await vault.exportBackup(master: secret(Canary.master));
    final mailId = idOf(vault, 'Почта');

    final device = await newVault();
    expect(device.state, VaultState.notCreated);
    final contents = await device.readBackup(bytes, secret(Canary.master));
    expect(contents.items.length, 3);
    expect(contents.skipped, 0);
    expect('$contents', isNot(contains('CANARY')));
    await device.createFromBackup(
      contents,
      secret('CANARY-master2-Pz8'),
      params: fastKdf,
    );
    contents.wipe();
    expect(device.isUnlocked, isTrue);
    expect(device.entries.length, 3);
    final mail = device.entry(mailId)!;
    expect(mail.hint, Canary.hint);
    expect(mail.login, Canary.login);
    // Производные поля сброшены.
    expect(mail.important, isFalse);
    expect(mail.train, isEmpty);
    expect(mail.dateSource, DateSource.import);
    expect(await passwordOf(device, mailId), 'CANARY-pw-mail-new');
    // Общий k_fp: «это прежний пароль» и повторы работают.
    expect(mail.fpOld.length, 1);
    expect(
      await device.recall(mailId, secret(Canary.password)),
      RecallVerdict.oldOne,
    );
    final groups = CheckGroups.of(
      device.entries,
      DateTime.utc(2026, 11, 10),
      equal: crypto.equal,
    );
    expect(groups.reused.single.length, 2);
    // Новый мастер-пароль открывает, мастер-пароль копии — нет.
    device.lock();
    await expectLater(
      device.unlock(secret(Canary.master)),
      throwsA(VaultError.wrongPassword),
    );
    await device.unlock(secret('CANARY-master2-Pz8'));
    expect(
      VaultEnvelope.decode((await device.store.readVault())!).vaultId,
      isNot(VaultEnvelope.decode(bytes).vaultId),
    );
  });

  test('отдельный пароль копии: мастер-пароль её не открывает', () async {
    final vault = await filled();
    final bytes = await vault.exportBackup(
      master: secret(Canary.master),
      passphrase: secret('CANARY-backup-pass-Qw9'),
    );
    final device = await newVault();
    await expectLater(
      device.readBackup(bytes, secret(Canary.master)),
      throwsA(VaultError.wrongPassword),
    );
    final contents =
        await device.readBackup(bytes, secret('CANARY-backup-pass-Qw9'));
    expect(contents.items.length, 3);
    contents.wipe();
    await vault.recordBackup(separate: true);
    expect(vault.lastBackupAt, isNotNull);
  });

  test('слияние по entry.id: дубль, конфликт («из копии»), новая', () async {
    final vault = await filled();
    final bytes = await vault.exportBackup(master: secret(Canary.master));
    final chat = idOf(vault, 'Чат');
    final forum = idOf(vault, 'Форум');
    await vault.deleteEntry(chat);
    await vault.updatePassword(forum, secret('CANARY-pw-forum-now'));
    await vault.addEntry(service: 'Только здесь', password: secret('CANARY-x'));

    final contents = await vault.readBackup(bytes, secret(Canary.master));
    final matches = vault.matchImport(contents.items, byId: true);
    final byService = <String, ImportMatch>{
      for (var i = 0; i < contents.items.length; i++)
        contents.items[i].service: matches[i],
    };
    expect(byService['Почта']!.status, ImportStatus.same);
    expect(byService['Форум']!.status, ImportStatus.conflict);
    expect(byService['Форум']!.defaultChoice, ImportChoice.keepBoth);
    expect(byService['Чат']!.status, ImportStatus.fresh);
    final result = await vault.importItems(
      <ImportDecision>[
        for (var i = 0; i < contents.items.length; i++)
          ImportDecision(
            contents.items[i],
            matches[i],
            contents.items[i].service == 'Форум'
                ? ImportChoice.replace
                : matches[i].defaultChoice,
          ),
      ],
      fromBackup: true,
    );
    contents.wipe();
    expect(result.added, 1);
    expect(result.replaced, 1);
    expect(result.skipped, 1);
    expect(vault.entries.length, 4);
    expect(vault.entry(chat), isNotNull);
    expect(await passwordOf(vault, forum), 'CANARY-pw-same');
    expect(
      await vault.recall(forum, secret('CANARY-pw-forum-now')),
      RecallVerdict.oldOne,
    );
  });

  test('слияние в чужое хранилище: fp пересчитан ключом хранилища', () async {
    final source = await filled();
    final bytes = await source.exportBackup(master: secret(Canary.master));
    final other = await newVault();
    await other.create(secret('CANARY-master2-Pz8'), params: fastKdf);
    await other.addEntry(
      service: 'Почта',
      login: Canary.login,
      password: secret('CANARY-pw-mail-new'),
    );
    final contents = await other.readBackup(bytes, secret(Canary.master));
    final matches = other.matchImport(contents.items, byId: true);
    await other.importItems(
      <ImportDecision>[
        for (var i = 0; i < contents.items.length; i++)
          ImportDecision(
            contents.items[i],
            matches[i],
            matches[i].defaultChoice,
          ),
      ],
      fromBackup: true,
    );
    contents.wipe();
    // «Почта» — тот же пароль: дубль по отпечатку ключом этого хранилища.
    expect(matches.first.status, ImportStatus.same);
    expect(other.entries.length, 3);
    for (final entry in other.entries) {
      final secret = await other.readSecret(entry.id);
      try {
        expect(other.fingerprint(secret.password), entry.fp);
      } finally {
        secret.wipe();
      }
      // Прежние отпечатки пришедших записей отброшены.
      expect(entry.fpOld, isEmpty);
      expect(entry.important, isFalse);
    }
  });

  test('адрес изменится — пометка с хостами в punycode', () async {
    final vault = await newVault();
    await vault.create(secret(Canary.master), params: fastKdf);
    final id = await vault.addEntry(
      service: 'Сбер',
      urls: <String>['https://sberbank.ru'],
      password: secret('CANARY-pw-sb'),
    );
    final item = ImportItem(
      service: 'Сбер',
      urls: <String>['https://sbеrbank.ru'],
      password: secret('CANARY-pw-sb2'),
      sourceId: id,
    );
    final match = vault.matchImport(<ImportItem>[item], byId: true).single;
    expect(match.status, ImportStatus.conflict);
    expect(match.addressChanges, isTrue);
    expect(match.addressFrom, 'sberbank.ru');
    expect(match.addressTo, startsWith('xn--'));
    item.wipe();
  });

  test('«Заменить всё»: мастер-пароль обязателен, прежнее — в архиве',
      () async {
    final store = InMemoryVaultStore();
    final vault = await newVault(store);
    await vault.create(secret(Canary.master), params: fastKdf);
    await vault.addEntry(service: 'Было', password: secret('CANARY-pw-was'));

    final source = await filled();
    final bytes = await source.exportBackup(master: secret(Canary.master));
    final contents = await vault.readBackup(bytes, secret(Canary.master));
    final before = (await store.readVault())!;
    await expectLater(
      vault.replaceWithBackup(contents, secret('CANARY-wrong')),
      throwsA(VaultError.wrongPassword),
    );
    expect(vault.entries.single.service, 'Было');
    final name = await vault.replaceWithBackup(contents, secret(Canary.master));
    contents.wipe();
    expect(name, startsWith('replaced-'));
    expect(store.files['archive/$name'], before);
    expect(vault.isUnlocked, isTrue);
    expect(vault.entries.map((e) => e.service).toSet(), <String>{
      'Почта',
      'Форум',
      'Чат',
    });
    vault.lock();
    await vault.unlock(secret(Canary.master));
    expect(vault.entries.length, 3);
  });

  test('слияние: сбой записи — хранилище не изменено', () async {
    final store = FailingVaultStore();
    final vault = await newVault(store);
    await vault.create(secret(Canary.master), params: fastKdf);
    final source = await filled();
    final bytes = await source.exportBackup(master: secret(Canary.master));
    final contents = await vault.readBackup(bytes, secret(Canary.master));
    final matches = vault.matchImport(contents.items, byId: true);
    final before = await store.readVault();
    store.fail = true;
    await expectLater(
      vault.importItems(
        <ImportDecision>[
          for (var i = 0; i < contents.items.length; i++)
            ImportDecision(
              contents.items[i],
              matches[i],
              ImportChoice.keepBoth,
            ),
        ],
        fromBackup: true,
      ),
      throwsA(anything),
    );
    contents.wipe();
    expect(vault.entries, isEmpty);
    expect(await store.readVault(), before);
  });

  group('поддельная копия (15.4)', () {
    const pass = 'CANARY-forged-pass';
    const mib = VaultKdfParams.mib;

    /// Копия с произвольным индексом, честно зашифрованная паролем [pass].
    Future<Uint8List> forge(
      Map<String, Object?> index,
      Map<String, String> passwords, {
      String kind = VaultFormat.kindBackup,
    }) async {
      final salt = crypto.bytes(VaultFormat.saltBytes);
      final vaultId = base64.encode(crypto.bytes(VaultFormat.idBytes));
      const params = VaultKdfParams.forTesting();
      final header = VaultKeys.headerOf(
        version: VaultFormat.version,
        kind: kind,
        vaultId: vaultId,
        ops: params.ops,
        mem: params.mem,
        salt: salt,
      );
      final kek = await crypto.derive(secret(pass), salt, params);
      final vk = crypto.randomKey();
      final ring = VaultKeyRing.from(crypto, vk);
      final wrap = crypto.sealKey(
        kek,
        vk,
        VaultKeys.wrapPwAdOf(
          version: VaultFormat.version,
          kind: kind,
          vaultId: vaultId,
          kdf: KdfRecord(ops: params.ops, mem: params.mem, salt: salt),
          pwKind: kind == VaultFormat.kindVault ? VaultFormat.pwMaster : null,
        ),
      );
      kek.dispose();
      final body = VaultPadding.pad(
        Uint8List.fromList(utf8.encode(jsonEncode(index))),
        VaultFormat.indexBlock,
      );
      final rev = index['rev'] as int;
      final secrets = <String, SealedSecret>{
        for (final MapEntry(:key, :value) in passwords.entries)
          key: SealedSecret(
            crypto.seal(
              ring.secret,
              SecretCodec.encodePadded(secret(value), SecretBytes.empty()),
              VaultKeys.secretAd(
                version: VaultFormat.version,
                kind: kind,
                vaultId: vaultId,
                entryId: key,
                srev: 1,
              ),
            ),
            1,
          ),
      };
      final envelope = VaultEnvelope(
        kind: kind,
        vaultId: vaultId,
        kdf: KdfRecord(ops: params.ops, mem: params.mem, salt: salt),
        wrapPw: wrap,
        pwKind: kind == VaultFormat.kindVault ? VaultFormat.pwMaster : null,
        rev: rev,
        index: crypto.seal(ring.index, body, VaultKeys.indexAd(header, rev)),
        secrets: secrets,
      );
      ring.dispose();
      return envelope.encode();
    }

    Map<String, Object?> entry(
      String id,
      String service, {
      List<String> urls = const <String>[],
    }) =>
        <String, Object?>{
          'id': id,
          'srev': 1,
          'service': service,
          'urls': urls,
          'login': 'canary',
          'hint': '',
          'important': true,
          'created': '2024-01-01T00:00:00.000Z',
          'changed': '2024-01-01T00:00:00.000Z',
          'date_source': 'user',
          'fp': base64.encode(List<int>.filled(32, 7)),
          'fp_old': <String>[base64.encode(List<int>.filled(32, 9))],
          'score': 4,
          'flags': <String>['weak'],
          'train': <String, Object?>{'next': '2020-01-01', 'stage': 6},
        };

    test('настройки, производные поля и мусор не берутся', () async {
      final a = '0' * 31 + '1';
      final b = '0' * 31 + '2';
      final c = '0' * 31 + '3';
      final bytes = await forge(
        <String, Object?>{
          'schema': 1,
          'rev': 5,
          'k_fp': base64.encode(List<int>.filled(32, 1)),
          'prefs': <String, Object?>{
            'hints_in_history': true,
            'autolock_min': 999,
          },
          'master': <String, Object?>{'last_typed': '2099-01-01T00:00:00Z'},
          'backup': <String, Object?>{'last': '2099-01-01T00:00:00Z'},
          'junk': 'x' * (1024 * 1024),
          'entries': <Object?>[
            entry(a, 'Банк', urls: <String>['javascript:alert(1)']),
            entry(b, 'moc.knab\u202E'),
            entry(c, 'Почта', urls: <String>['https://mail.example']),
          ],
        },
        <String, String>{
          a: 'CANARY-pw-f1',
          b: 'CANARY-pw-f2',
          c: 'CANARY-pw-f3',
        },
      );
      final device = await newVault();
      final contents = await device.readBackup(bytes, secret(pass));
      expect(contents.skipped, 1);
      expect(contents.items.length, 2);
      expect(contents.items.first.urls, isEmpty);
      await device.createFromBackup(
        contents,
        secret(Canary.master),
        params: fastKdf,
      );
      contents.wipe();
      expect(device.prefs, isEmpty);
      expect(VaultPrefs.hintsInHistory.of(device.prefs), isFalse);
      expect(device.idleTimeout, const Duration(minutes: 5));
      expect(device.lastBackupAt, isNull);
      expect(device.masterDue, isFalse);
      for (final e in device.entries) {
        expect(e.important, isFalse);
        expect(e.train, isEmpty);
        expect(e.flags, isEmpty);
        expect(e.score, isNull);
        // Отпечаток не сошёлся с пересчитанным — fp_old сброшены.
        expect(e.fpOld, isEmpty);
        expect(e.fp, isNot(List<int>.filled(32, 7)));
      }
    });

    test('глубина JSON 100 — corrupt', () async {
      Object nest(int depth) =>
          depth == 0 ? <Object?>[] : <Object?>[nest(depth - 1)];
      final bytes = await forge(
        <String, Object?>{
          'schema': 1,
          'rev': 1,
          'k_fp': base64.encode(List<int>.filled(32, 1)),
          'entries': <Object?>[],
          'deep': nest(100),
        },
        const <String, String>{},
      );
      final device = await newVault();
      await expectLater(
        device.readBackup(bytes, secret(pass)),
        throwsA(VaultError.corrupt),
      );
    });

    test('mem = 1 ГиБ — kdfInvalid без вывода ключа', () async {
      final counting = _CountingCrypto(crypto);
      final device = await newVault(InMemoryVaultStore(), counting);
      final json = <String, Object?>{
        'format': VaultFormat.name,
        'v': 1,
        'kind': 'backup',
        'vault_id': base64.encode(List<int>.filled(16, 3)),
        'kdf': <String, Object?>{
          'alg': 'argon2id13',
          'ops': 3,
          'mem': 1024 * mib,
          'salt': base64.encode(List<int>.filled(16, 4)),
        },
        'wrap_pw': <String, Object?>{
          'n': base64.encode(List<int>.filled(24, 5)),
          'c': base64.encode(List<int>.filled(48, 6)),
        },
        'rev': 1,
        'index': <String, Object?>{
          'n': base64.encode(List<int>.filled(24, 5)),
          'c': base64.encode(List<int>.filled(4112, 6)),
        },
        'secrets': <String, Object?>{},
      };
      await expectLater(
        device.readBackup(
          Uint8List.fromList(utf8.encode(jsonEncode(json))),
          secret(pass),
        ),
        throwsA(VaultError.kdfInvalid),
      );
      expect(counting.derives, 0);
    });

    test('копию нельзя открыть как хранилище, хранилище — как копию', () async {
      final vault = await filled();
      final bytes = await vault.exportBackup(master: secret(Canary.master));
      final asVault = InMemoryVaultStore();
      await asVault.writeVault(bytes);
      final victim = await newVault(asVault);
      await expectLater(
        victim.unlock(secret(Canary.master)),
        throwsA(VaultError.corrupt),
      );
      final own = (await vault.store.readVault())!;
      await expectLater(
        vault.readBackup(own, secret(Canary.master)),
        throwsA(VaultError.corrupt),
      );
    });

    test('больше 20 МБ — corrupt без разбора', () async {
      final device = await newVault();
      await expectLater(
        device.readBackup(Uint8List(VaultBackup.maxBytes + 1), secret(pass)),
        throwsA(VaultError.corrupt),
      );
    });
  });
}
