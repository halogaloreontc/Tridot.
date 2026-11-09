import 'dart:convert';
import 'dart:io';

import 'secret_store.dart';

/// Секреты подключений в отдельном файле приложения (ADR-011).
///
/// Временная реализация без новых пакетов: файл лежит в служебной папке
/// приложения (не в «Документах» рядом с задачами и не в settings.json),
/// на macOS и Linux у него права только владельца (`600`). Это не
/// Keychain и не Keystore: защищённое хранилище платформы — следующий шаг
/// (docs/PLANS.md), [SecretStore] позволяет заменить реализацию без
/// правок коннекторов. Значения никуда не печатаются.
final class FileSecretStore implements SecretStore {
  FileSecretStore(this.filePath);

  final String filePath;
  Map<String, String>? _cache;
  Future<void> _writes = Future<void>.value();

  Future<Map<String, String>> _values() async {
    final cached = _cache;
    if (cached != null) return cached;
    final values = <String, String>{};
    try {
      final file = File(filePath);
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          for (final MapEntry(:key, :value) in decoded.entries) {
            if (key is String && value is String) values[key] = value;
          }
        }
      }
    } on Object {
      // Повреждённый файл: секретов нет, подключиться можно заново.
    }
    return _cache = values;
  }

  @override
  Future<String?> read(String key) async => (await _values())[key];

  @override
  Future<void> write(String key, String value) async {
    final values = await _values();
    values[key] = value;
    await _save(values);
  }

  @override
  Future<void> delete(String key) async {
    final values = await _values();
    if (values.remove(key) == null) return;
    await _save(values);
  }

  Future<void> _save(Map<String, String> values) {
    final text = jsonEncode(values);
    final write = _writes.then((_) async {
      final file = File(filePath);
      await file.parent.create(recursive: true);
      final temporary = File('$filePath.tmp');
      await temporary.writeAsString('', flush: true);
      await _ownerOnly(temporary.path);
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(filePath);
    });
    _writes = write.catchError((Object _) {});
    return write;
  }

  static Future<void> _ownerOnly(String path) async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    try {
      await Process.run('chmod', <String>['600', path]);
    } on Object {
      // Нет chmod (песочница): файл всё равно в служебной папке приложения.
    }
  }
}
