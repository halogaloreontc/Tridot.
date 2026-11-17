import 'keyboard_layouts.dart';

/// Словарь для поиска по кодовым точкам: подстроку пароля сравнивают со
/// словами без создания строки из пароля (3.7).
final class RuneDictionary {
  RuneDictionary(Iterable<String> words) {
    var rank = 0;
    for (final word in words) {
      rank++;
      final runes = word.runes.toList();
      if (runes.isEmpty) continue;
      final key = _hash(runes, 0, runes.length);
      final bucket = _buckets[key] ??= <(List<int>, int)>[];
      if (bucket.any(((List<int>, int) e) => _same(e.$1, runes, 0))) continue;
      bucket.add((runes, rank));
      _size++;
      _byLength[runes.length] = (_byLength[runes.length] ?? 0) + 1;
      if (runes.length > _longest) _longest = runes.length;
    }
  }

  final Map<int, List<(List<int>, int)>> _buckets =
      <int, List<(List<int>, int)>>{};
  int _size = 0;
  int _longest = 0;
  final Map<int, int> _byLength = <int, int>{};

  /// Слов длиной ровно [length] кодовых точек.
  int countOfLength(int length) => _byLength[length] ?? 0;

  /// Слов в словаре.
  int get size => _size;

  /// Самое длинное слово (кодовых точек).
  int get longest => _longest;

  bool get isEmpty => _size == 0;

  /// Ранг (1 — самое частое) слова `runes[start, end)` или `null`.
  int? rank(List<int> runes, int start, int end) {
    if (end - start > _longest || end <= start) return null;
    final bucket = _buckets[_hash(runes, start, end)];
    if (bucket == null) return null;
    for (final (word, rank) in bucket) {
      if (word.length == end - start && _same(word, runes, start)) return rank;
    }
    return null;
  }

  /// Есть ли слово целиком.
  bool contains(List<int> runes) => rank(runes, 0, runes.length) != null;

  static int _hash(List<int> runes, int start, int end) {
    var h = 17;
    for (var i = start; i < end; i++) {
      h = (h * 31 + runes[i]) & 0x3FFFFFFF;
    }
    return h;
  }

  static bool _same(List<int> word, List<int> runes, int start) {
    if (start + word.length > runes.length) return false;
    for (var i = 0; i < word.length; i++) {
      if (word[i] != runes[start + i]) return false;
    }
    return true;
  }
}

/// Словари навыка «Пароли» (решение владельца №6: генератор — только
/// английский словарь EFF large, 7776 слов).
///
/// * [eff] — EFF's Long Wordlist (CC BY 3.0 US), генератор и оценка
///   фраз из слов;
/// * [common] — 10 000 частых паролей SecLists (MIT), оценка надёжности;
/// * [russian] — короткий собственный список частых русских слов в
///   паролях: только оценка надёжности («привет» и `ghbdtn`), не
///   генератор. Частотного русского словаря паролей со свободной
///   лицензией в SecLists нет — подробнее в assets/passwords/NOTICE.txt.
///
/// Файлы встроены в приложение (`assets/passwords/`), сеть не нужна.
final class PasswordWordlists {
  PasswordWordlists._({
    required this.eff,
    required this.common,
  })  : effWords = RuneDictionary(eff),
        russian = RuneDictionary(russianWords),
        russianInLatin = RuneDictionary(<String>[
          for (final w in russianWords)
            String.fromCharCodes(
              KeyboardLayouts.cyrillicToLatin(w.runes.toList()),
            ),
        ]);

  /// Без словарей: генератор слов недоступен, оценка — по остальным
  /// моделям (раскладка, последовательности, даты, повторы).
  PasswordWordlists.empty()
      : eff = const <String>[],
        common = RuneDictionary(const <String>[]),
        effWords = RuneDictionary(const <String>[]),
        russian = RuneDictionary(russianWords),
        russianInLatin = RuneDictionary(<String>[
          for (final w in russianWords)
            String.fromCharCodes(
              KeyboardLayouts.cyrillicToLatin(w.runes.toList()),
            ),
        ]);

  /// Разбор файлов `assets/passwords/eff_large_wordlist.txt` (слово в
  /// строке) и `common_passwords.txt`. Словарь EFF проверяется: ровно
  /// 7776 разных слов из строчных латинских букв (и дефиса) — иначе
  /// `FormatException` и генератор слов не включается.
  factory PasswordWordlists.parse({
    required String eff,
    required String common,
  }) {
    final words = <String>[
      for (final line in eff.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    final valid = RegExp(r'^[a-z][a-z-]*[a-z]$');
    if (words.length != effSize ||
        words.toSet().length != effSize ||
        words.any((String w) => !valid.hasMatch(w))) {
      throw const FormatException('словарь EFF повреждён');
    }
    final frequent = <String>[
      for (final line in common.split('\n'))
        if (line.trim().isNotEmpty) line.trim().toLowerCase(),
    ];
    return PasswordWordlists._(
      eff: List<String>.unmodifiable(words),
      common: RuneDictionary(frequent),
    );
  }

  /// Размер EFF large: 6^5 бросков кубика.
  static const int effSize = 7776;

  /// Слова генератора (пусто — словарь не загрузился).
  final List<String> eff;

  final RuneDictionary effWords;

  /// Частые пароли (нижний регистр, ранг — место в списке).
  final RuneDictionary common;

  /// Русские слова кириллицей и они же в английской раскладке.
  final RuneDictionary russian;
  final RuneDictionary russianInLatin;

  /// Готов ли генератор из слов.
  bool get hasEff => eff.length == effSize;

  /// Частые русские слова в паролях (собственный список проекта, не из
  /// внешнего источника): имена, клички, «пароль», «привет», месяцы.
  /// Только для оценки: «привет» кириллицей и `ghbdtn` в английской
  /// раскладке — слабые.
  static const List<String> russianWords = <String>[
    'пароль', 'привет', 'любовь', 'солнышко', 'солнце', 'котик', 'зайка', //
    'зайчик', 'наташа', 'максим', 'саша', 'маша', 'настя', 'катя', 'лена',
    'оля', 'таня', 'аня', 'юля', 'света', 'ира', 'дима', 'сергей', 'андрей',
    'алексей', 'денис', 'никита', 'иван', 'мама', 'папа', 'москва', 'россия',
    'спартак', 'зенит', 'динамо', 'футбол', 'хоккей', 'кошка', 'собака',
    'барсик', 'мурзик', 'малыш', 'ангел', 'дракон', 'космос', 'звезда',
    'счастье', 'свобода', 'победа', 'мечта', 'жизнь', 'семья', 'работа',
    'школа', 'компьютер', 'интернет', 'админ', 'секрет', 'ключ', 'замок',
    'дача', 'лето', 'зима', 'весна', 'осень', 'январь', 'февраль', 'март',
    'апрель', 'июнь', 'июль', 'август', 'сентябрь', 'октябрь', 'ноябрь',
    'декабрь', 'радуга', 'ромашка', 'роза', 'лилия', 'цветок', 'ласточка',
    'рыбка', 'медведь', 'волк', 'тигр', 'лиса', 'шарик', 'бобик', 'тузик',
    'красота', 'любимый', 'любимая', 'милый', 'родной', 'родная',
    'бабушка', 'дедушка', 'вася', 'петя', 'коля', 'миша', 'паша', 'женя',
    'витя', 'вова', 'володя', 'ваня', 'олег', 'игорь', 'антон', 'роман',
    'артем', 'кирилл', 'егор', 'илья', 'марина', 'ольга', 'елена',
    'татьяна', 'наталья', 'ирина', 'светлана', 'юлия', 'анна', 'мария',
    'екатерина', 'анастасия', 'дарья', 'полина', 'алина', 'кристина', 'вика',
    'виктория', 'ксюша', 'ксения', 'даша', 'люба', 'надежда', 'вера',
    'галина', 'людмила', 'валентина', 'нина', 'питер', 'родина', 'добро',
    'спасибо', 'хорошо', 'отлично', 'супер', 'класс', 'король', 'королева',
    'принцесса', 'принц', 'чемпион', 'машина', 'телефон', 'яндекс', 'почта',
    'вконтакте', 'игра', 'танки', 'музыка', 'гитара', 'море', 'небо', 'луна',
    'земля', 'огонь', 'вода', 'ветер', 'снег', 'дождь', 'ночь', 'утро',
    'вечер', 'кот', 'дом', 'мир',
  ];
}
