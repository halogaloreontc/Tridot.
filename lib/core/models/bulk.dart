import '../formatting/due_format.dart';
import '../replies/reply_template.dart';
import 'task.dart';

/// Что делает массовая команда с отмеченными задачами.
enum BulkAction {
  /// «Перенеси всё на выходные», «сдвинь всё на час позже».
  reschedule,

  /// «Закрой все просроченные», «отметь всё на сегодня выполненным».
  complete,
}

/// По какому признаку массовая команда выбирает задачи (кроме меток).
enum BulkScopeKind {
  /// Все активные задачи: «перенеси всё на завтра».
  all,

  /// Просроченные: «закрой все просроченные».
  overdue,

  /// Задачи без срока: «перенеси все задачи без срока на пятницу».
  noDue,

  /// Задачи на один день: «сегодняшние», «все задачи на пятницу»,
  /// «с пятницы на понедельник».
  day,
}

/// Какие задачи выбирает массовая команда: признак [kind] и метки
/// [tags] («всё с #работа»). Метки сужают любой признак.
final class BulkSelection {
  const BulkSelection({
    this.kind = BulkScopeKind.all,
    this.day,
    this.tags = const <String>[],
  }) : assert(
          (kind == BulkScopeKind.day) == (day != null),
          'День нужен ровно у BulkScopeKind.day',
        );

  final BulkScopeKind kind;

  /// День задач для [BulkScopeKind.day] (полночь); иначе `null`.
  final DateTime? day;

  /// Метки без «#» в нижнем регистре; задача должна нести каждую.
  final List<String> tags;

  /// Подходит ли активная задача [task] в момент [now].
  bool matches(Task task, DateTime now) {
    if (!task.isActive) return false;
    for (final tag in tags) {
      if (!task.tags.contains(tag)) return false;
    }
    final due = task.dueAt;
    return switch (kind) {
      BulkScopeKind.all => true,
      BulkScopeKind.overdue => isOverdue(task, now),
      BulkScopeKind.noDue => due == null,
      BulkScopeKind.day => due != null &&
          due.year == day!.year &&
          due.month == day!.month &&
          due.day == day!.day,
    };
  }

  /// Запись в корпусе (docs/CORPUS.md, поле `scope`): `all`, `overdue`,
  /// `noDue` или `date:ГГГГ-ММ-ДД`, затем метки через пробел: `overdue
  /// #работа`.
  String get label {
    final base = switch (kind) {
      BulkScopeKind.all => 'all',
      BulkScopeKind.overdue => 'overdue',
      BulkScopeKind.noDue => 'noDue',
      BulkScopeKind.day => 'date:${_isoDate(day!)}',
    };
    return <String>[base, for (final tag in tags) '#$tag'].join(' ');
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind.name,
        if (day != null) 'day': _isoDate(day!),
        'tags': tags,
      };

  /// Незнакомые значения (файл из новой версии) читаются как «все».
  static BulkSelection fromJson(Object? json) {
    if (json is! Map) return const BulkSelection();
    final kind = BulkScopeKind.values
            .where((BulkScopeKind k) => k.name == json['kind'])
            .firstOrNull ??
        BulkScopeKind.all;
    final day = DateTime.tryParse('${json['day']}');
    final tags = <String>[
      for (final tag in json['tags'] as List<Object?>? ?? const <Object?>[])
        if (tag is String) tag,
    ];
    if (kind == BulkScopeKind.day && day == null) {
      return BulkSelection(tags: tags);
    }
    return BulkSelection(
      kind: kind,
      day: kind == BulkScopeKind.day ? day : null,
      tags: tags,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BulkSelection && other.label == label;

  @override
  int get hashCode => label.hashCode;

  @override
  String toString() => label;
}

/// Единица сдвига срока «на N … позже».
enum ShiftUnit {
  minutes('m', 'минуту', 'минуты', 'минут'),
  hours('h', 'час', 'часа', 'часов'),
  days('d', 'день', 'дня', 'дней');

  const ShiftUnit(this.code, this.one, this.few, this.many);

  /// Буква в корпусе: `+1h`, `-2d`, `+30m`.
  final String code;
  final String one;
  final String few;
  final String many;
}

/// Сдвиг срока каждой задачи на одну и ту же величину: «сдвинь всё на час
/// позже» — +1 час, «на 2 дня раньше» — −2 дня. Недели считаются днями.
final class DueShift {
  const DueShift(this.amount, this.unit) : assert(amount != 0);

  /// Сколько единиц: больше нуля — позже, меньше — раньше.
  final int amount;
  final ShiftUnit unit;

  /// Сдвигает срок [due]. Дни прибавляются по календарю, без влияния
  /// перехода на летнее время.
  DateTime apply(DateTime due) => switch (unit) {
        ShiftUnit.minutes => due.add(Duration(minutes: amount)),
        ShiftUnit.hours => due.add(Duration(hours: amount)),
        ShiftUnit.days => DateTime(
            due.year,
            due.month,
            due.day + amount,
            due.hour,
            due.minute,
          ),
      };

  /// Сдвигается ли так задача с точностью [precision]: минуты и часы —
  /// только у задач с точным временем, дни — у любых со сроком.
  bool fits(DuePrecision precision) =>
      unit == ShiftUnit.days || precision == DuePrecision.dateTime;

  /// «на 1 час позже», «на 2 дня раньше».
  String describe() {
    final n = amount.abs();
    final word = switch (ReplyTemplate.pluralIndex(n)) {
      0 => unit.one,
      1 => unit.few,
      _ => unit.many,
    };
    return 'на $n $word ${amount > 0 ? 'позже' : 'раньше'}';
  }

  /// Запись в корпусе (поле `shift`): `+1h`, `-2d`, `+30m`.
  String get label => '${amount > 0 ? '+' : '-'}${amount.abs()}${unit.code}';

  static DueShift? parse(Object? label) {
    if (label is! String) return null;
    final match = RegExp(r'^([+-])(\d{1,4})([mhd])$').firstMatch(label);
    if (match == null) return null;
    final amount = int.parse(match.group(2)!);
    if (amount == 0) return null;
    final unit = ShiftUnit.values.firstWhere(
      (ShiftUnit u) => u.code == match.group(3),
    );
    return DueShift(match.group(1) == '-' ? -amount : amount, unit);
  }

  @override
  bool operator ==(Object other) => other is DueShift && other.label == label;

  @override
  int get hashCode => label.hashCode;

  @override
  String toString() => label;
}

/// Строка списка массовой команды: задача и отметка «применить к ней».
final class BulkItem {
  BulkItem({
    required this.taskId,
    required this.title,
    this.dueLabel,
    this.checked = true,
  });

  final String taskId;
  final String title;

  /// Срок задачи на момент вопроса словами («завтра в 10:00») или `null`.
  final String? dueLabel;

  /// Отмечена ли задача. Меняется галочкой в карточке и ответами «кроме…»,
  /// «только…» — пока вопрос ждёт ответа.
  bool checked;

  Map<String, Object?> toJson() => <String, Object?>{
        'task_id': taskId,
        'title': title,
        if (dueLabel != null) 'due': dueLabel,
        'checked': checked,
      };

  static BulkItem? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['task_id'];
    final title = json['title'];
    if (id is! String || title is! String) return null;
    final due = json['due'];
    return BulkItem(
      taskId: id,
      title: title,
      dueLabel: due is String ? due : null,
      checked: json['checked'] != false,
    );
  }
}

/// Чем закончился вопрос массовой команды.
enum BulkChecklistState {
  /// Ждёт «да», «нет», «кроме …» или нажатия кнопки в карточке.
  pending,

  /// Применено: [BulkChecklist.applied] из [BulkChecklist.checkedCount].
  applied,

  /// Применённое изменение отменено («Отменить», «отмени»).
  undone,

  /// Пользователь отказался («нет», «Отмена»).
  cancelled,

  /// Вопрос снят без ответа: другое сообщение или перезапуск приложения.
  expired,
}

/// Вопрос массовой команды вместе со списком задач: «Перенести эти 5 задач
/// на 7 ноября?» и галочка у каждой задачи.
///
/// Один объект на вопрос: его держит ожидание подтверждения
/// (`PendingConfirmation.payload`) и карточка в чате, поэтому галочка в
/// карточке сразу видна ответу «да». Отметки меняются только пока вопрос
/// ждёт ответа ([isPending]); дальше карточка только показывает итог.
/// В историю чата карточка пишется [toJson] как данные, а не текст.
final class BulkChecklist {
  BulkChecklist({
    required this.id,
    required this.action,
    required this.selection,
    required this.items,
    this.targetDue,
    this.targetPrecision,
    this.shift,
    this.targetLabel,
    this.state = BulkChecklistState.pending,
    this.applied = 0,
    this.canUndo = false,
  });

  /// Сколько задач список показывает целиком; больше — тоже показывает,
  /// с прокруткой, а вопрос называет число.
  static const int longList = 30;

  final String id;
  final BulkAction action;
  final BulkSelection selection;
  final List<BulkItem> items;

  /// Новый срок переноса; `null` у завершения и сдвига.
  final DateTime? targetDue;
  final DuePrecision? targetPrecision;

  /// Сдвиг вместо нового срока: «на час позже».
  final DueShift? shift;

  /// Цель для карточки: «сб, 7 ноября», «на 1 час позже»; `null` у
  /// завершения.
  final String? targetLabel;

  BulkChecklistState state;

  /// Сколько задач изменено после ответа «да».
  int applied;

  /// Можно ли ещё вернуть всё как было: только у последнего применённого
  /// массового изменения в открытом чате.
  bool canUndo;

  bool get isPending => state == BulkChecklistState.pending;

  int get checkedCount => items.where((BulkItem i) => i.checked).length;

  List<String> get checkedIds => <String>[
        for (final item in items)
          if (item.checked) item.taskId,
      ];

  /// Ставит или снимает отметку; вне ожидания ответа ничего не меняет.
  bool setChecked(String taskId, bool checked) {
    if (!isPending) return false;
    var changed = false;
    for (final item in items) {
      if (item.taskId == taskId && item.checked != checked) {
        item.checked = checked;
        changed = true;
      }
    }
    return changed;
  }

  /// «Выбрать все» / «Снять все».
  bool setAll(bool checked) {
    if (!isPending) return false;
    var changed = false;
    for (final item in items) {
      if (item.checked != checked) {
        item.checked = checked;
        changed = true;
      }
    }
    return changed;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'action': action.name,
        'selection': selection.toJson(),
        'items': <Map<String, Object?>>[
          for (final item in items) item.toJson(),
        ],
        if (targetDue != null) 'target_due': targetDue!.toIso8601String(),
        if (targetPrecision != null) 'target_precision': targetPrecision!.name,
        if (shift != null) 'shift': shift!.label,
        if (targetLabel != null) 'target_label': targetLabel,
        'state': state.name,
        'applied': applied,
      };

  /// Карточка из истории чата после перезапуска. Неотвеченный вопрос
  /// становится устаревшим ([BulkChecklistState.expired]): ожидание
  /// подтверждения живёт только в памяти, и «да» после перезапуска ничего
  /// не применит. Отменить применённое после перезапуска тоже нельзя.
  /// Повреждённая запись — `null`: история читается и без карточки.
  static BulkChecklist? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final action = BulkAction.values
        .where((BulkAction a) => a.name == json['action'])
        .firstOrNull;
    final rawItems = json['items'];
    if (id is! String || action == null || rawItems is! List) return null;
    final items = <BulkItem>[
      for (final raw in rawItems)
        if (BulkItem.fromJson(raw) case final BulkItem item) item,
    ];
    final state = BulkChecklistState.values
            .where((BulkChecklistState s) => s.name == json['state'])
            .firstOrNull ??
        BulkChecklistState.expired;
    final targetDue = DateTime.tryParse('${json['target_due']}');
    final precision = DuePrecision.values
        .where((DuePrecision p) => p.name == json['target_precision'])
        .firstOrNull;
    final applied = json['applied'];
    final label = json['target_label'];
    return BulkChecklist(
      id: id,
      action: action,
      selection: BulkSelection.fromJson(json['selection']),
      items: items,
      targetDue: targetDue,
      targetPrecision: targetDue == null ? null : precision,
      shift: DueShift.parse(json['shift']),
      targetLabel: label is String ? label : null,
      state: state == BulkChecklistState.pending
          ? BulkChecklistState.expired
          : state,
      applied: applied is int ? applied : 0,
    );
  }
}

String _isoDate(DateTime day) => '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';
