/// «Помощь в постановке задачи» (ADR-022): подсказка команд, когда фразу
/// не понял ни один навык.
///
/// Вспомогательный путь на редкий случай — опечатка или искажённое слово
/// в команде. Фраза из правильно написанных слов подсказок не получает,
/// даже если в ней есть слово команды («сколько тебе лет», «проект
/// мечты»): это не норма ответа, а помощь при ошибке. Включается только там, где раньше был голый ответ
/// «не понял» (`common.unknown`): понятые фразы и фразы, на которые уже
/// есть уточняющий вопрос, сюда не попадают. Подсказка ничего не
/// запоминает: ни «фраза → команда», ни выбор подсказки. Похожесть —
/// нечёткое совпадение слов фразы с ключевыми словами команд каталога
/// ([CommandCatalog]) с поправкой на опечатку, при равенстве — по
/// счётчикам выбора команд ([CommandUsage]).
///
/// Чистый Dart: ни Flutter, ни ввода-вывода.
library;

import '../chats/chat_search.dart';
import '../passwords/secret_guard.dart';
import 'command_catalog.dart';

/// Одна подсказка: команда каталога и шаблон для поля ввода.
final class CommandSuggestion {
  const CommandSuggestion({
    required this.entryId,
    required this.label,
    required this.template,
  });

  /// Id команды каталога (`task.list`).
  final String entryId;

  /// Подпись кнопки: подпись команды в каталоге.
  final String label;

  /// Шаблон для поля ввода; `|` — место курсора. Если в шаблоне было
  /// место для названия и слова пользователя очевидно туда ложатся, они
  /// уже подставлены, а курсор — в конце.
  final String template;
}

/// Подсказки под ответом «не до конца понял»: от одной до [maxCommands]
/// команд и последней кнопкой — «Найти команду». Без похожих команд
/// подсказок нет вовсе: ответ «не понял» остаётся прежним.
final class CommandSuggestions {
  const CommandSuggestions(this.commands);

  final List<CommandSuggestion> commands;

  /// Подпись последней кнопки.
  static const String findLabel = 'Найти команду';

  /// Больше команд не предлагаем: это подсказка, а не меню.
  static const int maxCommands = 3;
}

/// Подбор похожих команд для непонятой фразы.
abstract final class CommandSuggester {
  /// Похожие команды для [text] из [catalog]; пусто — похожих нет или
  /// фраза о паролях ([isPrivate]). [usage] — счётчики выбора команд:
  /// только порядок при равной похожести.
  static List<CommandSuggestion> suggest(
    String text,
    CommandCatalog catalog, {
    Map<String, int> usage = const <String, int>{},
  }) {
    if (isPrivate(text)) return const <CommandSuggestion>[];
    final words = _tokens(text);
    if (words.isEmpty || words.length > maxWords) {
      return const <CommandSuggestion>[];
    }
    final entries = <CommandEntry>[
      for (final entry in catalog.entries)
        if (_suggestable(entry)) entry,
    ];
    // Словарь правильных слов команд — и выключенных навыков тоже:
    // «процент» при выключенном калькуляторе — не опечатка в «проект».
    final allKeywords = <String>{
      for (final words in _keywords.values) ...words,
      for (final entry in entries) ...keywordsOf(entry),
    };
    // Подсказка — только для опечатки: хотя бы одно слово фразы похоже на
    // слово команды, но не совпадает ни с одним словом команд и не их
    // форма. Фраза из правильно написанных слов («сколько тебе лет»,
    // «расскажи сказку», «проект мечты») подсказок не получает: это
    // понятная просьба, которую навыки не умеют, а не ошибка в команде.
    final typos = <String>{
      for (final word in words)
        if (isTypo(word.folded, allKeywords)) word.folded,
    };
    if (typos.isEmpty) return const <CommandSuggestion>[];
    final scored = <_Scored>[];
    for (final (index, entry) in entries.indexed) {
      final keywords = keywordsOf(entry);
      if (keywords.isEmpty) continue;
      var score = 0.0;
      var viaTypo = false;
      for (final keyword in keywords) {
        var best = 0.0;
        var bestTypo = false;
        for (final word in words) {
          if (_filler.contains(word.folded)) continue;
          final q = similarity(word.folded, keyword);
          if (q > best) {
            best = q;
            bestTypo = typos.contains(word.folded);
          } else if (q > 0 && q == best && typos.contains(word.folded)) {
            bestTypo = true;
          }
        }
        if (best > 0) {
          score += best * (_generic.contains(keyword) ? 0.5 : 1);
          if (bestTypo) viaTypo = true;
        }
      }
      // Команду подсказываем, только если на неё похожа сама опечатка.
      if (score <= 0 || !viaTypo) continue;
      final top = CommandCatalog.defaultTop.indexOf(entry.id);
      scored.add(
        _Scored(
          entry,
          score,
          usage[entry.id] ?? 0,
          top < 0 ? CommandCatalog.defaultTop.length + index : top,
        ),
      );
    }
    if (scored.isEmpty) return const <CommandSuggestion>[];
    scored.sort((_Scored a, _Scored b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final byUse = b.uses.compareTo(a.uses);
      if (byUse != 0) return byUse;
      return a.order.compareTo(b.order);
    });
    final top = scored.first.score;
    if (top < minScore) return const <CommandSuggestion>[];
    return <CommandSuggestion>[
      for (final s in scored
          .where(
            (_Scored s) => s.score >= top * closeShare && s.score >= minScore,
          )
          .take(CommandSuggestions.maxCommands))
        CommandSuggestion(
          entryId: s.entry.id,
          label: s.entry.label,
          template: _prefill(s.entry, text, words),
        ),
    ];
  }

  /// Слово [word] — опечатка в слове команды: похоже на одно из
  /// [keywords] с поправкой на опечатку (0.6–0.75) или отличается от него
  /// одной пропущенной или лишней буквой, но не совпадает ни с одним из них
  /// и не их форма с другим окончанием. Разговорные искажения команд
  /// ([_misspelled], «скока») — тоже опечатки.
  static bool isTypo(String word, Iterable<String> keywords) {
    if (_filler.contains(word)) return false;
    if (_misspelled.contains(word)) return true;
    final real = <String>[
      for (final keyword in keywords)
        if (!_misspelled.contains(keyword)) keyword,
    ];
    if (real.contains(word)) return false;
    // Одна буква пропущена, лишняя, заменена внутри слова или две соседние
    // переставлены — опечатка («расскаж», «задчи», «пакажи»). Другое
    // окончание того же слова («задачу» и «задачи», «сделал») — нет.
    for (final keyword in real) {
      // Слово команды с окончанием («проекты», «процента») или та же
      // основа («корни» — «корень») — форма слова, а не опечатка.
      if (_isForm(word, keyword)) return false;
    }
    for (final keyword in real) {
      if (word.length < 4 || keyword.length < 4) continue;
      if (_osa(word, keyword) != 1) continue;
      final lastOnly = word.length == keyword.length &&
          word.substring(0, word.length - 1) ==
              keyword.substring(0, keyword.length - 1);
      if (!lastOnly) return true;
    }
    // Короткое слово лишь созвучно команде («купи» — «копию»): не опечатка.
    if (word.length <= 4) return false;
    var best = 0.0;
    for (final keyword in real) {
      final q = similarity(word, keyword);
      if (q >= 0.9) return false;
      if (q > best) best = q;
    }
    return best > 0;
  }

  /// Ключевые слова, которые сами — искажённое написание («скока» вместо
  /// «сколько»): совпадение с ними — опечатка, а не правильное слово.
  static const Set<String> _misspelled = <String>{'скока'};

  /// Меньше этой похожести — не предлагаем: одно слово с опечаткой
  /// (`зделай` ≈ `сделай`) ещё проходит, случайное созвучие — нет.
  static const double minScore = 0.75;

  /// Вместе с самой похожей показываем только почти такие же.
  static const double closeShare = 0.6;

  /// Длинная фраза — не опечатка в команде: подсказок нет.
  static const int maxWords = 12;

  /// Фраза о паролях, пароль, код или секрет: ни подсказок, ни
  /// подстановки — слова пользователя не повторяются ни в ответе, ни в
  /// поле. Ловит и слово «пароль» с опечаткой («пороль»), и слова,
  /// похожие на пароль (буквы с цифрами).
  static bool isPrivate(String text) {
    if (text.contains('•')) return true;
    if (SecretGuard.redact(text).guarded) return true;
    for (final token in RegExp(r'\S+').allMatches(text)) {
      final raw = token.group(0)!;
      if (RegExp(r'\p{L}', unicode: true).hasMatch(raw) &&
          RegExp(r'\d').hasMatch(raw) &&
          raw.length >= 6) {
        return true;
      }
    }
    for (final word in _tokens(text)) {
      final w = word.folded;
      for (final prefix in _privatePrefixes) {
        if (w.startsWith(prefix)) return true;
      }
      if (w.length >= 5 && _osa(_stem(w), 'парол') <= 1) return true;
    }
    return false;
  }

  static const List<String> _privatePrefixes = <String>[
    'парол',
    'пасвор',
    'пассвор',
    'pass',
    'pwd',
    'пин',
    'pin',
    'секрет',
    'логин',
    'login',
    'мастер',
    'сейф',
    'код',
    'otp',
    'токен',
    'token',
  ];

  /// Команды для подсказки: только вставка шаблона, без сейфа и без
  /// команд о выбранной задаче.
  static bool _suggestable(CommandEntry entry) =>
      entry.kind == CommandKind.insert &&
      entry.category != CommandCategory.vault &&
      !entry.needsSelection &&
      entry.template.isNotEmpty;

  /// Похожесть слова фразы [word] и ключевого слова [keyword] (оба в
  /// нижнем регистре, «е» вместо «ё»): 1 — то же слово, 0.9 — та же
  /// основа («задачи» и «задачу»), 0.75 и 0.6 — опечатка; 0 — не похоже.
  static double similarity(String word, String keyword) {
    if (word == keyword) return 1;
    final shorter = word.length < keyword.length ? word.length : keyword.length;
    if (shorter < 4) return 0;
    var prefix = 0;
    while (prefix < shorter && word[prefix] == keyword[prefix]) {
      prefix++;
    }
    if (prefix >= 4 && prefix >= shorter - 2) return 0.9;
    if (_osa(word, keyword) <= 1) return 0.75;
    final a = _stem(word);
    final b = _stem(keyword);
    if (a.length < 4 || b.length < 4) return 0;
    final d = _osa(a, b);
    if (d <= 1) return 0.75;
    final longer = a.length > b.length ? a.length : b.length;
    if (d == 2 && longer >= 7) return 0.6;
    return 0;
  }

  /// Слово без окончания: до двух последних гласных, «й» и «ь».
  /// [word] — форма [keyword]: то же слово с другим окончанием до трёх
  /// букв или та же основа без беглой гласной («корни» — «корень»).
  static bool _isForm(String word, String keyword) {
    if (keyword.length >= 4 &&
        word.length > keyword.length &&
        word.length - keyword.length <= 3 &&
        word.startsWith(keyword) &&
        _endings.contains(word[keyword.length])) {
      return true;
    }
    final a = _stem(word);
    final b = _stem(keyword);
    if (a.length < 3 || b.length < 3) return false;
    // Беглая гласная перед последней согласной основы: корен- / корн-.
    if (b.length == a.length + 1 &&
        b.substring(0, b.length - 2) == a.substring(0, a.length - 1) &&
        b[b.length - 1] == a[a.length - 1] &&
        'еоё'.contains(b[b.length - 2])) {
      return true;
    }
    return false;
  }

  static String _stem(String word) {
    var w = word;
    for (var i = 0; i < 2 && w.length > 4; i++) {
      if (!_endings.contains(w[w.length - 1])) break;
      w = w.substring(0, w.length - 1);
    }
    return w;
  }

  static const String _endings = 'аяуюиыеоэйь';

  /// Расстояние Дамерау — Левенштейна (оптимальное выравнивание строк):
  /// вставка, удаление, замена и перестановка соседних букв.
  static int _osa(String a, String b) {
    final n = a.length;
    final m = b.length;
    if ((n - m).abs() > 2) return 3;
    var prev2 = List<int>.filled(m + 1, 0);
    var prev = List<int>.generate(m + 1, (int j) => j);
    for (var i = 1; i <= n; i++) {
      final row = List<int>.filled(m + 1, 0)..[0] = i;
      for (var j = 1; j <= m; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        var v = prev[j] + 1;
        if (row[j - 1] + 1 < v) v = row[j - 1] + 1;
        if (prev[j - 1] + cost < v) v = prev[j - 1] + cost;
        if (i > 1 &&
            j > 1 &&
            a[i - 1] == b[j - 2] &&
            a[i - 2] == b[j - 1] &&
            prev2[j - 2] + 1 < v) {
          v = prev2[j - 2] + 1;
        }
        row[j] = v;
      }
      prev2 = prev;
      prev = row;
    }
    return prev[m];
  }

  /// Ключевые слова команды: встроенные — из [_keywords], команды
  /// расширений — слова их примера.
  static List<String> keywordsOf(CommandEntry entry) {
    final own = _keywords[entry.id];
    if (own != null) return own;
    return <String>{
      for (final word in _tokens(entry.template.replaceAll('|', ' ')))
        if (word.folded.length >= 3 && !_filler.contains(word.folded))
          word.folded,
    }.toList();
  }

  /// Ключевые слова встроенных команд: глагол команды и предмет, в той
  /// форме, в какой их пишут. Слова раздела («задачи») — тоже: «покажи
  /// задчи» похоже и на «Показать задачи», и на «Задачи на сегодня».
  static const Map<String, List<String>> _keywords = <String, List<String>>{
    'task.new': <String>['добавь', 'задачу', 'создай', 'сделай', 'новая'],
    'task.tomorrow10': <String>['добавь', 'задачу', 'завтра'],
    'task.project': <String>['добавь', 'задачу', 'проект'],
    'task.remind': <String>['напомни', 'напоминание'],
    'task.list': <String>['покажи', 'задачи', 'список'],
    'task.today': <String>['покажи', 'задачи', 'сегодня'],
    'task.complete': <String>['заверши', 'задачу', 'выполнена', 'готово'],
    'plan.moveTask': <String>['перенеси', 'задачу'],
    'plan.overdue': <String>['перенеси', 'просроченные'],
    'plan.week': <String>['покажи', 'задачи', 'неделю'],
    'talk.skills': <String>['умеешь', 'помощь', 'команды'],
    'talk.joke': <String>['расскажи', 'шутку', 'анекдот'],
    'talk.brief': <String>['говори', 'короче'],
    'calc.eval': <String>['сколько', 'скока', 'посчитай', 'будет'],
    'calc.percent': <String>['процент', 'процентов'],
    'calc.root': <String>['корень'],
    'wh.where': <String>['где', 'лежит'],
    'wh.today': <String>['пришло', 'сегодня'],
    'wh.nophoto': <String>['фото'],
    'data.backup': <String>['сделай', 'резервную', 'копию'],
    'data.restore': <String>['восстанови', 'данные', 'копии'],
    'data.open': <String>['открой', 'данные', 'приложения'],
  };

  /// Общие слова команд: одного такого слова мало для подсказки, они
  /// весят вдвое меньше («покажи», «задачу»).
  static const Set<String> _generic = <String>{
    'задачу',
    'задачи',
    'покажи',
    'сделай',
    'открой',
    'будет',
    'данные',
    'сегодня',
    'где',
  };

  /// Служебные слова: ни ключевыми словами, ни поводом для подсказки не
  /// бывают.
  static const Set<String> _filler = <String>{
    'мне',
    'мой',
    'мои',
    'моя',
    'все',
    'всё',
    'что',
    'это',
    'как',
    'для',
    'про',
    'пожалуйста',
    'пж',
    'плиз',
    'ну',
    'давай',
    'можно',
    'надо',
    'нужно',
    'ещё',
    'еще',
    'тут',
    'там',
    'его',
    'её',
    'ее',
    'она',
    'они',
    'ты',
    'вы',
  };

  /// Команды, в шаблоне которых место для названия: туда можно положить
  /// слова пользователя после слов команды.
  static const Set<String> _titleSlots = <String>{
    'task.new',
    'task.project',
    'task.complete',
    'plan.moveTask',
    'task.remind',
  };

  /// Команды калькулятора: на место `|` ложится только пример из цифр.
  static const Set<String> _mathSlots = <String>{
    'calc.eval',
    'calc.percent',
    'calc.root',
  };

  /// Шаблон [entry] со словами пользователя на месте `|`, если это
  /// безопасно и очевидно: слова команды стоят в начале фразы, а после
  /// них — короткий хвост (название задачи или пример из цифр). Иначе —
  /// шаблон как есть, курсор на пустом месте.
  static String _prefill(
    CommandEntry entry,
    String text,
    List<_Token> words,
  ) {
    final template = entry.template;
    if (!template.contains('|')) return template;
    final title = _titleSlots.contains(entry.id);
    final math = _mathSlots.contains(entry.id);
    if (!title && !math) return template;
    final keywords = keywordsOf(entry);
    var last = -1;
    for (var i = 0; i < words.length; i++) {
      final w = words[i].folded;
      final isCommand = keywords.any((String k) => similarity(w, k) > 0);
      if (isCommand) {
        // Слово команды после хвоста — порядок не очевиден.
        if (last != i - 1 && !_onlyFiller(words, last + 1, i)) {
          return template;
        }
        last = i;
      }
    }
    if (last < 0) return template;
    var tail = text.substring(words[last].end).trim();
    tail = tail
        .replaceAll(RegExp(r'^[\s«»"“”„:,.!?;—–-]+'), '')
        .replaceAll(RegExp(r'[\s«»"“”„:,.!?;—–-]+$'), '')
        .trim();
    if (tail.isEmpty || tail.length > 80) return template;
    if (isPrivate(tail)) return template;
    if (title) {
      if (!RegExp(r'\p{L}', unicode: true).hasMatch(tail)) return template;
      if (tail.contains('#') || tail.contains('«') || tail.contains('»')) {
        return template;
      }
      if (_tokens(tail).length > 8) return template;
      if (_tokens(tail).every((_Token t) => _filler.contains(t.folded))) {
        return template;
      }
    } else {
      if (!RegExp(r'^[\d\s+\-*/×÷:^().,%]+$').hasMatch(tail) ||
          !RegExp(r'\d').hasMatch(tail)) {
        return template;
      }
    }
    final filled = template.replaceFirst('|', tail);
    return '$filled|';
  }

  static bool _onlyFiller(List<_Token> words, int from, int to) {
    for (var i = from; i < to; i++) {
      if (!_filler.contains(words[i].folded)) return false;
    }
    return true;
  }

  static List<_Token> _tokens(String text) => <_Token>[
        for (final m
            in RegExp(r'[\p{L}\p{N}]+', unicode: true).allMatches(text))
          _Token(ChatSearch.fold(m.group(0)!), m.start, m.end),
      ];
}

final class _Token {
  const _Token(this.folded, this.start, this.end);

  final String folded;
  final int start;
  final int end;
}

final class _Scored {
  const _Scored(this.entry, this.score, this.uses, this.order);

  final CommandEntry entry;
  final double score;
  final int uses;
  final int order;
}
