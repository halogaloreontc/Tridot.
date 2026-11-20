import 'dart:convert';

import 'app_profile.dart';
import 'connection.dart';
import 'connection_slots.dart';

/// Приложение из каталога подключений (ADR-043): чужая CRM, подключённая
/// по адресу. Секретов здесь нет — только их имена, чтобы удалить их
/// поимённо: у [SecretStore] нет списка ключей.
final class DirectoryEntry {
  const DirectoryEntry({
    required this.id,
    required this.appId,
    required this.base,
    required this.addedAt,
    required this.profile,
    this.secretNames = const <String>[],
    this.problem,
    this.offered,
  });

  /// Id подключения: `[a-z][a-z0-9]{0,31}` ([ConnectionSlots.validId]).
  /// Им называются файлы (`connections/<id>.json`, `<id>.assistant.json`,
  /// `<id>.pinned.assistant.json`) и секреты (`<id>.token`, `<id>.sid`,
  /// `<id>.<имя>`). После удаления не выдаётся никогда.
  final String id;

  /// `app.id` описания.
  final String appId;

  /// Адрес приложения с `/` в конце: там лежит `assistant.json`.
  final Uri base;

  final DateTime addedAt;

  /// Как приложение называть: из описания или поправленный человеком.
  /// `null` — сохранённый профиль больше не проходит проверку ([problem]):
  /// приложение не отвечает, но удалить его можно.
  final AppProfile? profile;

  /// Имена секретов из `auth` описания (`token`, `sid`, свои заголовки):
  /// при удалении стираются `<id>.<имя>` для каждого.
  final List<String> secretNames;

  /// Почему запись не годится в работу; `null` — годится.
  final String? problem;

  /// Новое описание сервера расширяет закреплённое — чем именно
  /// (`ConnectionService.offered`). Хранится, чтобы предложение «подключить
  /// заново» пережило перезапуск: не принятое описание в кэш не идёт.
  /// `null` — предложений нет.
  final String? offered;

  /// Та же запись с другим [offered].
  DirectoryEntry withOffered(String? value) => DirectoryEntry(
        id: id,
        appId: appId,
        base: base,
        addedAt: addedAt,
        profile: profile,
        secretNames: secretNames,
        problem: problem,
        offered: value,
      );

  /// Предел текста [offered] в файле.
  static const int maxOffered = 400;

  static final RegExp _controls = RegExp(r'[\u0000-\u001f\u007f]');

  /// [offered] из файла: строка без управляющих знаков, не длиннее
  /// [maxOffered]; иначе `null`.
  static String? _offered(Object? raw) {
    if (raw is! String) return null;
    final text = raw.replaceAll(_controls, ' ').trim();
    if (text.isEmpty) return null;
    return text.length > maxOffered ? text.substring(0, maxOffered) : text;
  }

  /// Ключи секретов подключения: `<id>.token`, `<id>.sid` и по одному на
  /// каждое имя из [secretNames].
  Set<String> get secretKeys => <String>{
        '$id.token',
        '$id.sid',
        for (final name in secretNames) '$id.$name',
      };

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'appId': appId,
        'base': base.toString(),
        'addedAt': addedAt.toUtc().toIso8601String(),
        if (profile case final AppProfile p) 'profile': p.toJson(),
        if (secretNames.isNotEmpty) 'secretNames': secretNames,
        if (_offered(offered) case final String text) 'offered': text,
      };

  static final RegExp _secretName = RegExp(r'^[a-z][a-z0-9_]{0,31}$');

  /// Запись из файла каталога; `null` — запись битая (нет годного id или
  /// адреса). Профиль проверяется заново ([AppProfile.parse]) против
  /// [taken] — обращений других подключений.
  static DirectoryEntry? fromJson(
    Object? json, {
    Set<String> taken = const <String>{},
  }) {
    if (json is! Map) return null;
    final id = json['id'];
    final appId = json['appId'];
    final base = json['base'];
    if (id is! String || !ConnectionSlots.validId(id)) return null;
    if (appId is! String || appId.isEmpty) return null;
    final uri = base is String ? Uri.tryParse(base) : null;
    if (uri == null ||
        !uri.hasScheme ||
        uri.host.isEmpty ||
        !uri.path.endsWith('/')) {
      return null;
    }
    final parsed = AppProfile.parse(json['profile'], taken: taken);
    var profile = parsed.profile;
    String? problem;
    if (profile == null) {
      problem = 'профиль приложения не прошёл проверку';
    } else if (profile.appId != appId) {
      profile = null;
      problem = 'профиль от другого приложения';
    }
    final names = json['secretNames'];
    return DirectoryEntry(
      id: id,
      appId: appId,
      base: uri,
      addedAt: DateTime.tryParse(
            json['addedAt'] is String ? json['addedAt'] as String : '',
          ) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      profile: profile,
      secretNames: <String>[
        if (names is List)
          for (final name in names)
            if (name is String && _secretName.hasMatch(name)) name,
      ],
      problem: problem,
      offered: _offered(json['offered']),
    );
  }
}

/// Содержимое каталога подключений: живые приложения и id, выданные
/// когда-то и удалённые ([retired]): их не получит никто.
final class DirectorySnapshot {
  const DirectorySnapshot({
    this.entries = const <DirectoryEntry>[],
    this.retired = const <String>{},
  });

  final List<DirectoryEntry> entries;
  final Set<String> retired;

  static const String format = 'tridot-connections/1';

  /// Все id, которые новому подключению не достанутся: живые и удалённые.
  Set<String> get usedIds => <String>{
        for (final entry in entries) entry.id,
        ...retired,
      };

  DirectoryEntry? entry(String id) =>
      entries.where((DirectoryEntry e) => e.id == id).firstOrNull;

  String encode() => const JsonEncoder.withIndent('  ').convert(
        <String, Object?>{
          'format': format,
          'apps': <Object?>[for (final entry in entries) entry.toJson()],
          'retired': retired.toList()..sort(),
        },
      );

  /// Каталог из текста файла. Чужой формат или битый JSON — пустой
  /// каталог; битые записи пропускаются, но их id остаются выданными
  /// ([retired]), если его можно прочитать.
  static DirectorySnapshot decode(String? text) {
    if (text == null || text.trim().isEmpty) return const DirectorySnapshot();
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      return const DirectorySnapshot();
    }
    if (json is! Map || json['format'] != format) {
      return const DirectorySnapshot();
    }
    final retired = <String>{
      if (json['retired'] case final List<Object?> list)
        for (final id in list)
          if (id is String && ConnectionSlots.idPattern.hasMatch(id)) id,
    };
    final entries = <DirectoryEntry>[];
    final taken = <String>{};
    final seen = <String>{};
    for (final raw in json['apps'] is List ? json['apps'] as List : const []) {
      final entry = DirectoryEntry.fromJson(raw, taken: taken);
      if (entry == null) {
        if (raw is Map && raw['id'] is String) {
          final id = raw['id'] as String;
          if (ConnectionSlots.idPattern.hasMatch(id)) retired.add(id);
        }
        continue;
      }
      if (!seen.add(entry.id)) continue;
      entries.add(entry);
      if (entry.profile case final AppProfile p) {
        taken.addAll(<String>[
          p.name,
          ...p.addressing,
          if (p.inPhrase case final String phrase) phrase,
        ]);
      }
    }
    return DirectorySnapshot(entries: entries, retired: retired);
  }
}

/// Где лежит каталог подключений и закреплённые описания (ADR-043).
/// Склад здесь не хранится: его записи — прежние ([ConnectionStore]).
abstract interface class ConnectionDirectory {
  Future<DirectorySnapshot> load();

  Future<void> save(DirectorySnapshot snapshot);

  /// Закреплённое описание подключения [id]: ровно тот текст, что
  /// показали при подключении. `null` — нет.
  Future<String?> loadPinned(String id);

  Future<void> savePinned(String id, String source);

  /// Удаляет файлы подключения [id]: запись, кэш описания сервера и
  /// закреплённое описание. Ошибка удаления — исключение.
  Future<void> deleteFiles(String id);
}

/// Каталог в памяти: для тестов и сборок без файлов. [store] — записи и
/// кэш описаний, которые [deleteFiles] стирает вместе с закреплённым.
final class InMemoryConnectionDirectory implements ConnectionDirectory {
  InMemoryConnectionDirectory({this.store});

  final InMemoryConnectionStore? store;

  /// Текст каталога, как в файле.
  String? text;
  final Map<String, String> pinned = <String, String>{};

  @override
  Future<DirectorySnapshot> load() async => DirectorySnapshot.decode(text);

  @override
  Future<void> save(DirectorySnapshot snapshot) async {
    text = snapshot.encode();
  }

  @override
  Future<String?> loadPinned(String id) async => pinned[id];

  @override
  Future<void> savePinned(String id, String source) async {
    pinned[id] = source;
  }

  @override
  Future<void> deleteFiles(String id) async {
    pinned.remove(id);
    store?.records.remove(id);
    store?.manifests.remove(id);
  }
}
