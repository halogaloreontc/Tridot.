import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/scenario/command_spans.dart';
import '../assistant_theme.dart';

/// Части фразы, которые распознали навыки ([AssistantController.highlight]).
typedef CommandHighlighter = List<CommandSpan> Function(String text);

/// Как показывать распознанные части фразы (ADR-027).
enum CommandSpanMode {
  /// Обычный текст: в ленте команда выглядит как любая фраза — без
  /// моноширинного шрифта и цветных чисел.
  plain,

  /// Мягко: в поле ввода во время набора распознанный глагол — цветом
  /// `cmdTint` и полужирным; срок, числа, метки и адрес — как текст.
  subtle,
}

/// Стиль распознанной части фразы (ADR-027): только шрифт текста, без
/// моноширинного шрифта. В режиме [CommandSpanMode.subtle] выделен лишь
/// глагол команды.
TextStyle commandSpanStyle(
  CommandSpanKind kind,
  TextStyle base, {
  required AppPalette colors,
  CommandSpanMode mode = CommandSpanMode.subtle,
}) {
  if (mode == CommandSpanMode.plain || kind != CommandSpanKind.verb) {
    return base;
  }
  return base.copyWith(color: colors.cmdTint, fontWeight: FontWeight.w600);
}

/// [text] с подсвеченными [spans]. [composing] — набираемое слово
/// клавиатуры: оно подчёркивается, как в обычном поле ввода.
TextSpan highlightedCommand(
  String text,
  List<CommandSpan> spans,
  TextStyle base, {
  TextRange? composing,
  required AppPalette colors,
  CommandSpanMode mode = CommandSpanMode.subtle,
}) {
  final bounds = <int>{0, text.length};
  for (final span in spans) {
    if (span.start < text.length) bounds.add(span.start);
    if (span.end <= text.length) bounds.add(span.end);
  }
  final hasComposing = composing != null &&
      composing.isValid &&
      !composing.isCollapsed &&
      composing.end <= text.length;
  if (hasComposing) {
    bounds
      ..add(composing.start)
      ..add(composing.end);
  }
  final cuts = bounds.toList()..sort();
  final children = <TextSpan>[];
  var index = 0;
  for (var i = 0; i + 1 < cuts.length; i++) {
    final start = cuts[i];
    final end = cuts[i + 1];
    if (start >= end) continue;
    while (index < spans.length && spans[index].end <= start) {
      index++;
    }
    final inside = index < spans.length && spans[index].start <= start
        ? spans[index]
        : null;
    final underline =
        hasComposing && start >= composing.start && end <= composing.end;
    TextStyle styled(TextStyle style) => underline
        ? style.merge(const TextStyle(decoration: TextDecoration.underline))
        : style;
    final piece = text.substring(start, end);
    if (inside == null) {
      children.add(TextSpan(text: piece, style: styled(base)));
      continue;
    }
    final style = commandSpanStyle(
      inside.kind,
      base,
      colors: colors,
      mode: mode,
    );
    children.add(TextSpan(text: piece, style: styled(style)));
  }
  return TextSpan(style: base, children: children);
}

/// Поле ввода команды с мягкой подсветкой распознанного (ADR-027). Разбор идёт не
/// на каждую букву, а через [delay] после последней правки; пока он не
/// готов, остаётся прежняя подсветка, если текст только дописан в конец.
final class CommandInputController extends TextEditingController {
  CommandInputController({
    this.highlighter,
    this.delay = const Duration(milliseconds: 180),
  }) {
    addListener(_changed);
  }

  /// Кто размечает фразу; `null` — без подсветки.
  CommandHighlighter? highlighter;

  final Duration delay;

  Timer? _timer;
  String _spansFor = '';
  List<CommandSpan> _spans = const <CommandSpan>[];

  /// Подсветка для текущего текста (для тестов).
  List<CommandSpan> get spans => _current;

  List<CommandSpan> get _current {
    final current = text;
    if (_spans.isEmpty) return const <CommandSpan>[];
    if (current == _spansFor) return _spans;
    if (current.startsWith(_spansFor)) return _spans;
    return const <CommandSpan>[];
  }

  void _changed() {
    final current = text;
    if (current == _spansFor) return;
    _timer?.cancel();
    if (current.trim().isEmpty || highlighter == null) {
      _timer = null;
      _spansFor = current;
      _spans = const <CommandSpan>[];
      return;
    }
    _timer = Timer(delay, _recompute);
  }

  void _recompute() {
    _timer = null;
    final current = text;
    final highlight = highlighter;
    List<CommandSpan> found;
    try {
      found = highlight == null ? const <CommandSpan>[] : highlight(current);
    } on Object {
      found = const <CommandSpan>[];
    }
    final changed = _spansFor != current || !_same(found, _spans);
    _spansFor = current;
    _spans = found;
    if (changed) notifyListeners();
  }

  static bool _same(List<CommandSpan> a, List<CommandSpan> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final spans = _current;
    if (spans.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final current = text;
    return highlightedCommand(
      current,
      CommandSpans.normalize(spans, current.length),
      style ?? const TextStyle(),
      colors: context.colors,
      composing:
          withComposing && value.isComposingRangeValid ? value.composing : null,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    removeListener(_changed);
    super.dispose();
  }
}
