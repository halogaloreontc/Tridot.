// Быстрые действия над полем ввода (макет «Д»): «Задача», «Напомнить»,
// «Пароль» — только крупными в пустой сессии, «Пароль» — только с
// навыком; после первой команды остаются лишь кнопки ролей и выбранной
// задачи.
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
  testWidgets('пустая сессия: круглые кнопки 52 px с подписями',
      (tester) async {
    final calls = await _pump(tester, big: true, onPassword: () {});
    for (final label in <String>['Задача', 'Напомнить', 'Пароль']) {
      expect(find.byKey(Key('quick-$label')), findsOneWidget, reason: label);
      expect(find.text(label), findsOneWidget);
    }
    final circle = find.descendant(
      of: find.byKey(const Key('quick-Задача')),
      matching: find.byType(Container),
    );
    expect(tester.getSize(circle.first), const Size(52, 52));
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
