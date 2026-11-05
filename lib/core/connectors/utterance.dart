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
  });

  /// Разбирает [text]; [now] нужен для сроков «завтра», «в 10:00».
  factory Utterance.analyze(String text, {required DateTime now}) {
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
    final tokens = <UtteranceToken>[
      for (var i = 0; i < words.length; i++)
        UtteranceToken(
          index: i,
          text: words[i].group(0)!,
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

  /// Сообщение как есть.
  final String original;

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
    final chars = original.split('');
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

  static bool _isEdge(String char) =>
      _edgePunctuation.contains(char) || char.trim().isEmpty;

  /// Первая буква заглавная, остальное как написал пользователь.
  static String capitalize(String text) {
    if (text.isEmpty) return text;
    return text[0].toUpperCase() + text.substring(1);
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
