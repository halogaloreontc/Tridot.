// Окна подтверждения и разрешения (ADR-027, поправка «плотнее»): одна
// ширина, кнопки одной высоты в ряд справа или столбиком (главная сверху),
// шторка с плиткой значка и кнопками внизу.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/layout.dart';
import 'package:local_assistant/app/widgets/app_dialog.dart';
import 'package:local_assistant/app/widgets/grouped.dart';

Future<void> _open(
  WidgetTester tester,
  WidgetBuilder dialog, {
  double width = 390,
  bool sheet = false,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      key: UniqueKey(),
      theme: AssistantTheme.light(),
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: TextButton(
              key: const Key('open'),
              onPressed: () => sheet
                  ? showAppSheet<void>(context: context, builder: dialog)
                  : showDialog<void>(context: context, builder: dialog),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open')));
  await tester.pumpAndSettle();
}

/// Лист окна — без полей `insetPadding` вокруг.
final Finder _surface = find
    .descendant(of: find.byType(Dialog), matching: find.byType(Material))
    .first;

Widget _dialog(List<Widget> actions, {Widget? content}) => AppDialog(
      title: const Text('Удалить проект?'),
      content: content ?? const Text('Удаление нельзя отменить.'),
      actions: actions,
    );

void main() {
  testWidgets('две кнопки — в ряд справа, одной высоты, зазор 8', (
    tester,
  ) async {
    await _open(
      tester,
      (_) => _dialog(<Widget>[
        TextButton(
          key: const Key('cancel'),
          onPressed: () {},
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const Key('ok'),
          onPressed: () {},
          child: const Text('Скачать'),
        ),
      ]),
    );
    expect(find.byType(AlertDialog), findsOneWidget);
    final cancel = tester.getRect(find.byKey(const Key('cancel')));
    final ok = tester.getRect(find.byKey(const Key('ok')));
    expect(cancel.height, ok.height);
    expect(ok.top, cancel.top);
    expect(ok.left, greaterThan(cancel.right));
    final render = tester.renderObject<RenderConfirmActions>(
      find.byType(ConfirmActions),
    );
    expect(render.stacked, isFalse);
    // Видимая кнопка — 44, цель нажатия — 48.
    final filled = tester.getRect(
      find.descendant(
        of: find.byKey(const Key('ok')),
        matching: find.byType(Material),
      ),
    );
    expect(filled.height, AppSize.button);
    expect(ok.height, greaterThanOrEqualTo(48));
    // Главная — у правого края текста окна.
    final dialog = tester.getRect(_surface);
    expect(dialog.right - ok.right, AppDialogMetrics.actionsH);
  });

  testWidgets('не помещаются — столбиком во всю ширину, главная сверху', (
    tester,
  ) async {
    await _open(
      tester,
      (_) => _dialog(<Widget>[
        TextButton(
          key: const Key('cancel'),
          onPressed: () {},
          child: const Text('Отмена'),
        ),
        TextButton(
          key: const Key('danger'),
          onPressed: () {},
          child: const Text('Удалить вместе с сессиями (3)'),
        ),
        FilledButton(
          key: const Key('main'),
          onPressed: () {},
          child: const Text('Вынести сессии из проекта'),
        ),
      ]),
    );
    final main = tester.getRect(find.byKey(const Key('main')));
    final danger = tester.getRect(find.byKey(const Key('danger')));
    final cancel = tester.getRect(find.byKey(const Key('cancel')));
    expect(main.bottom, lessThanOrEqualTo(danger.top));
    expect(danger.bottom, lessThanOrEqualTo(cancel.top));
    expect(main.width, danger.width);
    expect(danger.width, cancel.width);
    expect(
      tester
          .renderObject<RenderConfirmActions>(find.byType(ConfirmActions))
          .stacked,
      isTrue,
    );
  });

  testWidgets('окно с полем и окно с текстом — одной ширины', (tester) async {
    final widths = <double>[];
    for (final content in <Widget>[
      const Text('Да?'),
      const TextField(),
      const Text(
        'Длинный текст окна, который переносится на несколько строк и не '
        'должен расширять окно сверх общей ширины.',
      ),
    ]) {
      await _open(
        tester,
        (_) => _dialog(
          <Widget>[TextButton(onPressed: () {}, child: const Text('Ок'))],
          content: content,
        ),
      );
      widths.add(tester.getSize(_surface).width);
    }
    expect(widths.toSet(), hasLength(1));
    expect(
      widths.first,
      AppDialogMetrics.contentWidth + 2 * AppDialogMetrics.padH,
    );
    // Узкий телефон: окно сжимается до полей экрана.
    await _open(tester, (_) => _dialog(const <Widget>[]), width: 320);
    expect(tester.getSize(_surface).width, 320 - 2 * 16);
  });

  testWidgets('шрифты окна: заголовок 18/600, текст 15', (tester) async {
    await _open(tester, (_) => _dialog(const <Widget>[]));
    final title = DefaultTextStyle.of(
      tester.element(find.text('Удалить проект?')),
    ).style;
    final body = DefaultTextStyle.of(
      tester.element(find.text('Удаление нельзя отменить.')),
    ).style;
    expect(title.fontSize, 18);
    expect(title.fontWeight, FontWeight.w600);
    expect(body.fontSize, 15);
  });

  testWidgets('шторка: ручка, плитка значка, кнопки внизу справа', (
    tester,
  ) async {
    await _open(
      tester,
      sheet: true,
      (_) => AppSheet(
        icon: Icons.notifications_active_outlined,
        title: const Text('Напоминания вовремя'),
        body: const Text('Нужно разрешить уведомления.'),
        actions: <Widget>[
          TextButton(onPressed: () {}, child: const Text('Не сейчас')),
          FilledButton(
            key: const Key('allow'),
            onPressed: () {},
            child: const Text('Разрешить'),
          ),
        ],
      ),
    );
    final sheet = tester.getRect(find.byType(BottomSheet));
    // Своя ручка 32×4 без поля 48 у ручки темы: заголовок — в 24 от края
    // шторки, а для диктора ручка по-прежнему кнопка «закрыть».
    final handle = tester.getRect(find.byKey(const Key('sheet-handle')));
    expect(handle.size, const Size(32, 4));
    expect(handle.top - sheet.top, AppSpace.xs);
    final titleTop = tester.getRect(find.text('Напоминания вовремя')).top;
    expect(titleTop - sheet.top, lessThanOrEqualTo(28));
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.bySemanticsLabel('Dismiss'),
      ),
      findsOneWidget,
    );
    final allow = tester.getRect(find.byKey(const Key('allow')));
    expect(sheet.right - allow.right, AppDialogMetrics.actionsH);
    final body = DefaultTextStyle.of(
      tester.element(find.text('Нужно разрешить уведомления.')),
    ).style;
    expect(body.fontSize, 15);
    final title = DefaultTextStyle.of(
      tester.element(find.text('Напоминания вовремя')),
    ).style;
    expect(title.fontSize, 18);
  });

  testWidgets('ручка шторки: «закрыть» для диктора — цель 48×48, закрывает', (
    tester,
  ) async {
    await _open(
      tester,
      sheet: true,
      (_) => const AppSheet(title: Text('Облачный диск')),
    );
    final handle = tester.getSemantics(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.bySemanticsLabel('Dismiss'),
      ),
    );
    expect(handle.rect.width, greaterThanOrEqualTo(48));
    expect(handle.rect.height, greaterThanOrEqualTo(48));
    await tester.tapAt(
      tester.getRect(find.byKey(const Key('sheet-handle'))).center,
    );
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('длинные подписи кнопок столбиком — по центру', (tester) async {
    await _open(
      tester,
      width: 320,
      (_) => _dialog(<Widget>[
        TextButton(
          onPressed: () {},
          child: const ActionLabel('Вынести сессии из проекта'),
        ),
        FilledButton(
          onPressed: () {},
          child: const ActionLabel('Удалить вместе с сессиями (3)'),
        ),
      ]),
    );
    for (final label in <String>[
      'Вынести сессии из проекта',
      'Удалить вместе с сессиями (3)',
    ]) {
      final text = tester.widget<Text>(find.text(label));
      expect(text.textAlign, TextAlign.center);
    }
  });

  testWidgets('плитка значка — у первой строки длинного заголовка', (
    tester,
  ) async {
    await _open(
      tester,
      width: 320,
      (_) => const AppDialog(
        icon: Icons.cloud_outlined,
        title: Text('Удалить проект и все его сессии вместе с задачами?'),
        content: Text('Удаление нельзя отменить.'),
      ),
    );
    final title = tester.getRect(
      find.text('Удалить проект и все его сессии вместе с задачами?'),
    );
    final tile = tester.getRect(find.byType(IconTile));
    expect(title.height, greaterThan(2 * tile.height));
    // Середина плитки — на середине первой строки (18 × 1.33), а не
    // посреди двух-трёх строк.
    expect(tile.center.dy - title.top, closeTo(18 * 1.33 / 2, 1));
  });

  testWidgets('окно со списком просит шире — на десктопе не сжимается', (
    tester,
  ) async {
    await _open(
      tester,
      width: 1280,
      (_) => const AppDialog(
        contentWidth: 480,
        title: Text('Сохранить сюда'),
        content: SizedBox(key: Key('wide'), width: 480, height: 100),
      ),
    );
    expect(tester.getSize(find.byKey(const Key('wide'))).width, 480);
  });
}
