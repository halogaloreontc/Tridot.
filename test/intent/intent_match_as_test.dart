import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/alarm/alarm_connector.dart';
import 'package:local_assistant/core/skills/archiver/archiver_connector.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/skills/converter/converter_connector.dart';
import 'package:local_assistant/core/skills/data/data_connector.dart';
import 'package:local_assistant/core/skills/files/files_connector.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/skills/table/table_connector.dart';
import 'package:local_assistant/core/skills/weather/weather_connector.dart';
import 'package:local_assistant/core/skills/ytdl/ytdl_connector.dart';
import 'package:local_assistant/core/skills/ytdl/ytdl_unavailable.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import '../connectors/manifest/fixtures.dart';

/// «Да» на подсказку запасного слоя (ADR-045): каждая команда модели
/// (tools/intent_model/labels.yaml) выполняется правилами своего навыка —
/// [IntentTarget.matchAs] находит её во фразе, которую обычный `match` не
/// понял, или спрашивает недостающее, или есть пример команды.
void main() {
  final now = DateTime(2026, 11, 20, 10);
  final clock = FixedClock(now);
  final connectors = <Connector>[
    TasksConnector(
      taskService: TaskService(
        repository: InMemoryTaskRepository(),
        clock: clock,
      ),
      parser: ScenarioParser(clock: clock),
    ),
    warehouseConnector(
      path: builtInManifestPath,
      record: connectedRecord(),
      builtIn: builtInManifest(builtInManifestPath),
    ),
    const CalculatorConnector(),
    TalkConnector(),
    const DataConnector(),
    ArchiverConnector(),
    ConverterConnector(),
    YtdlConnector(),
    AlarmConnector(clock: clock),
    FilesConnector(),
    WeatherConnector(
      backend: WeatherService.memory(clock: clock),
      clock: clock,
    ),
    TableConnector(read: (_) async => null, model: () async => null),
  ];
  Connector byId(String id) =>
      connectors.firstWhere((Connector c) => c.info.id == id);
  Utterance analyze(String text) => Utterance.analyze(text, now: now);

  /// Метки модели из labels.yaml.
  final labels = <String>[
    for (final line in File('tools/intent_model/labels.yaml').readAsLinesSync())
      if (RegExp(r'^\s+"([a-z]+:[A-Za-z.]+)":').firstMatch(line)
          case final RegExpMatch m)
        m.group(1)!,
  ];

  test('метки прочитаны', () => expect(labels.length, greaterThan(50)));

  test('каждая команда модели — у навыка с IntentTarget и выполнима', () {
    final missing = <String>[];
    for (final label in labels) {
      final [connectorId, commandId] = label.split(':');
      final connector = byId(connectorId);
      if (connector is! IntentTarget) {
        missing.add('$label: нет IntentTarget');
        continue;
      }
      final target = connector as IntentTarget;
      final match = target.matchAs(commandId, analyze('ну это самое'), analyze);
      if (match == null && target.intentExample(commandId) == null) {
        if (label == 'talk:talk.question') continue;
        missing.add('$label: ни разбора, ни примера');
      }
    }
    expect(missing, isEmpty);
  });

  /// Фразы проб ADR-045 (tools/intent_model/eval), которых правила не
  /// поняли: с подсказкой модели команда разбирается правилами навыка.
  /// Метка → (фраза, команды-ответы).
  final relaxed = <String, (String, Set<String>)>{
    'tasks:task.create': (
      'у меня в пятницу в 14:00 собеседование',
      <String>{'task.create'},
    ),
    'tasks:task.list': ('на этой неделе много дел?', <String>{'task.list'}),
    'tasks:task.complete': (
      'всё, с химчисткой разобрался',
      <String>{'task.complete'},
    ),
    'tasks:task.reschedule': (
      'перекинь оплату счёта на конец месяца',
      <String>{'task.reschedule'},
    ),
    'tasks:task.rescheduleMany': (
      'перенеси всё сегодняшнее на завтра на то же время',
      <String>{'task.rescheduleMany'},
    ),
    'alarm:alarm.set': (
      'мне бы не проспать завтра в 6:15',
      <String>{'alarm.set'}
    ),
    'alarm:alarm.date': (
      'двадцать пятого мне вставать в семь утра, заведи будильник',
      <String>{'alarm.date'},
    ),
    'alarm:alarm.timer': ('ещё на 5 минут', <String>{'alarm.timer'}),
    'calc:calc.evaluate': (
      'слушай, Лиорио, сколько будет 17 умножить на 3',
      <String>{'calc.evaluate'},
    ),
    'converter:converter.convert': (
      'сделай из видео гифку',
      <String>{'converter.convert'},
    ),
    'files:files.delete': ('удали скачанный файл', <String>{'files.delete'}),
    'talk:talk.joke': ('развесели старика анекдотом', <String>{'talk.joke'}),
    'weather:weather.day': (
      'а в Калининграде завтра?',
      <String>{'weather.day'}
    ),
    'weather:weather.wear': ('куртку брать?', <String>{'weather.wear'}),
    'warehouse:warehouse.where': (
      'щас где лежат венские стулья?',
      <String>{'warehouse.where'},
    ),
    'warehouse:warehouse.cell': (
      'покажи содержимое ячейки 303-1-1',
      <String>{'warehouse.cell'},
    ),
    'warehouse:warehouse.count': (
      'есть ещё табуретки?',
      <String>{'warehouse.count'},
    ),
    'warehouse:warehouse.yesterday': (
      'ну а за вчерашний день поступления какие?',
      <String>{'warehouse.yesterday'},
    ),
  };

  for (final MapEntry(key: label, value: (phrase, accepted))
      in relaxed.entries) {
    test('$label: «$phrase»', () {
      final [connectorId, commandId] = label.split(':');
      final connector = byId(connectorId);
      final match = (connector as IntentTarget)
          .matchAs(commandId, analyze(phrase), analyze);
      expect(match, isNotNull);
      expect(accepted, contains(match!.commandId));
    });
  }

  test('без слотов — навык спрашивает сам (будильник: на какое время?)', () {
    final alarm = byId('alarm') as IntentTarget;
    final match = alarm.matchAs('alarm.set', analyze('ну это самое'), analyze);
    expect(match?.commandId, 'alarm.clarify');
    final warehouse = byId('warehouse') as IntentTarget;
    // «Где лежит» без артикула: склад спрашивает, что найти.
    expect(
      warehouse
          .matchAs('warehouse.where', analyze('ну это самое'), analyze)
          ?.commandId,
      'warehouse.where',
    );
  });

  test('склад: носитель и артикул, действие — из встроенной копии', () {
    final warehouse = byId('warehouse') as IntentTarget;
    final move = warehouse.matchAs(
      'warehouse.act.move',
      analyze('3 шт 64115 из 215-1-1-1 в 215-1-1-2'),
      analyze,
    );
    expect(move?.commandId, 'warehouse.act.move');
    expect(warehouse.intentExample('warehouse.price'), isNotEmpty);
    expect(
      warehouse.matchAs('tasks.task.create', analyze('x'), analyze),
      isNull,
    );
  });

  test('носитель не превращает фразу в другую команду', () {
    final tasks = byId('tasks') as IntentTarget;
    // «Отметь выполненной» — не «создать задачу».
    final match = tasks.matchAs('task.list', analyze('купить хлеб'), analyze);
    expect(match?.commandId, anyOf(isNull, 'task.list'));
  });

  test('загрузчик видео без yt-dlp: та же команда — честный ответ', () {
    final unavailable = YtdlUnavailableConnector(
      YtdlUnavailableReason.android,
    ) as IntentTarget;
    final match =
        unavailable.matchAs('ytdl.download', analyze('ролик стяни'), analyze);
    expect(match?.commandId, YtdlUnavailableConnector.command);
  });
}
