import 'dart:io';

import '../services/clock.dart';

/// Сведения о месте данных для экрана «Данные».
abstract interface class StorageInfo {
  /// Короткое описание: «JSON на этом устройстве».
  String get label;

  /// Путь к файлу или null, если данные только в памяти.
  String? get location;

  /// Папка истории чатов (`chats/`, ADR-010) или null, если чаты только в
  /// памяти.
  String? get chatsLocation;

  /// Размер данных в байтах; null, если файла ещё нет.
  Future<int?> sizeBytes();

  bool get canBackup;

  /// Копия данных рядом с исходным файлом; возвращает путь копии.
  Future<String> backup();
}

final class JsonStorageInfo implements StorageInfo {
  JsonStorageInfo(
    this.filePath, {
    this.chatsDirectory,
    Clock clock = const SystemClock(),
  }) : _clock = clock;

  final String filePath;

  /// Папка чатов: её файлы входят в размер. Резервная копия — по-прежнему
  /// только tasks.json (копия чатов — docs/PLANS.md).
  final String? chatsDirectory;
  final Clock _clock;

  @override
  String? get chatsLocation => chatsDirectory;

  @override
  String get label => 'JSON на этом устройстве';

  @override
  String? get location => filePath;

  @override
  bool get canBackup => true;

  /// tasks.json и все файлы чатов; null, если нет ни того, ни другого.
  @override
  Future<int?> sizeBytes() async {
    final file = File(filePath);
    int? total = await file.exists() ? await file.length() : null;
    final chats = chatsDirectory;
    if (chats != null && await Directory(chats).exists()) {
      await for (final entity in Directory(chats).list()) {
        if (entity is File && entity.path.endsWith('.json')) {
          total = (total ?? 0) + await entity.length();
        }
      }
    }
    return total;
  }

  @override
  Future<String> backup() async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw StateError('Задач ещё нет — копировать нечего');
    }
    final now = _clock.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final dot = filePath.lastIndexOf('.');
    final base = dot > 0 ? filePath.substring(0, dot) : filePath;
    final target = '$base.backup-$stamp.json';
    await file.copy(target);
    return target;
  }
}

/// Данные только в памяти (веб-превью, тесты): копировать некуда.
final class MemoryStorageInfo implements StorageInfo {
  const MemoryStorageInfo();

  @override
  String get label => 'Только в памяти — данные пропадут после закрытия';

  @override
  String? get location => null;

  @override
  String? get chatsLocation => null;

  @override
  bool get canBackup => false;

  @override
  Future<int?> sizeBytes() async => null;

  @override
  Future<String> backup() =>
      Future<String>.error(UnsupportedError('Данные только в памяти'));
}
