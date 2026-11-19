import '../connectors/verb_forms.dart';
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
    // Внутри кавычек — название как сказано: «купить будилку» не
    // становится «купить будильник».
    final quotes = <String>[];
    var value = text.trim().replaceAllMapped(_quoted, (Match m) {
      quotes.add(m.group(0)!);
      return '$_quoteMark${quotes.length - 1}$_quoteEnd';
    });
    final before = value;
    for (var pass = 0; pass < 3; pass++) {
      final next = _stripLead(value);
      if (next == value) break;
      value = next;
    }
    // «Отметь отметь, что …», «напомни напомни …» — слово повторено
    // в надиктованном.
    value = value.replaceAllMapped(
      _stutter,
      (Match m) => m.group(1) ?? m.group(2)!,
    );
    value = _modal(value);
    value = _stripTail(value, fromVoice: fromVoice);
    // «кУПИТЬ молоко» — нажат Caps Lock: слово с маленькой первой и
    // большими остальными — в обычный регистр.
    value = value.replaceAllMapped(
      _capsLocked,
      (Match m) => m.group(0)!.toLowerCase(),
    );
    value = _colloquial(value);
    value = _verbLast(value);
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
    value = value.replaceAllMapped(
      RegExp('$_quoteMark(\\d+)$_quoteEnd'),
      (Match m) => quotes[int.parse(m.group(1)!)],
    );
    return value[0].toUpperCase() + value.substring(1);
  }

  /// Первое слово (от четырёх букв) или «задачу», сказанные дважды
  /// подряд. Внутри фразы повтор бывает нужен: «в пятнадцать ноль ноль».
  static final RegExp _stutter = RegExp(
    r'(?:^([а-яё]{4,})(?:\s*,?\s+)\1|(?<![а-яё])(задачу|напоминание)\s+\2)'
    r'(?![а-яё])',
    caseSensitive: false,
  );

  static final RegExp _capsLocked =
      RegExp(r'(?<![А-Яа-яЁё])[а-яё][А-ЯЁ]{2,}(?![А-Яа-яЁё])');

  static final RegExp _quoted = RegExp('«[^»]*»|"[^"]*"|„[^“”]*[“”]');
  static const String _quoteMark = '\uE000';
  static const String _quoteEnd = '\uE001';

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

  static bool _opensQuote(String text) => '«"“„$_quoteMark'.contains(text[0]);

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
    // «Кстати не дай мне забыть …», «короче напомни …» — без запятой
    // только перед словом команды.
    RegExp(
      r'^(?:кстати|короче|в\s+общем)\s+(?=(?:напомни|не\s+дай|добавь|'
      r'запиши|поставь|перенеси|отметь)(?![а-яё]))',
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
    // «И ещё одну — купить хлеб», «а ещё задачу: забрать куртку» — ещё
    // одно дело в разговоре о задачах.
    RegExp(
      r'^(?:(?:и|а)\s+)?ещ[её]\s+(?:(?:одн[уоа]|один)(?:\s+задачу)?'
      r'(?:\s*[—–:,]|\s+-)|(?:одн[уоа]\s+)?задачу(?![а-яё])[\s,:—–-]*)\s*',
      caseSensitive: false,
    ),
    // Поправка: «я имел в виду в 19:00», «в смысле, на завтра» — дальше
    // то, что сказано вместо прежнего.
    RegExp(
      r'^(?:(?:нет|не)\s*,?\s*)?(?:я\s+)?(?:имел[аи]?\s+в\s+виду|'
      r'хотел[аи]?\s+сказать|в\s+смысле)(?![а-яё-])[\s,:—–-]*',
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
    final verb = match.group(2)!;
    final when = match.group(1)!;
    final imperative = _toImperative[verb.toLowerCase().replaceAll('ё', 'е')];
    if (imperative == null) return text;
    final rest = text.substring(match.end);
    final words = rest
        .toLowerCase()
        .replaceAll(RegExp(r'«[^»]*»|"[^"]*"'), ' ')
        .split(RegExp(r'[^а-яёa-z0-9]+'));
    if (words.any(_questionWords.contains)) return text;
    // «Ты могла бы отметить отчёт, но забыла» — упрёк, а не просьба:
    // «мог бы» без «не» — только вопросом; «…, но …» — рассказ.
    final hypothetical = !match.group(0)!.toLowerCase().contains('не ') &&
        RegExp(r'(?<![а-яё])(?:мог|могла|могли)\s+бы', caseSensitive: false)
            .hasMatch(match.group(0)!);
    if (hypothetical && !text.trimRight().endsWith('?')) return text;
    if (words.contains('но') || words.contains('однако')) return text;
    // «Сможешь завершить отчёт до пятницы?» — о сроке, а не «заверши
    // сейчас».
    if (_completionVerbs.contains(verb.toLowerCase()) &&
        RegExp(r'(?<![а-яё])(?:до|к)\s', caseSensitive: false).hasMatch(rest)) {
      return text;
    }
    final tail = rest.replaceFirst(RegExp(r'\s*\?+\s*$'), '');
    return when.isEmpty
        ? '$imperative$tail'
        : '$imperative ${when.trim()}$tail';
  }

  static const Set<String> _completionVerbs = <String>{
    'завершить',
    'закрыть',
    'выполнить',
    'отметить',
  };

  static final RegExp _modalFrame = RegExp(
    r'^(?:(?:а|и)\s+)?(?:(?:ты|вы)\s+)?'
    r'(?:можешь|можете|сможешь|сможете|'
    r'не\s+(?:мог|могла|могли)\s+бы(?:\s+(?:ты|вы))?|'
    r'(?:мог|могла|могли)\s+бы(?:\s+(?:ты|вы))?)'
    r'\s+(?:мне\s+|нам\s+|пожалуйста\s+)*'
    // «не мог бы ты завтра утром напомнить …» — срок до глагола.
    r'((?:(?:завтра|послезавтра|сегодня|утром|вечером|днем|днём)\s+)*)'
    r'(?:мне\s+|нам\s+)?([а-яё]+)',
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

  /// Разговорные формы команд — словами команд навыков: «кинь напоминалку
  /// на завтра …» → «напомни на завтра …», «вычеркни купить хлеб» →
  /// «заверши купить хлеб», «поставь будилку» → «поставь будильник».
  /// Только сочетания, однозначные сами по себе: «кинь мяч», «перекинь
  /// деньги маме» не трогаются (перенос — только со сроком). И, как вся
  /// обёртка, — только по правилу [prefer]: «запомни пароль от вк» как есть
  /// понимают «Пароли», и переписанная фраза не берётся.
  static String _colloquial(String text) {
    var value = text;
    for (final (pattern, replacement) in _colloquialRules) {
      // «Дело глаголом» по окончанию — только примерно («путь», «грусть»):
      // настоящий инфинитив проверяет VerbForms.
      if (pattern.pattern.contains(_deed)) {
        final match = pattern.firstMatch(value);
        if (match == null) continue;
        final rest = value.substring(match.end);
        final due = (pattern.pattern.contains(_due) &&
                RegExp('^$_due', caseSensitive: false).hasMatch(rest)) ||
            (pattern.pattern.contains(_dayWord) &&
                RegExp('^$_dayWord', caseSensitive: false).hasMatch(rest));
        final deed = rest
            .toLowerCase()
            .replaceAll('ё', 'е')
            .split(RegExp(r'[^а-я]+'))
            .any(VerbForms.isInfinitive);
        if (!due && !deed) continue;
      }
      value = value.replaceFirstMapped(
        pattern,
        (Match m) => replacement.replaceAllMapped(
          RegExp(r'\$(\d)'),
          (Match g) => m.group(int.parse(g.group(1)!)) ?? '',
        ),
      );
    }
    return value;
  }

  static const String _due =
      r'(?=.*(?:(?<![а-яё])(?:на|к|до)\s+(?:завтра|послезавтра|сегодня|'
      r'понедельник|вторник|среду|четверг|пятницу|субботу|воскресенье|'
      r'вечер|утро|выходные|неделю|час|\d)(?![а-яё])|'
      r'(?<![а-яё])(?:позже|раньше|попозже|пораньше)(?![а-яё])))';

  /// Дальше по фразе — дело глаголом: «… позвонить маме».
  static const String _deed =
      r'(?=.*\s[а-яё]{2,}(?:ть|ти|чь)(?:ся|сь)?(?:[\s,.!?]|$))';

  /// Дальше по фразе — день или время: «в четверг», «завтра», «в 9».
  static const String _dayWord =
      r'(?=.*(?<![а-яё])(?:завтра|послезавтра|сегодня|понедельник|вторник|'
      r'среду|четверг|пятницу|субботу|воскресенье|выходных|выходные|утром|'
      r'вечером|днем|днём|\d+)(?![а-яё]))';

  /// Дальше — срок или дело глаголом.
  static const String _dueOrDeed = '(?:$_due|$_deed)';

  static final List<(RegExp, String)> _colloquialRules = <(RegExp, String)>[
    // Глагол и предмет в конце: «на 7 будильник поставь», «купить хлеб
    // добавь в задачи», «от вк пароль скинь».
    (
      RegExp(
        r'^((?:на|в)\s+.+?)\s+(будильник|таймер)\s+(поставь|заведи)$',
        caseSensitive: false,
      ),
      r'$3 $2 $1',
    ),
    (
      RegExp(
        r'^(?!.*(?<![а-яё])(?:не|нет|ничего)(?![а-яё]))'
        r'(.+?)[\s,]+(?:добавь|запиши|закинь|кинь)\s+в\s+'
        r'(?:задачи|список(?:\s+дел)?|дела)$',
        caseSensitive: false,
      ),
      r'добавь задачу $1',
    ),
    (
      RegExp(
        r'^(от\s+.+?)\s+(пароль|логин)\s+(скинь|покажи|дай)$',
        caseSensitive: false,
      ),
      r'$3 $2 $1',
    ),
    (
      RegExp(
        r'^(?:кинь|закинь|брось|черкни|черкани|поставь)\s+(?:мне\s+)?'
        r'(?:напоминалк[уи]|напоминалочку)(?![а-яё])',
        caseSensitive: false,
      ),
      'напомни',
    ),
    (
      RegExp(
        r'^(?:кинь|закинь|брось)\s+в\s+(?:напоминания|напоминалки)(?![а-яё])',
        caseSensitive: false,
      ),
      'напомни',
    ),
    (
      RegExp(
        r'^(?:кинь|закинь|брось|черкни|черкани|занеси|внеси)\s+в\s+'
        r'(?:задачи|список(?:\s+дел)?|дела|туду)(?![а-яё])\s*:?',
        caseSensitive: false,
      ),
      'добавь задачу ',
    ),
    (
      RegExp(
        r'^в\s+(?:список\s+дел|задачи|туду)\s*:',
        caseSensitive: false,
      ),
      'добавь задачу',
    ),
    (
      RegExp(r'^не\s+дай\s+(?:мне\s+)?забыть(?![а-яё])', caseSensitive: false),
      'напомни',
    ),
    // «Хочется не забыть поздравить Сергея», «было бы здорово не забыть
    // про врача в четверг» — просьба напомнить, сказанная пожеланием.
    (
      RegExp(
        r'^(?:мне\s+)?(?:хочется|хочу|хотелось\s+бы|важно|надо\s+бы|'
        r'было\s+бы\s+(?:здорово|хорошо|неплохо|круто)|'
        r'(?:хорошо|неплохо)\s+бы)\s+не\s+забыть(?![а-яё])'
        '(?:$_dayWord|$_deed)',
        caseSensitive: false,
      ),
      'напомни',
    ),
    // «Хорошо бы в выходные помыть машину», «неплохо бы созвониться
    // с бухгалтером до среды» — дело глаголом: как «надо …».
    (
      RegExp(
        '^(?:хорошо|неплохо|было\\s+бы\\s+(?:здорово|хорошо|неплохо))'
        '(?:\\s+бы)?(?![а-яё])$_deed',
        caseSensitive: false,
      ),
      'надо',
    ),
    // «Буду признателен, если напомнишь оплатить кредит» — вежливое
    // «напомни».
    (
      RegExp(
        r'^(?:буду\s+)?(?:признателен|признательна|благодарен|благодарна)'
        r'\s*,?\s*если\s+(?:ты\s+)?(?:мне\s+)?напомнишь(?![а-яё])',
        caseSensitive: false,
      ),
      'напомни',
    ),
    // «Ты напомнишь мне в 6 полить цветы?» — просьба вопросом, а дальше
    // дело глаголом.
    (
      RegExp(
        '^(?:а\\s+)?(?:ты\\s+)?напомнишь(?![а-яё])$_deed',
        caseSensitive: false,
      ),
      'напомни',
    ),
    // «Я хочу в субботу разобрать балкон» — желание со сроком и делом
    // глаголом — дело на этот день. Без срока («хочу спать») — как есть.
    (
      RegExp(
        '^(?:я\\s+)?хочу(?![а-яё])(?!\\s+не\\s)$_dayWord$_deed',
        caseSensitive: false,
      ),
      'надо',
    ),
    // «Не забудь, что у Маши день рождения в субботу» — в начале фразы,
    // со сроком или делом: как «напомни».
    (
      RegExp(
        '^не\\s+забудь(?:те)?(?![а-яё])(?:$_dayWord|$_deed)',
        caseSensitive: false,
      ),
      'напомни',
    ),
    // «Так, записывай: послезавтра в 14:00 встреча» — как «запиши».
    (
      RegExp(r'^записывай(?:те)?(?![а-яё])', caseSensitive: false),
      'запиши',
    ),
    // «Запомни: завтра в 10 позвонить маме» — дело со сроком или глаголом;
    // «запомни: хлеб» — как есть.
    (
      RegExp('^запомни\\s*:$_dueOrDeed', caseSensitive: false),
      'запиши:',
    ),
    // «Напомнить завтра в 9 купить корм» — заметка себе: как «напомни».
    // Не вопрос и не раздумье: «Напомнить маме позвонить?», «напомнить ли
    // ему …», «напомнить тебе …» — как есть.
    (
      RegExp(
        '^напомнить(?![^?]*\\?)(?!.*(?<![а-яё])(?:ли|или|тебе|вам)(?![а-яё]))'
        '$_deed',
        caseSensitive: false,
      ),
      'напомни',
    ),
    (
      RegExp(
        '^(?:черкани|черкни)(?![а-яё])$_due',
        caseSensitive: false,
      ),
      'запиши',
    ),
    (
      RegExp(r'^(?:вычеркни|вычеркнуть)(?=\s+\S)', caseSensitive: false),
      'заверши',
    ),
    (
      RegExp('^перекинь(?![а-яё])$_due', caseSensitive: false),
      'перенеси',
    ),
    // «Поменяй срок у задачи про отчёт на 20 ноября» — перенос.
    (
      RegExp(
        r'^(?:поменяй|измени|смени)\s+(?:срок|дату|дедлайн)'
        r'(?:\s+(?:у|для))?\s+задач[иу](?![а-яё])'
        '$_due',
        caseSensitive: false,
      ),
      'перенеси задачу',
    ),
    // «Отодвинь звонок на час» — как «отложи»: длительность без «позже» —
    // сдвиг вперёд.
    (
      RegExp('^отодвинь(?![а-яё])$_due', caseSensitive: false),
      'отложи',
    ),
    (
      RegExp(
        r'^(?:покажи|открой|выведи)\s+(?:туду|тудушки|тудушку)(?![а-яё])',
        caseSensitive: false,
      ),
      'покажи задачи',
    ),
    (
      RegExp(
        r'^(?:ч[её]|что)\s+(?:там\s+)?у\s+меня\s+по\s+делам(?![а-яё])',
        caseSensitive: false,
      ),
      'покажи задачи',
    ),
    (RegExp(r'будилк(?:у|а|е)(?![а-яё])', caseSensitive: false), 'будильник'),
    (RegExp(r'^буди(?=\s)', caseSensitive: false), 'разбуди'),
    (
      RegExp(r'^(?:кинь|закинь|запусти)\s+таймер', caseSensitive: false),
      'поставь таймер',
    ),
    (RegExp(r'^отсчитай(?=\s+\d)', caseSensitive: false), 'засеки'),
    (RegExp(r'^покеда(?![а-яё])', caseSensitive: false), 'пока'),
    (
      RegExp(r'^как\s+тобой\s+пользоваться', caseSensitive: false),
      'что ты умеешь',
    ),
    (RegExp(r'^сгенери(?=\s)', caseSensitive: false), 'сгенерируй'),
    (
      RegExp(r'^(?:забэкапь|забекапь)(?![а-яё])', caseSensitive: false),
      'сделай резервную копию',
    ),
    (
      RegExp(
        r'^переделай(?=\s+(?:видео|аудио|фото|файл|ролик|запись|картинк|'
        r'музык|песн)\S*\s+в\s)',
        caseSensitive: false,
      ),
      'сконвертируй',
    ),
    (
      RegExp(
        r'^(?:вытащи|достань|извлеки)\s+(?:звук|аудио|музыку)\s+из\s+'
        r'(?:видео|ролика|клипа)(?=\s+в\s)',
        caseSensitive: false,
      ),
      'сконвертируй видео',
    ),
    (
      RegExp(
        r'^(?:вытащи|достань|извлеки)\s+(?:файлы|вс[её])\s+из\s+'
        r'(?:архива|zip|зипа)(?![а-яё])',
        caseSensitive: false,
      ),
      'распакуй архив',
    ),
    (
      RegExp(
        r'^в\s+ч[её]м\s+(.*?)\s*(?:идти|выходить|пойти)'
        r'(?:\s+на\s+улицу)?\s*\??$',
        caseSensitive: false,
      ),
      r'что надеть $1',
    ),
  ];

  /// Глагол в конце: «будильник на 7 поставь», «архив распакуй» — на
  /// место команды, в начало.
  static String _verbLast(String text) {
    final match = _lastVerb.firstMatch(text);
    if (match == null) return text;
    final verb = match.group(2)!;
    final head = match.group(1)!;
    final words = head
        .toLowerCase()
        .replaceAll('ё', 'е')
        .split(RegExp(r'[^а-яa-z0-9]+'))
        .where((String w) => w.isNotEmpty)
        .toList();
    // «Хорошо, запиши», «да, добавь», «нет, не запиши» — ответ и согласие,
    // а не дело «Хорошо»; отрицание — тем более не команда.
    if (words.isEmpty ||
        words.every(_discourse.contains) ||
        words.any(_negations.contains)) {
      return text;
    }
    return '$verb $head';
  }

  static const Set<String> _discourse = <String>{
    'да',
    'ага',
    'угу',
    'ок',
    'окей',
    'хорошо',
    'ладно',
    'давай',
    'тогда',
    'конечно',
    'спасибо',
    'ну',
    'так',
    'все',
    'это',
    'вот',
    'можно',
    'еще',
    'просто',
    'сейчас',
    'потом',
    'теперь',
    'а',
    'и',
  };

  static const Set<String> _negations = <String>{
    'не',
    'нет',
    'ничего',
    'никогда',
    'ни',
  };

  /// Только глаголы, которые не меняют существующие задачи: «всё,
  /// закрой» — конец реплики, а не «закрой всё».
  static final RegExp _lastVerb = RegExp(
    r'^(?!(?:поставь|распакуй|сконвертируй|скинь|добавь|сожми|запиши|'
    r'покажи)\s)(?!(?:вс[её]|ну|так|ладно|ок)[\s,.!—-]*$)'
    r'(.+?)[\s,]+'
    r'(поставь|распакуй|сконвертируй|конвертируй|скинь|покажи|сожми|'
    r'добавь|запиши)$',
    caseSensitive: false,
  );

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
