import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/calculator/calculator.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import 'connectors/example_warehouse_connector.dart';
import 'connectors/fakes.dart';

/// Регрессионный корпус фраз: test/corpus/*.jsonl, формат — docs/CORPUS.md.
///
/// Каждая строка — одна фраза и ожидаемый разбор. Поля, которых нет в строке,
/// не проверяются; явный `null` проверяется как «должно быть пусто».
/// Строки со `status: known_gap` описывают ещё не поддержанные фразы: тест
/// падает, если такая фраза вдруг начала разбираться правильно, — тогда её
/// нужно перевести в `active`.
///
/// Поле `connector` (по умолчанию `tasks`) говорит, какой коннектор должен
/// забрать фразу. Для каждой строки проверяется и спор коннекторов: среди
/// всех из [_connectorFactories] побеждает именно этот.
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
  'targetQuery',
  'connector',
  'due',
  'precision',
  'issue',
  'titleIssue',
  'projects',
  'status',
  'note',
  'source',
  'tags',
  'answer',
};

final DateTime _defaultNow = DateTime(2026, 11, 2, 16, 30);

/// Коннекторы, чьи фразы живут в корпусе. Новый коннектор добавляется сюда
/// фабрикой с подделками вместо сети и хранилищ (docs/CONNECTORS.md):
/// `match` не делает ввода-вывода, поэтому подделкам нечего отвечать.
final Map<String, Connector Function(DateTime now)> _connectorFactories =
    <String, Connector Function(DateTime now)>{
  TasksConnector.id: (DateTime now) => TasksConnector(
        taskService: TaskService(
          repository: InMemoryTaskRepository(),
          clock: FixedClock(now),
        ),
        parser: ScenarioParser(clock: FixedClock(now)),
      ),
  // Учебный коннектор из docs/CONNECTORS.md: его фразы проверяют, что
  // задачи и склад не перехватывают команды друг друга.
  ExampleWarehouseConnector.id: (DateTime now) => ExampleWarehouseConnector(
        transport: FakeHttpTransport(
          (HttpRequestData r) => throw StateError('match не ходит в сеть'),
        ),
        secrets: InMemorySecretStore(),
        baseUri: Uri.parse('https://warehouse.example/api/'),
      ),
  CalculatorConnector.id: (DateTime now) => const CalculatorConnector(),
};

/// Ответ калькулятора для сравнения с полем `answer`: неразрывные пробелы
/// между разрядами («2 400») в корпусе пишутся обычными.
String _calcAnswer(String text) => Calculator.calculate(text)
    .answer
    .replaceAll(Calculator.groupSeparator, ' ');

/// Кого выберет маршрутизатор: id коннектора, `ambiguous`, если он
/// переспросит (те же правила, что в AssistantController), или `null`.
String? _routed(List<ConnectorMatch> all) {
  if (all.isEmpty) return null;
  final sorted = all.any((ConnectorMatch m) => !m.implicit)
      ? all.where((ConnectorMatch m) => !m.implicit).toList()
      : all;
  final best = sorted.first;
  for (final other in sorted.skip(1)) {
    if (other.connectorId == best.connectorId) continue;
    if (best.confidence >= AssistantController.ambiguityFloor &&
        other.confidence >= AssistantController.ambiguityFloor &&
        best.confidence - other.confidence <=
            AssistantController.ambiguityMargin) {
      return 'ambiguous';
    }
    break;
  }
  return best.connectorId;
}

Set<String> get _connectorIds => _connectorFactories.keys.toSet();

bool _isEmptyValue(Object? value) =>
    value == null || value == 'none' || (value is List && value.isEmpty);

/// Поля, которые есть только у разбора задач.
const Set<String> _taskOnlyKeys = <String>{
  'title',
  'targetQuery',
  'due',
  'precision',
  'issue',
  'titleIssue',
  'projects',
};

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

  final connector = json['connector'];
  if (connector != null &&
      (connector is! String || !_connectorIds.contains(connector))) {
    fail('неизвестный connector «$connector»; известные: $_connectorIds');
  }
  if (connector == null || connector == TasksConnector.id) {
    checkEnum('intent', CommandIntent.values);
  } else {
    // Для других коннекторов intent — commandId или `unknown`.
    // Генератор корпуса может записать пустые поля разбора — это не
    // ошибка. Непустые значения для других коннекторов не проверяются,
    // поэтому запрещены, чтобы не создавать видимость проверки.
    final extra = json.keys
        .toSet()
        .intersection(_taskOnlyKeys)
        .where((String key) => !_isEmptyValue(json[key]))
        .toSet();
    if (extra.isNotEmpty) {
      fail('поля $extra проверяются только у коннектора tasks');
    }
  }
  checkEnum('precision', DuePrecision.values);
  checkEnum('issue', DueIssue.values);
  checkEnum('titleIssue', TitleIssue.values);
  final projects = json['projects'];
  if (projects != null &&
      (projects is! List || projects.any((Object? p) => p is! String))) {
    fail('поле projects должно быть списком строк');
  }
  for (final key in <String>[
    'title',
    'targetQuery',
    'due',
    'now',
    'note',
    'source',
  ]) {
    final value = json[key];
    if (value != null && value is! String) {
      fail('поле $key должно быть строкой');
    }
  }
  if (json.containsKey('answer')) {
    // Ответ проверяется только у калькулятора и только для примеров.
    if (json['answer'] is! String) fail('поле answer должно быть строкой');
    if (connector != CalculatorConnector.id ||
        json['intent'] != CalculatorConnector.commandId) {
      fail('поле answer бывает только у connector «calc» с intent '
          '«${CalculatorConnector.commandId}»');
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
    final mismatches = <String>[];
    void compare(String field, Object? actual, Object? expected) {
      if (actual != expected) {
        mismatches.add('$field: ожидалось $expected, получено $actual');
      }
    }

    final connectorId = json['connector'] as String? ?? TasksConnector.id;
    final expectedIntent = json['intent'] as String;
    final utterance = Utterance.analyze(text, now: now);
    final matches = <ConnectorMatch>[
      for (final factory in _connectorFactories.values)
        if (factory(now).match(utterance) case final ConnectorMatch match)
          match,
    ]..sort(
        (ConnectorMatch a, ConnectorMatch b) =>
            b.confidence.compareTo(a.confidence),
      );
    if (expectedIntent != 'unknown') {
      compare('connector', _routed(matches), connectorId);
    }
    if (connectorId != TasksConnector.id) {
      final own = matches
          .where((ConnectorMatch m) => m.connectorId == connectorId)
          .toList();
      compare(
        'intent',
        own.isEmpty ? 'unknown' : own.first.commandId,
        expectedIntent,
      );
      if (json['answer'] case final String answer) {
        compare('answer', _calcAnswer(text), answer);
      }
      return mismatches;
    }

    final parsed = ScenarioParser(clock: FixedClock(now)).parse(text);

    compare(
      'intent',
      parsed.intent,
      CommandIntent.values.byName(json['intent'] as String),
    );
    if (json.containsKey('title')) {
      // Для переноса и завершения `title` — то, по чему ищется задача:
      // точное название из кавычек или запрос без кавычек. Так же размечает
      // tools/corpus_gen. Отдельно их различает поле `targetQuery`.
      final isTarget = parsed.intent == CommandIntent.rescheduleTask ||
          parsed.intent == CommandIntent.completeTask;
      compare(
        'title',
        isTarget ? parsed.title ?? parsed.targetQuery : parsed.title,
        json['title'],
      );
    }
    if (json.containsKey('targetQuery')) {
      compare('targetQuery', parsed.targetQuery, json['targetQuery']);
    }
    if (json.containsKey('due')) {
      final due = json['due'] as String?;
      compare('due', parsed.dueAt, due == null ? null : DateTime.parse(due));
    }
    // Точность есть ровно тогда, когда есть срок: без срока она не
    // должна притворяться «dateTime».
    if ((parsed.dueAt == null) != (parsed.duePrecision == null)) {
      mismatches.add(
        'precision: при сроке ${parsed.dueAt} получено ${parsed.duePrecision}',
      );
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
