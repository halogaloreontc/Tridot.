// Левое меню (макет «Д»): шапка «Tridot» с версией, карточка «Мой
// Связной», разделы, дерево расширений со статусами, недавние сессии,
// поиск по сессиям, который растягивается и прячет «+», «Отмена» и Esc,
// встаёт над клавиатурой, подсветка совпадения. Секреты из карточек
// «Паролей» поиск не находит.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/shell/relay_drawer.dart';
import 'package:local_assistant/app/widgets/personas_section.dart';
import 'package:local_assistant/core/app_info.dart';
import 'package:local_assistant/core/chats/chat_book.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/chats/chat_search.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
import 'package:local_assistant/core/models/secure_card.dart';
import 'package:local_assistant/core/personas/persona.dart';
import 'package:local_assistant/core/services/clock.dart';

final _now = DateTime(2026, 11, 9, 12, 40);

final _groups = <SessionGroupEntry>[
  const SessionGroupEntry(
    id: 'today',
    label: 'Сегодня',
    entries: <SessionEntry>[
      SessionEntry(
        id: 'session:a',
        title: 'Отметить приход 318',
        time: '12:40',
        itemKey: Key('chat-session:a'),
        dotKey: Key('chat-unread-session:a'),
        active: true,
        canAct: true,
        canRename: true,
      ),
    ],
  ),
  const SessionGroupEntry(
    id: 'yesterday',
    label: 'Вчера',
    entries: <SessionEntry>[
      SessionEntry(
        id: 'session:1',
        title: 'Сверить накладные',
        time: '18:20',
        itemKey: Key('chat-session:1'),
        dotKey: Key('chat-unread-session:1'),
        unread: true,
        canAct: true,
        canRename: true,
      ),
    ],
  ),
];

SessionEntry _entry(
  String id, {
  String? title,
  bool active = false,
  bool pinned = false,
  bool acts = true,
  String? preview,
  Persona? persona,
}) =>
    SessionEntry(
      id: 'session:$id',
      title: title ?? 'Сессия $id',
      time: '12:00',
      itemKey: Key('chat-session:$id'),
      dotKey: Key('chat-unread-session:$id'),
      active: active,
      pinned: pinned,
      canAct: acts,
      canRename: acts,
      preview: preview,
      persona: persona,
    );

SessionGroupEntry _group(String id, String label, List<SessionEntry> e) =>
    SessionGroupEntry(id: id, label: label, entries: e);

final _rich = <SessionGroupEntry>[
  _group('pinned', 'Закреплённые', <SessionEntry>[
    _entry(
      'p',
      title: 'Еженедельный отчёт',
      pinned: true,
      preview: 'Сводка за неделю готова',
      persona: Personas.noda,
    ),
  ]),
  _group('today', 'Сегодня', <SessionEntry>[
    _entry(
      'a',
      title: 'Отметить приход 318',
      active: true,
      preview: 'Принят, но не проведён ни в SV, ни в 1С',
      persona: Personas.liorio,
    ),
  ]),
  _group('yesterday', 'Вчера', <SessionEntry>[
    _entry('1', title: 'Сверить накладные', preview: 'Расхождение в двух'),
  ]),
  _group('week', 'На неделе', <SessionEntry>[
    _entry('w', preview: 'Пересчитано 412 позиций из 530'),
  ]),
  _group('earlier', 'Ранее', <SessionEntry>[
    _entry('e', preview: 'Продление до марта'),
    _entry('e2', preview: 'Добавила перчатки'),
  ]),
];

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
  List<SessionGroupEntry>? groups,
  SectionCounts counts = const SectionCounts(),
  List<Persona>? assistants,
  List<ProjectEntry> projects = const <ProjectEntry>[],
  String? activeSection,
  ThemeData? theme,
}) async {
  final calls = _Calls();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? AssistantTheme.dark(),
      home: Scaffold(
        // Как выдвижная панель: Scaffold не сжимает её под клавиатуру.
        resizeToAvoidBottomInset: false,
        body: RelayDrawer(
          activeSection: activeSection,
          wide: wide,
          onCollapse: onCollapse,
          reduceMotion: true,
          groups: groups ?? _groups,
          counts: counts,
          onSessionAction: (String id, SessionAction action) =>
              calls.log.add('${action.name}:$id'),
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
                  statusColor: AppPalette.dark.success,
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
          assistants: assistants,
          projects: projects,
          onOpenProject: (String id) => calls.log.add('project:$id'),
          onNewProject: () => calls.log.add('new-project'),
        ),
      ),
    ),
  );
  return calls;
}

void main() {
  testWidgets('знак приложения — три точки цветами Связной, Лиорио и Ноды',
      (tester) async {
    // В шапке меню знака нет: он в «Настройки → О приложении» (ADR-027).
    await _pump(tester);
    expect(find.byKey(const ValueKey<String>('app-glyph')), findsNothing);
    await tester.pumpWidget(
      MaterialApp(
        theme: AssistantTheme.dark(),
        home: const Scaffold(body: Center(child: RelayGlyph())),
      ),
    );
    final glyph = find.byKey(const ValueKey<String>('app-glyph'));
    expect(glyph, findsOneWidget);
    final paint = tester.widget<CustomPaint>(
      find.descendant(of: glyph, matching: find.byType(CustomPaint)),
    );
    expect(paint.painter, isA<RelayGlyphPainter>());
    expect((paint.painter! as RelayGlyphPainter).colors, <Color>[
      AppPalette.dark.sado,
      AppPalette.dark.liorio,
      AppPalette.dark.noda,
    ]);
    // Три закрашенные точки на сетке 24: (5,12), (12,12), (19,12), r = 3.
    final recorder = _CircleCanvas();
    const RelayGlyphPainter().paint(recorder, const Size(24, 24));
    expect(recorder.circles, <(Offset, double, int)>[
      (const Offset(5, 12), 3, AppPalette.dark.sado.toARGB32()),
      (const Offset(12, 12), 3, AppPalette.dark.liorio.toARGB32()),
      (const Offset(19, 12), 3, AppPalette.dark.noda.toARGB32()),
    ]);
    // Светлая палитра — свои точки; смена палитры перерисовывает знак.
    const light = RelayGlyphPainter(palette: AppPalette.light);
    expect(light.colors.first, AppPalette.light.sado);
    expect(light.shouldRepaint(const RelayGlyphPainter()), isTrue);
    expect(
      const RelayGlyphPainter().shouldRepaint(const RelayGlyphPainter()),
      isFalse,
    );
  });

  testWidgets('знаки на карточке «Мой …» — только активные помощники',
      (tester) async {
    Iterable<String> shown() => <String>[
          for (final id in <String>['sado', 'rio', 'noda'])
            if (find
                .byKey(ValueKey<String>('relay-avatar-$id'))
                .evaluate()
                .isNotEmpty)
              id,
        ];
    double width() => tester
        .getSize(find.byKey(const ValueKey<String>('relay-avatars')))
        .width;

    await _pump(tester, assistants: Personas.all);
    expect(shown(), <String>['sado', 'rio', 'noda']);
    final trio = width();
    await _pump(tester, assistants: <Persona>[Personas.sado, Personas.noda]);
    expect(shown(), <String>['sado', 'noda']);
    expect(width(), lessThan(trio));
    await _pump(tester, assistants: <Persona>[Personas.sado]);
    expect(shown(), <String>['sado']);
    expect(width(), 36);
  });

  testWidgets('карточка, разделы, расширения и сессии ведут куда надо',
      (tester) async {
    final calls = await _pump(tester);
    expect(find.text(AppInfo.hubName), findsOneWidget);
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

  testWidgets('«Мой Связной»: телефон — 68 px, компьютер — 60, имя 16/600',
      (tester) async {
    for (final wide in <bool>[false, true]) {
      await _pump(tester, wide: wide, size: Size(wide ? 312 : 360, 900));
      final card = find.byKey(const Key('drawer-my-relay'));
      // Первая строка сгруппированной панели разделов (ADR-027).
      expect(
        tester.getSize(card).height,
        greaterThanOrEqualTo(wide ? 60 : 68),
      );
      final title = tester.widget<Text>(
        find.descendant(of: card, matching: find.text(AppInfo.hubName)),
      );
      // «Мой Связной» целиком — шрифтом текста: шрифт названия — только
      // у «Tridot» в шапке (ADR-021).
      final style = title.textSpan!.style!;
      expect(style.fontSize, 16);
      expect(style.fontWeight, FontWeight.w600);
    }
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

  testWidgets('шапка «Tridot» крупно, без версии — и на телефоне',
      (tester) async {
    await _pump(tester);
    expect(find.byKey(const ValueKey<String>('app-name')), findsOneWidget);
    expect(find.text(AppInfo.name), findsOneWidget);
    // Версия — в «Настройки → О приложении» (ADR-027).
    expect(find.byKey(const ValueKey<String>('app-version')), findsNothing);
    final name = tester.widget<Text>(
      find.byKey(const ValueKey<String>('app-name')),
    );
    expect(name.style!.fontSize, 26);
    expect(
      tester.getRect(find.byKey(const ValueKey<String>('app-name'))).bottom,
      lessThanOrEqualTo(
        tester.getRect(find.byKey(const Key('drawer-my-relay'))).top,
      ),
    );
    // «Свернуть панель» — только на компьютере.
    expect(find.byKey(const Key('sidebar-collapse')), findsNothing);
    var collapsed = 0;
    await _pump(tester, wide: true, onCollapse: () => collapsed++);
    await tester.tap(find.byKey(const Key('sidebar-collapse')));
    expect(collapsed, 1);
  });

  testWidgets('«+» — новая сессия: только значок, кнопка 48 тональная',
      (tester) async {
    final calls = await _pump(tester);
    final button = find.byKey(const Key('new-session'));
    expect(
      find.descendant(of: button, matching: find.byIcon(Icons.edit_square)),
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
    // «+» — квадратная кнопка 48, поиск забирает остальное (ADR-027).
    expect(rect.width, moreOrLessEquals(48, epsilon: 1));
    expect(row.width, greaterThan(rect.width * 3));
    expect(rect.height, row.height);
    // Тональная: заливка листа, значок акцентом — не сплошной акцент.
    expect(
      tester
          .widget<Material>(
            find.ancestor(of: button, matching: find.byType(Material)).first,
          )
          .color,
      AppPalette.dark.workspace,
    );
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
      greaterThan(open.width * 0.5),
      reason: 'поле забирает почти всю строку',
    );
    // Поиск — заливкой листа (ADR-027); в фокусе — рамка 1.5 акцентом,
    // чтобы фокус был виден и с клавиатуры.
    final decoration =
        tester.widget<AnimatedContainer>(box).decoration! as BoxDecoration;
    expect((decoration.border! as Border).top.color, AppPalette.dark.accent);
    expect((decoration.border! as Border).top.width, 1.5);
    expect(decoration.color, AppPalette.dark.workspace);
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
    expect(find.text('Сегодня'), findsNothing);
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
    expect(match!.style!.backgroundColor, AppPalette.dark.markBg);
    expect(match!.style!.color, AppPalette.dark.mark);
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
    expect(find.text('Сегодня'), findsOneWidget, reason: 'поиск снят');
  });

  testWidgets('320 px и шрифт 2x: без переполнения', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(
      tester,
      size: const Size(264, 640),
      groups: _rich,
      counts: const SectionCounts(tasks: 12, overdue: 3, projects: 4),
    );
    expect(tester.takeException(), isNull);
    await tester.longPress(find.byKey(const Key('chat-session:p')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    await _pump(tester, size: const Size(312, 640), wide: true, groups: _rich);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('session-search')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('разделы: счётчики и «N просрочена» с верным числом',
      (tester) async {
    for (final (n, word) in <(int, String)>[
      (1, 'просрочена'),
      (2, 'просрочены'),
      (5, 'просрочено'),
      (21, 'просрочена'),
    ]) {
      await _pump(
        tester,
        counts: SectionCounts(tasks: 30, overdue: n, projects: 4, planning: 2),
      );
      expect(find.text('$n $word'), findsOneWidget, reason: '$n');
      final alert =
          tester.widget<Text>(find.byKey(const Key('nav-tasks-alert')));
      expect(alert.style!.color, AppPalette.dark.danger);
    }
    expect(
      find.descendant(
        of: find.byKey(const Key('nav-projects-count')),
        matching: find.text('4'),
      ),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Задачи, 30, 21 просрочена'), findsOneWidget);
    expect(find.bySemanticsLabel('Планирование, 2'), findsOneWidget);
    // Нечего считать — без счётчика и без строки просрочки.
    await _pump(tester, counts: const SectionCounts(tasks: 0));
    expect(find.byKey(const Key('nav-tasks-count')), findsOneWidget);
    expect(find.byKey(const Key('nav-tasks-alert')), findsNothing);
    expect(find.byKey(const Key('nav-projects-count')), findsNothing);
    expect(find.byKey(const Key('nav-planning-count')), findsNothing);
    // Строки разделов — во всю ширину и не ниже 48 (поправка «плотнее»).
    final row = tester.getRect(find.byKey(const Key('nav-tasks')));
    expect(row.height, greaterThanOrEqualTo(48));
    expect(
      tester.getRect(find.byKey(const Key('nav-projects'))).top,
      greaterThan(row.bottom - 1),
      reason: 'строкой под «Задачами», а не в ряд',
    );
  });

  testWidgets('выбранный раздел: мягкая заливка с отступом 4 и радиусом 8',
      (tester) async {
    for (final (theme, palette) in <(ThemeData, AppPalette)>[
      (AssistantTheme.light(), AppPalette.light),
      (AssistantTheme.dark(), AppPalette.dark),
    ]) {
      for (final id in <String>['tasks', 'projects']) {
        await _pump(tester, activeSection: id, theme: theme);
        // Смена темы — с переходом: дождаться конца.
        await tester.pumpAndSettle();
        final ink = find.byKey(Key('nav-$id'));
        final fill = find.ancestor(of: ink, matching: find.byType(Material));
        final material = tester.widget<Material>(fill.first);
        expect(material.color, palette.selection, reason: id);
        expect(material.borderRadius, BorderRadius.circular(8), reason: id);
        // Отступ 4 от краёв группы (её край — край «Мой Связной»).
        final group = tester.getRect(find.byKey(const Key('drawer-my-relay')));
        final rect = tester.getRect(fill.first);
        expect(rect.left - group.left, 4, reason: id);
        expect(group.right - rect.right, 4, reason: id);
        // У «Проектов» заливка — и под «+».
        if (id == 'projects') {
          final plus = tester.getRect(find.byKey(const Key('project-new')));
          expect(rect.left <= plus.left && rect.right >= plus.right, isTrue);
          expect(rect.top <= plus.top && rect.bottom >= plus.bottom, isTrue);
        }
        // Другие разделы — без заливки.
        final other = id == 'tasks' ? 'planning' : 'tasks';
        final rest = tester.widget<Material>(
          find
              .ancestor(
                of: find.byKey(Key('nav-$other')),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(rest.type, MaterialType.transparency, reason: other);
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('группы: закреплённые — только если есть; превью и знак',
      (tester) async {
    await _pump(tester, groups: _rich, size: const Size(360, 1400));
    for (final key in <String>[
      'drawer-group-pinned',
      'drawer-group-today',
      'drawer-group-yesterday',
      'drawer-group-week',
      'drawer-group-earlier',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget, reason: key);
    }
    expect(find.text('Закреплённые'), findsOneWidget);
    expect(find.text('Сводка за неделю готова'), findsOneWidget);
    // Точка того, кто ответил последним (ADR-027).
    final mark = find.descendant(
      of: find.byKey(const Key('chat-session:p')),
      matching: find.byType(PersonaDot),
    );
    expect(tester.widget<PersonaDot>(mark).persona, Personas.noda);
    // Порядок: «Мой Связной», разделы, закреплённые, дни, «Расширения».
    double top(String key) => tester.getRect(find.byKey(Key(key))).top;
    expect(top('drawer-my-relay'), lessThan(top('nav-tasks')));
    expect(top('nav-planning'), lessThan(top('drawer-group-pinned')));
    expect(top('drawer-group-pinned'), lessThan(top('drawer-group-today')));
    expect(top('drawer-group-today'), lessThan(top('drawer-group-yesterday')));
    expect(top('drawer-group-week'), lessThan(top('drawer-group-earlier')));
    expect(top('drawer-group-earlier'), lessThan(top('drawer-extensions')));
    // Строка сессии — не ниже 60, превью — одной строкой.
    expect(
      tester.getSize(find.byKey(const Key('chat-session:p'))).height,
      greaterThanOrEqualTo(60),
    );
    // Края прокрутки — без затемнения-виньетки: список обрезается ровно.
    expect(find.byKey(const Key('drawer-fade-top')), findsNothing);
    expect(find.byKey(const Key('drawer-fade-bottom')), findsNothing);
    expect(
      find.descendant(
        of: find.byType(RelayDrawer),
        matching: find.byWidgetPredicate(
          (Widget w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).gradient != null,
        ),
      ),
      findsNothing,
    );

    await _pump(tester);
    expect(find.text('Закреплённые'), findsNothing);
    expect(find.byKey(const Key('drawer-group-week')), findsNothing);
  });

  testWidgets('компьютер: «Вчера», «На неделе», «Ранее» свёрнуты со счётом',
      (tester) async {
    await _pump(tester, groups: _rich, wide: true, size: const Size(312, 900));
    expect(find.byKey(const Key('chat-session:p')), findsOneWidget);
    expect(find.byKey(const Key('chat-session:a')), findsOneWidget);
    expect(find.byKey(const Key('chat-session:1')), findsNothing);
    expect(find.byKey(const Key('chat-session:w')), findsNothing);
    expect(find.byKey(const Key('chat-session:e')), findsNothing);
    expect(find.bySemanticsLabel('Ранее, 2'), findsOneWidget);
    // «Расширения» видны без прокрутки.
    expect(
      find.byKey(const Key('drawer-extension-warehouse')).hitTestable(),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('drawer-group-earlier')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-session:e')), findsOneWidget);
    expect(find.byKey(const Key('chat-session:e2')), findsOneWidget);
    await tester.tap(find.byKey(const Key('drawer-group-earlier')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-session:e')), findsNothing);
    // Группа с открытой сессией раскрыта сама.
    await _pump(
      tester,
      wide: true,
      size: const Size(312, 900),
      groups: <SessionGroupEntry>[
        _group('week', 'На неделе', <SessionEntry>[_entry('w', active: true)]),
      ],
    );
    expect(find.byKey(const Key('chat-session:w')), findsOneWidget);
  });

  testWidgets('долгое нажатие — меню «Ж2»: поднятая строка, пункты, Esc',
      (tester) async {
    final calls =
        await _pump(tester, groups: _rich, size: const Size(360, 900));
    final row = find.byKey(const Key('chat-session:a'));
    final rowRect = tester.getRect(row);
    await tester.longPress(row);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-menu')), findsOneWidget);
    expect(find.byKey(const Key('session-menu-dim')), findsOneWidget);
    final lifted = tester.getRect(find.byKey(const Key('session-menu-lifted')));
    expect(lifted.top, lessThan(rowRect.top), reason: 'строка приподнята');
    final menu = tester.getRect(find.byKey(const Key('session-menu')));
    expect(menu.top, greaterThan(rowRect.bottom), reason: 'меню под строкой');
    expect(menu.right, moreOrLessEquals(rowRect.right, epsilon: 1));
    // Тестовый шрифт шире настоящего: меню растёт под подписи, но не шире
    // экрана. 236 с настоящими шрифтами — в session_hold_menu_test.
    expect(menu.width, lessThanOrEqualTo(360 - 16));
    for (final key in <String>[
      'session-menu-rename',
      'session-menu-pin',
      'session-menu-delete',
    ]) {
      expect(
        tester.getSize(find.byKey(Key(key))).height,
        greaterThanOrEqualTo(44),
        reason: key,
      );
    }
    expect(find.text('Закрепить'), findsOneWidget);
    final delete = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('session-menu-delete')),
        matching: find.text('Удалить'),
      ),
    );
    expect(delete.style!.color, AppPalette.dark.danger);
    expect(
      find.bySemanticsLabel('Действия с сессией «Отметить приход 318»'),
      findsOneWidget,
    );
    // Esc — закрыть без действия.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-menu')), findsNothing);
    // Нажатие мимо — тоже.
    await tester.longPress(row);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(20, 880));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-menu')), findsNothing);
    expect(calls.log, isEmpty);
    // Закреплённая — «Открепить»; выбор уходит хозяину.
    await tester.longPress(find.byKey(const Key('chat-session:p')));
    await tester.pumpAndSettle();
    expect(find.text('Открепить'), findsOneWidget);
    await tester.tap(find.byKey(const Key('session-menu-pin')));
    await tester.pumpAndSettle();
    await tester.longPress(row);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-delete')));
    await tester.pumpAndSettle();
    expect(calls.log, <String>['pin:session:p', 'delete:session:a']);
  });

  testWidgets('без действий: пустая сессия; чат задачи — без «Переименовать»',
      (tester) async {
    final calls = await _pump(
      tester,
      groups: <SessionGroupEntry>[
        _group('today', 'Сегодня', <SessionEntry>[
          _entry('new', acts: false),
          const SessionEntry(
            id: 'task:t1',
            title: 'Позвонить поставщику',
            time: '10:15',
            itemKey: Key('chat-t1'),
            dotKey: Key('chat-unread-t1'),
            canAct: true,
          ),
        ]),
      ],
    );
    await tester.longPress(find.byKey(const Key('chat-session:new')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-menu')), findsNothing);
    await tester.longPress(find.byKey(const Key('chat-t1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-menu-rename')), findsNothing);
    expect(find.byKey(const Key('session-menu-pin')), findsOneWidget);
    // Системная «Назад» закрывает меню.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-menu')), findsNothing);
    expect(calls.log, isEmpty);
  });

  testWidgets('компьютер: «⋯» при наведении и правая кнопка — то же меню',
      (tester) async {
    final calls = await _pump(
      tester,
      groups: _rich,
      wide: true,
      size: const Size(312, 900),
    );
    final more = find.byKey(const Key('chat-more-session:a'));
    expect(more, findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const Key('chat-session:a'))),
    );
    await tester.pumpAndSettle();
    expect(more, findsOneWidget);
    expect(find.byTooltip('Действия с сессией'), findsOneWidget);
    expect(tester.getSize(more).height, greaterThanOrEqualTo(44));
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-menu')), findsOneWidget);
    await tester.tap(find.byKey(const Key('session-menu-rename')));
    await tester.pumpAndSettle();
    // Правая кнопка мыши.
    await tester.tap(
      find.byKey(const Key('chat-session:p')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-menu')), findsOneWidget);
    await tester.tap(find.byKey(const Key('session-menu-delete')));
    await tester.pumpAndSettle();
    expect(calls.log, <String>['rename:session:a', 'delete:session:p']);
  });

  testWidgets('экранный диктор: действия с сессией — без долгого нажатия',
      (tester) async {
    final handle = tester.ensureSemantics();
    final calls =
        await _pump(tester, groups: _rich, size: const Size(360, 900));
    final node = tester.getSemantics(find.byKey(const Key('chat-session:a')));
    final data = node.getSemanticsData();
    final labels = <String>[
      for (final id in data.customSemanticsActionIds!)
        CustomSemanticsAction.getAction(id)!.label!,
    ];
    // Порядок идентификаторов — порядок их первой регистрации в процессе.
    expect(
      labels,
      unorderedEquals(<String>['Переименовать', 'Закрепить', 'Удалить']),
    );
    final owner = node.owner!;
    final delete = data.customSemanticsActionIds!.firstWhere(
      (int id) => CustomSemanticsAction.getAction(id)!.label == 'Удалить',
    );
    owner.performAction(node.id, SemanticsAction.customAction, delete);
    await tester.pump();
    expect(calls.log, <String>['delete:session:a']);
    final pinned = tester
        .getSemantics(find.byKey(const Key('chat-session:p')))
        .getSemanticsData();
    expect(
      pinned.customSemanticsActionIds!
          .map((int id) => CustomSemanticsAction.getAction(id)!.label),
      contains('Открепить'),
    );
    handle.dispose();
  });

  test('подписи времени в группах (макет Ж1)', () {
    final now = DateTime(2026, 11, 12, 14, 20);
    expect(
      sessionRowTimeLabel(DateTime(2026, 11, 12, 9, 5), now, 'today'),
      '09:05',
    );
    expect(
      sessionRowTimeLabel(DateTime(2026, 11, 11, 18, 20), now, 'yesterday'),
      '18:20',
    );
    expect(sessionRowTimeLabel(DateTime(2026, 11, 10), now, 'week'), 'вт');
    expect(
      sessionRowTimeLabel(DateTime(2026, 11, 4), now, 'earlier'),
      '4 нояб',
    );
    expect(
      sessionRowTimeLabel(DateTime(2026, 10, 30), now, 'earlier'),
      '30 окт',
    );
    expect(sessionRowTimeLabel(DateTime(2026, 11, 9), now, 'pinned'), 'пн');
    expect(sessionRowTimeLabel(DateTime(2026, 10, 9), now, 'pinned'), '9 окт');
    // Прошлый год: тот же день и месяц не сливаются с этим годом.
    expect(
      sessionRowTimeLabel(DateTime(2025, 11, 12), now, 'earlier'),
      '12.11.25',
    );
    expect(
      sessionRowTimeLabel(DateTime(2025, 11, 12), now, 'pinned'),
      '12.11.25',
    );
    expect(
      sessionRowTimeLabel(DateTime(2026, 11, 12, 9), now, 'earlier'),
      isNot(sessionRowTimeLabel(DateTime(2025, 11, 12, 9), now, 'earlier')),
    );
  });

  test('подписи времени', () {
    expect(sessionTimeLabel(DateTime(2026, 11, 9, 9, 5), _now), '09:05');
    expect(sessionTimeLabel(DateTime(2026, 11, 8, 23), _now), 'вчера');
    expect(sessionTimeLabel(DateTime(2026, 11, 5), _now), 'чт');
    expect(sessionTimeLabel(DateTime(2026, 10, 9), _now), '9 окт.');
  });

  group('проекты-папки (ADR-018)', () {
    testWidgets('папки под «Проектами», «+» — новый проект', (tester) async {
      final calls = await _pump(
        tester,
        projects: const <ProjectEntry>[
          ProjectEntry(id: 'project:1', name: 'Ремонт', sessions: 2),
          ProjectEntry(
            id: 'project:2',
            name: 'Отпуск',
            sessions: 0,
            active: true,
          ),
        ],
      );
      final projects = tester.getTopLeft(find.byKey(const Key('nav-projects')));
      final folder =
          tester.getTopLeft(find.byKey(const Key('project-project:1')));
      final planning = tester.getTopLeft(find.byKey(const Key('nav-planning')));
      expect(folder.dy, greaterThan(projects.dy));
      expect(folder.dy, lessThan(planning.dy));
      expect(find.text('Ремонт'), findsOneWidget);
      expect(find.text('2'), findsWidgets);

      await tester.tap(find.byKey(const Key('project-project:1')));
      await tester.tap(find.byKey(const Key('project-new')));
      expect(calls.log, <String>['project:project:1', 'new-project']);
      expect(
        tester.getSemantics(find.byKey(const Key('project-project:1'))),
        matchesSemantics(
          label: 'Проект «Ремонт», 2 сессии',
          isButton: true,
          hasSelectedState: true,
          hasTapAction: true,
        ),
      );
    });

    testWidgets('больше пяти папок — «Все проекты»', (tester) async {
      final calls = await _pump(
        tester,
        projects: <ProjectEntry>[
          for (var i = 0; i < 7; i++)
            ProjectEntry(id: 'project:$i', name: 'Папка $i', sessions: i),
        ],
      );
      expect(find.byKey(const Key('project-project:4')), findsOneWidget);
      expect(find.byKey(const Key('project-project:5')), findsNothing);
      await tester.tap(find.byKey(const Key('project-all')));
      expect(calls.log, <String>['projects']);
    });

    testWidgets('строка сессии в проекте — значок папки и название',
        (tester) async {
      await _pump(
        tester,
        groups: <SessionGroupEntry>[
          _group('today', 'Сегодня', <SessionEntry>[
            const SessionEntry(
              id: 'session:p',
              title: 'Плитка',
              time: '12:00',
              itemKey: Key('chat-session:p'),
              dotKey: Key('chat-unread-session:p'),
              preview: 'Добавил задачу',
              projectName: 'Ремонт',
              canAct: true,
              canRename: true,
              canMove: true,
            ),
          ]),
        ],
      );
      expect(find.byKey(const Key('chat-project-session:p')), findsOneWidget);
      expect(find.textContaining('Ремонт'), findsOneWidget);
      await tester.longPress(find.byKey(const Key('chat-session:p')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('session-menu-move')), findsOneWidget);
      await tester.tap(find.byKey(const Key('session-menu-move')));
      await tester.pumpAndSettle();
    });

    testWidgets('без canMove (чат задачи) «В проект…» нет', (tester) async {
      await _pump(tester);
      final row = find.byKey(const Key('chat-session:1'));
      await tester.ensureVisible(row);
      await tester.longPress(row);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('session-menu-move')), findsNothing);
    });
  });
}

/// Холст, который запоминает нарисованные круги.
final class _CircleCanvas implements Canvas {
  final List<(Offset, double, int)> circles = <(Offset, double, int)>[];

  @override
  void drawCircle(Offset c, double radius, Paint paint) =>
      circles.add((c, radius, paint.color.toARGB32()));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}
