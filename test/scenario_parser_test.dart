import 'package:flutter_test/flutter_test.dart';
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
}
