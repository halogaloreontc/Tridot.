// Погода в чате (ADR-030): фраза → карточка прогноза; своя ссылка
// открывается системой только у живого ответа — восстановленная история
// ничего не открывает; не открылось — строка следом.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/extensions/weather_kit.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/app/links/link_opener.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/weather/weather_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import 'support/fake_weather.dart';

final class _FakeProcess implements Process {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

const WeatherPlace kazan = WeatherPlace(
  name: 'Казань',
  latitude: 55.78874,
  longitude: 49.12214,
  admin1: 'Татарстан',
  country: 'Россия',
  countryCode: 'RU',
);

const String link = 'https://example.com/weather?city=kzn';

void main() {
  late InMemoryChatStore store;
  late InMemorySettingsStore settings;
  late RecordingTransport transport;
  late List<List<String>> opened;
  late bool browserMissing;

  setUp(() {
    store = InMemoryChatStore();
    settings = InMemorySettingsStore();
    transport = RecordingTransport.kazan();
    opened = <List<String>>[];
    browserMissing = false;
  });

  final clock = FixedClock(DateTime(2026, 11, 15, 9, 40));

  Future<void> pump(WidgetTester tester, WeatherSettings weather) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final tasks =
        TaskService(repository: InMemoryTaskRepository(), clock: clock);
    final saved = await settings.load();
    await settings.save(
      saved.withChoice(
        const ExtensionChoice(enabled: <String>{WeatherConnector.id}),
      ),
    );
    final service = WeatherService.memory(
      transport: transport,
      clock: clock,
      settings: weather,
    );
    final kit = WeatherKit(
      service: service,
      links: LinkOpener(
        platform: JobPlatform.linux,
        start: (
          String exe,
          List<String> args, {
          bool runInShell = false,
          ProcessStartMode mode = ProcessStartMode.normal,
        }) async {
          if (browserMissing) throw const ProcessException('xdg-open', []);
          opened.add(<String>[exe, ...args]);
          return _FakeProcess();
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AssistantTheme.dark(),
        home: HomePage(
          assistant: AssistantController(
            extensions: ExtensionRegistry(
              connectors: <Connector>[
                TasksConnector(
                  taskService: tasks,
                  parser: ScenarioParser(clock: clock),
                ),
                WeatherConnector(backend: service, clock: clock),
              ],
            ),
            clock: clock,
          ),
          tasks: tasks,
          clock: clock,
          settingsStore: settings,
          chatStore: store,
          weather: kit,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> say(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('assistant-input')), text);
    await tester.tap(find.byKey(const Key('assistant-send')));
    await tester.pumpAndSettle();
  }

  testWidgets('Open-Meteo: фраза → карточка прогноза', (tester) async {
    await pump(
      tester,
      WeatherSettings(
        source: WeatherSource.openMeteo,
        networkAllowedAt: DateTime(2026, 11, 1),
        place: kazan,
      ),
    );
    await say(tester, 'какая погода');
    expect(find.byKey(const ValueKey<String>('weather-card')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('weather-card-temp')),
      findsOneWidget,
    );
    expect(find.text('Open-Meteo.com · CC BY 4.0'), findsOneWidget);
    expect(opened, isEmpty);
    // «Обновить» — тот же снимок в том же сообщении, новый запрос.
    final before = transport.requests.length;
    await tester
        .tap(find.byKey(const ValueKey<String>('weather-card-refresh')));
    await tester.pumpAndSettle();
    expect(transport.requests.length, before + 1);
    expect(find.byKey(const ValueKey<String>('weather-card')), findsOneWidget);
  });

  testWidgets('своя ссылка: открыта один раз, история ничего не открывает',
      (tester) async {
    const settingsLink =
        WeatherSettings(source: WeatherSource.link, link: link);
    await pump(tester, settingsLink);
    await say(tester, 'какая погода');
    expect(opened, <List<String>>[
      <String>['xdg-open', link],
    ]);
    expect(find.textContaining('example.com'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('weather-card-open')),
      findsOneWidget,
    );
    expect(transport.requests, isEmpty);
    // «Открыть ещё раз» — по кнопке.
    await tester.tap(find.byKey(const ValueKey<String>('weather-card-open')));
    await tester.pumpAndSettle();
    expect(opened, hasLength(2));
    // Перезапуск: история из хранилища, ссылка сама не открывается.
    await tester.pumpWidget(const SizedBox());
    await pump(tester, settingsLink);
    await tester.pumpAndSettle();
    expect(opened, hasLength(2));
    final threads = await store.loadIndex();
    final cards = <Object?>[
      for (final thread in threads)
        for (final m in await store.loadMessages(thread.id))
          if (m.weather != null) m.toJson()['weather'],
    ];
    expect(cards, hasLength(1));
    expect(cards.single.toString(), isNot(contains('example.com')));
  });

  testWidgets('браузера нет — строка следом', (tester) async {
    browserMissing = true;
    await pump(
      tester,
      const WeatherSettings(source: WeatherSource.link, link: link),
    );
    await say(tester, 'какая погода');
    expect(
      find.textContaining('на устройстве не нашлось браузера'),
      findsOneWidget,
    );
  });
}
