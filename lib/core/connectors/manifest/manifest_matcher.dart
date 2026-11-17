import 'manifest_format.dart';
import 'manifest_text.dart';

/// Правило разбора: одна фраза `say` команды.
final class ManifestRule {
  ManifestRule._({
    required this.command,
    required this.phrase,
    required this.names,
    required this.pattern,
    required this.weight,
    required this.literalWords,
    required this.index,
  });

  final ManifestCommand command;

  /// Фраза в общем виде: «где лежит {q}».
  final String phrase;

  /// Поля по порядку.
  final List<String> names;
  final RegExp pattern;

  /// Длина слов вокруг полей в знаках (как в core.mjs): чем больше, тем
  /// конкретнее правило.
  final int weight;

  /// Сколько слов вокруг полей: от него уверенность «Tridot».
  final int literalWords;

  /// Порядок фразы внутри команды: при равном весе — раньше первее.
  final int index;
}

/// Что разобрано: команда, поля и как найдено.
final class ManifestHit {
  const ManifestHit({
    required this.command,
    required this.slots,
    required this.how,
    this.rule,
  });

  final ManifestCommand command;
  final Map<String, String> slots;

  /// `say` — по фразе, `fallback` — команда по умолчанию.
  final String how;

  /// Правило, по которому найдено; `null` у `fallback`.
  final ManifestRule? rule;

  bool get isFallback => how == 'fallback';
}

String _escape(String text) =>
    text.replaceAllMapped(RegExp(r'[.*+?^${}()|[\]\\]'), (m) => '\\${m[0]}');

/// Правила разбора описания: порт `askCompile`, `askMatch`, `askRule`,
/// `askSlot` из core.mjs. Снимок неизменяемый: новое описание — новый
/// [ManifestMatcher].
final class ManifestMatcher {
  ManifestMatcher(this.description)
      : rules = _compile(description),
        fallback = description.fallback == null
            ? null
            : description.command(description.fallback!),
        _filler = <String>{
          for (final word in description.filler) askText(word),
        };

  final ManifestDescription description;

  /// Правила: конкретные (длиннее без полей) — первыми.
  final List<ManifestRule> rules;

  /// Команда по умолчанию (`fallback`).
  final ManifestCommand? fallback;

  final Set<String> _filler;

  /// Регулярные выражения `shape` компилируются один раз.
  final Map<String, RegExp> _shapes = <String, RegExp>{};

  static List<ManifestRule> _compile(ManifestDescription description) {
    final rules = <ManifestRule>[];
    for (final command in description.commands) {
      for (var i = 0; i < command.say.length; i++) {
        final text = askText(command.say[i]);
        final names = <String>[];
        final literals = <String>[];
        final pattern = StringBuffer('^');
        var last = 0;
        for (final m in askSlotPattern.allMatches(text)) {
          literals.add(text.substring(last, m.start));
          pattern
            ..write(_escape(text.substring(last, m.start)))
            ..write('(.+?)');
          names.add(m[1]!);
          last = m.end;
        }
        literals.add(text.substring(last));
        pattern
          ..write(_escape(text.substring(last)))
          ..write(r'$');
        final joined = literals.join();
        rules.add(
          ManifestRule._(
            command: command,
            phrase: text,
            names: names,
            pattern: RegExp(pattern.toString()),
            weight: joined.length,
            literalWords: joined
                .split(' ')
                .where((String w) => w.trim().isNotEmpty)
                .length,
            index: i,
          ),
        );
      }
    }
    rules.sort((ManifestRule a, ManifestRule b) {
      final byWeight = b.weight.compareTo(a.weight);
      if (byWeight != 0) return byWeight;
      final byOrder = a.command.order.compareTo(b.command.order);
      return byOrder != 0 ? byOrder : a.index.compareTo(b.index);
    });
    return List<ManifestRule>.unmodifiable(rules);
  }

  RegExp _shape(String shape) =>
      _shapes[shape] ??= RegExp(shape, caseSensitive: false);

  /// Значение поля по его виду; пустая строка — не подошло.
  String slotValue(ManifestSlot? def, String value) {
    var s = value.trim();
    if (def == null) return s;
    final shape = def.shape;
    if (shape != null && !_shape(shape).hasMatch(askText(s))) return '';
    if (def.type == 'cell') {
      s = s
          .toUpperCase()
          .replaceAll(RegExp(r'\s*-\s*'), '-')
          .replaceAll(RegExp(r'\s+'), ' ');
    }
    if (def.type == 'int') return RegExp(r'^\d+$').hasMatch(s) ? s : '';
    return s;
  }

  /// Фраза без слов-связок (`filler`).
  String strip(String text) {
    if (_filler.isEmpty) return text;
    return text.split(' ').where((String w) => !_filler.contains(w)).join(' ');
  }

  /// Порт `askMatch`: сначала фраза как есть, потом без связок, потом
  /// команда по умолчанию. Без правил «Tridot» — для сверки с core.mjs.
  ManifestHit? askMatch(String text) {
    final raw = askText(text);
    if (raw.isEmpty) return null;
    final bare = strip(raw);
    for (final t in bare.isNotEmpty && bare != raw ? [raw, bare] : [raw]) {
      final hit = askRule(t);
      if (hit != null) return hit;
    }
    final f = fallback;
    if (f != null) {
      final name = f.slots.keys.first;
      final value = slotValue(f.slots[name], bare.isNotEmpty ? bare : raw);
      if (value.isNotEmpty) {
        return ManifestHit(
          command: f,
          slots: <String, String>{name: value},
          how: 'fallback',
        );
      }
    }
    return null;
  }

  /// Порт `askRule`: первое подходящее правило для текста в общем виде.
  ManifestHit? askRule(String text) {
    for (final hit in hits(text)) {
      return hit;
    }
    return null;
  }

  /// Все подходящие правила по порядку: «Tridot» отбирает из них своё.
  Iterable<ManifestHit> hits(String text) sync* {
    for (final rule in rules) {
      final m = rule.pattern.firstMatch(text);
      if (m == null) continue;
      final slots = <String, String>{};
      var ok = true;
      for (var i = 0; i < rule.names.length; i++) {
        final name = rule.names[i];
        final value = slotValue(rule.command.slots[name], m[i + 1]!);
        if (value.isEmpty) ok = false;
        slots[name] = value;
      }
      if (ok) {
        yield ManifestHit(
          command: rule.command,
          slots: slots,
          how: 'say',
          rule: rule,
        );
      }
    }
  }
}
