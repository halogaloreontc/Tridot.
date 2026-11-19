// Шторка «История команд» (showCommandHistory): закрывается нажатием мимо,
// свайпом вниз и свайпом вверх — за шапку с ручкой, а когда списку некуда
// листаться, то и за список. Свайп вверх по длинному списку листает его.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/widgets/history_rail.dart';

List<HistoryEntry> _entries(int count) => <HistoryEntry>[
      for (var i = 0; i < count; i++)
        HistoryEntry(
          command: 'Напомни позвонить маме в пятницу $i',
          timestamp: '12:${(10 + i % 50).toString().padLeft(2, '0')}',
          result: i.isEven ? 'Готово: напоминание на пятницу' : null,
        ),
    ];

final _sheet = find.byKey(const Key('history-sheet'));
final _handle = find.byKey(const Key('history-sheet-handle'));

/// Ответы шторки: номер команды или `null`, по одному на закрытие.
Future<List<int?>> _pump(
  WidgetTester tester, {
  int count = 40,
  bool reduceMotion = false,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final results = <int?>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.dark(),
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => Center(
            child: TextButton(
              key: const Key('open'),
              onPressed: () async => results.add(
                await showCommandHistory(
                  context,
                  entries: _entries(count),
                  reduceMotion: reduceMotion,
                ),
              ),
              child: const Text('Открыть'),
            ),
          ),
        ),
      ),
    ),
  );
  return results;
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('open')));
  await tester.pumpAndSettle();
  expect(_sheet, findsOneWidget);
}

Offset _title(WidgetTester tester) =>
    tester.getCenter(find.text('История команд'));

void main() {
  testWidgets('свайп вверх за шапку закрывает: null, без выбора',
      (tester) async {
    final results = await _pump(tester);
    await _open(tester);
    await tester.dragFrom(_title(tester), const Offset(0, -30));
    await tester.pumpAndSettle();
    expect(_sheet, findsOneWidget, reason: 'короткий свайп не закрывает');

    await tester.dragFrom(_title(tester), const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);
    expect(results, <int?>[null]);

    // За ручку — тоже; и быстрый короткий бросок.
    await _open(tester);
    await tester.flingFrom(
      tester.getCenter(_handle),
      const Offset(0, -40),
      1500,
    );
    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);
    expect(results, <int?>[null, null]);
  });

  testWidgets('свайп вверх по длинному списку листает, а не закрывает',
      (tester) async {
    final results = await _pump(tester);
    await _open(tester);
    final list = tester.widget<ListView>(_sheet).controller!;
    expect(list.offset, 0);
    await tester.drag(_sheet, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(_sheet, findsOneWidget);
    expect(list.offset, greaterThan(0));

    await tester.fling(_sheet, const Offset(0, -300), 2000);
    await tester.pumpAndSettle();
    expect(_sheet, findsOneWidget);

    // У нижнего края списка — тоже не закрывает.
    final end = list.position.maxScrollExtent;
    list.jumpTo(end);
    await tester.pump();
    await tester.drag(_sheet, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(_sheet, findsOneWidget);
    expect(results, isEmpty);

    // Назад к началу — и нажатие по команде её выбирает.
    await tester.drag(_sheet, const Offset(0, 100000));
    await tester.pumpAndSettle();
    expect(_sheet, findsOneWidget);
    await tester.tap(find.byKey(const Key('history-item-39')));
    await tester.pumpAndSettle();
    expect(results, <int?>[39]);
  });

  testWidgets('короткий список: свайп вверх по нему закрывает', (tester) async {
    final results = await _pump(tester, count: 3);
    await _open(tester);
    await tester.dragFrom(
      tester.getCenter(find.byKey(const Key('history-item-1'))),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);
    expect(results, <int?>[null]);
  });

  testWidgets('свайп вниз и нажатие мимо по-прежнему закрывают',
      (tester) async {
    final results = await _pump(tester);
    await _open(tester);
    await tester.dragFrom(_title(tester), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);

    await _open(tester);
    await tester.flingFrom(
      tester.getCenter(_handle),
      const Offset(0, 60),
      1500,
    );
    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);

    await _open(tester);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);

    await _open(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);
    expect(results, <int?>[null, null, null, null]);
  });

  testWidgets('диктор: ручка «Закрыть» на месте', (tester) async {
    final handle = tester.ensureSemantics();
    final results = await _pump(tester);
    await _open(tester);
    final node = tester.getSemantics(_handle);
    expect(node.label, isNotEmpty);
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    tester.semantics.performAction(
      find.semantics.byLabel(node.label),
      SemanticsAction.tap,
    );
    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);
    expect(results, <int?>[null]);
    handle.dispose();
  });

  testWidgets('«Меньше движения»: открывается и закрывается без анимации',
      (tester) async {
    final results = await _pump(tester, reduceMotion: true);
    await tester.tap(find.byKey(const Key('open')));
    await tester.pump();
    expect(_sheet, findsOneWidget);
    final first = tester.getRect(_sheet);
    await tester.pumpAndSettle();
    expect(tester.getRect(_sheet), first, reason: 'сразу на месте');
    await tester.dragFrom(_title(tester), const Offset(0, -120));
    await tester.pump();
    await tester.pump();
    expect(_sheet, findsNothing);
    expect(results, <int?>[null]);
  });
}
