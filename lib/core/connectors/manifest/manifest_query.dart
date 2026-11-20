import '../utterance.dart';

/// Запрос к складу словами пользователя: что искать и как спросили.
///
/// Описание склада (`assistant/1`) знает свои фразы — «сколько {q}», «где
/// лежит {q}», «остаток {q}». Люди спрашивают шире: «есть ли на складе
/// 64115», «наличие 64115», «покажи остатки по 64115, пожалуйста». Здесь —
/// клиентская часть «Tridot», как и ослабления `_relaxed` в коннекторе:
/// описание и его перенос в core.mjs не меняются.
///
/// Текст — уже в общем виде `askText`: строчные, «е» вместо «ё», без
/// кавычек и знаков по краям.
abstract final class ManifestQuery {
  /// Поле запроса без служебных слов по краям: «по 64115» → «64115»,
  /// «стул венский на складе» → «стул венский», «64115 лежит» →
  /// «64115», «64115, пожалуйста» → «64115», «64 115» (голос) →
  /// «64115». Пустая строка — искать нечего («сколько на складе»).
  static String clean(String value) {
    var q = value.trim();
    for (var pass = 0; pass < 4; pass++) {
      final before = q;
      for (final pattern in _edgeWords) {
        q = q.replaceAll(pattern, ' ').trim();
      }
      q = q.replaceAll(_spaces, ' ').replaceAll(_edgePunctuation, '').trim();
      if (q == before) break;
    }
    // Голос пишет артикул группами: «64 115», «120 734».
    final groups = _digitGroups.firstMatch(q);
    if (groups != null) {
      final joined = '${groups.group(1)}${groups.group(2)}';
      if (joined.length == 5 || joined.length == 6) q = joined;
    }
    return q;
  }

  /// «Сколько стоят пуфы», «сколько сттоит 64115», «скоолько стит 64115»
  /// → «сколько стоит …»: глагол цены в другой форме или с одной опечаткой
  /// (не в первой и не в последней букве). `null` — не вопрос о цене.
  static String? priceForm(String text) {
    final match = _priceAsk.firstMatch(text);
    if (match == null) return null;
    final verb = match.group(1)!;
    final price = _priceForms.contains(verb) ||
        (verb.length >= 4 &&
            (Utterance.isTypoOf(verb, 'стоит') ||
                Utterance.isTypoOf(verb, 'стоят')));
    if (!price) return null;
    final normalized = 'сколько стоит ${text.substring(match.end).trim()}';
    return normalized == text ? null : normalized;
  }

  /// «Склад вчера чё было по приходам», «что там по приходам сегодня» →
  /// «приходы вчера», «приходы сегодня»: кроме дня и слова о приходах —
  /// только связки. `null` — не то.
  static String? arrivalsForm(String text) {
    final words = text
        .split(RegExp(r'[\s,.!?]+'))
        .where((String w) => w.isNotEmpty)
        .toList(growable: false);
    String? day;
    var arrivals = false;
    for (var i = 0; i < words.length; i++) {
      final word = words[i];
      // «С утра», «за вчерашний день», «от вчерашнего числа», «за неделю».
      final named = _arrivalDays[word] ??
          (word == 'утра' && i > 0 && words[i - 1] == 'с' ? 'сегодня' : null);
      if (named != null) {
        if (day != null && day != named) return null;
        day = named;
      } else if (word.startsWith('приход') ||
          word == 'пришло' ||
          word.startsWith('поступ') ||
          _deliveryWords.contains(word)) {
        arrivals = true;
      } else if (!_arrivalsFiller.contains(word)) {
        return null;
      }
    }
    if (!arrivals || day == null) return null;
    final canonical = day == 'неделя' ? 'что пришло за неделю' : 'приходы $day';
    return canonical == text ? null : canonical;
  }

  /// «Остались ещё 64117», «а 64115 ещё осталось?» → «сколько осталось
  /// 64117»: вопрос об остатке артикула, а не «где лежит» по голому коду.
  static String? remainForm(String text) {
    final match = _remainCode.firstMatch(text) ?? _codeRemain.firstMatch(text);
    if (match == null) return null;
    return 'сколько осталось ${match.group(1)}';
  }

  static final RegExp _remainCode = RegExp(
    r'^(?:а\s+)?остал(?:ось|ся|ась|ись)\s+(?:еще\s+)?(\d{5,6})$',
  );

  static final RegExp _codeRemain = RegExp(
    r'^(?:а\s+)?(\d{5,6})\s+(?:еще\s+)?остал(?:ось|ся|ась|ись)$',
  );

  /// Разговорная речь словами описания: «скока» → «сколько», «чо не
  /// проведено ещё» → «что не проведено», «приходы без фоток покажь» →
  /// «приходы без фото», «покажи содержимое ячейки 303-1-1» → «что в
  /// ячейке 303-1-1», «что лежит в ячейке 215 3 2 1» (голос съел дефисы)
  /// → «… 215-3-2-1», «какая у меня роль» → «моя роль». `null` — менять
  /// нечего.
  static String? colloquial(String text) {
    var t = ' $text ';
    for (final (pattern, replacement) in _colloquialWords) {
      t = t.replaceAll(pattern, replacement);
    }
    t = t.replaceAll(_spaces, ' ').trim();
    for (final (pattern, replace) in _colloquialRewrites) {
      final match = pattern.firstMatch(t);
      if (match == null) continue;
      t = replace.replaceAllMapped(
        RegExp(r'\$(\d)'),
        (Match m) => match.group(int.parse(m.group(1)!)) ?? '',
      );
    }
    // Код ячейки без дефисов после слова «ячейка/стеллаж»: «215 3 2 1».
    t = t.replaceAllMapped(_spokenCell, (Match m) {
      final parts = m.group(3)!.trim().split(_spaces);
      return '${m.group(1)} ${m.group(2)}-${parts.join('-')}';
    });
    if (t.isEmpty || t == text) return null;
    return t;
  }

  static final List<(RegExp, String)> _colloquialWords = <(RegExp, String)>[
    (RegExp(r'(?<=\s)ско(?:ка|ко|лька)(?=\s)'), 'сколько'),
    (RegExp(r'^\s(?:чо|чё|че|шо)(?=\s)'), ' что'),
    (RegExp(r'(?<=\s)(?:фоток|фоточек|фотки|фоткам|фотографий)(?=\s)'), 'фото'),
    (RegExp(r'(?<=\s)(?:щас|еще|плиз|пж)(?=\s)'), ' '),
    (RegExp(r'\s(?:покажи|покажь)\s*$'), ' '),
  ];

  static final List<(RegExp, String)> _colloquialRewrites = <(RegExp, String)>[
    (
      RegExp(
        r'^(?:(?:покажи|глянь|посмотри|выведи)\s+)?содержимое\s+'
        r'(?:ячейки\s+|места\s+)?(.+)$',
      ),
      r'что в ячейке $1',
    ),
    (RegExp(r'^какая\s+у\s+меня\s+роль(.*)$'), r'моя роль$1'),
    // «Кем я числюсь на складе» — «кто я на складе».
    (
      RegExp(r'^кем\s+я\s+(?:числюсь|являюсь|записан|записана)(.*)$'),
      r'кто я$1',
    ),
    // «Чем склад может помочь» — «что умеет склад».
    (
      RegExp(r'^чем\s+(?:мне\s+)?склад\s+(?:может|сможет)\s+помочь$'),
      'что умеет склад',
    ),
    // «Покажи что в 101-2-3 хранится» — глагол после кода ячейки.
    (
      RegExp(
        r'^(?:покажи\s+)?что\s+(?:у\s+нас\s+)?(?:в|на)\s+(?:ячейке\s+)?'
        r'(\d{3}(?:-[0-9a-zа-я]+)+)\s+(?:хранится|хранятся|лежит|лежат|'
        r'находится|находятся|есть)$',
      ),
      r'что в ячейке $1',
    ),
    // «Остались ли приёмки, которые никто не провёл?», «есть приходы не
    // проведённые» — приходы и «не провёл/не проведены» в одной фразе.
    (
      RegExp(
        r'^(?=(?:(?:а|ну)\s+)?(?:остались|осталось|есть|какие|какая|что|'
        r'кто|где|сколько|покажи|выведи)\s)'
        r'(?=.*(?:приемк|приход|поступлени|накладн))'
        r'(?=.*(?:не\s*провед|не\s+провел|не\s+провели)).*$',
      ),
      'что не проведено',
    ),
    // «Кто из кладовщиков не сфоткал приёмку», «где не сфотографировали
    // приход» — приходы без фото.
    (
      RegExp(
        r'^(?=(?:(?:а|ну)\s+)?(?:остались|осталось|есть|какие|какая|что|'
        r'кто|где|сколько|покажи|выведи)\s)'
        r'(?=.*(?:приемк|приход|поступлени))'
        r'(?=.*не\s+(?:с|за)?(?:фоткал|фотографировал|сфотал|снял)).*$',
      ),
      'приходы без фото',
    ),
    // «Под какими правами я зашёл (в складскую систему)» — мои права.
    (
      RegExp(
        r'^(?:под\s+)?каки(?:е|ми)\s+(?:у\s+меня\s+)?прав(?:а|ами)\s+я'
        r'(?:\s.*)?$',
      ),
      'какие у меня права',
    ),
    // «Что умеет складской помощник».
    (
      RegExp(r'^что\s+умеет\s+складской\s+(?:помощник|бот|модуль)$'),
      'что умеет склад',
    ),
    // «Что висит непроведённое», «какие остались непроведённые».
    (
      RegExp(
        r'^(?:что|какие)\s+(?:у\s+нас\s+)?(?:висит|висят|осталось|'
        r'остались|есть)\s+(?:не\s*проведенн[а-я]*)(?:\s+приходы)?$',
      ),
      'что не проведено',
    ),
    // «У каких приходов нет фото» — «приходы без фото».
    (
      RegExp(
        r'^(?:у\s+каких|у\s+которых|где)\s+(?:приходов\s+)?нет\s+'
        r'(?:фото|снимков)$',
      ),
      'приходы без фото',
    ),
  ];

  static final RegExp _spokenCell = RegExp(
    r'(ячейк[аеуи]|стеллаж[еау]?)\s+(\d{3})((?:\s+\d{1,2}){1,3})$',
  );

  static const Map<String, String> _arrivalDays = <String, String>{
    'сегодня': 'сегодня',
    'сегодняшний': 'сегодня',
    'сегодняшнего': 'сегодня',
    'вчера': 'вчера',
    'вчерашний': 'вчера',
    'вчерашнего': 'вчера',
    'вчерашнее': 'вчера',
    'неделю': 'неделя',
    'неделя': 'неделя',
  };

  /// «Привезли», «завезли» — тоже приходы: «с утра много ли товара
  /// привезли?».
  static const Set<String> _deliveryWords = <String>{
    'привезли',
    'завезли',
    'привезено',
    'завезено',
    'приемки',
    'приемок',
  };

  static const Set<String> _arrivalsFiller = <String>{
    'ну',
    'а',
    'с',
    'от',
    'день',
    'числа',
    'были',
    'был',
    'выведи',
    'покажи',
    'мне',
    'много',
    'ли',
    'товара',
    'товаров',
    'какой',
    'что',
    'чё',
    'че',
    'чо',
    'было',
    'по',
    'там',
    'какие',
    'у',
    'нас',
    'на',
    'складе',
    'склад',
    'за',
    'есть',
  };

  static final RegExp _priceAsk =
      RegExp(r'^с+к+о+л+ь+к+о+\s+(с[а-я]+)\s+(?=\S)');

  static const Set<String> _priceForms = <String>{
    'стоит',
    'стоят',
    'стоил',
    'стоила',
    'стоило',
    'стоили',
    'стоить',
  };

  static final RegExp _spaces = RegExp(r'\s+');
  static final RegExp _edgePunctuation =
      RegExp(r'^[\s,.!?;:—–-]+|[\s,.!?;:—–-]+$');
  static final RegExp _digitGroups = RegExp(r'^(\d{2,3}) (\d{3})$');

  /// Служебные слова по краям поля. Чистка повторяется, пока что-то
  /// снимается («по артикулу 64115 на складе»); внутри прохода сначала —
  /// сочетания, потом одиночные предлоги.
  static final List<RegExp> _edgeWords = <RegExp>[
    RegExp(r'[,\s]+(?:пожалуйста|плиз|пж|срочно)$'),
    RegExp(r'^(?:пожалуйста|плиз|пж)[,\s]+'),
    RegExp(r'(?:^|\s)(?:на|в)\s+склад(?:е|у|а)?$'),
    RegExp(r'^(?:на|в)\s+склад(?:е|у|а)?(?:\s|$)'),
    RegExp(r'(?:^|\s)у\s+нас(?:\s+на\s+склад(?:е|у)?)?$'),
    RegExp(r'^у\s+нас(?:\s|$)'),
    RegExp(r'(?:^|\s)(?:есть\s+)?в\s+наличии$'),
    RegExp(r'^(?:есть\s+)?в\s+наличии(?:\s|$)'),
    RegExp(
      r'(?:^|\s)(?:лежит|лежат|находится|находятся|хранится|хранятся|'
      r'осталось|остался|осталась|остались|есть|имеется|всего)$',
    ),
    RegExp(
      r'^(?:лежит|лежат|находится|находятся|хранится|хранятся|осталось|'
      r'остался|осталась|остались|есть|имеется)(?:\s|$)',
    ),
    // Предлог — после «на складе» и «у нас»: иначе от «на складе 64115»
    // осталось бы «складе 64115».
    RegExp(r'^(?:по|на|у|для|про)\s+(?=\S)'),
    RegExp(r'^(?:мне\s+)?найти(?:\s|$)'),
    // «артикул 64115», «артикул BX-7712» — код с цифрой.
    RegExp(r'^(?:артикул(?:у|а)?|арт)\s+(?=[a-zа-я-]*\d)'),
    RegExp(r'^штук(?:\s|$)'),
  ];

  /// В поле — только общие слова о складе: «позиций», «всего товара»,
  /// «наименований на складе». Это вопрос обо всём складе, а не поиск
  /// товара с названием «позиций».
  static bool isWholeStock(String value) {
    final words = value
        .split(_spaces)
        .where((String w) => w.isNotEmpty)
        .toList(growable: false);
    if (words.isEmpty) return false;
    var stock = false;
    for (final word in words) {
      if (_stockStems.any(word.startsWith)) {
        stock = true;
      } else if (!_wholeWords.contains(word)) {
        return false;
      }
    }
    return stock;
  }

  static const List<String> _stockStems = <String>[
    'позици',
    'товар',
    'наименовани',
    'артикул',
    'единиц',
    'sku',
    'ассортимент',
  ];

  static const Set<String> _wholeWords = <String>{
    'всего',
    'все',
    'всех',
    'вообще',
    'разных',
    'у',
    'нас',
    'на',
    'в',
    'складе',
    'склад',
    'наличии',
  };

  /// Та же просьба словами описания: «есть ли X» → «сколько X»,
  /// «наличие X» → «остаток X», «поищи X» → «найди X». [availability] —
  /// вопрос о наличии («есть ли», «а X есть?»): он похож на обычную речь
  /// («есть ли смысл ждать»), поэтому коннектор принимает его только в
  /// разговоре о складе.
  static List<({String text, bool availability})> paraphrases(String text) {
    final out = <({String text, bool availability})>[];
    void add(String value, {bool availability = false}) {
      final clean = value.replaceAll(_spaces, ' ').trim();
      if (clean.isNotEmpty && clean != text) {
        out.add((text: clean, availability: availability));
      }
    }

    for (final (pattern, replace, availability) in _rewrites) {
      final match = pattern.firstMatch(text);
      if (match == null) continue;
      add(
        replace.replaceAllMapped(
          RegExp(r'\$(\d)'),
          (Match m) => match.group(int.parse(m.group(1)!)) ?? '',
        ),
        availability: availability,
      );
    }
    // Слова приходов: «поступления» — «приходы», «за последнюю неделю» —
    // «за неделю», «что сегодня пришло на склад» — без «на склад».
    final arrivals = text
        .replaceAll(RegExp(r'поступлени[яйе]'), 'приходы')
        // «Что поступило сегодня» — «что пришло сегодня».
        .replaceAll(RegExp(r'(?<![а-я])поступил[оаи]?(?![а-я])'), 'пришло')
        .replaceAll(
          RegExp(
            r'за\s+(?:последн(?:юю\s+неделю|ие\s+(?:7|семь)\s+дней)|'
            r'(?:7|семь)\s+дней)',
          ),
          'за неделю',
        )
        .replaceAll(RegExp(r'\s+(?:на|в)\s+склад(?:е|у)?$'), '')
        .replaceAll(RegExp(r'^какие\s+(?=приходы\s+без)'), '');
    add(arrivals);
    return out;
  }

  static final List<(RegExp, String, bool)> _rewrites =
      <(RegExp, String, bool)>[
    (RegExp(r'^есть\s+ли\s+(?:у\s+нас\s+)?(.+)$'), r'сколько $1', true),
    // «Есть табуретки?» — без «ли».
    (
      RegExp(r'^есть\s+(?!ли\s|в\s+наличии)(?:еще\s+)?(?:у\s+нас\s+)?(.+)$'),
      r'сколько $1',
      true,
    ),
    (
      RegExp(r'^(?:а\s+)?(.+?)\s+(?:есть|имеется|имеются)$'),
      r'сколько $1',
      true
    ),
    (
      RegExp(r'^(?:есть\s+в\s+)?наличи[еяи]\s+(?:по\s+|у\s+)?(.+)$'),
      r'остаток $1',
      false,
    ),
    (RegExp(r'^(?:по)?ищи(?:-ка)?\s+(.+)$'), r'найди $1', false),
    (
      RegExp(r'^где\s+(?:мне\s+|можно\s+|бы\s+)*найти\s+(.+)$'),
      r'где $1',
      false,
    ),
    (
      RegExp(
        r'^в\s+какой\s+ячейке\s+(?:лежит\s+|лежат\s+|находится\s+|'
        r'хранится\s+)?(.+)$',
      ),
      r'где лежит $1',
      false,
    ),
    // «На каком стеллаже искать 64117», «в какой ячейке смотреть …».
    (
      RegExp(
        r'^(?:на\s+каком\s+стеллаже|на\s+какой\s+полке|в\s+какой\s+ячейке)'
        r'\s+(?:мне\s+)?(?:искать|смотреть|найти|лежит|лежат)\s+(.+)$',
      ),
      r'где лежит $1',
      false,
    ),
    // «Барных табуретов на остатках хватает ли?» — остаток назван прямо.
    (
      RegExp(
        r'^(.+?)\s+(?:на|в)\s+остатках\s+(?:хватает|хватит|есть)(?:\s+ли)?$',
      ),
      r'сколько $1',
      false,
    ),
    (RegExp(r'^(?:покажи\s+)?ячейку\s+(.+)$'), r'ячейка $1', false),
    (RegExp(r'^по\s+ч[её]м\s+(.+)$'), r'почем $1', false),
    (
      RegExp(r'^какой\s+(?:сейчас\s+)?остаток\s+(?:по\s+|у\s+)?(.+)$'),
      r'остаток $1',
      false,
    ),
    // «Пуфиков много ещё осталось?» — только в разговоре о складе:
    // «денег много осталось?» — не товар.
    (
      RegExp(
        r'^(.+?)\s+много\s+(?:еще\s+)?остал(?:ось|ся|ась|ись)$',
      ),
      r'сколько осталось $1',
      true,
    ),
    // «Остались ещё пуфы?» — с названием только в разговоре о складе:
    // «остались ещё вопросы» — не товар. С артикулом — [remainForm].
    (
      RegExp(r'^(?:а\s+)?остал(?:ось|ся|ась|ись)\s+(?:еще\s+)?(\D.*)$'),
      r'сколько осталось $1',
      true,
    ),
    (
      // «Пуфиков штук сколько числится в остатках».
      RegExp(
        r'^(.+?)\s+(?:штук\s+)?сколько\s+(?:осталось|есть|штук|числится)'
        r'(?:\s+(?:в|на)\s+(?:остатках|складе))?$',
      ),
      r'сколько осталось $1',
      false,
    ),
  ];
}
