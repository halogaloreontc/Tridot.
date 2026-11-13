// Формат и файлы хранилища паролей (ADR-014, раздел 11, группа 2): круг
// записи и чтения, дополнение до 4 КиБ, «слишком новый» файл, миграция с
// синтетической v0, неизвестные поля, сбой на rename, права каталога,
// смена мастер-пароля и «перешифровать всё», откат по частям.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/passwords/secret_bytes.dart';
import 'package:local_assistant/core/passwords/vault.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_errors.dart';
import 'package:local_assistant/core/passwords/vault_format.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';
import 'package:path/path.dart' as p;

import 'vault_test_support.dart';

Map<String, Object?> _json(Uint8List bytes) =>
    jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;

Uint8List _bytes(Map<String, Object?> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

/// Хранилище, которое пишет журнал операций.
final class _LoggingStore implements VaultStore {
  final InMemoryVaultStore inner = InMemoryVaultStore();
  final List<String> log = <String>[];

  @override
  Future<bool> hasVault() => inner.hasVault();
  @override
  Future<Uint8List?> readVault() => inner.readVault();
  @override
  Future<Uint8List?> readPrevious() => inner.readPrevious();
  @override
  Future<void> writeVault(Uint8List bytes, {bool replacePrevious = false}) {
    log.add(replacePrevious ? 'vault+prev' : 'vault');
    return inner.writeVault(bytes, replacePrevious: replacePrevious);
  }

  @override
  Future<void> writePrevious(Uint8List bytes) {
    log.add('prev');
    return inner.writePrevious(bytes);
  }

  @override
  Future<List<int>> backupVersions() => inner.backupVersions();
  @override
  Future<Uint8List?> readBackup(int version) => inner.readBackup(version);
  @override
  Future<void> writeBackup(int version, Uint8List bytes) {
    log.add('bak$version');
    return inner.writeBackup(version, bytes);
  }

  @override
  Future<void> deleteBackup(int version) {
    log.add('-bak$version');
    return inner.deleteBackup(version);
  }

  @override
  Future<Uint8List?> readAttempts() => inner.readAttempts();
  @override
  Future<void> writeAttempts(Uint8List bytes) => inner.writeAttempts(bytes);
  @override
  Future<void> removeTemporary() => inner.removeTemporary();
  @override
  Future<void> archiveVault(String name) => inner.archiveVault(name);
  @override
  Future<List<String>> archived() => inner.archived();
}

void main() {
  late SodiumVaultCrypto crypto;

  setUpAll(() async {
    crypto = await testCrypto();
  });

  /// Кольцо ключей файла [file] по паролю [master] или `null`.
  Future<VaultKeyRing?> ringFor(Uint8List file, String master) async {
    final envelope = VaultEnvelope.decode(file);
    final header = VaultKeys.header(envelope);
    final password = secret(master);
    final kek = await crypto.derive(password, envelope.kdf.salt, fastKdf);
    password.wipe();
    final vk = crypto.openKey(kek, envelope.wrapPw, VaultKeys.wrapPwAd(header));
    kek.dispose();
    return vk == null ? null : VaultKeyRing.from(crypto, vk);
  }

  /// Индекс файла [file] кольцом [ring] или `null`.
  VaultIndex? indexWith(Uint8List file, VaultKeyRing ring) {
    final envelope = VaultEnvelope.decode(file);
    final body = crypto.open(
      ring.index,
      envelope.index,
      VaultKeys.indexAd(VaultKeys.header(envelope), envelope.rev),
    );
    return body == null ? null : VaultIndex.decodePadded(body);
  }

  /// Файл, собранный вручную: версия [version], схема индекса [schema],
  /// лишние поля [extra] в индексе и [entryExtra] в записи.
  Future<(Uint8List, String)> craft({
    int version = 1,
    int schema = 1,
    Map<String, Object?> extra = const <String, Object?>{},
    Map<String, Object?> entryExtra = const <String, Object?>{},
  }) async {
    const kind = VaultFormat.kindVault;
    final vaultId = base64.encode(crypto.bytes(16));
    final salt = crypto.bytes(16);
    final header = VaultKeys.headerOf(
      version: version,
      kind: kind,
      vaultId: vaultId,
      ops: fastKdf.ops,
      mem: fastKdf.mem,
      salt: salt,
    );
    final master = secret(Canary.master);
    final kek = await crypto.derive(master, salt, fastKdf);
    final ring = VaultKeyRing.from(crypto, crypto.randomKey());
    final wrap = crypto.sealKey(kek, ring.vk, VaultKeys.wrapPwAd(header));
    final kFpBytes = SecretBytes.adopt(crypto.bytes(32));
    final kFp = crypto.importKey(kFpBytes.clone());
    final id = VaultIds.hex(crypto.bytes(16));
    final password = secret(Canary.password);
    final fp = VaultKeys.fingerprint(crypto, kFp, password);
    final now = DateTime.utc(2026).toIso8601String();
    final index = <String, Object?>{
      ...extra,
      'schema': schema,
      'rev': 3,
      'k_fp': base64.encode(kFpBytes.unsafeBytes),
      'entries': <Object?>[
        <String, Object?>{
          ...entryExtra,
          'id': id,
          'srev': 1,
          schema == 0 ? 'title' : 'service': 'Почта',
          'created': now,
          'changed': now,
          'fp': base64.encode(fp),
        },
      ],
    };
    final body = VaultPadding.pad(
      Uint8List.fromList(utf8.encode(jsonEncode(index))),
      VaultFormat.indexBlock,
    );
    final secretBody = SecretCodec.encodePadded(password, secret(Canary.note));
    final file = <String, Object?>{
      'format': VaultFormat.name,
      'v': version,
      if (version >= 1) 'kind': kind,
      'vault_id': vaultId,
      'kdf': KdfRecord(ops: fastKdf.ops, mem: fastKdf.mem, salt: salt).toJson(),
      'wrap_pw': wrap.toJson(),
      'rev': 3,
      'index':
          crypto.seal(ring.index, body, VaultKeys.indexAd(header, 3)).toJson(),
      'secrets': <String, Object?>{
        id: SealedSecret(
          crypto.seal(
            ring.secret,
            secretBody,
            VaultKeys.secretAd(
              version: version,
              kind: kind,
              vaultId: vaultId,
              entryId: id,
              srev: 1,
            ),
          ),
          1,
        ).toJson(),
      },
    };
    kek.dispose();
    kFp.dispose();
    ring.dispose();
    return (_bytes(file), id);
  }

  group('формат', () {
    test('круг записи и чтения: записи и секреты на месте', () async {
      final store = InMemoryVaultStore();
      final vault = testVault(store, crypto);
      await vault.create(secret(Canary.master), params: fastKdf);
      final id = await vault.addEntry(
        service: 'Почта',
        login: Canary.login,
        hint: Canary.hint,
        urls: const <String>['https://mail.example.org'],
        important: true,
        password: secret(Canary.password),
        note: secret(Canary.note),
      );
      vault.lock();
      expect(vault.entries, isEmpty);

      final fresh = testVault(store, crypto);
      await fresh.load();
      expect(fresh.state, VaultState.locked);
      await fresh.unlock(secret(Canary.master));
      final entry = fresh.entry(id)!;
      expect(entry.service, 'Почта');
      expect(entry.login, Canary.login);
      expect(entry.hint, Canary.hint);
      expect(entry.important, isTrue);
      expect(entry.urls, <String>['https://mail.example.org']);
      final value = await fresh.readSecret(id);
      expect(utf8.decode(value.password.unsafeBytes), Canary.password);
      expect(utf8.decode(value.note.unsafeBytes), Canary.note);
      value.wipe();
      expect(value.password.isWiped, isTrue);
      expect(entry.toString(), 'VaultEntry($id)');
    });

    test('индекс дополнен до 4 КиБ, секрет — до 256 Б', () async {
      final store = InMemoryVaultStore();
      final vault = testVault(store, crypto);
      await vault.create(secret(Canary.master), params: fastKdf);
      final short = await vault.addEntry(
        service: 'А',
        password: secret('CANARY-1'),
      );
      final long = await vault.addEntry(
        service: 'Б',
        password: secret('CANARY-${'x' * 120}'),
      );
      final envelope = VaultEnvelope.decode((await store.readVault())!);
      expect((envelope.index.cipher.length - 16) % 4096, 0);
      final a = envelope.secrets[short]!.box.cipher.length - 16;
      final b = envelope.secrets[long]!.box.cipher.length - 16;
      expect(a % 256, 0);
      expect(a, b, reason: 'длина пароля не видна');
      expect(
        VaultPadding.unpad(
          VaultPadding.pad(Uint8List.fromList(<int>[1, 2, 3]), 16),
          16,
        ),
        <int>[1, 2, 3],
      );
      expect(
        () => VaultPadding.unpad(Uint8List(15), 16),
        throwsA(VaultError.corrupt),
      );
    });

    test('v новее приложения → tooNew, файл не тронут', () async {
      final store = InMemoryVaultStore();
      final vault = testVault(store, crypto);
      await vault.create(secret(Canary.master), params: fastKdf);
      vault.lock();
      final json = _json((await store.readVault())!)
        ..['v'] = VaultFormat.version + 1;
      final bytes = _bytes(json);
      store.files[FileVaultStore.vaultName] = bytes;
      final fresh = testVault(store, crypto);
      await expectLater(
        fresh.unlock(secret(Canary.master)),
        throwsA(VaultError.tooNew),
      );
      expect(store.files[FileVaultStore.vaultName], bytes);
      expect(store.files.containsKey(FileVaultStore.previousName), isFalse);
    });

    test('миграция с синтетической v0: копия .bak, затем текущая, .bak удалён',
        () async {
      final store = _LoggingStore();
      final (file, id) = await craft(version: 0, schema: 0);
      store.inner.files[FileVaultStore.vaultName] = file;
      final vault = testVault(store, crypto);
      await vault.unlock(secret(Canary.master));
      expect(store.log, <String>['bak0', 'vault', '-bak0']);
      expect(vault.entry(id)!.service, 'Почта');
      final migrated = _json((await store.readVault())!);
      expect(migrated['v'], VaultFormat.version);
      expect(migrated['kind'], 'vault');
      final value = await vault.readSecret(id);
      expect(utf8.decode(value.password.unsafeBytes), Canary.password);
      value.wipe();
      // Мигрированный файл открывается заново.
      vault.lock();
      final again = testVault(store, crypto);
      await again.unlock(secret(Canary.master));
      (await again.readSecret(id)).wipe();
      expect(await store.backupVersions(), isEmpty);
    });

    test('миграция v1 → v2 (ADR-015): .bak1 записан и удалён, без хронологии',
        () async {
      final store = _LoggingStore();
      final (file, id) = await craft();
      store.inner.files[FileVaultStore.vaultName] = file;
      final vault = testVault(store, crypto);
      await vault.unlock(secret(Canary.master));
      expect(store.log, <String>['bak1', 'vault', '-bak1']);
      final migrated = _json((await store.readVault())!);
      expect(migrated['v'], 2);
      expect(migrated.containsKey('history'), isFalse);
      expect(vault.entry(id)!.history, isEmpty);
      final value = await vault.readSecret(id);
      expect(utf8.decode(value.password.unsafeBytes), Canary.password);
      value.wipe();
      vault.lock();
      final again = testVault(store, crypto);
      await again.unlock(secret(Canary.master));
      (await again.readSecret(id)).wipe();
      expect(await store.backupVersions(), isEmpty);
    });

    test('миграция не записалась (io) — не открываем, файл v0 цел', () async {
      final store = InMemoryVaultStore();
      final (file, id) = await craft(version: 0, schema: 0);
      store.files[FileVaultStore.vaultName] = file;
      store.failNextWrite = true;
      final vault = testVault(store, crypto);
      await expectLater(
        vault.unlock(secret(Canary.master)),
        throwsA(VaultError.io),
      );
      expect(vault.isUnlocked, isFalse);
      expect(vault.entries, isEmpty);
      expect(await store.readVault(), file, reason: 'v0 не тронут');
      // Следующее открытие мигрирует, и записи на месте.
      final again = testVault(store, crypto);
      await again.unlock(secret(Canary.master));
      await again.addEntry(service: 'Форум', password: secret('CANARY-2'));
      (await again.readSecret(id)).wipe();
      again.lock();
      final fresh = testVault(store, crypto);
      await fresh.unlock(secret(Canary.master));
      expect(fresh.entries, hasLength(2));
      final value = await fresh.readSecret(id);
      expect(utf8.decode(value.password.unsafeBytes), Canary.password);
      value.wipe();
    });

    test('заметка с переводами строк в пределе — файл открывается', () async {
      final store = InMemoryVaultStore();
      final vault = testVault(store, crypto);
      await vault.create(secret(Canary.master), params: fastKdf);
      final text = 'abcd1234\n' * 1820;
      expect(text.length, lessThanOrEqualTo(VaultFormat.maxNote));
      final id = await vault.addEntry(
        service: 'Коды',
        password: secret(Canary.password),
        note: secret(text),
      );
      vault.lock();
      final fresh = testVault(store, crypto);
      await fresh.unlock(secret(Canary.master));
      final value = await fresh.readSecret(id);
      expect(utf8.decode(value.note.unsafeBytes), text);
      value.wipe();
    });

    test('худший секрет (одни управляющие и кавычки) — в пределе формата',
        () async {
      final password = SecretBytes.copy(
        Uint8List.fromList(List<int>.filled(VaultFormat.maxPassword, 0x22)),
      );
      final note = SecretBytes.copy(
        Uint8List.fromList(List<int>.filled(VaultFormat.maxNote, 0x01)),
      );
      final store = InMemoryVaultStore();
      final vault = testVault(store, crypto);
      await vault.create(secret(Canary.master), params: fastKdf);
      final id = await vault.addEntry(
        service: 'Худший',
        password: password,
        note: note,
      );
      vault.lock();
      final fresh = testVault(store, crypto);
      await fresh.unlock(secret(Canary.master));
      final value = await fresh.readSecret(id);
      expect(value.password.unsafeBytes, password.unsafeBytes);
      expect(value.note.unsafeBytes, note.unsafeBytes);
      value.wipe();
    });

    test('неизвестные поля индекса и записи сохраняются', () async {
      final store = InMemoryVaultStore();
      final (file, id) = await craft(
        extra: const <String, Object?>{
          'future_field': <String>['a'],
        },
        entryExtra: const <String, Object?>{'totp_hint': 'later'},
      );
      store.files[FileVaultStore.vaultName] = file;
      final vault = testVault(store, crypto);
      await vault.unlock(secret(Canary.master));
      await vault.updateInfo(id, hint: 'новая подсказка');
      vault.lock();
      final ring = (await ringFor((await store.readVault())!, Canary.master))!;
      final index = indexWith((await store.readVault())!, ring)!;
      expect(index.extra['future_field'], <Object?>['a']);
      expect(index.entries.single.extra['totp_hint'], 'later');
      expect(index.entries.single.hint, 'новая подсказка');
      ring.dispose();
    });

    test('порченый JSON, глубина и base64 — corrupt без текста причины', () {
      for (final bad in <String>[
        'не json',
        '{"format":"relay-vault","v":1,"kind":"vault"}',
        '[${'[' * 20}${']' * 20}]',
        '{"format":"relay-vault","v":1,"kind":"vault","vault_id":"!!!"}',
      ]) {
        expect(
          () => VaultEnvelope.decode(Uint8List.fromList(utf8.encode(bad))),
          throwsA(
            isA<VaultError>()
                .having((VaultError e) => e.toString(), 'text', 'corrupt'),
          ),
          reason: bad,
        );
      }
      expect(
        JsonLimits.within('{"a":[[1]]}', maxDepth: 3, maxElements: 10),
        isTrue,
      );
      expect(
        JsonLimits.within('{"a":[[[1]]]}', maxDepth: 3, maxElements: 10),
        isFalse,
      );
      expect(
        JsonLimits.within('{"a":"[[[[[["}', maxDepth: 2, maxElements: 10),
        isTrue,
      );
    });

    test('секрет: побайтный JSON с экранированием и юникодом', () {
      final password = SecretBytes.copy(
        utf8.encode('CANARY "кавычка" \\ \n\t ✓ 𝄞'),
      );
      final padded = SecretCodec.encodePadded(password, SecretBytes.empty());
      expect(padded.length % 256, 0);
      final back = SecretCodec.decodePadded(padded);
      expect(back.password.unsafeBytes, password.unsafeBytes);
      expect(back.note.isEmpty, isTrue);
      expect(padded.every((int b) => b == 0), isTrue, reason: 'затёрт');
      // Совместим с обычным JSON.
      final again = SecretCodec.encodePadded(password, password);
      final body = VaultPadding.unpad(Uint8List.fromList(again), 256);
      final json = jsonDecode(utf8.decode(body)) as Map<String, Object?>;
      expect(json['p'], 'CANARY "кавычка" \\ \n\t ✓ 𝄞');
      expect(json.keys, <String>['p', 'note']);
    });
  });

  group('файлы', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('vault_files_');
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('сбой на rename — рабочие vault.relayvault и vault.prev', () async {
      final dir = p.join(temp.path, 'vault');
      var fail = false;
      final store = FileVaultStore(
        dir,
        renameForTesting: (File from, String to) async {
          if (fail && p.basename(to) == FileVaultStore.vaultName) {
            throw const FileSystemException('сбой');
          }
          await from.rename(to);
        },
      );
      final vault = testVault(store, crypto);
      await vault.create(secret(Canary.master), params: fastKdf);
      final id = await vault.addEntry(
        service: 'Почта',
        password: secret(Canary.password),
      );
      fail = true;
      await expectLater(
        vault.addEntry(service: 'Форум', password: secret('CANARY-2')),
        throwsA(VaultError.io),
      );
      expect(vault.entries, hasLength(1), reason: 'в памяти не изменилось');
      fail = false;
      vault.lock();

      for (final name in <String>[
        FileVaultStore.vaultName,
        FileVaultStore.previousName,
      ]) {
        final bytes = await File(p.join(dir, name)).readAsBytes();
        final ring = (await ringFor(bytes, Canary.master))!;
        expect(indexWith(bytes, ring), isNotNull, reason: name);
        ring.dispose();
      }
      expect(
        File(p.join(dir, '${FileVaultStore.vaultName}.tmp')).existsSync(),
        isTrue,
      );
      final fresh = testVault(FileVaultStore(dir), crypto);
      await fresh.load();
      expect(
        File(p.join(dir, '${FileVaultStore.vaultName}.tmp')).existsSync(),
        isFalse,
      );
      await fresh.unlock(secret(Canary.master));
      expect(fresh.entries.single.id, id);
    });

    test('удаление: сбой записи vault.prev — отказ целиком, без полумер',
        () async {
      final dir = p.join(temp.path, 'vault');
      var fail = false;
      final store = FileVaultStore(
        dir,
        renameForTesting: (File from, String to) async {
          if (fail && p.basename(to) == FileVaultStore.previousName) {
            throw const FileSystemException('сбой');
          }
          await from.rename(to);
        },
      );
      final vault = testVault(store, crypto);
      await vault.create(secret(Canary.master), params: fastKdf);
      final a = await vault.addEntry(
        service: 'Почта',
        password: secret(Canary.password),
      );
      final b = await vault.addEntry(
        service: 'Форум',
        password: secret('CANARY-2'),
      );
      fail = true;
      await expectLater(vault.deleteEntry(a), throwsA(VaultError.io));
      // Сказали «не удалилось» — и правда не удалилось: в памяти и на диске.
      expect(vault.entries.map((VaultEntry e) => e.id), <String>[a, b]);
      final onDisk = (await store.readVault())!;
      final ring = (await ringFor(onDisk, Canary.master))!;
      expect(
        indexWith(onDisk, ring)!.entries.map((VaultEntry e) => e.id),
        <String>[a, b],
      );
      ring.dispose();
      fail = false;
      await vault.deleteEntry(a);
      expect(vault.entries.single.id, b);
      final prev = VaultEnvelope.decode((await store.readPrevious())!);
      expect(prev.secrets.containsKey(a), isFalse);
    });

    test('каталог 700 до первой записи, файлы 600', () async {
      if (!Platform.isLinux && !Platform.isMacOS) return;
      final dir = p.join(temp.path, 'assistant', 'vault');
      final vault = testVault(FileVaultStore(dir), crypto);
      await vault.create(secret(Canary.master), params: fastKdf);
      await vault.addEntry(service: 'Почта', password: secret(Canary.password));
      String mode(String path) =>
          (FileStat.statSync(path).mode & 0x1FF).toRadixString(8);
      expect(mode(dir), '700');
      expect(mode(p.join(dir, FileVaultStore.vaultName)), '600');
      expect(mode(p.join(dir, FileVaultStore.previousName)), '600');
      expect(mode(p.join(dir, FileVaultStore.attemptsName)), isNotNull);
    });
  });

  group('мастер-пароль и ключи', () {
    test(
        'смена мастер-пароля: индекс тот же, VK новый, .prev и .bak '
        'со старым паролем не открываются', () async {
      final store = InMemoryVaultStore();
      final vault = testVault(store, crypto);
      await vault.create(secret(Canary.master), params: fastKdf);
      final id = await vault.addEntry(
        service: 'Почта',
        login: Canary.login,
        password: secret(Canary.password),
        note: secret(Canary.note),
      );
      await store.writeBackup(0, (await store.readVault())!);
      final before = (await store.readVault())!;
      final entriesBefore = vault.entries.map((VaultEntry e) => e.toJson());

      await vault.changeMaster(
        current: secret(Canary.master),
        next: secret('CANARY-new-master'),
        params: fastKdf,
      );
      expect(
        vault.entries.map((VaultEntry e) => e.toJson()),
        entriesBefore,
        reason: 'содержимое индекса не изменилось',
      );
      final after = (await store.readVault())!;
      // Старый VK (из старого файла и старого пароля) не открывает новый
      // индекс.
      final oldRing = (await ringFor(before, Canary.master))!;
      expect(indexWith(after, oldRing), isNull);
      oldRing.dispose();
      for (final bytes in <Uint8List>[
        after,
        (await store.readPrevious())!,
        (await store.readBackup(0))!,
      ]) {
        expect(await ringFor(bytes, Canary.master), isNull);
        final ring = (await ringFor(bytes, 'CANARY-new-master'))!;
        expect(indexWith(bytes, ring), isNotNull);
        ring.dispose();
      }
      // Секреты перешифрованы и читаются.
      final value = await vault.readSecret(id);
      expect(utf8.decode(value.password.unsafeBytes), Canary.password);
      value.wipe();
      vault.lock();
      await expectLater(
        testVault(store, crypto).unlock(secret(Canary.master)),
        throwsA(VaultError.wrongPassword),
      );
    });

    test('смена мастер-пароля требует верный текущий', () async {
      final vault = testVault(InMemoryVaultStore(), crypto);
      await vault.create(secret(Canary.master), params: fastKdf);
      await expectLater(
        vault.changeMaster(
          current: secret('CANARY-wrong'),
          next: secret('CANARY-new-master'),
          params: fastKdf,
        ),
        throwsA(VaultError.wrongPassword),
      );
    });

    test('«перешифровать всё» меняет VK, пароль прежний', () async {
      final store = InMemoryVaultStore();
      final vault = testVault(store, crypto);
      await vault.create(secret(Canary.master), params: fastKdf);
      final id = await vault.addEntry(
        service: 'Почта',
        password: secret(Canary.password),
      );
      final before = (await store.readVault())!;
      await vault.reencryptAll(secret(Canary.master));
      final after = (await store.readVault())!;
      final oldRing = (await ringFor(before, Canary.master))!;
      final newRing = (await ringFor(after, Canary.master))!;
      expect(indexWith(after, oldRing), isNull);
      expect(indexWith(after, newRing), isNotNull);
      expect(
        crypto.exportKey(oldRing.vk).unsafeBytes,
        isNot(crypto.exportKey(newRing.vk).unsafeBytes),
      );
      oldRing.dispose();
      newRing.dispose();
      (await vault.readSecret(id)).wipe();
    });

    test('удаление записи перезаписывает vault.prev', () async {
      final store = InMemoryVaultStore();
      final vault = testVault(store, crypto);
      await vault.create(secret(Canary.master), params: fastKdf);
      final id = await vault.addEntry(
        service: 'Почта',
        password: secret(Canary.password),
      );
      await vault.addEntry(service: 'Форум', password: secret('CANARY-2'));
      await vault.deleteEntry(id);
      final prev = VaultEnvelope.decode((await store.readPrevious())!);
      expect(prev.secrets.containsKey(id), isFalse);
      expect(await store.readPrevious(), await store.readVault());
    });

    test('k_fp переживает смену мастер-пароля: отпечатки те же', () async {
      final vault = testVault(InMemoryVaultStore(), crypto);
      await vault.create(secret(Canary.master), params: fastKdf);
      await vault.addEntry(service: 'Почта', password: secret(Canary.password));
      final fp = vault.fingerprint(secret(Canary.password));
      await vault.changeMaster(
        current: secret(Canary.master),
        next: secret('CANARY-new-master'),
        params: fastKdf,
      );
      expect(vault.fingerprint(secret(Canary.password)), fp);
      expect(vault.matchesKnownSecret(Canary.password), isTrue);
      expect(vault.matchesKnownSecret('CANARY-not-this'), isFalse);
    });
  });

  group('откат по частям', () {
    late InMemoryVaultStore store;
    late Vault vault;
    late String id;
    late Uint8List oldFile;

    setUp(() async {
      store = InMemoryVaultStore();
      vault = testVault(store, crypto);
      await vault.create(secret(Canary.master), params: fastKdf);
      id = await vault.addEntry(
        service: 'Почта',
        password: secret('CANARY-old-pw'),
      );
      oldFile = (await store.readVault())!;
      await vault.updatePassword(id, secret(Canary.password));
      vault.lock();
    });

    test('секрет из старой версии с правленым «r» → corrupt', () async {
      final current = _json((await store.readVault())!);
      final old = _json(oldFile);
      final oldSecret = (old['secrets']! as Map<String, Object?>)[id]!
          as Map<String, Object?>;
      final secrets = current['secrets']! as Map<String, Object?>;
      final r = (secrets[id]! as Map<String, Object?>)['r'];
      secrets[id] = <String, Object?>{...oldSecret, 'r': r};
      store.files[FileVaultStore.vaultName] = _bytes(current);
      final fresh = testVault(store, crypto);
      await fresh.unlock(secret(Canary.master));
      await expectLater(fresh.readSecret(id), throwsA(VaultError.corrupt));
    });

    test('«r» не совпал с srev → corrupt при открытии', () async {
      final current = _json((await store.readVault())!);
      final secrets = current['secrets']! as Map<String, Object?>;
      (secrets[id]! as Map<String, Object?>)['r'] = 1;
      store.files[FileVaultStore.vaultName] = _bytes(current);
      await expectLater(
        testVault(store, crypto).unlock(secret(Canary.master)),
        throwsA(VaultError.corrupt),
      );
    });

    test('внешний rev не совпал с внутренним → corrupt', () async {
      final current = _json((await store.readVault())!);
      current['rev'] = (current['rev']! as int) + 1;
      store.files[FileVaultStore.vaultName] = _bytes(current);
      await expectLater(
        testVault(store, crypto).unlock(secret(Canary.master)),
        throwsA(VaultError.corrupt),
      );
    });

    test('лишний или недостающий id в secrets → corrupt', () async {
      final current = _json((await store.readVault())!);
      final secrets = current['secrets']! as Map<String, Object?>;
      final extra = <String, Object?>{
        ...current,
        'secrets': <String, Object?>{
          ...secrets,
          VaultIds.hex(Uint8List(16)): secrets[id],
        },
      };
      store.files[FileVaultStore.vaultName] = _bytes(extra);
      await expectLater(
        testVault(store, crypto).unlock(secret(Canary.master)),
        throwsA(VaultError.corrupt),
      );
      final missing = <String, Object?>{
        ...current,
        'secrets': <String, Object?>{},
      };
      store.files[FileVaultStore.vaultName] = _bytes(missing);
      await expectLater(
        testVault(store, crypto).unlock(secret(Canary.master)),
        throwsA(VaultError.corrupt),
      );
    });

    test('rev меньше seen_rev — предупреждение, не отказ', () async {
      final fresh = testVault(store, crypto);
      final result = await fresh.unlock(secret(Canary.master), seenRev: 99);
      expect(result.rolledBack, isTrue);
      fresh.lock();
      final ok = await testVault(store, crypto)
          .unlock(secret(Canary.master), seenRev: 1);
      expect(ok.rolledBack, isFalse);
    });

    test('updatePassword: .prev перезаписан, старого пароля там нет', () async {
      expect(await store.readPrevious(), await store.readVault());
    });

    test('updatePassword: прежний отпечаток в fp_old, srev вырос', () async {
      final fresh = testVault(store, crypto);
      await fresh.unlock(secret(Canary.master));
      final entry = fresh.entry(id)!;
      expect(entry.srev, 2);
      expect(entry.fpOld, hasLength(1));
      expect(entry.fpOld.single, fresh.fingerprint(secret('CANARY-old-pw')));
    });
  });
}
