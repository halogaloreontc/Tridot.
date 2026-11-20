import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/widgets/message_copy_button.dart';
import 'package:local_assistant/app/widgets/message_row.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/personas/persona.dart';

/// «Копировать» под сообщениями: ответ — кнопка всегда, своё сообщение —
/// при наведении на компьютере, строка «думает» — без кнопки.
void main() {
  final cast = PersonaCast.of(
    const PersonaSettings(teamMode: TeamMode.solo, emoji: false),
  );
  final now = DateTime(2026, 11, 20, 12);
  String? copied;

  setUp(() {
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform,
            (MethodCall call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pump(
    WidgetTester tester,
    ChatMessage message, {
    bool thinking = false,
    TargetPlatform platform = TargetPlatform.android,
  }) =>
      tester.pumpWidget(
        MaterialApp(
          theme: AssistantTheme.dark().copyWith(platform: platform),
          home: Scaffold(
            body: MessageRow(
              cast: cast,
              message: message,
              now: now,
              showTime: false,
              thinking: thinking,
              onOpenTask: (_) {},
              onToggleDone: (_) {},
            ),
          ),
        ),
      );

  ChatMessage reply(String text) => ChatMessage(
        id: 'r1',
        author: ChatAuthor.persona,
        personaId: 'sado',
        text: text,
        timestamp: now,
      );

  ChatMessage mine(String text) => ChatMessage(
        id: 'u1',
        author: ChatAuthor.user,
        text: text,
        timestamp: now,
      );

  testWidgets('ответ: «Копировать» кладёт весь текст в буфер, галочка',
      (WidgetTester tester) async {
    await pump(tester, reply('Создал задачу «Купить молоко» на завтра.'));
    final button = find.byKey(const ValueKey<String>('message-copy'));
    expect(button, findsOneWidget);
    await tester.tap(button);
    await tester.pump();
    expect(copied, 'Создал задачу «Купить молоко» на завтра.');
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    await tester.pump(MessageCopyButton.doneFor);
    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
  });

  testWidgets('строка «думает» — без кнопки', (WidgetTester tester) async {
    await pump(tester, reply('Связной думает…'), thinking: true);
    expect(find.byKey(const ValueKey<String>('message-copy')), findsNothing);
  });

  testWidgets('своё сообщение на телефоне — без кнопки (долгое нажатие)',
      (WidgetTester tester) async {
    await pump(tester, mine('напомни завтра купить молоко'));
    expect(find.byKey(const ValueKey<String>('message-copy')), findsNothing);
  });

  testWidgets('своё сообщение на компьютере — кнопка при наведении',
      (WidgetTester tester) async {
    await pump(
      tester,
      mine('напомни завтра купить молоко'),
      platform: TargetPlatform.macOS,
    );
    final button = find.byKey(const ValueKey<String>('message-copy'));
    // Место под кнопку есть, но она не видна, пока мышь не над пузырём.
    expect(
      tester
          .widget<Visibility>(
            find.ancestor(of: button, matching: find.byType(Visibility)),
          )
          .visible,
      isFalse,
    );
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture
        .moveTo(tester.getCenter(find.text('напомни завтра купить молоко')));
    await tester.pump();
    await tester.tap(button);
    await tester.pump();
    expect(copied, 'напомни завтра купить молоко');
  });
}
