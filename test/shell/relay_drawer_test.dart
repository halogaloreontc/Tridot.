// Левое меню (макет «Д»): карточка «Мой Связной», разделы, дерево
// расширений со статусами, недавние сессии, поиск по сессиям, который
// растягивается и прячет «+ Сессия», «Отмена» и Esc, подсветка совпадения.
// Секреты из карточек «Паролей» поиск не находит.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/shell/relay_drawer.dart';
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
}) async {
  final calls = _Calls();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.dark(),
      home: Scaffold(
        body: RelayDrawer(
          wide: wide,
          reduceMotion: true,
          sessions: <SessionEntry>[
            const SessionEntry(
              id: 'main',
              title: 'Главный',
              time: '12:40',
              itemKey: Key('chat-main'),
              dotKey: Key('chat-unread-main'),
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
      tester.getSize(find.byKey(const Key('chat-main'))).height,
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

  testWidgets('поиск растягивается, прячет «+ Сессия», «Отмена» и Esc',
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
    book
      ..append(
        ChatThread.mainId,
        ChatMessage(
          id: book.newMessageId(),
          author: ChatAuthor.persona,
          personaId: 'rio',
          text: 'Приход 318 ждёт отметки, нужно подтверждение',
          timestamp: _now,
        ),
      )
      ..append(
        ChatThread.mainId,
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
        of: find.byKey(const Key('search-hit-main')),
        matching: find.text(sessionTimeLabel(_now, _now)),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('search-hit-main')),
        matching: find.text('Лиорио'),
      ),
      findsNothing,
    );
    final snippet = tester.widget<RichText>(
      find.descendant(
        of: find.byKey(const Key('search-snippet-main')),
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
    await tester.tap(find.byKey(const Key('search-hit-main')));
    await tester.pumpAndSettle();
    expect(calls.log, <String>['hit:main']);
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
