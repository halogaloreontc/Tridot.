import 'dart:convert';

import 'reply_template.dart';

export 'reply_template.dart';

/// Что говорит помощник: запись каталога по id и факты для подстановки.
final class Reply {
  const Reply(this.id, [this.values = const <String, String>{}]);

  /// Идентификатор записи: `task.created`, `calc.result`.
  final String id;

  /// Факты: название, срок, число. Каталог только оборачивает их в слова.
  final Map<String, String> values;
}

/// Как сейчас говорит помощник: стиль, род, обращение, эмодзи.
final class ReplyVoice {
  const ReplyVoice({
    this.style = ReplyStyles.neutral,
    this.gender = ReplyGender.male,
    this.address = ReplyAddress.formal,
    this.emoji = true,
  });

  /// Id стиля: встроенного (`neutral`, `friendly`, `brief`, `business`)
  /// или пака ответов. Неизвестный стиль — нейтральный.
  final String style;
  final ReplyGender gender;
  final ReplyAddress address;

  /// Показывать эмодзи, если стиль ими пользуется.
  final bool emoji;
}

/// Встроенные стили общения.
abstract final class ReplyStyles {
  static const String neutral = 'neutral';
  static const String friendly = 'friendly';
  static const String brief = 'brief';
  static const String business = 'business';

  /// В порядке показа в настройках.
  static const List<String> builtIn = <String>[
    neutral,
    friendly,
    brief,
    business,
  ];
}

/// Что известно о записи по нейтральному каталогу: какие подстановки
/// обязательны во всех стилях и что нельзя потерять.
final class ReplySpec {
  const ReplySpec({
    required this.id,
    required this.placeholders,
    this.question = false,
    this.keep = const <String>{},
    this.sentenceEnd = false,
    this.protected = false,
  });

  final String id;

  /// Подстановки нейтрального текста: каждая обязана попасть в любой
  /// вариант любого стиля при любом роде, обращении и форме числа.
  final Set<String> placeholders;

  /// Нейтральный текст — вопрос («?»): во всех стилях тоже вопрос.
  final bool question;

  /// Знаки, которые нельзя потерять: «≈» у приближённого ответа.
  final Set<String> keep;

  /// Нейтральный текст кончается знаком конца предложения («.», «!»,
  /// «?», «…»): и каждый вариант без эмодзи тоже. Иначе при выключенных
  /// эмодзи соседние фразы слипаются без точки.
  final bool sentenceEnd;

  /// Предупреждение или вопрос-подтверждение («На ноль делить нельзя»,
  /// «Отметить «…» выполненной?»): пак ответов не может его
  /// переопределить — звучит текст встроенного стиля. Так пак не скажет
  /// «Готово!» вместо предупреждения и «Отметил» вместо вопроса.
  final bool protected;
}

/// Записи, известные каталогу, и проверка вариантов против них.
final class ReplySchema {
  ReplySchema(Map<String, ReplySpec> specs)
      : specs = Map<String, ReplySpec>.unmodifiable(specs);

  final Map<String, ReplySpec> specs;

  /// Знаки-предупреждения, которые стиль обязан сохранить.
  static const Set<String> warningMarks = <String>{'≈'};

  ReplySpec? operator [](String id) => specs[id];

  bool contains(String id) => specs.containsKey(id);

  /// Проблемы варианта [template] записи [id] по-русски; пусто — годен.
  ///
  /// Подстановки — только известные; каждая обязательная попадает в текст
  /// при любом роде и обращении, с эмодзи и без и при любой форме числа
  /// (одна, две, пять — значения [sentinels] каждой формы); вопрос
  /// остаётся вопросом; «≈» не теряется; конец предложения не теряется
  /// без эмодзи; текст не пустой.
  List<String> check(String id, ReplyTemplate template) {
    final spec = specs[id];
    if (spec == null) return <String>['неизвестная запись «$id»'];
    final problems = <String>[];
    for (final name in template.placeholders) {
      if (!spec.placeholders.contains(name)) {
        problems.add(
          'неизвестная подстановка {$name}'
          '${spec.placeholders.isEmpty ? '' : ': есть ${_list(spec.placeholders)}'}',
        );
      }
    }
    if (problems.isNotEmpty) return problems;
    final missing = <String>{};
    var lostQuestion = false;
    final lostMarks = <String>{};
    var empty = false;
    var lostEnd = false;
    for (var form = 0; form < pluralForms; form++) {
      final values = sentinels(spec.placeholders, form: form);
      for (final combination in combinations) {
        final text = template.render(
          values,
          gender: combination.$1,
          address: combination.$2,
          emoji: combination.$3,
        );
        if (text.trim().isEmpty) empty = true;
        for (final name in spec.placeholders) {
          if (!text.contains(values[name]!)) missing.add(name);
        }
        if (spec.question && !text.contains('?')) lostQuestion = true;
        for (final mark in spec.keep) {
          if (!text.contains(mark)) lostMarks.add(mark);
        }
        if (spec.sentenceEnd && !combination.$3 && !endsSentence(text)) {
          lostEnd = true;
        }
      }
    }
    if (empty) problems.add('пустой текст');
    if (missing.isNotEmpty) {
      problems.add(
        'не во всех вариантах рода, обращения и числа есть ${_list(missing)}',
      );
    }
    if (lostQuestion) problems.add('уточнение должно остаться вопросом «?»');
    for (final mark in lostMarks) {
      problems.add('предупреждение «$mark» нельзя убирать');
    }
    if (lostEnd) {
      problems.add(
        'без эмодзи текст должен кончаться «.», «!», «?» или «…», как '
        'нейтральный: ставьте знак перед меткой {э:…}',
      );
    }
    return problems;
  }

  /// Текст кончается знаком конца предложения, возможно — за ним закрытая
  /// кавычка или скобка: «…в 15:00.», «Готово!», «(например, «Отчёт».)».
  static bool endsSentence(String text) => _sentenceEnd.hasMatch(text);

  static final RegExp _sentenceEnd = RegExp('[.!?…][»"\')]*\\s*\$');

  static String _list(Iterable<String> names) =>
      (names.toList()..sort()).map((String n) => '{$n}').join(', ');

  /// Все сочетания рода, обращения и эмодзи.
  static final List<(ReplyGender, ReplyAddress, bool)> combinations =
      <(ReplyGender, ReplyAddress, bool)>[
    for (final gender in ReplyGender.values)
      for (final address in ReplyAddress.values)
        for (final emoji in <bool>[true, false]) (gender, address, emoji),
  ];

  /// Сколько форм числа проверяет [check]: одна, две, пять.
  static const int pluralForms = 3;

  /// Уникальные числа-заглушки для проверки. Каждое подходит для
  /// `{мн:…}` и оканчивается на 1, 2 или 5 — форма числа [form]: 0 —
  /// «одна» (…01), 1 — «две» (…02), 2 — «пять» (…05). Так проверка
  /// видит и подстановку внутри формы числа, и форму, где число написано
  /// словом («две задачи»). Одинаковая длина не даёт одному значению
  /// найтись внутри другого.
  static Map<String, String> sentinels(
    Iterable<String> names, {
    int form = 2,
  }) {
    final sorted = names.toList()..sort();
    final ending = const <int>[1, 2, 5][form];
    return <String, String>{
      for (var i = 0; i < sorted.length; i++)
        sorted[i]: '${91700000 + i * 100 + ending}',
    };
  }

  /// Схема по нейтральному каталогу: подстановки и признаки берутся из
  /// первого варианта. Остальные варианты нейтрального текста проверяются
  /// против неё же. [protected] — запись из списка `protected`.
  static ReplySpec specFor(
    String id,
    ReplyTemplate neutral, {
    bool protected = false,
  }) {
    final values = sentinels(neutral.placeholders);
    final text = neutral.render(values, emoji: false);
    return ReplySpec(
      id: id,
      placeholders: neutral.placeholders,
      question: text.contains('?'),
      keep: <String>{
        for (final mark in warningMarks)
          if (text.contains(mark)) mark,
      },
      sentenceEnd: endsSentence(text),
      protected: protected,
    );
  }
}

/// Каталог одного стиля: варианты фраз по id.
final class ReplyCatalog {
  const ReplyCatalog({
    required this.style,
    required this.title,
    required this.entries,
    this.description = '',
    this.builtIn = true,
    this.protectedIds = const <String>{},
  });

  /// Id стиля: `neutral` или id пака ответов.
  final String style;

  /// Название для настроек: «Дружеский».
  final String title;

  final String description;

  /// Встроенный стиль или пак ответов.
  final bool builtIn;

  /// 1–3 варианта на запись. Записи, которых нет, берутся из
  /// нейтрального каталога.
  final Map<String, List<ReplyTemplate>> entries;

  /// Только у нейтрального: предупреждения и вопросы-подтверждения
  /// (поле `protected`), которые паки ответов не переопределяют
  /// ([ReplySpec.protected]).
  final Set<String> protectedIds;
}

/// Итог разбора каталога: каталог или ошибки по-русски.
final class ReplyCatalogParseResult {
  const ReplyCatalogParseResult._(this.catalog, this.errors);

  final ReplyCatalog? catalog;
  final List<String> errors;

  bool get ok => catalog != null;
}

/// Формат файлов каталога `assets/replies/<стиль>.json` и общие правила
/// записей (тех же, что в паке ответов).
abstract final class ReplyFormat {
  static const String format = 'assistant-replies/1';

  static const int maxVariants = 3;
  static const int maxTextLength = 500;

  static final RegExp idPattern =
      RegExp(r'^[a-z][a-zA-Z0-9]*(\.[a-z][a-zA-Z0-9]*)+$');
  static final RegExp stylePattern = RegExp(r'^[a-z0-9][a-z0-9._-]{1,63}$');

  static final RegExp _control = RegExp(
    r'[\u0000-\u0008\u000B-\u001F\u007F-\u009F\u061C\u200E\u200F'
    r'\u202A-\u202E\u2066-\u2069]',
  );

  static const Set<String> _keys = <String>{
    'format',
    'style',
    'title',
    'description',
    'entries',
    'protected',
  };

  /// Разбирает каталог стиля. Без [schema] это нейтральный каталог: он сам
  /// задаёт записи и их подстановки, а в поле `protected` — список
  /// предупреждений и вопросов-подтверждений. Со [schema] записи
  /// проверяются против неё ([ReplySchema.check]); каталог не из
  /// встроенных ([builtIn] = `false`) не может переопределять
  /// [ReplySpec.protected].
  static ReplyCatalogParseResult parse(
    String source, {
    ReplySchema? schema,
    bool builtIn = true,
  }) {
    final errors = <String>[];
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      return ReplyCatalogParseResult._(null, <String>[
        'Это не JSON: ${error.message}.',
      ]);
    }
    if (decoded is! Map<String, Object?>) {
      return const ReplyCatalogParseResult._(null, <String>[
        'Каталог должен быть JSON-объектом { … }.',
      ]);
    }
    for (final key in decoded.keys) {
      if (!_keys.contains(key)) errors.add('Неизвестное поле «$key».');
    }
    if (decoded['format'] != format) {
      errors.add('Поле «format» должно быть «$format».');
    }
    final style = decoded['style'];
    if (style is! String || !stylePattern.hasMatch(style)) {
      errors.add('Поле «style» — id стиля латиницей.');
    }
    final title = decoded['title'];
    if (title is! String || title.trim().isEmpty) {
      errors.add('Нет названия стиля «title».');
    }
    final description = decoded['description'] ?? '';
    if (description is! String) {
      errors.add('Поле «description» должно быть строкой.');
    }
    final rawEntries = decoded['entries'];
    final entries = rawEntries is Map<String, Object?>
        ? parseEntries(
            rawEntries,
            schema: schema,
            where: 'entries',
            pack: !builtIn,
            errors,
          )
        : null;
    if (rawEntries is! Map<String, Object?>) {
      errors.add('Поле «entries» должно быть объектом {id: варианты}.');
    }
    final protectedIds = <String>{};
    final rawProtected = decoded['protected'];
    if (rawProtected != null) {
      if (schema != null) {
        errors.add(
          'Поле «protected» есть только у нейтрального каталога.',
        );
      } else if (rawProtected is! List<Object?>) {
        errors.add('Поле «protected» — список id записей.');
      } else {
        for (final id in rawProtected) {
          if (id is! String ||
              (rawEntries is Map<String, Object?> &&
                  !rawEntries.containsKey(id))) {
            errors.add('protected: «$id» — нет такой записи.');
          } else {
            protectedIds.add(id);
          }
        }
      }
    }
    if (errors.isNotEmpty || entries == null) {
      return ReplyCatalogParseResult._(null, errors);
    }
    return ReplyCatalogParseResult._(
      ReplyCatalog(
        style: style! as String,
        title: (title! as String).trim(),
        description: (description as String).trim(),
        entries: entries,
        builtIn: builtIn,
        protectedIds: Set<String>.unmodifiable(protectedIds),
      ),
      const <String>[],
    );
  }

  /// Записи `{id: "текст" | ["вариант", …]}`. Без [schema] — нейтральные:
  /// все варианты записи с одинаковыми подстановками. [pack] — записи пака
  /// ответов: предупреждения и вопросы-подтверждения ([ReplySpec.protected])
  /// в нём запрещены. Ошибки — в [errors] с местом:
  /// «entries.task.created[1]: …».
  static Map<String, List<ReplyTemplate>>? parseEntries(
    Map<String, Object?> raw,
    List<String> errors, {
    ReplySchema? schema,
    String where = 'entries',
    bool pack = false,
  }) {
    final before = errors.length;
    final result = <String, List<ReplyTemplate>>{};
    for (final MapEntry(:key, :value) in raw.entries) {
      final place = '$where.$key';
      if (!idPattern.hasMatch(key)) {
        errors.add(
          '$place: id записи — слова латиницей через точку, '
          'например «task.created».',
        );
        continue;
      }
      if (schema != null && !schema.contains(key)) {
        errors.add('$place: неизвестная запись каталога.');
        continue;
      }
      if (pack && schema != null && schema[key]!.protected) {
        errors.add(
          '$place: это предупреждение или вопрос-подтверждение — пак '
          'ответов его не переопределяет.',
        );
        continue;
      }
      final variants = variantsOf(value, place, errors);
      if (variants == null) continue;
      final templates = <ReplyTemplate>[];
      for (var i = 0; i < variants.length; i++) {
        final at = variants.length == 1 ? place : '$place[$i]';
        try {
          templates.add(ReplyTemplate.parse(variants[i]));
        } on ReplyFormatException catch (error) {
          errors.add('$at: ${error.message}.');
        }
      }
      if (templates.length != variants.length) continue;
      final check = schema ??
          ReplySchema(<String, ReplySpec>{
            key: ReplySchema.specFor(key, templates.first),
          });
      for (var i = 0; i < templates.length; i++) {
        final at = templates.length == 1 ? place : '$place[$i]';
        for (final problem in check.check(key, templates[i])) {
          errors.add('$at: $problem.');
        }
        if (schema == null &&
            !_sameSet(
              templates[i].placeholders,
              templates.first.placeholders,
            )) {
          errors.add('$at: подстановки не как в первом варианте.');
        }
      }
      result[key] = List<ReplyTemplate>.unmodifiable(templates);
    }
    if (errors.length != before) return null;
    return Map<String, List<ReplyTemplate>>.unmodifiable(result);
  }

  /// Строка или список из 1–[maxVariants] непустых строк.
  static List<String>? variantsOf(
    Object? value,
    String place,
    List<String> errors,
  ) {
    final List<Object?> list = switch (value) {
      final String text => <Object?>[text],
      final List<Object?> items => items,
      _ => const <Object?>[],
    };
    if (value is! String && value is! List<Object?>) {
      errors.add('$place: ожидается строка или список строк.');
      return null;
    }
    if (list.isEmpty || list.length > maxVariants) {
      errors.add('$place: от 1 до $maxVariants вариантов.');
      return null;
    }
    final result = <String>[];
    for (var i = 0; i < list.length; i++) {
      final at = list.length == 1 ? place : '$place[$i]';
      final item = list[i];
      if (item is! String || item.trim().isEmpty) {
        errors.add('$at: вариант должен быть непустой строкой.');
      } else if (item.length > maxTextLength) {
        errors.add('$at: текст длиннее $maxTextLength символов.');
      } else if (_control.hasMatch(item)) {
        errors.add('$at: в тексте есть управляющие символы.');
      } else {
        result.add(item);
      }
    }
    return result.length == list.length ? result : null;
  }

  static bool _sameSet(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);
}
