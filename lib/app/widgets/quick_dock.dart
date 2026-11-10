import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Низ чата: быстрые действия над полем ввода, с бюджетом высоты.
///
/// Поле ввода ([composer] — обычно в своей прокрутке) сначала получает
/// столько высоты, сколько просит. Быстрым действиям достаётся остаток
/// бюджета [budget]:
///
/// - остатка хватает хотя бы на [minRoom] — действия получают его как
///   наибольшую высоту (переносятся по строкам, а если не уместились —
///   прокручиваются внутри остатка);
/// - не хватает (узкий экран и крупный шрифт) — действия получают
///   неограниченную высоту: это знак собрать их в одну строку с
///   горизонтальной прокруткой ([QuickDock.isTight]). Строка остаётся на
///   месте, а полю ввода достаётся остаток бюджета — оно прокручивается
///   внутри себя.
///
/// Так кнопки ролей не уезжают под «Кому:» вместе с половиной чужой
/// кнопки, а остаются в одной видимой строке над полем ввода.
class QuickDock extends MultiChildRenderObjectWidget {
  QuickDock({
    super.key,
    required this.budget,
    required Widget actions,
    required Widget composer,
    this.minRoom = 104,
  }) : super(children: <Widget>[actions, composer]);

  /// Сколько высоты у низа чата всего.
  final double budget;

  /// Меньше этого остатка действиям не хватит на две строки кнопок.
  final double minRoom;

  /// Действиям в [constraints] места не хватило: показать одной строкой.
  static bool isTight(BoxConstraints constraints) =>
      !constraints.hasBoundedHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderQuickDock(budget: budget, minRoom: minRoom);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderQuickDock)
      ..budget = budget
      ..minRoom = minRoom;
  }
}

final class _DockParentData extends ContainerBoxParentData<RenderBox> {}

final class _RenderQuickDock extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _DockParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _DockParentData> {
  _RenderQuickDock({required double budget, required double minRoom})
      : _budget = budget,
        _minRoom = minRoom;

  double _budget;

  set budget(double value) {
    if (value == _budget) return;
    _budget = value;
    markNeedsLayout();
  }

  double _minRoom;

  set minRoom(double value) {
    if (value == _minRoom) return;
    _minRoom = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _DockParentData) {
      child.parentData = _DockParentData();
    }
  }

  @override
  void performLayout() {
    final actions = firstChild!;
    final composer = lastChild!;
    final width = constraints.maxWidth;
    final wide = BoxConstraints.tightFor(width: width);
    composer.layout(wide, parentUsesSize: true);
    final room = _budget - composer.size.height;
    if (room >= _minRoom) {
      actions.layout(wide.copyWith(maxHeight: room), parentUsesSize: true);
    } else {
      // Тесно: действия — одной строкой, полю ввода — что осталось (оно
      // прокручивается внутри себя, строка действий остаётся на виду).
      actions.layout(wide, parentUsesSize: true);
      final rest = _budget - actions.size.height;
      if (rest > 0 && rest < composer.size.height) {
        composer.layout(wide.copyWith(maxHeight: rest), parentUsesSize: true);
      }
    }
    (actions.parentData! as _DockParentData).offset = Offset.zero;
    (composer.parentData! as _DockParentData).offset =
        Offset(0, actions.size.height);
    size = constraints.constrain(
      Size(width, actions.size.height + composer.size.height),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
