// Подписи целиком (ADR-021): слово не рвётся посреди строки, даже на
// узком телефоне и с крупным шрифтом.
//
// - [WholeWordText] — подпись с переносом по словам; если строка
//   кончается внутри слова или подпись не входит в maxLines, масштаб этой
//   подписи уменьшается, пока слова не встанут целиком («Планирование» на
//   320 px и шрифте 200 %).
// - [fitSingleWord] — подпись в одну строку, которая при нехватке места
//   уменьшается целиком (FittedBox), а не обрезается и не переносится.
// - [lineWidth] — замер для раскладок, которые сами выбирают, ставить ли
//   подпись рядом со значением или над ним.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Тире не начинает строку: пробел перед ними — неразрывный, знак
/// остаётся в конце строки при слове перед ним («3 минуты —» / «откроются
/// «Часы»»). Длина текста та же: отметки команд по смещениям не сдвигаются.
String bindDashes(String text) => text.contains(' ')
    ? text.replaceAllMapped(_looseDash, (Match m) => '\u00a0${m[1]}')
    : text;

final RegExp _looseDash = RegExp(r' ([—–])');

/// То же и для «·» — только в абзаце [WholeWordText], не в тексте виджета.
final RegExp _looseMark = RegExp(r' ([—–·])');

const String _dashes = '—–·';

/// Ширина [text] одной строкой стилем [style] из контекста [context]
/// (с масштабом шрифта оттуда же).
double lineWidth(BuildContext context, String text, {TextStyle? style}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: DefaultTextStyle.of(context).style.merge(style),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// Текст, который переносится только между словами: если строка где-то
/// кончается внутри слова (или подпись не входит в [maxLines]), подпись
/// чуть уменьшается — шагами, не меньше [minShrink] от обычного размера, —
/// пока слова не встанут целиком.
///
/// Внутри — обычный [Text]; масштаб подбирается при раскладке (свой
/// RenderObject вокруг абзаца), а не в LayoutBuilder: так подпись можно
/// ставить и туда, где спрашивают собственную ширину (AlertDialog,
/// IntrinsicWidth).
final class WholeWordText extends StatelessWidget {
  const WholeWordText(
    String this.data, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.firstWordOnly = false,
  }) : span = null;

  /// То же для текста из частей разного стиля («Мой» + «Связной»).
  const WholeWordText.rich(
    InlineSpan this.span, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.firstWordOnly = false,
  }) : data = null;

  final String? data;
  final InlineSpan? span;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  /// Название из нескольких слов, которое можно резать многоточием
  /// (сессия, задача): уменьшается, только если в строку не входит даже
  /// первое слово — иначе видно «Добав…» вместо «Добавь…».
  final bool firstWordOnly;

  /// Меньше этой доли от обычного масштаба подпись не сжимается.
  static const double minShrink = 0.5;

  @override
  Widget build(BuildContext context) {
    final text = span == null
        ? Text(
            data!,
            style: style,
            textAlign: textAlign,
            maxLines: maxLines,
            overflow: overflow,
          )
        : Text.rich(
            span!,
            style: style,
            textAlign: textAlign,
            maxLines: maxLines,
            overflow: overflow,
          );
    return _WholeWords(
      base: MediaQuery.textScalerOf(context),
      firstWordOnly: firstWordOnly,
      child: text,
    );
  }
}

final class _WholeWords extends SingleChildRenderObjectWidget {
  const _WholeWords({
    required this.base,
    required this.firstWordOnly,
    required super.child,
  });

  final TextScaler base;
  final bool firstWordOnly;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderWholeWords(base)..firstWordOnly = firstWordOnly;

  @override
  void updateRenderObject(BuildContext context, _RenderWholeWords render) {
    render
      ..base = base
      ..firstWordOnly = firstWordOnly
      // Text под нами вернёт абзацу обычный масштаб — подобрать заново,
      // даже если абзац сам по себе граница раскладки.
      ..markNeedsLayout();
  }
}

/// Перед раскладкой абзаца под собой подбирает ему масштаб шрифта.
final class _RenderWholeWords extends RenderProxyBox {
  _RenderWholeWords(this._base);

  TextScaler _base;

  bool firstWordOnly = false;

  set base(TextScaler value) {
    if (value == _base) return;
    _base = value;
    markNeedsLayout();
  }

  /// Абзац [Text]: сам ребёнок или первый в цепочке одиночных потомков
  /// (MouseRegion выделения и т. п.).
  RenderParagraph? get _paragraph {
    RenderObject? node = child;
    for (var depth = 0; depth < 6 && node != null; depth++) {
      if (node is RenderParagraph) return node;
      RenderObject? only;
      var count = 0;
      node.visitChildren((RenderObject c) {
        only = c;
        count++;
      });
      node = count == 1 ? only : null;
    }
    return null;
  }

  @override
  void performLayout() {
    final paragraph = _paragraph;
    if (paragraph != null) {
      final width = constraints.maxWidth;
      // Менять потомка посреди своей раскладки можно только так.
      invokeLayoutCallback<BoxConstraints>((BoxConstraints _) {
        // Тире — при слове перед ним (bindDashes): абзацу, а не виджету,
        // поэтому текст [Text] остаётся прежним, а строка с «—» не
        // начинается.
        final bound = _bindSpan(paragraph.text);
        if (!identical(bound, paragraph.text)) paragraph.text = bound;
        paragraph.textScaler = !width.isFinite
            ? _base
            : firstWordOnly
                ? firstWordScaler(
                    paragraph.text,
                    width: width,
                    scaler: _base,
                    textDirection: paragraph.textDirection,
                  )
                : wholeWordScaler(
                    paragraph.text,
                    width: width,
                    scaler: _base,
                    textDirection: paragraph.textDirection,
                    maxLines: paragraph.maxLines,
                    ellipsis: paragraph.overflow == TextOverflow.ellipsis,
                  );
      });
    }
    super.performLayout();
  }
}

/// [span] с [bindDashes] во всех частях; без свободных тире — он сам.
InlineSpan _bindSpan(InlineSpan span) {
  if (span is! TextSpan) return span;
  final plain = span.toPlainText(includeSemanticsLabels: false);
  if (!_looseMark.hasMatch(plain)) return span;
  TextSpan bind(TextSpan s) => TextSpan(
        text: s.text?.replaceAllMapped(
          _looseMark,
          (Match m) => '\u00a0${m[1]}',
        ),
        style: s.style,
        recognizer: s.recognizer,
        mouseCursor: s.mouseCursor,
        onEnter: s.onEnter,
        onExit: s.onExit,
        semanticsLabel: s.semanticsLabel,
        semanticsIdentifier: s.semanticsIdentifier,
        locale: s.locale,
        spellOut: s.spellOut,
        children: s.children == null
            ? null
            : <InlineSpan>[
                for (final child in s.children!)
                  child is TextSpan ? bind(child) : child,
              ],
      );
  return bind(span);
}

final RegExp _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);

bool _isWordChar(String text, int index) =>
    index >= 0 && index < text.length && _wordChar.hasMatch(text[index]);

/// Кончается ли какая-нибудь строка разложенного [painter] внутри слова
/// (или начинается ли с тире).
/// [lines] — сколько первых переносов проверять (`null` — все).
bool breaksInsideWord(TextPainter painter, String plain, {int? lines}) {
  final metrics = painter.computeLineMetrics().skip(1);
  for (final line in lines == null ? metrics : metrics.take(lines)) {
    final position = painter.getPositionForOffset(
      Offset(line.left + 0.5, line.baseline - line.ascent / 2),
    );
    final start = painter.getLineBoundary(position).start;
    if (_isWordChar(plain, start - 1) && _isWordChar(plain, start)) {
      return true;
    }
    // Строка с тире: слово с «—» после неразрывного пробела не влезло в
    // строку целиком — тоже уменьшить.
    if (start > 0 && start < plain.length && _dashes.contains(plain[start])) {
      return true;
    }
  }
  return false;
}

/// Масштаб шрифта для [span] шириной [width]: обычный [scaler], если
/// слова и так встают целиком и в [maxLines] строк, иначе — меньше,
/// шагами по 8 %, но не меньше [WholeWordText.minShrink] от обычного.
///
/// С [ellipsis] лишние строки не повод сжимать: текст обрежется «…».
/// Проверяются только видимые переносы и перенос в первую скрытую
/// строку — он не должен приходиться посреди слова.
TextScaler wholeWordScaler(
  InlineSpan span, {
  required double width,
  required TextScaler scaler,
  TextDirection textDirection = TextDirection.ltr,
  int? maxLines,
  bool ellipsis = false,
}) {
  final plain = span.toPlainText(includeSemanticsLabels: false);
  const probe = 14.0;
  final current = scaler.scale(probe) / probe;
  var factor = 1.0;
  var effective = scaler;
  final cut = ellipsis && maxLines != null;
  final painter = TextPainter(
    text: span,
    textDirection: textDirection,
    maxLines: cut ? null : maxLines,
  );
  try {
    while (true) {
      painter
        ..textScaler = effective
        ..layout(maxWidth: width);
      final fits = cut
          ? !breaksInsideWord(painter, plain, lines: maxLines)
          : !breaksInsideWord(painter, plain) && !painter.didExceedMaxLines;
      if (fits) {
        return effective;
      }
      if (factor <= WholeWordText.minShrink) return effective;
      factor = math.max(factor * 0.92, WholeWordText.minShrink);
      effective = TextScaler.linear(current * factor);
    }
  } finally {
    painter.dispose();
  }
}

/// Масштаб, при котором первое слово [span] входит в [width] (не меньше
/// [WholeWordText.minShrink] от обычного); входит и так — [scaler].
TextScaler firstWordScaler(
  InlineSpan span, {
  required double width,
  required TextScaler scaler,
  TextDirection textDirection = TextDirection.ltr,
}) {
  final plain = span.toPlainText(includeSemanticsLabels: false).trim();
  final first = plain.split(RegExp(r'\s')).first;
  if (first.isEmpty) return scaler;
  TextStyle? style = span.style;
  span.visitChildren((InlineSpan child) {
    if (child is TextSpan && (child.text?.isNotEmpty ?? false)) {
      style = (style ?? const TextStyle()).merge(child.style);
      return false;
    }
    return true;
  });
  final painter = TextPainter(
    text: TextSpan(text: first, style: style),
    textDirection: textDirection,
    textScaler: scaler,
    maxLines: 1,
  )..layout();
  final need = painter.width;
  painter.dispose();
  if (need <= width) return scaler;
  const probe = 14.0;
  final current = scaler.scale(probe) / probe;
  final factor = math.max(width / need * 0.98, WholeWordText.minShrink);
  return TextScaler.linear(current * factor);
}

/// Подпись в одну строку: не помещается — уменьшается целиком.
Widget fitSingleWord(
  String text, {
  Key? key,
  TextStyle? style,
  AlignmentGeometry alignment = AlignmentDirectional.centerStart,
  TextAlign? textAlign,
}) =>
    FittedBox(
      key: key,
      fit: BoxFit.scaleDown,
      alignment: alignment,
      child: Text(
        text,
        style: style,
        textAlign: textAlign,
        maxLines: 1,
        softWrap: false,
      ),
    );
