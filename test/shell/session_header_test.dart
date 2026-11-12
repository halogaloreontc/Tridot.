// Шапка сессии (макет «Д»): «Лиорио ▾», «Сегодня N», красная точка при
// просрочке, подпись для чтения с экрана, крупный шрифт.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/shell/session_header.dart';

Future<void> _pump(
  WidgetTester tester, {
  int count = 3,
  int overdue = 1,
  VoidCallback? onToday,
  VoidCallback? onPersona,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.dark(),
      home: Scaffold(
        body: SessionHeader(
          leading: IconButton(
            key: const Key('menu-button'),
            onPressed: () {},
            icon: const Icon(Icons.menu),
          ),
          personaName: 'Лиорио',
          onPersona: onPersona,
          today: TodayButton(
            count: count,
            overdue: overdue,
            onPressed: onToday ?? () {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('счётчик, красная точка и нажатия', (tester) async {
    var today = 0;
    var persona = 0;
    await _pump(
      tester,
      onToday: () => today++,
      onPersona: () => persona++,
    );
    expect(find.text('Лиорио'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('today-count'))).data,
      '3',
    );
    expect(find.byKey(const Key('today-overdue-dot')), findsOneWidget);
    await tester.tap(find.byKey(const Key('today-button')));
    await tester.tap(find.byKey(const Key('persona-switch')));
    expect(today, 1);
    expect(persona, 1);
    // Помощник — между меню и «Сегодня», не налезает на них.
    final middle = tester.getRect(find.byKey(const Key('persona-switch')));
    expect(
      middle.left,
      greaterThanOrEqualTo(
        tester.getRect(find.byKey(const Key('menu-button'))).right,
      ),
    );
    expect(
      middle.right,
      lessThanOrEqualTo(
        tester.getRect(find.byKey(const Key('today-button'))).left,
      ),
    );
  });

  testWidgets('без просрочки точки нет', (tester) async {
    await _pump(tester, count: 2, overdue: 0);
    expect(find.byKey(const Key('today-overdue-dot')), findsNothing);
  });

  test('подпись для чтения с экрана — со склонением', () {
    expect(
      TodayButton.semanticLabel(3, 1),
      'Сегодня: 3 дела, одно просрочено',
    );
    expect(TodayButton.semanticLabel(1, 0), 'Сегодня: 1 дело');
    expect(TodayButton.semanticLabel(5, 2), 'Сегодня: 5 дел, просрочено 2');
  });

  testWidgets('320 px и шрифт 2x: без переполнения, подпись спрятана',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(tester, size: const Size(320, 640), count: 12);
    expect(tester.takeException(), isNull);
    expect(find.text('Сегодня'), findsNothing);
    expect(find.byKey(const Key('today-count')), findsOneWidget);
    final button = tester.getRect(find.byKey(const Key('today-button')));
    expect(button.right, lessThanOrEqualTo(320));
    expect(button.height, greaterThanOrEqualTo(44));
  });
}
