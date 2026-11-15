import 'package:flutter/material.dart';

import '../../core/models/weather_card.dart';
import '../../core/skills/weather/open_meteo_client.dart';
import '../../core/skills/weather/weather_codes.dart';
import '../../core/skills/weather/weather_models.dart';
import '../assistant_theme.dart';
import 'whole_word_text.dart';

/// Иконка Material для значка погоды.
IconData weatherIcon(WeatherGlyph glyph) => switch (glyph) {
      WeatherGlyph.sun => Icons.wb_sunny_outlined,
      WeatherGlyph.cloud => Icons.cloud_outlined,
      WeatherGlyph.fog => Icons.foggy,
      WeatherGlyph.rain => Icons.water_drop_outlined,
      WeatherGlyph.snow => Icons.ac_unit,
      WeatherGlyph.storm => Icons.thunderstorm_outlined,
    };

/// Карточка погоды под ответом (ADR-030, оформление — ADR-027): прогноз
/// Open-Meteo с подписью источника, «Открыть ещё раз» для своей страницы
/// или приложения, «Настроить», пока источник не выбран.
final class WeatherCardView extends StatefulWidget {
  const WeatherCardView({
    super.key,
    required this.card,
    this.compact = false,
    this.busy = false,
    this.onRefresh,
    this.onMore,
    this.onOpenSite,
    this.onOpenAgain,
    this.onSetup,
  });

  final WeatherCard card;

  /// Телефон: видно 5 дней, ниже — «Ещё 2 дня».
  final bool compact;

  /// Идёт «Обновить».
  final bool busy;
  final VoidCallback? onRefresh;

  /// «Подробнее» — своя страница погоды; `null` — ссылки нет.
  final VoidCallback? onMore;

  /// Подпись источника — сайт Open-Meteo.
  final VoidCallback? onOpenSite;
  final VoidCallback? onOpenAgain;
  final VoidCallback? onSetup;

  /// Наибольшая ширина карточки.
  static const double maxWidth = 420;

  /// Сколько дней видно на телефоне до «Ещё».
  static const int compactDays = 5;

  @override
  State<WeatherCardView> createState() => _WeatherCardViewState();
}

final class _WeatherCardViewState extends State<WeatherCardView> {
  bool _allDays = false;

  static const List<FontFeature> _tabular = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final Widget body = switch (card.kind) {
      WeatherCardKind.forecast => _forecast(context, card.forecast!),
      WeatherCardKind.launcher => _launcher(context, card),
      WeatherCardKind.setup => _setup(context),
    };
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: WeatherCardView.maxWidth),
        child: Semantics(
          container: true,
          child: Material(
            key: const ValueKey<String>('weather-card'),
            color: context.colors.raised,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: body,
            ),
          ),
        ),
      ),
    );
  }

  TextStyle _style(
    BuildContext context,
    double size, {
    Color? color,
    FontWeight? weight,
  }) =>
      TextStyle(
        fontFamily: AppFonts.text,
        fontSize: size,
        height: 1.3,
        color: color ?? context.colors.text,
        fontWeight: weight,
      );

  Widget _forecast(BuildContext context, Forecast forecast) {
    final colors = context.colors;
    final current = forecast.current;
    final stale = widget.card.stale;
    final time = WeatherFormat.clock(current.time);
    final region = forecast.place.region;
    final days = forecast.days;
    final shown = widget.compact && !_allDays
        ? days.take(WeatherCardView.compactDays).toList()
        : days;
    final hidden = days.length - shown.length;
    final today = forecast.day(0);
    final precip = <String>[
      'Осадки ${WeatherFormat.millimetres(current.precipitation)}',
      if (today?.chance != null) WeatherFormat.percent(today!.chance),
    ].join(' · ');
    final wind = current.wind == null
        ? null
        : 'Ветер ${WeatherFormat.speed(current.wind)}'
            '${current.gusts != null && current.gusts! >= current.wind! + 4 ? ', порывы до ${current.gusts!.round()}' : ''}';
    final large = MediaQuery.textScalerOf(context).scale(10) > 13;
    final timeText = WholeWordText(
      stale ? 'нет связи · данные на $time' : 'на $time',
      key: const ValueKey<String>('weather-card-time'),
      textAlign: large ? TextAlign.start : TextAlign.end,
      style: _style(
        context,
        13,
        color: stale ? colors.warning : colors.muted,
      ),
    );
    final sky = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        WholeWordText(
          WeatherCodes.sky(current.code),
          style: _style(context, 15, color: colors.textStrong),
        ),
        WholeWordText(
          'Ощущается как '
          '${WeatherFormat.temp(current.feelsLike ?? current.temperature)}',
          style: _style(context, 15, color: colors.muted),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  WholeWordText(
                    forecast.place.name,
                    key: const ValueKey<String>('weather-card-place'),
                    style: _style(
                      context,
                      17,
                      color: colors.textStrong,
                      weight: FontWeight.w600,
                    ),
                  ),
                  if (region.isNotEmpty)
                    WholeWordText(
                      region.replaceAll(', ', ' · '),
                      style: _style(context, 13, color: colors.muted),
                    ),
                  // Крупный шрифт: время — строкой ниже, а не сбоку.
                  if (large) timeText,
                ],
              ),
            ),
            if (!large) ...<Widget>[
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 170),
                child: timeText,
              ),
            ],
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            Icon(
              weatherIcon(WeatherCodes.glyph(current.code)),
              size: 28,
              color: colors.icon,
            ),
            const SizedBox(width: 10),
            Text(
              WeatherFormat.temp(current.temperature),
              key: const ValueKey<String>('weather-card-temp'),
              style: TextStyle(
                fontFamily: AppFonts.text,
                fontSize: 34,
                height: 1.1,
                fontWeight: FontWeight.w300,
                color: colors.textStrong,
                fontFeatures: _tabular,
              ),
            ),
            if (!large) ...<Widget>[
              const SizedBox(width: 12),
              Expanded(child: sky),
            ],
          ],
        ),
        if (large) sky,
        const SizedBox(height: 8),
        WholeWordText(
          <String>[precip, if (wind != null) wind].join('\n'),
          style: _style(context, 13, color: colors.muted),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < shown.length; i++)
          _dayRow(context, forecast, shown[i], i),
        if (hidden > 0)
          Row(
            children: <Widget>[
              TextButton(
                key: const ValueKey<String>('weather-card-more-days'),
                style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
                onPressed: () => setState(() => _allDays = true),
                child: Text(
                  'Ещё $hidden ${hidden == 1 ? 'день' : hidden < 5 ? 'дня' : 'дней'}',
                ),
              ),
            ],
          ),
        // Действия — своей строкой, указание источника — под ними: так
        // «Обновить» не падает одна на следующую строку.
        if (widget.onMore != null || widget.busy || widget.onRefresh != null)
          Wrap(
            spacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              if (widget.onMore != null)
                TextButton(
                  key: const ValueKey<String>('weather-card-details'),
                  style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
                  onPressed: widget.onMore,
                  child: const Text('Подробнее'),
                ),
              if (widget.busy)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (widget.onRefresh != null)
                TextButton(
                  key: const ValueKey<String>('weather-card-refresh'),
                  style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
                  onPressed: widget.onRefresh,
                  child: const Text('Обновить'),
                ),
            ],
          ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            key: const ValueKey<String>('weather-card-attribution'),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              foregroundColor: colors.muted,
              textStyle: _style(context, 13),
            ),
            onPressed: widget.onOpenSite,
            child: const Text(OpenMeteo.attribution),
          ),
        ),
      ],
    );
  }

  Widget _dayRow(
    BuildContext context,
    Forecast forecast,
    DailyWeather day,
    int index,
  ) {
    final colors = context.colors;
    final offset = day.date.difference(forecast.today).inHours ~/ 24;
    final focus =
        widget.card.focusDay != null && widget.card.focusDay == offset;
    final chance = day.chance;
    final value = _style(context, 15, color: colors.textStrong)
        .copyWith(fontFeatures: _tabular);
    return Container(
      key: ValueKey<String>('weather-card-day-$index'),
      constraints: const BoxConstraints(minHeight: 36),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: focus
          ? BoxDecoration(
              color: colors.fieldOnRaised,
              borderRadius: BorderRadius.circular(8),
            )
          : null,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final label = WholeWordText(
            offset == 0 ? 'Сегодня' : WeatherFormat.shortDay(day.date),
            style: _style(context, 15, color: colors.textStrong),
          );
          final soft =
              value.copyWith(color: focus ? colors.text : colors.muted);
          // На выделенной строке приглушённый цвет бледнее 4,5:1 — там
          // обычный текст.
          final values = <Widget>[
            Icon(
              weatherIcon(WeatherCodes.glyph(day.code)),
              size: 20,
              color: colors.icon,
            ),
            const SizedBox(width: 10),
            // Диапазон — постоянной ширины: значки дней стоят столбцом.
            SizedBox(
              width: _rangeWidth(context, value),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  Text(WeatherFormat.temp(day.min), style: soft),
                  Text(' … ', style: soft),
                  Text(WeatherFormat.temp(day.max), style: value),
                ],
              ),
            ),
            SizedBox(
              width: 8 + MediaQuery.textScalerOf(context).scale(36),
              child: chance != null && chance >= 20
                  ? Text(
                      '$chance%',
                      textAlign: TextAlign.end,
                      style: _style(context, 13, color: colors.muted),
                    )
                  : null,
            ),
          ];
          // Крупный шрифт на узком экране: день — строкой выше значений.
          final scale = MediaQuery.textScalerOf(context).scale(15) / 15;
          if (constraints.maxWidth < 110 * scale + 150) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                label,
                Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: values,
                ),
              ],
            );
          }
          return Row(children: <Widget>[Expanded(child: label), ...values]);
        },
      ),
    );
  }

  /// Ширина самого длинного диапазона «−00° … −00°» в этом шрифте.
  static double _rangeWidth(BuildContext context, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(
        text: '${WeatherFormat.temp(-88)} … ${WeatherFormat.temp(-88)}',
        style: style,
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width.ceilToDouble() + 1;
    painter.dispose();
    return width;
  }

  Widget _launcher(BuildContext context, WeatherCard card) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(
              card.app ? Icons.apps : Icons.open_in_new,
              size: 22,
              color: colors.icon,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: WholeWordText(
                card.label ?? 'Страница погоды',
                key: const ValueKey<String>('weather-card-label'),
                style: _style(context, 15, color: colors.textStrong),
              ),
            ),
          ],
        ),
        TextButton(
          key: const ValueKey<String>('weather-card-open'),
          style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: widget.onOpenAgain,
          child: const Text('Открыть ещё раз'),
        ),
      ],
    );
  }

  Widget _setup(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(Icons.cloud_outlined, size: 22, color: colors.icon),
            const SizedBox(width: 10),
            Expanded(
              child: WholeWordText(
                'Источник погоды не выбран',
                style: _style(context, 15, color: colors.textStrong),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        TextButton(
          key: const ValueKey<String>('weather-card-setup'),
          style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: widget.onSetup,
          child: const Text('Настроить'),
        ),
      ],
    );
  }
}
