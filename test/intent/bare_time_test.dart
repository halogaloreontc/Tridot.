import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/intent/bare_time.dart';

/// Те же случаи — `tools/intent_model/tests/test_prepare.py`
/// (`test_bare_time_guard`): пробы веб-уровней считаются так же.
void main() {
  test('голое время — не для модели, числа и команды — для неё', () {
    for (final text in <String>[
      '7:30',
      'в 9',
      'нет, на 6:45',
      'к 6 вечера',
      'часам к 5',
      'около 7',
      '18:30',
      'в 10.',
    ]) {
      expect(bareTimePhrase(text), isTrue, reason: text);
    }
    for (final text in <String>[
      '15',
      '7+30',
      '2*9',
      'в 9 разбуди',
      '12.11',
      'сколько будет 7:30',
      'в 25',
      '7:75',
      '',
    ]) {
      expect(bareTimePhrase(text), isFalse, reason: text);
    }
  });
}
