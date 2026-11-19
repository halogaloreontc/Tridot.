import 'weather_models.dart';

/// Название города из фразы — в именительный падеж, на устройстве
/// (ADR-030).
///
/// Поиск Open-Meteo понимает только именительный падеж: «Казани»,
/// «Санкт-Петербурге» он не находит, а «Москве» находит «Москверо» в
/// Нью-Мексико. Поэтому падеж приводится здесь, а из ответа берётся только
/// точное совпадение названия ([pick]).
abstract final class PlaceNames {
  /// Сколько вариантов пробовать на одну фразу — не больше трёх запросов.
  static const int maxCandidates = 3;

  /// Предлоги и союзы внутри названия через дефис: «Ростов-на-Дону»,
  /// «Комсомольск-на-Амуре».
  static const Set<String> _linkWords = <String>{'на', 'над', 'под', 'де'};

  /// Варианты названия в именительном падеже, в порядке перебора: «Казани»
  /// → «Казань»; «Москве» → «Москва», «Москв»…; «Нижнем Новгороде» →
  /// «Нижний Новгород»; «Ростове-на-Дону» → «Ростов-на-Дону»; «Сочи» —
  /// как есть (последним вариантом всегда идёт исходное название).
  static List<String> candidates(String query) {
    final words = query
        .trim()
        .split(RegExp(r'\s+'))
        .where((String w) => w.isNotEmpty)
        .map(_capitalize)
        .toList();
    if (words.isEmpty) return const <String>[];
    // «Питер», «в Питере», «СПб», «мск» — разговорные имена городов.
    if (words.length == 1) {
      for (final variant in <String>[
        words.single,
        ..._nominative(words.single),
      ]) {
        final alias = _aliases[key(variant)];
        if (alias != null) return <String>[alias];
      }
    }
    // Прилагательные перед последним словом: «Нижнем» → «Нижний».
    final head = <String>[
      for (final word in words.sublist(0, words.length - 1)) _adjective(word),
    ];
    final out = <String>[];
    for (final last in _nounVariants(words.last)) {
      final candidate = <String>[...head, last].join(' ');
      if (!out.contains(candidate)) out.add(candidate);
    }
    final original = words.join(' ');
    if (!out.contains(original)) out.add(original);
    if (out.length <= maxCandidates) return out;
    // Исходное — всегда в переборе: несклоняемые названия.
    final first = out.take(maxCandidates - 1).toList();
    return first.contains(original)
        ? out.take(maxCandidates).toList()
        : <String>[...first, original];
  }

  /// Варианты существительного; через дефис меняется одна часть: первая,
  /// если дальше предлог («Ростове-на-Дону»), иначе последняя
  /// («Санкт-Петербурге»).
  static List<String> _nounVariants(String word) {
    final parts = word.split('-');
    if (parts.length > 1) {
      final linked = parts.skip(1).any(
            (String p) => _linkWords.contains(p.toLowerCase()),
          );
      final index = linked ? 0 : parts.length - 1;
      return <String>[
        for (final variant in _nominative(parts[index]))
          <String>[
            ...parts.sublist(0, index),
            variant,
            ...parts.sublist(index + 1),
          ].join('-'),
      ];
    }
    return _nominative(word);
  }

  /// Разговорные и короткие имена городов — полное название.
  static const Map<String, String> _aliases = <String, String>{
    'питер': 'Санкт-Петербург',
    'спб': 'Санкт-Петербург',
    'петербург': 'Санкт-Петербург',
    'мск': 'Москва',
    'екб': 'Екатеринбург',
    'ебург': 'Екатеринбург',
    'нск': 'Новосибирск',
    'новосиб': 'Новосибирск',
    'нн': 'Нижний Новгород',
    // «В Нижнем» — так зовут Нижний Новгород.
    'нижний': 'Нижний Новгород',
    'нижнем': 'Нижний Новгород',
    'нижнего': 'Нижний Новгород',
  };

  /// Несклоняемые названия, которые похожи на косвенный падеж.
  static const Set<String> _indeclinable = <String>{
    'сочи',
    'тбилиси',
    'хельсинки',
    'анапа',
    'бали',
    'майами',
  };

  /// «Москве» → «Москва», «Москв»; «Новгороде» → «Новгорода», «Новгород»;
  /// «Казани» → «Казань»; «Ярославле» → «Ярославль», «Ярославла»; иное —
  /// без изменений.
  static List<String> _nominative(String word) {
    final lower = word.toLowerCase();
    if (word.length < 3 || _indeclinable.contains(lower)) return <String>[word];
    final stem = word.substring(0, word.length - 1);
    if (lower.endsWith('ии')) return <String>['$stemя'];
    if (lower.endsWith('ле')) {
      // «Ярославле» → «Ярославль», «Туле» → «Тула».
      return <String>['$stemь', '$stemа'];
    }
    if (lower.endsWith('е')) {
      // «Петербурге», «Новгороде», «Ростове» — мужской род чаще: без «-е».
      if (lower.endsWith('ге') ||
          lower.endsWith('де') ||
          lower.endsWith('ове') ||
          lower.endsWith('еве') ||
          lower.endsWith('ке') ||
          lower.endsWith('ре') ||
          lower.endsWith('не') ||
          lower.endsWith('ске')) {
        return <String>[stem, '$stemа'];
      }
      return <String>['$stemа', stem];
    }
    if (lower.endsWith('и')) return <String>['$stemь'];
    return <String>[word];
  }

  /// «Нижнем» → «Нижний», «Великом» → «Великий», «Новом» → «Новый».
  static String _adjective(String word) {
    final lower = word.toLowerCase();
    if (word.length < 4) return word;
    final stem = word.substring(0, word.length - 2);
    if (lower.endsWith('ем')) return '$stemий';
    if (lower.endsWith('ом')) {
      final before = lower[lower.length - 3];
      return 'кгхжшчщ'.contains(before) ? '$stemий' : '$stemый';
    }
    return word;
  }

  /// «казани» → «Казани»; набранное заглавными «ЕКАТЕРИНБУРГЕ» →
  /// «Екатеринбурге» (короткие «США», «ОАЭ» — как есть).
  static String _capitalize(String word) => word
      .split('-')
      .map(
        (String part) => part.isEmpty || _linkWords.contains(part.toLowerCase())
            ? part.toLowerCase()
            : part.length > 3 && part == part.toUpperCase()
                ? part[0] + part.substring(1).toLowerCase()
                : part[0].toUpperCase() + part.substring(1),
      )
      .join('-');

  /// Для сравнения: строчные, «ё» → «е».
  static String key(String name) =>
      name.trim().toLowerCase().replaceAll('ё', 'е');

  /// Во сколько раз город должен быть крупнее, чтобы перевесить страну:
  /// «Париж» — столица Франции, а не посёлок в Челябинской области.
  static const int _dominance = 10;

  /// Город из [results] с названием точно [candidate] (без учёта регистра и
  /// «ё»). Решает население: страна [preferCountry], затем Россия выигрывают
  /// только среди сопоставимых городов — не меньше чем в [_dominance] раз
  /// мельче самого крупного. Нет точного совпадения — `null`.
  static WeatherPlace? pick(
    List<WeatherPlace> results,
    String candidate, {
    String? preferCountry,
  }) {
    final wanted = key(candidate);
    final exact = <WeatherPlace>[
      for (final place in results)
        if (key(place.name) == wanted) place,
    ];
    if (exact.isEmpty) return null;
    int people(WeatherPlace p) => p.population ?? 0;
    exact.sort(
      (WeatherPlace a, WeatherPlace b) => people(b).compareTo(people(a)),
    );
    final largest = people(exact.first);
    final comparable = <WeatherPlace>[
      for (final place in exact)
        if (people(place) * _dominance >= largest) place,
    ];
    int rank(WeatherPlace p) {
      if (preferCountry != null && p.countryCode == preferCountry) return 0;
      if (p.countryCode == 'RU') return 1;
      return 2;
    }

    comparable.sort((WeatherPlace a, WeatherPlace b) {
      final byCountry = rank(a).compareTo(rank(b));
      return byCountry != 0 ? byCountry : people(b).compareTo(people(a));
    });
    return comparable.first;
  }
}
