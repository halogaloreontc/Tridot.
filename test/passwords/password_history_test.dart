// Хронология паролей (ADR-015): опция выключена по умолчанию, включение —
// только с мастер-паролем, прежний пароль шифруется как текущий, лимит,
// удаление опечатки восстанавливает D7, пересборка при смене ключа,
// согласованность конверта и индекса, резервная копия.
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

/// Смены пароля разнесены по дням: автозапирание не мешает.
const VaultPolicy _long = VaultPolicy(
  idle: Duration(days: 365),
  hardLimit: Duration(days: 365),
);

/// Прежние пароли записи — канарейки с номером.
String _old(int n) => 'CANARY-hist-$n-Wq';

Map<String, Object?> _json(Uint8List bytes) =>
    jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;

Uint8List _bytes(Map<String, Object?> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

void main() {
  late SodiumVaultCrypto crypto;

  setUpAll(() async {
    crypto = await testCrypto();
  });

  late InMemoryVaultStore store;
  late TestClock clock;
  late Vault vault;

  setUp(() async {
    store = InMemoryVaultStore();
    clock = TestClock();
    vault = testVault(store, crypto, clock: clock, policy: _long);
    await vault.create(secret(Canary.master), params: fastKdf);
  });

  Future<void> enable() => vault.setPrefs(
        <String, Object?>{'pw_history': true},
        master: secret(Canary.master),
      );

  Future<String> plain(Future<SecretBytes> read) async {
    final value = await read;
    try {
      return utf8.decode(value.unsafeBytes);
    } finally {
      value.wipe();
    }
  }

  Future<String> currentOf(String id) async {
    final value = await vault.readSecret(id);
    try {
      return utf8.decode(value.password.unsafeBytes);
    } finally {
      value.wipe();
    }
  }

  Future<String> historyText(String id, String hid) =>
      plain(vault.readHistoryPassword(id, hid));

  Future<String> addMail() => vault.addEntry(
        service: 'Почта',
        login: Canary.login,
        password: secret(_old(0)),
      );

  /// Пароль записи сменили [times] раз: `_old(0)` → … → `_old(times)`,
  /// между сменами проходит день.
  Future<String> changed(int times) async {
    final id = await addMail();
    for (var n = 1; n <= times; n++) {
      clock.advance(const Duration(days: 1));
      await vault.updatePassword(id, secret(_old(n)));
    }
    return id;
  }

  Future<Map<String, Object?>> file() async =>
      _json((await store.readVault())!);

  group('опция', () {
    test('выключена по умолчанию: ни hist, ни history, D7 как раньше',
        () async {
      expect(VaultPrefs.passwordHistory.of(vault.prefs), isFalse);
      expect(vault.historyEnabled, isFalse);
      final id = await changed(2);
      expect(vault.entry(id)!.history, isEmpty);
      expect((await file()).containsKey('history'), isFalse);
      expect(vault.historyCount, 0);
      for (final bytes in <Uint8List?>[
        await store.readVault(),
        await store.readPrevious(),
      ]) {
        expect(VaultEnvelope.decode(bytes!).history, isEmpty);
      }
    });

    test('включение — только с верным мастер-паролем', () async {
      final changes = <String, Object?>{'pw_history': true};
      expect(vault.prefsWeaken(changes), isTrue);
      await expectLater(vault.setPrefs(changes), throwsArgumentError);
      await expectLater(
        vault.setPrefs(changes, master: secret('CANARY-wrong-master')),
        throwsA(VaultError.wrongPassword),
      );
      expect(vault.historyEnabled, isFalse);
      await enable();
      expect(vault.historyEnabled, isTrue);
      // Выключение защиту не ослабляет: без мастер-пароля.
      expect(
        vault.prefsWeaken(<String, Object?>{'pw_history': false}),
        isFalse,
      );
      await vault.setPrefs(<String, Object?>{'pw_history': false});
      expect(vault.historyEnabled, isFalse);
    });
  });

  group('смена пароля', () {
    test('прежний пароль — один элемент с верными датами', () async {
      await enable();
      final id = await addMail();
      final created = vault.entry(id)!.changed;
      clock.advance(const Duration(hours: 5));
      await vault.updatePassword(id, secret(_old(1)));
      final history = vault.entry(id)!.history;
      expect(history, hasLength(1));
      expect(history.single.from, created);
      expect(history.single.to, clock.now());
      expect(history.single.src, DateSource.user);
      expect(history.single.looksLikeTypo, isFalse);
      expect(await historyText(id, history.single.id), _old(0));
      expect(await currentOf(id), _old(1));
      // Снаружи — только число элементов.
      final outside = await file();
      expect(
        (outside['history']! as Map<String, Object?>).keys,
        <String>[history.single.id],
      );
    });

    test('тот же пароль — хронология не растёт', () async {
      await enable();
      final id = await addMail();
      await vault.updatePassword(id, secret(_old(0)));
      expect(vault.entry(id)!.history, isEmpty);
      await vault.updateNote(id, secret(Canary.note));
      expect(vault.entry(id)!.history, isEmpty);
    });

    test('предел 10: самая старая коробка удаляется', () async {
      await enable();
      final id = await changed(VaultEntry.maxHistory + 2);
      final history = vault.entry(id)!.history;
      expect(history, hasLength(VaultEntry.maxHistory));
      expect(
        VaultEnvelope.decode((await store.readVault())!).history,
        hasLength(VaultEntry.maxHistory),
      );
      // Новые первыми: последний прежний — _old(11), самый старый — _old(2).
      expect(
        await historyText(id, history.first.id),
        _old(VaultEntry.maxHistory + 1),
      );
      expect(await historyText(id, history.last.id), _old(2));
    });

    test('возврат к прежнему паролю убирает его из хронологии', () async {
      await enable();
      final id = await changed(2); // хронология: _old(1), _old(0)
      await vault.updatePassword(id, secret(_old(0)));
      final history = vault.entry(id)!.history;
      expect(history, hasLength(2));
      expect(
        <String>[for (final h in history) await historyText(id, h.id)],
        <String>[_old(2), _old(1)],
      );
      expect(vault.entry(id)!.flags, contains(EntryFlags.returnedOld));
    });

    test('опечатка: пароль простоял меньше часа', () async {
      await enable();
      final id = await addMail();
      clock.advance(const Duration(days: 3));
      await vault.updatePassword(id, secret(_old(1)));
      clock.advance(const Duration(minutes: 2));
      await vault.updatePassword(id, secret(_old(2)));
      final history = vault.entry(id)!.history;
      expect(history.first.looksLikeTypo, isTrue);
      expect(history.last.looksLikeTypo, isFalse);
    });

    test('опция выключена с «Оставить»: старые видны, новые не копятся',
        () async {
      await enable();
      final id = await changed(1);
      await vault.setPrefs(<String, Object?>{'pw_history': false});
      clock.advance(const Duration(days: 1));
      await vault.updatePassword(id, secret(_old(2)));
      final history = vault.entry(id)!.history;
      expect(history, hasLength(1));
      expect(await historyText(id, history.single.id), _old(0));
    });

    test('«Оставить», затем возврат к прежнему — текущий не в хронологии',
        () async {
      await enable();
      final id = await changed(1);
      await vault.setPrefs(<String, Object?>{'pw_history': false});
      clock.advance(const Duration(days: 1));
      await vault.updatePassword(id, secret(_old(0)));
      expect(await currentOf(id), _old(0));
      final history = vault.entry(id)!.history;
      expect(history, isEmpty);
      expect(VaultEnvelope.decode((await store.readVault())!).history, isEmpty);
      expect(vault.historyCount, 0);
    });

    test('неизвестная дата начала — не «опечатка»', () {
      final from = DateTime.utc(2026, 11, 10, 9);
      final to = from.add(const Duration(minutes: 10));
      expect(
        HistoryMeta(id: 'a' * 32, from: from, to: to, src: DateSource.user)
            .looksLikeTypo,
        isTrue,
      );
      expect(
        HistoryMeta(id: 'a' * 32, from: from, to: to, src: DateSource.import)
            .looksLikeTypo,
        isTrue,
      );
      expect(
        HistoryMeta(id: 'a' * 32, from: from, to: to).looksLikeTypo,
        isFalse,
      );
    });

    test('неизвестные поля элемента сохраняются при записи', () {
      final json = <String, Object?>{
        'h': 'b' * 32,
        'from': '2026-11-10T09:00:00.000Z',
        'to': '2026-11-12T09:00:00.000Z',
        'src': 'user',
        'future': <String, Object?>{'k': 1},
      };
      final meta = HistoryMeta.fromJson(json);
      expect(meta.toJson(), json);
      expect(meta.toString(), isNot(contains('future')));
    });

    test('удаление записи убирает её коробки', () async {
      await enable();
      final id = await changed(3);
      final other = await vault.addEntry(
        service: 'Форум',
        password: secret('CANARY-forum-1'),
      );
      await vault.updatePassword(other, secret('CANARY-forum-2'));
      await vault.deleteEntry(id);
      expect(
        VaultEnvelope.decode((await store.readVault())!).history.keys,
        <String>[vault.entry(other)!.history.single.id],
      );
      expect(await store.readPrevious(), await store.readVault());
    });
  });

  group('удаление из хронологии', () {
    test('элемент: meta, коробка и отпечаток исчезают, .prev и .bak = текущий',
        () async {
      await enable();
      final id = await changed(2); // хронология: _old(1), _old(0)
      await store.writeBackup(1, (await store.readPrevious())!);
      final typo = vault.entry(id)!.history.first;
      expect(await vault.recall(id, secret(_old(1))), RecallVerdict.oldOne);
      await vault.deleteHistoryItem(id, typo.id);
      final entry = vault.entry(id)!;
      expect(
        entry.history.map((HistoryMeta h) => h.id),
        isNot(contains(typo.id)),
      );
      expect(entry.history, hasLength(1));
      final current = await store.readVault();
      expect(
        VaultEnvelope.decode(current!).history.containsKey(typo.id),
        isFalse,
      );
      expect(await store.readPrevious(), current);
      expect(await store.readBackup(1), current);
      // От опечатки не осталось и отпечатка: «это прежний пароль» молчит.
      expect(await vault.recall(id, secret(_old(1))), RecallVerdict.wrong);
      expect(await vault.recall(id, secret(_old(0))), RecallVerdict.oldOne);
      await expectLater(
        vault.readHistoryPassword(id, typo.id),
        throwsArgumentError,
      );
    });

    test('чужой id элемента — ошибка, ничего не меняется', () async {
      await enable();
      final id = await changed(1);
      final before = await store.readVault();
      await expectLater(
        vault.deleteHistoryItem(id, '0' * 32),
        throwsArgumentError,
      );
      expect(await store.readVault(), before);
    });

    test('очистить хронологию записи и всего сейфа', () async {
      await enable();
      final a = await changed(3);
      final b = await vault.addEntry(
        service: 'Форум',
        password: secret('CANARY-forum-1'),
      );
      await vault.updatePassword(b, secret('CANARY-forum-2'));
      await vault.clearHistory(a);
      expect(vault.entry(a)!.history, isEmpty);
      expect(vault.entry(a)!.fpOld, isEmpty);
      expect(vault.entry(b)!.history, hasLength(1));
      expect(vault.historyCount, 1);
      await vault.purgeHistory();
      expect(vault.historyCount, 0);
      final current = await store.readVault();
      expect(_json(current!).containsKey('history'), isFalse);
      expect(await store.readPrevious(), current);
    });

    test('важная запись: показ и удаление — после мастер-пароля', () async {
      await enable();
      final id = await vault.addEntry(
        service: 'Банк',
        password: secret(_old(0)),
        important: true,
      );
      expect(await vault.verifyMaster(secret(Canary.master)), isTrue);
      await vault.updatePassword(id, secret(_old(1)));
      final hid = vault.entry(id)!.history.single.id;
      clock.advance(Vault.confirmWindow + const Duration(seconds: 1));
      expect(vault.isGuarded(vault.entry(id)!), isTrue);
      await expectLater(vault.readHistoryPassword(id, hid), throwsStateError);
      await expectLater(vault.deleteHistoryItem(id, hid), throwsStateError);
      await expectLater(vault.clearHistory(id), throwsStateError);
      expect(vault.entry(id)!.history, hasLength(1));
      expect(await vault.verifyMaster(secret(Canary.master)), isTrue);
      expect(await historyText(id, hid), _old(0));
      await vault.deleteHistoryItem(id, hid);
      expect(vault.entry(id)!.history, isEmpty);
    });
  });

  group('пересборка и целостность', () {
    test('смена мастер-пароля и «перешифровать всё» — хронология читается',
        () async {
      await enable();
      final id = await changed(2);
      const next = 'CANARY-master-next-77';
      await vault.changeMaster(
        current: secret(Canary.master),
        next: secret(next),
        params: fastKdf,
      );
      await vault.reencryptAll(secret(next));
      vault.lock();
      final again = testVault(store, crypto, clock: clock, policy: _long);
      await again.unlock(secret(next));
      final history = again.entry(id)!.history;
      final read = <String>[];
      for (final h in history) {
        final value = await again.readHistoryPassword(id, h.id);
        read.add(utf8.decode(value.unsafeBytes));
        value.wipe();
      }
      expect(read, <String>[_old(1), _old(0)]);
    });

    test('коробка пересажена к другой записи — corrupt', () async {
      await enable();
      final a = await changed(1);
      final b = await vault.addEntry(
        service: 'Форум',
        password: secret('CANARY-forum-1'),
      );
      await vault.updatePassword(b, secret('CANARY-forum-2'));
      final ha = vault.entry(a)!.history.single.id;
      final hb = vault.entry(b)!.history.single.id;
      vault.lock();
      final json = await file();
      final history = json['history']! as Map<String, Object?>;
      final boxA = history[ha];
      history[ha] = history[hb];
      history[hb] = boxA;
      store.files[FileVaultStore.vaultName] = _bytes(json);
      final again = testVault(store, crypto, clock: clock, policy: _long);
      await again.unlock(secret(Canary.master));
      await expectLater(
        again.readHistoryPassword(a, ha),
        throwsA(VaultError.corrupt),
      );
    });

    test('лишняя или пропавшая коробка — corrupt при открытии', () async {
      await enable();
      final id = await changed(2);
      final hid = vault.entry(id)!.history.first.id;
      vault.lock();
      final original = await file();

      final orphan = _json(_bytes(original));
      final history = orphan['history']! as Map<String, Object?>;
      history['f' * 32] = history[hid];
      store.files[FileVaultStore.vaultName] = _bytes(orphan);
      await expectLater(
        testVault(store, crypto, clock: clock, policy: _long)
            .unlock(secret(Canary.master)),
        throwsA(VaultError.corrupt),
      );

      final missing = _json(_bytes(original));
      (missing['history']! as Map<String, Object?>).remove(hid);
      store.files[FileVaultStore.vaultName] = _bytes(missing);
      await expectLater(
        testVault(store, crypto, clock: clock, policy: _long)
            .unlock(secret(Canary.master)),
        throwsA(VaultError.corrupt),
      );

      final dropped = _json(_bytes(original))..remove('history');
      store.files[FileVaultStore.vaultName] = _bytes(dropped);
      await expectLater(
        testVault(store, crypto, clock: clock, policy: _long)
            .unlock(secret(Canary.master)),
        throwsA(VaultError.corrupt),
      );
    });

    test('файл v2 с хронологией в приложении v1 — tooNew, не тронут', () async {
      await enable();
      await changed(1);
      vault.lock();
      final json = (await file())..['v'] = VaultFormat.version + 1;
      final bytes = _bytes(json);
      store.files[FileVaultStore.vaultName] = bytes;
      await expectLater(
        testVault(store, crypto, clock: clock, policy: _long)
            .unlock(secret(Canary.master)),
        throwsA(VaultError.tooNew),
      );
      expect(store.files[FileVaultStore.vaultName], bytes);
    });

    test('канарейки хронологии — только в шифротексте', () async {
      await enable();
      final id = await changed(3);
      for (final h in vault.entry(id)!.history) {
        expect(h.toString(), isNot(contains('CANARY')));
      }
      expect(vault.entry(id).toString(), isNot(contains('CANARY')));
      final files = <Uint8List>[
        (await store.readVault())!,
        (await store.readPrevious())!,
      ];
      for (var n = 0; n < 3; n++) {
        for (final form in Canary.encodings(_old(n))) {
          for (final bytes in files) {
            expect(containsBytes(bytes, form), isFalse);
          }
        }
      }
    });
  });

  group('резервная копия', () {
    Future<Uint8List> exported() =>
        vault.exportBackup(master: secret(Canary.master), params: fastKdf);

    test('туда и обратно: «создать из копии» с хронологией', () async {
      await enable();
      final id = await changed(2);
      final bytes = await exported();
      expect(VaultEnvelope.decode(bytes).history, hasLength(2));
      final other =
          testVault(InMemoryVaultStore(), crypto, clock: clock, policy: _long);
      await other.load();
      final contents = await other.readBackup(bytes, secret(Canary.master));
      expect(contents.hasHistory, isTrue);
      await other.createFromBackup(
        contents,
        secret('CANARY-master-other-1'),
        params: fastKdf,
        keepHistory: true,
      );
      contents.wipe();
      expect(other.historyEnabled, isTrue);
      final history = other.entry(id)!.history;
      expect(history, hasLength(2));
      final read = <String>[];
      for (final h in history) {
        final value = await other.readHistoryPassword(id, h.id);
        read.add(utf8.decode(value.unsafeBytes));
        value.wipe();
      }
      expect(read, <String>[_old(1), _old(0)]);
    });

    test('«создать из копии» без хронологии — прежние пароли отброшены',
        () async {
      await enable();
      final id = await changed(2);
      final bytes = await exported();
      final other =
          testVault(InMemoryVaultStore(), crypto, clock: clock, policy: _long);
      await other.load();
      final contents = await other.readBackup(bytes, secret(Canary.master));
      await other.createFromBackup(
        contents,
        secret('CANARY-master-other-1'),
        params: fastKdf,
      );
      contents.wipe();
      expect(other.historyEnabled, isFalse);
      expect(other.entry(id)!.history, isEmpty);
      expect(other.historyCount, 0);
    });

    test('слияние: в сейф с выключенной опцией хронология не переносится',
        () async {
      await enable();
      await changed(2);
      final bytes = await exported();
      final other =
          testVault(InMemoryVaultStore(), crypto, clock: clock, policy: _long);
      await other.create(secret('CANARY-master-other-1'), params: fastKdf);
      final contents = await other.readBackup(bytes, secret(Canary.master));
      final matches = other.matchImport(contents.items, byId: true);
      await other.importItems(
        <ImportDecision>[
          for (var i = 0; i < contents.items.length; i++)
            ImportDecision(
              contents.items[i],
              matches[i],
              ImportChoice.keepBoth,
            ),
        ],
        fromBackup: true,
      );
      contents.wipe();
      expect(other.entries, hasLength(1));
      expect(other.historyCount, 0);
    });

    test(
        'слияние «из копии» при включённой опции: текущий пароль и '
        'хронология копии без повторов', () async {
      await enable();
      final id = await changed(2); // текущий _old(2); прежние _old(1), _old(0)
      final bytes = await exported();
      // Здесь пароль сменили иначе: _old(1) → _old(9).
      clock.advance(const Duration(days: 1));
      await vault.updatePassword(id, secret(_old(9)));
      final contents = await vault.readBackup(bytes, secret(Canary.master));
      final matches = vault.matchImport(contents.items, byId: true);
      expect(matches.single.status, ImportStatus.conflict);
      await vault.importItems(
        <ImportDecision>[
          ImportDecision(
            contents.items.single,
            matches.single,
            ImportChoice.replace,
          ),
        ],
        fromBackup: true,
      );
      contents.wipe();
      expect(await currentOf(id), _old(2));
      final read = <String>[
        for (final h in vault.entry(id)!.history) await historyText(id, h.id),
      ];
      // _old(9) ушёл в хронологию; _old(2) теперь текущий — не в ней;
      // _old(1) и _old(0) не повторяются.
      expect(read.toSet(), <String>{_old(9), _old(1), _old(0)});
      expect(read, hasLength(3));
      expect(read.first, _old(9));
    });

    test('битый элемент хронологии копии пропущен, запись осталась', () {
      final kFp = base64.encode(List<int>.filled(32, 7));
      final fp = base64.encode(List<int>.filled(32, 1));
      const id = '0123456789abcdef0123456789abcdef';
      final good = <String, Object?>{
        'h': 'a' * 32,
        'from': '2026-01-01T00:00:00.000Z',
        'to': '2026-02-01T00:00:00.000Z',
        'src': 'user',
      };
      final index = <String, Object?>{
        'schema': VaultFormat.indexSchema,
        'rev': 1,
        'k_fp': kFp,
        'entries': <Object?>[
          <String, Object?>{
            'id': id,
            'srev': 1,
            'service': 'Почта',
            'created': '2026-01-01T00:00:00.000Z',
            'changed': '2026-02-01T00:00:00.000Z',
            'fp': fp,
            'hist': <Object?>[
              good,
              <String, Object?>{'h': 'не id', 'from': 'x', 'to': 'y'},
              'мусор',
              good, // повтор id
              <String, Object?>{...good, 'h': 'b' * 32, 'to': 'никогда'},
            ],
          },
        ],
      };
      final padded = VaultPadding.pad(
        Uint8List.fromList(utf8.encode(jsonEncode(index))),
        VaultFormat.indexBlock,
      );
      final (key, infos, skipped, _) = BackupIndexReader.parse(padded, rev: 1);
      key.wipe();
      expect(skipped, 0);
      expect(
        infos.single.history.map((HistoryMeta h) => h.id),
        <String>['a' * 32],
      );
    });

    test('коробка элемента копии не расшифровалась — элемент пропущен',
        () async {
      await enable();
      final id = await changed(2);
      final bytes = await exported();
      final json = _json(bytes);
      final history = json['history']! as Map<String, Object?>;
      final keys = history.keys.toList();
      // Две коробки поменяли местами: AD не сходится, обе пропущены.
      final first = history[keys[0]];
      history[keys[0]] = history[keys[1]];
      history[keys[1]] = first;
      final contents =
          await vault.readBackup(_bytes(json), secret(Canary.master));
      expect(contents.items.single.sourceId, id);
      expect(contents.items.single.history, isEmpty);
      expect(contents.skipped, 0);
      contents.wipe();
    });

    test('копия v2 у старого читателя — tooNew', () async {
      await enable();
      await changed(1);
      final json = _json(await exported())..['v'] = VaultFormat.version + 1;
      await expectLater(
        vault.readBackup(_bytes(json), secret(Canary.master)),
        throwsA(VaultError.tooNew),
      );
    });

    test('в копии канарейки хронологии — только в шифротексте', () async {
      await enable();
      await changed(2);
      final bytes = await exported();
      expect(bytes.length, lessThan(VaultBackup.maxBytes));
      for (var n = 0; n < 2; n++) {
        for (final form in Canary.encodings(_old(n))) {
          expect(containsBytes(bytes, form), isFalse);
        }
      }
      final contents = await vault.readBackup(bytes, secret(Canary.master));
      expect(contents.items.single.toString(), isNot(contains('CANARY')));
      expect(
        contents.items.single.history.first.toString(),
        isNot(contains('CANARY')),
      );
      contents.wipe();
      expect(contents.items.single.history.first.password.isWiped, isTrue);
    });
  });
}
