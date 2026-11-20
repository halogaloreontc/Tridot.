// Экранная клавиатура в тестах виджетов (ADR-044): поле в фокусе должно
// быть видно над ней целиком, а экран — без переполнения.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Высота клавиатуры телефона в логических точках.
const double keyboardHeight = 300;

/// Размеры экрана, на которых проверяется правило: обычный телефон и
/// маленький (клавиатура закрывает почти половину).
const List<Size> keyboardScreens = <Size>[Size(390, 844), Size(360, 640)];

/// Экран [size] с плотностью 1 (точка = пиксель); сбрасывается в конце
/// теста.
void setPhoneScreen(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Открывает клавиатуру высотой [height] (или закрывает — 0).
Future<void> setKeyboard(WidgetTester tester, double height) async {
  tester.view.viewInsets = FakeViewPadding(bottom: height);
  await tester.pumpAndSettle();
}

/// Долистывает до [field]: поле в ленивом списке ниже края ещё не
/// построено — тогда листает первую вертикальную прокрутку на экране.
Future<void> scrollToField(WidgetTester tester, Finder field) async {
  if (field.evaluate().isNotEmpty) return;
  final scrollable = find
      .byWidgetPredicate(
        (Widget w) =>
            w is Scrollable &&
            axisDirectionToAxis(w.axisDirection) == Axis.vertical,
      )
      .hitTestable();
  if (scrollable.evaluate().isEmpty) return;
  await tester.scrollUntilVisible(field, 120, scrollable: scrollable.first);
  await tester.pumpAndSettle();
}

/// Ставит фокус в поле [field] (TextField, TextFormField или EditableText)
/// так, как это делает человек: долистывает до него, нажимает — и
/// поднимается клавиатура. Потом проверяет, что поле целиком над
/// клавиатурой и на экране, а переполнений нет.
///
/// Видимое место — над клавиатурой и внутри прокручиваемых областей вокруг
/// поля. Поле выше него (многострочный редактор) — тогда видна строка с
/// курсором.
Future<void> expectFieldAboveKeyboard(
  WidgetTester tester,
  Finder field, {
  String? reason,
}) async {
  final what = reason ?? field.describeMatch(Plurality.one);
  tester.view.viewInsets = FakeViewPadding.zero;
  await tester.pumpAndSettle();
  await scrollToField(tester, field);
  expect(field, findsOneWidget, reason: what);
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  await tester.showKeyboard(field);
  await tester.pump();
  await setKeyboard(tester, keyboardHeight);
  expect(tester.takeException(), isNull, reason: '$what: переполнение');

  final editable = find
      .descendant(
        of: field,
        matching: find.byType(EditableText),
        matchRoot: true,
      )
      .first;
  final state = tester.state<EditableTextState>(editable);
  expect(state.widget.focusNode.hasFocus, isTrue, reason: '$what: фокус');

  final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
  final keyboardTop = screen.height - keyboardHeight;
  // Видимое место: над клавиатурой и внутри всех прокручиваемых областей
  // вокруг поля (то, что ушло за край ленты, не видно, хотя и не под
  // клавиатурой).
  var room = Rect.fromLTRB(0, 0, screen.width, keyboardTop);
  RenderObject? node = tester.renderObject(field).parent;
  while (node != null) {
    if (node is RenderAbstractViewport && node is RenderBox) {
      final box = node as RenderBox;
      room = room.intersect(
        MatrixUtils.transformRect(
          box.getTransformTo(null),
          Offset.zero & box.size,
        ),
      );
    }
    node = node.parent;
  }
  final rect = tester.getRect(field);
  bool inside(Rect r) =>
      r.top >= room.top - .5 &&
      r.bottom <= room.bottom + .5 &&
      r.left >= room.left - .5 &&
      r.right <= room.right + .5;
  if (rect.height <= room.height) {
    expect(
      inside(rect),
      isTrue,
      reason: '$what: поле $rect, а видно только $room '
          '(клавиатура с $keyboardTop)',
    );
  } else {
    // Поле выше видимого места (многострочный редактор): видна строка с
    // курсором.
    final render = state.renderEditable;
    final caret = MatrixUtils.transformRect(
      render.getTransformTo(null),
      render.getLocalRectForCaret(render.selection!.extent),
    );
    expect(
      inside(caret),
      isTrue,
      reason: '$what: курсор $caret, а видно только $room',
    );
  }

  // Поле не закрыто другим слоем (панелью снизу, шапкой): нажатие в
  // середину видимой части попадает в само поле.
  final visible = rect.intersect(room);
  final hit = tester.hitTestOnBinding(visible.center);
  final box = tester.renderObject(field);
  expect(
    hit.path.any((entry) => entry.target == box),
    isTrue,
    reason: '$what: середину поля закрывает другой слой',
  );

  await setKeyboard(tester, 0);
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}
