// Меню действий с сессией (макет «Ж2») и строка расширения (макет «Ж1»)
// с настоящими шрифтами приложения: крупный шрифт не обрезает пункты,
// копия строки над меню не звучит для диктора второй раз, фокус после
// меню возвращается на строку, с клавиатуры меню открывают Shift+F10 и
// клавиша меню, окно «Переименовать» помещается над клавиатурой,
// состояние расширения прижато к правому краю.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/shell/relay_drawer.dart';
import 'package:local_assistant/app/shell/session_hold_menu.dart';
import 'package:local_assistant/core/chats/chat_search.dart';

import '../support/app_fonts.dart';

SessionEntry _entry(String id, String title, {bool pinned = false}) =>
    SessionEntry(
      id: 'session:$id',
      title: title,
      time: '12:00',
      itemKey: Key('chat-session:$id'),
      dotKey: Key('chat-unread-session:$id'),
      pinned: pinned,
      canAct: true,
      canRename: true,
      preview: 'Принят, но не проведён',
    );

final _groups = <SessionGroupEntry>[
  SessionGroupEntry(
    id: 'pinned',
    label: 'Закреплённые',
    entries: <SessionEntry>[_entry('p', 'Еженедельный отчёт', pinned: true)],
  ),
  SessionGroupEntry(
    id: 'today',
    label: 'Сегодня',
    entries: <SessionEntry>[
      _entry('a', 'Отметить приход 318'),
      _entry('b', 'Сверить накладные'),
    ],
  ),
];

Future<List<String>> _pump(
  WidgetTester tester, {
  Size size = const Size(320, 640),
  bool wide = false,
  List<ExtensionEntry> extensions = const <ExtensionEntry>[],
}) async {
  final log = <String>[];
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.dark(),
      home: Scaffold(
        resizeToAvoidBottomInset: false,
        body: RelayDrawer(
          wide: wide,
          reduceMotion: true,
          groups: _groups,
          extensions: extensions,
          onSessionAction: (String id, SessionAction action) =>
              log.add('${action.name}:$id'),
          onOpenMyRelay: () {},
          onTasks: () {},
          onProjects: () {},
          onPlanning: () {},
          onOpenSession: (String id) => log.add('open:$id'),
          onNewSession: () {},
          search: (String q) async => const <ChatSearchHit>[],
          onOpenHit: (ChatSearchHit hit) {},
          timeLabel: (DateTime at) => '12:00',
        ),
      ),
    ),
  );
  return log;
}

void main() {
  // Ширина подписей — по настоящим шрифтам приложения.
  setUpAll(loadAppFonts);

  for (final scale in <double>[1, 1.3, 1.5, 2]) {
    testWidgets('шрифт ${scale}x: пункты меню не обрезаны, меню в экране',
        (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _pump(tester);
      for (final id in <String>['a', 'p']) {
        await tester.scrollUntilVisible(
          find.byKey(Key('chat-session:$id')),
          100,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.longPress(find.byKey(Key('chat-session:$id')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final menu = tester.getRect(find.byKey(const Key('session-menu')));
        expect(menu.left, greaterThanOrEqualTo(0));
        expect(menu.right, lessThanOrEqualTo(320));
        for (final label in <String>[
          'Переименовать',
          if (id == 'p') 'Открепить' else 'Закрепить',
          'Удалить',
        ]) {
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(
              of: find.byKey(const Key('session-menu')),
              matching: find.text(label),
            ),
          );
          expect(paragraph.didExceedMaxLines, isFalse, reason: label);
          {
            // Помещается в одну строку — без переноса посреди слова.
            expect(
              paragraph.size.height,
              lessThan(16 * scale * 1.3 * 1.5),
              reason: label,
            );
          }
        }
        if (scale == 1) {
          expect(menu.width, 236, reason: 'обычный шрифт — как в макете');
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
      }
    });
  }

  testWidgets('копия строки над меню не звучит для диктора второй раз',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, size: const Size(360, 900));
    await tester.longPress(find.byKey(const Key('chat-session:a')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-menu-lifted')), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Отметить приход 318')),
      findsOneWidget,
      reason: 'только «Действия с сессией «…»»',
    );
    expect(
      find.bySemanticsLabel('Действия с сессией «Отметить приход 318»'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('компьютер: после меню с «⋯» фокус — снова на строке',
      (tester) async {
    await _pump(tester, size: const Size(312, 900), wide: true);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const Key('chat-session:a'))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-more-session:a')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-menu')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-menu')), findsNothing);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'session-row',
      reason: 'фокус не ушёл в начало панели',
    );
    // Правая кнопка и нажатие мимо — так же.
    await tester.tap(
      find.byKey(const Key('chat-session:b')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(300, 880));
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'session-row');
  });

  for (final key in <(String, LogicalKeyboardKey, bool)>[
    ('Shift+F10', LogicalKeyboardKey.f10, true),
    ('клавиша меню', LogicalKeyboardKey.contextMenu, false),
  ]) {
    testWidgets('узкая панель: ${key.$1} на строке открывает меню',
        (tester) async {
      final log = await _pump(tester, size: const Size(360, 900));
      expect(find.byKey(const Key('chat-more-session:a')), findsNothing);
      final row = tester.widget<InkWell>(
        find.byKey(const Key('chat-session:a')),
      );
      row.focusNode!.requestFocus();
      await tester.pump();
      if (key.$3) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key.$2);
      if (key.$3) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('session-menu')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('session-menu')), findsNothing);
      expect(log, isEmpty);
    });
  }

  testWidgets('«Переименовать»: 320×640, шрифт 2x, открытая клавиатура',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.reset);
    late BuildContext host;
    await tester.pumpWidget(
      MaterialApp(
        theme: AssistantTheme.dark(),
        home: Builder(
          builder: (BuildContext context) {
            host = context;
            return const Scaffold();
          },
        ),
      ),
    );
    final result = showRenameSessionDialog(host, current: 'Сверка прихода');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('rename-field')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('rename-field')), 'Приход');
    await tester.ensureVisible(find.byKey(const Key('rename-save')));
    await tester.tap(find.byKey(const Key('rename-save')));
    await tester.pumpAndSettle();
    expect(await result, 'Приход');
  });

  testWidgets('«Переименовать»: длинное название — по видимым знакам',
      (tester) async {
    late BuildContext host;
    await tester.pumpWidget(
      MaterialApp(
        theme: AssistantTheme.dark(),
        home: Builder(
          builder: (BuildContext context) {
            host = context;
            return const Scaffold();
          },
        ),
      ),
    );
    final result = showRenameSessionDialog(host, current: '📦' * 70);
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.byKey(const Key('rename-field')),
    );
    expect(field.controller!.text, '📦' * 60, reason: 'не режет знак');
    await tester.tap(find.byKey(const Key('rename-save')));
    await tester.pumpAndSettle();
    expect(await result, '📦' * 60);
  });

  testWidgets('расширения: состояние с точкой прижато к правому краю',
      (tester) async {
    await _pump(
      tester,
      size: const Size(360, 900),
      extensions: <ExtensionEntry>[
        ExtensionEntry(
          id: 'warehouse',
          title: 'Склад',
          icon: Icons.inventory_2_outlined,
          status: 'на связи',
          statusColor: AppPalette.dark.success,
          dot: true,
          onTap: () {},
        ),
        ExtensionEntry(
          id: 'passwords',
          title: 'Пароли',
          icon: Icons.lock_outline,
          status: 'заперт',
          dot: true,
          dotColor: AppPalette.dark.faint,
          onTap: () {},
        ),
      ],
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('drawer-extension-passwords')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    for (final id in <String>['warehouse', 'passwords']) {
      final row = tester.getRect(find.byKey(Key('drawer-extension-$id')));
      final status =
          tester.getRect(find.byKey(Key('drawer-extension-status-$id')));
      final dot = tester.getRect(find.byKey(Key('drawer-extension-dot-$id')));
      expect(
        status.right,
        moreOrLessEquals(row.right - 12, epsilon: 0.5),
        reason: '$id: подпись у правого края (поле 12, сетка 4)',
      );
      expect(dot.right, moreOrLessEquals(status.left - 8, epsilon: 0.5));
      expect(dot.left, greaterThan(row.center.dx), reason: id);
    }
  });
}
