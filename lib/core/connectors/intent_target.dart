import 'connector.dart';

/// Разбор фразы с тем же контекстом чата, что у исходного сообщения.
typedef UtteranceAnalyzer = Utterance Function(String text);

/// Коннектор, который умеет выполнить свою команду по подсказке запасного
/// слоя (ADR-041): пользователь ответил «Да» на «Похоже, вы хотите …?» к
/// фразе, которую `match` не понял.
///
/// [matchAs] — разбор послабее обычного, но теми же разборщиками навыка:
/// слоты (срок, время, артикул, выражение) берутся из фразы правилами;
/// чего не хватает — навык спрашивает сам, как на неполную фразу. Действия
/// на запись сохраняют своё подтверждение: [matchAs] только находит
/// команду, `run` — тот же. Без ввода-вывода, как `match`.
abstract interface class IntentTarget {
  /// Совпадение команды [commandId] для [utterance] или `null`, если и
  /// послабее её не разобрать. [analyze] разбирает вспомогательные фразы
  /// («поставь будильник» + фраза пользователя) в том же чате.
  ConnectorMatch? matchAs(
    String commandId,
    Utterance utterance,
    UtteranceAnalyzer analyze,
  );

  /// Пример полной фразы команды [commandId] для ответа «скажите,
  /// например: …», когда [matchAs] не справился; `null` — примера нет.
  String? intentExample(String commandId);
}

/// Как выполнить команду по подсказке: общий способ для [IntentTarget].
///
/// 1. обычный `match` фразы — если он нашёл ту же команду ([accepts]);
/// 2. фраза пользователя с «носителем» — каноническим началом команды
///    («поставь будильник» + «чтобы в 7 зазвенело»): слоты достаёт
///    разборщик навыка;
///    Слова-синонимы ([rewrites]: «отложи» → «перенеси») заменяются — и
///    фраза пробуется сама и с носителями;
/// 3. [ask] — фраза команды без слотов: навык выполнит команду без слотов
///    или спросит недостающее, как на неполную фразу.
///
/// Совпадение принимается, только если команда — из [accepts] (по
/// умолчанию — сама команда): носитель не должен превратить фразу в
/// другую команду.
final class IntentRecipe {
  const IntentRecipe({
    this.carriers = const <String>[],
    this.ask,
    this.accepts = const <String>{},
    this.example,
    this.values,
    this.rewrites = const <String, String>{},
  });

  /// Канонические начала команды: «напомни», «добавь задачу».
  final List<String> carriers;

  /// Фраза команды без слотов: «покажи задачи», «поставь будильник».
  final String? ask;

  /// Какие команды навыка ещё годятся: «погода на завтра» вместо «погода
  /// сейчас».
  final Set<String> accepts;

  /// Пример полной фразы для ответа «скажите, например: …», если разобрать
  /// не вышло.
  final String? example;

  /// Что ставить после носителя; `null` — вся фраза пользователя. Склад
  /// сначала пробует артикулы фразы: «где лежит 64115», а не «где лежит
  /// мне бы найти 64115 побыстрее».
  final List<String> Function(Utterance utterance)? values;

  /// Слова-синонимы → слово, которое знает разборщик навыка: «отложи»,
  /// «перекинь» → «перенеси». Фраза с заменой пробуется сама и с
  /// носителями.
  final Map<String, String> rewrites;

  /// [text] с заменой слов [rewrites] или `null`, если менять нечего.
  String? rewrite(String text) {
    if (rewrites.isEmpty) return null;
    var changed = false;
    final out = text.replaceAllMapped(_word, (Match m) {
      final word = m.group(0)!;
      final to = rewrites[word.toLowerCase().replaceAll('ё', 'е')];
      if (to == null) return word;
      changed = true;
      return to;
    });
    return changed ? out : null;
  }

  static final RegExp _word = RegExp('[А-Яа-яЁё]+');

  /// Совпадение [connector] для команды [commandId] по этому рецепту.
  ConnectorMatch? match(
    Connector connector,
    String commandId,
    Utterance utterance,
    UtteranceAnalyzer analyze,
  ) {
    bool fits(ConnectorMatch? m) =>
        m != null &&
        m.confidence > 0 &&
        m.payload is! Reroute &&
        (m.commandId == commandId || accepts.contains(m.commandId));
    ConnectorMatch? tryMatch(Utterance u) {
      try {
        final found = connector.match(u);
        return fits(found) ? found : null;
      } on Object {
        return null;
      }
    }

    final direct = tryMatch(utterance);
    if (direct != null) return direct;
    final rewritten = rewrite(utterance.original);
    if (rewritten != null) {
      final plain = tryMatch(analyze(rewritten));
      if (plain != null) return plain;
    }
    final texts = <String>[
      ...?values?.call(utterance),
      if (values == null) utterance.original,
      if (rewritten != null) rewritten,
    ];
    for (final carrier in carriers) {
      for (final text in texts) {
        if (text.trim().isEmpty) continue;
        final carried = tryMatch(analyze('$carrier ${text.trim()}'));
        if (carried != null) return carried;
      }
    }
    final bare = ask;
    return bare == null ? null : tryMatch(analyze(bare));
  }
}

/// [IntentTarget.matchAs] по таблице рецептов коннектора.
ConnectorMatch? matchByRecipe(
  Connector connector,
  Map<String, IntentRecipe> recipes,
  String commandId,
  Utterance utterance,
  UtteranceAnalyzer analyze,
) =>
    recipes[commandId]?.match(connector, commandId, utterance, analyze);
