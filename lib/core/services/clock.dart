abstract interface class Clock {
  DateTime now();
}

final class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();
}

final class FixedClock implements Clock {
  const FixedClock(this.value);

  final DateTime value;

  @override
  DateTime now() => value;
}

/// Монотонное время: только растёт и не зависит от перевода системных
/// часов. Сроки, которые нельзя ни продлить, ни сбросить переводом часов
/// (окно подтверждения, предел догадок, автозапирание), меряются им.
abstract interface class MonotonicClock {
  /// Сколько прошло с произвольной, но постоянной точки отсчёта.
  Duration get elapsed;
}

/// [MonotonicClock] на [Stopwatch], запущенном при создании.
final class StopwatchClock implements MonotonicClock {
  StopwatchClock() : _watch = Stopwatch()..start();

  final Stopwatch _watch;

  @override
  Duration get elapsed => _watch.elapsed;
}
