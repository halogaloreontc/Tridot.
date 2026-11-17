// Навык «Архиватор» (ADR-024): какие фразы его, карточка с подставленными
// файлами, ответ Лиорио, подсказка при выключенном расширении.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/archiver/archiver_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

final DateTime _now = DateTime(2026, 11, 14, 10);

String? _command(String text) =>
    ArchiverConnector().match(Utterance.analyze(text, now: _now))?.commandId;

AssistantController _assistant({required bool archiver}) {
  final clock = FixedClock(_now);
  return AssistantController(
    extensions: ExtensionRegistry(
      connectors: <Connector>[
        TasksConnector(
          taskService: TaskService(
            repository: InMemoryTaskRepository(),
            clock: clock,
          ),
          parser: ScenarioParser(clock: clock),
        ),
        ArchiverConnector(),
      ],
      choice: ExtensionChoice(
        enabled: <String>{if (archiver) ArchiverConnector.id},
      ),
    ),
    clock: clock,
  );
}

const JobFile _zip = JobFile(
  path: 'files/session-1/m_1-0.zip',
  name: 'фото.zip',
  attachment: true,
);
const JobFile _doc = JobFile(
  path: 'files/session-1/m_2-0.pdf',
  name: 'отчёт.pdf',
  attachment: true,
);

void main() {
  group('фразы', () {
    test('повелительное наклонение и объект — команда архиватора', () {
      final cases = <String, String>{
        'сожми в zip': ArchiverConnector.zipCommand,
        'Сожми файлы': ArchiverConnector.zipCommand,
        'заархивируй папку': ArchiverConnector.zipCommand,
        'заархивируй': ArchiverConnector.zipCommand,
        'запакуй эти файлы в архив': ArchiverConnector.zipCommand,
        'упакуй в zip': ArchiverConnector.zipCommand,
        'создай архив': ArchiverConnector.zipCommand,
        'пожалуйста, сожми файлы': ArchiverConnector.zipCommand,
        'распакуй архив': ArchiverConnector.extractCommand,
        'разархивируй zip': ArchiverConnector.extractCommand,
        'извлеки из архива': ArchiverConnector.extractCommand,
        'покажи что в архиве': ArchiverConnector.listCommand,
        'открой архив': ArchiverConnector.listCommand,
        'что в архиве?': ArchiverConnector.listCommand,
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        expect(_command(key), value, reason: key);
      }
    });

    test('задачи, инфинитив и покупка — не его фразы', () {
      for (final text in <String>[
        'купить архив',
        'сдать документы в архив',
        'добавь задачу сжать отчёт',
        'напомни распаковать коробки завтра',
        'сжать отчёт',
        'распакуй коробки',
        'сожми',
        'отправь отчёт в архив',
        'открой данные приложения',
        'покажи задачи',
        'создай задачу сделать архив',
      ]) {
        expect(_command(text), isNull, reason: text);
      }
    });

    test('примеры навыка распознаются', () {
      for (final example in ArchiverConnector().info.examples) {
        expect(_command(example), isNotNull, reason: example);
      }
      expect(ArchiverConnector().info.defaultEnabled, isFalse);
      expect(ArchiverConnector().info.kind, ExtensionKind.skill);
    });
  });

  group('карточка', () {
    test(
        '«распакуй архив» с .zip в сообщении — архив уже в форме, отвечает '
        'Лиорио', () async {
      final assistant = _assistant(archiver: true);
      final response = await assistant.handle(
        'распакуй архив',
        attachments: const <JobFile>[_zip],
      );
      final card = response.job!;
      expect(card.extensionId, ArchiverConnector.id);
      expect(card.state, CardState.form);
      expect(card.choice('action'), ExtensionForms.extract);
      expect(card.files(), <JobFile>[_zip]);
      expect(response.personaId, 'rio');
      expect(response.intent, ArchiverConnector.extractCommand);
      expect(ExtensionForms.blocker(card, JobPlatform.android), isNull);
      // Файлы — только на время сообщения.
      expect(assistant.session.attachments, isEmpty);
    });

    test('архив из недавних сообщений сессии тоже подставляется', () async {
      final assistant = _assistant(archiver: true);
      final response = await assistant.handle(
        'покажи что в архиве',
        recentAttachments: const <JobFile>[_doc, _zip],
      );
      expect(response.job!.files(), <JobFile>[_zip]);
      expect(response.job!.choice('action'), ExtensionForms.list);
    });

    test('«сожми в zip» с файлами сообщения — они в форме', () async {
      final assistant = _assistant(archiver: true);
      final response = await assistant.handle(
        'сожми в zip',
        attachments: const <JobFile>[_doc],
        recentAttachments: const <JobFile>[_zip],
      );
      expect(response.job!.files(), <JobFile>[_doc]);
      expect(response.job!.choice('action'), ExtensionForms.zip);
      expect(response.message, contains('Запустить'));
    });

    test('карточка из «+» без фразы — пустая форма от Лиорио', () {
      final assistant = _assistant(archiver: true);
      final response = assistant.openForm(
        ArchiverConnector.id,
        action: ExtensionForms.extract,
      )!;
      expect(response.job!.files(), isEmpty);
      expect(response.job!.choice('action'), ExtensionForms.extract);
      expect(response.personaId, 'rio');
      expect(assistant.openForm('нет_такого'), isNull);
    });

    test('у каждой карточки свой id', () async {
      final assistant = _assistant(archiver: true);
      final a = (await assistant.handle('сожми в zip')).job!.id;
      final b = (await assistant.handle('сожми в zip')).job!.id;
      expect(a, isNot(b));
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(a), isTrue);
    });
  });

  group('расширение выключено', () {
    test('фраза архиватора — подсказка, где включить, а не задача', () async {
      final assistant = _assistant(archiver: false);
      final response = await assistant.handle('сожми в zip');
      expect(response.intent, 'extension.off');
      expect(response.message, contains('Архиватор'));
      expect(response.message, contains('Расширения'));
      expect(response.job, isNull);
      final form = assistant.openForm(ArchiverConnector.id)!;
      expect(form.intent, 'extension.off');
      expect(form.job, isNull);
    });

    test('задачи остаются задачами', () async {
      final assistant = _assistant(archiver: false);
      final response = await assistant.handle('добавь задачу сжать отчёт');
      expect(response.intent, 'task.create');
      final infinitive = await assistant.handle('сдать документы в архив');
      expect(infinitive.intent, 'task.create');
    });
  });
}
