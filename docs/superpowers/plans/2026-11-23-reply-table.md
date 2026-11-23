# Табличный ответ помощника — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Дать карточке склада (`WarehouseCardView`) табличный вид для
однородных списков (`where`, `count`, `cell`, `unposted`) через общую,
переиспользуемую модель `ReplyTable` и виджет `ReplyTableView` — без
изменения протокола склада и формата истории чата, работает и в
приложении, и в веб-помощнике.

**Architecture:** `WarehouseCard.asTable(rows)` (чистая функция в
`lib/core`) строит `ReplyTable` из уже сохранённых полей карточки.
`ReplyTableView` (обычные Flutter-виджеты, без platform-специфичных
импортов, `lib/app/widgets/`) рисует `ReplyTable`. `WarehouseCardView`
решает по `card.command`, рисовать таблицу или прежний список —
вызывающий код (`home_page.dart`, `widget_app.dart`) не меняется.

**Tech Stack:** Dart/Flutter, flutter_test; без новых зависимостей.

**Spec:** `docs/superpowers/specs/2026-11-23-reply-table-design.md`

## Global Constraints

- `lib/core` не импортирует Flutter — `ReplyTable`/`ReplyTableRow`/
  `ReplyTableColumn` и `WarehouseCard.asTable()` живут в `lib/core/models/`.
- `lib/app/widgets/reply_table_view.dart` не импортирует `dart:ffi`,
  `package:path_provider`, `package:file_selector`, `package:mobile_scanner`,
  `package:record`, `dart:io` — используется и веб-помощником
  (`test/web_widget/web_graph_test.dart`).
- Протокол истории чата (`ChatMessage`/`AssistantResponse`) и протокол
  склада (`ManifestView`) не меняются: таблица — пересчёт из уже
  сохранённых полей `WarehouseCard`, ничего нового не персистится.
- Таблица — только для `command` из `{where, count, cell, unposted}`;
  остальные команды (действия, ответы про одну вещь) рисуются прежним
  списком.
- Ссылка на позицию/приход (`WarehouseCard.openKinds`: `sku`, `entry`)
  у строки с такой ссылкой — строка целиком нажимается и ведёт к вещи,
  как сейчас в списке; у вложенных ячеек ссылки нет, как и сейчас.
- Стиль — по мокапу https://claude.ai/artifact/5LcbN96iRLSBXT7dj1ZAGd:
  полоса заголовка на всю ширину, группа строк одного артикула — цветная
  полоса слева (не пустые повторы), число — отдельным столбцом справа,
  жирнее, `tabular-nums`, чередование фона с `ReplyTable.zebraFrom` (3)
  верхнеуровневых строк, размеры текста/отступы — как в
  `WarehouseCardView` (16/14/13).

## Review Focus

- **Существующие тесты `test/app/warehouse_card_view_test.dart` все
  используют `command: 'where'`.** После правки `'where'` входит в
  табличный список — без изменения этого файла все его тесты (список,
  `onOpenLink`, «Показать все») начнут проверять несуществующее
  (таблицу вместо списка) и падать. Это не «тест нашёл баг» — это план
  должен явно обновить их команду, иначе Task 3 не проходит собственные
  старые тесты.
- **Один верхнеуровневый элемент с вложенными ячейками** (как `_tunli`
  в существующих тестах: 1 артикул, 1 ячейка) — таблица из одной строки
  должна выглядеть нормально (без лишней «группы из одной строки» —
  `group: start` без последующего `continues` допустим и не должен ничего
  ломать).
- **Пустой список строк** (`card.rows.isEmpty`, но ответ всё равно
  показан, напр. `hidden`/`more` без строк) — `asTable` должен вернуть
  `null`, а не таблицу без строк.
- **Команда вне списка, но со строками** (например, будущая `today`) —
  должен рисоваться прежний список, а не таблица: без этого проверки
  границы списка команд нет вовсе.
- **`onOpenLink == null`** (приложение Android не передаёт его —
  `home_page.dart:1485` не задаёт `onOpenLink`) — таблица не должна
  падать и не должна делать строки нажимаемыми.

---

## Task 1: модель `ReplyTable` и `WarehouseCard.asTable()`

**Files:**
- Create: `lib/core/models/reply_table.dart`
- Modify: `lib/core/models/warehouse_card.dart`
- Test: `test/core/models/warehouse_card_table_test.dart`

**Interfaces:**
- Produces:
  - `enum ReplyTableGroup { none, start, continues }`
  - `final class ReplyTableColumn { const ReplyTableColumn(String label, {bool numeric = false}); String get label; bool get numeric; }`
  - `final class ReplyTableRow { const ReplyTableRow({required List<String> cells, ReplyTableGroup group = ReplyTableGroup.none, bool zebra = false, String linkKind = '', String linkId = ''}); List<String> get cells; ReplyTableGroup get group; bool get zebra; String get linkKind; String get linkId; }`
  - `final class ReplyTable { const ReplyTable({required List<ReplyTableColumn> columns, required List<ReplyTableRow> rows}); List<ReplyTableColumn> get columns; List<ReplyTableRow> get rows; static const int zebraFrom = 3; }`
  - `ReplyTable? WarehouseCard.asTable(List<WarehouseRow> rows)` — метод экземпляра `WarehouseCard`.

- [ ] **Step 1: Написать `test/core/models/warehouse_card_table_test.dart` с падающими тестами**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/models/reply_table.dart';
import 'package:local_assistant/core/models/warehouse_card.dart';

WarehouseCard _card(String command, List<WarehouseRow> rows) => WarehouseCard(
      connector: 'warehouse', command: command, title: 't', say: 's', rows: rows,
    );

void main() {
  test('команда вне списка — null, даже со строками', () {
    final card = _card('price', const <WarehouseRow>[WarehouseRow(title: 'a', badge: '1')]);
    expect(card.asTable(card.rows), isNull);
  });

  test('пустые строки — null', () {
    final card = _card('where', const <WarehouseRow>[]);
    expect(card.asTable(card.rows), isNull);
  });

  test('одна строка без вложенных ячеек — одна строка таблицы с её ссылкой', () {
    final card = _card('count', const <WarehouseRow>[
      WarehouseRow(title: '70042', text: 'Стол кухонный', note: '118-2-3', badge: '45 шт.', linkKind: 'sku', linkId: '70042'),
    ]);
    final table = card.asTable(card.rows)!;
    expect(table.rows, hasLength(1));
    expect(table.rows.single.cells, <String>['70042', 'Стол кухонный', '118-2-3', '45 шт.']);
    expect(table.rows.single.group, ReplyTableGroup.none);
    expect(table.rows.single.linkKind, 'sku');
    expect(table.rows.single.linkId, '70042');
  });

  test('ячейка (linkKind cell) — ссылка не переносится: не в openKinds', () {
    final card = _card('where', const <WarehouseRow>[
      WarehouseRow(title: '64115', text: 'Стул', badge: '1200 шт.', linkKind: 'sku', linkId: '64115', rows: <WarehouseRow>[
        WarehouseRow(title: '215-1-1-1', note: 'годен', badge: '1000 шт.', linkKind: 'cell', linkId: '215-1-1-1'),
        WarehouseRow(title: '215-1-1-2', note: 'годен', badge: '200 шт.', linkKind: 'cell', linkId: '215-1-1-2'),
      ]),
    ]);
    final table = card.asTable(card.rows)!;
    expect(table.rows, hasLength(2));
    expect(table.rows[0].cells, <String>['64115', 'Стул', '215-1-1-1 · годен', '1000 шт.']);
    expect(table.rows[0].group, ReplyTableGroup.start);
    expect(table.rows[0].linkKind, 'sku');
    expect(table.rows[0].linkId, '64115');
    expect(table.rows[1].cells, <String>['', '', '215-1-1-2 · годен', '200 шт.']);
    expect(table.rows[1].group, ReplyTableGroup.continues);
    expect(table.rows[1].linkKind, '', reason: 'вложенная ячейка не нажимается, как и в списке сейчас');
  });

  test('зебра — с 3 верхнеуровневых строк и выше, по родителю (группа — вместе)', () {
    final rows = <WarehouseRow>[
      for (final id in <String>['1', '2', '3'])
        WarehouseRow(title: id, badge: '1 шт.'),
    ];
    final table = _card('cell', rows).asTable(rows)!;
    expect(table.rows.map((r) => r.zebra), <bool>[false, true, false]);
  });

  test('зебра выключена при 2 строках и меньше', () {
    final rows = <WarehouseRow>[
      WarehouseRow(title: '1', badge: '1 шт.'),
      WarehouseRow(title: '2', badge: '1 шт.'),
    ];
    final table = _card('cell', rows).asTable(rows)!;
    expect(table.rows.every((r) => !r.zebra), isTrue);
  });
}
```

- [ ] **Step 2: Запустить и убедиться, что тесты падают (нет `asTable`/`ReplyTable`)**

Run: `flutter test test/core/models/warehouse_card_table_test.dart`
Expected: FAIL (`reply_table.dart` не найден / `asTable` не определён)

- [ ] **Step 3: Создать `lib/core/models/reply_table.dart`**

Чистые immutable-классы `ReplyTableGroup`, `ReplyTableColumn`, `ReplyTableRow`,
`ReplyTable` с сигнатурами из блока Interfaces выше. Без логики — только
хранение данных (как `WarehouseRow`/`WarehouseCard` сейчас).

- [ ] **Step 4: Реализовать `WarehouseCard.asTable(List<WarehouseRow> rows)` в `lib/core/models/warehouse_card.dart`**

Множество команд с табличным видом — константа `tableCommands =
{'where', 'count', 'cell', 'unposted'}` (можно `static const Set<String>`
на `WarehouseCard`). Если `command` не входит или `rows.isEmpty` — `null`.
Столбцы — всегда `[ReplyTableColumn('Что'), ReplyTableColumn('Название'),
ReplyTableColumn('Где'), ReplyTableColumn('Кол-во', numeric: true)]`.
На верхнеуровневую строку без вложенных — одна `ReplyTableRow` с
`cells: [title, text, note, badge]`, `linkKind`/`linkId` — те же, что у
строки, но только если `WarehouseCard.openKinds.contains(linkKind)`
(иначе пустые — та же проверка, что сейчас в `_row`/`_linked`). На
строку с вложенными — по одной `ReplyTableRow` на каждую вложенную
ячейку: `cells: [j == 0 ? title : '', j == 0 ? text : '', where, cell.badge]`,
где `where = [cell.title, cell.text, cell.note].where((s) => s.isNotEmpty).join(' · ')`;
`group` — `start` у `j == 0`, иначе `continues`; `linkKind`/`linkId` — от
родителя (с той же проверкой `openKinds`) только при `j == 0`, иначе
пустые. `zebra` — `true` у строк, принадлежащих верхнеуровневому элементу
с нечётным индексом (0-based), когда всего верхнеуровневых строк
`>= ReplyTable.zebraFrom`; все строки одного родителя получают одно и то
же значение `zebra`.

- [ ] **Step 5: Запустить тесты и убедиться, что проходят**

Run: `flutter test test/core/models/warehouse_card_table_test.dart`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/core/models/reply_table.dart lib/core/models/warehouse_card.dart test/core/models/warehouse_card_table_test.dart
git commit -m "feat: модель ReplyTable и WarehouseCard.asTable()"
```

---

## Task 2: виджет `ReplyTableView`

**Files:**
- Create: `lib/app/widgets/reply_table_view.dart`
- Test: `test/app/reply_table_view_test.dart`

**Interfaces:**
- Consumes: `ReplyTable`, `ReplyTableRow`, `ReplyTableColumn`, `ReplyTableGroup` (Task 1).
- Produces: `final class ReplyTableView extends StatelessWidget { const ReplyTableView({super.key, required ReplyTable table, void Function(String kind, String id)? onOpenLink}); }`
  Ключи виджетов (для тестов и для Task 3):
  - `ValueKey('reply-table')` — корневой виджет таблицы;
  - `ValueKey('reply-table-row-$i')` — строка `i` (0-based, по порядку в `table.rows`);
  - `ValueKey('reply-table-row-$i-bar')` — цветная полоса группы, присутствует только если `table.rows[i].group != ReplyTableGroup.none`;
  - `ValueKey('reply-table-row-$i-zebra')` — фон чередования, присутствует только если `table.rows[i].zebra`.

- [ ] **Step 1: Написать `test/app/reply_table_view_test.dart` с падающими тестами**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/widgets/reply_table_view.dart';
import 'package:local_assistant/core/models/reply_table.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

const ReplyTable _table = ReplyTable(
  columns: <ReplyTableColumn>[
    ReplyTableColumn('Что'), ReplyTableColumn('Название'),
    ReplyTableColumn('Где'), ReplyTableColumn('Кол-во', numeric: true),
  ],
  rows: <ReplyTableRow>[
    ReplyTableRow(
      cells: <String>['64115', 'Стул венский', '215-1-1-1 · годен', '1000 шт.'],
      group: ReplyTableGroup.start, linkKind: 'sku', linkId: '64115',
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

  testWidgets('полоса группы — только у строк с group != none', (WidgetTester tester) async {
    await _pump(tester, const ReplyTableView(table: _table));
    expect(find.byKey(const ValueKey<String>('reply-table-row-0-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('reply-table-row-1-bar')), findsOneWidget);
  });

  testWidgets('без зебры — нет фона чередования', (WidgetTester tester) async {
    await _pump(tester, const ReplyTableView(table: _table));
    expect(find.byKey(const ValueKey<String>('reply-table-row-0-zebra')), findsNothing);
  });

  testWidgets('зебра — фон чередования у помеченной строки', (WidgetTester tester) async {
    const t = ReplyTable(
      columns: <ReplyTableColumn>[ReplyTableColumn('A')],
      rows: <ReplyTableRow>[
        ReplyTableRow(cells: <String>['x']),
        ReplyTableRow(cells: <String>['y'], zebra: true),
      ],
    );
    await _pump(tester, const ReplyTableView(table: t));
    expect(find.byKey(const ValueKey<String>('reply-table-row-0-zebra')), findsNothing);
    expect(find.byKey(const ValueKey<String>('reply-table-row-1-zebra')), findsOneWidget);
  });

  testWidgets('строка со ссылкой нажимается и вызывает onOpenLink', (WidgetTester tester) async {
    final opened = <String>[];
    await _pump(tester, ReplyTableView(
      table: _table,
      onOpenLink: (String kind, String id) => opened.add('$kind:$id'),
    ));
    await tester.tap(find.byKey(const ValueKey<String>('reply-table-row-0')));
    expect(opened, <String>['sku:64115']);
    // Строка без ссылки (group: continues, linkKind пуст) — не нажимается.
    await tester.tap(find.byKey(const ValueKey<String>('reply-table-row-1')));
    expect(opened, <String>['sku:64115']);
  });

  testWidgets('onOpenLink отсутствует — строка со ссылкой не падает при нажатии', (WidgetTester tester) async {
    await _pump(tester, const ReplyTableView(table: _table));
    await tester.tap(find.byKey(const ValueKey<String>('reply-table-row-0')));
    // Ничего не ожидаем — тест проходит, если не было исключения.
  });
}
```

- [ ] **Step 2: Запустить и убедиться, что падают (нет `reply_table_view.dart`)**

Run: `flutter test test/app/reply_table_view_test.dart`
Expected: FAIL

- [ ] **Step 3: Реализовать `ReplyTableView` в `lib/app/widgets/reply_table_view.dart`**

`StatelessWidget`, без platform-специфичных импортов. Полоса заголовка —
`Row` из `Expanded` с подписями столбцов (`numeric` — выравнивание
`TextAlign.end`), на всю ширину, нижняя граница. Каждая строка —
`Row` из `Expanded`-ячеек в том же порядке столбцов (`numeric` — по
правому краю, `FontFeature.tabularFigures()`, жирнее основного текста);
между соседними ячейками — тонкая вертикальная граница (`Container` с
`border` или `DecoratedBox`); между строками — нижняя граница, как в
`WarehouseCardView` (`colors.divider`/аналог через `Theme.of(context)`,
раз это общий виджет без доступа к `AssistantTheme`-экстеншену — см.
ниже). Полоса группы — узкий `Container` (3px, цвет акцента с
прозрачностью) слева от первой ячейки строки, добавляется только когда
`row.group != ReplyTableGroup.none` (под ключом `*-bar`). Зебра — фоновая
подложка строки (`Container`/`DecoratedBox` с ключом `*-zebra`) только
когда `row.zebra`. Ссылка — строка оборачивается в `InkWell`/`GestureDetector`
с `onTap: () => onOpenLink!(row.linkKind, row.linkId)` только когда
`onOpenLink != null && row.linkKind.isNotEmpty && row.linkId.isNotEmpty`.
Цвета — через `Theme.of(context).colorScheme` (виджет в `lib/app/widgets`
без доступа к `context.colors` из `assistant_theme.dart`, если тот
импортирует что-то за пределами ограничений веб-помощника — проверить:
если `assistant_theme.dart` уже используется в `message_row.dart`/
`warehouse_card_view.dart`, которые веб-помощник использует без проблем
(`web_graph_test.dart` их не запрещает), можно и здесь взять `context.colors`
и те же стили, что в `WarehouseCardView._style`, для единого вида;
подтвердить импортами `warehouse_card_view.dart` как образец.

- [ ] **Step 4: Запустить тесты и убедиться, что проходят**

Run: `flutter test test/app/reply_table_view_test.dart`
Expected: PASS

- [ ] **Step 5: `flutter analyze` (без новых предупреждений) и `dart format`**

Run: `dart format --output=none --set-exit-if-changed lib/app/widgets/reply_table_view.dart test/app/reply_table_view_test.dart && flutter analyze`
Expected: чисто

- [ ] **Step 6: Commit**

```bash
git add lib/app/widgets/reply_table_view.dart test/app/reply_table_view_test.dart
git commit -m "feat: виджет ReplyTableView"
```

---

## Task 3: `WarehouseCardView` рисует таблицу, где это решено

**Files:**
- Modify: `lib/app/widgets/warehouse_card_view.dart`
- Modify: `test/app/warehouse_card_view_test.dart`

**Interfaces:**
- Consumes: `WarehouseCard.asTable` (Task 1), `ReplyTableView` (Task 2).
- Produces: не меняет публичный конструктор `WarehouseCardView` — только внутренний `build()`.

- [ ] **Step 1: В `test/app/warehouse_card_view_test.dart` развести «список» и «таблица» по командам**

`'where'` теперь входит в табличный список (`WarehouseCard.tableCommands`).
Чтобы существующие тесты (список, `onOpenLink` по строке, «Показать все»,
`onlyLink`) продолжали проверять именно список, добавить параметр
команды в `_card()`:

```dart
WarehouseCard _card(
  List<WarehouseRow> rows, {
  int hidden = 0,
  String command = 'price', // вне tableCommands — проверяем список, как раньше
}) =>
    WarehouseCard(
      connector: 'warehouse', command: command, title: 'Где лежит товар',
      say: '«тунли 67432»: 1 позиция, всего 1 шт.', rows: rows, hidden: hidden,
    );
```

Во всех существующих вызовах `_card(...)` явный `command` не нужен —
дефолт `'price'` сохраняет прежнее поведение (список). Это единственная
правка существующих тестов в этом шаге.

- [ ] **Step 2: Дописать в тот же файл новые падающие тесты на табличный вид**

```dart
testWidgets('command «where»: таблица вместо списка', (WidgetTester tester) async {
  await _pump(
    tester,
    WarehouseCardView(card: _card(const <WarehouseRow>[_tunli], command: 'where')),
  );
  expect(find.byKey(const ValueKey<String>('reply-table')), findsOneWidget);
  expect(find.byKey(const ValueKey<String>('warehouse-card-row-0')), findsNothing);
});

testWidgets('command вне списка со строками: список, как раньше', (WidgetTester tester) async {
  await _pump(
    tester,
    WarehouseCardView(card: _card(const <WarehouseRow>[_tunli], command: 'price')),
  );
  expect(find.byKey(const ValueKey<String>('reply-table')), findsNothing);
  expect(find.byKey(const ValueKey<String>('warehouse-card-row-0')), findsOneWidget);
});

testWidgets('command «where», onOpenLink null: таблица не падает, не нажимается', (WidgetTester tester) async {
  await _pump(
    tester,
    WarehouseCardView(card: _card(const <WarehouseRow>[_tunli], command: 'where')),
  );
  await tester.tap(find.byKey(const ValueKey<String>('reply-table-row-0')));
  // Не падает — этого достаточно; onOpenLink не задан у этого WarehouseCardView.
});

testWidgets('command «unposted», onOpenLink задан: ссылка доходит до таблицы', (WidgetTester tester) async {
  final opened = <String>[];
  await _pump(
    tester,
    WarehouseCardView(
      card: _card(const <WarehouseRow>[_tunli], command: 'unposted'),
      onOpenLink: (String kind, String id) => opened.add('$kind:$id'),
    ),
  );
  await tester.tap(find.byKey(const ValueKey<String>('reply-table-row-0')));
  expect(opened, <String>['sku:67432']);
});
```

- [ ] **Step 3: Запустить весь файл и убедиться, что новые тесты падают, а старые (после Step 1) — проходят**

Run: `flutter test test/app/warehouse_card_view_test.dart`
Expected: старые тесты PASS, четыре новых из Step 2 — FAIL (нет ветки на таблицу)

- [ ] **Step 4: В `lib/app/widgets/warehouse_card_view.dart` добавить ветку на таблицу**

В `build()`, после вычисления `rows` (уже свёрнутый список, переменная
перед текущим `for (var i = 0; i < rows.length; i++)`), добавить:

```dart
final table = card.asTable(rows);
```

и заменить блок `for (var i...) ... _row(rows[i], i)` на условный: если
`table != null` — один `ReplyTableView(key: const ValueKey<String>('reply-table'), table: table, onOpenLink: widget.onOpenLink)`;
иначе — прежний цикл с `_row`/`Divider`. Остальное (заголовок, `say`,
«Показать все», `hidden`/`more`, кнопка «Открыть…») не меняется и стоит
вне этого условия, как сейчас.

- [ ] **Step 5: Запустить весь файл, убедиться, что все тесты проходят**

Run: `flutter test test/app/warehouse_card_view_test.dart`
Expected: PASS (все, включая новые)

- [ ] **Step 6: `flutter test`, `flutter analyze`, `dart format` на весь проект**

Run: `dart format --output=none --set-exit-if-changed lib test tool && flutter analyze && flutter test`
Expected: чисто, все ~8,5 тыс. тестов проходят

- [ ] **Step 7: Commit**

```bash
git add lib/app/widgets/warehouse_card_view.dart test/app/warehouse_card_view_test.dart
git commit -m "feat: WarehouseCardView рисует таблицу для where/count/cell/unposted"
```

---

## Task 4: веб-помощник показывает ту же таблицу

**Files:**
- Create: `test/web_widget/reply_table_view_test.dart`

**Interfaces:**
- Consumes: `ReplyTableView` (Task 2), `WarehouseCardView` (Task 3) — без изменений кода, только проверка.

Виджет общий (`lib/app/widgets/`) и уже используется веб-помощником
(`lib/web_widget/widget_app.dart:660`) без изменений вызова — отдельного
кода для веба не требуется. Этот таск — тесты, подтверждающие, что
общий виджет действительно пригоден для веба: не тянет запрещённые
импорты (структурно гарантирует `test/web_widget/web_graph_test.dart`,
раз файл лежит вне `ioFree`-исключений и не импортирует их) и рисует
то же самое под веб-помощником, что и в приложении.

- [ ] **Step 1: Написать `test/web_widget/reply_table_view_test.dart`**

Тот же набор проверок, что в `test/app/reply_table_view_test.dart`
(Task 2, Step 1: заголовки, полоса группы, зебра, нажатие строки со
ссылкой) — скопировать файл и импорты без изменений логики теста.
Это не дублирование продукта (виджет один), а подтверждение, что он
компилируется и ведёт себя одинаково в тестовом окружении
`test/web_widget/`, где раньше у `WarehouseCardView`/`ReplyTableView`
своего теста не было вовсе.

- [ ] **Step 2: Запустить и убедиться, что проходит (виджет уже реализован в Task 2)**

Run: `flutter test test/web_widget/reply_table_view_test.dart`
Expected: PASS

- [ ] **Step 3: Прогнать граф импортов веб-помощника**

Run: `flutter test test/web_widget/web_graph_test.dart`
Expected: PASS (новый файл не добавляет запрещённых импортов)

- [ ] **Step 4: Commit**

```bash
git add test/web_widget/reply_table_view_test.dart
git commit -m "test: ReplyTableView в тестовом окружении веб-помощника"
```

---

## Task 5: документация

**Files:**
- Modify: `docs/ARCHITECTURE.md` (раздел о карточке склада / ADR-027, если там описана `WarehouseCardView`)
- Modify: `docs/DECISIONS.md` (дополнение к ADR-031 или ADR-027 — где уже описана карточка склада)

**Interfaces:** нет (документация).

- [ ] **Step 1: Найти, где уже описана `WarehouseCardView`/карточка склада**

Run: `grep -rn "WarehouseCardView\|карточка склада" docs/ARCHITECTURE.md docs/DECISIONS.md`

- [ ] **Step 2: Дописать туда короткий абзац**

О `ReplyTable`/`ReplyTableView`: общая возможность оформить ответ
таблицей (не только склад), первый потребитель — карточка склада для
`where`/`count`/`cell`/`unposted`; протокол и формат истории чата не
изменились (таблица — пересчёт на лету). Ссылка на дизайн-документ
(`docs/superpowers/specs/2026-11-23-reply-table-design.md`).

- [ ] **Step 3: Commit**

```bash
git add docs/ARCHITECTURE.md docs/DECISIONS.md
git commit -m "docs: таблица в ответе склада (ReplyTable/ReplyTableView)"
```
