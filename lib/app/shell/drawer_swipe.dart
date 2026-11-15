import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Свайп вправо по рабочей области (сессия, разделы, «Мой Связной»)
/// открывает меню на телефоне, как в приложениях ChatGPT и Claude: не
/// только от края экрана. У самого края на Android с жестовой навигацией
/// палец забирает система как «Назад», поэтому одной полосы у края мало.
///
/// Жест читается по сырым касаниям ([Listener]), а не через «арену»
/// жестов: текст сообщений ([SelectableText]) сам забирает горизонтальное
/// перетаскивание, и свайп по ленте иначе почти никогда бы не сработал.
/// Поэтому правила здесь свои:
///
/// - только палец и стилус — мышь на компьютере ничего не открывает;
/// - направление решается, когда палец сдвинулся на [kTouchSlop]: вправо
///   и заметно больше по горизонтали, чем по вертикали — свайп; иначе это
///   прокрутка ленты или что-то ещё, и до отпускания пальца жест больше не
///   смотрим;
/// - палец держали дольше [kLongPressTimeout], прежде чем повести, — это
///   выделение текста, а не свайп;
/// - касание, попавшее в горизонтальную прокрутку (строка кнопок,
///   вкладки), которую можно прокрутить назад, в однострочное поле
///   ввода, в поле ввода с курсором (там палец двигает курсор и
///   выделение) или в [DrawerSwipeBlocker], свайпом не считается — у них
///   свои жесты. Прокрутка у своего начала (первая вкладка) вправо тянуть
///   не может, и там свайп открывает меню; прокрутку, которую палец не
///   двигает (вкладки «Мой Связной» на телефоне), свайп не замечает.
///   Многострочное поле без фокуса (текст документа) свайпу не мешает:
///   горизонтально в нём тянуть нечего;
/// - горизонтальная прокрутка, которая всё же началась под пальцем (в том
///   числе [SingleChildScrollView], которого по дереву отрисовки не
///   узнать), снимает свайп ([ScrollStartNotification]), если она не у
///   своего начала;
/// - у самого края экрана ([edge]) меню тянет за палец Scaffold — там не
///   вмешиваемся. Ту же ширину получает `Scaffold.drawerEdgeDragWidth`,
///   чтобы между зонами не было «мёртвой» полосы.
///
/// Свайп влево — зеркально: с [onOpenEnd] он открывает правую панель
/// («Файлы сессии», ADR-028) по тем же правилам. У правого края ([edge])
/// панель тоже тянет за палец Scaffold. Горизонтальная прокрутка, которую
/// можно прокрутить вперёд, свайп влево забирает себе — как свайп вправо
/// у прокрутки, которую можно вернуть назад. Без [onOpenEnd] свайп влево
/// ничего не делает: открытое меню закрывает сама выдвижная панель.
///
/// Панель открывается анимацией, как только палец прошёл [distance], а не
/// тянется за ним: у [DrawerController] нет открытого API для этого.
/// Экранный диктор жест не видит: для него есть кнопки «Меню» и «Файлы
/// сессии».
final class DrawerSwipe extends StatefulWidget {
  const DrawerSwipe({
    super.key,
    required this.child,
    required this.onOpen,
    this.onOpenEnd,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback onOpen;

  /// Свайп влево: открыть правую панель; `null` — свайпа влево нет.
  final VoidCallback? onOpenEnd;

  /// Свайпы в обе стороны.
  final bool enabled;

  /// Сколько пикселей вправо достаточно, чтобы открыть меню.
  static const double distance = 48;

  /// Полоса у левого (и правого) края, где панель тянет за палец сам
  /// Scaffold: её же передают в `Scaffold.drawerEdgeDragWidth`.
  static const double edge = 24;

  @override
  State<DrawerSwipe> createState() => _DrawerSwipeState();
}

enum _Phase { undecided, swipe, swipeEnd, ignored }

final class _DrawerSwipeState extends State<DrawerSwipe> {
  int? _pointer;
  Offset _start = Offset.zero;
  _Phase _phase = _Phase.ignored;

  /// Куда ещё можно: вправо (меню) и влево (правая панель).
  bool _right = false;
  bool _left = false;

  /// Ширина окна: полоса у правого края.
  double _width = double.infinity;

  /// Палец держат на месте дольше [kLongPressTimeout]: это выделение
  /// текста, свайпа не будет.
  Timer? _hold;

  @override
  void dispose() {
    _hold?.cancel();
    super.dispose();
  }

  static const Set<PointerDeviceKind> _kinds = <PointerDeviceKind>{
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
  };

  void _onDown(PointerDownEvent event) {
    if (_pointer != null) {
      // Второй палец — это уже не свайп.
      _phase = _Phase.ignored;
      return;
    }
    if (!widget.enabled || !_kinds.contains(event.kind)) return;
    final dx = event.position.dx;
    var right = dx >= DrawerSwipe.edge;
    var left = widget.onOpenEnd != null && dx <= _width - DrawerSwipe.edge;
    if (!right && !left) return;
    final blocked = _blocked(event);
    right = right && !blocked.right;
    left = left && !blocked.left;
    if (!right && !left) return;
    _right = right;
    _left = left;
    _pointer = event.pointer;
    _start = event.position;
    _phase = _Phase.undecided;
    _hold?.cancel();
    _hold = Timer(kLongPressTimeout, () {
      if (_phase == _Phase.undecided) _phase = _Phase.ignored;
    });
  }

  void _onMove(PointerMoveEvent event) {
    if (event.pointer != _pointer || _phase == _Phase.ignored) return;
    final delta = event.position - _start;
    if (_phase == _Phase.undecided) {
      if (delta.distance < kTouchSlop) return;
      _hold?.cancel();
      final horizontal = delta.dx.abs() > delta.dy.abs() * 2;
      _phase = !horizontal
          ? _Phase.ignored
          : delta.dx > 0
              ? (_right ? _Phase.swipe : _Phase.ignored)
              : (_left ? _Phase.swipeEnd : _Phase.ignored);
    }
    if (_phase == _Phase.swipe && delta.dx >= DrawerSwipe.distance) {
      _phase = _Phase.ignored;
      widget.onOpen();
    } else if (_phase == _Phase.swipeEnd && -delta.dx >= DrawerSwipe.distance) {
      _phase = _Phase.ignored;
      widget.onOpenEnd?.call();
    }
  }

  void _onEnd(PointerEvent event) {
    if (event.pointer != _pointer) return;
    _hold?.cancel();
    _pointer = null;
    _phase = _Phase.ignored;
  }

  /// Касание попало туда, где горизонтальное движение — своё: строка с
  /// горизонтальной прокруткой, изменяемое поле ввода или
  /// [DrawerSwipeBlocker]. Для каждой стороны отдельно: прокрутку у
  /// начала вправо тянуть некуда, у конца — влево.
  ({bool right, bool left}) _blocked(PointerDownEvent event) {
    const both = (right: true, left: true);
    var right = false;
    var left = false;
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, event.position, event.viewId);
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData &&
          identical(target.metaData, DrawerSwipeBlocker.marker)) {
        return both;
      }
      // Горизонтальная прокрутка у своего начала (первая вкладка, строка
      // кнопок в исходном положении) тянуть вправо не может — там свайп
      // открывает меню. Прокрученная — забирает жест себе. Влево так же:
      // у конца свайп открывает правую панель.
      if (target is RenderViewportBase &&
          axisDirectionToAxis(target.axisDirection) == Axis.horizontal &&
          _userScrollable(target.offset)) {
        final ltr = target.axisDirection == AxisDirection.right;
        right = right || !(ltr && _atStart(target.offset));
        left = left || !(ltr && _atEnd(target.offset));
      }
      if (target is RenderEditable &&
          !target.readOnly &&
          (target.hasFocus || target.maxLines == 1)) {
        return both;
      }
    }
    return (right: right, left: left);
  }

  /// Прокрутку, которую палец не двигает (вкладки «Мой Связной» на
  /// телефоне листают только сегменты), свайп не замечает.
  static bool _userScrollable(ViewportOffset offset) =>
      offset is! ScrollPosition ||
      offset.physics.shouldAcceptUserOffset(offset);

  static bool _atStart(ViewportOffset offset) =>
      offset is ScrollPosition &&
      offset.hasContentDimensions &&
      offset.pixels <= offset.minScrollExtent;

  static bool _atEnd(ViewportOffset offset) =>
      offset is ScrollPosition &&
      offset.hasContentDimensions &&
      offset.pixels >= offset.maxScrollExtent;

  /// Под пальцем началась горизонтальная прокрутка — это её жест. Кроме
  /// прокрутки у своего начала (первая вкладка [TabBarView], строка кнопок
  /// в исходном положении): вправо ей тянуть некуда, и куда повели палец,
  /// решит [_onMove] — вправо это свайп меню, влево прокрутка.
  bool _onScroll(ScrollStartNotification notification) {
    final m = notification.metrics;
    if (_pointer == null ||
        notification.dragDetails == null ||
        m.axis != Axis.horizontal) {
      return false;
    }
    final ltr = m.axisDirection == AxisDirection.right;
    if (!(ltr && m.extentBefore == 0)) {
      _right = false;
      if (_phase == _Phase.swipe) _phase = _Phase.ignored;
    }
    if (!(ltr && m.extentAfter == 0)) {
      _left = false;
      if (_phase == _Phase.swipeEnd) _phase = _Phase.ignored;
    }
    if (!_right && !_left) {
      _hold?.cancel();
      _phase = _Phase.ignored;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    _width = MediaQuery.maybeSizeOf(context)?.width ?? double.infinity;
    return Listener(
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onEnd,
      onPointerCancel: _onEnd,
      child: NotificationListener<ScrollStartNotification>(
        onNotification: _onScroll,
        child: widget.child,
      ),
    );
  }
}

/// Место, где свайп вправо меню (и влево правую панель) не открывает:
/// поле ввода и кнопки под ним. Касание здесь [DrawerSwipe] пропускает,
/// своим жестам содержимого (выделение текста, прокрутка строки кнопок)
/// метка не мешает.
final class DrawerSwipeBlocker extends StatelessWidget {
  const DrawerSwipeBlocker({super.key, required this.child});

  final Widget child;

  /// Метка в дереве отрисовки, по которой [DrawerSwipe] узнаёт место.
  static final Object marker = Object();

  @override
  Widget build(BuildContext context) {
    return MetaData(
      metaData: marker,
      behavior: HitTestBehavior.translucent,
      child: child,
    );
  }
}
