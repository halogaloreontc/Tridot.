import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/personas/persona.dart';
import 'package:local_assistant/core/replies/reply_library.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';
import 'package:local_assistant/core/storage/task_repository.dart';

final _clock = FixedClock(DateTime(2026, 11, 4, 12));

/// Запись ждёт, пока тест не отпустит её.
final class _GatedRepository implements TaskRepository {
  final InMemoryTaskRepository _inner = InMemoryTaskRepository();
  Completer<void>? gate;

  @override
  Future<List<Task>> list() => _inner.list();

  @override
  Future<Task?> get(String id) => _inner.get(id);

  @override
  Future<void> save(Task task) async {
    await gate?.future;
    await _inner.save(task);
  }
}

(AssistantController, TaskService) _assistant({
  PersonaSettings personas = const PersonaSettings(),
  TaskRepository? repository,
}) {
  final tasks = TaskService(
    repository: repository ?? InMemoryTaskRepository(),
    clock: _clock,
  );
  return (
    AssistantController(
      connectors: <Connector>[
        TasksConnector(
          taskService: tasks,
          parser: ScenarioParser(clock: _clock),
        ),
        const CalculatorConnector(),
      ],
      clock: _clock,
      personas: personas,
    ),
    tasks,
  );
}

void main() {
  test('«Noda!», «Нода.» — обращение: отвечает Noda', () async {
    final (assistant, _) = _assistant();
    for (final text in <String>['Noda!', 'Нода.', 'Noda?']) {
      final response = await assistant.handle(text);
      expect(response.personaId, 'noda', reason: text);
      expect(response.replyId, 'common.addressed', reason: text);
    }
    final sum = await assistant.handle('Noda;2+2');
    expect(sum.personaId, 'noda');
    expect(sum.message, contains('2 + 2 = 4'));
  });

  group('дуэт', () {
    test('по умолчанию отвечает Liorio нейтрально', () async {
      final (assistant, _) = _assistant();
      final response = await assistant.handle('Добавь задачу купить хлеб');
      expect(response.personaId, 'rio');
      expect(response.message, 'Создал задачу «Купить хлеб».');
      expect(response.replyId, 'task.created');
      expect(response.values, <String, String>{'title': 'Купить хлеб'});
    });

    test('обращение по имени: имя снимается, отвечает Noda в своём стиле',
        () async {
      final (assistant, tasks) = _assistant();
      final response =
          await assistant.handle('Noda, добавь задачу купить хлеб');
      expect(response.personaId, 'noda');
      expect(response.replyId, 'task.created');
      expect(response.message, contains('«Купить хлеб»'));
      expect(response.message, isNot(contains('Noda')));
      final created = (await tasks.listActive()).single;
      expect(created.title, 'Купить хлеб', reason: 'имя не в названии');

      final rio = await assistant.handle('Лиорио: покажи задачи');
      expect(rio.personaId, 'rio');
      expect(rio.message, startsWith('Активных задач: 1.'));

      final calc = await assistant.handle('нода — сколько будет 2+2');
      expect(calc.personaId, 'noda');
      expect(calc.message, contains('2 + 2 = 4'));
    });

    test('Noda говорит о себе в женском роде, Liorio — в мужском', () async {
      final (assistant, _) = _assistant(
        personas: const PersonaSettings(
          styles: <String, String>{'rio': 'neutral', 'noda': 'neutral'},
        ),
      );
      expect(
        (await assistant.handle('Noda, заверши купить молоко')).message,
        'Не нашла активную задачу «Купить молоко».',
      );
      expect(
        (await assistant.handle('Лиорио, заверши купить молоко')).message,
        'Не нашёл активную задачу «Купить молоко».',
      );
    });

    test('адресат из поля ввода; обращение по имени важнее', () async {
      final (assistant, _) = _assistant();
      expect(
        (await assistant.handle('покажи задачи', addressee: 'noda')).personaId,
        'noda',
      );
      expect(
        (await assistant.handle('Liorio, покажи задачи', addressee: 'noda'))
            .personaId,
        'rio',
      );
    });

    test('основной — Noda: отвечает она, второй пишет Liorio', () async {
      final (assistant, _) =
          _assistant(personas: const PersonaSettings(mainPersona: 'noda'));
      expect((await assistant.handle('покажи задачи')).personaId, 'noda');
      expect(assistant.welcome().personaId, 'noda');
      final notice = assistant.overdueNotice(<Task>[
        Task(
          id: '1',
          title: 'Отчёт',
          status: TaskStatus.planned,
          priority: TaskPriority.normal,
          dueAt: DateTime(2026, 11, 3),
          duePrecision: DuePrecision.date,
          createdAt: DateTime(2026, 11, 1),
          updatedAt: DateTime(2026, 11, 1),
        ),
      ])!;
      expect(notice.personaId, 'rio');
      expect(notice.message, 'У вас 1 просроченная задача: «Отчёт».');
    });

    test('только имя — отклик, ожидание подтверждения снимается', () async {
      final (assistant, tasks) = _assistant();
      await tasks.create(title: 'Купить хлеб');
      await assistant.handle('я купил хлеб');
      expect(assistant.session.pendingConfirmation, isNotNull);
      final response = await assistant.handle('Нода');
      expect(response.personaId, 'noda');
      expect(response.replyId, 'common.addressed');
      expect(assistant.session.pendingConfirmation, isNull);
    });
  });

  group('к кому обратились, тот и продолжает — тем же навыком', () {
    /// Разговор в одном чате: интерфейс адресата не передаёт, продолжение
    /// помнит сам помощник ([AssistantController.followUpPersonaId]).
    Future<List<AssistantResponse>> chat(
      AssistantController assistant,
      List<String> messages, {
      List<String?>? followUps,
    }) async {
      final responses = <AssistantResponse>[];
      for (final message in messages) {
        responses.add(await assistant.handle(message));
        followUps?.add(assistant.followUpPersonaId);
      }
      return responses;
    }

    test(
        '«Нода, …» — дальше тем же навыком отвечает Noda, другим — снова '
        'основной', () async {
      final (assistant, tasks) = _assistant();
      final followUps = <String?>[];
      final responses = await chat(
        assistant,
        <String>[
          'Нода, добавь задачу купить хлеб',
          'покажи задачи',
          '2+2',
          'покажи задачи',
          'Лиорио, 3+3',
          'покажи задачи',
        ],
        followUps: followUps,
      );
      expect(
        responses.map((AssistantResponse r) => r.personaId),
        <String>['noda', 'noda', 'rio', 'rio', 'rio', 'rio'],
      );
      expect(
        responses.map((AssistantResponse r) => r.addressedPersonaId),
        <String?>['noda', null, null, null, 'rio', null],
      );
      // Невидимого «закреплённого» адресата нет: другой навык — и Noda
      // уже не продолжает. Основной, который ведёт всё, не продолжает
      // «особо» — он и так отвечает.
      expect(followUps, <String?>['noda', 'noda', null, null, null, null]);
      expect((await tasks.listActive()).single.title, 'Купить хлеб');
    });

    test('обращение к основному при чужой роли — продолжает основной',
        () async {
      final (assistant, _) =
          _assistant(personas: const PersonaSettings(mainPersona: 'noda'));
      final response = await assistant.handle('Нода, 2+2');
      expect(response.personaId, 'noda');
      expect(assistant.followUpPersonaId, isNull, reason: 'основной ведёт всё');
      await assistant.handle('Лиорио, 2+2');
      expect(assistant.followUpPersonaId, 'rio');
      expect((await assistant.handle('5+5')).personaId, 'rio');
      expect((await assistant.handle('покажи задачи')).personaId, 'noda');
    });

    test('явный адресат (API) — на это сообщение, продолжения нет', () async {
      final (assistant, _) = _assistant();
      final response = await assistant.handle('2+2', addressee: 'noda');
      expect(response.personaId, 'noda');
      expect(response.addressedPersonaId, isNull);
      expect(assistant.followUpPersonaId, isNull);
      expect((await assistant.handle('3+3')).personaId, 'rio');
    });

    test('«Нода» без команды — следующая фраза ей, любым навыком', () async {
      final (assistant, _) = _assistant();
      final responses = await chat(
        assistant,
        <String>['Нода', '2+2', '3+3', 'покажи задачи'],
      );
      expect(responses.first.replyId, 'common.addressed');
      expect(
        responses.skip(1).map((AssistantResponse r) => r.personaId),
        <String>['noda', 'noda', 'rio'],
      );
    });

    test('на «да» отвечает спросивший', () async {
      final (assistant, tasks) = _assistant();
      await tasks.create(title: 'Купить хлеб');
      final question = await assistant.handle('Нода, я купил хлеб');
      expect(question.personaId, 'noda');
      expect(question.status, AssistantStatus.needsClarification);
      expect(assistant.session.pendingSpeaker, Personas.noda);
      // Даже если явно написали Liorio (API) — на «да» отвечает Noda.
      final yes = await assistant.handle('да', addressee: 'rio');
      expect(yes.personaId, 'noda');
      expect(yes.message, contains('Купить хлеб'));
      expect((await tasks.listActive()), isEmpty);
      expect(assistant.session.pendingSpeaker, isNull);
    });

    test('«Лиорио, да» на вопрос Noda: действие то же, отвечает названный',
        () async {
      final (assistant, tasks) = _assistant();
      await tasks.create(title: 'Купить хлеб');
      await assistant.handle('Нода, я купил хлеб');
      expect(assistant.session.pendingSpeaker, Personas.noda);
      final yes = await assistant.handle('Лиорио, да');
      expect(yes.personaId, 'rio');
      expect((await tasks.listActive()), isEmpty);
      // Основной ведёт всё — продолжать нечего.
      expect(assistant.followUpPersonaId, isNull);
    });

    test('смена чата снимает продолжение', () async {
      final (assistant, _) = _assistant();
      await assistant.handle('Нода, 2+2');
      expect(assistant.followUpPersonaId, 'noda');
      assistant.enterChat(sessionId: 's1');
      expect(assistant.followUpPersonaId, isNull);
      expect((await assistant.handle('3+3')).personaId, 'rio');
      await assistant.handle('Нода, 2+2');
      assistant.forgetChatSelections();
      expect(assistant.followUpPersonaId, isNull);
    });

    test('соло: имя — просто текст, продолжения нет', () async {
      final (assistant, _) = _assistant(
        personas: const PersonaSettings(mode: AssistantMode.solo),
      );
      final responses = await chat(assistant, <String>['Нода, 2+2', '3+3']);
      expect(
        responses.map((AssistantResponse r) => r.personaId),
        <String>['rio', 'rio'],
      );
      expect(responses.first.addressedPersonaId, isNull);
      expect(assistant.followUpPersonaId, isNull);
    });

    test(
        'напоминание о просрочке — от второго относительно основного, '
        'а не от адресата', () async {
      final overdue = <Task>[
        Task(
          id: '1',
          title: 'Отчёт',
          status: TaskStatus.planned,
          priority: TaskPriority.normal,
          dueAt: DateTime(2026, 11, 3),
          duePrecision: DuePrecision.date,
          createdAt: DateTime(2026, 11, 1),
          updatedAt: DateTime(2026, 11, 1),
        ),
      ];
      for (final main in <String>['rio', 'noda']) {
        final (assistant, _) =
            _assistant(personas: PersonaSettings(mainPersona: main));
        final second = main == 'rio' ? 'noda' : 'rio';
        for (final name in <String>['Лиорио', 'Нода']) {
          await assistant.handle('$name, 2+2');
          expect(
            assistant.overdueNotice(overdue)!.personaId,
            second,
            reason: 'основной $main, обратились: $name',
          );
        }
      }
    });
  });

  group('соло', () {
    test('отвечает выбранный, имя другого — просто текст', () async {
      final (assistant, tasks) = _assistant(
        personas: const PersonaSettings(
          mode: AssistantMode.solo,
          soloPersona: 'noda',
          styles: <String, String>{'rio': 'neutral', 'noda': 'neutral'},
        ),
      );
      final response = await assistant.handle('Добавь задачу купить хлеб');
      expect(response.personaId, 'noda');
      expect(response.message, 'Создала задачу «Купить хлеб».');
      final addressed = await assistant.handle(
        'Liorio, добавь задачу позвонить',
        addressee: 'rio',
      );
      expect(addressed.personaId, 'noda', reason: 'в соло один помощник');
      expect(
        (await tasks.listActive()).map((Task t) => t.title),
        isNot(contains('Позвонить')),
        reason: 'имя не снимается',
      );
      expect(assistant.overdueNotice(const <Task>[]), isNull);
    });
  });

  test('«ты» и стиль без эмодзи', () async {
    final (assistant, _) = _assistant(
      personas: const PersonaSettings(
        styles: <String, String>{'rio': 'friendly', 'noda': 'friendly'},
        address: ReplyAddress.informal,
        emoji: false,
      ),
    );
    for (var i = 0; i < 4; i++) {
      final response = await assistant.handle('Добавь задачу купить хлеб $i');
      expect(response.message, contains('«Купить хлеб $i»'));
      expect(ReplyTemplate.pictographs.hasMatch(response.message), isFalse);
    }
    final question = await assistant.handle('Перенеси её');
    expect(question.message, contains('?'));
  });

  test('соседние ответы одной записи в дружеском стиле разные', () async {
    final (assistant, _) = _assistant(
      personas: const PersonaSettings(
        styles: <String, String>{'rio': 'friendly', 'noda': 'friendly'},
      ),
    );
    final first = await assistant.handle('2+2');
    final second = await assistant.handle('2+2');
    expect(first.message, contains('2 + 2 = 4'));
    expect(second.message, contains('2 + 2 = 4'));
    expect(first.message, isNot(second.message));
  });

  test('смена настроек во время ответа: ответ договаривается прежним голосом',
      () async {
    final repository = _GatedRepository();
    final (assistant, tasks) = _assistant(repository: repository);
    repository.gate = Completer<void>();
    final pending = assistant.handle('Добавь задачу купить хлеб');
    await Future<void>.delayed(Duration.zero);
    assistant.personas = const PersonaSettings(
      mode: AssistantMode.solo,
      soloPersona: 'noda',
      styles: <String, String>{'rio': 'business', 'noda': 'brief'},
      address: ReplyAddress.informal,
    );
    repository.gate!.complete();
    final response = await pending;
    expect(response.personaId, 'rio');
    expect(response.message, 'Создал задачу «Купить хлеб».');
    expect((await tasks.listActive()).single.title, 'Купить хлеб');

    final next = await assistant.handle('Покажи задачи');
    expect(next.personaId, 'noda');
    expect(next.message, 'Задач: 1. Ближайшая: «Купить хлеб».');
  });
}
