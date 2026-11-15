import 'package:flutter/foundation.dart';

import '../../core/models/launch_request.dart';
import '../../core/skills/weather/weather_service.dart';
import '../links/link_opener.dart';

/// Чем кончилось открытие страницы или приложения погоды.
enum WeatherLaunch {
  /// Открылось то, что просили.
  opened,

  /// Приложение не открылось — открыта запасная ссылка.
  fallback,

  /// Страница не открылась: браузера нет.
  linkFailed,

  /// Приложение не открылось, а ссылки нет (или и она не открылась).
  appMissing;

  /// Строка вслед за ответом; `null` — всё открылось как сказано.
  String? get followUpId => switch (this) {
        opened => null,
        fallback => 'weather.app.fallback',
        linkFailed => 'weather.link.failed',
        appMissing => 'weather.app.missing',
      };
}

/// Погода для экрана настроек и карточки (ADR-030): [WeatherService] и
/// [LinkOpener] с уведомлением об изменениях.
final class WeatherKit extends ChangeNotifier {
  WeatherKit({required this.service, required this.links});

  final WeatherService service;
  final LinkOpener links;

  WeatherSettings get settings => service.settings;

  Future<void> load() async {
    await service.load();
    notifyListeners();
  }

  Future<void> _update(WeatherSettings settings) async {
    await service.update(settings);
    notifyListeners();
  }

  Future<void> setSource(WeatherSource source) =>
      _update(settings.copyWith(source: source));

  /// «Разрешить» в окне согласия.
  Future<void> allowNetwork() async {
    await service.allowNetwork();
    notifyListeners();
  }

  /// «Отозвать»: запросов больше нет.
  Future<void> revokeNetwork() async {
    await service.revokeNetwork();
    notifyListeners();
  }

  Future<void> setPlace(WeatherPlace place) =>
      _update(settings.copyWith(place: place));

  /// Сохраняет ссылку, если она прошла проверку; иначе — что не так.
  Future<WeatherLinkIssue?> setLink(String text) async {
    final result = WeatherLink.parse(text);
    if (!result.ok) return result.issue;
    await _update(settings.copyWith(link: result.url));
    return null;
  }

  Future<void> clearLink() => _update(settings.copyWith(clearLink: true));

  Future<void> setApp(WeatherApp app) => _update(settings.copyWith(app: app));

  /// «Удалить данные погоды»: кэш и найденные города.
  Future<void> clearData() async {
    await service.clearData();
    notifyListeners();
  }

  Future<List<WeatherPlace>> search(String name) => service.search(name);

  /// «Проверить» (Open-Meteo): один запрос прогноза.
  Future<WeatherResult> check() async {
    final place = settings.place;
    final result = place == null
        ? const WeatherResult.noPlace()
        : await service.forecastFor(place, refresh: true);
    notifyListeners();
    return result;
  }

  /// «Обновить» на карточке.
  Future<WeatherResult> refresh(WeatherPlace place) async {
    final result = await service.forecastFor(place, refresh: true);
    notifyListeners();
    return result;
  }

  /// Открыть то, что попросил ответ.
  Future<WeatherLaunch> launch(LaunchRequest request) async {
    final app = request.appId;
    final url = request.url;
    if (app == null) {
      if (url == null) return WeatherLaunch.linkFailed;
      return await links.openUrl(url)
          ? WeatherLaunch.opened
          : WeatherLaunch.linkFailed;
    }
    if (await links.openApp(app)) return WeatherLaunch.opened;
    if (url != null && await links.openUrl(url)) return WeatherLaunch.fallback;
    return WeatherLaunch.appMissing;
  }

  /// «Открыть ещё раз» на карточке: адрес и приложение — из настроек, не
  /// из истории чата.
  Future<WeatherLaunch> openAgain() {
    final s = settings;
    final app = s.app;
    if (s.source == WeatherSource.app && app != null) {
      return launch(
        LaunchRequest.app(app.id, appLabel: app.label, fallbackUrl: s.link),
      );
    }
    final link = s.link;
    if (link == null) {
      return Future<WeatherLaunch>.value(WeatherLaunch.linkFailed);
    }
    return launch(LaunchRequest.url(link));
  }
}
