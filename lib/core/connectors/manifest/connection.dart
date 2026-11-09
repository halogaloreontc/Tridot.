import 'dart:convert';
import 'dart:io';

import 'manifest_format.dart';

/// Подключение к приложению с описанием `assistant/1`: склад halowarekeep,
/// потом expeora. Один слот — один коннектор и одна строка в «Настройки →
/// Подключения». Объявляются в коде ([ConnectionSlots]), а не в описании:
/// id коннектора, тексты каталога ответов и разбор фраз «Связного» живут
/// в приложении.
final class ConnectionSlot {
  const ConnectionSlot({
    required this.id,
    required this.title,
    required this.appId,
    required this.description,
    required this.aliases,
    required this.helpPhrases,
    required this.replies,
    required this.protectedReplies,
    this.builtInQr,
    this.builtInAsset,
    this.commandReplies = const <String, String>{},
  });

  /// Id коннектора: `warehouse`. Ключи секретов — `<id>.token`, `<id>.sid`;
  /// команды — `<id>.<id команды>`.
  final String id;

  /// «Склад».
  final String title;

  /// `app.id` описания: чужое описание слот не примет. По нему же
  /// называются файлы подключения (`connections/<appId>.json`).
  final String appId;

  /// Одно предложение для «Настройки → Подключения».
  final String description;

  /// Обращения к приложению в начале фразы: «склад, …», «на складе …».
  /// Снимают спор двух приложений без уточнения.
  final List<String> aliases;

  /// Свои фразы справки: «что умеет склад». Фразы `help` описания
  /// («привет», «помощь») слишком общие для помощника с задачами и беседой.
  final List<String> helpPhrases;

  /// Записи каталога ответов (docs/REPLIES.md): id `<id>.…`.
  final Map<String, String> replies;
  final Set<String> protectedReplies;

  /// Команда описания с ответом без сети (`reply`) → своя запись
  /// каталога (без `<id>.`): `price` → `price`. Текст описания нейтральный
  /// и на «вы»; запись каталога говорит голосом помощника. Команда без
  /// своей записи отвечает текстом описания (`<id>.reply`).
  final Map<String, String> commandReplies;

  /// Вход по ссылке, если в описании нет `auth.qr` (склад до 1.4.56).
  final ManifestQr? builtInQr;

  /// Встроенная копия описания в assets: по ней коннектор понимает фразы
  /// и до подключения.
  final String? builtInAsset;

  String get tokenKey => '$id.token';
  String get sidKey => '$id.sid';

  /// Ключ секрета `{$name}` из `auth.headers`.
  String secretKey(String name) => '$id.$name';
}

/// Уровень входа.
enum ConnectionLevel {
  /// Не подключено: нет пароля приложения.
  none,

  /// Только по общему паролю (`shared`): остатки и ячейки.
  shared,

  /// Под своим логином (`staff`): ещё и приходы.
  staff;

  static ConnectionLevel parse(Object? value) => ConnectionLevel.values
      .firstWhere((ConnectionLevel l) => l.name == value, orElse: () => none);
}

/// Что не так со связью: от этого «Как дела?».
enum ConnectionFailure {
  /// Нет связи с сервером, тайм-аут.
  offline,

  /// Сервер не принял пароль (401).
  token,

  /// Личный ключ устарел (403 `need: login` при сохранённом ключе).
  expired,

  /// Сервер отвечает ошибкой (5xx, не JSON).
  server;

  static ConnectionFailure? parse(Object? value) => ConnectionFailure.values
      .where((ConnectionFailure f) => f.name == value)
      .firstOrNull;
}

/// Откуда и когда взято описание.
final class ManifestMeta {
  const ManifestMeta({
    this.version,
    this.fingerprint,
    this.etag,
    this.lastModified,
    this.fetchedAt,
    this.commands = 0,
  });

  factory ManifestMeta.fromJson(Object? json) {
    final map = json is Map ? json : const <Object?, Object?>{};
    String? text(String key) => map[key] is String ? map[key] as String : null;
    return ManifestMeta(
      version: text('version'),
      fingerprint: text('fingerprint'),
      etag: text('etag'),
      lastModified: text('last_modified'),
      fetchedAt: DateTime.tryParse(text('fetched_at') ?? ''),
      commands: map['commands'] is int ? map['commands'] as int : 0,
    );
  }

  factory ManifestMeta.of(
    ManifestDescription description, {
    String? etag,
    String? lastModified,
    DateTime? fetchedAt,
  }) =>
      ManifestMeta(
        version: description.version,
        fingerprint: description.fingerprint,
        etag: etag,
        lastModified: lastModified,
        fetchedAt: fetchedAt,
        commands: description.commands.length,
      );

  final String? version;
  final String? fingerprint;
  final String? etag;
  final String? lastModified;
  final DateTime? fetchedAt;
  final int commands;

  /// Для экрана: «1.4.56» или «a1b2c3d4» (начало отпечатка).
  String get label =>
      version ?? (fingerprint == null ? '—' : fingerprint!.substring(0, 8));

  Map<String, Object?> toJson() => <String, Object?>{
        if (version != null) 'version': version,
        if (fingerprint != null) 'fingerprint': fingerprint,
        if (etag != null) 'etag': etag,
        if (lastModified != null) 'last_modified': lastModified,
        if (fetchedAt != null) 'fetched_at': fetchedAt!.toIso8601String(),
        'commands': commands,
      };
}

/// Состояние подключения без секретов: адрес, логин, уровень, описание,
/// здоровье. Хранится в `connections/<appId>.json`; пароль и ключ — только
/// в [SecretStore].
final class ConnectionRecord {
  const ConnectionRecord({
    required this.appId,
    this.baseUri,
    this.login,
    this.level = ConnectionLevel.none,
    this.manifest = const ManifestMeta(),
    this.lastOk,
    this.failure,
    this.failureSince,
  });

  factory ConnectionRecord.fromJson(String appId, Object? json) {
    final map = json is Map ? json : const <Object?, Object?>{};
    final base = map['base'];
    final health = map['health'] is Map
        ? map['health'] as Map
        : const <Object?, Object?>{};
    return ConnectionRecord(
      appId: appId,
      baseUri: base is String && base.isNotEmpty ? Uri.tryParse(base) : null,
      login: map['login'] is String && (map['login'] as String).isNotEmpty
          ? map['login'] as String
          : null,
      level: ConnectionLevel.parse(map['level']),
      manifest: ManifestMeta.fromJson(map['manifest']),
      lastOk: DateTime.tryParse(health['last_ok'] as String? ?? ''),
      failure: ConnectionFailure.parse(health['failure']),
      failureSince: DateTime.tryParse(health['since'] as String? ?? ''),
    );
  }

  final String appId;

  /// Адрес приложения: где лежит `assistant.json`.
  final Uri? baseUri;

  /// Логин сотрудника (не секрет).
  final String? login;
  final ConnectionLevel level;
  final ManifestMeta manifest;

  /// Последний успешный ответ сервера.
  final DateTime? lastOk;

  /// Последний сбой; `null` — после него был успех.
  final ConnectionFailure? failure;
  final DateTime? failureSince;

  bool get connected => level != ConnectionLevel.none;

  /// Адрес описания: `<адрес>/assistant.json`.
  Uri? get manifestUri => baseUri?.resolve('assistant.json');

  ConnectionRecord copyWith({
    Uri? baseUri,
    String? login,
    bool clearLogin = false,
    ConnectionLevel? level,
    ManifestMeta? manifest,
    DateTime? lastOk,
    ConnectionFailure? failure,
    DateTime? failureSince,
    bool clearFailure = false,
    bool clearHealth = false,
  }) =>
      ConnectionRecord(
        appId: appId,
        baseUri: baseUri ?? this.baseUri,
        login: clearLogin ? null : login ?? this.login,
        level: level ?? this.level,
        manifest: manifest ?? this.manifest,
        lastOk: clearHealth ? null : lastOk ?? this.lastOk,
        failure: clearFailure || clearHealth ? null : failure ?? this.failure,
        failureSince: clearFailure || clearHealth
            ? null
            : failureSince ?? this.failureSince,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'app': appId,
        if (baseUri != null) 'base': baseUri.toString(),
        if (login != null) 'login': login,
        'level': level.name,
        'manifest': manifest.toJson(),
        'health': <String, Object?>{
          if (lastOk != null) 'last_ok': lastOk!.toIso8601String(),
          if (failure != null) 'failure': failure!.name,
          if (failureSince != null) 'since': failureSince!.toIso8601String(),
        },
      };
}

/// Где лежат состояние подключений и кэш описаний. Ключ — `app.id`
/// приложения: у каждого своё (склад, expeora).
abstract interface class ConnectionStore {
  Future<ConnectionRecord?> load(String appId);

  Future<void> save(ConnectionRecord record);

  /// Текст кэшированного описания или `null`.
  Future<String?> loadManifest(String appId);

  Future<void> saveManifest(String appId, String source);
}

final class InMemoryConnectionStore implements ConnectionStore {
  final Map<String, String> records = <String, String>{};
  final Map<String, String> manifests = <String, String>{};

  @override
  Future<ConnectionRecord?> load(String appId) async {
    final text = records[appId];
    return text == null
        ? null
        : ConnectionRecord.fromJson(appId, jsonDecode(text));
  }

  @override
  Future<void> save(ConnectionRecord record) async {
    records[record.appId] = jsonEncode(record.toJson());
  }

  @override
  Future<String?> loadManifest(String appId) async => manifests[appId];

  @override
  Future<void> saveManifest(String appId, String source) async {
    manifests[appId] = source;
  }
}

/// Файлы в `<папка данных>/connections`: `<appId>.json` (состояние) и
/// `<appId>.assistant.json` (кэш описания). Повреждённый файл не мешает
/// запуску: подключение считается новым.
final class JsonConnectionStore implements ConnectionStore {
  JsonConnectionStore(this.directory);

  final String directory;
  Future<void> _writes = Future<void>.value();

  static final RegExp _safeId = RegExp(r'^[a-z][a-z0-9_-]{0,63}$');

  String _path(String appId, String suffix) {
    if (!_safeId.hasMatch(appId)) {
      throw ArgumentError.value(appId, 'appId', 'Неверный id приложения');
    }
    return '$directory${Platform.pathSeparator}$appId$suffix';
  }

  @override
  Future<ConnectionRecord?> load(String appId) async {
    final file = File(_path(appId, '.json'));
    try {
      if (!await file.exists()) return null;
      return ConnectionRecord.fromJson(
        appId,
        jsonDecode(await file.readAsString()),
      );
    } on Object {
      return null;
    }
  }

  @override
  Future<void> save(ConnectionRecord record) => _write(
        _path(record.appId, '.json'),
        const JsonEncoder.withIndent('  ').convert(record.toJson()),
      );

  @override
  Future<String?> loadManifest(String appId) async {
    final file = File(_path(appId, '.assistant.json'));
    try {
      return await file.exists() ? await file.readAsString() : null;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> saveManifest(String appId, String source) =>
      _write(_path(appId, '.assistant.json'), source);

  Future<void> _write(String path, String text) {
    final write = _writes.then((_) async {
      final file = File(path);
      await file.parent.create(recursive: true);
      final temporary = File('$path.tmp');
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(path);
    });
    _writes = write.catchError((Object _) {});
    return write;
  }
}
