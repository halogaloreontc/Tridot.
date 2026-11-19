import 'dart:io';

import 'connection_directory.dart';
import 'connection_slots.dart';

// Файловый каталог подключений — отдельно от connection_directory.dart:
// путь коннектора не тянет dart:io (веб-помощник, ADR-032). Импортирует
// его только lib/main.dart.

/// Каталог подключений в `<папка данных>/connections` (ADR-039):
/// `_directory.json` и закреплённые описания `<id>.pinned.assistant.json`
/// рядом с записями [JsonConnectionStore]. Имя `_directory` ни с каким id
/// не совпадёт: id начинается с латинской буквы. Повреждённый файл не
/// мешает запуску: каталог считается пустым.
final class JsonConnectionDirectory implements ConnectionDirectory {
  JsonConnectionDirectory(this.directory);

  final String directory;
  Future<void> _writes = Future<void>.value();

  static const String fileName = '_directory.json';

  String get _indexPath => '$directory${Platform.pathSeparator}$fileName';

  String _path(String id, String suffix) {
    if (!ConnectionSlots.idPattern.hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'Неверный id подключения');
    }
    return '$directory${Platform.pathSeparator}$id$suffix';
  }

  @override
  Future<DirectorySnapshot> load() async {
    try {
      final file = File(_indexPath);
      if (!await file.exists()) return const DirectorySnapshot();
      return DirectorySnapshot.decode(await file.readAsString());
    } on Object {
      return const DirectorySnapshot();
    }
  }

  @override
  Future<void> save(DirectorySnapshot snapshot) =>
      _write(_indexPath, snapshot.encode());

  @override
  Future<String?> loadPinned(String id) async {
    try {
      final file = File(_path(id, '.pinned.assistant.json'));
      return await file.exists() ? await file.readAsString() : null;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> savePinned(String id, String source) =>
      _write(_path(id, '.pinned.assistant.json'), source);

  @override
  Future<void> deleteFiles(String id) async {
    await _writes;
    Object? failed;
    for (final suffix in <String>[
      '.json',
      '.assistant.json',
      '.pinned.assistant.json',
    ]) {
      final file = File(_path(id, suffix));
      try {
        if (await file.exists()) await file.delete();
      } on Object catch (error) {
        failed ??= error;
      }
    }
    if (failed != null) throw failed;
  }

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
