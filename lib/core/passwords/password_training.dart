/// Ответ «Проверить себя» и тренировки (5.2, 5.8). Только эти пять
/// ответов: ни длины, ни расстояния, ни совпавших символов — это не
/// оракул «насколько близко».
enum RecallVerdict {
  /// Верно.
  correct,

  /// Почти: набрано в другой раскладке (ЙЦУКЕН↔QWERTY).
  almostLayout,

  /// Почти: регистр (Caps Lock, первая буква).
  almostCase,

  /// Это прежний пароль записи (`fp_old`).
  oldOne,

  /// Не совпадает.
  wrong,

  /// Слишком много попыток подряд — пауза ([RecallLimiter]).
  limited,
}

/// Итог тренировки для расписания (5.8).
enum TrainingOutcome {
  /// Вспомнили сами (своя подсказка не мешает).
  correct,

  /// Вспомнили с помощью: ступень лестницы ≥ 2 (D27) — интервал не
  /// растёт, но и не сбрасывается.
  helped,

  /// Не вспомнили или сдались — завтра снова.
  wrong,

  /// «Не сейчас» — завтра.
  skipped,

  /// «Больше не спрашивать» — запись выходит из тренировки.
  stopped,
}

/// Интервальное повторение: 1 → 3 → 7 → 14 → 30 → 60 → 120 дней (5.8).
/// Состояние — в `train` записи (внутри зашифрованного индекса):
/// `step`, `streak`, `next`, `last`, `off`. В `settings.json` — только
/// дата ближайшей тренировки.
abstract final class TrainingSchedule {
  static const List<int> intervals = <int>[1, 3, 7, 14, 30, 60, 120];

  /// Новая важная запись: первый вопрос — завтра.
  static Map<String, Object?> start(DateTime now) => <String, Object?>{
        'step': 0,
        'streak': 0,
        'next': _iso(now.add(const Duration(days: 1))),
      };

  /// Следующее состояние после [outcome].
  static Map<String, Object?> next(
    Map<String, Object?> train,
    TrainingOutcome outcome,
    DateTime now,
  ) {
    final step = stepOf(train);
    final streak = streakOf(train);
    final last = _iso(now);
    switch (outcome) {
      case TrainingOutcome.correct:
        final nextStep =
            step + 1 < intervals.length ? step + 1 : intervals.length - 1;
        return <String, Object?>{
          'step': nextStep,
          'streak': streak + 1,
          'next': _iso(now.add(Duration(days: intervals[nextStep]))),
          'last': last,
        };
      case TrainingOutcome.helped:
        return <String, Object?>{
          'step': step,
          'streak': streak,
          'next': _iso(now.add(Duration(days: intervals[step]))),
          'last': last,
        };
      case TrainingOutcome.wrong:
        return <String, Object?>{
          'step': 0,
          'streak': 0,
          'next': _iso(now.add(Duration(days: intervals.first))),
          'last': last,
        };
      case TrainingOutcome.skipped:
        return <String, Object?>{
          ...train,
          'next': _iso(now.add(const Duration(days: 1))),
        };
      case TrainingOutcome.stopped:
        return <String, Object?>{...train, 'off': true};
    }
  }

  static int stepOf(Map<String, Object?> train) {
    final step = train['step'];
    return step is int && step >= 0 && step < intervals.length ? step : 0;
  }

  static int streakOf(Map<String, Object?> train) {
    final streak = train['streak'];
    return streak is int && streak >= 0 ? streak : 0;
  }

  static DateTime? nextOf(Map<String, Object?> train) {
    final next = train['next'];
    return next is String ? DateTime.tryParse(next) : null;
  }

  /// Выведена ли из тренировки («Больше не спрашивать»).
  static bool isOff(Map<String, Object?> train) => train['off'] == true;

  /// Пора спросить.
  static bool isDue(Map<String, Object?> train, DateTime now) {
    if (isOff(train)) return false;
    final next = nextOf(train);
    return next != null && !now.isBefore(next);
  }

  /// Через сколько дней следующий раз (не меньше 1).
  static int daysUntil(Map<String, Object?> train, DateTime now) {
    final next = nextOf(train);
    if (next == null) return 1;
    final hours = next.difference(now).inHours;
    final days = (hours + 23) ~/ 24;
    return days < 1 ? 1 : days;
  }

  static String _iso(DateTime time) => time.toUtc().toIso8601String();
}

/// Ограничение «Проверить себя» и тренировки: не больше [limit] попыток
/// на запись за [window]. Дальше — пауза: открывший хранилище может
/// нажать «Показать», а перебирать «верно / не совпадает» незачем.
/// Состояние живёт в памяти открытого хранилища и сбрасывается при
/// запирании (открыть снова можно только мастер-паролем).
final class RecallLimiter {
  RecallLimiter({this.limit = 5, this.window = const Duration(minutes: 10)});

  final int limit;
  final Duration window;
  final Map<String, List<Duration>> _attempts = <String, List<Duration>>{};

  /// Можно ли ещё одну попытку для [id] (и учесть её). [now] —
  /// монотонное время (`MonotonicClock`): перевод часов вперёд попытки
  /// не возвращает.
  bool take(String id, Duration now) {
    final list = _attempts[id] ??= <Duration>[];
    list.removeWhere((Duration t) => now - t >= window);
    if (list.length >= limit) return false;
    list.add(now);
    return true;
  }

  /// Сколько попыток осталось для [id].
  int left(String id, Duration now) {
    final list = _attempts[id] ?? const <Duration>[];
    final recent = list.where((Duration t) => now - t < window);
    final rest = limit - recent.length;
    return rest < 0 ? 0 : rest;
  }

  void clear() => _attempts.clear();

  @override
  String toString() => 'RecallLimiter';
}
