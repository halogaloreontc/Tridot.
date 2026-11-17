/// Сгруппированные списки «как в Заметках» (ADR-027, шаг S3): группа
/// строк на заливке со скруглением 12 вместо тонких рамок, строки не ниже
/// 52, разделители «вставкой», крупный заголовок экрана и поле поиска.
///
/// Группа ставит строкам свою тему `ListTile`: прежние `ListTile`,
/// `SwitchListTile` и `CheckboxListTile` внутри [InsetGroup] выглядят как
/// [GroupedRow] и сохраняют свои ключи и типы (на них опираются тесты).
library;

import 'package:flutter/material.dart';

import '../assistant_theme.dart';
import '../layout.dart';
import 'whole_word_text.dart';

/// Порог масштаба шрифта, после которого значение строки уходит под
/// заголовок: рядом оно рвало бы слова на 320 px.
const double groupedStackScale = 1.3;

/// Уже на самом пороге значение уходит вниз, если экран узкий: рядом с
/// заголовком на 320 px оно сжимало заголовок и переносилось по словам.
bool _stacked(BuildContext context) {
  final scale = MediaQuery.textScalerOf(context).scale(1);
  return scale > groupedStackScale ||
      (scale >= groupedStackScale && MediaQuery.sizeOf(context).width < 360);
}

/// Группа строк: заголовок 14 w600 приглушённым, тело — заливкой листа со
/// скруглением 12, разделители «вставкой», футер 13 приглушённым.
final class InsetGroup extends StatelessWidget {
  const InsetGroup({
    super.key,
    this.header,
    this.headerKey,
    this.headerDanger = false,
    this.footer,
    this.footerKey,
    required this.children,
    this.color,
    this.margin,
    this.dividers = true,
  });

  final String? header;
  final Key? headerKey;

  /// Заголовок цветом ошибки («Просрочено»).
  final bool headerDanger;

  /// Пояснение под группой: строка или виджет.
  final Object? footer;
  final Key? footerKey;

  final List<Widget> children;

  /// Заливка тела; по умолчанию — лист (`workspace`) на фоне экрана.
  final Color? color;

  /// Внешние поля; по умолчанию — 16 по бокам ([InsetGroupScope]) и 24
  /// снизу.
  final EdgeInsetsGeometry? margin;

  /// Разделители между строками.
  final bool dividers;

  static double _indentOf(Widget child) => switch (child) {
        GroupedRow(:final icon, :final tile, :final leading)
            when icon != null || tile != null || leading != null =>
          AppSpace.separatorInset,
        GroupedSwitchRow(:final secondary) when secondary != null =>
          AppSpace.separatorInset,
        ListTile(:final leading) when leading != null =>
          AppSpace.separatorInset,
        _ => AppSpace.rowH,
      };

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final visible = <Widget>[
      for (final child in children)
        if (child is! SizedBox || child.width != 0 || child.height != 0) child,
    ];
    final rows = <Widget>[];
    for (final (i, child) in visible.indexed) {
      if (i > 0 && dividers) {
        // Отступ — по строке над разделителем: линия начинается там же,
        // где её текст.
        rows.add(_InsetSeparator(indent: _indentOf(visible[i - 1])));
      }
      rows.add(child);
    }
    final footer = this.footer;
    final side = InsetGroupScope.sideOf(context);
    return Padding(
      padding:
          margin ?? EdgeInsets.fromLTRB(side, 0, side, AppSpace.sectionGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (header case final String header)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.rowH,
                0,
                AppSpace.rowH,
                8,
              ),
              child: WholeWordText(
                header,
                key: headerKey,
                style: text.labelMedium!.copyWith(
                  color: headerDanger ? colors.danger : colors.muted,
                ),
              ),
            ),
          if (rows.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.group),
              child: Material(
                color: color ?? colors.workspace,
                child: ListTileTheme.merge(
                  tileColor: Colors.transparent,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: AppSpace.rowH),
                  minTileHeight: AppSize.rowMin,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: rows,
                  ),
                ),
              ),
            ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.rowH,
                8,
                AppSpace.rowH,
                0,
              ),
              child: footer is Widget
                  ? footer
                  : WholeWordText(
                      '$footer',
                      key: footerKey,
                      style: text.bodySmall!.copyWith(color: colors.muted),
                    ),
            ),
        ],
      ),
    );
  }
}

/// Боковые поля групп внутри: 0 там, где страница уже даёт свои 16
/// («Мой Связной → Помощники»), иначе — 16 от края экрана.
final class InsetGroupScope extends InheritedWidget {
  const InsetGroupScope({super.key, required this.side, required super.child});

  final double side;

  static double sideOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<InsetGroupScope>()?.side ??
      AppSpace.insetH;

  @override
  bool updateShouldNotify(InsetGroupScope oldWidget) => oldWidget.side != side;
}

/// Разделитель «вставкой» 0,5 логического пикселя.
final class _InsetSeparator extends StatelessWidget {
  const _InsetSeparator({required this.indent});

  final double indent;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(left: indent),
        child: ColoredBox(
          color: context.colors.divider,
          child: const SizedBox(height: 0.5, width: double.infinity),
        ),
      );
}

/// Плитка 28 со скруглением 7 и белым глифом 18: цвет — только из
/// проверенного набора палитры (`tileGray` … `tileAmber`, ≥ 3:1).
final class IconTile extends StatelessWidget {
  const IconTile({super.key, required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: AppSize.iconTile,
        height: AppSize.iconTile,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(AppRadius.tile),
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 18, color: Colors.white),
      );
}

/// Строка группы: значок (плитка или значок 22), заголовок 16, подпись 14,
/// значение 16 приглушённым справа (при крупном шрифте — под заголовком),
/// шеврон. `destructive` — текст цветом ошибки по центру, без значка.
final class GroupedRow extends StatelessWidget {
  const GroupedRow({
    super.key,
    this.icon,
    this.tile,
    this.leading,
    required this.title,
    this.titleKey,
    this.subtitle,
    this.value,
    this.valueKey,
    this.trailing,
    this.chevron = false,
    this.onTap,
    this.destructive = false,
    this.accent = false,
    this.titleStyle,
  });

  /// Значок: на плитке цвета [tile] или сам по себе, 22 цветом иконок.
  final IconData? icon;
  final Color? tile;

  /// Свой виджет слева (монограмма, точка помощника).
  final Widget? leading;

  final String title;
  final Key? titleKey;
  final String? subtitle;
  final String? value;
  final Key? valueKey;
  final Widget? trailing;
  final bool chevron;
  final VoidCallback? onTap;
  final bool destructive;

  /// Заголовок цветом акцента (действие, а не переход).
  final bool accent;
  final TextStyle? titleStyle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final enabled = onTap != null;
    if (destructive) {
      return InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSize.rowMin),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.rowH,
              vertical: AppSpace.rowV,
            ),
            child: Center(
              child: WholeWordText(
                title,
                key: titleKey,
                textAlign: TextAlign.center,
                style: text.bodyLarge!.copyWith(
                  color: enabled ? colors.danger : colors.faint,
                ),
              ),
            ),
          ),
        ),
      );
    }
    final stacked = _stacked(context);
    final titleColor = !enabled && trailing == null && !chevron
        ? colors.textStrong
        : accent
            ? colors.accent
            : colors.textStrong;
    final lead = leading ??
        switch ((icon, tile)) {
          (final IconData icon, final Color tile) =>
            IconTile(icon: icon, color: tile),
          (final IconData icon, null) =>
            Icon(icon, size: AppSize.icon, color: colors.icon),
          _ => null,
        };
    final valueText = value == null
        ? null
        : WholeWordText(
            value!,
            key: valueKey,
            textAlign: stacked ? TextAlign.start : TextAlign.end,
            style: text.bodyLarge!.copyWith(color: colors.muted),
          );
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppSize.rowMin),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.rowH,
            vertical: AppSpace.rowV,
          ),
          child: Row(
            children: <Widget>[
              if (lead != null) ...<Widget>[
                SizedBox(
                  width: AppSize.iconTile,
                  child: Center(child: lead),
                ),
                const SizedBox(width: AppSpace.s),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    WholeWordText(
                      title,
                      key: titleKey,
                      style: titleStyle ??
                          text.bodyLarge!.copyWith(color: titleColor),
                    ),
                    if (subtitle case final String subtitle)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: WholeWordText(
                          subtitle,
                          style: text.bodyMedium!.copyWith(
                            color: colors.muted,
                          ),
                        ),
                      ),
                    if (stacked && valueText != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: valueText,
                      ),
                  ],
                ),
              ),
              if (!stacked && valueText != null) ...<Widget>[
                const SizedBox(width: AppSpace.s),
                Flexible(child: valueText),
              ],
              if (trailing case final Widget trailing) ...<Widget>[
                const SizedBox(width: AppSpace.xs),
                trailing,
              ],
              if (chevron) ...<Widget>[
                const SizedBox(width: AppSpace.xxs),
                Icon(Icons.chevron_right, size: 20, color: colors.faint),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Строка с переключателем: тап по всей строке переключает его. Это
/// `SwitchListTile` (тип и ключ видят тесты) с подписями без разрыва слов.
final class GroupedSwitchRow extends SwitchListTile {
  GroupedSwitchRow({
    super.key,
    required String title,
    String? subtitle,
    required super.value,
    required super.onChanged,
    super.secondary,
  }) : super(
          title: WholeWordText(title),
          subtitle: subtitle == null ? null : WholeWordText(subtitle),
          // Подписи с того же отступа, что у [GroupedRow]: значок
          // [AppSize.iconTile] и зазор [AppSpace.s].
          minLeadingWidth: AppSize.iconTile,
          horizontalTitleGap: AppSpace.s,
        );
}

/// Выбор из 2–5 вариантов строками с галочкой акцентом (вместо чипов и
/// сегментов на телефоне). Ключ строки — `'$keyPrefix${id(option)}'`.
final class GroupedChoiceList<T> extends StatelessWidget {
  const GroupedChoiceList({
    super.key,
    this.header,
    this.footer,
    required this.options,
    required this.selected,
    required this.label,
    required this.onSelected,
    this.optionKey,
    this.subtitle,
    this.margin,
  });

  final String? header;
  final Object? footer;
  final List<T> options;
  final T selected;
  final String Function(T option) label;
  final String? Function(T option)? subtitle;
  final ValueChanged<T>? onSelected;
  final Key Function(T option)? optionKey;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InsetGroup(
      header: header,
      footer: footer,
      margin: margin,
      children: <Widget>[
        for (final option in options)
          Semantics(
            selected: option == selected,
            inMutuallyExclusiveGroup: true,
            child: GroupedRow(
              key: optionKey?.call(option),
              title: label(option),
              subtitle: subtitle?.call(option),
              onTap: onSelected == null ? null : () => onSelected!(option),
              trailing: SizedBox(
                width: 24,
                child: option == selected
                    ? Icon(Icons.check, size: 22, color: colors.accent)
                    : null,
              ),
            ),
          ),
      ],
    );
  }
}

/// Крупный заголовок экрана: 26 w700, отступы 16, 8, 16, 12.
final class LargeTitle extends StatelessWidget {
  const LargeTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.displaySmall!.copyWith(
          color: context.colors.textStrong,
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.pageH,
        AppSpace.xs,
        AppSpace.pageH,
        AppSpace.s,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Semantics(
              header: true,
              child: WholeWordText(text, style: style),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Поле поиска: заливка (`raised` на листе, `workspace` на фоне экрана),
/// скругление 12, видимая высота 40 в цели нажатия 48, значок лупы.
final class SearchField extends StatelessWidget {
  const SearchField({
    super.key,
    required this.controller,
    this.focusNode,
    this.hint = 'Поиск',
    this.onChanged,
    this.onSubmitted,
    this.onClear,
    this.onBackground = true,
    this.autofocus = false,
    this.semanticsLabel,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// Кнопка «очистить» при непустом поле; `null` — очищает само.
  final VoidCallback? onClear;

  /// Поле на фоне сгруппированного экрана (тогда заливка — лист).
  final bool onBackground;
  final bool autofocus;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final Widget box = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSize.minTap),
      child: Center(
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          autofocus: autofocus,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          textInputAction: TextInputAction.search,
          style: text.bodyLarge!.copyWith(color: colors.textStrong),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: onBackground ? colors.workspace : colors.raised,
            hintText: hint,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
            prefixIcon: Icon(Icons.search, size: 20, color: colors.muted),
            prefixIconConstraints:
                const BoxConstraints(minWidth: 36, minHeight: 40),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.search),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.search),
              borderSide: BorderSide.none,
            ),
            // Фокус виден рамкой 1.5 акцентом (§0: допустимая рамка).
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.search),
              borderSide: BorderSide(color: colors.accent, width: 1.5),
            ),
            suffixIcon: ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (BuildContext context, TextEditingValue v, _) => v
                      .text.isEmpty
                  ? const SizedBox.shrink()
                  : IconButton(
                      tooltip: 'Очистить',
                      icon: Icon(Icons.cancel, size: 18, color: colors.faint),
                      onPressed: onClear ??
                          () {
                            controller.clear();
                            onChanged?.call('');
                          },
                    ),
            ),
          ),
        ),
      ),
    );
    // Подпись для экранного диктора — поверх подсказки «Поиск».
    return semanticsLabel == null
        ? box
        : Semantics(label: semanticsLabel, textField: true, child: box);
  }
}

/// Карточка заливкой `raised`, скругление 12, без рамки: заголовок 16 со
/// значком 22, тело 14 приглушённым.
final class FilledCard extends StatelessWidget {
  const FilledCard({
    super.key,
    this.icon,
    this.title,
    required this.child,
    this.color,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 16),
  });

  final IconData? icon;
  final String? title;
  final Widget child;
  final Color? color;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return Material(
      color: color ?? colors.raised,
      borderRadius: BorderRadius.circular(AppRadius.card),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (title != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.xs),
                child: Row(
                  children: <Widget>[
                    if (icon != null) ...<Widget>[
                      Icon(icon, size: AppSize.icon, color: colors.icon),
                      const SizedBox(width: AppSpace.xs),
                    ],
                    Expanded(
                      child: WholeWordText(
                        title!,
                        style: text.titleMedium!.copyWith(
                          color: colors.textStrong,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            DefaultTextStyle.merge(
              style: text.bodyMedium!.copyWith(color: colors.muted),
              child: child,
            ),
          ],
        ),
      ),
    );
  }
}

/// Строка длинного сгруппированного списка (`ListView.builder`): заливка
/// листа, скругление у первой и последней строки, разделитель «вставкой»
/// над всеми, кроме первой. Список строится лениво — [InsetGroup] для
/// сотен строк не годится.
final class GroupedListCell extends StatelessWidget {
  const GroupedListCell({
    super.key,
    required this.first,
    required this.last,
    required this.child,
    this.indent = AppSpace.rowH,
    this.color,
  });

  final bool first;
  final bool last;
  final Widget child;
  final double indent;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    const r = Radius.circular(AppRadius.group);
    return ClipRRect(
      borderRadius: BorderRadius.vertical(
        top: first ? r : Radius.zero,
        bottom: last ? r : Radius.zero,
      ),
      child: Material(
        color: color ?? context.colors.workspace,
        child: ListTileTheme.merge(
          tileColor: Colors.transparent,
          contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.rowH),
          minTileHeight: AppSize.rowMin,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (!first) _InsetSeparator(indent: indent),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// Строка навигации с выбором (раздел, проект, сессия; ADR-027): заливка
/// выбранной строки и волна нажатия — одной формы. В группе ([inGroup])
/// заливка отступает от краёв группы на [AppSpace.selectionInsetH] и
/// скруглена концентрично ей ([AppRadius.selection]); на фоне панели —
/// скругление поля ([AppRadius.field]) без отступа.
///
/// Строка внутри ([child]) уменьшает свои боковые поля на
/// [AppSpace.selectionInsetH], чтобы текст оставался на прежнем месте.
final class SelectableRow extends StatelessWidget {
  const SelectableRow({
    super.key,
    required this.selected,
    required this.onTap,
    required this.child,
    this.inkKey,
    this.inGroup = true,
  });

  final bool selected;
  final VoidCallback? onTap;
  final Widget child;

  /// Ключ самой кнопки ([InkWell]).
  final Key? inkKey;
  final bool inGroup;

  /// Форма заливки строки [inGroup].
  static BorderRadius radiusOf({bool inGroup = true}) => BorderRadius.circular(
        inGroup ? AppRadius.selection : AppRadius.field,
      );

  @override
  Widget build(BuildContext context) {
    final radius = radiusOf(inGroup: inGroup);
    final body = Material(
      type: selected ? MaterialType.canvas : MaterialType.transparency,
      color: selected ? context.colors.selection : null,
      borderRadius: radius,
      child: InkWell(
        key: inkKey,
        onTap: onTap,
        borderRadius: radius,
        child: child,
      ),
    );
    if (!inGroup) return body;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.selectionInsetH,
        vertical: AppSpace.selectionInsetV,
      ),
      child: body,
    );
  }
}

/// Тень «бегунка» выбранного сегмента: только в светлой теме — в тёмной
/// бегунок и так светлее дорожки.
List<BoxShadow>? segmentThumbShadow(BuildContext context) =>
    context.colors.isLight
        ? <BoxShadow>[
            BoxShadow(
              color: context.colors.shadow,
              blurRadius: 6,
              offset: const Offset(0, 1),
            ),
          ]
        : null;
