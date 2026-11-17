/// Названия сервисов во фразах навыка «Пароли» (раздел 6): синонимы,
/// падежи и нестрогое сравнение с названиями записей.
library;

/// Группа синонимов: первое слово — как называть сервис в ответах.
const List<List<String>> _groups = <List<String>>[
  <String>[
    'почта',
    'почты',
    'почте',
    'почту',
    'почтой',
    'электронная почта',
    'электронной почты',
    'электронную почту',
    'mail',
    'email',
    'e-mail',
    'имейл',
    'имейла',
    'емейл',
    'мейл',
    'мейла',
    'gmail',
    'джимейл',
    'джимейла',
    'яндекс почта',
    'яндекс почты',
    'яндекс.почта',
    'яндекс.почты',
    'mail.ru',
  ],
  <String>[
    'ВКонтакте',
    'вконтакте',
    'вк',
    'vk',
    'vk.com',
    'контакт',
    'контакта',
  ],
  <String>[
    'Госуслуги',
    'госуслуги',
    'госуслуг',
    'госуслугам',
    'госуслугах',
    'гу',
    'gosuslugi',
    'gosuslugi.ru',
  ],
  <String>[
    'Сбер',
    'сбер',
    'сбера',
    'сбербанк',
    'сбербанка',
    'сбербанк онлайн',
    'сбером',
    'sber',
    'sberbank',
  ],
  <String>[
    'Т-Банк',
    'т-банк',
    'т-банка',
    'тбанк',
    'тинькофф',
    'тинькоффа',
    'тиньков',
    'тинька',
    'tinkoff',
    'tbank',
  ],
  <String>['Озон', 'озон', 'озона', 'озоне', 'озоном', 'ozon', 'ozon.ru'],
  <String>[
    'Wildberries',
    'wildberries',
    'вайлдберриз',
    'валдберис',
    'вб',
    'wb',
    'wildberries.ru',
  ],
  <String>[
    'Wi-Fi',
    'wi-fi',
    'wifi',
    'wi fi',
    'вайфай',
    'вайфая',
    'вай-фай',
    'вай-фая',
    'вафля',
    'роутер',
    'роутера',
  ],
  <String>['Яндекс', 'яндекс', 'яндекса', 'yandex', 'yandex.ru'],
  <String>['Google', 'google', 'гугл', 'гугла', 'google.com'],
  <String>['Apple ID', 'apple id', 'эпл айди', 'apple', 'icloud', 'айклауд'],
  <String>[
    'Telegram',
    'telegram',
    'телеграм',
    'телеграма',
    'телеграмм',
    'телега',
    'телеги',
  ],
  <String>['WhatsApp', 'whatsapp', 'ватсап', 'ватсапа', 'вотсап'],
  <String>['Steam', 'steam', 'стим', 'стима'],
];

abstract final class ServiceAliases {
  /// Название для ответа: синоним из таблицы — каноническое имя
  /// («почты» → «почта», «тинькоффа» → «Т-Банк»), иначе как написано.
  static String display(String raw) {
    final key = _key(raw);
    for (final group in _groups) {
      if (group.skip(1).contains(key) || group.first == raw.trim()) {
        return group.first;
      }
    }
    return raw.trim();
  }

  /// [raw] — сервис из таблицы синонимов в любом записанном падеже:
  /// «сбером», «почтой», «роутера».
  static bool isKnown(String raw) {
    final key = _key(raw);
    return _groups.any(
      (List<String> group) =>
          group.any((String name) => name.toLowerCase() == key),
    );
  }

  /// Все написания, по которым искать запись для [raw]: сам запрос и его
  /// синонимы из таблицы (в нижнем регистре).
  static Set<String> needles(String raw) {
    final key = _key(raw);
    final out = <String>{if (key.isNotEmpty) key};
    for (final group in _groups) {
      if (group.contains(key) || group.first.toLowerCase() == key) {
        out.addAll(group.map((String s) => s.toLowerCase()));
      }
    }
    return out;
  }

  /// Подходит ли запись с названиями [names] под запрос [raw]: совпадение
  /// синонима, вхождение (от 3 букв) или расстояние Левенштейна ≤ 2 (≤ 1
  /// для коротких).
  static bool matches(String raw, Iterable<String> names) {
    final wanted = needles(raw);
    if (wanted.isEmpty) return false;
    for (final name in names) {
      final have = _key(name);
      if (have.isEmpty) continue;
      final haveNeedles = needles(name);
      if (haveNeedles.any(wanted.contains)) return true;
      for (final needle in wanted) {
        if (needle.length >= 3 &&
            (have.contains(needle) ||
                (have.length >= 3 && needle.contains(have)))) {
          return true;
        }
        final limit = needle.length >= 6 ? 2 : (needle.length >= 4 ? 1 : 0);
        if (limit > 0 && (have.length - needle.length).abs() <= limit) {
          if (distance(have, needle) <= limit) return true;
        }
      }
    }
    return false;
  }

  /// Расстояние Левенштейна.
  static int distance(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    var previous = List<int>.generate(b.length + 1, (int i) => i);
    for (var i = 1; i <= a.length; i++) {
      final current = List<int>.filled(b.length + 1, 0)..[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        final deletion = previous[j] + 1;
        final insertion = current[j - 1] + 1;
        final substitution = previous[j - 1] + cost;
        var best = deletion < insertion ? deletion : insertion;
        if (substitution < best) best = substitution;
        current[j] = best;
      }
      previous = current;
    }
    return previous[b.length];
  }

  static String _key(String raw) => raw
      .trim()
      .toLowerCase()
      .replaceAll('ё', 'е')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^(?:www\.)'), '');
}
