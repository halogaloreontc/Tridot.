import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/shell/drawer_swipe.dart';

Future<List<int>> _pump(WidgetTester tester, Widget child) async {
  final opened = <int>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DrawerSwipe(
          onOpen: () => opened.add(1),
          child: child,
        ),
      ),
    ),
  );
  return opened;
}

Widget _wideRow() => Row(
      children: <Widget>[
        for (var i = 0; i < 40; i++)
          SizedBox(width: 60, height: 60, child: Text('ячейка $i')),
      ],
    );

void main() {
  testWidgets(
      'вкладки (TabBarView): с первой свайп вправо открывает меню, с '
      'дальней — листает назад', (tester) async {
    final controller = TabController(length: 4, vsync: const TestVSync());
    addTearDown(controller.dispose);
    final opened = await _pump(
      tester,
      TabBarView(
        controller: controller,
        children: <Widget>[
          for (var i = 0; i < 4; i++)
            ListView(
              children: <Widget>[
                for (var j = 0; j < 30; j++)
                  SizedBox(height: 60, child: Text('вкладка $i, строка $j')),
              ],
            ),
        ],
      ),
    );
    await tester.dragFrom(const Offset(150, 300), const Offset(220, 0));
    await tester.pumpAndSettle();
    expect(opened, hasLength(1));
    expect(controller.index, 0);

    controller.index = 2;
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(100, 300), const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(opened, hasLength(1));
    expect(controller.index, 1);
  });

  testWidgets(
      'вкладки, которые палец не листает: свайп вправо с любой открывает '
      'меню', (tester) async {
    final controller = TabController(length: 4, vsync: const TestVSync());
    addTearDown(controller.dispose);
    final opened = await _pump(
      tester,
      TabBarView(
        controller: controller,
        physics: const NeverScrollableScrollPhysics(),
        children: <Widget>[
          for (var i = 0; i < 4; i++)
            ListView(
              children: <Widget>[
                for (var j = 0; j < 30; j++)
                  SizedBox(height: 60, child: Text('вкладка $i, строка $j')),
              ],
            ),
        ],
      ),
    );
    for (final (tab, y) in <(int, double)>[(2, 150), (3, 400), (1, 550)]) {
      controller.index = tab;
      await tester.pumpAndSettle();
      await tester.dragFrom(Offset(200, y), const Offset(220, 0));
      await tester.pumpAndSettle();
      expect(controller.index, tab, reason: 'вкладка не листается');
    }
    expect(opened, hasLength(3));
  });

  testWidgets('строка кнопок у своего начала свайпу вправо не мешает',
      (tester) async {
    final opened = await _pump(
      tester,
      Center(
        child: SizedBox(
          height: 60,
          child: ListView(
            key: const Key('row'),
            scrollDirection: Axis.horizontal,
            children: <Widget>[
              for (var i = 0; i < 40; i++)
                SizedBox(width: 60, child: Text('ячейка $i')),
            ],
          ),
        ),
      ),
    );
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
    // Влево — строка листается, меню нет.
    await tester.dragFrom(const Offset(400, 300), const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(scroll.position.pixels, greaterThan(0));
    // Обратно к началу — и вправо уже свайп меню.
    scroll.position.jumpTo(0);
    await tester.pump();
    await tester.dragFrom(const Offset(400, 300), const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(opened, hasLength(1));
  });

  testWidgets(
      'горизонтальный SingleChildScrollView сам листается, меню не '
      'открывает', (tester) async {
    final opened = await _pump(
      tester,
      Center(
        child: SingleChildScrollView(
          key: const Key('row'),
          scrollDirection: Axis.horizontal,
          child: _wideRow(),
        ),
      ),
    );
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
    // Сначала сдвинем строку, чтобы ей было куда листать вправо.
    scroll.position.jumpTo(600);
    await tester.pump();
    await tester.dragFrom(
      tester.getCenter(find.byKey(const Key('row'))),
      const Offset(240, 0),
    );
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(scroll.position.pixels, lessThan(600));
  });

  testWidgets('вертикальная прокрутка свайпу вправо не мешает', (tester) async {
    final opened = await _pump(
      tester,
      SingleChildScrollView(
        child: Column(
          children: <Widget>[
            for (var i = 0; i < 40; i++)
              SizedBox(height: 60, child: Text('строка $i')),
          ],
        ),
      ),
    );
    await tester.dragFrom(const Offset(120, 300), const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(opened, hasLength(1));
  });

  testWidgets(
      'многострочное поле без фокуса не мешает, однострочное и с курсором '
      '— мешают', (tester) async {
    final multi = FocusNode();
    addTearDown(multi.dispose);
    final opened = await _pump(
      tester,
      Column(
        children: <Widget>[
          const TextField(key: Key('single')),
          TextField(
            key: const Key('multi'),
            focusNode: multi,
            minLines: 6,
            maxLines: null,
          ),
        ],
      ),
    );
    Offset at(String key) =>
        tester.getTopLeft(find.byKey(Key(key))) + const Offset(60, 20);

    await tester.dragFrom(at('single'), const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);

    await tester.dragFrom(at('multi'), const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(opened, hasLength(1));

    multi.requestFocus();
    await tester.pumpAndSettle();
    await tester.dragFrom(at('multi'), const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(opened, hasLength(1));
  });

  group('свайп влево — правая панель (ADR-028)', () {
    Future<({List<int> start, List<int> end})> pumpBoth(
      WidgetTester tester,
      Widget child,
    ) async {
      final start = <int>[];
      final end = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DrawerSwipe(
              onOpen: () => start.add(1),
              onOpenEnd: () => end.add(1),
              child: child,
            ),
          ),
        ),
      );
      return (start: start, end: end);
    }

    Widget feed() => ListView(
          children: <Widget>[
            for (var i = 0; i < 40; i++)
              SizedBox(height: 60, child: Text('строка $i')),
          ],
        );

    testWidgets('влево — onOpenEnd, вправо — onOpen', (tester) async {
      final opened = await pumpBoth(tester, feed());
      await tester.dragFrom(const Offset(600, 300), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(opened.end, hasLength(1));
      expect(opened.start, isEmpty);
      await tester.dragFrom(const Offset(200, 300), const Offset(200, 0));
      await tester.pumpAndSettle();
      expect(opened.start, hasLength(1));
      expect(opened.end, hasLength(1));
    });

    testWidgets('без onOpenEnd свайп влево ничего не делает', (tester) async {
      final opened = await _pump(tester, feed());
      await tester.dragFrom(const Offset(600, 300), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
    });

    testWidgets(
        'вертикально, наискось, короткий, долгое нажатие, мышь и полоса у '
        'правого края — не свайп', (tester) async {
      final opened = await pumpBoth(tester, feed());
      // Вертикально и наискось.
      await tester.dragFrom(const Offset(600, 300), const Offset(-40, -200));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(600, 300), const Offset(-120, -80));
      await tester.pumpAndSettle();
      // Меньше 48.
      await tester.dragFrom(const Offset(600, 300), const Offset(-40, 0));
      await tester.pumpAndSettle();
      // Мышь.
      await tester.dragFrom(
        const Offset(600, 300),
        const Offset(-200, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      // От самого правого края: там панель тянет Scaffold.
      await tester.dragFrom(const Offset(790, 300), const Offset(-200, 0));
      await tester.pumpAndSettle();
      // Палец держали, прежде чем повести, — выделение текста.
      final gesture = await tester.startGesture(const Offset(600, 300));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.moveBy(const Offset(-200, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(opened.end, isEmpty);
      expect(opened.start, isEmpty);
    });

    testWidgets(
        'горизонтальная строка: пока есть куда листать — листается, у конца '
        '— свайп', (tester) async {
      final opened = await pumpBoth(
        tester,
        Center(
          child: SizedBox(
            height: 60,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: <Widget>[
                for (var i = 0; i < 40; i++)
                  SizedBox(width: 60, child: Text('ячейка $i')),
              ],
            ),
          ),
        ),
      );
      final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
      await tester.dragFrom(const Offset(600, 300), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(opened.end, isEmpty);
      expect(scroll.position.pixels, greaterThan(0));
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      await tester.dragFrom(const Offset(600, 300), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(opened.end, hasLength(1));
    });

    testWidgets('вкладки: с первой влево — следующая вкладка, не панель',
        (tester) async {
      final controller = TabController(length: 3, vsync: const TestVSync());
      addTearDown(controller.dispose);
      final opened = await pumpBoth(
        tester,
        TabBarView(
          controller: controller,
          children: <Widget>[for (var i = 0; i < 3; i++) feed()],
        ),
      );
      await tester.dragFrom(const Offset(600, 300), const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(controller.index, 1);
      expect(opened.end, isEmpty);
      // Вправо со второй — назад, не меню.
      await tester.dragFrom(const Offset(200, 300), const Offset(500, 0));
      await tester.pumpAndSettle();
      expect(controller.index, 0);
      expect(opened.start, isEmpty);
    });

    testWidgets('DrawerSwipeBlocker и enabled: false — ни в одну сторону',
        (tester) async {
      final opened = await pumpBoth(
        tester,
        Column(
          children: <Widget>[
            Expanded(child: feed()),
            const DrawerSwipeBlocker(
              child: SizedBox(height: 120, child: Text('поле')),
            ),
          ],
        ),
      );
      await tester.dragFrom(const Offset(600, 540), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(opened.end, isEmpty);
      final start = <int>[];
      final end = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DrawerSwipe(
              enabled: false,
              onOpen: () => start.add(1),
              onOpenEnd: () => end.add(1),
              child: feed(),
            ),
          ),
        ),
      );
      await tester.dragFrom(const Offset(600, 300), const Offset(-200, 0));
      await tester.dragFrom(const Offset(200, 300), const Offset(200, 0));
      await tester.pumpAndSettle();
      expect(start, isEmpty);
      expect(end, isEmpty);
    });
  });
}
