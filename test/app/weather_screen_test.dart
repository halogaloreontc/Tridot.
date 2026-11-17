import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/extensions/weather_kit.dart';
import 'package:local_assistant/app/extensions/weather_screen.dart';
import 'package:local_assistant/app/links/link_opener.dart';
import 'package:local_assistant/app/widgets/extensions_section.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/weather/weather_connector.dart';
import 'package:local_assistant/core/services/clock.dart';

import '../support/app_fonts.dart';
import '../support/fake_weather.dart';
import '../support/word_wrap_guard.dart';

final class _FakeProcess implements Process {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  setUpAll(loadAppFonts);

  late RecordingTransport transport;
  late List<List<String>> opened;

  WeatherKit kit({WeatherSettings settings = const WeatherSettings()}) {
    transport = RecordingTransport.kazan();
    opened = <List<String>>[];
    final service = WeatherService.memory(
      transport: transport,
      clock: FixedClock(DateTime(2026, 11, 15, 9, 40)),
      settings: settings,
    );
    return WeatherKit(
      service: service,
      links: LinkOpener(
        platform: JobPlatform.linux,
        start: (
          String exe,
          List<String> args, {
          bool runInShell = false,
          ProcessStartMode mode = ProcessStartMode.normal,
        }) async {
          opened.add(<String>[exe, ...args]);
          return _FakeProcess();
        },
      ),
    );
  }

  Future<void> pump(
    WidgetTester tester,
    WeatherKit kit, {
    ThemeData? theme,
    double width = 390,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? AssistantTheme.dark(),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
          ),
          child: child!,
        ),
        home: WeatherScreen(kit: kit),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> chooseSource(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(const ValueKey<String>('weather-source')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('указание Open-Meteo — только при источнике Open-Meteo',
      (tester) async {
    final attribution =
        find.byKey(const ValueKey<String>('weather-attribution'));
    await pump(tester, kit());
    expect(attribution, findsNothing);
    await pump(
      tester,
      kit(
        settings: const WeatherSettings(source: WeatherSource.link),
      ),
    );
    expect(attribution, findsNothing);
    expect(find.text('Своя ссылка'), findsWidgets);
    await pump(
      tester,
      kit(
        settings: const WeatherSettings(source: WeatherSource.openMeteo),
      ),
    );
    expect(attribution, findsOneWidget);
    expect(find.text('Open-Meteo'), findsWidgets);
  });

  testWidgets('Open-Meteo: «Отмена» в согласии — сети нет', (tester) async {
    final k = kit();
    await pump(tester, k);
    await chooseSource(tester, 'Open-Meteo — прогноз в чате');
    expect(
      find.byKey(const ValueKey<String>('weather-consent-text')),
      findsOneWidget,
    );
    await tester
        .tap(find.byKey(const ValueKey<String>('weather-consent-cancel')));
    await tester.pumpAndSettle();
    expect(k.settings.source, WeatherSource.openMeteo);
    expect(k.settings.networkAllowed, isFalse);
    expect(find.text('Сеть для погоды не разрешена'), findsOneWidget);
    final search = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey<String>('weather-city-search')),
    );
    expect(search.onPressed, isNull);
    expect(transport.requests, isEmpty);
  });

  testWidgets('разрешить, найти город, выбрать, проверить, отозвать',
      (tester) async {
    final k = kit();
    await pump(tester, k);
    await chooseSource(tester, 'Open-Meteo — прогноз в чате');
    await tester
        .tap(find.byKey(const ValueKey<String>('weather-consent-accept')));
    await tester.pumpAndSettle();
    expect(k.settings.networkAllowed, isTrue);
    expect(transport.requests, isEmpty, reason: 'на набор — ни запроса');
    await tester.enterText(
      find.byKey(const ValueKey<String>('weather-city-field')),
      'Казань',
    );
    await tester.pump();
    expect(transport.requests, isEmpty);
    await tester.tap(find.byKey(const ValueKey<String>('weather-city-search')));
    await tester.pumpAndSettle();
    expect(transport.requests, hasLength(1));
    expect(find.text('Казань — Татарстан, Россия'), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey<String>('weather-city-result-0')));
    await tester.pumpAndSettle();
    expect(k.settings.place?.name, 'Казань');
    await tester.tap(find.byKey(const ValueKey<String>('weather-check')));
    await tester.pumpAndSettle();
    expect(find.text('Связь есть: сейчас +2°, пасмурно'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('weather-consent-revoke')),
    );
    await tester
        .tap(find.byKey(const ValueKey<String>('weather-consent-revoke')));
    await tester.pumpAndSettle();
    expect(k.settings.networkAllowed, isFalse);
  });

  testWidgets('город не найден — строка под полем', (tester) async {
    final k = kit(
      settings: WeatherSettings(
        source: WeatherSource.openMeteo,
        networkAllowedAt: DateTime(2026, 11, 1),
      ),
    );
    await pump(tester, k);
    await tester.enterText(
      find.byKey(const ValueKey<String>('weather-city-field')),
      'Неведомск',
    );
    await tester.tap(find.byKey(const ValueKey<String>('weather-city-search')));
    await tester.pumpAndSettle();
    expect(find.text('Город не найден — проверьте название'), findsOneWidget);
  });

  testWidgets('своя ссылка: проверка, извлечение из текста, «Проверить»',
      (tester) async {
    final k = kit();
    await pump(tester, k);
    await chooseSource(tester, 'Своя ссылка — открыть страницу');
    final field = find.byKey(const ValueKey<String>('weather-link-field'));
    final save = find.byKey(const ValueKey<String>('weather-link-save'));
    for (final (String input, String message) in <(String, String)>[
      ('http://example.com/w', 'Нужна ссылка, которая начинается с https://'),
      ('https://localhost/w', 'В ссылке нет адреса сайта'),
      ('https://example.com/${'a' * 2100}', 'Ссылка слишком длинная'),
    ]) {
      await tester.enterText(field, input);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget, reason: input);
      expect(k.settings.link, isNull);
    }
    await tester.enterText(field, 'Погода в Казани https://example.com/w?c=1.');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(k.settings.link, 'https://example.com/w?c=1');
    await tester.tap(find.byKey(const ValueKey<String>('weather-check')));
    await tester.pumpAndSettle();
    expect(opened.single, <String>['xdg-open', 'https://example.com/w?c=1']);
    expect(transport.requests, isEmpty);
  });

  for (final (String name, ThemeData theme) in <(String, ThemeData)>[
    ('тёмная', AssistantTheme.dark()),
    ('светлая', AssistantTheme.light()),
  ]) {
    testWidgets('экран, $name, 320 ×2: целые слова', (tester) async {
      final k = kit(
        settings: WeatherSettings(
          source: WeatherSource.openMeteo,
          networkAllowedAt: DateTime(2026, 11, 1),
          link: 'https://example.com/w',
        ),
      );
      await pump(tester, k, theme: theme, width: 320, scale: 2);
      expect(tester.takeException(), isNull);
      expect(midWordBreaks(tester), isEmpty);
    });
  }

  testWidgets('«Расширения»: включение без источника открывает экран',
      (tester) async {
    final k = kit();
    final registry = ExtensionRegistry(
      connectors: <Connector>[WeatherConnector(backend: k.service)],
    );
    var settings = const AppSettings();
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AssistantTheme.dark(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) =>
                SingleChildScrollView(
              child: ExtensionsSection(
                registry: registry,
                settings: settings,
                onChanged: (AppSettings next) =>
                    setState(() => settings = next),
                weather: k,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Выключено. Источник не выбран'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('extension-weather')));
    await tester.pumpAndSettle();
    expect(find.byType(WeatherScreen), findsOneWidget);
    expect(transport.requests, isEmpty);
  });
}
