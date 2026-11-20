import 'app_profile.dart';

/// Тексты слота приложения, которого нет в коде (ADR-043): название,
/// обращения, фразы справки и записи каталога ответов из профиля
/// приложения ([AppProfile]). Тот же набор ключей, что у склада, только
/// нейтральный стиль; голос и предупреждения — «Tridot», не приложения.
///
/// Значения профиля проверены при разборе (только буквы, цифры, пробел,
/// дефис и «»): синтаксиса шаблонов в них нет, и они подставляются
/// готовыми строками.
abstract final class GenericSlotTexts {
  /// Путь к подключению приложения [title].
  static String path(String title) =>
      'Мой Связной → Помощники → Подключения → $title';

  /// Название для интерфейса: «Автосервис». Заглавная — только у
  /// кириллицы: латинские марки («amoCRM») — как есть.
  static String title(AppProfile profile) => capitalize(profile.name);

  /// Первая буква кириллицы — заглавная, остальное как есть.
  static String capitalize(String text) {
    if (text.isEmpty) return text;
    final first = text[0];
    if (!RegExp('[а-яё]').hasMatch(first)) return text;
    return '${first.toUpperCase()}${text.substring(1)}';
  }

  /// Обращения: «в автосервисе», «автосервис» и слова `addressing`.
  static List<String> aliases(AppProfile profile) => _unique(<String>[
        if (profile.inPhrase case final String phrase) phrase,
        profile.name,
        ...profile.addressing,
      ]);

  /// Фразы справки: «что умеет автосервис», «помощь по автосервису».
  static List<String> helpPhrases(AppProfile profile) {
    final c = profile.cases;
    return _unique(<String>[
      'что умеет ${c.nom}',
      'что может ${c.nom}',
      'что знает ${c.nom}',
      'помощь по ${c.dat}',
      'справка по ${c.dat}',
      'команды ${c.gen}',
      'что спросить у ${c.gen}',
      for (final word in profile.addressing) 'что умеет $word',
    ]);
  }

  /// Одно предложение для списка подключений.
  static String description(AppProfile profile) =>
      '${title(profile)}: только чтение — команды и ответы из описания '
      'приложения.';

  /// Подпись поля для вопроса «что искать», если в описании её нет.
  static const String queryLabel = 'название или номер';

  /// Ключи записей каталога слота — те же, что у склада (без `<id>.`).
  static const List<String> replyKeys = <String>[
    'answer',
    'more',
    'empty',
    'fallbackEmpty',
    'reply',
    'price',
    'help',
    'ask',
    'total',
    'serverSaid',
    'notConnected',
    'auth.token',
    'auth.expired',
    'auth.staff',
    'auth.role',
    'offline',
    'timeout',
    'serverError',
    'busy',
  ];

  /// Защищённые записи (предупреждения): паки ответов их не меняют.
  static const List<String> protectedKeys = <String>[
    'serverSaid',
    'notConnected',
    'auth.token',
    'auth.expired',
    'auth.staff',
    'auth.role',
    'offline',
    'timeout',
    'serverError',
    'busy',
  ];

  /// Записи каталога слота [id]: `<id>.answer` → текст.
  static Map<String, String> replies(AppProfile profile, String id) {
    final texts = _texts(profile);
    return <String, String>{
      for (final key in replyKeys) '$id.$key': texts[key]!,
    };
  }

  static Set<String> protectedReplies(String id) => <String>{
        for (final key in protectedKeys) '$id.$key',
      };

  static Map<String, String> _texts(AppProfile profile) {
    final c = profile.cases;
    final path = GenericSlotTexts.path(title(profile));
    final gender = profile.declinable ? profile.gender : null;
    final head = capitalize(c.nom);
    final common = <String, String>{
      'answer': '{text}',
      'more': 'Показаны не все — {вы:уточните|ты:уточни} запрос.',
      'empty': '{text}',
      'fallbackEmpty': '{text} {вы:Спросите|ты:Спроси}, например: '
          '{examples}.',
      'reply': '{text}',
      'price': 'Цены я пока не называю — {вы:посмотрите|ты:посмотри} цену '
          'в самом приложении.',
      'ask': '{вы:Уточните|ты:Уточни}, что искать: {label}. Например: '
          '«{example}».',
      'auth.expired': 'Личный ключ для ${c.gen} устарел — '
          '{вы:подключитесь|ты:подключись} заново: $path.',
      'auth.staff': 'Это видно только под своим логином. '
          '{вы:Подключитесь|ты:Подключись} под своей учётной записью: '
          '$path.',
      'auth.role': 'Учётная запись ждёт роли — {вы:попросите|ты:попроси} '
          'администратора ${c.gen} её назначить.',
      'offline': 'Нет связи ${withS(c.ins)}. {вы:Проверьте|ты:Проверь} '
          'интернет и {вы:спросите|ты:спроси} ещё раз.',
    };
    if (gender == null) {
      // Несклоняемое имя («CRM») или род неизвестен: без согласования.
      return <String, String>{
        ...common,
        'help': 'Команды ${c.gen}: {list}.',
        'total': 'Общий счёт записей ${c.gen} пока не ведётся — '
            '{вы:назовите|ты:назови} конкретную: имя, номер или название.',
        'serverSaid': 'Ответ ${c.gen}: {error}',
        'notConnected': 'Нет подключения ${withK(c.dat)}. '
            '{вы:Подключитесь|ты:Подключись}: $path.',
        'auth.token': 'Пароль для ${c.gen} не принят — '
            '{вы:подключитесь|ты:подключись} заново: $path.',
        'timeout': 'Ответ от ${c.gen} не пришёл вовремя. '
            '{вы:Попробуйте|ты:Попробуй} ещё раз чуть позже.',
        'serverError': 'Ошибка на стороне ${c.gen}. '
            '{вы:Попробуйте|ты:Попробуй} позже.',
        'busy': 'Слишком много запросов ${withK(c.dat)} — '
            '{вы:попробуйте|ты:попробуй} через минуту.',
      };
    }
    String past(String stem) => pastTense(stem, gender);
    final plural = gender == AppGender.pl;
    final pronoun = switch (gender) {
      AppGender.m => 'он',
      AppGender.f => 'она',
      AppGender.n => 'оно',
      AppGender.pl => 'они',
    };
    final object = switch (gender) {
      AppGender.m || AppGender.n => 'его',
      AppGender.f => 'её',
      AppGender.pl => 'их',
    };
    final connected = switch (gender) {
      AppGender.m => 'подключён',
      AppGender.f => 'подключена',
      AppGender.n => 'подключено',
      AppGender.pl => 'подключены',
    };
    return <String, String>{
      ...common,
      'help': '$head ${plural ? 'понимают' : 'понимает'}: {list}.',
      'total': 'Сколько всего записей, ${c.nom} пока не '
          '${plural ? 'считают' : 'считает'} — $pronoun '
          '${plural ? 'отвечают' : 'отвечает'} про конкретную. '
          '{вы:Назовите|ты:Назови} её: имя, номер или название.',
      'serverSaid': '$head ${past('ответил')}: {error}',
      'notConnected': '$head не $connected. {вы:Подключите|ты:Подключи} '
          '$object: $path.',
      'auth.token': '$head не ${past('принял')} пароль — '
          '{вы:подключитесь|ты:подключись} заново: $path.',
      'timeout': '$head не ${past('ответил')} вовремя. '
          '{вы:Попробуйте|ты:Попробуй} ещё раз чуть позже.',
      'serverError': '$head ${plural ? 'отвечают' : 'отвечает'} с ошибкой. '
          '{вы:Попробуйте|ты:Попробуй} позже.',
      'busy': '$head ${plural ? 'просят' : 'просит'} подождать: слишком '
          'много запросов. {вы:Попробуйте|ты:Попробуй} через минуту.',
    };
  }

  /// Прошедшее время по роду: «ответил» → «ответила», «ответило»,
  /// «ответили».
  static String pastTense(String masculine, AppGender gender) =>
      switch (gender) {
        AppGender.m => masculine,
        AppGender.f => '$masculineа',
        AppGender.n => '$masculineо',
        AppGender.pl => '$masculineи',
      };

  /// «с автосервисом», «со складом», «с CRM».
  static String withS(String ins) => '${_heavy(ins, s: true) ? 'со' : 'с'} '
      '$ins';

  /// «к автосервису», «ко всем», «к CRM».
  static String withK(String dat) => '${_heavy(dat, s: false) ? 'ко' : 'к'} '
      '$dat';

  static final RegExp _consonant = RegExp('[бвгджзйклмнпрстфхцчшщ]');

  /// Перед словом нужен беглый гласный: «со складом», «ко мне».
  static bool _heavy(String word, {required bool s}) {
    final w = word.toLowerCase().replaceFirst(RegExp('^[«»]+'), '');
    if (w.length < 2) return false;
    if (w.startsWith('вс') || w.startsWith('вт') || w.startsWith('мн')) {
      return true;
    }
    return s && 'сзжшщ'.contains(w[0]) && _consonant.hasMatch(w[1]);
  }

  static List<String> _unique(List<String> values) {
    final seen = <String>{};
    return <String>[
      for (final value in values)
        if (seen.add(value.toLowerCase().replaceAll('ё', 'е'))) value,
    ];
  }
}
