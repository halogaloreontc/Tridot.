// Переходы по оболочке «Д» в тестах главного экрана: меню, «Мой Связной»
// и его вкладки, «Сегодня» (компьютер) и «Сводка» (телефон), возврат в
// сессию.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/shell/relay_drawer.dart';

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

/// Пункты сессий (не чатов задач) в меню, свежие сверху.
Finder sessionEntries() => find.byWidgetPredicate(
      (Widget w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('chat-session:'),
    );

/// Пункт меню с названием [title] (сессия или чат задачи).
Finder drawerEntry(String title) => find.descendant(
      of: find.byType(RelayDrawer),
      matching: find.text(title),
    );

/// Открывает из меню сессию (или чат задачи) с названием [title].
Future<void> openSessionTitled(WidgetTester tester, String title) async {
  await openDrawerIfNeeded(tester);
  await expandDrawerGroups(tester);
  final entry = drawerEntry(title).first;
  await tester.ensureVisible(entry);
  await tester.pumpAndSettle();
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

/// Обратно в сессию: «назад» из «Мой Связной», иначе самая свежая сессия в
/// меню (обычно та, где писали команды).
Future<void> backToSession(WidgetTester tester) async {
  final back = find.byKey(const Key('my-relay-back'));
  if (back.evaluate().isNotEmpty) {
    await tester.tap(back);
    await tester.pumpAndSettle();
    return;
  }
  await openDrawerIfNeeded(tester);
  final entry = sessionEntries().first;
  await tester.ensureVisible(entry);
  await tester.pumpAndSettle();
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

/// Id единственной сохранённой сессии в [ids] (`store.chatIds`).
String onlySessionId(Iterable<String> ids) =>
    ids.singleWhere((String id) => id.startsWith('session:'));

/// Открывает колонку «Сегодня» на компьютере, если она свёрнута. На
/// телефоне её нет — там [openSummary].
Future<void> openToday(WidgetTester tester) async {
  if (find.byKey(const Key('today-panel')).evaluate().isNotEmpty) return;
  await tester.tap(find.byKey(const Key('today-show')));
  await tester.pumpAndSettle();
}

/// «Мой Связной» → «Сводка»: на телефоне здесь всё, что было в «Сегодня».
Future<void> openSummary(WidgetTester tester) => openMyRelay(tester);

/// То же, что [finder], но без меню: в меню у сессии вторая строка —
/// последний ответ помощника, и текст ответа виден там тоже.
Finder outsideDrawer(Finder finder) => find.byElementPredicate(
      (Element element) {
        if (!finder.evaluate().contains(element)) return false;
        var inDrawer = false;
        element.visitAncestorElements((Element ancestor) {
          if (ancestor.widget is RelayDrawer) {
            inDrawer = true;
            return false;
          }
          return true;
        });
        return !inDrawer;
      },
      description: '${finder.describeMatch(Plurality.many)} вне меню',
    );

/// Раскрывает свёрнутые группы меню («Вчера», «На неделе», «Ранее» на
/// компьютере), чтобы их сессии можно было найти и нажать.
Future<void> expandDrawerGroups(WidgetTester tester) async {
  for (final id in RelayDrawer.collapsible) {
    final toggle = find.byKey(Key('drawer-group-$id'));
    if (toggle.evaluate().isEmpty) continue;
    final expanded = find.descendant(
      of: toggle,
      matching: find.byIcon(Icons.keyboard_arrow_down),
    );
    final header = find.descendant(
      of: toggle,
      matching: find.byIcon(Icons.chevron_right),
    );
    if (expanded.evaluate().isNotEmpty || header.evaluate().isEmpty) continue;
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
  }
}
