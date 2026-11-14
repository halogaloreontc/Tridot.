import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/manifest/connection_slots.dart';
import 'package:local_assistant/core/connectors/manifest/manifest_format.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/models/bulk.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/personas/persona_address.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/calculator/calculator.dart';
import 'package:local_assistant/core/skills/archiver/archiver_connector.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/skills/converter/converter_connector.dart';
import 'package:local_assistant/core/skills/data/data_connector.dart';
import 'package:local_assistant/core/skills/passwords/passwords_connector.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/skills/ytdl/ytdl_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import 'connectors/manifest/fixtures.dart';

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
///
/// Роли (ADR-012): по умолчанию включены все встроенные роли («Личное» и
/// «Кладовщик»), а склад не подключён — так склад спорит за каждую фразу
/// корпуса, но подсказки роли, которым нужно подключение, молчат. Поле
/// `roles` (список id ролей) задаёт включённые роли строки, `connected:
/// true` — склад подключён (подсказки роли «Кладовщик» действуют).
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
  'scope',
  'shift',
  'roles',
  'connected',
  'after',
  'form',
};

/// Что карточка конвертера получит из фразы: цель и качество, ключи по
/// порядку (`target=mp3, audio_kbps=320`).
String? _formOf(Object? payload) => switch (payload) {
      final ConvertRequest r => _sortedForm(<String, String>{
          if (r.target case final String target) 'target': target,
          if (r.unoffered case final String format) 'unoffered': format,
          ...r.options,
        }),
      _ => null,
    };

String _sortedForm(Map<String, String> form) => <String>[
      for (final key in form.keys.toList()..sort()) '$key=${form[key]}',
    ].join(', ');

/// Роли строки без поля `roles`: все встроенные.
final List<String> _defaultRoles = <String>[
  for (final role in Roles.all) role.id,
];

final DateTime _defaultNow = DateTime(2026, 11, 2, 16, 30);

/// Встроенная копия описания склада с действиями — разбирается один раз.
final ManifestDescription _builtIn = builtInManifest();

/// Коннекторы, чьи фразы живут в корпусе. Новый коннектор добавляется сюда
/// фабрикой с подделками вместо сети и хранилищ (docs/CONNECTORS.md):
/// `match` не делает ввода-вывода, поэтому подделкам нечего отвечать.
final Map<String, Connector Function(DateTime now, bool connected)>
    _connectorFactories =
    <String, Connector Function(DateTime now, bool connected)>{
  TasksConnector.id: (DateTime now, bool connected) => TasksConnector(
        taskService: TaskService(
          repository: InMemoryTaskRepository(),
          clock: FixedClock(now),
        ),
        parser: ScenarioParser(clock: FixedClock(now)),
      ),
  // Склад по описанию assistant/1 (test/fixtures/assistant): его фразы
  // проверяют, что задачи, калькулятор, беседа и склад не перехватывают
  // команды друг друга.
  // Действия с записью (ADR-013) — из встроенной копии 1.4.57: их фразы
  // тоже спорят за каждую строку корпуса.
  ConnectionSlots.warehouse.id: (DateTime now, bool connected) =>
      warehouseConnector(
        record: connected ? connectedRecord() : null,
        builtIn: _builtIn,
      ),
  CalculatorConnector.id: (DateTime now, bool connected) =>
      const CalculatorConnector(),
  // Беседа уступает любой команде (fallback): её фразы проверяют, что
  // «привет, добавь задачу …» остаётся задачей.
  TalkConnector.id: (DateTime now, bool connected) => TalkConnector(),
  // Навык «Пароли» (ADR-014) выключен по умолчанию, но в корпусе включён
  // всегда: он спорит за каждую строку, а его фразы — только синтетика.
  // `match` не трогает хранилище, поэтому фасад не нужен.
  PasswordsConnector.id: (DateTime now, bool connected) => PasswordsConnector(),
  // «Данные» (решения владельца 3, 5): копия и «хранилище» без опоры на
  // пароли — уточняющий вопрос. Совпадения без маркера и ниже порога
  // спора: уступают любой явной фразе.
  DataConnector.id: (DateTime now, bool connected) => const DataConnector(),
  // Архиватор (ADR-024) выключен по умолчанию, но в корпусе включён
  // всегда: его фразы («сожми в zip») не должны перехватывать задачи.
  ArchiverConnector.id: (DateTime now, bool connected) => ArchiverConnector(),
  // Конвертер (ADR-024, шаг 2) — так же: «переведи 100 долларов в рубли»
  // и «переведи на английский» остаются не его.
  ConverterConnector.id: (DateTime now, bool connected) => ConverterConnector(),
  // Загрузчик видео (ADR-024, шаг 3): в приложении — только Windows и
  // Linux и не в сборке для Google Play, в корпусе — всегда, на любой
  // платформе: его фразы («скачай видео …») не должны перехватывать
  // задачи и конвертер.
  YtdlConnector.id: (DateTime now, bool connected) => YtdlConnector(),
};

/// Ответ калькулятора для сравнения с полем `answer`: пример — как его
/// видит коннектор (со снятым вступлением «привет, …»). Неразрывные
/// пробелы между разрядами («2 400») в корпусе пишутся обычными.
String _calcAnswer(Utterance utterance) {
  final recognition = CalculatorConnector.recognize(utterance);
  final result = recognition == null
      ? Calculator.calculate(utterance.original)
      : Calculator.evaluateRecognition(recognition);
  return result.answer.replaceAll(Calculator.groupSeparator, ' ');
}

/// Кого выберет маршрутизатор: id коннектора, `ambiguous`, если он
/// переспросит, или `null` — общая функция [RoutePolicy.pick], та же, что
/// в AssistantController.
String? _routed(RouteDecision decision) =>
    decision.isAmbiguous ? 'ambiguous' : decision.winner?.connectorId;

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
  'scope',
  'shift',
};

/// Намерения массовых команд: только у них есть `scope` и `shift`.
const Set<String> _bulkIntents = <String>{'rescheduleMany', 'completeMany'};

/// `all`, `overdue`, `noDue` или `date:ГГГГ-ММ-ДД`, затем метки `#тег`.
final RegExp _scopePattern = RegExp(
  r'^(all|overdue|noDue|date:\d{4}-\d{2}-\d{2})( #[^\s#]+)*$',
);

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
  for (final key in <String>['scope', 'shift']) {
    if (!json.containsKey(key)) continue;
    final value = json[key];
    if (!_bulkIntents.contains(json['intent'])) {
      fail('поле $key бывает только у намерений $_bulkIntents');
    }
    if (value == null) continue;
    if (key == 'scope' &&
        (value is! String || !_scopePattern.hasMatch(value))) {
      fail('недопустимое значение scope: $value');
    }
    if (key == 'shift' && DueShift.parse(value) == null) {
      fail('недопустимое значение shift: $value (ожидается +1h, -2d, +30m)');
    }
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
  final roles = json['roles'];
  if (roles != null &&
      (roles is! List ||
          roles.any((Object? r) => r is! String || Roles.byId(r) == null))) {
    fail('поле roles — список id ролей: '
        '${Roles.all.map((RoleInfo r) => r.id).join(', ')}');
  }
  final connected = json['connected'];
  if (connected != null && connected is! bool) {
    fail('поле connected — true или false');
  }
  final form = json['form'];
  if (form != null) {
    if (form is! Map || form.values.any((Object? v) => v is! String)) {
      fail('поле form — объект «поле: значение» строками');
    }
    if (connector != ConverterConnector.id) {
      fail('поле form бывает только у connector «converter»');
    }
  }
  final after = json['after'];
  if (after != null && (after is! String || !_connectorIds.contains(after))) {
    fail('поле after — id коннектора: $_connectorIds');
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
    final after = json['after'] as String?;
    final roles = <String>{
      ...(json['roles'] as List<dynamic>?)?.cast<String>() ?? _defaultRoles,
    };
    final connected = json['connected'] as bool? ?? false;
    // Реестр с выбором ролей строки: выключенная роль прячет свои навыки,
    // включённая — передаёт подсказки маршрутизации.
    final registry = ExtensionRegistry(
      connectors: <Connector>[
        for (final factory in _connectorFactories.values)
          factory(now, connected),
      ],
      choice: ExtensionChoice(
        enabled: const <String>{
          PasswordsConnector.id,
          ArchiverConnector.id,
          ConverterConnector.id,
          YtdlConnector.id,
        },
        enabledRoles: roles,
        disabledRoles: <String>{
          for (final role in Roles.all)
            if (!roles.contains(role.id)) role.id,
        },
      ),
    );
    // Совпадения в порядке подключения. Фразу о паролях не получает ни
    // один сетевой коннектор (раздел 5.9) — то же правило, что в
    // AssistantController.
    List<ConnectorMatch> matchesOf(Utterance utterance) {
      final passwordsPhrase = PasswordPhrases.looksLike(utterance);
      return <ConnectorMatch>[
        for (final connector in registry.enabledConnectors)
          if (!(passwordsPhrase && connector.info.requiresNetwork))
            if (connector.match(utterance) case final ConnectorMatch match)
              match,
      ];
    }

    // Обращение по имени в начале («Связной, …») маршрутизатор снимает до
    // разбора (AssistantController.resolve): навыки получают фразу без
    // него.
    var phrase = PersonaAddressing.commandText(text);
    var utterance = Utterance.analyze(phrase, now: now)
        .withChat(null, recentConnectorId: after);
    var matches = matchesOf(utterance);
    var decision = RoutePolicy.pick(matches, recentConnectorId: after);
    // Фраза понята по контексту как фраза другого навыка: проверяется
    // разбор канонической фразы, как её разберёт маршрутизатор.
    if (decision.winner?.payload case final Reroute reroute) {
      phrase = reroute.text;
      utterance = Utterance.analyze(phrase, now: now);
      matches = matchesOf(utterance);
      decision = RoutePolicy.pick(matches);
    }
    if (expectedIntent != 'unknown') {
      compare('connector', _routed(decision), connectorId);
    }
    if (connectorId != TasksConnector.id) {
      final own = matches
          .where((ConnectorMatch m) => m.connectorId == connectorId)
          .toList()
        ..sort(
          (ConnectorMatch a, ConnectorMatch b) =>
              b.confidence.compareTo(a.confidence),
        );
      compare(
        'intent',
        own.isEmpty ? 'unknown' : own.first.commandId,
        expectedIntent,
      );
      if (json['answer'] case final String answer) {
        compare('answer', _calcAnswer(utterance), answer);
      }
      if (json['form'] case final Map<String, dynamic> form) {
        compare(
          'form',
          _formOf(own.isEmpty ? null : own.first.payload),
          _sortedForm(form.cast<String, String>()),
        );
      }
      return mismatches;
    }

    final parsed = ScenarioParser(clock: FixedClock(now)).parse(phrase);

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
    if (json.containsKey('scope')) {
      compare('scope', parsed.selection?.label, json['scope']);
    }
    if (json.containsKey('shift')) {
      compare('shift', parsed.shift?.label, json['shift']);
    }
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
