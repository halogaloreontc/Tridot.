import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/models/reply_table.dart';
import 'package:local_assistant/core/models/warehouse_card.dart';

WarehouseCard _card(String command, List<WarehouseRow> rows) => WarehouseCard(
      connector: 'warehouse',
      command: command,
      title: 't',
      say: 's',
      rows: rows,
    );

void main() {
  test('команда вне списка — null, даже со строками', () {
    final card = _card('price', const <WarehouseRow>[
      WarehouseRow(title: 'a', badge: '1'),
    ]);
    expect(card.asTable(card.rows), isNull);
  });

  test('пустые строки — null', () {
    final card = _card('where', const <WarehouseRow>[]);
    expect(card.asTable(card.rows), isNull);
  });

  test('одна строка без вложенных ячеек — одна строка таблицы с её ссылкой',
      () {
    final card = _card('count', const <WarehouseRow>[
      WarehouseRow(
        title: '70042',
        text: 'Стол кухонный',
        note: '118-2-3',
        badge: '45 шт.',
        linkKind: 'sku',
        linkId: '70042',
      ),
    ]);
    final table = card.asTable(card.rows)!;
    expect(table.rows, hasLength(1));
    expect(
      table.rows.single.cells,
      <String>['70042', 'Стол кухонный', '118-2-3', '45 шт.'],
    );
    expect(table.rows.single.group, ReplyTableGroup.none);
    expect(table.rows.single.linkKind, 'sku');
    expect(table.rows.single.linkId, '70042');
  });

  test('ячейка (linkKind cell) — ссылка не переносится: не в openKinds', () {
    final card = _card('where', const <WarehouseRow>[
      WarehouseRow(
        title: '64115',
        text: 'Стул',
        badge: '1200 шт.',
        linkKind: 'sku',
        linkId: '64115',
        rows: <WarehouseRow>[
          WarehouseRow(
            title: '215-1-1-1',
            note: 'годен',
            badge: '1000 шт.',
            linkKind: 'cell',
            linkId: '215-1-1-1',
          ),
          WarehouseRow(
            title: '215-1-1-2',
            note: 'годен',
            badge: '200 шт.',
            linkKind: 'cell',
            linkId: '215-1-1-2',
          ),
        ],
      ),
    ]);
    final table = card.asTable(card.rows)!;
    expect(table.rows, hasLength(2));
    expect(
      table.rows[0].cells,
      <String>['64115', 'Стул', '215-1-1-1 · годен', '1000 шт.'],
    );
    expect(table.rows[0].group, ReplyTableGroup.start);
    expect(table.rows[0].linkKind, 'sku');
    expect(table.rows[0].linkId, '64115');
    expect(
      table.rows[1].cells,
      <String>['', '', '215-1-1-2 · годен', '200 шт.'],
    );
    expect(table.rows[1].group, ReplyTableGroup.continues);
    expect(
      table.rows[1].linkKind,
      '',
      reason: 'вложенная ячейка не нажимается, как и в списке сейчас',
    );
  });

  test(
      'зебра — с 3 верхнеуровневых строк и выше, по родителю (группа — вместе)',
      () {
    final rows = <WarehouseRow>[
      for (final id in <String>['1', '2', '3'])
        WarehouseRow(title: id, badge: '1 шт.'),
    ];
    final table = _card('cell', rows).asTable(rows)!;
    expect(table.rows.map((r) => r.zebra), <bool>[false, true, false]);
  });

  test('зебра выключена при 2 строках и меньше', () {
    final rows = <WarehouseRow>[
      const WarehouseRow(title: '1', badge: '1 шт.'),
      const WarehouseRow(title: '2', badge: '1 шт.'),
    ];
    final table = _card('cell', rows).asTable(rows)!;
    expect(table.rows.every((r) => !r.zebra), isTrue);
  });
}
