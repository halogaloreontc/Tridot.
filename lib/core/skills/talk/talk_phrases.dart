import '../../connectors/due_parser.dart';
import '../../personas/persona.dart';
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

  /// «Noda, будь основной», «пусть отвечает Лиорио».
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

  /// Помощник, названный в просьбе («пусть отвечает Лио»): `rio`, `noda`.
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
    'плз',
    'пжлст',
    'пожалуста',
    'pls',
    'plz',
    'please',
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

  /// Имена для обращения → id: «привет, Нода», «пусть отвечает Лио»
  /// ([Persona.addressNames]). Годятся где угодно в реплике.
  static final Map<String, String> _names = <String, String>{
    for (final persona in Personas.all)
      for (final form in persona.addressNames) form: persona.id,
  };

  /// Косвенные падежи имён → id: «сделай Ноду основной»
  /// ([Persona.inflectedForms]). Только на месте `<имя>` в образцах
  /// просьб: «привет Ноду» — не обращение и не беседа.
  static final Map<String, String> _inflectedNames = <String, String>{
    for (final persona in Personas.all)
      for (final form in persona.inflectedForms) form: persona.id,
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
    // «Ты основной?» — вопрос, а не просьба: ответ «кто ты» говорит, кто
    // из помощников основной.
    'ты основной': TalkRequest(TalkTopic.whoAreYou),
    'ты основная': TalkRequest(TalkTopic.whoAreYou),
    'ты главный': TalkRequest(TalkTopic.whoAreYou),
    'ты главная': TalkRequest(TalkTopic.whoAreYou),
    'кто основной': TalkRequest(TalkTopic.whoAreYou),
    'кто главный': TalkRequest(TalkTopic.whoAreYou),
    'кто из вас основной': TalkRequest(TalkTopic.whoAreYou),
    'кто из вас главный': TalkRequest(TalkTopic.whoAreYou),

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
    'joke': TalkRequest(TalkTopic.joke),
    'a joke': TalkRequest(TalkTopic.joke),
    'tell me a joke': TalkRequest(TalkTopic.joke),
    'tell a joke': TalkRequest(TalkTopic.joke),
    'tell me a pun': TalkRequest(TalkTopic.joke, pun: true),
    'make me laugh': TalkRequest(TalkTopic.joke),
    'another joke': TalkRequest(TalkTopic.joke),
    'one more joke': TalkRequest(TalkTopic.joke),

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
    'очень прикольно': TalkRequest(TalkTopic.reaction),
    'это прикольно': TalkRequest(TalkTopic.reaction),
    'ок прикольно': TalkRequest(TalkTopic.reaction),
    'это прикол': TalkRequest(TalkTopic.reaction),
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
    'сделай <имя> основной': _main,
    'сделай <имя> основным': _main,
    'сделай основной <имя>': _main,
    'сделай основным <имя>': _main,
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
    var inflected = false;
    for (final word in words) {
      final name = _names[word] ?? _inflectedNames[word];
      if (name == null) continue;
      if (persona != null && persona != name) return null;
      persona = name;
      if (!_names.containsKey(word)) inflected = true;
    }
    if (!inflected && _isRude(words)) {
      return TalkRequest(TalkTopic.rude, persona: persona);
    }
    final kept = <String>[
      for (final word in words)
        if (_names.containsKey(word) || _inflectedNames.containsKey(word))
          _nameSlot
        else if (!_fillers.contains(word))
          word,
    ];
    if (kept.isEmpty) return null;
    final withName = _phrases[kept.join(' ')];
    if (withName != null) return withName.withPersona(persona);
    // «Пусть теперь всё говорит Нода»: имя — часть просьбы, а не обращение.
    if (_isMainRequest(kept)) return _main.withPersona(persona);
    // Косвенный падеж — только в образце просьбы: «привет Ноду» — мимо.
    if (inflected) return null;
    // Имя как обращение где угодно, кроме образцов просьб: «привет, Нода».
    final plain = <String>[
      for (final word in kept)
        if (word != _nameSlot) word,
    ];
    if (plain.isEmpty) return null;
    final request = (persona == null ? null : _phrases[plain.join(' ')]) ??
        _settingRequest(plain) ??
        _jokeRequest(plain);
    return request?.withPersona(persona);
  }

  // ------------------------------------------------ просьбы своими словами
  //
  // Кроме точных фраз [_phrases] беседа понимает просьбы о шутке и о стиле,
  // сказанные своими словами: «расскажи анекдот про кошку», «аха, ну давай
  // ещё анекдотик», «пошути, а то скучно», «убери эмодзи из ответов»,
  // «меньше воды, пиши по сути». Правило одно для всех: в реплике есть
  // ядро просьбы (слово о шутке, «пошути», «ещё одну», слово о стиле), а
  // все остальные слова — из короткого словаря болтовни вокруг неё. Любое
  // чужое слово («добавь задачу рассказать шутку», «расскажи шутку на
  // корпоративе») — и реплика уже не беседа: её разбирают другие навыки.

  /// Слова-ядра просьбы о шутке: основа и её окончания — «шутку»,
  /// «шуточку», «анекдотик», «каламбур», «прикол», «приколись», «юмор»,
  /// «юморни», «хохму». Только формы существительного и глагола-просьбы:
  /// «прикольно», «прикольный», «юмористично», «юморист» — оценки, а не
  /// просьба о шутке.
  static const Map<String, Set<String>> _jokeStems = <String, Set<String>>{
    'шутк': <String>{'а', 'у', 'и', 'ой', 'е'},
    'шуточк': <String>{'а', 'у', 'и', 'ой', 'е'},
    'шутеечк': <String>{'а', 'у', 'и', 'ой', 'е'},
    'анекдот': _nounEndings,
    'каламбур': _nounEndings,
    'скаламбур': <String>{'ь', 'ьте'},
    'прикол': <String>{..._nounEndings, 'ись', 'итесь', 'ни', 'ните'},
    'юмор': <String>{'', 'а', 'у', 'ом', 'ни', 'ните', 'ну', 'нуть'},
    'хохм': <String>{'а', 'у', 'ы', 'ой', 'очку', 'очка', 'ни'},
  };

  /// Окончания существительных-ядер: «анекдот», «анекдота», «анекдотик»,
  /// «анекдотиков», «приколы», «приколом».
  static const Set<String> _nounEndings = <String>{
    '', 'а', 'у', 'ы', 'ов', 'ом', 'е', 'ик', 'ика', 'ику', 'ики', //
    'иков', 'чик', 'чика', 'чику',
  };

  /// Именительный падеж слова-ядра после «это» — не просьба, а оценка
  /// сказанного: «это шутка», «это прикол», «это анекдот».
  static const Set<String> _jokeNominatives = <String>{
    'шутка',
    'шуточка',
    'шутеечка',
    'анекдот',
    'анекдотик',
    'каламбур',
    'прикол',
    'приколы',
    'юмор',
    'хохма',
  };

  /// Оценки шутки: «тупая шутка», «смешной». Одна оценка — отклик на
  /// прошлую шутку; просьба о новой — только со словом просьбы рядом:
  /// «ну и тупая шутка, давай нормальную».
  static const Set<String> _jokeVerdicts = <String>{
    'тупая', 'тупой', 'дурацкая', 'дурацкий', 'несмешная', 'несмешной', //
    'смешная', 'смешной',
  };

  /// Слова просьбы: без них реплика с оценкой шутки — не просьба.
  static const Set<String> _jokeAsks = <String>{
    'расскажи',
    'расскажите',
    'рассказывай',
    'скажи',
    'скажите',
    'давай',
    'давайте',
    'хочу',
    'хочется',
    'придумай',
    'придумайте',
    'покажи',
    'подкинь',
    'выдай',
    'неси',
    'гони',
    'знаешь',
    'знаете',
    'есть',
    'будет',
    'можно',
    'где',
    'жду',
    'нужна',
    'нужен',
    'нужно',
    'еще',
    'новую',
    'другую',
    'нормальную',
  };

  /// «Что-нибудь смешное» в родительном падеже — только с «нибудь»:
  /// «чего-нибудь смешного»; «что смешного?» — обида, а не просьба.
  static const Set<String> _funnyGenitives = <String>{
    'смешного',
    'смешненького',
    'забавного',
    'веселенького',
  };

  /// «Что-нибудь смешное»: смешное вместо слова «шутка».
  static const Set<String> _funnyWords = <String>{
    'смешное',
    'смешного',
    'смешненькое',
    'смешненького',
    'забавное',
    'забавного',
    'веселенькое',
    'веселенького',
  };

  /// Глаголы, которые сами просят шутку: «пошути», «повесели меня»,
  /// «развлеки», «хочу посмеяться», «давай поржать».
  static const Set<String> _jokeVerbs = <String>{
    'пошути',
    'пошутите',
    'пошуткуй',
    'посмеши',
    'посмешите',
    'насмеши',
    'насмешите',
    'рассмеши',
    'рассмешите',
    'повесели',
    'повеселите',
    'развесели',
    'развеселите',
    'развлеки',
    'развлеките',
    'поржать',
    'посмеяться',
    'похохмить',
    'похохми',
  };

  /// После «ещё» — ещё одна шутка: «ещё один», «а можно ещё одну?»,
  /// «ну давай ещё».
  static const Set<String> _moreWords = <String>{
    'один',
    'одну',
    'одна',
    'разок',
    'давай',
    'давайте',
    'можно',
  };

  /// Слова вокруг просьбы о шутке: сама просьба («расскажи», «давай»,
  /// «можно», «знаешь»), уточнения («какую-нибудь», «ещё одну»,
  /// «нормальную», «но короче», «без матов»), причины и оценки («а то
  /// скучно», «я скучаю», «ты смешной», «тупая шутка»), вызов («если ты
  /// вообще на это способен»).
  static const Set<String> _jokeContext = <String>{
    // Просьба.
    'расскажи', 'расскажите', 'рассказывай', 'скажи', 'скажите', 'давай',
    'давайте', 'хочу', 'хочется', 'придумай', 'придумайте', 'покажи',
    'подкинь', 'выдай', 'неси', 'гони', 'знаешь', 'знаете', 'есть',
    'будет', 'можно', 'где', 'жду', 'нужна', 'нужен', 'нужно', 'бы',
    // Уточнения.
    'какой', 'какую', 'какая', 'какое', 'какие', 'что', 'чего', 'чем',
    'нибудь', 'то', 'еще', 'один', 'одну', 'одна', 'разок', 'новую',
    'новый', 'новенькую', 'другую', 'другой', 'нормальную', 'нормальный',
    'хорошую', 'хороший', 'смешную', 'смешнее', 'посмешнее', 'свежую',
    'свежий', 'лучшую', 'твой', 'твоя', 'твое', 'твои', 'мой', 'моя',
    'мою', 'свой', 'свою', 'у', 'тебя', 'вас', 'меня', 'для', 'на',
    'сегодня', 'и', 'или', 'ок', 'окей', 'ладно', 'но', 'только',
    'короче', 'покороче', 'коротко', 'без', 'матов', 'мата', 'пошлостей',
    'два', 'три', 'предложения', 'слова',
    // Причины, оценки, вызов.
    'ты', 'смешной', 'смешная', 'тупая', 'тупой', 'дурацкая',
    'несмешная', 'скучно', 'скучаю', 'заскучал', 'заскучала', 'грустно',
    'капец', 'я', 'очень', 'так', 'если', 'это', 'способен', 'способна',
    'умеешь', 'можешь',
  };

  /// Смех вокруг просьбы: «ахаха», «хехе», «аха», «лол».
  static final RegExp _laughter =
      RegExp(r'^(?:а?(?:ха|хе|хи)+х?|ах+|хех|лол|ржу|ржака)$');

  /// Отказ от шуток — не просьба о шутке: «не надо шуток», «хватит».
  static const Set<String> _jokeRefusal = <String>{
    'не',
    'нет',
    'хватит',
    'перестань',
    'перестаньте',
    'прекрати',
    'прекратите',
  };

  /// «Про кошку», «о программистах»: тема шутки — не больше двух слов.
  static const Set<String> _about = <String>{'про', 'о', 'об'};

  static const int _maxTopicWords = 2;

  static bool _isJokeWord(String word) {
    for (final MapEntry(key: stem, value: endings) in _jokeStems.entries) {
      if (word.startsWith(stem) &&
          endings.contains(word.substring(stem.length))) {
        return true;
      }
    }
    return false;
  }

  /// Просьба о шутке своими словами или `null`.
  static TalkRequest? _jokeRequest(List<String> words) {
    if (words.any(_jokeRefusal.contains)) return null;
    // «Шутки шутками, а …» — присказка, а не просьба.
    if (words.contains('шутки') && words.contains('шутками')) return null;
    for (var i = 0; i + 1 < words.length; i++) {
      if (words[i] == 'это' && _jokeNominatives.contains(words[i + 1])) {
        return null;
      }
    }
    if (words.any(_jokeVerdicts.contains) &&
        !words.any(
          (String w) =>
              _jokeAsks.contains(w) ||
              _jokeVerbs.contains(w) ||
              (_isJokeWord(w) && !_jokeNominatives.contains(w)),
        )) {
      return null;
    }
    var core = false;
    var pun = false;
    for (var i = 0; i < words.length; i++) {
      final word = words[i];
      if (_funnyGenitives.contains(word) && !words.contains('нибудь')) {
        return null;
      }
      if (_isJokeWord(word) ||
          _funnyWords.contains(word) ||
          _jokeVerbs.contains(word)) {
        core = true;
        if (word.contains('каламбур')) pun = true;
        continue;
      }
      if (word == 'еще' &&
          words.any((String w) => w != word && _moreWords.contains(w))) {
        core = true;
        continue;
      }
      if (_about.contains(word)) {
        // Тема — первое слово после «про» («каламбур про слова») и ещё
        // одно, если это не слово болтовни: «анекдот про чёрного кота»,
        // «анекдот про кошку, пожалуйста».
        if (i + 1 >= words.length) return null;
        i++;
        var topic = 1;
        while (i + 1 < words.length &&
            topic < _maxTopicWords &&
            !_jokeContext.contains(words[i + 1])) {
          i++;
          topic++;
        }
        continue;
      }
      if (_jokeContext.contains(word) || _laughter.hasMatch(word)) continue;
      return null;
    }
    if (!core) return null;
    return TalkRequest(TalkTopic.joke, pun: pun);
  }

  /// Шутки как настройка: «шутки больше не надо», «хватит столько
  /// шутить», «пошути побольше», «каламбуры только по праздникам».
  static const Set<String> _jokesLessCues = <String>{
    'меньше',
    'поменьше',
    'реже',
    'пореже',
    'столько',
    'иногда',
    'изредка',
    'праздникам',
  };

  static const Set<String> _jokesOffCues = <String>{
    'не',
    'хватит',
    'перестань',
    'перестаньте',
    'прекрати',
    'прекратите',
    'без',
    'надоели',
    'надоело',
    'отключи',
    'выключи',
  };

  static const Set<String> _jokesMoreCues = <String>{
    'больше',
    'побольше',
    'чаще',
    'почаще',
  };

  /// Слова о шутках в просьбе о частоте: «шути», «шутить», «пошути».
  static bool _isJokingWord(String word) =>
      word.startsWith('шут') || word == 'пошути' || _isJokeWord(word);

  static const Set<String> _jokesContext = <String>{
    'надо',
    'нужно',
    'так',
    'много',
    'по',
    'только',
    'давай',
    'можно',
    'ок',
    'и',
    'со',
    'своими',
    'свои',
    'твои',
    'твоих',
  };

  /// Смайлики: «смайлик», «смайлы», «эмодзи».
  static bool _isEmojiWord(String word) =>
      word.startsWith('смайл') ||
      word.startsWith('эмодз') ||
      word.startsWith('эмодж') ||
      word == 'emoji';

  static const Set<String> _emojiOffCues = <String>{
    'без',
    'убери',
    'уберите',
    'не',
    'хватит',
    'меньше',
    'поменьше',
    'выключи',
    'отключи',
    'прекрати',
  };

  static const Set<String> _emojiOnCues = <String>{
    'добавь',
    'добавляй',
    'добавьте',
    'ставь',
    'ставьте',
    'используй',
    'используйте',
    'верни',
    'верните',
    'включи',
    'можно',
    'давай',
    'со',
    'с',
    'больше',
    'побольше',
  };

  static const Set<String> _emojiContext = <String>{
    'этих',
    'эти',
    'в',
    'из',
    'ответы',
    'ответах',
    'ответов',
    'сообщения',
    'сообщениях',
    'сообщений',
    'свои',
    'твои',
    'твоих',
    'надо',
    'нужно',
    'ок',
    'и',
    'пиши',
    'отвечай',
    'говори',
  };

  /// «На ты», «на вы» и слова вокруг: «перейди на ты», «давай со мной
  /// на вы».
  static const Set<String> _addressContext = <String>{
    'перейди',
    'перейдите',
    'перейдем',
    'давай',
    'давайте',
    'говори',
    'обращайся',
    'общайся',
    'можно',
    'будь',
    'ко',
    'мне',
    'со',
    'мной',
    'ок',
    'лучше',
    'и',
    'сразу',
  };

  /// Слова, по которым ясен стиль: «короче», «подробнее», «помягче»,
  /// «официально».
  static const Map<String, String> _styleCues = <String, String>{
    'короче': ReplyStyles.brief,
    'покороче': ReplyStyles.brief,
    'кратко': ReplyStyles.brief,
    'кратче': ReplyStyles.brief,
    'коротко': ReplyStyles.brief,
    'краток': ReplyStyles.brief,
    'кратка': ReplyStyles.brief,
    'лаконичнее': ReplyStyles.brief,
    'лаконично': ReplyStyles.brief,
    'сжато': ReplyStyles.brief,
    'подробнее': ReplyStyles.neutral,
    'подробно': ReplyStyles.neutral,
    'детально': ReplyStyles.neutral,
    'детальнее': ReplyStyles.neutral,
    'развернуто': ReplyStyles.neutral,
    'развернутее': ReplyStyles.neutral,
    'нейтрально': ReplyStyles.neutral,
    'нейтральнее': ReplyStyles.neutral,
    'спокойнее': ReplyStyles.neutral,
    'дружелюбнее': ReplyStyles.friendly,
    'дружелюбный': ReplyStyles.friendly,
    'дружелюбно': ReplyStyles.friendly,
    'дружелюбным': ReplyStyles.friendly,
    'повеселее': ReplyStyles.friendly,
    'веселее': ReplyStyles.friendly,
    'помягче': ReplyStyles.friendly,
    'мягче': ReplyStyles.friendly,
    'теплее': ReplyStyles.friendly,
    'потеплее': ReplyStyles.friendly,
    'ласковее': ReplyStyles.friendly,
    'душевнее': ReplyStyles.friendly,
    'неформально': ReplyStyles.friendly,
    'официально': ReplyStyles.business,
    'официальнее': ReplyStyles.business,
    'официальный': ReplyStyles.business,
    'официальным': ReplyStyles.business,
    'строже': ReplyStyles.business,
    'посерьезнее': ReplyStyles.business,
    'серьезнее': ReplyStyles.business,
    'формально': ReplyStyles.business,
    'формальнее': ReplyStyles.business,
    'деловой': ReplyStyles.business,
    'деловым': ReplyStyles.business,
  };

  /// Стиль парой-тройкой слов: «по сути», «без воды», «без лишних слов»,
  /// «сбавь тон», «меньше ласкового», «по-деловому».
  static const Map<String, String> _stylePhrases = <String, String>{
    'по сути': ReplyStyles.brief,
    'по делу': ReplyStyles.brief,
    'без воды': ReplyStyles.brief,
    'меньше воды': ReplyStyles.brief,
    'поменьше воды': ReplyStyles.brief,
    'без лишних слов': ReplyStyles.brief,
    'сбавь тон': ReplyStyles.neutral,
    'меньше ласкового': ReplyStyles.neutral,
    'поменьше ласкового': ReplyStyles.neutral,
    'меньше ласки': ReplyStyles.neutral,
    'по деловому': ReplyStyles.business,
  };

  static const Set<String> _styleContext = <String>{
    'говори',
    'отвечай',
    'общайся',
    'пиши',
    'разговаривай',
    'будь',
    'давай',
    'давайте',
    'распиши',
    'расписывай',
    'объясняй',
    'сделай',
    'смени',
    'поменяй',
    'стиль',
    'тон',
    'тоном',
    'стилем',
    'на',
    'более',
    'максимально',
    'все',
    'можно',
    'ок',
    'и',
    'со',
    'мной',
    'чуть',
    'немного',
    'бы',
  };

  /// «Слишком официально» — жалоба на нынешний стиль, а не просьба о нём:
  /// слово после «слишком» стиль не задаёт.
  static const String _tooMuch = 'слишком';

  /// Просьба о стиле общения своими словами или `null`.
  static TalkRequest? _settingRequest(List<String> words) {
    if (words.any(_isJokingWord)) {
      final rest = words.where((String w) => !_isJokingWord(w));
      final cues = <String>{
        ..._jokesLessCues,
        ..._jokesOffCues,
        ..._jokesMoreCues,
      };
      if (!rest.every(
        (String w) => cues.contains(w) || _jokesContext.contains(w),
      )) {
        return null;
      }
      if (rest.any(_jokesLessCues.contains)) return _jokesLess;
      if (rest.any(_jokesOffCues.contains)) return _jokesOff;
      if (rest.any(_jokesMoreCues.contains)) return _jokesMore;
      return null;
    }
    if (words.any(_isEmojiWord)) {
      final rest = words.where((String w) => !_isEmojiWord(w));
      if (!rest.every(
        (String w) =>
            _emojiOffCues.contains(w) ||
            _emojiOnCues.contains(w) ||
            _emojiContext.contains(w),
      )) {
        return null;
      }
      if (rest.any(_emojiOffCues.contains)) return _emojiOff;
      if (rest.any(_emojiOnCues.contains)) return _emojiOn;
      return null;
    }
    final address = _addressRequest(words);
    if (address != null) return address;
    return _styleRequest(words);
  }

  static TalkRequest? _addressRequest(List<String> words) {
    for (var i = 0; i + 1 < words.length; i++) {
      if (words[i] != 'на') continue;
      final request = switch (words[i + 1]) {
        'ты' => _informal,
        'вы' => _formal,
        _ => null,
      };
      if (request == null) continue;
      final rest = <String>[...words.take(i), ...words.skip(i + 2)];
      return rest.every(_addressContext.contains) ? request : null;
    }
    return null;
  }

  static TalkRequest? _styleRequest(List<String> words) {
    final styles = <String>{};
    var i = 0;
    while (i < words.length) {
      if (words[i] == _tooMuch) {
        // «Слишком официально»: и это слово, и следующее — жалоба.
        i += 2;
        continue;
      }
      final phrase = _stylePhraseAt(words, i);
      if (phrase != null) {
        styles.add(phrase.$1);
        i += phrase.$2;
        continue;
      }
      final cue = _styleCues[words[i]];
      if (cue != null) {
        styles.add(cue);
      } else if (!_styleContext.contains(words[i])) {
        return null;
      }
      i++;
    }
    if (styles.length != 1) return null;
    return switch (styles.single) {
      ReplyStyles.brief => _brief,
      ReplyStyles.friendly => _friendly,
      ReplyStyles.business => _business,
      _ => _neutral,
    };
  }

  /// Стиль из [_stylePhrases], который начинается словом [at], и число
  /// его слов.
  static (String, int)? _stylePhraseAt(List<String> words, int at) {
    for (final MapEntry(:key, :value) in _stylePhrases.entries) {
      final phrase = key.split(' ');
      if (_startsWith(words, phrase, at)) return (value, phrase.length);
    }
    return null;
  }

  /// Глаголы в «пусть <имя> отвечает»: «говорит», «общается», «пишет».
  static const Set<String> _mainVerbs = <String>{
    'отвечает',
    'говорит',
    'общается',
    'пишет',
    'разговаривает',
  };

  static const Set<String> _mainContext = <String>{
    'все',
    'всегда',
    'дальше',
    'отныне',
    'сама',
    'сам',
    'за',
    'со',
    'мной',
  };

  /// «Пусть теперь всё говорит Нода», «пусть дальше отвечает Лио»: в
  /// просьбе ровно одно имя, «пусть» и глагол речи.
  static bool _isMainRequest(List<String> kept) {
    if (!kept.contains('пусть')) return false;
    if (kept.where((String w) => w == _nameSlot).length != 1) return false;
    if (!kept.any(_mainVerbs.contains)) return false;
    return kept.every(
      (String w) =>
          w == _nameSlot ||
          w == 'пусть' ||
          _mainVerbs.contains(w) ||
          _mainContext.contains(w),
    );
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
