// «Найти команду» — шторкой (ADR-020, ADR-027): поле поиска заливкой на
// уровень контрастнее шторки в обеих темах (принцип 5).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/widgets/command_finder_sheet.dart';
import 'package:local_assistant/core/commands/command_catalog.dart';

void main() {
  for (final (name, theme, palette) in <(String, ThemeData, AppPalette)>[
    ('тёмная', AssistantTheme.dark(), AppPalette.dark),
    ('светлая', AssistantTheme.light(), AppPalette.light),
  ]) {
    testWidgets('$name: поле поиска не сливается со шторкой', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                key: const Key('open'),
                onPressed: () => showCommandFinder(
                  context,
                  CommandCatalog.build(connectors: const []),
                ),
                child: const Text('Открыть'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      final sheet = Theme.of(
        tester.element(find.byType(CommandFinderSheet)),
      ).bottomSheetTheme.modalBackgroundColor;
      final decorator = tester.widget<InputDecorator>(
        find.descendant(
          of: find.byKey(const Key('command-search')),
          matching: find.byType(InputDecorator),
        ),
      );
      final fill = decorator.decoration.fillColor ??
          theme.inputDecorationTheme.fillColor;
      expect(sheet, palette.background);
      expect(fill, palette.workspace);
      expect(fill, isNot(sheet));
    });
  }
}
