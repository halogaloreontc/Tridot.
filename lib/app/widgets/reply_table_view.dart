import 'package:flutter/material.dart';

import '../../core/models/reply_table.dart';
import '../assistant_theme.dart';
import 'whole_word_text.dart';

/// Таблица в ответе помощника (общая возможность, ADR-027): заголовки
/// столбцов на всю ширину, строки одного родителя связаны цветной полосой
/// слева вместо пустых повторов, числовой столбец — по правому краю,
/// жирнее, чередование фона у длинных списков. Столбец `fullWidth` (длинная
/// заметка/адрес) — не делит строку с остальными: отдельная строка во всю
/// ширину под ними, без заголовка в общей полосе (слишком узкий столбец
/// ломает слова посередине при крупном тексте — ADR-021). Используют и
/// приложение, и веб-помощник — без platform-специфичных импортов.
final class ReplyTableView extends StatelessWidget {
  const ReplyTableView({super.key, required this.table, this.onOpenLink});

  final ReplyTable table;

  /// Строка со ссылкой (`ReplyTableRow.linkKind`/`linkId` не пусты)
  /// нажимается целиком; `null` — ни одна строка не нажимается.
  final void Function(String kind, String id)? onOpenLink;

  static const List<FontFeature> _tabular = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  /// Номера столбцов, что делят общую строку (не `fullWidth`), по порядку.
  List<int> get _inline => <int>[
        for (var c = 0; c < table.columns.length; c++)
          if (!table.columns[c].fullWidth) c,
      ];

  TextStyle _style(
    BuildContext context,
    double size, {
    Color? color,
    FontWeight? weight,
  }) =>
      TextStyle(
        fontFamily: AppFonts.text,
        fontSize: size,
        height: 1.3,
        color: color ?? context.colors.text,
        fontWeight: weight,
      );

  Widget _cell(
    BuildContext context,
    String text,
    ReplyTableColumn column, {
    required TextStyle style,
    required bool last,
  }) =>
      Expanded(
        flex: column.flex,
        child: Container(
          padding: const EdgeInsetsDirectional.only(end: 10),
          decoration: last
              ? null
              : BoxDecoration(
                  border: BorderDirectional(
                    end: BorderSide(color: context.colors.divider),
                  ),
                ),
          child: WholeWordText(
            text,
            textAlign: column.numeric ? TextAlign.end : TextAlign.start,
            style:
                column.numeric ? style.copyWith(fontFeatures: _tabular) : style,
          ),
        ),
      );

  List<Widget> _inlineCells(
    BuildContext context,
    List<String> cells,
    TextStyle Function(ReplyTableColumn column) styleOf,
  ) {
    final inline = _inline;
    return <Widget>[
      for (var i = 0; i < inline.length; i++)
        _cell(
          context,
          cells[inline[i]],
          table.columns[inline[i]],
          style: styleOf(table.columns[inline[i]]),
          last: i == inline.length - 1,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final header = Color.alphaBlend(
      colors.divider.withValues(alpha: .35),
      colors.raised,
    );
    return Column(
      key: const ValueKey<String>('reply-table'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        DecoratedBox(
          decoration: BoxDecoration(
            color: header,
            border: Border(bottom: BorderSide(color: colors.divider)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: _inlineCells(
                context,
                <String>[for (final c in table.columns) c.label],
                (c) => _style(
                  context,
                  11,
                  color: colors.muted,
                  weight: FontWeight.w600,
                ).copyWith(letterSpacing: .3),
              ),
            ),
          ),
        ),
        for (var i = 0; i < table.rows.length; i++) _row(context, i),
      ],
    );
  }

  Widget _row(BuildContext context, int index) {
    final colors = context.colors;
    final row = table.rows[index];
    final last = index == table.rows.length - 1;
    final tappable =
        onOpenLink != null && row.linkKind.isNotEmpty && row.linkId.isNotEmpty;

    final mainLine = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: _inlineCells(
        context,
        row.cells,
        (c) => _style(
          context,
          14,
          color: c.numeric ? colors.textStrong : null,
          weight: c.numeric ? FontWeight.w600 : null,
        ),
      ),
    );

    final fullWidthLines = <Widget>[
      for (var c = 0; c < table.columns.length; c++)
        if (table.columns[c].fullWidth && row.cells[c].isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: WholeWordText(
              row.cells[c],
              style: _style(context, 13, color: colors.muted),
            ),
          ),
    ];

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[mainLine, ...fullWidthLines],
      ),
    );

    final layers = <Widget>[
      if (row.zebra)
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              key: ValueKey<String>('reply-table-row-$index-zebra'),
              color: colors.divider.withValues(alpha: .25),
            ),
          ),
        ),
      content,
      if (row.group != ReplyTableGroup.none)
        PositionedDirectional(
          start: 0,
          top: 0,
          bottom: 0,
          child: IgnorePointer(
            child: Container(
              key: ValueKey<String>('reply-table-row-$index-bar'),
              width: 3,
              color: colors.accent.withValues(alpha: .45),
            ),
          ),
        ),
    ];

    final body = DecoratedBox(
      key: ValueKey<String>('reply-table-row-$index'),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: colors.divider)),
      ),
      child: Stack(children: layers),
    );

    if (!tappable) return body;
    return InkWell(
      onTap: () => onOpenLink!(row.linkKind, row.linkId),
      child: body,
    );
  }
}
