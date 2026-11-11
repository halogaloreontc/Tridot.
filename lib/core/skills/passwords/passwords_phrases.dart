import '../../connectors/utterance.dart';
import 'service_aliases.dart';

/// Команды навыка «Пароли» (раздел 6). Это же `intent` корпуса
/// `test/corpus/passwords.jsonl`.
abstract final class PasswordCommands {
  static const String hint = 'passwords.hint';
  static const String reveal = 'passwords.reveal';
  static const String copy = 'passwords.copy';
  static const String generate = 'passwords.generate';
  static const String check = 'passwords.check';
  static const String add = 'passwords.add';
  static const String change = 'passwords.change';
  static const String delete = 'passwords.delete';
  static const String list = 'passwords.list';
  static const String train = 'passwords.train';
  static const String open = 'passwords.open';
  static const String lock = 'passwords.lock';
  static const String backup = 'passwords.backup';
  static const String import = 'passwords.import';
  static const String restore = 'passwords.restore';
  static const String masterForgot = 'passwords.masterForgot';
  static const String login = 'passwords.login';
  static const String lostDevice = 'passwords.lostDevice';
  static const String recoverHelp = 'passwords.recoverHelp';
  static const String help = 'passwords.help';

  static const List<String> all = <String>[
    hint,
    reveal,
    copy,
    generate,
    check,
    add,
    change,
    delete,
    list,
    train,
    open,
    lock,
    backup,
    import,
    restore,
    masterForgot,
    login,
    lostDevice,
    recoverHelp,
    help,
  ];
}

/// Разобранная фраза: команда, сервис и уверенность. В ней нет и не
/// бывает пароля: значение из чата навык не берёт никогда.
final class PasswordCommand {
  const PasswordCommand({
    required this.cmd,
    required this.confidence,
    this.query,
    this.implicit = false,
    this.options = const <String, Object?>{},
  });

  final String cmd;

  /// Сервис из фразы для ответа («почта», «Т-Банк») или `null`.
  final String? query;

  final double confidence;

  /// Совпадение без уверенности: уступает любому явному (маркеры задачи,
  /// одно слово «пароль»).
  final bool implicit;

  /// Параметры без секретов: у генератора — режим, длина, число слов,
  /// классы символов (`GeneratorOptions.toJson`).
  final Map<String, Object?> options;

  @override
  String toString() => 'PasswordCommand($cmd)';
}

/// Чистый разбор фраз о паролях: без ввода-вывода и без хранилища.
///
/// Его же спрашивает маршрутизатор: распознанную фразу не получает ни
/// один сетевой коннектор, а при выключенном навыке она получает ответ
/// `passwords.off`, а не становится задачей.
abstract final class PasswordPhrases {
  /// Уверенность, начиная с которой фраза — команда навыка
  /// (`passwords.off` при выключенном навыке).
  static const double firm = 0.55;

  /// С маркерами задачи («в задачи», «напомни», срок, `#метка`) фраза
  /// уходит задачам.
  static const double yielded = 0.3;

  static const String _pw =
      r'(?:пароль|пароля|паролю|пароли|паролей|пасс|password)';
  static const String _prep = r'(?:от|для|к|на|у)';
  static const String _forgot =
      r'(?:забыл|забыла|забыли|позабыл|позабыла|не помню|не могу вспомнить|не вспомню)';
  static const String _my = r'(?:(?:мой|свой|мою|свою|мне|у меня)\s+)?';

  /// Один пароль (не «пароли» — это список).
  static const String _onePw = r'(?:пароль|пароля|пасс|password)';

  /// «Напомни (мне)» перед паролем или логином — просьба подсказать, а не
  /// задача-напоминание.
  static const String _remind = r'(?:напомни|подскажи)(?:\s+мне)?';

  /// «Логин и пароль», «пароль и логин»: человек забыл оба.
  static const String _loginAndPw =
      '(?:(?:логин|имя пользователя)\\s+и\\s+$_pw|$_pw\\s+и\\s+логин)';

  /// Голые устройства (без слова о паролях) — только целой фразой:
  /// «купить чехол, потерял телефон» — задача, а не навык.
  static const String _device =
      r'(?:телефон|смартфон|ноутбук|ноут|планшет|компьютер)';

  /// «(новый, надёжный …) пароль» после глагола генератора.
  static const String _newPw =
      '(?:новый\\s+|надежный\\s+|сложный\\s+|случайный\\s+|хороший\\s+|'
      'длинный\\s+|запоминающийся\\s+|простой\\s+|стойкий\\s+)*$_pw';

  static final List<(RegExp, String, double)> _rules =
      <(RegExp, String, double)>[
    // «забыл мастер-пароль», «не помню пароль от хранилища».
    (
      RegExp('$_forgot\\s+$_my(?:мастер[- ]?пароль|главный пароль)'),
      PasswordCommands.masterForgot,
      0.92,
    ),
    (
      RegExp('$_forgot\\s+$_my$_pw\\s+(?:от|к|для)\\s+'
          r'(?:хранилища|паролей|сейфа|менеджера паролей)'),
      PasswordCommands.masterForgot,
      0.92,
    ),
    (
      RegExp(r'не (?:могу|получается) (?:открыть|войти в) '
          r'(?:пароли|хранилище|сейф)'),
      PasswordCommands.masterForgot,
      0.92,
    ),
    // «потерял телефон», «переезжаю на новый ноутбук».
    (
      RegExp('^(?:я\\s+)?(?:потерял|потеряла|потеряли|украли|разбил|разбила|'
          'утопил|утопила)\\s+(?:мой\\s+|свой\\s+)?$_device'
          '(?:,?\\s+что (?:теперь\\s+)?делать)?\$'),
      PasswordCommands.lostDevice,
      0.85,
    ),
    (
      RegExp('^(?=.*(?:парол|хранилищ))(?:.*\\s)?(?:потерял|потеряла|потеряли|'
          'украли|разбил|разбила|утопил|утопила)\\s+(?:мой\\s+|свой\\s+)?'
          '$_device'),
      PasswordCommands.lostDevice,
      0.85,
    ),
    (
      RegExp('^(?:я\\s+)?(?:переезжаю|перехожу|переехал|переехала)\\s+на\\s+'
          'нов\\S*\\s+(?:$_device|устройство)(?=\$|.*(?:парол|хранилищ))'),
      PasswordCommands.lostDevice,
      0.85,
    ),
    (
      RegExp('как\\s+(?:перенести|переносить|забрать)\\s+$_pw'),
      PasswordCommands.lostDevice,
      0.85,
    ),
    // Справка — раньше остального: «как поменять пароль» — вопрос, не
    // команда.
    (
      RegExp(r'что\s+(?:ты\s+)?(?:умеешь|можешь)\s+(?:делать\s+)?с\s+паролями'),
      PasswordCommands.help,
      0.8,
    ),
    (
      RegExp('как\\s+(?:придумать|создать|сделать|выбрать|подобрать|'
          'поменять|сменить|менять|хранить)\\s+'
          '(?:хороший\\s+|надежный\\s+|сложный\\s+|безопасный\\s+)?$_pw'),
      PasswordCommands.help,
      0.8,
    ),
    (
      RegExp('(?:помощь|справка)\\s+(?:по|про)\\s+(?:паролям|пароли)'),
      PasswordCommands.help,
      0.8,
    ),
    (
      RegExp('как\\s+восстановить\\s+(?:доступ\\s+(?:\\S+\\s+){0,4})?$_pw'),
      PasswordCommands.recoverHelp,
      0.8,
    ),
    // Запереть и открыть хранилище.
    (
      RegExp(r'^(?:запри|закрой|заблокируй|запереть|закрыть|заблокировать)\s+'
          r'(?:мои\s+)?(?:пароли|хранилище(?:\s+паролей)?|сейф)$'),
      PasswordCommands.lock,
      0.92,
    ),
    (
      RegExp(r'^(?:открой|открыть|разблокируй)\s+(?:мои\s+)?'
          r'(?:пароли|хранилище(?:\s+паролей)?|сейф|менеджер паролей)$'),
      PasswordCommands.open,
      0.92,
    ),
    // Генератор (5.4): параметры — в [PasswordCommand.options].
    (
      RegExp('(?:сгенерируй|придумай|создай|сгенерировать|придумать)\\s+'
          '(?:мне\\s+)?$_newPw'),
      PasswordCommands.generate,
      0.92,
    ),
    // «Нужен пароль» — новый, только если дальше не «от/для/к/у …»: «мне
    // нужен пароль от почты» — это забытый пароль (подсказка), а не
    // генератор. «Нужен пароль на 20 символов» — генератор.
    (
      RegExp('нужен\\s+(?:мне\\s+)?$_newPw'
          '(?!\\s+(?:от|для|к|у)\\s|\\s+на\\s+(?!\\d))'),
      PasswordCommands.generate,
      0.92,
    ),
    (
      RegExp('^$_pw\\s+(?:из\\s+(?:\\d+\\s+)?слов|на\\s+\\d+\\s+символ)'),
      PasswordCommands.generate,
      0.92,
    ),
    // Проверка.
    (
      RegExp(
        r'(?:проверь|проверить)\s+(?:мои\s+|все\s+)?(?:пароли|надежность паролей)$',
      ),
      PasswordCommands.check,
      0.9,
    ),
    (
      RegExp(r'(?:есть ли|где|какие)\s+(?:у меня\s+)?'
          r'(?:слабые|одинаковые|повторяющиеся|старые|простые)\s+пароли'),
      PasswordCommands.check,
      0.9,
    ),
    // Тренировка.
    (
      RegExp('(?:проверь|проверить),?\\s+помню ли я\\s+$_pw'
          '(?:\\s+$_prep\\s+(.+))?\$'),
      PasswordCommands.train,
      0.9,
    ),
    (
      RegExp(r'^потренируй (?:меня|мою память)'
          r'(?:\s+(?:в|на|по)\s+(?:паролях|паролям|пароли))?$'),
      PasswordCommands.train,
      0.9,
    ),
    // Копия, восстановление и импорт (5.6, 5.7).
    (
      RegExp(r'(?:восстанови|восстановить|верни|вернуть|загрузи|загрузить|'
          r'достань|достать)\s+(?:мои\s+|все\s+)?(?:пароли|хранилище'
          r'(?:\s+паролей)?)\s+из\s+(?:резервной\s+)?(?:копии|бэкапа)'),
      PasswordCommands.restore,
      0.85,
    ),
    (
      RegExp(r'^восстановление\s+(?:паролей|хранилища(?:\s+паролей)?)\s+'
          r'из\s+(?:резервной\s+)?(?:копии|бэкапа)'),
      PasswordCommands.restore,
      0.85,
    ),
    (
      RegExp(r'(?:сделай|создай|сохрани)\s+(?:резервную\s+)?копию\s+'
          r'(?:моих\s+)?(?:паролей|хранилища)'),
      PasswordCommands.backup,
      0.85,
    ),
    (
      RegExp(r'^(?:резервная\s+копия|бэкап)\s+(?:моих\s+)?'
          r'(?:паролей|хранилища(?:\s+паролей)?)$'),
      PasswordCommands.backup,
      0.85,
    ),
    (
      RegExp(r'(?:импортируй|импортировать|загрузи|перенеси|забери)\s+'
          r'(?:мои\s+)?пароли\s+(?:из|с)\s+\S+'),
      PasswordCommands.import,
      0.85,
    ),
    (
      RegExp(r'^(?:импорт|перенос|загрузка)\s+(?:моих\s+)?паролей\s+'
          r'(?:из|с)\s+\S+'),
      PasswordCommands.import,
      0.85,
    ),
    (
      RegExp(r'^(?:импортируй|импортировать)\s+(?:мои\s+)?пароли$'),
      PasswordCommands.import,
      0.85,
    ),
    // Список.
    (
      RegExp(
        r'^(?:какие|что за)\s+пароли\s+(?:у меня\s+)?(?:сохранены|есть|хранятся)',
      ),
      PasswordCommands.list,
      0.85,
    ),
    (
      RegExp(r'^сколько\s+(?:у меня\s+)?паролей'),
      PasswordCommands.list,
      0.85,
    ),
    (
      RegExp(r'^(?:покажи|выведи)\s+(?:мне\s+)?(?:мои\s+|все\s+)+пароли$|'
          r'^список\s+паролей$'),
      PasswordCommands.list,
      0.85,
    ),
    // Логин.
    (
      RegExp('(?:какой|какая)\\s+$_my(?:логин|почта|имя пользователя)\\s+'
          '(?:$_prep|в)\\s+(.+)'),
      PasswordCommands.login,
      0.9,
    ),
    (
      RegExp(
        '(?:$_forgot|$_remind)\\s+$_my(?:логин|имя пользователя)\\s+'
        '(?:$_prep|в)\\s+(.+)',
      ),
      PasswordCommands.login,
      0.9,
    ),
    (
      RegExp(r'на какую почту я\s+(?:регистрировал|зарегистрировал)\S*\s+'
          r'(?:в|на)\s+(.+)'),
      PasswordCommands.login,
      0.9,
    ),
    // Добавить, сменить, удалить.
    (
      RegExp('(?:запомни|сохрани|добавь|запиши|внеси|занеси)\\s+'
          '(?:новый\\s+)?$_my$_pw(?:\\s+$_prep\\s+(.+))?\$'),
      PasswordCommands.add,
      0.9,
    ),
    (
      RegExp('(?:смени|поменяй|измени|обнови|сменить|поменять|обновить)\\s+'
          '$_my$_pw\\s+$_prep\\s+(.+)'),
      PasswordCommands.change,
      0.9,
    ),
    (
      RegExp('(?:удали|сотри|убери|удалить)\\s+$_my$_pw\\s+$_prep\\s+(.+)'),
      PasswordCommands.delete,
      0.9,
    ),
    (
      RegExp('(?:удали|сотри|убери)\\s+запись\\s+(.+?)\\s+из\\s+паролей'),
      PasswordCommands.delete,
      0.9,
    ),
    // Скопировать и показать.
    (
      RegExp('(?:скопируй|копируй|скопировать)\\s+$_my$_pw'
          '(?:\\s+$_prep\\s+(.+))?\$'),
      PasswordCommands.copy,
      0.92,
    ),
    (
      // С начала слова: «подскажи» — не «скажи».
      RegExp('(?:^|\\s)$_reveal\\s+$_my$_pw\\s+$_prep\\s+(.+)'),
      PasswordCommands.reveal,
      0.92,
    ),
    // «Покажи пароль» без сервиса — переспросим, от чего.
    (
      RegExp('^$_reveal\\s+$_my$_onePw\$'),
      PasswordCommands.reveal,
      0.92,
    ),
    // «Забыл пароль от почты» — подсказка («подскажи», «напомни» — тоже
    // сначала подсказка, пароль — только по явной просьбе).
    (
      RegExp('(?:$_forgot|$_remind)\\s+$_my(?:$_loginAndPw|$_pw)\\s+'
          '$_prep\\s+(.+)'),
      PasswordCommands.hint,
      0.92,
    ),
    (
      RegExp('^(?:$_remind)\\s+$_my$_onePw\$'),
      PasswordCommands.hint,
      0.92,
    ),
    (
      RegExp('^$_pw\\s+$_prep\\s+(.+?)\\s+$_forgot\$'),
      PasswordCommands.hint,
      0.92,
    ),
    (
      RegExp(
        '(?:какой|какой же|какой был)\\s+$_my(?:был\\s+)?$_pw\\s+$_prep\\s+(.+)',
      ),
      PasswordCommands.hint,
      0.92,
    ),
    (
      RegExp('^(?:какой|какой же|какой был)\\s+$_my(?:был\\s+)?$_onePw\$'),
      PasswordCommands.hint,
      0.92,
    ),
    (
      RegExp('подсказк\\S*\\s+(?:к|для|от)\\s+(?:паролю|пароля|пароль)'
          '(?:\\s+$_prep\\s+(.+))?\$'),
      PasswordCommands.hint,
      0.92,
    ),
    // «Не могу войти, забыл пароль»: без сервиса — как восстановить.
    // Только рядом со словом «пароль»: «не могу зайти к маме» — не о нём.
    (
      RegExp('^(?=.*$_pw)(?:.*\\s)?не (?:могу|получается) (?:войти|зайти)'),
      PasswordCommands.recoverHelp,
      0.8,
    ),
    (
      RegExp('$_forgot\\s+$_my(?:$_loginAndPw|$_pw)\$'),
      PasswordCommands.recoverHelp,
      0.8,
    ),
    // «Где пароли», «где мои пароли» — список; «где мой пароль» без
    // сервиса — подсказка, навык переспросит, от чего.
    (
      RegExp(r'^где\s+(?:(?:у меня|лежат|хранятся)\s+)?(?:мои\s+|все\s+)*'
          r'пароли$'),
      PasswordCommands.list,
      0.85,
    ),
    (
      RegExp('^где\\s+(?:(?:мой|свой)\\s+)?$_onePw\$'),
      PasswordCommands.hint,
      0.92,
    ),
    // «Пароль от почты?» без глагола, «где лежит пароль от почты», «склад,
    // пароль от почты»: перед паролем — не больше четырёх слов без цифр и
    // ни одного инфинитива («поставить пароль на wifi» — задача,
    // «сколько будет 6 паролей на 2» — арифметика).
    (
      RegExp('^((?:[^\\s,\\d]+[\\s,]+){0,4}?)$_my$_onePw\\s+$_prep\\s+(.+)\$'),
      PasswordCommands.hint,
      0.75,
    ),
  ];

  /// Глаголы «покажи пароль»: явная просьба показать.
  static const String _reveal =
      r'(?:покажи|дай|скажи|выведи|назови|скинь|пришли|отправь|напиши)';

  /// Инфинитив перед «пароль от …» — задача («поставить», «сменить»).
  static final RegExp _infinitive = RegExp(r'(?:ть|ться|ти|чь)$');

  /// Похоже на повелительное наклонение: «поставь», «купи», «дай».
  /// Прилагательные на «-ый/-ий/-ой/-ей» и «мои», «свои» — не глаголы.
  static final RegExp _imperative = RegExp(
    r'(?:[^ыиоеёйьъ]й|[^аеёиоуыэюяйьъ]и|ь|йте|ите|ьте)$',
  );

  /// Прошедшее время: «Маша просила», «сказал».
  static final RegExp _past = RegExp(r'[аеиоуяы]л(?:а|и|о)?$');

  /// Глаголы настоящего времени о другом человеке («мама просит …»,
  /// «коллеги хотят …»): просьба не к навыку.
  static const Set<String> _thirdPerson = <String>{
    'просит',
    'просят',
    'попросит',
    'попросят',
    'хочет',
    'хотят',
    'велит',
    'велят',
    'говорит',
    'говорят',
    'требует',
    'требуют',
    'ждёт',
    'ждет',
    'ждут',
    'пишет',
    'пишут',
    'учит',
    'учат',
  };

  /// «спрашивает», «предлагает», «советует», «уговаривают»: окончание
  /// третьего лица у длинных глаголов (у «привет», «ответ» его нет).
  static final RegExp _thirdPersonEnding =
      RegExp(r'^[а-яё]{3,}(?:ает|яет|ует|юет|ают|яют|уют|еет|еют)$');

  /// Глаголы, которые сами просят пароль у навыка: перед «пароль от …»
  /// они не мешают («найди пароль от почты», «покажи-ка пароль от …»).
  static const Set<String> _ownVerbs = <String>{
    'покажи',
    'дай',
    'скажи',
    'выведи',
    'назови',
    'скинь',
    'пришли',
    'отправь',
    'напиши',
    'найди',
    'ищи',
    'поищи',
    'подскажи',
    'напомни',
    'посмотри',
    'глянь',
  };

  /// Глаголы показа и отправки: слово после них в дательном падеже —
  /// это получатель («отправь пете пароль от wifi»), а не сам человек.
  static const Set<String> _sendVerbs = <String>{
    'покажи',
    'дай',
    'скажи',
    'скинь',
    'пришли',
    'отправь',
    'напиши',
    'назови',
  };

  /// Слова на «-ь/-и/-й», которые не глаголы.
  static const Set<String> _notVerbs = <String>{
    'теперь',
    'опять',
    'здесь',
    'ведь',
    'эти',
    'кстати',
    'почти',
    'сети',
    'был',
    'была',
    'было',
    'были',
  };

  /// Получатели: «гостям», «маме» — пароль для другого человека.
  static const Set<String> _recipients = <String>{
    'ему',
    'ей',
    'им',
    'нам',
    'вам',
    'тебе',
    'всем',
    'гостям',
    'детям',
    'маме',
    'папе',
    'жене',
    'мужу',
    'сыну',
    'дочке',
    'дочери',
    'брату',
    'сестре',
    'другу',
    'подруге',
    'коллеге',
    'коллегам',
    'соседу',
    'соседям',
    'бабушке',
    'дедушке',
    'админу',
    'клиенту',
    'клиентам',
  };

  /// Дательный падеж после глагола отправки: «пете», «маше», «ивану».
  static final RegExp _dative = RegExp(r'(?:е|у|ю|ам|ям|ой|ей|им|ым)$');

  /// Слова перед «пароль от …» говорят о другом деле или другом
  /// человеке: инфинитив («поставить»), чужой глагол в повелительном
  /// наклонении («поставь», «купи»), прошедшее время («Маша просила»),
  /// получатель («Пете», «гостям»). Тогда общее правило не срабатывает.
  static bool _foreign(String prefix, String shownPrefix) {
    final words = prefix
        .replaceAll(',', ' ')
        .trim()
        .split(RegExp(r'\s+'))
        .where((String w) => w.isNotEmpty)
        .toList();
    final shownWords = shownPrefix
        .replaceAll(',', ' ')
        .trim()
        .split(RegExp(r'\s+'))
        .where((String w) => w.isNotEmpty)
        .toList();
    for (var i = 0; i < words.length; i++) {
      final word = words[i].toLowerCase().replaceAll(RegExp(r'-ка$'), '');
      if (_infinitive.hasMatch(word)) return true;
      if (_recipients.contains(word)) return true;
      if (_notVerbs.contains(word) || _ownVerbs.contains(word)) {
        if (_sendVerbs.contains(word) &&
            i + 1 < words.length &&
            words[i + 1] != 'мне' &&
            _dative.hasMatch(words[i + 1].toLowerCase())) {
          return true;
        }
        continue;
      }
      if (_imperative.hasMatch(word) || _past.hasMatch(word)) return true;
      // Настоящее время о другом: «мама просит придумать пароль».
      if (_thirdPerson.contains(word) || _thirdPersonEnding.hasMatch(word)) {
        return true;
      }
      // Имя с большой буквы не в начале фразы: «скажи Пете …».
      if (i > 0 &&
          shownWords.length == words.length &&
          RegExp(r'^[A-ZА-ЯЁ]').hasMatch(shownWords[i])) {
        return true;
      }
    }
    return false;
  }

  /// Одно слово «пароль» / «пароли» — справка, но уступает всему.
  static final RegExp _single = RegExp('^(?:мои\\s+)?$_pw\$');

  /// Маркеры задачи: такая фраза — задача, а не команда навыка.
  static final RegExp _taskMarker = RegExp(
    r'(?:^|\s)(?:в\s+)?задач\S*|напомни|напомнить|не забыть|в\s+список\s+дел|'
    r'в\s+дела(?:\s|$)|todo',
  );

  /// «Напомни (мне)» прямо перед паролем или логином.
  static final RegExp _remindPassword = RegExp(
    '(?:^|\\s)$_remind\\s+$_my(?=$_pw|логин|имя пользователя)',
  );

  /// Хвост, который не часть названия сервиса.
  static final RegExp _tail = RegExp(
    r'(?:\s+(?:пожалуйста|плиз|срочно|снова|опять|еще раз|уже|теперь|'
    r'забыл|забыла|не помню|какой|какая|какое|какой он|был|была|там|тут|'
    r'у меня|подскажи|напомни|скажи|покажи))+$',
  );

  /// «(у) меня от …» перед названием сервиса.
  static final RegExp _holder = RegExp(
    r'^(?:у\s+)?(?:меня|нас|тебя)\s+(?:от|для|на|к|в)\s+',
    caseSensitive: false,
  );

  /// Вместо сервиса — только «меня», «у нас».
  static final RegExp _holderOnly = RegExp(
    r'^(?:у\s+)?(?:меня|нас|тебя)$',
    caseSensitive: false,
  );

  /// Притяжательное перед названием сервиса: «своей почты» → «почты».
  static final RegExp _possessive = RegExp(
    r'^(?:моей|моего|моих|моя|мой|моё|мое|мою|моему|своей|своего|своих|'
    r'своя|свой|своё|свое|свою|своему|нашей|нашего|наш|наша)\s+',
    caseSensitive: false,
  );

  /// Фраза о паролях (уверенность любая, в том числе уступающая задачам):
  /// её не получает ни один сетевой коннектор (раздел 5.9). Это и
  /// разобранная команда, и любое упоминание слова «пароль» ([mentions]).
  static bool looksLike(Utterance utterance) =>
      mentions(utterance) || parse(utterance) != null;

  /// Слово «пароль» в любой форме («пароли», «паролем», «мастер-пароль»),
  /// «password», «пасс».
  static final RegExp _mention = RegExp(
    r'(?<![a-zа-яё])(?:парол|password|пасс(?![a-zа-яё]))',
    caseSensitive: false,
  );

  /// Во фразе упомянут пароль — независимо от [parse]: «напомни мне
  /// сменить пароль» — задача, но сетевому коннектору её не показываем
  /// ни при какой уверенности, включён навык или нет.
  static bool mentions(Utterance utterance) =>
      _mention.hasMatch(utterance.normalized) ||
      _mention.hasMatch(utterance.original);

  /// Разбор [utterance] или `null` — не фраза о паролях.
  static PasswordCommand? parse(Utterance utterance) {
    final text = _clean(utterance.normalized);
    if (text.isEmpty || !text.contains(_anchor)) return null;
    for (final (pattern, cmd, confidence) in _rules) {
      final match = pattern.firstMatch(text);
      if (match == null) continue;
      var group = 1;
      if (cmd == PasswordCommands.generate && match.start > 0) {
        // Генератор не привязан к началу фразы: «Маша просила придумать
        // пароль для wifi» — о другом человеке, это не просьба к навыку.
        final before = text.substring(0, match.start);
        final shown = _clean(utterance.original);
        final shownBefore = shown.length == text.length
            ? shown.substring(0, match.start)
            : before;
        if (_foreign(before, shownBefore)) continue;
      }
      if (match.groupCount >= 2) {
        // Общее правило «… пароль от …»: первая группа — слова перед ним.
        final prefix = match.group(1)!;
        final shown = _clean(utterance.original);
        final shownPrefix = shown.length == text.length
            ? shown.substring(match.start, match.start + prefix.length)
            : prefix;
        if (_foreign(prefix, shownPrefix)) continue;
        group = 2;
      }
      var raw = match.groupCount >= group ? match.group(group) : null;
      if (raw != null) {
        // Название — как написано (регистр), если длины строк совпали.
        final shown = _clean(utterance.original);
        if (shown.length == text.length) {
          final start = match.start + match.group(0)!.lastIndexOf(raw);
          raw = shown.substring(start, start + raw.length);
        }
      }
      final generator = cmd == PasswordCommands.generate;
      final query = generator ? null : _service(raw, utterance);
      final yields = _yields(utterance, text, cmd);
      return PasswordCommand(
        cmd: cmd,
        query: query,
        confidence: yields ? yielded : confidence,
        implicit: yields,
        options: generator ? generatorOptions(text) : const <String, Object?>{},
      );
    }
    if (_single.hasMatch(text)) {
      return const PasswordCommand(
        cmd: PasswordCommands.help,
        confidence: firm,
        implicit: true,
      );
    }
    return null;
  }

  /// Параметры генератора из фразы: «на 24 символа», «из 6 слов», «без
  /// символов», «только буквы и цифры», «без похожих», «запоминающийся».
  /// Слова — только английские (EFF): русских режимов нет (решение
  /// владельца №6). Пусто — значения по умолчанию.
  static Map<String, Object?> generatorOptions(String text) {
    final lower = text.toLowerCase();
    final options = <String, Object?>{};
    final words = RegExp(r'из\s+(?:(\d+)\s+)?(?:английских\s+)?слов|'
            r'запоминающ|фраз[аыу]|парольн\S* фраз')
        .firstMatch(lower);
    final chars = RegExp(r'(?:на|из|в|длиной)\s+(\d+)\s+(?:символ|знак|букв)')
        .firstMatch(lower);
    if (words != null && chars == null) {
      options['mode'] = 'words';
      final count = int.tryParse(words.group(1) ?? '');
      if (count != null) options['words'] = count;
    } else {
      options['mode'] = 'characters';
      final length = int.tryParse(chars?.group(1) ?? '');
      if (length != null) options['length'] = length;
    }
    // «без цифр и символов», «без символов, цифр» — каждое слово после
    // одного «без».
    const without = r'без\s+(?:[а-яё]+\s*(?:,\s*|\s+и\s+))*';
    if (RegExp('$without(?:спец\\S*\\s*)?(?:символов|знаков)|'
            r'только\s+(?:из\s+)?букв\S*\s+и\s+цифр|из\s+букв\s+и\s+цифр')
        .hasMatch(lower)) {
      options['symbols'] = false;
    }
    if (RegExp('$withoutцифр').hasMatch(lower)) options['digits'] = false;
    if (RegExp('$withoutпохожих').hasMatch(lower)) {
      options['noLookAlike'] = true;
    }
    return options;
  }

  /// Хоть одно опорное слово: без него фраза точно не о паролях.
  static final RegExp _anchor = RegExp(
    r'парол|пасс|password|логин|почту|имя пользователя|хранилищ|сейф|'
    r'телефон|смартфон|ноутбук|ноут|планшет|компьютер|устройство|потренируй',
  );

  static bool _yields(Utterance utterance, String text, String cmd) {
    // «Напомни мне пароль от почты» — просьба подсказать; «напомни
    // сменить пароль» — задача.
    final rest = text.replaceFirst(_remindPassword, '');
    if (_taskMarker.hasMatch(rest)) return true;
    if (utterance.hashtags.isNotEmpty) return true;
    // «пароль на 24 символа» — не срок.
    if (cmd == PasswordCommands.generate) return false;
    return utterance.due.spans.isNotEmpty;
  }

  /// Слова, с которых начинается уже не название: «сменился», «не
  /// работает», получатель «гостям».
  static const Set<String> _stopWords = <String>{
    'сменили',
    'поменяли',
    'изменили',
    'сломали',
    'не',
    'работает',
    'слетел',
    'пропал',
    'новый',
    'старый',
    'нужен',
    'нужно',
    'надо',
  };

  /// Название сервиса обрывается на числе (коды домофона в ответ не
  /// попадают никогда), на возвратном глаголе («сменился») и на
  /// стоп-словах. Первое слово остаётся всегда, кроме числа.
  static String _cutTail(String value) {
    final words = value.split(RegExp(r'\s+'));
    final kept = <String>[];
    for (final word in words) {
      final lower = word.toLowerCase();
      if (RegExp(r'^\d+$').hasMatch(lower)) break;
      if (kept.isNotEmpty &&
          (_stopWords.contains(lower) ||
              _recipients.contains(lower) ||
              RegExp(r'(?:ся|сь)$').hasMatch(lower))) {
        break;
      }
      kept.add(word);
    }
    return kept.join(' ');
  }

  static String _clean(String text) => text
      .replaceAll(RegExp(r'[«»"“”„]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[\s,.!?;:—–-]+|[\s,.!?;:—–…]+$'), '')
      .trim();

  /// Сервис: из кавычек, иначе остаток после предлога без хвоста.
  static String? _service(String? raw, Utterance utterance) {
    if (utterance.quotedTitles.isNotEmpty) {
      final quoted = utterance.quotedTitles.first.text.trim();
      if (quoted.isNotEmpty) return ServiceAliases.display(quoted);
    }
    if (raw == null) return null;
    var value = raw.replaceAll(RegExp(r'[?!.,;:]+.*$'), '').trim();
    value = _cutTail(value);
    final tail = _tail.firstMatch(value.toLowerCase());
    if (tail != null) value = value.substring(0, tail.start).trim();
    // «от почты в задачи» и подобное уже ушло задачам; «у меня» — не
    // сервис.
    value = value.replaceAll(_possessive, '');
    // «нужен пароль у меня от почты»: правило «пароль у …» взяло «меня от
    // почты» — сервис после предлога.
    value = value.replaceFirst(_holder, '');
    if (_holderOnly.hasMatch(value)) return null;
    value = value.replaceAll(_possessive, '');
    if (value.isEmpty || value.length > 60) return null;
    return ServiceAliases.display(value);
  }
}
