import '../connectors/connector.dart';
import 'pack.dart';

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
/// включено из выключенного по умолчанию. Хранится в настройках, поэтому
/// новое расширение, включённое по умолчанию, после обновления приложения
/// появляется включённым.
final class ExtensionChoice {
  const ExtensionChoice({
    this.disabled = const <String>{},
    this.enabled = const <String>{},
  });

  /// Выключенные id расширений, включённых по умолчанию.
  final Set<String> disabled;

  /// Явно включённые id расширений, выключенных по умолчанию.
  final Set<String> enabled;

  bool isEnabled(ExtensionInfo info) {
    if (info.required) return true;
    return info.defaultEnabled
        ? !disabled.contains(info.id)
        : enabled.contains(info.id);
  }

  /// Новый выбор, где [info] включено или выключено.
  ExtensionChoice withEnabled(ExtensionInfo info, bool value) {
    if (info.required && !value) {
      throw StateError('«${info.title}» нельзя выключить');
    }
    final disabled = Set<String>.of(this.disabled)..remove(info.id);
    final enabled = Set<String>.of(this.enabled)..remove(info.id);
    if (info.defaultEnabled && !value) disabled.add(info.id);
    if (!info.defaultEnabled && value) enabled.add(info.id);
    return ExtensionChoice(disabled: disabled, enabled: enabled);
  }

  /// Выбор без следов [id]: расширение снова в состоянии по умолчанию.
  ExtensionChoice without(String id) =>
      !disabled.contains(id) && !enabled.contains(id)
          ? this
          : ExtensionChoice(
              disabled: Set<String>.of(disabled)..remove(id),
              enabled: Set<String>.of(enabled)..remove(id),
            );

  bool sameAs(ExtensionChoice other) =>
      disabled.length == other.disabled.length &&
      enabled.length == other.enabled.length &&
      disabled.containsAll(other.disabled) &&
      enabled.containsAll(other.enabled);
}
