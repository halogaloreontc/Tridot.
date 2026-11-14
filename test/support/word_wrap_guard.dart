// Проверка «слово не рвётся посреди строки» (ADR-021): обходит все
// RenderParagraph на экране, заново раскладывает их текст той же ширины и
// тем же стилем и ищет три беды:
//
// - BREAK — строка кончается внутри слова («Напомнит» / «ь»): буква или
//   цифра по обе стороны переноса. Дефис, мягкий перенос и «/» — честные
//   места переноса, их не трогаем; адрес почты, ссылка, имя файла — это
//   данные, а не подписи, они на узком экране переносятся где придётся;
// - CUT — текст не уместился в maxLines и обрезан, а это подпись из
//   одного слова: «Напом…» вместо «Напомнить». Текст из нескольких слов
//   (название задачи, сессии) многоточием резать можно — так задумано;
//   кроме подписей из списка [whole]: их режут — тоже беда («Поиск по
//   зада…»);
// - CLIP — строка без переноса (softWrap: false) шире своего места и
//   срезана краем.
//
// Параграфы с WidgetSpan пропускаем: их ширины зависят от вложенных
// виджетов. Исключения — явным списком [allow] (ключ предка или сам
// текст), каждое с комментарием в тесте.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

final RegExp _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);
final RegExp _space = RegExp(r'\s');

bool _isWordChar(String text, int index) =>
    index >= 0 && index < text.length && _wordChar.hasMatch(text[index]);

/// Адрес почты, ссылка, путь, имя файла: такой «токен» без пробелов на
/// узком экране переносится где придётся — это данные, а не подпись.
/// Только настоящие формы: «@», «://», «имя.расш», «_», «\\», путь от
/// корня или «~». Просто «/» между словами («Диалог/Документ») — подпись:
/// перенос у самого «/» честный, а внутри слов — беда.
final RegExp _machine = RegExp(r'[@_\\]|\w\.\w|://|^[/~]');

bool _isMachineToken(String text, int at) {
  var from = at;
  var to = at;
  while (from > 0 && !_space.hasMatch(text[from - 1])) {
    from--;
  }
  while (to < text.length && !_space.hasMatch(text[to])) {
    to++;
  }
  return _machine.hasMatch(text.substring(from, to));
}

/// Сколько слов в [text] (через пробелы).
int _words(String text) =>
    text.trim().split(_space).where((String w) => w.isNotEmpty).length;

/// Нашлось ли у [paragraph] среди предков (по дереву элементов) что-то из
/// [allow]: строковый ключ или ключ-строка значения.
String? _keyPath(
  RenderParagraph paragraph,
  Set<String> allow, {
  required void Function() onAllowed,
}) {
  final creator = paragraph.debugCreator;
  if (creator is! DebugCreator) return null;
  final keys = <String>[];
  void look(Element element) {
    final key = element.widget.key;
    if (key is ValueKey<String>) {
      keys.add(key.value);
      if (allow.contains(key.value)) onAllowed();
    }
  }

  look(creator.element);
  creator.element.visitAncestorElements((Element e) {
    look(e);
    return true;
  });
  return keys.isEmpty ? null : keys.take(3).join(' < ');
}

/// Все параграфы под всеми видами.
Iterable<RenderParagraph> _paragraphs(WidgetTester tester) sync* {
  final stack = <RenderObject>[
    for (final view in tester.binding.renderViews) view,
  ];
  while (stack.isNotEmpty) {
    final node = stack.removeLast();
    if (node is RenderParagraph) yield node;
    node.visitChildren(stack.add);
  }
}

/// Стиль первого фрагмента текста (для замера первого слова).
TextStyle? _firstStyle(InlineSpan span) {
  TextStyle? style = span.style;
  span.visitChildren((InlineSpan child) {
    if (child is TextSpan && (child.text?.isNotEmpty ?? false)) {
      style = (style ?? const TextStyle()).merge(child.style);
      return false;
    }
    return true;
  });
  return style;
}

bool _hasWidgetSpan(InlineSpan span) {
  var found = false;
  span.visitChildren((InlineSpan child) {
    if (child is PlaceholderSpan) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

/// Нарушения на текущем экране; пустой список — всё в порядке.
///
/// [allow] — ключи предков (`ValueKey<String>`) или тексты целиком,
/// которые проверять не надо; [whole] — подписи из нескольких слов,
/// которые нельзя и обрезать многоточием.
List<String> midWordBreaks(
  WidgetTester tester, {
  Set<String> allow = const <String>{},
  Set<String> whole = const <String>{},
}) {
  final out = <String>[];
  final seen = <String>{};
  for (final p in _paragraphs(tester)) {
    if (!p.attached || !p.hasSize || p.size.isEmpty) continue;
    if (_hasWidgetSpan(p.text)) continue;
    final text = p.text.toPlainText(includeSemanticsLabels: false);
    if (text.trim().isEmpty || allow.contains(text)) continue;
    var allowed = false;
    final path = _keyPath(p, allow, onAllowed: () => allowed = true);
    if (allowed) continue;

    final constraints = p.constraints;
    final ellipsis = p.overflow == TextOverflow.ellipsis;
    final painter = TextPainter(
      text: p.text,
      textAlign: p.textAlign,
      textDirection: p.textDirection,
      textScaler: p.textScaler,
      maxLines: p.maxLines,
      ellipsis: ellipsis ? '…' : null,
      locale: p.locale,
      strutStyle: p.strutStyle,
      textWidthBasis: p.textWidthBasis,
      textHeightBehavior: p.textHeightBehavior,
    );
    final wrap = p.softWrap || ellipsis;
    painter.layout(
      minWidth: constraints.minWidth,
      maxWidth: wrap ? constraints.maxWidth : double.infinity,
    );
    final where = '«$text» (место ${constraints.maxWidth.toStringAsFixed(1)}'
        ', масштаб ${p.textScaler.scale(10) / 10}'
        '${path == null ? '' : ', $path'})';

    final problems = <String>[];
    // BREAK: начало каждой строки, кроме первой.
    final lines = painter.computeLineMetrics();
    for (final line in lines.skip(1)) {
      final y = line.baseline - line.ascent / 2;
      final pos = painter.getPositionForOffset(
        Offset(line.left + 0.5, y),
      );
      final start = painter.getLineBoundary(pos).start;
      if (start <= 0 || start >= text.length) continue;
      if (_isWordChar(text, start - 1) &&
          _isWordChar(text, start) &&
          !_isMachineToken(text, start)) {
        problems.add(
          'BREAK «${text.substring(0, start)}|${text.substring(start)}»',
        );
        break;
      }
    }
    // CUT: подпись из одного слова не уместилась в maxLines.
    if (painter.didExceedMaxLines &&
        (_words(text) == 1 || whole.contains(text))) {
      problems.add('CUT (не уместилось в ${p.maxLines} стр.)');
    } else if (painter.didExceedMaxLines && problems.isEmpty) {
      // Не уместилось в maxLines: перенос в скрытую строку тоже бывает
      // посреди слова («Напоми|нания включены» при maxLines: 1). Раскладка
      // без предела строк: граница последней видимой строки.
      final full = TextPainter(
        text: p.text,
        textAlign: p.textAlign,
        textDirection: p.textDirection,
        textScaler: p.textScaler,
        locale: p.locale,
        strutStyle: p.strutStyle,
        textWidthBasis: p.textWidthBasis,
        textHeightBehavior: p.textHeightBehavior,
      )..layout(maxWidth: constraints.maxWidth);
      final all = full.computeLineMetrics();
      final visible = p.maxLines ?? all.length;
      if (visible < all.length) {
        final line = all[visible];
        final pos = full.getPositionForOffset(
          Offset(line.left + 0.5, line.baseline - line.ascent / 2),
        );
        final start = full.getLineBoundary(pos).start;
        if (start > 0 &&
            start < text.length &&
            _isWordChar(text, start - 1) &&
            _isWordChar(text, start) &&
            !_isMachineToken(text, start)) {
          problems.add(
            'BREAK в скрытую строку «${text.substring(0, start)}|'
            '${text.substring(start)}»',
          );
        }
      }
      // Видна хотя бы первая слово целиком? Иначе подпись не прочесть.
      final first = text.trim().split(_space).first;
      final word = TextPainter(
        text: TextSpan(text: first, style: _firstStyle(p.text)),
        textDirection: p.textDirection,
        textScaler: p.textScaler,
        locale: p.locale,
      )..layout();
      if (word.width > constraints.maxWidth + 0.5 &&
          !_machine.hasMatch(first)) {
        problems.add(
          'CUT (первое слово «$first» не помещается: '
          '${word.width.toStringAsFixed(1)})',
        );
      }
      word.dispose();
      full.dispose();
    }
    // CLIP: строка без переноса шире места.
    if (!wrap &&
        constraints.maxWidth.isFinite &&
        painter.width > constraints.maxWidth + 0.5) {
      problems.add(
        'CLIP (нужно ${painter.width.toStringAsFixed(1)})',
      );
    }
    painter.dispose();
    for (final problem in problems) {
      final line = '$problem: $where';
      if (seen.add(line)) out.add(line);
    }
  }
  return out;
}

/// Падает, если на экране есть подпись, разорванная посреди слова.
void expectWholeWords(
  WidgetTester tester, {
  Set<String> allow = const <String>{},
  Set<String> whole = const <String>{},
  String label = '',
}) {
  final found = midWordBreaks(tester, allow: allow, whole: whole);
  if (found.isEmpty) return;
  fail(
    'Слова рвутся посреди строки${label.isEmpty ? '' : ' ($label)'}:\n'
    '${found.map((String s) => '  - $s').join('\n')}',
  );
}

/// Размер окна телефона [width] × [height] и масштаб шрифта [scale].
void setPhone(
  WidgetTester tester, {
  required double width,
  double height = 800,
  double scale = 1.0,
}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}
