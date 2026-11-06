/// Шаблон фразы каталога ответов и его разметка (docs/REPLIES.md).
///
/// Разметка внутри текста:
///
/// - `{title}` — подстановка значения (факта) по имени: латиница и цифры,
///   начинается со строчной буквы;
/// - `{м:Добавил|ж:Добавила}` — род говорящего помощника;
/// - `{вы:Хотите|ты:Хочешь}` — обращение к пользователю;
/// - `{мн:count|задача|задачи|задач}` — число по значению `count`: одна,
///   две, пять;
/// - `{э:🙂}` — эмодзи; вне этой метки эмодзи в тексте запрещены, поэтому
///   при выключенных эмодзи они убираются все;
/// - `{{` и `}}` — фигурные скобки как есть.
///
/// Внутри вариантов рода, обращения и числа можно ставить подстановки и
/// эмодзи, но не другой выбор. Ошибки разметки — [ReplyFormatException]
/// по-русски.
library;

/// Грамматический род помощника, который говорит.
enum ReplyGender { male, female }

/// Как помощник обращается к пользователю.
enum ReplyAddress {
  /// «Вы»: значение по умолчанию.
  formal,

  /// «Ты».
  informal,
}

/// Ошибка разметки шаблона.
final class ReplyFormatException implements Exception {
  const ReplyFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Часть шаблона.
sealed class _Segment {
  const _Segment();
}

final class _Text extends _Segment {
  const _Text(this.text);

  final String text;
}

final class _Value extends _Segment {
  const _Value(this.name);

  final String name;
}

final class _Emoji extends _Segment {
  const _Emoji(this.text);

  final String text;
}

final class _Gender extends _Segment {
  const _Gender(this.male, this.female);

  final List<_Segment> male;
  final List<_Segment> female;
}

final class _Address extends _Segment {
  const _Address(this.formal, this.informal);

  final List<_Segment> formal;
  final List<_Segment> informal;
}

final class _Plural extends _Segment {
  const _Plural(this.name, this.forms);

  final String name;

  /// Одна, две, пять.
  final List<List<_Segment>> forms;
}

/// Разобранный шаблон фразы.
final class ReplyTemplate {
  ReplyTemplate._(this.source, this._segments);

  /// Разбирает [source]. Ошибка разметки — [ReplyFormatException].
  factory ReplyTemplate.parse(String source) {
    final parser = _Parser(source);
    final segments = parser.parseSequence(topLevel: true);
    return ReplyTemplate._(source, List<_Segment>.unmodifiable(segments));
  }

  static final RegExp namePattern = RegExp(r'^[a-z][a-zA-Z0-9]*$');

  /// Эмодзи и прочие пиктограммы, флаги (региональные буквы), знаки
  /// варианта и склейки эмодзи: вне `{э:…}` запрещены.
  static final RegExp pictographs = RegExp(_pictographs, unicode: true);

  // Свойство Extended_Pictographic понимает движок Dart с `unicode: true`,
  // но не проверка выражений анализатора, поэтому шаблон — не литерал.
  static final String _pictographs =
      r'[\p{Extended_Pictographic}\u{1F1E6}-\u{1F1FF}\uFE0F\u200D]';

  /// Буквы и цифры: в метке эмодзи их быть не должно, чтобы при
  /// выключенных эмодзи не пропал смысл.
  static final RegExp _lettersOrDigits = RegExp(r'[\p{L}\p{N}]', unicode: true);

  /// Текст как в каталоге.
  final String source;

  final List<_Segment> _segments;

  /// Имена всех подстановок, включая число в `{мн:…}`.
  late final Set<String> placeholders = Set<String>.unmodifiable(
    _names(_segments),
  );

  /// В шаблоне есть эмодзи.
  late final bool hasEmoji = _anyEmoji(_segments);

  static Set<String> _names(List<_Segment> segments) => <String>{
        for (final segment in segments)
          ...switch (segment) {
            _Text() || _Emoji() => const <String>{},
            _Value(:final name) => <String>{name},
            _Gender(:final male, :final female) => <String>{
                ..._names(male),
                ..._names(female),
              },
            _Address(:final formal, :final informal) => <String>{
                ..._names(formal),
                ..._names(informal),
              },
            _Plural(:final name, :final forms) => <String>{
                name,
                for (final form in forms) ..._names(form),
              },
          },
      };

  static bool _anyEmoji(List<_Segment> segments) => segments.any(
        (_Segment segment) => switch (segment) {
          _Emoji() => true,
          _Text() || _Value() => false,
          _Gender(:final male, :final female) =>
            _anyEmoji(male) || _anyEmoji(female),
          _Address(:final formal, :final informal) =>
            _anyEmoji(formal) || _anyEmoji(informal),
          _Plural(:final forms) => forms.any(_anyEmoji),
        },
      );

  /// Текст для пользователя. Каждое значение из [values] вставляется как
  /// есть, без разбора разметки. Нет значения для подстановки —
  /// [ArgumentError]: это ошибка в коде, а не в каталоге.
  String render(
    Map<String, String> values, {
    ReplyGender gender = ReplyGender.male,
    ReplyAddress address = ReplyAddress.formal,
    bool emoji = true,
  }) {
    final out = _Output();
    _render(_segments, values, gender, address, emoji, out);
    return out.finish();
  }

  void _render(
    List<_Segment> segments,
    Map<String, String> values,
    ReplyGender gender,
    ReplyAddress address,
    bool emoji,
    _Output out,
  ) {
    for (final segment in segments) {
      switch (segment) {
        case _Text(:final text):
          out.text(text);
        case _Value(:final name):
          out.value(_value(values, name));
        case _Emoji(:final text):
          if (emoji) {
            out.text(text);
          } else {
            out.gap();
          }
        case _Gender(:final male, :final female):
          _render(
            gender == ReplyGender.male ? male : female,
            values,
            gender,
            address,
            emoji,
            out,
          );
        case _Address(:final formal, :final informal):
          _render(
            address == ReplyAddress.formal ? formal : informal,
            values,
            gender,
            address,
            emoji,
            out,
          );
        case _Plural(:final name, :final forms):
          final count = int.tryParse(_value(values, name).trim());
          _render(
            forms[pluralIndex(count)],
            values,
            gender,
            address,
            emoji,
            out,
          );
      }
    }
  }

  static String _value(Map<String, String> values, String name) =>
      values[name] ??
      (throw ArgumentError.value(name, 'values', 'Нет значения подстановки'));

  /// Русское правило числа: 0 — «одна» (1, 21), 1 — «две» (2–4, 22),
  /// 2 — «пять» (5–20, 25, 11–14). Не число — «пять».
  static int pluralIndex(int? count) {
    if (count == null) return 2;
    final n = count.abs();
    if (n % 10 == 1 && n % 100 != 11) return 0;
    if (n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 12 || n % 100 > 14)) {
      return 1;
    }
    return 2;
  }

  /// Проверка текста метки эмодзи.
  static String? emojiProblem(String text) {
    if (text.trim().isEmpty) return 'пустая метка эмодзи';
    if (_lettersOrDigits.hasMatch(text)) {
      return 'в метке эмодзи «$text» есть буквы или цифры';
    }
    return null;
  }
}

/// Сборка текста. Убранная метка эмодзи не оставляет двойных пробелов и
/// пробела перед знаком препинания; значения при этом не трогаются.
final class _Output {
  final StringBuffer _buffer = StringBuffer();
  bool _pendingGap = false;
  bool _lastIsValue = false;
  String _last = '';

  static const String _punctuation = '.,!?:;…)»';

  void text(String text) {
    if (text.isEmpty) return;
    if (_pendingGap) {
      _pendingGap = false;
      final endsWithSpace = !_lastIsValue && _last.endsWith(' ');
      final atStart = _buffer.isEmpty;
      if ((endsWithSpace || atStart) && text.startsWith(' ')) {
        text = text.substring(1);
      } else if (endsWithSpace && _punctuation.contains(text[0])) {
        _dropTrailingSpace();
      }
      if (text.isEmpty) return;
    }
    _write(text, isValue: false);
  }

  void value(String value) {
    _pendingGap = false;
    _write(value, isValue: true);
  }

  void gap() => _pendingGap = true;

  void _write(String text, {required bool isValue}) {
    _buffer.write(text);
    _last = text;
    _lastIsValue = isValue;
  }

  void _dropTrailingSpace() {
    final current = _buffer.toString();
    _buffer
      ..clear()
      ..write(current.substring(0, current.length - 1));
    _last = _last.substring(0, _last.length - 1);
  }

  String finish() {
    var result = _buffer.toString();
    if (_pendingGap && !_lastIsValue && result.endsWith(' ')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }
}

final class _Parser {
  _Parser(this.source);

  final String source;
  int _pos = 0;

  Never _fail(String message) =>
      throw ReplyFormatException('$message (позиция ${_pos + 1})');

  /// Последовательность до конца текста ([topLevel]) или до `|`/`}`
  /// внутри варианта.
  List<_Segment> parseSequence({required bool topLevel}) {
    final segments = <_Segment>[];
    // Где в тексте стоят метки эмодзи: для ошибки с позицией.
    final emojiAt = <int, int>{};
    final text = StringBuffer();
    void flush() {
      if (text.isEmpty) return;
      final value = text.toString();
      final emoji = ReplyTemplate.pictographs.firstMatch(value);
      if (emoji != null) {
        _fail('эмодзи «${emoji[0]}» вне метки {э:…}');
      }
      segments.add(_Text(value));
      text.clear();
    }

    while (_pos < source.length) {
      final char = source[_pos];
      if (char == '{') {
        if (_peek(1) == '{') {
          text.write('{');
          _pos += 2;
          continue;
        }
        flush();
        final at = _pos;
        segments.add(_tag(topLevel: topLevel));
        if (segments.last is _Emoji) emojiAt[segments.length - 1] = at;
        continue;
      }
      if (char == '}') {
        if (_peek(1) == '}') {
          text.write('}');
          _pos += 2;
          continue;
        }
        if (topLevel) _fail('лишняя «}»');
        break;
      }
      if (char == '|' && !topLevel) break;
      text.write(char);
      _pos++;
    }
    flush();
    for (final MapEntry(key: index, value: at) in emojiAt.entries) {
      final before = _spaced(
        index == 0 ? null : segments[index - 1],
        before: true,
        boundary: topLevel,
      );
      final after = _spaced(
        index + 1 < segments.length ? segments[index + 1] : null,
        before: false,
        boundary: topLevel,
      );
      if (!before && !after) {
        _pos = at;
        _fail(
          'метка эмодзи приклеена к тексту с обеих сторон: без эмодзи слова '
          'слипнутся — поставьте пробел до или после {э:…}',
        );
      }
    }
    return segments;
  }

  static final RegExp _space = RegExp(r'\s');

  /// С этой стороны метки эмодзи пробел или край всего текста ([boundary]
  /// — метка не внутри выбора): убранная метка не склеит слова.
  static bool _spaced(
    _Segment? neighbour, {
    required bool before,
    required bool boundary,
  }) =>
      switch (neighbour) {
        null => boundary,
        _Text(:final text) =>
          _space.hasMatch(before ? text[text.length - 1] : text[0]),
        _ => false,
      };

  String? _peek(int offset) {
    final index = _pos + offset;
    return index < source.length ? source[index] : null;
  }

  /// Метка с «{» в [_pos].
  _Segment _tag({required bool topLevel}) {
    final start = _pos;
    _pos++;
    final colon = source.indexOf(':', _pos);
    final close = source.indexOf('}', _pos);
    if (close < 0) {
      _pos = start;
      _fail('метка не закрыта «}»');
    }
    final isChoice = colon >= 0 && colon < close;
    if (!isChoice) {
      final name = source.substring(_pos, close);
      if (!ReplyTemplate.namePattern.hasMatch(name)) {
        _pos = start;
        _fail(
          name.contains('|')
              ? 'метка «{$name}» без вида выбора: ожидается м:, вы:, мн: или э:'
              : 'имя подстановки «$name» должно быть латиницей и начинаться '
                  'со строчной буквы',
        );
      }
      _pos = close + 1;
      return _Value(name);
    }
    final kind = source.substring(_pos, colon);
    if (!topLevel && kind != 'э') {
      _pos = start;
      _fail('выбор внутри выбора не поддерживается');
    }
    _pos = colon + 1;
    switch (kind) {
      case 'э':
        final end = source.indexOf('}', _pos);
        final text = source.substring(_pos, end);
        if (text.contains('{') || text.contains('|')) {
          _fail('в метке эмодзи только сами эмодзи');
        }
        final problem = ReplyTemplate.emojiProblem(text);
        if (problem != null) _fail(problem);
        _pos = end + 1;
        return _Emoji(text);
      case 'м' || 'ж':
        final options = _options(start, first: kind);
        final male = options['м'];
        final female = options['ж'];
        if (male == null ||
            female == null ||
            options.length != 2 ||
            !options.keys.every((String k) => k == 'м' || k == 'ж')) {
          _pos = start;
          _fail('род: нужны ровно два варианта «м:» и «ж:»');
        }
        return _Gender(male, female);
      case 'вы' || 'ты':
        final options = _options(start, first: kind);
        final formal = options['вы'];
        final informal = options['ты'];
        if (formal == null ||
            informal == null ||
            options.length != 2 ||
            !options.keys.every((String k) => k == 'вы' || k == 'ты')) {
          _pos = start;
          _fail('обращение: нужны ровно два варианта «вы:» и «ты:»');
        }
        return _Address(formal, informal);
      case 'мн':
        final bar = source.indexOf('|', _pos);
        final end = source.indexOf('}', _pos);
        if (bar < 0 || bar > end) {
          _pos = start;
          _fail('число: ожидается {мн:имя|одна|две|пять}');
        }
        final name = source.substring(_pos, bar);
        if (!ReplyTemplate.namePattern.hasMatch(name)) {
          _pos = start;
          _fail('число: «$name» — не имя подстановки');
        }
        _pos = bar + 1;
        final forms = <List<_Segment>>[];
        while (true) {
          forms.add(parseSequence(topLevel: false));
          if (_pos >= source.length) {
            _pos = start;
            _fail('метка не закрыта «}»');
          }
          final char = source[_pos++];
          if (char == '}') break;
        }
        if (forms.length != 3) {
          _pos = start;
          _fail('число: нужны три формы — одна, две, пять');
        }
        return _Plural(name, forms);
      default:
        _pos = start;
        _fail('неизвестная метка «$kind:»: есть м:/ж:, вы:/ты:, мн:, э:');
    }
  }

  /// Варианты «ключ:текст|ключ:текст}». [_pos] — сразу после первого
  /// «ключ:».
  Map<String, List<_Segment>> _options(int start, {required String first}) {
    final options = <String, List<_Segment>>{};
    var key = first;
    while (true) {
      if (options.containsKey(key)) {
        _pos = start;
        _fail('вариант «$key:» повторяется');
      }
      options[key] = parseSequence(topLevel: false);
      if (_pos >= source.length) {
        _pos = start;
        _fail('метка не закрыта «}»');
      }
      final char = source[_pos++];
      if (char == '}') return options;
      // «|»: следующий вариант с ключом.
      final colon = source.indexOf(':', _pos);
      final bar = source.indexOf('|', _pos);
      final close = source.indexOf('}', _pos);
      if (colon < 0 ||
          (close >= 0 && colon > close) ||
          (bar >= 0 && colon > bar)) {
        _pos = start;
        _fail('у каждого варианта нужен ключ: «м:», «ж:», «вы:» или «ты:»');
      }
      key = source.substring(_pos, colon);
      _pos = colon + 1;
    }
  }
}
