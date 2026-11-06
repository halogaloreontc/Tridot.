import '../../connectors/due_parser.dart';
import '../../replies/reply_catalog.dart';

/// О чём реплика беседы.
enum TalkTopic {
  /// «Привет», «добрый вечер».
  greet,

  /// «Пока», «до завтра», «спокойной ночи».
  bye,

  /// «Спасибо», «спс».
  thanks,

  /// «Как дела?» — ответ из настоящего состояния задач и коннекторов.
  howAreYou,

  /// «Кто ты», «как тебя зовут».
  whoAreYou,

  /// «Что ты умеешь», «помощь».
  capabilities,

  /// «Расскажи шутку», «каламбур».
  joke,

  /// «Ок», «понял», «круто», «👍».
  reaction,

  /// Грубость: спокойный ответ без нравоучений.
  rude,

  /// Просьба о стиле общения: «говори короче», «давай на ты».
  setting,
}

/// Время суток для приветствия.
enum DayPart {
  morning,
  day,
  evening,
  night;

  /// Время суток по часам: утро 4–11, день 12–17, вечер 18–22, ночь 23–3.
  static DayPart of(DateTime time) => switch (time.hour) {
        >= 4 && < 12 => morning,
        >= 12 && < 18 => day,
        >= 18 && < 23 => evening,
        _ => night,
      };

  /// Приветствие этого времени суток: «Добрый вечер».
  String get greeting => switch (this) {
        morning => 'Доброе утро',
        day => 'Добрый день',
        evening => 'Добрый вечер',
        night => 'Доброй ночи',
      };

  /// Соседние части суток не поправляются: «добрый день» в 18:30 — норма.
  /// Поправка нужна только через одну: «доброе утро» в 22:00.
  bool isFarFrom(DayPart other) => (index - other.index).abs() == 2;
}

/// Что именно просят поменять в стиле общения.
enum TalkSettingKind {
  /// Стиль общения ([TalkRequest.style]).
  style,

  /// «Давай на ты».
  informal,

  /// «Давай на вы».
  formal,

  /// «Без смайликов».
  emojiOff,

  /// «Можно со смайликами».
  emojiOn,

  /// «Шути меньше».
  jokesLess,

  /// «Шути больше».
  jokesMore,

  /// «Не шути».
  jokesOff,

  /// «Noda, будь основной», «пусть отвечает Рио».
  main,
}

/// Разобранная реплика беседы.
final class TalkRequest {
  const TalkRequest(
    this.topic, {
    this.saidPart,
    this.night = false,
    this.pun = false,
    this.setting,
    this.style,
    this.persona,
  });

  final TalkTopic topic;

  /// Какое время суток назвал пользователь в приветствии («доброе утро»).
  final DayPart? saidPart;

  /// «Спокойной ночи», «доброй ночи».
  final bool night;

  /// Просят именно каламбур.
  final bool pun;

  final TalkSettingKind? setting;

  /// Стиль для [TalkSettingKind.style]: id из [ReplyStyles].
  final String? style;

  /// Помощник, названный в просьбе («пусть отвечает Рио»): `rio`, `noda`.
  /// `null` — тот, кто отвечает.
  final String? persona;

  TalkRequest withPersona(String? id) => TalkRequest(
        topic,
        saidPart: saidPart,
        night: night,
        pun: pun,
        setting: setting,
        style: style,
        persona: id,
      );
}

/// Распознавание реплик беседы: только сообщение целиком, а не часть
/// команды. «Привет» — беседа, «привет, добавь задачу купить хлеб» —
/// задача; «пока» — прощание, «пока не забыл, купить хлеб» — задача.
abstract final class TalkPhrases {
  /// Длиннее — уже не короткая реплика беседы.
  static const int maxWords = 8;

  static final RegExp _word = RegExp('[a-zа-я0-9]+');

  /// Слова, которые ничего не меняют в реплике: «ну, спасибо»,
  /// «расскажи-ка мне шутку, пожалуйста».
  static const Set<String> _fillers = <String>{
    'пожалуйста',
    'пожалуйсто',
    'плиз',
    'пж',
    'ну',
    'эй',
    'же',
    'ка',
    'мне',
    'нам',
    'слушай',
    'слушайте',
    'тогда',
    'теперь',
    'уже',
    'вот',
    'а',
    'вообще',
  };

  /// Имена помощников: «привет, Нода», «пусть отвечает Рио».
  static const Map<String, String> _names = <String, String>{
    'rio': 'rio',
    'рио': 'rio',
    'noda': 'noda',
    'нода': 'noda',
  };

  /// Вместо имени в образцах просьб.
  static const String _nameSlot = '<имя>';

  static const Set<String> _rudeWords = <String>{
    'дурак',
    'дура',
    'дурачок',
    'тупой',
    'тупая',
    'тупица',
    'тупишь',
    'тупит',
    'идиот',
    'идиотка',
    'дебил',
    'кретин',
    'придурок',
    'глупый',
    'глупая',
    'бестолковый',
    'бестолковая',
    'бесполезный',
    'бесполезная',
    'заткнись',
    'отстань',
    'отвали',
    'бесишь',
    'достал',
    'достала',
    'задолбал',
    'задолбала',
    'лох',
    'отстой',
    'фигня',
  };

  /// Слова, которые бывают рядом с грубостью: «ты совсем тупой».
  static const Set<String> _rudeCompanions = <String>{
    'ты',
    'вы',
    'какой',
    'какая',
    'совсем',
    'такой',
    'такая',
    'очень',
    'просто',
    'полный',
    'полная',
    'бот',
    'ну',
    'и',
    'меня',
  };

  static const Map<String, TalkRequest> _phrases = <String, TalkRequest>{
    // Приветствия.
    'привет': TalkRequest(TalkTopic.greet),
    'приветик': TalkRequest(TalkTopic.greet),
    'привет привет': TalkRequest(TalkTopic.greet),
    'всем привет': TalkRequest(TalkTopic.greet),
    'приветствую': TalkRequest(TalkTopic.greet),
    'здравствуй': TalkRequest(TalkTopic.greet),
    'здравствуйте': TalkRequest(TalkTopic.greet),
    'здрасте': TalkRequest(TalkTopic.greet),
    'здрасьте': TalkRequest(TalkTopic.greet),
    'хай': TalkRequest(TalkTopic.greet),
    'йо': TalkRequest(TalkTopic.greet),
    'салют': TalkRequest(TalkTopic.greet),
    'hi': TalkRequest(TalkTopic.greet),
    'hello': TalkRequest(TalkTopic.greet),
    'hey': TalkRequest(TalkTopic.greet),
    'доброе утро': TalkRequest(TalkTopic.greet, saidPart: DayPart.morning),
    'доброго утра': TalkRequest(TalkTopic.greet, saidPart: DayPart.morning),
    'добрый день': TalkRequest(TalkTopic.greet, saidPart: DayPart.day),
    'доброго дня': TalkRequest(TalkTopic.greet, saidPart: DayPart.day),
    'добрый вечер': TalkRequest(TalkTopic.greet, saidPart: DayPart.evening),
    'доброго вечера': TalkRequest(TalkTopic.greet, saidPart: DayPart.evening),

    // Прощания.
    'пока': TalkRequest(TalkTopic.bye),
    'пока пока': TalkRequest(TalkTopic.bye),
    'до завтра': TalkRequest(TalkTopic.bye),
    'до свидания': TalkRequest(TalkTopic.bye),
    'до встречи': TalkRequest(TalkTopic.bye),
    'до скорого': TalkRequest(TalkTopic.bye),
    'до связи': TalkRequest(TalkTopic.bye),
    'увидимся': TalkRequest(TalkTopic.bye),
    'бывай': TalkRequest(TalkTopic.bye),
    'прощай': TalkRequest(TalkTopic.bye),
    'всего доброго': TalkRequest(TalkTopic.bye),
    'всего хорошего': TalkRequest(TalkTopic.bye),
    'пора': TalkRequest(TalkTopic.bye),
    'все пока': TalkRequest(TalkTopic.bye),
    'чао': TalkRequest(TalkTopic.bye),
    'bye': TalkRequest(TalkTopic.bye),
    'спокойной ночи': TalkRequest(TalkTopic.bye, night: true),
    'доброй ночи': TalkRequest(TalkTopic.bye, night: true),

    // Благодарность.
    'спасибо': TalkRequest(TalkTopic.thanks),
    'спс': TalkRequest(TalkTopic.thanks),
    'спасибочки': TalkRequest(TalkTopic.thanks),
    'спасибки': TalkRequest(TalkTopic.thanks),
    'благодарю': TalkRequest(TalkTopic.thanks),
    'благодарю тебя': TalkRequest(TalkTopic.thanks),
    'благодарю вас': TalkRequest(TalkTopic.thanks),
    'спасибо большое': TalkRequest(TalkTopic.thanks),
    'большое спасибо': TalkRequest(TalkTopic.thanks),
    'спасибо огромное': TalkRequest(TalkTopic.thanks),
    'огромное спасибо': TalkRequest(TalkTopic.thanks),
    'спасибо тебе': TalkRequest(TalkTopic.thanks),
    'спасибо вам': TalkRequest(TalkTopic.thanks),
    'спасибо за помощь': TalkRequest(TalkTopic.thanks),
    'все спасибо': TalkRequest(TalkTopic.thanks),
    'мерси': TalkRequest(TalkTopic.thanks),
    'thanks': TalkRequest(TalkTopic.thanks),
    'thank you': TalkRequest(TalkTopic.thanks),

    // «Как дела?»
    'как дела': TalkRequest(TalkTopic.howAreYou),
    'как твои дела': TalkRequest(TalkTopic.howAreYou),
    'как ваши дела': TalkRequest(TalkTopic.howAreYou),
    'как у тебя дела': TalkRequest(TalkTopic.howAreYou),
    'как у вас дела': TalkRequest(TalkTopic.howAreYou),
    'как дела у тебя': TalkRequest(TalkTopic.howAreYou),
    'как дела у вас': TalkRequest(TalkTopic.howAreYou),
    'как ты': TalkRequest(TalkTopic.howAreYou),
    'ты как': TalkRequest(TalkTopic.howAreYou),
    'как ты там': TalkRequest(TalkTopic.howAreYou),
    'как вы': TalkRequest(TalkTopic.howAreYou),
    'как жизнь': TalkRequest(TalkTopic.howAreYou),
    'как поживаешь': TalkRequest(TalkTopic.howAreYou),
    'как поживаете': TalkRequest(TalkTopic.howAreYou),
    'как сам': TalkRequest(TalkTopic.howAreYou),
    'как сама': TalkRequest(TalkTopic.howAreYou),
    'как настроение': TalkRequest(TalkTopic.howAreYou),
    'как оно': TalkRequest(TalkTopic.howAreYou),
    'все в порядке': TalkRequest(TalkTopic.howAreYou),
    'все ли в порядке': TalkRequest(TalkTopic.howAreYou),
    'все работает': TalkRequest(TalkTopic.howAreYou),

    // «Кто ты?»
    'кто ты': TalkRequest(TalkTopic.whoAreYou),
    'ты кто': TalkRequest(TalkTopic.whoAreYou),
    'кто вы': TalkRequest(TalkTopic.whoAreYou),
    'вы кто': TalkRequest(TalkTopic.whoAreYou),
    'кто ты такой': TalkRequest(TalkTopic.whoAreYou),
    'кто ты такая': TalkRequest(TalkTopic.whoAreYou),
    'ты кто такой': TalkRequest(TalkTopic.whoAreYou),
    'ты кто такая': TalkRequest(TalkTopic.whoAreYou),
    'как тебя зовут': TalkRequest(TalkTopic.whoAreYou),
    'как вас зовут': TalkRequest(TalkTopic.whoAreYou),
    'как твое имя': TalkRequest(TalkTopic.whoAreYou),
    'как ваше имя': TalkRequest(TalkTopic.whoAreYou),
    'представься': TalkRequest(TalkTopic.whoAreYou),
    'представьтесь': TalkRequest(TalkTopic.whoAreYou),
    'с кем я говорю': TalkRequest(TalkTopic.whoAreYou),

    // «Что умеешь?»
    'что ты умеешь': TalkRequest(TalkTopic.capabilities),
    'что умеешь': TalkRequest(TalkTopic.capabilities),
    'что ты умеешь делать': TalkRequest(TalkTopic.capabilities),
    'что вы умеете': TalkRequest(TalkTopic.capabilities),
    'что умеете': TalkRequest(TalkTopic.capabilities),
    'что ты можешь': TalkRequest(TalkTopic.capabilities),
    'что можешь': TalkRequest(TalkTopic.capabilities),
    'что вы можете': TalkRequest(TalkTopic.capabilities),
    'чем ты можешь помочь': TalkRequest(TalkTopic.capabilities),
    'чем можешь помочь': TalkRequest(TalkTopic.capabilities),
    'чем можете помочь': TalkRequest(TalkTopic.capabilities),
    'помощь': TalkRequest(TalkTopic.capabilities),
    'помоги': TalkRequest(TalkTopic.capabilities),
    'справка': TalkRequest(TalkTopic.capabilities),
    'help': TalkRequest(TalkTopic.capabilities),
    'какие есть команды': TalkRequest(TalkTopic.capabilities),
    'какие команды': TalkRequest(TalkTopic.capabilities),

    // Шутки и каламбуры.
    'расскажи шутку': TalkRequest(TalkTopic.joke),
    'скажи шутку': TalkRequest(TalkTopic.joke),
    'давай шутку': TalkRequest(TalkTopic.joke),
    'хочу шутку': TalkRequest(TalkTopic.joke),
    'шутку': TalkRequest(TalkTopic.joke),
    'шутка': TalkRequest(TalkTopic.joke),
    'пошути': TalkRequest(TalkTopic.joke),
    'пошути еще': TalkRequest(TalkTopic.joke),
    'еще пошути': TalkRequest(TalkTopic.joke),
    'еще шутку': TalkRequest(TalkTopic.joke),
    'еще одну шутку': TalkRequest(TalkTopic.joke),
    'расскажи еще шутку': TalkRequest(TalkTopic.joke),
    'анекдот': TalkRequest(TalkTopic.joke),
    'расскажи анекдот': TalkRequest(TalkTopic.joke),
    'давай анекдот': TalkRequest(TalkTopic.joke),
    'еще анекдот': TalkRequest(TalkTopic.joke),
    'рассмеши': TalkRequest(TalkTopic.joke),
    'рассмеши меня': TalkRequest(TalkTopic.joke),
    'расскажи что нибудь смешное': TalkRequest(TalkTopic.joke),
    'каламбур': TalkRequest(TalkTopic.joke, pun: true),
    'скажи каламбур': TalkRequest(TalkTopic.joke, pun: true),
    'расскажи каламбур': TalkRequest(TalkTopic.joke, pun: true),
    'давай каламбур': TalkRequest(TalkTopic.joke, pun: true),
    'еще каламбур': TalkRequest(TalkTopic.joke, pun: true),
    'скаламбурь': TalkRequest(TalkTopic.joke, pun: true),

    // Короткие отклики.
    'ок': TalkRequest(TalkTopic.reaction),
    'окей': TalkRequest(TalkTopic.reaction),
    'ok': TalkRequest(TalkTopic.reaction),
    'okay': TalkRequest(TalkTopic.reaction),
    'понял': TalkRequest(TalkTopic.reaction),
    'поняла': TalkRequest(TalkTopic.reaction),
    'понятно': TalkRequest(TalkTopic.reaction),
    'ясно': TalkRequest(TalkTopic.reaction),
    'ясненько': TalkRequest(TalkTopic.reaction),
    'круто': TalkRequest(TalkTopic.reaction),
    'класс': TalkRequest(TalkTopic.reaction),
    'классно': TalkRequest(TalkTopic.reaction),
    'супер': TalkRequest(TalkTopic.reaction),
    'отлично': TalkRequest(TalkTopic.reaction),
    'хорошо': TalkRequest(TalkTopic.reaction),
    'ладно': TalkRequest(TalkTopic.reaction),
    'здорово': TalkRequest(TalkTopic.reaction),
    'прикольно': TalkRequest(TalkTopic.reaction),
    'норм': TalkRequest(TalkTopic.reaction),
    'нормально': TalkRequest(TalkTopic.reaction),
    'замечательно': TalkRequest(TalkTopic.reaction),
    'прекрасно': TalkRequest(TalkTopic.reaction),
    'ура': TalkRequest(TalkTopic.reaction),
    'вау': TalkRequest(TalkTopic.reaction),
    'ага': TalkRequest(TalkTopic.reaction),
    'угу': TalkRequest(TalkTopic.reaction),
    'cool': TalkRequest(TalkTopic.reaction),
    'nice': TalkRequest(TalkTopic.reaction),

    // Стиль общения.
    'говори короче': _brief,
    'говори кратко': _brief,
    'говори покороче': _brief,
    'отвечай короче': _brief,
    'отвечай кратко': _brief,
    'отвечай покороче': _brief,
    'давай короче': _brief,
    'давай покороче': _brief,
    'покороче': _brief,
    'будь краток': _brief,
    'будь кратка': _brief,
    'говори подробнее': _neutral,
    'говори нормально': _neutral,
    'говори как обычно': _neutral,
    'отвечай подробнее': _neutral,
    'отвечай нормально': _neutral,
    'давай подробнее': _neutral,
    'давай нормально': _neutral,
    'подробнее': _neutral,
    'давай дружелюбнее': _friendly,
    'давай повеселее': _friendly,
    'давай веселее': _friendly,
    'будь дружелюбнее': _friendly,
    'будь повеселее': _friendly,
    'говори дружелюбнее': _friendly,
    'говори повеселее': _friendly,
    'повеселее': _friendly,
    'дружелюбнее': _friendly,
    'говори официально': _business,
    'говори официальнее': _business,
    'говори по деловому': _business,
    'давай официально': _business,
    'давай по деловому': _business,
    'будь официальнее': _business,
    'отвечай официально': _business,
    'отвечай по деловому': _business,
    'официально': _business,
    'по деловому': _business,
    'давай на ты': _informal,
    'на ты': _informal,
    'можно на ты': _informal,
    'говори на ты': _informal,
    'обращайся на ты': _informal,
    'перейдем на ты': _informal,
    'давай перейдем на ты': _informal,
    'давай на вы': _formal,
    'на вы': _formal,
    'можно на вы': _formal,
    'говори на вы': _formal,
    'обращайся на вы': _formal,
    'перейдем на вы': _formal,
    'давай перейдем на вы': _formal,
    'без смайликов': _emojiOff,
    'без смайлов': _emojiOff,
    'без эмодзи': _emojiOff,
    'можно без эмодзи': _emojiOff,
    'давай без эмодзи': _emojiOff,
    'не надо эмодзи': _emojiOff,
    'убери эмодзи': _emojiOff,
    'давай без смайликов': _emojiOff,
    'можно без смайликов': _emojiOff,
    'не надо смайликов': _emojiOff,
    'хватит смайликов': _emojiOff,
    'убери смайлики': _emojiOff,
    'не используй смайлики': _emojiOff,
    'можно со смайликами': _emojiOn,
    'со смайликами': _emojiOn,
    'давай со смайликами': _emojiOn,
    'можно смайлики': _emojiOn,
    'верни смайлики': _emojiOn,
    'используй смайлики': _emojiOn,
    'с эмодзи': _emojiOn,
    'можно с эмодзи': _emojiOn,
    'шути меньше': _jokesLess,
    'шути поменьше': _jokesLess,
    'шути реже': _jokesLess,
    'меньше шуток': _jokesLess,
    'поменьше шуток': _jokesLess,
    'шути больше': _jokesMore,
    'шути побольше': _jokesMore,
    'шути чаще': _jokesMore,
    'больше шуток': _jokesMore,
    'побольше шуток': _jokesMore,
    'не шути': _jokesOff,
    'не шути больше': _jokesOff,
    'больше не шути': _jokesOff,
    'хватит шутить': _jokesOff,
    'перестань шутить': _jokesOff,
    'без шуток': _jokesOff,
    'давай без шуток': _jokesOff,
    'не надо шуток': _jokesOff,
    'не надо шутить': _jokesOff,
    'будь основной': _main,
    'будь основным': _main,
    'будь главной': _main,
    'будь главным': _main,
    'отвечай ты': _main,
    '<имя> будь основной': _main,
    '<имя> будь основным': _main,
    'пусть отвечает <имя>': _main,
    'пусть <имя> отвечает': _main,
    'пусть <имя> будет основной': _main,
    'пусть <имя> будет основным': _main,
    'пусть основной будет <имя>': _main,
    'пусть основным будет <имя>': _main,
    'пусть основной будет': _main,
    'отвечает <имя>': _main,
    'основной <имя>': _main,
    'основная <имя>': _main,
  };

  static const TalkRequest _brief = TalkRequest(
    TalkTopic.setting,
    setting: TalkSettingKind.style,
    style: ReplyStyles.brief,
  );
  static const TalkRequest _neutral = TalkRequest(
    TalkTopic.setting,
    setting: TalkSettingKind.style,
    style: ReplyStyles.neutral,
  );
  static const TalkRequest _friendly = TalkRequest(
    TalkTopic.setting,
    setting: TalkSettingKind.style,
    style: ReplyStyles.friendly,
  );
  static const TalkRequest _business = TalkRequest(
    TalkTopic.setting,
    setting: TalkSettingKind.style,
    style: ReplyStyles.business,
  );
  static const TalkRequest _informal =
      TalkRequest(TalkTopic.setting, setting: TalkSettingKind.informal);
  static const TalkRequest _formal =
      TalkRequest(TalkTopic.setting, setting: TalkSettingKind.formal);
  static const TalkRequest _emojiOff =
      TalkRequest(TalkTopic.setting, setting: TalkSettingKind.emojiOff);
  static const TalkRequest _emojiOn =
      TalkRequest(TalkTopic.setting, setting: TalkSettingKind.emojiOn);
  static const TalkRequest _jokesLess =
      TalkRequest(TalkTopic.setting, setting: TalkSettingKind.jokesLess);
  static const TalkRequest _jokesMore =
      TalkRequest(TalkTopic.setting, setting: TalkSettingKind.jokesMore);
  static const TalkRequest _jokesOff =
      TalkRequest(TalkTopic.setting, setting: TalkSettingKind.jokesOff);
  static const TalkRequest _main =
      TalkRequest(TalkTopic.setting, setting: TalkSettingKind.main);

  /// Эмодзи без слов: «👍» — отклик, «👋» — приветствие.
  static const Map<String, TalkTopic> _symbols = <String, TalkTopic>{
    '👍': TalkTopic.reaction,
    '👌': TalkTopic.reaction,
    '🙂': TalkTopic.reaction,
    '😊': TalkTopic.reaction,
    '😀': TalkTopic.reaction,
    '😄': TalkTopic.reaction,
    '🔥': TalkTopic.reaction,
    '👋': TalkTopic.greet,
    '🙏': TalkTopic.thanks,
  };

  static final RegExp _ignoredSymbols = RegExp(
    '[\\s\u{FE0F}\u{200D}\u{1F3FB}-\u{1F3FF}!.,…?]',
    unicode: true,
  );

  /// Вступления, после которых может идти другая реплика беседы:
  /// «привет, как дела?», «добрый вечер, что ты умеешь», «спасибо, пока»,
  /// «привет, говори короче», «спасибо, дурак». Длинные — первыми.
  static const List<String> _prefixes = <String>[
    'спасибо большое',
    'большое спасибо',
    'доброе утро',
    'добрый день',
    'добрый вечер',
    'всем привет',
    'привет',
    'приветик',
    'приветствую',
    'здравствуй',
    'здравствуйте',
    'хай',
    'йо',
    'спасибо',
    'спс',
    'благодарю',
  ];

  /// Связка между вступлением и репликой: «спасибо и пока».
  static const Set<String> _joiners = <String>{'и', 'а', 'ну'};

  /// Реплика беседы или `null`, если сообщение — не беседа целиком.
  ///
  /// Сравнивается всё сообщение: после слов-паразитов («ну»,
  /// «пожалуйста») и имён помощников ничего лишнего остаться не должно.
  /// Имя помощника где угодно в реплике («спасибо, Нода») попадает в
  /// [TalkRequest.persona]: в дуэте отвечает названный.
  static TalkRequest? recognize(String text) {
    final normalized = DueParser.normalizeChars(text);
    final words = <String>[
      for (final match in _word.allMatches(normalized)) match.group(0)!,
    ];
    if (words.isEmpty) {
      final symbols = text.replaceAll(_ignoredSymbols, '');
      final topic = _symbols[symbols];
      return topic == null ? null : TalkRequest(topic);
    }
    if (words.length > maxWords) return null;
    // Цифры — уже не беседа: «ок 15:00», «спасибо 2».
    if (words.any((String w) => RegExp(r'\d').hasMatch(w))) return null;
    final whole = _recognizeWords(words);
    if (whole != null) return whole;
    // «Привет, говори короче», «спасибо, пока», «спасибо и пока»: после
    // вступления — другая реплика, она и важнее.
    for (final prefix in _prefixes) {
      final prefixWords = prefix.split(' ');
      var start = _skipNames(words, 0);
      if (!_startsWith(words, prefixWords, start)) continue;
      start = _skipNames(words, start + prefixWords.length);
      while (start < words.length && _joiners.contains(words[start])) {
        start++;
      }
      if (start >= words.length) continue;
      final named = <String>{
        for (final word in words.take(start))
          if (_names[word] case final String id) id,
      };
      final rest = _recognizeWords(words.sublist(start));
      if (rest == null) continue;
      if (named.length > 1 ||
          (named.isNotEmpty &&
              rest.persona != null &&
              rest.persona != named.first)) {
        return null;
      }
      return rest.persona == null && named.isNotEmpty
          ? rest.withPersona(named.first)
          : rest;
    }
    return null;
  }

  static int _skipNames(List<String> words, int from) {
    var i = from;
    while (i < words.length &&
        (_names.containsKey(words[i]) || _fillers.contains(words[i]))) {
      i++;
    }
    return i;
  }

  static bool _startsWith(List<String> words, List<String> prefix, int at) {
    if (words.length - at < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (words[at + i] != prefix[i]) return false;
    }
    return true;
  }

  /// Реплика целиком: грубость, фраза из [_phrases] после слов-паразитов,
  /// с именем помощника на месте `<имя>` или без него.
  static TalkRequest? _recognizeWords(List<String> words) {
    String? persona;
    for (final word in words) {
      final name = _names[word];
      if (name == null) continue;
      if (persona != null && persona != name) return null;
      persona = name;
    }
    if (_isRude(words)) return TalkRequest(TalkTopic.rude, persona: persona);
    final kept = <String>[
      for (final word in words)
        if (_names.containsKey(word))
          _nameSlot
        else if (!_fillers.contains(word))
          word,
    ];
    if (kept.isEmpty) return null;
    final withName = _phrases[kept.join(' ')];
    if (withName != null) return withName.withPersona(persona);
    if (persona == null) return null;
    // Имя как обращение где угодно, кроме образцов просьб: «привет, Нода».
    final plain = kept.where((String w) => w != _nameSlot).join(' ');
    if (plain.isEmpty) return null;
    return _phrases[plain]?.withPersona(persona);
  }

  static bool _isRude(List<String> words) =>
      words.length <= 5 &&
      words.any(_rudeWords.contains) &&
      words.every(
        (String w) =>
            _rudeWords.contains(w) ||
            _rudeCompanions.contains(w) ||
            _names.containsKey(w),
      );
}
