import '../../connectors/question_phrases.dart';
import '../../connectors/utterance.dart';
import 'place_names.dart';

/// Что спросили о погоде.
enum WeatherAskKind {
  /// «Какая погода», «погода в Казани».
  now,

  /// Назван день: «погода завтра», «в субботу».
  day,

  /// «Прогноз на неделю», «на выходные».
  week,

  /// «Будет дождь?», «нужен зонт?».
  rain,

  /// «Что надеть», «во что одеться».
  wear,

  /// «Открой погоду».
  open,

  /// О прошедшем дне: «вчера был дождь?».
  past,

  /// Дальше, чем на неделю.
  range,
}

/// На сколько дней вперёд: вся неделя или выходные.
enum WeatherRange { week, weekend }

/// Разобранный вопрос о погоде (ADR-030).
final class WeatherAsk {
  const WeatherAsk({
    required this.kind,
    this.dayOffset,
    this.range,
    this.placeQuery,
    this.date,
    this.strong = false,
  });

  final WeatherAskKind kind;

  /// Во фразе прямо названа погода, прогноз или температура: «сколько
  /// градусов на улице» — не вопрос складу о количестве.
  final bool strong;

  /// Дата [dayOffset] по часам устройства; `null` — день не назван.
  final DateTime? date;

  /// День от сегодняшнего: 0 — сегодня, 1 — завтра; `null` — не назван.
  final int? dayOffset;
  final WeatherRange? range;

  /// Город, как сказан во фразе: «Казани», «Нижнем Новгороде»; `null` —
  /// не назван.
  final String? placeQuery;

  /// Команда навыка: `weather.now`, `weather.rain`…
  String get commandId => 'weather.${kind.name}';

  /// Город в именительном падеже — первый вариант перебора.
  String? get placeName {
    final query = placeQuery;
    if (query == null) return null;
    final candidates = PlaceNames.candidates(query);
    return candidates.isEmpty ? null : candidates.first;
  }
}

/// Фразы о погоде: только точные словоформы, без поиска по началу слова
/// («погоди» — не погода).
abstract final class WeatherPhrases {
  static const Set<String> _weather = <String>{
    'погода',
    'погоды',
    'погоде',
    'погоду',
    'погодой',
    'погодка',
    'погодку',
  };

  /// После «прогноз» — только то, что бывает у прогноза погоды:
  /// «прогноз на неделю», «прогноз погоды»; «прогноз продаж» — не наш.
  static const Set<String> _forecastNext = <String>{
    'погоды',
    'на',
    'для',
    'в',
    'во',
    'завтра',
    'сегодня',
    'послезавтра',
  };

  static const Set<String> _forecast = <String>{
    'прогноз',
    'прогноза',
    'прогнозу',
  };

  static const Set<String> _rain = <String>{
    'дождь',
    'дождя',
    'дожди',
    'дождик',
    'дождем',
    'дождливо',
    'ливень',
    'снег',
    'снега',
    'снегопад',
    'осадки',
    'осадков',
    'гроза',
    'грозы',
    'зонт',
    'зонтик',
  };

  /// Мороз — не осадки: «завтра мороз?» — погода на день.
  static const Set<String> _cold = <String>{'мороз', 'морозы'};

  static const Set<String> _wearVerbs = <String>{
    'надеть',
    'одеться',
    'одеваться',
    'надевать',
    'одеть',
  };

  static const Set<String> _wearQuestion = <String>{'что', 'во', 'как'};

  static const Set<String> _temperature = <String>{
    'температура',
    'температуру',
    'градусов',
    'градуса',
    'холодно',
    'тепло',
    'жарко',
  };

  static const Set<String> _temperatureContext = <String>{
    'сейчас',
    'улице',
    'завтра',
    'сегодня',
    'будет',
    'какая',
    'сколько',
  };

  /// Температура тела, а не погоды.
  static const Set<String> _body = <String>{
    'у',
    'тела',
    'ребенка',
    'меня',
    'тебя',
    'воды',
    'духовке',
    'холодильнике',
  };

  /// Глаголы задачи: «напомни взять зонт, если дождь» — задача.
  static const Set<String> _taskVerbs = <String>{
    'напомни',
    'напомните',
    'напомнить',
    'добавь',
    'добавьте',
    'добавить',
    'запиши',
    'запишите',
    'записать',
    'создай',
    'создайте',
    'создать',
    'поставь',
    'поставьте',
    'внеси',
  };

  /// Инфинитивы, с которыми фраза всё ещё вопрос о погоде.
  static const Set<String> _askInfinitives = <String>{
    'узнать',
    'посмотреть',
    'показать',
    'сказать',
    'подсказать',
    'проверить',
    'ждать',
  };

  static const Set<String> _open = <String>{'открой', 'открыть', 'запусти'};

  static const Set<String> _past = <String>{'вчера', 'позавчера'};

  static const Set<String> _week = <String>{'неделю', 'неделе', 'неделя'};

  static const Set<String> _weekend = <String>{
    'выходные',
    'выходных',
    'выходной',
  };

  /// После «в» — не город: «на улице», «в доме», «в городе».
  static const Set<String> _notPlace = <String>{
    'улице',
    'городе',
    'офисе',
    'работе',
    'квартире',
    'комнате',
    'помещении',
    'целом',
    'общем',
    'итоге',
    'течение',
    'принципе',
    'что',
    'чем',
    'этом',
    'тот',
    'ту',
    'это',
    'эти',
    'выходные',
    'выходной',
    'неделю',
  };

  /// «Погода в доме», «в семье» — не о небе.
  static const Set<String> _home = <String>{
    'доме',
    'семье',
    'мире',
    'душе',
    'отношениях',
    'коллективе',
    'стране',
  };

  /// Служебные слова, на которых название города кончается.
  static const Set<String> _stop = <String>{
    'на',
    'и',
    'а',
    'в',
    'во',
    'сейчас',
    'завтра',
    'сегодня',
    'послезавтра',
    'будет',
    'будут',
    'какая',
    'какой',
    'как',
    'что',
    'есть',
    'ли',
    'утром',
    'днем',
    'вечером',
    'ночью',
    'погода',
    'погоду',
    'прогноз',
    'дождь',
    'снег',
  };

  static bool _remindQuestion(Utterance utterance) {
    final question = QuestionPhrases.detect(utterance);
    return question != null &&
        question.remindOpener &&
        question.kind == QuestionKind.info &&
        utterance.words.where(_taskVerbs.contains).length == 1;
  }

  /// Разбирает фразу; `null` — не о погоде.
  static WeatherAsk? parse(Utterance utterance, DateTime now) {
    final words = utterance.words;
    if (words.isEmpty) return null;
    // «Напомни, какая погода завтра» — вопрос, а не задача: «напомни»
    // здесь просит подсказать.
    if (words.any(_taskVerbs.contains) && !_remindQuestion(utterance)) {
      return null;
    }
    final weather = words.any(_weather.contains);
    var forecast = false;
    for (var i = 0; i < words.length; i++) {
      if (!_forecast.contains(words[i])) continue;
      if (i == words.length - 1 || _forecastNext.contains(words[i + 1])) {
        forecast = true;
      }
    }
    final rain = words.any(_rain.contains);
    final cold = words.any(_cold.contains);
    final wear =
        words.any(_wearVerbs.contains) && words.any(_wearQuestion.contains);
    final place = _place(utterance, weather || forecast);
    if (place == _homeMarker) return null;
    final temperature = words.any(_temperature.contains) &&
        (words.any(_temperatureContext.contains) || place != null) &&
        !words.any(_body.contains);
    final strong = weather || forecast;
    if (!strong && !rain && !cold && !wear && !temperature) return null;
    // «Купить зонт», «написать статью о погоде», «сдать отчёт о погоде» —
    // фраза с инфинитива задачи — это задача, даже если погода названа.
    final first = words.first;
    if (_looksInfinitive(first) &&
        !_wearVerbs.contains(first) &&
        !_askInfinitives.contains(first) &&
        !_open.contains(first)) {
      return null;
    }
    // «Статья о погоде», «отчёт про погоду» — погода как тема, не вопрос.
    if (!_askOpeners.contains(first) && _weatherAsTopic(words)) return null;
    // «Перенеси задачу про зонт», «выполнил задачу про зонт» — речь о задаче.
    if (!strong &&
        (_taskWordsAbout.contains(first) ||
            words.any((w) => w.startsWith('задач')))) {
      return null;
    }
    if (!strong) {
      // «Температура от -5 до 12 градусов» — числа, а не вопрос о погоде.
      if (!rain && !wear && !cold && utterance.numbers.length >= 2) {
        return null;
      }
    }

    final dueAt = utterance.due.dueAt;
    final today = DateTime(now.year, now.month, now.day);
    int? offset = dueAt == null
        ? null
        : (DateTime(dueAt.year, dueAt.month, dueAt.day)
                    .difference(today)
                    .inHours +
                12) ~/
            24;
    final weekend = words.any(_weekend.contains);
    final week = words.any(_week.contains);
    final next = words.any((w) => w.startsWith('следующ'));
    // «Погода в субботу» в субботу — о сегодняшнем дне, не через неделю.
    if (offset == 7 &&
        !next &&
        !words.contains('через') &&
        words.any(_weekdays.contains)) {
      offset = 0;
    }
    final past = words.any(_past.contains) || (offset != null && offset < 0);
    WeatherRange? range;
    if (weekend) {
      range = WeatherRange.weekend;
      if (now.weekday == DateTime.sunday && !next) {
        // В воскресенье «на выходных» — это сегодня, а не через шесть дней.
        offset = 0;
      } else {
        offset ??= now.weekday == DateTime.sunday
            ? 0
            : DateTime.saturday - now.weekday;
      }
    } else if (week && !wear) {
      range = WeatherRange.week;
    }

    WeatherAskKind kind;
    if (past) {
      kind = WeatherAskKind.past;
    } else if (offset != null && offset > 6) {
      kind = WeatherAskKind.range;
    } else if (wear) {
      kind = WeatherAskKind.wear;
    } else if (rain) {
      kind = WeatherAskKind.rain;
    } else if (range != null) {
      kind = WeatherAskKind.week;
    } else if (words.any(_open.contains) && offset == null) {
      kind = WeatherAskKind.open;
    } else if (offset != null && offset > 0) {
      kind = WeatherAskKind.day;
    } else {
      kind = WeatherAskKind.now;
    }
    return WeatherAsk(
      kind: kind,
      dayOffset: offset,
      range: range,
      placeQuery: place,
      strong: strong || temperature,
      date: offset == null
          ? null
          : DateTime(today.year, today.month, today.day + offset),
    );
  }

  /// «о погоде», «про погоду» — погода как тема фразы.
  static bool _weatherAsTopic(List<String> words) {
    for (var i = 0; i + 1 < words.length; i++) {
      if (_topicPrepositions.contains(words[i]) &&
          _weather.contains(words[i + 1])) {
        return true;
      }
    }
    return false;
  }

  static const Set<String> _weekdays = <String>{
    'понедельник',
    'вторник',
    'среду',
    'четверг',
    'пятницу',
    'субботу',
    'воскресенье',
  };

  static const Set<String> _topicPrepositions = <String>{
    'о',
    'об',
    'обо',
    'про',
  };

  /// С этих слов «о погоде» — всё ещё вопрос: «расскажи о погоде».
  static const Set<String> _askOpeners = <String>{
    'расскажи',
    'расскажите',
    'скажи',
    'скажите',
    'подскажи',
    'подскажите',
    'покажи',
    'покажите',
    'узнай',
    'что',
    'какая',
    'как',
    'есть',
    'новости',
  };

  /// Глаголы над задачей: «перенеси задачу про зонт», «отметь», «выполнил».
  static const Set<String> _taskWordsAbout = <String>{
    'перенеси',
    'перенесите',
    'отметь',
    'отметьте',
    'выполнил',
    'выполнила',
    'выполнено',
    'сделал',
    'сделала',
    'удали',
    'удалите',
    'заверши',
    'закрой',
  };

  static bool _looksInfinitive(String word) =>
      word.length > 3 &&
      !_notInfinitive.contains(word) &&
      (word.endsWith('ть') || word.endsWith('ти') || word.endsWith('чь'));

  /// Похожи на инфинитив, но нет: «кстати, завтра будет дождь».
  static const Set<String> _notInfinitive = <String>{
    'кстати',
    'почти',
    'прости',
    'опять',
    'пусть',
    'ведь',
    'есть',
  };

  static const String _homeMarker = '\u0000home';

  /// Город после «в/во» или сразу после «погода» с заглавной: «погода в
  /// Казани», «погода Москва». Слова, которые разбор сроков счёл датой
  /// («в субботу»), городом не считаются.
  static String? _place(Utterance utterance, bool marker) {
    final tokens = utterance.tokens;
    final spans = utterance.due.spans;
    bool usable(UtteranceToken t) =>
        !Utterance.isCovered(t, spans) &&
        !t.isNumber &&
        !_stop.contains(t.text) &&
        !_notPlace.contains(t.text);
    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      int? start;
      if ((token.text == 'в' || token.text == 'во') && i + 1 < tokens.length) {
        final next = tokens[i + 1];
        if (_home.contains(next.text)) return _homeMarker;
        if (usable(next)) start = i + 1;
      } else if (marker &&
          _weather.contains(token.text) &&
          i + 1 < tokens.length &&
          _capital(tokens[i + 1]) &&
          usable(tokens[i + 1])) {
        start = i + 1;
      }
      if (start == null) continue;
      var end = start;
      while (end + 1 < tokens.length && end - start < 3) {
        final next = tokens[end + 1];
        final gap = utterance.original.substring(
          tokens[end].span.end,
          next.span.start,
        );
        if (gap == '-') {
          end++;
          continue;
        }
        if (gap.trim().isNotEmpty || !usable(next)) break;
        final adjective = tokens[end].text.endsWith('ем') ||
            tokens[end].text.endsWith('ом') ||
            tokens[end].text.endsWith('ой');
        if ((_capital(tokens[end]) && _capital(next)) || adjective) {
          end++;
          continue;
        }
        break;
      }
      return utterance.original.substring(
        tokens[start].span.start,
        tokens[end].span.end,
      );
    }
    return null;
  }

  static bool _capital(UtteranceToken token) {
    final first = token.original.isEmpty ? '' : token.original[0];
    return first.isNotEmpty &&
        first != first.toLowerCase() &&
        first == first.toUpperCase();
  }
}
