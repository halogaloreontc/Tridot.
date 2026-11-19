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
    for (final word in words) {
      if (word == 'сегодня' || word == 'вчера') {
        if (day != null && day != word) return null;
        day = word;
      } else if (word.startsWith('приход') ||
          word == 'пришло' ||
          word.startsWith('поступ')) {
        arrivals = true;
      } else if (!_arrivalsFiller.contains(word)) {
        return null;
      }
    }
    if (!arrivals || day == null) return null;
    final canonical = 'приходы $day';
    return canonical == text ? null : canonical;
  }

  static const Set<String> _arrivalsFiller = <String>{
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
    RegExp(r'^(?:артикул(?:у|а)?|арт)\s+(?=\d)'),
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
            r'за\s+последн(?:юю\s+неделю|ие\s+(?:7|семь)\s+дней)',
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
    (RegExp(r'^(?:покажи\s+)?ячейку\s+(.+)$'), r'ячейка $1', false),
    (RegExp(r'^по\s+ч[её]м\s+(.+)$'), r'почем $1', false),
    (
      RegExp(r'^какой\s+(?:сейчас\s+)?остаток\s+(?:по\s+|у\s+)?(.+)$'),
      r'остаток $1',
      false,
    ),
    (
      RegExp(r'^(.+?)\s+сколько\s+(?:осталось|есть|штук)$'),
      r'сколько осталось $1',
      false,
    ),
  ];
}
