import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/widgets/reply_table_view.dart';
import 'package:local_assistant/core/models/reply_table.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

const ReplyTable _table = ReplyTable(
  columns: <ReplyTableColumn>[
    ReplyTableColumn('Что'),
    ReplyTableColumn('Название'),
    ReplyTableColumn('Где'),
    ReplyTableColumn('Кол-во', numeric: true),
  ],
  rows: <ReplyTableRow>[
    ReplyTableRow(
      cells: <String>['64115', 'Стул венский', '215-1-1-1 · годен', '1000 шт.'],
      group: ReplyTableGroup.start,
      linkKind: 'sku',
      linkId: '64115',
    ),
    ReplyTableRow(
      cells: <String>['', '', '215-1-1-2 · годен', '200 шт.'],
      group: ReplyTableGroup.continues,
    ),
  ],
);

void main() {
  testWidgets('заголовки и видимый текст строк', (WidgetTester tester) async {
    await _pump(tester, const ReplyTableView(table: _table));
    expect(find.text('Что'), findsOneWidget);
    expect(find.text('Название'), findsOneWidget);
    expect(find.text('Где'), findsOneWidget);
    expect(find.text('Кол-во'), findsOneWidget);
    expect(find.text('64115'), findsOneWidget);
    expect(find.text('215-1-1-1 · годен'), findsOneWidget);
    expect(find.text('215-1-1-2 · годен'), findsOneWidget);
    expect(find.text('1000 шт.'), findsOneWidget);
  });

  testWidgets('полоса группы — только у строк с group != none', (
    WidgetTester tester,
  ) async {
    await _pump(tester, const ReplyTableView(table: _table));
    expect(
      find.byKey(const ValueKey<String>('reply-table-row-0-bar')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('reply-table-row-1-bar')),
      findsOneWidget,
    );
  });

  testWidgets('без зебры — нет фона чередования', (WidgetTester tester) async {
    await _pump(tester, const ReplyTableView(table: _table));
    expect(
      find.byKey(const ValueKey<String>('reply-table-row-0-zebra')),
      findsNothing,
    );
  });

  testWidgets('зебра — фон чередования у помеченной строки', (
    WidgetTester tester,
  ) async {
    const t = ReplyTable(
      columns: <ReplyTableColumn>[ReplyTableColumn('A')],
      rows: <ReplyTableRow>[
        ReplyTableRow(cells: <String>['x']),
        ReplyTableRow(cells: <String>['y'], zebra: true),
      ],
    );
    await _pump(tester, const ReplyTableView(table: t));
    expect(
      find.byKey(const ValueKey<String>('reply-table-row-0-zebra')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('reply-table-row-1-zebra')),
      findsOneWidget,
    );
  });

  testWidgets('строка со ссылкой нажимается и вызывает onOpenLink', (
    WidgetTester tester,
  ) async {
    final opened = <String>[];
    await _pump(
      tester,
      ReplyTableView(
        table: _table,
        onOpenLink: (String kind, String id) => opened.add('$kind:$id'),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('reply-table-row-0')),
    );
    expect(opened, <String>['sku:64115']);
    // Строка без ссылки (group: continues, linkKind пуст) — не нажимается.
    await tester.tap(
      find.byKey(const ValueKey<String>('reply-table-row-1')),
    );
    expect(opened, <String>['sku:64115']);
  });

  testWidgets(
      'onOpenLink отсутствует — строка со ссылкой не падает при нажатии', (
    WidgetTester tester,
  ) async {
    await _pump(tester, const ReplyTableView(table: _table));
    await tester.tap(
      find.byKey(const ValueKey<String>('reply-table-row-0')),
    );
    // Ничего не ожидаем — тест проходит, если не было исключения.
  });
}
