import 'dart:math' as math;

import '../../connectors/due_parser.dart';
import '../../connectors/verb_forms.dart';
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

  /// «Открой мой Связной», «мой Связной»: открыть раздел «Мой Связной»
  /// (`AppInfo.hubName`). Название раздела не зависит от имени и рода
  /// главного помощника; прежнее «Мой Tridot» — тоже он.
  openHub,
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

  /// «Noda, будь основной», «пусть отвечает Лиорио». Главный всегда Связной
  /// (ADR-016): просьба настроек не меняет, ответ — где включить
  /// помощников.
  main,

  /// «Включи соло»: всё делает Связной.
  modeSolo,

  /// «Включи дуэт», «включи дуэт с Нодой»: Связной и один помощник.
  modeDuo,

  /// «Включи трио»: все трое.
  modeTrio;

  /// Просьба сменить режим команды.
  bool get isMode => this == modeSolo || this == modeDuo || this == modeTrio;
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
    'слышь',
    'слыш',
    'тогда',
    'теперь',
    'уже',
    'вот',
    'а',
    'вообще',
    // Обращение по-свойски: «спс бро», «как дела, дружище».
    'бро',
    'братан',
    'братишка',
    'дружище',
  };

  /// Имена для обращения → id: «привет, Нода», «пусть отвечает Лио»
  /// ([Persona.addressNames]). Годятся где угодно в реплике. Из текущего
  /// состава ([PersonaCast.current]).
  static Map<String, String> get _names {
    _refreshNames();
    return _addressNames;
  }

  /// Косвенные падежи имён → id: «сделай Ноду основной»
  /// ([Persona.inflectedForms]). Только на месте `<имя>` в образцах
  /// просьб: «привет Ноду» — не обращение и не беседа.
  static Map<String, String> get _inflectedNames {
    _refreshNames();
    return _inflectedForms;
  }

  static int _namesVersion = -1;
  static Map<String, String> _addressNames = const <String, String>{};
  static Map<String, String> _inflectedForms = const <String, String>{};

  /// Пересобирает словари имён, если имена поменялись
  /// ([PersonaCast.version]).
  static void _refreshNames() {
    if (_namesVersion == PersonaCast.version) return;
    final members = PersonaCast.current.members;
    _addressNames = <String, String>{
      for (final persona in members)
        for (final form in persona.addressNames) form: persona.id,
    };
    _inflectedForms = <String, String>{
      for (final persona in members)
        for (final form in persona.inflectedForms) form: persona.id,
    };
    _namesVersion = PersonaCast.version;
  }

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
    'бестолочь',
    'тормоз',
    'тормозишь',
    'ненавижу',
    'урод',
    'уродина',
  };

  /// Грубость из двух слов: «я тебя не люблю», «ты мне не нравишься».
  static const List<List<String>> _rudePairs = <List<String>>[
    <String>['не', 'люблю'],
    <String>['не', 'нравишься'],
    // «Ну и бот» — пренебрежительно, как «ну ты и тупой».
    <String>['ну', 'и', 'бот'],
  ];

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
    'тебя',
    'я',
    'мне',
    'же',
    'честно',
  };

  static const Map<String, TalkRequest> _phrases = <String, TalkRequest>{
    // Приветствия.
    'привет': TalkRequest(TalkTopic.greet),
    'приветик': TalkRequest(TalkTopic.greet),
    // Разговорные: «прив», «дарова», «здарова» («здорово!» без имени —
    // отклик, а не приветствие).
    'прив': TalkRequest(TalkTopic.greet),
    'приветы': TalkRequest(TalkTopic.greet),
    'дарова': TalkRequest(TalkTopic.greet),
    'здарова': TalkRequest(TalkTopic.greet),
    'здаров': TalkRequest(TalkTopic.greet),
    'хаюшки': TalkRequest(TalkTopic.greet),
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
    'хорошего вечера': TalkRequest(TalkTopic.bye),
    'хорошего тебе вечера': TalkRequest(TalkTopic.bye),
    'хорошего вам вечера': TalkRequest(TalkTopic.bye),
    'хорошего дня': TalkRequest(TalkTopic.bye),
    'хорошего тебе дня': TalkRequest(TalkTopic.bye),
    'хорошего вам дня': TalkRequest(TalkTopic.bye),
    'удачного дня': TalkRequest(TalkTopic.bye),
    'приятного вечера': TalkRequest(TalkTopic.bye),
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
    'давай пока': TalkRequest(TalkTopic.bye),
    'все давай пока': TalkRequest(TalkTopic.bye),
    'пока давай': TalkRequest(TalkTopic.bye),
    'ну все давай': TalkRequest(TalkTopic.bye),
    'чао': TalkRequest(TalkTopic.bye),
    'bye': TalkRequest(TalkTopic.bye),
    'спокойной ночи': TalkRequest(TalkTopic.bye, night: true),
    'доброй ночи': TalkRequest(TalkTopic.bye, night: true),

    // Благодарность.
    'спасибо': TalkRequest(TalkTopic.thanks),
    'спс': TalkRequest(TalkTopic.thanks),
    'спасибочки': TalkRequest(TalkTopic.thanks),
    'спасибки': TalkRequest(TalkTopic.thanks),
    'благодарочка': TalkRequest(TalkTopic.thanks),
    'благодарствую': TalkRequest(TalkTopic.thanks),
    'пасиб': TalkRequest(TalkTopic.thanks),
    'пасиба': TalkRequest(TalkTopic.thanks),
    'сенкс': TalkRequest(TalkTopic.thanks),
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
    'как дела сегодня': TalkRequest(TalkTopic.howAreYou),
    'как ты сегодня': TalkRequest(TalkTopic.howAreYou),
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
    'что за бот': TalkRequest(TalkTopic.whoAreYou),
    'ты что за бот': TalkRequest(TalkTopic.whoAreYou),
    'что ты за бот': TalkRequest(TalkTopic.whoAreYou),
    'ты бот': TalkRequest(TalkTopic.whoAreYou),
    'ты живой': TalkRequest(TalkTopic.whoAreYou),
    'ты человек': TalkRequest(TalkTopic.whoAreYou),
    'ты робот': TalkRequest(TalkTopic.whoAreYou),
    'ты живой или бот': TalkRequest(TalkTopic.whoAreYou),
    'ты живой или робот': TalkRequest(TalkTopic.whoAreYou),
    'ты бот или человек': TalkRequest(TalkTopic.whoAreYou),
    'ты человек или бот': TalkRequest(TalkTopic.whoAreYou),
    'что ты такое': TalkRequest(TalkTopic.whoAreYou),
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
    'что у тебя в арсенале': TalkRequest(TalkTopic.capabilities),
    'что в твоем арсенале': TalkRequest(TalkTopic.capabilities),
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
    'все ок': TalkRequest(TalkTopic.reaction),
    'все окей': TalkRequest(TalkTopic.reaction),
    'все хорошо': TalkRequest(TalkTopic.reaction),
    'все отлично': TalkRequest(TalkTopic.reaction),
    'все норм': TalkRequest(TalkTopic.reaction),
    'все понятно': TalkRequest(TalkTopic.reaction),
    'все ясно': TalkRequest(TalkTopic.reaction),
    'все супер': TalkRequest(TalkTopic.reaction),
    // Похвала шутке: «жги ещё», «не останавливайся».
    'жги': TalkRequest(TalkTopic.reaction),
    'жги еще': TalkRequest(TalkTopic.reaction),
    'не останавливайся': TalkRequest(TalkTopic.reaction),
    'так держать': TalkRequest(TalkTopic.reaction),

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
    'включи соло': _modeSolo,
    'включи режим соло': _modeSolo,
    'режим соло': _modeSolo,
    'давай соло': _modeSolo,
    'перейди на соло': _modeSolo,
    'переключи на соло': _modeSolo,
    'переключись на соло': _modeSolo,
    'включи дуэт': _modeDuo,
    'включи режим дуэт': _modeDuo,
    'режим дуэт': _modeDuo,
    'давай дуэт': _modeDuo,
    'перейди на дуэт': _modeDuo,
    'переключи на дуэт': _modeDuo,
    'переключись на дуэт': _modeDuo,
    'включи трио': _modeTrio,
    'включи режим трио': _modeTrio,
    'режим трио': _modeTrio,
    'давай трио': _modeTrio,
    'перейди на трио': _modeTrio,
    'переключи на трио': _modeTrio,
    'переключись на трио': _modeTrio,
    'включи дуэт с <имя>': _modeDuo,
    'дуэт с <имя>': _modeDuo,
    'включи режим дуэт с <имя>': _modeDuo,
    'давай дуэт с <имя>': _modeDuo,
    'перейди на дуэт с <имя>': _modeDuo,
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
  static const TalkRequest _modeSolo =
      TalkRequest(TalkTopic.setting, setting: TalkSettingKind.modeSolo);
  static const TalkRequest _modeDuo =
      TalkRequest(TalkTopic.setting, setting: TalkSettingKind.modeDuo);
  static const TalkRequest _modeTrio =
      TalkRequest(TalkTopic.setting, setting: TalkSettingKind.modeTrio);

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

  /// Отклик перед репликой: «хорошо, круто, давай на ты». Их может быть
  /// несколько подряд, дальше — другая реплика, она и важнее.
  static const Set<String> _reactionLeads = <String>{
    'хорошо',
    'круто',
    'ок',
    'окей',
    'ладно',
    'понятно',
    'отлично',
    'супер',
    'класс',
  };

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
    // Части сообщения между запятыми и знаками конца фразы: хвост-замечание
    // («…, задолбал», «…, а ты подожди») отделяется только ими.
    final clauses = <List<String>>[
      for (final part in normalized.split(_clauseBreak))
        <String>[
          for (final match in _word.allMatches(part))
            _canonical[match.group(0)!] ?? match.group(0)!,
        ],
    ]..removeWhere((List<String> c) => c.isEmpty);
    final words = <String>[for (final clause in clauses) ...clause];
    if (words.isEmpty) {
      final symbols = text.replaceAll(_ignoredSymbols, '');
      final topic = _symbols[symbols];
      return topic == null ? null : TalkRequest(topic);
    }
    if (words.length > maxWords) return null;
    // Команда задачи где угодно — не беседа: «расскажи шутку для коллег —
    // создай задачу» (как «добавь задачу рассказать шутку»).
    if (_taskCommand.hasMatch(normalized)) return null;
    // Цифры — уже не беседа: «ок 15:00», «спасибо 2».
    if (words.any((String w) => RegExp(r'\d').hasMatch(w))) return null;
    // «Открой мой Связной» — до имён помощников: «связной» здесь —
    // название раздела, а не обращение.
    if (isHubRequest(words)) return const TalkRequest(TalkTopic.openHub);
    _fixMisspelledNames(clauses);
    final fixed = <String>[for (final clause in clauses) ...clause];
    return _recognizeAll(fixed) ??
        _withoutRemarks(clauses) ??
        _recognizeWords(fixed, loose: true);
  }

  /// Названия раздела «Мой Связной» словами: так его зовут всегда, при
  /// любом имени и роде главного помощника; «мой Tridot» — прежнее имя.
  /// «Открой моего связного» — винительный падеж, «мой связный» — так
  /// слово пишет голосовой ввод.
  static const Set<String> _hubNames = <String>{
    'мой связной',
    'моя связная',
    'моего связного',
    'мою связную',
    'мой связный',
    'мой tridot',
    'мой тридот',
  };

  /// Глаголы перед названием раздела: «открой мой Связной», «перейди в
  /// мой Связной».
  static const Set<String> _hubVerbs = <String>{
    'открой',
    'откройте',
    'открыть',
    'покажи',
    'покажите',
    'показать',
    'перейди в',
    'перейдите в',
    'перейти в',
    'зайди в',
    'зайдите в',
    'зайти в',
    'иди в',
    'вернись в',
    'вернуться в',
    'раздел',
  };

  /// [words] — просьба открыть раздел «Мой Связной»: его название, перед
  /// ним — глагол из [_hubVerbs] или ничего («мой Связной»), вокруг —
  /// только слова-паразиты ([_fillers]). Глагол бывает и после названия:
  /// «Мой Связной открой».
  static bool isHubRequest(List<String> words) {
    final kept = <String>[
      for (final word in words)
        if (!_fillers.contains(word)) word,
    ];
    if (kept.length < 2) return false;
    if (kept.length == 3 &&
        _hubNames.contains(kept.take(2).join(' ')) &&
        _hubVerbs.contains(kept.last) &&
        kept.last != 'раздел') {
      return true;
    }
    final name = kept.sublist(kept.length - 2).join(' ');
    if (!_hubNames.contains(name)) return false;
    final lead = kept.sublist(0, kept.length - 2);
    if (lead.isEmpty) return true;
    final verb = lead.join(' ');
    return _hubVerbs.contains(verb) ||
        (lead.length > 1 &&
            lead.last == 'раздел' &&
            _hubVerbs.contains(lead.sublist(0, lead.length - 1).join(' ')));
  }

  /// Реплика без хвоста-замечания: «говори короче, задолбал», «пусть
  /// отвечает Нода, а ты подожди», «давай ещё одну, не смешно». Хвост —
  /// последние части после запятой, целиком из слов [_remarkWords],
  /// грубостей и смеха; без него остаётся просьба о шутке, стиле или
  /// «что умеешь». Замечание словарь закрытый: «говори короче, добавь
  /// задачу» — не беседа.
  static TalkRequest? _withoutRemarks(List<List<String>> clauses) {
    var end = clauses.length;
    // «Расскажи шутку про IT — вставь в презентацию»: что человек сделает
    // с шуткой потом, просьбу не меняет. Только у шутки и только последней
    // частью.
    final jokeUse = end > 1 && _isJokeUse(clauses[end - 1]);
    if (jokeUse) end--;
    while (end > 1 && _isRemark(clauses[end - 1])) {
      end--;
    }
    if (end == clauses.length) return null;
    final head = <String>[for (final clause in clauses.take(end)) ...clause];
    final request = _recognizeAll(head);
    if (request == null || !_remarkTopics.contains(request.topic)) return null;
    if (jokeUse && request.topic != TalkTopic.joke) return null;
    return request;
  }

  /// Что сделать с шуткой: «вставь в презентацию», «перешлю коллегам»,
  /// «использую в тосте». Глаголы — закрытый список; команда задачи
  /// («создай задачу») отсеяна раньше ([_taskCommand]).
  static bool _isJokeUse(List<String> words) =>
      words.isNotEmpty &&
      words.length <= _maxRemarkWords &&
      _jokeUseVerbs.contains(words.first);

  static const Set<String> _jokeUseVerbs = <String>{
    'вставь',
    'вставлю',
    'вставим',
    'использую',
    'используем',
    'перешлю',
    'расскажу',
    'покажу',
  };

  /// Темы, к которым можно приписать хвост-замечание.
  static const Set<TalkTopic> _remarkTopics = <TalkTopic>{
    TalkTopic.rude,
    TalkTopic.joke,
    TalkTopic.setting,
    TalkTopic.capabilities,
  };

  static final RegExp _clauseBreak = RegExp('[,;!?.…—–]');

  /// Команда создать задачу: глагол рядом со словом «задача» или «в
  /// задачи».
  static final RegExp _taskCommand = RegExp(
    r'(?:^|[\s,;—–-])(?:создай|добавь|запиши|поставь|заведи)(?:те)?\s+'
    r'(?:\S+\s+)?(?:задач|напоминани)|(?:^|\s)в\s+(?:задачи|список\s+дел)',
  );

  /// Слова хвоста-замечания: причина («а то ты сухой», «я не на работе»),
  /// одобрение («мне нравится»), «не смешно», «а ты подожди».
  static const Set<String> _remarkWords = <String>{
    'а', 'то', 'чего', 'что', 'ты', 'я', 'мы', 'мне', 'не', 'на', 'же',
    'так', 'очень', 'совсем', 'уже', 'какой', 'какая', 'сухой', 'сухая', //
    'скучный', 'скучная', 'скучно', 'грустно', 'занудный', 'занудная',
    'серьезный', 'серьезная', 'строгий', 'строгая', 'нравится', 'нравятся',
    'понравилось', 'работе', 'дома', 'отпуске', 'подожди', 'помолчи',
    'молчи', 'отдохни', 'отдыхай', 'ага', 'угу', 'ок', 'окей', 'ладно',
    'но', 'хоть', 'зато', //
  };

  /// «Не смешно», «не смеюсь», «не улыбаюсь», «не усмехаюсь» (и с
  /// опечаткой): основы слов о смехе в замечании.
  static const List<String> _laughStems = <String>[
    'смешн',
    'смею',
    'смеюс',
    'улыба',
    'усме',
    'усми',
    'ржу',
    'ржет',
  ];

  static bool _isRemark(List<String> words) =>
      words.length <= _maxRemarkWords &&
      words.every(
        (String w) =>
            _remarkWords.contains(w) ||
            _rudeWords.contains(w) ||
            _names.containsKey(w) ||
            _fillers.contains(w) ||
            _laughter.hasMatch(w) ||
            _laughStems.any(w.startsWith),
      );

  static const int _maxRemarkWords = 6;

  /// Разговорные формы → обычные: «чё», «чо» — «что»; «главный» —
  /// «основной» (в образцах просьб только «основной»); «будь основному» —
  /// «будь основным».
  static const Map<String, String> _canonical = <String, String>{
    'че': 'что',
    'чо': 'что',
    'шо': 'что',
    'што': 'что',
    'главный': 'основной',
    'главная': 'основная',
    'главной': 'основной',
    'главным': 'основным',
    'главному': 'основным',
    'основному': 'основным',
  };

  /// Имя с опечаткой в обращении в начале реплики: «Лео, что умеешь?»,
  /// «Лииорио, анекдот», «Нод Нод, пошути». Одна буква лишняя,
  /// пропущенная или другая, первая — та же, а слово не короче трёх букв.
  /// Дальше в реплике имя — часть просьбы, и опечатку не отличить от
  /// другого слова: «пусть отвечает Лион» — не Лио.
  static void _fixMisspelledNames(List<List<String>> clauses) {
    final positions = <(int, int)>[
      for (var c = 0; c < clauses.length; c++)
        for (var w = 0; w < clauses[c].length; w++) (c, w),
    ];
    String? fix(String word) {
      if (_names.containsKey(word) || _inflectedNames.containsKey(word)) {
        return word;
      }
      if (word.length < 3) return null;
      for (final name in _names.keys) {
        if (name[0] == word[0] && _oneEditApart(name, word)) return name;
      }
      return null;
    }

    for (final (c, w) in positions) {
      final word = clauses[c][w];
      if (_fillers.contains(word)) continue;
      final name = fix(word);
      if (name == null) break;
      clauses[c][w] = name;
    }
  }

  /// Слова отличаются ровно одной правкой: вставкой, удалением или заменой
  /// буквы.
  static bool _oneEditApart(String a, String b) {
    if (a == b || (a.length - b.length).abs() > 1) return false;
    var i = 0;
    while (i < a.length && i < b.length && a[i] == b[i]) {
      i++;
    }
    if (a.length == b.length) return a.substring(i + 1) == b.substring(i + 1);
    if (a.length > b.length) return a.substring(i + 1) == b.substring(i);
    return a.substring(i) == b.substring(i + 1);
  }

  /// Реплика целиком или вступление и за ним другая реплика.
  static TalkRequest? _recognizeAll(List<String> words) {
    final whole = _recognizeWords(words);
    if (whole != null) return whole;
    // «Хорошо, круто, давай на ты»: отклики впереди, дальше — другая
    // реплика.
    var lead = _skipNames(words, 0);
    var leads = 0;
    while (lead < words.length && _reactionLeads.contains(words[lead])) {
      lead = _skipNames(words, lead + 1);
      leads++;
    }
    if (leads > 0 && lead < words.length) {
      final rest = _recognizeWords(words.sublist(lead));
      if (rest != null && rest.topic != TalkTopic.reaction) return rest;
    }
    // «Привет, говори короче», «спасибо, пока», «спасибо и пока»: после
    // вступления — другая реплика, она и важнее.
    for (final prefix in _prefixes) {
      final prefixWords = prefix.split(' ');
      var start = _skipNames(words, 0);
      if (!_startsWith(words, prefixWords, start)) continue;
      start = _skipNames(words, start + prefixWords.length);
      // «Спасибо за шутку, ещё», «спс за инфу, пока»: за что спасибо —
      // одно слово.
      String? thanksFor;
      if (_thanksWords.contains(prefixWords.last) &&
          start + 1 < words.length &&
          words[start] == 'за') {
        thanksFor = words[start + 1];
        start = _skipNames(words, start + 2);
      }
      while (start < words.length && _joiners.contains(words[start])) {
        start++;
      }
      if (start >= words.length) continue;
      final named = <String>{
        for (final word in words.take(start))
          if (_names[word] case final String id) id,
      };
      final restWords = words.sublist(start);
      // «Спасибо за шутку, ну ещё!»: одно «ещё» после спасибо за шутку —
      // просьба о новой.
      final more = thanksFor != null &&
          _isJokeWord(thanksFor) &&
          restWords.every((String w) => w == 'еще' || _fillers.contains(w)) &&
          restWords.contains('еще');
      final rest = more
          ? TalkRequest(TalkTopic.joke, pun: thanksFor.contains('каламбур'))
          : _recognizeWords(restWords);
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
  /// с именем помощника на месте `<имя>` или без него, просьба своими
  /// словами. [loose] — последняя попытка: ещё и благодарность своими
  /// словами («спс, реально выручил»), которая уступает вступлению
  /// («спс, всё ок» — отклик).
  static TalkRequest? _recognizeWords(
    List<String> words, {
    bool loose = false,
  }) {
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
    bool isName(String word) =>
        _names.containsKey(word) || _inflectedNames.containsKey(word);
    final kept = <String>[
      for (var i = 0; i < words.length; i++)
        if (isName(words[i]))
          _nameSlot
        // «Дуэт со Связным», «дуэт со Светой» — тот же образец, что «дуэт
        // с <имя>» (ADR-017).
        else if (words[i] == 'со' &&
            i + 1 < words.length &&
            isName(words[i + 1]))
          'с'
        else if (!_fillers.contains(words[i]))
          words[i],
    ];
    if (kept.isEmpty) return null;
    final withName = _phrases[kept.join(' ')] ?? _settingWithPlace(kept);
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
    // «Здорово, Лиорио!» — приветствие: «здорово» с обращением по имени.
    // Без имени («здорово!») — отклик.
    if (persona != null && plain.length == 1 && plain.first == 'здорово') {
      return TalkRequest(TalkTopic.greet, persona: persona);
    }
    final request = (persona == null ? null : _phrases[plain.join(' ')]) ??
        _chainRequest(plain) ??
        _settingRequest(plain) ??
        _jokeRequest(plain) ??
        _capabilitiesRequest(plain) ??
        _skillAbilityRequest(plain) ??
        (loose ? _thanksRequest(plain) : null);
    return request?.withPersona(persona);
  }

  /// Где действует просьба: «сделай Ноду главной в чате», «будь основной
  /// здесь». Место ничего не меняет — только в просьбах о стиле.
  static const List<List<String>> _places = <List<String>>[
    <String>['в', 'этом', 'чате'],
    <String>['в', 'чате'],
    <String>['в', 'разговоре'],
    <String>['здесь'],
    <String>['тут'],
  ];

  static TalkRequest? _settingWithPlace(List<String> kept) {
    for (final place in _places) {
      final at = kept.length - place.length;
      if (at < 1 || !_startsWith(kept, place, at)) continue;
      final request = _phrases[kept.take(at).join(' ')];
      if (request?.topic == TalkTopic.setting) return request;
    }
    return null;
  }

  /// Темы, реплики которых можно сказать подряд: «пока, до завтра»,
  /// «кто ты вообще, что за бот», «спасибо, спасибо большое».
  static const Set<TalkTopic> _chainTopics = <TalkTopic>{
    TalkTopic.greet,
    TalkTopic.bye,
    TalkTopic.thanks,
    TalkTopic.howAreYou,
    TalkTopic.whoAreYou,
    TalkTopic.capabilities,
    TalkTopic.reaction,
  };

  /// Несколько фраз [_phrases] одной темы подряд — реплика этой темы.
  /// Разные темы — по правилу вступления ([_prefixes]), а не здесь.
  static TalkRequest? _chainRequest(List<String> words) {
    TalkRequest? first;
    var at = 0;
    while (at < words.length) {
      TalkRequest? found;
      var length = 0;
      // Длинная фраза — раньше короткой: «до завтра», а не «до».
      for (var end = words.length; end > at; end--) {
        final request = _phrases[words.sublist(at, end).join(' ')];
        if (request == null || !_chainTopics.contains(request.topic)) continue;
        found = request;
        length = end - at;
        break;
      }
      if (found == null) return null;
      if (first != null && found.topic != first.topic) {
        // «Кто ты и что умеешь»: о себе и о возможностях — ответ о
        // возможностях (он и представляет помощника).
        const pair = <TalkTopic>{TalkTopic.whoAreYou, TalkTopic.capabilities};
        if (!pair.contains(first.topic) || !pair.contains(found.topic)) {
          return null;
        }
        if (found.topic == TalkTopic.capabilities) first = found;
      }
      first ??= found;
      at += length;
      // «Пока и до завтра»: «и» между фразами.
      if (at < words.length - 1 && words[at] == 'и') at++;
    }
    // Одна фраза — не цепочка: её уже искали в [_phrases].
    return at > 0 && first != null && words.length > 1 ? first : null;
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
    'следующую',
    'дай',
    'дайте',
    'повтори',
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
    'шути',
    'шутите',
    'шутни',
    'шутани',
    'рассмей',
    'рассмейте',
  };

  /// Прошедшее время как приказ — только со словом спешки: «быстро
  /// пошутил!»; «я пошутил» — не просьба.
  static const Set<String> _jokePastVerbs = <String>{
    'пошутил',
    'пошутила',
    'пошутили',
  };

  static const Set<String> _hurryWords = <String>{
    'быстро',
    'живо',
    'бегом',
    'срочно',
  };

  /// Присказки «на бис», которые сами шутку не просят: «повтори успех,
  /// ещё анекдот», «на бис».
  static const List<List<String>> _encores = <List<String>>[
    <String>['повтори', 'успех'],
    <String>['на', 'бис'],
  ];

  /// Что любят или не любят — перед просьбой о шутке другого рода:
  /// «каламбуры не люблю, дай анекдот».
  static const Set<String> _preferenceWords = <String>{
    'люблю',
    'нравятся',
    'нравится',
    'надо',
    'нужно',
    'эти',
    'этих',
    'твои',
    'твоих',
    'свои',
    'своих',
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
    'два', 'три', 'предложения', 'слова', 'следующую', 'следующий',
    'следующая', 'дай', 'дайте', 'повтори', 'быстро', 'живо', 'бегом',
    'срочно', 'ага', 'угу',
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
  static const Set<String> _about = <String>{'про', 'о', 'об', 'тема', 'тему'};

  static const int _maxTopicWords = 2;

  /// «Для выступления на мите», «для тоста»: для чего шутка — до трёх
  /// слов. «Расскажи шутку на корпоративе» — не цель, а дело: не беседа.
  static const String _purpose = 'для';

  static const int _maxPurposeWords = 3;

  /// «Пошути, что ты умный»: о чём шутка после глагола — до трёх слов.
  static const int _maxClauseWords = 3;

  /// Слова без присказок [_encores].
  static List<String> _withoutEncores(List<String> words) {
    final result = <String>[];
    var i = 0;
    outer:
    while (i < words.length) {
      for (final encore in _encores) {
        if (_startsWith(words, encore, i)) {
          i += encore.length;
          continue outer;
        }
      }
      result.add(words[i]);
      i++;
    }
    return result;
  }

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
  static TalkRequest? _jokeRequest(List<String> original) {
    var words = _withoutEncores(original);
    if (words.isEmpty) return null;
    final refusal = words.lastIndexWhere(_jokeRefusal.contains);
    if (refusal >= 0) {
      // «Каламбуры не люблю, дай анекдот»: отказ от одного рода шуток и
      // просьба о другом. Просьба — после отказа, а до неё — только что
      // не любят.
      final ask = words.indexWhere(
        (String w) => _jokeAsks.contains(w) || _jokeVerbs.contains(w),
        refusal + 1,
      );
      if (ask < 0) return null;
      final before = words.take(ask);
      if (!before.every(
        (String w) =>
            _jokeRefusal.contains(w) ||
            _isJokeWord(w) ||
            _preferenceWords.contains(w),
      )) {
        return null;
      }
      words = words.sublist(ask);
    }
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
          _jokeVerbs.contains(word) ||
          (_jokePastVerbs.contains(word) &&
              words.any(_hurryWords.contains) &&
              !words.contains('я'))) {
        core = true;
        if (word.contains('каламбур')) pun = true;
        if (i + 1 < words.length &&
            words[i + 1] == 'что' &&
            _jokeVerbs.contains(word)) {
          // «Пошути, что ты умный»: дальше — о чём шутка.
          i = math.min(i + 1 + _maxClauseWords, words.length - 1);
        }
        continue;
      }
      if (word == _purpose) {
        // «Для выступления на мите»: цель — до трёх слов, пока не
        // начнётся сама просьба.
        var purpose = 0;
        while (i + 1 < words.length &&
            purpose < _maxPurposeWords &&
            !_jokeAsks.contains(words[i + 1]) &&
            !_isJokeWord(words[i + 1]) &&
            !_jokeVerbs.contains(words[i + 1])) {
          i++;
          purpose++;
        }
        if (purpose == 0) return null;
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
      if (_jokeContext.contains(word) ||
          _laughter.hasMatch(word) ||
          // «Ну и где анекдоты, бестолочь?»: обращение-грубость.
          _rudeWords.contains(word)) {
        continue;
      }
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

  /// «Шути больше», «давай с юмором».
  static const Set<String> _jokesMoreCues = <String>{
    'больше',
    'побольше',
    'чаще',
    'почаще',
    'с',
    'со',
  };

  /// Слова о шутках в просьбе о частоте: «шути», «шутить», «пошути»,
  /// «паясничать», «прикалываться».
  static bool _isJokingWord(String word) =>
      word.startsWith('шут') ||
      word == 'пошути' ||
      _isJokeWord(word) ||
      _clowningStems.any(word.startsWith);

  /// Шутовство другими словами: «хватит паясничать», «не прикалывайся»,
  /// «меньше дурачься».
  static const List<String> _clowningStems = <String>[
    'паяснича',
    'прикалыва',
    'дурачит',
    'дурачься',
    'кривля',
    'балагур',
    'юморит',
  ];

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
    'нравится',
    'нравятся',
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
    'всех',
    'всяких',
    'этого',
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
    'переходи',
    'переходим',
    'переходите',
    'перейти',
    'общаться',
    'говорить',
    'разговаривать',
    'будем',
    'ты',
    'вы',
    'с',
    'тобой',
    'вами',
  };

  /// Слова стиля рядом с «на ты»: «давай без официоза, на ты».
  static const Set<String> _informalCompanions = <String>{
    'без',
    'официоза',
    'формальностей',
    'церемоний',
    'попроще',
    'по',
    'простому',
    'дружески',
  };

  /// Слова стиля рядом с «на вы»: «давай на вы, официально».
  static const Set<String> _formalCompanions = <String>{
    'официально',
    'вежливо',
    'вежливее',
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
    'вежливее': ReplyStyles.business,
    'повежливее': ReplyStyles.business,
    'вежливо': ReplyStyles.business,
    'вежливой': ReplyStyles.business,
    'вежливым': ReplyStyles.business,
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
    'без пафоса': ReplyStyles.brief,
    'не юли': ReplyStyles.brief,
    'не юлить': ReplyStyles.brief,
    'не тяни': ReplyStyles.brief,
    'не лей воду': ReplyStyles.brief,
    'без официоза': ReplyStyles.friendly,
    'без формальностей': ReplyStyles.friendly,
    'как с другом': ReplyStyles.friendly,
    'как с подругой': ReplyStyles.friendly,
    'как другу': ReplyStyles.friendly,
    'по дружески': ReplyStyles.friendly,
    'по простому': ReplyStyles.friendly,
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
    'нужен',
    'нужна',
    'нужно',
    'надо',
    'хочу',
    'постарайся',
    'постарайтесь',
    'в',
    'ответах',
    'ответе',
    'ответы',
    'сообщениях',
  };

  /// Указательные слова ничего не меняют в стиле: «без этого пафоса».
  static const Set<String> _demonstratives = <String>{
    'этого',
    'этой',
    'этих',
    'всех',
    'всего',
    'всяких',
    'такого',
  };

  /// «Официально не надо», «не будь таким официальным»: стиль наоборот.
  static const Map<String, String> _oppositeStyles = <String, String>{
    ReplyStyles.business: ReplyStyles.friendly,
    ReplyStyles.friendly: ReplyStyles.neutral,
    ReplyStyles.brief: ReplyStyles.neutral,
    ReplyStyles.neutral: ReplyStyles.brief,
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
      final rest = _withoutPurpose(words).where((String w) => !_isEmojiWord(w));
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
      final companions =
          request == _informal ? _informalCompanions : _formalCompanions;
      return rest.every(
        (String w) => _addressContext.contains(w) || companions.contains(w),
      )
          ? request
          : null;
    }
    return null;
  }

  static TalkRequest? _styleRequest(List<String> all) {
    final words = <String>[
      for (final word in all)
        if (!_demonstratives.contains(word)) word,
    ];
    final styles = <String>{};
    var negated = false;
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
      } else if (words[i] == 'не') {
        negated = true;
      } else if (!_styleContext.contains(words[i]) &&
          !(negated && _negatedContext.contains(words[i]))) {
        return null;
      }
      i++;
    }
    if (styles.length != 1) return null;
    final style = negated ? _oppositeStyles[styles.single] : styles.single;
    return switch (style) {
      ReplyStyles.brief => _brief,
      ReplyStyles.friendly => _friendly,
      ReplyStyles.business => _business,
      _ => _neutral,
    };
  }

  /// Слова при отрицании стиля: «не будь таким официальным», «официально
  /// не стоит».
  static const Set<String> _negatedContext = <String>{
    'таким',
    'такой',
    'стоит',
    'нужно',
    'надо',
  };

  /// Слова без цели «для …» из одного слова: «добавь смайликов для
  /// настроения».
  static List<String> _withoutPurpose(List<String> words) {
    final result = <String>[];
    for (var i = 0; i < words.length; i++) {
      if (words[i] == _purpose && i + 1 < words.length) {
        i++;
        continue;
      }
      result.add(words[i]);
    }
    return result;
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

  // ------------------------------------------------ «что умеешь» и спасибо

  /// Глаголы вопроса о возможностях: «что ты умеешь», «чем можешь».
  static const Set<String> _abilityVerbs = <String>{
    'умеешь',
    'умеете',
    'можешь',
    'можете',
  };

  static const Set<String> _abilityQuestions = <String>{'что', 'чем'};

  /// Слова, которые сами просят справку: «помощь по командам», «какие у
  /// тебя возможности».
  static const Set<String> _helpWords = <String>{
    'помощь',
    'справка',
    'справку',
    'help',
    'команды',
    'команд',
    'возможности',
    'функции',
    'умения',
  };

  /// Слова вокруг вопроса о возможностях: «ты вообще что умеешь-то»,
  /// «что ты умеешь делать», «какие есть команды».
  static const Set<String> _abilityContext = <String>{
    'ты',
    'вы',
    'что',
    'чем',
    'делать',
    'сделать',
    'еще',
    'то',
    'и',
    'какие',
    'какая',
    'есть',
    'у',
    'тебя',
    'вас',
    'твои',
    'ваши',
    'мне',
    'помочь',
    'список',
    'покажи',
    'нужна',
    'нужен',
    'дай',
    'все',
    'вообще',
  };

  /// «Кроме шуток», «в плане анализа данных», «по командам»: о чём
  /// вопрос — до двух слов после этих слов.
  static const List<List<String>> _abilityTopics = <List<String>>[
    <String>['в', 'плане'],
    <String>['по', 'части'],
    <String>['в', 'области'],
    <String>['в', 'сфере'],
    <String>['кроме'],
    <String>['насчет'],
    <String>['касательно'],
    <String>['по'],
  ];

  /// Основы слов о самом приложении: «по командам», «по задачам», «по
  /// навыкам», «по Tridot».
  static const List<String> _appTopics = <String>[
    'команд', 'задач', 'функци', 'навык', 'возможност', 'приложени', //
    'связн', 'tridot', 'тридот', 'калькулятор', 'бесед', 'настройк',
    'коннектор', 'помощник',
  ];

  /// «Что ты умеешь» своими словами или `null`: вопрос «что/чем» с
  /// «умеешь/можешь» или слово справки, вокруг — только слова вопроса и
  /// одна тема. «Что ты можешь сказать про отчёт», «чем помочь с
  /// задачей» — не вопрос о возможностях.
  static TalkRequest? _capabilitiesRequest(List<String> words) {
    final question = words.any(_abilityVerbs.contains) &&
        words.any(_abilityQuestions.contains);
    if (!question && !words.any(_helpWords.contains)) return null;
    var topics = 0;
    var i = 0;
    outer:
    while (i < words.length) {
      final word = words[i];
      if (_abilityVerbs.contains(word) ||
          _helpWords.contains(word) ||
          _abilityContext.contains(word)) {
        i++;
        continue;
      }
      for (final lead in _abilityTopics) {
        if (!_startsWith(words, lead, i)) continue;
        final start = i + lead.length;
        if (start >= words.length || ++topics > 1) return null;
        // Без вопроса «что умеешь» тема — только о самом помощнике:
        // «помощь по командам»; «помощь по дому» — не справка.
        if (!question && !_appTopics.any(words[start].startsWith)) {
          return null;
        }
        i = math.min(start + _maxTopicWords, words.length);
        continue outer;
      }
      return null;
    }
    return const TalkRequest(TalkTopic.capabilities);
  }

  /// «Умеешь ставить будильник?», «умеешь считать проценты?», «как
  /// пользоваться калькулятором» — вопрос о том, что умеет помощник:
  /// «умеешь» и инфинитив, дальше не больше двух слов без чисел. «Можешь
  /// поставить будильник?» — вежливая просьба, а не вопрос: её здесь нет.
  static TalkRequest? _skillAbilityRequest(List<String> words) {
    var at = 0;
    while (at < words.length && (words[at] == 'ты' || words[at] == 'вы')) {
      at++;
    }
    final rest = words.sublist(at);
    if (rest.isEmpty || rest.any((String w) => RegExp(r'\d').hasMatch(w))) {
      return null;
    }
    if ((rest.first == 'умеешь' || rest.first == 'умеете') &&
        rest.length >= 2 &&
        rest.length <= 4 &&
        VerbForms.isInfinitive(rest[1])) {
      return const TalkRequest(TalkTopic.capabilities);
    }
    if (rest.length == 3 &&
        rest[0] == 'как' &&
        rest[1] == 'пользоваться' &&
        (_appTopics.any(rest[2].startsWith) ||
            _skillTopics.any(rest[2].startsWith))) {
      return const TalkRequest(TalkTopic.capabilities);
    }
    return null;
  }

  /// Основы названий навыков: «как пользоваться будильником».
  static const List<String> _skillTopics = <String>[
    'будильник', 'таймер', 'погод', 'конвертер', 'архиватор', 'склад', //
  ];

  /// Слова благодарности: «спасибо», «спс», «благодарю».
  static const Set<String> _thanksWords = <String>{
    'спасибо',
    'спс',
    'спасибочки',
    'спасибки',
    'благодарю',
    'мерси',
    'сенкс',
    'пасиб',
    'пасиба',
    'thanks',
    'thx',
  };

  /// Слова вокруг благодарности: «ок, понял, спасибо», «спс, выручил»,
  /// «спс, реально спасло».
  static const Set<String> _thanksContext = <String>{
    'большое',
    'огромное',
    'тебе',
    'вам',
    'очень',
    'реально',
    'правда',
    'ок',
    'окей',
    'ok',
    'понял',
    'поняла',
    'ясно',
    'понятно',
    'все',
    'и',
    'так',
    'ты',
    'вы',
    'лучший',
    'лучшая',
    'супер',
    'круто',
    'отлично',
    'хорошо',
    'ладно',
    'ага',
    'угу',
    'заранее',
    'выручил',
    'выручила',
    'выручили',
    'выручаешь',
    'выручаете',
    'спас',
    'спасла',
    'спасло',
    'спасли',
    'помог',
    'помогла',
    'помогло',
    'помогли',
    'помогаешь',
  };

  /// «Спасибо» своими словами или `null`: слово благодарности, за что
  /// спасибо («за инфу», «за быстрый ответ» — одно-два слова) и слова
  /// [_thanksContext]. «Спасибо, перенеси отчёт» — не беседа.
  static TalkRequest? _thanksRequest(List<String> words) {
    if (!words.any(_thanksWords.contains)) return null;
    for (var i = 0; i < words.length; i++) {
      final word = words[i];
      if (_thanksWords.contains(word) || _thanksContext.contains(word)) {
        continue;
      }
      if (word == 'за' && i + 1 < words.length) {
        // За что: одно слово и ещё одно, если перед ним прилагательное
        // («за быстрый ответ»).
        i++;
        if (i + 1 < words.length && _adjective.hasMatch(words[i])) i++;
        continue;
      }
      return null;
    }
    return const TalkRequest(TalkTopic.thanks);
  }

  static final RegExp _adjective = RegExp(r'(?:ый|ий|ой|ую|ое|ее|ые|ие)$');

  static bool _isRude(List<String> all) {
    final words = <String>[];
    var rude = false;
    outer:
    for (var i = 0; i < all.length; i++) {
      for (final pair in _rudePairs) {
        if (_startsWith(all, pair, i)) {
          rude = true;
          i += pair.length - 1;
          continue outer;
        }
      }
      words.add(all[i]);
    }
    return all.length <= 5 &&
        (rude || words.any(_rudeWords.contains)) &&
        words.every(
          (String w) =>
              _rudeWords.contains(w) ||
              _rudeCompanions.contains(w) ||
              _names.containsKey(w),
        );
  }
}
