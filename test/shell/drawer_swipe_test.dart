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
}
