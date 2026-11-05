import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/screens/settings_screen.dart';
import 'package:local_assistant/core/settings/app_settings.dart';

Widget host({
  AppSettings settings = const AppSettings(),
  ValueChanged<AppSettings>? onChanged,
  VoidCallback? onClearChat,
  int messageCount = 5,
}) {
  return MaterialApp(
    theme: AssistantTheme.dark(),
    home: Scaffold(
      body: SettingsScreen(
        settings: settings,
        onChanged: onChanged ?? (_) {},
        onClearChat: onClearChat ?? () {},
        messageCount: messageCount,
      ),
    ),
  );
}

const clearKey = ValueKey<String>('clear-chat');

void main() {
  testWidgets('shows sections and switch values', (tester) async {
    await tester.pumpWidget(host());
    expect(find.text('Настройки'), findsOneWidget);
    expect(find.text('Уменьшить анимацию'), findsOneWidget);
    expect(find.text('Кубик и переходы без движения'), findsOneWidget);
    expect(find.text('Время под сообщениями'), findsOneWidget);
    expect(
      find.text('Личный помощник · локально, без интернета и языковой модели'),
      findsOneWidget,
    );
    final reduce = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey<String>('setting-reduce-motion')),
    );
    final stamps = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey<String>('setting-timestamps')),
    );
    expect(reduce.value, isFalse);
    expect(stamps.value, isTrue);
  });

  testWidgets('switches report updated settings', (tester) async {
    final changes = <AppSettings>[];
    await tester.pumpWidget(host(onChanged: changes.add));
    await tester.tap(find.text('Уменьшить анимацию'));
    await tester.tap(find.text('Время под сообщениями'));
    await tester.pump();
    expect(changes, hasLength(2));
    expect(changes[0].reduceMotion, isTrue);
    expect(changes[0].showTimestamps, isTrue);
    expect(changes[1].reduceMotion, isFalse);
    expect(changes[1].showTimestamps, isFalse);
  });

  testWidgets('clear chat is disabled with only the greeting', (tester) async {
    await tester.pumpWidget(host(messageCount: 1));
    final button = tester.widget<ButtonStyleButton>(find.byKey(clearKey));
    expect(button.onPressed, isNull);
  });

  testWidgets('clear chat asks for confirmation; cancel keeps history',
      (tester) async {
    var cleared = 0;
    await tester.pumpWidget(host(onClearChat: () => cleared++));
    await tester.tap(find.byKey(clearKey));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(cleared, 0);

    await tester.tap(find.byKey(clearKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Очистить'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(cleared, 1);
  });

  testWidgets('licenses button opens the license page', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.byKey(const ValueKey<String>('licenses')));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
  });

  testWidgets('no overflow at 320x640 with textScaler 2.0', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byKey(clearKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(clearKey));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no overflow at 1600 wide', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(messageCount: 1));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
