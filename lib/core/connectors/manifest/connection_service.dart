import 'dart:async';
import 'dart:convert';

import '../../services/clock.dart';
import '../http_transport.dart';
import '../secret_store.dart';
import 'connection.dart';
import 'connection_texts.dart';
import 'description_authority.dart';
import 'manifest_connector.dart';
import 'manifest_fetch.dart';
import 'manifest_format.dart';
import 'manifest_text.dart';

/// Итог подключения, входа или обновления описания: текст для экрана.
/// В тексте никогда нет пароля, ключа или кода из ссылки.
final class ConnectionResult {
  const ConnectionResult.ok(this.message) : ok = true;

  const ConnectionResult.failed(this.message) : ok = false;

  final bool ok;
  final String message;
}

/// Ссылка входа из окна «Войти на телефоне» или «Подключить Связного»:
/// адрес приложения и одноразовый код.
final class QrLink {
  const QrLink(this.base, this.code);

  /// Адрес приложения с `/` в конце: там лежит `assistant.json`.
  final Uri base;

  /// 32 знака hex строчными. Секрет: не печатать.
  final String code;

  @override
  String toString() => 'QrLink($base)';
}

/// Ссылка или адрес не годятся: код ([problem]), а текст — у того, кто
/// показывает ([textFor]): разбор статический и не знает, куда входят.
final class ConnectionAddressException implements Exception {
  const ConnectionAddressException(this.problem);

  final AddressProblem problem;

  /// Текст склада — прежний.
  String get message => ConnectionTexts.warehouse.address(problem);

  /// Текст для подключения с текстами [texts].
  String textFor(ConnectionTexts texts) => texts.address(problem);

  @override
  String toString() => message;
}

/// Хранилище на устройстве не сработало: текст для экрана, без пути и
/// без секретов.
final class ConnectionStorageException implements Exception {
  const ConnectionStorageException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Подключение к приложению `assistant/1`: вход по ссылке и вручную,
/// обновление описания, выход (ADR-011). Секреты пишет только в
/// [SecretStore], состояние без секретов — в [ConnectionStore].
final class ConnectionService {
  ConnectionService({
    required this.connector,
    required HttpTransport transport,
    required SecretStore secrets,
    required ConnectionStore store,
    Clock clock = const SystemClock(),
    this.builtIn,
    this.pinned,
    this.fixedBase,
    DescriptionPick? pick,
    this.device = defaultDevice,
  })  : _transport = transport,
        _secrets = secrets,
        _store = store,
        _clock = clock {
    final initial = pick ??
        DescriptionAuthority.choose(
          builtIn: builtIn,
          pinned: pinned,
          server: identical(connector.description, builtIn) ||
                  identical(connector.description, pinned)
              ? null
              : connector.description,
          ownWords: _ownWords,
        );
    descriptionOrigin = initial.origin;
    descriptionReason = initial.reason;
    if (_pinnedAnchor) offered = initial.refused;
    connector
      // Действия с записью — только из встроенной копии (ADR-013), какое
      // бы описание ни было в работе для чтения.
      ..builtIn = builtIn
      ..onRecordChanged = (ConnectionRecord record) {
        final expired = record.failure == ConnectionFailure.expired &&
            _lastFailure != ConnectionFailure.expired;
        _lastFailure = record.failure;
        unawaited(_store.save(record).catchError((Object _) {}));
        // Ключ устарел — вход сменился: разрешение действий снимается.
        if (expired) _sessionChanged();
        _notify();
      }
      ..onStale = () {
        if (_refreshing) return;
        unawaited(refreshManifest());
      };
  }

  /// Подключение после перезапуска: состояние и кэш описания сервера из
  /// [store] и встроенная копия [builtIn]. Главное — встроенное: кэш
  /// сервера в работе, только если он новее и не шире по правам
  /// ([DescriptionAuthority]). Без описания коннектор не понимает фраз, но
  /// экран подключения работает.
  ///
  /// [pinned] — закреплённое описание приложения без встроенной копии
  /// (каталог подключений, ADR-043), взятое с [base]: опора вместо
  /// встроенного. Разбирается как описание сервера — действий с записью
  /// из него нет никогда. [base] — адрес приложения из каталога: вход с
  /// другого адреса это подключение не перенацеливает.
  static Future<ConnectionService> restore({
    required ConnectionSlot slot,
    required HttpTransport transport,
    required SecretStore secrets,
    required ConnectionStore store,
    String? builtIn,
    String? pinned,
    Uri? base,
    Clock clock = const SystemClock(),
    String device = defaultDevice,
  }) async {
    ConnectionRecord? record;
    String? cached;
    try {
      record = await store.load(slot.fileKey);
      cached = await store.loadManifest(slot.fileKey);
    } on Object {
      record = null;
      cached = null;
    }
    ManifestDescription? parse(
      String? source,
      Uri? origin, {
      bool builtIn = false,
    }) {
      if (source == null) return null;
      try {
        return ManifestDescription.parse(
          source,
          appIds: slot.appIds,
          manifestUri: origin,
          builtIn: builtIn,
        );
      } on ManifestException {
        return null;
      }
    }

    final ours = parse(builtIn, null, builtIn: true);
    // Закреплённое — никогда не как встроенное: `builtIn: true` включил бы
    // раздел `actions[]` (ADR-013).
    final pin = parse(pinned, base?.resolve('assistant.json'));
    // Кэш годится только серверу, с которого взят (`cached_from`): после
    // входа на другой склад чужое описание в работу не идёт.
    final from = record?.manifestUri;
    final bound =
        cached != null && (record?.manifest.isCachedFrom(from) ?? false);
    final server = bound ? parse(cached, from) : null;
    final pick = DescriptionAuthority.choose(
      builtIn: ours,
      pinned: pin,
      server: server,
      serverError: bound && server == null
          ? 'сохранённая копия не прошла проверку'
          : null,
      ownWords: ownWordsOf(slot),
    );
    if (record != null && (server == null || pick.refused != null)) {
      // Кэша этого сервера нет или он больше не годится: запись — о
      // встроенном описании, без `etag`, чтобы следующая проверка скачала
      // описание заново, а не получила «не изменилось».
      final meta = record.manifest;
      if (meta.etag != null ||
          meta.lastModified != null ||
          meta.cachedFrom != null) {
        final anchor = ours ?? pin;
        record = record.copyWith(
          manifest:
              anchor == null ? const ManifestMeta() : ManifestMeta.of(anchor),
        );
      }
    }
    final connector = ManifestConnector(
      slot: slot,
      transport: transport,
      secrets: secrets,
      description: pick.description,
      record: record,
    );
    return ConnectionService(
      connector: connector,
      transport: transport,
      secrets: secrets,
      store: store,
      clock: clock,
      builtIn: ours,
      pinned: pin,
      fixedBase: base,
      pick: pick,
      device: device,
    );
  }

  /// Слова самого приложения: название и обращения слота. Фразы его команд
  /// с них начинаться могут ([DescriptionAuthority.textProblems]).
  static Set<String> ownWordsOf(ConnectionSlot slot) => <String>{
        slot.title,
        for (final alias in slot.aliases) ...<String>[
          alias,
          ...alias.split(' '),
        ],
      };

  Set<String> get _ownWords => ownWordsOf(connector.slot);

  /// Как устройство называется на складе в списке подключённых Связных.
  static const String defaultDevice = 'Связной';

  /// Название этого устройства для сервера ([ManifestQr.device]): не
  /// длиннее 40 знаков, без управляющих.
  final String device;

  final ManifestConnector connector;
  final HttpTransport _transport;
  final SecretStore _secrets;
  final ConnectionStore _store;
  final Clock _clock;

  bool _refreshing = false;

  ConnectionFailure? _lastFailure;

  final List<void Function()> _sessionListeners = <void Function()>[];

  /// Вход сменился: новый вход по ссылке или вручную, «Войти под
  /// логином», выход, устаревший личный ключ. Владелец снимает разрешение
  /// действий с записью («Разрешить действия», ADR-013): оно привязано к
  /// входу, а не только к логину.
  void addSessionListener(void Function() listener) =>
      _sessionListeners.add(listener);

  void removeSessionListener(void Function() listener) =>
      _sessionListeners.remove(listener);

  void _sessionChanged() {
    for (final listener in List<void Function()>.of(_sessionListeners)) {
      listener();
    }
  }

  /// Почему последнее описание не принято; `null` — принято.
  String? manifestError;

  /// Встроенная копия описания (`assets/connectors/`) — главная (ADR-012).
  final ManifestDescription? builtIn;

  /// Закреплённое описание приложения без встроенной копии (ADR-043): то,
  /// что показали при подключении. Опора вместо [builtIn]; действий с
  /// записью в нём нет.
  final ManifestDescription? pinned;

  /// Адрес приложения из каталога подключений: вход по ссылке или вручную
  /// с другого адреса не перенацеливает подключение (ADR-043). `null` —
  /// слот из кода (склад): адрес задаёт вход.
  final Uri? fixedBase;

  /// Опора выбора описания: встроенное, иначе закреплённое.
  ManifestDescription? get anchor => builtIn ?? pinned;

  bool get _pinnedAnchor => builtIn == null && pinned != null;

  /// Новое описание сервера расширяет права или вход приложения с
  /// закреплённым описанием — чем именно; в работе закреплённое
  /// (ADR-043). Экран подключения предложит посмотреть и подключить
  /// заново. `null` — предложений нет.
  String? offered;

  /// Какое описание в работе: встроенное или с сервера.
  late DescriptionOrigin descriptionOrigin;

  /// Почему в работе именно оно — для экрана подключения.
  late String descriptionReason;

  /// Причина выбора принятого описания — без приписки о не принятом
  /// новом.
  late String _acceptedReason = descriptionReason;

  /// Что делать с ответом сервера [fetched] с адреса [manifestUri]
  /// (ADR-012). Ничего не меняет: решение применяет [_commit].
  ///
  /// Описание сервера принято (разобралось и не расширяет права) — выбор
  /// между ним и встроенным, оно идёт в кэш. Не принято — в кэш не идёт и
  /// ничего не заменяет: если кэш описания взят с этого же адреса, всё
  /// остаётся как было (описание в работе, кэш, запись с её `etag`), иначе
  /// в работе встроенное. Так состояние сейчас и после перезапуска
  /// одинаково.
  _Decision _decide(Uri manifestUri, ManifestFetched fetched) {
    final server = fetched.description;
    if (server != null) {
      final pick = DescriptionAuthority.choose(
        builtIn: builtIn,
        pinned: pinned,
        server: server,
        ownWords: _ownWords,
      );
      final refused = pick.refused;
      if (refused == null) {
        return _Decision(
          pick,
          ManifestMeta.of(
            server,
            etag: fetched.etag,
            lastModified: fetched.lastModified,
            fetchedAt: _clock.now(),
            cachedFrom: manifestUri,
          ),
          cache: server.source,
        );
      }
      return _keep(manifestUri, refused, offer: refused);
    }
    return _keep(manifestUri, fetched.rejected ?? 'описание не получено');
  }

  /// Описание сервера не принято ([why]): прежнее остаётся.
  _Decision _keep(Uri manifestUri, String why, {String? offer}) {
    final now = _clock.now();
    final current = connector.description;
    if (current != null && record.manifest.isCachedFrom(manifestUri)) {
      final reason = _acceptedReason.replaceFirst(RegExp(r'\.$'), '');
      return _Decision(
        DescriptionPick(
          current,
          descriptionOrigin,
          '$reason; новое описание сервера не принято ($why).',
        ),
        record.manifest.checkedAt(now),
        error: why,
        kept: true,
        offer: offer,
      );
    }
    final pick = DescriptionAuthority.choose(
      builtIn: builtIn,
      pinned: pinned,
      serverError: why,
    );
    final description = pick.description;
    return _Decision(
      pick,
      description == null
          ? ManifestMeta(fetchedAt: now)
          : ManifestMeta.of(description, fetchedAt: now),
      error: why,
      offer: offer,
    );
  }

  /// Применяет решение: кэш, описание в коннекторе, текст для экрана.
  /// Запись подключения ([_Decision.meta]) сохраняет вызывающий.
  Future<void> _commit(_Decision decision) async {
    if (decision.cache case final String source) {
      await _store.saveManifest(slot.fileKey, source);
    }
    if (_pinnedAnchor) offered = decision.offer;
    final pick = decision.pick;
    descriptionOrigin = pick.origin;
    descriptionReason = pick.reason;
    if (!decision.kept) _acceptedReason = pick.reason;
    final description = pick.description;
    if (description != null && !identical(description, connector.description)) {
      connector.load(description);
    }
    manifestError = decision.error == null
        ? null
        : 'Описание сервера не принято: ${decision.error}.';
  }

  ConnectionSlot get slot => connector.slot;

  /// Тексты для экрана: у склада — прежние, у приложения — с его именем.
  ConnectionTexts get texts => ConnectionTexts.of(slot);
  ConnectionRecord get record => connector.record;
  bool get connected => record.connected;
  ManifestDescription? get description => connector.description;

  final List<void Function()> _listeners = <void Function()>[];

  String? _signal;

  /// Строка сигналов склада для карточки подключения («Сегодня 3 прихода ·
  /// проверено в 14:05»): пишет [WarehouseSignals], пока приложение
  /// открыто; `null` — сигналов нет.
  String? get signal => _signal;

  set signal(String? value) {
    if (value == _signal) return;
    _signal = value;
    _notify();
  }

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _notify() {
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  /// Секреты не записались на устройство (диск полон, нет прав).
  static const String _notSaved = 'Не получилось сохранить пароль на '
      'устройстве (нет места или прав). Освободите место и подключите '
      'снова — по ссылке нужна новая.';

  static const String _notDeleted = 'Не получилось удалить пароль с '
      'устройства (нет прав на папку). Попробуйте выйти ещё раз.';

  /// Сколько ждать сервер при входе и проверке описания.
  static const Duration timeout = Duration(seconds: 15);

  /// Выход не должен держать экран: ответа ждём недолго.
  static const Duration logoutTimeout = Duration(seconds: 5);

  // ------------------------------------------------------------ адреса

  /// Адрес приложения из того, что ввёл человек: схема `https` (без неё
  /// подставляется), `http` — только для своей сети (`localhost`, `127.*`,
  /// `10.*`, `192.168.*`, `172.16–31.*`). Без логина в адресе, без
  /// параметров и «#»; страница `*.html`/`*.php` → её папка.
  static Uri baseOf(String input) {
    var text = input.trim();
    if (text.isEmpty) {
      throw const ConnectionAddressException(AddressProblem.empty);
    }
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(text)) {
      text = 'https://$text';
    }
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) {
      throw const ConnectionAddressException(AddressProblem.notUrl);
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') {
      throw const ConnectionAddressException(AddressProblem.scheme);
    }
    if (uri.userInfo.isNotEmpty) {
      throw const ConnectionAddressException(AddressProblem.userInfo);
    }
    if (scheme == 'http' && !isLocalHost(uri.host)) {
      throw const ConnectionAddressException(AddressProblem.httpRemote);
    }
    var path = uri.path;
    final last = path.split('/').last;
    if (last.contains('.')) path = path.substring(0, path.length - last.length);
    if (!path.endsWith('/')) path = '$path/';
    return Uri(
      scheme: scheme,
      host: uri.host.toLowerCase(),
      port: uri.hasPort ? uri.port : null,
      path: path,
    );
  }

  /// Адрес своей сети: там можно без https.
  static bool isLocalHost(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h == '::1' || h == '[::1]') return true;
    final parts = h.split('.');
    if (parts.length != 4) return false;
    final n = parts.map(int.tryParse).toList();
    if (n.any((int? x) => x == null || x < 0 || x > 255)) return false;
    return n[0] == 127 ||
        n[0] == 10 ||
        (n[0] == 192 && n[1] == 168) ||
        (n[0] == 172 && n[1]! >= 16 && n[1]! <= 31);
  }

  static final RegExp _qrCode = RegExp(r'^[0-9a-f]{32}$');

  /// Разбирает ссылку `https://<склад>/#qr=<32 hex>`: [param] — имя
  /// параметра (`auth.qr.link` описания, по умолчанию `qr`).
  static QrLink parseQrLink(String input, {String param = 'qr'}) {
    final text = input.trim();
    if (text.isEmpty) {
      throw const ConnectionAddressException(AddressProblem.linkEmpty);
    }
    if (isConnectLink(text)) return parseConnectLink(text);
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme) {
      throw const ConnectionAddressException(AddressProblem.notLink);
    }
    String? code;
    for (final part in <String>[uri.fragment, uri.query]) {
      if (part.isEmpty) continue;
      final Map<String, String> values;
      try {
        values = Uri.splitQueryString(part);
      } on Object {
        continue;
      }
      code ??= values[param];
    }
    if (code == null) {
      throw const ConnectionAddressException(AddressProblem.noCode);
    }
    final normalized = code.trim().toLowerCase();
    if (!_qrCode.hasMatch(normalized)) {
      throw const ConnectionAddressException(AddressProblem.badCode);
    }
    final base = baseOf(
      uri.replace(fragment: '', query: '').toString().replaceAll(
            RegExp(r'[?#]+$'),
            '',
          ),
    );
    return QrLink(base, normalized);
  }

  /// Схема ссылки «Открыть в Tridot» (ADR-031).
  static const String linkScheme = 'tridot';

  /// Похоже на `tridot://…`: такую ссылку разбирает только
  /// [parseConnectLink].
  static bool isConnectLink(String input) =>
      input.trim().toLowerCase().startsWith('$linkScheme:');

  static const int _maxLinkLength = 2048;

  /// Разбирает ссылку со страницы склада «Подключить Связного»:
  /// `tridot://connect?u=<адрес склада https://…/>&qr=<32 hex>[&for=assist]`.
  ///
  /// Строго: схема `tridot`, хост `connect`, без пути, логина, порта и
  /// «#»; только поля `u`, `qr` и `for`, каждое один раз; `u` — полный
  /// адрес `https://…` (или `http://` своей сети, [baseOf]) без
  /// параметров и «#»; код — ровно 32 знака hex строчными. Иначе —
  /// [ConnectionAddressException] с текстом для экрана, без кода.
  static QrLink parseConnectLink(String input) {
    const broken = ConnectionAddressException(AddressProblem.connectBroken);
    final text = input.trim();
    if (text.length > _maxLinkLength || text.contains(RegExp(r'\s'))) {
      throw broken;
    }
    final Uri uri;
    try {
      uri = Uri.parse(text);
    } on FormatException {
      throw broken;
    }
    if (uri.scheme.toLowerCase() != linkScheme ||
        uri.host.toLowerCase() != 'connect' ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasFragment ||
        !uri.hasQuery) {
      throw broken;
    }
    final Map<String, List<String>> fields;
    try {
      fields = uri.queryParametersAll;
    } on Object {
      throw broken;
    }
    const known = <String>{'u', 'qr', 'for'};
    if (fields.keys.any((String k) => !known.contains(k)) ||
        fields.values.any((List<String> v) => v.length != 1)) {
      throw broken;
    }
    final purpose = fields['for']?.single;
    if (purpose != null && purpose != 'assist') throw broken;
    final code = fields['qr']?.single ?? '';
    if (!_qrCode.hasMatch(code)) {
      throw const ConnectionAddressException(AddressProblem.connectCode);
    }
    final address = fields['u']?.single ?? '';
    final target = Uri.tryParse(address);
    if (target == null ||
        !RegExp(r'^https?://', caseSensitive: false).hasMatch(address) ||
        target.hasQuery ||
        target.hasFragment) {
      throw broken;
    }
    return QrLink(baseOf(address), code);
  }

  // -------------------------------------------------------- описание

  Future<ManifestFetched> _fetchManifest(Uri base, {ManifestMeta? known}) =>
      ManifestFetch.fetch(
        _transport,
        base,
        appIds: slot.appIds,
        known: known,
        // Описание того же приложения, не прошедшее проверку: есть
        // встроенное или закреплённое — работаем по нему (ADR-012).
        sameApp: anchor == null ? null : _sameApp,
        wait: timeout,
      );

  /// Ответ — описание этого приложения (`format` и `app.id` совпадают),
  /// пусть и не прошедшее проверку.
  bool _sameApp(String body) {
    final json = _object(body);
    if (json == null || json['format'] != ManifestDescription.format) {
      return false;
    }
    final app = json['app'];
    return app is Map && slot.acceptsApp(app['id']);
  }

  /// Проверяет описание на сервере заново: «Обновить описание» и раз в
  /// сутки в фоне. Не принятое описание (не прошло проверку, расширяет
  /// права) ничего не заменяет: ни описание в работе, ни кэш, ни запись с
  /// `etag` — после перезапуска в работе то же самое ([_decide]).
  Future<ConnectionResult> refreshManifest() async {
    final base = record.baseUri;
    if (base == null) {
      return ConnectionResult.failed(texts.notConnectedYet);
    }
    final manifestUri = base.resolve('assistant.json');
    _refreshing = true;
    try {
      // «Не изменилось» спрашиваем, только если кэш взят с этого адреса:
      // иначе сравнивать не с чем.
      final fetched = await _fetchManifest(
        base,
        known:
            record.manifest.isCachedFrom(manifestUri) ? record.manifest : null,
      );
      if (fetched.unchanged) {
        await _save(
          record.copyWith(manifest: record.manifest.checkedAt(_clock.now())),
        );
        manifestError = null;
        _notify();
        return const ConnectionResult.ok('Описание не изменилось.');
      }
      if (fetched.error != null) {
        manifestError = fetched.error;
        _notify();
        return ConnectionResult.failed(fetched.error!);
      }
      final decision = _decide(manifestUri, fetched);
      await _commit(decision);
      await _save(record.copyWith(manifest: decision.meta));
      _notify();
      if (decision.pick.description == null) {
        return const ConnectionResult.failed('Описание не получено.');
      }
      return ConnectionResult.ok(
        decision.error == null && descriptionOrigin == DescriptionOrigin.server
            ? 'Описание обновлено: версия ${decision.meta.label}.'
            : 'Описание проверено. В работе: $descriptionReason',
      );
    } finally {
      _refreshing = false;
    }
  }

  // ------------------------------------------------------------- вход

  /// Вход по ссылке из окна «Войти на телефоне»: описание, затем действие
  /// входа (`auth.qr` описания или встроенный профиль слота) — без пароля
  /// склада.
  Future<ConnectionResult> connectByLink(String link) async {
    final QrLink parsed;
    try {
      parsed = parseQrLink(link);
    } on ConnectionAddressException catch (error) {
      return ConnectionResult.failed(error.textFor(texts));
    }
    if (_otherAddress(parsed.base) case final String why) {
      return ConnectionResult.failed(why);
    }
    final fetched = await _fetchManifest(parsed.base);
    if (fetched.error != null) return ConnectionResult.failed(fetched.error!);
    final manifestUri = parsed.base.resolve('assistant.json');
    final decision = _decide(manifestUri, fetched);
    final description = decision.pick.description;
    if (description == null) {
      return const ConnectionResult.failed('Описание не получено.');
    }
    final qr = description.qr ?? anchor?.qr ?? slot.builtInQr;
    if (qr == null) {
      return const ConnectionResult.failed(
        'Это приложение не умеет вход по ссылке. Подключите его вручную.',
      );
    }
    if (!RegExp(qr.shape, caseSensitive: false).hasMatch(parsed.code)) {
      return const ConnectionResult.failed(
        'Код в ссылке не того вида — скопируйте ссылку заново.',
      );
    }
    if (!_authAllowed(description, 'qr', qr.action)) {
      return const ConnectionResult.failed(
        'Описание просит войти незнакомым действием — подключите вручную.',
      );
    }
    final response = await _post(
      description,
      ManifestConnector.actionUri(description, manifestUri, qr.action),
      const <String, String>{},
      <String, Object?>{
        // Постоянные поля — только знакомые (`scope: assist`), код — свой.
        for (final MapEntry(:key, :value) in qr.body.entries)
          if (ManifestDescription.constantFields[key]?.contains(value) ?? false)
            key: value,
        if (qr.device case final String field) field: _deviceLabel,
        qr.param: parsed.code,
      },
    );
    if (response == null) {
      return ConnectionResult.failed(texts.offlineRetry);
    }
    final json = _object(response.body);
    if (!response.isSuccess || json == null || json['ok'] != true) {
      final status = response.statusCode;
      final known = qr.errors['$status'] ?? slot.builtInQr?.errors['$status'];
      final said = _text(json?[description.errorField]);
      return ConnectionResult.failed(
        known ??
            (said.isNotEmpty
                ? texts.serverSaid(said)
                : texts.serverError(status)),
      );
    }
    final token = _text(json[qr.take['token'] ?? 'token']);
    final sid = _text(json[qr.take['sid'] ?? 'sid']);
    final login = _text(json[qr.take['login'] ?? 'login']);
    // Склад 1.4.62 отвечает `scope`; старый его не знает — ключ полный.
    final scope = json['scope'] == 'assist' ? 'assist' : '';
    // Ключу помощника новый склад пароль склада не отдаёт (tokenless):
    // хватает личного ключа. Старый склад пароль присылает — храним, как
    // прежде.
    if (token.isEmpty && (scope != 'assist' || sid.isEmpty)) {
      return ConnectionResult.failed(texts.noPasswordSent);
    }
    final previous = await _previousKey();
    try {
      await _saveConnection(
        base: parsed.base,
        decision: decision,
        token: token,
        sid: sid,
        login: login,
        scope: scope,
        me: ConnectionMe.fromServer(json, at: _clock.now()),
      );
    } on Object {
      await _forgetSecrets();
      return const ConnectionResult.failed(_notSaved);
    }
    // Прежний вход заменён: его ключ гасим на складе, а не оставляем
    // живым на 30 дней.
    await _dropKey(previous, except: sid);
    if (sid.isNotEmpty) await refreshMe();
    return ConnectionResult.ok(_connectedText(login));
  }

  /// Ключ помощника, уже полученный страницей склада (веб-помощник,
  /// ADR-032): страница того же адреса сама вызывает `assist_web_key`
  /// своим входом и передаёт ключ во фрейм. Пароль склада не нужен и не
  /// хранится (`tokenless`), прежний ключ на складе не гасится — его
  /// заменяет сам склад (один веб-ключ на вкладку). Описание — с сервера
  /// по [address]; не получилось — в работе встроенное. Затем «кто я»
  /// (`ask_me`): права и логин называет склад, [name] и [role] страницы —
  /// только до его ответа.
  Future<ConnectionResult> connectWithKey({
    required String address,
    required String sid,
    String login = '',
    String name = '',
    String role = '',
  }) async {
    final Uri base;
    try {
      base = baseOf(address);
    } on ConnectionAddressException catch (error) {
      return ConnectionResult.failed(error.textFor(texts));
    }
    if (_otherAddress(base) case final String why) {
      return ConnectionResult.failed(why);
    }
    final key = sid.trim();
    if (!_assistKey.hasMatch(key)) {
      return ConnectionResult.failed(texts.keyWrongShape);
    }
    final manifestUri = base.resolve('assistant.json');
    final fetched = await _fetchManifest(base);
    final decision = _decide(manifestUri, fetched);
    if (decision.pick.description == null) {
      return ConnectionResult.failed(fetched.error ?? 'Описание не получено.');
    }
    final user = login.trim().toLowerCase();
    try {
      await _saveConnection(
        base: base,
        decision: decision,
        token: '',
        sid: key,
        login: _loginShape.hasMatch(user) ? user : '',
        scope: 'assist',
        me: ConnectionMe.fromServer(
          <String, Object?>{'name': name, 'roleLabel': role},
          at: _clock.now(),
        ),
      );
    } on Object {
      await _forgetSecrets();
      return const ConnectionResult.failed(_notSaved);
    }
    final me = await refreshMe();
    if (!me.ok && record.failure == ConnectionFailure.expired) {
      return ConnectionResult.failed(me.message);
    }
    return ConnectionResult.ok(_connectedText(record.login ?? ''));
  }

  /// Ключ помощника от страницы склада: печатные знаки без пробелов.
  static final RegExp _assistKey = RegExp(r'^[A-Za-z0-9._~+/=-]{16,200}$');

  /// Логин сотрудника от страницы склада — только для записи до ответа
  /// `ask_me`.
  static final RegExp _loginShape = RegExp(r'^[a-z0-9._@-]{1,64}$');

  /// «Склад подключён: ivanov (Иван Петров, Кладовщик).»
  String _connectedText(String login) {
    final me = record.me;
    final who = <String>[
      if (me.name.isNotEmpty) me.name,
      if (me.role.isNotEmpty) me.role,
    ].join(', ');
    return texts.connected(login, who);
  }

  static final RegExp _deviceControls = RegExp(
    '[\\u0000-\\u001f\\u007f\\u200e\\u200f\\u202a-\\u202e\\u2066-\\u2069]',
  );

  /// [device] для сервера: одна строка, не длиннее 40 знаков.
  String get _deviceLabel {
    final text = device
        .replaceAll(_deviceControls, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.isEmpty) return defaultDevice;
    return text.length > 40 ? text.substring(0, 40) : text;
  }

  /// «Кто я и что мне можно» (`auth.me`, склад `ask_me`): имя, роль и
  /// права входа — в запись подключения, для карточки и проверки прав
  /// перед действием. Склад без `ask_me` (400) — прежние сведения
  /// остаются. Без личного ключа — ничего не спрашивает.
  Future<ConnectionResult> refreshMe() async {
    final description = this.description;
    final me = description?.me ?? anchor?.me;
    final base = record.manifestUri;
    if (description == null || me == null || base == null) {
      return ConnectionResult.failed(texts.noWho);
    }
    final keys = await readConnectionKeys(_secrets, slot, record);
    if (keys == null || keys['sid'] == null) {
      return const ConnectionResult.failed('Нужен вход под своим логином.');
    }
    // Только читающее действие из api.only (проверено при разборе) и не
    // запись ни при каком описании.
    if (!description.only.contains(me.action) ||
        ManifestDescription.writeNames.contains(me.action) ||
        ManifestDescription.checkNames.contains(me.action)) {
      return ConnectionResult.failed(texts.noWho);
    }
    final response = await _post(
      description,
      ManifestConnector.actionUri(description, base, me.action),
      keys,
      const <String, Object?>{},
    );
    if (response == null) {
      return ConnectionResult.failed(texts.offline);
    }
    final json = _object(response.body);
    if ((response.statusCode == 403 &&
            json?[description.needField] == 'login') ||
        (response.statusCode == 401 && record.tokenless)) {
      connector.markExpired(_clock.now());
      return const ConnectionResult.failed(
        'Личный ключ устарел — подключитесь заново.',
      );
    }
    if (!response.isSuccess || json == null || json['ok'] != true) {
      return ConnectionResult.failed(texts.noWho);
    }
    final got = ConnectionMe.fromServer(
      json,
      allField: me.all,
      permsField: me.perms,
      at: _clock.now(),
    );
    final login = _text(json['login']);
    await _save(
      record.copyWith(
        me: got,
        login: login.isEmpty ? null : login.toLowerCase(),
        lastOk: _clock.now(),
        clearFailure: true,
      ),
    );
    _notify();
    return const ConnectionResult.ok('Права обновлены.');
  }

  /// Вход вручную: адрес и «Пароль склада», по желанию — логин и пароль
  /// сотрудника. Пароль проверяется безвредным чтением из `api.only`;
  /// логин и пароль сотрудника не хранятся — только полученный ключ.
  Future<ConnectionResult> connectManual({
    required String address,
    required String password,
    String login = '',
    String pass = '',
  }) async {
    final Uri base;
    try {
      base = baseOf(address);
    } on ConnectionAddressException catch (error) {
      return ConnectionResult.failed(error.textFor(texts));
    }
    if (_otherAddress(base) case final String why) {
      return ConnectionResult.failed(why);
    }
    if (password.isEmpty) {
      return ConnectionResult.failed(texts.enterPassword);
    }
    final fetched = await _fetchManifest(base);
    if (fetched.error != null) return ConnectionResult.failed(fetched.error!);
    final decision = _decide(base.resolve('assistant.json'), fetched);
    final description = decision.pick.description;
    if (description == null) {
      return const ConnectionResult.failed('Описание не получено.');
    }
    final checked = await _checkToken(description, base, password);
    if (checked != null) return ConnectionResult.failed(checked);
    var sid = '';
    var scope = '';
    var tokenless = false;
    final user = login.trim();
    if (user.isNotEmpty) {
      final got = await _staffKey(description, base, password, user, pass);
      if (!got.ok) return got;
      sid = got.message;
      scope = _lastScope;
      tokenless = _lastTokenless;
    }
    final previous = await _previousKey();
    try {
      await _saveConnection(
        base: base,
        decision: decision,
        // Склад сказал «tokenless»: ключу помощника пароль склада не нужен —
        // на устройстве его не храним.
        token: tokenless ? '' : password,
        sid: sid,
        login: sid.isEmpty ? '' : user.toLowerCase(),
        scope: scope,
      );
    } on Object {
      await _forgetSecrets();
      return const ConnectionResult.failed(_notSaved);
    }
    await _dropKey(previous, except: sid);
    if (sid.isNotEmpty) await refreshMe();
    return ConnectionResult.ok(
      sid.isEmpty
          ? texts.connectedByPassword
          : texts.connected(user.toLowerCase(), ''),
    );
  }

  /// «Войти под логином», когда склад подключён только паролем.
  Future<ConnectionResult> loginStaff({
    required String login,
    required String pass,
  }) async {
    final description = this.description;
    final base = record.baseUri;
    final token = await _secrets.read(slot.tokenKey);
    if (description == null || base == null || token == null) {
      return ConnectionResult.failed(texts.connectFirst);
    }
    final user = login.trim();
    if (user.isEmpty) return const ConnectionResult.failed('Введите логин.');
    final got = await _staffKey(description, base, token, user, pass);
    if (!got.ok) return got;
    final tokenless = _lastTokenless;
    try {
      await _secrets.write(slot.sidKey, got.message);
    } on Object {
      return const ConnectionResult.failed(_notSaved);
    }
    if (tokenless) {
      try {
        await _secrets.delete(slot.tokenKey);
      } on Object {
        // Не удалился — пароль склада остаётся, как у старого склада.
      }
    }
    await _save(
      record.copyWith(
        login: user.toLowerCase(),
        level: ConnectionLevel.staff,
        clearFailure: true,
        me: const ConnectionMe(),
        scope: _lastScope,
        tokenless: tokenless,
      ),
    );
    _sessionChanged();
    _notify();
    await refreshMe();
    return ConnectionResult.ok('Вход выполнен: ${user.toLowerCase()}.');
  }

  /// Выход: ключ снимается и на сервере, если описание умеет
  /// (`auth.logout`, склад 1.4.56); ответ и ошибки сервера не важны —
  /// пароль и ключ удаляются с устройства всегда. Адрес и кэш описания
  /// остаются.
  ///
  /// [remote] `false` — ключ на складе уже погашен (веб-помощник: вышли
  /// из склада, ключ гаснет вместе со входом страницы) — запроса нет.
  Future<void> logout({bool remote = true}) async {
    // `credentials.sid.drop` (склад 1.4.63, `auth_out`), иначе
    // `auth.logout` (`sess_end`). Ответ не важен: 400/403 — ключ уже снят
    // или сервер старше, на устройстве удаляем всё равно.
    if (remote) await _dropKey(await _previousKey());
    // Каждый ключ удаляем отдельно: сбой одного не оставляет другой.
    Object? failed;
    for (final key in <String>[slot.tokenKey, slot.sidKey]) {
      try {
        await _secrets.delete(key);
      } on Object catch (error) {
        failed ??= error;
      }
    }
    if (failed != null) {
      // Пароль остался на устройстве: подключение не снимаем, человек
      // повторит выход.
      _notify();
      throw const ConnectionStorageException(_notDeleted);
    }
    await _save(
      record.copyWith(
        level: ConnectionLevel.none,
        clearLogin: true,
        clearHealth: true,
      ),
    );
    _sessionChanged();
    _notify();
  }

  // ---------------------------------------------------------- служебное

  /// Вход с адреса [base] для подключения из каталога с другим адресом
  /// ([fixedBase]): текст отказа; `null` — адрес тот же или слот из кода.
  String? _otherAddress(Uri base) {
    final fixed = fixedBase;
    if (fixed == null || fixed == base) return null;
    return 'Это подключение — к ${fixed.host}. Ссылка ведёт на другой адрес '
        '(${base.host}): другое приложение подключают заново, через '
        '«Подключить приложение».';
  }

  /// Ещё раз, перед самим запросом: действие входа — из
  /// [ManifestDescription.authActions] и не команда из `api.only`.
  static bool _authAllowed(ManifestDescription d, String role, String action) =>
      (ManifestDescription.authActions[role]?.contains(action) ?? false) &&
      !d.only.contains(action);

  /// `null` — пароль подошёл; иначе текст ошибки. Подошёл — только если
  /// безвредное чтение ответило 200 и JSON-объектом без `ok: false`:
  /// переадресация, 404 или страница вместо JSON — не тот адрес, 429 —
  /// «попробуйте позже». Без такой команды в описании пароль не проверить
  /// — и не сохраняем.
  Future<String?> _checkToken(
    ManifestDescription d,
    Uri base,
    String token,
  ) async {
    // Ни запись, ни расчёт действия пробой не бывают (ADR-013): правило
    // проверки описания это и так запрещает, здесь — ещё раз.
    final forbidden = <String>{
      ...ManifestDescription.writeNames,
      ...ManifestDescription.checkNames,
      ...d.act,
    };
    final probe = d.commands.where((ManifestCommand c) {
      final needs = d.access[c.access]?.needs ?? const <String>['token'];
      return c.call != null &&
          !forbidden.contains(c.call!.action) &&
          needs.every((String n) => n == 'token');
    }).firstOrNull;
    if (probe == null) {
      return texts.cannotCheck;
    }
    final response = await _post(
      d,
      ManifestConnector.actionUri(
        d,
        base.resolve('assistant.json'),
        probe.call!.action,
      ),
      <String, String>{'token': token},
      askBody(
        probe.call!.body,
        <String, String>{for (final name in probe.slots.keys) name: '0'},
        ManifestVars(_clock.now()),
      ),
    );
    if (response == null) {
      return texts.offlineAddress;
    }
    final status = response.statusCode;
    if (status == 401) return texts.passwordRejected;
    if (status == 429) return texts.busyAttempts;
    if ((status >= 300 && status < 400) || status == 404) {
      return texts.notThisApp(status);
    }
    if (!response.isSuccess) return texts.serverError(status);
    final json = _object(response.body);
    if (json == null) return texts.notJson;
    if (json['ok'] == false) return texts.passwordRejected;
    return null;
  }

  /// `scope` последнего ответа [_staffKey]: `assist` — склад подтвердил
  /// ключ только для помощника.
  String _lastScope = '';

  /// Склад ответил `tokenless`: ключу помощника пароль склада не нужен.
  bool _lastTokenless = false;

  /// Ключ нынешнего входа и как его снять на складе (`credentials.sid.drop`
  /// или `auth.logout`) — до того, как новый вход перепишет ключи.
  /// `null` — входа нет или описание выхода не умеет.
  Future<_DropKey?> _previousKey() async {
    final description = this.description;
    final logout = description?.signOut ?? anchor?.signOut;
    final base = record.manifestUri;
    if (!record.connected ||
        description == null ||
        logout == null ||
        base == null ||
        !_authAllowed(description, 'logout', logout.action)) {
      return null;
    }
    try {
      final credentials = <String, String>{};
      for (final name in logout.needs) {
        final value = await _secrets.read(slot.secretKey(name));
        if (value != null && value.isNotEmpty) {
          credentials[name] = value;
        } else if (!(name == 'token' && record.tokenless)) {
          return null;
        }
      }
      return _DropKey(
        description,
        ManifestConnector.actionUri(description, base, logout.action),
        credentials,
      );
    } on Object {
      return null;
    }
  }

  /// Гасит ключ [key] на складе. Ответ не важен: 400/403 — ключ уже снят
  /// или склад старше; нет связи — ключ истечёт сам. [except] — новый
  /// ключ: тот же самый не гасим.
  Future<void> _dropKey(_DropKey? key, {String? except}) async {
    if (key == null) return;
    if (except != null && key.credentials['sid'] == except) return;
    try {
      await _post(
        key.description,
        key.uri,
        key.credentials,
        const <String, Object?>{},
        wait: logoutTimeout,
      );
    } on Object {
      // Сервер недоступен — ключ истечёт сам.
    }
  }

  /// Личный ключ по логину и паролю (`credentials.sid.get`): в
  /// [ConnectionResult.message] успешного итога — сам ключ (не показывать).
  Future<ConnectionResult> _staffKey(
    ManifestDescription d,
    Uri base,
    String token,
    String login,
    String pass,
  ) async {
    final get = d.credentials['sid']?.get;
    if (get == null || !_authAllowed(d, 'login', get.action)) {
      return const ConnectionResult.failed(
        'Это приложение не умеет вход по логину.',
      );
    }
    final response = await _post(
      d,
      ManifestConnector.actionUri(
        d,
        base.resolve('assistant.json'),
        get.action,
      ),
      <String, String>{'token': token},
      askBody(
        get.body,
        <String, String>{'login': login, 'pass': pass},
        ManifestVars(_clock.now()),
      ),
    );
    if (response == null) {
      return ConnectionResult.failed(texts.offlineInternet);
    }
    if (response.statusCode == 401) {
      return ConnectionResult.failed(texts.passwordRejected);
    }
    final json = _object(response.body);
    if (!response.isSuccess || json == null) {
      return ConnectionResult.failed(texts.serverError(response.statusCode));
    }
    final locked = json['locked'];
    if (locked is num && locked > 0) {
      return ConnectionResult.failed(
        'Слишком много попыток — подождите '
        '${askPlural(locked, 'секунду,секунды,секунд')}.',
      );
    }
    final sid = _text(json[get.take]);
    _lastScope = json['scope'] == 'assist' ? 'assist' : '';
    _lastTokenless = _lastScope == 'assist' && json['tokenless'] == true;
    if (json['ok'] != true || sid.isEmpty) {
      final left = json['left'];
      return ConnectionResult.failed(
        left is num && json['known'] == true
            ? 'Неверный логин или пароль (осталось '
                '${askPlural(left, 'попытка,попытки,попыток')}).'
            : 'Неверный логин или пароль.',
      );
    }
    return ConnectionResult.ok(sid);
  }

  /// POST действия с ключами [credentials] по `auth.headers`; `null` —
  /// нет связи.
  Future<HttpResponseData?> _post(
    ManifestDescription description,
    Uri uri,
    Map<String, String> credentials,
    Map<String, Object?> body, {
    Duration wait = timeout,
  }) async {
    try {
      return await _transport.send(
        HttpRequestData(
          method: 'POST',
          uri: uri,
          headers: ManifestConnector.headersFor(description, credentials),
          body: jsonEncode(body),
          timeout: wait,
        ),
      );
    } on Object {
      return null;
    }
  }

  /// Подключение не записалось: не оставлять половину ключей.
  Future<void> _forgetSecrets() async {
    for (final key in <String>[slot.tokenKey, slot.sidKey]) {
      try {
        await _secrets.delete(key);
      } on Object {
        // Не удалилось — запись подключения не сохранена, ключ не зовётся.
      }
    }
  }

  Future<void> _saveConnection({
    required Uri base,
    required _Decision decision,
    required String token,
    required String sid,
    required String login,
    String scope = '',
    ConnectionMe me = const ConnectionMe(),
  }) async {
    if (token.isEmpty) {
      // Ключ помощника без пароля склада (tokenless): прежний пароль —
      // тоже долой.
      await _secrets.delete(slot.tokenKey);
    } else {
      await _secrets.write(slot.tokenKey, token);
    }
    if (sid.isEmpty) {
      await _secrets.delete(slot.sidKey);
    } else {
      await _secrets.write(slot.sidKey, sid);
    }
    await _commit(decision);
    await _save(
      ConnectionRecord(
        appId: slot.fileKey,
        baseUri: base,
        login: login.isEmpty ? null : login,
        level: sid.isEmpty ? ConnectionLevel.shared : ConnectionLevel.staff,
        manifest: decision.meta,
        lastOk: _clock.now(),
        me: sid.isEmpty ? const ConnectionMe() : me,
        scope: sid.isEmpty ? '' : scope,
        tokenless: token.isEmpty && sid.isNotEmpty && scope == 'assist',
      ),
    );
    _sessionChanged();
    _notify();
  }

  Future<void> _save(ConnectionRecord record) async {
    connector.record = record;
    try {
      await _store.save(record);
    } on Object {
      // Не записалось — подключение работает до перезапуска.
    }
  }

  static Map<String, Object?>? _object(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  static String _text(Object? value) => value is String ? value.trim() : '';
}

/// Что делать с ответом сервера: какое описание в работе, что записать о
/// нём в подключение и что положить в кэш.
final class _Decision {
  const _Decision(
    this.pick,
    this.meta, {
    this.cache,
    this.error,
    this.kept = false,
    this.offer,
  });

  final DescriptionPick pick;

  /// Описание сервера расширяет закреплённое: чем (ADR-043).
  final String? offer;

  /// Запись об описании для [ConnectionRecord.manifest].
  final ManifestMeta meta;

  /// Текст принятого описания сервера — в кэш; `null` — кэш не трогать.
  final String? cache;

  /// Почему описание сервера не принято; `null` — принято.
  final String? error;

  /// Прежнее описание осталось как было.
  final bool kept;
}

/// Ключ входа и действие выхода для него.
final class _DropKey {
  const _DropKey(this.description, this.uri, this.credentials);

  final ManifestDescription description;
  final Uri uri;
  final Map<String, String> credentials;
}
