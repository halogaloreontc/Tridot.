// «Помощь в постановке задачи» (ADR-022): подсказка похожих команд, когда
// фразу не понял ни один навык. Только вспомогательный путь: понятые
// фразы и фразы с уточняющим вопросом не меняются, фразы о паролях —
// без подсказок, ничего не запоминается.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/commands/command_catalog.dart';
import 'package:local_assistant/core/commands/command_suggest.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/replies/reply_template.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/skills/data/data_connector.dart';
import 'package:local_assistant/core/skills/passwords/passwords_connector.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

ConnectorInfo _info(String id, {List<String> examples = const <String>[]}) =>
    ConnectorInfo(
      id: id,
      title: id,
      description: '',
      examples: examples,
    );

final CommandCatalog _catalog = CommandCatalog.build(
  connectors: <ConnectorInfo>[
    _info('tasks'),
    _info('calc'),
    _info('talk'),
    _info('data'),
    _info('passwords'),
  ],
);

List<String> _ids(String text, {Map<String, int> usage = const {}}) => <String>[
      for (final s in CommandSuggester.suggest(text, _catalog, usage: usage))
        s.entryId,
    ];

AssistantController _assistant({bool passwords = false}) {
  final clock = FixedClock(DateTime(2026, 11, 2, 16, 30));
  final tasks = TaskService(repository: InMemoryTaskRepository(), clock: clock);
  return AssistantController(
    connectors: <Connector>[
      TasksConnector(taskService: tasks, parser: ScenarioParser(clock: clock)),
      const CalculatorConnector(),
      TalkConnector(taskService: tasks),
      if (passwords) PasswordsConnector(),
    ],
    clock: clock,
  );
}

/// Понятно написанные фразы, которые навыки не умеют: подсказок нет.
const List<String> _plainPhrases = <String>[
  'сколько тебе лет',
  'сколько стоит хлеб',
  'сколько времени',
  'сколько задач',
  'расскажи сказку',
  'расскажи про погоду',
  'список покупок',
  'новая машина',
  'новая песня',
  'новая неделя',
  'что будет завтра',
  'дела на завтра',
  'завтра',
  'ты умеешь петь',
  'корень зла',
  // Формы слов команд и короткие созвучия — не опечатки (решение
  // владельца: подсказки только для действительно непонятного).
  'проекты на лето',
  'проекта нет',
  'корни дерева',
  'процента нет',
  'купи билеты в кино',
  'корень',
  'процент',
  'процент по кредиту',
  'напоминание',
  'посчитай',
  'проект',
  'проект мечты',
  'покажи выполненные',
];

void main() {
  group('CommandSuggester: похожие команды', () {
    test('опечатки в командах находят свою команду первой', () {
      expect(_ids('покажи задчи').first, 'task.list');
      expect(_ids('сделй задачу купить хлеб').first, 'task.new');
      expect(_ids('расскаж шутку'), <String>['talk.joke']);
      expect(_ids('рaсскажи анегдот'), contains('talk.joke'));
      expect(_ids('посчетай 2+2'), <String>['calc.eval']);
      expect(_ids('скока будет 2+2'), <String>['calc.eval']);
      expect(_ids('заверш задачу отчёт'), <String>['task.complete']);
      expect(_ids('покаж просроченые'), <String>['plan.overdue']);
      expect(_ids('зделай резервную копию').first, 'data.backup');
    });

    test('не больше трёх команд и только близкие к лучшей', () {
      final ids = _ids('покажи задчи');
      expect(ids.length, lessThanOrEqualTo(CommandSuggestions.maxCommands));
      expect(ids, <String>['task.list', 'task.today', 'plan.week']);
    });

    test('бессмыслица, одно общее слово и посторонние слова — без подсказок',
        () {
      for (final text in <String>[
        'ывапр олдж',
        'хлеб',
        'кот',
        'что',
        'покажи',
        'сделай',
        '!!!',
        '',
      ]) {
        expect(_ids(text), isEmpty, reason: text);
      }
    });

    // Просьба владельца: подсказка — для опечатки или совсем непонятной
    // фразы, а не обычный ответ. Правильно написанные фразы, даже со
    // словом команды, подсказок не получают.
    test('фразы без опечатки — без подсказок, даже со словом команды', () {
      for (final text in _plainPhrases) {
        expect(_ids(text), isEmpty, reason: text);
      }
    });

    test('опечатка — только та команда, на которую она похожа', () {
      // «проект» — правильное слово, а не опечатка в «процент».
      expect(_ids('праект'), isNot(contains('calc.percent')));
      expect(_ids('процнт от 200'), <String>['calc.percent']);
      expect(
        CommandSuggester.isTypo('проект', <String>['процент', 'проект']),
        isFalse,
      );
      expect(CommandSuggester.isTypo('задчи', <String>['задачи']), isTrue);
      expect(CommandSuggester.isTypo('задачам', <String>['задачи']), isFalse);
    });

    test('длинная фраза — не опечатка в команде', () {
      expect(
        _ids('вчера я весь день думал о том, как бы мне покажи задчи '
            'наконец разобрать и не забыть ничего важного'),
        isEmpty,
      );
    });

    test('счётчики выбора решают только при равной похожести', () {
      expect(_ids('покажи задчи').first, 'task.list');
      expect(
        _ids('покажи задчи', usage: <String, int>{'plan.week': 5}).first,
        'plan.week',
      );
      // Счётчик не поднимает непохожую команду.
      expect(
        _ids('расскаж шутку', usage: <String, int>{'calc.eval': 50}),
        <String>['talk.joke'],
      );
    });

    test('выключенный навык не подсказывается', () {
      final tasksOnly = CommandCatalog.build(
        connectors: <ConnectorInfo>[_info('tasks')],
      );
      expect(CommandSuggester.suggest('расскаж шутку', tasksOnly), isEmpty);
      expect(CommandSuggester.suggest('посчетай 2+2', tasksOnly), isEmpty);
    });

    test('ни сейфа, ни команд о выбранной задаче, ни действий', () {
      final withSelection = CommandCatalog.build(
        connectors: <ConnectorInfo>[_info('tasks'), _info('passwords')],
        hasSelection: true,
      );
      for (final text in <String>[
        'праверь мои',
        'запри',
        'перенеси её',
        'заверш её',
      ]) {
        for (final s in CommandSuggester.suggest(text, withSelection)) {
          final entry = withSelection.byId(s.entryId)!;
          expect(entry.category, isNot(CommandCategory.vault), reason: text);
          expect(entry.needsSelection, isFalse, reason: text);
          expect(entry.kind, CommandKind.insert, reason: text);
        }
      }
    });
  });

  group('подстановка слов пользователя', () {
    String template(String text, String id) =>
        CommandSuggester.suggest(text, _catalog)
            .firstWhere((CommandSuggestion s) => s.entryId == id)
            .template;

    test('название задачи — на место «|», курсор в конце', () {
      expect(
        template('сделй задачу купить хлеб', 'task.new'),
        'Добавь задачу «купить хлеб»|',
      );
      expect(
        template('заверш задачу отчёт', 'task.complete'),
        'Заверши «отчёт»|',
      );
    });

    test('пример калькулятора — только цифры и знаки', () {
      expect(template('посчетай 2+2', 'calc.eval'), 'Сколько будет 2+2|');
      expect(template('посчетай', 'calc.eval'), 'Сколько будет |');
    });

    test('без хвоста или при неочевидном порядке — шаблон как есть', () {
      expect(template('покажи задчи', 'task.list'), 'Покажи задачи');
      expect(template('сделй задачу', 'task.new'), 'Добавь задачу «|»');
      // Слова команды после «хвоста»: что название, не очевидно.
      expect(
        template('хлеб купить сделй задачу', 'task.new'),
        'Добавь задачу «|»',
      );
    });

    test('похожее на пароль в хвосте не подставляется', () {
      expect(_ids('сделй задачу Xk9#mQ2!vL'), isEmpty);
    });
  });

  group('пароли и секреты: ни подсказок, ни повторов', () {
    test('фразы о паролях и похожее на пароль', () {
      for (final text in <String>[
        'пороль от почты',
        'забыл пороль от почты',
        'сделай резервную копию пароля',
        'мой пин 4321',
        'код 1234',
        'qwerty123',
        'парол',
        '••••••',
        'password',
      ]) {
        expect(CommandSuggester.isPrivate(text), isTrue, reason: text);
        expect(_ids(text), isEmpty, reason: text);
      }
    });

    test('обычные опечатки паролем не считаются', () {
      for (final text in <String>['покажи задчи', 'расскаж шутку']) {
        expect(CommandSuggester.isPrivate(text), isFalse, reason: text);
      }
    });
  });

  group('AssistantController: только вместо «не понял»', () {
    test('понятые фразы — как раньше, без подсказок', () async {
      final assistant = _assistant();
      for (final text in <String>[
        'дабавь задчу хлеб',
        'пакажи задачи',
        'добавь задачу молоко',
        'покажи задачи',
        'сколько будет 2+2',
        'привет',
        'расскажи шутку',
      ]) {
        final response = await assistant.handle(text);
        expect(response.intent, isNot('unknown'), reason: text);
        expect(response.suggestions, isNull, reason: text);
      }
    });

    test('фраза с одним уточняющим вопросом — вопрос, а не подсказка',
        () async {
      final assistant = _assistant();
      for (final text in <String>['добавь задачу', 'напомни', 'перенеси']) {
        final response = await assistant.handle(text);
        expect(
          response.status,
          AssistantStatus.needsClarification,
          reason: text,
        );
        expect(response.suggestions, isNull, reason: text);
      }
    });

    test('опечатка: «Не до конца понял. Возможно, подойдёт: …»', () async {
      final assistant = _assistant();
      // Опечатка в первой букве: её не исправляет TypoFix (ADR-037) —
      // остаются подсказки.
      final response = await assistant.handle('покажи садачи');
      expect(response.intent, 'unknown');
      expect(response.replyId, AssistantController.unknownSuggestReply);
      expect(response.message, startsWith('Не до конца понял. Возможно, '));
      expect(response.message, contains('«Показать задачи»'));
      expect(
        <String>[for (final s in response.suggestions!.commands) s.entryId],
        <String>['task.list', 'task.today', 'plan.week'],
      );
      // В тексте — только подписи команд, не слова пользователя.
      expect(response.message, isNot(contains('садачи')));
    });

    test(
        'опечатку, которую можно исправить, исправляет TypoFix, а не '
        'подсказки', () async {
      final assistant = _assistant();
      final response = await assistant.handle('покажи задчи');
      expect(response.intent, 'task.list');
      expect(response.suggestions, isNull);
      expect(response.message, startsWith('Похоже на опечатку'));
    });

    test('голосом помощницы — «поняла»', () async {
      final assistant = _assistant();
      assistant.personas = assistant.personas.withGender(
        assistant.personas.responder.id,
        ReplyGender.female,
      );
      final response = await assistant.handle('расскаж шутку');
      expect(response.message, startsWith('Не до конца поняла.'));
    });

    test('бессмыслица и фразы без опечатки — прежний ответ без кнопок',
        () async {
      final assistant = _assistant();
      for (final text in <String>[
        'ывапр олдж',
        'да',
        'хочу пиццу',
        'открой камеру',
        'позвони маме',
        ..._plainPhrases,
      ]) {
        final response = await assistant.handle(text);
        if (response.intent != 'unknown') continue;
        expect(response.replyId, TasksConnector.unknownReply, reason: text);
        expect(response.suggestions, isNull, reason: text);
      }
    });

    test('фраза о паролях — прежний ответ без кнопок и без повтора', () async {
      for (final passwords in <bool>[false, true]) {
        final assistant = _assistant(passwords: passwords);
        for (final text in <String>[
          'пороль от почты',
          'забыл пороль от почты',
          'мой пин 4321',
          'qwerty123',
        ]) {
          final response = await assistant.handle(text);
          expect(response.suggestions, isNull, reason: '$passwords $text');
          expect(response.message, isNot(contains('4321')), reason: text);
          expect(response.message, isNot(contains('qwerty')), reason: text);
          expect(response.message, isNot(contains('почты')), reason: text);
        }
      }
    });

    test('ничего не запоминает: та же фраза — тот же ответ', () async {
      final assistant = _assistant();
      final first = await assistant.handle('расскаж шутку');
      final second = await assistant.handle('расскаж шутку');
      expect(first.suggestions!.commands.single.entryId, 'talk.joke');
      expect(second.intent, 'unknown');
      expect(second.suggestions!.commands.single.entryId, 'talk.joke');
      // И понятая следом фраза не меняется.
      final joke = await assistant.handle('расскажи шутку');
      expect(joke.suggestions, isNull);
    });

    test('счётчики выбора команд задают порядок равных', () async {
      final assistant = _assistant()
        ..commandUsage = const <String, int>{'task.today': 3};
      final response = await assistant.handle('покажи садачи');
      expect(response.suggestions!.commands.first.entryId, 'task.today');
    });
  });

  test('каталог команд с данными: «зделай резервную копию»', () async {
    final clock = FixedClock(DateTime(2026, 11, 2, 16, 30));
    final tasks =
        TaskService(repository: InMemoryTaskRepository(), clock: clock);
    final assistant = AssistantController(
      connectors: <Connector>[
        TasksConnector(
          taskService: tasks,
          parser: ScenarioParser(clock: clock),
        ),
        const DataConnector(),
      ],
      clock: clock,
    );
    final response = await assistant.handle('зделай резервную копию');
    expect(response.intent, 'unknown');
    expect(response.suggestions!.commands.first.entryId, 'data.backup');
  });

  test('подсказка живёт только в памяти: в JSON чата её нет', () {
    final message = ChatMessage(
      id: 'm_1',
      author: ChatAuthor.persona,
      text: 'Не до конца понял.',
      timestamp: DateTime(2026, 11, 2),
      suggestions: const CommandSuggestions(<CommandSuggestion>[
        CommandSuggestion(
          entryId: 'task.list',
          label: 'Показать задачи',
          template: 'Покажи задачи',
        ),
      ]),
    );
    expect(message.toJson().keys, isNot(contains('suggestions')));
    expect(message.toJson().toString(), isNot(contains('task.list')));
    expect(message.withText('x').suggestions, same(message.suggestions));
    expect(message.copyAs('m_2').suggestions, isNull);
    expect(ChatMessage.fromJson(message.toJson())?.suggestions, isNull);
  });
}
