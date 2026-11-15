/// Строка карточки склада: что, где, сколько.
final class WarehouseRow {
  const WarehouseRow({
    this.title = '',
    this.text = '',
    this.note = '',
    this.badge = '',
    this.linkKind = '',
    this.linkId = '',
    this.rows = const <WarehouseRow>[],
  });

  /// Артикул, ячейка или номер прихода.
  final String title;

  /// Название товара или вид прихода.
  final String text;

  /// Ячейка и класс, партия, покупатель.
  final String note;

  /// «12 шт.».
  final String badge;

  /// Что это за вещь на складе: `sku`, `cell`, `entry`.
  final String linkKind;
  final String linkId;

  /// Вложенные строки: ячейки артикула.
  final List<WarehouseRow> rows;

  Map<String, Object?> toJson() => <String, Object?>{
        if (title.isNotEmpty) 'title': title,
        if (text.isNotEmpty) 'text': text,
        if (note.isNotEmpty) 'note': note,
        if (badge.isNotEmpty) 'badge': badge,
        if (linkKind.isNotEmpty) 'link_kind': linkKind,
        if (linkId.isNotEmpty) 'link_id': linkId,
        if (rows.isNotEmpty)
          'rows': <Map<String, Object?>>[for (final r in rows) r.toJson()],
      };

  static WarehouseRow? fromJson(Object? json, {int depth = 0}) {
    if (json is! Map) return null;
    final rows = json['rows'];
    return WarehouseRow(
      title: WarehouseCard.clean(json['title']),
      text: WarehouseCard.clean(json['text']),
      note: WarehouseCard.clean(json['note']),
      badge: WarehouseCard.clean(json['badge']),
      linkKind: WarehouseCard.kind(json['link_kind']),
      linkId: WarehouseCard.clean(json['link_id']),
      rows: depth == 0 && rows is List
          ? <WarehouseRow>[
              for (final row in rows.take(WarehouseCard.maxNested))
                if (WarehouseRow.fromJson(row, depth: 1)
                    case final WarehouseRow r)
                  r,
            ]
          : const <WarehouseRow>[],
    );
  }
}

/// Карточка ответа склада под сообщением (ADR-031): где лежит — ячейка,
/// сколько, класс; остатки; приходы. Только данные из ответа сервера, без
/// адреса склада и без ключей: «Открыть склад» берёт адрес из
/// подключения ([connector]). Пишется в историю чата (ключ `warehouse`);
/// текст ответа остаётся для голоса и истории.
final class WarehouseCard {
  const WarehouseCard({
    required this.connector,
    required this.command,
    required this.title,
    required this.say,
    this.rows = const <WarehouseRow>[],
    this.hidden = 0,
    this.more = false,
  });

  /// Id коннектора: `warehouse`.
  final String connector;

  /// Id команды описания: `where`, `cell`, `today`.
  final String command;

  /// «Где лежит товар».
  final String title;

  /// Итог одной строкой: «64115: 2 позиции, всего 14 шт.».
  final String say;

  final List<WarehouseRow> rows;

  /// Сколько строк не поместилось («и ещё N»).
  final int hidden;

  /// Сервер показал не всё — уточнить запрос.
  final bool more;

  static const int maxRows = 30;
  static const int maxNested = 8;
  static const int maxText = 120;

  static final RegExp _controls = RegExp(
    '[\\u0000-\\u001f\\u007f\\u200e\\u200f\\u202a-\\u202e\\u2066-\\u2069]',
  );

  /// Строка для карточки: одна строка, без управляющих знаков, не длиннее
  /// [maxText].
  static String clean(Object? value) {
    if (value is! String) return '';
    final text =
        value.replaceAll(_controls, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length > maxText ? '${text.substring(0, maxText - 1)}…' : text;
  }

  /// Вид ссылки: только знакомые.
  static String kind(Object? value) =>
      value is String && const <String>{'sku', 'cell', 'entry'}.contains(value)
          ? value
          : '';

  Map<String, Object?> toJson() => <String, Object?>{
        'connector': connector,
        'command': command,
        'title': title,
        'say': say,
        if (rows.isNotEmpty)
          'rows': <Map<String, Object?>>[for (final r in rows) r.toJson()],
        if (hidden > 0) 'hidden': hidden,
        if (more) 'more': true,
      };

  /// Битая карточка — `null`: сообщение читается без неё.
  static WarehouseCard? fromJson(Object? json) {
    if (json is! Map) return null;
    final connector = json['connector'];
    final command = json['command'];
    if (connector is! String ||
        !RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(connector) ||
        command is! String ||
        !RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(command)) {
      return null;
    }
    final rows = json['rows'];
    final hidden = json['hidden'];
    return WarehouseCard(
      connector: connector,
      command: command,
      title: clean(json['title']),
      say: clean(json['say']),
      rows: rows is List
          ? <WarehouseRow>[
              for (final row in rows.take(maxRows))
                if (WarehouseRow.fromJson(row) case final WarehouseRow r) r,
            ]
          : const <WarehouseRow>[],
      hidden: hidden is int && hidden > 0 ? hidden : 0,
      more: json['more'] == true,
    );
  }
}
