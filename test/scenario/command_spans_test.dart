// Подсветка команды (ADR-021): части фразы — из настоящего разбора навыков,
// пароли не подсвечиваются вовсе.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/skills/data/data_connector.dart';
import 'package:local_assistant/core/skills/passwords/passwords_connector.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

final _clock = FixedClock(DateTime(2026, 11, 2, 16, 30));

AssistantController _assistant() {
  final tasks = TaskService(
    repository: InMemoryTaskRepository(),
    clock: _clock,
  );
  return AssistantController(
    connectors: <Connector>[
      TasksConnector(taskService: tasks, parser: ScenarioParser(clock: _clock)),
      const CalculatorConnector(),
      TalkConnector(taskService: tasks),
      PasswordsConnector(
        vault: null,
        canCopySecrets: false,
        vaultExisted: () => false,
      ),
      const DataConnector(),
    ],
    clock: _clock,
  );
}

/// Части фразы словами: `verb:Добавь задачу`.
List<String> _parts(String text, List<CommandSpan> spans) => <String>[
      for (final span in spans)
        '${span.kind.name}:${text.substring(span.start, span.end)}',
    ];

void main() {
  late AssistantController assistant;
  List<String> parts(String text) => _parts(text, assistant.highlight(text));

  setUp(() => assistant = _assistant());

  group('задачи', () {
    test('слово команды, название, срок и метка', () {
      expect(parts('Добавь задачу купить хлеб на завтра в 10 #дом'), <String>[
        'verb:Добавь задачу',
        'title:купить хлеб',
        'due:на завтра в 10',
        'tag:#дом',
      ]);
    });

    test('название в кавычках — без кавычек', () {
      expect(parts('Добавь задачу «Отчёт» на завтра в 10:00'), <String>[
        'verb:Добавь задачу',
        'title:Отчёт',
        'due:на завтра в 10:00',
      ]);
    });

    test('перенос: цель и новый срок', () {
      expect(parts('Перенеси отчёт на завтра'), <String>[
        'verb:Перенеси',
        'title:отчёт',
        'due:на завтра',
      ]);
    });

    test('висящий предлог шаблона не становится целью', () {
      expect(parts('Перенеси её на завтра в'), <String>[
        'verb:Перенеси',
        'due:на завтра',
      ]);
    });

    test('команда без маркера: название и срок, слова команды нет', () {
      expect(parts('купить молоко завтра'), <String>[
        'title:купить молоко',
        'due:завтра',
      ]);
    });

    test('команда в конце фразы', () {
      expect(parts('надо сходить к врачу на этой неделе, добавь'), <String>[
        'title:сходить к врачу',
        'due:на этой неделе',
        'verb:добавь',
      ]);
    });

    test('список задач', () {
      expect(parts('покажи задачи'), <String>['verb:покажи задачи']);
    });

    test('та же разметка, что у ScenarioParser.spansOf', () {
      const text = 'напомни мне про встречу с клиентом в пятницу';
      final parser = ScenarioParser(clock: _clock);
      final direct = parser.spansOf(Utterance.analyze(text, now: _clock.now()));
      expect(assistant.highlight(text), direct);
      expect(_parts(text, direct), <String>[
        'verb:напомни',
        'title:про встречу с клиентом',
        'due:в пятницу',
      ]);
    });
  });

  group('обращение и калькулятор', () {
    test('имя главного помощника — обращение, дальше — разбор без него', () {
      expect(parts('Связной, добавь задачу хлеб'), <String>[
        'address:Связной',
        'verb:добавь задачу',
        'title:хлеб',
      ]);
    });

    test('пример калькулятора — числа и знаки, маркер без цвета', () {
      expect(parts('сколько будет 2+2*2'), <String>['number:2+2*2']);
      expect(
        parts('сколько будет 15% от 2400'),
        <String>['number:15%', 'number:2400'],
      );
    });

    test('у примера после «, а …» — только эта часть', () {
      expect(
        parts('через 2 часа дедлайн, а 9×9 сколько?'),
        <String>['number:9×9'],
      );
    });
  });

  group('без подсветки', () {
    for (final text in <String>[
      '',
      '   ',
      'привет',
      'расскажи шутку',
      'что-то совсем непонятное',
    ]) {
      test('«$text»', () => expect(assistant.highlight(text), isEmpty));
    }

    test('слишком длинный текст', () {
      final text = 'Добавь задачу ${'хлеб ' * 100}';
      expect(text.length, greaterThan(CommandSpans.maxLength));
      expect(assistant.highlight(text), isEmpty);
    });
  });

  group('пароли не подсвечиваются вовсе', () {
    for (final text in <String>[
      'пароль от почты Kx9!mq2z',
      'покажи пароль от почты',
      'Добавь задачу пароль: Kx9!mq2zQ',
      'Добавь задачу ••••••',
      'Связной, покажи пароли',
      'войти #qr=0123456789abcdef',
    ]) {
      test('«$text»', () => expect(assistant.highlight(text), isEmpty));
    }
  });

  group('CommandSpans', () {
    test('normalize: по порядку, без пересечений, внутри текста', () {
      final spans = CommandSpans.normalize(
        const <CommandSpan>[
          CommandSpan(5, 9, CommandSpanKind.due),
          CommandSpan(0, 4, CommandSpanKind.verb),
          CommandSpan(2, 6, CommandSpanKind.title),
          CommandSpan(8, 30, CommandSpanKind.tag),
        ],
        12,
      );
      expect(spans, const <CommandSpan>[
        CommandSpan(0, 4, CommandSpanKind.verb),
        CommandSpan(4, 6, CommandSpanKind.title),
        CommandSpan(6, 9, CommandSpanKind.due),
        CommandSpan(9, 12, CommandSpanKind.tag),
      ]);
    });

    test('merge: слова одного вида через пробел и запятую — одной частью', () {
      const text = 'хлеб, молоко 5';
      final merged = CommandSpans.merge(
        const <CommandSpan>[
          CommandSpan(0, 4, CommandSpanKind.title),
          CommandSpan(6, 12, CommandSpanKind.title),
          CommandSpan(13, 14, CommandSpanKind.number),
        ],
        text,
      );
      expect(_parts(text, merged), <String>['title:хлеб, молоко', 'number:5']);
    });
  });
}
