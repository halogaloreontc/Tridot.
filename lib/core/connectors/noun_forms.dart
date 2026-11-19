import 'verb_forms.dart';

/// Падеж начала названия, которое нужно привести к именительному.
enum _Case {
  /// Без предлога или после «про»: «встречу» → «встреча».
  accusative,

  /// После «о», «об»: «о встрече» → «встреча».
  prepositional,

  /// После «насчёт», «по поводу»: «насчёт оплаты» → «оплата».
  genitive,
}

/// Замена окончания: у слова, которое (в нормализованном виде) кончается
/// на [from], эти буквы меняются на [to].
final class _Ending {
  const _Ending(this.from, this.to);

  final String from;
  final String to;
}

/// Приведение начала названия задачи к именительному падежу: «напомни про
/// встречу с клиентом» → «Встреча с клиентом», «о звонке маме» → «Звонок
/// маме», «добавь новую презентацию» → «Новая презентация».
///
/// Без словаря русского языка: правила по частым окончаниям и короткие
/// списки слов, которые правила разбирают неверно. Меняется только главное
/// слово начальной именной группы и прилагательные перед ним; всё после
/// него остаётся как написано. Если форма не ясна — название не меняется
/// вовсе: лучше «О Москве», чем испорченное слово.
abstract final class NounForms {
  /// Предлоги и союзы, на которых кончается начальная именная группа.
  static const Set<String> _boundaries = <String>{
    'с',
    'со',
    'к',
    'ко',
    'в',
    'во',
    'на',
    'для',
    'по',
    'у',
    'от',
    'до',
    'из',
    'за',
    'о',
    'об',
    'обо',
    'про',
    'при',
    'без',
    'через',
    'перед',
    'после',
    'между',
    'над',
    'под',
    'и',
    'или',
    'а',
    'но',
    'что',
    'чтобы',
    'как',
  };

  /// Несклоняемые слова: «про кофе», «о такси» — именительный тот же.
  static const Set<String> _indeclinable = <String>{
    'кофе',
    'такси',
    'метро',
    'кино',
    'кафе',
    'меню',
    'пальто',
    'радио',
    'интервью',
    'резюме',
    'пюре',
    'шоссе',
    'хобби',
    'депо',
    'фото',
    'видео',
    'авто',
    'жалюзи',
    // На «-у»/«-ю»: без них правило винительного дало бы «Рага», «Бака».
    'рагу',
    'кенгуру',
    'баку',
    'табу',
    'гуру',
    'ушу',
    'иглу',
    'какаду',
    'фондю',
    'барбекю',
    'авеню',
    'ревю',
    'дежавю',
  };

  /// Формы на «-у»/«-ю», которые не винительный падеж существительного
  /// женского рода: глаголы первого лица («куплю», «иду») и дательный
  /// падеж частых слов о людях («клиенту», «врачу»). Без них «добавь
  /// клиенту счёт» стало бы «Клиента счёт».
  static const Set<String> _notFeminineAccusative = <String>{
    'иду',
    'еду',
    'жду',
    'веду',
    'везу',
    'несу',
    'бегу',
    'кладу',
    'пеку',
    'ищу',
    'пойду',
    'приду',
    'зайду',
    'заеду',
    'буду',
    'могу',
    'хочу',
    'куплю',
    'позвоню',
    'напишу',
    'схожу',
    'съезжу',
    'сделаю',
    'заберу',
    'возьму',
    'отвезу',
    'привезу',
    'отнесу',
    'принесу',
    'плачу',
    'лечу',
    'учу',
    'прошу',
    'люблю',
    'сплю',
    'говорю',
    'смотрю',
    'клиенту',
    'брату',
    'другу',
    'врачу',
    'директору',
    'начальнику',
    'сыну',
    'мужу',
    'деду',
    'соседу',
    'мастеру',
    'курьеру',
    'юристу',
    'бухгалтеру',
    'менеджеру',
    'партнеру',
    'поставщику',
    'учителю',
    'доктору',
    'стоматологу',
    'парикмахеру',
    'ивану',
    'петру',
    'игорю',
    'олегу',
    'антону',
    'максиму',
    'денису',
    'борису',
    'роману',
    'артему',
    'павлу',
    'михаилу',
    'егору',
    'глебу',
    'ильдару',
    'тимуру',
    'кириллу',
    'владу',
    'дмитрию',
    'юрию',
    'василию',
    'анатолию',
    'виталию',
    'евгению',
    'арсению',
    'валерию',
    'геннадию',
    'григорию',
    'коллективу',
    'дню',
    'ночью',
    'утру',
    'вечеру',
    'обеду',
    'понедельнику',
    'вторнику',
    'четвергу',
    'пятницу',
    'среду',
    'субботу',
    'воскресенью',
    'неделю',
    'выходному',
    'тому',
    'этому',
    'всему',
    'кому',
    'чему',
    'нему',
    'ему',
    'мою',
    'твою',
    'свою',
    'нашу',
    'вашу',
    'эту',
    'ту',
    'всю',
    'одну',
    'какую',
  };

  /// Существительные на «-ью» в винительном падеже: остальные слова
  /// на «-ью» — творительный падеж («ночью», «солью») или глаголы («пью»).
  static const Map<String, String> _accusativeYu = <String, String>{
    'статью': 'статья',
    'семью': 'семья',
    'судью': 'судья',
    'гостью': 'гостья',
    'скамью': 'скамья',
  };

  /// Местоимения и порядковые числительные перед существительным женского
  /// рода в винительном падеже: «мою встречу» → «моя встреча». Общее
  /// правило прилагательных («-ую» → «-ая») их не разбирает.
  static const Map<String, String> _accusativePronouns = <String, String>{
    'мою': 'моя',
    'твою': 'твоя',
    'свою': 'своя',
    'нашу': 'наша',
    'вашу': 'ваша',
    'эту': 'эта',
    'ту': 'та',
    'одну': 'одна',
    'всю': 'вся',
    'третью': 'третья',
  };

  /// То же в предложном и родительном падежах: «о моей встрече», «насчёт
  /// нашей встречи». Без списка правило «-ей» → «-яя» дало бы «Мояя».
  static const Map<String, String> _obliquePronouns = <String, String>{
    'моей': 'моя',
    'твоей': 'твоя',
    'своей': 'своя',
    'нашей': 'наша',
    'вашей': 'ваша',
    'этой': 'эта',
    'той': 'та',
    'одной': 'одна',
    'всей': 'вся',
    'третьей': 'третья',
  };

  /// Предложный падеж частых слов, которые правила окончаний не разбирают:
  /// мужской род на согласную («о плане»), беглая гласная («о звонке»),
  /// средний род («о письме»).
  static const Map<String, _Ending> _prepositionalWords = <String, _Ending>{
    'плане': _Ending('е', ''),
    'отчете': _Ending('е', ''),
    'проекте': _Ending('е', ''),
    'договоре': _Ending('е', ''),
    'счете': _Ending('е', ''),
    'платеже': _Ending('е', ''),
    'билете': _Ending('е', ''),
    'бюджете': _Ending('е', ''),
    'ответе': _Ending('е', ''),
    'совете': _Ending('е', ''),
    'ремонте': _Ending('е', ''),
    'концерте': _Ending('е', ''),
    'паспорте': _Ending('е', ''),
    'сайте': _Ending('е', ''),
    'заказе': _Ending('е', ''),
    'визите': _Ending('е', ''),
    'приеме': _Ending('е', ''),
    'созвоне': _Ending('е', ''),
    'разговоре': _Ending('е', ''),
    'докладе': _Ending('е', ''),
    'вебинаре': _Ending('е', ''),
    'семинаре': _Ending('е', ''),
    'экзамене': _Ending('е', ''),
    'отпуске': _Ending('е', ''),
    'переезде': _Ending('е', ''),
    'ужине': _Ending('е', ''),
    'обеде': _Ending('е', ''),
    'магазине': _Ending('е', ''),
    'документе': _Ending('е', ''),
    'результате': _Ending('е', ''),
    'формате': _Ending('е', ''),
    'уроке': _Ending('е', ''),
    'завтраке': _Ending('е', ''),
    'чеке': _Ending('е', ''),
    'банке': _Ending('е', ''),
    'парке': _Ending('е', ''),
    'матче': _Ending('е', ''),
    'враче': _Ending('е', ''),
    'ключе': _Ending('е', ''),
    'звонке': _Ending('ке', 'ок'),
    'подарке': _Ending('ке', 'ок'),
    'рынке': _Ending('ке', 'ок'),
    'дне': _Ending('не', 'ень'),
    'письме': _Ending('е', 'о'),
    'деле': _Ending('е', 'о'),
    'собрании': _Ending('и', 'е'),
    'маме': _Ending('е', 'а'),
    'папе': _Ending('е', 'а'),
    'машине': _Ending('е', 'а'),
    'работе': _Ending('е', 'а'),
    'субботе': _Ending('е', 'а'),
    'почте': _Ending('е', 'а'),
    'карте': _Ending('е', 'а'),
    'анкете': _Ending('е', 'а'),
    'статье': _Ending('е', 'я'),
    'семье': _Ending('е', 'я'),
    'неделе': _Ending('е', 'я'),
    'лекции': _Ending('и', 'я'),
    'компании': _Ending('и', 'я'),
    'кампании': _Ending('и', 'я'),
    'линии': _Ending('и', 'я'),
    'серии': _Ending('и', 'я'),
    'ксении': _Ending('и', 'я'),
    'германии': _Ending('и', 'я'),
    'испании': _Ending('и', 'я'),
    'британии': _Ending('и', 'я'),
    'дании': _Ending('и', 'я'),
    'поездке': _Ending('е', 'а'),
  };

  /// Предложный падеж на «-ии», который не угадать: мужской род на «-ий»
  /// («о сценарии», «о гении», «о Евгении») или средний и женский род
  /// с одинаковым окончанием («о пособии», «об условии»). Остаются как
  /// написаны.
  static const Set<String> _unclearIi = <String>{
    'евгении',
    'арсении',
    'геннадии',
    'аркадии',
    'валерии',
    'гении',
    'санатории',
    'репозитории',
    'пособии',
  };

  /// Мужской род на «-аче», «-аше» в предложном падеже: «о враче»,
  /// «о карандаше» — правило «-е» → «-а» для них неверно.
  static const Set<String> _masculineHushing = <String>{
    'враче',
    'калаче',
    'карандаше',
    'шалаше',
  };

  /// Женский род на «-ь» в родительном падеже на «-ечи»: «насчёт речи».
  static const Set<String> _softEchi = <String>{
    'речи',
    'печи',
    'течи',
  };

  /// Родительный падеж частых слов мужского и среднего рода на «-а»:
  /// «насчёт отчёта», «насчёт письма».
  static const Map<String, _Ending> _genitiveWords = <String, _Ending>{
    'отчета': _Ending('а', ''),
    'плана': _Ending('а', ''),
    'проекта': _Ending('а', ''),
    'договора': _Ending('а', ''),
    'счета': _Ending('а', ''),
    'платежа': _Ending('а', ''),
    'билета': _Ending('а', ''),
    'бюджета': _Ending('а', ''),
    'ремонта': _Ending('а', ''),
    'заказа': _Ending('а', ''),
    'визита': _Ending('а', ''),
    'созвона': _Ending('а', ''),
    'разговора': _Ending('а', ''),
    'доклада': _Ending('а', ''),
    'отпуска': _Ending('а', ''),
    'переезда': _Ending('а', ''),
    'ужина': _Ending('а', ''),
    'обеда': _Ending('а', ''),
    'документа': _Ending('а', ''),
    'урока': _Ending('а', ''),
    'звонка': _Ending('ка', 'ок'),
    'подарка': _Ending('ка', 'ок'),
    'дня': _Ending('ня', 'ень'),
    'письма': _Ending('а', 'о'),
    'дела': _Ending('а', 'о'),
  };

  /// Мужской род на «-ате» в предложном падеже: «о результате».
  static const Set<String> _masculineAte = <String>{
    'результате',
    'формате',
    'салате',
    'адвокате',
    'кандидате',
    'штате',
    'халате',
    'банкомате',
    'автомате',
    'депутате',
    'аппарате',
  };

  /// Приводит начало названия [text] к именительному падежу.
  ///
  /// [allowPreposition]: название может начинаться с «про», «о», «об»,
  /// «насчёт», «по поводу» — их убирают, если главное слово после них
  /// удалось привести («о звонке маме» → «звонок маме»). Иначе предлог
  /// остаётся: «о Москве».
  ///
  /// [allowPo]: ещё и «по» — для цели завершения: «закрой задачу по
  /// подготовке презентации» → «подготовка презентации». Слово после «по»
  /// приводится по правилам предложного падежа (у слов на «-а/-я» дательный
  /// с ним совпадает); иначе «по» остаётся: «по отчёту».
  ///
  /// Название с инфинитивом не меняется: «машину помыть», «Машу
  /// забрать» — винительный падеж там к месту. Предлог прямо перед
  /// инфинитивом убирается: «про позвонить подруге» → «позвонить подруге».
  /// Без предлога главное слово
  /// меняется, только если за ним конец группы: «встречу провёл»,
  /// «клиенту счёт» остаются как написано.
  static String nominative(
    String text, {
    bool allowPreposition = true,
    bool allowPo = false,
  }) {
    final words = _word.allMatches(text).toList(growable: false);
    if (words.isEmpty) return text;
    final normalized = <String>[
      for (final word in words) _normalize(word.group(0)!),
    ];
    if (allowPreposition &&
        words.length > 1 &&
        _infinitivePrepositions.contains(normalized.first) &&
        VerbForms.isInfinitive(normalized[1])) {
      return text.substring(words[1].start);
    }
    if (normalized.any(VerbForms.isInfinitive)) return text;
    bool adjacent(int left, int right) =>
        text.substring(words[left].end, words[right].start).trim().isEmpty;

    var start = 0;
    var grammaticalCase = _Case.accusative;
    var hasPreposition = false;
    if (allowPreposition) {
      final first = normalized.first;
      if (first == 'о' || first == 'об' || first == 'обо') {
        grammaticalCase = _Case.prepositional;
        start = 1;
      } else if (first == 'про') {
        start = 1;
      } else if (allowPo &&
          first == 'по' &&
          (normalized.length < 2 || normalized[1] != 'поводу')) {
        grammaticalCase = _Case.prepositional;
        start = 1;
      } else if (first == 'насчет') {
        grammaticalCase = _Case.genitive;
        start = 1;
      } else if (first == 'по' &&
          normalized.length > 1 &&
          normalized[1] == 'поводу') {
        grammaticalCase = _Case.genitive;
        start = 2;
      }
      hasPreposition = start > 0;
    }
    if (start >= words.length || (start > 0 && !adjacent(start - 1, start))) {
      return text;
    }

    // Прилагательные перед главным словом: «новую презентацию», «о новой
    // встрече».
    var head = start;
    while (head + 1 < words.length &&
        adjacent(head, head + 1) &&
        _adjective(normalized[head], grammaticalCase) != null &&
        !_boundaries.contains(normalized[head + 1])) {
      head++;
    }
    final headWord = words[head].group(0)!;
    final headNominative = _head(
      headWord,
      normalized[head],
      grammaticalCase,
      // Без предлога «-у» может быть и дательным падежом («клиенту
      // счёт»): винительный — только если дальше конец группы.
      strict: !hasPreposition,
      next: head + 1 < words.length && adjacent(head, head + 1)
          ? normalized[head + 1]
          : null,
    );
    if (headNominative == null) return text;
    final feminine = headNominative != headWord &&
        (headNominative.endsWith('а') || headNominative.endsWith('я'));

    final replacements = <int, String>{head: headNominative};
    for (var i = start; i < head; i++) {
      final ending = _adjective(normalized[i], grammaticalCase);
      // Прилагательное меняется только при главном слове женского рода:
      // «о новом проекте» — род и окончание не угадать.
      if (ending == null || !feminine) return text;
      replacements[i] = _apply(words[i].group(0)!, ending);
    }
    if (!hasPreposition &&
        replacements.entries.every(
          (MapEntry<int, String> e) => words[e.key].group(0) == e.value,
        )) {
      return text;
    }

    final buffer = StringBuffer();
    var position = hasPreposition ? words[start].start : 0;
    for (var i = start; i <= head; i++) {
      buffer
        ..write(text.substring(position, words[i].start))
        ..write(replacements[i] ?? words[i].group(0));
      position = words[i].end;
    }
    buffer.write(text.substring(position));
    return buffer.toString();
  }

  static final RegExp _word = RegExp('[A-Za-zА-Яа-яЁё0-9]+');

  /// Предлоги, которые убираются перед инфинитивом: «про позвонить маме».
  static const Set<String> _infinitivePrepositions = <String>{
    'про',
    'о',
    'об',
    'насчет',
  };

  static String _normalize(String word) =>
      word.toLowerCase().replaceAll('ё', 'е');

  static const String _vowels = 'аеёиоуыэюя';

  static String _apply(String word, _Ending ending) =>
      word.substring(0, word.length - ending.from.length) + ending.to;

  /// Окончание прилагательного для замены или `null`, если слово не
  /// прилагательное нужной формы женского рода.
  static _Ending? _adjective(String word, _Case grammaticalCase) {
    final pronoun = (grammaticalCase == _Case.accusative
        ? _accusativePronouns
        : _obliquePronouns)[word];
    // «мою» → «моя»: заменяется всё слово.
    if (pronoun != null) return _Ending(word, pronoun);
    if (word.length < 4) return null;
    switch (grammaticalCase) {
      case _Case.accusative:
        if (word.endsWith('ую')) return const _Ending('ую', 'ая');
        if (word.endsWith('юю')) return const _Ending('юю', 'яя');
        return null;
      case _Case.prepositional:
      case _Case.genitive:
        final before = word[word.length - 3];
        // «чьей», «двоей» — перед окончанием гласная или «ь»: местоимение
        // или числительное не из списка. Не трогаем.
        if (_vowels.contains(before) || before == 'ь') return null;
        if (word.endsWith('ой')) return const _Ending('ой', 'ая');
        if (word.endsWith('ей')) {
          // «хорошей» → «хорошая», «синей» → «синяя».
          return 'жшчщ'.contains(before)
              ? const _Ending('ей', 'ая')
              : const _Ending('ей', 'яя');
        }
        return null;
    }
  }

  /// Главное слово в именительном падеже, само слово, если форма та же,
  /// или `null`, если форма не ясна.
  static String? _head(
    String word,
    String normalized,
    _Case grammaticalCase, {
    required bool strict,
    required String? next,
  }) {
    // «ДР», «МФЦ» — сокращения не склоняются.
    if (word.length >= 2 &&
        word == word.toUpperCase() &&
        RegExp('^[А-ЯЁ]+\$').hasMatch(word)) {
      return word;
    }
    if (_indeclinable.contains(normalized)) return word;
    // Латиница, числа, артикулы — не трогаем.
    if (!RegExp('^[а-я]+\$').hasMatch(normalized) || normalized.length < 3) {
      return null;
    }
    switch (grammaticalCase) {
      case _Case.accusative:
        return _accusative(word, normalized, strict: strict, next: next);
      case _Case.prepositional:
        return _prepositional(word, normalized);
      case _Case.genitive:
        return _genitive(word, normalized);
    }
  }

  static String? _accusative(
    String word,
    String normalized, {
    required bool strict,
    required String? next,
  }) {
    final feminine = _feminineAccusative(normalized);
    if (feminine == null) {
      if (strict) return word;
      // После «про»: «про отчёт», «про письмо», «про документы» — форма
      // та же. «Про клиента» — одушевлённый, именительный не угадать.
      final last = normalized[normalized.length - 1];
      if (last == 'а' || last == 'я') return null;
      if (last == 'у' || last == 'ю') return null;
      return word;
    }
    // «встречу клиента», «покупку кофе», «встречу с клиентом» — дальше
    // конец группы, родительный падеж или несклоняемое слово. «Клиенту
    // счёт», «Ивану подарок» — дательный: название не меняется.
    if (strict && next != null && !_endsGroup(next, normalized)) return word;
    return _apply(word, feminine);
  }

  static _Ending? _feminineAccusative(String word) {
    if (_notFeminineAccusative.contains(word)) return null;
    // «заказчику», «поставщику» — дательный падеж мужского рода.
    if (word.endsWith('чику') || word.endsWith('щику')) return null;
    final yu = _accusativeYu[word];
    if (yu != null) return const _Ending('ью', 'ья');
    if (word.length < 3) return null;
    if (word.endsWith('ию')) return const _Ending('ю', 'я');
    final before = word[word.length - 2];
    if (_vowels.contains(before) || before == 'ь' || before == 'ъ') {
      return null;
    }
    if (word.endsWith('у')) return const _Ending('у', 'а');
    if (word.endsWith('ю')) {
      // «дыню» → «дыня», «Олю» → «Оля»; «чью», «пью» — нет.
      return const _Ending('ю', 'я');
    }
    return null;
  }

  /// Слово после главного не мешает винительному падежу: предлог или союз,
  /// родительный падеж («клиента», «команды», «документов»), несклоняемое.
  ///
  /// «-ы/-и» бывает и родительным единственного («уборку квартиры»),
  /// и множественным числом («Олегу цветы» — дательный при главном слове).
  /// Поэтому с ним главное слово [head] меняется, только если по суффиксу
  /// это точно женский род: «уборку», «встречу», «презентацию».
  static bool _endsGroup(String next, String head) {
    if (_boundaries.contains(next) || _indeclinable.contains(next)) {
      return true;
    }
    if (!RegExp('^[а-я]+\$').hasMatch(next)) return true;
    final length = head.length;
    final surelyFeminine = (head.endsWith('ку') &&
            length >= 4 &&
            !_vowels.contains(head[length - 3])) ||
        head.endsWith('цию') ||
        head.endsWith('сию') ||
        head.endsWith('ачу') ||
        head.endsWith('ечу');
    if (next.endsWith('ы') || next.endsWith('и')) return surelyFeminine;
    // «Покупку шин», «доставку штор» — родительный множественного без
    // окончания: только при точно женском главном слове.
    final last = next[next.length - 1];
    // «Встречу провёл» — глагол прошедшего времени, а не родительный.
    if (surelyFeminine &&
        !_vowels.contains(last) &&
        last != 'й' &&
        last != 'л') {
      return true;
    }
    return next.endsWith('а') ||
        next.endsWith('я') ||
        next.endsWith('ов') ||
        next.endsWith('ев') ||
        next.endsWith('ей');
  }

  static String? _prepositional(String word, String normalized) {
    final known = _prepositionalWords[normalized];
    if (known != null) return _apply(word, known);
    if (normalized.endsWith('ии')) return _prepositionalIi(word, normalized);
    final length = normalized.length;
    // «о поездке», «о покупке», «о бабушке», «о справке» → «-ка». Только
    // после согласных, с которыми «-ке» — женский род: «о списке»,
    // «о ребёнке», «о ноутбуке», «о вторнике» — мужской, их не трогаем.
    if (normalized.endsWith('ке') &&
        length >= 4 &&
        'вдзплмршжч'.contains(normalized[length - 3])) {
      return _apply(word, const _Ending('е', 'а'));
    }
    // «о встрече», «о задаче», «о даче» → «-а»; «о малыше», «о плаще»,
    // «о борще» — мужской род, не трогаем.
    if ((normalized.endsWith('аче') || normalized.endsWith('ече')) &&
        !_masculineHushing.contains(normalized)) {
      return _apply(word, const _Ending('е', 'а'));
    }
    // «о Маше», «о Даше», «о каше», «о Мише», «о Лёше» → «-а».
    if ((normalized.endsWith('аше') ||
            normalized.endsWith('оше') ||
            normalized.endsWith('еше') ||
            normalized.endsWith('ише') ||
            normalized.endsWith('юше')) &&
        !_masculineHushing.contains(normalized)) {
      return _apply(word, const _Ending('е', 'а'));
    }
    // «об оплате», «о зарплате», «о дате» → «-а»; «о брате», «о салате»,
    // «о результате» — мужской род.
    if ((normalized.endsWith('лате') || normalized == 'дате') &&
        !_masculineAte.contains(normalized)) {
      return _apply(word, const _Ending('е', 'а'));
    }
    // «о здоровье», «о воскресенье» — та же форма.
    if (normalized.endsWith('ье')) return word;
    return null;
  }

  /// Предложный падеж на «-ии»: «-ие» среднего рода («о собрании»,
  /// «о событии», «о путешествии») и «-ия» женского («о гарантии»,
  /// «о церемонии», «о презентации»). Окончание одно, поэтому решает
  /// суффикс; где он не помогает — `null`.
  static String? _prepositionalIi(String word, String normalized) {
    if (_unclearIi.contains(normalized)) return null;
    // Имена и страны с заглавной буквы: «о Дмитрии», «о Юрии» — мужской
    // род на «-ий». Известные страны — в [_prepositionalWords].
    if (word[0] != word[0].toLowerCase()) return null;
    const neuter = _Ending('и', 'е');
    const feminine = _Ending('и', 'я');
    bool ends(List<String> suffixes) => suffixes.any(normalized.endsWith);
    // «о собрании», «о решении», «о событии», «о занятии», «об участии»,
    // «о путешествии», «о столетии».
    if (ends(const <String>[
      'ании',
      'ении',
      'ытии',
      'итии',
      'ятии',
      'стии',
      'етии',
      'ствии',
    ])) {
      return _apply(word, neuter);
    }
    // «о гарантии», «о партии», «о демократии».
    if (ends(const <String>['нтии', 'ртии', 'атии'])) {
      return _apply(word, feminine);
    }
    // «о сценарии», «о комментарии», «о критерии» — мужской род на «-ий»;
    // «об условии», «о пособии» — средний. Не угадать.
    if (ends(const <String>['арии', 'ерии', 'вии', 'бии', 'тии'])) {
      return null;
    }
    // «о презентации», «о пенсии», «о премии», «об истории», «о церемонии»,
    // «о фамилии», «о трагедии», «о стратегии».
    return _apply(word, feminine);
  }

  static String? _genitive(String word, String normalized) {
    final known = _genitiveWords[normalized];
    if (known != null) return _apply(word, known);
    // «насчёт Евгения», «насчёт Дмитрия» — имя мужского рода на «-ий».
    if (normalized.endsWith('ия') && word[0] != word[0].toLowerCase()) {
      return null;
    }
    // «насчёт собрания» → «собрание».
    if (normalized.endsWith('ния') || normalized.endsWith('тия')) {
      return _apply(word, const _Ending('я', 'е'));
    }
    // «насчёт презентации» → «презентация».
    if (normalized.endsWith('ии')) return _apply(word, const _Ending('и', 'я'));
    // «насчёт оплаты» → «оплата».
    if (normalized.endsWith('ы')) return _apply(word, const _Ending('ы', 'а'));
    // «насчёт поездки», «насчёт книги» → «-а».
    if (normalized.endsWith('ки') ||
        normalized.endsWith('ги') ||
        normalized.endsWith('хи')) {
      return _apply(word, const _Ending('и', 'а'));
    }
    // «насчёт встречи», «задачи», «Маши», «продажи» → «-а»; «насчёт
    // помощи», «ночи», «речи», «вещи» — женский род на «-ь», не трогаем.
    if ((normalized.endsWith('ачи') ||
            (normalized.endsWith('ечи') && !_softEchi.contains(normalized)) ||
            normalized.endsWith('аши') ||
            normalized.endsWith('ажи')) &&
        normalized.length >= 4) {
      return _apply(word, const _Ending('и', 'а'));
    }
    return null;
  }
}
