import '../connectors/utterance.dart';
import 'command_lexicon.g.dart';
import 'route_policy.dart';

/// Опечатки в словах команд любого навыка: «постпвь будильник на 7»,
/// «склоько венских стульев», «напомни заввтра в 10», «что пишло сегодня».
///
/// Разбор задач исправляет опечатки сам, но только в глаголе в начале и в
/// «задачу» после него; другие навыки видят слово с опечаткой и молчат.
/// Здесь — спасательный проход, как [LayoutFix]: только если фразу как есть
/// не понял никто явно, и только слова не из словаря команд
/// ([commandLexicon], собран из корпуса фраз), от пяти букв: короткие
/// слова слишком легко спутать («стол» — «стул»). Слово заменяется, если
/// рядом ровно одно слово словаря на расстоянии одной правки — не в первой
/// и не в последней букве ([Utterance.isTypoOf]); при двух соседях —
/// только если один встречается в корпусе втрое чаще. «Наполни», «записи»
/// и другие настоящие слова рядом с командами ([Utterance.isRealWord]) не
/// трогаются. Исправить опечатку по смыслу нельзя без словаря языка,
/// поэтому запись после такого исправления — только после «Да».
abstract final class TypoFix {
  /// Фраза с исправленными словами или `null`, если исправлять нечего.
  static String? repair(String text) => _repair(text, commandLexicon);

  /// Только слова срока: «напоми заввтра в 10 позвонить маме» — команду
  /// понял разбор задач, а «заввтра» стало бы частью названия и срок бы
  /// пропал. Исправленная так фраза берётся, если её понимает тот же навык
  /// той же командой ([sameCommand]).
  static String? repairDue(String text) => _repair(text, _dueLexicon);

  static String? _repair(String text, Map<String, int> lexicon) {
    if (text.length > 400) return null;
    var changed = false;
    final fixed = text.replaceAllMapped(_word, (Match m) {
      final word = m.group(0)!;
      final lower = word.toLowerCase().replaceAll('ё', 'е');
      final replacement = _fix(lower, lexicon);
      if (replacement == null) return word;
      changed = true;
      return _sameCase(word, replacement);
    });
    return changed ? fixed : null;
  }

  /// Взять ли исправленный разбор — по тому же правилу, что раскладка:
  /// фразу как есть не понял никто явно, исправленную — навык.
  static bool prefer(RouteDecision original, RouteDecision repaired) {
    final was = original.winner;
    if (original.isAmbiguous || (was != null && !was.fallback)) return false;
    final winner = repaired.winner;
    if (winner == null || repaired.isAmbiguous) return false;
    if (!winner.fallback) return true;
    return was == null && !winner.commandId.endsWith('.question');
  }

  /// Исправленный срок у той же команды того же навыка.
  static bool sameCommand(RouteDecision original, RouteDecision repaired) {
    final was = original.winner;
    final winner = repaired.winner;
    return was != null &&
        winner != null &&
        !repaired.isAmbiguous &&
        was.connectorId == winner.connectorId &&
        was.commandId == winner.commandId;
  }

  static final RegExp _word = RegExp('[а-яёА-ЯЁ]+');

  static String? _fix(String word, Map<String, int> lexicon) {
    if (word.length < 5 || commandLexicon.containsKey(word)) return null;
    if (Utterance.isRealWord(word)) return null;
    String? best;
    var bestCount = 0;
    var second = 0;
    for (final MapEntry(key: candidate, value: count) in lexicon.entries) {
      if (candidate[0] != word[0] ||
          (candidate.length - word.length).abs() > 1 ||
          !Utterance.isTypoOf(word, candidate)) {
        continue;
      }
      if (count > bestCount) {
        second = bestCount;
        bestCount = count;
        best = candidate;
      } else if (count > second) {
        second = count;
      }
    }
    if (best == null) return null;
    if (second > 0 && bestCount < 3 * second) return null;
    return best;
  }

  /// Слова срока из словаря команд: дни, части суток, единицы времени,
  /// месяцы.
  static final Map<String, int> _dueLexicon = <String, int>{
    for (final MapEntry(:key, :value) in commandLexicon.entries)
      if (_dueWords.hasMatch(key)) key: value,
  };

  static final RegExp _dueWords = RegExp(
    r'^(?:сегодня|завтра|послезавтра|вчера|утром|утра|вечером|вечера|'
    r'днем|ночью|минут[аы]?|минуту|секунд[аы]?|часов|часа|недел[июе]|'
    r'месяц[аеу]?|понедельник|вторник|среду|четверг|пятницу|субботу|'
    r'воскресенье|выходных|январ[яь]|феврал[яь]|марта|апреля|мая|июня|'
    r'июля|августа|сентября|октября|ноября|декабря|через)$',
  );

  /// [replacement] в регистре [word]: «Пакажи» → «Покажи».
  static String _sameCase(String word, String replacement) {
    final upper = word[0] != word[0].toLowerCase();
    if (!upper) return replacement;
    return replacement[0].toUpperCase() + replacement.substring(1);
  }
}
