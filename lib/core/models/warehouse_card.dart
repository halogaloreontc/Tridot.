import 'reply_table.dart';

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

  /// Команды с однородным списком строк — им подходит табличный вид
  /// (`asTable`); у остальных (действия, ответы про одну вещь) — список.
  static const Set<String> tableCommands = <String>{
    'where',
    'count',
    'cell',
    'unposted',
  };

  /// Таблица для [rows] (уже свёрнутый список — тот же, что рисует
  /// `WarehouseCardView`), если команда входит в [tableCommands] и строки
  /// есть; иначе `null` — рисовать списком, как раньше. Не меняет и не
  /// сохраняет ничего в карточке — чистый пересчёт из её полей.
  ReplyTable? asTable(List<WarehouseRow> rows) {
    if (!tableCommands.contains(command) || rows.isEmpty) return null;
    const columns = <ReplyTableColumn>[
      ReplyTableColumn('Что'),
      ReplyTableColumn('Название'),
      ReplyTableColumn('Где'),
      ReplyTableColumn('Кол-во', numeric: true),
    ];
    final zebra = rows.length >= ReplyTable.zebraFrom;
    final out = <ReplyTableRow>[];
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      final strip = zebra && i.isOdd;
      final link = openKinds.contains(r.linkKind) ? r.linkKind : '';
      if (r.rows.isEmpty) {
        out.add(
          ReplyTableRow(
            cells: <String>[r.title, r.text, r.note, r.badge],
            zebra: strip,
            linkKind: link,
            linkId: link.isEmpty ? '' : r.linkId,
          ),
        );
        continue;
      }
      for (var j = 0; j < r.rows.length; j++) {
        final cell = r.rows[j];
        final where = <String>[cell.title, cell.text, cell.note]
            .where((s) => s.isNotEmpty)
            .join(' · ');
        out.add(
          ReplyTableRow(
            cells: <String>[
              j == 0 ? r.title : '',
              j == 0 ? r.text : '',
              where,
              cell.badge,
            ],
            group: j == 0 ? ReplyTableGroup.start : ReplyTableGroup.continues,
            zebra: strip,
            linkKind: j == 0 ? link : '',
            linkId: j == 0 && link.isNotEmpty ? r.linkId : '',
          ),
        );
      }
    }
    return ReplyTable(columns: columns, rows: out);
  }

  /// Что склад умеет открыть по ссылке из карточки: позицию (`sku`) и
  /// приход (`entry`). Ячейку — нет, она остаётся текстом.
  static const Set<String> openKinds = <String>{'sku', 'entry'};

  /// Ответ про одну вещь (одна позиция или один приход, склад показал
  /// всё) — ссылка на неё: «Открыть в складе» ведёт прямо к ней.
  ({String kind, String id})? get onlyLink {
    if (hidden > 0 || more) return null;
    final links = <({String kind, String id})>{
      for (final r in rows)
        if (openKinds.contains(r.linkKind) && r.linkId.isNotEmpty)
          (kind: r.linkKind, id: r.linkId),
    };
    return links.length == 1 && rows.length == 1 ? links.first : null;
  }

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
