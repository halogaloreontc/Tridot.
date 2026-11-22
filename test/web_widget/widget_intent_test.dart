import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/intent/intent_memory.dart';
import 'package:local_assistant/core/models/assistant_types.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/web_widget/widget_app.dart';
import 'package:local_assistant/web_widget/widget_intent.dart';
import 'package:local_assistant/web_widget/widget_session.dart';
import 'package:local_assistant/web_widget/widget_storage.dart';

import 'fakes.dart';
import 'intent_fakes.dart';

/// Запасной слой понимания в веб-помощнике (ADR-045, шаг 4): пакет `web`
/// со склада, поддельная среда вместо onnxruntime-web, память в хранилище
/// браузера под логином.
void main() {
  /// Фразы, которых правила помощника не понимают (проверяется ниже).
  const arrivals = 'ну и чем нас порадовали поставщики с утра';
  const half = 'четырнадцать с половиной на два';
  const cinema = 'в субботу в 11 с детьми в кино сходить надо';
  const secret = 'мой пароль от почты кот123';

  late FakeWarehouse server;
  late FakeHost host;
  late MemoryStorage storage;
  late FakePackServer files;
  late FakeWebRuntime runtime;
  late WidgetSession session;
  var made = false;

  WidgetSession make({bool model = true, Future<void> Function()? prepare}) {
    host = FakeHost();
    made = true;
    return session = WidgetSession(
      host: host,
      transport: server,
      storage: storage,
      builtInManifest: builtInSource(),
      version: '1.0.0',
      updateEvery: const Duration(hours: 1),
      clock: FixedClock(DateTime(2026, 11, 22, 10)),
      intentFetcher: model ? files : null,
      intentRuntime: model ? runtime.open : null,
      intentPrepare: prepare,
      intentDelay: Duration.zero,
    );
  }

  setUp(() {
    made = false;
    server = FakeWarehouse();
    storage = MemoryStorage();
    files = FakePackServer();
    final pack = webPackFiles();
    final manifest = webManifest(pack);
    files.serve(<String, Uint8List>{...pack, 'manifest.json': manifest});
    server.intentPointer = webPointer(manifest: manifest);
    runtime = FakeWebRuntime(<String, Float32List>{
      arrivals: webVector(<String, double>{'warehouse:warehouse.today': 1}),
      half: webVector(<String, double>{'calc:calc.evaluate': 1}),
      cinema: webVector(<String, double>{'tasks:task.create': 1}),
      secret: webVector(<String, double>{'warehouse:warehouse.today': 1}),
    });
  });

  tearDown(() {
    if (made) session.dispose();
  });

  Future<void> open() async {
    session.start();
    host.emit(initMessage());
    await settle();
    for (var i = 0; i < 200; i++) {
      final state = session.intent?.state;
      if (state != null &&
          state != WidgetIntentState.unknown &&
          state != WidgetIntentState.loading) {
        break;
      }
      await Future<void>.delayed(Duration.zero);
    }
  }

  String last() => session.messages.last.text;

  test('без модели эти фразы — «не понял»', () async {
    make(model: false);
    await open();
    expect(session.intent!.state, WidgetIntentState.none);
    for (final phrase in <String>[arrivals, half, cinema]) {
      await session.send(phrase);
      expect(last(), isNot(contains('Похоже, вы хотите')), reason: phrase);
      expect(session.pendingClarification, isNull, reason: phrase);
    }
    // Журнал непонятых ведётся и без модели — как в приложении.
    expect(
      session.intent!.memory.unclear.map((UnclearPhrase p) => p.text),
      containsAll(<String>[arrivals, half, cinema]),
    );
  });

  test('склад без модели (404) — подсказок нет, файлы не скачиваются',
      () async {
    server.intentPointer = null;
    make();
    await open();
    expect(session.intent!.state, WidgetIntentState.none);
    expect(session.intent!.version, isNull);
    expect(files.requests, isEmpty);
    expect(runtime.opened, 0);
    await session.send(arrivals);
    expect(last(), isNot(contains('Похоже, вы хотите')));
  });

  test('«не понял» → «Похоже, вы хотите…?», «Да» — команда склада правилами',
      () async {
    make();
    await open();
    final intent = session.intent!;
    expect(intent.state, WidgetIntentState.ready, reason: intent.problem);
    expect(intent.version, '1.0.0');
    expect(runtime.opened, 1);
    // Все файлы — из папки версии склада.
    expect(
      files.requests.map((Uri u) => u.path),
      everyElement(startsWith('/assistant/intent/web/1.0.0-6dc650b6/')),
    );

    await session.send(arrivals);
    expect(last(), contains('Похоже, вы хотите'));
    expect(last(), contains('что пришло на склад сегодня'));
    final question = session.pendingClarification!;
    expect(
      question.options.map((o) => o.label),
      <String>['Да', 'Нет'],
    );
    expect(identical(session.messages.last.clarification, question), isTrue);

    server.on('ask_arrivals', 200, <String, Object?>{
      'ok': true,
      'count': 2,
      'qty': 14,
      'items': <Object?>[],
    });
    await session.choose(question.options.first);
    expect(server.actions, contains('ask_arrivals'));
    expect(session.pendingClarification, isNull);
    expect(session.messages.last.status, isNot(AssistantStatus.failed));
    expect(
      intent.memory.positives.single.label,
      'warehouse:warehouse.today',
    );
    expect(intent.memory.unclear.first.kind, UnclearKind.accepted);
    // Память — в хранилище браузера под логином.
    final saved = jsonDecode(storage.values['svz:intent:ivanov']!) as Map;
    expect((saved['positives'] as List).single['text'], arrivals);
  });

  test('«Нет» — отрицательный пример и обычное «не понял»', () async {
    make();
    await open();
    await session.send(half);
    expect(last(), contains('посчитать на калькуляторе'));
    final no = session.pendingClarification!.options.last;
    expect(no.label, 'Нет');
    await session.choose(no);
    expect(session.pendingClarification, isNull);
    expect(last(), isNot(contains('Похоже, вы хотите')));
    final memory = session.intent!.memory;
    expect(memory.negatives.single.label, 'calc:calc.evaluate');
    expect(memory.unclear.first.kind, UnclearKind.rejected);
    // Похожую фразу больше не предлагает.
    await session.send(half);
    expect(last(), isNot(contains('Похоже, вы хотите')));
  });

  test(
      'задачи в индексе web не предлагаются; приватное до модели не '
      'доходит', () async {
    make();
    await open();
    await session.send(cinema);
    expect(last(), isNot(contains('Похоже, вы хотите')));
    expect(session.intent!.memory.unclear.first.text, cinema);

    await session.send(secret);
    expect(last(), isNot(contains('Похоже, вы хотите')));
    expect(runtime.seen, isNot(contains(secret)));
    final stored = storage.values['svz:intent:ivanov'] ?? '';
    expect(stored, isNot(contains('кот123')));
    expect(
      session.intent!.memory.unclear.map((UnclearPhrase p) => p.text),
      isNot(contains(secret)),
    );
  });

  test(
      '«Подсказывать команды» выключено — модель выгружена, включено — '
      'снова', () async {
    make();
    await open();
    final intent = session.intent!;
    await intent.setEnabled(false);
    expect(intent.state, WidgetIntentState.off);
    expect(intent.ready, isFalse);
    expect(runtime.closed, isTrue);
    expect(storage.values['svz:intent-on:ivanov'], '0');
    await session.send(arrivals);
    expect(last(), isNot(contains('Похоже, вы хотите')));
    await intent.setEnabled(true);
    expect(intent.state, WidgetIntentState.ready);
    expect(runtime.opened, 2);
  });

  test('подменённый пакет — не загрузился, ответы правил те же', () async {
    final pack = webPackFiles();
    final manifest = webManifest(pack);
    final broken = Uint8List.fromList(pack['index.bin']!)..[20] ^= 1;
    files.serve(<String, Uint8List>{
      ...pack,
      'index.bin': broken,
      'manifest.json': manifest,
    });
    make();
    await open();
    expect(session.intent!.state, WidgetIntentState.failed);
    expect(session.intent!.problem, contains('sha256'));
    expect(runtime.opened, 0);
    await session.send(arrivals);
    expect(last(), isNot(contains('Похоже, вы хотите')));
  });

  test('нет onnxruntime-web в сборке — модель не скачивается', () async {
    make(prepare: () async => throw StateError('ort не загрузился'));
    await open();
    expect(session.intent!.state, WidgetIntentState.failed);
    expect(
      files.requests.map((Uri u) => u.pathSegments.last),
      <String>['manifest.json'],
    );
    expect(runtime.opened, 0);
  });

  test('выход из склада — модель закрыта, слоя нет', () async {
    make();
    await open();
    host.emit(<String, Object?>{'svz': 1, 'type': 'logout'});
    await settle();
    expect(session.intent, isNull);
    expect(runtime.closed, isTrue);
  });

  testWidgets('кнопки «Да» / «Нет» под подсказкой и экран «Понимание фраз»',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    make();
    await tester.pumpWidget(WidgetApp(session: session));
    await tester.runAsync(() async {
      await open();
      await session.send(half);
      await settle();
    });
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('clarify-option-0')), findsOne);
    expect(find.widgetWithText(FilledButton, 'Да'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(OutlinedButton, 'Нет'));
      await settle();
    });
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('clarify-option-0')),
      findsNothing,
    );
    expect(session.intent!.memory.negatives, hasLength(1));

    await tester.tap(find.byKey(const ValueKey<String>('widget-menu')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('drawer-extension-intent')),
      findsOneWidget,
    );
    expect(find.text('модель 1.0.0'), findsOneWidget);
    await tester.tap(find.byKey(const Key('drawer-extension-intent')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('intent-screen')), findsOneWidget);
    expect(find.textContaining('Версия 1.0.0'), findsOneWidget);
    expect(find.text(half), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('intent-learning')));
      await settle();
    });
    await tester.pump();
    expect(session.intent!.memory.learning, isFalse);
    // «Забыть выученное» — с подтверждением.
    await tester.tap(find.byKey(const Key('intent-forget')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('intent-forget-yes')));
      await settle();
    });
    await tester.pumpAndSettle();
    expect(session.intent!.memory.learnedCount, 0);
  });

  group('память в хранилище браузера', () {
    test('по логину, переживает перезагрузку, повреждённая — как новая',
        () async {
      final store = WidgetIntentMemoryStore(storage, 'Ivanov');
      expect(store.key, 'svz:intent:ivanov');
      final memory = IntentMemory(store: store);
      await memory.load();
      expect(memory.learning, isTrue);
      expect(memory.logging, isTrue);
      await memory.note('что-то непонятное', UnclearKind.unknown);
      await memory.remember(
        'что там пришло',
        'warehouse:warehouse.today',
        vector: webVector(<String, double>{'warehouse:warehouse.today': 1}),
        modelKey: 'web@1.0.0',
      );
      final again =
          IntentMemory(store: WidgetIntentMemoryStore(storage, 'ivanov'));
      await again.load();
      expect(again.unclear.single.text, 'что-то непонятное');
      expect(again.positives.single.vector, hasLength(webDims));
      // Другой сотрудник — своя память.
      final other =
          IntentMemory(store: WidgetIntentMemoryStore(storage, 'petrov'));
      await other.load();
      expect(other.unclear, isEmpty);

      storage.values['svz:intent:ivanov'] = '{битый';
      final broken =
          IntentMemory(store: WidgetIntentMemoryStore(storage, 'ivanov'));
      await broken.load();
      expect(broken.unclear, isEmpty);
    });

    test('не влезает — сначала без векторов, потом без старых примеров',
        () async {
      final memory = IntentMemory(store: WidgetIntentMemoryStore(storage, 'a'));
      final vector = Float32List(312)..fillRange(0, 312, 0.05);
      for (var i = 0; i < 400; i++) {
        await memory.remember(
          'фраза номер $i',
          'warehouse:warehouse.today',
          vector: vector,
          modelKey: 'web@1.0.0',
        );
      }
      final text = storage.values['svz:intent:a']!;
      expect(text.length, lessThanOrEqualTo(WidgetIntentMemoryStore.maxChars));
      final json = jsonDecode(text) as Map<String, Object?>;
      final positives = json['positives']! as List<Object?>;
      expect(positives, isNotEmpty);
      expect((positives.last! as Map)['text'], 'фраза номер 399');
      expect((positives.last! as Map).containsKey('vector'), isFalse);
    });

    test('запись запрещена — память до закрытия страницы', () async {
      final memory = IntentMemory(
        store: WidgetIntentMemoryStore(_ReadOnlyStorage(), 'a'),
      );
      await memory.note('фраза', UnclearKind.unknown);
      expect(memory.unclear.single.text, 'фраза');
    });
  });
}

final class _ReadOnlyStorage implements KeyValueStorage {
  @override
  String? read(String key) => null;

  @override
  void write(String key, String value) =>
      throw StateError('QuotaExceededError');

  @override
  void remove(String key) {}
}
