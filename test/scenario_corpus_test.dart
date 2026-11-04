import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';

/// Регрессионный корпус фраз: test/corpus/*.jsonl, формат — docs/CORPUS.md.
///
/// Каждая строка — одна фраза и ожидаемый разбор. Поля, которых нет в строке,
/// не проверяются; явный `null` проверяется как «должно быть пусто».
/// Строки со `status: known_gap` описывают ещё не поддержанные фразы: тест
/// падает, если такая фраза вдруг начала разбираться правильно, — тогда её
/// нужно перевести в `active`.
void main() {
  final corpusDir = Directory('test/corpus');
  final files = corpusDir
      .listSync()
      .whereType<File>()
      .where((File f) => f.path.endsWith('.jsonl'))
      .toList()
    ..sort((File a, File b) => a.path.compareTo(b.path));

  final seenIds = <String, String>{};
  final cases = <_Case>[];
  for (final file in files) {
    final name = file.uri.pathSegments.last;
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty || line.startsWith('//')) continue;
      final location = '$name:${i + 1}';
      final json = jsonDecode(line) as Map<String, dynamic>;
      final unknown = json.keys.toSet().difference(_allowedKeys);
      if (unknown.isNotEmpty) {
        throw FormatException('$location: неизвестные поля $unknown');
      }
      final id = json['id'] as String;
      final previous = seenIds[id];
      if (previous != null) {
        throw FormatException('$location: id «$id» уже есть в $previous');
      }
      seenIds[id] = location;
      cases.add(_Case(location, json));
    }
  }

  test('корпус не пуст', () => expect(cases, isNotEmpty));

  for (final file in files) {
    final name = file.uri.pathSegments.last;
    group(name, () {
      for (final c in cases.where((_Case c) => c.location.startsWith(name))) {
        test('${c.id}: ${c.text}', () {
          final mismatches = c.check();
          if (c.isKnownGap) {
            expect(
              mismatches,
              isNotEmpty,
              reason: '${c.location}: фраза уже разбирается верно — '
                  'смените status на active',
            );
          } else {
            expect(mismatches, isEmpty, reason: c.location);
          }
        });
      }
    });
  }
}

const Set<String> _allowedKeys = <String>{
  'id',
  'text',
  'now',
  'intent',
  'title',
  'due',
  'precision',
  'issue',
  'status',
  'note',
  'source',
  'tags',
};

final DateTime _defaultNow = DateTime(2026, 11, 2, 16, 30);

final class _Case {
  _Case(this.location, this.json);

  final String location;
  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get text => json['text'] as String;
  bool get isKnownGap => json['status'] == 'known_gap';

  List<String> check() {
    final status = json['status'] as String? ?? 'active';
    if (status != 'active' && status != 'known_gap') {
      throw FormatException('$location: неизвестный status «$status»');
    }
    final nowText = json['now'] as String?;
    final now = nowText == null ? _defaultNow : DateTime.parse(nowText);
    final parsed = ScenarioParser(clock: FixedClock(now)).parse(text);

    final mismatches = <String>[];
    void compare(String field, Object? actual, Object? expected) {
      if (actual != expected) {
        mismatches.add('$field: ожидалось $expected, получено $actual');
      }
    }

    compare(
      'intent',
      parsed.intent,
      CommandIntent.values.byName(json['intent'] as String),
    );
    if (json.containsKey('title')) {
      compare('title', parsed.title, json['title']);
    }
    if (json.containsKey('due')) {
      final due = json['due'] as String?;
      compare('due', parsed.dueAt, due == null ? null : DateTime.parse(due));
    }
    if (json.containsKey('precision')) {
      compare(
        'precision',
        parsed.duePrecision,
        DuePrecision.values.byName(json['precision'] as String),
      );
    }
    final issue = json['issue'] as String?;
    compare(
      'issue',
      parsed.dueIssue,
      issue == null ? DueIssue.none : DueIssue.values.byName(issue),
    );
    return mismatches;
  }
}
