import 'dart:convert';
import 'dart:typed_data';

import '../passwords/csv_import.dart' show CsvException, CsvReader;

/// Таблица для вопросов «Продвинутой» (ADR-046): первая строка — названия
/// столбцов, остальные — данные строками.
final class TableData {
  TableData(this.columns, this.rows);

  /// CSV в UTF-8 или Windows-1251 (разборщик импорта паролей: кавычки, BOM,
  /// разделитель по первой строке). `null` — пусто или не таблица.
  static TableData? fromCsv(Uint8List bytes) {
    try {
      final table = CsvReader.parse(bytes);
      final text = CsvReader.isUtf8(bytes)
          ? (Uint8List f) => utf8.decode(f)
          : (Uint8List f) => utf8.decode(CsvReader.windows1251ToUtf8(f));
      final rows = <List<String>>[
        for (final row in table.rows)
          [for (final field in row) text(field).trim()],
      ];
      if (rows.length < 2 || rows.first.every((c) => c.isEmpty)) return null;
      final header = rows.first;
      return TableData(header, [
        for (final row in rows.skip(1))
          if (row.any((c) => c.isNotEmpty))
            [
              for (var i = 0; i < header.length; i++)
                i < row.length ? row[i] : '',
            ],
      ]);
    } on CsvException {
      return null;
    }
  }

  final List<String> columns;
  final List<List<String>> rows;

  int indexOf(String column) => columns.indexOf(column);
}
