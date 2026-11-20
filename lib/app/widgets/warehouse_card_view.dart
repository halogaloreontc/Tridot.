import 'package:flutter/material.dart';

import '../../core/connectors/manifest/connection_texts.dart';
import '../../core/models/warehouse_card.dart';
import '../assistant_theme.dart';
import 'whole_word_text.dart';

/// Карточка ответа склада под сообщением (ADR-031, оформление — ADR-027 и
/// компактная поправка: 16/14/13): итог, строки «артикул — название —
/// количество», вложенные ячейки, «Открыть склад».
///
/// Карточка любого приложения по описанию (ADR-043): название и обращения
/// — из [texts] подключения («Автосервис», «Открыть в автосервисе»); у
/// склада — прежние. Подключение удалено — карточка без кнопок.
final class WarehouseCardView extends StatefulWidget {
  const WarehouseCardView({
    super.key,
    required this.card,
    this.onOpen,
    this.onOpenLink,
    this.showSay = true,
    this.texts = ConnectionTexts.warehouse,
  });

  final WarehouseCard card;

  /// Тексты подключения карточки: у склада — прежние.
  final ConnectionTexts texts;

  /// Итог ответа ([WarehouseCard.say]) под заголовком: не нужен, когда
  /// тот же текст стоит в пузыре чата.
  final bool showSay;

  /// «Открыть склад»: страница склада из подключения; `null` — склад
  /// не подключён, кнопки нет.
  final VoidCallback? onOpen;

  /// Открыть в складе вещь из строки: позицию или приход
  /// ([WarehouseCard.openKinds]). Задан — строки с такой ссылкой нажимаются,
  /// а у ответа про одну вещь кнопка внизу — «Открыть в складе» и ведёт к
  /// ней. `null` — склад по ссылке не открыть (только «Открыть склад»).
  final void Function(String kind, String id)? onOpenLink;

  static const double maxWidth = 460;

  /// Сколько строк видно до «Показать все».
  static const int folded = 6;

  @override
  State<WarehouseCardView> createState() => _WarehouseCardViewState();
}

final class _WarehouseCardViewState extends State<WarehouseCardView> {
  bool _all = false;

  TextStyle _style(double size, {Color? color, FontWeight? weight}) =>
      TextStyle(
        fontFamily: AppFonts.text,
        fontSize: size,
        height: 1.3,
        color: color ?? context.colors.text,
        fontWeight: weight,
      );

  static const List<FontFeature> _tabular = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final colors = context.colors;
    final rows = _all || card.rows.length <= WarehouseCardView.folded + 1
        ? card.rows
        : card.rows.take(WarehouseCardView.folded).toList();
    final folded = card.rows.length - rows.length;
    final only = widget.onOpenLink == null ? null : card.onlyLink;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: WarehouseCardView.maxWidth),
        child: Semantics(
          container: true,
          child: Material(
            key: const ValueKey<String>('warehouse-card'),
            color: colors.raised,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.only(top: 1, right: 8),
                        child: Icon(
                          widget.texts.isWarehouse
                              ? Icons.inventory_2_outlined
                              : Icons.hub_outlined,
                          size: 18,
                          color: colors.icon,
                        ),
                      ),
                      Expanded(
                        child: WholeWordText(
                          card.title.isEmpty
                              ? widget.texts.cardTitle
                              : card.title,
                          key: const ValueKey<String>('warehouse-card-title'),
                          style: _style(
                            16,
                            color: colors.textStrong,
                            weight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (card.say.isNotEmpty && widget.showSay)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: WholeWordText(
                        card.say,
                        key: const ValueKey<String>('warehouse-card-say'),
                        style: _style(14, color: colors.muted),
                      ),
                    ),
                  const SizedBox(height: 8),
                  for (var i = 0; i < rows.length; i++) ...<Widget>[
                    if (i > 0) Divider(height: 1, color: colors.divider),
                    _row(rows[i], i),
                  ],
                  if (folded > 0)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(
                        key: const ValueKey<String>('warehouse-card-all'),
                        onPressed: () => setState(() => _all = true),
                        child: Text('Показать все · ещё $folded'),
                      ),
                    ),
                  if (card.hidden > 0 || card.more)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: WholeWordText(
                        card.more
                            ? widget.texts.cardPartial
                            : 'И ещё ${card.hidden}.',
                        style: _style(13, color: colors.muted),
                      ),
                    ),
                  if (only != null)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        key: const ValueKey<String>('warehouse-card-open'),
                        onPressed: () => widget.onOpenLink!(only.kind, only.id),
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: Text(widget.texts.cardOpenIn),
                      ),
                    )
                  else if (widget.onOpen != null)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        key: const ValueKey<String>('warehouse-card-open'),
                        onPressed: widget.onOpen,
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: Text(widget.texts.cardOpen),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Строка со ссылкой — нажимается целиком и открывает вещь в складе
  /// (артикул — цветом ссылки); без ссылки — как была.
  Widget _linked(VoidCallback? onTap, int index, String head, Widget child) {
    if (onTap == null) return child;
    return Semantics(
      container: true,
      button: true,
      label: '${widget.texts.cardOpenIn}: $head',
      child: InkWell(
        key: ValueKey<String>('warehouse-card-link-$index'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: child,
      ),
    );
  }

  Widget _row(WarehouseRow row, int index) {
    final colors = context.colors;
    final head = row.title.isEmpty ? row.text : row.title;
    final sub = row.title.isEmpty ? '' : row.text;
    final open = widget.onOpenLink;
    final linked = open != null &&
        WarehouseCard.openKinds.contains(row.linkKind) &&
        row.linkId.isNotEmpty;
    return Padding(
      key: ValueKey<String>('warehouse-card-row-$index'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _linked(
            linked ? () => open(row.linkKind, row.linkId) : null,
            index,
            head,
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (head.isNotEmpty)
                        WholeWordText(
                          head,
                          style: _style(
                            14,
                            color: linked ? colors.accent : colors.textStrong,
                            weight: FontWeight.w600,
                          ),
                        ),
                      if (sub.isNotEmpty) WholeWordText(sub, style: _style(14)),
                      if (row.note.isNotEmpty)
                        WholeWordText(
                          row.note,
                          style: _style(13, color: colors.muted),
                        ),
                    ],
                  ),
                ),
                if (row.badge.isNotEmpty) ...<Widget>[
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 140),
                    child: Text(
                      row.badge,
                      textAlign: TextAlign.end,
                      style: _style(14, color: colors.textStrong)
                          .copyWith(fontFeatures: _tabular),
                    ),
                  ),
                ],
              ],
            ),
          ),
          for (final cell in row.rows)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 12, top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: 6),
                    child: Icon(
                      cell.linkKind == 'cell'
                          ? Icons.grid_view_outlined
                          : Icons.subdirectory_arrow_right,
                      size: 14,
                      color: colors.muted,
                    ),
                  ),
                  Expanded(
                    child: WholeWordText(
                      <String>[
                        for (final part in <String>[
                          cell.title,
                          cell.text,
                          cell.note,
                        ])
                          if (part.isNotEmpty) part,
                      ].join(' · '),
                      style: _style(13),
                    ),
                  ),
                  if (cell.badge.isNotEmpty) ...<Widget>[
                    const SizedBox(width: 8),
                    Text(
                      cell.badge,
                      style: _style(13, color: colors.muted)
                          .copyWith(fontFeatures: _tabular),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}
