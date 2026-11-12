// Шапка сессии (макет «Д»): «Лиорио ▾» по центру, необязательная кнопка
// справа, всегда одна строка 56 (хроника команд — поверх ленты), крупный
// шрифт.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/shell/session_header.dart';

Future<void> _pump(
  WidgetTester tester, {
  VoidCallback? onPersona,
  Widget? trailing,
  bool wide = false,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.dark(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: SessionHeader(
            wide: wide,
            leading: IconButton(
              key: const Key('menu-button'),
              onPressed: () {},
              icon: const Icon(Icons.menu),
            ),
            personaName: 'Лиорио',
            onPersona: onPersona,
            trailing: trailing,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('телефон: помощник по центру, справа пусто', (tester) async {
    var persona = 0;
    await _pump(tester, onPersona: () => persona++);
    expect(find.text('Лиорио'), findsOneWidget);
    expect(find.text('Сегодня'), findsNothing);
    await tester.tap(find.byKey(const Key('persona-switch')));
    expect(persona, 1);
    final middle = tester.getRect(find.byKey(const Key('persona-switch')));
    expect(middle.center.dx, moreOrLessEquals(195, epsilon: 1));
    expect(
      middle.left,
      greaterThanOrEqualTo(
        tester.getRect(find.byKey(const Key('menu-button'))).right,
      ),
    );
    // Шапка — одна строка 56.
    expect(tester.getSize(find.byType(SessionHeader)).height, 56);
  });

  testWidgets('кнопка справа; шапка — одна строка 56', (tester) async {
    var shown = 0;
    await _pump(
      tester,
      wide: true,
      size: const Size(1000, 700),
      trailing: IconButton(
        key: const Key('today-show'),
        onPressed: () => shown++,
        icon: const Icon(Icons.view_sidebar_outlined),
      ),
    );
    await tester.tap(find.byKey(const Key('today-show')));
    expect(shown, 1);
    expect(
      tester.getRect(find.byKey(const Key('today-show'))).right,
      lessThanOrEqualTo(1000),
    );
    expect(tester.getSize(find.byType(SessionHeader)).height, 56);
  });

  testWidgets('320 px и шрифт 2x: без переполнения', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(
      tester,
      size: const Size(320, 640),
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.byKey(const Key('persona-switch'))).right,
      lessThanOrEqualTo(320),
    );
  });
}
