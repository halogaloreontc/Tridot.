import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/widgets/command_composer.dart';
import 'package:local_assistant/core/chats/attachments.dart';

/// Голосовые жесты поля ввода (ADR-023) без главного экрана.
final class _Calls {
  int tap = 0;
  int longPress = 0;
  int cancel = 0;
}

Future<_Calls> _pump(
  WidgetTester tester, {
  required VoiceButtonMode mode,
  List<PendingAttachmentChip> pending = const <PendingAttachmentChip>[],
  String text = '',
  bool sending = false,
}) async {
  final calls = _Calls();
  final controller = TextEditingController(text: text);
  final focus = FocusNode();
  addTearDown(controller.dispose);
  addTearDown(focus.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.dark(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: CommandComposer(
            controller: controller,
            focusNode: focus,
            sending: sending,
            mode: AssistantViewMode.dialogue,
            onModeChanged: (_) {},
            onSend: () {},
            onCommand: (_) {},
            previousCommand: () => null,
            nextCommand: () => null,
            pending: pending,
            voiceMode: mode,
            onVoiceTap: () => calls.tap++,
            onVoiceLongPress: () => calls.longPress++,
            onVoiceCancel: () => calls.cancel++,
          ),
        ),
      ),
    ),
  );
  return calls;
}

const _input = Key('assistant-input');

void main() {
  testWidgets('долгое нажатие на пустое готовое поле — голосовой ввод',
      (tester) async {
    final calls = await _pump(tester, mode: VoiceButtonMode.idle);
    await tester.longPress(find.byKey(_input));
    await tester.pump();
    expect(calls.longPress, 1);
    expect(calls.tap, 0);
  });

  testWidgets('с выбранным файлом долгое нажатие ничего не включает',
      (tester) async {
    final calls = await _pump(
      tester,
      mode: VoiceButtonMode.idle,
      pending: const <PendingAttachmentChip>[
        PendingAttachmentChip(
          name: 'отчёт.pdf',
          kind: AttachmentKind.document,
          size: 1024,
        ),
      ],
    );
    expect(find.byKey(const Key('assistant-voice')), findsNothing);
    await tester.longPress(find.byKey(_input));
    await tester.pumpAndSettle();
    expect(calls.longPress, 0);
  });

  testWidgets('во время отправки и пока слушает — нет', (tester) async {
    var calls = await _pump(tester, mode: VoiceButtonMode.idle, sending: true);
    await tester.longPress(find.byKey(_input));
    await tester.pump(const Duration(seconds: 1));
    expect(calls.longPress, 0);

    calls = await _pump(tester, mode: VoiceButtonMode.listening);
    await tester.longPress(find.byKey(_input));
    await tester.pump(const Duration(seconds: 1));
    expect(calls.longPress, 0);
  });

  testWidgets('готовится: спиннер, нажатие — отмена хозяином, крестик',
      (tester) async {
    final handle = tester.ensureSemantics();
    final calls = await _pump(tester, mode: VoiceButtonMode.loading);
    expect(find.text('Готовлю распознавание…'), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const Key('assistant-voice'))),
      matchesSemantics(
        label: 'Голосовой ввод',
        value: 'готовлю',
        hint: 'нажмите, чтобы отменить',
        isButton: true,
        hasTapAction: true,
      ),
    );
    await tester.tap(find.byKey(const Key('assistant-voice')));
    expect(calls.tap, 1);
    await tester.tap(find.byKey(const Key('voice-abort')));
    expect(calls.cancel, 1);
    handle.dispose();
  });

  testWidgets('слушает — «стоп» остаётся и при тексте в поле', (tester) async {
    final calls = await _pump(
      tester,
      mode: VoiceButtonMode.listening,
      text: 'черновик',
    );
    expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
    expect(find.byKey(const Key('assistant-send')), findsNothing);
    await tester.tap(find.byKey(const Key('assistant-voice')));
    expect(calls.tap, 1);
  });

  testWidgets('удержание микрофона и «стоп» — то же нажатие, не подсказка',
      (tester) async {
    Future<void> hold(Key key) async {
      final gesture =
          await tester.startGesture(tester.getCenter(find.byKey(key)));
      await tester.pump(const Duration(milliseconds: 1200));
      await gesture.up();
      await tester.pump();
    }

    var calls = await _pump(tester, mode: VoiceButtonMode.idle);
    await hold(const Key('assistant-voice'));
    expect(calls.tap, 1);

    calls = await _pump(tester, mode: VoiceButtonMode.listening);
    await hold(const Key('assistant-voice'));
    expect(calls.tap, 1);
    await hold(const Key('voice-abort'));
    expect(calls.cancel, 1);
    await tester.pumpAndSettle();
  });

  testWidgets('в поле одни пробелы — долгое нажатие оставляет «Вставить»',
      (tester) async {
    final calls = await _pump(tester, mode: VoiceButtonMode.idle, text: '   ');
    await tester.longPress(find.byKey(_input));
    await tester.pumpAndSettle();
    expect(calls.longPress, 0);
  });

  testWidgets('диктор знает о долгом нажатии на пустое поле', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, mode: VoiceButtonMode.idle);
    final node = tester.getSemantics(
      find.byKey(const Key('assistant-input-semantics')),
    );
    expect(
      node.getSemanticsData().hint,
      'Долгое нажатие на пустое поле — голосовой ввод',
    );
    await _pump(tester, mode: VoiceButtonMode.idle, text: 'черновик');
    final busy = tester.getSemantics(
      find.byKey(const Key('assistant-input-semantics')),
    );
    expect(busy.getSemanticsData().hint, isNot(contains('Долгое нажатие')));
    handle.dispose();
  });
}
