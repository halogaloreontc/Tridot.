import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/utterance.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';

void main() {
  final now = DateTime(2026, 11, 2, 16, 30);

  test('кавычки, метки и слова со смещениями в исходном тексте', () {
    const text = 'Добавь  «Ёлка» #Дом ЁЖИКА завтра';
    final u = Utterance.analyze(text, now: now);

    expect(u.quotedTitles.single.text, 'Ёлка');
    expect(u.hashtags.single.name, 'дом');
    expect(u.words, <String>['добавь', 'ежика', 'завтра']);
    final hedgehog = u.tokens[1];
    expect(text.substring(hedgehog.span.start, hedgehog.span.end), 'ЁЖИКА');
    expect(hedgehog.original, 'ЁЖИКА');
    expect(u.normalized.length, text.length);
    expect(u.due.dueAt, DateTime(2026, 11, 3));
  });

  test('остаток фразы сохраняет регистр и убирает лишние знаки', () {
    const text = 'Купить iPhone, на завтра , #покупки';
    final u = Utterance.analyze(text, now: now);

    expect(u.remainder(u.due.spans), 'Купить iPhone');
  });

  test('коды из 5–6 цифр отдельно от дат и времени', () {
    final u =
        Utterance.analyze('64115 и 123456 в 10:00, 15.11, 1234567', now: now);

    expect(u.codes, <String>['64115', '123456']);
    expect(u.due.issue, DueIssue.none);
    expect(u.due.dueAt, DateTime(2026, 11, 15, 10));
  });

  test('вопрос определяется вне кавычек', () {
    expect(Utterance.analyze('Заверши «Что?»', now: now).isQuestion, isFalse);
    expect(Utterance.analyze('Заверши?', now: now).isQuestion, isTrue);
  });
}
