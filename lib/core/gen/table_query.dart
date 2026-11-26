import 'dart:convert';

import 'table_data.dart';

/// Что посчитать: сумма, число строк, среднее, минимум, максимум или
/// значения столбца.
enum TableOp { sum, count, avg, min, max, list }

/// Сравнение в условии на строки.
enum TableCmp { eq, ne, gt, lt, ge, le, contains }

final class TableFilter {
  const TableFilter(this.column, this.cmp, this.value);

  final String column;
  final TableCmp cmp;
  final Object value;
}

/// Запрос к таблице, который пишет модель (ADR-046): считает Dart, а не
/// модель — выдуманных чисел нет.
final class TableQuery {
  const TableQuery(this.op, this.column, this.filters);

  final TableOp op;
  final String? column;
  final List<TableFilter> filters;

  /// Строгий разбор ответа модели: неизвестный столбец, операция или
  /// сравнение — `null`.
  static TableQuery? parse(String text, TableData table) {
    Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (json is! Map<String, Object?>) return null;
    final op = _enum(TableOp.values, json['op']);
    if (op == null) return null;
    final column = json['column'];
    if (column != null && (column is! String || table.indexOf(column) < 0)) {
      return null;
    }
    if (op != TableOp.count && column == null) return null;
    final raw = json['filters'] ?? const <Object?>[];
    if (raw is! List<Object?>) return null;
    final filters = <TableFilter>[];
    for (final f in raw) {
      if (f is! Map<String, Object?>) return null;
      final col = f['column'];
      final cmp = _enum(TableCmp.values, f['cmp']);
      final value = f['value'];
      if (col is! String || table.indexOf(col) < 0 || cmp == null) return null;
      if (value is! String && value is! num) return null;
      filters.add(TableFilter(col, cmp, value as Object));
    }
    return TableQuery(op, column as String?, filters);
  }

  static T? _enum<T extends Enum>(List<T> values, Object? name) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return null;
  }

  /// Ответ по таблице: [TableAnswer.value] — число (или `null`, если
  /// считать нечего), [TableAnswer.values] — для [TableOp.list].
  TableAnswer run(TableData table) {
    final hit = [
      for (final row in table.rows)
        if (filters.every((f) => _match(table, row, f))) row,
    ];
    if (op == TableOp.count) {
      return TableAnswer(this, hit.length, value: hit.length);
    }
    final i = table.indexOf(column!);
    if (op == TableOp.list) {
      return TableAnswer(this, hit.length, values: [for (final r in hit) r[i]]);
    }
    final nums = [
      for (final r in hit)
        if (number(r[i]) case final v?) v,
    ];
    if (nums.isEmpty) return TableAnswer(this, hit.length);
    final value = switch (op) {
      TableOp.sum => nums.fold<num>(0, (a, b) => a + b),
      TableOp.avg => nums.fold<num>(0, (a, b) => a + b) / nums.length,
      TableOp.min => nums.reduce((a, b) => a < b ? a : b),
      TableOp.max => nums.reduce((a, b) => a > b ? a : b),
      TableOp.count || TableOp.list => throw StateError('уже разобрано'),
    };
    return TableAnswer(this, hit.length, value: value);
  }

  static bool _match(TableData table, List<String> row, TableFilter f) {
    final have = row[table.indexOf(f.column)];
    final want = f.value;
    if (f.cmp == TableCmp.contains) {
      return have.toLowerCase().contains('$want'.toLowerCase());
    }
    final a = number(have);
    final b = want is num ? want : number('$want');
    if (f.cmp == TableCmp.eq || f.cmp == TableCmp.ne) {
      final same = a != null && b != null
          ? a == b
          : have.trim().toLowerCase() == '$want'.trim().toLowerCase();
      return f.cmp == TableCmp.eq ? same : !same;
    }
    if (a == null || b == null) return false;
    return switch (f.cmp) {
      TableCmp.gt => a > b,
      TableCmp.lt => a < b,
      TableCmp.ge => a >= b,
      TableCmp.le => a <= b,
      _ => false,
    };
  }

  /// Число из ячейки: «1 250,5» → 1250.5; не число — `null`.
  static num? number(String text) =>
      num.tryParse(text.replaceAll(RegExp(r'[\s ]'), '').replaceAll(',', '.'));
}

final class TableAnswer {
  const TableAnswer(this.query, this.matched, {this.value, this.values});

  final TableQuery query;

  /// Сколько строк прошло условия.
  final int matched;
  final num? value;
  final List<String>? values;
}
