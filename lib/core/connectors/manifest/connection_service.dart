import 'dart:async';
import 'dart:convert';

import '../../services/clock.dart';
import '../http_transport.dart';
import '../secret_store.dart';
import 'connection.dart';
import 'manifest_connector.dart';
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

/// Ссылка входа из окна «Войти на телефоне»: адрес приложения и
/// одноразовый код.
final class QrLink {
  const QrLink(this.base, this.code);

  /// Адрес приложения с `/` в конце: там лежит `assistant.json`.
  final Uri base;

  /// 32 знака hex строчными. Секрет: не печатать.
  final String code;

  @override
  String toString() => 'QrLink($base)';
}

/// Ссылка или адрес не годятся: текст для экрана.
final class ConnectionAddressException implements Exception {
  const ConnectionAddressException(this.message);

  final String message;

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
  })  : _transport = transport,
        _secrets = secrets,
        _store = store,
        _clock = clock {
    connector
      ..onRecordChanged = (ConnectionRecord record) {
        unawaited(_store.save(record).catchError((Object _) {}));
        _notify();
      }
      ..onStale = () {
        if (_refreshing) return;
        unawaited(refreshManifest());
      };
  }

  /// Подключение после перезапуска: состояние и кэш описания из [store],
  /// а если кэша нет или он битый — встроенная копия [builtIn]. Без
  /// описания коннектор не понимает фраз, но экран подключения работает.
  static Future<ConnectionService> restore({
    required ConnectionSlot slot,
    required HttpTransport transport,
    required SecretStore secrets,
    required ConnectionStore store,
    String? builtIn,
    Clock clock = const SystemClock(),
  }) async {
    ConnectionRecord? record;
    String? cached;
    try {
      record = await store.load(slot.appId);
      cached = await store.loadManifest(slot.appId);
    } on Object {
      record = null;
      cached = null;
    }
    ManifestDescription? description;
    for (final (source, origin) in <(String?, Uri?)>[
      (cached, record?.manifestUri),
      (builtIn, null),
    ]) {
      if (source == null) continue;
      try {
        description = ManifestDescription.parse(
          source,
          appId: slot.appId,
          manifestUri: origin,
        );
        break;
      } on ManifestException {
        continue;
      }
    }
    final connector = ManifestConnector(
      slot: slot,
      transport: transport,
      secrets: secrets,
      description: description,
      record: record,
    );
    return ConnectionService(
      connector: connector,
      transport: transport,
      secrets: secrets,
      store: store,
      clock: clock,
    );
  }

  final ManifestConnector connector;
  final HttpTransport _transport;
  final SecretStore _secrets;
  final ConnectionStore _store;
  final Clock _clock;

  bool _refreshing = false;

  /// Почему последнее описание не принято; `null` — принято.
  String? manifestError;

  ConnectionSlot get slot => connector.slot;
  ConnectionRecord get record => connector.record;
  bool get connected => record.connected;
  ManifestDescription? get description => connector.description;

  final List<void Function()> _listeners = <void Function()>[];

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
      throw const ConnectionAddressException('Укажите адрес склада.');
    }
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(text)) {
      text = 'https://$text';
    }
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) {
      throw const ConnectionAddressException('Адрес не похож на ссылку.');
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') {
      throw const ConnectionAddressException(
        'Нужен адрес https://… склада.',
      );
    }
    if (uri.userInfo.isNotEmpty) {
      throw const ConnectionAddressException(
        'Логин и пароль в адресе не указывают — для них есть поля ниже.',
      );
    }
    if (scheme == 'http' && !isLocalHost(uri.host)) {
      throw const ConnectionAddressException(
        'Без шифрования (http) можно только в своей сети. Для склада в '
        'интернете нужен адрес https://…',
      );
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
      throw const ConnectionAddressException(
        'Вставьте ссылку из окна «Войти на телефоне».',
      );
    }
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme) {
      throw const ConnectionAddressException(
        'Это не ссылка. Скопируйте её кнопкой «Скопировать ссылку» в окне '
        '«Войти на телефоне».',
      );
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
      throw const ConnectionAddressException(
        'В ссылке нет кода входа. Скопируйте её заново в окне «Войти на '
        'телефоне».',
      );
    }
    final normalized = code.trim().toLowerCase();
    if (!_qrCode.hasMatch(normalized)) {
      throw const ConnectionAddressException(
        'Код в ссылке обрезан или испорчен — скопируйте ссылку заново.',
      );
    }
    final base = baseOf(
      uri.replace(fragment: '', query: '').toString().replaceAll(
            RegExp(r'[?#]+$'),
            '',
          ),
    );
    return QrLink(base, normalized);
  }

  // -------------------------------------------------------- описание

  Future<_Fetched> _fetchManifest(Uri base, {ManifestMeta? known}) async {
    final uri = base.resolve('assistant.json');
    final headers = <String, String>{'Accept': 'application/json'};
    if (known?.etag case final String etag) headers['If-None-Match'] = etag;
    if (known?.lastModified case final String date) {
      headers['If-Modified-Since'] = date;
    }
    final HttpResponseData response;
    try {
      response = await _transport.send(
        HttpRequestData(
          method: 'GET',
          uri: uri,
          headers: headers,
          timeout: timeout,
        ),
      );
    } on TimeoutException {
      return const _Fetched.failed('Сервер не ответил вовремя.');
    } on Object {
      return const _Fetched.failed(
        'Нет связи с сервером. Проверьте адрес и интернет.',
      );
    }
    if (response.statusCode == 304) return const _Fetched.unchanged();
    if (response.statusCode == 404) {
      return const _Fetched.failed(
        'По этому адресу нет описания помощника (assistant.json).',
      );
    }
    if (!response.isSuccess) {
      return _Fetched.failed(
        'Сервер ответил ошибкой ${response.statusCode}.',
      );
    }
    try {
      final description = ManifestDescription.parse(
        response.body,
        appId: slot.appId,
        manifestUri: uri,
      );
      return _Fetched(
        description,
        ManifestMeta.of(
          description,
          etag: response.headers['etag'],
          lastModified: response.headers['last-modified'],
          fetchedAt: _clock.now(),
        ),
      );
    } on ManifestException catch (error) {
      return _Fetched.failed('Описание не принято: ${error.message}.');
    }
  }

  /// Проверяет описание на сервере заново: «Обновить описание» и раз в
  /// сутки в фоне. Битое описание не заменяет прежнее.
  Future<ConnectionResult> refreshManifest() async {
    final base = record.baseUri;
    if (base == null) {
      return const ConnectionResult.failed('Склад ещё не подключён.');
    }
    _refreshing = true;
    try {
      final fetched = await _fetchManifest(base, known: record.manifest);
      if (fetched.unchanged) {
        await _save(
          record.copyWith(
            manifest: ManifestMeta(
              version: record.manifest.version,
              fingerprint: record.manifest.fingerprint,
              etag: record.manifest.etag,
              lastModified: record.manifest.lastModified,
              fetchedAt: _clock.now(),
              commands: record.manifest.commands,
            ),
          ),
        );
        manifestError = null;
        _notify();
        return const ConnectionResult.ok('Описание не изменилось.');
      }
      final description = fetched.description;
      if (description == null) {
        manifestError = fetched.error;
        _notify();
        return ConnectionResult.failed(fetched.error!);
      }
      await _store.saveManifest(slot.appId, description.source);
      connector.load(description);
      manifestError = null;
      await _save(record.copyWith(manifest: fetched.meta));
      _notify();
      return ConnectionResult.ok(
        'Описание обновлено: версия ${fetched.meta!.label}.',
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
      return ConnectionResult.failed(error.message);
    }
    final fetched = await _fetchManifest(parsed.base);
    final description = fetched.description;
    if (description == null) {
      return ConnectionResult.failed(fetched.error ?? 'Описание не получено.');
    }
    final qr = description.qr ?? slot.builtInQr;
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
    final manifestUri = parsed.base.resolve('assistant.json');
    final response = await _post(
      description,
      ManifestConnector.actionUri(description, manifestUri, qr.action),
      const <String, String>{},
      <String, Object?>{qr.param: parsed.code},
    );
    if (response == null) {
      return const ConnectionResult.failed(
        'Нет связи со складом. Проверьте интернет и попробуйте снова.',
      );
    }
    final json = _object(response.body);
    if (!response.isSuccess || json == null || json['ok'] != true) {
      final status = response.statusCode;
      final known = qr.errors['$status'] ?? slot.builtInQr?.errors['$status'];
      final said = _text(json?[description.errorField]);
      return ConnectionResult.failed(
        known ??
            (said.isNotEmpty
                ? 'Склад ответил: $said'
                : 'Склад ответил ошибкой $status.'),
      );
    }
    final token = _text(json[qr.take['token'] ?? 'token']);
    final sid = _text(json[qr.take['sid'] ?? 'sid']);
    final login = _text(json[qr.take['login'] ?? 'login']);
    if (token.isEmpty) {
      return const ConnectionResult.failed(
        'Склад не прислал пароль — сделайте новую ссылку.',
      );
    }
    try {
      await _saveConnection(
        base: parsed.base,
        description: description,
        meta: fetched.meta!,
        token: token,
        sid: sid,
        login: login,
      );
    } on Object {
      await _forgetSecrets();
      return const ConnectionResult.failed(_notSaved);
    }
    return ConnectionResult.ok(
      login.isEmpty ? 'Склад подключён.' : 'Склад подключён: $login.',
    );
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
      return ConnectionResult.failed(error.message);
    }
    if (password.isEmpty) {
      return const ConnectionResult.failed('Введите пароль склада.');
    }
    final fetched = await _fetchManifest(base);
    final description = fetched.description;
    if (description == null) {
      return ConnectionResult.failed(fetched.error ?? 'Описание не получено.');
    }
    final checked = await _checkToken(description, base, password);
    if (checked != null) return ConnectionResult.failed(checked);
    var sid = '';
    final user = login.trim();
    if (user.isNotEmpty) {
      final got = await _staffKey(description, base, password, user, pass);
      if (!got.ok) return got;
      sid = got.message;
    }
    try {
      await _saveConnection(
        base: base,
        description: description,
        meta: fetched.meta!,
        token: password,
        sid: sid,
        login: sid.isEmpty ? '' : user.toLowerCase(),
      );
    } on Object {
      await _forgetSecrets();
      return const ConnectionResult.failed(_notSaved);
    }
    return ConnectionResult.ok(
      sid.isEmpty
          ? 'Склад подключён по паролю склада.'
          : 'Склад подключён: ${user.toLowerCase()}.',
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
      return const ConnectionResult.failed('Сначала подключите склад.');
    }
    final user = login.trim();
    if (user.isEmpty) return const ConnectionResult.failed('Введите логин.');
    final got = await _staffKey(description, base, token, user, pass);
    if (!got.ok) return got;
    try {
      await _secrets.write(slot.sidKey, got.message);
    } on Object {
      return const ConnectionResult.failed(_notSaved);
    }
    await _save(
      record.copyWith(
        login: user.toLowerCase(),
        level: ConnectionLevel.staff,
        clearFailure: true,
      ),
    );
    _notify();
    return ConnectionResult.ok('Вход выполнен: ${user.toLowerCase()}.');
  }

  /// Выход: ключ снимается и на сервере, если описание умеет
  /// (`auth.logout`, склад 1.4.56); ответ и ошибки сервера не важны —
  /// пароль и ключ удаляются с устройства всегда. Адрес и кэш описания
  /// остаются.
  Future<void> logout() async {
    final description = this.description;
    final logout = description?.logout;
    final base = record.manifestUri;
    try {
      if (description != null && logout != null && base != null) {
        final credentials = <String, String>{};
        var complete = true;
        for (final name in logout.needs) {
          final value = await _secrets.read(slot.secretKey(name));
          if (value == null || value.isEmpty) {
            complete = false;
          } else {
            credentials[name] = value;
          }
        }
        if (complete && _authAllowed(description, 'logout', logout.action)) {
          await _post(
            description,
            ManifestConnector.actionUri(description, base, logout.action),
            credentials,
            const <String, Object?>{},
            wait: logoutTimeout,
          );
        }
      }
    } on Object {
      // Сервер недоступен — ключ истечёт сам; на устройстве удаляем всё.
    }
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
    _notify();
  }

  // ---------------------------------------------------------- служебное

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
    final probe = d.commands.where((ManifestCommand c) {
      final needs = d.access[c.access]?.needs ?? const <String>['token'];
      return c.call != null && needs.every((String n) => n == 'token');
    }).firstOrNull;
    if (probe == null) {
      return 'Пароль не проверить: в описании нет команды по паролю склада.';
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
      return 'Нет связи со складом. Проверьте адрес и интернет.';
    }
    final status = response.statusCode;
    if (status == 401) return 'Склад не принял пароль.';
    if (status == 429) {
      return 'Склад просит подождать: слишком много попыток. Попробуйте '
          'через несколько минут.';
    }
    if ((status >= 300 && status < 400) || status == 404) {
      return 'По этому адресу не склад или он переехал (ответ $status). '
          'Проверьте адрес.';
    }
    if (!response.isSuccess) return 'Склад ответил ошибкой $status.';
    final json = _object(response.body);
    if (json == null) {
      return 'По этому адресу отвечает не склад (ответ не JSON). Проверьте '
          'адрес.';
    }
    if (json['ok'] == false) return 'Склад не принял пароль.';
    return null;
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
      return const ConnectionResult.failed(
        'Нет связи со складом. Проверьте интернет.',
      );
    }
    if (response.statusCode == 401) {
      return const ConnectionResult.failed('Склад не принял пароль.');
    }
    final json = _object(response.body);
    if (!response.isSuccess || json == null) {
      return ConnectionResult.failed(
        'Склад ответил ошибкой ${response.statusCode}.',
      );
    }
    final locked = json['locked'];
    if (locked is num && locked > 0) {
      return ConnectionResult.failed(
        'Слишком много попыток — подождите '
        '${askPlural(locked, 'секунду,секунды,секунд')}.',
      );
    }
    final sid = _text(json[get.take]);
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
    required ManifestDescription description,
    required ManifestMeta meta,
    required String token,
    required String sid,
    required String login,
  }) async {
    await _secrets.write(slot.tokenKey, token);
    if (sid.isEmpty) {
      await _secrets.delete(slot.sidKey);
    } else {
      await _secrets.write(slot.sidKey, sid);
    }
    await _store.saveManifest(slot.appId, description.source);
    connector.load(description);
    manifestError = null;
    await _save(
      ConnectionRecord(
        appId: slot.appId,
        baseUri: base,
        login: login.isEmpty ? null : login,
        level: sid.isEmpty ? ConnectionLevel.shared : ConnectionLevel.staff,
        manifest: meta,
        lastOk: _clock.now(),
      ),
    );
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

final class _Fetched {
  const _Fetched(this.description, this.meta)
      : error = null,
        unchanged = false;

  const _Fetched.failed(this.error)
      : description = null,
        meta = null,
        unchanged = false;

  const _Fetched.unchanged()
      : description = null,
        meta = null,
        error = null,
        unchanged = true;

  final ManifestDescription? description;
  final ManifestMeta? meta;
  final String? error;
  final bool unchanged;
}
