import 'route_policy.dart';

/// Разговорная обёртка вокруг команды — для всех навыков сразу: «так,
/// поставь будильник на 7», «будь добр, покажи пароль от вк», «слушай, а
/// сконвертируй видео в mp3», «где лежит 64115, пожалуйста», «а можешь
/// запереть пароли?», «перенеси-ка встречу», «запиши себе купить хлеб».
///
/// Слова-вставки уже знают разбор задач ([SpeechNoise]) и вступления
/// «привет, …» ([SocialPrefix]), но другие навыки видят фразу целиком и
/// на «так, …» молчат. [strip] снимает обёртку один раз для всех;
/// [prefer] решает, чей разбор взять: фраза как есть остаётся главной,
/// без обёртки — только если её понял явный навык, а исходную — никто
/// явно, или тот же навык той же командой (тогда без обёртки чище поля:
/// «Встреча с клиентом», а не «Будь добр, встречу с клиентом»).
///
/// Внутри кавычек ничего не меняется. Ответ на вопрос помощника («да,
/// купил хлеб», «нет, не купил») сюда не попадает: маршрутизатор
/// обращается к обёртке только без ждущего вопроса.
abstract final class CommandFrame {
  /// Фраза без обёртки или `null`, если снимать нечего. [fromVoice] —
  /// надиктовано: «спасибо» в конце без запятой — тоже вежливость, а не
  /// часть дела.
  static String? strip(String text, {bool fromVoice = false}) {
    if (text.length > 400) return null;
    var value = text.trim();
    final before = value;
    for (var pass = 0; pass < 3; pass++) {
      final next = _stripLead(value);
      if (next == value) break;
      value = next;
    }
    value = _modal(value);
    value = _stripTail(value, fromVoice: fromVoice);
    value = value.replaceAllMapped(_kaParticle, (Match m) {
      final verb = m.group(1)!;
      return _imperatives.contains(verb.toLowerCase()) ? verb : m.group(0)!;
    });
    value = value.replaceAllMapped(
      _selfAfterVerb,
      (Match m) => '${m.group(1)} ',
    );
    value = value.replaceAll(_spaces, ' ').trim();
    if (value.isEmpty || value == before) return null;
    return value[0].toUpperCase() + value.substring(1);
  }

  /// Взять ли разбор фразы без обёртки ([framed]) вместо разбора фразы как
  /// есть ([original]):
  ///
  /// - тот же навык той же командой — да: чище поля;
  /// - фразу как есть не понял никто — да («короче, привет», «так, купить
  ///   хлеб»);
  /// - без обёртки — явная команда, а как есть — догадка, запасной ответ
  ///   беседы или спор — да;
  /// - иначе — нет: «ок, всё понял, спасибо!» остаётся репликой беседы, а
  ///   не сообщением о сделанном «Всё понял».
  static bool prefer(RouteDecision original, RouteDecision framed) {
    final winner = framed.winner;
    if (winner == null || framed.isAmbiguous) return false;
    final was = original.winner;
    if (was != null &&
        was.connectorId == winner.connectorId &&
        was.commandId == winner.commandId) {
      return true;
    }
    if (was == null && !original.isAmbiguous) return true;
    if (winner.implicit || winner.fallback) return false;
    return was == null || was.implicit || was.fallback || original.isAmbiguous;
  }

  static final RegExp _spaces = RegExp(r'\s+');

  /// Вступление в начале фразы и то, что за ним: запятая, тире, двоеточие
  /// или пробел.
  static String _stripLead(String text) {
    for (final pattern in _leads) {
      final match = pattern.firstMatch(text);
      if (match == null) continue;
      final rest = text.substring(match.end).trimLeft();
      if (rest.isEmpty || _opensQuote(rest)) continue;
      return rest;
    }
    return text;
  }

  static bool _opensQuote(String text) => '«"“„'.contains(text[0]);

  /// Вступления. Неоднозначные слова («так», «короче», «значит», «вот»,
  /// «смотри», «ладно», «окей») — только с запятой или тире: «так держать»,
  /// «короче говоря», «вот это купить» не трогаются.
  static final List<RegExp> _leads = <RegExp>[
    RegExp(
      r'^(?:э+|мм+|хм+|кхм|эм+|ээ+м*)(?![а-яёa-z])[\s,.!—–-]*',
      caseSensitive: false,
    ),
    RegExp(
      r'^(?:так|короче|значит|вот|смотри|ладно|окей|ок|итак|в\s+общем|'
      r'кстати|слушай-ка|давай|ну)(?:\s*[,—–:]|\s+-)\s*',
      caseSensitive: false,
    ),
    RegExp(
      r'^(?:будь\s+(?:добр|добра|другом|любезен|любезна)|'
      r'будьте\s+(?:добры|любезны)|'
      r'если\s+(?:тебе\s+|вам\s+)?(?:не\s+сложно|не\s+трудно|можно)|'
      r'алло|эй|слушай(?:те)?|слышь|слышишь|давай-ка|'
      r'пожалуйста|пожалуйсто|плиз|пж)'
      r'(?![а-яё-])(?:\s*[,—–:]|\s+-)?\s*(?:а(?![а-яё])\s*,?\s*)?',
      caseSensitive: false,
    ),
  ];

  /// «А можешь запереть пароли?», «не мог бы ты сделать бэкап?» →
  /// «запри пароли», «сделай бэкап»: инфинитив — в повелительное по
  /// закрытой таблице. Глагол не из таблицы и вопрос дальше («а можешь
  /// сказать, как тебя зовут?») — фраза как есть.
  static String _modal(String text) {
    final match = _modalFrame.firstMatch(text);
    if (match == null) return text;
    final verb = match.group(1)!;
    final imperative = _toImperative[verb.toLowerCase().replaceAll('ё', 'е')];
    if (imperative == null) return text;
    final rest = text.substring(match.end);
    final words = rest
        .toLowerCase()
        .replaceAll(RegExp(r'«[^»]*»|"[^"]*"'), ' ')
        .split(RegExp(r'[^а-яёa-z0-9]+'));
    if (words.any(_questionWords.contains)) return text;
    final tail = rest.replaceFirst(RegExp(r'\s*\?+\s*$'), '');
    return '$imperative$tail';
  }

  static final RegExp _modalFrame = RegExp(
    r'^(?:(?:а|и)\s+)?(?:(?:ты|вы)\s+)?'
    r'(?:можешь|можете|сможешь|сможете|'
    r'не\s+(?:мог|могла|могли)\s+бы(?:\s+(?:ты|вы))?|'
    r'(?:мог|могла|могли)\s+бы(?:\s+(?:ты|вы))?)'
    r'\s+(?:мне\s+|нам\s+|пожалуйста\s+)*([а-яё]+)',
    caseSensitive: false,
  );

  static const Set<String> _questionWords = <String>{
    'как',
    'что',
    'где',
    'когда',
    'какой',
    'какая',
    'какое',
    'какие',
    'кто',
    'сколько',
    'почему',
    'зачем',
    'ли',
    'ты',
    'тебя',
    'тебе',
    'вы',
    'вас',
    'вам',
  };

  /// Вежливость в конце: «…, пожалуйста», «… — спасибо». Без запятой —
  /// только «пожалуйста» и, у надиктованного, «спасибо» — если перед ним
  /// не «скажи/передай/отправь …»: «напомни сказать Олегу спасибо» — дело.
  static String _stripTail(String text, {required bool fromVoice}) {
    final comma = _tailWithComma.firstMatch(text);
    if (comma != null) return text.substring(0, comma.start);
    final bare = (fromVoice ? _tailVoice : _tailTyped).firstMatch(text);
    if (bare == null) return text;
    final head = text.substring(0, bare.start);
    if (bare.group(1)!.toLowerCase() == 'спасибо' &&
        head
            .toLowerCase()
            .split(RegExp(r'[^а-яё]+'))
            .any((String w) => _speechStems.any(w.startsWith))) {
      return text;
    }
    return head;
  }

  static final RegExp _tailWithComma = RegExp(
    r'\s*[,—–]\s*(?:пожалуйста|пожалуйсто|пж|плиз|спасибо)[\s.!)]*$',
    caseSensitive: false,
  );

  static final RegExp _tailTyped = RegExp(
    r'\s+(пожалуйста)[\s.!]*$',
    caseSensitive: false,
  );

  static final RegExp _tailVoice = RegExp(
    r'\s+(пожалуйста|спасибо)[\s.!]*$',
    caseSensitive: false,
  );

  /// Глаголы, после которых «спасибо» — часть дела.
  static const List<String> _speechStems = <String>[
    'сказ',
    'скаж',
    'напис',
    'напиш',
    'перед',
    'отправ',
    'посла',
    'пошли',
    'кин',
    'скин',
    'черкн',
    'отпис',
    'поблагодар',
    'ответ',
  ];

  /// «Перенеси-ка», «запиши-ка»: частица у глагола из таблицы.
  static final RegExp _kaParticle = RegExp(
    r'(?<![а-яё])([а-яё]+)-ка(?![а-яё])',
    caseSensitive: false,
  );

  /// «Запиши себе купить хлеб» → «Запиши купить хлеб».
  static final RegExp _selfAfterVerb = RegExp(
    r'(?<![а-яё])(запиши|напомни|добавь|запомни|поставь)\s+себе\s+',
    caseSensitive: false,
  );

  /// Инфинитив → повелительное: только эти глаголы команд.
  static const Map<String, String> _toImperative = <String, String>{
    'перенести': 'перенеси',
    'отложить': 'отложи',
    'сдвинуть': 'сдвинь',
    'передвинуть': 'передвинь',
    'отметить': 'отметь',
    'закрыть': 'закрой',
    'завершить': 'заверши',
    'выполнить': 'выполни',
    'добавить': 'добавь',
    'записать': 'запиши',
    'создать': 'создай',
    'завести': 'заведи',
    'напомнить': 'напомни',
    'поставить': 'поставь',
    'показать': 'покажи',
    'переименовать': 'переименуй',
    'удалить': 'удали',
    'стереть': 'сотри',
    'запереть': 'запри',
    'заблокировать': 'заблокируй',
    'открыть': 'открой',
    'сделать': 'сделай',
    'восстановить': 'восстанови',
    'сконвертировать': 'сконвертируй',
    'конвертировать': 'конвертируй',
    'перегнать': 'перегони',
    'сжать': 'сожми',
    'заархивировать': 'заархивируй',
    'распаковать': 'распакуй',
    'скачать': 'скачай',
    'найти': 'найди',
    'посчитать': 'посчитай',
    'разбудить': 'разбуди',
    'засечь': 'засеки',
    'включить': 'включи',
    'выключить': 'выключи',
    'скопировать': 'скопируй',
    'сгенерировать': 'сгенерируй',
    'придумать': 'придумай',
    'проверить': 'проверь',
    'сохранить': 'сохрани',
    'убрать': 'убери',
  };

  static final Set<String> _imperatives = _toImperative.values.toSet();
}
