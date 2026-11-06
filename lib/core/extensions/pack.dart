import 'dart:convert';

import '../replies/reply_library.dart';

/// Для кого запись пака: для любого помощника, только Liorio или только Noda.
/// Значение в JSON — id помощника: `rio` (Liorio, id от прежнего имени,
/// ADR-008) или `noda`; `liorio` читается как `rio`.
enum PackPersona {
  any,
  rio,
  noda;

  /// Подходит ли запись помощнику [persona]: `any` подходит всем.
  bool suits(PackPersona persona) =>
      this == PackPersona.any || persona == PackPersona.any || this == persona;
}

/// Стиль общения, к которому подходит запись (docs/PLANS.md, «Каталог
/// ответов и стили общения»).
enum PackStyle { neutral, friendly, brief, business }

/// Запись пака: шутка, каламбур, фраза. Текст — только текст: он не
/// выполняется и не читается как разметка.
final class PackEntry {
  const PackEntry({
    required this.id,
    required this.text,
    this.tags = const <String>[],
    this.persona = PackPersona.any,
    this.styles = const <PackStyle>[],
  });

  /// Уникален внутри пака.
  final String id;

  final String text;

  /// Темы в нижнем регистре: «задачи», «понедельник».
  final List<String> tags;

  final PackPersona persona;

  /// Пусто — подходит любому стилю.
  final List<PackStyle> styles;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'text': text,
        if (tags.isNotEmpty) 'tags': tags,
        if (persona != PackPersona.any) 'persona': persona.name,
        if (styles.isNotEmpty)
          'styles': <String>[for (final style in styles) style.name],
      };
}

/// Пак: только содержимое, без кода (docs/EXTENSIONS.md).
final class Pack {
  const Pack({
    required this.id,
    required this.type,
    required this.title,
    required this.author,
    required this.version,
    required this.entries,
    this.language = 'ru',
    this.description = '',
    this.replies = const <String, List<String>>{},
  });

  final String id;

  /// Что внутри: [PackFormat.types].
  final String type;
  final String title;
  final String author;
  final String language;
  final String version;
  final String description;

  /// Записи паков шуток, каламбуров и фраз. У пака ответов пусто.
  final List<PackEntry> entries;

  /// Пак ответов (`type: replies`): варианты фраз по id записи каталога.
  final Map<String, List<String>> replies;

  /// Стиль общения из пака ответов: id стиля — id пака.
  ReplyCatalog replyCatalog({bool builtIn = false}) => ReplyCatalog(
        style: id,
        title: title,
        description: description,
        builtIn: builtIn,
        entries: <String, List<ReplyTemplate>>{
          // Пак уже проверен при разборе: шаблоны разбираются без ошибок.
          for (final MapEntry(:key, :value) in replies.entries)
            key: <ReplyTemplate>[
              for (final text in value) ReplyTemplate.parse(text),
            ],
        },
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'format': PackFormat.format,
        'id': id,
        'type': type,
        'title': title,
        'author': author,
        'language': language,
        'version': version,
        if (description.isNotEmpty) 'description': description,
        'entries': type == PackFormat.repliesType
            ? <String, Object?>{
                for (final MapEntry(:key, :value) in replies.entries)
                  key: value.length == 1 ? value.single : value,
              }
            : <Map<String, Object?>>[
                for (final entry in entries) entry.toJson(),
              ],
      };

  /// Компактный JSON: так пак на диске не больше вставленного текста и
  /// проходит предел [PackFormat.maxBytes] при следующей загрузке.
  String encode() => jsonEncode(toJson());
}

/// Итог разбора пака: пак или список ошибок по-русски.
final class PackParseResult {
  const PackParseResult._(this.pack, this.errors);

  final Pack? pack;

  /// Понятные ошибки с местом: «entries[3].text: текст длиннее 500
  /// символов». Пусто, если пак принят.
  final List<String> errors;

  bool get ok => pack != null;
}

/// Формат паков `assistant-pack/1` и его строгая проверка.
abstract final class PackFormat {
  static const String format = 'assistant-pack/1';

  /// Известные виды паков. Новый вид добавляется сюда вместе с навыком,
  /// который им пользуется.
  static const Set<String> types = <String>{
    'jokes',
    'puns',
    'phrases',
    repliesType,
  };

  /// Пак ответов: свой стиль общения (docs/REPLIES.md). `entries` —
  /// объект {id записи каталога: вариант или список из 1–3 вариантов}.
  static const String repliesType = 'replies';

  /// Пока только русский.
  static const Set<String> languages = <String>{'ru'};

  static const int maxBytes = 1024 * 1024;
  static const int maxEntries = 5000;
  static const int maxTextLength = 500;
  static const int maxTags = 10;
  static const int maxTagLength = 30;
  static const int maxTitleLength = 100;
  static const int maxDescriptionLength = 500;

  /// Сколько ошибок показать: дальше — «и ещё N».
  static const int maxReportedErrors = 20;

  static final RegExp idPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{1,63}$');
  static final RegExp entryIdPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$');
  static final RegExp versionPattern = RegExp(r'^\d{1,4}\.\d{1,4}\.\d{1,4}$');

  /// Управляющие символы, кроме перевода строки и табуляции, и знаки
  /// направления текста (U+202E и соседи): с ними название в настройках
  /// показалось бы задом наперёд.
  static final RegExp _control = RegExp(
    r'[\u0000-\u0008\u000B-\u001F\u007F-\u009F\u061C\u200E\u200F'
    r'\u202A-\u202E\u2066-\u2069]',
  );

  static const Set<String> _topKeys = <String>{
    'format',
    'id',
    'type',
    'title',
    'author',
    'language',
    'version',
    'description',
    'entries',
  };

  static const Set<String> _entryKeys = <String>{
    'id',
    'text',
    'tags',
    'persona',
    'styles',
  };

  /// Разбирает и проверяет пак. Ничего не выполняет: текст записей
  /// остаётся текстом.
  ///
  /// Пак ответов проверяется против [replySchema] (по умолчанию —
  /// встроенный каталог): только известные записи и подстановки, разметка
  /// рода, обращения и эмодзи без ошибок.
  static PackParseResult parse(String input, {ReplySchema? replySchema}) {
    final errors = <String>[];
    // Метка порядка байтов из редакторов Windows — не часть JSON.
    final source = input.startsWith('\uFEFF') ? input.substring(1) : input;
    if (utf8.encode(source).length > maxBytes) {
      return const PackParseResult._(null, <String>[
        'Файл пака больше 1 МБ.',
      ]);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      return PackParseResult._(null, <String>[
        'Это не JSON: ${error.message}.',
      ]);
    }
    if (decoded is! Map<String, Object?>) {
      return const PackParseResult._(null, <String>[
        'Пак должен быть JSON-объектом { … }.',
      ]);
    }
    final json = decoded;

    for (final key in json.keys) {
      if (!_topKeys.contains(key)) errors.add('Неизвестное поле «$key».');
    }

    final formatValue = json['format'];
    if (formatValue is! String) {
      errors.add('Нет поля «format»: ожидается «$format».');
    } else if (formatValue != format) {
      errors.add(
        formatValue.startsWith('assistant-pack/')
            ? 'Версия формата «$formatValue» не поддерживается: '
                'ожидается «$format».'
            : 'Неизвестный формат «$formatValue»: ожидается «$format».',
      );
    }

    String? text(String key, String name, {int max = maxTitleLength}) {
      final value = json[key];
      if (value == null) {
        errors.add('Нет поля «$key» ($name).');
        return null;
      }
      if (value is! String) {
        errors.add('Поле «$key» должно быть строкой.');
        return null;
      }
      final trimmed = value.trim();
      if (trimmed.isEmpty) {
        errors.add('Поле «$key» пустое.');
        return null;
      }
      if (trimmed.length > max) {
        errors.add('Поле «$key» длиннее $max символов.');
        return null;
      }
      if (_control.hasMatch(trimmed)) {
        errors.add('В поле «$key» есть управляющие символы.');
        return null;
      }
      return trimmed;
    }

    final id = text('id', 'идентификатор', max: 64);
    if (id != null && !idPattern.hasMatch(id)) {
      errors.add(
        'Идентификатор «$id» не подходит: 2–64 символа, строчные '
        'латинские буквы, цифры, «.», «_», «-»; начинается с буквы или '
        'цифры.',
      );
    }
    final type = text('type', 'вид пака', max: 32);
    if (type != null && !types.contains(type)) {
      errors.add(
        'Неизвестный вид пака «$type». Поддерживаются: ${types.join(', ')}.',
      );
    }
    final title = text('title', 'название');
    final author = text('author', 'автор');
    final language = text('language', 'язык', max: 16);
    if (language != null && !languages.contains(language)) {
      errors.add('Язык «$language» пока не поддерживается: только «ru».');
    }
    final version = text('version', 'версия', max: 16);
    if (version != null && !versionPattern.hasMatch(version)) {
      errors.add('Версия «$version» должна быть вида «1.0.0».');
    }
    var description = '';
    if (json.containsKey('description')) {
      final value = json['description'];
      if (value is! String) {
        errors.add('Поле «description» должно быть строкой.');
      } else if (value.trim().length > maxDescriptionLength) {
        errors.add(
          'Поле «description» длиннее $maxDescriptionLength символов.',
        );
      } else if (_control.hasMatch(value)) {
        errors.add('В поле «description» есть управляющие символы.');
      } else {
        description = value.trim();
      }
    }

    final entries = <PackEntry>[];
    var replies = const <String, List<String>>{};
    final rawEntries = json['entries'];
    if (type == repliesType && id != null && ReplyStyles.builtIn.contains(id)) {
      errors.add('Id «$id» занят встроенным стилем: выберите другой.');
    }
    if (rawEntries == null) {
      errors.add('Нет поля «entries» (записи).');
    } else if (type == repliesType) {
      replies = _replies(
        rawEntries,
        replySchema ?? ReplyLibrary.builtIn.schema,
        errors,
      );
    } else if (rawEntries is! List<Object?>) {
      errors.add('Поле «entries» должно быть списком.');
    } else if (rawEntries.isEmpty) {
      errors.add('В паке нет ни одной записи.');
    } else if (rawEntries.length > maxEntries) {
      errors.add('Записей больше $maxEntries.');
    } else {
      final seen = <String>{};
      for (var i = 0; i < rawEntries.length; i++) {
        final entry = _entry(rawEntries[i], 'entries[$i]', errors, seen);
        // Проверяем все записи до конца: «И ещё ошибок: N» — настоящее
        // число. Размер ограничен 1 МБ и 5000 записями.
        if (entry != null) entries.add(entry);
      }
    }

    if (errors.isNotEmpty) return PackParseResult._(null, _trim(errors));
    return PackParseResult._(
      Pack(
        id: id!,
        type: type!,
        title: title!,
        author: author!,
        language: language!,
        version: version!,
        description: description,
        entries: List<PackEntry>.unmodifiable(entries),
        replies: replies,
      ),
      const <String>[],
    );
  }

  /// Записи пака ответов: объект {id: варианты}. Проверяются все.
  static Map<String, List<String>> _replies(
    Object rawEntries,
    ReplySchema schema,
    List<String> errors,
  ) {
    if (rawEntries is! Map<String, Object?>) {
      errors.add(
        'У пака ответов «entries» — объект {id записи: варианты}.',
      );
      return const <String, List<String>>{};
    }
    if (rawEntries.isEmpty) {
      errors.add('В паке нет ни одной записи.');
      return const <String, List<String>>{};
    }
    if (rawEntries.length > maxEntries) {
      errors.add('Записей больше $maxEntries.');
      return const <String, List<String>>{};
    }
    final parsed = ReplyFormat.parseEntries(
      rawEntries,
      errors,
      schema: schema,
      pack: true,
    );
    if (parsed == null) return const <String, List<String>>{};
    return Map<String, List<String>>.unmodifiable(<String, List<String>>{
      for (final MapEntry(:key, :value) in parsed.entries)
        key: List<String>.unmodifiable(
          value.map((ReplyTemplate t) => t.source),
        ),
    });
  }

  static List<String> _trim(List<String> errors) {
    if (errors.length <= maxReportedErrors) return errors;
    final rest = errors.length - maxReportedErrors;
    return <String>[
      ...errors.take(maxReportedErrors),
      'И ещё ошибок: $rest.',
    ];
  }

  static PackEntry? _entry(
    Object? raw,
    String where,
    List<String> errors,
    Set<String> seen,
  ) {
    if (raw is! Map<String, Object?>) {
      errors.add('$where: запись должна быть объектом { … }.');
      return null;
    }
    final before = errors.length;
    for (final key in raw.keys) {
      if (!_entryKeys.contains(key)) {
        errors.add('$where: неизвестное поле «$key».');
      }
    }
    final id = raw['id'];
    if (id is! String) {
      errors.add('$where: нет строкового поля «id».');
    } else if (!entryIdPattern.hasMatch(id)) {
      errors.add(
        '$where: id «$id» — до 64 символов из строчных латинских букв, '
        'цифр, «.», «_», «-».',
      );
    } else if (!seen.add(id)) {
      errors.add('$where: id «$id» уже есть в паке.');
    }
    final text = raw['text'];
    String? trimmed;
    if (text is! String) {
      errors.add('$where: нет строкового поля «text».');
    } else {
      trimmed = text.trim();
      if (trimmed.isEmpty) {
        errors.add('$where: пустой текст.');
      } else if (trimmed.length > maxTextLength) {
        errors.add('$where: текст длиннее $maxTextLength символов.');
      } else if (_control.hasMatch(trimmed)) {
        errors.add('$where: в тексте есть управляющие символы.');
      }
    }
    final tags = <String>[];
    final rawTags = raw['tags'];
    if (rawTags != null) {
      if (rawTags is! List<Object?>) {
        errors.add('$where: «tags» должно быть списком строк.');
      } else if (rawTags.length > maxTags) {
        errors.add('$where: меток больше $maxTags.');
      } else {
        for (final tag in rawTags) {
          if (tag is! String || tag.trim().isEmpty) {
            errors.add('$where: метка должна быть непустой строкой.');
          } else if (_control.hasMatch(tag)) {
            errors.add('$where: в метке есть управляющие символы.');
          } else if (tag.trim().length > maxTagLength) {
            errors.add('$where: метка «$tag» длиннее $maxTagLength символов.');
          } else {
            final normalized = _normalizeTag(tag);
            if (!tags.contains(normalized)) tags.add(normalized);
          }
        }
      }
    }
    var persona = PackPersona.any;
    final rawPersona = raw['persona'];
    if (rawPersona != null) {
      final id = rawPersona == 'liorio' ? PackPersona.rio.name : rawPersona;
      final match = id is String
          ? PackPersona.values.where((p) => p.name == id).firstOrNull
          : null;
      if (match == null) {
        errors.add(
          '$where: persona должна быть одной из: any, rio (Liorio), noda.',
        );
      } else {
        persona = match;
      }
    }
    final styles = <PackStyle>[];
    final rawStyles = raw['styles'];
    if (rawStyles != null) {
      if (rawStyles is! List<Object?>) {
        errors.add('$where: «styles» должно быть списком строк.');
      } else {
        for (final style in rawStyles) {
          final match = style is String
              ? PackStyle.values.where((s) => s.name == style).firstOrNull
              : null;
          if (match == null) {
            errors.add(
              '$where: неизвестный стиль «$style». Есть: '
              '${PackStyle.values.map((s) => s.name).join(', ')}.',
            );
          } else if (!styles.contains(match)) {
            styles.add(match);
          }
        }
      }
    }
    if (errors.length != before) return null;
    return PackEntry(
      id: id! as String,
      text: trimmed!,
      tags: List<String>.unmodifiable(tags),
      persona: persona,
      styles: List<PackStyle>.unmodifiable(styles),
    );
  }

  static String _normalizeTag(String tag) =>
      tag.trim().toLowerCase().replaceAll('ё', 'е');

  /// Метка для поиска: как в паке после проверки.
  static String normalizeTag(String tag) => _normalizeTag(tag);
}
