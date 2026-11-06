import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/personas/persona.dart';
import 'package:local_assistant/core/replies/reply_library.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

/// Коннектор с заданным здоровьем: «Как дела?» должен о нём рассказать.
final class _SickConnector implements Connector, ConnectorHealth {
  _SickConnector(this.report);

  /// Отчёт или исключение, которое бросит проверка.
  final FutureOr<HealthReport> Function() report;

  int checks = 0;

  @override
  ConnectorInfo get info => const ConnectorInfo(
        id: 'warehouse',
        title: 'Склад',
        description: 'Учебный склад.',
        examples: <String>['где лежит 64115'],
      );

  @override
  Future<HealthReport> health() async {
    checks++;
    return report();
  }

  @override
  ConnectorMatch? match(Utterance utterance) => null;

  @override
  Future<AssistantResponse> run(ConnectorMatch m, AssistantSession s) =>
      throw StateError('не вызывается');
}

/// Подключение без [ConnectorHealth]: проверить его нельзя.
final class _UncheckedConnector implements Connector {
  @override
  ConnectorInfo get info => const ConnectorInfo(
        id: 'unchecked',
        title: 'Склад без проверки',
        description: 'Без проверки здоровья.',
        requiresNetwork: true,
      );

  @override
  ConnectorMatch? match(Utterance utterance) => null;

  @override
  Future<AssistantResponse> run(ConnectorMatch m, AssistantSession s) =>
      throw StateError('не вызывается');
}

String _pack(
  String id,
  List<Map<String, Object?>> entries, {
  String type = 'jokes',
}) =>
    jsonEncode(<String, Object?>{
      'format': 'assistant-pack/1',
      'id': id,
      'type': type,
      'title': 'Пак $id',
      'author': 'Тест',
      'language': 'ru',
      'version': '1.0.0',
      'entries': entries,
    });

final String _basicJokes =
    File('assets/packs/jokes_basic.json').readAsStringSync();

final class _Fixture {
  _Fixture(this.assistant, this.tasks, this.talk, this.registry);

  final AssistantController assistant;
  final TaskService tasks;
  final TalkConnector talk;
  final ExtensionRegistry registry;

  Future<AssistantResponse> say(String text, {String? addressee}) =>
      assistant.handle(text, addressee: addressee);
}

Future<_Fixture> _fixture({
  DateTime? now,
  List<String>? packs,
  PersonaSettings personas = const PersonaSettings(),
  List<Connector> extra = const <Connector>[],
}) async {
  final clock = FixedClock(now ?? DateTime(2026, 11, 4, 12));
  final tasks = TaskService(
    repository: InMemoryTaskRepository(),
    clock: clock,
  );
  final talk = TalkConnector(taskService: tasks);
  final store = PackStore.memory(builtIn: packs ?? <String>[_basicJokes]);
  await store.load();
  final registry = ExtensionRegistry(
    connectors: <Connector>[
      TasksConnector(taskService: tasks, parser: ScenarioParser(clock: clock)),
      const CalculatorConnector(),
      talk,
      ...extra,
    ],
    packs: store,
  );
  final assistant = AssistantController(
    extensions: registry,
    clock: clock,
    personas: personas,
  );
  return _Fixture(assistant, tasks, talk, registry);
}

Task _task(String title, {DateTime? due}) => Task(
      id: 'id-$title',
      title: title,
      status: TaskStatus.planned,
      priority: TaskPriority.normal,
      dueAt: due,
      duePrecision: DuePrecision.date,
      createdAt: DateTime(2026, 11, 1),
      updatedAt: DateTime(2026, 11, 1),
    );

void main() {
  group('распознаёт реплику только целиком', () {
    const talk = <String, TalkTopic>{
      'привет': TalkTopic.greet,
      'Здравствуйте!': TalkTopic.greet,
      'добрый вечер': TalkTopic.greet,
      'хай': TalkTopic.greet,
      'йо': TalkTopic.greet,
      '👋': TalkTopic.greet,
      'пока': TalkTopic.bye,
      'до завтра': TalkTopic.bye,
      'спокойной ночи': TalkTopic.bye,
      'спасибо': TalkTopic.thanks,
      'спс': TalkTopic.thanks,
      'благодарю': TalkTopic.thanks,
      'как дела?': TalkTopic.howAreYou,
      'как ты': TalkTopic.howAreYou,
      'как жизнь': TalkTopic.howAreYou,
      'привет, как дела?': TalkTopic.howAreYou,
      'кто ты': TalkTopic.whoAreYou,
      'как тебя зовут': TalkTopic.whoAreYou,
      'ты кто такая?': TalkTopic.whoAreYou,
      'что ты умеешь': TalkTopic.capabilities,
      'помощь': TalkTopic.capabilities,
      'help': TalkTopic.capabilities,
      'расскажи шутку': TalkTopic.joke,
      'пошути': TalkTopic.joke,
      'анекдот': TalkTopic.joke,
      'каламбур': TalkTopic.joke,
      'ещё шутку': TalkTopic.joke,
      'ок': TalkTopic.reaction,
      'понял': TalkTopic.reaction,
      'круто': TalkTopic.reaction,
      '👍': TalkTopic.reaction,
      'ты тупой': TalkTopic.rude,
      'дурак': TalkTopic.rude,
      'говори короче': TalkTopic.setting,
      'давай на ты': TalkTopic.setting,
      'без смайликов': TalkTopic.setting,
      'шути меньше': TalkTopic.setting,
      'Noda будь основной': TalkTopic.setting,
      'пусть отвечает Рио': TalkTopic.setting,
      // Вступление и другая реплика: важнее вторая.
      'привет, говори короче': TalkTopic.setting,
      'спасибо, пока': TalkTopic.bye,
      'спасибо и пока': TalkTopic.bye,
      'привет ты тупой': TalkTopic.rude,
      'спасибо, дурак': TalkTopic.rude,
      'ну всё, пока': TalkTopic.bye,
      'можно без эмодзи': TalkTopic.setting,
      'не шути больше': TalkTopic.setting,
      'ты кто вообще': TalkTopic.whoAreYou,
      'а ты кто': TalkTopic.whoAreYou,
      'всем привет': TalkTopic.greet,
      'привет, Нода, как дела?': TalkTopic.howAreYou,
    };
    for (final MapEntry(key: text, value: topic) in talk.entries) {
      test('«$text» — ${topic.name}', () {
        expect(TalkPhrases.recognize(text)?.topic, topic);
      });
    }

    const notTalk = <String>[
      'пока не забыл, купить хлеб',
      'привет, добавь задачу купить хлеб',
      'спасибо, перенеси отчёт на завтра',
      'до завтра сдать отчёт',
      'ок 15:00',
      'купить дуракам подарок',
      'добавь задачу рассказать шутку',
      'расскажи про задачи',
      'привет, пока не забыл купить хлеб',
      'спасибо, купить молоко',
      'привет, Нода, добавь задачу хлеб',
      '',
    ];
    for (final text in notTalk) {
      test('не беседа: «$text»', () {
        expect(TalkPhrases.recognize(text), isNull);
      });
    }

    test('«каламбур» просит именно каламбур, «доброе утро» — утро', () {
      expect(TalkPhrases.recognize('каламбур')!.pun, isTrue);
      expect(
        TalkPhrases.recognize('доброе утро')!.saidPart,
        DayPart.morning,
      );
      expect(TalkPhrases.recognize('спокойной ночи')!.night, isTrue);
    });

    test('имя в любом месте реплики — к кому обратились', () {
      expect(TalkPhrases.recognize('спасибо, Нода')!.persona, 'noda');
      expect(TalkPhrases.recognize('как дела, Нода?')!.persona, 'noda');
      expect(
        TalkPhrases.recognize('привет, Рио, говори короче')!.persona,
        'rio',
      );
      expect(TalkPhrases.recognize('спасибо')!.persona, isNull);
      expect(TalkPhrases.recognize('Нода, спасибо, Рио'), isNull);
    });

    test('имя в просьбе об основном — кого назначить', () {
      expect(TalkPhrases.recognize('пусть отвечает Рио')!.persona, 'rio');
      expect(TalkPhrases.recognize('Noda будь основной')!.persona, 'noda');
      expect(TalkPhrases.recognize('будь основной')!.persona, isNull);
    });
  });

  group('маршрутизация: беседа не перехватывает команды', () {
    test('«привет, добавь задачу купить хлеб» создаёт задачу', () async {
      final f = await _fixture();

      final response = await f.say('привет, добавь задачу купить хлеб');

      expect(response.intent, 'task.create');
      expect(response.task?.title, 'Купить хлеб');
    });

    test('«пока не забыл, купить хлеб» — задача, а не прощание', () async {
      final f = await _fixture();

      final response = await f.say('пока не забыл, купить хлеб');

      expect(response.intent, 'task.create');
      expect(response.task?.title, 'Купить хлеб');
    });

    test('«привет» — беседа; при выключенной беседе — «не понял»', () async {
      final f = await _fixture();

      expect((await f.say('привет')).intent, TalkConnector.greetCommand);

      f.registry.apply(f.registry.choiceWith(TalkConnector.id, false));
      final off = await f.say('привет');
      expect(off.intent, 'unknown');
      expect(off.message, TasksConnector.unknownResponse.message);
    });

    test('совпадение беседы — на крайний случай', () {
      final match = TalkConnector().match(
        Utterance.analyze('привет', now: DateTime(2026, 11, 4)),
      );
      expect(match?.fallback, isTrue);
      expect(match?.commandId, TalkConnector.greetCommand);
    });

    test('«спасибо» после вопроса — не «да»: переспрос, задача остаётся',
        () async {
      final f = await _fixture();
      final bread = (await f.say('Добавь задачу купить хлеб')).task!;
      final question = await f.say('я купил хлеб');
      expect(question.status, AssistantStatus.needsClarification);

      final thanks = await f.say('спасибо');

      expect(thanks.replyId, 'common.confirm.unclear');
      expect(thanks.status, AssistantStatus.needsClarification);
      expect(
          thanks.message,
          'Пока ничего не сделал. Ответьте, пожалуйста: '
          '«да» или «нет»?');
      expect(f.assistant.session.pendingConfirmation, isNotNull);
      expect(
        (await f.tasks.listActive()).map((Task t) => t.id),
        contains(bread.id),
      );
      // Вопрос в силе: «да» теперь завершает задачу.
      final yes = await f.say('да');
      expect(yes.intent, 'task.complete');
      expect(
        (await f.tasks.listActive()).map((Task t) => t.id),
        isNot(contains(bread.id)),
      );
    });

    for (final reaction in <String>[
      'хорошо',
      'ладно',
      'понял',
      'отлично',
      'супер',
      'ясно',
      'круто',
      '🙂',
      'спасибо, Нода',
    ]) {
      test('«$reaction» после вопроса — переспрос, а не отклик', () async {
        final f = await _fixture();
        final bread = (await f.say('Добавь задачу купить хлеб')).task!;
        await f.say('я купил хлеб');

        final response = await f.say(reaction);

        expect(response.replyId, 'common.confirm.unclear', reason: reaction);
        expect(f.assistant.session.pendingConfirmation, isNotNull);
        expect(
          (await f.tasks.listActive()).map((Task t) => t.id),
          contains(bread.id),
        );
        // Без вопроса это обычный отклик.
        await f.say('нет');
        expect(
          (await f.say(reaction)).intent,
          anyOf(TalkConnector.reactionCommand, TalkConnector.thanksCommand),
        );
      });
    }

    test('«хорошо» после вопроса о жалобе — переспрос, вопрос в силе',
        () async {
      final sick = _SickConnector(
        () => const HealthReport(HealthStatus.down, detail: 'нет связи'),
      );
      final f = await _fixture(extra: <Connector>[sick]);
      await f.say('как дела?');

      final ok = await f.say('хорошо');
      expect(ok.replyId, 'common.confirm.unclear');
      final yes = await f.say('да');
      expect(yes.replyId, 'talk.complaint.later');
    });

    test('другая реплика беседы после вопроса снимает его, как раньше',
        () async {
      final f = await _fixture();
      await f.say('Добавь задачу купить хлеб');
      await f.say('я купил хлеб');

      final response = await f.say('как дела?');

      expect(response.intent, TalkConnector.howAreYouCommand);
      expect(f.assistant.session.pendingConfirmation, isNull);
    });

    test('«👍» после вопроса — согласие, без вопроса — отклик', () async {
      final f = await _fixture();
      final bread = (await f.say('Добавь задачу купить хлеб')).task!;

      expect((await f.say('👍')).intent, TalkConnector.reactionCommand);

      await f.say('я купил хлеб');
      final done = await f.say('👍');
      expect(done.task?.id, bread.id);
      expect(await f.tasks.listActive(), isEmpty);
    });

    test('«да, спасибо большое» после вопроса — согласие', () async {
      final f = await _fixture();
      final bread = (await f.say('Добавь задачу купить хлеб')).task!;
      await f.say('я купил хлеб');

      final done = await f.say('Ага, спасибо большое');

      expect(done.task?.id, bread.id);
    });
  });

  group('приветствия', () {
    test('по времени суток из часов', () async {
      for (final (hour, greeting) in const <(int, String)>[
        (8, 'Доброе утро'),
        (13, 'Добрый день'),
        (20, 'Добрый вечер'),
        (2, 'Доброй ночи'),
      ]) {
        final f = await _fixture(now: DateTime(2026, 11, 4, hour));
        final response = await f.say('привет');
        expect(response.message, '$greeting! Готов помочь.', reason: '$hour');
        expect(response.personaId, 'rio');
      }
    });

    test('«доброе утро» в 22:00: поправка только в дружеском стиле', () async {
      final f = await _fixture(now: DateTime(2026, 11, 4, 22));

      final rio = await f.say('доброе утро');
      expect(rio.replyId, 'talk.greet');
      expect(rio.message, 'Добрый вечер! Готов помочь.');

      final noda = await f.say('Noda, доброе утро');
      expect(noda.personaId, 'noda');
      expect(noda.replyId, 'talk.greet.mismatch');
      expect(noda.message, contains('22:00'));
      expect(noda.message, contains('Доброе утро'));
      expect(noda.message, contains('Добрый вечер'));
    });

    test('«добрый день» в 18:30 — соседнее время, без поправки', () async {
      final f = await _fixture(
        now: DateTime(2026, 11, 4, 18, 30),
        personas: const PersonaSettings(mainPersona: 'noda'),
      );

      final response = await f.say('добрый день');

      expect(response.replyId, 'talk.greet');
    });

    test('Noda говорит о себе в женском роде', () async {
      final f = await _fixture(
        personas: const PersonaSettings(
          mainPersona: 'noda',
          styles: <String, String>{'rio': 'neutral', 'noda': 'neutral'},
        ),
      );

      expect((await f.say('привет')).message, 'Добрый день! Готова помочь.');
    });

    test('прощание и благодарность', () async {
      final f = await _fixture();

      expect(
        (await f.say('пока')).message,
        'До свидания! Возвращайтесь, когда понадобится помощь.',
      );
      expect((await f.say('спокойной ночи')).message, 'Спокойной ночи!');
      expect((await f.say('спасибо')).message, 'Пожалуйста! Обращайтесь.');
      expect((await f.say('ок')).intent, TalkConnector.reactionCommand);
    });

    test('грубость — спокойный ответ, один вариант в каждом стиле', () async {
      for (final style in ReplyStyles.builtIn) {
        expect(
          ReplyLibrary.builtIn.variants('talk.rude', style),
          hasLength(1),
          reason: style,
        );
      }
      final f = await _fixture();
      final response = await f.say('ты тупой');
      expect(response.intent, TalkConnector.rudeCommand);
      expect(response.message, contains('попробуем ещё раз'));
    });
  });

  group('«Как дела?» — из настоящего состояния', () {
    test('всё работает, задач нет', () async {
      final f = await _fixture();

      final response = await f.say('как дела?');

      expect(response.intent, TalkConnector.howAreYouCommand);
      expect(response.status, AssistantStatus.completed);
      expect(
        response.message,
        'У меня всё в порядке: все навыки и подключения работают. '
        'Активных задач нет.',
      );
    });

    test('считает активные и просроченные задачи', () async {
      final repository = InMemoryTaskRepository();
      await repository.save(_task('Отчёт', due: DateTime(2026, 11, 2)));
      await repository.save(_task('Счёт', due: DateTime(2026, 11, 3)));
      await repository.save(_task('Хлеб'));
      final tasks = TaskService(
        repository: repository,
        clock: FixedClock(DateTime(2026, 11, 4, 12)),
      );
      final talk = TalkConnector(taskService: tasks);
      final assistant = AssistantController(
        extensions: ExtensionRegistry(connectors: <Connector>[talk]),
        clock: FixedClock(DateTime(2026, 11, 4, 12)),
      );

      final response = await assistant.handle('как дела');

      expect(
        response.message,
        'У меня всё в порядке: все навыки и подключения работают. '
        'У вас 3 активные задачи, из них просрочено: 2.',
      );
    });

    test('проблема коннектора: что не так и вопрос о жалобе; «да»', () async {
      final sick = _SickConnector(
        () => HealthReport(
          HealthStatus.down,
          detail: 'нет связи с сервером',
          since: DateTime(2026, 11, 4, 9, 5),
        ),
      );
      final f = await _fixture(extra: <Connector>[sick]);

      final response = await f.say('как дела?');

      expect(response.status, AssistantStatus.needsClarification);
      expect(
        response.message,
        contains('«Склад» не работает: нет связи с сервером (с 9:05)'),
      );
      expect(response.message, endsWith('Передать жалобу администратору?'));
      expect(
        f.assistant.session.pendingConfirmation?.connectorId,
        TalkConnector.id,
      );

      final yes = await f.say('да');
      expect(yes.intent, TalkConnector.complaintCommand);
      expect(yes.replyId, 'talk.complaint.later');
      expect(yes.message, contains('сервере коннектора'));
      expect(yes.message, contains('«Склад» не работает'));
      expect(f.assistant.session.pendingConfirmation, isNull);
    });

    test('«нет» — не передаёт; выключенный коннектор не проверяется', () async {
      final sick = _SickConnector(
        () => const HealthReport(
          HealthStatus.degraded,
          detail: 'медленно отвечает',
        ),
      );
      final f = await _fixture(extra: <Connector>[sick]);

      final response = await f.say('как дела');
      expect(response.message, contains('«Склад» работает с перебоями'));
      final no = await f.say('нет');
      expect(no.message, 'Хорошо, не передаю.');

      f.registry.apply(f.registry.choiceWith('warehouse', false));
      final checks = sick.checks;
      final ok = await f.say('как дела');
      expect(ok.status, AssistantStatus.completed);
      expect(sick.checks, checks);
    });

    test('упавшая проверка — тоже проблема, вчерашняя дата с днём', () async {
      final broken = _SickConnector(() => throw StateError('сломалось'));
      final f = await _fixture(extra: <Connector>[broken]);

      final response = await f.say('как дела');

      expect(response.message, contains('проверка не удалась'));
      expect(
        TalkConnector.describe(
          'Склад',
          HealthReport(HealthStatus.down, since: DateTime(2026, 11, 3, 18)),
          DateTime(2026, 11, 4, 12),
        ),
        '«Склад» не работает (с 03.11 18:00)',
      );
    });

    test('задачи, калькулятор и беседа здоровы', () async {
      final f = await _fixture();
      for (final connector in f.registry.connectors) {
        final report = await (connector as ConnectorHealth).health();
        expect(report.status, HealthStatus.ok, reason: connector.info.id);
      }
    });
  });

  group('«кто ты» и «что умеешь»', () {
    test('дуэт: основной и второй представляются по-разному', () async {
      final f = await _fixture();

      final rio = await f.say('кто ты');
      expect(rio.replyId, 'talk.who.main');
      expect(rio.message, startsWith('Я Rio, основной помощник'));
      expect(rio.message, contains('Noda'));

      final noda = await f.say('кто ты', addressee: 'noda');
      expect(noda.replyId, 'talk.who.secondary');
      expect(noda.personaId, 'noda');
      expect(noda.message, contains('Rio'));
    });

    test('соло: единственный помощник', () async {
      final f = await _fixture(
        personas: const PersonaSettings(
          mode: AssistantMode.solo,
          soloPersona: 'noda',
          styles: <String, String>{'rio': 'neutral', 'noda': 'neutral'},
        ),
      );

      final response = await f.say('как тебя зовут?');

      expect(
        response.message,
        'Я Noda, ваш помощник: отвечаю на сообщения, веду задачи и считаю.',
      );
    });

    test('«что умеешь» — только включённое, по примеру', () async {
      final f = await _fixture();

      final all = await f.say('что ты умеешь');
      expect(all.message, contains('«Задачи» — например'));
      expect(all.message, contains('«Калькулятор» — например'));
      expect(all.message, contains('«Беседа» — например'));

      f.registry.apply(f.registry.choiceWith(CalculatorConnector.id, false));
      final without = await f.say('что ты умеешь');
      expect(without.message, isNot(contains('Калькулятор')));
      expect(without.message, contains('«Задачи»'));
    });
  });

  group('шутки из паков', () {
    test('нет включённого пака шуток — говорит, как включить', () async {
      final f = await _fixture(packs: <String>[]);

      final response = await f.say('расскажи шутку');

      expect(response.replyId, 'talk.joke.none');
      expect(response.message, contains('«Настройки → Расширения»'));

      final g = await _fixture();
      g.registry.apply(g.registry.choiceWith('jokes.basic', false));
      expect((await g.say('пошути')).replyId, 'talk.joke.none');
    });

    test('шутка из пака, без повторов среди последних 10', () async {
      final f = await _fixture();
      final texts = <String>{
        for (final entry in f.registry.packEntries(type: 'jokes')) entry.text,
      };
      final told = <String>[];
      for (var i = 0; i < 12; i++) {
        final response = await f.say('расскажи шутку');
        expect(response.replyId, 'talk.joke');
        told.add(response.message);
      }
      for (final message in told) {
        expect(texts.any(message.contains), isTrue, reason: message);
      }
      for (var i = 0; i < told.length; i++) {
        final window = told.sublist(i < 10 ? 0 : i - 9, i);
        expect(window, isNot(contains(told[i])), reason: '№$i');
      }
    });

    test('маленький пак: повтор только после всех, самой давней', () async {
      final f = await _fixture(
        packs: <String>[
          _pack('jokes.two', <Map<String, Object?>>[
            <String, Object?>{'id': 'a', 'text': 'Шутка А.'},
            <String, Object?>{'id': 'b', 'text': 'Шутка Б.'},
          ]),
        ],
      );

      final first = (await f.say('пошути')).message;
      final second = (await f.say('пошути')).message;
      final third = (await f.say('пошути')).message;

      expect(first, isNot(second));
      expect(third, first);
    });

    test('по помощнику и стилю записи', () async {
      final f = await _fixture(
        packs: <String>[
          _pack('jokes.mixed', <Map<String, Object?>>[
            <String, Object?>{
              'id': 'r',
              'text': 'Шутка для Rio.',
              'persona': 'rio',
            },
            <String, Object?>{
              'id': 'n',
              'text': 'Шутка для Noda.',
              'persona': 'noda',
              'styles': <String>['friendly'],
            },
            <String, Object?>{
              'id': 'b',
              'text': 'Деловая шутка Noda.',
              'persona': 'noda',
              'styles': <String>['business'],
            },
          ]),
        ],
      );

      expect((await f.say('анекдот')).message, 'Шутка для Rio.');
      final noda = await f.say('Нода, анекдот');
      expect(noda.message, contains('Шутка для Noda.'));
    });

    test('«каламбур» — из пака каламбуров или с меткой', () async {
      final f = await _fixture(
        packs: <String>[
          _basicJokes,
          _pack(
            'puns.extra',
            <Map<String, Object?>>[
              <String, Object?>{'id': 'p', 'text': 'Каламбур из пака.'},
            ],
            type: 'puns',
          ),
        ],
      );
      final puns = <String>{
        'Каламбур из пака.',
        for (final entry in f.registry.packEntries(tags: <String>{'каламбур'}))
          entry.text,
      };

      for (var i = 0; i < 4; i++) {
        final message = (await f.say('каламбур')).message;
        expect(puns.any(message.contains), isTrue, reason: message);
      }
    });
  });

  group('частота шуток: только приветствие и «спасибо»', () {
    Future<List<bool>> puns(JokeFrequency jokes) async {
      final f = await _fixture(personas: PersonaSettings(jokes: jokes));
      final result = <bool>[];
      for (var i = 0; i < 8; i++) {
        final response = await f.say(i.isEven ? 'привет' : 'спасибо');
        result.add(response.message.contains('аламбур'));
      }
      return result;
    }

    test('«нет» — никогда', () async {
      expect(await puns(JokeFrequency.off), everyElement(isFalse));
    });

    test('«изредка» — каждый четвёртый раз', () async {
      expect(
        await puns(JokeFrequency.rare),
        <bool>[false, false, false, true, false, false, false, true],
      );
    });

    test('«чаще» — каждый второй раз', () async {
      expect(
        await puns(JokeFrequency.normal),
        <bool>[false, true, false, true, false, true, false, true],
      );
    });

    test('ответы задач и калькулятора — без шуток', () async {
      final f = await _fixture(
        personas: const PersonaSettings(jokes: JokeFrequency.normal),
      );
      for (var i = 0; i < 4; i++) {
        final created = await f.say('Добавь задачу дело $i');
        expect(created.message, 'Создал задачу «Дело $i».');
        expect((await f.say('2+2')).message, '2 + 2 = 4');
      }
    });
  });

  group('просьбы о стиле меняют настройки', () {
    test('«говори короче» — стиль того, кто отвечает, ответ новым голосом',
        () async {
      final f = await _fixture();

      final response = await f.say('говори короче');

      expect(response.intent, TalkConnector.settingCommand);
      expect(response.settingsChange, isNotNull);
      expect(f.assistant.personas.styleOf(Personas.rio), ReplyStyles.brief);
      expect(f.assistant.personas.styleOf(Personas.noda), 'friendly');
      expect(response.message, 'Понял. Коротко.');
      expect((await f.say('Добавь задачу купить хлеб')).message, isNot(''));
    });

    test('обращение по имени меняет стиль названного', () async {
      final f = await _fixture();

      await f.say('Noda, говори официально');

      expect(f.assistant.personas.styleOf(Personas.noda), 'business');
      expect(f.assistant.personas.styleOf(Personas.rio), 'neutral');
    });

    final cases = <String, bool Function(PersonaSettings)>{
      'говори подробнее': (PersonaSettings p) =>
          p.styleOf(Personas.rio) == 'neutral',
      'давай повеселее': (PersonaSettings p) =>
          p.styleOf(Personas.rio) == 'friendly',
      'говори по-деловому': (PersonaSettings p) =>
          p.styleOf(Personas.rio) == 'business',
      'давай на ты': (PersonaSettings p) => p.address == ReplyAddress.informal,
      'без смайликов': (PersonaSettings p) => !p.emoji,
      'шути больше': (PersonaSettings p) => p.jokes == JokeFrequency.normal,
      'шути меньше': (PersonaSettings p) => p.jokes == JokeFrequency.off,
      'не шути': (PersonaSettings p) => p.jokes == JokeFrequency.off,
    };
    for (final MapEntry(key: text, value: check) in cases.entries) {
      test('«$text»', () async {
        final f = await _fixture(
          personas: const PersonaSettings(
            styles: <String, String>{'rio': 'brief', 'noda': 'friendly'},
          ),
        );
        final response = await f.say(text);
        expect(check(f.assistant.personas), isTrue);
        expect(
          check(response.settingsChange!.apply(const PersonaSettings())),
          isTrue,
          reason: 'изменение применяется к любым настройкам',
        );
      });
    }

    test('«на вы» и «со смайликами» возвращают обратно', () async {
      final f = await _fixture(
        personas: const PersonaSettings(
          address: ReplyAddress.informal,
          emoji: false,
        ),
      );

      final formal = await f.say('на вы');
      expect(formal.message, 'Хорошо, теперь на «вы».');
      await f.say('можно со смайликами');

      expect(f.assistant.personas.address, ReplyAddress.formal);
      expect(f.assistant.personas.emoji, isTrue);
    });

    test('уже так — ничего не меняет', () async {
      final f = await _fixture();

      final response = await f.say('на вы');

      expect(response.replyId, 'talk.set.already');
      expect(response.settingsChange, isNull);
      expect(f.assistant.personas, const PersonaSettings());
    });

    test('«Noda будь основной» и «пусть отвечает Рио» в дуэте', () async {
      final f = await _fixture();

      final noda = await f.say('Noda будь основной');
      expect(f.assistant.personas.mainPersona, 'noda');
      expect(noda.personaId, 'noda');
      expect(noda.message, contains('Noda'));
      expect((await f.say('привет')).personaId, 'noda');

      final rio = await f.say('пусть отвечает Рио');
      expect(f.assistant.personas.mainPersona, 'rio');
      expect(rio.personaId, 'rio');
      expect((await f.say('привет')).personaId, 'rio');
    });

    test('в соло — кто отвечает', () async {
      final f = await _fixture(
        personas: const PersonaSettings(mode: AssistantMode.solo),
      );

      await f.say('пусть отвечает Нода');

      expect(f.assistant.personas.soloPersona, 'noda');
      expect(f.assistant.personas.mainPersona, 'rio');
      expect((await f.say('привет')).personaId, 'noda');
    });

    test('«без смайликов» в дружеском стиле — подтверждение без эмодзи',
        () async {
      final f = await _fixture();

      final response = await f.say('Нода, без смайликов');

      expect(ReplyTemplate.pictographs.hasMatch(response.message), isFalse);
      final greet = await f.say('Нода, привет');
      expect(ReplyTemplate.pictographs.hasMatch(greet.message), isFalse);
    });

    test('изменение применяется к настройкам на момент применения', () {
      const change = PersonaSettingsChange(emoji: false);
      const changedMeanwhile = PersonaSettings(mainPersona: 'noda');

      final result = change.apply(changedMeanwhile);

      expect(result.mainPersona, 'noda');
      expect(result.emoji, isFalse);
      expect(change.isNoOpFor(result), isTrue);
    });
  });

  group('вступление перед командой не попадает в название', () {
    const cases = <String, String>{
      'ну привет, добавь задачу хлеб': 'Хлеб',
      'привет, Нода, добавь задачу хлеб': 'Хлеб',
      'привет как дела добавь задачу хлеб': 'Хлеб',
      'круто, добавь задачу молоко': 'Молоко',
      'отлично, добавь задачу молоко': 'Молоко',
      'привет, пока не забыл купить хлеб': 'Купить хлеб',
      'всем привет, купить хлеб': 'Купить хлеб',
      'спасибо большое, добавь задачу сыр': 'Сыр',
      'эй, привет! добавь задачу кефир': 'Кефир',
    };
    for (final MapEntry(key: text, value: title) in cases.entries) {
      test('«$text» → «$title»', () async {
        final f = await _fixture();
        final response = await f.say(text);
        expect(response.intent, 'task.create', reason: response.message);
        expect(response.task?.title, title);
      });
    }

    test('«да, добавь задачу молоко» после вопроса о жалобе', () async {
      final sick = _SickConnector(
        () => const HealthReport(HealthStatus.down, detail: 'нет связи'),
      );
      final f = await _fixture(extra: <Connector>[sick]);
      await f.say('как дела?');
      final response = await f.say('да, добавь задачу молоко');
      expect(response.task?.title, 'Молоко');
    });

    test('отклик без знака — часть названия: «хорошо выспаться»', () async {
      final f = await _fixture();
      final response = await f.say('добавь задачу хорошо выспаться');
      expect(response.task?.title, 'Хорошо выспаться');
    });

    for (final (text, answer) in <(String, String)>[
      ('привет, сколько будет 2+2', '4'),
      ('привет! 2+2', '4'),
      ('спасибо, сколько будет 3*3', '9'),
      ('спасибо 2+2', '4'),
      ('добрый вечер, посчитай 10/4', '2,5'),
      ('привет, -2+3', '1'),
    ]) {
      test('калькулятор: «$text»', () async {
        final f = await _fixture();
        final response = await f.say(text);
        expect(response.intent, CalculatorConnector.commandId);
        expect(response.message, endsWith('= $answer'));
      });
    }
  });

  group('имя помощника в конце реплики — отвечает названный', () {
    for (final text in <String>[
      'спасибо, Нода',
      'привет, Нода',
      'Доброе утро, Нода',
      'как дела, Нода?',
      'что ты умеешь, Нода?',
      'расскажи шутку, Нода',
      'кто ты, Нода?',
    ]) {
      test('дуэт: «$text» — Noda', () async {
        final f = await _fixture();
        final response = await f.say(text);
        expect(response.personaId, 'noda', reason: response.message);
      });
    }

    test('«кто ты, Нода?» — Noda, второй помощник', () async {
      final f = await _fixture();
      final response = await f.say('кто ты, Нода?');
      expect(response.replyId, 'talk.who.secondary');
      expect(response.message, contains('Noda'));
    });

    test('соло: имя другого — просто текст, отвечает выбранный', () async {
      final f = await _fixture(
        personas: const PersonaSettings(mode: AssistantMode.solo),
      );
      final response = await f.say('спасибо, Нода');
      expect(response.personaId, 'rio');
    });

    test('«говори короче, Нода» — стиль Noda', () async {
      final f = await _fixture();
      final response = await f.say('говори короче, Нода');
      expect(response.personaId, 'noda');
      expect(f.assistant.personas.styleOf(Personas.noda), ReplyStyles.brief);
      expect(f.assistant.personas.styleOf(Personas.rio), ReplyStyles.neutral);
    });
  });

  group('к кому обратились, тот и продолжает', () {
    final mixed = _pack('jokes.mixed', <Map<String, Object?>>[
      <String, Object?>{'id': 'r', 'text': 'Шутка для Rio.', 'persona': 'rio'},
      <String, Object?>{
        'id': 'n',
        'text': 'Шутка для Noda.',
        'persona': 'noda',
      },
    ]);

    /// Разговор в одном чате: адресат после ответа — как в интерфейсе.
    Future<List<AssistantResponse>> chat(
      _Fixture f,
      List<String> messages,
    ) async {
      String? addressee;
      final responses = <AssistantResponse>[];
      for (final message in messages) {
        final response = await f.say(message, addressee: addressee);
        addressee = f.assistant.addresseeAfter(response, current: addressee);
        responses.add(response);
      }
      return responses;
    }

    test('«Нода, расскажи шутку» → «ещё шутку» — снова Noda, из её шуток',
        () async {
      final f = await _fixture(packs: <String>[mixed]);
      final responses = await chat(f, <String>[
        'Нода, расскажи шутку',
        'ещё шутку',
        'расскажи ещё шутку',
        'Рио, расскажи шутку',
        'ещё шутку',
      ]);
      expect(
        responses.map((AssistantResponse r) => r.personaId),
        <String>['noda', 'noda', 'noda', 'rio', 'rio'],
      );
      for (final response in responses.take(3)) {
        expect(response.message, contains('Шутка для Noda.'));
        // Дружеский стиль Noda по умолчанию.
        expect(response.message, isNot(contains('Шутка для Rio.')));
      }
      for (final response in responses.skip(3)) {
        expect(response.message, contains('Шутка для Rio.'));
      }
    });

    test('имя в конце реплики тоже закрепляет адресата', () async {
      final f = await _fixture(packs: <String>[mixed]);
      final responses = await chat(f, <String>[
        'расскажи шутку, Нода',
        'ещё шутку',
        'спасибо, Рио',
        'ещё шутку',
      ]);
      expect(
        responses.map((AssistantResponse r) => r.personaId),
        <String>['noda', 'noda', 'rio', 'rio'],
      );
      expect(
        responses.map((AssistantResponse r) => r.addressedPersonaId),
        <String?>['noda', null, 'rio', null],
      );
    });

    test('«говори короче, Нода», дальше без имени — Noda кратко', () async {
      final f = await _fixture();
      final responses = await chat(f, <String>[
        'говори короче, Нода',
        'Добавь задачу купить хлеб',
      ]);
      expect(responses.last.personaId, 'noda');
      expect(f.assistant.personas.styleOf(Personas.noda), ReplyStyles.brief);
      expect(f.assistant.personas.styleOf(Personas.rio), ReplyStyles.neutral);
    });

    test('«пусть отвечает Рио» после обращения к Noda — отвечает Rio',
        () async {
      final f = await _fixture();
      final responses = await chat(f, <String>[
        'Нода, привет',
        'Noda будь основной',
        'пусть отвечает Рио',
        '2+2',
      ]);
      expect(responses[2].addressedPersonaId, isNull, reason: 'не обращение');
      expect(responses.last.personaId, 'rio');
      expect(f.assistant.personas.mainPersona, 'rio');
    });

    test('«пусть отвечает Рио», когда Рио и так основной, — снимает Noda',
        () async {
      for (final request in <String>[
        'пусть отвечает Рио',
        'Нода, пусть отвечает Рио',
      ]) {
        final f = await _fixture();
        String? addressee;
        final responses = <AssistantResponse>[];
        for (final message in <String>['Нода, привет', request, '2+2']) {
          final response = await f.say(message, addressee: addressee);
          addressee = f.assistant.addresseeAfter(response, current: addressee);
          responses.add(response);
          if (message == request) {
            expect(addressee, isNull, reason: request);
          }
        }
        expect(responses[1].replyId, 'talk.set.already', reason: request);
        expect(responses[1].personaId, 'rio', reason: request);
        expect(responses[1].settingsChange, isNull, reason: request);
        expect(responses.last.personaId, 'rio', reason: request);
        expect(f.assistant.personas.mainPersona, 'rio');
      }
    });

    test('«Рио, пусть отвечает Нода», когда Нода основная, — снимает Rio',
        () async {
      final f = await _fixture(
        personas: const PersonaSettings(mainPersona: 'noda'),
      );
      final responses = await chat(f, <String>[
        'Рио, привет',
        'Рио, пусть отвечает Нода',
        '2+2',
      ]);
      expect(responses[1].personaId, 'noda');
      expect(responses[1].replyId, 'talk.set.already');
      expect(responses.last.personaId, 'noda');
    });

    test('соло: «пусть отвечает Рио», когда Рио выбран, — как раньше',
        () async {
      final f = await _fixture(
        personas: const PersonaSettings(mode: AssistantMode.solo),
      );
      final response = await f.say('пусть отвечает Рио');
      expect(response.replyId, 'talk.set.already');
      expect(response.personaId, 'rio');
      expect(response.addressedPersonaId, isNull);
    });

    test('«спасибо, Рио» на вопрос Noda — переспрашивает Rio, он адресат',
        () async {
      for (final ack in <String>['спасибо, Рио', 'Рио, спасибо']) {
        final f = await _fixture();
        await f.tasks.create(title: 'Купить хлеб');
        String? addressee;
        final responses = <AssistantResponse>[];
        for (final message in <String>['Нода, я купил хлеб', ack, '2+2']) {
          final response = await f.say(message, addressee: addressee);
          addressee = f.assistant.addresseeAfter(response, current: addressee);
          responses.add(response);
        }
        expect(responses[0].personaId, 'noda', reason: ack);
        expect(responses[1].replyId, 'common.confirm.unclear', reason: ack);
        expect(responses[1].personaId, 'rio', reason: ack);
        expect(responses[1].addressedPersonaId, 'rio', reason: ack);
        expect(addressee, isNull, reason: ack);
        expect(responses.last.personaId, 'rio', reason: ack);
      }
    });

    test('«да, Рио» на вопрос Noda — действие то же, отвечает Rio', () async {
      for (final yes in <String>['да, Рио', 'Рио, да']) {
        final f = await _fixture();
        await f.tasks.create(title: 'Купить хлеб');
        final responses = await chat(f, <String>[
          'Нода, я купил хлеб',
          yes,
          '2+2',
        ]);
        expect(responses[1].personaId, 'rio', reason: yes);
        expect(responses[1].addressedPersonaId, 'rio', reason: yes);
        expect(await f.tasks.listActive(), isEmpty, reason: yes);
        expect(responses.last.personaId, 'rio', reason: yes);
      }
    });

    test('«да» без имени на вопрос Noda — отвечает Noda, адресат прежний',
        () async {
      final f = await _fixture();
      await f.tasks.create(title: 'Купить хлеб');
      final responses = await chat(f, <String>[
        'Нода, я купил хлеб',
        'да',
        '2+2',
      ]);
      expect(responses[1].personaId, 'noda');
      expect(responses[1].addressedPersonaId, isNull);
      expect(responses.last.personaId, 'noda');
    });

    test('соло: шутки «ещё» — от выбранного, имя не закрепляется', () async {
      final f = await _fixture(
        packs: <String>[mixed],
        personas: const PersonaSettings(mode: AssistantMode.solo),
      );
      final responses = await chat(f, <String>[
        'Нода, расскажи шутку',
        'ещё шутку',
      ]);
      expect(
        responses.map((AssistantResponse r) => r.personaId),
        <String>['rio', 'rio'],
      );
      expect(responses.first.addressedPersonaId, isNull);
    });
  });

  group('«Как дела?» без проверки здоровья', () {
    test('не говорит «все работают» о непроверенном', () async {
      final f = await _fixture(extra: <Connector>[_UncheckedConnector()]);

      final response = await f.say('как дела');

      expect(response.replyId, 'talk.status.okUnchecked');
      expect(response.message, isNot(contains('все навыки')));
      expect(
        response.message,
        'Навыки и подключения с проверкой работают. Проверить не могу: '
        '«Склад без проверки». Активных задач нет.',
      );
    });
  });

  group('без эмодзи фразы не слипаются', () {
    // Строчная буква или «»» и сразу новое предложение с заглавной.
    final glued = RegExp(r'[а-яё0-9»] [А-ЯЁ]');

    for (final style in <String>[
      ReplyStyles.friendly,
      ReplyStyles.neutral,
      ReplyStyles.brief,
      ReplyStyles.business,
    ]) {
      test(style, () async {
        final sick = _SickConnector(
          () => const HealthReport(HealthStatus.degraded, detail: 'медленно'),
        );
        for (final extra in <List<Connector>>[
          const <Connector>[],
          <Connector>[sick],
        ]) {
          final f = await _fixture(
            extra: extra,
            personas: PersonaSettings(
              styles: <String, String>{'rio': style, 'noda': style},
              emoji: false,
              jokes: JokeFrequency.normal,
            ),
          );
          await f.say('Добавь задачу купить хлеб');
          for (var i = 0; i < 6; i++) {
            for (final text in <String>['как дела?', 'спасибо', 'привет']) {
              final message = (await f.say(text)).message;
              expect(glued.hasMatch(message), isFalse, reason: message);
              expect(
                ReplySchema.endsSentence(message),
                isTrue,
                reason: message,
              );
            }
            await f.say('нет');
          }
        }
      });
    }
  });

  test('команды беседы совпадают с темами генератора корпуса', () {
    final toml = File('tools/corpus_gen/topics/talk.toml').readAsStringSync();
    final block = RegExp(r'^intents = \[(.*?)\]', multiLine: true, dotAll: true)
        .firstMatch(toml)!
        .group(1)!;
    final intents = RegExp('"([^"]+)"')
        .allMatches(block)
        .map((RegExpMatch m) => m.group(1))
        .toSet();
    expect(intents, <String>{...TalkConnector.commands, 'unknown'});
  });

  test('примеры беседы распознаются', () {
    final talk = TalkConnector();
    for (final example in talk.info.examples) {
      expect(
        talk.match(Utterance.analyze(example, now: DateTime(2026, 11, 4))),
        isNotNull,
        reason: example,
      );
    }
  });
}
