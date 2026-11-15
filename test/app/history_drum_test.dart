// «Барабан» хроники на телефоне: окошко вырастает из кнопки полос, команды
// листаются свайпом в стороны, по центру — главная; нажатие мимо, «Назад»,
// Esc и свайп вниз закрывают; «Весь список» — прежняя шторка.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/widgets/history_rail.dart';
import 'package:local_assistant/app/widgets/history_drum.dart';
import 'package:local_assistant/app/widgets/whole_word_text.dart';

import '../support/app_fonts.dart';
import '../support/word_wrap_guard.dart';

final _entries = <HistoryEntry>[
  for (var i = 0; i < 12; i++)
    HistoryEntry(
      command: 'Напомни позвонить маме в пятницу $i',
      timestamp: '12:${(10 + i).toString().padLeft(2, '0')}',
      result: i.isEven ? 'Готово: напоминание на пятницу в 18:00' : null,
    ),
];

final _popup = find.byKey(const Key('history-drum-popup'));
final _open = find.byKey(const Key('history-rail-open'));
final _pillBox = find.byKey(const Key('history-rail-pill'));

String _count(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('history-drum-count'))).data!;

PageController _controller(WidgetTester tester) =>
    tester.widget<PageView>(find.byKey(const Key('history-drum'))).controller!;

int _center(WidgetTester tester) => _controller(tester).page!.round();

Future<List<int>> _pump(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  ThemeData? theme,
  bool reduceMotion = false,
  bool disableAnimations = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final picked = <int>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? AssistantTheme.dark(),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: disableAnimations,
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.only(top: 60),
          child: Align(
            alignment: Alignment.topCenter,
            child: HistoryRailPill(
              entries: _entries,
              compact: true,
              reduceMotion: reduceMotion,
              onSelect: picked.add,
            ),
          ),
        ),
      ),
    ),
  );
  return picked;
}

Future<void> _openDrum(WidgetTester tester) async {
  await tester.tap(_open);
  await tester.pumpAndSettle();
  expect(_popup, findsOneWidget);
}

void main() {
  const sizes = <Size>[Size(320, 640), Size(390, 844), Size(430, 932)];
  final themes = <String, ThemeData Function()>{
    'тёмная': AssistantTheme.dark,
    'светлая': AssistantTheme.light,
  };

  for (final MapEntry(key: name, value: theme) in themes.entries) {
    for (final size in sizes) {
      final label = '$name ${size.width.toInt()}×${size.height.toInt()}';
      testWidgets('$label: окошко вырастает из кнопки', (tester) async {
        await _pump(tester, size: size, theme: theme());
        final pill = tester.getRect(_pillBox);
        await tester.tap(_open);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 110));
        final mid = tester.getRect(_popup);
        await tester.pumpAndSettle();
        final end = tester.getRect(_popup);
        expect(mid.width, greaterThan(pill.width));
        expect(mid.width, lessThan(end.width));
        expect(mid.height, greaterThan(pill.height));
        expect(mid.height, lessThan(end.height));
        expect(end.left, greaterThanOrEqualTo(16));
        expect(end.right, lessThanOrEqualTo(size.width - 16));
        expect(end.top, moreOrLessEquals(pill.top));
        expect(end.bottom, lessThanOrEqualTo(size.height - 16));
        expect(_center(tester), 11);
        expect(_count(tester), '12 из 12');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('$name: цели нажатия и контраст', (tester) async {
      await loadAppFonts();
      await _pump(tester, theme: theme());
      final handle = tester.ensureSemantics();
      await _openDrum(tester);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });
  }

  testWidgets('«Меньше движения» и disableAnimations: сразу целиком',
      (tester) async {
    for (final (reduce, disable) in <(bool, bool)>[
      (true, false),
      (false, true),
    ]) {
      await _pump(tester, reduceMotion: reduce, disableAnimations: disable);
      await tester.tap(_open);
      await tester.pump();
      final rect = tester.getRect(_popup);
      await tester.pumpAndSettle();
      expect(tester.getRect(_popup), rect);
      expect(rect.width, 358);
      await tester.tapAt(const Offset(5, 839));
      await tester.pump();
      expect(_popup, findsNothing);
    }
  });

  testWidgets('свайп в сторону — соседняя команда, щелчок отклика один',
      (tester) async {
    await _pump(tester);
    final haptics = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add(call.arguments as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await _openDrum(tester);
    final card = tester.getSize(find.byKey(const Key('history-drum-item-11')));
    await tester.drag(
      find.byKey(const Key('history-drum')),
      Offset(card.width, 0),
    );
    await tester.pumpAndSettle();
    expect(_center(tester), 10);
    expect(_count(tester), '11 из 12');
    expect(haptics, <String>['HapticFeedbackType.selectionClick']);

    // Короткий бросок — ровно на целую страницу.
    await tester.fling(
      find.byKey(const Key('history-drum')),
      const Offset(60, 0),
      800,
    );
    await tester.pumpAndSettle();
    final page = _controller(tester).page!;
    expect(page, page.roundToDouble());
    expect(page, lessThan(10));
  });

  testWidgets('нажатие: сбоку — в центр, по центру — переход', (tester) async {
    final picked = await _pump(tester);
    await _openDrum(tester);
    final side = find.byKey(const Key('history-drum-item-10'));
    final rect = tester.getRect(side);
    // Видимая часть соседа — у левого края окошка.
    await tester.tapAt(Offset(rect.right - 12, rect.center.dy));
    await tester.pumpAndSettle();
    expect(_center(tester), 10);
    expect(picked, isEmpty);
    expect(_popup, findsOneWidget);
    await tester.tap(find.byKey(const Key('history-drum-item-10')));
    await tester.pumpAndSettle();
    expect(picked, <int>[10]);
    expect(_popup, findsNothing);
  });

  testWidgets('закрывается: мимо, «Назад», Esc, свайп вниз', (tester) async {
    final picked = await _pump(tester);
    await _openDrum(tester);
    await tester.tapAt(const Offset(5, 839));
    await tester.pumpAndSettle();
    expect(_popup, findsNothing);

    await _openDrum(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_popup, findsNothing);

    await _openDrum(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_popup, findsNothing);

    await _openDrum(tester);
    final header = tester.getRect(_popup).topCenter + const Offset(0, 24);
    await tester.dragFrom(header, const Offset(0, 30));
    await tester.pumpAndSettle();
    expect(_popup, findsOneWidget, reason: 'короткий свайп — пружинит назад');
    await tester.dragFrom(header, const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(_popup, findsNothing);
    expect(picked, isEmpty);
  });

  testWidgets('клавиатура: ← и Enter', (tester) async {
    final picked = await _pump(tester);
    await _openDrum(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(_count(tester), '11 из 12');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(picked, <int>[10]);
  });

  testWidgets('«Весь список» — шторка «История команд»', (tester) async {
    final picked = await _pump(tester);
    await _openDrum(tester);
    await tester.tap(find.byKey(const Key('history-drum-all')));
    await tester.pumpAndSettle();
    expect(_popup, findsNothing);
    expect(find.byKey(const Key('history-sheet')), findsOneWidget);
    await tester.tap(find.byKey(const Key('history-item-9')));
    await tester.pumpAndSettle();
    expect(picked, <int>[9]);
  });

  testWidgets('диктор: карточки и счётчик со стрелками', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);
    await _openDrum(tester);
    expect(
      find.bySemanticsLabel(RegExp('^Команда 12 из 12: ')),
      findsOneWidget,
    );
    final drum = find.bySemanticsLabel('Команды сессии');
    expect(tester.getSemantics(drum).value, '12 из 12');
    tester.semantics.performAction(
      find.semantics.byLabel('Команды сессии'),
      SemanticsAction.decrease,
    );
    await tester.pumpAndSettle();
    expect(tester.getSemantics(drum).value, '11 из 12');
    expect(
      tester.getSemantics(drum),
      isSemantics(hasIncreaseAction: true, hasDecreaseAction: true),
    );
    handle.dispose();
  });

  testWidgets('320×640, шрифт ×2: без переполнения и разрывов слов',
      (tester) async {
    await loadAppFonts();
    setPhone(tester, width: 320, height: 640, scale: 2);
    final picked = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AssistantTheme.dark(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.only(top: 60),
            child: Align(
              alignment: Alignment.topCenter,
              child: HistoryRailPill(
                entries: _entries,
                compact: true,
                onSelect: picked.add,
              ),
            ),
          ),
        ),
      ),
    );
    await _openDrum(tester);
    expect(tester.takeException(), isNull);
    expect(tester.getRect(_popup).bottom, lessThanOrEqualTo(640 - 16));
    expectWholeWords(
      tester,
      whole: const <String>{'История команд', 'Нажмите, чтобы перейти'},
      label: 'барабан 320 ×2',
    );
  });

  testWidgets('тире не начинает строку ответа (280–390 px)', (tester) async {
    await loadAppFonts();
    const results = <String>[
      'Запустить таймер на 3 минуты — откроются «Часы» на телефоне.',
      'Таймер на 3 минуты — откроются «Часы».',
      'Поставлю таймер на 3 минуты — откроются «Часы».',
      'Будильник на 7:00 — откроются «Часы», там его и подтвердите.',
    ];
    final entries = <HistoryEntry>[
      for (final (i, result) in results.indexed)
        HistoryEntry(
          command: 'Поставь таймер на 3 минуты',
          timestamp: '09:3$i',
          result: result,
        ),
    ];
    final found = <String>[];
    for (var width = 280.0; width <= 390; width += 2) {
      setPhone(tester, width: width, height: 760);
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey<double>(width),
          theme: AssistantTheme.dark(),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.only(top: 60),
              child: Align(
                alignment: Alignment.topCenter,
                child: HistoryRailPill(
                  entries: entries,
                  compact: true,
                  reduceMotion: true,
                  onSelect: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await _openDrum(tester);
      // Каждую карточку — по центру: в центре она шире всего.
      for (var page = 0; page < results.length; page++) {
        _controller(tester).jumpToPage(page);
        await tester.pumpAndSettle();
        found.addAll(
          midWordBreaks(
            tester,
            whole: const <String>{'История команд', 'Нажмите, чтобы перейти'},
          ).where((String s) => s.startsWith('DASH')).map(
                (String s) => '$width: $s',
              ),
        );
      }
    }
    expect(found, isEmpty);
    expect(tester.takeException(), isNull);
  });

  test('обрезка не кончается тире', () async {
    await loadAppFonts();
    const style = TextStyle(fontFamily: AppFonts.text, fontSize: 17);
    final text = bindDashes('3 минуты — откроются «Часы» на телефоне');
    for (var width = 60.0; width <= 200; width += 4) {
      final shown = fitWords(text, style: style, maxWidth: width, maxLines: 1);
      expect(shown, isNot(matches(RegExp(r'[ \u00a0—–-]…$'))), reason: shown);
      expect(shown, isNot(contains('—…')), reason: shown);
    }
  });

  test('обрезка по границе слова, а не внутри', () async {
    await loadAppFonts();
    const style = TextStyle(fontFamily: AppFonts.text, fontSize: 17);
    const text = 'напомни в понедельник позвонить в банк про карту';
    final shown = fitWords(text, style: style, maxWidth: 160, maxLines: 1);
    expect(shown, endsWith('…'));
    final body = shown.substring(0, shown.length - 1);
    expect(text.startsWith(body), isTrue);
    expect(text[body.length], ' ', reason: 'обрезано внутри слова: $shown');
    expect(
      fitWords('коротко', style: style, maxWidth: 160, maxLines: 1),
      'коротко',
    );
  });

  testWidgets('шрифт ×2 без строк ответа — у команды три строки',
      (tester) async {
    late HistoryDrumLayout layout;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: Builder(
          builder: (BuildContext context) {
            layout = HistoryDrumLayout.measure(
              context,
              width: 288,
              maxHeight: 560,
              count: 6,
            );
            return const SizedBox();
          },
        ),
      ),
    );
    expect(layout.resultLines, 0);
    expect(layout.commandLines, 3);
  });
}
