import 'dart:convert';

import 'manifest_text.dart';

/// Описание не принято: что именно не так.
final class ManifestException implements Exception {
  const ManifestException(this.errors);

  final List<String> errors;

  String get message => errors.join('; ');

  @override
  String toString() => 'Описание не принято: $message';
}

/// Поле фразы: `{q}`, `{cell}`.
final class ManifestSlot {
  const ManifestSlot({required this.type, this.label = '', this.shape});

  /// `text` — как есть, `cell` — заглавными, `int` — только цифры.
  final String type;
  final String label;

  /// Регулярное выражение для значения в общем виде (без учёта регистра).
  final String? shape;
}

/// Действие сервера и шаблон тела запроса.
final class ManifestCall {
  const ManifestCall({required this.action, this.body = const {}});

  final String action;
  final Map<String, Object?> body;
}

/// Команда описания.
final class ManifestCommand {
  const ManifestCommand({
    required this.id,
    required this.title,
    required this.say,
    required this.order,
    this.examples = const <String>[],
    this.slots = const <String, ManifestSlot>{},
    this.access,
    this.call,
    this.answer = const <String, Object?>{},
    this.reply,
    this.help = false,
  });

  final String id;
  final String title;
  final List<String> say;
  final List<String> examples;
  final Map<String, ManifestSlot> slots;

  /// Уровень доступа из `auth.access`: `shared`, `staff`.
  final String? access;
  final ManifestCall? call;

  /// `answer` как есть: шаблоны читает [ManifestView].
  final Map<String, Object?> answer;

  /// Ответ без сети («цены помощник пока не называет»).
  final String? reply;

  /// Список команд с примерами, без сети.
  final bool help;

  /// Порядок в описании: при равном весе раньше — первее.
  final int order;
}

/// Уровень доступа: подпись и нужные ключи.
final class ManifestAccess {
  const ManifestAccess({required this.label, required this.needs});

  final String label;
  final List<String> needs;
}

/// Вход по одноразовой ссылке (`auth.qr`, склад 1.4.56).
final class ManifestQr {
  const ManifestQr({
    required this.action,
    this.link = '#qr=',
    this.param = 'code',
    this.shape = r'^[0-9a-f]{32}$',
    this.take = const <String, String>{
      'token': 'token',
      'sid': 'sid',
      'login': 'login',
    },
    this.ttl = 120,
    this.errors = const <String, String>{},
  });

  final String link;
  final String shape;
  final String action;

  /// Поле тела запроса, в котором уходит код.
  final String param;

  /// Ключ → поле ответа: `token`, `sid`, `login`.
  final Map<String, String> take;
  final int ttl;

  /// Код ответа → текст: `410` → «Код устарел…».
  final Map<String, String> errors;

  /// Имя параметра ссылки: `#qr=` → `qr`.
  String get linkParam {
    final text = link.replaceFirst(RegExp(r'^[#?&]'), '');
    return text.endsWith('=') ? text.substring(0, text.length - 1) : text;
  }
}

/// Выход (`auth.logout`, склад 1.4.56): снять свой личный ключ на сервере.
final class ManifestLogout {
  const ManifestLogout({
    required this.action,
    this.needs = const <String>['token', 'sid'],
  });

  final String action;
  final List<String> needs;
}

/// Как получить личный ключ по логину и паролю (`credentials.sid.get`).
final class ManifestCredentialGet {
  const ManifestCredentialGet({
    required this.action,
    required this.body,
    required this.take,
  });

  final String action;
  final Map<String, Object?> body;
  final String take;
}

/// Ключ входа: `token` («Пароль склада»), `sid` («Личный ключ»).
final class ManifestCredential {
  const ManifestCredential({required this.label, this.get});

  final String label;
  final ManifestCredentialGet? get;
}

/// Описание приложения в формате `assistant/1` (`assistant.json`).
///
/// Только данные: образцы фраз, регулярные выражения `shape` и шаблоны
/// ответов. Чужой код не выполняется (ADR-005, ADR-011).
final class ManifestDescription {
  ManifestDescription._({
    required this.json,
    required this.source,
    required this.version,
    required this.appId,
    required this.appTitle,
    required this.about,
    required this.apiUrl,
    required this.method,
    required this.actionIn,
    required this.actionName,
    required this.only,
    required this.errorField,
    required this.needField,
    required this.headers,
    required this.credentials,
    required this.access,
    required this.qr,
    required this.logout,
    required this.fallback,
    required this.filler,
    required this.commands,
  });

  /// Формат, который понимает коннектор.
  static const String format = 'assistant/1';

  /// Пределы «Связного»: описание — недоверенные данные.
  static const int maxBytes = 256 * 1024;
  static const int maxCommands = 100;
  static const int maxPhrases = 50;
  static const int maxPhraseLength = 120;
  static const int maxShapeLength = 200;

  final Map<String, Object?> json;

  /// Текст файла, из которого разобрано описание.
  final String source;

  /// `version` описания (склад 1.4.56); `null` — в описании её нет.
  final String? version;
  final String appId;
  final String appTitle;
  final String about;
  final String apiUrl;
  final String method;
  final String actionIn;
  final String actionName;
  final List<String> only;
  final String errorField;
  final String needField;

  /// Заголовок → шаблон: `X-Wh-Token: {$token}`.
  final Map<String, String> headers;
  final Map<String, ManifestCredential> credentials;
  final Map<String, ManifestAccess> access;

  /// `auth.qr`; `null` — в описании нет (тогда — встроенный профиль слота).
  final ManifestQr? qr;

  /// `auth.logout`; `null` — выход только на устройстве.
  final ManifestLogout? logout;
  final String? fallback;
  final List<String> filler;
  final List<ManifestCommand> commands;

  ManifestCommand? command(String id) =>
      commands.where((ManifestCommand c) => c.id == id).firstOrNull;

  /// Короткий отпечаток текста описания (FNV-1a, 64 бита): показать версию,
  /// если в описании её нет. Не для защиты.
  String get fingerprint => fingerprintOf(source);

  static String fingerprintOf(String text) {
    var hash = BigInt.parse('cbf29ce484222325', radix: 16);
    final prime = BigInt.parse('100000001b3', radix: 16);
    final mask = (BigInt.one << 64) - BigInt.one;
    for (final byte in utf8.encode(text)) {
      hash = ((hash ^ BigInt.from(byte)) * prime) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  /// Разбирает и проверяет описание. [appId] — какое приложение ждёт
  /// слот; [manifestUri] — откуда описание пришло: `api.url` обязан быть
  /// того же источника (схема, хост, порт), иначе пароль ушёл бы на чужой
  /// хост. Любая ошибка — [ManifestException] со всеми найденными.
  static ManifestDescription parse(
    String source, {
    String? appId,
    Uri? manifestUri,
  }) {
    if (utf8.encode(source).length > maxBytes) {
      throw const ManifestException(<String>['файл больше 256 КБ']);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const ManifestException(<String>['это не JSON']);
    }
    if (decoded is! Map<String, Object?>) {
      throw const ManifestException(<String>['описание — не объект']);
    }
    final errors = check(decoded, appId: appId, manifestUri: manifestUri);
    if (errors.isNotEmpty) throw ManifestException(errors);
    return _build(decoded, source);
  }

  /// Проверка как `askCheck` из core.mjs плюс пределы «Связного». Пустой
  /// список — описанием можно пользоваться.
  static List<String> check(
    Object? desc, {
    String? appId,
    Uri? manifestUri,
  }) {
    if (desc is! Map) return const <String>['описание — не объект'];
    final errs = <String>[];
    void bad(String m) => errs.add(m);
    if (desc['format'] != format) {
      bad('format: ждём «$format», а не «${jsString(desc['format'] ?? absent)}»');
    }
    final api = _map(desc['api']);
    if (!_truthyString(api['url'])) bad('api.url: нет адреса API');
    final only = api['only'];
    if (only is! List || only.isEmpty) {
      bad('api.only: нужен список действий, которые помощнику можно звать');
    }
    final auth = _map(desc['auth']);
    final access = _map(auth['access']);
    final rawCommands = desc['commands'];
    final cmds = rawCommands is List ? rawCommands : const <Object?>[];
    if (cmds.isEmpty) bad('commands: нет ни одной команды');
    final ids = <String>{};
    for (var i = 0; i < cmds.length; i++) {
      final c = cmds[i];
      final id = c is Map ? c['id'] : null;
      final at = 'commands[$i]${id is String && id.isNotEmpty ? ' ($id)' : ''}';
      if (c is! Map) {
        bad('$at: не объект');
        continue;
      }
      if (id is! String || !RegExp(r'^[a-z][a-z0-9_-]*$').hasMatch(id)) {
        bad('$at: id — латиница, цифры, «-» и «_»');
      }
      if (ids.contains(id)) bad('$at: id повторяется');
      if (id is String) ids.add(id);
      final say = c['say'];
      if (say is! List || say.isEmpty) {
        bad('$at: say — нужна хотя бы одна фраза');
      }
      final slots = _map(c['slots']);
      for (final p in say is List ? say : const <Object?>[]) {
        if (p is! String || askText(p).isEmpty) {
          bad('$at: пустая фраза');
          continue;
        }
        final used = <String>[
          for (final m in askSlotPattern.allMatches(p)) m[1]!,
        ];
        for (final s in used) {
          if (!slots.containsKey(s)) {
            bad('$at: в фразе «$p» поле {$s}, которого нет в slots');
          }
        }
        if (used.toSet().length != used.length) {
          bad('$at: в фразе «$p» поле повторяется');
        }
        if (RegExp(r'\}\s*\{').hasMatch(p)) {
          bad('$at: в фразе «$p» два поля подряд — их не разделить');
        }
        if (p.length > maxPhraseLength) {
          bad('$at: фраза длиннее $maxPhraseLength знаков');
        }
      }
      if (say is List && say.length > maxPhrases) {
        bad('$at: фраз больше $maxPhrases');
      }
      for (final MapEntry(key: s, value: def) in slots.entries) {
        if (s is! String || !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(s)) {
          bad('$at: имя поля «$s» — строчная латиница, цифры и «_»');
        }
        final sh = def is Map ? def['shape'] : null;
        if (sh is String && sh.isNotEmpty) {
          if (sh.length > maxShapeLength) {
            bad('$at: slots.$s.shape длиннее $maxShapeLength знаков');
          }
          try {
            RegExp(sh, caseSensitive: false);
          } on FormatException {
            bad('$at: slots.$s.shape — не регулярное выражение');
          }
        }
      }
      final cAccess = c['access'];
      if (_truthyString(cAccess) && !access.containsKey(cAccess)) {
        bad('$at: access «$cAccess» нет в auth.access');
      }
      if (_truthy(c['help']) || _truthy(c['reply'])) continue;
      final call = _map(c['call']);
      if (!_truthyString(call['action'])) {
        bad('$at: call.action — какое действие звать');
        continue;
      }
      if (only is List && !only.contains(call['action'])) {
        bad('$at: действие «${call['action']}» не входит в api.only');
      }
      final body = _map(call['body']);
      for (final MapEntry(:key, :value) in body.entries) {
        if (value is! String) continue;
        for (final m in RegExp(r'\{([a-z][a-z0-9_]*)\}', caseSensitive: false)
            .allMatches(value)) {
          if (!slots.containsKey(m[1])) {
            bad('$at: call.body.$key ссылается на {${m[1]}}, '
                'а такого поля нет');
          }
        }
      }
      final a = _map(c['answer']);
      if (!_truthy(a['say']) && !_truthy(a['list'])) {
        bad('$at: answer — нужен say или list');
      }
      if (_truthy(a['list']) && !_truthy(a['item'])) {
        bad('$at: answer.item — как показать строку списка');
      }
    }
    final fallback = desc['fallback'];
    if (_truthy(fallback) && !ids.contains(fallback)) {
      bad('fallback: нет команды «$fallback»');
    }
    if (_truthy(fallback)) {
      final f = cmds
          .whereType<Map<Object?, Object?>>()
          .where((Map<Object?, Object?> c) => c['id'] == fallback)
          .firstOrNull;
      if (f != null && _map(f['slots']).length != 1) {
        bad('fallback: у команды должно быть ровно одно поле');
      }
    }
    // Пределы и правила «Связного».
    if (cmds.length > maxCommands) bad('commands: команд больше $maxCommands');
    final app = _map(desc['app']);
    if (appId != null && app['id'] != appId) {
      bad('app.id: ждём «$appId», а не «${jsString(app['id'] ?? absent)}»');
    }
    final method = (api['method'] ?? 'POST').toString().toUpperCase();
    if (method != 'POST' && method != 'GET') {
      bad('api.method: только POST или GET');
    }
    final bodyKind = api['body'] ?? 'json';
    if (bodyKind != 'json') bad('api.body: поддерживается только json');
    final action = _map(api['action']);
    if ((action['in'] ?? 'query') != 'query') {
      bad('api.action.in: поддерживается только query');
    }
    final url = api['url'];
    if (manifestUri != null && url is String && url.isNotEmpty) {
      final Uri resolved;
      try {
        resolved = manifestUri.resolve(url);
        if (!sameOrigin(resolved, manifestUri)) {
          bad('api.url: адрес API на другом сервере, чем описание');
        }
      } on FormatException {
        bad('api.url: неверный адрес');
      }
    }
    final qr = _map(auth['qr']);
    if (qr.isNotEmpty && !_truthyString(qr['action'])) {
      bad('auth.qr.action: каким действием входить по ссылке');
    }
    final qrShape = qr['shape'];
    if (qrShape is String) {
      try {
        RegExp(qrShape, caseSensitive: false);
      } on FormatException {
        bad('auth.qr.shape — не регулярное выражение');
      }
    }
    final logout = _map(auth['logout']);
    if (logout.isNotEmpty && !_truthyString(logout['action'])) {
      bad('auth.logout.action: каким действием выходить');
    }
    // Действия входа и выхода зовутся с паролем и ключом: только известные
    // безвредные (authActions) и не из команд — иначе описание с сервера
    // заставило бы помощника звать запись.
    void authAction(String at, String role, Object? name) {
      if (!_truthyString(name)) return;
      if (!(authActions[role]?.contains(name) ?? false)) {
        bad('$at: действие «$name» помощник не зовёт — для входа знает '
            'только ${(authActions[role] ?? const <String>{}).join(', ')}');
      }
      if (only is List && only.contains(name)) {
        bad('$at: действие «$name» — команда из api.only, не вход');
      }
    }

    authAction('auth.qr.action', 'qr', qr['action']);
    authAction('auth.logout.action', 'logout', logout['action']);
    final qrParam = qr['param'];
    if (qrParam != null &&
        (qrParam is! String || !_fieldName.hasMatch(qrParam))) {
      bad('auth.qr.param — строчная латиница, цифры и «_»');
    }
    final logoutNeeds = logout['needs'];
    if (logoutNeeds != null &&
        (logoutNeeds is! List ||
            logoutNeeds.any((Object? n) => n != 'token' && n != 'sid'))) {
      bad('auth.logout.needs: только token и sid');
    }
    for (final MapEntry(key: name, value: credential)
        in _map(auth['credentials']).entries) {
      final get = _map(_map(credential)['get']);
      if (get.isEmpty) continue;
      final at = 'auth.credentials.$name.get';
      if (name != 'sid') {
        bad('$at: получать по логину можно только личный ключ (sid)');
        continue;
      }
      if (!_truthyString(get['action'])) {
        bad('$at.action: каким действием получать ключ');
      }
      authAction('$at.action', 'login', get['action']);
      final take = get['take'];
      if (take != null && (take is! String || !_fieldName.hasMatch(take))) {
        bad('$at.take — строчная латиница, цифры и «_»');
      }
      final body = get['body'];
      if (body != null && body is! Map) bad('$at.body: не объект');
      final used = <Object?>[];
      for (final MapEntry(:key, :value) in _map(body).entries) {
        if (key is! String || !_fieldName.hasMatch(key)) {
          bad('$at.body: имя поля «$key» — строчная латиница, цифры и «_»');
        }
        if (value != '{login}' && value != '{pass}') {
          bad('$at.body.$key: только «{login}» или «{pass}»');
        }
        used.add(value);
      }
      if (used.toSet().length != used.length) {
        bad('$at.body: логин или пароль повторяется');
      }
    }
    return errs;
  }

  /// Действия входа, которые помощник зовёт сам, по роли: `qr` — вход по
  /// ссылке, `login` — личный ключ по логину и паролю
  /// (`credentials.sid.get`), `logout` — выход. Всё безвредно: ничего не
  /// пишет, кроме ключа входа. Новое приложение (expeora) — дописать сюда
  /// после проверки его кода.
  static const Map<String, Set<String>> authActions = <String, Set<String>>{
    'qr': <String>{'qr_take'},
    'login': <String>{'auth_check'},
    'logout': <String>{'sess_end'},
  };

  static final RegExp _fieldName = RegExp(r'^[a-z][a-z0-9_]*$');

  /// Схема, хост и порт совпадают.
  static bool sameOrigin(Uri a, Uri b) =>
      a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
      a.host.toLowerCase() == b.host.toLowerCase() &&
      a.port == b.port;

  static ManifestDescription _build(Map<String, Object?> d, String source) {
    final app = _map(d['app']);
    final api = _map(d['api']);
    final auth = _map(d['auth']);
    final errors = _map(api['errors']);
    final action = _map(api['action']);
    final version = d['version'];
    final commands = <ManifestCommand>[];
    final raw = d['commands']! as List;
    for (var i = 0; i < raw.length; i++) {
      final c = raw[i] as Map;
      final call = _map(c['call']);
      commands.add(
        ManifestCommand(
          id: c['id'] as String,
          title: _string(c['title']),
          say: <String>[for (final p in c['say'] as List) p as String],
          examples: _strings(c['examples']),
          slots: <String, ManifestSlot>{
            for (final MapEntry(:key, :value) in _map(c['slots']).entries)
              key as String: ManifestSlot(
                type: _string(_map(value)['type'], 'text'),
                label: _string(_map(value)['label']),
                shape: _map(value)['shape'] is String &&
                        (_map(value)['shape'] as String).isNotEmpty
                    ? _map(value)['shape'] as String
                    : null,
              ),
          },
          access: c['access'] is String ? c['access'] as String : null,
          call: call['action'] is String
              ? ManifestCall(
                  action: call['action'] as String,
                  body: _objectMap(call['body']),
                )
              : null,
          answer: _objectMap(c['answer']),
          reply: _truthyString(c['reply']) ? c['reply'] as String : null,
          help: _truthy(c['help']),
          order: i,
        ),
      );
    }
    final qr = _map(auth['qr']);
    final logout = _map(auth['logout']);
    return ManifestDescription._(
      json: d,
      source: source,
      version: version is String && version.trim().isNotEmpty
          ? version.trim()
          : null,
      appId: _string(app['id']),
      appTitle: _string(app['title']),
      about: _string(app['about']),
      apiUrl: api['url'] as String,
      method: _string(api['method'], 'POST').toUpperCase(),
      actionIn: _string(action['in'], 'query'),
      actionName: _string(action['name'], 'action'),
      only: _strings(api['only']),
      errorField: _string(errors['message'], 'error'),
      needField: _string(errors['need'], 'need'),
      headers: <String, String>{
        for (final MapEntry(:key, :value) in _map(auth['headers']).entries)
          if (key is String && value is String) key: value,
      },
      credentials: <String, ManifestCredential>{
        for (final MapEntry(:key, :value) in _map(auth['credentials']).entries)
          if (key is String) key: _credential(_map(value)),
      },
      access: <String, ManifestAccess>{
        for (final MapEntry(:key, :value) in _map(auth['access']).entries)
          if (key is String)
            key: ManifestAccess(
              label: _string(_map(value)['label']),
              needs: _strings(_map(value)['needs']),
            ),
      },
      qr: qr.isEmpty
          ? null
          : ManifestQr(
              action: qr['action'] as String,
              link: _string(qr['link'], '#qr='),
              param: _string(qr['param'], 'code'),
              shape: _string(qr['shape'], r'^[0-9a-f]{32}$'),
              take: _map(qr['take']).isEmpty
                  ? const <String, String>{
                      'token': 'token',
                      'sid': 'sid',
                      'login': 'login',
                    }
                  : <String, String>{
                      for (final MapEntry(:key, :value)
                          in _map(qr['take']).entries)
                        if (key is String && value is String) key: value,
                    },
              ttl: qr['ttl'] is int ? qr['ttl'] as int : 120,
              errors: <String, String>{
                for (final MapEntry(:key, :value) in _map(qr['errors']).entries)
                  if (key is String && value is String) key: value,
              },
            ),
      logout: logout.isEmpty
          ? null
          : ManifestLogout(
              action: logout['action'] as String,
              needs: _map(logout).containsKey('needs')
                  ? _strings(logout['needs'])
                  : const <String>['token', 'sid'],
            ),
      fallback: _truthyString(d['fallback']) ? d['fallback'] as String : null,
      filler: _strings(d['filler']),
      commands: List<ManifestCommand>.unmodifiable(commands),
    );
  }

  static ManifestCredential _credential(Map<Object?, Object?> c) {
    final get = _map(c['get']);
    return ManifestCredential(
      label: _string(c['label']),
      get: get['action'] is String
          ? ManifestCredentialGet(
              action: get['action'] as String,
              body: _objectMap(get['body']),
              take: _string(get['take'], 'sid'),
            )
          : null,
    );
  }

  static Map<Object?, Object?> _map(Object? value) =>
      value is Map ? value : const <Object?, Object?>{};

  static Map<String, Object?> _objectMap(Object? value) => <String, Object?>{
        if (value is Map)
          for (final MapEntry(:key, :value) in value.entries)
            if (key is String) key: value,
      };

  static String _string(Object? value, [String fallback = '']) =>
      value is String ? value : fallback;

  static List<String> _strings(Object? value) => <String>[
        if (value is List)
          for (final item in value)
            if (item is String) item,
      ];

  static bool _truthyString(Object? value) =>
      value is String && value.isNotEmpty;

  static bool _truthy(Object? value) {
    if (value == null) return false;
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) return value.isNotEmpty;
    return true;
  }
}
