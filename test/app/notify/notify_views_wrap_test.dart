import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/notify/notify_channel.dart';
import 'package:local_assistant/app/notify/notify_views.dart';
import 'package:local_assistant/core/settings/app_settings.dart';

import '../../support/app_fonts.dart';
import '../../support/fake_notify.dart';
import '../../support/word_wrap_guard.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required ThemeData theme,
  double scale = 2,
}) async {
  tester.view.physicalSize = const Size(320, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
        ),
        child: child!,
      ),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadAppFonts);

  final notifier = const PersonaSettings().notifier;

  for (final (String name, ThemeData theme) in <(String, ThemeData)>[
    ('тёмная', AssistantTheme.dark()),
    ('светлая', AssistantTheme.light()),
  ]) {
    for (final (String step, FakeNotify notify) in <(String, FakeNotify)>[
      ('объяснение', FakeNotify()),
      (
        'настройки',
        FakeNotify(permission: NotifyPermission.permanentlyDenied),
      ),
      (
        'точное время',
        FakeNotify(
          permission: NotifyPermission.granted,
          exact: ExactAlarm.denied,
        ),
      ),
    ]) {
      testWidgets('лист «$step», $name, 320 ×2: без переносов внутри слов',
          (tester) async {
        await _pump(
          tester,
          NotifySheet(platform: notify, notifier: notifier),
          theme: theme,
        );
        expect(tester.takeException(), isNull);
        expect(midWordBreaks(tester), isEmpty);
        await expectLater(tester, meetsGuideline(textContrastGuideline));
      });
    }

    testWidgets('«Разрешения», $name, 320 ×2', (tester) async {
      await _pump(
        tester,
        PermissionsSection(
          platform: FakeNotify(exact: ExactAlarm.denied),
          settings: const AppSettings(),
          onChanged: (_) {},
        ),
        theme: theme,
      );
      expect(tester.takeException(), isNull);
      expect(midWordBreaks(tester), isEmpty);
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    });
  }
}
