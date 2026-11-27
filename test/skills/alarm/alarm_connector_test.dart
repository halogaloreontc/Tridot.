import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/models/task.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/alarm/alarm_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

/// Понедельник, 16:30.
final _clock = FixedClock(DateTime(2026, 11, 2, 16, 30));

final class _Setter implements AlarmSetter {
  _Setter({this.clock = true});

  @override
  bool get supported => true;
  final bool clock;
  final List<AlarmRequest> requests = <AlarmRequest>[];

  @override
  Future<bool> canSet() async => clock;

  @override
  Future<bool> set(AlarmRequest request) async {
    if (!clock) return false;
    requests.add(request);
    return true;
  }
}

({AssistantController assistant, TaskService tasks}) _make(
  AlarmSetter? setter,
) {
  final tasks =
      TaskService(repository: InMemoryTaskRepository(), clock: _clock);
  final assistant = AssistantController(
    extensions: ExtensionRegistry(
      connectors: <Connector>[
        TasksConnector(
          taskService: tasks,
          parser: ScenarioParser(clock: _clock),
        ),
        AlarmConnector(setter: setter, clock: _clock),
      ],
    ),
    clock: _clock,
  );
  return (assistant: assistant, tasks: tasks);
}

void main() {
  test('примеры навыка узнаются', () {
    final connector = AlarmConnector(clock: _clock);
    for (final example in connector.info.examples) {
      final match =
          connector.match(Utterance.analyze(example, now: _clock.now()));
      expect(match, isNotNull, reason: example);
      expect(match!.commandId, isNot(AlarmPhrases.clarifyCommand));
    }
  });

  test('будильник: вопрос с кнопками, «Поставить» ставит в «Часах»', () async {
    final setter = _Setter();
    final (:assistant, tasks: _) = _make(setter);
    final ask = await assistant.handle('поставь будильник на 7 по будням');
    expect(ask.status, AssistantStatus.needsClarification);
    expect(ask.intent, AlarmPhrases.setCommand);
    // Нода говорит дружеским стилем: «Ставлю будильник на 7:00…?».
    expect(ask.message, contains('будильник на 7:00 по будням в «Часах»?'));
    // Будильник — зона оповещений: в Трио отвечает Нода.
    expect(ask.personaId, 'noda');
    final options = assistant.pendingClarification!.options;
    expect(options.map((ClarifyOption o) => o.label), <String>[
      'Поставить',
      'Отмена',
    ]);
    final done = await assistant.handle('Поставить');
    expect(done.status, AssistantStatus.completed);
    expect(done.replyId, 'alarm.set');
    expect(setter.requests.single.hour, 7);
    expect(setter.requests.single.days, <int>[1, 2, 3, 4, 5]);
    expect(assistant.pendingClarification, isNull);
  });

  test('«да» — тоже согласие, «отмена» — отказ', () async {
    final setter = _Setter();
    final (:assistant, tasks: _) = _make(setter);
    await assistant.handle('таймер на 5 минут');
    expect((await assistant.handle('да')).replyId, 'alarm.timer.set');
    expect(setter.requests.single.seconds, 300);
    await assistant.handle('разбуди меня в 6:30');
    final no = await assistant.handle('Отмена');
    expect(no.replyId, 'alarm.cancelled');
    expect(setter.requests, hasLength(1));
  });

  test('без «Часов» и на компьютере — напоминание вместо будильника', () async {
    for (final setter in <AlarmSetter?>[null, _Setter(clock: false)]) {
      final (:assistant, :tasks) = _make(setter);
      final offer = await assistant.handle('поставь будильник на 7');
      expect(
        offer.replyId,
        setter == null
            ? 'alarm.unavailable.platform'
            : 'alarm.unavailable.noClock',
      );
      expect(offer.message, contains('завтра в 7:00'));
      final made = await assistant.handle('Напомнить');
      expect(made.intent, 'task.create');
      final task = (await tasks.listActive()).single;
      expect(task.title, 'Будильник');
      expect(task.dueAt, DateTime(2026, 11, 3, 7));
      expect(task.duePrecision, DuePrecision.dateTime);
    }
  });

  test('дальше суток — предложение напомнить; «Не надо» — ничего', () async {
    final (:assistant, :tasks) = _make(_Setter());
    final offer = await assistant.handle(
      'поставь будильник в пятницу в 7 с подписью «спортзал»',
    );
    expect(offer.replyId, 'alarm.date');
    expect(
      offer.message,
      'Будильник ставится только на ближайшие сутки. Напомнить 6 ноября в '
      '7:00 уведомлением?',
    );
    expect((await assistant.handle('Не надо')).replyId, 'alarm.cancelled');
    expect(await tasks.listActive(), isEmpty);
    await assistant.handle('поставь будильник в пятницу в 7 «спортзал»');
    await assistant.handle('Напомнить');
    final task = (await tasks.listActive()).single;
    expect(task.title, 'Спортзал');
    expect(task.dueAt, DateTime(2026, 11, 6, 7));
  });

  test('таймер на компьютере — напоминание через столько же', () async {
    final (:assistant, :tasks) = _make(null);
    final offer = await assistant.handle('засеки 10 минут');
    expect(offer.message, contains('через 10 минут'));
    await assistant.handle('Напомнить');
    final task = (await tasks.listActive()).single;
    expect(task.title, 'Таймер');
    expect(task.dueAt, DateTime(2026, 11, 2, 16, 40));
  });

  test('без времени — вопрос; прошедшее сегодня — подсказка', () async {
    final (:assistant, tasks: _) = _make(_Setter());
    expect(
      (await assistant.handle('поставь будильник')).message,
      'На какое время поставить будильник?',
    );
    expect(
      (await assistant.handle('поставь таймер')).message,
      'На сколько поставить таймер?',
    );
    expect(
      (await assistant.handle('поставь будильник на сегодня в 7')).replyId,
      'alarm.past',
    );
  });

  test('задачи остаются задачами', () async {
    final (:assistant, :tasks) = _make(_Setter());
    final made = await assistant.handle('купить будильник');
    expect(made.intent, 'task.create');
    expect((await tasks.listActive()).single.title, 'Купить будильник');
  });
}
