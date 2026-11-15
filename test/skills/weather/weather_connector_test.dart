import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/models/weather_card.dart';
import 'package:local_assistant/core/replies/reply_library.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/skills/weather/weather_connector.dart';

import '../../support/fake_weather.dart';

const WeatherPlace kazan = WeatherPlace(
  name: 'Казань',
  latitude: 55.78874,
  longitude: 49.12214,
  admin1: 'Татарстан',
  country: 'Россия',
  countryCode: 'RU',
);

void main() {
  // Воскресенье, 15 ноября — «сегодня» прогноза Казани.
  final clock = FixedClock(DateTime(2026, 11, 15, 9, 40));

  Future<(WeatherConnector, RecordingTransport)> setup(
    WeatherSettings settings, {
    RecordingTransport? transport,
  }) async {
    final t = transport ?? RecordingTransport.kazan();
    final service = WeatherService(transport: t, clock: clock);
    await service.update(settings);
    return (WeatherConnector(backend: service, clock: clock), t);
  }

  final openMeteo = WeatherSettings(
    source: WeatherSource.openMeteo,
    networkAllowedAt: DateTime(2026, 11, 1),
    place: kazan,
  );

  Future<AssistantResponse> say(
    WeatherConnector c,
    String text, {
    ReplyVoice voice = const ReplyVoice(),
  }) async {
    final match = c.match(Utterance.analyze(text, now: clock.value));
    expect(match, isNotNull, reason: text);
    final session = AssistantSession(clock: clock)..voice = voice;
    return c.run(match!, session);
  }

  test('каждый пример из info.examples распознаётся', () async {
    final (c, _) = await setup(openMeteo);
    for (final example in c.info.examples) {
      expect(
        c.match(Utterance.analyze(example, now: clock.value)),
        isNotNull,
        reason: example,
      );
    }
    expect(c.info.requiresNetwork, isTrue);
    expect(c.info.defaultEnabled, isFalse);
    expect(c.info.offHint, isTrue);
  });

  group('Open-Meteo', () {
    test('сейчас: карточка и текст с фактами', () async {
      final (c, _) = await setup(openMeteo);
      final r = await say(c, 'какая погода');
      expect(r.intent, 'weather.now');
      expect(r.replyId, 'weather.now');
      expect(r.message, contains('Казань'));
      expect(r.message, contains('+2°'));
      expect(r.message, contains('−2°'));
      expect(r.message, contains('пасмурно'));
      expect(r.weather?.kind, WeatherCardKind.forecast);
      expect(r.weather?.stale, isFalse);
      expect(r.launch, isNull);
    });

    test('завтра: день, мин и макс, вероятность', () async {
      final (c, _) = await setup(openMeteo);
      final r = await say(c, 'какая погода завтра');
      expect(r.replyId, 'weather.day');
      expect(r.message, contains('завтра'));
      expect(r.message, contains('75%'));
      expect(r.weather?.focusDay, 1);
    });

    test('дождь завтра — да; сегодня — нет', () async {
      final (c, _) = await setup(openMeteo);
      expect((await say(c, 'будет дождь завтра?')).replyId, 'weather.rain.yes');
      expect((await say(c, 'будет дождь?')).replyId, 'weather.rain.no');
    });

    test('что надеть: совет из каталога', () async {
      final (c, _) = await setup(openMeteo);
      final r = await say(c, 'что надеть');
      expect(r.replyId, 'weather.wear');
      expect(r.message, contains('Подойдёт тёплая куртка.'));
    });

    test('город из фразы', () async {
      final (c, t) = await setup(openMeteo);
      final r = await say(c, 'погода в Москве');
      expect(r.message, startsWith('Москва'));
      expect(
        t.uris.first.queryParameters['name'],
        'Москва',
        reason: 'сначала именительный падеж',
      );
    });

    test('город не нашёлся', () async {
      final (c, _) = await setup(openMeteo);
      final r = await say(c, 'погода в Неведомске');
      expect(r.replyId, 'weather.place.notFound');
      expect(r.message, contains('«Неведомске»'));
    });

    test('без города в настройках — спросить', () async {
      final (c, t) = await setup(
        WeatherSettings(
          source: WeatherSource.openMeteo,
          networkAllowedAt: DateTime(2026, 11, 1),
        ),
      );
      final r = await say(c, 'какая погода');
      expect(r.replyId, 'weather.city.missing');
      expect(t.requests, isEmpty);
    });

    test('без разрешения — network.off, без запроса', () async {
      final (c, t) = await setup(
        const WeatherSettings(source: WeatherSource.openMeteo, place: kazan),
      );
      expect((await say(c, 'какая погода')).replyId, 'weather.network.off');
      expect(t.requests, isEmpty);
    });

    test('без связи и без кэша — offline.none', () async {
      final (c, _) = await setup(
        openMeteo,
        transport: RecordingTransport((_) => FakeReply.error(socketError)),
      );
      final r = await say(c, 'какая погода');
      expect(r.replyId, 'weather.offline.none');
      expect(r.status, AssistantStatus.failed);
    });

    test('через две недели — range; вчера — past', () async {
      final (c, t) = await setup(openMeteo);
      final range = await say(c, 'погода через две недели');
      expect(range.replyId, 'weather.range');
      expect(range.message, contains('21 ноября'));
      expect((await say(c, 'вчера был дождь?')).replyId, 'weather.past');
      expect(t.requests, isEmpty);
    });
  });

  group('своя ссылка', () {
    const link = 'https://example.com/weather?city=kzn';

    test('открывает ссылку, адреса в тексте нет', () async {
      final (c, t) = await setup(
        const WeatherSettings(source: WeatherSource.link, link: link),
      );
      final r = await say(c, 'какая погода');
      expect(r.replyId, 'weather.link.opened');
      expect(r.launch?.url, link);
      expect(r.launch?.isApp, isFalse);
      expect(r.message, isNot(contains('example.com')));
      expect(r.weather?.kind, WeatherCardKind.launcher);
      expect(r.weather?.toJson().toString(), isNot(contains('example.com')));
      expect(t.requests, isEmpty);
    });

    test('другой город — честно: по ссылке не узнать', () async {
      final (c, _) = await setup(
        const WeatherSettings(source: WeatherSource.link, link: link),
      );
      final r = await say(c, 'погода в Казани');
      expect(r.replyId, 'weather.link.city');
      expect(r.message, contains('Open-Meteo'));
    });
  });

  test('приложение с запасной ссылкой', () async {
    final (c, t) = await setup(
      const WeatherSettings(
        source: WeatherSource.app,
        app: WeatherApp(id: 'ru.yandex.weatherplugin', label: 'Яндекс Погода'),
        link: 'https://example.com/w',
      ),
    );
    final r = await say(c, 'открой погоду');
    expect(r.replyId, 'weather.app.opened');
    expect(r.launch?.appId, 'ru.yandex.weatherplugin');
    expect(r.launch?.url, 'https://example.com/w');
    expect(r.weather?.label, 'Приложение: Яндекс Погода');
    expect(t.requests, isEmpty);
  });

  test('источник не выбран — setup с кнопкой «Настроить»', () async {
    final (c, t) = await setup(const WeatherSettings());
    final r = await say(c, 'какая погода');
    expect(r.replyId, 'weather.setup');
    expect(r.weather?.kind, WeatherCardKind.setup);
    expect(t.requests, isEmpty);
    expect((await c.health()).status, HealthStatus.notConnected);
  });

  test('здоровье: после сбоя связи — degraded', () async {
    final (c, _) = await setup(
      openMeteo,
      transport: RecordingTransport((_) => FakeReply.error(socketError)),
    );
    expect((await c.health()).status, HealthStatus.ok);
    await say(c, 'какая погода');
    expect((await c.health()).status, HealthStatus.degraded);
  });

  group('все стили, «ты» и «вы», «м» и «ж»', () {
    const phrases = <String>[
      'какая погода',
      'какая погода завтра',
      'будет дождь завтра?',
      'будет дождь?',
      'будет снег в среду?',
      'что надеть',
      'во что одеться в пятницу',
      'прогноз на неделю',
      'погода в Неведомске',
      'вчера был дождь?',
      'погода через две недели',
    ];
    for (final style in ReplyStyles.builtIn) {
      for (final address in ReplyAddress.values) {
        for (final gender in ReplyGender.values) {
          test('$style, ${address.name}, ${gender.name}', () async {
            final (c, _) = await setup(openMeteo);
            for (final text in phrases) {
              final r = await say(
                c,
                text,
                voice:
                    ReplyVoice(style: style, gender: gender, address: address),
              );
              expect(r.message.trim(), isNotEmpty, reason: text);
              expect(r.message, isNot(contains('{')), reason: r.message);
              expect(r.message, isNot(contains('  ')), reason: r.message);
              for (final value in r.values.values) {
                expect(value, isNotEmpty, reason: '$text: ${r.values}');
              }
            }
          });
        }
      }
    }
  });
}
