import '../../connectors/connector.dart';
import '../../models/launch_request.dart';
import '../../models/weather_card.dart';
import '../../services/clock.dart';
import 'wear_advice.dart';
import 'weather_codes.dart';
import 'weather_phrases.dart';
import 'weather_service.dart';

export 'weather_phrases.dart';
export 'weather_service.dart';

/// Навык «Погода» (ADR-030): прогноз Open-Meteo в чате — только с
/// разрешения, своя страница погоды в браузере или приложение погоды.
///
/// `match` разбирает фразу без сети ([WeatherPhrases]); `run` спрашивает
/// [WeatherBackend], который без разрешения в сеть не ходит. Адрес своей
/// ссылки в текст ответа не попадает: его открывает интерфейс
/// ([LaunchRequest]), только у живого ответа. Ведёт Связной.
final class WeatherConnector implements Connector, ConnectorHealth {
  WeatherConnector({
    required this.backend,
    this.clock = const SystemClock(),
  });

  final WeatherBackend backend;
  final Clock clock;

  static const String id = 'weather';

  /// Явный вопрос о погоде: «будет дождь?», «что надеть».
  static const double confidence = 0.85;

  /// Погода, прогноз или температура названы прямо: выше вопроса складу
  /// «сколько … на улице» (0,75) с запасом больше порога спора.
  static const double strongConfidence = 0.92;

  /// Подпись карточки своей ссылки.
  static const String linkLabel = 'Страница погоды';

  @override
  ConnectorInfo get info => const ConnectorInfo(
        id: id,
        title: 'Погода',
        description: 'Прогноз в чате через Open-Meteo или ваша страница '
            'погоды — на выбор. Сеть — только с вашего разрешения.',
        examples: <String>[
          'какая погода завтра',
          'будет дождь?',
          'что надеть',
        ],
        kind: ExtensionKind.skill,
        requiresNetwork: true,
        defaultEnabled: false,
        offHint: true,
      );

  @override
  Future<HealthReport> health() async {
    await backend.load();
    final settings = backend.settings;
    final configured = switch (settings.source) {
      WeatherSource.none => false,
      WeatherSource.openMeteo => settings.networkAllowed,
      WeatherSource.link => settings.link != null,
      WeatherSource.app => settings.app != null || settings.link != null,
    };
    if (!configured) {
      return const HealthReport(
        HealthStatus.notConnected,
        detail: 'источник погоды не выбран',
      );
    }
    final error = backend.lastError;
    if (settings.source == WeatherSource.openMeteo &&
        (error == WeatherError.offline ||
            error == WeatherError.busy ||
            error == WeatherError.failed)) {
      return HealthReport(
        HealthStatus.degraded,
        detail: error == WeatherError.busy
            ? 'Open-Meteo перегружен'
            : 'нет связи с Open-Meteo',
        since: backend.lastErrorAt,
      );
    }
    return const HealthReport.ok();
  }

  @override
  ConnectorMatch? match(Utterance utterance) {
    final ask =
        WeatherPhrases.parse(utterance, clock.now()) ?? _followUp(utterance);
    if (ask == null) return null;
    return ConnectorMatch(
      connectorId: id,
      commandId: ask.commandId,
      confidence: ask.strong ? strongConfidence : confidence,
      payload: ask,
    );
  }

  /// «А завтра?», «а в Сочи?», «а на выходных?» сразу после ответа о
  /// погоде — тот же вопрос на другой день или о другом городе. Только
  /// короткий обрывок (до четырёх слов) из срока или «в/во Городе»: «а
  /// завтра купить хлеб» — уже не продолжение.
  WeatherAsk? _followUp(Utterance utterance) {
    if (utterance.recentConnectorId != id) return null;
    final match = _fragment.firstMatch(utterance.original.trim());
    if (match == null) return null;
    final rest = match.group(1)!.trim();
    final now = clock.now();
    final fragment = Utterance.analyze(rest, now: now);
    final words = fragment.words;
    if (words.isEmpty || words.length > 4) return null;
    final dateOnly = fragment.tokens.every(
      (UtteranceToken t) =>
          Utterance.isCovered(t, fragment.due.spans) ||
          t.text == 'на' ||
          t.text == 'в' ||
          t.text == 'во',
    );
    final place = _placeFragment.hasMatch(rest);
    final weekend = _weekend.hasMatch(rest.toLowerCase());
    if (!dateOnly && !place && !weekend) return null;
    return WeatherPhrases.parse(
      Utterance.analyze('погода $rest', now: now),
      now,
    );
  }

  static final RegExp _fragment = RegExp(
    r'^(?:а|и)\s+(?:как\s+|что\s+)?(?:насчет\s+|насчёт\s+)?'
    r'([^?!.]+?)\s*[?!.]*$',
    caseSensitive: false,
  );

  static final RegExp _placeFragment = RegExp(
    r'^(?:в|во)\s+[А-ЯЁ][а-яё-]+(?:\s+[А-ЯЁ][а-яё-]+)?$',
  );

  static final RegExp _weekend = RegExp(r'^на\s+выходных$');

  @override
  Future<AssistantResponse> run(
    ConnectorMatch match,
    AssistantSession session,
  ) async {
    final ask = match.payload! as WeatherAsk;
    await backend.load();
    final settings = backend.settings;
    final intent = ask.commandId;
    switch (settings.source) {
      case WeatherSource.none:
        return _setup(session, intent);
      case WeatherSource.link:
        final link = settings.link;
        if (link == null) return _setup(session, intent);
        return _openLink(link, ask, session, intent);
      case WeatherSource.app:
        final app = settings.app;
        if (app == null) {
          final link = settings.link;
          if (link == null) return _setup(session, intent);
          return _openLink(link, ask, session, intent);
        }
        return session.reply(
          'weather.app.opened',
          intent: intent,
          status: AssistantStatus.completed,
          weather: WeatherCard.launcher(
            label: 'Приложение: ${app.label}',
            app: true,
          ),
          launch: LaunchRequest.app(
            app.id,
            appLabel: app.label,
            fallbackUrl: settings.link,
          ),
        );
      case WeatherSource.openMeteo:
        break;
    }
    if (ask.kind == WeatherAskKind.past) {
      return session.reply(
        'weather.past',
        intent: intent,
        status: AssistantStatus.noAction,
      );
    }
    final now = clock.now();
    if (ask.kind == WeatherAskKind.range) {
      return session.reply(
        'weather.range',
        values: <String, String>{
          'last': WeatherFormat.date(
            DateTime(now.year, now.month, now.day + OpenMeteo.days - 1),
          ),
        },
        intent: intent,
        status: AssistantStatus.noAction,
      );
    }
    if (!settings.networkAllowed) {
      return session.reply(
        'weather.network.off',
        intent: intent,
        status: AssistantStatus.noAction,
      );
    }
    final result = await backend.forecast(placeQuery: ask.placeQuery);
    final forecast = result.forecast;
    if (forecast == null) return _failure(result, session, intent);
    final focus = ask.dayOffset ?? 0;
    if (focus >= forecast.days.length) {
      return session.reply(
        'weather.range',
        values: <String, String>{
          'last': WeatherFormat.date(forecast.days.last.date),
        },
        intent: intent,
        status: AssistantStatus.noAction,
      );
    }
    String? prefix;
    if (result.stale) {
      prefix = result.error == WeatherError.busy
          ? session.say('weather.busy')
          : session.say('weather.offline.cached', <String, String>{
              'time': _fetchedText(forecast.fetchedAt, now),
            });
    }
    final card = WeatherCard.forecast(
      forecast,
      focusDay: ask.dayOffset,
      stale: result.stale,
    );
    final (replyId, values) = _answer(ask, forecast, session);
    return session.reply(
      replyId,
      values: values,
      intent: intent,
      status: AssistantStatus.completed,
      weather: card,
      prefix: prefix,
    );
  }

  /// «9:30» сегодня или «14 ноября, 9:30».
  static String _fetchedText(DateTime fetched, DateTime now) {
    final sameDay = fetched.year == now.year &&
        fetched.month == now.month &&
        fetched.day == now.day;
    final clock = WeatherFormat.clock(fetched);
    return sameDay ? clock : '${WeatherFormat.date(fetched)}, $clock';
  }

  AssistantResponse _setup(AssistantSession session, String intent) =>
      session.reply(
        'weather.setup',
        intent: intent,
        status: AssistantStatus.noAction,
        weather: const WeatherCard.setup(),
      );

  AssistantResponse _openLink(
    String link,
    WeatherAsk ask,
    AssistantSession session,
    String intent,
  ) =>
      session.reply(
        ask.placeQuery == null ? 'weather.link.opened' : 'weather.link.city',
        intent: intent,
        status: AssistantStatus.completed,
        weather: const WeatherCard.launcher(label: linkLabel),
        launch: LaunchRequest.url(link),
      );

  AssistantResponse _failure(
    WeatherResult result,
    AssistantSession session,
    String intent,
  ) {
    if (result.missingPlace) {
      return session.reply(
        'weather.city.missing',
        intent: intent,
        status: AssistantStatus.needsClarification,
      );
    }
    return switch (result.error) {
      WeatherError.notFound => session.reply(
          'weather.place.notFound',
          values: <String, String>{'query': result.query ?? ''},
          intent: intent,
          status: AssistantStatus.noAction,
        ),
      WeatherError.noConsent => session.reply(
          'weather.network.off',
          intent: intent,
          status: AssistantStatus.noAction,
        ),
      WeatherError.offline => session.reply(
          'weather.offline.none',
          intent: intent,
          status: AssistantStatus.failed,
        ),
      WeatherError.busy => session.reply(
          'weather.busy',
          intent: intent,
          status: AssistantStatus.failed,
        ),
      WeatherError.failed || null => session.reply(
          'weather.failed',
          intent: intent,
          status: AssistantStatus.failed,
        ),
    };
  }

  /// Запись каталога и факты для ответа с прогнозом.
  (String, Map<String, String>) _answer(
    WeatherAsk ask,
    Forecast forecast,
    AssistantSession session,
  ) {
    final place = forecast.place.name;
    final offset = ask.dayOffset ?? 0;
    final today = forecast.today;
    final day = forecast.day(offset) ?? forecast.days.first;
    final current = forecast.current;
    final dayText = ask.range == WeatherRange.weekend
        ? 'на выходных'
        : WeatherFormat.day(today, offset);
    switch (ask.kind) {
      case WeatherAskKind.week:
        return ('weather.week', <String, String>{'place': place});
      case WeatherAskKind.day:
        return (
          'weather.day',
          <String, String>{
            'place': place,
            'day': dayText,
            'sky': WeatherCodes.sky(day.code),
            'min': WeatherFormat.temp(day.min),
            'max': WeatherFormat.temp(day.max),
            'chance': WeatherFormat.percent(day.chance),
          },
        );
      case WeatherAskKind.rain:
        return _rain(ask, forecast, place, dayText);
      case WeatherAskKind.wear:
        final now = offset == 0;
        final feels = now
            ? current.feelsLike ?? current.temperature
            : day.feelsMax ?? day.max;
        final advice = <String>[
          for (final id in WearAdvice.of(
            feels: feels,
            precipChance: day.chance,
            code: now && WeatherCodes.isWet(current.code)
                ? current.code
                : day.code,
            windMax: day.windMax,
          ))
            session.say(id),
        ].join(' ');
        return (
          'weather.wear',
          <String, String>{
            'place': place,
            'day': dayText,
            'sky': WeatherCodes.sky(now ? current.code : day.code),
            'feels': WeatherFormat.temp(feels),
            'advice': advice,
          },
        );
      case WeatherAskKind.now:
      case WeatherAskKind.open:
      case WeatherAskKind.past:
      case WeatherAskKind.range:
        return (
          'weather.now',
          <String, String>{
            'place': place,
            'temp': WeatherFormat.temp(current.temperature),
            'sky': WeatherCodes.sky(current.code),
            'feels':
                WeatherFormat.temp(current.feelsLike ?? current.temperature),
            'wind': WeatherFormat.wind(current.wind, current.gusts),
          },
        );
    }
  }

  (String, Map<String, String>) _rain(
    WeatherAsk ask,
    Forecast forecast,
    String place,
    String dayText,
  ) {
    final offset = ask.dayOffset ?? 0;
    final days = <DailyWeather>[
      if (forecast.day(offset) case final DailyWeather d) d,
      if (ask.range == WeatherRange.weekend)
        if (forecast.day(offset + 1) case final DailyWeather d) d,
    ];
    if (days.isEmpty) days.add(forecast.days.first);
    var chance = 0;
    var known = false;
    var code = days.first.code;
    for (final day in days) {
      if (day.chance != null) {
        known = true;
        if (day.chance! > chance) chance = day.chance!;
      }
      if (WeatherCodes.isWet(day.code) && !WeatherCodes.isWet(code)) {
        code = day.code;
      }
    }
    final current = forecast.current;
    final nowWet =
        offset == 0 && ask.range == null && WeatherCodes.isWet(current.code);
    if (nowWet) code = current.code;
    final wet = WeatherCodes.isWet(code);
    final kind = WeatherCodes.kind(code) ??
        ((days.first.max ?? 1) <= 0 ? 'снег' : 'дождь');
    final values = <String, String>{
      'place': place,
      'day': dayText,
      'chance': known ? '$chance%' : 'нет данных',
      'kind': kind,
    };
    if (nowWet || chance >= 60 || (wet && (!known || chance >= 40))) {
      return ('weather.rain.yes', values);
    }
    if (chance >= 30 || wet) {
      return (
        'weather.rain.maybe',
        <String, String>{
          'place': place,
          'day': dayText,
          'chance': values['chance']!,
        }
      );
    }
    return (
      'weather.rain.no',
      <String, String>{'place': place, 'day': dayText}
    );
  }
}
