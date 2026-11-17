// Словарь слов команд для исправления опечаток (TypoFix) — из корпуса
// фраз test/corpus/*.jsonl: слова понятых фраз (не intent: unknown, не
// known_gap) без слов названий и запросов (title, targetQuery, поля form
// q/text/target/label/place) — то, чем люди командуют, а не то, о чём.
// Только кириллица, от четырёх букв; число — сколько раз слово встретилось.
// Не входят строки typos.jsonl (там опечатки нарочно) и слова, которые сами
// похожи на опечатку более частого слова словаря («пеернеси» —
// «перенеси»): иначе опечатка стала бы «известным» словом.
//
// Запуск из корня проекта после правки корпуса:
//   dart run tool/gen_lexicon.dart
// Тест test/tool/command_lexicon_test.dart сверяет файл с корпусом.
import 'dart:convert';
import 'dart:io';

import 'package:local_assistant/core/connectors/utterance.dart';

const String output = 'lib/core/scenario/command_lexicon.g.dart';

void main() {
  File(output).writeAsStringSync(generate());
  stdout.writeln('Записано: $output');
}

final RegExp _token = RegExp('[a-zа-я0-9]+');
final RegExp _cyrillic = RegExp(r'^[а-я]{4,}$');

Iterable<String> _words(String text) => _token
    .allMatches(text.toLowerCase().replaceAll('ё', 'е'))
    .map((Match m) => m.group(0)!);

/// Слова и их частоты по корпусу.
Map<String, int> lexicon() {
  final counts = <String, int>{};
  final files = Directory('test/corpus')
      .listSync()
      .whereType<File>()
      .where((File f) => f.path.endsWith('.jsonl'))
      .toList()
    ..sort((File a, File b) => a.path.compareTo(b.path));
  for (final file in files) {
    if (file.uri.pathSegments.last == 'typos.jsonl') continue;
    for (final raw in file.readAsLinesSync()) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('//')) continue;
      final row = jsonDecode(line) as Map<String, dynamic>;
      if (row['intent'] == 'unknown' || row['status'] == 'known_gap') {
        continue;
      }
      final skip = <String>{};
      for (final key in <String>['title', 'targetQuery']) {
        if (row[key] case final String value) skip.addAll(_words(value));
      }
      if (row['form'] case final Map<String, dynamic> form) {
        for (final key in <String>['q', 'text', 'target', 'label', 'place']) {
          if (form[key] case final String value) skip.addAll(_words(value));
        }
      }
      for (final word in _words(row['text'] as String)) {
        if (skip.contains(word) || !_cyrillic.hasMatch(word)) continue;
        counts[word] = (counts[word] ?? 0) + 1;
      }
    }
  }
  // Опечатки из корпуса («пеернеси», «поставни»): одна правка до слова,
  // которое встречается втрое чаще.
  final typos = <String>{
    for (final MapEntry(key: word, value: count) in counts.entries)
      for (final MapEntry(key: other, value: otherCount) in counts.entries)
        if (otherCount >= 3 * count &&
            other != word &&
            Utterance.isTypoOf(word, other))
          word,
  };
  counts.removeWhere((String word, int _) => typos.contains(word));
  return counts;
}

String generate() {
  final counts = lexicon();
  final words = counts.keys.toList()..sort();
  final buffer = StringBuffer()
    ..writeln('// Сгенерировано tool/gen_lexicon.dart из test/corpus/*.jsonl.')
    ..writeln('// Не править вручную: правьте корпус и запустите генератор.')
    ..writeln()
    ..writeln('/// Слова команд и сроков из корпуса и сколько раз они '
        'встретились.')
    ..writeln('const Map<String, int> commandLexicon = <String, int>{');
  for (final word in words) {
    buffer.writeln("  '$word': ${counts[word]},");
  }
  buffer.writeln('};');
  return buffer.toString();
}
