import 'social_prefix.dart';
import 'speech_noise.dart';
import 'utterance.dart';
import 'verb_forms.dart';

/// Какой это вопрос ([QuestionPhrases.detect]).
enum QuestionKind {
  /// Вопрос о мире: «напомни, какая формула суммы в гугл-таблицах»,
  /// «подскажи, как называется столица Австралии», «где лежат ключи?».
  info,

  /// Просьба вспомнить за пользователя: «напомни, что я хотел купить».
  recall,

  /// Перевод единиц и валют: «переведи 5 миль в километры», «сколько
  /// метров в миле». Конвертер работает с файлами, курсов и справочника
  /// нет — честный ответ и что можно посчитать.
  units,
}

/// Вопрос во фразе: что найдено и где.
final class QuestionMatch {
  const QuestionMatch({
    required this.kind,
    required this.opener,
    required this.whIndex,
  });

  final QuestionKind kind;

  /// Слово-просьба перед вопросом: «напомни», «подскажи»; `null` — фраза
  /// сама начинается с вопросительного слова.
  final String? opener;

  /// Номер вопросительного слова в [Utterance.tokens].
  final int whIndex;

  /// «Напомни, какая …»: просьба звучит как «напомни», и её можно было
  /// принять за напоминание.
  bool get remindOpener => opener == 'напомни' || opener == 'напомните';
}

/// Вопросы, на которые помощник без сети не ответит: «напомни, какая
/// формула суммы в гугл-таблицах?», «подскажи, как сделать сумму
/// в экселе».
///
/// «Напомни» бывает и просьбой о напоминании, и вопросом. Различает их
/// то, что идёт сразу после просьбы: инфинитив («напомни купить хлеб»,
/// «напомни спросить, какая формула») — дело; вопросительное слово
/// («напомни, какая формула») — вопрос. «Напомни, что надо купить хлеб»,
/// «напомни, что завтра встреча» — дело: «что» здесь союз. Знак «?» сам
/// по себе вопросом фразу не делает. Слова в кавычках не смотрятся.
abstract final class QuestionPhrases {
  /// Просьбы, после которых идёт вопрос.
  static const Set<String> openers = <String>{
    'напомни',
    'напомните',
    'подскажи',
    'подскажите',
    'скажи',
    'скажите',
    'расскажи',
    'расскажите',
    'объясни',
    'объясните',
    'подскажешь',
    'скажешь',
    'напомнишь',
    'знаешь',
  };

  /// Слова до и после просьбы, которые не меняют смысла: «нужен напомни
  /// пожалуйста», «а подскажи мне».
  static const Set<String> _skip = <String>{
    'мне',
    'нам',
    'пожалуйста',
    'пожалуйсто',
    'плиз',
    'пж',
    'пжлст',
    'а',
    'и',
    'ну',
    'слушай',
    'слушайте',
    'можешь',
    'можете',
    'ты',
    'вы',
    'еще',
    'раз',
    'ка',
  };

  /// Глаголы перевода: «переведи 5 миль в километры».
  static const Set<String> _convertVerbs = <String>{
    'переведи',
    'переведите',
    'конвертируй',
    'сконвертируй',
    'конвертни',
    'пересчитай',
  };

  /// Основы единиц длины, массы, объёма, температуры и валют.
  static const List<String> _unitStems = <String>[
    'километр', 'сантиметр', 'миллиметр', 'метр', 'дюйм', 'фут', 'ярд', //
    'килограмм', 'грамм', 'фунт', 'унци', 'литр', 'галлон', 'градус', //
    'цельси', 'фаренгейт', 'доллар', 'евро', 'рубл', 'юан', 'тенге', //
    'гривн', 'бакс', 'узл',
  ];

  static const Set<String> _unitWords = <String>{
    'миля',
    'мили',
    'миль',
    'милю',
    'миле',
    'милях',
    'милями',
    'км',
    'кг',
  };

  static bool _isUnit(String word) =>
      _unitWords.contains(word) || _unitStems.any(word.startsWith);

  /// «Переведи 5 миль в километры», «переведи доллары в рубли», «сколько
  /// метров в миле»: единица до «в/во» и единица после.
  static bool _unitsQuestion(List<String> words) {
    if (words.length < 3 || words.length > 10) return false;
    var start = 0;
    while (start < words.length && _skip.contains(words[start])) {
      start++;
    }
    if (start >= words.length) return false;
    final first = words[start];
    if (!_convertVerbs.contains(first) && first != 'сколько') return false;
    final into = words.indexWhere(
      (String w) => w == 'в' || w == 'во',
      start + 1,
    );
    if (into < 0 || into + 1 >= words.length) return false;
    final before = words.sublist(start + 1, into);
    final after = words.sublist(into + 1);
    if (!before.any(_isUnit) || !after.any(_isUnit)) return false;
    // «Сколько» — только «сколько метров в миле»: единица сразу после.
    if (first == 'сколько' && !_isUnit(words[start + 1])) return false;
    return true;
  }

  /// Вопросительные слова: «какой» и «чей», «который» во всех формах,
  /// «как», «где», «когда», «кто», «сколько», «почему», «зачем».
  static bool isWhWord(String word) =>
      _wh.contains(word) ||
      _kakForms.contains(word) ||
      _chejForms.contains(word) ||
      (word.startsWith('котор') && word.length <= 9);

  static const Set<String> _wh = <String>{
    'как',
    'где',
    'куда',
    'откуда',
    'когда',
    'кто',
    'кого',
    'кому',
    'кем',
    'сколько',
    'почему',
    'зачем',
    'отчего',
    'докуда',
  };

  static const Set<String> _kakForms = <String>{
    'какой',
    'какая',
    'какое',
    'какие',
    'какого',
    'какую',
    'каким',
    'какому',
    'каком',
    'каких',
    'какими',
  };

  static const Set<String> _chejForms = <String>{
    'чей',
    'чья',
    'чье',
    'чьи',
    'чьего',
    'чьей',
    'чью',
  };

  /// Слова после «что», с которыми это вопрос: «что за», «что такое»,
  /// «что значит», «что означает».
  static const Set<String> _whatQuestion = <String>{
    'за',
    'такое',
    'значит',
    'означает',
  };

  /// Слова после вопросительного слова, с которыми фраза без просьбы и
  /// «?» — не вопрос: «как же», «как только», «когда будет время».
  static const Set<String> _notQuestionAfter = <String>{
    'же',
    'только',
    'будто',
    'бы',
    'хорошо',
    'здорово',
    'классно',
    'жаль',
    'будет',
    'приду',
    'вернусь',
    'освобожусь',
  };

  static const Set<String> _aboutAssistant = <String>{
    'ты',
    'тебя',
    'тебе',
    'тобой',
    'вы',
    'вас',
    'вам',
    'вами',
  };

  /// Вопрос о том, что есть в самом приложении: «как поменять пароль»,
  /// «сколько у меня задач», «когда дедлайн по проекту». На него лучше
  /// подсказать команду, чем отвечать «справочника нет».
  static bool aboutApp(Utterance utterance) => utterance.tokens.any(
        (UtteranceToken t) => _appStems.any(t.text.startsWith),
      );

  static const List<String> _appStems = <String>[
    'парол',
    'задач',
    'напоминани',
    'проект',
    'дедлайн',
    'сейф',
    'статус',
    'копи',
    'будильник',
    'таймер',
    'файл',
    'погод',
    'помощник',
    'связн',
    'нод',
    'лиорио',
  ];

  static const Set<String> _subjects = <String>{
    'я',
    'мы',
    'ты',
    'он',
    'она',
    'они',
  };

  /// Окончания глагола в настоящем или будущем времени: «приду»,
  /// «приеду», «проснусь», «придет», «вернемся».
  static const List<String> _finiteEndings = <String>[
    'усь',
    'юсь',
    'ется',
    'ится',
    'емся',
    'имся',
    'ешь',
    'ишь',
    'ет',
    'ит',
    'ем',
    'им',
    'ут',
    'ют',
    'ат',
    'ят',
    'у',
    'ю',
  ];

  static bool _looksFinite(String word) =>
      word.length >= 4 &&
      !VerbForms.isInfinitive(word) &&
      _finiteEndings.any(word.endsWith);

  static bool _infinitiveAfter(List<UtteranceToken> tokens, int from) {
    for (var k = from; k < tokens.length; k++) {
      if (VerbForms.isInfinitive(tokens[k].text)) return true;
    }
    return false;
  }

  /// Вопрос в [utterance] или `null`. Срок между просьбой и вопросом не
  /// мешает: «напомни завтра в 9, какая формула суммы» — вопрос со сроком,
  /// его можно записать задачей «Узнать, какая формула суммы».
  static QuestionMatch? detect(Utterance utterance) {
    final tokens = utterance.tokens;
    if (tokens.isEmpty) return null;
    if (_unitsQuestion(utterance.words)) {
      return const QuestionMatch(
        kind: QuestionKind.units,
        opener: null,
        whIndex: 0,
      );
    }
    final due = utterance.due.spans;
    var i = SocialPrefix.length(utterance);
    bool skippable(UtteranceToken token) =>
        _skip.contains(token.text) ||
        SpeechNoise.isLeadFiller(token.text) ||
        Utterance.isCovered(token, due);
    while (i < tokens.length && skippable(tokens[i])) {
      i++;
    }
    if (i >= tokens.length) return null;
    String? opener;
    final first = tokens[i].text;
    if (first == 'не' &&
        i + 1 < tokens.length &&
        const <String>{'подскажешь', 'подскажете', 'напомнишь', 'скажешь'}
            .contains(tokens[i + 1].text)) {
      opener = tokens[i + 1].text;
      i += 2;
    } else if (openers.contains(first)) {
      opener = first;
      i++;
    }
    while (i < tokens.length && skippable(tokens[i])) {
      i++;
    }
    if (i >= tokens.length) return null;
    final word = tokens[i].text;
    final next = i + 1 < tokens.length ? tokens[i + 1].text : null;
    // «Как же я устал», «как только приду», «когда будет время»
    // без просьбы — восклицание или условие, а не вопрос.
    if (opener == null &&
        !utterance.isQuestion &&
        (next == null || _notQuestionAfter.contains(next))) {
      return null;
    }
    // «Как дела у проекта?», «кто ты такой», «как тебя создали» — о делах
    // и о самом помощнике, а не справочный вопрос.
    if (next != null &&
        (_aboutAssistant.contains(next) || (word == 'как' && next == 'дела'))) {
      return null;
    }
    // «Напомни, когда приду домой, купить хлеб», «напомни как только
    // проснусь выпить таблетку» — условие напоминания, а не вопрос: за
    // «когда/как» идёт глагол (или «только», «будет»), а дальше — дело.
    // «Напомни, как называется …» без дела после — вопрос.
    if ((opener == 'напомни' || opener == 'напомните') &&
        (word == 'когда' || word == 'как') &&
        next != null &&
        (_notQuestionAfter.contains(next) || _looksFinite(next)) &&
        _infinitiveAfter(tokens, i + 2)) {
      return null;
    }
    if (isWhWord(word) ||
        (word == 'что' && next != null && _whatQuestion.contains(next))) {
      return QuestionMatch(kind: QuestionKind.info, opener: opener, whIndex: i);
    }
    // «Напомни, что я хотел купить» — вспомнить за пользователя. «Напомни,
    // что я обещал позвонить маме завтра» со сроком — дело.
    if ((opener == 'напомни' || opener == 'напомните') &&
        word == 'что' &&
        utterance.due.dueAt == null &&
        i + 2 < tokens.length &&
        _subjects.contains(tokens[i + 1].text) &&
        VerbForms.isPastVerb(tokens[i + 2].text)) {
      return QuestionMatch(
        kind: QuestionKind.recall,
        opener: opener,
        whIndex: i,
      );
    }
    return null;
  }
}

/// Вопрос о времени или дате: «сколько времени?», «который час»,
/// «какой сегодня день недели», «какое сегодня число». Ответ — по часам
/// устройства.
enum ClockQuestion {
  time,
  date;

  static const Set<String> _lead = <String>{
    'а',
    'ну',
    'и',
    'слушай',
    'скажи',
    'скажите',
    'подскажи',
    'подскажите',
    'напомни',
    'напомните',
    'не',
    'подскажешь',
    'скажешь',
    'пожалуйста',
    'мне',
    'ка',
    'сейчас',
    'сегодня',
  };

  static const Set<String> _timePhrases = <String>{
    'сколько времени',
    'сколько время',
    'который час',
  };

  static const Set<String> _datePhrases = <String>{
    'какой день',
    'какой день недели',
    'какое число',
    'какое число и день недели',
    'какая дата',
  };

  static const List<String> weekdays = <String>[
    'понедельник',
    'вторник',
    'среда',
    'четверг',
    'пятница',
    'суббота',
    'воскресенье',
  ];

  static const List<String> months = <String>[
    'января',
    'февраля',
    'марта',
    'апреля',
    'мая',
    'июня',
    'июля',
    'августа',
    'сентября',
    'октября',
    'ноября',
    'декабря',
  ];

  /// Вопрос в [utterance] или `null`. «Сейчас», «сегодня» и вежливые слова
  /// по краям не мешают: «который сейчас час», «какой сегодня день».
  static ClockQuestion? of(Utterance utterance) {
    final words = <String>[
      for (final word in utterance.words)
        if (!_lead.contains(word) && word != 'пожалуйста') word,
    ];
    if (words.length < 2 || words.length > 6) return null;
    final phrase = words.join(' ');
    if (_timePhrases.contains(phrase)) return time;
    if (_datePhrases.contains(phrase)) return date;
    return null;
  }
}
