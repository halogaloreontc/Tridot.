import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Свайп вправо по области сессии открывает меню (на телефоне), как в
/// приложениях ChatGPT и Claude: не только от края экрана.
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
/// - касание, попавшее в горизонтальную прокрутку (строка кнопок), в
///   однострочное поле ввода, в поле ввода с курсором (там палец двигает
///   курсор и выделение) или в [DrawerSwipeBlocker], свайпом не
///   считается — у них свои жесты. Многострочное поле без фокуса (текст
///   документа) свайпу не мешает: горизонтально в нём тянуть нечего;
/// - горизонтальная прокрутка, которая всё же началась под пальцем (в том
///   числе [SingleChildScrollView], которого по дереву отрисовки не
///   узнать), снимает свайп ([ScrollStartNotification]);
/// - у самого края экрана ([edge]) меню тянет за палец Scaffold — там не
///   вмешиваемся. Ту же ширину получает `Scaffold.drawerEdgeDragWidth`,
///   чтобы между зонами не было «мёртвой» полосы.
///
/// Меню открывается анимацией, как только палец прошёл [distance], а не
/// тянется за ним: у [DrawerController] нет открытого API для этого. Свайп
/// влево здесь ничего не делает: открытое меню закрывает сама выдвижная
/// панель. Экранный диктор жест не видит: для него есть кнопка «Меню».
final class DrawerSwipe extends StatefulWidget {
  const DrawerSwipe({
    super.key,
    required this.child,
    required this.onOpen,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback onOpen;
  final bool enabled;

  /// Сколько пикселей вправо достаточно, чтобы открыть меню.
  static const double distance = 48;

  /// Полоса у левого края, где меню тянет за палец сам Scaffold: её же
  /// передают в `Scaffold.drawerEdgeDragWidth`.
  static const double edge = 24;

  @override
  State<DrawerSwipe> createState() => _DrawerSwipeState();
}

enum _Phase { undecided, swipe, ignored }

final class _DrawerSwipeState extends State<DrawerSwipe> {
  int? _pointer;
  Offset _start = Offset.zero;
  _Phase _phase = _Phase.ignored;

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
    if (!widget.enabled ||
        !_kinds.contains(event.kind) ||
        event.position.dx < DrawerSwipe.edge ||
        _blocked(event)) {
      return;
    }
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
      _phase = delta.dx > 0 && delta.dx.abs() > delta.dy.abs() * 2
          ? _Phase.swipe
          : _Phase.ignored;
    }
    if (_phase == _Phase.swipe && delta.dx >= DrawerSwipe.distance) {
      _phase = _Phase.ignored;
      widget.onOpen();
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
  /// [DrawerSwipeBlocker].
  bool _blocked(PointerDownEvent event) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, event.position, event.viewId);
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData &&
          identical(target.metaData, DrawerSwipeBlocker.marker)) {
        return true;
      }
      if (target is RenderViewportBase &&
          axisDirectionToAxis(target.axisDirection) == Axis.horizontal) {
        return true;
      }
      if (target is RenderEditable &&
          !target.readOnly &&
          (target.hasFocus || target.maxLines == 1)) {
        return true;
      }
    }
    return false;
  }

  /// Под пальцем началась горизонтальная прокрутка — это её жест.
  bool _onScroll(ScrollStartNotification notification) {
    if (_pointer != null &&
        notification.dragDetails != null &&
        notification.metrics.axis == Axis.horizontal) {
      _hold?.cancel();
      _phase = _Phase.ignored;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
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

/// Место, где свайп вправо меню не открывает: поле ввода и кнопки под
/// ним. Касание здесь [DrawerSwipe] пропускает, своим жестам содержимого
/// (выделение текста, прокрутка строки кнопок) метка не мешает.
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
