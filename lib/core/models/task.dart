enum TaskStatus { inbox, planned, inProgress, done, cancelled }

enum TaskPriority { low, normal, high, urgent }

/// Точность срока задачи.
enum DuePrecision {
  /// Только день: «завтра», «в пятницу».
  date,

  /// День и точное время: «завтра в 10:00».
  dateTime,

  /// День и часть суток без точного времени: «завтра вечером». Время
  /// в [Task.dueAt] — условное ([PartOfDay.hour]), показывается словами
  /// («вечером»), а срок считается прошедшим только с концом части суток.
  partOfDay,
}

/// Часть суток для срока с точностью [DuePrecision.partOfDay]: условный
/// час, к которому ставится срок, и час, когда часть суток кончается.
enum PartOfDay {
  /// «утром» — 9:00, до полудня.
  morning(9, 12, 'утром'),

  /// «днём» — 13:00, до 17:00.
  day(13, 17, 'днём'),

  /// «после обеда» — 14:00, до 18:00.
  afternoon(14, 18, 'после обеда'),

  /// «вечером» — 19:00, до полуночи.
  evening(19, 24, 'вечером');

  const PartOfDay(this.hour, this.endHour, this.label);

  /// Условный час срока.
  final int hour;

  /// Час конца части суток (24 — полночь следующего дня).
  final int endHour;

  /// Как часть суток пишется после дня: «завтра вечером».
  final String label;

  /// Часть суток по условному часу срока. Чужой час (срок поправили
  /// вручную) относится к ближайшей части: до 12 — утро, до 14 — день,
  /// до 17 — после обеда, позже — вечер.
  static PartOfDay of(DateTime due) {
    for (final part in values) {
      if (part.hour == due.hour) return part;
    }
    if (due.hour < 12) return morning;
    if (due.hour < 14) return day;
    if (due.hour < 17) return afternoon;
    return evening;
  }

  /// Момент, когда часть суток дня [due] кончается.
  DateTime endOn(DateTime due) =>
      DateTime(due.year, due.month, due.day, endHour);
}

/// Заметка к задаче (ADR-033): факт, записанный из чата («22 шт в ОК,
/// арт. 67782»), и когда он записан.
final class TaskNote {
  const TaskNote({required this.text, required this.at});

  final String text;
  final DateTime at;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'text': text,
        'at': at.toIso8601String(),
      };

  /// Запись без текста или с испорченной датой пропускается ([Task.fromJson]).
  static TaskNote? fromJson(Object? json) {
    if (json is! Map) return null;
    final text = json['text'];
    final at = json['at'];
    if (text is! String || text.trim().isEmpty || at is! String) return null;
    final parsed = DateTime.tryParse(at);
    if (parsed == null) return null;
    return TaskNote(text: text, at: parsed);
  }
}

/// Пункт чек-листа задачи (ADR-033): «добавь пункт молоко».
final class TaskItem {
  const TaskItem({required this.text, this.done = false});

  final String text;
  final bool done;

  TaskItem copyWith({bool? done}) =>
      TaskItem(text: text, done: done ?? this.done);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'text': text,
        'done': done,
      };

  static TaskItem? fromJson(Object? json) {
    if (json is! Map) return null;
    final text = json['text'];
    if (text is! String || text.trim().isEmpty) return null;
    return TaskItem(text: text, done: json['done'] == true);
  }
}

class Task {
  const Task({
    required this.id,
    required this.title,
    required this.status,
    required this.priority,
    required this.createdAt,
    required this.updatedAt,
    this.description = '',
    this.dueAt,
    this.duePrecision = DuePrecision.dateTime,
    this.tags = const <String>[],
    this.completedAt,
    this.deletedAt,
    this.notes = const <TaskNote>[],
    this.items = const <TaskItem>[],
  });

  final String id;
  final String title;
  final String description;
  final TaskStatus status;
  final TaskPriority priority;
  final DateTime? dueAt;
  final DuePrecision duePrecision;
  final List<String> tags;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;
  final DateTime? deletedAt;

  /// Заметки из чата, старые первыми (ADR-033). В файлах до этой версии
  /// поля нет — пустой список.
  final List<TaskNote> notes;

  /// Пункты чек-листа (ADR-033).
  final List<TaskItem> items;

  /// Проект задачи — первая метка; пусто, если проекта нет.
  String? get project => tags.isEmpty ? null : tags.first;

  bool get isActive =>
      deletedAt == null &&
      status != TaskStatus.done &&
      status != TaskStatus.cancelled;

  Task copyWith({
    String? title,
    String? description,
    TaskStatus? status,
    TaskPriority? priority,
    DateTime? dueAt,
    DuePrecision? duePrecision,
    DateTime? updatedAt,
    DateTime? completedAt,
    DateTime? deletedAt,
    List<String>? tags,
    List<TaskNote>? notes,
    List<TaskItem>? items,
    bool clearCompletedAt = false,
  }) {
    return Task(
      id: id,
      title: title ?? this.title,
      description: description ?? this.description,
      status: status ?? this.status,
      priority: priority ?? this.priority,
      dueAt: dueAt ?? this.dueAt,
      duePrecision: duePrecision ?? this.duePrecision,
      tags: tags ?? this.tags,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      completedAt: clearCompletedAt ? null : completedAt ?? this.completedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      notes: notes ?? this.notes,
      items: items ?? this.items,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'description': description,
        'status': status.name,
        'priority': priority.name,
        'due_at': dueAt?.toIso8601String(),
        'due_precision': duePrecision.name,
        'tags': tags,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        'completed_at': completedAt?.toIso8601String(),
        'deleted_at': deletedAt?.toIso8601String(),
        if (notes.isNotEmpty)
          'notes': <Map<String, dynamic>>[
            for (final note in notes) note.toJson(),
          ],
        if (items.isNotEmpty)
          'items': <Map<String, dynamic>>[
            for (final item in items) item.toJson(),
          ],
      };

  factory Task.fromJson(Map<String, dynamic> json) {
    return Task(
      id: json['id'] as String,
      title: json['title'] as String,
      description: json['description'] as String? ?? '',
      status: TaskStatus.values.byName(json['status'] as String),
      priority: TaskPriority.values.byName(json['priority'] as String),
      dueAt: json['due_at'] == null
          ? null
          : DateTime.parse(json['due_at'] as String),
      duePrecision: _precisionFromJson(json['due_precision']),
      tags: (json['tags'] as List<dynamic>? ?? const <dynamic>[])
          .map((dynamic e) => e.toString())
          .toList(),
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      completedAt: json['completed_at'] == null
          ? null
          : DateTime.parse(json['completed_at'] as String),
      deletedAt: json['deleted_at'] == null
          ? null
          : DateTime.parse(json['deleted_at'] as String),
      notes: <TaskNote>[
        for (final row in json['notes'] as List<dynamic>? ?? const <dynamic>[])
          if (TaskNote.fromJson(row) case final TaskNote note) note,
      ],
      items: <TaskItem>[
        for (final row in json['items'] as List<dynamic>? ?? const <dynamic>[])
          if (TaskItem.fromJson(row) case final TaskItem item) item,
      ],
    );
  }

  /// Старые файлы без поля — `dateTime`; незнакомое значение (файл из
  /// более новой версии) тоже читается как `dateTime`, а не роняет загрузку.
  static DuePrecision _precisionFromJson(Object? value) {
    for (final precision in DuePrecision.values) {
      if (precision.name == value) return precision;
    }
    return DuePrecision.dateTime;
  }
}
