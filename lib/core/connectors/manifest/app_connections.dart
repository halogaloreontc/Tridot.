import 'dart:async';
import 'dart:collection';

import '../../services/clock.dart';
import '../http_transport.dart';
import '../secret_store.dart';
import 'app_profile.dart';
import 'connection.dart';
import 'connection_directory.dart';
import 'connection_service.dart';
import 'connection_slots.dart';
import 'connection_texts.dart';
import 'description_authority.dart';
import 'manifest_fetch.dart';
import 'manifest_format.dart';

/// Итог «Подключить приложение» до сохранения ([AppConnections.probe]):
/// что лежит по адресу. Ничего не сохранено; секретов нет.
final class ProbeResult {
  const ProbeResult({
    this.base,
    this.description,
    this.profile,
    this.profileWarnings = const <String>[],
    this.knownSlot,
    this.existingId,
    this.problems = const <String>[],
  });

  /// Адрес приложения с `/` в конце; `null` — адрес не годится.
  final Uri? base;

  /// Описание, как оно пришло и прошло проверку формата; его текст
  /// ([ManifestDescription.source]) и закрепляется при подключении.
  final ManifestDescription? description;

  /// Как приложение называть: из полей `app` описания (или по
  /// `app.title`), проверенное против обращений подключённых приложений.
  final AppProfile? profile;

  /// Что из профиля отброшено и почему.
  final List<String> profileWarnings;

  /// Приложение знакомо коду (склад halowarekeep / DepotDesk): оно
  /// подключается своим слотом, а не как новое приложение.
  final ConnectionSlot? knownSlot;

  /// Это приложение (`app.id` и хост) уже подключено: id подключения.
  final String? existingId;

  /// Почему подключить нельзя; пусто — можно (если не [knownSlot] и не
  /// [existingId]).
  final List<String> problems;

  /// Можно подключить как новое приложение ([AppConnections.add]).
  bool get canAdd =>
      base != null &&
      description != null &&
      profile != null &&
      problems.isEmpty &&
      knownSlot == null &&
      existingId == null;
}

/// «Подключить» или «Удалить» не вышло: текст для экрана, без секретов.
final class AppConnectionException implements Exception {
  const AppConnectionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Подключения к приложениям: слоты из кода (склад) и приложения из
/// каталога подключений (ADR-039). Склад в каталоге не хранится — его
/// записи, файлы и ключи прежние.
///
/// После [add] и [remove] слушатели узнают об изменении: коннекторы и
/// реестр расширений пересобираются тем же путём, что при запуске
/// (`ConnectorAssembly`), между ходами диалога.
final class AppConnections {
  AppConnections({
    required HttpTransport transport,
    required SecretStore secrets,
    required ConnectionStore store,
    required ConnectionDirectory directory,
    List<ConnectionService> known = const <ConnectionService>[],
    Clock clock = const SystemClock(),
    String device = ConnectionService.defaultDevice,
    Set<String> Function()? reservedIds,
  })  : _transport = transport,
        _secrets = secrets,
        _store = store,
        _directory = directory,
        _clock = clock,
        _device = device,
        _reservedIds = reservedIds,
        known = List<ConnectionService>.unmodifiable(known) {
    _all.addAll(this.known);
  }

  final HttpTransport _transport;
  final SecretStore _secrets;
  final ConnectionStore _store;
  final ConnectionDirectory _directory;
  final Clock _clock;
  final String _device;
  final Set<String> Function()? _reservedIds;

  /// Подключения слотов из кода: склад.
  final List<ConnectionService> known;

  final List<ConnectionService> _runtime = <ConnectionService>[];
  final List<ConnectionService> _all = <ConnectionService>[];

  DirectorySnapshot _snapshot = const DirectorySnapshot();

  /// Подключения приложений из каталога, в порядке подключения.
  List<ConnectionService> get runtime =>
      List<ConnectionService>.unmodifiable(_runtime);

  /// Все подключения: сначала из кода, потом из каталога. Живой список:
  /// после [add] и [remove] он уже другой.
  List<ConnectionService> get services => UnmodifiableListView(_all);

  /// Записи каталога, в том числе не годные в работу
  /// ([DirectoryEntry.problem]).
  List<DirectoryEntry> get entries => _snapshot.entries;

  ConnectionService? byId(String id) =>
      _all.where((ConnectionService s) => s.slot.id == id).firstOrNull;

  /// Приложения, чьё новое описание сервера расширяет закреплённое: id
  /// подключения → чем (ADR-039). Экран подключения предложит посмотреть.
  Map<String, String> get offers => <String, String>{
        for (final service in _runtime)
          if (service.offered case final String what) service.slot.id: what,
      };

  final List<void Function()> _listeners = <void Function()>[];

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _changed() {
    ConnectionSlots.useRuntime(<ConnectionSlot>[
      for (final service in _runtime) service.slot,
    ]);
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  /// Каталог с диска и подключения из него — при запуске. Запись, чей
  /// профиль не прошёл проверку, остаётся в [entries] (её можно удалить),
  /// но коннектора у неё нет.
  Future<void> load() async {
    // Обращения прежних слотов каталога не мешают проверке их же
    // профилей при повторной загрузке.
    ConnectionSlots.useRuntime(const <ConnectionSlot>[]);
    _snapshot = await _directory.load();
    _all.removeWhere(_runtime.contains);
    _runtime.clear();
    for (final entry in _snapshot.entries) {
      final service = await _restore(entry);
      if (service != null) _runtime.add(service);
    }
    _all.addAll(_runtime);
    for (final service in _runtime) {
      unawaited(_keepOffer(service));
    }
    _changed();
  }

  Future<ConnectionService?> _restore(DirectoryEntry entry) async {
    final profile = entry.profile;
    if (profile == null) return null;
    final ConnectionSlot slot;
    try {
      slot = ConnectionSlot.generic(profile, entry.id);
    } on ArgumentError {
      return null;
    }
    final pinned = await _directory.loadPinned(entry.id);
    final service = await ConnectionService.restore(
      slot: slot,
      transport: _transport,
      secrets: _secrets,
      store: _store,
      pinned: pinned,
      base: entry.base,
      clock: _clock,
      device: _device,
    );
    // Не принятое описание в кэш не идёт: предложение — из каталога.
    service.offered ??= entry.offered;
    _follow(service);
    return service;
  }

  /// Предложение приложения ([ConnectionService.offered]) — в каталог:
  /// после перезапуска «Приложение предлагает изменения» не пропадает.
  void _follow(ConnectionService service) {
    void listener() => unawaited(_keepOffer(service));
    service.addListener(listener);
  }

  Future<void> _keepOffer(ConnectionService service) async {
    final id = service.slot.id;
    final entry = _snapshot.entry(id);
    if (entry == null || !_runtime.contains(service)) return;
    final offered = service.offered;
    if (entry.offered == offered) return;
    _snapshot = DirectorySnapshot(
      entries: <DirectoryEntry>[
        for (final e in _snapshot.entries)
          if (e.id == id) e.withOffered(offered) else e,
      ],
      retired: _snapshot.retired,
    );
    try {
      await _directory.save(_snapshot);
    } on Object {
      // Не записалось — предложение живёт до перезапуска.
    }
  }

  /// Названия и обращения подключённых приложений: новое их не займёт.
  Set<String> get _takenWords => <String>{
        for (final service in _all) ...<String>[
          service.slot.title,
          ...service.slot.aliases,
        ],
      };

  /// Id, которые новому подключению не достанутся: живые, удалённые
  /// когда-то, коннекторы и паки реестра.
  Set<String> get _takenIds => <String>{
        ..._snapshot.usedIds,
        for (final service in _all) service.slot.id,
        ...?_reservedIds?.call(),
      };

  // -------------------------------------------------------------- проба

  /// Что лежит по адресу [address] (адрес, ссылка входа или
  /// `tridot://connect`): описание `<адрес>/assistant.json` без фильтра
  /// `app.id` и без сохранения. Защиты — те же, что при входе
  /// ([ManifestFetch]): https или http своей сети, без переадресаций,
  /// пределы размера, `api.url` того же источника. Код из ссылки не
  /// читается и никуда не идёт.
  Future<ProbeResult> probe(String address) async {
    final Uri base;
    try {
      base = _baseOfInput(address);
    } on ConnectionAddressException catch (error) {
      return ProbeResult(
        problems: <String>[error.textFor(ConnectionTexts.app)],
      );
    }
    final fetched = await ManifestFetch.fetch(_transport, base);
    final description = fetched.description;
    if (description == null) {
      return ProbeResult(
        base: base,
        problems: <String>[fetched.error ?? 'Описание не получено.'],
      );
    }
    final appId = description.appId;
    if (!_appIdShape.hasMatch(appId)) {
      return ProbeResult(
        base: base,
        problems: const <String>[
          'В описании нет годного app.id — приложение не назвало себя.',
        ],
      );
    }
    final knownSlot = <ConnectionSlot>[
      ...ConnectionSlots.all,
      for (final service in known) service.slot,
    ].where((ConnectionSlot s) => s.acceptsApp(appId)).firstOrNull;
    if (knownSlot != null) {
      return ProbeResult(
        base: base,
        description: description,
        knownSlot: knownSlot,
      );
    }
    final existing = _snapshot.entries
        .where(
          (DirectoryEntry e) =>
              e.appId == appId &&
              e.base.host == base.host &&
              e.base.port == base.port,
        )
        .firstOrNull;
    final checked = profileOf(description);
    final problems = <String>[
      if (checked.profile == null)
        'Приложение не назвало себя (app.name, app.title) так, чтобы к нему '
            'можно было обращаться.',
      for (final problem in DescriptionAuthority.textProblems(
        description,
        ownWords: checked.profile?.words.toSet() ?? const <String>{},
      ))
        'Описание не годится: $problem.',
    ];
    return ProbeResult(
      base: base,
      description: description,
      profile: checked.profile,
      profileWarnings: checked.warnings,
      existingId: existing?.id,
      problems: problems,
    );
  }

  static final RegExp _appIdShape = RegExp(r'^[a-z][a-z0-9_-]{0,63}$');

  /// Адрес из того, что ввели: ссылка входа (`#qr=…`, `tridot://connect`)
  /// — только её адрес, код отбрасывается.
  static Uri _baseOfInput(String input) {
    final text = input.trim();
    if (ConnectionService.isConnectLink(text) ||
        RegExp(r'[#?&]qr=', caseSensitive: false).hasMatch(text)) {
      return ConnectionService.parseQrLink(text).base;
    }
    return ConnectionService.baseOf(text);
  }

  /// Профиль описания [description], проверенный против обращений
  /// подключённых приложений. Полей `app.name` нет — имя по `app.title`
  /// (несклоняемое); `app.name` есть, но занято — профиля нет.
  ({AppProfile? profile, List<String> warnings}) profileOf(
    ManifestDescription description,
  ) {
    final app = description.json['app'];
    final named = app is Map && app['name'] != null;
    final Object raw = named
        ? app
        : <String, Object?>{
            'id': description.appId,
            'name': description.appTitle,
          };
    final checked = AppProfile.parse(raw, taken: _takenWords);
    return (
      profile: checked.profile,
      warnings: checked.warnings,
    );
  }

  // ---------------------------------------------------------- подключить

  /// Подключает приложение из [probe] (ADR-039): проверяет профиль
  /// ([profile] — поправленный человеком, иначе из описания) против
  /// обращений подключённых приложений, выдаёт id (никогда не прежний),
  /// закрепляет показанное описание — ровно тот текст — и сохраняет
  /// запись. Вход (пароль, ссылка) — потом, экраном подключения. Не
  /// вышло — [AppConnectionException].
  Future<({ConnectionService service, List<String> warnings})> add(
    ProbeResult probe, {
    AppProfile? profile,
  }) async {
    final base = probe.base;
    final description = probe.description;
    if (probe.knownSlot != null) {
      throw AppConnectionException(
        'Это ${probe.knownSlot!.title.toLowerCase()} — он подключается в '
        'своей строке подключений.',
      );
    }
    if (probe.existingId != null) {
      throw const AppConnectionException('Это приложение уже подключено.');
    }
    if (base == null || description == null || probe.problems.isNotEmpty) {
      throw AppConnectionException(
        probe.problems.isEmpty
            ? 'Описание приложения не получено.'
            : probe.problems.join(' '),
      );
    }
    final wanted = profile ?? probe.profile;
    if (wanted == null || wanted.appId != description.appId) {
      throw const AppConnectionException(
        'Назовите приложение: как к нему обращаться.',
      );
    }
    final checked = AppProfile.parse(wanted.toJson(), taken: _takenWords);
    final accepted = checked.profile;
    if (accepted == null || (profile != null && checked.warnings.isNotEmpty)) {
      throw AppConnectionException(
        checked.warnings.isEmpty
            ? 'Такое имя не годится.'
            : checked.warnings.join('; '),
      );
    }
    final id = ConnectionSlots.idFor(description.appId, _takenIds);
    final slot = ConnectionSlot.generic(accepted, id);
    final entry = DirectoryEntry(
      id: id,
      appId: description.appId,
      base: base,
      addedAt: _clock.now(),
      profile: accepted,
      secretNames: secretNamesOf(description),
    );
    final before = _snapshot;
    // Сначала каталог: даже если дальше что-то не запишется, удаление
    // найдёт подключение и сотрёт всё поимённо.
    _snapshot = DirectorySnapshot(
      entries: <DirectoryEntry>[...before.entries, entry],
      retired: before.retired,
    );
    try {
      await _directory.save(_snapshot);
      await _directory.savePinned(id, description.source);
      await _store.save(ConnectionRecord(appId: slot.fileKey, baseUri: base));
    } on Object {
      _snapshot = DirectorySnapshot(
        entries: before.entries,
        retired: <String>{...before.retired, id},
      );
      try {
        await _directory.deleteFiles(id);
        await _directory.save(_snapshot);
      } on Object {
        // Каталог не записался: id в нём не выдан и на диске его нет.
      }
      throw const AppConnectionException(
        'Не получилось сохранить подключение на устройстве (нет места или '
        'прав).',
      );
    }
    final service = await ConnectionService.restore(
      slot: slot,
      transport: _transport,
      secrets: _secrets,
      store: _store,
      pinned: description.source,
      base: base,
      clock: _clock,
      device: _device,
    );
    _runtime.add(service);
    _all.add(service);
    _follow(service);
    _changed();
    return (service: service, warnings: checked.warnings);
  }

  static final RegExp _placeholder = RegExp(r'\{\$([a-z][a-z0-9_]{0,31})\}');
  static final RegExp _secretName = RegExp(r'^[a-z][a-z0-9_]{0,31}$');

  /// Имена секретов описания: данные для входа (`auth.credentials`),
  /// ключи уровней доступа и выхода, подстановки `{$имя}` в
  /// `auth.headers`.
  static List<String> secretNamesOf(ManifestDescription description) {
    final names = <String>{
      ...description.credentials.keys,
      for (final access in description.access.values) ...access.needs,
      ...?description.logout?.needs,
      for (final value in description.headers.values)
        for (final match in _placeholder.allMatches(value)) match.group(1)!,
    }.where(_secretName.hasMatch).toList()
      ..sort();
    return names;
  }

  // ------------------------------------------------------------ удалить

  /// Удаляет подключение [id] (ADR-039): выход на сервере, если он умеет,
  /// затем поимённо — секреты (`<id>.token`, `<id>.sid`, `<id>.<имя>`),
  /// запись, кэш и закреплённое описание, строка каталога. Id больше не
  /// выдаётся никому. `false` — что-то с устройства не стёрлось (подключение
  /// всё равно снято, а id не достанется новому адресу).
  Future<bool> remove(String id) async {
    final entry = _snapshot.entry(id);
    if (entry == null) {
      throw const AppConnectionException('Такого подключения нет.');
    }
    var clean = true;
    final service =
        _runtime.where((ConnectionService s) => s.slot.id == id).firstOrNull;
    if (service != null) {
      try {
        await service.logout();
      } on Object {
        clean = false;
      }
    }
    for (final key in entry.secretKeys) {
      try {
        await _secrets.delete(key);
      } on Object {
        clean = false;
      }
    }
    try {
      await _directory.deleteFiles(id);
    } on Object {
      clean = false;
    }
    _snapshot = DirectorySnapshot(
      entries: <DirectoryEntry>[
        for (final e in _snapshot.entries)
          if (e.id != id) e,
      ],
      retired: <String>{..._snapshot.retired, id},
    );
    try {
      await _directory.save(_snapshot);
    } on Object {
      clean = false;
    }
    if (service != null) {
      _runtime.remove(service);
      _all.remove(service);
    }
    _changed();
    return clean;
  }
}
