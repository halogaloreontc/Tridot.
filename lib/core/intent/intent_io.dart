import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'intent_memory.dart';
import 'intent_pack.dart';

/// Пакет модели в папке на устройстве: `<поддержка>/assistant/intent/<уровень>/`
/// (туда его распакует скачивание, шаг 3) или папка из `TRIDOT_INTENT_PACK`
/// для разработки. Только `dart:io`: веб-помощник читает пакет со своего
/// адреса.
final class DirectoryPackSource implements IntentPackSource {
  DirectoryPackSource(this.path);

  final String path;

  File file(String name) => File('$path${Platform.pathSeparator}$name');

  /// В папке есть `manifest.json`.
  bool get exists => file(IntentManifest.manifestFile).existsSync();

  @override
  Future<Uint8List> read(String name) async {
    if (name.contains('/') || name.contains(r'\') || name.startsWith('.')) {
      throw IntentPackException('имя файла пакета $name');
    }
    try {
      return await file(name).readAsBytes();
    } on FileSystemException catch (error) {
      throw IntentPackException('$name: ${error.message}');
    }
  }
}

/// Память запасного слоя в JSON-файле на устройстве
/// (`<поддержка>/assistant/intent/memory.json`). Повреждённый файл не
/// мешает: память как новая и перезапишется при сохранении. Запись — через
/// временный файл, по очереди.
final class JsonIntentMemoryStore implements IntentMemoryStore {
  JsonIntentMemoryStore(this.filePath);

  final String filePath;
  Future<void> _writes = Future<void>.value();

  @override
  Future<Map<String, Object?>?> load() async {
    final file = File(filePath);
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, Object?>) return decoded;
    } on Object {
      // Повреждённый или нечитаемый файл.
    }
    return null;
  }

  @override
  Future<void> save(Map<String, Object?> json) {
    final write = _writes.then((_) => _write(json));
    _writes = write.catchError((Object _) {});
    return write;
  }

  Future<void> _write(Map<String, Object?> json) async {
    final file = File(filePath);
    await file.parent.create(recursive: true);
    final temporary = File('$filePath.tmp');
    await temporary.writeAsString(jsonEncode(json), flush: true);
    await temporary.rename(filePath);
  }
}
