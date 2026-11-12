// Быстрые действия над полем ввода (макет «Д»): крупные в пустой сессии,
// «пилюли» после первой команды, «Пароль» — только с навыком, кнопки ролей
// и выбранной задачи остаются.
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
}) async {
  final calls = <String>[];
  tester.view.physicalSize = const Size(390, 844);
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

  testWidgets('после команд: «пилюли» 44 px в ряд на всю ширину',
      (tester) async {
    await _pump(tester, big: false, onPassword: () {});
    final rects = <Rect>[
      for (final label in <String>['Задача', 'Напомнить', 'Пароль'])
        tester.getRect(find.byKey(Key('quick-$label'))),
    ];
    for (final rect in rects) {
      expect(rect.height, 44);
      expect(rect.top, rects.first.top);
      expect(rect.width, moreOrLessEquals(rects.first.width));
    }
  });

  testWidgets('«Пароль» — только с навыком «Пароли»', (tester) async {
    await _pump(tester, big: false);
    expect(find.byKey(const Key('quick-Пароль')), findsNothing);
    expect(find.byKey(const Key('quick-Задача')), findsOneWidget);
    expect(find.byKey(const Key('quick-Напомнить')), findsOneWidget);
    var opened = 0;
    await _pump(tester, big: false, onPassword: () => opened++);
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
  });
}
