import 'due_parser.dart';

/// Слово сообщения вне кавычек и меток.
final class UtteranceToken {
  const UtteranceToken({
    required this.index,
    required this.text,
    required this.original,
    required this.span,
  });

  /// Порядковый номер среди [Utterance.tokens].
  final int index;

  /// Нормализованный вид: нижний регистр, «ё» → «е».
  final String text;

  /// Как написал пользователь.
  final String original;

  /// Где слово стоит в [Utterance.original].
  final CharSpan span;

  bool get isNumber => _digits.hasMatch(text);

  static final RegExp _digits = RegExp(r'^\d+$');

  @override
  String toString() => text;
}

/// Название в парных кавычках.
final class QuotedTitle {
  const QuotedTitle(this.text, this.span);

  /// Текст внутри кавычек без пробелов по краям.
  final String text;

  /// Фрагмент вместе с кавычками.
  final CharSpan span;
}

/// Метка «#работа» вне кавычек.
final class Hashtag {
  const Hashtag(this.name, this.span);

  /// Без «#», в нижнем регистре.
  final String name;

  /// Фрагмент вместе с «#».
  final CharSpan span;
}

/// Общий предварительный разбор одного сообщения.
///
/// Строится один раз на сообщение и передаётся всем коннекторам, чтобы каждый
/// не разбирал текст заново и все понимали кавычки, метки, сроки и коды
/// одинаково. Все смещения ([CharSpan]) указывают в [original].
///
/// Порядок разбора:
/// 1. Названия в парных кавычках вырезаются первыми: слова и даты внутри
///    названия («Планёрка завтра») не влияют на остальной разбор.
/// 2. Метки «#проект» вне кавычек вырезаются вторыми: «#завтра» — не срок.
/// 3. По оставшемуся тексту строятся [tokens], [due] и [codes].
final class Utterance {
  Utterance._({
    required this.original,
    required this.normalized,
    required this.analysisText,
    required this.tokens,
    required this.quotedTitles,
    required this.unbalancedQuotes,
    required this.hashtags,
    required this.due,
    this.chatTaskId,
    this.awaitingAnswer = false,
    this.recentConnectorId,
  });

  /// Разбирает [text]; [now] нужен для сроков «завтра», «в 10:00».
  ///
  /// Латинские буквы-двойники внутри русских слов («завтрa» с латинской
  /// «a») заменяются русскими до разбора — и в [original] тоже.
  factory Utterance.analyze(String message, {required DateTime now}) {
    final text = fixHomoglyphs(message);
    final quotes = _extractQuoted(text);
    final hashtags = <Hashtag>[
      for (final match in _hashtag.allMatches(quotes.masked))
        Hashtag(
          match.group(1)!.toLowerCase(),
          CharSpan(match.start, match.end),
        ),
    ];
    var masked = quotes.masked;
    for (final tag in hashtags) {
      masked = masked.replaceRange(
        tag.span.start,
        tag.span.end,
        ' ' * tag.span.length,
      );
    }
    final analysisText = DueParser.normalizeChars(masked);
    final words = _word.allMatches(analysisText).toList(growable: false);
    final texts = <String>[for (final word in words) word.group(0)!];
    _fixCommandTypos(texts);
    final tokens = <UtteranceToken>[
      for (var i = 0; i < words.length; i++)
        UtteranceToken(
          index: i,
          text: texts[i],
          original: text.substring(words[i].start, words[i].end),
          span: CharSpan(words[i].start, words[i].end),
        ),
    ];
    return Utterance._(
      original: text,
      normalized: DueParser.normalizeChars(text),
      analysisText: analysisText,
      tokens: List<UtteranceToken>.unmodifiable(tokens),
      quotedTitles: List<QuotedTitle>.unmodifiable(quotes.titles),
      unbalancedQuotes: quotes.unbalanced,
      hashtags: List<Hashtag>.unmodifiable(hashtags),
      due: const DueParser().parse(analysisText, now),
    );
  }

  /// То же сообщение, отправленное в чате задачи [chatTaskId] (`null` —
  /// в главном чате); [awaitingAnswer] — помощник перед этим задал вопрос;
  /// [recentConnectorId] — кто недавно отвечал в этом чате (контекст
  /// сессии). Ставит маршрутизатор.
  Utterance withChat(
    String? chatTaskId, {
    bool awaitingAnswer = false,
    String? recentConnectorId,
  }) =>
      chatTaskId == this.chatTaskId &&
              awaitingAnswer == this.awaitingAnswer &&
              recentConnectorId == this.recentConnectorId
          ? this
          : Utterance._(
              original: original,
              normalized: normalized,
              analysisText: analysisText,
              tokens: tokens,
              quotedTitles: quotedTitles,
              unbalancedQuotes: unbalancedQuotes,
              hashtags: hashtags,
              due: due,
              chatTaskId: chatTaskId,
              awaitingAnswer: awaitingAnswer,
              recentConnectorId: recentConnectorId,
            );

  /// Коннектор, который отвечал в этом чате одно-два сообщения назад и не
  /// дольше нескольких минут назад (контекст сессии,
  /// `AssistantController`); `null` — контекста нет. Так «сделай бэкап»
  /// сразу после разговора о паролях понимается как копия паролей, а не
  /// вопрос «копию чего?». Только id коннектора: текста прежних сообщений
  /// здесь нет.
  final String? recentConnectorId;

  /// Предыдущий ответ помощника был вопросом («На когда перенести
  /// задачу?», «да или нет?»): короткое слово сейчас — скорее ответ на
  /// него, чем новая команда другому навыку. Подсказки ролей для голых
  /// слов («сегодня» — приходы склада) тогда молчат.
  final bool awaitingAnswer;

  /// Задача чата, в котором написано сообщение (docs/CONNECTORS.md, «Чат
  /// задачи»); `null` — главный чат. В чате задачи коннектор задач понимает
  /// и короткие фразы без объекта: «закрой», «на завтра».
  final String? chatTaskId;

  /// Открывающая кавычка → допустимые закрывающие.
  static const Map<String, Set<String>> _quotePairs = <String, Set<String>>{
    '«': <String>{'»'},
    '»': <String>{'«'},
    '“': <String>{'”', '“'},
    '„': <String>{'“', '”'},
    '"': <String>{'"'},
  };

  static final RegExp _word = RegExp('[a-zа-я0-9]+');

  static final RegExp _hashtag =
      RegExp(r'(?<![\p{L}\p{N}])#([\p{L}\p{N}_-]+)', unicode: true);

  static final RegExp _hasLetterOrDigit =
      RegExp(r'[\p{L}\p{N}]', unicode: true);

  static const String _edgePunctuation = ',.;:!?—–-…';

  /// Сообщение как есть (с исправленными буквами-двойниками,
  /// [fixHomoglyphs]).
  final String original;

  /// Всё сообщение написано заглавными: «НАПОМНИ ВСТРЕЧА В 5 КОРПУСЕ».
  /// Тогда [remainder] отдаёт текст строчными — название получается
  /// обычным предложением («Встреча в 5 корпусе»). Аббревиатуры в таком
  /// сообщении не отличить от остального текста, они тоже становятся
  /// строчными. Названия в кавычках не меняются: это точное название.
  bool get allCaps {
    var letters = 0;
    for (final rune in original.runes) {
      final char = String.fromCharCode(rune);
      final lower = char.toLowerCase();
      final upper = char.toUpperCase();
      if (lower == upper) continue;
      if (char == lower) return false;
      letters++;
    }
    return letters >= 4;
  }

  /// [original] в нижнем регистре и с «е» вместо «ё»; длина та же.
  final String normalized;

  /// [normalized], где названия в кавычках, сами кавычки и метки заменены
  /// пробелами той же длины. По нему строятся [tokens] и [due].
  final String analysisText;

  /// Слова вне кавычек и меток (буквы и цифры).
  final List<UtteranceToken> tokens;

  /// Все названия в парных кавычках, по порядку.
  final List<QuotedTitle> quotedTitles;

  /// Кавычка открыта, но не закрыта. Текст после неё остаётся в разборе.
  final bool unbalancedQuotes;

  /// Метки вне кавычек.
  final List<Hashtag> hashtags;

  /// Срок, найденный вне кавычек и меток, с фрагментами, которые он занял.
  final DueParseResult due;

  /// Нормализованные слова вне кавычек.
  List<String> get words =>
      tokens.map((UtteranceToken t) => t.text).toList(growable: false);

  /// Вопрос: знак «?» вне кавычек.
  bool get isQuestion => analysisText.contains('?');

  /// Все числа из одних цифр.
  List<UtteranceToken> get numbers =>
      tokens.where((UtteranceToken t) => t.isNumber).toList(growable: false);

  /// Коды из 5–6 цифр (артикулы, номера ячеек): «64115». Не бывают частью
  /// даты или времени — разбор сроков такие числа не берёт.
  List<String> get codes => <String>[
        for (final token in tokens)
          if (token.isNumber &&
              token.text.length >= 5 &&
              token.text.length <= 6 &&
              !_glued(token))
            token.text,
      ];

  bool _glued(UtteranceToken token) {
    final start = token.span.start;
    final end = token.span.end;
    final before = start > 0 ? analysisText[start - 1] : '';
    final after = end < analysisText.length ? analysisText[end] : '';
    return '.:'.contains(before) && before.isNotEmpty ||
        '.:'.contains(after) &&
            after.isNotEmpty &&
            end + 1 < analysisText.length &&
            RegExp(r'\d').hasMatch(analysisText[end + 1]);
  }

  /// Есть ли слово из [words] среди [tokens].
  bool hasAnyWord(Set<String> words) =>
      tokens.any((UtteranceToken t) => words.contains(t.text));

  /// Первое слово из [words] или `null`.
  UtteranceToken? firstOf(Set<String> words) {
    for (final token in tokens) {
      if (words.contains(token.text)) return token;
    }
    return null;
  }

  /// Слово целиком покрыто одним из [spans].
  static bool isCovered(UtteranceToken token, Iterable<CharSpan> spans) =>
      spans.any((CharSpan s) => s.covers(token.span));

  /// Слова, не покрытые [spans].
  List<UtteranceToken> tokensOutside(Iterable<CharSpan> spans) => tokens
      .where((UtteranceToken t) => !isCovered(t, spans))
      .toList(growable: false);

  /// Что осталось от [original] после удаления [remove], названий в кавычках
  /// и меток. Регистр пользователя сохраняется, пробелы схлопываются, знаки
  /// препинания по краям и «осиротевшие» запятые убираются. Пустая строка,
  /// если не осталось ни одного слова.
  String remainder(Iterable<CharSpan> remove) {
    final source = allCaps ? _lowerSameLength(original) : original;
    final chars = source.split('');
    for (var i = 0; i < chars.length; i++) {
      // Кавычки и метки уже заменены пробелами в analysisText.
      if (analysisText[i] == ' ' && original[i].trim().isNotEmpty) {
        chars[i] = ' ';
      }
    }
    for (final span in remove) {
      for (var i = span.start; i < span.end && i < chars.length; i++) {
        chars[i] = ' ';
      }
    }
    final parts = chars
        .join()
        .split(RegExp(r'\s+'))
        .where((String part) => _hasLetterOrDigit.hasMatch(part))
        .toList();
    if (parts.isEmpty) return '';
    var text = parts.join(' ');
    var start = 0;
    var end = text.length;
    while (start < end && _isEdge(text[start])) {
      start++;
    }
    while (end > start && _isEdge(text[end - 1])) {
      end--;
    }
    text = text.substring(start, end);
    return text;
  }

  /// Строчные буквы без изменения длины строки.
  static String _lowerSameLength(String text) {
    final buffer = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      final lower = text[i].toLowerCase();
      buffer.write(lower.length == 1 ? lower : text[i]);
    }
    return buffer.toString();
  }

  /// Латинские буквы, которые выглядят как русские.
  static const Map<String, String> _homoglyphs = <String, String>{
    'a': 'а',
    'c': 'с',
    'e': 'е',
    'o': 'о',
    'p': 'р',
    'x': 'х',
    'y': 'у',
    'k': 'к',
    'm': 'м',
    't': 'т',
    'A': 'А',
    'B': 'В',
    'C': 'С',
    'E': 'Е',
    'H': 'Н',
    'K': 'К',
    'M': 'М',
    'O': 'О',
    'P': 'Р',
    'T': 'Т',
    'X': 'Х',
    'Y': 'У',
  };

  static final RegExp _mixedWord = RegExp('[A-Za-zА-Яа-яЁё]+');
  static final RegExp _cyrillic = RegExp('[А-Яа-яЁё]');
  static final RegExp _latinLetter = RegExp('[A-Za-z]');

  /// Заменяет латинские буквы-двойники русскими в словах, где есть и те,
  /// и другие: «завтрa» → «завтра». Слово меняется, только если в нём
  /// русских букв больше, чем латинских, и все латинские — двойники. Так
  /// не меняются слова целиком латиницей («iPhone», «recurring») и
  /// латинские названия с русским окончанием: «Zoomе», «iPhoneа»,
  /// «PDFку», «Excelе», «SMSку» (в каждом есть латинская буква без
  /// русского двойника или латиницы больше). Длина строки сохраняется.
  static String fixHomoglyphs(String text) {
    if (!_latinLetter.hasMatch(text)) return text;
    return text.replaceAllMapped(_mixedWord, (Match match) {
      final word = match.group(0)!;
      if (!_cyrillic.hasMatch(word) || !_latinLetter.hasMatch(word)) {
        return word;
      }
      var latin = 0;
      var cyrillic = 0;
      for (final char in word.split('')) {
        if (_latinLetter.hasMatch(char)) {
          if (!_homoglyphs.containsKey(char)) return word;
          latin++;
        } else {
          cyrillic++;
        }
      }
      if (cyrillic <= latin) return word;
      return word.split('').map((String c) => _homoglyphs[c] ?? c).join();
    });
  }

  /// Слова команд, опечатки в которых исправляются ([_fixCommandTypos]).
  /// Повелительные формы на «-ь» есть и в написании с «-и» («постави»):
  /// так «поставни» — одна опечатка от «постави».
  static const Map<String, String> _commandWords = <String, String>{
    'добавь': 'добавь',
    'добави': 'добавь',
    'создай': 'создай',
    'запиши': 'запиши',
    'напомни': 'напомни',
    'перенеси': 'перенеси',
    'заверши': 'заверши',
    'выполни': 'выполни',
    'поставь': 'поставь',
    'постави': 'поставь',
    'отложи': 'отложи',
    'сдвинь': 'сдвинь',
    'передвинь': 'передвинь',
    'покажи': 'покажи',
    'отметь': 'отметь',
    'отмети': 'отметь',
    'закрой': 'закрой',
  };

  /// Настоящие слова в одной правке от слова команды: это не опечатки,
  /// и в команду они не превращаются. «Записи в блоге не грузятся»,
  /// «наполни ванну», «выполи грядку», «обложи налогом», «заверни
  /// подарок», «отмени встречу», «отмерь ткань», «добавки хочешь?».
  static const Set<String> _realWords = <String>{
    'записи',
    'запили',
    'запаши',
    'наполни',
    'перевеси',
    'переноси',
    'заверни',
    'выполи',
    'подставь',
    'обложи',
    'отмени',
    'отмерь',
    'отмели',
    'отметки',
    'отметка',
    'добавки',
    'добавка',
    'покачи',
    'сдачу',
  };

  /// Слова после команды, опечатки в которых исправляются.
  static const Map<String, String> _objectWords = <String, String>{
    'задачу': 'задачу',
    'напоминание': 'напоминание',
  };

  /// Опечатки в словах команд: «поставни задачу» → «поставь», «добавь
  /// задау» → «задачу». Только слова от пяти букв, одна правка (замена,
  /// вставка, пропуск, перестановка соседних букв) и только на месте
  /// команды: первое слово сообщения — глагол команды, слово сразу после
  /// команды — «задачу», «напоминание». Правка последней буквы (и
  /// перестановка двух последних) не считается опечаткой: «напомню»,
  /// «запишу», «задача», «напомин» — другие формы или обрывки. Правка
  /// первой буквы тоже не опечатка: «запомни», «двинь», «оставь» —
  /// другие слова. Настоящие слова рядом с командами ([_realWords]:
  /// «наполни», «записи», «отмени») не исправляются. Остальной текст
  /// («позвонитть») остаётся как написан.
  static void _fixCommandTypos(List<String> words) {
    String? fix(String word, Map<String, String> dictionary) {
      if (word.length < 5 || dictionary.containsKey(word)) return null;
      if (_realWords.contains(word)) return null;
      if (!RegExp(r'^[а-я]+$').hasMatch(word)) return null;
      for (final entry in dictionary.entries) {
        if (entry.key.length < 5) continue;
        if (_isTypo(word, entry.key)) return entry.value;
      }
      return null;
    }

    if (words.isEmpty) return;
    final verb = fix(words.first, _commandWords);
    if (verb != null) words[0] = verb;
    for (var i = 1; i < words.length; i++) {
      if (!_commandWords.containsKey(words[i - 1])) continue;
      final object = fix(words[i], _objectWords);
      if (object != null) words[i] = object;
    }
  }

  /// Ровно одна правка между [typo] и [word], не на первой и не на
  /// последней букве.
  static bool _isTypo(String typo, String word) {
    final a = typo;
    final b = word;
    if ((a.length - b.length).abs() > 1) return false;
    var prefix = 0;
    final shorter = a.length < b.length ? a.length : b.length;
    while (prefix < shorter && a[prefix] == b[prefix]) {
      prefix++;
    }
    if (prefix == 0) return false;
    if (a.length == b.length) {
      if (prefix >= a.length - 1) return false;
      // Замена одной буквы.
      if (a.substring(prefix + 1) == b.substring(prefix + 1)) return true;
      // Перестановка соседних, но не двух последних: «напомин» — не
      // «напомни».
      return prefix + 2 < a.length &&
          a[prefix] == b[prefix + 1] &&
          a[prefix + 1] == b[prefix] &&
          a.substring(prefix + 2) == b.substring(prefix + 2);
    }
    final longer = a.length > b.length ? a : b;
    final short = a.length > b.length ? b : a;
    // Лишняя или пропущенная буква в конце — другая форма слова.
    if (prefix >= short.length) return false;
    return longer.substring(prefix + 1) == short.substring(prefix);
  }

  static bool _isEdge(String char) =>
      _edgePunctuation.contains(char) || char.trim().isEmpty;

  /// Первая буква заглавная, остальное как написал пользователь. Знаки
  /// перед ней пропускаются: «'готовить презентацию'» → «'Готовить
  /// презентацию'». Число в начале остаётся началом: «3 отчёта».
  static String capitalize(String text) {
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (!_hasLetterOrDigit.hasMatch(char)) continue;
      return text.substring(0, i) + char.toUpperCase() + text.substring(i + 1);
    }
    return text;
  }

  /// Вырезает все названия в парных кавычках, заменяя их пробелами той же
  /// длины. Незакрытая кавычка не продолжает поиск внутри фрагмента, чтобы
  /// не взять кусок названия; текст после неё остаётся в разборе.
  static _Quotes _extractQuoted(String message) {
    final titles = <QuotedTitle>[];
    final masked = StringBuffer();
    var index = 0;
    while (index < message.length) {
      final open = message[index];
      final closers = _quotePairs[open];
      if (closers == null) {
        masked.write(open);
        index++;
        continue;
      }
      final end = _findClose(message, index, open, closers);
      if (end == null) {
        masked.write(' ');
        masked.write(message.substring(index + 1));
        return _Quotes(
          titles: titles,
          masked: masked.toString(),
          unbalanced: true,
        );
      }
      final title = message.substring(index + 1, end).trim();
      if (title.isNotEmpty) {
        titles.add(QuotedTitle(title, CharSpan(index, end + 1)));
      }
      masked.write(' ' * (end + 1 - index));
      index = end + 1;
    }
    return _Quotes(
      titles: titles,
      masked: masked.toString(),
      unbalanced: false,
    );
  }

  static int? _findClose(
    String message,
    int start,
    String open,
    Set<String> closers,
  ) {
    // Вложенность поддерживается для разных открывающей и закрывающей:
    // «Отчёт по «Ромашке»».
    final nests = !closers.contains(open);
    var depth = 1;
    for (var i = start + 1; i < message.length; i++) {
      final char = message[i];
      if (nests && char == open) {
        depth++;
      } else if (closers.contains(char)) {
        depth--;
        if (depth == 0) return i;
      }
    }
    return null;
  }
}

final class _Quotes {
  const _Quotes({
    required this.titles,
    required this.masked,
    required this.unbalanced,
  });

  final List<QuotedTitle> titles;
  final String masked;
  final bool unbalanced;
}
