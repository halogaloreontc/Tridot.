// Запасной слой понимания (ADR-041): у каждой команды, которой размечен
// корпус, есть описание для подсказки «Похоже, вы хотите …?» в
// tools/intent_model/labels.yaml. Иначе «Выпуск модели понимания» упадёт на
// сборке — ловим это сразу, в обычных тестах. Правило метки — то же, что
// corpus_label в tools/intent_model/data.py.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const Map<String, String> _taskIntents = <String, String>{
  'createTask': 'task.create',
  'listTasks': 'task.list',
  'completeTask': 'task.complete',
  'rescheduleTask': 'task.reschedule',
  'rescheduleMany': 'task.rescheduleMany',
  'completeMany': 'task.completeMany',
};

String? _label(Map<String, dynamic> row) {
  if (row['status'] == 'known_gap' || row['after'] != null) return null;
  final connector = (row['connector'] as String?) ?? 'tasks';
  final intent = row['intent'] as String? ?? '';
  // Навык «Пароли» модель не видит никогда.
  if (connector == 'passwords' || row['route'] == 'passwords') return null;
  if (intent == 'unknown') return null;
  if (connector == 'tasks') return 'tasks:${_taskIntents[intent] ?? intent}';
  return '$connector:$intent';
}

Set<String> _described() {
  final keys = <String>{};
  final line = RegExp(r'^\s+"([^"]+)":\s*\S');
  for (final text in File(
    'tools/intent_model/labels.yaml',
  ).readAsLinesSync()) {
    final match = line.firstMatch(text);
    if (match != null) keys.add(match.group(1)!);
  }
  return keys;
}

void main() {
  test('у каждой команды корпуса есть описание в labels.yaml', () {
    final described = _described();
    expect(described, isNotEmpty);
    final missing = <String, String>{};
    final files = Directory('test/corpus')
        .listSync()
        .whereType<File>()
        .where((File f) => f.path.endsWith('.jsonl'))
        .toList()
      ..sort((File a, File b) => a.path.compareTo(b.path));
    for (final file in files) {
      for (final raw in file.readAsLinesSync()) {
        final text = raw.trim();
        if (text.isEmpty || text.startsWith('//')) continue;
        final row = jsonDecode(text) as Map<String, dynamic>;
        final label = _label(row);
        if (label != null && !described.contains(label)) {
          missing.putIfAbsent(label, () => '${file.path}: ${row['id']}');
        }
      }
    }
    expect(
      missing,
      isEmpty,
      reason: 'Допишите в tools/intent_model/labels.yaml строку '
          '"<метка>": <что сделать> для каждой метки (пример строки рядом)',
    );
  });
}
