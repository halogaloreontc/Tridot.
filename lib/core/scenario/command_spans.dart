import '../connectors/connector.dart';

/// Что за часть фразы распознали навыки (подсветка команды, ADR-021).
enum CommandSpanKind {
  /// Обращение к помощнику по имени: «Нода, …».
  address,

  /// Слово команды: «добавь задачу», «перенеси», «покажи».
  verb,

  /// Название задачи или цель команды: «купить хлеб», «отчёт».
  title,

  /// Срок: «завтра в 10», «через 3 дня».
  due,

  /// Метка проекта: «#работа».
  tag,

  /// Числа и пример калькулятора, коды склада: «2 + 2 × 2», «64115».
  number,
}

/// Распознанная часть фразы: полуинтервал `[start, end)` в исходном тексте
/// (в UTF-16, как индексы `String`) и её вид.
final class CommandSpan {
  const CommandSpan(this.start, this.end, this.kind)
      : assert(start >= 0 && start < end);

  final int start;
  final int end;
  final CommandSpanKind kind;

  CommandSpan shift(int offset) =>
      CommandSpan(start + offset, end + offset, kind);

  @override
  bool operator ==(Object other) =>
      other is CommandSpan &&
      other.start == start &&
      other.end == end &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(start, end, kind);

  @override
  String toString() => '${kind.name}[$start,$end)';
}

/// Коннектор умеет показать, какие части фразы он распознал. Только для
/// подсветки: на маршрутизацию и ответ не влияет.
abstract interface class CommandSpanSource {
  /// Части [utterance], которые коннектор понял в совпадении [match].
  /// Индексы — в [Utterance.original].
  List<CommandSpan> spansOf(Utterance utterance, ConnectorMatch match);
}

/// Общие правила подсветки.
abstract final class CommandSpans {
  /// Длиннее не подсвечиваем: вставка большого текста не должна тормозить
  /// ввод.
  static const int maxLength = 400;

  /// Приводит набор частей к виду для отрисовки: внутри `[0, length)`, по
  /// порядку, без пересечений (раньше начавшаяся часть побеждает, у равных
  /// — более длинная).
  static List<CommandSpan> normalize(
    Iterable<CommandSpan> spans,
    int length,
  ) {
    final sorted = <CommandSpan>[
      for (final span in spans)
        if (span.start < length && span.end > span.start)
          CommandSpan(
            span.start,
            span.end > length ? length : span.end,
            span.kind,
          ),
    ]..sort((CommandSpan a, CommandSpan b) {
        final byStart = a.start.compareTo(b.start);
        return byStart != 0 ? byStart : b.end.compareTo(a.end);
      });
    final result = <CommandSpan>[];
    var end = 0;
    for (final span in sorted) {
      if (span.end <= end) continue;
      final start = span.start < end ? end : span.start;
      if (start >= span.end) continue;
      result.add(CommandSpan(start, span.end, span.kind));
      end = span.end;
    }
    return List<CommandSpan>.unmodifiable(result);
  }

  /// Подряд идущие слова одного вида — одной частью: «купить хлеб», а не
  /// «купить» и «хлеб» по отдельности. Сливаются части, между которыми в
  /// [text] нет ни букв, ни цифр (пробелы, запятые).
  static List<CommandSpan> merge(List<CommandSpan> spans, String text) {
    final result = <CommandSpan>[];
    for (final span in spans) {
      final last = result.isEmpty ? null : result.last;
      if (last != null &&
          last.kind == span.kind &&
          last.end <= span.start &&
          !_letterOrDigit.hasMatch(text.substring(last.end, span.start))) {
        result[result.length - 1] =
            CommandSpan(last.start, span.end, span.kind);
      } else {
        result.add(span);
      }
    }
    return result;
  }

  static final RegExp _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

  /// Пример калькулятора в [text]: числа со знаками действий между ними
  /// («2 + 2 × 2», «(3+4)^2», «15%»). Слова-маркеры («сколько будет») не
  /// подсвечиваются.
  static List<CommandSpan> arithmetic(String text) => <CommandSpan>[
        for (final match in _arithmetic.allMatches(text))
          CommandSpan(match.start, match.end, CommandSpanKind.number),
      ];

  static final RegExp _arithmetic = RegExp(
    r'[(√−-]*\d[\d\s.,+\-−*/×÷:^%()√=²³]*[\d)%²³]|[(√−-]*\d',
  );

  /// Метки и числа фразы: для коннекторов без своих правил подсветки.
  static List<CommandSpan> generic(Utterance utterance) => <CommandSpan>[
        for (final tag in utterance.hashtags)
          CommandSpan(tag.span.start, tag.span.end, CommandSpanKind.tag),
        for (final token in utterance.numbers)
          CommandSpan(token.span.start, token.span.end, CommandSpanKind.number),
      ];
}
