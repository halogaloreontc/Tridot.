import 'package:flutter_test/flutter_test.dart';

import '../../tool/route_phrases.dart';

/// tool/route_phrases.dart: по нему tools/corpus_gen сверяет фразы с одним
/// разметчиком, поэтому выбор коннектора должен быть как в приложении.
void main() {
  final now = DateTime(2026, 11, 2, 16, 30);

  Map<String, Object?> routed(String text) => routePhrase(text, now);

  test('создание задачи — tasks и разбор задачи', () {
    final result = routed('Добавь задачу позвонить клиенту завтра в 11:00');
    expect(result['connector'], 'tasks');
    expect(result['command'], 'task.create');
    final parse = result['parse']! as Map<String, Object?>;
    expect(parse['intent'], 'createTask');
    expect(parse['title'], 'Позвонить клиенту');
    expect(parse['due'], '2026-11-03T11:00');
    expect(parse['precision'], 'dateTime');
  });

  test('пример — калькулятор', () {
    final result = routed('сколько будет 2+2*2');
    expect(result['connector'], 'calc');
    expect(result['command'], 'calc.evaluate');
  });

  test('приветствие — беседа, но команда после него — задача', () {
    final greet = routed('привет');
    expect(greet['connector'], 'talk');
    expect(greet['command'], 'talk.greet');
    final matches = greet['matches']! as List<Map<String, Object?>>;
    expect(matches.single['fallback'], isTrue);

    final task = routed('привет, добавь задачу купить хлеб');
    expect(task['connector'], 'tasks');
    expect(task['command'], 'task.create');
  });

  test('непонятная фраза — никто', () {
    final result = routed('абракадабра');
    expect(result['connector'], isNull);
    expect(result['command'], isNull);
    expect(result['matches'], isEmpty);
    expect((result['parse']! as Map<String, Object?>)['intent'], 'unknown');
  });

  test('склад из корпусного теста забирает «где лежит {код}» у задач', () {
    // Иначе неявная задача прошла бы проверку, а корпусный тест отдал бы
    // фразу складу и упал на активной строке.
    final result = routed('забрать коробку 64115 где лежит завтра');
    expect(result['connector'], 'warehouse_example');
    final matches = result['matches']! as List<Map<String, Object?>>;
    expect(
      matches.map((Map<String, Object?> m) => m['connector']),
      containsAll(<String>['tasks', 'warehouse_example']),
    );
  });

  test('фраза из одних кавычек не роняет разбор', () {
    for (final text in ['«купить хлеб»', '"спасибо"', '👍']) {
      final parse = routed(text)['parse']! as Map<String, Object?>;
      expect(parse['intent'], isNotNull, reason: text);
    }
    final parse = routed('«купить хлеб»')['parse']! as Map<String, Object?>;
    expect(parse['intent'], 'unknown');
  });
}
