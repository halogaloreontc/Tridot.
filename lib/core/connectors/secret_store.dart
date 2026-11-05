/// Хранилище секретов коннекторов: токены, ключи API, пароли.
///
/// Секреты не кладутся в settings.json и другие открытые файлы (ADR-004).
/// Реализация для приложения должна использовать защищённое хранилище
/// платформы (Android Keystore, Windows Credential Manager, Keychain).
/// Ключи принято называть `<id коннектора>.<имя>`: `warehouse.token`.
abstract interface class SecretStore {
  /// Значение секрета или `null`, если он не задан.
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// Секреты только в памяти процесса: для тестов и запуска без защищённого
/// хранилища. После перезапуска приложения всё забывается.
final class InMemorySecretStore implements SecretStore {
  InMemorySecretStore([Map<String, String> initial = const <String, String>{}])
      : _values = Map<String, String>.of(initial);

  final Map<String, String> _values;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}
