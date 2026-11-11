import 'dart:convert';
import 'dart:typed_data';

import 'secret_bytes.dart';
import 'vault_errors.dart';

/// Формат файла хранилища `vault.relayvault` и копии `.relaybak`
/// (ADR-014, раздел 4).
///
/// Здесь только данные: разбор и запись конверта, индекса и секрета,
/// дополнение до кратной длины, версии и миграции. Ключей и шифрования
/// нет — это `vault_crypto.dart`. Любая ошибка разбора (неверный JSON,
/// UTF-8, base64, типы, длины, глубина) — [VaultError.corrupt] без
/// причины: у `FormatException` в `toString` есть кусок исходной строки,
/// а в расшифрованном индексе это были бы логины и подсказки.
abstract final class VaultFormat {
  /// Значение поля `format`.
  static const String name = 'relay-vault';

  /// Текущая версия конверта.
  static const int version = 1;

  /// Текущая схема индекса.
  static const int indexSchema = 1;

  /// Конверт хранилища и конверт копии.
  static const String kindVault = 'vault';
  static const String kindBackup = 'backup';

  /// Виды обёртки биометрией (`wrap_bio.kind`). Windows Hello по решению
  /// владельца не используется, но вид оставлен в формате, чтобы файл с
  /// ним читался (и обёртка игнорировалась), а не считался порченым.
  static const Set<String> bioKinds = <String>{
    'android-keystore',
    'windows-hello',
    'macos-se',
    'macos-keychain',
  };

  /// Предел файла хранилища и копии.
  static const int maxFileBytes = 32 * 1024 * 1024;

  /// Предел числа записей.
  static const int maxEntries = 20000;

  /// Глубина JSON конверта и индекса.
  static const int maxDepth = 8;

  /// Предел числа элементов JSON (значений в массивах и объектах).
  static const int maxElements = 400000;

  /// Тело индекса дополняется до кратного этой длине.
  static const int indexBlock = 4096;

  /// Секрет дополняется до кратного этой длине: длина пароля не видна.
  static const int secretBlock = 256;

  /// Длины в байтах.
  static const int idBytes = 16;
  static const int saltBytes = 16;
  static const int nonceBytes = 24;
  static const int keyBytes = 32;
  static const int macBytes = 16;

  /// Пределы полей записи (раздел 4.3).
  static const int maxService = 200;
  static const int maxLogin = 320;
  static const int maxHint = 500;
  static const int maxPassword = 1024;
  static const int maxNote = 16 * 1024;
  static const int maxUrls = 20;
  static const int maxUrl = 2048;
  static const int maxAliases = 20;

  /// Худший JSON секрета: каждый байт пароля и заметки — `\u00XX`
  /// (6 байт), плюс `{"p":"`, `","note":"`, `"}`.
  static const int _maxSecretJson = 6 + 6 * maxPassword + 10 + 6 * maxNote + 2;

  /// Тот же JSON после дополнения до [secretBlock] (4 байта длины).
  static const int _maxSecretPadded =
      ((_maxSecretJson + 4 + secretBlock - 1) ~/ secretBlock) * secretBlock;

  /// Предел base64 шифротекста секрета и индекса (до декодирования).
  /// Секрет: худший случай в пределах [maxPassword] и [maxNote] — иначе
  /// допустимая заметка (коды восстановления по строке) делала бы файл
  /// «испорченным» при следующем чтении.
  static const int maxSecretB64 = ((_maxSecretPadded + macBytes + 2) ~/ 3) * 4;
  static const int maxIndexB64 = 24 * 1024 * 1024;
}

/// Шифротекст с одноразовым числом XChaCha20-Poly1305.
final class SealedBox {
  SealedBox(this.nonce, this.cipher);

  final Uint8List nonce;
  final Uint8List cipher;

  Map<String, Object?> toJson() => <String, Object?>{
        'n': base64.encode(nonce),
        'c': base64.encode(cipher),
      };

  @override
  String toString() => 'SealedBox(${cipher.length} B)';
}

/// Шифротекст секрета записи и подсказка `r` (должна совпасть с `srev`
/// записи в индексе).
final class SealedSecret {
  SealedSecret(this.box, this.rev);

  final SealedBox box;
  final int rev;

  Map<String, Object?> toJson() => <String, Object?>{
        ...box.toJson(),
        'r': rev,
      };

  @override
  String toString() => 'SealedSecret(r$rev)';
}

/// Обёртка ключа хранилища биометрией (этап 4).
final class BioWrap {
  BioWrap(this.kind, this.box);

  final String kind;
  final SealedBox box;

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind,
        ...box.toJson(),
      };
}

/// Параметры Argon2id13 из файла: проверяются до вывода ключа
/// (`VaultKdfParams.checkLoaded`).
final class KdfRecord {
  KdfRecord({required this.ops, required this.mem, required this.salt});

  static const String alg = 'argon2id13';

  final int ops;
  final int mem;
  final Uint8List salt;

  Map<String, Object?> toJson() => <String, Object?>{
        'alg': alg,
        'ops': ops,
        'mem': mem,
        'salt': base64.encode(salt),
      };
}

/// Внешний конверт файла. Снаружи нет названий, дат и числа записей в
/// индексе (видно только число секретов — записано в ADR-014).
final class VaultEnvelope {
  VaultEnvelope({
    required this.kind,
    required this.vaultId,
    required this.kdf,
    required this.wrapPw,
    required this.rev,
    required this.index,
    required this.secrets,
    this.wrapBio,
    this.sourceVersion = VaultFormat.version,
  });

  /// [VaultFormat.kindVault] или [VaultFormat.kindBackup].
  final String kind;

  /// base64 от 16 случайных байт.
  final String vaultId;
  final KdfRecord kdf;
  final SealedBox wrapPw;
  final BioWrap? wrapBio;

  /// Номер версии содержимого; совпадает с `rev` внутри индекса.
  final int rev;
  final SealedBox index;

  /// id записи → шифротекст её секрета.
  final Map<String, SealedSecret> secrets;

  /// Версия, в которой файл был записан (меньше [VaultFormat.version] —
  /// мигрирован при чтении). По ней строится `header_bytes` для AD.
  final int sourceVersion;

  bool get migrated => sourceVersion != VaultFormat.version;

  /// Байты файла текущей версии.
  Uint8List encode() => Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'format': VaultFormat.name,
            'v': VaultFormat.version,
            'kind': kind,
            'vault_id': vaultId,
            'kdf': kdf.toJson(),
            'wrap_pw': wrapPw.toJson(),
            if (wrapBio != null) 'wrap_bio': wrapBio!.toJson(),
            'rev': rev,
            'index': index.toJson(),
            'secrets': <String, Object?>{
              for (final MapEntry(:key, :value) in secrets.entries)
                key: value.toJson(),
            },
          }),
        ),
      );

  /// Разбор файла. [VaultError.tooNew] — версия новее приложения;
  /// [VaultError.corrupt] — всё остальное, что не по формату.
  static VaultEnvelope decode(Uint8List bytes) {
    if (bytes.length > VaultFormat.maxFileBytes) throw VaultError.corrupt;
    final Object? json = _decodeJson(bytes);
    if (json is! Map<String, Object?>) throw VaultError.corrupt;
    if (json['format'] != VaultFormat.name) throw VaultError.corrupt;
    final v = json['v'];
    if (v is! int || v < 0) throw VaultError.corrupt;
    if (v > VaultFormat.version) throw VaultError.tooNew;
    var map = json;
    for (var from = v; from < VaultFormat.version; from++) {
      map = VaultMigrations.envelope[from]!(map);
    }
    try {
      return _parse(map, sourceVersion: v);
    } on VaultError {
      rethrow;
    } catch (_) {
      throw VaultError.corrupt;
    }
  }

  static VaultEnvelope _parse(
    Map<String, Object?> json, {
    required int sourceVersion,
  }) {
    final kind = json['kind'];
    if (kind != VaultFormat.kindVault && kind != VaultFormat.kindBackup) {
      throw VaultError.corrupt;
    }
    final vaultId = json['vault_id'];
    if (vaultId is! String) throw VaultError.corrupt;
    _b64(vaultId, VaultFormat.idBytes);
    final kdf = _map(json['kdf']);
    if (kdf['alg'] != KdfRecord.alg) throw VaultError.corrupt;
    final ops = kdf['ops'];
    final mem = kdf['mem'];
    if (ops is! int || mem is! int) throw VaultError.corrupt;
    final salt = _b64(kdf['salt'], VaultFormat.saltBytes);
    final wrapPw = _box(
      json['wrap_pw'],
      exact: VaultFormat.keyBytes + VaultFormat.macBytes,
    );
    BioWrap? wrapBio;
    if (json.containsKey('wrap_bio')) {
      final bio = _map(json['wrap_bio']);
      final bioKind = bio['kind'];
      if (bioKind is! String || !VaultFormat.bioKinds.contains(bioKind)) {
        throw VaultError.corrupt;
      }
      wrapBio = BioWrap(
        bioKind,
        _box(bio, exact: VaultFormat.keyBytes + VaultFormat.macBytes),
      );
    }
    final rev = json['rev'];
    if (rev is! int || rev < 0) throw VaultError.corrupt;
    final index = _box(json['index'], maxB64: VaultFormat.maxIndexB64);
    final rawSecrets = _map(json['secrets']);
    if (rawSecrets.length > VaultFormat.maxEntries) throw VaultError.corrupt;
    final secrets = <String, SealedSecret>{};
    for (final MapEntry(:key, :value) in rawSecrets.entries) {
      if (!VaultIds.isEntryId(key)) throw VaultError.corrupt;
      final secret = _map(value);
      final r = secret['r'];
      if (r is! int || r < 1) throw VaultError.corrupt;
      secrets[key] = SealedSecret(
        _box(secret, maxB64: VaultFormat.maxSecretB64),
        r,
      );
    }
    return VaultEnvelope(
      kind: kind! as String,
      vaultId: vaultId,
      kdf: KdfRecord(ops: ops, mem: mem, salt: salt),
      wrapPw: wrapPw,
      wrapBio: wrapBio,
      rev: rev,
      index: index,
      secrets: secrets,
      sourceVersion: sourceVersion,
    );
  }

  static Map<String, Object?> _map(Object? value) {
    if (value is! Map<String, Object?>) throw VaultError.corrupt;
    return value;
  }

  static SealedBox _box(Object? value, {int? exact, int? maxB64}) {
    final map = _map(value);
    final nonce = _b64(map['n'], VaultFormat.nonceBytes);
    final c = map['c'];
    if (c is! String) throw VaultError.corrupt;
    if (exact != null && c.length != _b64Length(exact)) {
      throw VaultError.corrupt;
    }
    if (maxB64 != null && c.length > maxB64) throw VaultError.corrupt;
    final cipher = _b64(c, null);
    if (cipher.length < VaultFormat.macBytes) throw VaultError.corrupt;
    return SealedBox(nonce, cipher);
  }

  /// base64 с проверкой длины до декодирования.
  static Uint8List _b64(Object? value, int? bytes) {
    if (value is! String) throw VaultError.corrupt;
    if (bytes != null && value.length != _b64Length(bytes)) {
      throw VaultError.corrupt;
    }
    try {
      final decoded = base64.decode(value);
      if (bytes != null && decoded.length != bytes) throw VaultError.corrupt;
      return decoded;
    } on VaultError {
      rethrow;
    } catch (_) {
      throw VaultError.corrupt;
    }
  }

  static int _b64Length(int bytes) => ((bytes + 2) ~/ 3) * 4;

  @override
  String toString() => 'VaultEnvelope($kind, rev $rev)';
}

/// Разбор JSON из байтов с ограничением глубины и числа элементов до
/// выделения памяти под дерево. Любая ошибка — [VaultError.corrupt].
Object? _decodeJson(Uint8List bytes) {
  final String text;
  try {
    text = utf8.decode(bytes);
  } catch (_) {
    throw VaultError.corrupt;
  }
  if (!JsonLimits.within(
    text,
    maxDepth: VaultFormat.maxDepth,
    maxElements: VaultFormat.maxElements,
  )) {
    throw VaultError.corrupt;
  }
  try {
    return jsonDecode(text);
  } catch (_) {
    throw VaultError.corrupt;
  }
}

/// Быстрая проверка глубины вложенности и числа элементов JSON без
/// построения дерева.
abstract final class JsonLimits {
  /// JSON из байтов с пределами [VaultFormat.maxDepth] и
  /// [VaultFormat.maxElements]; любая ошибка — [VaultError.corrupt].
  static Object? decode(Uint8List bytes) => _decodeJson(bytes);

  static bool within(
    String text, {
    required int maxDepth,
    required int maxElements,
  }) {
    var depth = 0;
    var elements = 0;
    var inString = false;
    var escaped = false;
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (c == 0x5C) {
          escaped = true;
        } else if (c == 0x22) {
          inString = false;
        }
        continue;
      }
      switch (c) {
        case 0x22:
          inString = true;
        case 0x5B || 0x7B:
          if (++depth > maxDepth) return false;
          elements++;
        case 0x5D || 0x7D:
          depth--;
        case 0x2C:
          if (++elements > maxElements) return false;
      }
    }
    return true;
  }
}

/// Идентификаторы: id записи — 16 случайных байт в hex.
abstract final class VaultIds {
  static final RegExp _entry = RegExp(r'^[0-9a-f]{32}$');

  static bool isEntryId(String id) => _entry.hasMatch(id);

  static String hex(Uint8List bytes) =>
      bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Миграции `v → v+1`: чистые функции над JSON. Перед записью
/// мигрированной версии хранилище кладёт копию `vault.v<N>.bak`.
abstract final class VaultMigrations {
  /// Конверт: версия `from` → `from + 1`.
  static final Map<int, Map<String, Object?> Function(Map<String, Object?>)>
      envelope = <int, Map<String, Object?> Function(Map<String, Object?>)>{
    0: _envelope0to1,
  };

  /// Индекс: схема `from` → `from + 1`.
  static final Map<int, Map<String, Object?> Function(Map<String, Object?>)>
      index = <int, Map<String, Object?> Function(Map<String, Object?>)>{
    0: _index0to1,
  };

  /// v0 (только в тестах и ранних сборках): без `kind` — это хранилище.
  static Map<String, Object?> _envelope0to1(Map<String, Object?> json) =>
      <String, Object?>{
        ...json,
        'v': 1,
        'kind': VaultFormat.kindVault,
      };

  /// Схема 0: название записи — `title`, а не `service`.
  static Map<String, Object?> _index0to1(Map<String, Object?> json) {
    final entries = json['entries'];
    return <String, Object?>{
      ...json,
      'schema': 1,
      if (entries is List<Object?>)
        'entries': <Object?>[
          for (final entry in entries)
            if (entry is Map<String, Object?>)
              <String, Object?>{
                for (final MapEntry(:key, :value) in entry.entries)
                  if (key != 'title') key: value,
                if (!entry.containsKey('service') && entry['title'] != null)
                  'service': entry['title'],
              }
            else
              entry,
        ],
    };
  }
}

/// Дополнение тела до кратного [block]: длина — в первых 4 байтах (big
/// endian), дальше данные и нули.
abstract final class VaultPadding {
  static Uint8List pad(Uint8List data, int block) {
    final total = ((data.length + 4 + block - 1) ~/ block) * block;
    final out = Uint8List(total);
    ByteData.sublistView(out).setUint32(0, data.length);
    out.setRange(4, 4 + data.length, data);
    return out;
  }

  /// Данные без дополнения: вид на тот же буфер. Ошибка — `corrupt`.
  static Uint8List unpad(Uint8List padded, int block) {
    if (padded.length < 4 || padded.length % block != 0) {
      throw VaultError.corrupt;
    }
    final length = ByteData.sublistView(padded).getUint32(0);
    if (length > padded.length - 4) throw VaultError.corrupt;
    for (var i = 4 + length; i < padded.length; i++) {
      if (padded[i] != 0) throw VaultError.corrupt;
    }
    return Uint8List.sublistView(padded, 4, 4 + length);
  }
}

/// Откуда дата изменения пароля.
enum DateSource { user, import, unknown }

/// Запись индекса: всё, кроме пароля и заметки. [toString] — только id.
final class VaultEntry {
  VaultEntry({
    required this.id,
    required this.srev,
    required this.service,
    this.urls = const <String>[],
    this.aliases = const <String>[],
    this.login = '',
    this.hint = '',
    this.important = false,
    required this.created,
    required this.changed,
    this.dateSource = DateSource.user,
    required this.fp,
    this.fpLoose,
    this.fpOld = const <Uint8List>[],
    this.score,
    this.flags = const <String>[],
    this.train = const <String, Object?>{},
    this.extra = const <String, Object?>{},
  });

  /// Сколько прежних отпечатков хранится (самих паролей нет).
  static const int maxOldFingerprints = 5;

  final String id;

  /// Версия секрета: входит в AD шифротекста секрета.
  final int srev;
  final String service;
  final List<String> urls;
  final List<String> aliases;
  final String login;
  final String hint;
  final bool important;
  final DateTime created;
  final DateTime changed;
  final DateSource dateSource;

  /// Отпечаток пароля BLAKE2b с ключом `k_fp`.
  final Uint8List fp;
  final Uint8List? fpLoose;
  final List<Uint8List> fpOld;
  final int? score;
  final List<String> flags;
  final Map<String, Object?> train;

  /// Неизвестные поля записи: пишутся обратно как есть.
  final Map<String, Object?> extra;

  bool get hasHint => hint.isNotEmpty;

  VaultEntry copyWith({
    int? srev,
    String? service,
    List<String>? urls,
    List<String>? aliases,
    String? login,
    String? hint,
    bool? important,
    DateTime? changed,
    DateSource? dateSource,
    Uint8List? fp,
    Uint8List? fpLoose,
    List<Uint8List>? fpOld,
    int? score,
    List<String>? flags,
    Map<String, Object?>? train,
  }) =>
      VaultEntry(
        id: id,
        srev: srev ?? this.srev,
        service: service ?? this.service,
        urls: urls ?? this.urls,
        aliases: aliases ?? this.aliases,
        login: login ?? this.login,
        hint: hint ?? this.hint,
        important: important ?? this.important,
        created: created,
        changed: changed ?? this.changed,
        dateSource: dateSource ?? this.dateSource,
        fp: fp ?? this.fp,
        fpLoose: fpLoose ?? this.fpLoose,
        fpOld: fpOld ?? this.fpOld,
        score: score ?? this.score,
        flags: flags ?? this.flags,
        train: train ?? this.train,
        extra: extra,
      );

  static const Set<String> _known = <String>{
    'id',
    'srev',
    'service',
    'urls',
    'aliases',
    'login',
    'hint',
    'important',
    'created',
    'changed',
    'date_source',
    'fp',
    'fp_loose',
    'fp_old',
    'score',
    'flags',
    'train',
  };

  Map<String, Object?> toJson() => <String, Object?>{
        ...extra,
        'id': id,
        'srev': srev,
        'service': service,
        'urls': urls,
        'aliases': aliases,
        'login': login,
        'hint': hint,
        'important': important,
        'created': created.toUtc().toIso8601String(),
        'changed': changed.toUtc().toIso8601String(),
        'date_source': dateSource.name,
        'fp': base64.encode(fp),
        if (fpLoose != null) 'fp_loose': base64.encode(fpLoose!),
        'fp_old': <String>[for (final old in fpOld) base64.encode(old)],
        if (score != null) 'score': score,
        'flags': flags,
        'train': train,
      };

  /// Запись из индекса. Нарушение схемы — `corrupt`.
  static VaultEntry fromJson(Object? json) {
    if (json is! Map<String, Object?>) throw VaultError.corrupt;
    final id = json['id'];
    final srev = json['srev'];
    if (id is! String || !VaultIds.isEntryId(id)) throw VaultError.corrupt;
    if (srev is! int || srev < 1) throw VaultError.corrupt;
    final created = _date(json['created']);
    final changed = _date(json['changed']);
    final fpOld = _strings(json['fp_old'], VaultEntry.maxOldFingerprints)
        .map(_fp)
        .toList();
    final loose = json['fp_loose'];
    final score = json['score'];
    final train = json['train'];
    return VaultEntry(
      id: id,
      srev: srev,
      service: _text(json['service'], VaultFormat.maxService),
      urls: _strings(json['urls'], VaultFormat.maxUrls, VaultFormat.maxUrl),
      aliases: _strings(
        json['aliases'],
        VaultFormat.maxAliases,
        VaultFormat.maxService,
      ),
      login: _text(json['login'], VaultFormat.maxLogin),
      hint: _text(json['hint'], VaultFormat.maxHint),
      important: json['important'] == true,
      created: created,
      changed: changed,
      dateSource: DateSource.values
              .where((DateSource s) => s.name == json['date_source'])
              .firstOrNull ??
          DateSource.unknown,
      fp: _fp(json['fp']),
      fpLoose: loose == null ? null : _fp(loose),
      fpOld: fpOld,
      score: score is int && score >= 0 && score <= 4 ? score : null,
      flags: _strings(json['flags'], 32, 32),
      train: train is Map<String, Object?> ? train : const <String, Object?>{},
      extra: <String, Object?>{
        for (final MapEntry(:key, :value) in json.entries)
          if (!_known.contains(key)) key: value,
      },
    );
  }

  static String _text(Object? value, int max) {
    if (value == null) return '';
    if (value is! String || value.length > max) throw VaultError.corrupt;
    return value;
  }

  static List<String> _strings(Object? value, int count, [int max = 64]) {
    if (value == null) return const <String>[];
    if (value is! List<Object?> || value.length > count) {
      throw VaultError.corrupt;
    }
    return <String>[for (final item in value) _text(item, max)];
  }

  static DateTime _date(Object? value) {
    if (value is! String) throw VaultError.corrupt;
    final date = DateTime.tryParse(value);
    if (date == null) throw VaultError.corrupt;
    return date;
  }

  static Uint8List _fp(Object? value) =>
      VaultEnvelope._b64(value, VaultFormat.keyBytes);

  @override
  String toString() => 'VaultEntry($id)';
}

/// Расшифрованный индекс хранилища.
final class VaultIndex {
  VaultIndex({
    this.schema = VaultFormat.indexSchema,
    required this.rev,
    required this.kFp,
    this.backup = const <String, Object?>{},
    this.entries = const <VaultEntry>[],
    this.master = const <String, Object?>{},
    this.prefs = const <String, Object?>{},
    this.extra = const <String, Object?>{},
    this.migrated = false,
  });

  final int schema;

  /// Должен совпасть с внешним `rev` конверта.
  final int rev;

  /// Ключ отпечатков (32 байта): отдельный случайный ключ, переезжает с
  /// копией и не меняется при смене мастер-пароля.
  final SecretBytes kFp;
  final Map<String, Object?> backup;
  final List<VaultEntry> entries;

  /// `last_typed` — когда последний раз вводили мастер-пароль.
  final Map<String, Object?> master;

  /// Защитные настройки (раздел 9): только внутри индекса.
  final Map<String, Object?> prefs;

  /// Неизвестные поля индекса: пишутся обратно как есть.
  final Map<String, Object?> extra;

  /// Схема была старой и мигрирована при чтении.
  final bool migrated;

  VaultIndex copyWith({
    int? rev,
    List<VaultEntry>? entries,
    Map<String, Object?>? master,
    Map<String, Object?>? prefs,
    Map<String, Object?>? backup,
  }) =>
      VaultIndex(
        schema: schema,
        rev: rev ?? this.rev,
        kFp: kFp,
        backup: backup ?? this.backup,
        entries: entries ?? this.entries,
        master: master ?? this.master,
        prefs: prefs ?? this.prefs,
        extra: extra,
      );

  static const Set<String> _known = <String>{
    'schema',
    'rev',
    'k_fp',
    'backup',
    'entries',
    'master',
    'prefs',
  };

  /// Тело индекса до шифрования: JSON, дополненный до кратного 4 КиБ.
  Uint8List encodePadded() {
    final json = Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object?>{
          ...extra,
          'schema': VaultFormat.indexSchema,
          'rev': rev,
          'k_fp': base64.encode(kFp.unsafeBytes),
          'backup': backup,
          'entries': <Object?>[for (final e in entries) e.toJson()],
          'master': master,
          'prefs': prefs,
        }),
      ),
    );
    try {
      return VaultPadding.pad(json, VaultFormat.indexBlock);
    } finally {
      json.fillRange(0, json.length, 0);
    }
  }

  /// Индекс из расшифрованного тела. Буфер [padded] затирается.
  static VaultIndex decodePadded(Uint8List padded) {
    try {
      final body = VaultPadding.unpad(padded, VaultFormat.indexBlock);
      final json = _decodeJson(body);
      if (json is! Map<String, Object?>) throw VaultError.corrupt;
      final schema = json['schema'];
      if (schema is! int || schema < 0) throw VaultError.corrupt;
      if (schema > VaultFormat.indexSchema) throw VaultError.tooNew;
      var map = json;
      for (var from = schema; from < VaultFormat.indexSchema; from++) {
        map = VaultMigrations.index[from]!(map);
      }
      return _parse(map, migrated: schema != VaultFormat.indexSchema);
    } on VaultError {
      rethrow;
    } catch (_) {
      throw VaultError.corrupt;
    } finally {
      padded.fillRange(0, padded.length, 0);
    }
  }

  static VaultIndex _parse(
    Map<String, Object?> json, {
    required bool migrated,
  }) {
    final rev = json['rev'];
    if (rev is! int || rev < 0) throw VaultError.corrupt;
    final kFp = SecretBytes.adopt(
      VaultEnvelope._b64(json['k_fp'], VaultFormat.keyBytes),
    );
    final rawEntries = json['entries'];
    if (rawEntries is! List<Object?> ||
        rawEntries.length > VaultFormat.maxEntries) {
      kFp.wipe();
      throw VaultError.corrupt;
    }
    final List<VaultEntry> entries;
    try {
      entries = <VaultEntry>[
        for (final e in rawEntries) VaultEntry.fromJson(e),
      ];
    } catch (_) {
      kFp.wipe();
      rethrow;
    }
    final ids = <String>{for (final e in entries) e.id};
    if (ids.length != entries.length) {
      kFp.wipe();
      throw VaultError.corrupt;
    }
    Map<String, Object?> object(String key) {
      final value = json[key];
      return value is Map<String, Object?> ? value : const <String, Object?>{};
    }

    return VaultIndex(
      rev: rev,
      kFp: kFp,
      backup: object('backup'),
      entries: List<VaultEntry>.unmodifiable(entries),
      master: object('master'),
      prefs: object('prefs'),
      extra: <String, Object?>{
        for (final MapEntry(:key, :value) in json.entries)
          if (!_known.contains(key)) key: value,
      },
      migrated: migrated,
    );
  }

  @override
  String toString() => 'VaultIndex(rev $rev, ${entries.length})';
}

/// Расшифрованный секрет записи: пароль и заметка. Вызывающий затирает
/// оба поля ([wipe]).
final class VaultSecret {
  VaultSecret(this.password, this.note);

  final SecretBytes password;
  final SecretBytes note;

  void wipe() {
    password.wipe();
    note.wipe();
  }

  @override
  String toString() => 'VaultSecret(•••)';
}

/// Тело секрета `{"p":"…","note":"…"}`, собранное и разобранное
/// побайтно: значение ни разу не становится строкой Dart.
abstract final class SecretCodec {
  static const List<int> _open = <int>[
    0x7B, 0x22, 0x70, 0x22, 0x3A, 0x22, // {"p":"
  ];
  static const List<int> _middle = <int>[
    0x22, 0x2C, 0x22, 0x6E, 0x6F, 0x74, 0x65, 0x22, 0x3A, 0x22, // ","note":"
  ];
  static const List<int> _close = <int>[0x22, 0x7D]; // "}

  /// JSON, дополненный до кратного 256 байтам.
  static Uint8List encodePadded(SecretBytes password, SecretBytes note) {
    if (password.length > VaultFormat.maxPassword ||
        note.length > VaultFormat.maxNote) {
      throw ArgumentError('секрет длиннее предела');
    }
    final out = BytesBuilder(copy: false);
    final scratch = <Uint8List>[];
    Uint8List chunk(List<int> bytes) {
      final c = Uint8List.fromList(bytes);
      scratch.add(c);
      return c;
    }

    out.add(chunk(_open));
    out.add(_escape(password.unsafeBytes, scratch));
    out.add(chunk(_middle));
    out.add(_escape(note.unsafeBytes, scratch));
    out.add(chunk(_close));
    final json = out.takeBytes();
    try {
      return VaultPadding.pad(json, VaultFormat.secretBlock);
    } finally {
      json.fillRange(0, json.length, 0);
      for (final c in scratch) {
        c.fillRange(0, c.length, 0);
      }
    }
  }

  static Uint8List _escape(Uint8List bytes, List<Uint8List> scratch) {
    final out = Uint8List(bytes.length * 6);
    scratch.add(out);
    var n = 0;
    for (final b in bytes) {
      final short = switch (b) {
        0x22 || 0x5C => b,
        0x0A => 0x6E, // \n
        0x0D => 0x72, // \r
        0x09 => 0x74, // \t
        0x08 => 0x62, // \b
        0x0C => 0x66, // \f
        _ => 0,
      };
      if (short != 0) {
        out[n++] = 0x5C;
        out[n++] = short;
      } else if (b < 0x20) {
        const hex = '0123456789abcdef';
        out[n++] = 0x5C;
        out[n++] = 0x75;
        out[n++] = 0x30;
        out[n++] = 0x30;
        out[n++] = hex.codeUnitAt(b >> 4);
        out[n++] = hex.codeUnitAt(b & 15);
      } else {
        out[n++] = b;
      }
    }
    return Uint8List.sublistView(out, 0, n);
  }

  /// Пароль и заметка из расшифрованного тела. Буфер [padded] затирается.
  static VaultSecret decodePadded(Uint8List padded) {
    try {
      final body = VaultPadding.unpad(padded, VaultFormat.secretBlock);
      var i = 0;
      void expect(List<int> literal) {
        for (final b in literal) {
          if (i >= body.length || body[i++] != b) throw VaultError.corrupt;
        }
      }

      expect(_open);
      final (password, afterPassword) = _unescape(body, i);
      i = afterPassword;
      try {
        expect(_middle);
        final (note, afterNote) = _unescape(body, i);
        i = afterNote;
        try {
          expect(_close);
          if (i != body.length) throw VaultError.corrupt;
        } catch (_) {
          note.wipe();
          rethrow;
        }
        return VaultSecret(password, note);
      } catch (_) {
        password.wipe();
        rethrow;
      }
    } on VaultError {
      rethrow;
    } catch (_) {
      throw VaultError.corrupt;
    } finally {
      padded.fillRange(0, padded.length, 0);
    }
  }

  /// Строка JSON от [start] до закрывающей кавычки — в байты UTF-8.
  static (SecretBytes, int) _unescape(Uint8List body, int start) {
    final out = Uint8List(body.length);
    var n = 0;
    var i = start;
    int hex4() {
      if (i + 4 > body.length) throw VaultError.corrupt;
      var value = 0;
      for (var k = 0; k < 4; k++) {
        final c = body[i++];
        final d = switch (c) {
          >= 0x30 && <= 0x39 => c - 0x30,
          >= 0x61 && <= 0x66 => c - 0x57,
          >= 0x41 && <= 0x46 => c - 0x37,
          _ => throw VaultError.corrupt,
        };
        value = value * 16 + d;
      }
      return value;
    }

    void rune(int r) {
      if (r < 0x80) {
        out[n++] = r;
      } else if (r < 0x800) {
        out[n++] = 0xC0 | (r >> 6);
        out[n++] = 0x80 | (r & 0x3F);
      } else if (r < 0x10000) {
        out[n++] = 0xE0 | (r >> 12);
        out[n++] = 0x80 | ((r >> 6) & 0x3F);
        out[n++] = 0x80 | (r & 0x3F);
      } else {
        out[n++] = 0xF0 | (r >> 18);
        out[n++] = 0x80 | ((r >> 12) & 0x3F);
        out[n++] = 0x80 | ((r >> 6) & 0x3F);
        out[n++] = 0x80 | (r & 0x3F);
      }
    }

    try {
      while (true) {
        if (i >= body.length) throw VaultError.corrupt;
        final b = body[i++];
        if (b == 0x22) {
          // Закрывающую кавычку разбирает вызывающий.
          i--;
          break;
        }
        if (b < 0x20) throw VaultError.corrupt;
        if (b != 0x5C) {
          out[n++] = b;
          continue;
        }
        if (i >= body.length) throw VaultError.corrupt;
        final e = body[i++];
        switch (e) {
          case 0x22 || 0x5C || 0x2F:
            out[n++] = e;
          case 0x62:
            out[n++] = 0x08;
          case 0x66:
            out[n++] = 0x0C;
          case 0x6E:
            out[n++] = 0x0A;
          case 0x72:
            out[n++] = 0x0D;
          case 0x74:
            out[n++] = 0x09;
          case 0x75:
            var r = hex4();
            if (r >= 0xD800 && r <= 0xDBFF) {
              if (i + 2 > body.length ||
                  body[i] != 0x5C ||
                  body[i + 1] != 0x75) {
                throw VaultError.corrupt;
              }
              i += 2;
              final low = hex4();
              if (low < 0xDC00 || low > 0xDFFF) throw VaultError.corrupt;
              r = 0x10000 + ((r - 0xD800) << 10) + (low - 0xDC00);
            } else if (r >= 0xDC00 && r <= 0xDFFF) {
              throw VaultError.corrupt;
            }
            rune(r);
          default:
            throw VaultError.corrupt;
        }
      }
      final secret = SecretBytes.copy(Uint8List.sublistView(out, 0, n));
      return (secret, i);
    } finally {
      out.fillRange(0, out.length, 0);
    }
  }
}
