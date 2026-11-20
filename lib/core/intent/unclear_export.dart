import 'dart:convert';

import 'intent_fallback.dart' show intentPrivate;
import 'intent_memory.dart';

/// «Непонятые фразы → Поделиться для улучшения» (ADR-045, п. 8): файл
/// JSONL, по строке на фразу. Пользователь видит ровно эти строки и может
/// убрать любую до отправки; само ничего не отправляется.
///
/// Строка: `{"text": …, "status": "unknown|accepted|rejected", "label": …,
/// "date": "2026-11-20"}` — только фраза, что с ней стало, предложенная
/// команда и день (без времени). Разработчик пишет по ним синтетические
/// аналоги для корпуса; сами фразы модель не учат.
abstract final class UnclearExport {
  /// Строки для [phrases] в том же порядке (новые первыми). Приватное
  /// (пароли, PIN, коды, логины) — вторая проверка после журнала:
  /// [blocks] и [intentPrivate] всегда.
  static List<String> lines(
    List<UnclearPhrase> phrases, {
    bool Function(String text)? blocks,
  }) =>
      <String>[
        for (final phrase in phrases)
          if (phrase.text.trim().isNotEmpty &&
              !intentPrivate(phrase.text) &&
              !(blocks?.call(phrase.text) ?? false))
            line(phrase),
      ];

  /// Одна строка JSONL.
  static String line(UnclearPhrase phrase) => jsonEncode(<String, Object?>{
        'text': phrase.text.replaceAll(RegExp(r'\s+'), ' ').trim(),
        'status': phrase.kind.name,
        if (phrase.label != null) 'label': phrase.label,
        'date': _day(phrase.at.toLocal()),
      });

  /// Текст файла: строки через перевод строки, в конце — перевод строки.
  static String text(List<String> lines) =>
      lines.isEmpty ? '' : '${lines.join('\n')}\n';

  /// Имя файла: `tridot-unclear-2026-11-20.jsonl`.
  static String fileName(DateTime now) => 'tridot-unclear-${_day(now)}.jsonl';

  static String _day(DateTime at) => '${at.year.toString().padLeft(4, '0')}-'
      '${at.month.toString().padLeft(2, '0')}-'
      '${at.day.toString().padLeft(2, '0')}';
}
