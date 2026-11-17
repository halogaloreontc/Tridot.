import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/skills/weather/weather_settings.dart';

void main() {
  test('схема строчными: «HTTPS://» открывается и на Android, и на macOS', () {
    final result = WeatherLink.parse('HTTPS://yandex.ru/pogoda/kazan');
    expect(result.url, 'https://yandex.ru/pogoda/kazan');
    expect(WeatherLink.safe(result.url!), isTrue);
    expect(WeatherLink.safe('HTTPS://yandex.ru/pogoda/kazan'), isFalse);
  });

  test('ссылка из текста, без знаков после неё', () {
    expect(
      WeatherLink.parse('Погода: https://yandex.ru/pogoda/moscow.').url,
      'https://yandex.ru/pogoda/moscow',
    );
  });

  test('не https, без сайта, с логином — нельзя', () {
    expect(
      WeatherLink.parse('http://example.com').issue,
      WeatherLinkIssue.notHttps,
    );
    expect(
      WeatherLink.parse('javascript://x.ru').issue,
      WeatherLinkIssue.notHttps,
    );
    expect(
      WeatherLink.parse('https://localhost').issue,
      WeatherLinkIssue.noHost,
    );
    expect(
      WeatherLink.parse('https://a:b@example.com').issue,
      WeatherLinkIssue.noHost,
    );
  });
}
