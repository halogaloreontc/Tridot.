// Круглые кнопки на панели поля ввода — «+», крестик голосового ввода,
// пустая отправка и выключенный микрофон — видны кругом, а не одним
// значком: их заливка не совпадает с заливкой панели (была та же
// [AppPalette.raised], и круг пропадал).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/widgets/command_composer.dart';

Future<void> _pump(
  WidgetTester tester, {
  required ThemeData theme,
  VoiceButtonMode voice = VoiceButtonMode.hidden,
}) async {
  final controller = TextEditingController();
  final focus = FocusNode();
  addTearDown(controller.dispose);
  addTearDown(focus.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: CommandComposer(
            controller: controller,
            focusNode: focus,
            sending: false,
            mode: AssistantViewMode.dialogue,
            onModeChanged: (_) {},
            onSend: () {},
            onCommand: (_) {},
            previousCommand: () => null,
            nextCommand: () => null,
            voiceMode: voice,
            onVoiceTap: () {},
            onVoiceCancel: () {},
          ),
        ),
      ),
    ),
  );
}

Color _panel(WidgetTester tester) => (tester
        .widget<Container>(find.byKey(const Key('assistant-composer')))
        .decoration! as BoxDecoration)
    .color!;

/// Круг внутри кнопки [key]: его заливка и размер.
(Color, Size) _circle(WidgetTester tester, String key) {
  final finder = find
      .descendant(
        of: find.byKey(Key(key)),
        matching: find.byWidgetPredicate(
          (Widget w) =>
              (w is Container &&
                  w.decoration is BoxDecoration &&
                  (w.decoration! as BoxDecoration).shape == BoxShape.circle) ||
              (w is AnimatedContainer &&
                  w.decoration is BoxDecoration &&
                  (w.decoration! as BoxDecoration).shape == BoxShape.circle),
        ),
      )
      .first;
  final w = tester.widget(finder);
  final decoration = (w is Container
      ? w.decoration
      : (w as AnimatedContainer).decoration)! as BoxDecoration;
  return (decoration.color!, tester.getSize(finder));
}

void main() {
  final themes = <String, (ThemeData Function(), AppPalette)>{
    'тёмная': (AssistantTheme.dark, AppPalette.dark),
    'светлая': (AssistantTheme.light, AppPalette.light),
  };
  for (final MapEntry(key: name, value: (theme, palette)) in themes.entries) {
    testWidgets('$name: «+» — круг, а не один значок', (tester) async {
      await _pump(tester, theme: theme());
      final (color, size) = _circle(tester, 'templates-button');
      expect(color, isNot(_panel(tester)));
      expect(color, palette.fieldOnRaised);
      expect(size, const Size(44, 44));
    });

    testWidgets('$name: пустая отправка — тоже круг', (tester) async {
      await _pump(tester, theme: theme());
      final button =
          tester.widget<IconButton>(find.byKey(const Key('assistant-send')));
      final background =
          button.style!.backgroundColor!.resolve(<WidgetState>{});
      expect(background, isNot(_panel(tester)));
      expect(
        button.style!.fixedSize!.resolve(<WidgetState>{}),
        const Size(44, 44),
      );
      // Круг отправки того же размера, что «+» (тема просила 48).
      final send = find.descendant(
        of: find.byKey(const Key('assistant-send')),
        matching: find.byType(Material),
      );
      expect(tester.getSize(send.first), const Size(44, 44));
    });

    testWidgets('$name: крестик голосового ввода и выключенный микрофон',
        (tester) async {
      await _pump(tester, theme: theme(), voice: VoiceButtonMode.listening);
      final (abort, size) = _circle(tester, 'voice-abort');
      expect(abort, isNot(_panel(tester)));
      expect(size, const Size(44, 44));

      await _pump(tester, theme: theme(), voice: VoiceButtonMode.off);
      final (mic, _) = _circle(tester, 'assistant-voice');
      expect(mic, isNot(_panel(tester)));
    });
  }
}
