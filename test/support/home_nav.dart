// Переходы по оболочке «Д» в тестах главного экрана: меню, «Мой Связной»
// и его вкладки, «Сегодня» (компьютер) и «Сводка» (телефон), возврат в
// сессию.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Открывает меню, если оно не стоит колонкой (телефон, узкое окно).
Future<void> openDrawerIfNeeded(WidgetTester tester) async {
  if (find
      .byKey(const Key('drawer-my-relay'))
      .hitTestable()
      .evaluate()
      .isNotEmpty) {
    return;
  }
  final menu = find.byKey(const Key('menu-button'));
  if (menu.evaluate().isNotEmpty) {
    await tester.tap(menu);
  } else {
    final scaffold = tester.state<ScaffoldState>(
      find.byType(Scaffold).first,
    );
    scaffold.openDrawer();
  }
  await tester.pumpAndSettle();
}

/// Нажимает пункт меню [key] (открывает меню, если нужно).
Future<void> tapInDrawer(WidgetTester tester, Key key) async {
  await openDrawerIfNeeded(tester);
  await tester.ensureVisible(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

/// «Мой Связной» на вкладке [tab]: summary, activity, assistants,
/// settings.
Future<void> openMyRelay(WidgetTester tester, [String tab = 'summary']) async {
  await tapInDrawer(tester, const Key('drawer-my-relay'));
  final target = find.byKey(Key('my-relay-tab-$tab'));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

/// Экран настроек: «Мой Связной» → «Настройки».
Future<void> openSettings(WidgetTester tester) =>
    openMyRelay(tester, 'settings');

/// Обратно в сессию: «назад» из «Мой Связной» или «Главный» в меню.
Future<void> backToSession(WidgetTester tester) async {
  final back = find.byKey(const Key('my-relay-back'));
  if (back.evaluate().isNotEmpty) {
    await tester.tap(back);
    await tester.pumpAndSettle();
    return;
  }
  await tapInDrawer(tester, const Key('chat-main'));
}

/// Открывает колонку «Сегодня» на компьютере, если она свёрнута. На
/// телефоне её нет — там [openSummary].
Future<void> openToday(WidgetTester tester) async {
  if (find.byKey(const Key('today-panel')).evaluate().isNotEmpty) return;
  await tester.tap(find.byKey(const Key('today-show')));
  await tester.pumpAndSettle();
}

/// «Мой Связной» → «Сводка»: на телефоне здесь всё, что было в «Сегодня».
Future<void> openSummary(WidgetTester tester) => openMyRelay(tester);
