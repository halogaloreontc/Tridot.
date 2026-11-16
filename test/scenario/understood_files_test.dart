import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/files/files_connector.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';
import 'package:local_assistant/core/voice/voice_text.dart';

final class _Remover implements SessionFileRemover {
  final List<String> removed = <String>[];

  @override
  Future<bool> remove(SessionFileRef file) async {
    removed.add(file.id);
    return true;
  }
}

void main() {
  late TaskService tasks;
  late AssistantController assistant;
  final clock = FixedClock(DateTime(2026, 11, 14, 23, 30));

  setUp(() {
    tasks = TaskService(repository: InMemoryTaskRepository(), clock: clock);
    assistant = AssistantController(
      connectors: <Connector>[
        TasksConnector(
          taskService: tasks,
          parser: ScenarioParser(clock: clock),
        ),
        TalkConnector(taskService: tasks),
        FilesConnector(),
      ],
      clock: clock,
    );
  });

  group('«Понял так: … Создать?» (п. 4)', () {
    const owner =
        'Можешь поставить зэд напоминание с утра чтобы я написал андрею';

    test('голосом: чистка распознанного убирает «зэд» — задача сразу',
        () async {
      // Так фраза приходит из микрофона: VoiceText.clean до handle.
      final spoken = VoiceText.clean(owner);
      expect(spoken, isNot(contains('зэд')));
      final created = await assistant.handle(spoken, fromVoice: true);
      expect(created.status, AssistantStatus.completed);
      expect(created.task?.title, 'Написать Андрею');
      expect(created.task?.dueAt, DateTime(2026, 11, 15, 9));
    });

    test('набранная та же фраза — задача сразу', () async {
      final created = await assistant.handle(owner);
      expect(created.status, AssistantStatus.completed);
      expect(created.task?.title, 'Написать Андрею');
    });

    test('не уверен — «Понял так: …» с [Создать] [Исправить]', () async {
      const unsure = 'напомни чтобы я лёг спать пораньше';
      final asked = await assistant.handle(VoiceText.clean(unsure));
      expect(asked.status, AssistantStatus.needsClarification);
      expect(asked.message, contains('«Лечь спать пораньше»'));
      expect(
        asked.clarification!.options.map((ClarifyOption o) => o.label),
        <String>['Создать', 'Исправить'],
      );
      expect(await tasks.listActive(), isEmpty);
      final created = await assistant.handle('Создать');
      // «Напомни» без времени: задача создана, и сразу вопрос «Когда
      // напомнить?» (ADR-033).
      expect(created.status, AssistantStatus.needsClarification);
      expect(created.replyId, 'task.created.askWhen');
      expect(created.task?.title, 'Лечь спать пораньше');
      expect(await tasks.listActive(), hasLength(1));
    });

    test('«Исправить» — понятая команда в поле ввода, задачи нет', () async {
      await assistant.handle('напомни чтобы я лёг спать пораньше');
      final edit = await assistant.handle('Исправить');
      expect(edit.status, AssistantStatus.noAction);
      expect(edit.replyId, 'task.clarify.edit');
      expect(edit.draft, 'Напомни «Лечь спать пораньше»');
      expect(await tasks.listActive(), isEmpty);
    });

    test('вопрос со сроком — «Узнать, …» только после «Создать»', () async {
      final asked =
          await assistant.handle('напомни завтра в 9 какая формула суммы');
      expect(asked.status, AssistantStatus.needsClarification);
      expect(asked.message, contains('«Узнать, какая формула суммы»'));
      final created = await assistant.handle('да');
      expect(created.task?.title, 'Узнать, какая формула суммы');
    });

    test('вопрос без срока — не задача, а честный ответ', () async {
      final answer = await assistant.handle(
        'Нужен напомни пожалуйста какая формула суммы в гугл таблицах?',
      );
      expect(answer.intent, TalkConnector.questionCommand);
      expect(answer.replyId, 'talk.question.offline');
      expect(await tasks.listActive(), isEmpty);
    });
  });

  group('«удали этот файл» (ADR-028)', () {
    const shot = SessionFileRef(
      id: 'out:card-1:0',
      name: 'Screenshot_20261114_233544.jpg',
      output: true,
      path: '/data/files/out/card-1/Screenshot_20261114_233544.jpg',
      extensionId: 'converter',
      messageId: 'm2',
    );
    const source = SessionFileRef(
      id: 'att:a1',
      name: 'Screenshot_20261114_233544.png',
      output: false,
      messageId: 'm1',
    );

    test('результат конвертера — с вопросом; «Отмена» ничего не удаляет',
        () async {
      final remover = _Remover();
      assistant.session.fileRemover = remover;
      final asked = await assistant.handle(
        'удали этот файл',
        recentFiles: const <SessionFileRef>[shot, source],
      );
      expect(asked.status, AssistantStatus.needsClarification);
      expect(asked.message, contains('«Screenshot_20261114_233544.jpg»'));
      expect(asked.message, contains('исходник останется'));
      final cancelled = await assistant.handle('Отмена');
      expect(cancelled.replyId, 'files.delete.cancelled');
      expect(remover.removed, isEmpty);

      await assistant.handle(
        'удали этот файл',
        recentFiles: const <SessionFileRef>[shot, source],
      );
      final done = await assistant.handle('Удалить');
      expect(done.status, AssistantStatus.completed);
      expect(done.replyId, 'files.delete.done');
      expect(remover.removed, <String>['out:card-1:0']);
    });

    test('«удали файл» при нескольких файлах — какой', () async {
      final asked = await assistant.handle(
        'удали файл',
        recentFiles: const <SessionFileRef>[shot, source],
      );
      expect(asked.replyId, 'files.delete.which');
      expect(asked.clarification!.options, hasLength(2));
    });

    test('вид файла: «удали архив» без архивов — такого нет', () async {
      final none = await assistant.handle(
        'удали последний архив',
        recentFiles: const <SessionFileRef>[shot, source],
      );
      expect(none.replyId, 'files.delete.noneOfKind');
      final png = await assistant.handle(
        'удали исходник',
        recentFiles: const <SessionFileRef>[shot, source],
      );
      expect(png.replyId, 'files.delete.confirm.attachment');
      expect(png.message, contains('«Screenshot_20261114_233544.png»'));
    });

    test('«удали результат» — файл карточки, без вопроса «какой»', () async {
      final asked = await assistant.handle(
        'удали результат',
        recentFiles: const <SessionFileRef>[source, shot],
      );
      expect(asked.replyId, 'files.delete.confirm');
      expect(asked.message, contains('«Screenshot_20261114_233544.jpg»'));
    });

    test('«Как дела» не жалуется на «Файлы сессии»', () async {
      final status = await assistant.handle('как дела');
      expect(status.replyId, isNot('talk.status.okUnchecked'));
    });

    test('файлов нет — так и сказано', () async {
      final none = await assistant.handle('удали этот файл');
      expect(none.replyId, 'files.delete.none');
    });
  });
}
