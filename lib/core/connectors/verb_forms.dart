/// Распознавание глагольных форм по окончанию: инфинитив («купить»,
/// «отнести», «испечь») и прошедшее время («купил», «сдала»).
///
/// Без словаря: правила по окончаниям и списки исключений. Слова —
/// нормализованные: нижний регистр, «е» вместо «ё».
abstract final class VerbForms {
  /// Слова на «-ть», «-ти», «-чь», которые не глаголы, хотя правила
  /// окончаний их пропускают: «в 2 сеть» — не время, «тетрадь купить» —
  /// не задача без маркера.
  static const Set<String> _notInfinitives = <String>{
    'сеть',
    'мать',
    'нить',
    'треть',
    'клеть',
    'плеть',
    'прыть',
    'кровать',
    'печать',
    'память',
    'опять',
    'зять',
    'рать',
    'гать',
    'благодать',
    'пять',
    'девять',
    'десять',
    'части',
    'запчасти',
    'власти',
    'снасти',
    'страсти',
    'сласти',
    'напасти',
    'дочь',
    'ночь',
    'полночь',
    'прочь',
    'мелочь',
    'сволочь',
    'речь',
    'печь',
    'горечь',
    'течь',
    'желчь',
    'дичь',
    'навзничь',
    'опричь',
  };

  /// Инфинитивы на «-уть»: «-нуть» («вернуть»), «дуть», «обуть», «разуть».
  /// Остальные слова на «-уть» — существительные: «путь», «суть», «жуть».
  static const List<String> _utEndings = <String>[
    'нуть',
    'дуть',
    'буть',
    'зуть',
  ];

  static const String _vowels = 'аеиоуыэюя';

  /// Похоже на инфинитив: «позвонить», «купить», «зайти», «отнести»,
  /// «испечь», «постричься». «Кстати», «ногти», «жуть», «мякоть»,
  /// «новость» — нет.
  static bool isInfinitive(String word) {
    var base = word;
    if (base.endsWith('ся') || base.endsWith('сь')) {
      base = base.substring(0, base.length - 2);
    }
    if (base.length < 3 || _notInfinitives.contains(base)) return false;
    if (word.length < 4) return false;
    if (base.endsWith('ть')) return _isTInfinitive(base);
    if (base.endsWith('ти')) return _isTiInfinitive(base);
    if (base.endsWith('чь')) {
      // «печь», «мочь», «стричь»; «вскачь», «плачь» — нет.
      return 'еои'.contains(base[base.length - 3]);
    }
    return false;
  }

  /// «-ть»: перед ним гласная («купить») или «з» («лезть»). «-сть» —
  /// почти всегда существительное («часть», «новость»), «-дцать» — число.
  static bool _isTInfinitive(String word) {
    if (word.length < 3 || word.endsWith('дцать')) return false;
    final before = word[word.length - 3];
    if (before == 'з') return word.length >= 5;
    if (!_vowels.contains(before)) return false;
    if (before == 'у') {
      return _utEndings.any(word.endsWith);
    }
    if (before == 'о') {
      // «колоть», «полоть», «пороть»; «локоть», «копоть», «плоть» — нет.
      if (word.length < 5) return false;
      final consonant = word[word.length - 4];
      return (consonant == 'л' || consonant == 'р') &&
          _vowels.contains(word[word.length - 5]);
    }
    return true;
  }

  /// «-ти»: «идти», «зайти», «везти», «нести», «расти». Перед «-ти» —
  /// «д», «й», «з» или «с» после гласной кроме «и», «о», «у»: «кстати»,
  /// «ногти», «дети», «кисти», «гости», «грусти» — не инфинитивы.
  static bool _isTiInfinitive(String word) {
    if (word.length < 4) return false;
    final before = word[word.length - 3];
    if (before == 'д' || before == 'й' || before == 'з') return true;
    if (before != 'с') return false;
    return 'аеяю'.contains(word[word.length - 4]);
  }

  /// Слова на «-л», «-ла», «-ли», «-ло», которые не глаголы.
  static const Set<String> _notPastVerbs = <String>{
    'стол',
    'пол',
    'футбол',
    'угол',
    'посол',
    'котел',
    'козел',
    'орел',
    'щегол',
    'купол',
    'пепел',
    'дятел',
    'мол',
    'дела',
    'дело',
    'тела',
    'тело',
    'села',
    'село',
    'стола',
    'пола',
    'футбола',
    'крыло',
    'пила',
    'сила',
    'жила',
    'вилла',
    'школа',
    'стрела',
    'могила',
    'весело',
    'смело',
    'тяжело',
    'мало',
    'около',
    'мило',
    'было',
    'были',
    'была',
    'был',
    'цели',
    'модели',
    'отели',
    'недели',
    'качели',
    'мебели',
    'автомобили',
    'роли',
    'боли',
    'соли',
    'короли',
    'нули',
    'рубли',
    'корабли',
    'фили',
    'дали',
  };

  /// Похоже на глагол прошедшего времени: «купил», «сдала», «позвонили».
  static bool isPastVerb(String word) {
    if (word.length < 4 || _notPastVerbs.contains(word)) return false;
    final stem = switch (word) {
      _ when word.endsWith('л') => word.substring(0, word.length - 1),
      _
          when word.endsWith('ла') ||
              word.endsWith('ли') ||
              word.endsWith('ло') =>
        word.substring(0, word.length - 2),
      _ => null,
    };
    if (stem == null || stem.length < 3) return false;
    // Перед суффиксом «-л» в прошедшем времени гласная: «купи-л»,
    // «сда-л». «Числа», «масло», «земли» — не глаголы.
    return _vowels.contains(stem[stem.length - 1]);
  }

  /// Прошедшее время, которое правилом «-л → -ть» не получить: «пошёл» —
  /// «пойти», «принёс» — «принести», «смог» — «смочь».
  static const Map<String, String> _irregularPast = <String, String>{
    'пошел': 'пойти',
    'пошла': 'пойти',
    'пошли': 'пойти',
    'зашел': 'зайти',
    'зашла': 'зайти',
    'зашли': 'зайти',
    'нашел': 'найти',
    'нашла': 'найти',
    'нашли': 'найти',
    'вышел': 'выйти',
    'вышла': 'выйти',
    'вышли': 'выйти',
    'пришел': 'прийти',
    'пришла': 'прийти',
    'пришли': 'прийти',
    'дошел': 'дойти',
    'дошла': 'дойти',
    'дошли': 'дойти',
    'принес': 'принести',
    'принесла': 'принести',
    'принесли': 'принести',
    'отнес': 'отнести',
    'отнесла': 'отнести',
    'отнесли': 'отнести',
    'занес': 'занести',
    'занесла': 'занести',
    'занесли': 'занести',
    'привез': 'привезти',
    'привезла': 'привезти',
    'привезли': 'привезти',
    'отвез': 'отвезти',
    'отвезла': 'отвезти',
    'отвезли': 'отвезти',
    'смог': 'смочь',
    'смогла': 'смочь',
    'смогли': 'смочь',
    'помог': 'помочь',
    'помогла': 'помочь',
    'помогли': 'помочь',
    'лег': 'лечь',
    'легла': 'лечь',
    'легли': 'лечь',
    'испек': 'испечь',
    'испекла': 'испечь',
    'испекли': 'испечь',
    'съел': 'съесть',
    'съела': 'съесть',
    'съели': 'съесть',
    'поел': 'поесть',
    'поела': 'поесть',
    'поели': 'поесть',
    // Короткие основы: правило «-л → -ть» их не берёт.
    'пил': 'пить',
    'пила': 'пить',
    'пили': 'пить',
    'был': 'быть',
    'была': 'быть',
    'были': 'быть',
    'мыл': 'мыть',
    'мыла': 'мыть',
    'мыли': 'мыть',
    'шил': 'шить',
    'шила': 'шить',
    'шили': 'шить',
    'бил': 'бить',
    'била': 'бить',
    'били': 'бить',
    'жил': 'жить',
    'жила': 'жить',
    'жили': 'жить',
    'сел': 'сесть',
    'села': 'сесть',
    'сели': 'сесть',
    'вел': 'вести',
    'вела': 'вести',
    'вели': 'вести',
  };

  /// Приставки «сесть» и «вести»: «пересел» → «пересесть», «перевёл» →
  /// «перевести», «провела» → «провести».
  static const List<String> _sestPrefixes = <String>[
    'при',
    'пере',
    'под',
    'рас',
    'за',
    'по',
    'вы',
  ];

  static const List<String> _vestiPrefixes = <String>[
    'пере',
    'про',
    'при',
    'от',
    'за',
    'вы',
    'раз',
    'под',
    'по',
    'у',
    'из',
    'до',
    'на',
    'с',
  ];

  static String? _prefixed(
    String word,
    List<String> prefixes,
    List<String> pasts,
    String infinitive,
  ) {
    for (final past in pasts) {
      if (!word.endsWith(past)) continue;
      final prefix = word.substring(0, word.length - past.length);
      if (prefixes.contains(prefix)) return '$prefix$infinitive';
    }
    return null;
  }

  /// Инфинитив глагола прошедшего времени: «написал» → «написать»,
  /// «позвонила» → «позвонить», «умылся» → «умыться», «пошёл» → «пойти».
  /// `null` — слово не похоже на прошедшее время. Нужен для «напомни,
  /// чтобы я написал Андрею» → «Написать Андрею».
  static String? toInfinitive(String word) {
    final irregular = _irregularPast[word];
    if (irregular != null) return irregular;
    final prefixed = _prefixed(
          word,
          _vestiPrefixes,
          const <String>['вела', 'вели', 'вел'],
          'вести',
        ) ??
        _prefixed(
          word,
          _sestPrefixes,
          const <String>['села', 'сели', 'сел'],
          'сесть',
        );
    if (prefixed != null) return prefixed;
    // «подстригся» → «подстричься», «испеклась» → «испечься».
    for (final reflexive in const <String>['гся', 'кся', 'глась', 'клась']) {
      if (!word.endsWith(reflexive)) continue;
      final stem = word.substring(0, word.length - reflexive.length);
      if (stem.length < 3) return null;
      return '$stemчься';
    }
    for (final reflexive in const <String>['лся', 'лась', 'лись', 'лось']) {
      if (!word.endsWith(reflexive)) continue;
      final stem = word.substring(0, word.length - reflexive.length);
      if (stem.length < 3 || !_vowels.contains(stem[stem.length - 1])) {
        return null;
      }
      return '$stemться';
    }
    if (!isPastVerb(word)) return null;
    final stem = word.endsWith('л')
        ? word.substring(0, word.length - 1)
        : word.substring(0, word.length - 2);
    return '$stemть';
  }

  /// Похоже на глагол во множественном числе прошедшего времени:
  /// «купили», «сдали». Без «мы» это не «я сделал»: «хлеб купили».
  static bool isPluralPastVerb(String word) =>
      isPastVerb(word) && (word.endsWith('ли') || word.endsWith('лись'));

  /// Окончания, которые отрезаются от основы глагола. Длинные — раньше
  /// коротких: «-ться» раньше «-ть».
  static const List<String> _verbEndings = <String>[
    'ться',
    'тись',
    'чься',
    'лась',
    'лись',
    'лся',
    'ть',
    'ти',
    'чь',
    'ла',
    'ли',
    'ло',
    'л',
  ];

  /// Основа глагола без окончания прошедшего времени или инфинитива:
  /// «купил», «купить» → «купи». `null` — слово не глагол: «кровать»,
  /// «новость», «часть» основы не имеют.
  static String? stem(String word) {
    final base = word.endsWith('ся') || word.endsWith('сь')
        ? word.substring(0, word.length - 2)
        : word;
    if (!isInfinitive(word) && !isPastVerb(base)) return null;
    for (final ending in _verbEndings) {
      if (word.endsWith(ending)) {
        final result = word.substring(0, word.length - ending.length);
        return result.length >= 3 ? result : null;
      }
    }
    return null;
  }
}
