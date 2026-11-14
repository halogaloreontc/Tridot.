// Каталог команд (ADR-020): разделы, скрытие выключенных навыков,
// постоянные id, поиск без учёта «ё» и регистра, частые команды и их
// счётчики в settings.json, и главное — каждый шаблон с примером
// заполнения доходит до своего навыка.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/commands/command_catalog.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/personas/persona_address.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/skills/data/data_connector.dart';
import 'package:local_assistant/core/skills/passwords/passwords_connector.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

import '../connectors/manifest/fixtures.dart';

final DateTime _now = DateTime(2026, 11, 2, 16, 30);

/// Все навыки, как в корпусе фраз: склад подключён, «Пароли» включены.
List<Connector> _connectors() => <Connector>[
      TasksConnector(
        taskService: TaskService(
          repository: InMemoryTaskRepository(),
          clock: FixedClock(_now),
        ),
        parser: ScenarioParser(clock: FixedClock(_now)),
      ),
      warehouseConnector(record: connectedRecord(), builtIn: builtInManifest()),
      const CalculatorConnector(),
      TalkConnector(),
      PasswordsConnector(),
      const DataConnector(),
    ];

ExtensionRegistry _registry({Set<String> disabled = const <String>{}}) =>
    ExtensionRegistry(
      connectors: _connectors(),
      choice: ExtensionChoice(
        enabled: <String>{
          PasswordsConnector.id,
          'warehouse',
        }.difference(disabled),
        disabled: disabled,
        enabledRoles: <String>{for (final role in Roles.all) role.id},
      ),
    );

List<ConnectorInfo> _infos(ExtensionRegistry registry) => <ConnectorInfo>[
      for (final connector in registry.enabledConnectors) connector.info,
    ];

/// Кого выберет маршрутизатор для [text] — тем же путём, что корпус.
String? _route(ExtensionRegistry registry, String text) {
  final phrase = PersonaAddressing.commandText(text);
  final utterance = Utterance.analyze(phrase, now: _now);
  final passwords = PasswordPhrases.looksLike(utterance);
  final matches = <ConnectorMatch>[
    for (final connector in registry.enabledConnectors)
      if (!(passwords && connector.info.requiresNetwork))
        if (connector.match(utterance) case final ConnectorMatch match) match,
  ];
  final decision = RoutePolicy.pick(matches);
  return decision.isAmbiguous ? 'ambiguous' : decision.winner?.connectorId;
}

void main() {
  group('CommandCatalog', () {
    test('все навыки включены — разделы в порядке, id уникальны', () {
      final catalog = CommandCatalog.build(
        connectors: _infos(_registry()),
        hasSelection: true,
      );
      expect(catalog.grouped.keys.toList(), <CommandCategory>[
        CommandCategory.tasks,
        CommandCategory.planning,
        CommandCategory.talk,
        CommandCategory.calc,
        CommandCategory.warehouse,
        CommandCategory.vault,
        CommandCategory.data,
      ]);
      final ids = catalog.entries.map((CommandEntry e) => e.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
      expect(ids, containsAll(CommandCatalog.knownIds));
    });

    test('постоянные id: по ним хранятся счётчики', () {
      // Переименовали — счётчики пользователей пропадут: тест напомнит.
      expect(
        CommandCatalog.knownIds,
        containsAll(<String>[
          'task.new',
          'task.tomorrow10',
          'task.list',
          'task.project',
          'plan.move',
          'plan.overdue',
          'calc.eval',
          'talk.joke',
          'wh.where',
          'data.backup',
          'pw.forgot',
          'pw.open',
        ]),
      );
    });

    test('каждый шаблон с примером доходит до своего навыка', () {
      final registry = _registry();
      final catalog = CommandCatalog.build(
        connectors: _infos(registry),
        hasSelection: true,
        projectTag: 'дом',
      );
      for (final entry in catalog.entries) {
        if (entry.kind == CommandKind.action) continue;
        if (entry.template.contains('|')) {
          expect(
            entry.sample,
            isNotEmpty,
            reason: '${entry.id}: шаблону с «|» нужен пример заполнения',
          );
        }
        expect(
          _route(registry, entry.filled),
          entry.connectorId,
          reason: '${entry.id}: «${entry.filled}»',
        );
      }
    });

    test('примеры заполнения разбираются как задумано', () {
      final parser = ScenarioParser(clock: FixedClock(_now));
      final project = parser.parse('Добавь задачу «Смета» #дом');
      expect(project.title, 'Смета');
      expect(project.projects, <String>['дом']);
      final move = parser.parse('Перенеси её на завтра в 15:00');
      expect(move.intent, CommandIntent.rescheduleTask);
      expect(move.targetQuery, isNull);
      expect(move.dueAt, DateTime(2026, 11, 3, 15));
    });

    test('выключенные навыки прячут свои команды', () {
      final registry = _registry(
        disabled: <String>{PasswordsConnector.id, CalculatorConnector.id},
      );
      final catalog = CommandCatalog.build(connectors: _infos(registry));
      final categories = catalog.grouped.keys;
      expect(categories, isNot(contains(CommandCategory.vault)));
      expect(categories, isNot(contains(CommandCategory.calc)));
      expect(catalog.byId('pw.open'), isNull);
      expect(catalog.byId('calc.eval'), isNull);
      // «Посчитать» уходит и из частых: на его место — следующая.
      expect(
        catalog.top(const <String, int>{}).map((CommandEntry e) => e.id),
        <String>['task.new', 'task.tomorrow10', 'task.list', 'task.project'],
      );
    });

    test('без выбранной задачи нет команд о ней', () {
      final infos = _infos(_registry());
      final without = CommandCatalog.build(connectors: infos);
      expect(without.byId('plan.move'), isNull);
      expect(without.byId('task.done'), isNull);
      final withSelection =
          CommandCatalog.build(connectors: infos, hasSelection: true);
      expect(withSelection.byId('plan.move')?.template, 'Перенеси её на |');
    });

    test('«Задача в проект»: курсор в названии, метка папки подставлена', () {
      final infos = _infos(_registry());
      final plain =
          CommandCatalog.build(connectors: infos).byId('task.project');
      expect(plain?.template, 'Добавь задачу «|» #');
      final tagged = CommandCatalog.build(connectors: infos, projectTag: 'дача')
          .byId('task.project');
      expect(tagged?.template, 'Добавь задачу «|» #дача');
    });

    test('склад без описания не показывает раздел', () {
      const infos = <ConnectorInfo>[
        ConnectorInfo(id: 'tasks', title: 'Задачи', description: ''),
        ConnectorInfo(id: 'warehouse', title: 'Склад', description: ''),
      ];
      final catalog = CommandCatalog.build(connectors: infos);
      expect(
        catalog.grouped.keys,
        isNot(contains(CommandCategory.warehouse)),
      );
    });

    test('неизвестное расширение — его примеры в «Другом»', () {
      const infos = <ConnectorInfo>[
        ConnectorInfo(
          id: 'weather',
          title: 'Погода',
          description: '',
          examples: <String>['Погода на завтра'],
        ),
      ];
      final catalog = CommandCatalog.build(connectors: infos);
      final entry = catalog.byId('ext.weather.0');
      expect(entry?.category, CommandCategory.other);
      expect(entry?.template, 'Погода на завтра');
      expect(CommandCatalog.isCountable('ext.weather.0'), isTrue);
    });

    test('поиск без учёта регистра и «ё», по подписи и разделу', () {
      final catalog = CommandCatalog.build(connectors: _infos(_registry()));
      List<String> ids(String query) =>
          catalog.search(query).map((CommandEntry e) => e.id).toList();
      expect(ids('ПЕРЕНЕСИ'), contains('plan.overdue'));
      expect(ids('ещё'), isEmpty);
      expect(ids('отчет'), contains('plan.moveTask'));
      expect(ids('сейф'), containsAll(<String>['pw.open', 'pw.forgot']));
      expect(ids('склад'), contains('wh.where'));
      expect(ids('  '), hasLength(catalog.entries.length));
      expect(ids('нет такой команды'), isEmpty);
    });

    test('поиск «склад» при выключенном складе пуст', () {
      final registry = _registry(disabled: <String>{'warehouse'});
      final catalog = CommandCatalog.build(connectors: _infos(registry));
      expect(catalog.search('склад'), isEmpty);
    });
  });

  group('частые команды', () {
    final catalog = CommandCatalog.build(connectors: _infos(_registry()));
    List<String> top(Map<String, int> usage) =>
        catalog.top(usage).map((CommandEntry e) => e.id).toList();

    test('без счётчиков — порядок по умолчанию', () {
      expect(top(const <String, int>{}), CommandCatalog.defaultTop);
    });

    test('по убыванию счёта, при равенстве — порядок по умолчанию', () {
      expect(
        top(const <String, int>{'calc.eval': 3, 'talk.joke': 1}),
        <String>['calc.eval', 'talk.joke', 'task.new', 'task.tomorrow10'],
      );
      expect(
        top(const <String, int>{'task.list': 2, 'task.new': 2}),
        <String>['task.new', 'task.list', 'task.tomorrow10', 'calc.eval'],
      );
    });

    test('счётчик неизвестной или выключенной команды не мешает', () {
      expect(
        top(const <String, int>{'wh.where': 9, 'старый.id': 99}).first,
        'wh.where',
      );
      final noCalc = CommandCatalog.build(
        connectors: _infos(_registry(disabled: <String>{'calc'})),
      );
      expect(
        noCalc.top(const <String, int>{'calc.eval': 50}).map((e) => e.id),
        isNot(contains('calc.eval')),
      );
    });
  });

  group('CommandUsage', () {
    test('bump считает только известные id', () {
      var usage = const <String, int>{};
      usage = CommandUsage.bump(usage, 'calc.eval');
      usage = CommandUsage.bump(usage, 'calc.eval');
      expect(usage, <String, int>{'calc.eval': 2});
      final same = CommandUsage.bump(usage, 'Забыл пароль от почты');
      expect(identical(same, usage), isTrue);
    });

    test('чтение: битые и неизвестные записи отбрасываются', () {
      expect(CommandUsage.fromJson('мусор'), isEmpty);
      expect(
        CommandUsage.fromJson(<String, Object?>{
          'calc.eval': 3,
          'task.new': -1,
          'talk.joke': '2',
          'неизвестно': 5,
          'pw.forgot': 1,
        }),
        <String, int>{'calc.eval': 3, 'pw.forgot': 1},
      );
    });

    test('не больше 50 записей — остаются частые', () {
      final many = <String, int>{
        for (var i = 0; i < 70; i++) 'ext.weather.$i': i + 1,
      };
      final trimmed = CommandUsage.trim(many);
      expect(trimmed, hasLength(CommandUsage.maxEntries));
      expect(trimmed.containsKey('ext.weather.69'), isTrue);
      expect(trimmed.containsKey('ext.weather.0'), isFalse);
    });

    test('settings.json: запись и чтение command_usage', () {
      const settings = AppSettings(
        commandUsage: <String, int>{'calc.eval': 3, 'task.new': 1},
      );
      final json = settings.toJson();
      expect(json['command_usage'], <String, int>{
        'calc.eval': 3,
        'task.new': 1,
      });
      expect(
        AppSettings.fromJson(json).commandUsage,
        <String, int>{'calc.eval': 3, 'task.new': 1},
      );
      expect(
        const AppSettings().toJson().containsKey('command_usage'),
        isFalse,
      );
      expect(
        AppSettings.fromJson(<String, dynamic>{'command_usage': 7})
            .commandUsage,
        isEmpty,
      );
    });
  });

  group('шаблон без времени (D-1)', () {
    test('«Перенеси её на завтра в» — «Во сколько?», задача не меняется',
        () async {
      final clock = FixedClock(_now);
      final service =
          TaskService(repository: InMemoryTaskRepository(), clock: clock);
      final assistant = AssistantController(
        connectors: <Connector>[
          TasksConnector(
            taskService: service,
            parser: ScenarioParser(clock: clock),
          ),
        ],
        clock: clock,
      );
      await assistant.handle('Добавь задачу «Отчёт» на завтра в 10:00');
      final response = await assistant.handle('Перенеси её на завтра в');
      expect(response.status, AssistantStatus.needsClarification);
      expect(response.message, contains('Во сколько?'));
      final task = (await service.listActive()).single;
      expect(task.dueAt, DateTime(2026, 11, 3, 10));
      expect(task.status, TaskStatus.planned);

      final done = await assistant.handle('Перенеси её на завтра в 15:00');
      expect(done.status, AssistantStatus.completed);
      expect(done.task?.dueAt, DateTime(2026, 11, 3, 15));
    });
  });
}
