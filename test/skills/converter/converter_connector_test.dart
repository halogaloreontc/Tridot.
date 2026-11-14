// Навык «Конвертер» (ADR-024, шаг 2): какие фразы его, цели по типу
// файла, варианты с ffmpeg — только на Windows и Linux и только со
// скачанной программой, карточка с подставленным файлом и целью.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/converter/converter_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

final DateTime _now = DateTime(2026, 11, 14, 10);

bool _matches(String text) =>
    ConverterConnector().match(Utterance.analyze(text, now: _now)) != null;

final class _Env implements ConverterEnvironment {
  _Env(this.platform, {this.ffmpegReady = false});

  @override
  final JobPlatform platform;

  @override
  final bool ffmpegReady;
}

AssistantController _assistant({
  bool enabled = true,
  ConverterEnvironment? environment,
}) {
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
        ConverterConnector(environment: environment),
      ],
      choice: ExtensionChoice(
        enabled: <String>{if (enabled) ConverterConnector.id},
      ),
    ),
    clock: clock,
  );
}

JobFile _att(String name) =>
    JobFile(path: 'files/session-1/$name', name: name, attachment: true);

ExtensionCard _card(String file, {String? target}) => ExtensionCard(
      id: 'j1_0',
      extensionId: ConverterConnector.id,
      updatedAt: _now,
      values: <String, Object?>{
        'file': <JobFile>[JobFile(path: '/tmp/$file', name: file)],
        if (target != null) 'target': target,
      },
    );

List<String> _options(
  ExtensionCard card,
  JobPlatform platform, [
  Set<String> tools = const <String>{},
]) =>
    ExtensionForms.of(ConverterConnector.id)!
        .firstWhere((FieldSpec f) => f.code == 'target')
        .options!(card, platform, tools)
        .map((Choice c) => '${c.value}${c.enabled ? '' : '×'}')
        .toList();

void main() {
  group('фразы', () {
    test('повелительное наклонение и объект или формат — его фразы', () {
      for (final text in <String>[
        'сконвертируй в mp3',
        'конвертируй фото в png',
        'переведи видео в mp3',
        'сконвертируй файл',
        'преобразуй картинку в jpg',
        'перегони видео в mp4',
        'сконвертируй видео в webm',
        'конвертируй звук из видео в mp3',
        'пожалуйста, сконвертируй фото',
        'сохрани фото в png',
        'переведи в mp3',
        'сконвертируй в другой формат',
      ]) {
        expect(_matches(text), isTrue, reason: text);
      }
    });

    test('деньги, единицы, перевод текста, задачи — не его фразы', () {
      for (final text in <String>[
        'переведи 100 долларов в рубли',
        'переведи на английский привет',
        'переведи файл на английский',
        'конвертируй доллары в рубли',
        'переведи 10 градусов в фаренгейты',
        'переведи 5 км в мили',
        'добавь задачу сконвертировать отчёт в pdf',
        'сконвертировать видео',
        'напомни перегнать видео в mp4 завтра',
        'запили видео про котиков',
        'переведи деньги маме',
        'переведи задачу на завтра',
        'сохрани пароль от почты',
        'сконвертируй',
        'перегони машину в гараж',
      ]) {
        expect(_matches(text), isFalse, reason: text);
      }
    });

    test('примеры навыка распознаются; выключен по умолчанию', () {
      for (final example in ConverterConnector().info.examples) {
        expect(_matches(example), isTrue, reason: example);
      }
      expect(ConverterConnector().info.defaultEnabled, isFalse);
      expect(ConverterConnector().info.kind, ExtensionKind.skill);
    });

    test('цель и тип файла из фразы', () {
      Utterance u(String text) => Utterance.analyze(text, now: _now);
      expect(ConverterPhrases.targetOf(u('сконвертируй в mp3')), 'mp3');
      expect(ConverterPhrases.targetOf(u('преобразуй картинку в jpg')), 'jpeg');
      expect(ConverterPhrases.targetOf(u('сконвертируй файл')), isNull);
      expect(
        ConverterPhrases.kindOf(u('конвертируй фото в png')),
        MediaKind.image,
      );
      expect(
        ConverterPhrases.kindOf(u('конвертируй звук из видео в mp3')),
        MediaKind.video,
      );
    });
  });

  group('цели по типу файла', () {
    test('картинки — png и jpeg без своего формата', () {
      expect(ConvertTargets.targetsFor('a.png'), <String>['jpeg']);
      expect(ConvertTargets.targetsFor('a.JPG'), <String>['png']);
      expect(ConvertTargets.targetsFor('a.webp'), <String>['png', 'jpeg']);
      expect(ConvertTargets.targetsFor('a.bmp'), <String>['png', 'jpeg']);
      expect(ConvertTargets.targetsFor('a.gif'), <String>['png', 'jpeg']);
    });

    test('звук — mp3; видео — mp3, видео и кадр', () {
      expect(ConvertTargets.targetsFor('a.wav'), <String>['mp3']);
      expect(ConvertTargets.targetsFor('a.mp3'), isEmpty);
      expect(
        ConvertTargets.targetsFor('a.mkv'),
        <String>['mp3', 'mp4', 'webm', 'frame-jpeg', 'frame-png'],
      );
      expect(
        ConvertTargets.targetsFor('a.mp4'),
        <String>['mp3', 'webm', 'frame-jpeg', 'frame-png'],
      );
    });

    test('HEIC и неизвестное — «пока не поддерживается»', () {
      expect(ConvertTargets.kindOf('IMG_1.HEIC'), MediaKind.unknown);
      expect(ConvertTargets.targetsFor('a.heic'), isEmpty);
      expect(
        ExtensionForms.blocker(_card('IMG_1.heic'), JobPlatform.linux),
        'Этот формат пока не поддерживается',
      );
      expect(
        ExtensionForms.blocker(_card('песня.mp3'), JobPlatform.linux),
        'Для этого файла нет других форматов',
      );
    });

    test('картинка запускается везде без ffmpeg', () {
      for (final platform in JobPlatform.values) {
        expect(
          ExtensionForms.blocker(
            _card('фото.webp', target: 'png'),
            platform,
          ),
          isNull,
          reason: platform.name,
        );
      }
    });

    test('звук и видео: на Android и macOS отключены честно', () {
      for (final platform in <JobPlatform>[
        JobPlatform.android,
        JobPlatform.macos,
        JobPlatform.ios,
      ]) {
        expect(
          _options(_card('клип.mkv'), platform, const <String>{'ffmpeg'}),
          everyElement(endsWith('×')),
          reason: platform.name,
        );
        expect(
          ExtensionForms.blocker(
            _card('клип.mkv', target: 'mp3'),
            platform,
            tools: const <String>{'ffmpeg'},
          ),
          contains('На этой платформе недоступно'),
        );
      }
    });

    test('на Windows и Linux — только со скачанным ffmpeg', () {
      for (final platform in <JobPlatform>[
        JobPlatform.windows,
        JobPlatform.linux,
      ]) {
        final card = _card('запись.wav', target: 'mp3');
        expect(_options(card, platform), <String>['mp3×']);
        expect(
          ExtensionForms.blocker(card, platform),
          contains('Нужен ffmpeg'),
        );
        expect(
          _options(card, platform, const <String>{'ffmpeg'}),
          <String>['mp3'],
        );
        expect(
          ExtensionForms.blocker(
            card,
            platform,
            tools: const <String>{'ffmpeg'},
          ),
          isNull,
        );
      }
    });

    test('без файла — «Выберите файл»; папка не подходит', () {
      final empty = ExtensionCard(
        id: 'j1_0',
        extensionId: ConverterConnector.id,
        updatedAt: _now,
      );
      expect(ExtensionForms.blocker(empty, JobPlatform.linux), 'Выберите файл');
      final folder = ExtensionCard(
        id: 'j1_0',
        extensionId: ConverterConnector.id,
        updatedAt: _now,
        values: <String, Object?>{
          'file': <JobFile>[
            const JobFile(path: '/tmp/a', name: 'a', folder: true),
          ],
        },
      );
      expect(
        ExtensionForms.blocker(folder, JobPlatform.linux),
        'Нужен файл, а не папка',
      );
    });
  });

  group('карточка', () {
    test('фото из сообщения и цель из фразы уже в форме; отвечает Лиорио',
        () async {
      final assistant = _assistant();
      final response = await assistant.handle(
        'конвертируй фото в png',
        attachments: <JobFile>[_att('документ.pdf'), _att('кот.jpg')],
      );
      final card = response.job!;
      expect(card.extensionId, ConverterConnector.id);
      expect(card.files('file').single.name, 'кот.jpg');
      expect(card.choice('target'), 'png');
      expect(response.personaId, 'rio');
      expect(response.intent, ConverterConnector.convertCommand);
      expect(ExtensionForms.blocker(card, JobPlatform.android), isNull);
    });

    test('видео из недавних сообщений; цель не подходит файлу — не ставится',
        () async {
      final assistant = _assistant();
      final response = await assistant.handle(
        'сконвертируй видео в png',
        recentAttachments: <JobFile>[_att('клип.mp4'), _att('кот.jpg')],
      );
      final card = response.job!;
      expect(card.files('file').single.name, 'клип.mp4');
      expect(card.choice('target'), isNull);
    });

    test('единственная цель ставится сама', () async {
      final response = await _assistant().handle(
        'сконвертируй файл',
        attachments: <JobFile>[_att('голос.ogg')],
      );
      expect(response.job!.choice('target'), 'mp3');
    });

    test('неизвестный формат — честный ответ «пока не умею»', () async {
      final response = await _assistant().handle(
        'сконвертируй файл',
        attachments: <JobFile>[_att('IMG_1.heic')],
      );
      expect(response.message, contains('пока не'));
      expect(response.job, isNotNull);
    });

    test('звук без ffmpeg на компьютере — где его скачать', () async {
      final response = await _assistant(
        environment: _Env(JobPlatform.linux),
      ).handle('сконвертируй в mp3', attachments: <JobFile>[_att('a.wav')]);
      expect(response.message, contains('ffmpeg'));
      expect(response.message, contains('Расширения'));
    });

    test('звук на телефоне — только картинки', () async {
      final response = await _assistant(
        environment: _Env(JobPlatform.android),
      ).handle('сконвертируй в mp3');
      expect(response.message, contains('только картинки'));
    });

    test('ffmpeg скачан — обычная карточка', () async {
      final response = await _assistant(
        environment: _Env(JobPlatform.windows, ffmpegReady: true),
      ).handle('сконвертируй в mp3', attachments: <JobFile>[_att('a.wav')]);
      expect(response.message, contains('Запустить'));
    });

    test('карточка из «+» — пустая форма', () {
      final response = _assistant().openForm(ConverterConnector.id)!;
      expect(response.job!.files('file'), isEmpty);
      expect(response.job!.choice('target'), isNull);
      expect(response.personaId, 'rio');
    });

    test('выключен — подсказка, где включить', () async {
      final response = await _assistant(enabled: false).handle(
        'сконвертируй в mp3',
      );
      expect(response.intent, 'extension.off');
      expect(response.message, contains('Конвертер'));
      expect(response.job, isNull);
    });
  });
}
