import 'dart:convert';
import 'dart:io';

import '../secret_store.dart';
import 'manifest_format.dart';

/// Подключение к приложению с описанием `assistant/1`: склад halowarekeep,
/// потом expeora. Один слот — один коннектор и одна строка в «Настройки →
/// Подключения». Объявляются в коде ([ConnectionSlots]), а не в описании:
/// id коннектора, тексты каталога ответов и разбор фраз «Tridot» живут
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
    this.alsoAccepts = const <String>{},
  });

  /// Id коннектора: `warehouse`. Ключи секретов — `<id>.token`, `<id>.sid`;
  /// команды — `<id>.<id команды>`.
  final String id;

  /// «Склад».
  final String title;

  /// `app.id` описания: чужое описание слот не примет. По нему же
  /// называются файлы подключения (`connections/<appId>.json`) — и тогда,
  /// когда сервер называет себя одним из [alsoAccepts].
  final String appId;

  /// Другие `app.id` того же приложения: склад DepotDesk — продолжение
  /// halowarekeep, описание у него то же, а `app.id` — `depotdesk`
  /// (ADR-031). Файлы подключения остаются под [appId]: прежние
  /// подключения не теряются.
  final Set<String> alsoAccepts;

  /// Все `app.id`, которые слот принимает.
  Set<String> get appIds => <String>{appId, ...alsoAccepts};

  bool acceptsApp(Object? id) => id is String && appIds.contains(id);

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

/// Ключи входа для запроса: `token` (пароль склада) и `sid` (личный
/// ключ), только непустые. `null` — входа нет: нет пароля склада, а ключ
/// помощника без пароля ([ConnectionRecord.tokenless]) не выдан или
/// потерян.
Future<Map<String, String>?> readConnectionKeys(
  SecretStore secrets,
  ConnectionSlot slot,
  ConnectionRecord record,
) async {
  final token = await secrets.read(slot.tokenKey);
  final sid = await secrets.read(slot.sidKey);
  final hasToken = token != null && token.isNotEmpty;
  final hasSid = sid != null && sid.isNotEmpty;
  if (!hasToken && !(record.tokenless && hasSid)) return null;
  return <String, String>{
    if (hasToken) 'token': token,
    if (hasSid) 'sid': sid,
  };
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
    this.cachedFrom,
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
      cachedFrom: text('cached_from'),
    );
  }

  factory ManifestMeta.of(
    ManifestDescription description, {
    String? etag,
    String? lastModified,
    DateTime? fetchedAt,
    Uri? cachedFrom,
  }) =>
      ManifestMeta(
        version: description.version,
        fingerprint: description.fingerprint,
        etag: etag,
        lastModified: lastModified,
        fetchedAt: fetchedAt,
        commands: description.commands.length,
        cachedFrom: cachedFrom?.toString(),
      );

  /// То же описание, проверенное заново в [moment]: версия, `etag` и
  /// привязка кэша не меняются.
  ManifestMeta checkedAt(DateTime moment) => ManifestMeta(
        version: version,
        fingerprint: fingerprint,
        etag: etag,
        lastModified: lastModified,
        fetchedAt: moment,
        commands: commands,
        cachedFrom: cachedFrom,
      );

  final String? version;
  final String? fingerprint;
  final String? etag;
  final String? lastModified;
  final DateTime? fetchedAt;
  final int commands;

  /// Адрес `assistant.json`, с которого взят кэш описания сервера
  /// (`connections/<appId>.assistant.json`), а с ним `etag` и
  /// `last_modified`. `null` — кэша сервера нет: запись о встроенном
  /// описании. Кэш годится только серверу, с которого взят: описание
  /// одного склада не управляет другим (ADR-012).
  final String? cachedFrom;

  /// Кэш описания взят с [manifestUri].
  bool isCachedFrom(Uri? manifestUri) =>
      manifestUri != null && cachedFrom == manifestUri.toString();

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
        if (cachedFrom != null) 'cached_from': cachedFrom,
      };
}

/// Кто вошёл и что ему можно на сервере (`auth.me`, склад `ask_me`;
/// ADR-031). Не секрет: имя, роль, права. Хранится в записи подключения.
final class ConnectionMe {
  const ConnectionMe({
    this.name = '',
    this.role = '',
    this.perms,
    this.all = false,
    this.can = const <String>[],
    this.actions,
    this.at,
  });

  factory ConnectionMe.fromJson(Object? json) {
    final map = json is Map ? json : const <Object?, Object?>{};
    final perms = map['perms'];
    final actions = map['actions'];
    return ConnectionMe(
      name: _clean(map['name']),
      role: _clean(map['role']),
      perms: perms is List
          ? <String>[
              for (final p in perms.take(maxItems))
                if (p is String && _perm.hasMatch(p)) p,
            ]
          : null,
      all: map['all'] == true,
      can: <String>[
        if (map['can'] case final List<Object?> list)
          for (final item in list.take(maxItems))
            if (_clean(item) case final String t when t.isNotEmpty) t,
      ],
      actions: actions is bool ? actions : null,
      at: DateTime.tryParse(map['at'] is String ? map['at'] as String : ''),
    );
  }

  /// Ответ сервера `ask_me` (`{login, name, role, roleLabel, all, perms,
  /// can[{id,title}], actions}`) или вход по ссылке (`name`, `role`,
  /// `perms`). Поля [allField] и [permsField] — из `auth.me` описания.
  factory ConnectionMe.fromServer(
    Map<String, Object?> json, {
    String allField = 'all',
    String permsField = 'perms',
    DateTime? at,
  }) {
    final role = _clean(json['roleLabel']);
    final perms = json[permsField];
    final can = json['can'];
    final actions = json['actions'];
    return ConnectionMe(
      name: _clean(json['name']),
      role: role.isNotEmpty ? role : _clean(json['role']),
      perms: perms is List
          ? <String>[
              for (final p in perms.take(maxItems))
                if (p is String && _perm.hasMatch(p)) p,
            ]
          : null,
      all: json[allField] == true,
      can: <String>[
        if (can is List)
          for (final item in can.take(maxItems))
            if (item is Map && _clean(item['title']).isNotEmpty)
              _clean(item['title'])
            else if (item is String && _clean(item).isNotEmpty)
              _clean(item),
      ],
      actions: actions is bool ? actions : null,
      at: at,
    );
  }

  static const int maxItems = 40;

  static final RegExp _perm = RegExp(r'^[*a-z][a-z0-9_]{0,31}$');

  static final RegExp _controls = RegExp(
    '[\\u0000-\\u001f\\u007f\\u200e\\u200f\\u202a-\\u202e\\u2066-\\u2069]',
  );

  /// Строка сервера: одна строка без управляющих знаков, не длиннее 60.
  static String _clean(Object? value) {
    if (value is! String) return '';
    final text =
        value.replaceAll(_controls, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length > 60 ? '${text.substring(0, 59)}…' : text;
  }

  /// «Иван Петров».
  final String name;

  /// «Кладовщик» (`roleLabel`).
  final String role;

  /// Права роли на сервере: `moves`, `post`, `price`; `null` — сервер их
  /// не назвал (склад без `ask_me`).
  final List<String>? perms;

  /// Роли можно всё (администратор).
  final bool all;

  /// Что роли можно менять через помощника — заголовки сервера.
  final List<String> can;

  /// Действия через помощника включены на сервере (`ASSIST_ACTIONS`);
  /// `null` — сервер не сказал.
  final bool? actions;

  /// Когда спросили сервер.
  final DateTime? at;

  /// Права известны: сервер их назвал.
  bool get known => all || perms != null;

  /// Есть ли право [right]; `null` — неизвестно.
  bool? has(String right) {
    if (all) return true;
    final list = perms;
    if (list == null) return null;
    return list.contains(right) || list.contains('*');
  }

  bool get isEmpty =>
      name.isEmpty && role.isEmpty && perms == null && !all && can.isEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
        if (name.isNotEmpty) 'name': name,
        if (role.isNotEmpty) 'role': role,
        if (perms != null) 'perms': perms,
        if (all) 'all': true,
        if (can.isNotEmpty) 'can': can,
        if (actions != null) 'actions': actions,
        if (at != null) 'at': at!.toIso8601String(),
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
    this.me = const ConnectionMe(),
    this.scope = '',
    this.tokenless = false,
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
      me: ConnectionMe.fromJson(map['me']),
      scope: map['scope'] == 'assist' ? 'assist' : '',
      tokenless: map['scope'] == 'assist' && map['tokenless'] == true,
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

  /// Кто вошёл и его права (`ask_me`); пусто — сервер не сказал.
  final ConnectionMe me;

  /// `assist` — ключ только для вопросов помощнику (склад 1.4.62);
  /// пусто — полный ключ приложения (склад старше) или ключа нет.
  final String scope;

  bool get assistKey => scope == 'assist';

  /// Ключ помощника ходит без пароля склада: склад его не выдал
  /// (`tokenless`, DepotDesk 1.4.62 / halowarekeep 1.4.66) — на устройстве
  /// хранится только личный ключ.
  final bool tokenless;

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
    ConnectionMe? me,
    String? scope,
    bool? tokenless,
  }) =>
      ConnectionRecord(
        appId: appId,
        me: clearLogin ? me ?? const ConnectionMe() : me ?? this.me,
        scope: clearLogin ? scope ?? '' : scope ?? this.scope,
        tokenless:
            clearLogin ? tokenless ?? false : tokenless ?? this.tokenless,
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
        if (!me.isEmpty) 'me': me.toJson(),
        if (scope.isNotEmpty) 'scope': scope,
        if (tokenless) 'tokenless': true,
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
