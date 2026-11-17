import 'dart:convert';

import 'package:characters/characters.dart';

import 'chat_models.dart';

/// Проект-папка (ADR-018): название, необязательное описание и сессии,
/// которые в него положили ([ChatThread.projectId]). Как папки проектов в
/// других чат-приложениях: из проекта сразу начинают новую сессию, а
/// готовую сессию переносят в проект и обратно.
///
/// Папку можно связать с меткой задач ([taskTag], «#работа»): тогда на её
/// экране видны задачи с этой меткой, а задача, созданная в сессии папки
/// без своей метки, получает метку папки. Метки задач остаются как были:
/// папка их не заменяет.
final class ChatProject {
  const ChatProject({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.description,
    this.taskTag,
    this.pinnedAt,
  });

  /// Префикс id: `project:<микросекунды>_<случайное>`.
  static const String prefix = 'project:';

  /// Самое длинное название проекта (в видимых знаках).
  static const int nameLimit = ChatThread.customTitleLimit;

  /// Самое длинное описание (в видимых знаках).
  static const int descriptionLimit = 500;

  final String id;
  final String name;

  /// Описание одной-двумя фразами; `null` — нет.
  final String? description;

  /// Метка задач без «#», в нижнем регистре; `null` — папка не связана с
  /// меткой.
  final String? taskTag;

  final DateTime createdAt;

  /// Когда меняли сам проект или его сессии: свежие проекты — выше.
  final DateTime updatedAt;

  /// Когда закрепили; `null` — не закреплён.
  final DateTime? pinnedAt;

  bool get pinned => pinnedAt != null;

  ChatProject copyWith({
    String? name,
    String? description,
    bool clearDescription = false,
    String? taskTag,
    bool clearTaskTag = false,
    DateTime? updatedAt,
    DateTime? pinnedAt,
    bool clearPinned = false,
  }) =>
      ChatProject(
        id: id,
        name: name ?? this.name,
        description:
            clearDescription ? null : (description ?? this.description),
        taskTag: clearTaskTag ? null : (taskTag ?? this.taskTag),
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        pinnedAt: clearPinned ? null : (pinnedAt ?? this.pinnedAt),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        if (description != null) 'description': description,
        if (taskTag != null) 'task_tag': taskTag,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        if (pinnedAt != null) 'pinned_at': pinnedAt!.toIso8601String(),
      };

  /// Проект из projects.json. Повреждённая запись — `null`: её пропускают,
  /// остальные читаются. Необязательные поля читаются осторожно: нет или
  /// не того типа — `null`.
  static ChatProject? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final rawName = json['name'];
    final created = DateTime.tryParse('${json['created_at']}');
    if (id is! String ||
        !id.startsWith(prefix) ||
        id.length == prefix.length ||
        rawName is! String ||
        created == null) {
      return null;
    }
    final name = cleanName(rawName);
    if (name == null) return null;
    final description = json['description'];
    final tag = json['task_tag'];
    final pinned = json['pinned_at'];
    return ChatProject(
      id: id,
      name: name,
      description: description is String ? cleanDescription(description) : null,
      taskTag: tag is String ? normalizeTag(tag) : null,
      createdAt: created,
      updatedAt: DateTime.tryParse('${json['updated_at']}') ?? created,
      pinnedAt: pinned is String ? DateTime.tryParse(pinned) : null,
    );
  }

  /// Название: пробелы схлопнуты, края обрезаны, не длиннее [nameLimit]
  /// видимых знаков. Пустое — `null`.
  static String? cleanName(String text) => ChatThread.cleanCustomTitle(text);

  /// Описание: края обрезаны, пустые строки схлопнуты, не длиннее
  /// [descriptionLimit] знаков. Пустое — `null`.
  static String? cleanDescription(String text) {
    final flat = text
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    if (flat.isEmpty) return null;
    final chars = flat.characters;
    return chars.length <= descriptionLimit
        ? flat
        : chars.take(descriptionLimit).toString().trimRight();
  }

  /// Метка задач, как её хранит TaskService: без «#», без пробелов по
  /// краям, в нижнем регистре. Пустая или с пробелом внутри — `null`
  /// (метка в команде — одно слово).
  static String? normalizeTag(String text) {
    final tag = text.trim().replaceFirst(RegExp('^#+'), '').toLowerCase();
    if (tag.isEmpty || RegExp(r'\s').hasMatch(tag)) return null;
    return tag;
  }
}

/// Формат `chats/projects/projects.json`.
abstract final class ChatProjectCodec {
  static const int schemaVersion = 1;

  /// Имя файла.
  static const String fileName = 'projects.json';

  /// Подпапка папки чатов, где лежит [fileName]. Не в самой папке чатов:
  /// прежние версии при пересборке index.json читают каждый `*.json`
  /// верхнего уровня как чат и откладывают «непонятный» в `.broken` —
  /// откат на старую версию стирал бы папки (ADR-018). Подпапки они не
  /// читают и при очистке истории не удаляют.
  static const String folder = 'projects';

  static String encode(Iterable<ChatProject> projects) =>
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'schema_version': schemaVersion,
        'projects': <Map<String, Object?>>[
          for (final project in projects) project.toJson(),
        ],
      });

  /// Проекты из файла или `null`, если файл повреждён (не JSON, новая
  /// версия формата, не та структура). Битые записи и повторы id
  /// пропускаются.
  static List<ChatProject>? decode(String content) {
    final Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final version = decoded['schema_version'];
    if (version is! int || version < 1 || version > schemaVersion) {
      return null;
    }
    final rows = decoded['projects'];
    if (rows is! List) return null;
    final seen = <String>{};
    return <ChatProject>[
      for (final row in rows)
        if (ChatProject.fromJson(row) case final ChatProject project
            when seen.add(project.id))
          project,
    ];
  }
}
