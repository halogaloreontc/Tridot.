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
import 'vault_codes.dart';
import 'vault_crypto.dart';
import 'vault_device_key.dart';
import 'vault_errors.dart';
import 'vault_format.dart';
import 'vault_prefs.dart';
import 'vault_proof.dart';
import 'vault_store.dart';

export 'vault_proof.dart';

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
/// Новый код восстановления ([Vault.regenerateRecovery]): [code] показать
/// один раз и затереть; [rotated] — сменился ли и ключ сейфа.
final class RecoveryRegen {
  const RecoveryRegen(this.code, {required this.rotated});

  final SecretBytes code;
  final bool rotated;

  @override
  String toString() => 'RecoveryRegen(•••, rotated: $rotated)';
}

final class VaultUnlockResult {
  const VaultUnlockResult({
    required this.rev,
    required this.rolledBack,
    this.variantHit = false,
    this.recoveryCode,
    this.recovered = false,
  });

  /// Версия открытого файла (для `passwords.seen_rev`).
  final int rev;

  /// Файл старее, чем был (`rev < seen_rev`): его могли подменить или
  /// восстановить из старой копии. Только предупреждение (раздел 4.1).
  final bool rolledBack;

  /// Подошёл не сам ввод, а его вариант (D25): другая раскладка, Caps
  /// Lock, регистр первой буквы, пробелы по краям.
  final bool variantHit;

  /// Сейф с мастер-паролем перешёл на защиту устройством (ADR-025): новый
  /// код восстановления для показа — один раз. Вызывающий затирает.
  final SecretBytes? recoveryCode;

  /// Открыли кодом восстановления: ключ устройства создан заново, ПИН-код
  /// и биометрия сняты — их можно включить снова.
  final bool recovered;
}

/// Чем можно открыть запертый сейф — по конверту, без ключей (ADR-025).
final class VaultLockInfo {
  const VaultLockInfo({
    required this.pwKind,
    this.device = false,
    this.pin = false,
    this.bio = false,
  });

  /// [VaultFormat.pwMaster] — старый сейф с мастер-паролем;
  /// [VaultFormat.pwRecovery] — защита устройством и код восстановления.
  final String pwKind;
  final bool device;
  final bool pin;
  final bool bio;

  bool get usesMaster => pwKind == VaultFormat.pwMaster;

  factory VaultLockInfo.of(VaultEnvelope envelope) => VaultLockInfo(
        pwKind: envelope.pwKind ?? VaultFormat.pwMaster,
        device: envelope.slots.containsKey(VaultFormat.slotDevice),
        pin: envelope.slots.containsKey(VaultFormat.slotPin),
        bio: envelope.slots.containsKey(VaultFormat.slotBio),
      );

  @override
  String toString() =>
      'VaultLockInfo($pwKind, dev: $device, pin: $pin, bio: $bio)';
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
    this.deviceKey,
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

  /// Ключ устройства (ADR-025). Есть — новый сейф защищён устройством и
  /// кодом восстановления, а сейф с мастер-паролем переходит на это после
  /// одного ввода мастер-пароля. Нет — прежний режим мастер-пароля.
  final VaultDeviceKey? deviceKey;

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
  ///
  /// [keepHistory] — перенести прежние пароли из копии и включить в новом
  /// хранилище хронологию паролей (ADR-015); иначе хронология копии
  /// отбрасывается.
  Future<void> createFromBackup(
    BackupContents contents,
    SecretBytes master, {
    VaultKdfParams? params,
    bool keepHistory = false,
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
        await _build(
          master,
          kdf,
          kFp: contents.kFp,
          items: contents.items,
          keepHistory: keepHistory,
        ),
        epoch: epoch,
      );
    });
  }

  /// Новый сейф, защищённый устройством (ADR-025): ключ сейфа обёрнут
  /// ключом устройства (слот `dev`) и ключом из нового кода
  /// восстановления. Возвращает код в виде для показа — один раз;
  /// вызывающий затирает. Без [params] — калибровка Argon2id. После
  /// создания хранилище открыто; код ещё не подтверждён
  /// ([recoveryConfirmed]).
  Future<SecretBytes> createProtected({VaultKdfParams? params}) {
    final epoch = _epoch;
    return _op(() async {
      await _ensureLoaded();
      _requireEnabled();
      _stillWanted(epoch);
      if (deviceKey == null) throw StateError('нет ключа устройства');
      if (_exists || await store.hasVault()) {
        _exists = true;
        throw StateError('хранилище уже есть');
      }
      final kdf = params ?? await _calibrate();
      _checkParams(kdf);
      return _withNewCode(
        (SecretBytes canonical) async => _install(
          await _build(canonical, kdf, withDevice: true),
          epoch: epoch,
        ),
      );
    });
  }

  /// «Создать сейф из копии» с защитой устройством (ADR-025): как
  /// [createFromBackup], но вместо мастер-пароля — ключ устройства и новый
  /// код восстановления (возвращается для показа; вызывающий затирает).
  Future<SecretBytes> createFromBackupProtected(
    BackupContents contents, {
    VaultKdfParams? params,
    bool keepHistory = false,
  }) {
    final epoch = _epoch;
    return _op(() async {
      await _ensureLoaded();
      _requireEnabled();
      _stillWanted(epoch);
      if (deviceKey == null) throw StateError('нет ключа устройства');
      if (_exists || await store.hasVault()) {
        _exists = true;
        throw StateError('хранилище уже есть');
      }
      final kdf = params ?? await _calibrate();
      _checkParams(kdf);
      return _withNewCode(
        (SecretBytes canonical) async => _install(
          await _build(
            canonical,
            kdf,
            kFp: contents.kFp,
            items: contents.items,
            keepHistory: keepHistory,
            withDevice: true,
          ),
          epoch: epoch,
        ),
      );
    });
  }

  /// Новый код восстановления: [use] получает его в виде без дефисов (для
  /// Argon2id); в ответе — вид для показа. Сбой — код затирается.
  Future<SecretBytes> _withNewCode(
    Future<void> Function(SecretBytes canonical) use,
  ) async {
    final code = RecoveryCode.generate(crypto);
    final canonical = RecoveryCode.canonical(code)!;
    try {
      await use(canonical);
      return code;
    } catch (_) {
      code.wipe();
      rethrow;
    } finally {
      canonical.wipe();
    }
  }

  /// «Заменить всё» из копии (5.7): только с верным мастер-паролем
  /// [master]; текущее хранилище не стирается, а уходит в
  /// `archive/replaced-<дата>.relayvault`. Новое — с тем же мастер-паролем
  /// и параметрами Argon2id, `k_fp` из копии. Хронология паролей копии
  /// переносится, только если она включена в текущем хранилище (тогда
  /// включена и в новом). Возвращает имя в архиве.
  Future<String> replaceWithBackup(
    BackupContents contents,
    SecretBytes master,
  ) =>
      _op(() async {
        final open = _requireOpen();
        if (open.envelope.isRecoveryKind) {
          throw StateError('сейф защищён устройством');
        }
        (await _unwrap(master, open.envelope)).dispose();
        return _replaceAll(open, contents, master);
      });

  /// «Заменить всё» у сейфа, защищённого устройством (ADR-025): после
  /// подтверждения [proof] новое хранилище из копии — со своим ключом
  /// устройства и новым кодом восстановления (второе в ответе; показать
  /// один раз, вызывающий затирает). ПИН-код и биометрию прежнего сейфа
  /// новый не наследует — их включают заново. Первое — имя в архиве.
  Future<(String, SecretBytes)> replaceWithBackupProtected(
    BackupContents contents,
    VaultProof proof,
  ) =>
      _op(() async {
        final open = _requireOpen();
        if (!open.envelope.isRecoveryKind || deviceKey == null) {
          throw StateError('сейф не защищён устройством');
        }
        await _proofCheck(open, proof);
        late String name;
        final code = await _withNewCode(
          (SecretBytes canonical) async =>
              name = await _replaceAll(open, contents, canonical),
        );
        return (name, code);
      });

  Future<String> _replaceAll(
    _Open open,
    BackupContents contents,
    SecretBytes secret,
  ) async {
    _alive(open);
    final kdf = VaultKdfParams.checkLoaded(
      open.envelope.kdf,
      allowTesting: allowTestingKdf,
    );
    final built = await _build(
      secret,
      kdf,
      kFp: contents.kFp,
      items: contents.items,
      keepHistory: VaultPrefs.passwordHistory.of(open.index.prefs),
      withDevice: open.envelope.isRecoveryKind,
    );
    final String name;
    try {
      _alive(open);
      name = await _archiveName('replaced');
      await store.archiveVault(name);
    } catch (_) {
      built.dispose();
      await _forget(built.aliases);
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
  }

  /// Новое хранилище в памяти: ключи, индекс (с записями [items]) и
  /// конверт. Ещё не записано. [keepHistory] — с хронологией паролей
  /// записей (и включённой опцией).
  ///
  /// [withDevice] — сейф защищён устройством (ADR-025): [master] — код
  /// восстановления (25 знаков без дефисов), слот `dev` создаётся здесь.
  Future<_Built> _build(
    SecretBytes master,
    VaultKdfParams kdf, {
    SecretBytes? kFp,
    List<ImportItem> items = const <ImportItem>[],
    bool keepHistory = false,
    bool withDevice = false,
  }) async {
    final now = clock.now();
    final salt = crypto.bytes(VaultFormat.saltBytes);
    final vaultId = base64.encode(crypto.bytes(VaultFormat.idBytes));
    final ring = VaultKeyRing.from(crypto, crypto.randomKey());
    final kFpBytes = kFp == null
        ? SecretBytes.adopt(crypto.bytes(VaultFormat.keyBytes))
        : kFp.clone();
    final kFpKey = crypto.importKey(kFpBytes.clone());
    final pwKind = withDevice ? VaultFormat.pwRecovery : VaultFormat.pwMaster;
    final aliases = <String>[];
    try {
      final kek = await crypto.derive(master, salt, kdf);
      final record = KdfRecord(ops: kdf.ops, mem: kdf.mem, salt: salt);
      final SealedBox wrap;
      try {
        wrap = crypto.sealKey(
          kek,
          ring.vk,
          VaultKeys.wrapPwAdOf(
            version: VaultFormat.version,
            kind: VaultFormat.kindVault,
            vaultId: vaultId,
            kdf: record,
            pwKind: pwKind,
          ),
        );
      } finally {
        kek.dispose();
      }
      final slots = <String, VaultSlot>{};
      if (withDevice) {
        final slot = await _makeSlot(VaultFormat.slotDevice, ring.vk, vaultId);
        aliases.add(slot.alias);
        slots[VaultFormat.slotDevice] = slot;
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
      final history = <String, SealedBox>{};
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
            history: keepHistory
                ? _mergeHistory(
                    ring: ring,
                    envelope: base,
                    entryId: id,
                    kFp: kFpKey,
                    currentFp: fp,
                    incoming: item.history,
                    boxes: history,
                  )
                : const <HistoryMeta>[],
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
        master: withDevice
            ? <String, Object?>{_rcConfirmedKey: false}
            : <String, Object?>{'last_typed': _iso(now)},
        prefs: keepHistory
            ? <String, Object?>{VaultPrefs.passwordHistory.key: true}
            : const <String, Object?>{},
      );
      final envelope = _sealEnvelope(
        ring: ring,
        vaultId: vaultId,
        kdf: record,
        wrapPw: wrap,
        index: index,
        secrets: secrets,
        history: history,
        pwKind: pwKind,
        slots: slots,
      );
      final bytes = envelope.encode();
      try {
        VaultEnvelope.decode(bytes);
      } on Object {
        throw ArgumentError('запись не помещается в формат хранилища');
      }
      return _Built(envelope, index, ring, kFpKey, bytes, now, aliases);
    } catch (_) {
      ring.dispose();
      kFpKey.dispose();
      kFpBytes.wipe();
      await _forget(aliases);
      rethrow;
    }
  }

  /// Записать собранное хранилище и открыть его.
  Future<void> _install(
    _Built built, {
    required int epoch,
    bool replacePrevious = false,
  }) async {
    var written = false;
    try {
      _stillWanted(epoch);
      await store.writeVault(built.bytes, replacePrevious: replacePrevious);
      written = true;
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
      // Файл не записан (или записан, но сейф заперли — тогда ключ нужен):
      // ключи устройства убираем, только если записи не было.
      if (!written) await _forget(built.aliases);
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

  /// Открывает хранилище мастер-паролем или кодом восстановления (у сейфа,
  /// защищённого устройством, ADR-025). Ошибки: [VaultRateLimited]
  /// (пауза, D25), `wrongPassword`, `corrupt`, `kdfInvalid`, `tooNew`,
  /// `io`, `locked` (навык выключен). [seenRev] — `passwords.seen_rev`
  /// из настроек: по нему видно откат файла. При неверном мастер-пароле
  /// сразу пробуются его варианты ([MasterVariants], D25) — это одна
  /// попытка счётчика; код восстановления приводится к своему виду
  /// ([RecoveryCode.canonical]) и вариантов не требует.
  ///
  /// Сейф с мастер-паролем при ключе устройства ([deviceKey]) сразу
  /// переходит на защиту устройством: новый ключ сейфа, слот `dev` и код
  /// восстановления ([VaultUnlockResult.recoveryCode]). Открыли кодом
  /// восстановления — ключ устройства создаётся заново, ПИН-код и
  /// биометрия снимаются ([VaultUnlockResult.recovered]).
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
      final (bytes, envelope) = await _readEnvelope();
      final recovery = envelope.isRecoveryKind;
      // Мигрированный файл пишется текущей версией: обёртку ключа нужно
      // запечатать заново с AD текущей версии.
      SealedBox? rewrapped;
      final variants =
          recovery ? const <SecretBytes>[] : MasterVariants.of(master);
      final VaultKey vk;
      final bool variantHit;
      try {
        (vk, variantHit) = await _unwrapAny(
          master,
          envelope,
          variants: variants,
          withKek: envelope.migrated
              ? (VaultKey kek, VaultKey vk) => rewrapped = crypto.sealKey(
                    kek,
                    vk,
                    VaultKeys.wrapPwAdOf(
                      version: VaultFormat.version,
                      kind: envelope.kind,
                      vaultId: envelope.vaultId,
                      kdf: envelope.kdf,
                      pwKind: envelope.pwKind,
                    ),
                  )
              : null,
        );
      } finally {
        for (final variant in variants) {
          variant.wipe();
        }
      }
      return _finishOpen(
        bytes,
        envelope,
        vk,
        epoch: epoch,
        seenRev: seenRev,
        confirmed: true,
        variantHit: variantHit,
        after: (_Open open) async {
          // Ввод проверен: метка внутри индекса; заодно запись
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
                open.index.migrated) {
              rethrow;
            }
          }
          if (deviceKey == null) return (code: null, recovered: false);
          if (recovery) {
            return (code: null, recovered: await _afterRecovery(open));
          }
          try {
            return (code: await _migrateToDevice(open), recovered: false);
          } on VaultFailure catch (error) {
            // Ключ устройства сейчас не создать (сбой системы) или не
            // записать файл: сейф открыт по-старому, мастер-паролем, и
            // перейдёт на защиту устройством при следующем вводе.
            if (error.code == VaultErrorCode.corrupt) rethrow;
            return (code: null, recovered: false);
          }
        },
      );
    });
  }

  /// Открыть ключом устройства (слот `dev`): без ввода, пока приложение
  /// открыто (ADR-025). Ошибки: `deviceKeyLost` (ключа нет — только код
  /// восстановления), `corrupt`, `io`, `locked`.
  Future<VaultUnlockResult> unlockDevice({int? seenRev}) => _unlockWith(
        const DeviceProof(),
        seenRev: seenRev,
        open: (VaultEnvelope envelope) =>
            _openSlot(envelope, VaultFormat.slotDevice),
      );

  /// Открыть ПИН-кодом сейфа (слот `pin`, ADR-025). Счётчик свой
  /// ([PinAttempts]): с 5-й ошибки паузы, 10-я закрывает путь по ПИН-коду
  /// (`pinLocked`, дальше — только код восстановления).
  Future<VaultUnlockResult> unlockPin(SecretBytes pin, {int? seenRev}) =>
      _unlockWith(
        PinProof(pin),
        seenRev: seenRev,
        confirmed: true,
        open: (VaultEnvelope envelope) => _openPin(envelope, pin),
      );

  /// Открыть биометрией (слот `bio`, ADR-025): система спросит отпечаток,
  /// лицо или блокировку экрана с причиной [reason]. Отмена — `bioCanceled`
  /// (не попытка); ключ сброшен системой — `bioInvalidated`, слот снят.
  Future<VaultUnlockResult> unlockBio(String reason, {int? seenRev}) =>
      _unlockWith(
        BioProof(reason),
        seenRev: seenRev,
        confirmed: true,
        open: (VaultEnvelope envelope) =>
            _openSlot(envelope, VaultFormat.slotBio, reason: reason),
      );

  Future<VaultUnlockResult> _unlockWith(
    VaultProof proof, {
    required Future<VaultKey> Function(VaultEnvelope envelope) open,
    int? seenRev,
    bool confirmed = false,
  }) {
    final epoch = _epoch;
    return _op(() async {
      await _ensureLoaded();
      _requireEnabled();
      _stillWanted(epoch);
      final current = _open;
      if (current != null) {
        await _proofCheck(current, proof);
        return VaultUnlockResult(
          rev: current.envelope.rev,
          rolledBack: false,
        );
      }
      final (bytes, envelope) = await _readEnvelope();
      final vk = await open(envelope);
      return _finishOpen(
        bytes,
        envelope,
        vk,
        epoch: epoch,
        seenRev: seenRev,
        confirmed: confirmed,
      );
    });
  }

  /// Файл хранилища и его конверт.
  Future<(Uint8List, VaultEnvelope)> _readEnvelope() async {
    final bytes = await store.readVault();
    if (bytes == null) {
      _exists = false;
      throw VaultError.io;
    }
    final envelope = VaultEnvelope.decode(bytes);
    if (envelope.kind != VaultFormat.kindVault) throw VaultError.corrupt;
    return (bytes, envelope);
  }

  /// Ключ сейфа снят: индекс, проверка согласованности, открытое состояние.
  /// [after] — запись после открытия (метка, миграция, переход на ключ
  /// устройства); без него мигрированный файл пишется текущей версией.
  Future<VaultUnlockResult> _finishOpen(
    Uint8List bytes,
    VaultEnvelope envelope,
    VaultKey vk, {
    required int epoch,
    int? seenRev,
    bool confirmed = false,
    bool variantHit = false,
    Future<({SecretBytes? code, bool recovered})> Function(_Open open)? after,
  }) async {
    final header = VaultKeys.header(envelope);
    final ring = VaultKeyRing.from(crypto, vk);
    VaultIndex? index;
    VaultKey? kFp;
    _Open? opened;
    SecretBytes? code;
    var recovered = false;
    try {
      // Пока шёл Argon2id (или системный запрос), хранилище заперли (фон,
      // выключение навыка): ключи не остаются в памяти.
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
      if (confirmed) _confirmed(open);
      if (after != null) {
        (:code, :recovered) = await after(open);
      } else if (envelope.migrated || index.migrated) {
        await _afterUnlock(open, original: bytes);
      }
      if (!identical(_open, open)) throw VaultError.locked;
      _stillWanted(epoch);
    } catch (_) {
      code?.wipe();
      final open = opened;
      if (open != null) {
        if (identical(_open, open)) _open = null;
        open.dispose();
      } else {
        ring.dispose();
        kFp?.dispose();
        index?.kFp.wipe();
      }
      rethrow;
    }
    _exists = true;
    _schedule();
    _notify(VaultSignal.changed);
    return VaultUnlockResult(
      rev: _open!.envelope.rev,
      rolledBack: seenRev != null && envelope.rev < seenRev,
      variantHit: variantHit,
      recoveryCode: code,
      recovered: recovered,
    );
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
      history: migrated
          ? _resealHistory(open, open.ring, open.envelope)
          : envelope.history,
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

  /// Проверка мастер-пароля (или кода восстановления) через общий счётчик
  /// ошибок (открытие, тренировка, обязательный ввод, смена мастер-пароля).
  Future<VaultKey> _unwrap(SecretBytes master, VaultEnvelope envelope) async =>
      (await _unwrapAny(master, envelope)).$1;

  /// Как [_unwrap], но после неверного [master] пробует [variants] в той же
  /// попытке счётчика. Второе в ответе — подошёл вариант.
  ///
  /// [withKek] получает KEK и VK до освобождения KEK (переобёртка ключа
  /// при миграции: AD обёртки до версии 3 содержит версию формата).
  ///
  /// У сейфа с кодом восстановления ввод сначала приводится к виду кода
  /// ([RecoveryCode.canonical]); не код вовсе — `wrongPassword` без
  /// попытки в счётчике (Argon2id не считается).
  Future<(VaultKey, bool)> _unwrapAny(
    SecretBytes master,
    VaultEnvelope envelope, {
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
    final canonical =
        envelope.isRecoveryKind ? RecoveryCode.canonical(master) : null;
    if (envelope.isRecoveryKind && canonical == null) {
      throw VaultError.wrongPassword;
    }
    try {
      // Попытка засчитывается до вывода ключа: убитое посреди Argon2id
      // приложение не получает бесплатную попытку. Записать не вышло —
      // не проверяем вовсе (без счётчика перебор был бы без пауз).
      await store.writeAttempts(attempts.failed(now).encode());
      final candidates = <SecretBytes>[
        canonical ?? master,
        if (canonical == null) ...variants,
      ];
      final ad = VaultKeys.wrapPwAdFor(envelope);
      for (var i = 0; i < candidates.length; i++) {
        final kek =
            await crypto.derive(candidates[i], envelope.kdf.salt, params);
        final VaultKey? vk;
        try {
          vk = crypto.openKey(kek, envelope.wrapPw, ad);
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
    } finally {
      canonical?.wipe();
    }
  }

  /// Верен ли мастер-пароль открытого хранилища (тренировка, обязательный
  /// ввод). Тот же счётчик ошибок и паузы, что у открытия. Верный ввод
  /// обновляет метку `last_typed`.
  Future<bool> verifyMaster(SecretBytes master) =>
      _op(() => _verifyMaster(master));

  Future<bool> _verifyMaster(SecretBytes master) => _guard(() async {
        final open = _requireOpen();
        try {
          final vk = await _unwrap(master, open.envelope);
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

  // ------------------------------------- защита устройством (ADR-025)

  /// Ключ индекса: подтвердил ли человек, что сохранил код
  /// восстановления («Я сохранил»).
  static const String _rcConfirmedKey = 'rc_ok';

  /// Чем открыт или открывается сейф — для экрана замка и настроек.
  /// Заперто — по конверту на диске (без ключей); файла нет — `null`.
  Future<VaultLockInfo?> lockInfo() => _serial(
        () => _guard(() async {
          await _ensureLoaded();
          final open = _open;
          if (open != null) return VaultLockInfo.of(open.envelope);
          final bytes = await store.readVault();
          if (bytes == null) return null;
          final envelope = VaultEnvelope.decode(bytes);
          if (envelope.kind != VaultFormat.kindVault) throw VaultError.corrupt;
          return VaultLockInfo.of(envelope);
        }),
      );

  /// Защита открытого сейфа (или `null`, пока заперто).
  VaultLockInfo? get protection {
    final open = _open;
    return open == null ? null : VaultLockInfo.of(open.envelope);
  }

  /// Сейф открыт и защищён устройством и кодом восстановления.
  bool get isProtected => _open?.envelope.isRecoveryKind ?? false;

  /// Код восстановления открытого сейфа подтверждён («Я сохранил»). У
  /// сейфа с мастер-паролем — всегда `true`.
  bool get recoveryConfirmed {
    final open = _open;
    if (open == null || !open.envelope.isRecoveryKind) return true;
    return open.index.master[_rcConfirmedKey] != false;
  }

  /// Человек подтвердил, что сохранил код восстановления.
  Future<void> confirmRecovery() => _op(() async {
        final open = _requireOpen();
        if (open.index.master[_rcConfirmedKey] == true) return;
        await _commit(
          open,
          entries: open.index.entries,
          secrets: open.envelope.secrets,
          master: <String, Object?>{
            ...open.index.master,
            _rcConfirmedKey: true,
          },
        );
        _notify(VaultSignal.changed);
      });

  /// Счётчик неверных ПИН-кодов сейфа (для «Осталось попыток»).
  Future<PinAttempts> pinAttempts() => _guard(() async {
        final alias = (_open?.envelope ??
                await () async {
                  final bytes = await store.readVault();
                  return bytes == null ? null : VaultEnvelope.decode(bytes);
                }())
            ?.slots[VaultFormat.slotPin]
            ?.alias;
        if (alias == null) return const PinAttempts();
        final stored = PinAttempts.decode(await store.readPinAttempts());
        return stored.of(alias).at(clock.now());
      });

  /// Новый код восстановления (ADR-025): после подтверждения [proof] —
  /// НОВЫЙ ключ сейфа (все записи перешифрованы), обёрнутый ключом из
  /// нового кода; слоты устройства запечатаны заново новыми ключами
  /// устройства, прежние удалены. Так прежний код не откроет ни этот файл,
  /// ни его старые копии вместе с новыми данными (`vault.prev` и
  /// `vault.v<N>.bak` перезаписаны). Слот `pin` переделывается ПИН-кодом из
  /// [proof] ([PinProof]), слот `bio` — ещё одним системным запросом с
  /// причиной [reason].
  ///
  /// Если ключ сейфа сменить нельзя (ПИН-код включён, а подтвердили не
  /// им), ключ сейфа прежний и лишь заново обёрнут новым кодом: старая
  /// копия файла вместе с прежним кодом тогда даёт доступ — поэтому
  /// [RecoveryRegen.rotated] `false`, приложение говорит об этом.
  /// Копии, выгруженные раньше, открываются тем, чем были закрыты.
  /// Код в ответе — для показа один раз; вызывающий затирает.
  Future<RecoveryRegen> regenerateRecovery(
    VaultProof proof, {
    String reason = 'Новый код восстановления',
  }) =>
      _op(() async {
        final open = _requireOpen();
        if (!open.envelope.isRecoveryKind) {
          throw StateError('сейф не защищён кодом восстановления');
        }
        await _proofCheck(open, proof);
        final kdf = VaultKdfParams.checkLoaded(
          open.envelope.kdf,
          allowTesting: allowTestingKdf,
        );
        final names = open.envelope.slots.keys.toSet();
        final pin = proof is PinProof ? proof.pin : null;
        final canRotate = deviceKey != null &&
            !open.envelope.migrated &&
            (!names.contains(VaultFormat.slotPin) || pin != null);
        if (canRotate) {
          final code = await _withNewCode(
            (SecretBytes canonical) => _rekey(
              open,
              canonical,
              kdf,
              pwKind: VaultFormat.pwRecovery,
              remake: names,
              pin: pin,
              reason: proof is BioProof ? proof.reason : reason,
              newCode: true,
            ),
          );
          return RecoveryRegen(code, rotated: true);
        }
        final code = await _withNewCode((SecretBytes canonical) async {
          final salt = crypto.bytes(VaultFormat.saltBytes);
          final record = KdfRecord(ops: kdf.ops, mem: kdf.mem, salt: salt);
          final kek = await crypto.derive(canonical, salt, kdf);
          final SealedBox wrap;
          try {
            wrap = crypto.sealKey(
              kek,
              open.ring.vk,
              VaultKeys.wrapPwAdOf(
                version: VaultFormat.version,
                kind: VaultFormat.kindVault,
                vaultId: open.envelope.vaultId,
                kdf: record,
                pwKind: VaultFormat.pwRecovery,
              ),
            );
          } finally {
            kek.dispose();
          }
          _alive(open);
          await _rewrite(
            open,
            kdf: record,
            wrapPw: wrap,
            master: <String, Object?>{
              ...open.index.master,
              _rcConfirmedKey: false,
            },
          );
        });
        return RecoveryRegen(code, rotated: false);
      });

  /// Можно ли включить ПИН-код сейфа на этом устройстве.
  bool get pinAllowed => deviceKey?.pinAllowed ?? false;

  /// Включить ПИН-код сейфа (ADR-025): слот `pin` (Argon2id от ПИН-кода и
  /// ключ устройства вместе) вместо `dev`. Дальше сейф без ПИН-кода (или
  /// биометрии, или кода восстановления) не открыть. Слабый ПИН-код —
  /// `ArgumentError` ([VaultPin.problem] проверяет приложение заранее).
  Future<void> enablePin(SecretBytes pin) => _op(() async {
        final open = _requireOpen();
        _requireProtected(open);
        if (!pinAllowed) throw StateError('ПИН-код здесь недоступен');
        if (open.envelope.slots.containsKey(VaultFormat.slotPin)) {
          throw StateError('ПИН-код уже включён');
        }
        if (VaultPin.problem(pin) != null) {
          throw ArgumentError('ПИН-код не годится');
        }
        await _replaceSlot(open, VaultFormat.slotPin, pin: pin);
        _rememberPin(pin);
      });

  /// Сменить ПИН-код: верный [current] (счётчик ПИН-кода), новый ключ
  /// устройства и новый слот; прежний ключ удаляется — прежний ПИН-код не
  /// откроет и старые копии файла.
  Future<void> changePin(SecretBytes current, SecretBytes next) =>
      _op(() async {
        final open = _requireOpen();
        _requireProtected(open);
        if (VaultPin.problem(next) != null) {
          throw ArgumentError('ПИН-код не годится');
        }
        (await _openPin(open.envelope, current)).dispose();
        _alive(open);
        _confirmed(open);
        await _replaceSlot(open, VaultFormat.slotPin, pin: next);
        _rememberPin(next);
      });

  /// Выключить ПИН-код (ослабление защиты): после подтверждения [proof]
  /// слот `pin` снимается; без биометрии сейф снова открывается ключом
  /// устройства.
  Future<void> disablePin(VaultProof proof) => _op(() async {
        final open = _requireOpen();
        _requireProtected(open);
        await _proofCheck(open, proof);
        await _dropSlot(open, VaultFormat.slotPin);
        _forgetPin();
      });

  /// Можно ли привязать сейф к биометрии на этом устройстве.
  Future<bool> bioAvailable() async {
    final key = deviceKey;
    if (key == null) return false;
    try {
      return await key.bioAvailable();
    } on Object {
      return false;
    }
  }

  /// Включить вход в сейф по биометрии (ADR-025): ключ устройства с
  /// проверкой личности, слот `bio` вместо `dev`. Система сразу спросит
  /// отпечаток, лицо или блокировку экрана ([reason]). Отмена —
  /// `bioCanceled`, ничего не меняется.
  Future<void> enableBio(String reason) => _op(() async {
        final open = _requireOpen();
        _requireProtected(open);
        if (open.envelope.slots.containsKey(VaultFormat.slotBio)) {
          throw StateError('биометрия уже включена');
        }
        await _replaceSlot(open, VaultFormat.slotBio, reason: reason);
      });

  /// Выключить вход по биометрии (ослабление защиты): после [proof].
  Future<void> disableBio(VaultProof proof) => _op(() async {
        final open = _requireOpen();
        _requireProtected(open);
        await _proofCheck(open, proof);
        await _dropSlot(open, VaultFormat.slotBio);
      });

  /// Проверить подтверждение [proof] открытого сейфа (переспрос для
  /// важных, ослабление настроек). `false` — не подошло; пауза и закрытый
  /// путь по ПИН-коду — ошибки ([VaultRateLimited], `pinLocked`).
  Future<bool> verify(VaultProof proof) => _op(() async {
        final open = _requireOpen();
        try {
          await _proofCheck(open, proof);
        } on VaultFailure catch (error) {
          if (error.code == VaultErrorCode.wrongPassword) return false;
          rethrow;
        }
        touch();
        return true;
      });

  /// Смена мастер-пароля и «Перешифровать всё» — только у сейфа с
  /// мастер-паролем: у защищённого устройством новый ключ сейфа снял бы
  /// слоты ПИН-кода и биометрии.
  void _requireMaster(_Open open) {
    if (open.envelope.isRecoveryKind) {
      throw StateError('у сейфа нет мастер-пароля');
    }
  }

  /// Ключ отпечатка ПИН-кода — случайный, только в памяти этого запуска.
  VaultKey? _pinKey;
  Uint8List? _pinPrint;

  Uint8List _pinHash(SecretBytes pin) {
    final key = _pinKey ??= crypto.randomKey();
    final bytes = pin.unsafeBytes;
    final message = Uint8List(bytes.length + 4)
      ..setRange(0, 4, ascii.encode('pin|'))
      ..setRange(4, 4 + bytes.length, bytes);
    try {
      return crypto.keyedHash(key, message);
    } finally {
      message.fillRange(0, message.length, 0);
    }
  }

  /// Верный ПИН-код: запомнить отпечаток для `SecretGuard` (ПИН-код,
  /// написанный в чат, скрывается).
  void _rememberPin(SecretBytes pin) {
    _forgetPin();
    _pinPrint = _pinHash(pin);
  }

  void _forgetPin() {
    final print = _pinPrint;
    if (print != null) print.fillRange(0, print.length, 0);
    _pinPrint = null;
    for (final seen in _pinSeen) {
      seen.fillRange(0, seen.length, 0);
    }
    _pinSeen.clear();
  }

  /// Сколько РАЗНЫХ наборов из 6 цифр сверить с ПИН-кодом за один верный
  /// ввод. Иначе чат — оракул без счётчика: вставь в него миллион
  /// вариантов и смотри, какой скрыт (ADR-025). Повтор того же набора
  /// (одно сообщение проходит фильтр несколько раз) бюджет не тратит.
  /// Бюджет кончился — отпечаток забыт, ПИН-код в чате больше не
  /// распознаётся до следующего верного ввода (защита только слабеет,
  /// подсказки не даёт).
  static const int pinGuardBudget = 5;

  /// Отпечатки уже сверенных наборов (тем же ключом этого запуска).
  final List<Uint8List> _pinSeen = <Uint8List>[];

  bool _pinMatches(String token) {
    final print = _pinPrint;
    if (print == null || token.length != VaultPin.length) return false;
    if (!RegExp(r'^[0-9]{6}$').hasMatch(token)) return false;
    final candidate = SecretBytes.fromText(token);
    try {
      final hash = _pinHash(candidate);
      if (crypto.equal(hash, print)) {
        hash.fillRange(0, hash.length, 0);
        return true;
      }
      if (_pinSeen.any((seen) => crypto.equal(seen, hash))) {
        hash.fillRange(0, hash.length, 0);
        return false;
      }
      _pinSeen.add(hash);
      if (_pinSeen.length >= pinGuardBudget) _forgetPin();
      return false;
    } catch (_) {
      return false;
    } finally {
      candidate.wipe();
    }
  }

  void _requireProtected(_Open open) {
    if (!open.envelope.isRecoveryKind || deviceKey == null) {
      throw StateError('сейф не защищён устройством');
    }
  }

  /// Мастер-пароль из старого API или подтверждение.
  static VaultProof _proofOf(SecretBytes? master, VaultProof? proof) {
    if (proof != null) return proof;
    if (master != null) return SecretProof(master);
    throw ArgumentError('нужно подтверждение');
  }

  /// Проверка подтверждения [proof]: мастер-пароль или код — общий счётчик
  /// (D25); ПИН-код — свой счётчик; биометрия — системный запрос;
  /// устройство — только у сейфа со слотом `dev`. Верно — окно свежего
  /// подтверждения ([isGuarded]) начинается заново.
  Future<void> _proofCheck(_Open open, VaultProof proof) async {
    final envelope = open.envelope;
    switch (proof) {
      case SecretProof(:final secret):
        (await _unwrap(secret, envelope)).dispose();
      case PinProof(:final pin):
        (await _openPin(envelope, pin)).dispose();
      case BioProof(:final reason):
        (await _openSlot(envelope, VaultFormat.slotBio, reason: reason))
            .dispose();
      case DeviceProof():
        if (!envelope.isRecoveryKind ||
            !envelope.slots.containsKey(VaultFormat.slotDevice)) {
          throw ArgumentError('нужен ПИН-код, биометрия или код');
        }
    }
    _alive(open);
    _confirmed(open);
  }

  /// Слот [name] (`pin` или `bio`) — новый ключ устройства и новая
  /// обёртка; `dev` снимается (иначе ПИН-код и биометрия ничего бы не
  /// защищали). Прежние ключи слота [name] и `dev` удаляются после
  /// записи.
  Future<void> _replaceSlot(
    _Open open,
    String name, {
    SecretBytes? pin,
    String? reason,
  }) async {
    final envelope = open.envelope;
    KdfRecord? pinKdf;
    if (pin != null) {
      final kdf = VaultKdfParams.checkLoaded(
        envelope.kdf,
        allowTesting: allowTestingKdf,
      );
      pinKdf = KdfRecord(
        ops: kdf.ops,
        mem: kdf.mem,
        salt: crypto.bytes(VaultFormat.saltBytes),
      );
    }
    final slot = await _makeSlot(
      name,
      open.ring.vk,
      envelope.vaultId,
      pin: pin,
      pinKdf: pinKdf,
      reason: reason,
    );
    final old = <String>[
      for (final key in <String>[name, VaultFormat.slotDevice])
        if (envelope.slots[key] case final VaultSlot s) s.alias,
    ];
    try {
      _alive(open);
      await _rewrite(
        open,
        slots: <String, VaultSlot>{
          for (final MapEntry(:key, :value) in envelope.slots.entries)
            if (key != VaultFormat.slotDevice && key != name) key: value,
          name: slot,
        },
      );
    } catch (_) {
      await _forget(<String>[slot.alias]);
      rethrow;
    }
    await _forget(old);
    if (name == VaultFormat.slotPin) await _resetPinAttempts(slot.alias);
    touch();
    _notify(VaultSignal.changed);
  }

  /// Снять слот [name]; не осталось ни ПИН-кода, ни биометрии — снова
  /// `dev` (новый ключ устройства).
  Future<void> _dropSlot(_Open open, String name) async {
    final envelope = open.envelope;
    final gone = envelope.slots[name];
    if (gone == null) return;
    final rest = <String, VaultSlot>{
      for (final MapEntry(:key, :value) in envelope.slots.entries)
        if (key != name) key: value,
    };
    VaultSlot? device;
    if (!rest.containsKey(VaultFormat.slotPin) &&
        !rest.containsKey(VaultFormat.slotBio) &&
        !rest.containsKey(VaultFormat.slotDevice)) {
      device = await _makeSlot(
        VaultFormat.slotDevice,
        open.ring.vk,
        envelope.vaultId,
      );
      rest[VaultFormat.slotDevice] = device;
    }
    try {
      _alive(open);
      await _rewrite(open, slots: rest);
    } catch (_) {
      if (device != null) await _forget(<String>[device.alias]);
      rethrow;
    }
    await _forget(<String>[gone.alias]);
    touch();
    _notify(VaultSignal.changed);
  }

  /// Новая версия файла без старых копий: `vault.prev` и `vault.v<N>.bak`
  /// перезаписываются ею же (снятый слот, прежний код не живут в копиях).
  Future<void> _rewrite(
    _Open open, {
    Map<String, VaultSlot>? slots,
    KdfRecord? kdf,
    SealedBox? wrapPw,
    Map<String, Object?>? master,
  }) async {
    final written = await _commit(
      open,
      entries: open.index.entries,
      secrets: open.envelope.secrets,
      slots: slots,
      kdf: kdf,
      wrapPw: wrapPw,
      master: master,
      replacePrevious: true,
    );
    // Основной файл и .prev уже новые: сбой копий не отменяет операцию
    // (иначе новый код восстановления, уже запечатавший файл, не показали
    // бы). Старая копия перезапишется при следующей записи.
    try {
      for (final version in await store.backupVersions()) {
        await store.writeBackup(version, written);
      }
    } on Object {
      // См. выше.
    }
  }

  /// Сейф с мастер-паролем → защита устройством (ADR-025): новый ключ
  /// сейфа (старые копии файла, закрытые мастер-паролем, не дают ключа к
  /// новым данным), слот `dev`, новый код восстановления — он в ответе.
  /// Мастер-пароль больше не используется.
  Future<SecretBytes> _migrateToDevice(_Open open) => _withNewCode(
        (SecretBytes canonical) async {
          final kdf = VaultKdfParams.checkLoaded(
            open.envelope.kdf,
            allowTesting: allowTestingKdf,
          );
          await _rekey(
            open,
            canonical,
            kdf,
            pwKind: VaultFormat.pwRecovery,
            withDevice: true,
          );
        },
      );

  /// Открыли кодом восстановления: ключ устройства — заново (слот `dev`),
  /// ПИН-код и биометрия сняты, их ключи удалены, счётчик ПИН-кода
  /// сброшен. `true` — всё записано.
  Future<bool> _afterRecovery(_Open open) async {
    final envelope = open.envelope;
    final old = <String>[for (final slot in envelope.slots.values) slot.alias];
    final VaultSlot device;
    try {
      device = await _makeSlot(
        VaultFormat.slotDevice,
        open.ring.vk,
        envelope.vaultId,
      );
    } on VaultError {
      // Ключ устройства не создать (сбой системы): сейф открыт, следующий
      // вход — снова кодом.
      return false;
    }
    try {
      _alive(open);
      await _rewrite(
        open,
        slots: <String, VaultSlot>{VaultFormat.slotDevice: device},
      );
    } on VaultFailure catch (error) {
      await _forget(<String>[device.alias]);
      if (error.code == VaultErrorCode.io) return false;
      rethrow;
    }
    await _forget(old);
    _forgetPin();
    try {
      await store.writePinAttempts(const PinAttempts().encode());
    } on Object {
      // Счётчик прежнего ключа ни на что не влияет.
    }
    return true;
  }

  Future<void> _resetPinAttempts(String alias) async {
    try {
      await store.writePinAttempts(PinAttempts(alias: alias).encode());
    } on Object {
      // Не сбросился — лишняя ошибка в счётчике, не дыра.
    }
  }

  /// Ключ сейфа из слота ПИН-кода. Попытка засчитывается до Argon2id;
  /// 10-я ошибка закрывает путь по ПИН-коду: ключ устройства удаляется,
  /// слот снимается — дальше только код восстановления (`pinLocked`).
  Future<VaultKey> _openPin(VaultEnvelope envelope, SecretBytes pin) async {
    final slot = envelope.slots[VaultFormat.slotPin];
    if (slot == null) throw VaultError.pinLocked;
    // Не 6 цифр — не ПИН-код вовсе: попытку не тратим.
    if (!VaultPin.isWellFormed(pin)) throw VaultError.wrongPassword;
    final now = clock.now();
    final stored = PinAttempts.decode(await store.readPinAttempts());
    final attempts = stored.of(slot.alias).at(now);
    if (!identical(attempts, stored)) {
      await store.writePinAttempts(attempts.encode());
    }
    if (attempts.closed) {
      await _closePin(envelope);
      throw VaultError.pinLocked;
    }
    final until = attempts.blockedUntil(now);
    if (until != null) throw VaultRateLimited(until);
    await store.writePinAttempts(attempts.failed(now).encode());
    try {
      final vk = await _openSlot(envelope, VaultFormat.slotPin, pin: pin);
      await _resetPinAttempts(slot.alias);
      _rememberPin(pin);
      return vk;
    } on VaultFailure catch (error) {
      if (error.code != VaultErrorCode.wrongPassword) {
        // Не ПИН-код виноват (ключа нет, сбой системы): попытка не в счёт.
        try {
          await store.writePinAttempts(attempts.encode());
        } on Object {
          // Лишняя ошибка в счётчике — не дыра.
        }
        rethrow;
      }
      final after = attempts.failed(clock.now());
      await store.writePinAttempts(after.encode());
      if (after.closed) {
        await _closePin(envelope);
        throw VaultError.pinLocked;
      }
      throw VaultError.wrongPassword;
    }
  }

  /// Путь по ПИН-коду закрыт: ключ устройства ПИН-кода удаляется (это и
  /// есть замок — старые копии файла его тоже теряют), слот снимается из
  /// файла.
  Future<void> _closePin(VaultEnvelope envelope) async {
    final slot = envelope.slots[VaultFormat.slotPin];
    if (slot == null) return;
    _forgetPin();
    await _forget(<String>[slot.alias]);
    await _dropSlotsLocked(<String>{VaultFormat.slotPin}, envelope);
  }

  /// Убрать мёртвые слоты [names] из файла без ключей сейфа: меняется
  /// только список слотов конверта (шифротексты те же, `rev` тот же).
  /// Не вышло — не беда: ключ слота уже удалён.
  ///
  /// [keepCopies]: `vault.prev` и `.bak` не трогать — слот снят только из
  /// основного файла. Так при «ключ потерян» (а это могла быть и ошибка
  /// классификации) прежние версии со слотом остаются для отката.
  Future<void> _dropSlotsLocked(
    Set<String> names,
    VaultEnvelope envelope, {
    bool keepCopies = false,
  }) async {
    try {
      final open = _open;
      final base = open != null && open.envelope.vaultId == envelope.vaultId
          ? open.envelope
          : envelope;
      // Мигрированный конверт так не переписать: он записался бы новой
      // версией со старыми AD.
      if (base.migrated) return;
      final next = base.withSlots(<String, VaultSlot>{
        for (final MapEntry(:key, :value) in base.slots.entries)
          if (!names.contains(key)) key: value,
      });
      final bytes = next.encode();
      await store.writeVault(bytes, replacePrevious: !keepCopies);
      if (!keepCopies) {
        for (final version in await store.backupVersions()) {
          await store.writeBackup(version, bytes);
        }
      }
      if (open != null && identical(open.envelope, base)) open.envelope = next;
    } on Object {
      // Ключ слота уже удалён: слот в файле ничего не открывает.
    }
  }

  /// Ключ сейфа из слота [name]. Ключ устройства потерян или сброшен
  /// системой — слот снимается из файла, ошибка выходит наружу
  /// (`deviceKeyLost`, `bioInvalidated`).
  Future<VaultKey> _openSlot(
    VaultEnvelope envelope,
    String name, {
    SecretBytes? pin,
    String? reason,
  }) async {
    final slot = envelope.slots[name];
    if (slot == null) throw ArgumentError('у сейфа нет такого слота');
    final key = deviceKey;
    // Файл перенесли на другое устройство или систему: здесь этого ключа
    // нет и не будет.
    if (key == null || key.kind != slot.kind) throw VaultError.deviceKeyLost;
    final VaultKey kek;
    try {
      kek = await _slotKek(
        name,
        slot.alias,
        envelope.vaultId,
        pin: pin,
        kdf: slot.kdf,
        reason: reason,
      );
    } on VaultFailure catch (error) {
      if (error.code == VaultErrorCode.deviceKeyLost) {
        // Ключа нет — удалять нечего; а если «потерян» — ошибочная
        // классификация сбоя, удаление сделало бы её необратимой. Слот
        // снимается только из основного файла, копии остаются.
        await _dropSlotsLocked(<String>{name}, envelope, keepCopies: true);
      } else if (error.code == VaultErrorCode.bioInvalidated) {
        // Ключ сброшен системой и больше ничего не посчитает.
        await _forget(<String>[slot.alias]);
        await _dropSlotsLocked(<String>{name}, envelope);
      }
      rethrow;
    }
    final VaultKey? vk;
    try {
      vk = crypto.openKey(
        kek,
        slot.box,
        VaultKeys.slotAd(
          slot: name,
          vaultId: envelope.vaultId,
          kind: slot.kind,
          alias: slot.alias,
          kdf: slot.kdf,
        ),
      );
    } finally {
      kek.dispose();
    }
    if (vk == null) {
      // Неверный ПИН-код даёт другой ответ ключа устройства; у слотов без
      // ввода это подмена файла.
      throw name == VaultFormat.slotPin
          ? VaultError.wrongPassword
          : VaultError.corrupt;
    }
    return vk;
  }

  /// KEK слота: `BLAKE2b(key = HMAC_устройства(alias, сообщение), метка)`.
  /// У ПИН-кода в сообщении — Argon2id от ПИН-кода (перебор возможен только
  /// на этом устройстве, с ключом в его защищённом хранилище).
  Future<VaultKey> _slotKek(
    String name,
    String alias,
    String vaultId, {
    SecretBytes? pin,
    KdfRecord? kdf,
    String? reason,
  }) async {
    final key = deviceKey;
    if (key == null) throw VaultError.deviceKeyLost;
    SecretBytes? input;
    if (name == VaultFormat.slotPin) {
      if (pin == null || kdf == null) throw ArgumentError('нужен ПИН-код');
      final params =
          VaultKdfParams.checkLoaded(kdf, allowTesting: allowTestingKdf);
      final derived = await crypto.derive(pin, kdf.salt, params);
      try {
        input = crypto.exportKey(derived);
      } finally {
        derived.dispose();
      }
    }
    final message = VaultKeys.slotMessage(
      name,
      vaultId,
      input?.unsafeBytes ?? Uint8List(0),
    );
    input?.wipe();
    final Uint8List mac;
    try {
      mac = await key.mac(alias, message, reason: reason);
    } on DeviceKeyException catch (error) {
      throw _deviceError(error.failure);
    } finally {
      message.fillRange(0, message.length, 0);
    }
    if (mac.length != VaultFormat.keyBytes) {
      mac.fillRange(0, mac.length, 0);
      throw VaultError.io;
    }
    final macKey = crypto.importKey(SecretBytes.adopt(mac));
    try {
      return crypto.importKey(
        SecretBytes.adopt(
          crypto.keyedHash(macKey, VaultKeys.slotLabel(name)),
        ),
      );
    } finally {
      macKey.dispose();
    }
  }

  /// Новый слот [name] для ключа сейфа [vk]: новый ключ устройства (у
  /// `bio` — с проверкой личности) и обёртка.
  Future<VaultSlot> _makeSlot(
    String name,
    VaultKey vk,
    String vaultId, {
    SecretBytes? pin,
    KdfRecord? pinKdf,
    String? reason,
  }) async {
    final key = deviceKey;
    if (key == null) throw StateError('нет ключа устройства');
    final String alias;
    try {
      alias = await key.create(userAuth: name == VaultFormat.slotBio);
    } on DeviceKeyException catch (error) {
      throw _deviceError(error.failure);
    }
    try {
      final kek = await _slotKek(
        name,
        alias,
        vaultId,
        pin: pin,
        kdf: pinKdf,
        reason: reason,
      );
      try {
        return VaultSlot(
          kind: key.kind,
          alias: alias,
          kdf: pinKdf,
          box: crypto.sealKey(
            kek,
            vk,
            VaultKeys.slotAd(
              slot: name,
              vaultId: vaultId,
              kind: key.kind,
              alias: alias,
              kdf: pinKdf,
            ),
          ),
        );
      } finally {
        kek.dispose();
      }
    } catch (_) {
      await _forget(<String>[alias]);
      rethrow;
    }
  }

  /// Удалить ключи устройства (ошибки не мешают: ключ без слота ничего не
  /// открывает).
  Future<void> _forget(Iterable<String> aliases) async {
    final key = deviceKey;
    if (key == null) return;
    for (final alias in aliases) {
      try {
        await key.delete(alias);
      } on Object {
        // Не удалился — останется ключом без слота.
      }
    }
  }

  static VaultError _deviceError(DeviceKeyFailure failure) => switch (failure) {
        DeviceKeyFailure.lost => VaultError.deviceKeyLost,
        DeviceKeyFailure.invalidated =>
          const VaultFailure(VaultErrorCode.bioInvalidated),
        DeviceKeyFailure.canceled =>
          const VaultFailure(VaultErrorCode.bioCanceled),
        DeviceKeyFailure.lockout =>
          const VaultFailure(VaultErrorCode.bioLockedOut),
        DeviceKeyFailure.unavailable => VaultError.io,
      };

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

  /// Пора ввести мастер-пароль (раз в 72 ч по умолчанию). У сейфа,
  /// защищённого устройством (ADR-025), мастер-пароля нет — никогда.
  bool get masterDue {
    if (isProtected) return false;
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
    VaultProof? proof,
  }) =>
      updateEntry(
        id,
        service: service,
        login: login,
        hint: hint,
        urls: urls,
        important: important,
        master: master,
        proof: proof,
      );

  /// Правка записи одной операцией (редактор): поля, новый пароль
  /// [password] и новая заметка [note] проверяются один раз и ложатся
  /// одной записью файла — либо всё, либо ничего. Окно подтверждения
  /// ([confirmWindow]) не может истечь между частями сохранения.
  ///
  /// Новый пароль: прежний отпечаток уходит в `fp_old` (до 5), `srev`
  /// растёт, `changed = now`. Прежние пароль и заметка не живут и в
  /// `.prev` (D7) — кроме включённой хронологии паролей (ADR-015): тогда
  /// прежний пароль ложится в хронологию записи зашифрованным.
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
    VaultProof? proof,
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
          await _proofCheck(open, _proofOf(master, proof));
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
        var history = open.envelope.history;
        try {
          if (password != null) {
            final fp = VaultKeys.fingerprint(crypto, open.kFp, password);
            if (VaultPrefs.passwordHistory.of(open.index.prefs)) {
              final boxes = <String, SealedBox>{...history};
              updated = updated.copyWith(
                history: _mergeHistory(
                  ring: open.ring,
                  envelope: open.envelope,
                  entryId: id,
                  kFp: open.kFp,
                  currentFp: fp,
                  existing: _historyPrints(open, entry),
                  incoming: <ImportHistory>[
                    ImportHistory(
                      password: current!.password,
                      from: entry.changed,
                      to: now,
                      src: entry.dateSource,
                    ),
                  ],
                  boxes: boxes,
                ),
              );
              history = boxes;
            } else if (entry.history.isNotEmpty) {
              // Хронология выключена («Оставить»): новые прежние пароли не
              // копятся, но новый пароль, совпавший с оставленным
              // элементом, из хронологии убирается — текущий пароль не
              // показывается как прежний.
              final boxes = <String, SealedBox>{...history};
              updated = updated.copyWith(
                history: _mergeHistory(
                  ring: open.ring,
                  envelope: open.envelope,
                  entryId: id,
                  kFp: open.kFp,
                  currentFp: fp,
                  existing: _historyPrints(open, entry),
                  boxes: boxes,
                ),
              );
              history = boxes;
            }
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
            history: history,
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
        final entry = _entry(open, id);
        if (isGuarded(entry)) {
          throw StateError('важная запись — после мастер-пароля');
        }
        final gone = <String>{for (final h in entry.history) h.id};
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
          history: <String, SealedBox>{
            for (final MapEntry(:key, :value) in open.envelope.history.entries)
              if (!gone.contains(key)) key: value,
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

  // ------------------------------------- хронология паролей (ADR-015)

  /// Включена ли хронология паролей (опция в `prefs` индекса).
  bool get historyEnabled => VaultPrefs.passwordHistory.of(prefs);

  /// Сколько прежних паролей хранится во всём хранилище.
  int get historyCount {
    var n = 0;
    for (final e in entries) {
      n += e.history.length;
    }
    return n;
  }

  /// Прежний пароль [historyId] записи [id]. Только для экрана записи в
  /// `lib/app` (через `VaultFacade` недоступно; в чат не выходит).
  /// Охраняемую важную запись ([isGuarded]) — только после мастер-пароля
  /// (`StateError`). Вызывающий затирает результат.
  Future<SecretBytes> readHistoryPassword(String id, String historyId) =>
      _guard(() async {
        final open = _requireOpen();
        final entry = _entry(open, id);
        if (isGuarded(entry)) {
          throw StateError('важная запись — после мастер-пароля');
        }
        if (!entry.history.any((HistoryMeta h) => h.id == historyId)) {
          throw ArgumentError('нет такого прежнего пароля');
        }
        final password = _openHistory(open, open.ring, entry, historyId);
        touch();
        return password;
      });

  /// Удалить прежний пароль [historyId] записи [id] (например, опечатку).
  /// Гарантия D7 для него восстанавливается: шифротекст, его отпечаток в
  /// `fp_old` и он сам в `vault.prev` и `vault.v<N>.bak` исчезают. Вернуть
  /// можно только из резервной копии. Охраняемую важную запись — только
  /// после мастер-пароля (`StateError`).
  Future<void> deleteHistoryItem(String id, String historyId) =>
      _dropHistory(<String>{id}, only: historyId);

  /// Очистить хронологию записи [id] (как [deleteHistoryItem] для всех её
  /// прежних паролей, одной записью файла).
  Future<void> clearHistory(String id) => _dropHistory(<String>{id});

  /// Удалить прежние пароли всех записей (выключение опции с «Удалить»).
  /// Одна запись файла; `.prev` и `.bak` перезаписываются.
  Future<void> purgeHistory() => _op(() async {
        final open = _requireOpen();
        await _dropHistoryIn(
          open,
          <String>{
            for (final e in open.index.entries)
              if (e.history.isNotEmpty) e.id,
          },
          guard: false,
        );
      });

  Future<void> _dropHistory(Set<String> ids, {String? only}) =>
      _op(() => _dropHistoryIn(_requireOpen(), ids, only: only));

  Future<void> _dropHistoryIn(
    _Open open,
    Set<String> ids, {
    String? only,
    bool guard = true,
  }) async {
    final boxes = <String, SealedBox>{...open.envelope.history};
    final updated = <String, VaultEntry>{};
    for (final id in ids) {
      final entry = _entry(open, id);
      if (guard && isGuarded(entry)) {
        throw StateError('важная запись — после мастер-пароля');
      }
      final drop = <HistoryMeta>[
        for (final h in entry.history)
          if (only == null || h.id == only) h,
      ];
      if (only != null && drop.isEmpty) {
        throw ArgumentError('нет такого прежнего пароля');
      }
      if (drop.isEmpty) continue;
      // Отпечатки удаляемых паролей уходят и из `fp_old`: иначе от
      // опечатки остался бы след («это прежний пароль»).
      final prints = <Uint8List>[];
      for (final h in drop) {
        final old = _openHistory(open, open.ring, entry, h.id);
        try {
          prints.add(VaultKeys.fingerprint(crypto, open.kFp, old));
        } finally {
          old.wipe();
        }
        boxes.remove(h.id);
      }
      final fpOld = <Uint8List>[
        for (final f in entry.fpOld)
          if (!prints.any((Uint8List p) => crypto.equal(p, f))) f,
      ];
      final returned = entry.flags.contains(EntryFlags.returnedOld) &&
          fpOld.any((Uint8List f) => crypto.equal(f, entry.fp));
      updated[id] = entry.copyWith(
        history: List<HistoryMeta>.unmodifiable(<HistoryMeta>[
          for (final h in entry.history)
            if (!drop.contains(h)) h,
        ]),
        fpOld: fpOld,
        flags: <String>[
          for (final f in entry.flags)
            if (f != EntryFlags.returnedOld) f,
          if (returned) EntryFlags.returnedOld,
        ],
      );
    }
    if (updated.isEmpty) return;
    _alive(open);
    final written = await _commit(
      open,
      entries: <VaultEntry>[
        for (final e in open.index.entries) updated[e.id] ?? e,
      ],
      secrets: open.envelope.secrets,
      history: boxes,
      replacePrevious: true,
    );
    // Удалённый пароль не живёт и в копиях до миграции.
    for (final version in await store.backupVersions()) {
      await store.writeBackup(version, written);
    }
    touch();
    _notify(VaultSignal.changed);
  }

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
  ///
  /// Отдельный токен из 6 цифр, равный ПИН-коду сейфа, верно введённому в
  /// этом запуске, — тоже `true` (и при запертом сейфе, ADR-025).
  bool matchesKnownSecret(String token) {
    if (_pinMatches(token)) return true;
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
    VaultProof? proof,
  }) =>
      _op(() async {
        final open = _requireOpen();
        VaultPrefs.check(changes);
        if (VaultPrefs.weakens(open.index.prefs, changes)) {
          await _proofCheck(open, _proofOf(master, proof));
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
  /// переписывается (старых паролей нет и там). С включённой хронологией
  /// паролей (ADR-015) прежний пароль и хронология из копии ложатся в
  /// хронологию записи (без повторов, до [VaultEntry.maxHistory]);
  /// с выключенной — хронология копии отбрасывается.
  Future<ImportResult> importItems(
    List<ImportDecision> decisions, {
    required bool fromBackup,
  }) =>
      _op(() async {
        final open = _requireOpen();
        final now = clock.now();
        final entries = <VaultEntry>[...open.index.entries];
        final secrets = <String, SealedSecret>{...open.envelope.secrets};
        final history = <String, SealedBox>{...open.envelope.history};
        // Хронология паролей (ADR-015): выключена — прежние пароли не
        // копятся, а хронология копии отбрасывается.
        final keepHistory = VaultPrefs.passwordHistory.of(open.index.prefs);
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
                  history: keepHistory
                      ? _mergeHistory(
                          ring: open.ring,
                          envelope: open.envelope,
                          entryId: existing.id,
                          kFp: open.kFp,
                          currentFp: fp,
                          existing: _historyPrints(open, existing),
                          incoming: <ImportHistory>[
                            ImportHistory(
                              password: current.password,
                              from: existing.changed,
                              to: now,
                              src: existing.dateSource,
                            ),
                            if (fromBackup) ...item.history,
                          ],
                          boxes: history,
                        )
                      // Хронология выключена: оставленные элементы — без
                      // нового текущего пароля.
                      : existing.history.isEmpty
                          ? null
                          : _mergeHistory(
                              ring: open.ring,
                              envelope: open.envelope,
                              entryId: existing.id,
                              kFp: open.kFp,
                              currentFp: fp,
                              existing: _historyPrints(open, existing),
                              boxes: history,
                            ),
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
              history: keepHistory && fromBackup
                  ? _mergeHistory(
                      ring: open.ring,
                      envelope: open.envelope,
                      entryId: id,
                      kFp: open.kFp,
                      currentFp: fp,
                      incoming: item.history,
                      boxes: history,
                    )
                  : const <HistoryMeta>[],
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
            history: history,
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
  ///
  /// У сейфа с кодом восстановления (ADR-025) [master] — код: копия
  /// закрывается им же (в виде без дефисов). С отдельным паролем копии
  /// [passphrase] вместо кода годится и подтверждение [proof] (ПИН-код,
  /// биометрия, устройство). ПИН-кодом копия не закрывается никогда.
  Future<Uint8List> exportBackup({
    SecretBytes? master,
    VaultProof? proof,
    SecretBytes? passphrase,
    VaultKdfParams? params,
    String? Function()? afterVerify,
  }) =>
      _op(() async {
        final open = _requireOpen();
        if (master == null && (proof == null || passphrase == null)) {
          throw ArgumentError('нужен код восстановления или пароль копии');
        }
        await _proofCheck(open, master != null ? SecretProof(master) : proof!);
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
        final code = passphrase == null && open.envelope.isRecoveryKind
            ? RecoveryCode.canonical(master!)
            : null;
        final secret = passphrase ?? code ?? master!;
        final salt = crypto.bytes(VaultFormat.saltBytes);
        final vaultId = base64.encode(crypto.bytes(VaultFormat.idBytes));
        final record = KdfRecord(ops: kdf.ops, mem: kdf.mem, salt: salt);
        final ring = VaultKeyRing.from(crypto, crypto.randomKey());
        try {
          final kek = await crypto.derive(secret, salt, kdf);
          final SealedBox wrap;
          try {
            wrap = crypto.sealKey(
              kek,
              ring.vk,
              VaultKeys.wrapPwAdOf(
                version: VaultFormat.version,
                kind: VaultFormat.kindBackup,
                vaultId: vaultId,
                kdf: record,
              ),
            );
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
          final history = _resealHistory(open, ring, base);
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
              history: history,
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
              read.items.length == open.index.entries.length &&
              _historyComplete(read.items, open.index.entries);
          read.wipe();
          if (!complete) throw VaultError.corrupt;
          touch();
          return bytes;
        } finally {
          ring.dispose();
          code?.wipe();
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
    // Копия, закрытая кодом восстановления (ADR-025), открывается кодом в
    // любом написании: сначала — приведённый к виду кода ввод, затем ввод
    // как есть (отдельный пароль копии мог быть похож на код).
    final code = RecoveryCode.canonical(passphrase);
    VaultKey? vk;
    try {
      for (final candidate in <SecretBytes>[
        if (code != null) code,
        if (code == null ||
            !crypto.equal(code.unsafeBytes, passphrase.unsafeBytes))
          passphrase,
      ]) {
        final kek = await crypto.derive(candidate, envelope.kdf.salt, params);
        try {
          vk = crypto.openKey(
            kek,
            envelope.wrapPw,
            VaultKeys.wrapPwAdFor(envelope),
          );
        } finally {
          kek.dispose();
        }
        if (vk != null) break;
      }
    } finally {
      code?.wipe();
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
          final history = <ImportHistory>[];
          for (final meta in info.history) {
            final password = _openBackupHistory(envelope, ring, info, meta);
            if (password != null) {
              history.add(
                ImportHistory(
                  password: password,
                  from: meta.from,
                  to: meta.to,
                  src: meta.src,
                ),
              );
            }
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
              history: List<ImportHistory>.unmodifiable(history),
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

  /// Прежний пароль из копии или `null` (нет шифротекста, не
  /// расшифровался, пусто, длиннее предела): битый элемент хронологии
  /// пропускается, запись остаётся.
  SecretBytes? _openBackupHistory(
    VaultEnvelope envelope,
    VaultKeyRing ring,
    BackupEntryInfo info,
    HistoryMeta meta,
  ) {
    final box = envelope.history[meta.id];
    if (box == null) return null;
    final plain = crypto.open(
      ring.secret,
      box,
      VaultKeys.historyAd(
        version: envelope.sourceVersion,
        kind: envelope.kind,
        vaultId: envelope.vaultId,
        entryId: info.id,
        historyId: meta.id,
      ),
    );
    if (plain == null) return null;
    final VaultSecret secret;
    try {
      secret = SecretCodec.decodePadded(plain);
    } on VaultError {
      return null;
    }
    secret.note.wipe();
    final password = secret.password;
    if (password.isEmpty || password.length > VaultFormat.maxPassword) {
      password.wipe();
      return null;
    }
    return password;
  }

  /// Проверка копии чтением: у каждой записи прочиталась вся хронология.
  static bool _historyComplete(
    List<ImportItem> items,
    List<VaultEntry> entries,
  ) {
    final expected = <String, int>{
      for (final e in entries) e.id: e.history.length,
    };
    for (final item in items) {
      if (expected[item.sourceId] != item.history.length) return false;
    }
    return true;
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
        _requireMaster(open);
        final check = await _unwrap(current, open.envelope);
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
        _requireMaster(open);
        final check = await _unwrap(master, open.envelope);
        check.dispose();
        _alive(open);
        final params = VaultKdfParams.checkLoaded(
          open.envelope.kdf,
          allowTesting: allowTestingKdf,
        );
        await _rekey(open, master, params);
      });

  /// Новый ключ сейфа и новая обёртка `wrap_pw` секретом [master] (вид
  /// [pwKind], по умолчанию прежний). [withDevice] — сразу и слот `dev`
  /// (переход на защиту устройством, ADR-025).
  ///
  /// [remake] — слоты устройства, которые запечатать заново под новый ключ
  /// сейфа (новые ключи устройства; `pin` — ПИН-кодом [pin], `bio` —
  /// системным запросом с причиной [reason]). Прежние ключи устройства
  /// удаляются после записи. [newCode] — новый код восстановления: метка
  /// «код подтверждён» сбрасывается.
  Future<void> _rekey(
    _Open open,
    SecretBytes master,
    VaultKdfParams kdf, {
    String? pwKind,
    bool withDevice = false,
    Set<String> remake = const <String>{},
    SecretBytes? pin,
    String? reason,
    bool newCode = false,
  }) async {
    final kind = pwKind ?? open.envelope.pwKind ?? VaultFormat.pwMaster;
    final salt = crypto.bytes(VaultFormat.saltBytes);
    final record = KdfRecord(ops: kdf.ops, mem: kdf.mem, salt: salt);
    final ring = VaultKeyRing.from(crypto, crypto.randomKey());
    final created = <String>[];
    final slots = <String, VaultSlot>{};
    final old = <String>[
      for (final name in remake)
        if (open.envelope.slots[name] case final VaultSlot s) s.alias,
    ];
    try {
      final kek = await crypto.derive(master, salt, kdf);
      final SealedBox wrap;
      try {
        wrap = crypto.sealKey(
          kek,
          ring.vk,
          VaultKeys.wrapPwAdOf(
            version: VaultFormat.version,
            kind: VaultFormat.kindVault,
            vaultId: open.envelope.vaultId,
            kdf: record,
            pwKind: kind,
          ),
        );
      } finally {
        kek.dispose();
      }
      _alive(open);
      if (withDevice) {
        final slot = await _makeSlot(
          VaultFormat.slotDevice,
          ring.vk,
          open.envelope.vaultId,
        );
        created.add(slot.alias);
        slots[VaultFormat.slotDevice] = slot;
      }
      // Порядок: сначала без запроса, биометрия — последней (отмена не
      // оставит лишних ключей надолго: их удалит catch).
      for (final name in <String>[
        VaultFormat.slotDevice,
        VaultFormat.slotPin,
        VaultFormat.slotBio,
      ]) {
        if (!remake.contains(name)) continue;
        KdfRecord? pinKdf;
        if (name == VaultFormat.slotPin) {
          if (pin == null) throw StateError('нужен ПИН-код');
          pinKdf = KdfRecord(
            ops: kdf.ops,
            mem: kdf.mem,
            salt: crypto.bytes(VaultFormat.saltBytes),
          );
        }
        final slot = await _makeSlot(
          name,
          ring.vk,
          open.envelope.vaultId,
          pin: name == VaultFormat.slotPin ? pin : null,
          pinKdf: pinKdf,
          reason: name == VaultFormat.slotBio ? reason : null,
        );
        created.add(slot.alias);
        slots[name] = slot;
        _alive(open);
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
        history: _resealHistory(open, ring, base),
        master: withDevice || newCode
            ? <String, Object?>{
                for (final MapEntry(:key, :value) in open.index.master.entries)
                  if (key != 'last_typed') key: value,
                _rcConfirmedKey: false,
              }
            : <String, Object?>{
                ...open.index.master,
                'last_typed': _iso(clock.now()),
              },
        ring: ring,
        kdf: record,
        wrapPw: wrap,
        pwKind: kind,
        slots: slots,
        replacePrevious: true,
      );
      // Новый файл уже записан: сбой копий ниже не отменяет его (иначе
      // показанный код или новые ключи потерялись бы, а файл остался под
      // ними). Копии перезаписываются по возможности.
      try {
        for (final version in await store.backupVersions()) {
          await store.writeBackup(version, written);
        }
      } on Object {
        // Старая копия останется до следующей записи.
      }
    } catch (_) {
      if (!identical(open.ring, ring)) ring.dispose();
      await _forget(created);
      rethrow;
    }
    await _forget(old);
    if (slots[VaultFormat.slotPin] case final VaultSlot s) {
      await _resetPinAttempts(s.alias);
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

  /// Прежний пароль [historyId] записи [entry] (ключи [ring], AD — версии
  /// файла). Вызывающий затирает.
  SecretBytes _openHistory(
    _Open open,
    VaultKeyRing ring,
    VaultEntry entry,
    String historyId,
  ) {
    final box = open.envelope.history[historyId];
    if (box == null) throw VaultError.corrupt;
    final body = crypto.open(
      ring.secret,
      box,
      VaultKeys.historyAd(
        version: open.envelope.sourceVersion,
        kind: open.envelope.kind,
        vaultId: open.envelope.vaultId,
        entryId: entry.id,
        historyId: historyId,
      ),
    );
    if (body == null) throw VaultError.corrupt;
    final secret = SecretCodec.decodePadded(body);
    secret.note.wipe();
    return secret.password;
  }

  /// Шифротекст прежнего пароля: тело то же, что у секрета (пароль и пустая
  /// заметка, дополнение до 256 байт), ключ `K_secret`, своя AD.
  SealedBox _sealHistory(
    VaultKeyRing ring,
    VaultEnvelope envelope,
    String entryId,
    String historyId,
    SecretBytes password,
  ) {
    final empty = SecretBytes.empty();
    final body = SecretCodec.encodePadded(password, empty);
    try {
      return crypto.seal(
        ring.secret,
        body,
        VaultKeys.historyAd(
          version: VaultFormat.version,
          kind: envelope.kind,
          vaultId: envelope.vaultId,
          entryId: entryId,
          historyId: historyId,
        ),
      );
    } finally {
      body.fillRange(0, body.length, 0);
      empty.wipe();
    }
  }

  /// Вся хронология открытого хранилища заново: ключами [ring] под
  /// конверт [base] (смена ключа, копия, миграция).
  Map<String, SealedBox> _resealHistory(
    _Open open,
    VaultKeyRing ring,
    VaultEnvelope base,
  ) {
    final out = <String, SealedBox>{};
    for (final entry in open.index.entries) {
      for (final meta in entry.history) {
        final password = _openHistory(open, open.ring, entry, meta.id);
        try {
          out[meta.id] = _sealHistory(ring, base, entry.id, meta.id, password);
        } finally {
          password.wipe();
        }
      }
    }
    return out;
  }

  /// Хронология записи [entry] с отпечатками паролей (для слияния).
  List<(HistoryMeta, Uint8List)> _historyPrints(_Open open, VaultEntry entry) =>
      <(HistoryMeta, Uint8List)>[
        for (final meta in entry.history)
          (meta, _historyPrint(open, entry, meta.id)),
      ];

  Uint8List _historyPrint(_Open open, VaultEntry entry, String historyId) {
    final password = _openHistory(open, open.ring, entry, historyId);
    try {
      return VaultKeys.fingerprint(crypto, open.kFp, password);
    } finally {
      password.wipe();
    }
  }

  /// Хронология записи [entryId] после слияния (ADR-015): прежние
  /// [existing] (с отпечатками) и пришедшие [incoming] (прежний пароль
  /// при смене, хронология копии). Без повторов по отпечатку и без
  /// текущего пароля [currentFp]; новые (по дате смены) первыми; не больше
  /// [VaultEntry.maxHistory]. Пришедшие запечатываются в [boxes] под
  /// новыми id, выпавшие прежние из [boxes] убираются. Пароли [incoming]
  /// не затираются.
  List<HistoryMeta> _mergeHistory({
    required VaultKeyRing ring,
    required VaultEnvelope envelope,
    required String entryId,
    required VaultKey kFp,
    required Uint8List currentFp,
    List<(HistoryMeta, Uint8List)> existing = const <(
      HistoryMeta,
      Uint8List
    )>[],
    List<ImportHistory> incoming = const <ImportHistory>[],
    required Map<String, SealedBox> boxes,
  }) {
    // Пришедшие — в начале: при равной дате (сменили дважды за миг) только
    // что сменённый пароль новее хранившихся.
    final candidates = <(DateTime, Uint8List, HistoryMeta?, ImportHistory?)>[
      for (final item in incoming)
        (
          item.to,
          VaultKeys.fingerprint(crypto, kFp, item.password),
          null,
          item,
        ),
      for (final (meta, fp) in existing) (meta.to, fp, meta, null),
    ];
    // Устойчивая сортировка: новые по дате смены первыми.
    final order = List<int>.generate(candidates.length, (int i) => i)
      ..sort((int a, int b) {
        final byDate = candidates[b].$1.compareTo(candidates[a].$1);
        return byDate != 0 ? byDate : a.compareTo(b);
      });
    final seen = <Uint8List>[currentFp];
    final result = <HistoryMeta>[];
    for (final i in order) {
      final (_, fp, meta, item) = candidates[i];
      final duplicate = seen.any((Uint8List s) => crypto.equal(s, fp));
      if (duplicate || result.length >= VaultEntry.maxHistory) {
        if (meta != null) boxes.remove(meta.id);
        continue;
      }
      seen.add(fp);
      if (meta != null) {
        result.add(meta);
        continue;
      }
      var hid = VaultIds.hex(crypto.bytes(VaultFormat.idBytes));
      while (boxes.containsKey(hid)) {
        hid = VaultIds.hex(crypto.bytes(VaultFormat.idBytes));
      }
      boxes[hid] = _sealHistory(ring, envelope, entryId, hid, item!.password);
      result.add(
        HistoryMeta(id: hid, from: item.from, to: item.to, src: item.src),
      );
    }
    return List<HistoryMeta>.unmodifiable(result);
  }

  VaultEnvelope _sealEnvelope({
    required VaultKeyRing ring,
    required String vaultId,
    required KdfRecord kdf,
    required SealedBox wrapPw,
    required VaultIndex index,
    required Map<String, SealedSecret> secrets,
    Map<String, SealedBox> history = const <String, SealedBox>{},
    BioWrap? wrapBio,
    String kind = VaultFormat.kindVault,
    String? pwKind,
    Map<String, VaultSlot> slots = const <String, VaultSlot>{},
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
        pwKind: kind == VaultFormat.kindVault
            ? pwKind ?? VaultFormat.pwMaster
            : null,
        slots: Map<String, VaultSlot>.unmodifiable(slots),
        rev: index.rev,
        index:
            crypto.seal(ring.index, body, VaultKeys.indexAd(header, index.rev)),
        secrets: Map<String, SealedSecret>.unmodifiable(secrets),
        history: Map<String, SealedBox>.unmodifiable(history),
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
    Map<String, SealedBox>? history,
    Map<String, Object?>? master,
    Map<String, Object?>? prefs,
    Map<String, Object?>? backup,
    VaultKeyRing? ring,
    KdfRecord? kdf,
    SealedBox? wrapPw,
    String? pwKind,
    Map<String, VaultSlot>? slots,
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
      pwKind: pwKind ?? open.envelope.pwKind,
      slots: slots ?? open.envelope.slots,
      index: index,
      secrets: secrets,
      history: history ?? open.envelope.history,
    );
    // Индекс и хронология конверта должны сойтись: иначе файл не открыть.
    try {
      VaultKeys.checkConsistency(envelope, index);
    } on VaultError {
      throw StateError('хронология не сходится с индексом');
    }
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
  _Built(
    this.envelope,
    this.index,
    this.ring,
    this.kFp,
    this.bytes,
    this.now, [
    this.aliases = const <String>[],
  ]);

  /// Ключи устройства, созданные для этого сейфа (убрать, если не записан).
  final List<String> aliases;

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
