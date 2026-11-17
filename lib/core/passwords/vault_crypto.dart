import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

import 'keyboard_layouts.dart';
import 'password_strength.dart' show Utf8Runes;
import 'secret_bytes.dart';
import 'vault_errors.dart';
import 'vault_format.dart';

/// Ключ в защищённой памяти (libsodium `SecureKey`: вне кучи Dart,
/// `mlock`, затирание при [dispose]).
abstract interface class VaultKey {
  void dispose();

  bool get isDisposed;
}

/// Случайные байты из ОС (libsodium `randombytes`). `dart:math Random` в
/// `lib/core/passwords` запрещён тестом.
abstract interface class VaultRandom {
  Uint8List bytes(int length);

  /// Равномерно в `[0, upperBound)`.
  int uniform(int upperBound);
}

/// Argon2id13: вывод ключа из мастер-пароля.
abstract interface class VaultKdf {
  /// Ключ KEK_pw (32 байта) из [password]. Байты пароля вызывающий
  /// затирает сам; копия для вычисления затирается здесь.
  Future<VaultKey> derive(
    SecretBytes password,
    Uint8List salt,
    VaultKdfParams params,
  );

  /// Сколько длится один вывод с [params] (для калибровки).
  Future<Duration> measure(VaultKdfParams params);
}

/// XChaCha20-Poly1305 IETF, `crypto_kdf`, BLAKE2b с ключом и сравнение за
/// постоянное время.
abstract interface class VaultCipher {
  /// Новый случайный ключ (32 байта).
  VaultKey randomKey();

  /// Ключ из байтов; [bytes] затираются.
  VaultKey importKey(SecretBytes bytes);

  /// Байты ключа (для `k_fp` в индексе). Вызывающий затирает их.
  SecretBytes exportKey(VaultKey key);

  /// Подключ `crypto_kdf_derive_from_key(master, id, "RlyVault")`.
  VaultKey deriveKey(VaultKey master, int id);

  /// Шифрование с новым случайным 24-байтовым nonce.
  SealedBox seal(VaultKey key, Uint8List message, Uint8List ad);

  /// Расшифровка; `null` — тег не сошёлся (чужой ключ, подмена, другой AD).
  /// Результат вызывающий затирает.
  Uint8List? open(VaultKey key, SealedBox box, Uint8List ad);

  /// Обёртка ключа [key] ключом [kek].
  SealedBox sealKey(VaultKey kek, VaultKey key, Uint8List ad);

  /// Ключ из обёртки; `null` — тег не сошёлся.
  VaultKey? openKey(VaultKey kek, SealedBox box, Uint8List ad);

  /// BLAKE2b-256 с ключом.
  Uint8List keyedHash(VaultKey key, Uint8List message);

  /// Равенство за постоянное время (`sodium_memcmp`).
  bool equal(Uint8List a, Uint8List b);
}

/// Всё, что нужно хранилищу от криптографии.
abstract interface class VaultCrypto
    implements VaultKdf, VaultCipher, VaultRandom {}

/// Устройство для калибровки Argon2id.
enum VaultDevice { desktop, mobile }

/// Параметры Argon2id13 с границами (раздел 3.2).
final class VaultKdfParams {
  const VaultKdfParams({required this.ops, required this.mem})
      : isTesting = false;

  /// Слабые параметры только для тестов (`mem = 64 КиБ`). Хранилище
  /// принимает их лишь с флагом `allowTestingKdf` в конструкторе и
  /// никогда — из файла без него.
  const VaultKdfParams.forTesting()
      : ops = 1,
        mem = testingMem,
        isTesting = true;

  static const int kib = 1024;
  static const int mib = 1024 * 1024;

  /// Абсолютные границы при загрузке: ниже — подмена на «слабый» файл,
  /// выше — DoS по памяти.
  static const int minLoadMem = 32 * mib;
  static const int maxLoadMem = 1024 * mib;
  static const int minLoadOps = 2;
  static const int maxLoadOps = 10;

  /// Пол при создании; на устройствах < 3 ГБ RAM — [lowMemoryFloor].
  static const VaultKdfParams floor = VaultKdfParams(ops: 3, mem: 64 * mib);
  static const VaultKdfParams lowMemoryFloor =
      VaultKdfParams(ops: 3, mem: 46 * mib);

  /// Пол и потолок копии (`.relaybak`).
  static const VaultKdfParams backupFloor =
      VaultKdfParams(ops: 4, mem: 64 * mib);
  static const int maxBackupMem = 256 * mib;

  static const int testingMem = 64 * kib;

  final int ops;
  final int mem;
  final bool isTesting;

  /// Проверка параметров из файла до вывода ключа: вне границ —
  /// [VaultError.kdfInvalid], память не выделяется. Для копии потолок
  /// жёстче: `mem ≤ 256 МиБ` и `mem ≤ totalMemory / 4`. Тестовые
  /// параметры — только при [allowTesting].
  static VaultKdfParams checkLoaded(
    KdfRecord record, {
    bool backup = false,
    int? totalMemory,
    bool allowTesting = false,
  }) {
    if (allowTesting &&
        record.ops == const VaultKdfParams.forTesting().ops &&
        record.mem == testingMem) {
      return const VaultKdfParams.forTesting();
    }
    final ops = record.ops;
    final mem = record.mem;
    if (ops < minLoadOps || ops > maxLoadOps) throw VaultError.kdfInvalid;
    if (mem < minLoadMem || mem > maxLoadMem) throw VaultError.kdfInvalid;
    if (backup) {
      if (mem > maxBackupMem) throw VaultError.kdfInvalid;
      if (totalMemory != null && mem > totalMemory ~/ 4) {
        throw VaultError.kdfInvalid;
      }
    }
    return VaultKdfParams(ops: ops, mem: mem);
  }

  /// Параметры копии: не слабее хранилища (`mem = min(vault.mem, 256 МиБ)`,
  /// `ops = max(vault.ops, 4)`), но не ниже 64 МиБ / ops 4.
  static VaultKdfParams forBackup(VaultKdfParams vault) {
    if (vault.isTesting) return vault;
    var mem = vault.mem < maxBackupMem ? vault.mem : maxBackupMem;
    if (mem < backupFloor.mem) mem = backupFloor.mem;
    final ops = vault.ops > backupFloor.ops ? vault.ops : backupFloor.ops;
    return VaultKdfParams(ops: ops, mem: mem);
  }

  /// Калибровка при создании и смене мастер-пароля: цель 0,7–1,0 с.
  /// Начинает с пола и растит память (×2), затем ops — пока следующий шаг
  /// по оценке не выйдет за секунду. Десктоп — до 256 МиБ / ops 4;
  /// телефон — 64 МиБ, 128 МиБ при `totalMemory ≥ 4 ГБ`, пол 46 МиБ при
  /// `totalMemory < 3 ГБ`. Если и пол дольше секунды — остаётся пол.
  static Future<VaultKdfParams> calibrate({
    required Future<Duration> Function(VaultKdfParams params) measure,
    VaultDevice device = VaultDevice.desktop,
    int? totalMemory,
  }) async {
    const gb = 1024 * mib;
    final lowMemory = device == VaultDevice.mobile &&
        totalMemory != null &&
        totalMemory < 3 * gb;
    var params = lowMemory ? lowMemoryFloor : floor;
    final int capMem;
    final int capOps;
    if (device == VaultDevice.desktop) {
      capMem = 256 * mib;
      capOps = 4;
    } else {
      capMem =
          totalMemory != null && totalMemory >= 4 * gb ? 128 * mib : 64 * mib;
      capOps = 4;
    }
    const low = Duration(milliseconds: 700);
    const high = Duration(milliseconds: 1000);
    var time = await measure(params);
    while (time < low && params.mem * 2 <= capMem) {
      if (time * 2 > high) break;
      params = VaultKdfParams(ops: params.ops, mem: params.mem * 2);
      time = await measure(params);
    }
    while (time < low && params.ops < capOps) {
      final next = time * ((params.ops + 1) / params.ops);
      if (next > high) break;
      params = VaultKdfParams(ops: params.ops + 1, mem: params.mem);
      time = await measure(params);
    }
    return params;
  }

  @override
  bool operator ==(Object other) =>
      other is VaultKdfParams && other.ops == ops && other.mem == mem;

  @override
  int get hashCode => Object.hash(ops, mem);

  @override
  String toString() => 'VaultKdfParams(ops $ops, mem ${mem ~/ kib} KiB)';
}

/// Ключи открытого хранилища: VK и подключи индекса и секретов.
final class VaultKeyRing {
  VaultKeyRing._(this.vk, this.index, this.secret);

  /// Подключи из [vk] (кольцо забирает [vk] себе).
  factory VaultKeyRing.from(VaultCipher cipher, VaultKey vk) => VaultKeyRing._(
        vk,
        cipher.deriveKey(vk, VaultKeys.indexSubkey),
        cipher.deriveKey(vk, VaultKeys.secretSubkey),
      );

  final VaultKey vk;
  final VaultKey index;
  final VaultKey secret;

  void dispose() {
    vk.dispose();
    index.dispose();
    secret.dispose();
  }

  @override
  String toString() => 'VaultKeyRing(•••)';
}

/// Иерархия ключей и AD (раздел 3.1, 3.3).
///
/// ```
/// KEK_pw = Argon2id13(мастер-пароль, salt, ops, mem)
/// VK     — случайный; wrap_pw = AEAD(KEK_pw, VK, AD = header|wrap_pw)
/// K_index  = crypto_kdf(VK, 1, "RlyVault")  — индекс, AD = header|index|rev
/// K_secret = crypto_kdf(VK, 2, "RlyVault")  — секреты,
///            AD = relay-vault|v|kind|vault_id|entry_id|secret|srev
/// K_fp — случайный, лежит в индексе.
/// ```
/// `header` = `relay-vault|v|kind|vault_id|argon2id13|ops|mem|b64(salt)`:
/// копию нельзя подсунуть как хранилище, обёртку — переставить в другое
/// поле, секрет — пересадить в другую запись или откатить по частям.
abstract final class VaultKeys {
  static const String context = 'RlyVault';
  static const int indexSubkey = 1;
  static const int secretSubkey = 2;

  static Uint8List header(VaultEnvelope envelope) => headerOf(
        version: envelope.sourceVersion,
        kind: envelope.kind,
        vaultId: envelope.vaultId,
        ops: envelope.kdf.ops,
        mem: envelope.kdf.mem,
        salt: envelope.kdf.salt,
      );

  static Uint8List headerOf({
    required int version,
    required String kind,
    required String vaultId,
    required int ops,
    required int mem,
    required Uint8List salt,
  }) =>
      _ascii(
        'relay-vault|$version|$kind|$vaultId|${KdfRecord.alg}|$ops|$mem|'
        '${base64.encode(salt)}',
      );

  static Uint8List wrapPwAd(Uint8List header) => _join(header, '|wrap_pw');

  /// AD обёртки `wrap_pw` конверта [envelope] (по версии, в которой он
  /// записан).
  static Uint8List wrapPwAdFor(VaultEnvelope envelope) => wrapPwAdOf(
        version: envelope.sourceVersion,
        kind: envelope.kind,
        vaultId: envelope.vaultId,
        kdf: envelope.kdf,
        pwKind: envelope.pwKind,
      );

  /// AD обёртки `wrap_pw`. До версии 3 — `header|wrap_pw` (в header есть
  /// версия формата). С версии 3 — без версии формата, но с `pw_kind`:
  /// сейф, который открывается ключом устройства, мигрирует в будущие
  /// версии без кода восстановления (обёртку нечем было бы запечатать
  /// заново), а «мастер-пароль» и «код» не переставить друг на друга.
  static Uint8List wrapPwAdOf({
    required int version,
    required String kind,
    required String vaultId,
    required KdfRecord kdf,
    String? pwKind,
  }) {
    if (version < 3) {
      return wrapPwAd(
        headerOf(
          version: version,
          kind: kind,
          vaultId: vaultId,
          ops: kdf.ops,
          mem: kdf.mem,
          salt: kdf.salt,
        ),
      );
    }
    return _ascii(
      'relay-vault-wrap|pw|$kind|$vaultId|${KdfRecord.alg}|${kdf.ops}|'
      '${kdf.mem}|${base64.encode(kdf.salt)}|${pwKind ?? '-'}',
    );
  }

  /// AD слота ключа сейфа (ADR-025): имя слота, сейф, вид и имя ключа
  /// устройства, у ПИН-кода — параметры Argon2id. Без версии формата:
  /// миграции не требуют ни ПИН-кода, ни биометрии.
  static Uint8List slotAd({
    required String slot,
    required String vaultId,
    required String kind,
    required String alias,
    KdfRecord? kdf,
  }) =>
      _ascii(
        'relay-vault-slot|$slot|$vaultId|$kind|$alias'
        '${kdf == null ? '' : '|${KdfRecord.alg}|${kdf.ops}|${kdf.mem}|'
            '${base64.encode(kdf.salt)}'}',
      );

  /// Сообщение ключу устройства: `relay-vault|слот|vault_id|` + [input]
  /// (для ПИН-кода — Argon2id от ПИН-кода, иначе пусто). Вызывающий
  /// затирает.
  static Uint8List slotMessage(String slot, String vaultId, Uint8List input) {
    final prefix = ascii.encode('relay-vault|$slot|$vaultId|');
    return Uint8List(prefix.length + input.length)
      ..setRange(0, prefix.length, prefix)
      ..setRange(prefix.length, prefix.length + input.length, input);
  }

  /// Метка ключа слота: `KEK = BLAKE2b(key = ответ ключа устройства,
  /// метка)`.
  static Uint8List slotLabel(String slot) => _ascii('relay-vault|kek|$slot');

  static Uint8List wrapBioAd(Uint8List header, String kind) =>
      _join(header, '|wrap_bio|$kind');

  static Uint8List indexAd(Uint8List header, int rev) =>
      _join(header, '|index|$rev');

  static Uint8List secretAd({
    required int version,
    required String kind,
    required String vaultId,
    required String entryId,
    required int srev,
  }) =>
      _ascii('relay-vault|$version|$kind|$vaultId|$entryId|secret|$srev');

  /// AD прежнего пароля в хронологии (ADR-015): элемент нельзя
  /// пересадить к другой записи или под другой id.
  static Uint8List historyAd({
    required int version,
    required String kind,
    required String vaultId,
    required String entryId,
    required String historyId,
  }) =>
      _ascii(
        'relay-vault|$version|$kind|$vaultId|$entryId|hist|$historyId',
      );

  static Uint8List _ascii(String text) =>
      Uint8List.fromList(ascii.encode(text));

  static Uint8List _join(Uint8List header, String suffix) =>
      Uint8List.fromList(<int>[...header, ...ascii.encode(suffix)]);

  /// Отпечаток пароля `BLAKE2b_K_fp("p|" + NFC(pwd))`.
  static Uint8List fingerprint(
    VaultCipher cipher,
    VaultKey kFp,
    SecretBytes password,
  ) {
    final bytes = password.unsafeBytes;
    final message = Uint8List(bytes.length + 2)
      ..[0] = 0x70 // p
      ..[1] = 0x7C // |
      ..setRange(2, bytes.length + 2, bytes);
    try {
      return cipher.keyedHash(kFp, message);
    } finally {
      message.fillRange(0, message.length, 0);
    }
  }

  /// «Почти повтор» `BLAKE2b_K_fp("l|" + lower(без хвоста из цифр и
  /// знаков))` (3.4): `Kotik2019` и `kotik2020` дают одно значение.
  /// `null` — от пароля ничего не осталось (одни цифры и знаки).
  static Uint8List? looseFingerprint(
    VaultCipher cipher,
    VaultKey kFp,
    SecretBytes password,
  ) {
    final runes = Utf8Runes.decode(password.unsafeBytes);
    if (runes == null) return null;
    var end = runes.length;
    while (end > 0 && !KeyboardLayouts.isLetter(runes[end - 1])) {
      end--;
    }
    final core = <int>[
      for (var i = 0; i < end; i++) KeyboardLayouts.lower(runes[i]),
    ];
    runes.fillRange(0, runes.length, 0);
    if (core.isEmpty) return null;
    final body = Utf8Runes.encode(core);
    core.fillRange(0, core.length, 0);
    final message = Uint8List(body.length + 2)
      ..[0] = 0x6C // l
      ..[1] = 0x7C // |
      ..setRange(2, body.length + 2, body);
    body.fillRange(0, body.length, 0);
    try {
      return cipher.keyedHash(kFp, message);
    } finally {
      message.fillRange(0, message.length, 0);
    }
  }

  /// Согласованность конверта и индекса (защита от отката по частям):
  /// внутренний `rev` равен внешнему, набор id секретов равен набору id
  /// записей, внешнее `r` каждого секрета равно `srev` записи, набор id
  /// хронологии в индексе (без повторов) равен набору ключей `history`
  /// конверта. Иначе — [VaultError.corrupt].
  static void checkConsistency(VaultEnvelope envelope, VaultIndex index) {
    if (index.rev != envelope.rev) throw VaultError.corrupt;
    if (envelope.secrets.length != index.entries.length) {
      throw VaultError.corrupt;
    }
    for (final entry in index.entries) {
      final secret = envelope.secrets[entry.id];
      if (secret == null || secret.rev != entry.srev) throw VaultError.corrupt;
    }
    final hids = <String>{};
    for (final entry in index.entries) {
      for (final meta in entry.history) {
        if (!hids.add(meta.id)) throw VaultError.corrupt;
        if (!envelope.history.containsKey(meta.id)) throw VaultError.corrupt;
      }
    }
    if (hids.length != envelope.history.length) throw VaultError.corrupt;
  }
}

/// Реализация на libsodium (`package:sodium`, сборка libsodium
/// build-хуком пакета под каждую платформу).
final class SodiumVaultCrypto implements VaultCrypto {
  SodiumVaultCrypto(this._sodium, {this.isolated = true});

  /// [isolated] — Argon2id в отдельном изоляте (`runIsolated`), чтобы не
  /// вешать интерфейс. В тестах с `fakeAsync` — `false`.
  static Future<SodiumVaultCrypto> load({bool isolated = true}) async =>
      SodiumVaultCrypto(await _init(), isolated: isolated);

  static Future<SodiumSumo>? _loading;

  static Future<SodiumSumo> _init() =>
      _loading ??= Future<SodiumSumo>.value(SodiumSumoInit.init());

  final SodiumSumo _sodium;
  final bool isolated;

  Aead get _aead => _sodium.crypto.aeadXChaCha20Poly1305IETF;

  @override
  Uint8List bytes(int length) => _sodium.randombytes.buf(length);

  @override
  int uniform(int upperBound) => _sodium.randombytes.uniform(upperBound);

  @override
  Future<VaultKey> derive(
    SecretBytes password,
    Uint8List salt,
    VaultKdfParams params,
  ) async {
    if (password.isEmpty) throw ArgumentError('пустой пароль');
    final sodium = _sodium;
    final saltCopy = Uint8List.fromList(salt);
    final ops = params.ops;
    final mem = params.mem;
    // Пароль уходит в изолят как SecureKey: без копий в куче Dart.
    final secure = sodium.secureCopy(password.unsafeBytes);
    try {
      if (!isolated) {
        return _SodiumKey(_pwhash(sodium, secure, saltCopy, ops, mem));
      }
      final transfer = await sodium.runIsolated(
        (List<SecureKey> keys, List<KeyPair> _) {
          final key = _pwhash(sodium, keys.single, saltCopy, ops, mem);
          try {
            return sodium.createTransferrableSecureKey(key);
          } finally {
            key.dispose();
            keys.single.dispose();
          }
        },
        secureKeys: <SecureKey>[secure],
      );
      return _SodiumKey(sodium.materializeTransferrableSecureKey(transfer));
    } on SodiumException {
      throw VaultError.io;
    } finally {
      secure.dispose();
    }
  }

  static SecureKey _pwhash(
    SodiumSumo sodium,
    SecureKey password,
    Uint8List salt,
    int ops,
    int mem,
  ) =>
      password.runUnlockedSync(
        (Uint8List data) => sodium.crypto.pwhash.callRaw(
          outLen: VaultFormat.keyBytes,
          password: Int8List.sublistView(data),
          salt: salt,
          opsLimit: ops,
          memLimit: mem,
          alg: CryptoPwhashAlgorithm.argon2id13,
        ),
      );

  @override
  Future<Duration> measure(VaultKdfParams params) async {
    final probe = SecretBytes.adopt(bytes(16));
    final watch = Stopwatch()..start();
    try {
      final key = await derive(probe, bytes(VaultFormat.saltBytes), params);
      key.dispose();
      return watch.elapsed;
    } finally {
      probe.wipe();
    }
  }

  @override
  VaultKey randomKey() =>
      _SodiumKey(_sodium.secureRandom(VaultFormat.keyBytes));

  @override
  VaultKey importKey(SecretBytes bytes) {
    try {
      return _SodiumKey(_sodium.secureCopy(bytes.unsafeBytes));
    } finally {
      bytes.wipe();
    }
  }

  @override
  SecretBytes exportKey(VaultKey key) =>
      SecretBytes.adopt(_key(key).extractBytes());

  @override
  VaultKey deriveKey(VaultKey master, int id) => _SodiumKey(
        _sodium.crypto.kdf.deriveFromKey(
          masterKey: _key(master),
          context: VaultKeys.context,
          subkeyId: BigInt.from(id),
          subkeyLen: VaultFormat.keyBytes,
        ),
      );

  @override
  SealedBox seal(VaultKey key, Uint8List message, Uint8List ad) {
    final nonce = bytes(VaultFormat.nonceBytes);
    final cipher = _aead.encrypt(
      message: message,
      nonce: nonce,
      key: _key(key),
      additionalData: ad,
    );
    return SealedBox(nonce, cipher);
  }

  @override
  Uint8List? open(VaultKey key, SealedBox box, Uint8List ad) {
    try {
      return _aead.decrypt(
        cipherText: box.cipher,
        nonce: box.nonce,
        key: _key(key),
        additionalData: ad,
      );
    } on SodiumException {
      return null;
    } on RangeError {
      return null;
    }
  }

  @override
  SealedBox sealKey(VaultKey kek, VaultKey key, Uint8List ad) =>
      _key(key).runUnlockedSync((Uint8List data) => seal(kek, data, ad));

  @override
  VaultKey? openKey(VaultKey kek, SealedBox box, Uint8List ad) {
    final raw = open(kek, box, ad);
    if (raw == null) return null;
    if (raw.length != VaultFormat.keyBytes) {
      raw.fillRange(0, raw.length, 0);
      return null;
    }
    return importKey(SecretBytes.adopt(raw));
  }

  @override
  Uint8List keyedHash(VaultKey key, Uint8List message) =>
      _sodium.crypto.genericHash(
        message: message,
        outLen: VaultFormat.keyBytes,
        key: _key(key),
      );

  // Сначала длина: `Sodium.memcmp` (package:sodium) на разной длине
  // бросает RangeError.
  // Не `a && memcmp(...)`: анализатор Dart 3.14 считает результат внутри
  // `&&` неиспользованным (unused_result), хотя он возвращается.
  @override
  bool equal(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    return _sodium.memcmp(a, b);
  }

  SecureKey _key(VaultKey key) {
    if (key is! _SodiumKey || key.isDisposed) {
      throw StateError('VaultKey(•••): чужой или освобождённый ключ');
    }
    return key.key;
  }
}

final class _SodiumKey implements VaultKey {
  _SodiumKey(this.key);

  final SecureKey key;
  bool _disposed = false;

  @override
  bool get isDisposed => _disposed;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    key.dispose();
  }

  @override
  String toString() => 'VaultKey(•••)';
}
