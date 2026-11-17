// Сгруппированные списки «как в Заметках» (ADR-027, шаг S3): группа на
// заливке без рамки, строки не ниже 48, разделители «вставкой», значение
// под заголовком при крупном шрифте, выбор галочкой, крупный заголовок и
// поиск — в обеих темах.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/widgets/grouped.dart';

const _themes = <String, ThemeData Function()>{
  'тёмная': AssistantTheme.dark,
  'светлая': AssistantTheme.light,
};

Future<void> _pump(
  WidgetTester tester,
  ThemeData theme,
  Widget child, {
  double scale = 1,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
        child: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
}

void main() {
  for (final MapEntry(key: name, value: make) in _themes.entries) {
    final theme = make();
    final p = theme.extension<AppPalette>()!;

    group(name, () {
      testWidgets('группа: заливка листа, скругление 12, без рамки',
          (tester) async {
        await _pump(
          tester,
          theme,
          InsetGroup(
            header: 'Интерфейс',
            footer: 'Пояснение',
            children: <Widget>[
              const GroupedRow(key: Key('b'), title: 'Без значка'),
              GroupedRow(
                key: const Key('a'),
                icon: Icons.contrast,
                tile: p.tileViolet,
                title: 'Оформление',
                value: 'Как в системе',
                chevron: true,
                onTap: () {},
              ),
            ],
          ),
        );
        expect(find.text('Интерфейс'), findsOneWidget);
        expect(find.text('Пояснение'), findsOneWidget);
        final clip = tester.widget<ClipRRect>(find.byType(ClipRRect).first);
        expect(clip.borderRadius, BorderRadius.circular(12));
        final material = tester.widget<Material>(
          find
              .descendant(
                of: find.byType(ClipRRect).first,
                matching: find.byType(Material),
              )
              .first,
        );
        expect(material.color, p.workspace);
        expect(material.shape, isNull);
        // Строки не ниже 48, значение 16 приглушённым — справа.
        for (final key in <String>['a', 'b']) {
          expect(
            tester.getSize(find.byKey(Key(key))).height,
            greaterThanOrEqualTo(48),
          );
        }
        final title = tester.getRect(find.text('Оформление'));
        final value = tester.getRect(find.text('Как в системе'));
        expect(value.left, greaterThan(title.right));
        // Разделитель «вставкой» 0,5 — по строке над ним: под строкой без
        // значка — от 16.
        final separator = find.byWidgetPredicate(
          (Widget w) => w is ColoredBox && w.color == p.divider,
        );
        expect(separator, findsOneWidget);
        expect(tester.getSize(separator).height, 0.5);
        expect(
          tester.getRect(separator).left -
              tester.getRect(find.byType(ClipRRect).first).left,
          16,
        );
      });

      testWidgets('под строкой со значком — разделитель от 56', (tester) async {
        await _pump(
          tester,
          theme,
          InsetGroup(
            children: <Widget>[
              const GroupedRow(title: 'Первая', icon: Icons.save_outlined),
              GroupedRow(
                title: 'Вторая',
                icon: Icons.folder_outlined,
                tile: p.tileAmber,
              ),
            ],
          ),
        );
        final separator = find.byWidgetPredicate(
          (Widget w) => w is ColoredBox && w.color == p.divider,
        );
        expect(
          tester.getRect(separator).left -
              tester.getRect(find.byType(ClipRRect).first).left,
          56,
        );
        // Плитка 28 со скруглением 7, глиф белый.
        final tile = tester.widget<IconTile>(find.byType(IconTile));
        expect(tile.color, p.tileAmber);
        expect(tester.getSize(find.byType(IconTile)), const Size(28, 28));
      });

      testWidgets('крупный шрифт: значение — под заголовком', (tester) async {
        await _pump(
          tester,
          theme,
          const InsetGroup(
            children: <Widget>[
              GroupedRow(title: 'Оформление', value: 'Как в системе'),
            ],
          ),
          scale: 2,
          size: const Size(320, 800),
        );
        final title = tester.getRect(find.text('Оформление'));
        final value = tester.getRect(find.text('Как в системе'));
        expect(value.top, greaterThanOrEqualTo(title.bottom - 1));
        expect(tester.takeException(), isNull);
      });

      testWidgets('опасное действие — цветом ошибки по центру', (tester) async {
        var taps = 0;
        await _pump(
          tester,
          theme,
          InsetGroup(
            children: <Widget>[
              GroupedRow(
                key: const Key('del'),
                title: 'Удалить',
                destructive: true,
                onTap: () => taps++,
              ),
            ],
          ),
        );
        final text = tester.widget<Text>(find.text('Удалить'));
        expect(text.style?.color, p.danger);
        await tester.tap(find.byKey(const Key('del')));
        expect(taps, 1);
      });

      testWidgets('переключатель — SwitchListTile, тап по строке',
          (tester) async {
        var value = false;
        await _pump(
          tester,
          theme,
          StatefulBuilder(
            builder: (BuildContext context, StateSetter set) => InsetGroup(
              children: <Widget>[
                GroupedSwitchRow(
                  key: const Key('sw'),
                  title: 'Меньше анимации',
                  subtitle: 'Кубик и переходы без движения',
                  value: value,
                  onChanged: (bool v) => set(() => value = v),
                ),
              ],
            ),
          ),
        );
        expect(
          tester.widget<SwitchListTile>(find.byKey(const Key('sw'))).value,
          isFalse,
        );
        await tester.tap(find.text('Меньше анимации'));
        await tester.pump();
        expect(value, isTrue);
      });

      testWidgets('выбор галочкой акцентом, одна выбрана', (tester) async {
        var selected = 'b';
        await _pump(
          tester,
          theme,
          StatefulBuilder(
            builder: (BuildContext context, StateSetter set) =>
                GroupedChoiceList<String>(
              header: 'Снова спрашивать',
              options: const <String>['a', 'b', 'c'],
              selected: selected,
              label: (String o) => 'Вариант $o',
              optionKey: (String o) => Key('opt-$o'),
              onSelected: (String o) => set(() => selected = o),
            ),
          ),
        );
        Finder check(String o) => find.descendant(
              of: find.byKey(Key('opt-$o')),
              matching: find.byIcon(Icons.check),
            );
        expect(check('b'), findsOneWidget);
        expect(check('a'), findsNothing);
        expect(tester.widget<Icon>(check('b')).color, p.accent);
        await tester.tap(find.byKey(const Key('opt-c')));
        await tester.pump();
        expect(check('c'), findsOneWidget);
        expect(check('b'), findsNothing);
      });

      testWidgets('крупный заголовок 26 w700 и поиск без рамки',
          (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        await _pump(
          tester,
          theme,
          Column(
            children: <Widget>[
              const LargeTitle('Настройки'),
              SearchField(controller: controller),
            ],
          ),
        );
        final title = tester.widget<Text>(
          find.descendant(
            of: find.byType(LargeTitle),
            matching: find.byType(Text),
          ),
        );
        final style = DefaultTextStyle.of(
          tester.element(find.text('Настройки')),
        ).style.merge(title.style);
        expect(style.fontSize, 26);
        expect(style.fontWeight, FontWeight.w700);
        final field = tester.widget<TextField>(find.byType(TextField));
        final border = field.decoration!.enabledBorder! as OutlineInputBorder;
        expect(border.borderSide, BorderSide.none);
        expect(field.decoration!.fillColor, p.workspace);
        expect(
          tester.getSize(find.byType(SearchField)).height,
          greaterThanOrEqualTo(48),
        );
      });
    });
  }
}
