import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../extensions/extension_registry.dart';
import '../services/clock.dart';
import 'secret_bytes.dart';
import 'vault_crypto.dart';
import 'vault_errors.dart';
import 'vault_format.dart';
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
  const VaultUnlockResult({required this.rev, required this.rolledBack});

  /// Версия открытого файла (для `passwords.seen_rev`).
  final int rev;

  /// Файл старее, чем был (`rev < seen_rev`): его могли подменить или
  /// восстановить из старой копии. Только предупреждение (раздел 4.1).
  final bool rolledBack;
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
    this.policy = const VaultPolicy(),
    this.allowTestingKdf = false,
    this.device = VaultDevice.desktop,
    this.totalMemory,
  });

  final VaultStore store;
  final VaultCrypto crypto;
  final Clock clock;
  final VaultPolicy policy;

  /// Разрешены ли [VaultKdfParams.forTesting] (только тесты).
  final bool allowTestingKdf;

  /// Для калибровки и потолка параметров копии.
  final VaultDevice device;
  final int? totalMemory;

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
      final now = clock.now();
      final salt = crypto.bytes(VaultFormat.saltBytes);
      final vaultId = base64.encode(crypto.bytes(VaultFormat.idBytes));
      final ring = VaultKeyRing.from(crypto, crypto.randomKey());
      final kFpBytes = SecretBytes.adopt(crypto.bytes(VaultFormat.keyBytes));
      final kFp = crypto.importKey(kFpBytes.clone());
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
        _stillWanted(epoch);
        final index = VaultIndex(
          rev: 1,
          kFp: kFpBytes,
          master: <String, Object?>{'last_typed': _iso(now)},
        );
        final envelope = _sealEnvelope(
          ring: ring,
          vaultId: vaultId,
          kdf: record,
          wrapPw: wrap,
          index: index,
          secrets: const <String, SealedSecret>{},
        );
        await store.writeVault(envelope.encode());
        _exists = true;
        // Заперли или выключили, пока шла запись: файл есть, ключей нет.
        _stillWanted(epoch);
        _open = _Open(
          envelope: envelope,
          index: index,
          ring: ring,
          kFp: kFp,
          unlockedAt: now,
        );
      } catch (_) {
        ring.dispose();
        kFp.dispose();
        kFpBytes.wipe();
        rethrow;
      }
      _schedule();
      _notify(VaultSignal.changed);
    });
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
  /// из настроек: по нему видно откат файла.
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
      final vk = await _unwrap(
        master,
        envelope,
        header,
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
          unlockedAt: clock.now(),
        );
        _open = open;
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
    Uint8List header, {
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
    final kek = await crypto.derive(master, envelope.kdf.salt, params);
    final VaultKey? vk;
    try {
      vk = crypto.openKey(kek, envelope.wrapPw, VaultKeys.wrapPwAd(header));
      if (vk != null) withKek?.call(kek, vk);
    } finally {
      kek.dispose();
    }
    if (vk == null) {
      // Та же попытка, время — конец проверки (пауза от него).
      await store.writeAttempts(attempts.failed(clock.now()).encode());
      throw VaultError.wrongPassword;
    }
    try {
      await store.writeAttempts(const VaultAttempts().encode());
    } on Object {
      // Не сбросился счётчик — лишняя ошибка в нём, не дыра.
    }
    return vk;
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
    open.lastActivity = clock.now();
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

  /// Когда хранилище запрётся само (простой или жёсткий предел).
  DateTime? get lockAt {
    final open = _open;
    if (open == null) return null;
    final idleAt = open.lastActivity.add(idleTimeout);
    final hardAt = open.unlockedAt.add(policy.hardLimit);
    return idleAt.isBefore(hardAt) ? idleAt : hardAt;
  }

  /// Запереть, если срок вышел (таймер мог опоздать: сон устройства).
  void checkTimeouts() {
    final at = lockAt;
    if (at == null) return;
    if (!clock.now().isBefore(at)) {
      lock();
    } else {
      _schedule();
    }
  }

  void _schedule() {
    _timer?.cancel();
    final at = lockAt;
    if (at == null) return;
    final wait = at.difference(clock.now());
    if (wait <= Duration.zero) {
      lock();
      return;
    }
    _timer = Timer(wait, checkTimeouts);
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
        );
        final noteBytes = note ?? SecretBytes.empty();
        final sealed =
            _sealSecret(open.ring, open.envelope, entry, password, noteBytes);
        await _commit(
          open,
          entries: <VaultEntry>[...open.index.entries, entry],
          secrets: <String, SealedSecret>{...open.envelope.secrets, id: sealed},
        );
        touch();
        _notify(VaultSignal.changed);
        return id;
      });

  /// Новый пароль записи: прежний отпечаток уходит в `fp_old` (до 5),
  /// `srev` растёт, `changed = now`. Заметка сохраняется.
  Future<void> updatePassword(String id, SecretBytes password) => _op(() async {
        final open = _requireOpen();
        final entry = _entry(open, id);
        _checkSecret(password, null);
        final current = _openSecret(open, open.ring, entry);
        try {
          final updated = entry.copyWith(
            srev: entry.srev + 1,
            changed: clock.now(),
            dateSource: DateSource.user,
            fp: VaultKeys.fingerprint(crypto, open.kFp, password),
            fpOld: <Uint8List>[entry.fp, ...entry.fpOld]
                .take(VaultEntry.maxOldFingerprints)
                .toList(),
          );
          final sealed = _sealSecret(
            open.ring,
            open.envelope,
            updated,
            password,
            current.note,
          );
          // Прежний пароль не живёт и в .prev (D7: старых паролей нет).
          await _commit(
            open,
            entries: _replace(open.index.entries, updated),
            secrets: <String, SealedSecret>{
              ...open.envelope.secrets,
              id: sealed,
            },
            replacePrevious: true,
          );
        } finally {
          current.wipe();
        }
        touch();
        _notify(VaultSignal.changed);
      });

  /// Правка полей записи без пароля.
  Future<void> updateInfo(
    String id, {
    String? service,
    String? login,
    String? hint,
    List<String>? urls,
    bool? important,
  }) =>
      _op(() async {
        final open = _requireOpen();
        final entry = _entry(open, id);
        final updated = entry.copyWith(
          service: service,
          login: login,
          hint: hint,
          urls: urls == null ? null : List<String>.unmodifiable(urls),
          important: important,
        );
        _checkInfo(
          service: updated.service,
          login: updated.login,
          hint: updated.hint,
          urls: updated.urls,
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
  Future<void> deleteEntry(String id) => _op(() async {
        final open = _requireOpen();
        _entry(open, id);
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

  /// Совпадает ли [token] по отпечатку с паролем какой-нибудь записи
  /// (`SecretGuard` при открытом хранилище). Заперто — `false`.
  bool matchesKnownSecret(String token) {
    final open = _open;
    if (open == null || token.isEmpty) return false;
    final candidate = SecretBytes.fromText(token);
    try {
      final fp = VaultKeys.fingerprint(crypto, open.kFp, candidate);
      var found = false;
      for (final entry in open.index.entries) {
        if (crypto.equal(fp, entry.fp)) found = true;
      }
      return found;
    } catch (_) {
      return false;
    } finally {
      candidate.wipe();
    }
  }

  /// Отпечаток пароля ключом `k_fp` открытого хранилища.
  Uint8List fingerprint(SecretBytes password) =>
      VaultKeys.fingerprint(crypto, _requireOpen().kFp, password);

  // ------------------------------------------------ мастер-пароль

  /// Смена мастер-пароля. Всегда с новым VK (D5): индекс и все секреты
  /// перешифровываются, `vault.prev` и `vault.v<N>.bak` перезаписываются
  /// новой версией — старый (возможно, утёкший) мастер-пароль больше
  /// ничего не открывает. Без [params] — новая калибровка.
  Future<void> changeMaster({
    required SecretBytes current,
    required SecretBytes next,
    VaultKdfParams? params,
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
  }) {
    final header = _headerFor(VaultFormat.kindVault, vaultId, kdf);
    final body = index.encodePadded();
    try {
      return VaultEnvelope(
        kind: VaultFormat.kindVault,
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
  final DateTime unlockedAt;
  DateTime lastActivity;

  void dispose() {
    ring.dispose();
    kFp.dispose();
    index.kFp.wipe();
  }
}
