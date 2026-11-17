// Окна подтверждения и разрешения (ADR-027, поправка «плотнее»): один
// компонент на все диалоги и шторки с «Да / Нет» — плитка значка и
// заголовок 18/600, текст 15, кнопки высотой 44 в ряд справа с зазором 8
// (не помещаются — столбиком во всю ширину, главная сверху), поля 20 и
// одна ширина у всех окон.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../assistant_theme.dart';
import '../layout.dart';
import 'grouped.dart';

/// Шапка окна: плитка значка (если есть) и заголовок. Заголовок — то, что
/// передали ([Text] или [WholeWordText]); стиль берётся из темы окна.
final class ConfirmHeader extends StatelessWidget {
  const ConfirmHeader({
    super.key,
    required this.title,
    this.icon,
    this.iconColor,
  });

  final Widget title;
  final IconData? icon;

  /// Цвет плитки; по умолчанию — фиолетовая плитка палитры.
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final icon = this.icon;
    if (icon == null) return title;
    // Плитка — у первой строки заголовка, а не посреди двух-трёх строк:
    // ряд прижат к верху, а короткая строка (или плитка) сдвинута так,
    // чтобы их середины совпали.
    final line = MediaQuery.textScalerOf(context)
            .scale(AssistantTheme.dialogTitle.fontSize ?? 18) *
        (AssistantTheme.dialogTitle.height ?? 1.33);
    final tileShift = math.max(0.0, (line - _tile) / 2);
    final titleShift = math.max(0.0, (_tile - line) / 2);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.only(top: tileShift),
          child: IconTile(
            icon: icon,
            color: iconColor ?? context.colors.tileViolet,
          ),
        ),
        const SizedBox(width: AppSpace.s),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(top: titleShift),
            child: title,
          ),
        ),
      ],
    );
  }

  static const double _tile = AppSize.iconTile;
}

/// Подпись кнопки окна: по центру и в две строки — при крупном шрифте
/// длинная подпись («Удалить вместе с сессиями») переносится, но не
/// прилипает к левому краю кнопки во всю ширину.
final class ActionLabel extends StatelessWidget {
  const ActionLabel(this.data, {super.key});

  final String data;

  @override
  Widget build(BuildContext context) => Text(data, textAlign: TextAlign.center);
}

/// Ручка шторки 32×4: 8 сверху и 12 до заголовка — вместо ручки темы с
/// полем 48, которая отодвигала заголовок шторки подтверждения на 54.
/// Как у ручки темы, это кнопка «закрыть» для диктора; её цель — 48×48
/// по центру, нижняя половина ложится на поле заголовка.
final class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).bottomSheetTheme;
    final size = theme.dragHandleSize ?? const Size(32, 4);
    void close() => unawaited(Navigator.of(context).maybePop());
    return SizedBox(
      height: AppSpace.xs + size.height + AppSpace.s,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.topCenter,
        children: <Widget>[
          Positioned(
            top: AppSpace.xs,
            child: Container(
              key: const Key('sheet-handle'),
              width: size.width,
              height: size.height,
              decoration: BoxDecoration(
                color: theme.dragHandleColor ?? context.colors.faint,
                borderRadius: BorderRadius.circular(size.height / 2),
              ),
            ),
          ),
          Positioned(
            top: 0,
            width: kMinInteractiveDimension,
            height: kMinInteractiveDimension,
            child: Semantics(
              button: true,
              label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
              onTap: close,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onTap: close,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Диалог подтверждения или разрешения поверх [AlertDialog]: те же
/// `title`, `content`, `actions`, но поля, ширина, шрифты и ряд кнопок —
/// общие для всех окон приложения.
final class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    this.icon,
    this.iconColor,
    this.title,
    this.content,
    this.actions,
    this.scrollable = false,
    this.contentWidth = AppDialogMetrics.contentWidth,
  });

  /// Ширина текста окна. Общая 312 — у подтверждений; окна со списком или
  /// полями (выбор папки, пак, мастер-пароль) просят шире — на телефоне
  /// их всё равно ограничит экран.
  final double contentWidth;

  /// Значок в плитке слева от заголовка — у окон разрешений и согласий.
  final IconData? icon;
  final Color? iconColor;
  final Widget? title;
  final Widget? content;

  /// Кнопки в порядке «второстепенная … главная»: в ряду главная справа,
  /// столбиком — сверху.
  final List<Widget>? actions;

  /// Текст листается, кнопки остаются на месте.
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final title = this.title;
    final content = this.content;
    final actions = this.actions;
    final width = contentWidth;
    return AlertDialog(
      scrollable: scrollable,
      titlePadding: const EdgeInsets.fromLTRB(
        AppDialogMetrics.padH,
        AppDialogMetrics.padTop,
        AppDialogMetrics.padH,
        0,
      ),
      title: title == null
          ? null
          : SizedBox(
              width: width,
              child: ConfirmHeader(
                title: title,
                icon: icon,
                iconColor: iconColor,
              ),
            ),
      contentPadding: EdgeInsets.fromLTRB(
        AppDialogMetrics.padH,
        title == null ? AppDialogMetrics.padTop : AppDialogMetrics.titleGap,
        AppDialogMetrics.padH,
        actions == null || actions.isEmpty ? AppDialogMetrics.padTop : 0,
      ),
      content: content == null ? null : SizedBox(width: width, child: content),
      actionsPadding: const EdgeInsets.fromLTRB(
        AppDialogMetrics.actionsH,
        AppDialogMetrics.actionsTop,
        AppDialogMetrics.actionsH,
        AppDialogMetrics.actionsBottom,
      ),
      actions: actions == null || actions.isEmpty
          ? null
          : <Widget>[ConfirmActions(children: actions)],
    );
  }
}

/// Шторка подтверждения или разрешения: ручка 32×4, плитка значка и
/// заголовок, текст 15, кнопки внизу на виду — при крупном шрифте текст
/// листается. Низ — над системной панелью ([SafeArea]).
final class AppSheet extends StatelessWidget {
  const AppSheet({
    super.key,
    required this.title,
    this.icon,
    this.iconColor,
    this.body,
    this.actions = const <Widget>[],
    this.handle = true,
  });

  /// Ручка сверху ([SheetHandle]); у шторки, которую нельзя смахнуть, —
  /// просто поле 20.
  final bool handle;

  final Widget title;
  final IconData? icon;
  final Color? iconColor;
  final Widget? body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final body = this.body;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (handle)
            const SheetHandle()
          else
            const SizedBox(height: AppDialogMetrics.padTop),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                AppDialogMetrics.padH,
                0,
                AppDialogMetrics.padH,
                0,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Semantics(
                    header: true,
                    child: DefaultTextStyle.merge(
                      style: AssistantTheme.dialogTitle.copyWith(
                        color: colors.textStrong,
                      ),
                      child: ConfirmHeader(
                        title: title,
                        icon: icon,
                        iconColor: iconColor,
                      ),
                    ),
                  ),
                  if (body != null) ...<Widget>[
                    const SizedBox(height: AppDialogMetrics.titleGap),
                    DefaultTextStyle.merge(
                      style: AssistantTheme.dialogBody.copyWith(
                        color: colors.text,
                      ),
                      child: body,
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppDialogMetrics.actionsH,
                AppDialogMetrics.actionsTop,
                AppDialogMetrics.actionsH,
                AppDialogMetrics.actionsBottom,
              ),
              child: ConfirmActions(children: actions),
            )
          else
            const SizedBox(height: AppDialogMetrics.padTop),
        ],
      ),
    );
  }
}

/// Шторка подтверждения из [AppSheet]: фон — лист окон (`workspace`, как
/// у диалогов), не выше 90 % экрана и не шире 560.
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isDismissible = true,
}) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      isDismissible: isDismissible,
      enableDrag: isDismissible,
      // Ручку рисует сама [AppSheet] — без поля 48 у ручки темы.
      showDragHandle: false,
      backgroundColor: context.colors.workspace,
      constraints: BoxConstraints(
        maxWidth: 560,
        maxHeight: MediaQuery.sizeOf(context).height * 0.9,
      ),
      builder: builder,
    );

/// Кнопка отказа или отмены — текстовая.
final class DialogCancel extends StatelessWidget {
  const DialogCancel({
    super.key,
    required this.onPressed,
    this.label = 'Отмена',
  });

  final VoidCallback? onPressed;
  final String label;

  @override
  Widget build(BuildContext context) =>
      TextButton(onPressed: onPressed, child: Text(label));
}

/// Разрушающее действие («Удалить», «Очистить»): текстовая кнопка цветом
/// ошибки — видно, что оно необратимо, и не спорит с текстом окна.
final class DialogDanger extends StatelessWidget {
  const DialogDanger({
    super.key,
    required this.onPressed,
    required this.child,
  });

  final VoidCallback? onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) => TextButton(
        style: TextButton.styleFrom(foregroundColor: context.colors.danger),
        onPressed: onPressed,
        child: child,
      );
}

/// Ряд кнопок окна: в строку справа с зазором [spacing], если все
/// помещаются; иначе — столбиком во всю ширину, последняя (главная) —
/// сверху. Своя ширина в замерах — ширина самой широкой кнопки, а не
/// сумма: кнопки не расширяют окно, а переходят в столбик.
final class ConfirmActions extends MultiChildRenderObjectWidget {
  const ConfirmActions({
    super.key,
    required super.children,
    this.spacing = AppDialogMetrics.actionGap,
  });

  final double spacing;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderConfirmActions(spacing: spacing);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderConfirmActions renderObject,
  ) {
    renderObject.spacing = spacing;
  }
}

final class _ActionsParentData extends ContainerBoxParentData<RenderBox> {}

/// Раскладка [ConfirmActions].
final class RenderConfirmActions extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _ActionsParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _ActionsParentData> {
  RenderConfirmActions({required double spacing}) : _spacing = spacing;

  double _spacing;
  double get spacing => _spacing;
  set spacing(double value) {
    if (value == _spacing) return;
    _spacing = value;
    markNeedsLayout();
  }

  /// Последняя раскладка — столбиком (для тестов).
  bool get stacked => _stacked;
  bool _stacked = false;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ActionsParentData) {
      child.parentData = _ActionsParentData();
    }
  }

  List<RenderBox> get _children {
    final out = <RenderBox>[];
    var child = firstChild;
    while (child != null) {
      out.add(child);
      child = childAfter(child);
    }
    return out;
  }

  double _rowWidth(List<RenderBox> kids) {
    if (kids.isEmpty) return 0;
    var sum = spacing * (kids.length - 1);
    for (final c in kids) {
      sum += c.getMaxIntrinsicWidth(double.infinity);
    }
    return sum;
  }

  bool _fits(List<RenderBox> kids, double maxWidth) =>
      _rowWidth(kids) <= maxWidth + 0.01;

  @override
  double computeMinIntrinsicWidth(double height) {
    var w = 0.0;
    for (final c in _children) {
      w = math.max(w, c.getMinIntrinsicWidth(double.infinity));
    }
    return w;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    var w = 0.0;
    for (final c in _children) {
      w = math.max(w, c.getMaxIntrinsicWidth(double.infinity));
    }
    return w;
  }

  double _heightFor(double width) {
    final kids = _children;
    if (kids.isEmpty) return 0;
    if (_fits(kids, width)) {
      var h = 0.0;
      for (final c in kids) {
        h = math.max(
          h,
          c.getMinIntrinsicHeight(c.getMaxIntrinsicWidth(double.infinity)),
        );
      }
      return h;
    }
    var h = spacing * (kids.length - 1);
    for (final c in kids) {
      h += c.getMinIntrinsicHeight(width);
    }
    return h;
  }

  @override
  double computeMinIntrinsicHeight(double width) => _heightFor(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _heightFor(width);

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final kids = _children;
    if (kids.isEmpty) return constraints.smallest;
    final maxWidth =
        constraints.maxWidth.isFinite ? constraints.maxWidth : _rowWidth(kids);
    Size size(RenderBox c, BoxConstraints bc) =>
        dry ? c.getDryLayout(bc) : (c..layout(bc, parentUsesSize: true)).size;
    if (_fits(kids, maxWidth)) {
      if (!dry) _stacked = false;
      final sizes = <Size>[
        for (final c in kids) size(c, BoxConstraints(maxWidth: maxWidth)),
      ];
      final height = sizes.fold<double>(0, (h, s) => math.max(h, s.height));
      if (!dry) {
        var x = maxWidth -
            sizes.fold<double>(0, (w, s) => w + s.width) -
            spacing * (kids.length - 1);
        for (final (i, c) in kids.indexed) {
          (c.parentData! as _ActionsParentData).offset =
              Offset(x, (height - sizes[i].height) / 2);
          x += sizes[i].width + spacing;
        }
      }
      return constraints.constrain(Size(maxWidth, height));
    }
    if (!dry) _stacked = true;
    var y = 0.0;
    for (final c in kids.reversed) {
      final s = size(c, BoxConstraints.tightFor(width: maxWidth));
      if (!dry) {
        (c.parentData! as _ActionsParentData).offset = Offset(0, y);
      }
      y += s.height + spacing;
    }
    return constraints.constrain(Size(maxWidth, y - spacing));
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layout(constraints, dry: true);

  @override
  void performLayout() {
    size = _layout(constraints, dry: false);
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
