import 'builtin_replies.g.dart';
import 'reply_catalog.dart';

export 'reply_catalog.dart';

/// Все каталоги ответов: нейтральный (основа и схема), встроенные стили,
/// стили из паков ответов и записи коннекторов (docs/REPLIES.md).
///
/// Выбор варианта детерминированный: по id записи и номеру реплики в
/// разговоре ([render], `turn`). Так тесты воспроизводимы, а соседние
/// реплики одной записи звучат по-разному.
final class ReplyLibrary {
  ReplyLibrary._({
    required this.neutral,
    required Map<String, ReplyCatalog> styles,
    required this.schema,
  }) : _styles = Map<String, ReplyCatalog>.unmodifiable(styles);

  /// Библиотека из текстов каталогов. Первый — нейтральный: он задаёт
  /// записи и подстановки, остальные проверяются против него. Ошибка
  /// любого каталога — [FormatException] со списком ошибок: встроенные
  /// каталоги обязаны быть исправны.
  factory ReplyLibrary.fromSources(List<String> sources) {
    if (sources.isEmpty) {
      throw const FormatException('Нет нейтрального каталога ответов');
    }
    final neutralResult = ReplyFormat.parse(sources.first);
    final neutral = neutralResult.catalog;
    if (neutral == null || neutral.style != ReplyStyles.neutral) {
      throw FormatException(
        'Нейтральный каталог ответов не принят: '
        '${neutralResult.errors.isEmpty ? 'стиль не «neutral»' : neutralResult.errors.join(' ')}',
      );
    }
    final schema = schemaOf(neutral);
    final styles = <String, ReplyCatalog>{neutral.style: neutral};
    for (final source in sources.skip(1)) {
      final result = ReplyFormat.parse(source, schema: schema);
      final catalog = result.catalog;
      if (catalog == null) {
        throw FormatException(
          'Каталог ответов не принят: ${result.errors.join(' ')}',
        );
      }
      if (styles.containsKey(catalog.style)) {
        throw FormatException('Стиль «${catalog.style}» повторяется');
      }
      styles[catalog.style] = catalog;
    }
    return ReplyLibrary._(neutral: neutral, styles: styles, schema: schema);
  }

  /// Встроенные каталоги: `assets/replies/*.json` (их копия для ядра без
  /// Flutter — `builtin_replies.g.dart`, тест сверяет её с файлами).
  static final ReplyLibrary builtIn = ReplyLibrary.fromSources(<String>[
    for (final style in ReplyStyles.builtIn) builtInReplyCatalogs[style]!,
  ]);

  static ReplySchema schemaOf(ReplyCatalog neutral) => ReplySchema(
        <String, ReplySpec>{
          for (final MapEntry(:key, :value) in neutral.entries.entries)
            key: ReplySchema.specFor(
              key,
              value.first,
              protected: neutral.protectedIds.contains(key),
            ),
        },
      );

  /// Основа: каждая запись есть здесь, остальные стили берут недостающее
  /// отсюда.
  final ReplyCatalog neutral;

  /// Записи и их подстановки — для проверки стилей и паков ответов.
  final ReplySchema schema;

  final Map<String, ReplyCatalog> _styles;

  /// Стили в порядке показа: встроенные, затем паки.
  List<ReplyCatalog> get styles => _styles.values.toList(growable: false);

  ReplyCatalog? style(String id) => _styles[id];

  bool hasStyle(String id) => _styles.containsKey(id);

  /// Библиотека с записями коннекторов: нейтральный текст на id
  /// ([ConnectorInfo.replies]). Остальные стили берут их из нейтрального,
  /// паки ответов могут дать свои варианты — кроме [protectedIds]
  /// (предупреждения и вопросы-подтверждения коннектора,
  /// [ConnectorInfo.protectedReplies]). Ошибка разметки или id, занятый
  /// встроенной записью, — [FormatException].
  ReplyLibrary withEntries(
    Map<String, String> neutralEntries, {
    Set<String> protectedIds = const <String>{},
  }) {
    if (neutralEntries.isEmpty) return this;
    final errors = <String>[];
    for (final id in neutralEntries.keys) {
      if (neutral.entries.containsKey(id)) {
        errors.add('Запись «$id» уже есть в каталоге.');
      }
    }
    final parsed = ReplyFormat.parseEntries(
      <String, Object?>{...neutralEntries},
      errors,
      where: 'replies',
    );
    for (final id in protectedIds) {
      if (!neutralEntries.containsKey(id)) {
        errors.add('protectedReplies: «$id» — нет такой записи.');
      }
    }
    if (parsed == null || errors.isNotEmpty) {
      throw FormatException(errors.join(' '));
    }
    final merged = ReplyCatalog(
      style: neutral.style,
      title: neutral.title,
      description: neutral.description,
      entries: <String, List<ReplyTemplate>>{...neutral.entries, ...parsed},
      protectedIds: <String>{...neutral.protectedIds, ...protectedIds},
    );
    final styles = <String, ReplyCatalog>{..._styles, merged.style: merged};
    return ReplyLibrary._(
      neutral: merged,
      styles: styles,
      schema: schemaOf(merged),
    );
  }

  /// Библиотека, где записи [texts] заменены во всех стилях одним
  /// нейтральным текстом: другая оболочка с теми же навыками — веб-помощник
  /// склада (ADR-032) не говорит «Мой Связной → Помощники → …», его вход —
  /// страница склада. Подстановки — те же, что у записи (проверка схемой);
  /// неизвестный id или ошибка разметки — [FormatException].
  ReplyLibrary withOverrides(Map<String, String> texts) {
    if (texts.isEmpty) return this;
    final errors = <String>[];
    final parsed = ReplyFormat.parseEntries(
      <String, Object?>{...texts},
      errors,
      schema: schema,
      where: 'overrides',
    );
    if (parsed == null || errors.isNotEmpty) {
      throw FormatException(errors.join(' '));
    }
    ReplyCatalog patch(ReplyCatalog catalog) => ReplyCatalog(
          style: catalog.style,
          title: catalog.title,
          description: catalog.description,
          builtIn: catalog.builtIn,
          protectedIds: catalog.protectedIds,
          entries: <String, List<ReplyTemplate>>{
            ...catalog.entries,
            ...parsed,
          },
        );
    final merged = patch(neutral);
    return ReplyLibrary._(
      neutral: merged,
      styles: <String, ReplyCatalog>{
        for (final MapEntry(:key, :value) in _styles.entries)
          key: key == merged.style ? merged : patch(value),
      },
      schema: schema,
    );
  }

  /// Библиотека с дополнительными стилями (включённые паки ответов).
  /// Стиль, чей id уже занят, пропускается.
  ReplyLibrary withStyles(Iterable<ReplyCatalog> extra) {
    final styles = <String, ReplyCatalog>{..._styles};
    var changed = false;
    for (final catalog in extra) {
      if (styles.containsKey(catalog.style)) continue;
      styles[catalog.style] = catalog;
      changed = true;
    }
    if (!changed) return this;
    return ReplyLibrary._(neutral: neutral, styles: styles, schema: schema);
  }

  /// Варианты записи [id] в стиле [style]: свои или нейтральные.
  /// Предупреждения и вопросы-подтверждения ([ReplySpec.protected]) пак
  /// ответов не переопределяет: у стиля из пака они всегда нейтральные.
  List<ReplyTemplate> variants(String id, String style) {
    final catalog = _styles[style];
    final own = catalog?.entries[id];
    final allowed =
        catalog == null || catalog.builtIn || !(schema[id]?.protected ?? false);
    if (own != null && own.isNotEmpty && allowed) return own;
    final base = neutral.entries[id];
    if (base == null) {
      throw ArgumentError.value(
        id,
        'id',
        'Нет такой записи в каталоге ответов',
      );
    }
    return base;
  }

  /// Текст реплики. [turn] — номер реплики в разговоре: от него и от id
  /// зависит, какой из вариантов прозвучит.
  String render(Reply reply, ReplyVoice voice, {int turn = 0}) {
    final options = variants(reply.id, voice.style);
    final index = (stableHash(reply.id) + turn) % options.length;
    return options[index].render(
      reply.values,
      gender: voice.gender,
      address: voice.address,
      emoji: voice.emoji,
    );
  }

  /// FNV-1a по кодовым единицам: одинаков на всех платформах и запусках,
  /// в отличие от `String.hashCode`.
  static int stableHash(String text) {
    var hash = 0x811c9dc5;
    for (final unit in text.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }
}
