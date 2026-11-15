// «Настройки → Оформление» (ADR-027): как в системе, светлое, тёмное.
// По умолчанию — как в системе; смена темы не теряет состояние экрана.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';
import 'package:local_assistant/main.dart';

import '../support/home_nav.dart';

final _clock = FixedClock(DateTime(2026, 11, 14, 12));

/// Приложение как в main.dart: тема по режиму из настроек.
final class _App extends StatefulWidget {
  const _App({super.key, required this.store, required this.initial});

  final SettingsStore store;
  final AppAppearance initial;

  @override
  State<_App> createState() => _AppState();
}

final class _AppState extends State<_App> {
  late ThemeMode mode = themeModeOf(widget.initial);

  void setMode(ThemeMode value) => setState(() => mode = value);
  late final TaskService tasks =
      TaskService(repository: InMemoryTaskRepository(), clock: _clock);
  late final AssistantController assistant = AssistantController(
    connectors: <Connector>[
      TasksConnector(taskService: tasks, parser: ScenarioParser(clock: _clock)),
    ],
    clock: _clock,
  );

  @override
  Widget build(BuildContext context) => MaterialApp(
        theme: AssistantTheme.light(),
        darkTheme: AssistantTheme.dark(),
        themeMode: mode,
        home: HomePage(
          assistant: assistant,
          tasks: tasks,
          clock: _clock,
          settingsStore: widget.store,
          chatStore: InMemoryChatStore(),
          onAppearanceChanged: (AppAppearance a) =>
              setState(() => mode = themeModeOf(a)),
        ),
      );
}

Color _scaffold(WidgetTester tester) => Theme.of(
      tester.element(find.byKey(const Key('assistant-input'))),
    ).scaffoldBackgroundColor;

void main() {
  group('AppSettings.appearance', () {
    test('по умолчанию — как в системе, в JSON не пишется', () {
      const settings = AppSettings();
      expect(settings.appearance, AppAppearance.system);
      expect(settings.toJson().containsKey('appearance'), isFalse);
    });

    test('светлое и тёмное сохраняются и читаются', () {
      for (final value in <AppAppearance>[
        AppAppearance.light,
        AppAppearance.dark,
      ]) {
        final json = const AppSettings().copyWith(appearance: value).toJson();
        expect(json['appearance'], value.id);
        expect(AppSettings.fromJson(json).appearance, value);
      }
    });

    test('неизвестное или битое значение — как в системе', () {
      for (final broken in <Object?>[
        'sepia',
        3,
        true,
        null,
        <int>[1],
      ]) {
        expect(
          AppSettings.fromJson(<String, dynamic>{'appearance': broken})
              .appearance,
          AppAppearance.system,
          reason: '$broken',
        );
      }
    });

    test('режим темы по оформлению', () {
      expect(themeModeOf(AppAppearance.system), ThemeMode.system);
      expect(themeModeOf(AppAppearance.light), ThemeMode.light);
      expect(themeModeOf(AppAppearance.dark), ThemeMode.dark);
    });

    test('строка состояния и панель навигации — по яркости темы', () {
      final light = overlayStyleFor(AssistantTheme.light());
      expect(light.statusBarIconBrightness, Brightness.dark);
      expect(light.systemNavigationBarColor, AppPalette.light.background);
      final dark = overlayStyleFor(AssistantTheme.dark());
      expect(dark.statusBarIconBrightness, Brightness.light);
      expect(dark.systemNavigationBarColor, AppPalette.dark.background);
    });
  });

  group('тема по системе', () {
    for (final (brightness, background) in <(Brightness, Color)>[
      (Brightness.light, const Color(0xFFF2F2F7)),
      (Brightness.dark, const Color(0xFF000000)),
    ]) {
      testWidgets('система $brightness — фон $background', (tester) async {
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        await tester.pumpWidget(
          _App(store: InMemorySettingsStore(), initial: AppAppearance.system),
        );
        await tester.pumpAndSettle();
        expect(_scaffold(tester), background);
      });
    }
  });

  testWidgets('«Тёмное» перекрашивает экран, набранный текст остаётся',
      (tester) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final store = InMemorySettingsStore();
    await tester.pumpWidget(_App(store: store, initial: AppAppearance.system));
    await tester.pumpAndSettle();
    expect(_scaffold(tester), AppPalette.light.background);
    await tester.enterText(
      find.byKey(const Key('assistant-input')),
      'черновик фразы',
    );
    await tester.pump();

    await openSettings(tester);
    final row = find.byKey(const ValueKey<String>('setting-appearance'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: row, matching: find.text('Как в системе')),
      findsOneWidget,
    );
    await tester.tap(row);
    await tester.pumpAndSettle();
    for (final id in <String>['system', 'light', 'dark']) {
      expect(find.byKey(ValueKey<String>('appearance-$id')), findsOneWidget);
    }
    expect(
      find.text('Как в системе — тема меняется вместе с телефоном'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey<String>('appearance-dark')));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byKey(const ValueKey('appearance-dark'))))
          .brightness,
      Brightness.dark,
    );
    expect((await store.load()).appearance, AppAppearance.dark);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('appearance-dark')),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );

    // Назад в сессию: поле ввода на месте, с тем же текстом.
    await tester.pageBack();
    await tester.pumpAndSettle();
    final input = find.byKey(const Key('assistant-input'));
    if (input.hitTestable().evaluate().isEmpty) {
      await tapInDrawer(tester, const Key('new-session'));
    }
    expect(_scaffold(tester), AppPalette.dark.background);
  });

  testWidgets('смена темы не пересоздаёт поле ввода', (tester) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey<_AppState>();
    await tester.pumpWidget(
      _App(
        key: key,
        store: InMemorySettingsStore(),
        initial: AppAppearance.light,
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('assistant-input')),
      'черновик фразы',
    );
    await tester.pump();
    final state = tester.state(find.byType(HomePage));
    key.currentState!.setMode(ThemeMode.dark);
    await tester.pumpAndSettle();
    expect(_scaffold(tester), AppPalette.dark.background);
    expect(tester.state(find.byType(HomePage)), same(state));
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('assistant-input')))
          .controller!
          .text,
      'черновик фразы',
    );
  });

  testWidgets('оформление из настроек применяется при запуске', (tester) async {
    final store = InMemorySettingsStore();
    await store.save(const AppSettings(appearance: AppAppearance.dark));
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(_App(store: store, initial: AppAppearance.system));
    await tester.pumpAndSettle();
    expect(_scaffold(tester), AppPalette.dark.background);
  });

  testWidgets('«Меньше анимации» — тема меняется без перетекания цветов',
      (tester) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Duration duration() => tester
        .widget<MaterialApp>(find.byType(MaterialApp))
        .themeAnimationDuration;
    final tasks =
        TaskService(repository: InMemoryTaskRepository(), clock: _clock);
    final assistant = AssistantController(
      connectors: <Connector>[
        TasksConnector(
          taskService: tasks,
          parser: ScenarioParser(clock: _clock),
        ),
      ],
      clock: _clock,
    );
    final store = InMemorySettingsStore();
    await store.save(const AppSettings(reduceMotion: true));
    await tester.pumpWidget(
      AssistantApp(
        assistant: assistant,
        tasks: tasks,
        clock: _clock,
        settingsStore: store,
        chatStore: InMemoryChatStore(),
        initialReduceMotion: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(duration(), Duration.zero);

    // Выключили в настройках — снова обычная анимация темы.
    await tester.pumpWidget(const SizedBox());
    await store.save(const AppSettings());
    await tester.pumpWidget(
      AssistantApp(
        assistant: assistant,
        tasks: tasks,
        clock: _clock,
        settingsStore: store,
        chatStore: InMemoryChatStore(),
        initialReduceMotion: true,
      ),
    );
    await tester.pumpAndSettle();
    // Прочитанные настройки сильнее начального значения.
    expect(duration(), kThemeAnimationDuration);
  });

  test('SystemUiOverlayStyle прозрачной строки состояния', () {
    expect(
      overlayStyleFor(AssistantTheme.light()).statusBarColor,
      const Color(0x00000000),
    );
    expect(SystemUiOverlayStyle.dark.statusBarIconBrightness, Brightness.dark);
  });
}
