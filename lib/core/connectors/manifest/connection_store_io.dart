import 'dart:convert';
import 'dart:io';

import 'connection.dart';

// Файловое хранилище подключений — отдельно от connection.dart: путь
// коннектора (описание, запись, ключи) не тянет dart:io и собирается для
// веб-помощника (ADR-032). Импортирует его только lib/main.dart.

/// Файлы в `<папка данных>/connections`: `<appId>.json` (состояние) и
/// `<appId>.assistant.json` (кэш описания). Повреждённый файл не мешает
/// запуску: подключение считается новым.
final class JsonConnectionStore implements ConnectionStore {
  JsonConnectionStore(this.directory);

  final String directory;
  Future<void> _writes = Future<void>.value();

  static final RegExp _safeId = RegExp(r'^[a-z][a-z0-9_-]{0,63}$');

  String _path(String appId, String suffix) {
    if (!_safeId.hasMatch(appId)) {
      throw ArgumentError.value(appId, 'appId', 'Неверный id приложения');
    }
    return '$directory${Platform.pathSeparator}$appId$suffix';
  }

  @override
  Future<ConnectionRecord?> load(String appId) async {
    final file = File(_path(appId, '.json'));
    try {
      if (!await file.exists()) return null;
      return ConnectionRecord.fromJson(
        appId,
        jsonDecode(await file.readAsString()),
      );
    } on Object {
      return null;
    }
  }

  @override
  Future<void> save(ConnectionRecord record) => _write(
        _path(record.appId, '.json'),
        const JsonEncoder.withIndent('  ').convert(record.toJson()),
      );

  @override
  Future<String?> loadManifest(String appId) async {
    final file = File(_path(appId, '.assistant.json'));
    try {
      return await file.exists() ? await file.readAsString() : null;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> saveManifest(String appId, String source) =>
      _write(_path(appId, '.assistant.json'), source);

  Future<void> _write(String path, String text) {
    final write = _writes.then((_) async {
      final file = File(path);
      await file.parent.create(recursive: true);
      final temporary = File('$path.tmp');
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(path);
    });
    _writes = write.catchError((Object _) {});
    return write;
  }
}
