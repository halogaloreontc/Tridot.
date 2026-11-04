// Разбирает фразы текущим ScenarioParser и печатает результат.
//
// Вход (stdin): JSON Lines {"id": "...", "text": "...", "now": "2026-11-02T16:30"}.
// Выход (stdout): JSON Lines {"id", "intent", "title", "due", "precision",
// "issue", "titleIssue"} в формате регрессионного корпуса (docs/CORPUS.md).
//
// Запуск из корня проекта: dart run tool/parse_phrases.dart < phrases.jsonl
import 'dart:convert';
import 'dart:io';

import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';

final DateTime _defaultNow = DateTime(2026, 11, 2, 16, 30);

Future<void> main() async {
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final input = jsonDecode(line) as Map<String, dynamic>;
    final nowText = input['now'] as String?;
    final now = nowText == null ? _defaultNow : DateTime.parse(nowText);
    final parsed =
        ScenarioParser(clock: FixedClock(now)).parse(input['text'] as String);
    final due = parsed.dueAt;
    stdout.writeln(
      jsonEncode(<String, Object?>{
        'id': input['id'],
        'intent': parsed.intent.name,
        'title': parsed.title,
        'due': due == null ? null : _formatDue(due, parsed.duePrecision),
        'precision': due == null ? null : parsed.duePrecision.name,
        'issue': parsed.dueIssue.name,
        'titleIssue': parsed.titleIssue.name,
      }),
    );
  }
}

String _formatDue(DateTime due, DuePrecision precision) {
  String two(int v) => v.toString().padLeft(2, '0');
  final date = '${due.year}-${two(due.month)}-${two(due.day)}';
  if (precision == DuePrecision.date) return date;
  return '${date}T${two(due.hour)}:${two(due.minute)}';
}
