import '../connectors/utterance.dart';
import '../connectors/verb_forms.dart';
import 'command_lexicon.g.dart';
import 'route_policy.dart';

/// Опечатки в словах команд любого навыка: «постпвь будильник на 7»,
/// «склоько венских стульев», «напомни заввтра в 10», «что пишло сегодня».
///
/// Разбор задач исправляет опечатки сам, но только в глаголе в начале и в
/// «задачу» после него; другие навыки видят слово с опечаткой и молчат.
/// Здесь — спасательный проход, как [LayoutFix]: только если фразу как есть
/// не понял никто явно, и только слова не из словаря команд
/// ([commandLexicon], собран из корпуса фраз), от пяти букв: короткие
/// слова слишком легко спутать («стол» — «стул»). Слово заменяется, если
/// рядом ровно одно слово словаря на расстоянии одной правки — не в первой
/// и не в последней букве ([Utterance.isTypoOf]); при двух соседях —
/// только если один встречается в корпусе втрое чаще. «Наполни», «записи»
/// и другие настоящие слова рядом с командами ([Utterance.isRealWord]) не
/// трогаются. Ещё — слитные слова («в7», «завтрав», «будильникна»,
/// «напомнизавтра»), правка конца слова там, где другой формы нет
/// («завтро», «завтар», «напомнь») и am/pm после часа. Исправить опечатку
/// по смыслу нельзя без словаря языка, поэтому запись после такого
/// исправления — только после «Да».
abstract final class TypoFix {
  /// Фраза с исправленными словами или `null`, если исправлять нечего.
  static String? repair(String text) => _repair(text, commandLexicon);

  /// Только слова срока: «напоми заввтра в 10 позвонить маме» — команду
  /// понял разбор задач, а «заввтра» стало бы частью названия и срок бы
  /// пропал. Исправленная так фраза берётся, если её понимает тот же навык
  /// той же командой ([sameCommand]).
  static String? repairDue(String text) => _repair(text, _dueLexicon);

  static String? _repair(String text, Map<String, int> lexicon) {
    if (text.length > 400) return null;
    final full = identical(lexicon, commandLexicon);
    // «В 7 pm» → «в 7 вечера», «в7» → «в 7».
    var fixed = _outsideQuotes(text, _amPm, (Match m) {
      final hour = int.parse(m.group(1)!);
      if (hour < 1 || hour > 12) return null;
      final pm = m.group(2)!.toLowerCase().startsWith('p');
      final part = pm
          ? (hour == 12 || hour <= 4 ? 'дня' : 'вечера')
          : (hour == 12 || hour <= 4 ? 'ночи' : 'утра');
      return '$hour $part';
    });
    fixed = _outsideQuotes(
      fixed,
      _gluedPreposition,
      (Match m) => '${m.group(1)} ${m.group(2)}',
    );
    fixed = _outsideQuotes(fixed, _word, (Match m) {
      final word = m.group(0)!;
      final lower = word.toLowerCase().replaceAll('ё', 'е');
      final replacement = _dialect[lower] ??
          (full ? _dialectVerbs[lower] : null) ??
          _unglue(lower, full: full) ??
          _fix(lower, lexicon) ??
          _fixEnding(lower, lexicon, full: full);
      if (replacement == null) return null;
      return _sameCase(word, replacement);
    });
    return fixed == text ? null : fixed;
  }

  /// [pattern] в [text] вне кавычек (там — название как сказано) заменяется
  /// тем, что вернёт [replace]; `null` — оставить как есть.
  static String _outsideQuotes(
    String text,
    RegExp pattern,
    String? Function(Match m) replace,
  ) {
    final quoted = <(int, int)>[
      for (final m in _quoted.allMatches(text)) (m.start, m.end),
    ];
    return text.replaceAllMapped(pattern, (Match m) {
      if (quoted.any(((int, int) q) => m.start >= q.$1 && m.end <= q.$2)) {
        return m.group(0)!;
      }
      return replace(m) ?? m.group(0)!;
    });
  }

  /// «7 pm», «7pm», «10 a.m.» — час по-английски.
  static final RegExp _amPm = RegExp(
    r'(?<![\d:.])(\d{1,2})\s*(pm|am|p\.m\.|a\.m\.)(?![a-z])',
    caseSensitive: false,
  );

  /// Предлог вплотную к числу: «в7», «к9», «на10:30».
  static final RegExp _gluedPreposition = RegExp(
    r'(?<![а-яёa-z0-9])(в|во|к|ко|до|на|через)(\d{1,2}(?::\d{2})?)(?![\d])',
    caseSensitive: false,
  );

  /// Слова из соседних языков и разговорные формы слов срока, которые
  /// часто вставляют в русскую речь: закрытый список.
  static const Map<String, String> _dialect = <String, String>{
    'зранку': 'утром',
    // Разговорное и устаревшее «чрез»: «напомни чрез час».
    'чрез': 'через',
    // Ласкательные части суток: «с утреца», «вечерком».
    'утреца': 'утра',
    'утречком': 'утром',
    'вечерком': 'вечером',
  };

  /// Глаголы команд оттуда же — только при полной правке (с «Да?»).
  static const Map<String, String> _dialectVerbs = <String, String>{
    'нагадай': 'напомни',
    'нагадайте': 'напомните',
  };

  /// Слова срока и навыков, к которым прилипает предлог: «завтрав 9»,
  /// «будильникна 7».
  static const Set<String> _anchorNouns = <String>{'будильник', 'таймер'};

  /// Без «к»: «завтрак» — настоящее слово, а не «завтра к».
  static const List<String> _tailPrepositions = <String>['во', 'в', 'на'];

  /// Два слова без пробела: срок или навык с предлогом («завтрав» →
  /// «завтра в»), а при полной правке ещё глагол команды со сроком или
  /// предметом («напомнизавтра» → «напомни завтра»). Иначе `null`.
  static String? _unglue(String word, {required bool full}) {
    if (word.length < 5 || commandLexicon.containsKey(word)) return null;
    if (Utterance.isRealWord(word) || _realWords.contains(word)) return null;
    for (final preposition in _tailPrepositions) {
      if (!word.endsWith(preposition)) continue;
      final head = word.substring(0, word.length - preposition.length);
      if (_dueWords.hasMatch(head) || _anchorNouns.contains(head)) {
        return '$head $preposition';
      }
    }
    if (!full) return null;
    for (var at = 5; at <= word.length - 4; at++) {
      final head = word.substring(0, at);
      final tail = word.substring(at);
      if (Utterance.isCommandVerb(head) &&
          (_dueWords.hasMatch(tail) ||
              _anchorNouns.contains(tail) ||
              tail == 'задачу')) {
        return '$head $tail';
      }
    }
    return null;
  }

  /// Правка в конце слова — только там, где другой формы нет: две
  /// последние буквы переставлены в слове срока («завтар»; у глагола
  /// «напомин» — обрывок «напоминания», не правится); «ь» вместо «и» у
  /// глагола команды («напомнь», «покажь») — только при полной правке, она
  /// всегда переспрашивает «Да?»; последняя буква в «завтра», «сегодня»,
  /// «послезавтра» («завтро»).
  static String? _fixEnding(
    String word,
    Map<String, int> lexicon, {
    required bool full,
  }) {
    if (word.length < 6 || commandLexicon.containsKey(word)) return null;
    if (Utterance.isRealWord(word) || _realWords.contains(word)) return null;
    bool verb(String candidate) => full && Utterance.isCommandVerb(candidate);
    final swapped = word.substring(0, word.length - 2) +
        word[word.length - 1] +
        word[word.length - 2];
    if (lexicon.containsKey(swapped) && _dueWords.hasMatch(swapped)) {
      return swapped;
    }
    final stem = word.substring(0, word.length - 1);
    if (word.endsWith('ь') && verb('$stemи')) return '$stemи';
    for (final day in _dayEndings) {
      if (day.length == word.length && day.startsWith(stem)) return day;
    }
    return null;
  }

  static const List<String> _dayEndings = <String>[
    'завтра',
    'сегодня',
    'послезавтра',
  ];

  /// Взять ли исправленный разбор — по тому же правилу, что раскладка:
  /// фразу как есть не понял никто явно, исправленную — навык.
  ///
  /// Навык, который как есть только переспросил (догадка `implicit`:
  /// «сколько будет 125 умножитть на 4» — «Не понял пример»), уступает
  /// исправленной фразе той же своей команды, понятой явно.
  static bool prefer(RouteDecision original, RouteDecision repaired) {
    final was = original.winner;
    final winner = repaired.winner;
    if (was != null &&
        was.implicit &&
        !original.isAmbiguous &&
        winner != null &&
        !repaired.isAmbiguous &&
        !winner.implicit &&
        !winner.fallback &&
        winner.connectorId == was.connectorId &&
        winner.commandId == was.commandId) {
      return true;
    }
    if (original.isAmbiguous || (was != null && !was.fallback)) return false;
    if (winner == null || repaired.isAmbiguous) return false;
    if (!winner.fallback) return true;
    return was == null && !winner.commandId.endsWith('.question');
  }

  /// Исправленный срок у той же команды того же навыка.
  static bool sameCommand(RouteDecision original, RouteDecision repaired) {
    final was = original.winner;
    final winner = repaired.winner;
    return was != null &&
        winner != null &&
        !repaired.isAmbiguous &&
        was.connectorId == winner.connectorId &&
        was.commandId == winner.commandId;
  }

  static final RegExp _word = RegExp('[а-яёА-ЯЁ]+');

  static final RegExp _quoted = RegExp('«[^»]*»|"[^"]*"|„[^“”]*[“”]');

  /// Настоящие слова в одной правке от слова срока или команды: «надели»
  /// — не «недели», «марка» — не «марта», «входных» — не «выходных».
  static const Set<String> _realWords = <String>{
    'надели',
    'наделю',
    'марка',
    'марки',
    'марку',
    'маркой',
    'входных',
    'входные',
    'входной',
    'чатов',
    'чатом',
    'минус',
    'утрам',
    'вечерам',
    'ночам',
  };

  static String? _fix(String word, Map<String, int> lexicon) {
    if (word.length < 5 || commandLexicon.containsKey(word)) return null;
    if (Utterance.isRealWord(word) || _realWords.contains(word)) return null;
    // Растянутая буква: «завтраа», «напоомни» — одна из двух одинаковых
    // подряд лишняя, и без неё получается слово словаря.
    final squeezed = <String>{
      for (var i = 0; i + 1 < word.length; i++)
        if (word[i] == word[i + 1])
          word.substring(0, i) + word.substring(i + 1),
    }.where(lexicon.containsKey).toList();
    if (squeezed.length == 1) return squeezed.single;
    // «По утрам», «по вечерам», «по средам» — дательный множественного, а
    // не опечатка в «утром», «вечером».
    if (word.endsWith('ам') || word.endsWith('ям')) return null;
    // Инфинитив — настоящее слово, а не опечатка в повелительном: «а как
    // перенести задачу?» — вопрос, «перенеси» сделало бы его командой.
    final infinitive = VerbForms.isInfinitive(word);
    String? best;
    var bestCount = 0;
    var second = 0;
    for (final MapEntry(key: candidate, value: count) in lexicon.entries) {
      if (candidate[0] != word[0] ||
          (candidate.length - word.length).abs() > 1 ||
          !Utterance.isTypoOf(word, candidate)) {
        continue;
      }
      if (infinitive && !VerbForms.isInfinitive(candidate)) continue;
      if (count > bestCount) {
        second = bestCount;
        bestCount = count;
        best = candidate;
      } else if (count > second) {
        second = count;
      }
    }
    if (best == null) return null;
    if (second > 0 && bestCount < 3 * second) return null;
    return best;
  }

  /// Слова срока из словаря команд: дни, части суток, единицы времени,
  /// месяцы.
  static final Map<String, int> _dueLexicon = <String, int>{
    for (final MapEntry(:key, :value) in commandLexicon.entries)
      if (_dueWords.hasMatch(key)) key: value,
  };

  static final RegExp _dueWords = RegExp(
    r'^(?:сегодня|завтра|послезавтра|вчера|утром|утра|вечером|вечера|'
    r'днем|ночью|минут[аы]?|минуту|секунд[аы]?|часов|часа|недел[июе]|'
    r'месяц[аеу]?|понедельник|вторник|среду|четверг|пятницу|субботу|'
    r'воскресенье|выходных|январ[яь]|феврал[яь]|марта|апреля|мая|июня|'
    r'июля|августа|сентября|октября|ноября|декабря|через|'
    // Длинные числа словами: у коротких («шесть», «семь») рядом настоящие
    // слова («шерсть», «семья»).
    r'одиннадцать|двенадцать|пятнадцать|двадцать|тридцать|пятьдесят)$',
  );

  /// [replacement] в регистре [word]: «Пакажи» → «Покажи».
  static String _sameCase(String word, String replacement) {
    final upper = word[0] != word[0].toLowerCase();
    if (!upper) return replacement;
    return replacement[0].toUpperCase() + replacement.substring(1);
  }
}
