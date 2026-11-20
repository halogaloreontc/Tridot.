import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/intent/intent_fallback.dart';
import 'package:local_assistant/core/intent/intent_io.dart';
import 'package:local_assistant/core/services/clock.dart';

/// Часы, которые можно переводить.
final class MovingClock implements Clock {
  MovingClock(this.value);

  DateTime value;

  @override
  DateTime now() => value;
}

void main() {
  final start = DateTime.utc(2026, 11, 20, 10);

  group('журнал непонятых фраз', () {
    test('не больше 200 записей, новые первыми, та же фраза — одна', () async {
      final clock = MovingClock(start);
      final memory = IntentMemory(clock: clock, blocks: (_) => false);
      for (var i = 0; i < 250; i++) {
        clock.value = start.add(Duration(minutes: i));
        await memory.note('фраза номер $i', UnclearKind.unknown);
      }
      expect(memory.unclear, hasLength(IntentMemory.maxUnclear));
      expect(memory.unclear.first.text, 'фраза номер 249');
      expect(memory.unclear.last.text, 'фраза номер 50');
      await memory.note('Фраза  номер 100', UnclearKind.rejected, label: 'x:y');
      expect(memory.unclear.first.kind, UnclearKind.rejected);
      expect(
        memory.unclear.where((UnclearPhrase e) => e.text.contains('100')),
        hasLength(1),
      );
    });

    test('старше 90 дней удаляются сами', () async {
      final clock = MovingClock(start);
      final store = InMemoryIntentMemoryStore();
      final memory = IntentMemory(
        store: store,
        clock: clock,
        blocks: (_) => false,
      );
      await memory.note('давняя фраза', UnclearKind.unknown);
      clock.value = start.add(const Duration(days: 60));
      await memory.note('свежая фраза', UnclearKind.unknown);
      clock.value = start.add(const Duration(days: 91));
      expect(memory.unclear.map((UnclearPhrase e) => e.text), <String>[
        'свежая фраза',
      ]);
      // И после перезапуска.
      final again = IntentMemory(
        store: store,
        clock: clock,
        blocks: (_) => false,
      );
      await again.load();
      expect(again.unclear, hasLength(1));
    });

    test('«Собирать непонятые фразы» выключено — ничего не пишется', () async {
      final store = InMemoryIntentMemoryStore();
      final memory = IntentMemory(store: store, blocks: (_) => false);
      await memory.setLogging(false);
      final saves = store.saves;
      await memory.note('фраза', UnclearKind.unknown);
      expect(memory.unclear, isEmpty);
      expect(store.saves, saves);
    });

    test('приватные фразы не пишутся никогда', () async {
      final store = InMemoryIntentMemoryStore();
      final memory = IntentMemory(store: store, blocks: intentPrivate);
      for (final phrase in <String>[
        'пароль от почты CANARY',
        'пин-код 4821',
        'код подтверждения 123456',
        'логин от госуслуг',
        'abc123def',
      ]) {
        await memory.note(phrase, UnclearKind.unknown);
        await memory.remember(phrase, 'tasks:task.create');
        await memory.reject(phrase, <String>['tasks:task.create']);
      }
      expect(memory.unclear, isEmpty);
      expect(memory.positives, isEmpty);
      expect(memory.negatives, isEmpty);
      expect(store.saves, 0);
    });
  });

  group('личные примеры', () {
    test('«Да» снимает прежнее «Нет» той же фразы, и наоборот', () async {
      final memory = IntentMemory(blocks: (_) => false);
      await memory.reject('в кино', <String>['tasks:task.create']);
      await memory.remember('В кино', 'tasks:task.create');
      expect(memory.negatives, isEmpty);
      expect(memory.positives, hasLength(1));
      await memory.reject('в кино', <String>['tasks:task.create']);
      expect(memory.positives, isEmpty);
    });

    test('учиться выключено — новые примеры не сохраняются', () async {
      final memory = IntentMemory(blocks: (_) => false);
      await memory.setLearning(false);
      await memory.remember('в кино', 'tasks:task.create');
      await memory.reject('в кино', <String>['tasks:task.list']);
      expect(memory.positives, isEmpty);
      expect(memory.negatives, isEmpty);
    });

    test('«Забыть выученное» стирает всё, журнал остаётся', () async {
      final memory = IntentMemory(blocks: (_) => false);
      await memory.remember('в кино', 'tasks:task.create');
      await memory.reject('посчитай', <String>['calc:calc.evaluate']);
      await memory.note('в кино', UnclearKind.accepted);
      await memory.forgetLearned();
      expect(memory.positives, isEmpty);
      expect(memory.negatives, isEmpty);
      expect(memory.unclear, hasLength(1));
      await memory.clearUnclear();
      expect(memory.unclear, isEmpty);
    });

    test('примеров каждого вида не больше предела', () async {
      final memory = IntentMemory(blocks: (_) => false);
      for (var i = 0; i < IntentMemory.maxExamples + 5; i++) {
        await memory.remember('фраза $i', 'tasks:task.create');
      }
      expect(memory.positives, hasLength(IntentMemory.maxExamples));
      expect(memory.positives.first.text, 'фраза 5');
    });
  });

  group('JSON на устройстве', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('intent_memory'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('всё переживает перезапуск, вектор — без потерь', () async {
      final path = '${dir.path}/intent/memory.json';
      final vector = Float32List.fromList(<double>[0.25, -0.5, 1 / 3]);
      final memory = IntentMemory(
        store: JsonIntentMemoryStore(path),
        clock: FixedClock(start),
        blocks: (_) => false,
      );
      await memory.remember(
        'в кино',
        'tasks:task.create',
        vector: vector,
        modelKey: 'light@0.1.0',
      );
      await memory.reject('посчитай', <String>['calc:calc.evaluate']);
      await memory.note(
        'в кино',
        UnclearKind.accepted,
        label: 'tasks:task.create',
      );
      await memory.setLogging(false);
      final again = IntentMemory(
        store: JsonIntentMemoryStore(path),
        clock: FixedClock(start),
      );
      await again.load();
      expect(again.logging, isFalse);
      expect(again.learning, isTrue);
      expect(again.positives.single.vector, vector);
      expect(again.positives.single.modelKey, 'light@0.1.0');
      expect(again.negatives.single.vector, isNull);
      expect(again.unclear.single.label, 'tasks:task.create');
    });

    test('повреждённый файл — память как новая', () async {
      final path = '${dir.path}/memory.json';
      File(path).writeAsStringSync('{не json');
      final memory = IntentMemory(store: JsonIntentMemoryStore(path));
      await memory.load();
      expect(memory.learning, isTrue);
      expect(memory.logging, isTrue);
      File(path).writeAsStringSync('{"positives": [{"text": 1}]}');
      await memory.load();
      expect(memory.positives, isEmpty);
    });
  });
}
