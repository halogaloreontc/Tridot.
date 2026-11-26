import 'dart:convert';
import 'dart:typed_data';

import 'bert_chars.g.dart';

/// Токенизатор пакета модели понимания (ADR-045): фраза → номера токенов
/// со служебными (`[CLS] … [SEP]` или `<s> … </s>`), как у HuggingFace
/// tokenizers с усечением до [IntentTokenizer.encode] `maxLength`.
///
/// Два вида — по `model.type` в `tokenizer.json` пакета:
/// - [WordPieceTokenizer] (была у снятой rubert-tiny2): BertNormalizer
///   (clean_text, без нижнего регистра и снятия ударений), BertPreTokenizer,
///   `##`;
/// - [ByteBpeTokenizer] (USER-base: «Лёгкая» и `web`): byte-level BPE в духе RoBERTa.
///
/// Чистый Dart без ввода-вывода: тот же код работает в приложении и в
/// веб-помощнике.
abstract interface class IntentTokenizer {
  /// Токенизатор из разобранного `tokenizer.json`.
  factory IntentTokenizer.fromJson(Map<String, Object?> json) {
    final model = json['model'];
    if (model is! Map<String, Object?>) {
      throw const FormatException('tokenizer.json: нет model');
    }
    return switch (model['type']) {
      'WordPiece' => WordPieceTokenizer.fromJson(json),
      'BPE' => ByteBpeTokenizer.fromJson(json),
      final Object? other =>
        throw FormatException('tokenizer.json: неизвестная модель $other'),
    };
  }

  /// Токенизатор из текста `tokenizer.json`.
  factory IntentTokenizer.parse(String text) {
    final json = jsonDecode(text);
    if (json is! Map<String, Object?>) {
      throw const FormatException('tokenizer.json: не объект');
    }
    return IntentTokenizer.fromJson(json);
  }

  /// Номер токена-заполнителя для пакета фраз разной длины.
  int get padId;

  /// Номера токенов [text] со служебными, не больше [maxLength] вместе с
  /// ними: лишнее в конце фразы отрезается, как у tokenizers.
  List<int> encode(String text, {int maxLength = 64});
}

/// Пакет фраз для модели: номера, маска и типы токенов, дополненные до
/// одной длины. `Int32List`, а не `Int64List`: в вебе 64-битных списков
/// нет, приложение переводит их само.
final class TokenBatch {
  TokenBatch._(this.rows, this.length, this.ids, this.mask, this.types);

  /// Пакет из номеров [sequences] (каждая — от [IntentTokenizer.encode]).
  factory TokenBatch.of(List<List<int>> sequences, {required int padId}) {
    final rows = sequences.length;
    var length = 0;
    for (final sequence in sequences) {
      if (sequence.length > length) length = sequence.length;
    }
    final ids = Int32List(rows * length)..fillRange(0, rows * length, padId);
    final mask = Int32List(rows * length);
    for (var row = 0; row < rows; row++) {
      final sequence = sequences[row];
      for (var i = 0; i < sequence.length; i++) {
        ids[row * length + i] = sequence[i];
        mask[row * length + i] = 1;
      }
    }
    return TokenBatch._(rows, length, ids, mask, Int32List(rows * length));
  }

  final int rows;

  /// Длина каждой строки пакета.
  final int length;

  /// `input_ids` по строкам: `[rows, length]`.
  final Int32List ids;

  /// `attention_mask`: 1 — токен фразы, 0 — заполнитель.
  final Int32List mask;

  /// `token_type_ids`: одни нули (одна фраза).
  final Int32List types;

  /// Вход модели по имени из `inputs` манифеста.
  Int32List input(String name) => switch (name) {
        'input_ids' => ids,
        'attention_mask' => mask,
        'token_type_ids' => types,
        _ => throw ArgumentError.value(name, 'name', 'неизвестный вход'),
      };
}

/// Служебный токен словаря (`added_tokens`): его ищут в исходном тексте
/// раньше разбора, как tokenizers.
final class AddedToken {
  const AddedToken(this.content, this.id, this.lstrip, this.rstrip);

  final String content;
  final int id;
  final bool lstrip;
  final bool rstrip;
}

/// Кусок текста между служебными токенами или сам токен ([id]).
typedef _Segment = ({String text, int? id});

List<AddedToken> _addedTokens(Map<String, Object?> json) => <AddedToken>[
      for (final token
          in (json['added_tokens'] as List<Object?>?) ?? const <Object?>[])
        if (token is Map<String, Object?> &&
            token['content'] is String &&
            (token['content']! as String).isNotEmpty &&
            token['id'] is int)
          AddedToken(
            token['content']! as String,
            token['id']! as int,
            token['lstrip'] == true,
            token['rstrip'] == true,
          ),
    ];

/// Делит [text] по служебным токенам [added] (самое раннее, при равенстве
/// — самое длинное совпадение).
List<_Segment> _split(String text, List<AddedToken> added) {
  if (added.isEmpty) return <_Segment>[(text: text, id: null)];
  final out = <_Segment>[];
  var rest = text;
  while (rest.isNotEmpty) {
    AddedToken? found;
    var at = -1;
    for (final token in added) {
      final index = rest.indexOf(token.content);
      if (index < 0) continue;
      if (at < 0 ||
          index < at ||
          (index == at && token.content.length > found!.content.length)) {
        at = index;
        found = token;
      }
    }
    if (found == null) {
      out.add((text: rest, id: null));
      break;
    }
    var before = rest.substring(0, at);
    var after = rest.substring(at + found.content.length);
    if (found.lstrip) before = before.trimRight();
    if (found.rstrip) after = after.trimLeft();
    if (before.isNotEmpty) out.add((text: before, id: null));
    out.add((text: '', id: found.id));
    rest = after;
  }
  return out;
}

int _special(Map<String, int> vocab, List<String> names) {
  for (final name in names) {
    final id = vocab[name];
    if (id != null) return id;
  }
  throw FormatException('tokenizer.json: нет токена ${names.first}');
}

Map<String, int> _readVocab(Object? raw) {
  if (raw is! Map<String, Object?>) {
    throw const FormatException('tokenizer.json: нет словаря');
  }
  return <String, int>{
    for (final MapEntry(:key, :value) in raw.entries)
      if (value is int) key: value,
  };
}

/// Обрезка до [maxLength] со служебными по краям.
List<int> _wrap(List<int> ids, int first, int last, int maxLength) {
  final room = maxLength - 2;
  final body = ids.length > room ? ids.sublist(0, room < 0 ? 0 : room) : ids;
  return <int>[first, ...body, last];
}

/// WordPiece в духе BERT: BertNormalizer (clean_text, иероглифы — отдельно;
/// регистр и ударения не трогаются), BertPreTokenizer (пробелы и знаки
/// препинания), жадный поиск самого длинного куска словаря, продолжение —
/// с `##`. Слово длиннее [maxCharsPerWord] знаков или без разбора —
/// `[UNK]` целиком.
final class WordPieceTokenizer implements IntentTokenizer {
  WordPieceTokenizer({
    required Map<String, int> vocab,
    this.prefix = '##',
    this.maxCharsPerWord = 100,
    List<AddedToken> added = const <AddedToken>[],
  })  : _vocab = vocab,
        _added = added,
        unkId = _special(vocab, const <String>['[UNK]']),
        clsId = _special(vocab, const <String>['[CLS]']),
        sepId = _special(vocab, const <String>['[SEP]']),
        padId = _special(vocab, const <String>['[PAD]']);

  factory WordPieceTokenizer.fromJson(Map<String, Object?> json) {
    final model = json['model']! as Map<String, Object?>;
    final normalizer = json['normalizer'];
    if (normalizer is Map<String, Object?> &&
        (normalizer['lowercase'] == true ||
            normalizer['strip_accents'] == true)) {
      // Пакеты WordPiece регистр сохраняют; иначе нужен другой разбор.
      throw const FormatException(
        'tokenizer.json: нижний регистр и снятие ударений не поддержаны',
      );
    }
    return WordPieceTokenizer(
      vocab: _readVocab(model['vocab']),
      prefix: model['continuing_subword_prefix'] as String? ?? '##',
      maxCharsPerWord: model['max_input_chars_per_word'] as int? ?? 100,
      added: _addedTokens(json),
    );
  }

  final Map<String, int> _vocab;
  final List<AddedToken> _added;

  /// Приставка куска внутри слова.
  final String prefix;

  final int maxCharsPerWord;

  final int unkId;
  final int clsId;
  final int sepId;

  @override
  final int padId;

  @override
  List<int> encode(String text, {int maxLength = 64}) {
    final ids = <int>[];
    for (final segment in _split(text, _added)) {
      if (segment.id case final int id) {
        ids.add(id);
        continue;
      }
      for (final word in words(normalize(segment.text))) {
        _piece(word, ids);
      }
    }
    return _wrap(ids, clsId, sepId, maxLength);
  }

  /// BertNormalizer: управляющие знаки убраны, пробельные — пробел,
  /// иероглифы окружены пробелами.
  static String normalize(String text) {
    final out = StringBuffer();
    for (final rune in text.runes) {
      if (BertCharClasses.inRanges(BertCharClasses.removed, rune)) continue;
      if (BertCharClasses.inRanges(BertCharClasses.space, rune)) {
        out.write(' ');
      } else if (BertCharClasses.inRanges(BertCharClasses.cjk, rune)) {
        out
          ..write(' ')
          ..writeCharCode(rune)
          ..write(' ');
      } else {
        out.writeCharCode(rune);
      }
    }
    return out.toString();
  }

  /// BertPreTokenizer: слова по пробелам, каждый знак препинания — слово.
  static List<String> words(String text) {
    final out = <String>[];
    final current = StringBuffer();
    void flush() {
      if (current.isEmpty) return;
      out.add(current.toString());
      current.clear();
    }

    for (final rune in text.runes) {
      if (rune == 0x20) {
        flush();
      } else if (BertCharClasses.inRanges(BertCharClasses.punct, rune)) {
        flush();
        out.add(String.fromCharCode(rune));
      } else {
        current.writeCharCode(rune);
      }
    }
    flush();
    return out;
  }

  void _piece(String word, List<int> ids) {
    final runes = word.runes.toList();
    if (runes.length > maxCharsPerWord) {
      ids.add(unkId);
      return;
    }
    final pieces = <int>[];
    var start = 0;
    while (start < runes.length) {
      var end = runes.length;
      int? found;
      while (start < end) {
        final body = String.fromCharCodes(runes, start, end);
        final id = _vocab[start > 0 ? '$prefix$body' : body];
        if (id != null) {
          found = id;
          break;
        }
        end--;
      }
      if (found == null) {
        ids.add(unkId);
        return;
      }
      pieces.add(found);
      start = end;
    }
    ids.addAll(pieces);
  }
}

/// Byte-level BPE в духе RoBERTa: без нормализации, разбиение регулярным
/// выражением GPT-2 (без пробела в начале фразы), байты UTF-8 → знаки
/// таблицы `bytes_to_unicode`, слияния по рангу `merges`.
final class ByteBpeTokenizer implements IntentTokenizer {
  ByteBpeTokenizer({
    required Map<String, int> vocab,
    required List<(String, String)> merges,
    List<AddedToken> added = const <AddedToken>[],
  })  : _vocab = vocab,
        _added = added,
        _ranks = <String, int>{
          for (final (index, (a, b)) in merges.indexed) '$a $b': index,
        },
        bosId = _special(vocab, const <String>['<s>']),
        eosId = _special(vocab, const <String>['</s>']),
        padId = _special(vocab, const <String>['<pad>']);

  factory ByteBpeTokenizer.fromJson(Map<String, Object?> json) {
    final model = json['model']! as Map<String, Object?>;
    final pre = json['pre_tokenizer'];
    if (pre is Map<String, Object?> && pre['add_prefix_space'] == true) {
      throw const FormatException(
        'tokenizer.json: пробел в начале фразы не поддержан',
      );
    }
    final merges = <(String, String)>[];
    for (final merge in (model['merges'] as List<Object?>?) ?? const []) {
      if (merge is String) {
        final space = merge.indexOf(' ');
        if (space > 0) {
          merges.add((merge.substring(0, space), merge.substring(space + 1)));
        }
      } else if (merge is List<Object?> &&
          merge.length == 2 &&
          merge[0] is String &&
          merge[1] is String) {
        merges.add((merge[0]! as String, merge[1]! as String));
      }
    }
    return ByteBpeTokenizer(
      vocab: _readVocab(model['vocab']),
      merges: merges,
      added: _addedTokens(json),
    );
  }

  final Map<String, int> _vocab;
  final List<AddedToken> _added;
  final Map<String, int> _ranks;
  final Map<String, List<int>> _cache = <String, List<int>>{};

  final int bosId;
  final int eosId;

  @override
  final int padId;

  /// Разбиение GPT-2.
  static final RegExp _pattern = RegExp(
    r"""'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+""",
    unicode: true,
  );

  /// Байт → знак: печатные байты — сами собой, остальные — с U+0100.
  static final List<String> _byteChars = () {
    final printable = <int>[
      for (var b = 0x21; b <= 0x7E; b++) b,
      for (var b = 0xA1; b <= 0xAC; b++) b,
      for (var b = 0xAE; b <= 0xFF; b++) b,
    ];
    final table = List<String>.filled(256, '');
    var extra = 0;
    for (var b = 0; b < 256; b++) {
      table[b] = printable.contains(b)
          ? String.fromCharCode(b)
          : String.fromCharCode(256 + extra++);
    }
    return table;
  }();

  @override
  List<int> encode(String text, {int maxLength = 64}) {
    final ids = <int>[];
    for (final segment in _split(text, _added)) {
      if (segment.id case final int id) {
        ids.add(id);
        continue;
      }
      for (final match in _pattern.allMatches(segment.text)) {
        final piece = match.group(0)!;
        final mapped = StringBuffer();
        for (final byte in utf8.encode(piece)) {
          mapped.write(_byteChars[byte]);
        }
        ids.addAll(_bpe(mapped.toString()));
      }
    }
    return _wrap(ids, bosId, eosId, maxLength);
  }

  List<int> _bpe(String word) {
    final cached = _cache[word];
    if (cached != null) return cached;
    var symbols = <String>[
      for (final rune in word.runes) String.fromCharCode(rune),
    ];
    while (symbols.length > 1) {
      int? best;
      for (var i = 0; i < symbols.length - 1; i++) {
        final rank = _ranks['${symbols[i]} ${symbols[i + 1]}'];
        if (rank != null && (best == null || rank < best)) best = rank;
      }
      if (best == null) break;
      final merged = <String>[];
      var i = 0;
      while (i < symbols.length) {
        if (i < symbols.length - 1 &&
            _ranks['${symbols[i]} ${symbols[i + 1]}'] == best) {
          merged.add('${symbols[i]}${symbols[i + 1]}');
          i += 2;
        } else {
          merged.add(symbols[i]);
          i++;
        }
      }
      symbols = merged;
    }
    final ids = <int>[
      for (final symbol in symbols)
        if (_vocab[symbol] case final int id) id,
    ];
    if (_cache.length < 4096) _cache[word] = ids;
    return ids;
  }
}
