import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/notify/notify_channel.dart';
import 'package:local_assistant/app/screens/settings_screen.dart';
import 'package:local_assistant/core/settings/app_settings.dart';

import '../support/fake_notify.dart';

Future<List<AppSettings>> _pump(
  WidgetTester tester,
  NotifyPlatform? notify, {
  AppSettings settings = const AppSettings(),
}) async {
  tester.view.physicalSize = const Size(420, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final changes = <AppSettings>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.dark(),
      home: Scaffold(
        body: SettingsScreen(
          settings: settings,
          onChanged: changes.add,
          onClearChat: () {},
          messageCount: 0,
          onOpenAssistants: () {},
          notify: notify,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return changes;
}

String _subtitle(WidgetTester tester, String key) {
  final row = find.byKey(ValueKey<String>(key));
  final texts = tester
      .widgetList<Text>(find.descendant(of: row, matching: find.byType(Text)))
      .map((Text t) => t.data ?? t.textSpan?.toPlainText() ?? '')
      .toList();
  return texts.join(' | ');
}

void main() {
  testWidgets('нет уведомлений на устройстве (Linux) — группы нет',
      (tester) async {
    await _pump(tester, const UnsupportedNotify());
    expect(find.text('Разрешения'), findsNothing);
    await _pump(tester, null);
    expect(find.text('Разрешения'), findsNothing);
  });

  testWidgets('Android: уведомления, точное время, задачи без времени, «Часы»',
      (tester) async {
    final notify = FakeNotify(exact: ExactAlarm.denied);
    final changes = await _pump(tester, notify);
    expect(find.text('Разрешения'), findsOneWidget);
    expect(
      _subtitle(tester, 'permission-notifications'),
      contains('Не запрашивались'),
    );
    expect(
      _subtitle(tester, 'permission-exact'),
      contains('Напоминания могут опаздывать на несколько минут'),
    );
    expect(
      _subtitle(tester, 'permission-alarm'),
      contains('Ставятся в приложении «Часы»'),
    );
    expect(_subtitle(tester, 'permission-date-only'), contains('В 9:00'));
    await tester
        .tap(find.byKey(const ValueKey<String>('permission-date-only')));
    await tester.pumpAndSettle();
    expect(changes.last.notifyDateOnly, isFalse);
    await tester.tap(find.byKey(const ValueKey<String>('permission-exact')));
    expect(notify.exactOpened, 1);
    // «Уведомления» — объяснение и системный вопрос.
    await tester.tap(
      find.byKey(const ValueKey<String>('permission-notifications')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Напоминания вовремя'), findsOneWidget);
    await tester.tap(find.byKey(const Key('notify-allow')));
    await tester.pumpAndSettle();
    // Разрешено, но точного времени нет — второй шаг.
    expect(find.text('Точно в срок'), findsOneWidget);
    await tester.tap(find.byKey(const Key('notify-exact-skip')));
    await tester.pumpAndSettle();
    expect(_subtitle(tester, 'permission-notifications'), contains('Включены'));
    expect(changes.last.notifyExplained, isTrue);
  });

  testWidgets('включено — нажатие открывает настройки системы; без «Часов»',
      (tester) async {
    final notify = FakeNotify(permission: NotifyPermission.granted)
      ..clock = false;
    await _pump(tester, notify);
    expect(
      find.byKey(const ValueKey<String>('permission-exact')),
      findsNothing,
    );
    expect(
      _subtitle(tester, 'permission-alarm'),
      contains('Нет приложения «Часы»'),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('permission-notifications')),
    );
    await tester.pumpAndSettle();
    expect(notify.settingsOpened, 1);
  });

  testWidgets('macOS: без будильника и точного времени', (tester) async {
    final notify = FakeNotify(
      permission: NotifyPermission.permanentlyDenied,
      alarms: false,
    );
    await _pump(tester, notify);
    expect(
      _subtitle(tester, 'permission-notifications'),
      contains('Выключены'),
    );
    expect(
      find.byKey(const ValueKey<String>('permission-alarm')),
      findsNothing,
    );
  });

  test('настройки уведомлений сохраняются', () {
    const settings = AppSettings(
      notifyExplained: true,
      notifyDismissedDay: '2026-11-15',
      notifyDateOnly: false,
      notifyDateOnlyHour: 8,
    );
    final back = AppSettings.fromJson(settings.toJson());
    expect(back.notifyExplained, isTrue);
    expect(back.notifyDismissedDay, '2026-11-15');
    expect(back.notifyDateOnly, isFalse);
    expect(back.notifyDateOnlyHour, 8);
    const fresh = AppSettings();
    expect(
      fresh.toJson().keys.where((String k) => k.startsWith('notify.')),
      isEmpty,
    );
    expect(
      AppSettings.fromJson(<String, dynamic>{'notify.date_only_hour': 30})
          .notifyDateOnlyHour,
      9,
    );
  });
}
