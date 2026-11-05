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
      _validate(json, location);
      final id = json['id'] as String;
      final previous = seenIds[id];
      if (previous != null) {
        throw FormatException('$location: id «$id» уже есть в $previous');
      }
      seenIds[id] = location;
      cases.add(_Case(name, location, json));
    }
  }

  test('корпус не пуст', () => expect(cases, isNotEmpty));

  for (final file in files) {
    final name = file.uri.pathSegments.last;
    group(name, () {
      for (final c in cases.where((_Case c) => c.file == name)) {
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
  'titleIssue',
  'projects',
  'status',
  'note',
  'source',
  'tags',
};

final DateTime _defaultNow = DateTime(2026, 11, 2, 16, 30);

/// Проверяет строку целиком при загрузке, чтобы ошибка в данных указывала
/// на файл и строку, а не роняла тест непонятным приведением типов.
void _validate(Map<String, dynamic> json, String location) {
  void fail(String message) => throw FormatException('$location: $message');

  for (final key in <String>['id', 'text', 'intent']) {
    if (json[key] is! String) {
      fail('поле $key обязательно и должно быть строкой');
    }
  }
  void checkEnum(String key, List<Enum> values) {
    if (!json.containsKey(key)) return;
    final value = json[key];
    if (value is! String || !values.any((Enum e) => e.name == value)) {
      fail('недопустимое значение $key: $value');
    }
  }

  checkEnum('intent', CommandIntent.values);
  checkEnum('precision', DuePrecision.values);
  checkEnum('issue', DueIssue.values);
  checkEnum('titleIssue', TitleIssue.values);
  final projects = json['projects'];
  if (projects != null &&
      (projects is! List || projects.any((Object? p) => p is! String))) {
    fail('поле projects должно быть списком строк');
  }
  for (final key in <String>['title', 'due', 'now', 'note', 'source']) {
    final value = json[key];
    if (value != null && value is! String) {
      fail('поле $key должно быть строкой');
    }
  }
  final status = json['status'];
  if (status != null && status != 'active' && status != 'known_gap') {
    fail('неизвестный status «$status»');
  }
  for (final key in <String>['due', 'now']) {
    final value = json[key];
    if (value is String && DateTime.tryParse(value) == null) {
      fail('поле $key не является датой: $value');
    }
  }
}

final class _Case {
  _Case(this.file, this.location, this.json);

  final String file;
  final String location;
  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get text => json['text'] as String;
  bool get isKnownGap => json['status'] == 'known_gap';

  List<String> check() {
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
    if (json.containsKey('projects')) {
      final expected = (json['projects'] as List<dynamic>).cast<String>();
      if (parsed.projects.join(',') != expected.join(',')) {
        mismatches.add(
          'projects: ожидалось $expected, получено ${parsed.projects}',
        );
      }
    }
    final titleIssue = json['titleIssue'] as String?;
    compare(
      'titleIssue',
      parsed.titleIssue,
      titleIssue == null
          ? TitleIssue.none
          : TitleIssue.values.byName(titleIssue),
    );
    return mismatches;
  }
}
