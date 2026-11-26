import 'dart:convert';

import '../passwords/secret_guard.dart';
import 'gen_model.dart';
import 'table_data.dart';
import 'table_query.dart';

/// Вопрос к таблице через «Продвинутую» (ADR-046): модель переводит вопрос
/// в [TableQuery] под грамматикой, считает [TableQuery.run]. Модель видит
/// названия столбцов и первые строки, прошедшие [SecretGuard].
abstract final class TableAsk {
  static const int sampleRows = 3;

  static Future<TableAnswer?> ask(
    GenModel model,
    TableData table,
    String question,
  ) async {
    final raw = await model.complete(
      system: system(table),
      user: question,
      grammar: grammar(table.columns),
      maxTokens: 160,
    );
    return TableQuery.parse(raw, table)?.run(table);
  }

  static String system(TableData table) {
    String line(List<String> cells) => SecretGuard.redact(cells.join(',')).text;
    final sample = [
      for (final row in table.rows.take(sampleRows)) line(row),
    ].join('\n');
    return 'Ты переводишь вопрос о таблице в запрос. Считать будет программа, '
        'ты — только запрос.\n'
        'Столбцы: ${line(table.columns)}\nПервые строки:\n$sample\n'
        'Верни JSON: op — sum (сумма), count (сколько строк), avg (среднее), '
        'min, max или list (значения столбца); column — столбец для op (для '
        'count — null); filters — условия на строки: column, cmp (eq, ne, gt, '
        'lt, ge, le, contains), value. Имена и названия ищи через contains.';
  }

  /// GBNF ответа: только известные столбцы, операции и сравнения.
  static String grammar(List<String> columns) {
    String lit(String s) =>
        '"${jsonEncode(s).replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
    String alt(Iterable<String> names) => names.map(lit).join(' | ');
    return [
      r'root ::= "{" ws "\"op\":" ws op "," ws "\"column\":" ws column "," ws '
          r'"\"filters\":" ws "[" ws (filter (ws "," ws filter)*)? ws "]" ws "}"',
      'op ::= ${alt(TableOp.values.map((v) => v.name))}',
      'cmp ::= ${alt(TableCmp.values.map((v) => v.name))}',
      'name ::= ${alt(columns)}',
      'column ::= name | "null"',
      r'filter ::= "{" ws "\"column\":" ws name "," ws "\"cmp\":" ws cmp "," '
          r'ws "\"value\":" ws value ws "}"',
      'value ::= string | number',
      r'string ::= "\"" ([^"\\\x00-\x1f] | "\\" ["\\/bfnrt])* "\""',
      'number ::= "-"? [0-9]+ ("." [0-9]+)?',
      'ws ::= [ ]?',
    ].join('\n');
  }
}
