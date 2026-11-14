// Шапка сессии (макет «Д»): название сессии ▾ по центру и под ним — кто
// отвечает; нажатие на название — меню сессии (как долгое нажатие в
// панели), а не переход в настройки помощников. Необязательная кнопка
// справа, всегда одна строка 56 (хроника команд — поверх ленты), крупный
// шрифт.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/shell/session_header.dart';
import 'package:local_assistant/app/shell/session_hold_menu.dart';
import 'package:local_assistant/core/personas/persona.dart';

Future<void> _pump(
  WidgetTester tester, {
  ValueChanged<SessionAction>? onAction,
  Widget? trailing,
  bool wide = false,
  bool pinned = false,
  String title = 'Купить хлеб',
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
            sessionTitle: title,
            persona: Personas.liorio,
            onSessionAction: onAction,
            pinned: pinned,
            trailing: trailing,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('телефон: название по центру, под ним — кто отвечает',
      (tester) async {
    await _pump(tester, onAction: (_) {});
    expect(find.text('Купить хлеб'), findsOneWidget);
    expect(find.byKey(const Key('session-persona')), findsOneWidget);
    expect(find.text(Personas.liorio.russianName), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
    expect(find.text('Сегодня'), findsNothing);
    final middle = tester.getRect(find.byKey(const Key('session-title')));
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

  testWidgets('нажатие на название — меню сессии, выбор уходит наружу',
      (tester) async {
    final chosen = <SessionAction>[];
    await _pump(tester, onAction: chosen.add, pinned: true);
    await tester.tap(find.byKey(const Key('session-title')));
    await tester.pumpAndSettle();
    expect(find.text('Переименовать'), findsOneWidget);
    expect(find.text('Открепить'), findsOneWidget);
    expect(find.text('Удалить'), findsOneWidget);
    await tester.tap(find.text('Переименовать'));
    await tester.pumpAndSettle();
    expect(chosen, <SessionAction>[SessionAction.rename]);
  });

  testWidgets('пустая сессия: без стрелки, нажатие ничего не открывает',
      (tester) async {
    await _pump(tester, title: 'Новая сессия');
    expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);
    await tester.tap(find.byKey(const Key('session-title')));
    await tester.pumpAndSettle();
    expect(find.text('Переименовать'), findsNothing);
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
    // На компьютере название — слева, у кнопки меню.
    expect(
      tester.getRect(find.byKey(const Key('session-title'))).left,
      lessThan(100),
    );
    expect(tester.getSize(find.byType(SessionHeader)).height, 56);
  });

  testWidgets('320 px и шрифт 2x: без переполнения', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(
      tester,
      onAction: (_) {},
      title: 'Очень длинное название сессии про хлеб, молоко и сыр',
      size: const Size(320, 640),
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.byKey(const Key('session-title'))).right,
      lessThanOrEqualTo(320),
    );
    expect(tester.getSize(find.byType(SessionHeader)).height, 56);
  });
}
