import 'manifest_format.dart';

/// Какое описание приложения сейчас в работе.
enum DescriptionOrigin {
  /// Встроенная копия из `assets/connectors/` — главная.
  builtIn,

  /// Описание с сервера: новее встроенного и не шире его по правам.
  server,

  /// Описания нет: фразы не понимаются, экран подключения работает.
  none,
}

/// Итог выбора: описание, откуда оно и почему (текст для экрана).
final class DescriptionPick {
  const DescriptionPick(
    this.description,
    this.origin,
    this.reason, {
    this.refused,
  });

  /// Описание сервера прошло разбор, но отвергнуто как расширяющее права:
  /// чем именно. Такое описание не заменяет принятое раньше и не попадает
  /// в кэш ([ConnectionService]). `null` — не отвергнуто.
  final String? refused;

  final ManifestDescription? description;
  final DescriptionOrigin origin;

  /// Какое и почему, со строчной буквы — после «В работе: »:
  /// «встроенное описание 1.4.56: описание сервера 1.4.50 не новее.» Без
  /// секретов и адресов.
  final String reason;
}

/// «Наше описание главное» (ADR-012): встроенная копия описания — главная.
/// Описание с сервера заменяет её, только если оно разобралось и прошло
/// полную проверку (`ManifestDescription.parse`, в том числе список
/// действий входа), его `version` новее встроенной и оно не расширяет
/// права ([widening]):
///
/// - команды и `api.only` — только из `api.only` встроенного описания;
///   действия входа и выхода ([ManifestDescription.authActions]) — только
///   в разделе `auth`, командой они не бывают;
/// - `api.url`, `api.action` (`in`, `name`) и `auth.headers` — те же, что
///   во встроенном: иначе тот же список действий звал бы другой адрес
///   («api.php?action=…» с переименованным параметром) или слал бы ключи
///   в других заголовках;
/// - `api.method`, `api.errors`, уровни `auth.access`, вход по логину,
///   по ссылке и выход — те же; у знакомого действия в теле запроса
///   только знакомые поля;
/// - действия с записью ([ManifestDescription.writeNames]) и расчёты
///   действий описание сервера не называет вовсе: их берут только из
///   встроенной копии (ADR-013).
abstract final class DescriptionAuthority {
  /// Выбор между встроенным [builtIn] и описанием сервера [server];
  /// [serverError] — почему описание сервера не принято (тогда [server] —
  /// `null`).
  static DescriptionPick choose({
    ManifestDescription? builtIn,
    ManifestDescription? server,
    String? serverError,
  }) {
    if (builtIn == null) {
      if (server == null) {
        return DescriptionPick(
          null,
          DescriptionOrigin.none,
          serverError ?? 'описания пока нет.',
        );
      }
      return DescriptionPick(
        server,
        DescriptionOrigin.server,
        'описание сервера: встроенного нет.',
      );
    }
    final ours = builtIn.version ?? 'без версии';
    if (server == null) {
      return DescriptionPick(
        builtIn,
        DescriptionOrigin.builtIn,
        serverError == null
            ? 'встроенное описание $ours.'
            : 'встроенное описание $ours: описание сервера не принято '
                '($serverError).',
      );
    }
    final theirs = server.version;
    if (theirs == null) {
      return DescriptionPick(
        builtIn,
        DescriptionOrigin.builtIn,
        'встроенное описание $ours: в описании сервера нет версии.',
      );
    }
    if (compareVersions(theirs, builtIn.version) <= 0) {
      return DescriptionPick(
        builtIn,
        DescriptionOrigin.builtIn,
        'встроенное описание $ours: описание сервера $theirs не новее.',
      );
    }
    final extra = widening(builtIn, server);
    if (extra.isNotEmpty) {
      return DescriptionPick(
        builtIn,
        DescriptionOrigin.builtIn,
        'встроенное описание $ours: описание сервера $theirs расширяет '
        'права (${extra.join('; ')}).',
        refused: 'расширяет права (${extra.join('; ')})',
      );
    }
    return DescriptionPick(
      server,
      DescriptionOrigin.server,
      'описание сервера $theirs: новее встроенного $ours.',
    );
  }

  /// Чем описание [server] шире встроенного [builtIn] — по пунктам, для
  /// экрана; пусто — прав не больше:
  ///
  /// - действие в `api.only` или у команды, которого нет в `api.only`
  ///   встроенного (в том числе действие входа: командой оно не бывает);
  /// - действие входа, выхода или получения ключа не из
  ///   [ManifestDescription.authActions] своей роли;
  /// - другие `api.url`, `api.action.in`, `api.action.name` или
  ///   `auth.headers`.
  static List<String> widening(
    ManifestDescription builtIn,
    ManifestDescription server,
  ) {
    final found = <String>[];
    final commands = <String>{
      ...server.only,
      for (final command in server.commands)
        if (command.call case final ManifestCall call) call.action,
    }.difference(builtIn.only.toSet()).toList()
      ..sort();
    if (commands.isNotEmpty) {
      found.add('действия, которых нет во встроенном: ${commands.join(', ')}');
    }
    final auth = <String>[
      if (server.qr case final ManifestQr qr)
        if (!_auth('qr', qr.action)) qr.action,
      if (server.logout case final ManifestLogout logout)
        if (!_auth('logout', logout.action)) logout.action,
      for (final credential in server.credentials.values) ...<String>[
        if (credential.get case final ManifestCredentialGet get)
          if (!_auth('login', get.action)) get.action,
        if (credential.drop case final ManifestCredentialDrop drop)
          if (!_auth('logout', drop.action)) drop.action,
      ],
    ]..sort();
    if (auth.isNotEmpty) {
      found.add('незнакомые действия входа: ${auth.join(', ')}');
    }
    if (server.apiUrl != builtIn.apiUrl) found.add('другой адрес api.url');
    if (server.actionIn != builtIn.actionIn ||
        server.actionName != builtIn.actionName) {
      found.add('другой параметр действия api.action');
    }
    if (!_sameMap(server.headers, builtIn.headers)) {
      found.add('другие заголовки auth.headers');
    }
    // Действия с записью — только из встроенной копии (ADR-013): описание
    // сервера, которое называет их в `api.only` или у команды, отвергнуто
    // целиком.
    final writes = <String>{
      ...server.only,
      for (final command in server.commands)
        if (command.call case final ManifestCall call) call.action,
    }.intersection(<String>{
      ...ManifestDescription.writeNames,
      ...builtIn.act,
      for (final action in builtIn.actions) action.write,
    }).toList()
      ..sort();
    if (writes.isNotEmpty) {
      found.add('описание сервера ссылается на действия с записью: '
          '${writes.join(', ')}');
    }
    final checks = <String>{
      for (final command in server.commands)
        if (command.call case final ManifestCall call) call.action,
    }.intersection(<String>{
      ...ManifestDescription.checkNames,
      for (final action in builtIn.actions) action.check,
    }).toList()
      ..sort();
    if (checks.isNotEmpty) {
      found.add('команды зовут расчёты действий: ${checks.join(', ')}');
    }
    if (server.method != builtIn.method) found.add('другой метод api.method');
    if (server.errorField != builtIn.errorField ||
        server.needField != builtIn.needField ||
        server.codeField != builtIn.codeField) {
      found.add('другие поля ошибок api.errors');
    }
    // Тело запроса: у знакомого действия — только знакомые поля. Иначе
    // новое описание дописало бы в запрос чтения поле, которого встроенное
    // не шлёт.
    final keys = <String, Set<String>>{};
    for (final command in builtIn.commands) {
      if (command.call case final ManifestCall call) {
        (keys[call.action] ??= <String>{}).addAll(call.body.keys);
      }
    }
    final bodies = <String>{
      for (final command in server.commands)
        if (command.call case final ManifestCall call)
          if (!(keys[call.action] ?? const <String>{})
              .containsAll(call.body.keys))
            call.action,
    }.toList()
      ..sort();
    if (bodies.isNotEmpty) {
      found.add('новые поля в теле запроса: ${bodies.join(', ')}');
    }
    if (!_sameAccess(server.access, builtIn.access)) {
      found.add('другие уровни доступа auth.access');
    }
    if (!_sameGet(
      server.credentials['sid']?.get,
      builtIn.credentials['sid']?.get,
    )) {
      found.add('другой вход по логину auth.credentials.sid.get');
    }
    if (builtIn.qr case final ManifestQr ours) {
      final theirs = server.qr;
      if (theirs != null &&
          (theirs.action != ours.action ||
              theirs.param != ours.param ||
              !_sameMap(theirs.take, ours.take) ||
              !_sameMap(theirs.body, ours.body) ||
              (theirs.device != null && theirs.device != ours.device))) {
        found.add('другой вход по ссылке auth.qr');
      }
    }
    // Ключ только для помощника (ADR-031): тело `auth.qr` и входа по
    // логину сравнивается целиком — `scope: assist` описание сервера не
    // убирает.
    final ourDrop = builtIn.credentials['sid']?.drop?.action;
    final theirDrop = server.credentials['sid']?.drop?.action;
    if (theirDrop != null && theirDrop != ourDrop) {
      found.add('другой выход credentials.sid.drop');
    }
    if (server.me case final ManifestMe theirs) {
      final ours = builtIn.me;
      if (ours == null ||
          theirs.action != ours.action ||
          theirs.all != ours.all ||
          theirs.perms != ours.perms) {
        found.add('другое «кто я» auth.me');
      }
    }
    if (builtIn.logout case final ManifestLogout ours) {
      final theirs = server.logout;
      if (theirs != null &&
          (theirs.action != ours.action ||
              !_sameList(theirs.needs, ours.needs))) {
        found.add('другой выход auth.logout');
      }
    }
    return found;
  }

  static bool _sameList(List<String> a, List<String> b) =>
      a.length == b.length && a.toSet().containsAll(b);

  static bool _sameAccess(
    Map<String, ManifestAccess> a,
    Map<String, ManifestAccess> b,
  ) =>
      a.length == b.length &&
      a.entries.every(
        (MapEntry<String, ManifestAccess> e) =>
            b[e.key] != null && _sameList(e.value.needs, b[e.key]!.needs),
      );

  static bool _sameGet(ManifestCredentialGet? a, ManifestCredentialGet? b) {
    if (a == null || b == null) return a == null && b == null;
    return a.action == b.action &&
        a.take == b.take &&
        a.body.length == b.body.length &&
        a.body.entries.every(
          (MapEntry<String, Object?> e) => b.body[e.key] == e.value,
        );
  }

  static bool _auth(String role, String action) =>
      ManifestDescription.authActions[role]?.contains(action) ?? false;

  static bool _sameMap(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length &&
      a.entries.every((MapEntry<String, String> e) => b[e.key] == e.value);

  /// Сравнение версий вида `1.4.56`: больше нуля — [a] новее [b]. Нет
  /// версии — самая старая; часть не из цифр («1.5.0-beta») — версия не
  /// сравнима и не считается новее (0).
  static int compareVersions(String? a, String? b) {
    final left = _parts(a);
    final right = _parts(b);
    if (a != null && left == null) return 0;
    if (b != null && right == null) return 0;
    if (left == null) return right == null ? 0 : -1;
    if (right == null) return 1;
    final length = left.length > right.length ? left.length : right.length;
    for (var i = 0; i < length; i++) {
      final x = i < left.length ? left[i] : 0;
      final y = i < right.length ? right[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  static final RegExp _version = RegExp(r'^\d{1,6}(\.\d{1,6}){0,5}$');

  static List<int>? _parts(String? version) {
    if (version == null) return null;
    final text = version.trim();
    if (!_version.hasMatch(text)) return null;
    return <int>[for (final part in text.split('.')) int.parse(part)];
  }
}
