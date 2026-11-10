import '../connectors/connector.dart';
import 'pack.dart';
import 'role.dart';

/// Паспорт расширения для «Настройки → Расширения».
final class ExtensionInfo {
  const ExtensionInfo({
    required this.id,
    required this.kind,
    required this.title,
    required this.description,
    this.version = '1.0.0',
    this.author = ConnectorInfo.defaultAuthor,
    this.builtIn = true,
    this.defaultEnabled = true,
    this.required = false,
  });

  /// Навык или подключение: код всегда в составе приложения (ADR-005).
  factory ExtensionInfo.fromConnector(ConnectorInfo info) => ExtensionInfo(
        id: info.id,
        kind: info.kind,
        title: info.title,
        description: info.description,
        version: info.version,
        author: info.author,
        defaultEnabled: info.defaultEnabled,
        required: info.required,
      );

  factory ExtensionInfo.fromPack(Pack pack, {required bool builtIn}) =>
      ExtensionInfo(
        id: pack.id,
        kind: ExtensionKind.pack,
        title: pack.title,
        description: pack.description,
        version: pack.version,
        author: pack.author,
        builtIn: builtIn,
      );

  final String id;
  final ExtensionKind kind;
  final String title;
  final String description;
  final String version;
  final String author;

  /// Встроено в приложение: код навыков и подключений, паки из assets.
  final bool builtIn;

  /// Включено, пока пользователь не выключил.
  final bool defaultEnabled;

  /// Не выключается (задачи).
  final bool required;
}

/// Выбор пользователя: что выключено из включённого по умолчанию и что
/// включено из выключенного по умолчанию — для расширений и для ролей —
/// и кто ведёт каждую роль. Хранится в настройках, поэтому новое
/// расширение или роль, включённые по умолчанию, после обновления
/// приложения появляются включёнными.
///
/// [isEnabled] — правило без ролей; с ролями решает
/// [ExtensionRegistry.enabledUnder] (docs/EXTENSIONS.md, «Роли и
/// расширения»).
final class ExtensionChoice {
  const ExtensionChoice({
    this.disabled = const <String>{},
    this.enabled = const <String>{},
    this.disabledRoles = const <String>{},
    this.enabledRoles = const <String>{},
    this.roleOwners = const <String, String>{},
  });

  /// Выключенные id расширений, включённых по умолчанию. Для расширения,
  /// которое входит в роль, — выключенное пользователем явно, при любом
  /// `defaultEnabled`.
  final Set<String> disabled;

  /// Явно включённые id расширений, выключенных по умолчанию. Для
  /// расширения, которое входит в роль, не действует: его включает роль.
  final Set<String> enabled;

  /// Выключенные роли из включённых по умолчанию.
  final Set<String> disabledRoles;

  /// Включённые роли из выключенных по умолчанию.
  final Set<String> enabledRoles;

  /// Кто ведёт роль: id роли → id помощника (`rio`, `noda`). Нет записи —
  /// ведёт основной.
  final Map<String, String> roleOwners;

  bool isEnabled(ExtensionInfo info) {
    if (info.required) return true;
    return info.defaultEnabled
        ? !disabled.contains(info.id)
        : enabled.contains(info.id);
  }

  bool isRoleEnabled(RoleInfo role) => role.defaultEnabled
      ? !disabledRoles.contains(role.id)
      : enabledRoles.contains(role.id);

  ExtensionChoice _copy({
    Set<String>? disabled,
    Set<String>? enabled,
    Set<String>? disabledRoles,
    Set<String>? enabledRoles,
    Map<String, String>? roleOwners,
  }) =>
      ExtensionChoice(
        disabled: disabled ?? this.disabled,
        enabled: enabled ?? this.enabled,
        disabledRoles: disabledRoles ?? this.disabledRoles,
        enabledRoles: enabledRoles ?? this.enabledRoles,
        roleOwners: roleOwners ?? this.roleOwners,
      );

  /// Новый выбор, где [info] включено или выключено.
  ExtensionChoice withEnabled(ExtensionInfo info, bool value) {
    if (info.required && !value) {
      throw StateError('«${info.title}» нельзя выключить');
    }
    final disabled = Set<String>.of(this.disabled)..remove(info.id);
    final enabled = Set<String>.of(this.enabled)..remove(info.id);
    if (info.defaultEnabled && !value) disabled.add(info.id);
    if (!info.defaultEnabled && value) enabled.add(info.id);
    return _copy(disabled: disabled, enabled: enabled);
  }

  /// Новый выбор для расширения, которое входит в роль: включить — снять
  /// явное выключение (дальше решает роль), выключить — выключить явно.
  ExtensionChoice withRoleExtension(ExtensionInfo info, bool value) {
    if (info.required && !value) {
      throw StateError('«${info.title}» нельзя выключить');
    }
    final disabled = Set<String>.of(this.disabled)..remove(info.id);
    final enabled = Set<String>.of(this.enabled)..remove(info.id);
    if (!value) disabled.add(info.id);
    return _copy(disabled: disabled, enabled: enabled);
  }

  /// Новый выбор, где роль [role] включена или выключена. Подключения и
  /// секреты роли не трогаются: включённая снова роль работает без
  /// нового входа.
  ExtensionChoice withRole(RoleInfo role, bool value) {
    final disabledRoles = Set<String>.of(this.disabledRoles)..remove(role.id);
    final enabledRoles = Set<String>.of(this.enabledRoles)..remove(role.id);
    if (role.defaultEnabled && !value) disabledRoles.add(role.id);
    if (!role.defaultEnabled && value) enabledRoles.add(role.id);
    return _copy(disabledRoles: disabledRoles, enabledRoles: enabledRoles);
  }

  /// Новый выбор, где роль [roleId] ведёт помощник [personaId]; `null` —
  /// основной.
  ExtensionChoice withOwner(String roleId, String? personaId) {
    final owners = Map<String, String>.of(roleOwners)..remove(roleId);
    if (personaId != null) owners[roleId] = personaId;
    return _copy(roleOwners: owners);
  }

  /// Выбор без следов [id]: расширение снова в состоянии по умолчанию.
  ExtensionChoice without(String id) =>
      !disabled.contains(id) && !enabled.contains(id)
          ? this
          : _copy(
              disabled: Set<String>.of(disabled)..remove(id),
              enabled: Set<String>.of(enabled)..remove(id),
            );

  static bool _sameSet(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  bool sameAs(ExtensionChoice other) =>
      _sameSet(disabled, other.disabled) &&
      _sameSet(enabled, other.enabled) &&
      _sameSet(disabledRoles, other.disabledRoles) &&
      _sameSet(enabledRoles, other.enabledRoles) &&
      roleOwners.length == other.roleOwners.length &&
      roleOwners.entries.every(
        (MapEntry<String, String> e) => other.roleOwners[e.key] == e.value,
      );
}
