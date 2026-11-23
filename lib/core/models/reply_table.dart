/// Таблица в ответе помощника (общая возможность, не только склад):
/// заголовки столбцов и строки ячеек. Первый источник — `WarehouseCard`
/// (`asTable`), но модель сама не знает про склад.
enum ReplyTableGroup {
  /// Строка сама по себе, не часть группы.
  none,

  /// Первая строка группы (родитель с вложенными строками).
  start,

  /// Продолжение группы: та же вещь, что у строки `start` перед ней.
  continues,
}

/// Заголовок столбца: подпись и выравнивание (числовой — по правому краю).
final class ReplyTableColumn {
  const ReplyTableColumn(this.label, {this.numeric = false});

  final String label;
  final bool numeric;
}

/// Строка таблицы: по ячейке на столбец.
final class ReplyTableRow {
  const ReplyTableRow({
    required this.cells,
    this.group = ReplyTableGroup.none,
    this.zebra = false,
    this.linkKind = '',
    this.linkId = '',
  });

  final List<String> cells;
  final ReplyTableGroup group;

  /// Чередование фона строки (у длинных списков без группировки).
  final bool zebra;

  /// Строка ведёт к вещи (как `WarehouseRow.linkKind`/`linkId`) — пустые,
  /// если не нажимается.
  final String linkKind;
  final String linkId;
}

final class ReplyTable {
  const ReplyTable({required this.columns, required this.rows});

  final List<ReplyTableColumn> columns;
  final List<ReplyTableRow> rows;

  /// От скольких верхнеуровневых строк включается чередование фона.
  static const int zebraFrom = 3;
}
