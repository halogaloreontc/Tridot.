import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../extensions/extension_registry.dart';
import '../services/clock.dart';
import 'import_rules.dart';
import 'keyboard_layouts.dart';
import 'master_variants.dart';
import 'password_audit.dart';
import 'password_strength.dart' show Utf8Runes;
import 'password_training.dart';
import 'secret_bytes.dart';
import 'vault_backup.dart';
import 'vault_crypto.dart';
import 'vault_errors.dart';
import 'vault_format.dart';
import 'vault_prefs.dart';
import 'vault_store.dart';

/// Состояние хранилища (раздел 3.6).
enum VaultState {
  /// Файла нет.
  notCreated,

  /// Файл есть, ключей в памяти нет.
  locked,

  /// Открыто: ключи и индекс в памяти до запирания.
  unlocked,

  /// Навык выключен: данные заперты, открыть нельзя.
  disabled,
}

/// Состояние приложения для запирания (без Flutter: ядро на чистом
/// Dart). `lib/app` переводит в него `AppLifecycleState`.
enum VaultAppState { resumed, inactive, hidden, paused, detached }

/// Что сообщает хранилище слушателям.
enum VaultSignal {
  /// Состояние или записи изменились.
  changed,

  /// Спрятать показанное (окно неактивно), но не запирать.
  hide,

  /// Хранилище заперто: погасить карточки, очистить поля и буфер.
  locked,
}

/// Сроки запирания и обязательного ввода мастер-пароля. Настройки из
/// `prefs` индекса (`autolock_min`, `master_every_h`) важнее.
final class VaultPolicy {
  const VaultPolicy({
    this.idle = const Duration(minutes: 5),
    this.hardLimit = const Duration(minutes: 60),
    this.masterEvery = const Duration(hours: 72),
  });

  /// Простой без действий с хранилищем.
  final Duration idle;

  /// Жёсткий предел открытого состояния.
  final Duration hardLimit;

  /// Мастер-пароль обязателен не реже.
  final Duration masterEvery;

  /// Допустимые значения настроек в `prefs`.
  static const Set<int> autolockMinutes = <int>{1, 5, 15, 30};
  static const Set<int> masterEveryHours = <int>{24, 72, 168};
}

/// Итог открытия.
final class VaultUnlockResult {
  const VaultUnlockResult({
    required this.rev,
    required this.rolledBack,
    this.variantHit = false,
  });

  /// Версия открытого файла (для `passwords.seen_rev`).
  final int rev;

  /// Файл старее, чем был (`rev < seen_rev`): его могли подменить или
  /// восстановить из старой копии. Только предупреждение (раздел 4.1).
  final bool rolledBack;

  /// Подошёл не сам ввод, а его вариант (D25): другая раскладка, Caps
  /// Lock, регистр первой буквы, пробелы по краям.
  final bool variantHit;
}

/// Хранилище паролей: конверт с ключом, индекс и секреты записей
/// (ADR-014). Создаётся в `main.dart`; навыку отдаётся только
/// `VaultFacade`, без методов, возвращающих пароль.
///
/// Мастер-пароль приходит как [SecretBytes]; хранилище его не затирает —
/// это делает вызывающий сразу после вызова.
final class Vault {
  Vault({
    required this.store,
    required this.crypto,
    this.clock = const SystemClock(),
    MonotonicClock? monotonic,
    this.policy = const VaultPolicy(),
    this.allowTestingKdf = false,
    this.device = VaultDevice.desktop,
    this.totalMemory,
  }) : monotonic = monotonic ??
            (clock is MonotonicClock
                ? clock as MonotonicClock
                : StopwatchClock());

  final VaultStore store;
  final VaultCrypto crypto;

  /// Стенные часы: даты в файле, «последняя копия», пауза после ошибок.
  final Clock clock;

  /// Монотонное время открытого хранилища: окно подтверждения, предел
  /// догадок, «Проверить себя» и автозапирание не продлеваются и не
  /// сбрасываются переводом системных часов. Часы-подделка тестов,
  /// умеющая и то и другое, служит обоими.
  final MonotonicClock monotonic;
  final VaultPolicy policy;

  /// Разрешены ли [VaultKdfParams.forTesting] (только тесты).
  final bool allowTestingKdf;

  /// Для калибровки и потолка параметров копии.
  final VaultDevice device;
  final int? totalMemory;

  /// Оценка надёжности и флаги записей (5.5). Ставит `lib/app`, когда
  /// загрузились словари; без неё оценка и флаги не пересчитываются.
  PasswordAssessor? assessor;

  bool _loaded = false;
  bool _exists = false;
  bool _disabled = false;
  _Open? _open;
  Timer? _timer;

  /// Растёт при каждом запирании: операция, ждавшая KDF или диск, видит,
  /// что её «заперли» посреди, и не оставляет ключи в памяти.
  int _epoch = 0;

  /// Хвост очереди операций: ввод мастер-пароля и записи идут по одной
  /// (иначе параллельные попытки обходят счётчик D25, а параллельные
  /// записи затирают друг друга).
  Future<void> _tail = Future<void>.value();
  final List<void Function(VaultSignal)> _listeners =
      <void Function(VaultSignal)>[];

  VaultState get state {
    if (_disabled) return VaultState.disabled;
    if (_open != null) return VaultState.unlocked;
    return _exists ? VaultState.locked : VaultState.notCreated;
  }

  bool get isUnlocked => _open != null;

  void addListener(void Function(VaultSignal) listener) =>
      _listeners.add(listener);

  void removeListener(void Function(VaultSignal) listener) =>
      _listeners.remove(listener);

  void _notify(VaultSignal signal) {
    for (final listener in List<void Function(VaultSignal)>.of(_listeners)) {
      listener(signal);
    }
  }

  /// Читает, есть ли файл, и убирает остатки `.tmp`.
  Future<void> load() => _serial(_load);

  Future<void> _load() => _guard(() async {
        await store.removeTemporary();
        _exists = await store.hasVault();
        _loaded = true;
        _notify(VaultSignal.changed);
      });

  Future<void> _ensureLoaded() async {
    if (!_loaded) await _load();
  }

  // --------------------------------------------------------- создание

  /// Новое хранилище с мастер-паролем [master]. Без [params] — калибровка
  /// (0,7–1,0 с, раздел 3.2). После создания хранилище открыто.
  Future<void> create(SecretBytes master, {VaultKdfParams? params}) {
    // Эпоха — в момент вызова, а не когда очередь дойдёт: запирание
    // (фон, выключение) после вызова всегда побеждает.
    final epoch = _epoch;
    return _op(() async {
      await _ensureLoaded();
      _requireEnabled();
      _stillWanted(epoch);
      if (_exists || await store.hasVault()) {
        _exists = true;
        throw StateError('хранилище уже есть');
      }
      final kdf = params ?? await _calibrate();
      _checkParams(kdf);
      await _install(await _build(master, kdf), epoch: epoch);
    });
  }

  /// «Создать хранилище из копии» (5.7): новый `vault_id`, `k_fp` — из
  /// копии (поэтому «повтор» и «это прежний пароль» работают и на новом
  /// устройстве). Хранилища на устройстве быть не должно. [contents]
  /// затирает вызывающий.
  Future<void> createFromBackup(
    BackupContents contents,
    SecretBytes master, {
    VaultKdfParams? params,
  }) {
    final epoch = _epoch;
    return _op(() async {
      await _ensureLoaded();
      _requireEnabled();
      _stillWanted(epoch);
      if (_exists || await store.hasVault()) {
        _exists = true;
        throw StateError('хранилище уже есть');
      }
      final kdf = params ?? await _calibrate();
      _checkParams(kdf);
      await _install(
        await _build(master, kdf, kFp: contents.kFp, items: contents.items),
        epoch: epoch,
      );
    });
  }

  /// «Заменить всё» из копии (5.7): только с верным мастер-паролем
  /// [master]; текущее хранилище не стирается, а уходит в
  /// `archive/replaced-<дата>.relayvault`. Новое — с тем же мастер-паролем
  /// и параметрами Argon2id, `k_fp` из копии. Возвращает имя в архиве.
  Future<String> replaceWithBackup(
    BackupContents contents,
    SecretBytes master,
  ) =>
      _op(() async {
        final open = _requireOpen();
        final vk = await _unwrap(
          master,
          open.envelope,
          VaultKeys.header(open.envelope),
        );
        vk.dispose();
        _alive(open);
        final kdf = VaultKdfParams.checkLoaded(
          open.envelope.kdf,
          allowTesting: allowTestingKdf,
        );
        final built =
            await _build(master, kdf, kFp: contents.kFp, items: contents.items);
        final String name;
        try {
          _alive(open);
          name = await _archiveName('replaced');
          await store.archiveVault(name);
        } catch (_) {
          built.dispose();
          rethrow;
        }
        // Текущее отложено: ключи прежнего хранилища больше не нужны.
        _open = null;
        open.dispose();
        _notify(VaultSignal.hide);
        _notify(VaultSignal.locked);
        try {
          await _install(built, epoch: _epoch, replacePrevious: true);
          final installed = _open;
          if (installed != null) _confirmed(installed);
        } catch (_) {
          // Прежнее уже в архиве: его можно открыть из «Старых хранилищ».
          _exists = await store.hasVault();
          _notify(VaultSignal.changed);
          rethrow;
        }
        return name;
      });

  /// Новое хранилище в памяти: ключи, индекс (с записями [items]) и
  /// конверт. Ещё не записано.
  Future<_Built> _build(
    SecretBytes master,
    VaultKdfParams kdf, {
    SecretBytes? kFp,
    List<ImportItem> items = const <ImportItem>[],
  }) async {
    final now = clock.now();
    final salt = crypto.bytes(VaultFormat.saltBytes);
    final vaultId = base64.encode(crypto.bytes(VaultFormat.idBytes));
    final ring = VaultKeyRing.from(crypto, crypto.randomKey());
    final kFpBytes = kFp == null
        ? SecretBytes.adopt(crypto.bytes(VaultFormat.keyBytes))
        : kFp.clone();
    final kFpKey = crypto.importKey(kFpBytes.clone());
    try {
      final kek = await crypto.derive(master, salt, kdf);
      final record = KdfRecord(ops: kdf.ops, mem: kdf.mem, salt: salt);
      final header = _headerFor(VaultFormat.kindVault, vaultId, record);
      final SealedBox wrap;
      try {
        wrap = crypto.sealKey(kek, ring.vk, VaultKeys.wrapPwAd(header));
      } finally {
        kek.dispose();
      }
      final base = VaultEnvelope(
        kind: VaultFormat.kindVault,
        vaultId: vaultId,
        kdf: record,
        wrapPw: wrap,
        rev: 1,
        index: wrap,
        secrets: const <String, SealedSecret>{},
      );
      final entries = <VaultEntry>[];
      final secrets = <String, SealedSecret>{};
      final ids = <String>{};
      for (final item in items) {
        _checkInfo(
          service: item.service,
          login: item.login,
          hint: item.hint,
          urls: item.urls,
        );
        _checkSecret(item.password, item.note);
        var id = item.sourceId;
        while (id == null || !VaultIds.isEntryId(id) || ids.contains(id)) {
          id = VaultIds.hex(crypto.bytes(VaultFormat.idBytes));
        }
        ids.add(id);
        final fp = VaultKeys.fingerprint(crypto, kFpKey, item.password);
        final src = item.srcFp;
        // Отпечаток из копии сошёлся с пересчитанным — прежние отпечатки
        // верны (тот же `k_fp`); иначе пересчёт и `fp_old = []`.
        final trusted = src != null &&
            src.length == fp.length &&
            crypto.equal(Uint8List.fromList(src), fp);
        final entry = _assessed(
          VaultEntry(
            id: id,
            srev: 1,
            service: item.service,
            urls: List<String>.unmodifiable(item.urls),
            aliases: List<String>.unmodifiable(item.aliases),
            login: item.login,
            hint: item.hint,
            created: item.created ?? item.changed ?? now,
            changed: item.changed ?? now,
            dateSource:
                item.changed == null ? DateSource.unknown : DateSource.import,
            fp: fp,
            fpLoose: VaultKeys.looseFingerprint(crypto, kFpKey, item.password),
            fpOld: trusted
                ? <Uint8List>[
                    for (final old in item.srcFpOld.take(
                      VaultEntry.maxOldFingerprints,
                    ))
                      Uint8List.fromList(old),
                  ]
                : const <Uint8List>[],
          ),
          item.password,
        );
        entries.add(entry);
        secrets[id] = _sealSecret(ring, base, entry, item.password, item.note);
      }
      final index = VaultIndex(
        rev: 1,
        kFp: kFpBytes,
        entries: List<VaultEntry>.unmodifiable(entries),
        master: <String, Object?>{'last_typed': _iso(now)},
      );
      final envelope = _sealEnvelope(
        ring: ring,
        vaultId: vaultId,
        kdf: record,
        wrapPw: wrap,
        index: index,
        secrets: secrets,
      );
      final bytes = envelope.encode();
      try {
        VaultEnvelope.decode(bytes);
      } on Object {
        throw ArgumentError('запись не помещается в формат хранилища');
      }
      return _Built(envelope, index, ring, kFpKey, bytes, now);
    } catch (_) {
      ring.dispose();
      kFpKey.dispose();
      kFpBytes.wipe();
      rethrow;
    }
  }

  /// Записать собранное хранилище и открыть его.
  Future<void> _install(
    _Built built, {
    required int epoch,
    bool replacePrevious = false,
  }) async {
    try {
      _stillWanted(epoch);
      await store.writeVault(built.bytes, replacePrevious: replacePrevious);
      _exists = true;
      // Заперли или выключили, пока шла запись: файл есть, ключей нет.
      _stillWanted(epoch);
      _open = _Open(
        envelope: built.envelope,
        index: built.index,
        ring: built.ring,
        kFp: built.kFp,
        unlockedAt: _moment(),
      );
    } catch (_) {
      built.dispose();
      rethrow;
    }
    _schedule();
    _notify(VaultSignal.changed);
  }

  /// Свободное имя `<prefix>-<дата>.relayvault` в архиве.
  Future<String> _archiveName(String prefix) async {
    final day = clock.now().toUtc().toIso8601String().substring(0, 10);
    final taken = (await store.archived()).toSet();
    var name = '$prefix-$day.relayvault';
    for (var n = 2; taken.contains(name); n++) {
      name = '$prefix-$day-$n.relayvault';
    }
    return name;
  }

  Future<VaultKdfParams> _calibrate() => VaultKdfParams.calibrate(
        measure: crypto.measure,
        device: device,
        totalMemory: totalMemory,
      );

  void _checkParams(VaultKdfParams params) {
    if (params.isTesting) {
      if (!allowTestingKdf) throw ArgumentError('тестовые параметры KDF');
      return;
    }
    VaultKdfParams.checkLoaded(
      KdfRecord(ops: params.ops, mem: params.mem, salt: Uint8List(0)),
    );
  }

  // --------------------------------------------------------- открытие

  /// Открывает хранилище мастер-паролем. Ошибки: [VaultRateLimited]
  /// (пауза, D25), `wrongPassword`, `corrupt`, `kdfInvalid`, `tooNew`,
  /// `io`, `locked` (навык выключен). [seenRev] — `passwords.seen_rev`
  /// из настроек: по нему видно откат файла. При неверном вводе сразу
  /// пробуются его варианты ([MasterVariants], D25) — это одна попытка
  /// счётчика.
  Future<VaultUnlockResult> unlock(SecretBytes master, {int? seenRev}) {
    // Эпоха — в момент вызова, а не когда очередь дойдёт: запирание,
    // пришедшее, пока ввод ждал в очереди (двойное нажатие + фон), не
    // теряется — ввод отклоняется как `locked`, без попытки в счётчике.
    final epoch = _epoch;
    return _op(() async {
      await _ensureLoaded();
      _requireEnabled();
      _stillWanted(epoch);
      final current = _open;
      if (current != null) {
        // Уже открыто: ввод всё равно проверяется (и идёт в счётчик).
        if (!await _verifyMaster(master)) throw VaultError.wrongPassword;
        return VaultUnlockResult(
          rev: current.envelope.rev,
          rolledBack: false,
        );
      }
      final bytes = await store.readVault();
      if (bytes == null) {
        _exists = false;
        throw VaultError.io;
      }
      final envelope = VaultEnvelope.decode(bytes);
      if (envelope.kind != VaultFormat.kindVault) throw VaultError.corrupt;
      final header = VaultKeys.header(envelope);
      // Мигрированный файл пишется текущей версией: обёртку ключа нужно
      // запечатать заново с новым header (в нём версия формата).
      SealedBox? rewrapped;
      final variants = MasterVariants.of(master);
      final VaultKey vk;
      final bool variantHit;
      try {
        (vk, variantHit) = await _unwrapAny(
          master,
          envelope,
          header,
          variants: variants,
          withKek: envelope.migrated
              ? (VaultKey kek, VaultKey vk) => rewrapped = crypto.sealKey(
                    kek,
                    vk,
                    VaultKeys.wrapPwAd(
                      _headerFor(envelope.kind, envelope.vaultId, envelope.kdf),
                    ),
                  )
              : null,
        );
      } finally {
        for (final variant in variants) {
          variant.wipe();
        }
      }
      final ring = VaultKeyRing.from(crypto, vk);
      VaultIndex? index;
      VaultKey? kFp;
      _Open? opened;
      try {
        // Пока шёл Argon2id, хранилище заперли (фон, выключение навыка):
        // ключи не остаются в памяти.
        _stillWanted(epoch);
        final body = crypto.open(
          ring.index,
          envelope.index,
          VaultKeys.indexAd(header, envelope.rev),
        );
        if (body == null) throw VaultError.corrupt;
        index = VaultIndex.decodePadded(body);
        VaultKeys.checkConsistency(envelope, index);
        kFp = crypto.importKey(index.kFp.clone());
        final open = opened = _Open(
          envelope: envelope,
          index: index,
          ring: ring,
          kFp: kFp,
          unlockedAt: _moment(),
        );
        _open = open;
        _confirmed(open);
        // Мастер-пароль введён: метка внутри индекса; заодно запись
        // мигрированной версии.
        try {
          await _afterUnlock(open, original: bytes, wrapPw: rewrapped);
        } on VaultFailure catch (error) {
          // Только для чтения (диск полон, нет прав): открыть всё равно
          // можно, метка запишется в следующий раз. Но не мигрированный
          // файл: в памяти — обёртка и секреты со старыми AD, и любая
          // следующая запись дала бы файл, который не открыть.
          if (error.code != VaultErrorCode.io ||
              envelope.migrated ||
              index.migrated) {
            rethrow;
          }
        }
        if (!identical(_open, open)) throw VaultError.locked;
        _stillWanted(epoch);
      } catch (_) {
        if (opened != null && identical(_open, opened)) _open = null;
        ring.dispose();
        kFp?.dispose();
        index?.kFp.wipe();
        rethrow;
      }
      _exists = true;
      _schedule();
      _notify(VaultSignal.changed);
      return VaultUnlockResult(
        rev: _open!.envelope.rev,
        rolledBack: seenRev != null && envelope.rev < seenRev,
        variantHit: variantHit,
      );
    });
  }

  Future<void> _afterUnlock(
    _Open open, {
    required Uint8List original,
    SealedBox? wrapPw,
  }) async {
    final envelope = open.envelope;
    final migrated = envelope.migrated || open.index.migrated;
    if (migrated) {
      await store.writeBackup(envelope.sourceVersion, original);
    }
    final secrets = migrated
        ? <String, SealedSecret>{
            for (final entry in open.index.entries)
              entry.id: _reseal(open, open.ring, entry),
          }
        : envelope.secrets;
    final written = await _commit(
      open,
      entries: open.index.entries,
      secrets: secrets,
      master: <String, Object?>{
        ...open.index.master,
        'last_typed': _iso(clock.now()),
      },
      wrapPw: wrapPw,
    );
    if (migrated && _verifies(open.ring, written)) {
      await store.deleteBackup(envelope.sourceVersion);
    }
  }

  /// Записанный файл открывается текущими ключами.
  bool _verifies(VaultKeyRing ring, Uint8List written) {
    try {
      final check = VaultEnvelope.decode(written);
      final header = VaultKeys.header(check);
      final body = crypto.open(
        ring.index,
        check.index,
        VaultKeys.indexAd(header, check.rev),
      );
      if (body == null) return false;
      VaultIndex.decodePadded(body).kFp.wipe();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Проверка мастер-пароля через общий счётчик ошибок (открытие,
  /// тренировка, обязательный ввод, смена мастер-пароля).
  ///
  /// [withKek] получает KEK и VK до освобождения KEK (переобёртка ключа
  /// при миграции: AD обёртки содержит версию формата).
  Future<VaultKey> _unwrap(
    SecretBytes master,
    VaultEnvelope envelope,
    Uint8List header,
  ) async =>
      (await _unwrapAny(master, envelope, header)).$1;

  /// Как [_unwrap], но после неверного [master] пробует [variants] в той же
  /// попытке счётчика. Второе в ответе — подошёл вариант.
  Future<(VaultKey, bool)> _unwrapAny(
    SecretBytes master,
    VaultEnvelope envelope,
    Uint8List header, {
    List<SecretBytes> variants = const <SecretBytes>[],
    void Function(VaultKey kek, VaultKey vk)? withKek,
  }) async {
    final params = VaultKdfParams.checkLoaded(
      envelope.kdf,
      allowTesting: allowTestingKdf,
    );
    final now = clock.now();
    final stored = VaultAttempts.decode(await store.readAttempts());
    final attempts = stored.at(now);
    if (!identical(attempts, stored)) {
      await store.writeAttempts(attempts.encode());
    }
    final until = attempts.blockedUntil(now);
    if (until != null) throw VaultRateLimited(until);
    // Попытка засчитывается до вывода ключа: убитое посреди Argon2id
    // приложение не получает бесплатную попытку. Записать не вышло —
    // не проверяем вовсе (без счётчика перебор был бы без пауз).
    await store.writeAttempts(attempts.failed(now).encode());
    final candidates = <SecretBytes>[master, ...variants];
    for (var i = 0; i < candidates.length; i++) {
      final kek = await crypto.derive(candidates[i], envelope.kdf.salt, params);
      final VaultKey? vk;
      try {
        vk = crypto.openKey(kek, envelope.wrapPw, VaultKeys.wrapPwAd(header));
        if (vk != null) withKek?.call(kek, vk);
      } finally {
        kek.dispose();
      }
      if (vk == null) continue;
      try {
        await store.writeAttempts(const VaultAttempts().encode());
      } on Object {
        // Не сбросился счётчик — лишняя ошибка в нём, не дыра.
      }
      return (vk, i > 0);
    }
    // Та же попытка, время — конец проверки (пауза от него).
    await store.writeAttempts(attempts.failed(clock.now()).encode());
    throw VaultError.wrongPassword;
  }

  /// Верен ли мастер-пароль открытого хранилища (тренировка, обязательный
  /// ввод). Тот же счётчик ошибок и паузы, что у открытия. Верный ввод
  /// обновляет метку `last_typed`.
  Future<bool> verifyMaster(SecretBytes master) =>
      _op(() => _verifyMaster(master));

  Future<bool> _verifyMaster(SecretBytes master) => _guard(() async {
        final open = _requireOpen();
        try {
          final vk = await _unwrap(
            master,
            open.envelope,
            VaultKeys.header(open.envelope),
          );
          vk.dispose();
        } on VaultFailure catch (error) {
          if (error.code == VaultErrorCode.wrongPassword) return false;
          rethrow;
        }
        _alive(open);
        _confirmed(open);
        await _commit(
          open,
          entries: open.index.entries,
          secrets: open.envelope.secrets,
          master: <String, Object?>{
            ...open.index.master,
            'last_typed': _iso(clock.now()),
          },
        );
        touch();
        return true;
      });

  /// «Начать заново» (5.11): мастер-пароль не нужен — кто держит
  /// устройство, и так может удалить файл. Хранилище запирается, а файл
  /// уходит в `archive/forgotten-<дата>.relayvault` — не стирается. После
  /// этого можно создать новое. Возвращает имя файла в архиве.
  Future<String?> startOver() {
    lock();
    return _serial(
      () => _guard(() async {
        await _ensureLoaded();
        if (!await store.hasVault()) {
          _exists = false;
          return null;
        }
        final name = await _archiveName('forgotten');
        await store.archiveVault(name);
        _exists = false;
        _notify(VaultSignal.changed);
        return name;
      }),
    );
  }

  // --------------------------------------------------------- запирание

  /// Запирает: ключи освобождаются, индекс отбрасывается, `k_fp`
  /// затирается. Слушатели получают [VaultSignal.locked].
  void lock() {
    _epoch++;
    _timer?.cancel();
    _timer = null;
    final open = _open;
    if (open == null) return;
    _open = null;
    open.dispose();
    _notify(VaultSignal.locked);
    _notify(VaultSignal.changed);
  }

  /// Навык включили или выключили. Выключение запирает; файл не трогаем.
  void setEnabled(bool enabled) {
    if (!enabled) {
      lock();
      if (_disabled) return;
      _disabled = true;
    } else {
      if (!_disabled) return;
      _disabled = false;
    }
    _notify(VaultSignal.changed);
  }

  /// Следить за навыком [id] в реестре расширений: выключили — запереть
  /// (D18). Возвращает функцию отписки.
  void Function() followExtension(ExtensionRegistry registry, String id) {
    void listener() => setEnabled(registry.isEnabled(id));
    registry.addListener(listener);
    listener();
    return () => registry.removeListener(listener);
  }

  /// Смена состояния приложения: `paused`, `hidden`, `detached` —
  /// запереть; `inactive` (на десктопе окно потеряло фокус) — только
  /// спрятать показанное.
  void onAppState(VaultAppState appState) {
    switch (appState) {
      case VaultAppState.paused ||
            VaultAppState.hidden ||
            VaultAppState.detached:
        lock();
      case VaultAppState.inactive:
        if (_open != null) _notify(VaultSignal.hide);
      case VaultAppState.resumed:
        checkTimeouts();
    }
  }

  /// Действие с хранилищем продлевает простой.
  void touch() {
    final open = _open;
    if (open == null) return;
    open.lastActivity = _moment();
    _schedule();
  }

  /// Простой, если в `prefs` нет своего.
  Duration get idleTimeout {
    final minutes = _open?.index.prefs['autolock_min'];
    if (minutes is int && VaultPolicy.autolockMinutes.contains(minutes)) {
      return Duration(minutes: minutes);
    }
    return policy.idle;
  }

  /// Когда хранилище запрётся само (простой или жёсткий предел), по
  /// стенным часам — для показа. Сам срок считается по [_lockIn].
  DateTime? get lockAt {
    final left = _lockIn();
    return left == null ? null : clock.now().add(left);
  }

  /// Сколько осталось до автозапирания. Прошедшее время — большее из
  /// монотонного и стенного ([_since]): перевод часов назад срок не
  /// продлевает, а сон устройства (монотонные часы его не считают на
  /// части систем) — учитывается.
  Duration? _lockIn() {
    final open = _open;
    if (open == null) return null;
    final idle = idleTimeout - _since(open.lastActivity);
    final hard = policy.hardLimit - _since(open.unlockedAt);
    return idle < hard ? idle : hard;
  }

  /// Запереть, если срок вышел (таймер мог опоздать: сон устройства).
  void checkTimeouts() {
    final left = _lockIn();
    if (left == null) return;
    if (left <= Duration.zero) {
      lock();
    } else {
      _schedule();
    }
  }

  void _schedule() {
    _timer?.cancel();
    final wait = _lockIn();
    if (wait == null) return;
    if (wait <= Duration.zero) {
      lock();
      return;
    }
    _timer = Timer(wait, checkTimeouts);
  }

  /// Отметка «сейчас»: стенные и монотонные часы вместе.
  _Moment _moment() => _Moment(clock.now(), monotonic.elapsed);

  /// Сколько прошло с [at] — большее из монотонного и стенного (стенное
  /// назад — ноль). Для сроков, где «прошло больше» — строже.
  Duration _since(_Moment at) {
    final mono = monotonic.elapsed - at.mono;
    final wall = clock.now().difference(at.wall);
    return wall > mono ? wall : mono;
  }

  /// Когда последний раз вводили мастер-пароль (только открытое).
  DateTime? get masterTypedAt {
    final value = _open?.index.master['last_typed'];
    return value is String ? DateTime.tryParse(value) : null;
  }

  /// Пора ввести мастер-пароль (раз в 72 ч по умолчанию).
  bool get masterDue {
    final typed = masterTypedAt;
    if (typed == null) return _open != null;
    final hours = _open?.index.prefs['master_every_h'];
    final every = hours is int && VaultPolicy.masterEveryHours.contains(hours)
        ? Duration(hours: hours)
        : policy.masterEvery;
    return !clock.now().isBefore(typed.add(every));
  }

  // --------------------------------------------------------- записи

  /// Записи индекса (без паролей и заметок). Пусто, пока заперто.
  List<VaultEntry> get entries => _open?.index.entries ?? const <VaultEntry>[];

  /// Защитные настройки из индекса.
  Map<String, Object?> get prefs =>
      _open?.index.prefs ?? const <String, Object?>{};

  /// Версия открытого файла.
  int? get rev => _open?.envelope.rev;

  VaultEntry? entry(String id) =>
      entries.where((VaultEntry e) => e.id == id).firstOrNull;

  /// Новая запись. Возвращает её id.
  Future<String> addEntry({
    required String service,
    required SecretBytes password,
    SecretBytes? note,
    String login = '',
    String hint = '',
    List<String> urls = const <String>[],
    List<String> aliases = const <String>[],
    bool important = false,
  }) =>
      _op(() async {
        final open = _requireOpen();
        _checkInfo(service: service, login: login, hint: hint, urls: urls);
        _checkSecret(password, note);
        final now = clock.now();
        final id = VaultIds.hex(crypto.bytes(VaultFormat.idBytes));
        final entry = VaultEntry(
          id: id,
          srev: 1,
          service: service,
          urls: List<String>.unmodifiable(urls),
          aliases: List<String>.unmodifiable(aliases),
          login: login,
          hint: hint,
          important: important,
          created: now,
          changed: now,
          fp: VaultKeys.fingerprint(crypto, open.kFp, password),
          fpLoose: VaultKeys.looseFingerprint(crypto, open.kFp, password),
          train: important
              ? TrainingSchedule.start(now)
              : const <String, Object?>{},
        );
        final assessed = _assessed(entry, password);
        final noteBytes = note ?? SecretBytes.empty();
        final sealed = _sealSecret(
          open.ring,
          open.envelope,
          assessed,
          password,
          noteBytes,
        );
        await _commit(
          open,
          entries: <VaultEntry>[...open.index.entries, assessed],
          secrets: <String, SealedSecret>{...open.envelope.secrets, id: sealed},
        );
        touch();
        _notify(VaultSignal.changed);
        return id;
      });

  /// Новый пароль записи: прежний отпечаток уходит в `fp_old` (до 5),
  /// `srev` растёт, `changed = now`. Заметка сохраняется.
  ///
  /// Охраняемую важную запись ([isGuarded]) без свежего мастер-пароля не
  /// меняют (`StateError`): редактор сначала переспрашивает (15.2).
  Future<void> updatePassword(String id, SecretBytes password) =>
      updateEntry(id, password: password);

  /// Новая заметка записи (пароль прежний). Прежняя заметка не живёт и в
  /// `.prev`.
  /// Охраняемую важную запись — только после мастер-пароля, как и пароль.
  Future<void> updateNote(String id, SecretBytes note) =>
      updateEntry(id, note: note);

  /// Правка полей записи без пароля.
  ///
  /// Снять с записи «Важный» при включённом «Переспрашивать для важных» —
  /// ослабление защиты (3.6, 15.2): только с верным [master], как и
  /// выключение самой настройки.
  Future<void> updateInfo(
    String id, {
    String? service,
    String? login,
    String? hint,
    List<String>? urls,
    bool? important,
    SecretBytes? master,
  }) =>
      updateEntry(
        id,
        service: service,
        login: login,
        hint: hint,
        urls: urls,
        important: important,
        master: master,
      );

  /// Правка записи одной операцией (редактор): поля, новый пароль
  /// [password] и новая заметка [note] проверяются один раз и ложатся
  /// одной записью файла — либо всё, либо ничего. Окно подтверждения
  /// ([confirmWindow]) не может истечь между частями сохранения.
  ///
  /// Новый пароль: прежний отпечаток уходит в `fp_old` (до 5), `srev`
  /// растёт, `changed = now`. Прежние пароль и заметка не живут и в
  /// `.prev`.
  ///
  /// Снять «Важный» при включённом «Переспрашивать для важных» —
  /// ослабление защиты (3.6, 15.2): только с верным [master]. Любая
  /// другая правка охраняемой важной записи ([isGuarded]) без свежего
  /// мастер-пароля — `StateError`, и ничего не меняется.
  Future<void> updateEntry(
    String id, {
    String? service,
    String? login,
    String? hint,
    List<String>? urls,
    bool? important,
    SecretBytes? password,
    SecretBytes? note,
    SecretBytes? master,
  }) =>
      _op(() async {
        final open = _requireOpen();
        final entry = _entry(open, id);
        if (password != null) _checkSecret(password, null);
        if (note != null && note.length > VaultFormat.maxNote) {
          throw ArgumentError('секрет вне пределов');
        }
        if (important == false &&
            entry.important &&
            VaultPrefs.repromptImportant.of(open.index.prefs)) {
          if (master == null) throw ArgumentError('нужен мастер-пароль');
          final vk = await _unwrap(
            master,
            open.envelope,
            VaultKeys.header(open.envelope),
          );
          vk.dispose();
          _alive(open);
          _confirmed(open);
        }
        // Любая правка охраняемой важной записи (15.2) — только после
        // мастер-пароля: новая подсказка сверяется с её паролем (4-граммы),
        // а новое название, логин или адрес — с куском пароля (флаг «в
        // пароле название или логин», оценка). Без предела это оракул
        // «есть ли в пароле эта подстрока». Редактор сначала
        // переспрашивает ([isGuarded]). Проверка — одна на всю правку и
        // до любых изменений.
        final touched = (service != null && service != entry.service) ||
            (login != null && login != entry.login) ||
            (hint != null && hint != entry.hint) ||
            (urls != null && !_sameList(urls, entry.urls)) ||
            (important != null && important != entry.important);
        final guarded = isGuarded(entry);
        if ((touched || password != null || note != null) && guarded) {
          throw StateError('важная запись — после мастер-пароля');
        }
        final now = clock.now();
        var updated = entry.copyWith(
          service: service,
          login: login,
          hint: hint,
          urls: urls == null ? null : List<String>.unmodifiable(urls),
          important: important,
          train:
              important == true && TrainingSchedule.nextOf(entry.train) == null
                  ? TrainingSchedule.start(now)
                  : null,
        );
        _checkInfo(
          service: updated.service,
          login: updated.login,
          hint: updated.hint,
          urls: updated.urls,
        );
        final secretChanged = password != null || note != null;
        final infoAssess = updated.hint != entry.hint ||
            updated.login != entry.login ||
            updated.service != entry.service;
        // Прежний секрет нужен, чтобы запечатать новую часть рядом со
        // старой, и для пересчёта флагов по сохранённому паролю.
        final current = secretChanged || (assessor != null && infoAssess)
            ? _openSecret(open, open.ring, entry)
            : null;
        try {
          if (password != null) {
            final fp = VaultKeys.fingerprint(crypto, open.kFp, password);
            // Вернулись к прежнему паролю (5.5, флаг `returnedOld`).
            var returned = false;
            for (final old in entry.fpOld) {
              if (crypto.equal(old, fp)) returned = true;
            }
            final same = crypto.equal(entry.fp, fp);
            updated = _assessed(
              updated.copyWith(
                changed: now,
                dateSource: DateSource.user,
                fp: fp,
                fpLoose: VaultKeys.looseFingerprint(crypto, open.kFp, password),
                fpOld: same
                    ? entry.fpOld
                    : <Uint8List>[entry.fp, ...entry.fpOld]
                        .take(VaultEntry.maxOldFingerprints)
                        .toList(),
                flags: <String>[
                  for (final f in entry.flags)
                    if (f != EntryFlags.returnedOld) f,
                  if (returned) EntryFlags.returnedOld,
                ],
              ),
              password,
            );
          } else if (current != null && infoAssess) {
            // Подсказку, название или логин сменили — флаги («подсказка
            // раскрывает пароль», «пароль содержит логин») пересчитать.
            updated = _assessed(updated, current.password);
          }
          if (secretChanged) {
            updated = updated.copyWith(srev: entry.srev + 1);
          }
          final secrets = secretChanged
              ? <String, SealedSecret>{
                  ...open.envelope.secrets,
                  id: _sealSecret(
                    open.ring,
                    open.envelope,
                    updated,
                    password ?? current!.password,
                    note ?? current!.note,
                  ),
                }
              : open.envelope.secrets;
          // Прежние пароль и заметка не живут и в .prev (D7).
          await _commit(
            open,
            entries: _replace(open.index.entries, updated),
            secrets: secrets,
            replacePrevious: secretChanged,
          );
        } finally {
          current?.wipe();
        }
        touch();
        _notify(VaultSignal.changed);
      });

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Запись [entry] с оценкой и флагами по паролю [password] (если есть
  /// [assessor]). Флаги, которые ставит само хранилище, сохраняются.
  ///
  /// Охраняемая важная запись ([isGuarded]) не пересчитывается по
  /// сохранённому паролю — её оценка и флаги заморожены до мастер-пароля
  /// (вторая линия защиты от оракула по подстрокам, 15.2). Вызывающие с
  /// новым паролем охраняемую запись сюда не приводят ([updatePassword],
  /// [importItems] требуют подтверждения).
  VaultEntry _assessed(VaultEntry entry, SecretBytes password) {
    final assessor = this.assessor;
    if (assessor == null) return entry;
    final result = assessor.assess(password, entry);
    return entry.copyWith(
      score: result.score,
      flags: <String>[
        for (final f in entry.flags)
          if (!EntryFlags.assessed.contains(f)) f,
        ...result.flags,
      ],
    );
  }

  /// Полная проверка (5.5): пароли расшифровываются по одному, оценка и
  /// флаги пересчитываются, недостающий `fp_loose` дописывается. Одна
  /// запись хранилища, если что-то изменилось.
  Future<void> reassess() => _op(() async {
        final open = _requireOpen();
        if (assessor == null) return;
        var changed = false;
        final next = <VaultEntry>[];
        for (final entry in open.index.entries) {
          // Охраняемая важная запись (15.2): оценка заморожена до
          // мастер-пароля — пароль не расшифровывается и не оценивается.
          if (isGuarded(entry)) {
            next.add(entry);
            continue;
          }
          final secret = _openSecret(open, open.ring, entry);
          try {
            var updated = _assessed(entry, secret.password);
            if (entry.fpLoose == null) {
              final loose = VaultKeys.looseFingerprint(
                crypto,
                open.kFp,
                secret.password,
              );
              if (loose != null) updated = updated.copyWith(fpLoose: loose);
            }
            if (updated.score != entry.score ||
                updated.fpLoose != entry.fpLoose ||
                updated.flags.join(',') != entry.flags.join(',')) {
              changed = true;
            }
            next.add(updated);
          } finally {
            secret.wipe();
          }
        }
        _alive(open);
        if (changed) {
          await _commit(open, entries: next, secrets: open.envelope.secrets);
          _notify(VaultSignal.changed);
        }
        touch();
      });

  /// «Проверить себя» и тренировка (5.2, 5.8): верно ли [attempt] для
  /// записи [id]. Кроме «верно» и «не совпадает» — только «почти»
  /// (раскладка, регистр) и «это прежний пароль»: сравниваются отпечатки
  /// вариантов ввода, ни длина, ни совпавшие символы не сообщаются. Не
  /// больше 5 попыток на запись за 10 минут ([RecallLimiter]).
  ///
  /// Охраняемая важная запись ([isGuarded]) тратит попытку из общего
  /// предела догадок [guessLimit] за [guessWindow] — того же, что у
  /// [entriesMatching]: одна догадка на вызов (варианты «почти» — её
  /// часть, 5.2), повтор уже сверенной — бесплатно. Иначе 5 попыток на
  /// каждую из N важных записей плюс 5 догадок ворот — 5 × (N + 1).
  Future<RecallVerdict> recall(String id, SecretBytes attempt) =>
      _guard(() async {
        final open = _requireOpen();
        final entry = _entry(open, id);
        if (isGuarded(entry)) {
          if (attempt.isEmpty) {
            touch();
            return RecallVerdict.wrong;
          }
          final fp = VaultKeys.fingerprint(crypto, open.kFp, attempt);
          try {
            if (!_takeGuess(open, fp)) return RecallVerdict.limited;
          } finally {
            fp.fillRange(0, fp.length, 0);
          }
        } else if (!open.recall.take(id, monotonic.elapsed)) {
          return RecallVerdict.limited;
        }
        touch();
        if (attempt.isEmpty) return RecallVerdict.wrong;
        bool same(SecretBytes candidate) => crypto.equal(
              VaultKeys.fingerprint(crypto, open.kFp, candidate),
              entry.fp,
            );
        if (same(attempt)) return RecallVerdict.correct;
        final fp = VaultKeys.fingerprint(crypto, open.kFp, attempt);
        var old = false;
        for (final previous in entry.fpOld) {
          if (crypto.equal(previous, fp)) old = true;
        }
        if (old) return RecallVerdict.oldOne;
        final runes = Utf8Runes.decode(attempt.unsafeBytes);
        if (runes == null) return RecallVerdict.wrong;
        final layout = <int>[for (final r in runes) KeyboardLayouts.swap(r)];
        final caseVariants = <List<int>>[
          <int>[for (final r in runes) KeyboardLayouts.flipCase(r)],
          KeyboardLayouts.lowerAll(runes),
          if (runes.isNotEmpty)
            <int>[KeyboardLayouts.flipCase(runes.first), ...runes.skip(1)],
        ];
        try {
          if (_matches(layout, same)) return RecallVerdict.almostLayout;
          for (final variant in caseVariants) {
            if (_matches(variant, same)) return RecallVerdict.almostCase;
          }
          return RecallVerdict.wrong;
        } finally {
          runes.fillRange(0, runes.length, 0);
          layout.fillRange(0, layout.length, 0);
          for (final v in caseVariants) {
            v.fillRange(0, v.length, 0);
          }
        }
      });

  /// Сколько попыток «Проверить себя» осталось для [id].
  /// Для охраняемой важной записи — сколько осталось общих догадок.
  int recallLeft(String id) {
    final open = _open;
    if (open == null) return 0;
    final entry = open.index.entries.where((VaultEntry e) => e.id == id);
    if (entry.isNotEmpty && isGuarded(entry.first)) return guessesLeft;
    return open.recall.left(id, monotonic.elapsed);
  }

  /// Сколько разных догадок ещё можно сверить с охраняемыми важными
  /// записями (общий предел [guessLimit] за [guessWindow]).
  int get guessesLeft {
    final open = _open;
    if (open == null) return 0;
    // Догадки истекают только по монотонным часам: перевод часов вперёд
    // предел не сбрасывает.
    final now = monotonic.elapsed;
    final recent = open.guesses
        .where(((Uint8List, Duration) g) => now - g.$2 < guessWindow)
        .length;
    final rest = guessLimit - recent;
    return rest < 0 ? 0 : rest;
  }

  static bool _matches(List<int> runes, bool Function(SecretBytes) same) {
    final bytes = SecretBytes.adopt(Utf8Runes.encode(runes));
    try {
      return same(bytes);
    } finally {
      bytes.wipe();
    }
  }

  /// Итог тренировки записи [id] (5.8): расписание в `train` индекса.
  Future<void> recordTraining(String id, TrainingOutcome outcome) =>
      _op(() async {
        final open = _requireOpen();
        final entry = _entry(open, id);
        final updated = entry.copyWith(
          train: TrainingSchedule.next(entry.train, outcome, clock.now()),
        );
        await _commit(
          open,
          entries: _replace(open.index.entries, updated),
          secrets: open.envelope.secrets,
        );
        touch();
        _notify(VaultSignal.changed);
      });

  /// Удаляет запись. `vault.prev` сразу перезаписывается текущей версией:
  /// иначе «удалённый» пароль жил бы в `.prev`.
  ///
  /// Охраняемую важную запись ([isGuarded]) без свежего мастер-пароля не
  /// удаляют (`StateError`, ничего не меняется): удаление — необратимое
  /// действие, для важных записей оно подтверждается мастер-паролем (3.6).
  /// Экран и карточка чата сначала переспрашивают.
  Future<void> deleteEntry(String id) => _op(() async {
        final open = _requireOpen();
        if (isGuarded(_entry(open, id))) {
          throw StateError('важная запись — после мастер-пароля');
        }
        await _commit(
          open,
          entries: <VaultEntry>[
            for (final e in open.index.entries)
              if (e.id != id) e,
          ],
          secrets: <String, SealedSecret>{
            for (final MapEntry(:key, :value) in open.envelope.secrets.entries)
              if (key != id) key: value,
          },
          replacePrevious: true,
        );
        touch();
        _notify(VaultSignal.changed);
      });

  /// Пароль и заметка записи. Только для `VaultRevealService` в `lib/app`
  /// (через `VaultFacade` недоступно). Вызывающий затирает результат.
  Future<VaultSecret> readSecret(String id) => _guard(() async {
        final open = _requireOpen();
        final secret = _openSecret(open, open.ring, _entry(open, id));
        touch();
        return secret;
      });

  // ------------------------------- охраняемые важные записи (3.6, 15.2)

  /// Окно свежего подтверждения мастер-паролем (3.6).
  static const Duration confirmWindow = Duration(seconds: 60);

  /// Сколько разных догадок можно сверить с охраняемыми важными записями
  /// за [guessWindow] (как у «Проверить себя»).
  static const int guessLimit = 5;
  static const Duration guessWindow = Duration(minutes: 10);

  void _confirmed(_Open open) => open.confirmedAt = _moment();

  /// Важная запись [entry] охраняется: переспрос включён, а мастер-пароль
  /// проверяли больше [confirmWindow] назад (или ни разу с открытия).
  /// Пока охраняется, введённый человеком текст сверяется с её паролем
  /// только через [entriesMatching] с `spendGuess` — одна догадка за
  /// попытку, [guessLimit] за [guessWindow].
  ///
  /// Срок меряется монотонными часами и стенными сразу: охраняется, если
  /// хоть по одним прошло больше окна или стенные ушли назад — перевод
  /// часов ни в какую сторону охрану не снимает. [margin] — запас: с
  /// ним запись «охраняется» уже тогда, когда до конца окна меньше
  /// [margin] (редактор спрашивает мастер-пароль заранее, чтобы окно не
  /// кончилось посреди сохранения).
  bool isGuarded(VaultEntry entry, {Duration margin = Duration.zero}) {
    final open = _open;
    if (open == null || !entry.important) return false;
    if (!VaultPrefs.repromptImportant.of(open.index.prefs)) return false;
    final at = open.confirmedAt;
    if (at == null) return true;
    final wall = clock.now().difference(at.wall);
    if (wall.isNegative) return true;
    final mono = monotonic.elapsed - at.mono;
    final limit = confirmWindow - margin;
    return mono > limit || wall > limit;
  }

  /// Есть хотя бы одна охраняемая важная запись.
  bool get anyGuarded => entries.any(isGuarded);

  /// Единственные ворота сравнения введённого текста [candidate] с
  /// паролями записей по отпечатку (15.2). Охраняемые важные записи
  /// ([isGuarded]) участвуют, только если [spendGuess] и предел догадок
  /// пропустил именно эту догадку: повтор уже сверенной — бесплатно
  /// (ответ уже известен), новая — одна из [guessLimit] за
  /// [guessWindow]. Иначе они пропускаются, и
  /// [SecretMatches.complete] — `false`: ответ «нет совпадений» тогда
  /// ничего не говорит о важных записях. Заперто — пусто и `complete`.
  SecretMatches entriesMatching(
    SecretBytes candidate, {
    String? except,
    bool spendGuess = false,
  }) {
    final open = _open;
    if (open == null || candidate.isEmpty) return const SecretMatches.none();
    final Uint8List fp;
    try {
      fp = VaultKeys.fingerprint(crypto, open.kFp, candidate);
    } catch (_) {
      return const SecretMatches.none();
    }
    try {
      final guarded = <VaultEntry>[
        for (final e in open.index.entries)
          if (isGuarded(e)) e,
      ];
      final withGuarded =
          guarded.isEmpty || (spendGuess && _takeGuess(open, fp));
      return SecretMatches(
        <VaultEntry>[
          for (final entry in open.index.entries)
            if (entry.id != except &&
                (withGuarded || !guarded.contains(entry)) &&
                crypto.equal(fp, entry.fp))
              entry,
        ],
        complete: withGuarded,
      );
    } finally {
      fp.fillRange(0, fp.length, 0);
    }
  }

  /// Пропустить ли догадку [fp] к охраняемым записям (и учесть её).
  bool _takeGuess(_Open open, Uint8List fp) {
    final now = monotonic.elapsed;
    open.guesses.removeWhere(((Uint8List, Duration) g) {
      final old = now - g.$2 >= guessWindow;
      if (old) g.$1.fillRange(0, g.$1.length, 0);
      return old;
    });
    for (final (seen, _) in open.guesses) {
      if (crypto.equal(seen, fp)) return true;
    }
    if (open.guesses.length >= guessLimit) return false;
    open.guesses.add((Uint8List.fromList(fp), now));
    return true;
  }

  /// Совпадает ли [token] по отпечатку с паролем какой-нибудь записи
  /// (`SecretGuard` при открытом хранилище, повтор мастер-пароля).
  /// Охраняемые важные записи не сравниваются ([entriesMatching]): иначе
  /// «скрыл / не скрыл» в чате — оракул без предела. Заперто — `false`.
  bool matchesKnownSecret(String token) {
    if (_open == null || token.isEmpty) return false;
    final candidate = SecretBytes.fromText(token);
    try {
      return entriesMatching(candidate).entries.isNotEmpty;
    } catch (_) {
      return false;
    } finally {
      candidate.wipe();
    }
  }

  /// Отпечаток пароля ключом `k_fp` открытого хранилища. Сравнивать
  /// введённый текст с записями — только через [entriesMatching].
  Uint8List fingerprint(SecretBytes password) =>
      VaultKeys.fingerprint(crypto, _requireOpen().kFp, password);

  /// Ослабит ли [changes] защитные настройки (раздел 9): тогда
  /// [setPrefs] требует мастер-пароль.
  bool prefsWeaken(Map<String, Object?> changes) =>
      VaultPrefs.weakens(prefs, changes);

  /// Меняет защитные настройки в индексе. Ослабление — только с верным
  /// мастер-паролем [master] (тот же счётчик ошибок, что у открытия);
  /// без него — `ArgumentError`, с неверным — `wrongPassword`.
  Future<void> setPrefs(
    Map<String, Object?> changes, {
    SecretBytes? master,
  }) =>
      _op(() async {
        final open = _requireOpen();
        VaultPrefs.check(changes);
        if (VaultPrefs.weakens(open.index.prefs, changes)) {
          if (master == null) throw ArgumentError('нужен мастер-пароль');
          final vk = await _unwrap(
            master,
            open.envelope,
            VaultKeys.header(open.envelope),
          );
          vk.dispose();
          _alive(open);
        }
        await _commit(
          open,
          entries: open.index.entries,
          secrets: open.envelope.secrets,
          prefs: <String, Object?>{...open.index.prefs, ...changes},
        );
        touch();
        _schedule();
        _notify(VaultSignal.changed);
      });

  // ------------------------------------------- импорт и резервная копия

  /// Совпадения пришедших записей с хранилищем — для предпросмотра (5.6,
  /// 5.7). Для копии ([byId]) — сначала по `entry.id`, затем по (сервис,
  /// логин); для CSV — по (сервис или хост, логин). Пароли сравниваются
  /// отпечатками ключом `k_fp` хранилища.
  List<ImportMatch> matchImport(List<ImportItem> items, {bool byId = false}) {
    final open = _requireOpen();
    String norm(String s) => s.trim().toLowerCase();
    Set<String> hosts(List<String> urls) =>
        <String>{for (final u in urls) ImportRules.hostOf(u)};
    final result = <ImportMatch>[];
    for (final item in items) {
      VaultEntry? match;
      if (byId && item.sourceId != null) {
        match = open.index.entries
            .where((VaultEntry e) => e.id == item.sourceId)
            .firstOrNull;
      }
      match ??= open.index.entries.where((VaultEntry e) {
        if (norm(e.login) != norm(item.login)) return false;
        if (norm(e.service) == norm(item.service)) return true;
        final mine = hosts(e.urls);
        return hosts(item.urls).any(mine.contains);
      }).firstOrNull;
      if (match == null) {
        result.add(const ImportMatch(ImportStatus.fresh));
        continue;
      }
      // Охраняемая важная запись (15.2) с файлом не сравнивается: иначе
      // CSV из тысячи строк «Почта, логин, догадка» — тысяча догадок.
      // Без мастер-пароля она всегда «другой пароль» (по умолчанию —
      // «оставить обе»).
      final same = !isGuarded(match) &&
          crypto.equal(
            VaultKeys.fingerprint(crypto, open.kFp, item.password),
            match.fp,
          );
      final from = hosts(match.urls);
      final to = hosts(item.urls);
      final changes = byId &&
          match.urls.isNotEmpty &&
          item.urls.isNotEmpty &&
          (from.length != to.length || !from.containsAll(to));
      result.add(
        ImportMatch(
          same ? ImportStatus.same : ImportStatus.conflict,
          existingId: match.id,
          addressFrom:
              changes ? ImportRules.displayHost(match.urls.first) : null,
          addressTo: changes ? ImportRules.displayHost(item.urls.first) : null,
        ),
      );
    }
    touch();
    return result;
  }

  /// Отпечатки для сравнения паролей внутри файла импорта: случайный
  /// ключ на один вызов [action], потом освобождается.
  T withImportDigest<T>(T Function(Uint8List Function(SecretBytes)) action) {
    final key = crypto.randomKey();
    try {
      return action(
        (SecretBytes password) => crypto.keyedHash(key, password.unsafeBytes),
      );
    } finally {
      key.dispose();
    }
  }

  /// Импорт одной записью хранилища (атомарно: сбой посреди — хранилище
  /// не изменено). Из CSV ([fromBackup] `false`) подсказка, «Важный» и
  /// настройки не берутся; из копии — подсказка своя, «Важный», оценка,
  /// флаги и тренировка сбрасываются. `fp`/`fp_loose` считаются ключом
  /// `k_fp` хранилища, `fp_old` пришедших записей отбрасываются. При
  /// «заменить» прежний `fp` уходит в `fp_old`, `vault.prev` сразу
  /// переписывается (старых паролей нет и там).
  Future<ImportResult> importItems(
    List<ImportDecision> decisions, {
    required bool fromBackup,
  }) =>
      _op(() async {
        final open = _requireOpen();
        final now = clock.now();
        final entries = <VaultEntry>[...open.index.entries];
        final secrets = <String, SealedSecret>{...open.envelope.secrets};
        final ids = <String>{for (final e in entries) e.id};
        final replacedIds = <String>{};
        // Охрана важных записей проверяется один раз на весь импорт: окно
        // подтверждения не кончается посреди него.
        final guardedIds = <String>{
          for (final e in open.index.entries)
            if (isGuarded(e)) e.id,
        };
        var added = 0;
        var replaced = 0;
        var skipped = 0;
        for (final decision in decisions) {
          final item = decision.item;
          final existingId = decision.match.existingId;
          var choice = decision.choice;
          if (choice == ImportChoice.skip) {
            skipped++;
            continue;
          }
          _checkInfo(
            service: item.service,
            login: item.login,
            hint: fromBackup ? item.hint : '',
            urls: item.urls,
          );
          _checkSecret(item.password, item.note);
          final dateSource =
              item.changed == null ? DateSource.unknown : DateSource.import;
          final fp = VaultKeys.fingerprint(crypto, open.kFp, item.password);
          final loose =
              VaultKeys.looseFingerprint(crypto, open.kFp, item.password);
          final index = existingId == null
              ? -1
              : entries.indexWhere((VaultEntry e) => e.id == existingId);
          // Дважды заменить одну запись в одном импорте нельзя — вторая
          // ложится рядом.
          if (choice == ImportChoice.replace &&
              (index < 0 || replacedIds.contains(existingId))) {
            choice = ImportChoice.keepBoth;
          }
          if (choice == ImportChoice.replace) {
            final existing = entries[index];
            // «Заменить» охраняемую важную запись — та же правка, что в
            // редакторе: только после мастер-пароля (15.2). Иначе файл с
            // новым названием или логином пересчитал бы флаги по её
            // паролю. Импорт целиком не применяется.
            if (guardedIds.contains(existing.id)) {
              throw StateError('важная запись — после мастер-пароля');
            }
            final current = _openSecret(open, open.ring, existing);
            try {
              final same = crypto.equal(existing.fp, fp);
              final updated = _assessed(
                existing.copyWith(
                  srev: existing.srev + 1,
                  service: fromBackup ? item.service : null,
                  login: fromBackup ? item.login : null,
                  hint: fromBackup ? item.hint : null,
                  urls: fromBackup
                      ? List<String>.unmodifiable(item.urls)
                      : List<String>.unmodifiable(
                          <String>{...existing.urls, ...item.urls}
                              .take(VaultFormat.maxUrls),
                        ),
                  aliases: fromBackup
                      ? List<String>.unmodifiable(item.aliases)
                      : null,
                  changed: item.changed ?? now,
                  dateSource: dateSource,
                  fp: fp,
                  fpLoose: loose,
                  fpOld: same
                      ? existing.fpOld
                      : <Uint8List>[existing.fp, ...existing.fpOld]
                          .take(VaultEntry.maxOldFingerprints)
                          .toList(),
                  flags: <String>[
                    for (final f in existing.flags)
                      if (f != EntryFlags.importConflict) f,
                  ],
                ),
                item.password,
              );
              final note =
                  fromBackup || !item.note.isEmpty ? item.note : current.note;
              secrets[existing.id] = _sealSecret(
                open.ring,
                open.envelope,
                updated,
                item.password,
                note,
              );
              entries[index] = updated;
              replacedIds.add(existing.id);
              replaced++;
            } finally {
              current.wipe();
            }
            continue;
          }
          var id = fromBackup ? item.sourceId : null;
          while (id == null || !VaultIds.isEntryId(id) || ids.contains(id)) {
            id = VaultIds.hex(crypto.bytes(VaultFormat.idBytes));
          }
          ids.add(id);
          final entry = _assessed(
            VaultEntry(
              id: id,
              srev: 1,
              service: item.service,
              urls: List<String>.unmodifiable(item.urls),
              aliases: List<String>.unmodifiable(item.aliases),
              login: item.login,
              hint: fromBackup ? item.hint : '',
              created: item.created ?? item.changed ?? now,
              changed: item.changed ?? now,
              dateSource: dateSource,
              fp: fp,
              fpLoose: loose,
              flags: decision.match.status == ImportStatus.conflict
                  ? const <String>[EntryFlags.importConflict]
                  : const <String>[],
            ),
            item.password,
          );
          secrets[id] = _sealSecret(
            open.ring,
            open.envelope,
            entry,
            item.password,
            item.note,
          );
          entries.add(entry);
          added++;
        }
        if (entries.length > VaultFormat.maxEntries) {
          throw ArgumentError('слишком много записей');
        }
        _alive(open);
        if (added + replaced > 0) {
          await _commit(
            open,
            entries: entries,
            secrets: secrets,
            replacePrevious: replaced > 0,
          );
          _notify(VaultSignal.changed);
        }
        touch();
        return ImportResult(added: added, replaced: replaced, skipped: skipped);
      });

  /// Резервная копия (4.3, 5.7): только из открытого хранилища и с верным
  /// мастер-паролем [master] (тот же счётчик ошибок). Пароль копии —
  /// [passphrase] или мастер-пароль. Свой `vault_id`, VK и соль; Argon2id
  /// не слабее хранилища ([VaultKdfParams.forBackup]); `wrap_bio` нет
  /// никогда. Индекс (с `k_fp`) и все секреты перешифрованы ключом копии.
  /// Перед возвратом копия проверяется чтением: открыть паролем,
  /// расшифровать индекс и каждый секрет. Хранилище не меняется — после
  /// сохранения файла вызвать [recordBackup].
  ///
  /// [afterVerify] вызывается сразу после проверки мастер-пароля (тогда
  /// важные записи уже не охраняются, [isGuarded]): проверка повтора
  /// пароля копии — только после мастер-пароля, иначе это оракул.
  /// Непустой ответ отменяет выгрузку ([VaultRejected]).
  Future<Uint8List> exportBackup({
    required SecretBytes master,
    SecretBytes? passphrase,
    VaultKdfParams? params,
    String? Function()? afterVerify,
  }) =>
      _op(() async {
        final open = _requireOpen();
        final check = await _unwrap(
          master,
          open.envelope,
          VaultKeys.header(open.envelope),
        );
        check.dispose();
        _alive(open);
        _confirmed(open);
        final rejected = afterVerify?.call();
        if (rejected != null) throw VaultRejected(rejected);
        final vaultKdf = VaultKdfParams.checkLoaded(
          open.envelope.kdf,
          allowTesting: allowTestingKdf,
        );
        final floor = VaultKdfParams.forBackup(vaultKdf);
        final kdf = params ?? floor;
        _checkParams(kdf);
        if (!kdf.isTesting && (kdf.mem < floor.mem || kdf.ops < floor.ops)) {
          throw ArgumentError('параметры копии слабее хранилища');
        }
        if (open.index.entries.length > VaultBackup.maxEntries) {
          throw ArgumentError('слишком много записей для копии');
        }
        final secret = passphrase ?? master;
        final salt = crypto.bytes(VaultFormat.saltBytes);
        final vaultId = base64.encode(crypto.bytes(VaultFormat.idBytes));
        final record = KdfRecord(ops: kdf.ops, mem: kdf.mem, salt: salt);
        final ring = VaultKeyRing.from(crypto, crypto.randomKey());
        try {
          final header = _headerFor(VaultFormat.kindBackup, vaultId, record);
          final kek = await crypto.derive(secret, salt, kdf);
          final SealedBox wrap;
          try {
            wrap = crypto.sealKey(kek, ring.vk, VaultKeys.wrapPwAd(header));
          } finally {
            kek.dispose();
          }
          _alive(open);
          final base = VaultEnvelope(
            kind: VaultFormat.kindBackup,
            vaultId: vaultId,
            kdf: record,
            wrapPw: wrap,
            rev: 1,
            index: wrap,
            secrets: const <String, SealedSecret>{},
          );
          final secrets = <String, SealedSecret>{};
          for (final entry in open.index.entries) {
            final plain = _openSecret(open, open.ring, entry);
            try {
              secrets[entry.id] =
                  _sealSecret(ring, base, entry, plain.password, plain.note);
            } finally {
              plain.wipe();
            }
          }
          final index = VaultIndex(
            rev: 1,
            kFp: open.index.kFp.clone(),
            entries: open.index.entries,
            extra: <String, Object?>{
              'exported_at': _iso(clock.now()),
              'app_version': VaultBackup.appVersion,
            },
          );
          final VaultEnvelope envelope;
          try {
            envelope = _sealEnvelope(
              ring: ring,
              vaultId: vaultId,
              kdf: record,
              wrapPw: wrap,
              index: index,
              secrets: secrets,
              kind: VaultFormat.kindBackup,
            );
          } finally {
            index.kFp.wipe();
          }
          final bytes = envelope.encode();
          if (bytes.length > VaultBackup.maxBytes) {
            throw ArgumentError('копия больше предела');
          }
          // Проверка чтением: открыть паролем, индекс и каждый секрет.
          final read = await _readBackup(bytes, secret);
          final complete = read.skipped == 0 &&
              read.items.length == open.index.entries.length;
          read.wipe();
          if (!complete) throw VaultError.corrupt;
          touch();
          return bytes;
        } finally {
          ring.dispose();
        }
      });

  /// Копия сохранена и проверена: дата в индексе (`backup.last`), счётчик
  /// изменений с копии — 0, каким паролем закрыта.
  Future<void> recordBackup({required bool separate}) => _op(() async {
        final open = _requireOpen();
        await _commit(
          open,
          entries: open.index.entries,
          secrets: open.envelope.secrets,
          backup: <String, Object?>{
            ...open.index.backup,
            'last': _iso(clock.now()),
            'changes_since': 0,
            'pw_kind': separate ? 'separate' : 'master',
          },
        );
        touch();
        _notify(VaultSignal.changed);
      });

  /// Когда последний раз делали копию (из индекса открытого хранилища).
  DateTime? get lastBackupAt {
    final value = _open?.index.backup['last'];
    return value is String ? DateTime.tryParse(value) : null;
  }

  /// Открыть копию паролем [passphrase] (4.3, 15.4). Копия — недоверенные
  /// данные: берутся только записи и `k_fp`; схема строгая (нарушение —
  /// запись пропускается); адреса с недопустимой схемой отбрасываются;
  /// параметры Argon2id проверяются до вывода ключа (`mem ≤ 256 МиБ` и
  /// `≤ totalMemory / 4`, иначе `kdfInvalid` — память не выделяется).
  /// Неверный пароль — `wrongPassword`. Результат затирает вызывающий.
  Future<BackupContents> readBackup(Uint8List bytes, SecretBytes passphrase) =>
      _guard(() async {
        _requireEnabled();
        return _readBackup(bytes, passphrase);
      });

  Future<BackupContents> _readBackup(
    Uint8List bytes,
    SecretBytes passphrase,
  ) async {
    if (bytes.length > VaultBackup.maxBytes) throw VaultError.corrupt;
    final envelope = VaultEnvelope.decode(bytes);
    if (envelope.kind != VaultFormat.kindBackup) throw VaultError.corrupt;
    final params = VaultKdfParams.checkLoaded(
      envelope.kdf,
      backup: true,
      totalMemory: totalMemory,
      allowTesting: allowTestingKdf,
    );
    final header = VaultKeys.header(envelope);
    final kek = await crypto.derive(passphrase, envelope.kdf.salt, params);
    final VaultKey? vk;
    try {
      vk = crypto.openKey(kek, envelope.wrapPw, VaultKeys.wrapPwAd(header));
    } finally {
      kek.dispose();
    }
    if (vk == null) throw VaultError.wrongPassword;
    final ring = VaultKeyRing.from(crypto, vk);
    try {
      final body = crypto.open(
        ring.index,
        envelope.index,
        VaultKeys.indexAd(header, envelope.rev),
      );
      if (body == null) throw VaultError.corrupt;
      final (kFp, infos, invalid, exported) =
          BackupIndexReader.parse(body, rev: envelope.rev);
      final items = <ImportItem>[];
      var skipped = invalid;
      try {
        for (final info in infos) {
          final sealed = envelope.secrets[info.id];
          if (sealed == null || sealed.rev != info.srev) {
            skipped++;
            continue;
          }
          final plain = crypto.open(
            ring.secret,
            sealed.box,
            VaultKeys.secretAd(
              version: envelope.sourceVersion,
              kind: envelope.kind,
              vaultId: envelope.vaultId,
              entryId: info.id,
              srev: info.srev,
            ),
          );
          if (plain == null) throw VaultError.corrupt;
          final secret = SecretCodec.decodePadded(plain);
          if (secret.password.isEmpty ||
              secret.password.length > VaultFormat.maxPassword ||
              secret.note.length > VaultFormat.maxNote) {
            secret.wipe();
            skipped++;
            continue;
          }
          items.add(
            ImportItem(
              service: info.service,
              login: info.login,
              hint: info.hint,
              urls: info.urls,
              aliases: info.aliases,
              password: secret.password,
              note: secret.note,
              created: info.created,
              changed: info.changed,
              sourceId: info.id,
              srcFp: info.fp,
              srcFpOld: info.fpOld,
              record: items.length + 1,
            ),
          );
        }
      } catch (_) {
        for (final item in items) {
          item.wipe();
        }
        kFp.wipe();
        rethrow;
      }
      return BackupContents(
        items: items,
        kFp: kFp,
        skipped: skipped,
        exportedAt: exported,
      );
    } finally {
      ring.dispose();
    }
  }

  // ------------------------------------------------ мастер-пароль

  /// Смена мастер-пароля. Всегда с новым VK (D5): индекс и все секреты
  /// перешифровываются, `vault.prev` и `vault.v<N>.bak` перезаписываются
  /// новой версией — старый (возможно, утёкший) мастер-пароль больше
  /// ничего не открывает. Без [params] — новая калибровка.
  ///
  /// [afterVerify] — после проверки [current], до перешифрования (повтор
  /// нового мастер-пароля, как у [exportBackup]).
  Future<void> changeMaster({
    required SecretBytes current,
    required SecretBytes next,
    VaultKdfParams? params,
    String? Function()? afterVerify,
  }) =>
      _op(() async {
        final open = _requireOpen();
        final check = await _unwrap(
          current,
          open.envelope,
          VaultKeys.header(open.envelope),
        );
        check.dispose();
        _alive(open);
        _confirmed(open);
        final rejected = afterVerify?.call();
        if (rejected != null) throw VaultRejected(rejected);
        final kdf = params ?? await _calibrate();
        _checkParams(kdf);
        _alive(open);
        await _rekey(open, next, kdf);
      });

  /// «Перешифровать всё новым ключом»: тот же мастер-пароль, новый VK и
  /// соль, прежние параметры Argon2id.
  Future<void> reencryptAll(SecretBytes master) => _op(() async {
        final open = _requireOpen();
        final check = await _unwrap(
          master,
          open.envelope,
          VaultKeys.header(open.envelope),
        );
        check.dispose();
        _alive(open);
        final params = VaultKdfParams.checkLoaded(
          open.envelope.kdf,
          allowTesting: allowTestingKdf,
        );
        await _rekey(open, master, params);
      });

  Future<void> _rekey(
    _Open open,
    SecretBytes master,
    VaultKdfParams kdf,
  ) async {
    final salt = crypto.bytes(VaultFormat.saltBytes);
    final record = KdfRecord(ops: kdf.ops, mem: kdf.mem, salt: salt);
    final ring = VaultKeyRing.from(crypto, crypto.randomKey());
    try {
      final header =
          _headerFor(VaultFormat.kindVault, open.envelope.vaultId, record);
      final kek = await crypto.derive(master, salt, kdf);
      final SealedBox wrap;
      try {
        wrap = crypto.sealKey(kek, ring.vk, VaultKeys.wrapPwAd(header));
      } finally {
        kek.dispose();
      }
      _alive(open);
      final base = VaultEnvelope(
        kind: VaultFormat.kindVault,
        vaultId: open.envelope.vaultId,
        kdf: record,
        wrapPw: wrap,
        rev: open.envelope.rev,
        index: open.envelope.index,
        secrets: const <String, SealedSecret>{},
      );
      final secrets = <String, SealedSecret>{};
      for (final entry in open.index.entries) {
        final secret = _openSecret(open, open.ring, entry);
        try {
          secrets[entry.id] =
              _sealSecret(ring, base, entry, secret.password, secret.note);
        } finally {
          secret.wipe();
        }
      }
      final written = await _commit(
        open,
        entries: open.index.entries,
        secrets: secrets,
        master: <String, Object?>{
          ...open.index.master,
          'last_typed': _iso(clock.now()),
        },
        ring: ring,
        kdf: record,
        wrapPw: wrap,
        replacePrevious: true,
      );
      for (final version in await store.backupVersions()) {
        await store.writeBackup(version, written);
      }
    } catch (_) {
      if (!identical(open.ring, ring)) ring.dispose();
      rethrow;
    }
    touch();
    _notify(VaultSignal.changed);
  }

  // --------------------------------------------------------- внутреннее

  _Open _requireOpen() {
    if (_disabled) throw VaultError.locked;
    final open = _open;
    if (open == null) throw VaultError.locked;
    return open;
  }

  void _requireEnabled() {
    if (_disabled) throw VaultError.locked;
  }

  /// Операция начата при эпохе [epoch]: если с тех пор заперли или
  /// выключили навык — `locked`.
  void _stillWanted(int epoch) {
    if (epoch != _epoch || _disabled) throw VaultError.locked;
  }

  /// [open] всё ещё открытое хранилище (не заперто посреди операции).
  void _alive(_Open open) {
    if (_disabled || !identical(_open, open)) throw VaultError.locked;
  }

  /// По одной: каждая операция ждёт конца предыдущей.
  Future<T> _serial<T>(Future<T> Function() action) {
    final run = _tail.then((_) => action());
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  Future<T> _op<T>(Future<T> Function() action) =>
      _serial(() => _guard(action));

  VaultEntry _entry(_Open open, String id) {
    final entry = open.index.entries.where((VaultEntry e) => e.id == id);
    if (entry.isEmpty) throw ArgumentError('нет записи');
    return entry.first;
  }

  static List<VaultEntry> _replace(List<VaultEntry> entries, VaultEntry next) =>
      <VaultEntry>[
        for (final e in entries) e.id == next.id ? next : e,
      ];

  static void _checkInfo({
    required String service,
    required String login,
    required String hint,
    required List<String> urls,
  }) {
    if (service.isEmpty ||
        service.length > VaultFormat.maxService ||
        login.length > VaultFormat.maxLogin ||
        hint.length > VaultFormat.maxHint ||
        urls.length > VaultFormat.maxUrls ||
        urls.any((String u) => u.length > VaultFormat.maxUrl)) {
      throw ArgumentError('поле записи вне пределов');
    }
  }

  static void _checkSecret(SecretBytes password, SecretBytes? note) {
    if (password.isEmpty ||
        password.length > VaultFormat.maxPassword ||
        (note != null && note.length > VaultFormat.maxNote)) {
      throw ArgumentError('секрет вне пределов');
    }
  }

  Uint8List _headerFor(String kind, String vaultId, KdfRecord kdf) =>
      VaultKeys.headerOf(
        version: VaultFormat.version,
        kind: kind,
        vaultId: vaultId,
        ops: kdf.ops,
        mem: kdf.mem,
        salt: kdf.salt,
      );

  Uint8List _secretAd(VaultEnvelope envelope, VaultEntry entry, int version) =>
      VaultKeys.secretAd(
        version: version,
        kind: envelope.kind,
        vaultId: envelope.vaultId,
        entryId: entry.id,
        srev: entry.srev,
      );

  SealedSecret _sealSecret(
    VaultKeyRing ring,
    VaultEnvelope envelope,
    VaultEntry entry,
    SecretBytes password,
    SecretBytes note,
  ) {
    final body = SecretCodec.encodePadded(password, note);
    try {
      return SealedSecret(
        crypto.seal(
          ring.secret,
          body,
          _secretAd(envelope, entry, VaultFormat.version),
        ),
        entry.srev,
      );
    } finally {
      body.fillRange(0, body.length, 0);
    }
  }

  /// Секрет записи. `srev` для AD — из индекса, не из внешнего `r`.
  VaultSecret _openSecret(_Open open, VaultKeyRing ring, VaultEntry entry) {
    final sealed = open.envelope.secrets[entry.id];
    if (sealed == null || sealed.rev != entry.srev) throw VaultError.corrupt;
    final body = crypto.open(
      ring.secret,
      sealed.box,
      _secretAd(open.envelope, entry, open.envelope.sourceVersion),
    );
    if (body == null) throw VaultError.corrupt;
    return SecretCodec.decodePadded(body);
  }

  SealedSecret _reseal(_Open open, VaultKeyRing ring, VaultEntry entry) {
    final secret = _openSecret(open, open.ring, entry);
    try {
      return _sealSecret(
        ring,
        open.envelope,
        entry,
        secret.password,
        secret.note,
      );
    } finally {
      secret.wipe();
    }
  }

  VaultEnvelope _sealEnvelope({
    required VaultKeyRing ring,
    required String vaultId,
    required KdfRecord kdf,
    required SealedBox wrapPw,
    required VaultIndex index,
    required Map<String, SealedSecret> secrets,
    BioWrap? wrapBio,
    String kind = VaultFormat.kindVault,
  }) {
    final header = _headerFor(kind, vaultId, kdf);
    final body = index.encodePadded();
    try {
      return VaultEnvelope(
        kind: kind,
        vaultId: vaultId,
        kdf: kdf,
        wrapPw: wrapPw,
        wrapBio: wrapBio,
        rev: index.rev,
        index:
            crypto.seal(ring.index, body, VaultKeys.indexAd(header, index.rev)),
        secrets: Map<String, SealedSecret>.unmodifiable(secrets),
      );
    } finally {
      body.fillRange(0, body.length, 0);
    }
  }

  /// Новая версия файла: `rev + 1`, индекс и конверт заново. В памяти
  /// меняется только после успешной записи. Возвращает записанные байты.
  Future<Uint8List> _commit(
    _Open open, {
    required List<VaultEntry> entries,
    required Map<String, SealedSecret> secrets,
    Map<String, Object?>? master,
    Map<String, Object?>? prefs,
    Map<String, Object?>? backup,
    VaultKeyRing? ring,
    KdfRecord? kdf,
    SealedBox? wrapPw,
    bool replacePrevious = false,
  }) async {
    final rev = open.envelope.rev + 1;
    final index = open.index.copyWith(
      rev: rev,
      entries: List<VaultEntry>.unmodifiable(entries),
      master: master,
      prefs: prefs,
      backup: backup,
    );
    final envelope = _sealEnvelope(
      ring: ring ?? open.ring,
      vaultId: open.envelope.vaultId,
      kdf: kdf ?? open.envelope.kdf,
      wrapPw: wrapPw ?? open.envelope.wrapPw,
      // Обёртка биометрией живёт, пока VK тот же.
      wrapBio: ring == null && wrapPw == null ? open.envelope.wrapBio : null,
      index: index,
      secrets: secrets,
    );
    final bytes = envelope.encode();
    // Файл, который не прочитать (предел шифротекста, индекса, файла), не
    // пишется: иначе хранилище целиком стало бы «испорченным».
    try {
      VaultEnvelope.decode(bytes);
    } on Object {
      throw ArgumentError('запись не помещается в формат хранилища');
    }
    await store.writeVault(bytes, replacePrevious: replacePrevious);
    if (!identical(_open, open)) {
      // Заперли, пока шла запись: файл на диске, ключи уже освобождены;
      // новое кольцо (смена ключа) тоже не остаётся в памяти.
      if (ring != null && !identical(ring, open.ring)) ring.dispose();
      return bytes;
    }
    open.envelope = envelope;
    open.index = index;
    if (ring != null && !identical(ring, open.ring)) {
      final old = open.ring;
      open.ring = ring;
      old.dispose();
    }
    return bytes;
  }

  static String _iso(DateTime time) => time.toUtc().toIso8601String();

  /// Наружу выходят только [VaultError], а также `ArgumentError` и
  /// `StateError` без данных (ошибка вызывающего).
  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on VaultError {
      rethrow;
    } on VaultRejected {
      rethrow;
    } on ArgumentError catch (error) {
      throw ArgumentError(error.message);
    } on StateError catch (error) {
      throw StateError(error.message);
    } catch (_) {
      throw VaultError.io;
    }
  }

  @override
  String toString() => 'Vault(${state.name})';
}

/// Собранное в памяти, но ещё не записанное хранилище.
final class _Built {
  _Built(this.envelope, this.index, this.ring, this.kFp, this.bytes, this.now);

  final VaultEnvelope envelope;
  final VaultIndex index;
  final VaultKeyRing ring;
  final VaultKey kFp;
  final Uint8List bytes;
  final DateTime now;

  void dispose() {
    ring.dispose();
    kFp.dispose();
    index.kFp.wipe();
  }
}

/// Открытое хранилище: ключи, индекс и шифротексты секретов.
final class _Open {
  _Open({
    required this.envelope,
    required this.index,
    required this.ring,
    required this.kFp,
    required this.unlockedAt,
  }) : lastActivity = unlockedAt;

  VaultEnvelope envelope;
  VaultIndex index;
  VaultKeyRing ring;
  final VaultKey kFp;
  final _Moment unlockedAt;
  _Moment lastActivity;

  /// Попытки «Проверить себя» (сбрасываются при запирании).
  final RecallLimiter recall = RecallLimiter();

  /// Когда последний раз проверяли мастер-пароль (открытие, переспрос,
  /// выгрузка копии, смена мастер-пароля). Создание хранилища не в счёт.
  _Moment? confirmedAt;

  /// Догадки, уже сверенные с охраняемыми важными записями (отпечаток и
  /// монотонное время): не больше [Vault.guessLimit] разных за
  /// [Vault.guessWindow].
  final List<(Uint8List, Duration)> guesses = <(Uint8List, Duration)>[];

  void dispose() {
    recall.clear();
    for (final (fp, _) in guesses) {
      fp.fillRange(0, fp.length, 0);
    }
    guesses.clear();
    ring.dispose();
    kFp.dispose();
    index.kFp.wipe();
  }
}

/// Итог [Vault.entriesMatching]: записи с тем же паролем; [complete] —
/// сравнили со всеми записями (охраняемые важные не пропущены).
final class SecretMatches {
  const SecretMatches(this.entries, {required this.complete});

  const SecretMatches.none()
      : entries = const <VaultEntry>[],
        complete = true;

  final List<VaultEntry> entries;
  final bool complete;

  @override
  String toString() => 'SecretMatches(${entries.length}, complete: $complete)';
}

/// Отметка времени открытого хранилища: стенные часы и монотонные.
final class _Moment {
  const _Moment(this.wall, this.mono);

  final DateTime wall;
  final Duration mono;
}
