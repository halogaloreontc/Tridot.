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
  const DescriptionPick(this.description, this.origin, this.reason);

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
/// права: все его действия — из `api.only` встроенного описания или из
/// [ManifestDescription.authActions].
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
        'встроенное описание $ours: описание сервера $theirs просит '
        'действия, которых нет во встроенном (${extra.join(', ')}).',
      );
    }
    return DescriptionPick(
      server,
      DescriptionOrigin.server,
      'описание сервера $theirs: новее встроенного $ours.',
    );
  }

  /// Действия описания [server], которых нет ни в `api.only` встроенного
  /// [builtIn], ни среди безвредных действий входа и выхода. Пусто — прав
  /// не больше, чем у встроенного.
  static List<String> widening(
    ManifestDescription builtIn,
    ManifestDescription server,
  ) {
    final allowed = <String>{
      ...builtIn.only,
      for (final actions in ManifestDescription.authActions.values) ...actions,
    };
    final used = <String>{
      ...server.only,
      for (final command in server.commands)
        if (command.call case final ManifestCall call) call.action,
      if (server.qr case final ManifestQr qr) qr.action,
      if (server.logout case final ManifestLogout logout) logout.action,
      for (final credential in server.credentials.values)
        if (credential.get case final ManifestCredentialGet get) get.action,
    };
    return (used.difference(allowed).toList()..sort());
  }

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
