// Левое меню (макет «Д»): шапка «Связной» с версией, карточка «Мой
// Связной», разделы, дерево расширений со статусами, недавние сессии,
// поиск по сессиям, который растягивается и прячет «+», «Отмена» и Esc,
// встаёт над клавиатурой, подсветка совпадения. Секреты из карточек
// «Паролей» поиск не находит.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/shell/relay_drawer.dart';
import 'package:local_assistant/core/app_info.dart';
import 'package:local_assistant/core/chats/chat_book.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/chats/chat_search.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
import 'package:local_assistant/core/models/secure_card.dart';
import 'package:local_assistant/core/services/clock.dart';

final _now = DateTime(2026, 11, 9, 12, 40);

final class _Calls {
  final List<String> log = <String>[];
}

Future<_Calls> _pump(
  WidgetTester tester, {
  List<ExtensionEntry>? extensions,
  Future<List<ChatSearchHit>> Function(String)? search,
  Size size = const Size(316, 844),
  bool wide = false,
  VoidCallback? onCollapse,
}) async {
  final calls = _Calls();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.dark(),
      home: Scaffold(
        // Как выдвижная панель: Scaffold не сжимает её под клавиатуру.
        resizeToAvoidBottomInset: false,
        body: RelayDrawer(
          wide: wide,
          onCollapse: onCollapse,
          reduceMotion: true,
          sessions: <SessionEntry>[
            const SessionEntry(
              id: 'session:a',
              title: 'Отметить приход 318',
              time: '12:40',
              itemKey: Key('chat-session:a'),
              dotKey: Key('chat-unread-session:a'),
              active: true,
            ),
            const SessionEntry(
              id: 'session:1',
              title: 'Сверить накладные',
              time: 'вчера',
              itemKey: Key('chat-session:1'),
              dotKey: Key('chat-unread-session:1'),
              unread: true,
            ),
          ],
          extensions: extensions ??
              <ExtensionEntry>[
                ExtensionEntry(
                  id: 'passwords',
                  title: 'Пароли',
                  status: 'заперт',
                  onTap: () => calls.log.add('passwords'),
                ),
                ExtensionEntry(
                  id: 'warehouse',
                  title: 'Склад',
                  status: 'на связи',
                  statusColor: AssistantColors.success,
                  dot: true,
                  onTap: () => calls.log.add('warehouse'),
                ),
              ],
          onOpenMyRelay: () => calls.log.add('my-relay'),
          onTasks: () => calls.log.add('tasks'),
          onProjects: () => calls.log.add('projects'),
          onPlanning: () => calls.log.add('planning'),
          onOpenSession: (String id) => calls.log.add('open:$id'),
          onNewSession: () => calls.log.add('new'),
          search: search ?? (String q) async => const <ChatSearchHit>[],
          onOpenHit: (ChatSearchHit hit) => calls.log.add('hit:${hit.chatId}'),
          timeLabel: (DateTime at) => sessionTimeLabel(at, _now),
        ),
      ),
    ),
  );
  return calls;
}

void main() {
  testWidgets('карточка, разделы, расширения и сессии ведут куда надо',
      (tester) async {
    final calls = await _pump(tester);
    expect(find.text('Мой Связной'), findsOneWidget);
    expect(find.byKey(const Key('nav-settings')), findsNothing);
    expect(find.byIcon(Icons.settings_outlined), findsNothing);
    expect(
      tester
          .widget<Text>(
            find.byKey(const Key('drawer-extension-status-passwords')),
          )
          .data,
      'заперт',
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const Key('drawer-extension-status-warehouse')),
          )
          .data,
      'на связи',
    );
    expect(find.byKey(const Key('chat-unread-session:1')), findsOneWidget);
    for (final key in <String>[
      'drawer-my-relay',
      'nav-tasks',
      'nav-projects',
      'nav-planning',
      'drawer-extension-passwords',
      'drawer-extension-warehouse',
      'chat-session:1',
      'new-session',
    ]) {
      await tester.tap(find.byKey(Key(key)));
    }
    expect(calls.log, <String>[
      'my-relay',
      'tasks',
      'projects',
      'planning',
      'passwords',
      'warehouse',
      'open:session:1',
      'new',
    ]);
    // Строки сессий — не ниже 44 px.
    expect(
      tester.getSize(find.byKey(const Key('chat-session:a'))).height,
      greaterThanOrEqualTo(44),
    );
  });

  testWidgets('дерево расширений сворачивается', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const Key('drawer-extensions-toggle')));
    await tester.pump();
    expect(find.byKey(const Key('drawer-extension-passwords')), findsNothing);
  });

  testWidgets('без расширений — без раздела', (tester) async {
    await _pump(tester, extensions: const <ExtensionEntry>[]);
    expect(find.text('Расширения'), findsNothing);
  });

  testWidgets('шапка «Связной» с версией — и на телефоне', (tester) async {
    await _pump(tester);
    expect(find.byKey(const ValueKey<String>('app-name')), findsOneWidget);
    expect(find.text(AppInfo.name), findsOneWidget);
    final version = find.byKey(const ValueKey<String>('app-version'));
    expect(tester.widget<Text>(version).data, AppInfo.version);
    expect(find.bySemanticsLabel('Версия ${AppInfo.version}'), findsOneWidget);
    // Версия — рядом с названием, в той же строке, над «Мой Связной».
    final name = tester.getRect(find.byKey(const ValueKey<String>('app-name')));
    final ver = tester.getRect(version);
    expect(ver.left, greaterThan(name.right));
    expect(ver.center.dy, moreOrLessEquals(name.center.dy, epsilon: 4));
    expect(
      name.bottom,
      lessThanOrEqualTo(
        tester.getRect(find.byKey(const Key('drawer-my-relay'))).top,
      ),
    );
    // «Свернуть панель» — только на компьютере.
    expect(find.byKey(const Key('sidebar-collapse')), findsNothing);
    var collapsed = 0;
    await _pump(tester, wide: true, onCollapse: () => collapsed++);
    expect(find.byKey(const ValueKey<String>('app-version')), findsOneWidget);
    await tester.tap(find.byKey(const Key('sidebar-collapse')));
    expect(collapsed, 1);
  });

  testWidgets('«+» — новая сессия: только значок, треть строки',
      (tester) async {
    final calls = await _pump(tester);
    final button = find.byKey(const Key('new-session'));
    expect(
      find.descendant(of: button, matching: find.byIcon(Icons.add)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: button, matching: find.byType(Text)),
      findsNothing,
    );
    expect(find.text('Сессия'), findsNothing);
    expect(find.byTooltip('Новая сессия'), findsOneWidget);
    expect(find.bySemanticsLabel('Новая сессия'), findsOneWidget);
    final row = tester.getRect(find.byKey(const Key('session-search-box')));
    final rect = tester.getRect(button);
    // Поле — две трети, «+» — треть за промежутком 8.
    expect(rect.width, moreOrLessEquals(row.width / 2, epsilon: 1));
    expect(rect.height, row.height);
    expect(rect.height, greaterThanOrEqualTo(44));
    await tester.tap(button);
    expect(calls.log, <String>['new']);
  });

  testWidgets('поиск с клавиатурой: строка поиска — над ней, результаты видны',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await _pump(
      tester,
      size: const Size(320, 640),
      search: (String q) async => <ChatSearchHit>[
        for (var i = 0; i < 6; i++)
          ChatSearchHit(
            chatId: 'session:$i',
            title: 'Сессия $i',
            snippet: 'накладные $i',
            matchStart: 0,
            matchEnd: 9,
            at: _now,
          ),
      ],
    );
    await tester.tap(find.byKey(const Key('session-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('session-search')), 'наклад');
    await tester.pump(RelayDrawer.searchDelay);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final box = tester.getRect(find.byKey(const Key('session-search-box')));
    expect(box.bottom, lessThanOrEqualTo(640 - 300));
    expect(box.top, greaterThan(0));
    expect(
      tester.getRect(find.byKey(const Key('session-search-cancel'))).bottom,
      lessThanOrEqualTo(640 - 300),
    );
    // Шапка, «Мой Связной» и разделы уступили место результатам.
    expect(find.byKey(const ValueKey<String>('app-name')), findsNothing);
    expect(find.byKey(const Key('drawer-my-relay')), findsNothing);
    final hit = find.byKey(const Key('search-hit-session:0'));
    expect(hit.hitTestable(), findsOneWidget);
    expect(tester.getRect(hit).bottom, lessThanOrEqualTo(box.top));
    // Клавиатура скрылась — всё на месте.
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('app-name')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('поиск растягивается, прячет «+», «Отмена» и Esc',
      (tester) async {
    await _pump(tester);
    final box = find.byKey(const Key('session-search-box'));
    final narrowWidth = tester.getSize(box).width;
    expect(find.byKey(const Key('new-session')).hitTestable(), findsOneWidget);
    expect(find.byKey(const Key('session-search-cancel')), findsNothing);

    await tester.tap(find.byKey(const Key('session-search')));
    await tester.pumpAndSettle();
    expect(tester.getSize(box).width, greaterThan(narrowWidth));
    expect(find.byKey(const Key('new-session')).hitTestable(), findsNothing);
    expect(find.byKey(const Key('session-search-cancel')), findsOneWidget);

    await tester.tap(find.byKey(const Key('session-search-cancel')));
    await tester.pumpAndSettle();
    expect(tester.getSize(box).width, narrowWidth);
    expect(find.byKey(const Key('new-session')).hitTestable(), findsOneWidget);

    await tester.tap(find.byKey(const Key('session-search')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-search-cancel')), findsNothing);
  });

  testWidgets('раскрытый поиск: поле во всю строку, «Отмена» у края',
      (tester) async {
    await _pump(tester, size: const Size(390, 844));
    final box = find.byKey(const Key('session-search-box'));
    // Нажатие в рамку, но мимо строки текста, тоже ставит курсор.
    final closed = tester.getRect(box);
    await tester.tapAt(Offset(closed.left + 40, closed.top + 4));
    await tester.pumpAndSettle();
    final field =
        tester.widget<TextField>(find.byKey(const Key('session-search')));
    expect(field.focusNode!.hasFocus, isTrue);
    expect(
      tester.getSize(find.byKey(const Key('session-search'))).height,
      greaterThanOrEqualTo(44),
    );

    final open = tester.getRect(box);
    final cancel =
        tester.getRect(find.byKey(const Key('session-search-cancel')));
    expect(open.right - cancel.right, lessThan(12), reason: '«Отмена» справа');
    expect(
      tester.getSize(find.byKey(const Key('session-search'))).width,
      greaterThan(open.width * 0.6),
      reason: 'поле забирает почти всю строку',
    );
    final decoration =
        tester.widget<AnimatedContainer>(box).decoration! as BoxDecoration;
    expect(
      (decoration.border! as Border).top.color,
      AssistantColors.borderFocus,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('«Найдено в сессиях · N», подсветка, переход и без секретов',
      (tester) async {
    final store = InMemoryChatStore();
    final book = ChatBook(store: store, clock: FixedClock(_now));
    await book.load();
    final s = book.currentId;
    book
      ..append(
        s,
        ChatMessage(
          id: book.newMessageId(),
          author: ChatAuthor.persona,
          personaId: 'rio',
          text: 'Приход 318 ждёт отметки, нужно подтверждение',
          timestamp: _now,
        ),
      )
      ..append(
        s,
        ChatMessage(
          id: book.newMessageId(),
          author: ChatAuthor.persona,
          personaId: 'rio',
          text: 'Пароль CANARY-8c1e приход показан',
          timestamp: _now,
          secureCard: const SecureCardRequest(kind: SecureCardKind.reveal),
        ),
      );
    final calls = await _pump(
      tester,
      search: (String q) => book.search(q),
    );
    await tester.tap(find.byKey(const Key('session-search')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('session-search')), 'ПРИХОД');
    await tester.pump(RelayDrawer.searchDelay);
    await tester.pumpAndSettle();
    expect(find.text('Найдено в сессиях · 1'), findsOneWidget);
    expect(find.text('Недавние сессии'), findsNothing);
    // Справа — время сессии, а не имя помощника.
    expect(
      find.descendant(
        of: find.byKey(Key('search-hit-$s')),
        matching: find.text(sessionTimeLabel(_now, _now)),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(Key('search-hit-$s')),
        matching: find.text('Лиорио'),
      ),
      findsNothing,
    );
    final snippet = tester.widget<RichText>(
      find.descendant(
        of: find.byKey(Key('search-snippet-$s')),
        matching: find.byType(RichText),
      ),
    );
    TextSpan? match;
    snippet.text.visitChildren((InlineSpan span) {
      if (span is TextSpan && span.text == 'Приход') match = span;
      return match == null;
    });
    expect(match, isNotNull, reason: 'совпадение — отдельным куском');
    // Подсветка — цвета Ноды, как `mark` в макете.
    expect(match!.style!.backgroundColor, AssistantColors.markBg);
    expect(match!.style!.color, AssistantColors.mark);
    expect(find.textContaining('CANARY', findRichText: true), findsNothing);

    await tester.enterText(find.byKey(const Key('session-search')), 'CANARY');
    await tester.pump(RelayDrawer.searchDelay);
    await tester.pumpAndSettle();
    expect(find.text('Найдено в сессиях · 0'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('session-search')), 'приход');
    await tester.pump(RelayDrawer.searchDelay);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('search-hit-$s')));
    await tester.pumpAndSettle();
    expect(calls.log, <String>['hit:$s']);
    expect(find.text('Недавние сессии'), findsOneWidget, reason: 'поиск снят');
  });

  testWidgets('320 px и шрифт 2x: без переполнения', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(tester, size: const Size(264, 640));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('session-search')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  test('подписи времени', () {
    expect(sessionTimeLabel(DateTime(2026, 11, 9, 9, 5), _now), '09:05');
    expect(sessionTimeLabel(DateTime(2026, 11, 8, 23), _now), 'вчера');
    expect(sessionTimeLabel(DateTime(2026, 11, 5), _now), 'чт');
    expect(sessionTimeLabel(DateTime(2026, 10, 9), _now), '9 окт.');
  });
}
