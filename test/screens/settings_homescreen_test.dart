// «Настройки → Виджеты» (ADR-034): показывать ли текст задач на рабочем
// столе и добавление виджетов.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/homescreen/home_screen_channel.dart';
import 'package:local_assistant/app/homescreen/home_screen_section.dart';
import 'package:local_assistant/app/screens/settings_screen.dart';
import 'package:local_assistant/core/settings/app_settings.dart';

import '../support/fake_home_screen.dart';

Future<List<AppSettings>> _pump(
  WidgetTester tester,
  HomeScreenPlatform? homeScreen, {
  AppSettings settings = const AppSettings(),
  ThemeData? theme,
}) async {
  tester.view.physicalSize = const Size(420, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final changes = <AppSettings>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? AssistantTheme.dark(),
      home: Scaffold(
        body: SettingsScreen(
          settings: settings,
          onChanged: changes.add,
          onClearChat: () {},
          messageCount: 0,
          homeScreen: homeScreen,
          category: 'widgets',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return changes;
}

String _texts(WidgetTester tester, String key) {
  final row = find.byKey(ValueKey<String>(key));
  return tester
      .widgetList<Text>(find.descendant(of: row, matching: find.byType(Text)))
      .map((Text t) => t.data ?? t.textSpan?.toPlainText() ?? '')
      .join(' | ');
}

const _toggle = ValueKey<String>('homescreen-show-text');

Finder _pin(HomeScreenKind kind) =>
    find.byKey(ValueKey<String>('homescreen-pin-${kind.name}'));

/// Справа у строки — «+» («Добавить») или галочка («На экране»).
Finder _add(HomeScreenKind kind) =>
    find.byKey(ValueKey<String>('homescreen-add-${kind.name}'));

Finder _on(HomeScreenKind kind) =>
    find.byKey(ValueKey<String>('homescreen-on-${kind.name}'));

Future<void> _resume(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('не Android — группы нет', (tester) async {
    await _pump(tester, null);
    expect(find.text('Виджеты'), findsNothing);
    await _pump(tester, const UnsupportedHomeScreen());
    expect(find.text('Виджеты'), findsNothing);
    // Канал есть, а система виджетов не знает.
    await _pump(tester, FakeHomeScreen(stateSupported: false));
    expect(find.text('Виджеты'), findsNothing);
    expect(find.byKey(_toggle), findsNothing);
  });

  testWidgets('три виджета: «+», после добавления — галочка «На экране»',
      (tester) async {
    final fake = FakeHomeScreen();
    await _pump(tester, fake);
    expect(find.text('Виджеты'), findsOneWidget);
    expect(
      _texts(tester, 'homescreen-pin-today'),
      'Сегодня | Ближайшие и просроченные задачи',
    );
    // Голосового ввода на этом устройстве нет — о микрофоне ни слова.
    expect(
      _texts(tester, 'homescreen-pin-quick'),
      'Быстрый ввод | Поле ввода',
    );
    expect(
      _texts(tester, 'homescreen-pin-combo'),
      'Сегодня и ввод | Задачи и поле ввода',
    );
    expect(find.textContaining('микрофон'), findsNothing);
    for (final kind in HomeScreenKind.values) {
      expect(_add(kind), findsOneWidget);
      expect(_on(kind), findsNothing);
    }
    // Диктор читает строку целиком: «Сегодня … Добавить».
    expect(
      find.bySemanticsLabel(RegExp('Сегодня\\n.*\\nДобавить')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel(RegExp('Добавить')), findsNWidgets(3));
    expect(
      find.textContaining('Или с рабочего стола: долгое нажатие на свободном '
          'месте → «Виджеты» → Tridot.'),
      findsOneWidget,
    );
    await tester.tap(_pin(HomeScreenKind.today));
    await tester.pumpAndSettle();
    expect(fake.pinned, <HomeScreenKind>[HomeScreenKind.today]);
    expect(find.byType(SnackBar), findsNothing);
    // Лаунчер спросил в своём окне; вернулись — состояние прочитано заново.
    await _resume(tester);
    expect(_on(HomeScreenKind.today), findsOneWidget);
    expect(_add(HomeScreenKind.today), findsNothing);
    expect(find.bySemanticsLabel(RegExp('На экране')), findsOneWidget);
    expect(_add(HomeScreenKind.quick), findsOneWidget);
    // Второй такой же виджет добавить можно.
    await tester.tap(_pin(HomeScreenKind.today));
    await tester.pumpAndSettle();
    expect(fake.pinned, hasLength(2));
  });

  testWidgets('виджет уже стоит — «На экране» сразу', (tester) async {
    await _pump(
      tester,
      FakeHomeScreen(
        installed: <HomeScreenKind, int>{HomeScreenKind.combo: 1},
      ),
    );
    expect(_on(HomeScreenKind.combo), findsOneWidget);
    expect(_add(HomeScreenKind.today), findsOneWidget);
    expect(_on(HomeScreenKind.today), findsNothing);
  });

  testWidgets('лаунчер не добавляет по просьбе — только подсказка',
      (tester) async {
    await _pump(tester, FakeHomeScreen(canPin: false));
    expect(find.text('Виджеты'), findsOneWidget);
    expect(find.byKey(_toggle), findsOneWidget);
    for (final kind in HomeScreenKind.values) {
      expect(_pin(kind), findsNothing);
    }
    expect(
      find.textContaining('Добавляются с рабочего стола: долгое нажатие'),
      findsOneWidget,
    );
  });

  testWidgets('лаунчер отказал — подсказка, как добавить иначе',
      (tester) async {
    final fake = FakeHomeScreen(pinAccepted: false);
    await _pump(tester, fake);
    await tester.tap(_pin(HomeScreenKind.quick));
    await tester.pumpAndSettle();
    expect(fake.pinned, <HomeScreenKind>[HomeScreenKind.quick]);
    expect(
      find.text('Не получилось. Добавьте виджет с рабочего стола.'),
      findsOneWidget,
    );
  });

  testWidgets('«Показывать текст задач» выключается и включается',
      (tester) async {
    final changes = await _pump(tester, FakeHomeScreen());
    expect(tester.widget<SwitchListTile>(find.byKey(_toggle)).value, isTrue);
    expect(
      _texts(tester, 'homescreen-show-text'),
      contains('Названия и последняя запись. Выключено — только число дел.'),
    );
    await tester.tap(find.byKey(_toggle));
    await tester.pumpAndSettle();
    expect(changes.single.homeScreenShowText, isFalse);
    await _pump(
      tester,
      FakeHomeScreen(),
      settings: const AppSettings(homeScreenShowText: false),
    );
    expect(tester.widget<SwitchListTile>(find.byKey(_toggle)).value, isFalse);
  });

  testWidgets('вход по отпечатку — переключатель выключен и объяснено почему',
      (tester) async {
    final changes = await _pump(
      tester,
      FakeHomeScreen(),
      settings: const AppSettings(appLock: true),
    );
    final toggle = tester.widget<SwitchListTile>(find.byKey(_toggle));
    expect(toggle.value, isFalse);
    expect(toggle.onChanged, isNull);
    expect(
      _texts(tester, 'homescreen-show-text'),
      contains('Включён вход по отпечатку — на виджете только число дел.'),
    );
    await tester.tap(find.byKey(_toggle));
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    // Виджеты добавлять можно и так.
    expect(_pin(HomeScreenKind.today), findsOneWidget);
  });

  testWidgets('с голосовым вводом у виджетов ввода — микрофон', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AssistantTheme.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: HomeScreenSection(
              platform: FakeHomeScreen(),
              settings: const AppSettings(),
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      _texts(tester, 'homescreen-pin-quick'),
      contains('Поле и микрофон'),
    );
    expect(
      _texts(tester, 'homescreen-pin-combo'),
      contains('Задачи, поле и микрофон'),
    );
  });

  for (final (name, theme) in <(String, ThemeData Function())>[
    ('тёмная', AssistantTheme.dark),
    ('светлая', AssistantTheme.light),
  ]) {
    testWidgets('$name тема: контраст и размер нажатий', (tester) async {
      await _pump(
        tester,
        FakeHomeScreen(
          installed: <HomeScreenKind, int>{HomeScreenKind.today: 1},
        ),
        theme: theme(),
      );
      await tester.ensureVisible(_pin(HomeScreenKind.combo));
      await tester.pumpAndSettle();
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      // И с выключенным переключателем (вход по отпечатку).
      await _pump(
        tester,
        FakeHomeScreen(),
        settings: const AppSettings(appLock: true),
        theme: theme(),
      );
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    });
  }

  test('настройка сохраняется, только когда выключена', () {
    const fresh = AppSettings();
    expect(fresh.homeScreenShowText, isTrue);
    expect(fresh.homeScreenText, isTrue);
    expect(fresh.toJson().containsKey('widgets.show_text'), isFalse);
    const off = AppSettings(homeScreenShowText: false);
    expect(off.toJson()['widgets.show_text'], isFalse);
    final back = AppSettings.fromJson(off.toJson());
    expect(back.homeScreenShowText, isFalse);
    expect(back.homeScreenText, isFalse);
    // Битое значение — как по умолчанию.
    expect(
      AppSettings.fromJson(<String, dynamic>{'widgets.show_text': 'нет'})
          .homeScreenShowText,
      isTrue,
    );
    // Вход по отпечатку прячет текст, а сама настройка остаётся.
    const locked = AppSettings(appLock: true);
    expect(locked.homeScreenShowText, isTrue);
    expect(locked.homeScreenText, isFalse);
    expect(
      locked.copyWith(appLock: false).homeScreenText,
      isTrue,
    );
  });
}
