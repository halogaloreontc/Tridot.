import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/models/weather_card.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/skills/weather/open_meteo_client.dart';
import 'package:local_assistant/core/skills/weather/weather_models.dart';

import '../support/fake_weather.dart';

void main() {
  const kazan = WeatherPlace(
    name: 'Казань',
    latitude: 55.78874,
    longitude: 49.12214,
    admin1: 'Татарстан',
    country: 'Россия',
    countryCode: 'RU',
  );

  Future<Forecast> forecast() => OpenMeteoClient(
        RecordingTransport.kazan(),
        clock: FixedClock(DateTime(2026, 11, 15, 9, 40)),
      ).forecast(kazan);

  ChatMessage message(WeatherCard card) => ChatMessage(
        id: 'm_1_1',
        author: ChatAuthor.persona,
        text: 'Казань: сейчас +2°',
        timestamp: DateTime(2026, 11, 15, 9, 41),
        personaId: 'sado',
        weather: card,
      );

  ChatMessage? roundTrip(ChatMessage m) =>
      ChatMessage.fromJson(jsonDecode(jsonEncode(m.toJson())));

  test('прогноз туда и обратно', () async {
    final f = await forecast();
    final back = roundTrip(
      message(WeatherCard.forecast(f, focusDay: 1, stale: true)),
    )!;
    final card = back.weather!;
    expect(card.kind, WeatherCardKind.forecast);
    expect(card.focusDay, 1);
    expect(card.stale, isTrue);
    expect(card.forecast!.place, kazan);
    expect(card.forecast!.place.admin1, 'Татарстан');
    expect(card.forecast!.current.temperature, 2.0);
    expect(card.forecast!.current.time, DateTime(2026, 11, 15, 9, 30));
    expect(card.forecast!.days, hasLength(7));
    expect(card.forecast!.days[1].chance, 75);
    expect(card.forecast!.fetchedAt, DateTime(2026, 11, 15, 9, 40));
  });

  test('карточка ссылки — без адреса', () {
    final back = roundTrip(
      message(const WeatherCard.launcher(label: 'Страница погоды')),
    )!;
    expect(back.weather!.kind, WeatherCardKind.launcher);
    expect(back.weather!.label, 'Страница погоды');
    expect(jsonEncode(back.toJson()), isNot(contains('https')));
  });

  test('битая карточка — сообщение без неё', () {
    final json = message(const WeatherCard.setup()).toJson()
      ..['weather'] = <String, Object?>{'kind': 'forecast', 'forecast': 7};
    final back = ChatMessage.fromJson(json)!;
    expect(back.text, 'Казань: сейчас +2°');
    expect(back.weather, isNull);
  });

  test('«Обновить» меняет снимок, остальное то же', () async {
    final f = await forecast();
    final m = message(WeatherCard.forecast(f, focusDay: 2, stale: true));
    final updated = m.withWeather(m.weather!.refreshed(f));
    expect(updated.id, m.id);
    expect(updated.text, m.text);
    expect(updated.weather!.focusDay, 2);
    expect(updated.weather!.stale, isFalse);
  });

  test('без карточки — без ключа weather', () {
    final m = ChatMessage(
      id: 'm_2_1',
      author: ChatAuthor.persona,
      text: 'Привет',
      timestamp: DateTime(2026, 11, 15),
    );
    expect(m.toJson().containsKey('weather'), isFalse);
    expect(m.toJson().containsKey('launch'), isFalse);
  });
}
