// Разбирает фразы текущим ScenarioParser и печатает результат.
//
// Вход (stdin): JSON Lines {"id": "...", "text": "...", "now": "2026-11-02T16:30"}.
// Выход (stdout): JSON Lines {"id", "intent", "title", "targetQuery", "due",
// "precision", "issue", "titleIssue", "projects"} в формате регрессионного
// корпуса (docs/CORPUS.md).
//
// Запуск из корня проекта: dart run tool/parse_phrases.dart < phrases.jsonl
import 'dart:convert';
import 'dart:io';

import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';

/// «Сейчас» по умолчанию — как в test/scenario_corpus_test.dart.
final DateTime defaultNow = DateTime(2026, 11, 2, 16, 30);

Future<void> main() => processLines(
      (Map<String, dynamic> input, DateTime now) =>
          parsedFields(input['text'] as String, now),
    );

/// Читает JSON Lines из stdin и печатает `{"id", ...convert(строка)}`.
Future<void> processLines(
  Map<String, Object?> Function(Map<String, dynamic> input, DateTime now)
      convert,
) async {
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final input = jsonDecode(line) as Map<String, dynamic>;
    final nowText = input['now'] as String?;
    final now = nowText == null ? defaultNow : DateTime.parse(nowText);
    Map<String, Object?> result;
    try {
      result = convert(input, now);
    } on Object catch (error) {
      // Одна сломанная фраза не должна ронять проверку остальных.
      result = <String, Object?>{'error': '$error'};
    }
    stdout.writeln(jsonEncode(<String, Object?>{'id': input['id'], ...result}));
  }
}

/// Разбор фразы ScenarioParser в формате корпуса.
Map<String, Object?> parsedFields(String text, DateTime now) {
  final parsed = ScenarioParser(clock: FixedClock(now)).parse(text);
  final due = parsed.dueAt;
  return <String, Object?>{
    'intent': parsed.intent.name,
    'title': parsed.title,
    'targetQuery': parsed.targetQuery,
    'due': due == null
        ? null
        : _formatDue(due, parsed.duePrecision ?? DuePrecision.dateTime),
    'precision': parsed.duePrecision?.name,
    'issue': parsed.dueIssue.name,
    'titleIssue': parsed.titleIssue.name,
    'projects': parsed.projects,
  };
}

String _formatDue(DateTime due, DuePrecision precision) {
  String two(int v) => v.toString().padLeft(2, '0');
  final date = '${due.year}-${two(due.month)}-${two(due.day)}';
  if (precision == DuePrecision.date) return date;
  return '${date}T${two(due.hour)}:${two(due.minute)}';
}
