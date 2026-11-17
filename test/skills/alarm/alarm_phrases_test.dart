import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/utterance.dart';
import 'package:local_assistant/core/skills/alarm/alarm_phrases.dart';

/// Понедельник, 16:30.
final DateTime _now = DateTime(2026, 11, 2, 16, 30);

AlarmRequest? _parse(String text, {DateTime? now}) => AlarmPhrases.parse(
      Utterance.analyze(text, now: now ?? _now),
      now ?? _now,
    );

void main() {
  test('«на 7» — ближайшие 7:00 в пределах суток', () {
    final morning = _parse('поставь будильник на 7')!;
    expect((morning.hour, morning.minute), (7, 0));
    expect(morning.at, DateTime(2026, 11, 3, 7));
    expect(morning.issue, AlarmIssue.none);
    final evening = _parse('поставь будильник на 19:00')!;
    expect(evening.at, DateTime(2026, 11, 2, 19));
    final early = _parse('будильник на 7', now: DateTime(2026, 11, 2, 5))!;
    expect(early.at, DateTime(2026, 11, 2, 7));
  });

  test('полседьмого, половина, вечер, ночь, день, словами', () {
    String time(String text) => _parse(text)!.timeText;
    expect(time('будильник на полседьмого'), '6:30');
    expect(time('поставь будильник в половине седьмого'), '6:30');
    expect(time('будильник на пол восьмого'), '7:30');
    expect(time('поставь будильник на 7 вечера'), '19:00');
    expect(time('поставь будильник на 2 ночи'), '2:00');
    expect(time('поставь будильник на 10 вечера'), '22:00');
    expect(time('поставь будильник на 3 дня'), '15:00');
    expect(time('поставь будильник на семь'), '7:00');
    expect(time('поставь будильник на 7 30'), '7:30');
    expect(time('разбуди меня в 6 утра'), '6:00');
  });

  test('через, дни, подпись', () {
    final relative = _parse('будильник через 20 минут')!;
    expect(relative.timeText, '16:50');
    final weekdays = _parse('будильник по будням на 7')!;
    expect(weekdays.days, <int>[1, 2, 3, 4, 5]);
    expect(weekdays.daysText, 'по будням');
    expect(_parse('будильник по выходным на 9')!.daysText, 'по выходным');
    expect(
      _parse('будильник на 7 по понедельникам и средам')!.daysText,
      'по понедельникам и средам',
    );
    expect(_parse('будильник каждый день на 8')!.daysText, 'каждый день');
    expect(
      _parse('поставь будильник на 7 с подписью «спортзал»')!.label,
      'спортзал',
    );
  });

  test('больше суток — напоминание; сегодня, но прошло — уточнение', () {
    final friday = _parse('поставь будильник в пятницу в 7')!;
    expect(friday.issue, AlarmIssue.date);
    expect(friday.at, DateTime(2026, 11, 6, 7));
    expect(friday.commandId, AlarmPhrases.dateCommand);
    final tomorrowEarly =
        _parse('разбуди меня завтра в 6:30', now: DateTime(2026, 11, 2, 5))!;
    expect(tomorrowEarly.issue, AlarmIssue.date);
    expect(_parse('разбуди меня завтра в 6:30')!.issue, AlarmIssue.none);
    expect(_parse('поставь будильник на сегодня в 7')!.issue, AlarmIssue.past);
    expect(_parse('разбуди меня через 30 часов')!.issue, AlarmIssue.date);
  });

  test('таймеры', () {
    int? seconds(String text) => _parse(text)!.seconds;
    expect(seconds('поставь таймер на 5 минут'), 300);
    expect(seconds('таймер на полчаса'), 1800);
    expect(seconds('таймер на 1:30'), 5400);
    expect(seconds('засеки 10 минут'), 600);
    expect(seconds('таймер 3 минуты'), 180);
    expect(seconds('таймер на полтора часа'), 5400);
    expect(seconds('таймер на 2 часа 15 минут'), 8100);
    expect(seconds('таймер на минуту'), 60);
    expect(seconds('таймер на двадцать пять минут'), 1500);
    expect(
      _parse('таймер на 2 часа 15 минут')!.durationText,
      '2 часа 15 минут',
    );
    expect(_parse('таймер на 1 минуту')!.durationText, '1 минуту');
    expect(_parse('поставь таймер')!.issue, AlarmIssue.noDuration);
    expect(_parse('таймер на 30 часов')!.issue, AlarmIssue.noDuration);
  });

  test('без времени — уточнение', () {
    expect(_parse('поставь будильник')!.issue, AlarmIssue.noTime);
    expect(_parse('разбуди меня')!.issue, AlarmIssue.noTime);
    expect(_parse('поставь будильник на 25:00')!.issue, AlarmIssue.noTime);
  });

  test('не будильник', () {
    for (final text in <String>[
      'купить будильник',
      'починить будильник',
      'напомни поставить будильник',
      'надо завести будильник на 7',
      'будильник не прозвенел',
      'не ставь будильник',
      'поставь будильник на полку',
      'где мой будильник?',
      'напомни завтра в 7 позвонить маме',
      'купить таймер для духовки',
    ]) {
      expect(_parse(text), isNull, reason: text);
    }
  });
}
