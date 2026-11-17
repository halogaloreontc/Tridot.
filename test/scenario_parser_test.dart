import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/due_parser.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';

void main() {
  final clock = FixedClock(DateTime(2026, 11, 2, 16, 30));
  final parser = ScenarioParser(clock: clock);

  test('разбирает создание задачи с названием, датой и временем', () {
    final command =
        parser.parse('Добавь задачу «Позвонить клиенту» на завтра в 11:00');

    expect(command.intent, CommandIntent.createTask);
    expect(command.title, 'Позвонить клиенту');
    expect(command.dueAt, DateTime(2026, 11, 3, 11));
    expect(command.duePrecision, DuePrecision.dateTime);
  });

  test('различает задачу на день без точного времени', () {
    final command = parser.parse('Создай задачу «Отчёт» на сегодня');

    expect(command.dueAt, DateTime(2026, 11, 2));
    expect(command.duePrecision, DuePrecision.date);
  });

  test('берёт название без кавычек из остатка фразы', () {
    final command = parser.parse('Добавь задачу позвонить клиенту завтра');

    expect(command.intent, CommandIntent.createTask);
    expect(command.title, 'Позвонить клиенту');
    expect(command.dueAt, DateTime(2026, 11, 3));
  });

  test('сообщает фрагменты срока со смещениями в исходном тексте', () {
    const text = 'Добавь  ЗАДАЧУ купить ёлку НА ЗАВТРА в 10:00';
    final due = parser.parseDueDetailed(text);

    expect(due.dueAt, DateTime(2026, 11, 3, 10));
    expect(
      due.spans.map((CharSpan s) => text.substring(s.start, s.end)),
      <String>['НА ЗАВТРА', 'в 10:00'],
    );
  });

  test('выбирает следующий день для уже прошедшего времени', () {
    final due = parser.parseDue('перенеси её на 15:00');

    expect(due?.$1, DateTime(2026, 11, 3, 15));
    expect(due?.$2, DuePrecision.dateTime);
  });

  test('без срока точность не указана', () {
    final command = parser.parse('Добавь задачу «Купить хлеб»');

    expect(command.dueAt, isNull);
    expect(command.duePrecision, isNull);
    expect(parser.parseDueDetailed('купить хлеб').precision, isNull);
    // Ошибка в сроке — тоже без точности.
    final failed = parser.parse('Добавь задачу «Отчёт» на 31.02');
    expect(failed.dueIssue, DueIssue.invalidDate);
    expect(failed.duePrecision, isNull);
  });

  test('день недели и «через» занимают фрагменты вместе с предлогами', () {
    const text = 'напомни В ПЯТНИЦУ в 10 или через 2 дня';
    final due = parser.parseDueDetailed(text);

    expect(
      due.spans.map((CharSpan s) => text.substring(s.start, s.end)),
      <String>['В ПЯТНИЦУ', 'в 10 или через 2 дня'],
    );
    expect(due.issue, DueIssue.conflictingDays);
  });

  test('сегодняшний день недели: время впереди — сегодня, иначе через неделю',
      () {
    final friday = ScenarioParser(
      clock: FixedClock(DateTime(2026, 11, 6, 12)),
    );

    expect(
      friday.parse('добавь отчёт в пятницу в 15:00').dueAt,
      DateTime(2026, 11, 6, 15),
    );
    expect(
      friday.parse('добавь отчёт в пятницу в 11:00').dueAt,
      DateTime(2026, 11, 13, 11),
    );
    expect(
      friday.parse('добавь отчёт в пятницу').dueAt,
      DateTime(2026, 11, 13),
    );
  });

  test('«через N месяцев» не выходит за конец месяца', () {
    final january = ScenarioParser(
      clock: FixedClock(DateTime(2027, 1, 31, 9)),
    );
    final command = january.parse('добавь продлить полис через месяц');

    expect(command.dueAt, DateTime(2027, 2, 28));
    expect(command.duePrecision, DuePrecision.date);
    expect(command.title, 'Продлить полис');
  });

  test('«через N часов» — прошедшее время, а не настенные часы', () {
    // В поясе с переходом на зимнее время (TZ=Europe/Berlin) ночь на
    // 25.10.2026 длиннее на час: 01:30 + 2 часа = 02:30 по зимнему времени.
    final now = DateTime(2026, 10, 25, 1, 30);
    final due = const DueParser().parse('через 2 часа', now);

    expect(due.dueAt, now.add(const Duration(hours: 2)));
    expect(due.dueAt!.difference(now), const Duration(hours: 2));
    expect(due.precision, DuePrecision.dateTime);

    final noon = DateTime(2026, 10, 24, 12);
    expect(
      const DueParser().parse('через 24 часа', noon).dueAt!.difference(noon),
      const Duration(hours: 24),
    );
  });

  group('даты словами', () {
    const due = DueParser();
    final now = DateTime(2026, 11, 2, 16, 30);

    test('фрагмент даты занимает число, месяц, год и предлог', () {
      const text = 'сдать отчёт до 16 апреля 2027 года';
      final result = due.parse(text, now);

      expect(result.dueAt, DateTime(2027, 4, 16));
      expect(result.precision, DuePrecision.date);
      expect(result.spans, hasLength(1));
      expect(
        text.substring(result.spans.single.start, result.spans.single.end),
        'до 16 апреля 2027 года',
      );
    });

    test('несуществующая дата — invalidDate, и важнее неверного времени', () {
      for (final text in <String>[
        '31 февраля',
        '30 февраля в 10',
        '31 февраля в 25:00',
        '31.04 в 25:30',
        '30.02 в 25 часов',
      ]) {
        final result = due.parse(text, now);
        expect(result.issue, DueIssue.invalidDate, reason: text);
        expect(result.dueAt, isNull, reason: text);
      }
    });

    test('час больше 23 с «часов» — invalidTime, без уточнения — не время', () {
      final hours = due.parse('в 25 часов', now);
      expect(hours.issue, DueIssue.invalidTime);
      expect(hours.spans, isNotEmpty);

      final bare = due.parse('встреча в 25', now);
      expect(bare.issue, DueIssue.none);
      expect(bare.spans, isEmpty);
    });

    test('число вплотную к двоеточию — не день', () {
      // «15» — минуты времени 10:15, а не 15 ноября.
      final result = due.parse('в 10:15 ноября', now);
      expect(result.dueAt, DateTime(2026, 11, 3, 10, 15));
      expect(result.precision, DuePrecision.dateTime);
    });
  });

  group('части месяца', () {
    const due = DueParser();
    DateTime? at(String text, DateTime now) => due.parse(text, now).dueAt;

    test('начало — 1-е число ещё не начавшегося месяца', () {
      expect(at('в начале месяца', DateTime(2026, 11, 2)), DateTime(2026, 12));
      expect(at('в начале месяца', DateTime(2026, 11, 1)), DateTime(2026, 12));
      expect(
        at('в начале месяца', DateTime(2026, 12, 20)),
        DateTime(2027),
      );
      expect(
        due.parse('в начале этого месяца', DateTime(2026, 11, 2)).issue,
        DueIssue.inPast,
      );
    });

    test('середина — 15-е этого месяца, если оно не прошло', () {
      expect(
        at('в середине месяца', DateTime(2026, 11, 15)),
        DateTime(2026, 11, 15),
      );
      expect(
        at('к середине месяца', DateTime(2026, 11, 16)),
        DateTime(2026, 12, 15),
      );
    });

    test('конец — последний день этого или следующего месяца', () {
      expect(
        at('в конце месяца', DateTime(2026, 2, 3)),
        DateTime(2026, 2, 28),
      );
      expect(
        at('до конца месяца', DateTime(2026, 11, 30, 20)),
        DateTime(2026, 11, 30),
      );
      expect(
        at('к концу следующего месяца', DateTime(2026, 12, 2)),
        DateTime(2027, 1, 31),
      );
      expect(at('конец месяца', DateTime(2026, 11, 2)), isNull);
    });
  });

  group('вопрос о списке задач', () {
    test('вопрос о своих планах целиком — список', () {
      for (final text in <String>[
        'что у меня на завтра?',
        'выведи весь список дел',
        'какие у меня встречи на завтра?',
        'покажи список «Дом»',
        'мне бы посмотреть план на неделю',
        'список',
      ]) {
        expect(
          parser.parse(text).intent,
          CommandIntent.listTasks,
          reason: text,
        );
      }
    });

    test('лишнее слово — уже не список', () {
      for (final text in <String>[
        'какие есть планы на выходные в городе?',
        'покажи список моих контактов',
        'покажи мне «подготовить презентацию»',
        'список «Дом» купить',
      ]) {
        expect(
          parser.parse(text).intent,
          isNot(CommandIntent.listTasks),
          reason: text,
        );
      }
      // Инфинитив без «хочу/бы» — задача.
      expect(parser.parse('посмотреть план').intent, CommandIntent.createTask);
    });
  });
}
