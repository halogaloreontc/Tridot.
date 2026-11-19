// Поле в фокусе всегда видно над экранной клавиатурой (ADR-040).
//
// Сама клавиатура места не отнимает: Scaffold сжимает тело на её высоту
// (`resizeToAvoidBottomInset` не выключаем), окна поднимаются над ней сами,
// шторки с полем отступают на `viewInsets` снизу. Поле в прокручиваемой
// области Flutter долистывает только до строки с курсором — подпись,
// счётчик и нижняя рамка поля, а у многострочного поля и остальные строки,
// остаются под клавиатурой или под кнопками окна. [KeyboardSafeScope]
// долистывает до поля целиком.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// Обёртка всего приложения (в `MaterialApp.builder`): когда поднимается
/// клавиатура или фокус переходит в другое поле при открытой клавиатуре,
/// поле в фокусе долистывается в видимую часть всех прокручиваемых областей
/// вокруг него — целиком, вместе с подписью и счётчиком.
///
/// Поле выше видимого места (длинный редактор) не трогает: тогда виден
/// курсор, как его показывает сам Flutter. Листает без анимации — так же,
/// как Flutter вслед за клавиатурой, поэтому и «Меньше движения» не
/// нарушает. Пока окно поднимается за клавиатурой ([settle]), поле
/// держится на виду; касание экрана это прекращает — листать человек
/// может сразу.
final class KeyboardSafeScope extends StatefulWidget {
  const KeyboardSafeScope({super.key, required this.child});

  final Widget child;

  /// Сколько после поднятия клавиатуры поле держится на виду: окна и
  /// шторки поднимаются вслед за ней с короткой анимацией.
  static const Duration settle = Duration(milliseconds: 400);

  @override
  State<KeyboardSafeScope> createState() => _KeyboardSafeScopeState();
}

final class _KeyboardSafeScopeState extends State<KeyboardSafeScope>
    with WidgetsBindingObserver {
  double _inset = 0;
  bool _scheduled = false;

  /// Время кадра, до которого поле снова долистывается после каждого кадра.
  Duration? _until;

  /// Касание экрана прервало слежение.
  bool _stopped = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addListener(_focusChanged);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_pointer);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeListener(_focusChanged);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_pointer);
    super.dispose();
  }

  double get _viewInset => View.maybeOf(context)?.viewInsets.bottom ?? 0;

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final inset = _viewInset;
    final grew = inset > _inset;
    _inset = inset;
    if (grew) _follow();
  }

  /// Человек коснулся экрана (листает, нажимает) — поле больше не держим.
  void _pointer(PointerEvent event) {
    if (event is PointerDownEvent) _stopped = true;
  }

  void _focusChanged() {
    if (mounted && _viewInset > 0) _follow();
  }

  /// Долистывать до поля после каждого кадра, пока окно или шторка
  /// поднимаются вслед за клавиатурой. Новых кадров не просит.
  void _follow() {
    _until = null;
    _stopped = false;
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback(_frame);
  }

  void _frame(Duration time) {
    _scheduled = false;
    if (!mounted || _stopped) return;
    final until = _until ??= time + KeyboardSafeScope.settle;
    revealFocusedField();
    if (time < until) {
      _scheduled = true;
      SchedulerBinding.instance.addPostFrameCallback(_frame);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Долистывает до поля ввода в фокусе (целиком, если оно помещается в
/// ближайшую прокручиваемую область). Без поля в фокусе ничего не делает.
void revealFocusedField() {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused is! Element || !focused.mounted) return;
  final field = _fieldOf(focused);
  if (field == null) return;
  final box = field.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return;
  final viewport = RenderAbstractViewport.maybeOf(box.parent);
  if (viewport is! RenderBox) return;
  final room = (viewport as RenderBox).size;
  final fits =
      viewport is RenderViewportBase && viewport.axis == Axis.horizontal
          ? box.size.width <= room.width
          : box.size.height <= room.height;
  if (!fits) return;
  box.showOnScreen();
}

/// Элемент поля ввода, в котором стоит фокус [focused]: `TextField` (с
/// подписью и счётчиком) или сам `EditableText`. Фокус не в поле — `null`.
Element? _fieldOf(Element focused) {
  Element? editable = focused.widget is EditableText ? focused : null;
  Element? field;
  var depth = 0;
  focused.visitAncestorElements((Element element) {
    final widget = element.widget;
    if (editable == null) {
      if (widget is EditableText) {
        editable = element;
        return true;
      }
      // Узел фокуса поля — сразу внутри EditableText; ушли дальше —
      // фокус не в поле.
      return ++depth < 12 && widget is! Scrollable;
    }
    if (widget is TextField) {
      field = element;
      return false;
    }
    // Поле без TextField (EditableText сам по себе): до первой прокрутки.
    return widget is! Scrollable;
  });
  return field ?? editable;
}
