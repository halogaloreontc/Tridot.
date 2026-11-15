import '../models/task.dart';

/// Одно системное напоминание о задаче (ADR-029): когда и что показать.
///
/// Только то, что увидит человек в уведомлении: название задачи и имя
/// помощника. Ни описания, ни меток, ни проекта: расписание лежит у
/// системы (Android — SharedPreferences `tridot_reminders`, исключены из
/// резервной копии; macOS — UNUserNotificationCenter) и никуда не
/// отправляется.
final class Reminder {
  const Reminder({
    required this.id,
    required this.taskId,
    required this.at,
    required this.title,
    required this.persona,
  });

  /// Постоянный ключ напоминания: id задачи и минута срока. Срок
  /// перенесли — ключ новый, старое напоминание снимается.
  final String id;

  final String taskId;

  /// Когда показать (местное время устройства).
  final DateTime at;

  /// Название задачи — текст уведомления.
  final String title;

  /// Имя помощника для заголовка: «Нода · напоминание».
  final String persona;

  /// Для канала платформы: время — миллисекунды эпохи.
  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'taskId': taskId,
        'at': at.millisecondsSinceEpoch,
        'title': title,
        'persona': persona,
      };

  @override
  bool operator ==(Object other) =>
      other is Reminder &&
      other.id == id &&
      other.taskId == taskId &&
      other.at == at &&
      other.title == title &&
      other.persona == persona;

  @override
  int get hashCode => Object.hash(id, taskId, at, title, persona);

  @override
  String toString() => 'Reminder($id, $at, $title)';
}

/// Какие напоминания поставить системе: план строится заново после каждого
/// изменения задач и целиком заменяет прежний (ADR-029).
abstract final class ReminderPlan {
  /// Дальше этого срока напоминания не ставятся: план и так обновится,
  /// когда приложение откроют.
  static const Duration horizon = Duration(days: 30);

  /// Не больше стольких напоминаний сразу: у macOS предел — 64 ждущих
  /// уведомления на приложение.
  static const int maxItems = 50;

  /// Длиннее этого название в уведомлении обрезается.
  static const int maxTitle = 120;

  /// План для [tasks] на момент [now].
  ///
  /// - Только активные задачи со сроком в будущем, не дальше [horizon].
  /// - Срок со временем — в это время; часть суток («вечером») — в её
  ///   условный час ([PartOfDay.hour], он уже в `dueAt`).
  /// - Срок без времени — в этот день в [dateOnlyHour]; `null` — о таких
  ///   задачах не напоминать. Час уже прошёл — сегодня не напоминать.
  /// - Ближайшие первыми, не больше [maxItems].
  static List<Reminder> from(
    Iterable<Task> tasks, {
    required DateTime now,
    required String persona,
    int? dateOnlyHour = 9,
  }) {
    final limit = now.add(horizon);
    final out = <Reminder>[];
    for (final task in tasks) {
      if (!task.isActive) continue;
      final due = task.dueAt;
      if (due == null) continue;
      final DateTime at;
      switch (task.duePrecision) {
        case DuePrecision.date:
          if (dateOnlyHour == null) continue;
          at = DateTime(due.year, due.month, due.day, dateOnlyHour);
        case DuePrecision.dateTime:
        case DuePrecision.partOfDay:
          at = DateTime(due.year, due.month, due.day, due.hour, due.minute);
      }
      if (!at.isAfter(now) || at.isAfter(limit)) continue;
      out.add(
        Reminder(
          id: '${task.id}@${at.millisecondsSinceEpoch ~/ 60000}',
          taskId: task.id,
          at: at,
          title: _title(task.title),
          persona: persona,
        ),
      );
    }
    out.sort((Reminder a, Reminder b) {
      final byTime = a.at.compareTo(b.at);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    return out.length <= maxItems ? out : List<Reminder>.of(out.take(maxItems));
  }

  /// Задачи, у которых срок уже наступил (сегодня или раньше), но они ещё
  /// не выполнены: их «Через 10 минут» система сохраняет при следующей
  /// замене плана. Выполнили или удалили задачу — отложенное снимается.
  static Set<String> snoozable(Iterable<Task> tasks, {required DateTime now}) {
    final today = DateTime(now.year, now.month, now.day);
    return <String>{
      for (final task in tasks)
        if (task.isActive &&
            task.dueAt != null &&
            !DateTime(task.dueAt!.year, task.dueAt!.month, task.dueAt!.day)
                .isAfter(today))
          task.id,
    };
  }

  /// Название в одну строку, без управляющих знаков, не длиннее
  /// [maxTitle].
  static String _title(String title) {
    final text = title
        .replaceAll(RegExp(r'[\u0000-\u001f\u007f-\u009f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.runes.length <= maxTitle) return text;
    return '${String.fromCharCodes(text.runes.take(maxTitle - 1))}…';
  }
}
