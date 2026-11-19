import 'dart:convert';

import 'app_profile.dart';
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

/// Действие с записью из раздела `actions[]` (склад 1.4.57, ADR-013).
///
/// Читается только у встроенной копии описания: у описания сервера раздел
/// не разбирается вовсе. Тела запросов, карточку и ответы задаёт код
/// «Tridot» по [kind]; у записи нет `call`, `answer`, `reply`.
final class ManifestAction {
  const ManifestAction({
    required this.id,
    required this.kind,
    required this.title,
    required this.say,
    required this.order,
    required this.check,
    required this.write,
    this.examples = const <String>[],
    this.slots = const <String, ManifestSlot>{},
    this.access,
    this.right = '',
  });

  final String id;

  /// `move` — перемещение между ячейками, `post` — отметка проведения.
  final String kind;
  final String title;
  final List<String> say;
  final List<String> examples;
  final Map<String, ManifestSlot> slots;

  /// Уровень доступа из `auth.access`: только с личным ключом (`sid`).
  final String? access;

  /// Расчёт (только чтение): `act_move_check`.
  final String check;

  /// Запись по кнопке «Подтвердить»: `act_move`.
  final String write;

  /// Право склада: `moves`, `post`.
  final String right;

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
    this.body = const <String, String>{},
    this.device,
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

  /// Постоянные поля тела запроса: `{"scope": "assist"}` — ключ только
  /// для вопросов помощнику (склад 1.4.62, ADR-031). Только из
  /// [ManifestDescription.constantFields].
  final Map<String, String> body;

  /// Поле тела с названием устройства («Связной · Android») — его видно
  /// на складе в списке подключённых; `null` — не слать.
  final String? device;

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

/// Как снять личный ключ на сервере (`credentials.sid.drop`, склад
/// 1.4.63): действие выхода с ключом в заголовке.
final class ManifestCredentialDrop {
  const ManifestCredentialDrop({required this.action});

  final String action;
}

/// Ключ входа: `token` («Пароль склада»), `sid` («Личный ключ»).
final class ManifestCredential {
  const ManifestCredential({required this.label, this.get, this.drop});

  final String label;
  final ManifestCredentialGet? get;
  final ManifestCredentialDrop? drop;
}

/// Кто я и что мне можно (`auth.me`, склад `ask_me`): читающее действие
/// из `api.only` и поля ответа.
final class ManifestMe {
  const ManifestMe({
    required this.action,
    this.all = 'all',
    this.perms = 'perms',
  });

  final String action;
  final String all;
  final String perms;
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
    required this.profile,
    required this.profileWarnings,
    required this.apiUrl,
    required this.method,
    required this.actionIn,
    required this.actionName,
    required this.only,
    required this.act,
    required this.errorField,
    required this.needField,
    required this.codeField,
    required this.headers,
    required this.credentials,
    required this.access,
    required this.qr,
    required this.logout,
    required this.me,
    required this.fallback,
    required this.filler,
    required this.commands,
    required this.actions,
    required this.builtIn,
  });

  /// Формат, который понимает коннектор.
  static const String format = 'assistant/1';

  /// Пределы «Tridot»: описание — недоверенные данные.
  static const int maxBytes = 256 * 1024;
  static const int maxCommands = 100;
  static const int maxPhrases = 50;
  static const int maxPhraseLength = 120;
  static const int maxShapeLength = 200;
  static const int maxActions = 10;

  final Map<String, Object?> json;

  /// Текст файла, из которого разобрано описание.
  final String source;

  /// `version` описания (склад 1.4.56); `null` — в описании её нет.
  final String? version;
  final String appId;
  final String appTitle;
  final String about;

  /// Профиль приложения из необязательных полей `app` (`name`, `forms`,
  /// `in`, `gender`, `addressing`; ADR-039); `null` — в описании их нет
  /// или имя не годится. Склад его не читает: у него свой слот.
  final AppProfile? profile;

  /// Что из профиля отброшено и почему: описание из-за этого не
  /// отклоняется.
  final List<String> profileWarnings;
  final String apiUrl;
  final String method;
  final String actionIn;
  final String actionName;
  final List<String> only;

  /// `api.act` — действия с записью по описанию. «Tridot» его не
  /// использует: что писать, знает код ([writeActions]); признак «сервер
  /// умеет» — сам ответ расчёта.
  final List<String> act;
  final String errorField;
  final String needField;

  /// Поле кода отказа (`api.errors.code`, склад 1.4.57): `no_right`,
  /// `stale`.
  final String codeField;

  /// Заголовок → шаблон: `X-Wh-Token: {$token}`.
  final Map<String, String> headers;
  final Map<String, ManifestCredential> credentials;
  final Map<String, ManifestAccess> access;

  /// `auth.qr`; `null` — в описании нет (тогда — встроенный профиль слота).
  final ManifestQr? qr;

  /// `auth.logout`; `null` — выход только на устройстве.
  final ManifestLogout? logout;

  /// `auth.me`; `null` — сервер не говорит, кто вошёл и что ему можно.
  final ManifestMe? me;

  /// Как выходить: `credentials.sid.drop` (склад 1.4.63), иначе
  /// `auth.logout`; `null` — выход только на устройстве.
  ManifestLogout? get signOut {
    final drop = credentials['sid']?.drop;
    if (drop != null) return ManifestLogout(action: drop.action);
    return logout;
  }

  final String? fallback;
  final List<String> filler;
  final List<ManifestCommand> commands;

  /// Действия с записью — только у встроенной копии ([builtIn]); у
  /// описания сервера всегда пусто, что бы в нём ни было (ADR-013).
  final List<ManifestAction> actions;

  /// Разобрано как встроенная копия из `assets/connectors/`.
  final bool builtIn;

  /// Действия с записью, которые знает код «Tridot», по виду: расчёт и
  /// запись. Встроенное описание с другой парой проверку не проходит.
  /// Новое действие — сюда, после чтения кода сервера.
  static const Map<String, (String, String)> writeActions =
      <String, (String, String)>{
    'move': ('act_move_check', 'act_move'),
    'post': ('act_post_check', 'act_post'),
  };

  /// «Чем кончилось» по одноразовому ключу записи: только служебная книга
  /// сервера, право склада не нужно.
  static const String settleAction = 'act_settle';

  /// Все действия записи и [settleAction]: обычный путь команд их не зовёт
  /// никогда.
  static Set<String> get writeNames => <String>{
        for (final pair in writeActions.values) pair.$2,
        settleAction,
      };

  /// Расчёты действий: читающие, но зовутся только из потока действий.
  static Set<String> get checkNames => <String>{
        for (final pair in writeActions.values) pair.$1,
      };

  ManifestAction? action(String id) =>
      actions.where((ManifestAction a) => a.id == id).firstOrNull;

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
  ///
  /// [builtIn] — встроенная копия: только у неё разбирается раздел
  /// `actions[]` (действия с записью, ADR-013).
  static ManifestDescription parse(
    String source, {
    String? appId,
    Set<String>? appIds,
    Uri? manifestUri,
    bool builtIn = false,
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
    final errors = check(
      decoded,
      appId: appId,
      appIds: appIds,
      manifestUri: manifestUri,
    );
    if (errors.isNotEmpty) throw ManifestException(errors);
    return _build(decoded, source, builtIn: builtIn);
  }

  /// Проверка как `askCheck` из core.mjs плюс пределы «Tridot». Пустой
  /// список — описанием можно пользоваться.
  static List<String> check(
    Object? desc, {
    String? appId,
    Set<String>? appIds,
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
    // Пределы и правила «Tridot».
    if (cmds.length > maxCommands) bad('commands: команд больше $maxCommands');
    final app = _map(desc['app']);
    final accepted = <String>{if (appId != null) appId, ...?appIds};
    if (accepted.isNotEmpty && !accepted.contains(app['id'])) {
      bad('app.id: ждём «${accepted.join('» или «')}», а не '
          '«${jsString(app['id'] ?? absent)}»');
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
    final qrBody = qr['body'];
    if (qrBody != null && qrBody is! Map) bad('auth.qr.body: не объект');
    _constants('auth.qr.body', qrBody, bad);
    final qrDevice = qr['device'];
    if (qrDevice != null &&
        (qrDevice is! String ||
            !_fieldName.hasMatch(qrDevice) ||
            _map(qrBody).containsKey(qrDevice) ||
            qrDevice == qr['param'])) {
      bad('auth.qr.device — имя поля: строчная латиница, цифры и «_»');
    }
    final logout = _map(auth['logout']);
    if (logout.isNotEmpty && !_truthyString(logout['action'])) {
      bad('auth.logout.action: каким действием выходить');
    }
    final me = _map(auth['me']);
    if (me.isNotEmpty) {
      final name = me['action'];
      if (!_truthyString(name)) {
        bad('auth.me.action: каким действием спросить «кто я»');
      } else if (only is! List || !only.contains(name)) {
        bad('auth.me.action: «$name» не входит в api.only');
      } else if (!(name as String).startsWith('ask_')) {
        bad('auth.me.action: только читающее действие ask_*');
      }
      for (final field in <String>['all', 'perms']) {
        final value = me[field];
        if (value != null &&
            (value is! String || !_fieldName.hasMatch(value))) {
          bad('auth.me.$field — строчная латиница, цифры и «_»');
        }
      }
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

    // И обратно: действие входа или выхода — не команда. Иначе фраза из
    // чата звала бы `sess_end` или `auth_check` с ключами пользователя.
    final authNames = <String>{
      for (final names in authActions.values) ...names,
    };
    for (final name in only is List ? only : const <Object?>[]) {
      if (authNames.contains(name)) {
        bad('api.only: «$name» — действие входа, командой оно не бывает');
      }
    }
    for (var i = 0; i < cmds.length; i++) {
      final c = cmds[i];
      if (c is! Map) continue;
      final name = _map(c['call'])['action'];
      if (authNames.contains(name)) {
        bad('commands[$i]: действие входа «$name» команда не зовёт');
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
      final drop = _map(_map(credential)['drop']);
      if (drop.isNotEmpty) {
        final at = 'auth.credentials.$name.drop';
        if (name != 'sid') {
          bad('$at: снимать на сервере можно только личный ключ (sid)');
        } else if (!_truthyString(drop['action'])) {
          bad('$at.action: каким действием снимать ключ');
        }
        authAction('$at.action', 'logout', drop['action']);
      }
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
          // Постоянное поле — только знакомое: `scope: assist`.
          if (constantFields[key]?.contains(value) ?? false) continue;
          bad('$at.body.$key: только «{login}», «{pass}» или '
              'scope «assist»');
        }
        used.add(value);
      }
      if (used.toSet().length != used.length) {
        bad('$at.body: логин или пароль повторяется');
      }
    }
    _checkActions(
      desc,
      bad,
      only: only is List ? only : const <Object?>[],
      commands: cmds,
      ids: ids,
      access: access,
      authNames: <Object?>[
        qr['action'],
        logout['action'],
        for (final credential in _map(auth['credentials']).values) ...<Object?>[
          _map(_map(credential)['get'])['action'],
          _map(_map(credential)['drop'])['action'],
        ],
      ],
    );
    return errs;
  }

  /// Правила действий с записью (склад 1.4.57, ADR-013) — те же, что в
  /// `core.mjs` склада: `api.act` не пересекается с `api.only`; каждое
  /// действие — известного вида, с расчётом из `api.only` и записью из
  /// `api.act`, только под личным ключом, без `call`/`answer`/`reply`/
  /// `help`, не `fallback`, у ячеек есть `shape`, в каждой фразе не меньше
  /// двух слов. Команды не зовут ни записи, ни расчёты; вход и выход — тоже.
  /// Описание сервера, которое называет действия записи в `api.only` или
  /// у команды без `api.act`, отвергает [DescriptionAuthority.widening].
  static void _checkActions(
    Map<Object?, Object?> desc,
    void Function(String) bad, {
    required List<Object?> only,
    required List<Object?> commands,
    required Set<String> ids,
    required Map<Object?, Object?> access,
    required List<Object?> authNames,
  }) {
    final api = _map(desc['api']);
    final rawAct = api['act'];
    if (rawAct != null &&
        (rawAct is! List || rawAct.any((x) => x is! String))) {
      bad('api.act: нужен список действий с записью');
    }
    final act = <Object?>{if (rawAct is List) ...rawAct};
    for (final name in only) {
      if (act.contains(name)) {
        bad('api.only: «$name» есть и в api.act — чтение и запись не '
            'пересекаются');
      }
    }
    final rawActions = desc['actions'];
    if (rawActions != null && rawActions is! List) {
      bad('actions: нужен список');
    }
    final actions = rawActions is List ? rawActions : const <Object?>[];
    if (actions.length > maxActions) {
      bad('actions: действий больше $maxActions');
    }
    final checks = <Object?>{};
    final actionIds = <String>{};
    for (var i = 0; i < actions.length; i++) {
      final a = actions[i];
      final id = a is Map ? a['id'] : null;
      final at = 'actions[$i]${id is String && id.isNotEmpty ? ' ($id)' : ''}';
      if (a is! Map) {
        bad('$at: не объект');
        continue;
      }
      if (id is! String || !RegExp(r'^[a-z][a-z0-9_-]*$').hasMatch(id)) {
        bad('$at: id — латиница, цифры, «-» и «_»');
      } else if (ids.contains(id) || !actionIds.add(id)) {
        bad('$at: id повторяется (среди команд и действий)');
      }
      if (id != null && id == desc['fallback']) {
        bad('$at: действие не бывает fallback');
      }
      final kind = a['kind'];
      final pair = writeActions[kind];
      if (pair == null) {
        bad('$at: kind — только ${writeActions.keys.join(', ')}');
      }
      final check = a['check'];
      final write = a['write'];
      checks.add(check);
      if (!only.contains(check)) {
        bad('$at: check «$check» не входит в api.only');
      }
      if (!act.contains(write)) bad('$at: write «$write» не входит в api.act');
      if (pair != null && (check != pair.$1 || write != pair.$2)) {
        bad('$at: для «$kind» помощник знает только ${pair.$1} и ${pair.$2}');
      }
      final level = a['access'];
      final needs = _map(access[level])['needs'];
      if (!_truthyString(level) || needs is! List || !needs.contains('sid')) {
        bad('$at: access — только уровень с личным ключом (sid)');
      }
      for (final field in <String>['call', 'answer', 'help', 'reply']) {
        if (a.containsKey(field)) bad('$at: у действия нет поля $field');
      }
      final right = a['right'];
      if (right != null && !_truthyString(right)) {
        bad('$at: right — имя права склада');
      }
      final slots = _map(a['slots']);
      for (final MapEntry(key: name, value: def) in slots.entries) {
        if (name is! String || !_fieldName.hasMatch(name)) {
          bad('$at: имя поля «$name» — строчная латиница, цифры и «_»');
        }
        final type = _map(def)['type'];
        final shape = _map(def)['shape'];
        if (type == 'cell' && !_truthyString(shape)) {
          bad('$at: у ячейки slots.$name нужен shape');
        }
        if (shape is String && shape.isNotEmpty) {
          if (shape.length > maxShapeLength) {
            bad('$at: slots.$name.shape длиннее $maxShapeLength знаков');
          }
          try {
            RegExp(shape, caseSensitive: false);
          } on FormatException {
            bad('$at: slots.$name.shape — не регулярное выражение');
          }
        }
      }
      final say = a['say'];
      if (say is! List || say.isEmpty) {
        bad('$at: say — нужна хотя бы одна фраза');
      }
      if (say is List && say.length > maxPhrases) {
        bad('$at: фраз больше $maxPhrases');
      }
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
        final literal = askText(p)
            .replaceAll(askSlotPattern, ' ')
            .split(' ')
            .where((String w) => w.trim().isNotEmpty)
            .length;
        if (literal < 2) {
          bad('$at: в фразе «$p» меньше двух слов вокруг полей');
        }
      }
    }
    // Команды не зовут ни записи, ни расчёты действий: расчёт строит
    // карточку только в потоке действий «Tridot».
    final forbidden = <Object?>{...act, ...checks};
    for (var i = 0; i < commands.length; i++) {
      final c = commands[i];
      if (c is! Map) continue;
      final name = _map(c['call'])['action'];
      if (name != null && forbidden.contains(name)) {
        bad('commands[$i]: команда не зовёт действие записи или расчёт '
            '«$name»');
      }
    }
    for (final name in authNames) {
      if (name != null && (act.contains(name) || writeNames.contains(name))) {
        bad('auth: действие входа «$name» — запись, так нельзя');
      }
    }
  }

  /// Действия входа, которые помощник зовёт сам, по роли: `qr` — вход по
  /// ссылке, `login` — личный ключ по логину и паролю
  /// (`credentials.sid.get`), `logout` — выход. Всё безвредно: ничего не
  /// пишет, кроме ключа входа. Новое приложение (expeora) — дописать сюда
  /// после проверки его кода.
  static const Map<String, Set<String>> authActions = <String, Set<String>>{
    'qr': <String>{'qr_take'},
    'login': <String>{'auth_check'},
    // `auth_out` — выход склада 1.4.63 (`credentials.sid.drop`), `sess_end`
    // — его второе имя с 1.4.62.
    'logout': <String>{'sess_end', 'auth_out'},
  };

  /// Постоянные поля тела входа, которые помощник шлёт: `scope: assist` —
  /// ключ только для вопросов помощнику (ADR-031). Другие значения —
  /// шире по правам, описание их не задаёт.
  static const Map<String, Set<String>> constantFields = <String, Set<String>>{
    'scope': <String>{'assist'},
  };

  static void _constants(
    String at,
    Object? body,
    void Function(String) bad,
  ) {
    for (final MapEntry(:key, :value) in _map(body).entries) {
      if (key is! String || !_fieldName.hasMatch(key)) {
        bad('$at: имя поля «$key» — строчная латиница, цифры и «_»');
        continue;
      }
      if (!(constantFields[key]?.contains(value) ?? false)) {
        bad('$at.$key: помощник шлёт только scope «assist»');
      }
    }
  }

  static final RegExp _fieldName = RegExp(r'^[a-z][a-z0-9_]*$');

  /// Схема, хост и порт совпадают.
  static bool sameOrigin(Uri a, Uri b) =>
      a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
      a.host.toLowerCase() == b.host.toLowerCase() &&
      a.port == b.port;

  static ManifestDescription _build(
    Map<String, Object?> d,
    String source, {
    required bool builtIn,
  }) {
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
    final actions = <ManifestAction>[];
    // Раздел действий — только у встроенной копии: описание сервера для
    // записи не значит ничего (ADR-013).
    final rawActions = builtIn ? d['actions'] : null;
    if (rawActions is List) {
      for (var i = 0; i < rawActions.length; i++) {
        final a = rawActions[i] as Map;
        actions.add(
          ManifestAction(
            id: a['id'] as String,
            kind: a['kind'] as String,
            title: _string(a['title']),
            say: <String>[for (final p in a['say'] as List) p as String],
            examples: _strings(a['examples']),
            slots: _slots(a['slots']),
            access: a['access'] is String ? a['access'] as String : null,
            check: a['check'] as String,
            write: a['write'] as String,
            right: _string(a['right']),
            order: i,
          ),
        );
      }
    }
    final qr = _map(auth['qr']);
    final logout = _map(auth['logout']);
    final profile = AppProfile.parse(d['app']);
    return ManifestDescription._(
      json: d,
      source: source,
      version: version is String && version.trim().isNotEmpty
          ? version.trim()
          : null,
      appId: _string(app['id']),
      appTitle: _string(app['title']),
      about: _string(app['about']),
      profile: profile.profile,
      profileWarnings: List<String>.unmodifiable(profile.warnings),
      apiUrl: api['url'] as String,
      method: _string(api['method'], 'POST').toUpperCase(),
      actionIn: _string(action['in'], 'query'),
      actionName: _string(action['name'], 'action'),
      only: _strings(api['only']),
      act: _strings(api['act']),
      errorField: _string(errors['message'], 'error'),
      needField: _string(errors['need'], 'need'),
      codeField: _string(errors['code'], 'code'),
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
              body: <String, String>{
                for (final MapEntry(:key, :value) in _map(qr['body']).entries)
                  if (key is String && value is String) key: value,
              },
              device: qr['device'] is String ? qr['device'] as String : null,
            ),
      logout: logout.isEmpty
          ? null
          : ManifestLogout(
              action: logout['action'] as String,
              needs: _map(logout).containsKey('needs')
                  ? _strings(logout['needs'])
                  : const <String>['token', 'sid'],
            ),
      me: _map(auth['me']).isEmpty
          ? null
          : ManifestMe(
              action: _map(auth['me'])['action'] as String,
              all: _string(_map(auth['me'])['all'], 'all'),
              perms: _string(_map(auth['me'])['perms'], 'perms'),
            ),
      fallback: _truthyString(d['fallback']) ? d['fallback'] as String : null,
      filler: _strings(d['filler']),
      commands: List<ManifestCommand>.unmodifiable(commands),
      actions: List<ManifestAction>.unmodifiable(actions),
      builtIn: builtIn,
    );
  }

  static Map<String, ManifestSlot> _slots(Object? raw) =>
      <String, ManifestSlot>{
        for (final MapEntry(:key, :value) in _map(raw).entries)
          key as String: ManifestSlot(
            type: _string(_map(value)['type'], 'text'),
            label: _string(_map(value)['label']),
            shape: _map(value)['shape'] is String &&
                    (_map(value)['shape'] as String).isNotEmpty
                ? _map(value)['shape'] as String
                : null,
          ),
      };

  static ManifestCredential _credential(Map<Object?, Object?> c) {
    final get = _map(c['get']);
    final drop = _map(c['drop']);
    return ManifestCredential(
      label: _string(c['label']),
      drop: drop['action'] is String
          ? ManifestCredentialDrop(action: drop['action'] as String)
          : null,
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
