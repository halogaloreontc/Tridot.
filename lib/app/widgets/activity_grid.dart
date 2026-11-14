import 'package:flutter/material.dart';

import '../../core/formatting/plural.dart';
import '../assistant_theme.dart';

const List<String> _monthsShort = <String>[
  'янв.',
  'февр.',
  'март',
  'апр.',
  'май',
  'июнь',
  'июль',
  'авг.',
  'сент.',
  'окт.',
  'нояб.',
  'дек.',
];

const List<String> _monthsGenitive = <String>[
  'января',
  'февраля',
  'марта',
  'апреля',
  'мая',
  'июня',
  'июля',
  'августа',
  'сентября',
  'октября',
  'ноября',
  'декабря',
];

const List<String> _monthsPrepositional = <String>[
  'январе',
  'феврале',
  'марте',
  'апреле',
  'мае',
  'июне',
  'июле',
  'августе',
  'сентябре',
  'октябре',
  'ноябре',
  'декабре',
];

/// «16 недель», «52 недели».
String weeksLabel(int n) => '$n ${ruPlural(n, 'неделя', 'недели', 'недель')}';

/// Уровень клетки 0..3 по числу дел за день.
int activityLevel(int count) {
  if (count <= 0) return 0;
  if (count == 1) return 1;
  if (count <= 3) return 2;
  return 3;
}

/// Цвет уровня: heat0..heat3 палитры П1.
Color activityShade(int level) => switch (level) {
      <= 0 => AssistantColors.heat0,
      1 => AssistantColors.heat1,
      2 => AssistantColors.heat2,
      _ => AssistantColors.heat3,
    };

/// Подпись для экранного диктора по тем же данным, что и клетки:
/// «Активность за 16 недель: 28 активных дней, с 27 июля; чаще всего — в
/// ноябре (12 дней)».
String activitySemantics(Map<DateTime, int> counts, DateTime now, int weeks) {
  final days = ActivityGrid.days(now, weeks);
  var active = 0;
  DateTime? first;
  final perMonth = <int, int>{};
  for (final day in days) {
    if ((counts[day] ?? 0) <= 0) continue;
    active++;
    first ??= day;
    final key = day.year * 12 + day.month - 1;
    perMonth[key] = (perMonth[key] ?? 0) + 1;
  }
  final head = 'Активность за ${weeksLabel(weeks)}: ';
  if (active == 0 || first == null) return '$headактивных дней нет';
  var topKey = perMonth.keys.first;
  for (final MapEntry(:key, :value) in perMonth.entries) {
    if (value > perMonth[topKey]!) topKey = key;
  }
  final word =
      ruPlural(active, 'активный день', 'активных дня', 'активных дней');
  return '$head$active $word, с ${first.day} '
      '${_monthsGenitive[first.month - 1]}; чаще всего — в '
      '${_monthsPrepositional[topKey % 12]} (${_daysWord(perMonth[topKey]!)})';
}

/// «1 день», «2 дня»: внутри [ActivityGrid] имя `days` занято.
String _daysWord(int n) => days(n);

/// Сетка активности (макет «Д»): столбцы — недели, строки — пн..вс,
/// последний столбец содержит сегодня. Подписи месяцев сверху, «Пн/Ср/Пт»
/// слева, легенда «меньше … больше» в шапке.
final class ActivityGrid extends StatelessWidget {
  const ActivityGrid({
    super.key,
    required this.counts,
    required this.now,
    this.weeks = 16,
    this.title = 'Активность',
    this.approximate = false,
    this.cell = 14,
    this.gap = 4,
  });

  /// Локальная дата в полночь → сколько дел за день.
  final Map<DateTime, int> counts;
  final DateTime now;
  final int weeks;
  final String title;

  /// Сессии ещё не прочитаны целиком: подпись честно говорит об этом.
  final bool approximate;

  /// Клетка и зазор: 14/4 на телефоне, 12/3 для года на компьютере.
  final double cell;
  final double gap;

  /// Дни сетки по порядку: с понедельника первой недели по сегодня.
  static List<DateTime> days(DateTime now, int weeks) {
    final today = DateTime(now.year, now.month, now.day);
    final lastMonday = DateTime(
      today.year,
      today.month,
      today.day - (today.weekday - 1),
    );
    final first = DateTime(
      lastMonday.year,
      lastMonday.month,
      lastMonday.day - 7 * (weeks - 1),
    );
    return <DateTime>[
      for (var i = 0; i < weeks * 7; i++)
        DateTime(first.year, first.month, first.day + i),
    ].where((DateTime d) => !d.isAfter(today)).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final all = days(now, weeks);
    final first = all.first;
    final activeDays = all.where((DateTime d) => (counts[d] ?? 0) > 0).length;
    final label = activitySemantics(counts, now, weeks);

    final monthRow = <Widget>[];
    final columns = <Widget>[];
    for (var week = 0; week < weeks; week++) {
      var monthLabel = '';
      final cells = <Widget>[];
      for (var weekday = 0; weekday < 7; weekday++) {
        final day =
            DateTime(first.year, first.month, first.day + week * 7 + weekday);
        if (day.day == 1) monthLabel = _monthsShort[day.month - 1];
        if (weekday > 0) cells.add(SizedBox(height: gap));
        if (day.isAfter(all.last)) {
          cells.add(SizedBox.square(dimension: cell));
          continue;
        }
        final count = counts[day] ?? 0;
        cells.add(
          Container(
            key: Key('activity-${day.year}-${day.month}-${day.day}'),
            width: cell,
            height: cell,
            decoration: BoxDecoration(
              color: activityShade(activityLevel(count)),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        );
      }
      if (week > 0) {
        columns.add(SizedBox(width: gap));
        monthRow.add(SizedBox(width: gap));
      }
      columns.add(Column(mainAxisSize: MainAxisSize.min, children: cells));
      monthRow.add(
        SizedBox(
          width: cell,
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            maxWidth: 48,
            child: Text(
              monthLabel,
              maxLines: 1,
              softWrap: false,
              style: _small,
            ),
          ),
        ),
      );
    }

    const weekdayLabels = <String>['Пн', '', 'Ср', '', 'Пт', '', ''];
    final grid = MediaQuery.withNoTextScaling(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const SizedBox(height: 16 + 6),
              for (var i = 0; i < 7; i++) ...<Widget>[
                if (i > 0) SizedBox(height: gap),
                // Строка подписи выше клетки 12: подпись выходит за клетку
                // по центру строки, а не обрезается («Ср», а не «Сɒ»).
                SizedBox(
                  width: 22,
                  height: cell,
                  child: OverflowBox(
                    alignment: Alignment.centerLeft,
                    maxHeight: cell + 2 * gap + 8,
                    child: Text(
                      weekdayLabels[i],
                      key: Key('activity-weekday-$i'),
                      maxLines: 1,
                      softWrap: false,
                      style: _small,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(width: 6),
          // Подписи дней стоят на месте, прокручиваются только недели;
          // свежие справа, поэтому прокрутка начинается с конца.
          Flexible(
            child: SingleChildScrollView(
              key: const Key('activity-scroll'),
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox(
                    height: 16,
                    child:
                        Row(mainAxisSize: MainAxisSize.min, children: monthRow),
                  ),
                  const SizedBox(height: 6),
                  Row(mainAxisSize: MainAxisSize.min, children: columns),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    return DecoratedBox(
      key: const Key('activity-grid'),
      decoration: BoxDecoration(
        color: AssistantColors.raised,
        border: Border.all(color: AssistantColors.borderSoft),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              spacing: 8,
              runSpacing: 6,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Semantics(
                      header: true,
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 15,
                          height: 1.3,
                          fontWeight: FontWeight.w600,
                          color: AssistantColors.textStrong,
                        ),
                      ),
                    ),
                    Text(
                      '${weeksLabel(weeks)} · ${_daysWord(activeDays)}'
                      '${approximate ? ' · по сессиям приблизительно' : ''}',
                      key: const Key('activity-total'),
                      style: metaTextStyle,
                    ),
                  ],
                ),
                ExcludeSemantics(
                  child: Wrap(
                    spacing: 3,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      const Text('меньше', style: metaTextStyle),
                      for (var level = 0; level < 4; level++)
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: activityShade(level),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      const Text('больше', style: metaTextStyle),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Semantics(
              key: const Key('activity-semantics'),
              label: label,
              image: true,
              child: ExcludeSemantics(child: grid),
            ),
          ],
        ),
      ),
    );
  }
}

const TextStyle _small = TextStyle(
  fontSize: 12,
  height: 1.2,
  color: AssistantColors.muted,
);
