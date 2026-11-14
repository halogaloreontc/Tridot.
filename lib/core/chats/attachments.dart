import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:path/path.dart' as p;

import 'chat_store.dart';

/// Вид вложения: от него зависят значок, превью и название сессии без
/// текста (ADR-019).
enum AttachmentKind {
  image('Фото'),
  video('Видео'),
  audio('Аудио'),
  document('Документ'),
  other('Файл');

  const AttachmentKind(this.label);

  /// Подпись вида: «Фото», «Видео», «Аудио», «Документ», «Файл».
  final String label;

  static const Set<String> _images = <String>{
    'jpg', 'jpeg', 'png', 'webp', 'gif', 'heic', 'heif', 'bmp', //
  };
  static const Set<String> _videos = <String>{
    'mp4', 'mov', 'mkv', 'webm', 'avi', '3gp', 'm4v', //
  };
  static const Set<String> _audios = <String>{
    'mp3', 'm4a', 'aac', 'ogg', 'oga', 'opus', 'wav', 'flac', 'amr', //
  };
  static const Set<String> _documents = <String>{
    'pdf', 'txt', 'md', 'doc', 'docx', 'xls', 'xlsx', 'odt', 'ods', 'rtf',
    'csv', 'ppt', 'pptx', 'odp', //
  };

  /// Вид по MIME-типу, а без него — по расширению имени [name].
  static AttachmentKind of(String name, [String? mime]) {
    final type = mime?.toLowerCase() ?? '';
    if (type.startsWith('image/')) return image;
    if (type.startsWith('video/')) return video;
    if (type.startsWith('audio/')) return audio;
    final ext = extensionOf(name);
    if (_images.contains(ext)) return image;
    if (_videos.contains(ext)) return video;
    if (_audios.contains(ext)) return audio;
    if (_documents.contains(ext) ||
        type == 'application/pdf' ||
        type.startsWith('text/')) {
      return document;
    }
    return other;
  }

  /// Расширение имени без точки, строчными; нет — пустая строка.
  static String extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }
}

/// Файл, прикреплённый к сообщению (ADR-019): копия лежит в папке сессии
/// `chats/files/<сессия>/`, в JSON чата — только описание.
final class ChatAttachment {
  const ChatAttachment({
    required this.id,
    required this.kind,
    required this.name,
    required this.path,
    required this.size,
    required this.addedAt,
    this.mime,
  });

  /// `<id сообщения>-<номер>`.
  final String id;
  final AttachmentKind kind;

  /// Имя для показа: как у исходного файла, но без секретов (очищено до
  /// сохранения).
  final String name;

  /// Путь копии относительно папки чатов: `files/<сессия>/<файл>`.
  final String path;

  /// Размер в байтах.
  final int size;

  final String? mime;
  final DateTime addedAt;

  /// Самое длинное имя для показа.
  static const int nameLimit = 120;

  /// Название сессии без текста: «Фото», «Видео», «Аудио» или
  /// «Файл: <имя>».
  String get sessionTitle => switch (kind) {
        AttachmentKind.image ||
        AttachmentKind.video ||
        AttachmentKind.audio =>
          kind.label,
        _ => 'Файл: $name',
      };

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'kind': kind.name,
        'name': name,
        'path': path,
        'size': size,
        if (mime != null) 'mime': mime,
        'added_at': addedAt.toIso8601String(),
      };

  /// Описание из файла чата. Битое — `null` (сообщение читается без него).
  /// Путь — только внутри `files/`, без «..»: файл чата не может указать
  /// на чужой файл.
  static ChatAttachment? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    final path = json['path'];
    final size = json['size'];
    final mime = json['mime'];
    final added = DateTime.tryParse('${json['added_at']}');
    final kind = AttachmentKind.values
            .where((AttachmentKind k) => k.name == json['kind'])
            .firstOrNull ??
        AttachmentKind.other;
    if (id is! String ||
        id.isEmpty ||
        name is! String ||
        path is! String ||
        !isSafePath(path) ||
        size is! int ||
        size < 0 ||
        added == null) {
      return null;
    }
    return ChatAttachment(
      id: id,
      kind: kind,
      name: cleanName(name),
      path: path,
      size: size,
      mime: mime is String && mime.isNotEmpty ? mime : null,
      addedAt: added,
    );
  }

  /// `files/<папка>/<файл>`: три части, без «..», без обратной черты.
  static bool isSafePath(String path) {
    final parts = path.split('/');
    return parts.length == 3 &&
        parts.first == AttachmentStore.folder &&
        parts.every(
          (String part) =>
              part.isNotEmpty &&
              part != '.' &&
              part != '..' &&
              RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(part),
        );
  }

  /// Имя для показа: без управляющих знаков, пробелы схлопнуты, не длиннее
  /// [nameLimit] знаков. Пустое — «файл».
  static String cleanName(String name) {
    final flat = name
        .replaceAll(
          RegExp(r'[\u0000-\u001f\u007f\u200e\u200f\u202a-\u202e]'),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (flat.isEmpty) return 'файл';
    final chars = flat.characters;
    return chars.length <= nameLimit
        ? flat
        : chars.take(nameLimit).toString().trimRight();
  }

  /// «2,4 МБ», «830 КБ», «12 Б».
  static String sizeLabel(int bytes) {
    if (bytes < 1024) return '$bytes Б';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} КБ';
    final mb = bytes / (1024 * 1024);
    final text = mb >= 10 ? mb.round().toString() : mb.toStringAsFixed(1);
    return '${text.replaceAll('.', ',')} МБ';
  }

  @override
  bool operator ==(Object other) =>
      other is ChatAttachment &&
      other.id == id &&
      other.kind == kind &&
      other.name == name &&
      other.path == path &&
      other.size == size &&
      other.mime == mime &&
      other.addedAt == addedAt;

  @override
  int get hashCode => Object.hash(id, kind, name, path, size, mime, addedAt);
}

/// Откуда берётся файл: обёртка над выбранным файлом (в приложении —
/// `XFile`), чтобы ядро не зависело от Flutter.
abstract interface class AttachmentSource {
  /// Имя файла, как его назвала система.
  String get name;

  /// MIME-тип, если система его знает.
  String? get mimeType;

  /// Размер в байтах.
  Future<int> length();

  /// Скопировать файл в [path] (без чтения целиком в память, если файл на
  /// диске).
  Future<void> saveTo(String path);

  /// Всё содержимое — только для хранилища в памяти.
  Future<Uint8List> readAsBytes();
}

/// Файл больше [AttachmentStore.maxBytes].
final class AttachmentTooLarge implements Exception {
  const AttachmentTooLarge(this.name, this.size);

  final String name;
  final int size;

  @override
  String toString() => 'AttachmentTooLarge($size)';
}

/// Где лежат копии вложений (ADR-019). Папка сессии —
/// `files/<имя файла чата без .json>/`, файл — `<id сообщения>-<номер>.<расширение>`:
/// имя для показа хранится в JSON, на диске его нет.
abstract interface class AttachmentStore {
  /// Папка вложений внутри папки чатов.
  static const String folder = 'files';

  /// Самый большой файл: 25 МБ. Больше — не прикрепляется.
  static const int maxBytes = 25 * 1024 * 1024;

  /// Сколько файлов можно прикрепить к одному сообщению.
  static const int maxPerMessage = 10;

  /// Файлы переживают перезапуск (на диске), а не только в памяти.
  bool get persistent;

  /// Скопировать [source] в папку чата [chatId] как вложение номер [index]
  /// сообщения [messageId]. Имя для показа — [name] (уже очищенное).
  /// Больше [maxBytes] — [AttachmentTooLarge].
  Future<ChatAttachment> import(
    String chatId,
    String messageId,
    int index,
    AttachmentSource source, {
    required String name,
    required DateTime now,
  });

  /// Полный путь копии на диске; `null` — хранилище в памяти.
  String? pathOf(ChatAttachment attachment);

  /// Содержимое копии в памяти; `null` — копия на диске или её нет.
  Uint8List? bytesOf(ChatAttachment attachment);

  /// Копия на месте.
  bool exists(ChatAttachment attachment);

  /// Стереть все вложения чата [chatId] (сессию удалили).
  Future<void> eraseChat(String chatId);

  /// Стереть все вложения («Очистить историю сессий»).
  Future<void> clearAll();

  /// Стереть файлы чата [chatId], на которые не ссылается ни одно
  /// сообщение: [live] — пути живых вложений.
  Future<void> sweep(String chatId, Set<String> live);
}

/// Общие правила раскладки файлов.
abstract final class AttachmentPaths {
  /// Имя папки чата: имя его файла без `.json`.
  static String chatFolder(String chatId) {
    final file = ChatCodec.fileName(chatId);
    return file.substring(0, file.length - '.json'.length);
  }

  /// Имя копии: `<id сообщения>-<номер>[.<расширение>]`, только латиница,
  /// цифры, «_», «-» и «.».
  static String fileName(String messageId, int index, String name) {
    final base = '${messageId.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_')}'
        '-$index';
    final ext = AttachmentKind.extensionOf(name);
    final safe = RegExp(r'^[a-z0-9]{1,8}$').hasMatch(ext) ? '.$ext' : '';
    return '$base$safe';
  }

  /// Относительный путь копии.
  static String relative(
    String chatId,
    String messageId,
    int index,
    String name,
  ) =>
      '${AttachmentStore.folder}/${chatFolder(chatId)}/'
      '${fileName(messageId, index, name)}';
}

/// Вложения в памяти: тесты и режим «Только в памяти» — пропадают с
/// закрытием приложения, как и чаты.
final class InMemoryAttachmentStore implements AttachmentStore {
  /// [persistent] — только для тестов, где хранилище в памяти изображает
  /// диск (файлы можно прикреплять, «перезапуск» их сохраняет).
  InMemoryAttachmentStore({this.persistent = false});

  final Map<String, Uint8List> _files = <String, Uint8List>{};

  /// Пути сохранённых копий (для тестов).
  Iterable<String> get paths => _files.keys;

  @override
  final bool persistent;

  @override
  Future<ChatAttachment> import(
    String chatId,
    String messageId,
    int index,
    AttachmentSource source, {
    required String name,
    required DateTime now,
  }) async {
    final size = await source.length();
    if (size > AttachmentStore.maxBytes) throw AttachmentTooLarge(name, size);
    final path = AttachmentPaths.relative(chatId, messageId, index, name);
    _files[path] = await source.readAsBytes();
    return ChatAttachment(
      id: '$messageId-$index',
      kind: AttachmentKind.of(name, source.mimeType),
      name: ChatAttachment.cleanName(name),
      path: path,
      size: size,
      mime: source.mimeType,
      addedAt: now,
    );
  }

  @override
  String? pathOf(ChatAttachment attachment) => null;

  @override
  Uint8List? bytesOf(ChatAttachment attachment) => _files[attachment.path];

  @override
  bool exists(ChatAttachment attachment) => _files.containsKey(attachment.path);

  @override
  Future<void> eraseChat(String chatId) async {
    final prefix =
        '${AttachmentStore.folder}/${AttachmentPaths.chatFolder(chatId)}/';
    _files.removeWhere((String path, _) => path.startsWith(prefix));
  }

  @override
  Future<void> clearAll() async => _files.clear();

  @override
  Future<void> sweep(String chatId, Set<String> live) async {
    final prefix =
        '${AttachmentStore.folder}/${AttachmentPaths.chatFolder(chatId)}/';
    _files.removeWhere(
      (String path, _) => path.startsWith(prefix) && !live.contains(path),
    );
  }
}

/// Вложения на диске: `<папка чатов>/files/<сессия>/<файл>`.
final class IoAttachmentStore implements AttachmentStore {
  IoAttachmentStore(this.chatsDirectory);

  /// Папка чатов (там же index.json).
  final String chatsDirectory;

  /// Папка всех вложений.
  String get root => p.join(chatsDirectory, AttachmentStore.folder);

  String _absolute(String relative) =>
      p.joinAll(<String>[chatsDirectory, ...relative.split('/')]);

  Directory _chatDirectory(String chatId) =>
      Directory(p.join(root, AttachmentPaths.chatFolder(chatId)));

  @override
  bool get persistent => true;

  @override
  Future<ChatAttachment> import(
    String chatId,
    String messageId,
    int index,
    AttachmentSource source, {
    required String name,
    required DateTime now,
  }) async {
    final size = await source.length();
    if (size > AttachmentStore.maxBytes) throw AttachmentTooLarge(name, size);
    final relative = AttachmentPaths.relative(chatId, messageId, index, name);
    final target = _absolute(relative);
    await Directory(p.dirname(target)).create(recursive: true);
    final temporary = '$target.tmp';
    try {
      await source.saveTo(temporary);
      await File(temporary).rename(target);
    } on Object {
      final left = File(temporary);
      if (await left.exists()) await left.delete();
      rethrow;
    }
    return ChatAttachment(
      id: '$messageId-$index',
      kind: AttachmentKind.of(name, source.mimeType),
      name: ChatAttachment.cleanName(name),
      path: relative,
      // Размер копии, а не обещанный системой.
      size: await File(target).length(),
      mime: source.mimeType,
      addedAt: now,
    );
  }

  @override
  String? pathOf(ChatAttachment attachment) => _absolute(attachment.path);

  @override
  Uint8List? bytesOf(ChatAttachment attachment) => null;

  @override
  bool exists(ChatAttachment attachment) {
    try {
      return File(_absolute(attachment.path)).existsSync();
    } on Object {
      return false;
    }
  }

  @override
  Future<void> eraseChat(String chatId) async {
    try {
      final folder = _chatDirectory(chatId);
      if (await folder.exists()) await folder.delete(recursive: true);
    } on Object {
      // Не вышло — файлы останутся до следующей уборки (чтение чата,
      // повторное удаление).
    }
  }

  @override
  Future<void> clearAll() async {
    try {
      final folder = Directory(root);
      if (await folder.exists()) await folder.delete(recursive: true);
    } on Object {
      // Не вышло — файлы останутся до следующей уборки (чтение чата,
      // повторное удаление).
    }
  }

  @override
  Future<void> sweep(String chatId, Set<String> live) async {
    try {
      final folder = _chatDirectory(chatId);
      if (!await folder.exists()) return;
      final prefix =
          '${AttachmentStore.folder}/${AttachmentPaths.chatFolder(chatId)}/';
      var left = 0;
      await for (final entity in folder.list()) {
        if (entity is! File) continue;
        final relative = '$prefix${p.basename(entity.path)}';
        // Копия ещё пишется (`<файл>.tmp` ждущего вложения) — не трогать.
        final writing = relative.endsWith('.tmp') &&
            live.contains(relative.substring(0, relative.length - 4));
        if (live.contains(relative) || writing) {
          left++;
        } else {
          await entity.delete();
        }
      }
      // Не рекурсивно: если за это время в папку начали копировать новый
      // файл, папка не пуста и остаётся.
      if (left == 0) await folder.delete();
    } on Object {
      // Не вышло — файлы останутся до следующей уборки (чтение чата,
      // повторное удаление).
    }
  }
}
