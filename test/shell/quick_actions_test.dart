// Быстрые действия над полем ввода (макет «Д»): «Задача», «Напомнить»,
// «Пароль» — только крупными в пустой сессии, «Пароль» — только с
// навыком. В начатой переписке — одна строка поверх ленты
// (QuickActionsRow): без фона, прокрутка вбок, пусто — ничего.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/shell/quick_actions.dart';
import 'package:local_assistant/core/extensions/role.dart';

Future<List<String>> _pump(
  WidgetTester tester, {
  required bool big,
  VoidCallback? onPassword,
  bool hasSelection = false,
  List<RoleChip> chips = const <RoleChip>[],
  Size size = const Size(390, 844),
}) async {
  final calls = <String>[];
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.dark(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: QuickActions(
              big: big,
              sending: false,
              hasSelection: hasSelection,
              roleChips: chips,
              onPassword: onPassword,
              onSend: ([String? text]) async => calls.add('send:$text'),
              onTemplate: (String t) => calls.add('template:$t'),
            ),
          ),
        ),
      ),
    ),
  );
  return calls;
}

void main() {
  group('строка начатой переписки (QuickActionsRow)', () {
    Future<void> pumpRow(WidgetTester tester, List<QuickRowItem> items) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final theme in <ThemeData>[
        AssistantTheme.light(),
        AssistantTheme.dark(),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: QuickActionsRow(items: items),
              ),
            ),
          ),
        );
      }
    }

    testWidgets('пусто — ничего и без места', (tester) async {
      await pumpRow(tester, const <QuickRowItem>[]);
      expect(find.byKey(const Key('quick-float-row')), findsNothing);
    });

    testWidgets('одна строка 44, без фона, лишнее — прокруткой',
        (tester) async {
      var taps = 0;
      await pumpRow(tester, <QuickRowItem>[
        for (var i = 0; i < 8; i++)
          (Key('row-$i'), ('Действие номер $i', Icons.check, () => taps++)),
      ]);
      final row = find.byKey(const Key('quick-float-row'));
      expect(tester.getSize(row).height, QuickActionsRow.height);
      // Все кнопки — на одной линии.
      final tops = <double>{
        for (var i = 0; i < 8; i++)
          tester.getRect(find.byKey(Key('row-$i'))).top,
      };
      expect(tops, hasLength(1));
      // Фона у строки нет: ни одного DecoratedBox шире кнопки.
      final wide = tester
          .widgetList<Container>(
            find.descendant(of: row, matching: find.byType(Container)),
          )
          .where((Container c) => c.decoration != null)
          .map((Container c) => c.constraints?.maxWidth ?? 0)
          .where((double w) => w.isFinite && w >= 390);
      expect(wide, isEmpty);
      expect(find.byType(Scrollbar), findsNothing);
      await tester.tap(find.byKey(const Key('row-0')));
      expect(taps, 1);
      await tester.dragUntilVisible(
        find.byKey(const Key('row-7')),
        row,
        const Offset(-200, 0),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('row-7')));
      expect(taps, 2);
    });
  });

  testWidgets('пустая сессия: плитки не ниже 72 с подписями, без рамок',
      (tester) async {
    final calls = await _pump(tester, big: true, onPassword: () {});
    for (final label in <String>['Задача', 'Напомнить', 'Пароль']) {
      expect(find.byKey(Key('quick-$label')), findsOneWidget, reason: label);
      expect(find.text(label), findsOneWidget);
      final tile = tester.getSize(find.byKey(Key('quick-$label')));
      expect(tile.height, greaterThanOrEqualTo(72), reason: label);
    }
    // Плитка — заливкой (ADR-027): ни одной рамки внутри.
    final borders = tester
        .widgetList<Container>(
          find.descendant(
            of: find.byKey(const Key('quick-Задача')),
            matching: find.byType(Container),
          ),
        )
        .where(
          (Container c) =>
              c.decoration is BoxDecoration &&
              (c.decoration! as BoxDecoration).border != null,
        );
    expect(borders, isEmpty);
    await tester.tap(find.byKey(const Key('quick-Задача')));
    await tester.tap(find.byKey(const Key('quick-Напомнить')));
    expect(calls, <String>[
      'template:${QuickActions.taskTemplate}',
      'template:${QuickActions.remindTemplate}',
    ]);
  });

  testWidgets('узкий телефон и крупный шрифт: три кнопки в одну строку',
      (tester) async {
    for (final scale in <double>[1.0, 1.15, 1.3, 2.0]) {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _pump(
        tester,
        big: true,
        onPassword: () {},
        size: const Size(320, 640),
      );
      final ys = <double>{
        for (final label in <String>['Задача', 'Напомнить', 'Пароль'])
          tester.getTopLeft(find.byKey(Key('quick-$label'))).dy,
      };
      expect(ys, hasLength(1), reason: 'масштаб $scale');
      final right = tester.getTopRight(find.byKey(const Key('quick-Пароль')));
      expect(right.dx, lessThanOrEqualTo(320), reason: 'масштаб $scale');
    }
  });

  testWidgets('после команд «Задачи», «Напомнить» и «Пароля» нет',
      (tester) async {
    await _pump(tester, big: false, onPassword: () {});
    for (final label in <String>['Задача', 'Напомнить', 'Пароль']) {
      expect(find.byKey(Key('quick-$label')), findsNothing, reason: label);
    }
    // Ни ролей, ни выбранной задачи — пусто, без отступа.
    expect(find.byKey(const Key('quick-actions')), findsNothing);
    expect(find.byKey(const Key('quick-strip')), findsNothing);
    expect(tester.getSize(find.byType(QuickActions)).height, 0);
  });

  testWidgets('«Пароль» — только с навыком «Пароли»', (tester) async {
    await _pump(tester, big: true);
    expect(find.byKey(const Key('quick-Пароль')), findsNothing);
    expect(find.byKey(const Key('quick-Задача')), findsOneWidget);
    expect(find.byKey(const Key('quick-Напомнить')), findsOneWidget);
    var opened = 0;
    await _pump(tester, big: true, onPassword: () => opened++);
    await tester.tap(find.byKey(const Key('quick-Пароль')));
    expect(opened, 1);
  });

  testWidgets('кнопки ролей и выбранной задачи остаются', (tester) async {
    final calls = await _pump(
      tester,
      big: false,
      hasSelection: true,
      chips: const <RoleChip>[
        RoleChip(
          label: 'Без фото',
          icon: 'photo',
          text: 'товары без фото',
          action: RoleChipAction.send,
        ),
      ],
    );
    expect(find.byKey(const Key('quick-rows')), findsOneWidget);
    for (final label in <String>['Перенести', 'Заверши её', 'Без фото']) {
      expect(find.byKey(Key('quick-$label')), findsOneWidget, reason: label);
    }
    await tester.tap(find.byKey(const Key('quick-Без фото')));
    await tester.tap(find.byKey(const Key('quick-Заверши её')));
    expect(calls, <String>['send:товары без фото', 'send:Заверши её']);
    expect(find.byKey(const Key('quick-Покажи задачи')), findsNothing);
    // Основных кнопок рядом с ними нет: сессия уже не новая.
    expect(find.byKey(const Key('quick-Задача')), findsNothing);
  });
}
