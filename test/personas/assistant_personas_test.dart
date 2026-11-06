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
    test('по умолчанию отвечает Rio нейтрально', () async {
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

      final rio = await assistant.handle('Рио: покажи задачи');
      expect(rio.personaId, 'rio');
      expect(rio.message, startsWith('Активных задач: 1.'));

      final calc = await assistant.handle('нода — сколько будет 2+2');
      expect(calc.personaId, 'noda');
      expect(calc.message, contains('2 + 2 = 4'));
    });

    test('Noda говорит о себе в женском роде, Rio — в мужском', () async {
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
        (await assistant.handle('заверши купить молоко')).message,
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
        (await assistant.handle('Rio, покажи задачи', addressee: 'noda'))
            .personaId,
        'rio',
      );
    });

    test('основной — Noda: отвечает она, второй пишет Rio', () async {
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
        'Rio, добавь задачу позвонить',
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
