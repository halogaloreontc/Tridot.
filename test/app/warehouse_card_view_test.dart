// Карточка ответа склада (ADR-031): «Открыть в складе» у ответа про одну
// вещь ведёт к ней, строки с позицией или приходом нажимаются, ячейка —
// текст; без ссылок (приложение Android) — прежнее «Открыть склад».
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/widgets/warehouse_card_view.dart';
import 'package:local_assistant/core/models/warehouse_card.dart';

import '../support/app_fonts.dart';

const WarehouseRow _tunli = WarehouseRow(
  title: '67432',
  text: 'ТУНЛИ столик туалетный (120*45*75)',
  badge: '1 шт.',
  linkKind: 'sku',
  linkId: '67432',
  rows: <WarehouseRow>[
    WarehouseRow(
      title: '101БРАК',
      text: 'БРАК',
      badge: '1 шт.',
      linkKind: 'cell',
      linkId: '101БРАК',
    ),
  ],
);

// 'price' — вне WarehouseCard.tableCommands: эти тесты проверяют список,
// как и раньше ('where' теперь рисуется таблицей — ReplyTableView,
// см. warehouse_card_table_test.dart и reply_table_view_test.dart).
WarehouseCard _card(
  List<WarehouseRow> rows, {
  int hidden = 0,
  String command = 'price',
}) =>
    WarehouseCard(
      connector: 'warehouse',
      command: command,
      title: 'Где лежит товар',
      say: '«тунли 67432»: 1 позиция, всего 1 шт.',
      rows: rows,
      hidden: hidden,
    );

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(420, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.dark(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('одна позиция: «Открыть в складе» ведёт к ней', (
    WidgetTester tester,
  ) async {
    final opened = <String>[];
    var home = 0;
    await _pump(
      tester,
      WarehouseCardView(
        card: _card(const <WarehouseRow>[_tunli]),
        onOpen: () => home++,
        onOpenLink: (String kind, String id) => opened.add('$kind:$id'),
      ),
    );
    expect(find.text('Открыть в складе'), findsOneWidget);
    expect(find.text('Открыть склад'), findsNothing);
    await tester.tap(find.byKey(const ValueKey<String>('warehouse-card-open')));
    expect(opened, <String>['sku:67432']);
    expect(home, 0);
    // Строка тоже ведёт к позиции; ячейка — только текст.
    await tester
        .tap(find.byKey(const ValueKey<String>('warehouse-card-link-0')));
    expect(opened, <String>['sku:67432', 'sku:67432']);
    expect(
      find.byKey(const ValueKey<String>('warehouse-card-link-1')),
      findsNothing,
    );
    final semantics = tester.ensureSemantics();
    expect(
      find.bySemanticsLabel(RegExp('^Открыть в складе: 67432')),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('несколько позиций: каждая строка — своя, внизу — склад', (
    WidgetTester tester,
  ) async {
    final opened = <String>[];
    var home = 0;
    await _pump(
      tester,
      WarehouseCardView(
        card: _card(const <WarehouseRow>[
          _tunli,
          WarehouseRow(
            title: 'П-0412',
            text: 'Приход от 14 ноября',
            linkKind: 'entry',
            linkId: '412',
          ),
          WarehouseRow(title: 'Итого', text: 'без ссылки'),
        ]),
        onOpen: () => home++,
        onOpenLink: (String kind, String id) => opened.add('$kind:$id'),
      ),
    );
    expect(find.text('Открыть склад'), findsOneWidget);
    expect(find.text('Открыть в складе'), findsNothing);
    await tester
        .tap(find.byKey(const ValueKey<String>('warehouse-card-link-1')));
    await tester
        .tap(find.byKey(const ValueKey<String>('warehouse-card-link-0')));
    expect(opened, <String>['entry:412', 'sku:67432']);
    expect(
      find.byKey(const ValueKey<String>('warehouse-card-link-2')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey<String>('warehouse-card-open')));
    expect(home, 1);
  });

  testWidgets('склад показал не всё — внизу склад, а не первая позиция', (
    WidgetTester tester,
  ) async {
    var home = 0;
    await _pump(
      tester,
      WarehouseCardView(
        card: _card(const <WarehouseRow>[_tunli], hidden: 3),
        onOpen: () => home++,
        onOpenLink: (String kind, String id) {},
      ),
    );
    expect(find.text('Открыть склад'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('warehouse-card-open')));
    expect(home, 1);
  });

  testWidgets('без ссылок (Android): «Открыть склад», строки не нажимаются', (
    WidgetTester tester,
  ) async {
    var home = 0;
    await _pump(
      tester,
      WarehouseCardView(
        card: _card(const <WarehouseRow>[_tunli]),
        onOpen: () => home++,
      ),
    );
    expect(find.text('Открыть склад'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('warehouse-card-link-0')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey<String>('warehouse-card-open')));
    expect(home, 1);
  });

  test('onlyLink: одна вещь целиком — ссылка, иначе нет', () {
    expect(
      _card(const <WarehouseRow>[_tunli]).onlyLink,
      (kind: 'sku', id: '67432'),
    );
    expect(_card(const <WarehouseRow>[_tunli], hidden: 1).onlyLink, isNull);
    expect(
      _card(const <WarehouseRow>[_tunli, _tunli]).onlyLink,
      isNull,
      reason: 'две строки — не «одна вещь», даже с одной ссылкой',
    );
    expect(
      _card(const <WarehouseRow>[
        WarehouseRow(title: 'A-1', linkKind: 'cell', linkId: 'A-1'),
      ]).onlyLink,
      isNull,
      reason: 'ячейку склад по ссылке не открывает',
    );
  });

  testWidgets('command «where»: таблица вместо списка', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      WarehouseCardView(
        card: _card(const <WarehouseRow>[_tunli], command: 'where'),
      ),
    );
    expect(find.byKey(const ValueKey<String>('reply-table')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('warehouse-card-row-0')),
      findsNothing,
    );
  });

  testWidgets('command вне списка со строками: список, как раньше', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      WarehouseCardView(
        card: _card(const <WarehouseRow>[_tunli], command: 'price'),
      ),
    );
    expect(find.byKey(const ValueKey<String>('reply-table')), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('warehouse-card-row-0')),
      findsOneWidget,
    );
  });

  testWidgets(
    'command «where», onOpenLink null: таблица не падает, не нажимается',
    (WidgetTester tester) async {
      await _pump(
        tester,
        WarehouseCardView(
          card: _card(const <WarehouseRow>[_tunli], command: 'where'),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('reply-table-row-0')),
      );
      // Не падает — этого достаточно; onOpenLink не задан у этого WarehouseCardView.
    },
  );

  testWidgets('command «unposted», onOpenLink задан: ссылка доходит до таблицы',
      (WidgetTester tester) async {
    final opened = <String>[];
    await _pump(
      tester,
      WarehouseCardView(
        card: _card(const <WarehouseRow>[_tunli], command: 'unposted'),
        onOpenLink: (String kind, String id) => opened.add('$kind:$id'),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('reply-table-row-0')),
    );
    expect(opened, <String>['sku:67432']);
    final semantics = tester.ensureSemantics();
    expect(
      find.bySemanticsLabel(RegExp('^Открыть в складе: 67432')),
      findsOneWidget,
      reason: 'как у строки списка — своя роль кнопки и подпись для читалки',
    );
    semantics.dispose();
  });
}
