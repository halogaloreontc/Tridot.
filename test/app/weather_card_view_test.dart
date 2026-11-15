import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/widgets/weather_card_view.dart';
import 'package:local_assistant/core/models/weather_card.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/skills/weather/open_meteo_client.dart';
import 'package:local_assistant/core/skills/weather/weather_models.dart';

import '../support/app_fonts.dart';
import '../support/fake_weather.dart';
import '../support/word_wrap_guard.dart';

const WeatherPlace kazan = WeatherPlace(
  name: 'Казань',
  latitude: 55.78874,
  longitude: 49.12214,
  admin1: 'Татарстан',
  country: 'Россия',
  countryCode: 'RU',
);

Future<Forecast> _forecast() => OpenMeteoClient(
      RecordingTransport.kazan(),
      clock: FixedClock(DateTime(2026, 11, 15, 9, 40)),
    ).forecast(kazan);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required ThemeData theme,
  double width = 360,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width, 1600);
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
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: child,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadAppFonts);

  for (final (String name, ThemeData theme) in <(String, ThemeData)>[
    ('тёмная', AssistantTheme.dark()),
    ('светлая', AssistantTheme.light()),
  ]) {
    for (final (double width, double scale) in <(double, double)>[
      (360, 1),
      (420, 1),
      (452, 1),
      (320, 2),
    ]) {
      testWidgets('прогноз, $name, $width ×$scale: целые слова, контраст',
          (tester) async {
        final f = await tester.runAsync(_forecast);
        await _pump(
          tester,
          WeatherCardView(
            card: WeatherCard.forecast(f!, focusDay: 1),
            compact: width < 400,
            onRefresh: () {},
            onMore: () {},
            onOpenSite: () {},
          ),
          theme: theme,
          width: width,
          scale: scale,
        );
        expect(tester.takeException(), isNull);
        expect(midWordBreaks(tester), isEmpty);
        expect(
          find.byKey(const ValueKey<String>('weather-card-temp')),
          findsOneWidget,
        );
        expect(find.text('Open-Meteo.com · CC BY 4.0'), findsOneWidget);
        expect(
          tester
              .getSize(find.byKey(const ValueKey<String>('weather-card')))
              .width,
          lessThanOrEqualTo(WeatherCardView.maxWidth),
        );
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      });
    }

    testWidgets('нет связи — пометка цветом предупреждения, $name',
        (tester) async {
      final f = await tester.runAsync(_forecast);
      await _pump(
        tester,
        WeatherCardView(card: WeatherCard.forecast(f!, stale: true)),
        theme: theme,
      );
      final time = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('weather-card-time')),
          matching: find.byType(Text),
        ),
      );
      expect(time.data, 'нет связи · данные на 9:30');
      expect(time.style?.color, theme.extension<AppPalette>()!.warning);
    });

    testWidgets('ссылка и «Настроить», $name, 320 ×2', (tester) async {
      await _pump(
        tester,
        const Column(
          children: <Widget>[
            WeatherCardView(
              card: WeatherCard.launcher(label: 'Приложение: Яндекс Погода'),
            ),
            SizedBox(height: 12),
            WeatherCardView(card: WeatherCard.setup()),
          ],
        ),
        theme: theme,
        width: 320,
        scale: 2,
      );
      expect(tester.takeException(), isNull);
      expect(midWordBreaks(tester), isEmpty);
      expect(find.text('Открыть ещё раз'), findsOneWidget);
      expect(find.text('Настроить'), findsOneWidget);
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    });
  }

  testWidgets('телефон: 5 дней и «Ещё 2 дня»', (tester) async {
    final f = await tester.runAsync(_forecast);
    await _pump(
      tester,
      WeatherCardView(card: WeatherCard.forecast(f!), compact: true),
      theme: AssistantTheme.dark(),
    );
    expect(
      find.byKey(const ValueKey<String>('weather-card-day-4')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('weather-card-day-5')),
      findsNothing,
    );
    await tester.tap(find.text('Ещё 2 дня'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('weather-card-day-6')),
      findsOneWidget,
    );
  });

  testWidgets('кнопки зовут свои действия', (tester) async {
    final f = await tester.runAsync(_forecast);
    final taps = <String>[];
    await _pump(
      tester,
      WeatherCardView(
        card: WeatherCard.forecast(f!),
        onRefresh: () => taps.add('refresh'),
        onMore: () => taps.add('more'),
        onOpenSite: () => taps.add('site'),
      ),
      theme: AssistantTheme.light(),
    );
    await tester
        .tap(find.byKey(const ValueKey<String>('weather-card-refresh')));
    await tester
        .tap(find.byKey(const ValueKey<String>('weather-card-details')));
    await tester.tap(
      find.byKey(const ValueKey<String>('weather-card-attribution')),
    );
    expect(taps, <String>['refresh', 'more', 'site']);
  });
}
