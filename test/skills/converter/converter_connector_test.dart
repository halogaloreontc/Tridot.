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
  _Env(
    this.platform, {
    this.ffmpegReady = false,
    this.native = NativeMediaCaps.none,
  });

  @override
  final JobPlatform platform;

  @override
  final bool ffmpegReady;

  @override
  final NativeMediaCaps native;
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
    test('картинки — png и jpeg; свой формат — «пережать»', () {
      expect(ConvertTargets.targetsFor('a.png'), <String>['png', 'jpeg']);
      expect(ConvertTargets.targetsFor('a.JPG'), <String>['png', 'jpeg']);
      expect(ConvertTargets.targetsFor('a.webp'), <String>['png', 'jpeg']);
      expect(ConvertTargets.targetsFor('a.bmp'), <String>['png', 'jpeg']);
      expect(ConvertTargets.targetsFor('a.gif'), <String>['png', 'jpeg']);
      expect(ConvertTargets.sameFormat('a.JPG', 'jpeg'), isTrue);
      expect(ConvertTargets.label('jpeg', same: true), 'JPEG (пережать)');
      expect(ConvertTargets.label('png', same: true), 'PNG (уменьшить)');
    });

    test('звук — mp3, m4a, wav; видео — ещё видео и кадр', () {
      expect(ConvertTargets.targetsFor('a.wav'), <String>['mp3', 'm4a']);
      expect(
        ConvertTargets.targetsFor('a.mp3'),
        <String>['mp3', 'm4a', 'wav'],
      );
      expect(
        ConvertTargets.targetsFor('a.mkv'),
        <String>[
          'mp3',
          'm4a',
          'wav',
          'mp4',
          'mov',
          'webm',
          'frame-jpeg',
          'frame-png',
        ],
      );
      // mp4 в mp4 — пережать; webm в webm и mov в mov — нет смысла.
      expect(ConvertTargets.targetsFor('a.mp4'), contains('mp4'));
      expect(ConvertTargets.targetsFor('a.webm'), isNot(contains('webm')));
      expect(ConvertTargets.targetsFor('a.mov'), isNot(contains('mov')));
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
        'Выберите: во что',
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
          anyOf(contains('только картинки'), contains('недоступно')),
        );
      }
    });

    test('на Windows и Linux — только со скачанным ffmpeg', () {
      for (final platform in <JobPlatform>[
        JobPlatform.windows,
        JobPlatform.linux,
      ]) {
        final card = _card('запись.wav', target: 'mp3');
        expect(_options(card, platform), <String>['mp3×', 'm4a×']);
        expect(
          ExtensionForms.blocker(card, platform),
          contains('Нужен ffmpeg'),
        );
        expect(
          _options(card, platform, const <String>{'ffmpeg'}),
          <String>['mp3', 'm4a'],
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

    test('видео из недавних сообщений; «в png» у видео — кадр', () async {
      final assistant = _assistant();
      final response = await assistant.handle(
        'сконвертируй видео в png',
        recentAttachments: <JobFile>[_att('клип.mp4'), _att('кот.jpg')],
      );
      final card = response.job!;
      expect(card.files('file').single.name, 'клип.mp4');
      expect(card.choice('target'), ConvertTargets.framePng);
    });

    test('цель не подходит файлу — не ставится', () async {
      final response = await _assistant().handle(
        'сконвертируй в mp3',
        recentAttachments: <JobFile>[_att('кот.jpg')],
      );
      final card = response.job!;
      expect(card.files('file').single.name, 'кот.jpg');
      expect(card.choice('target'), isNull);
    });

    test('цель не одна — не выбирается за пользователя', () async {
      final response = await _assistant().handle(
        'сконвертируй файл',
        attachments: <JobFile>[_att('голос.ogg')],
      );
      expect(response.job!.choice('target'), isNull);
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

  group('качество из фразы (ADR-026)', () {
    Map<String, String> form(String text) {
      final r = ConverterPhrases.requestOf(Utterance.analyze(text, now: _now));
      return <String, String>{
        if (r.target case final String t) 'target': t,
        if (r.unoffered case final String f) 'unoffered': f,
        ...r.options,
      };
    }

    test('битрейт: число, с единицей, склеенный, «на 320», ближайший', () {
      for (final text in <String>[
        'сконвертируй видео в mp3 320',
        'переведи видео в mp3 на 320 кбит/с',
        'сконвертируй в mp3 320k',
        'сконвертируй в mp3 320кбит',
        'сконвертируй в mp3 320 kbps',
        'сделай из видео mp3 в лучшем качестве',
        'сконвертируй песню в mp3 максимальное качество',
      ]) {
        expect(
          form(text),
          <String, String>{
            'target': 'mp3',
            'audio_kbps': '320',
          },
          reason: text,
        );
      }
      expect(form('сконвертируй в mp3 160'), containsPair('audio_kbps', '192'));
      expect(form('перегони песню в m4a 256k'), <String, String>{
        'target': 'm4a',
        'audio_kbps': '256',
      });
      expect(
        form('сконвертируй в mp3 экономно'),
        containsPair('audio_kbps', '128'),
      );
      // Битрейт вне разумного — не выдумывается.
      expect(form('сконвертируй в mp3 9000'), <String, String>{
        'target': 'mp3',
      });
    });

    test('видео: 720p, «р» по-русски, full hd, качество словами', () {
      expect(form('сконвертируй в mp4 720p'), <String, String>{
        'target': 'mp4',
        'video_res': '720',
      });
      expect(
        form('сконвертируй видео в mp4 480р'),
        containsPair('video_res', '480'),
      );
      expect(
        form('сконвертируй видео в mp4 1080'),
        containsPair('video_res', '1080'),
      );
      expect(
          form('сконвертируй видео в mp4 full hd экономно'), <String, String>{
        'target': 'mp4',
        'video_res': '1080',
        'video_quality': 'eco',
      });
      expect(
          form('сконвертируй видео в mov hd в высоком качестве'),
          <String, String>{
            'target': 'mov',
            'video_res': '720',
            'video_quality': 'high',
          });
      expect(form('уменьши видео до 720p'), <String, String>{
        'video_res': '720',
      });
    });

    test('картинки: качество JPEG, размер «до 1920», «1920px»', () {
      expect(form('конвертируй фото в jpg качество 85'), <String, String>{
        'target': 'jpeg',
        'jpeg_quality': '85',
      });
      expect(
        form('конвертируй фото в jpg качество 90'),
        containsPair('jpeg_quality', '95'),
      );
      expect(form('сожми фото до 1920'), <String, String>{
        'image_size': '1920',
      });
      expect(form('сконвертируй фото в png 1280px'), <String, String>{
        'target': 'png',
        'image_size': '1280',
      });
      expect(
        form('уменьши картинку до 2000 пикселей'),
        containsPair('image_size', '1920'),
      );
    });

    test('числа рядом с деньгами и временем — не качество', () {
      expect(_matches('переведи 320 рублей в доллары'), isFalse);
      expect(_matches('сконвертируй 1080 рублей'), isFalse);
      expect(_matches('сожми фото'), isFalse);
      expect(_matches('сожми файлы до 10 мегабайт'), isFalse);
      expect(form('сконвертируй видео в mp3 за 320 рублей'), <String, String>{
        'target': 'mp3',
      });
      expect(form('сконвертируй видео в mp4 на 720 минут'), <String, String>{
        'target': 'mp4',
      });
    });

    test('формат, которого нет нигде, — понят, чтобы честно ответить', () {
      expect(form('сконвертируй песню в flac'), <String, String>{
        'unoffered': 'FLAC',
      });
      expect(form('переведи видео в ogg'), <String, String>{
        'unoffered': 'OGG',
      });
      expect(_matches('переведи деньги в евро'), isFalse);
    });
  });

  group('ответ с качеством и честные отказы', () {
    test('«в mp3 320» — карточка уже с битрейтом, ответ его называет',
        () async {
      final response = await _assistant(
        environment: _Env(JobPlatform.linux, ffmpegReady: true),
      ).handle(
        'сконвертируй видео в mp3 320',
        attachments: <JobFile>[_att('клип.mp4')],
      );
      final card = response.job!;
      expect(card.choice('target'), 'mp3');
      expect(card.choice('audio_kbps'), '320');
      expect(response.replyId, 'converter.form.quality');
      expect(response.message, contains('MP3, 320 кбит/с'));
      expect(
        ExtensionForms.blocker(
          card,
          JobPlatform.linux,
          tools: const <String>{'ffmpeg'},
        ),
        isNull,
      );
    });

    test('качество не к цели в карточку не попадает', () async {
      final response = await _assistant().handle(
        'сконвертируй фото в png качество 60',
        attachments: <JobFile>[_att('кот.jpg')],
      );
      expect(response.job!.choice('jpeg_quality'), isNull);
    });

    test('«сожми фото до 1920» — тот же формат, размер выбран', () async {
      final response = await _assistant(
        environment: _Env(JobPlatform.android),
      ).handle('сожми фото до 1920', attachments: <JobFile>[_att('кот.jpg')]);
      final card = response.job!;
      expect(card.choice('target'), 'jpeg');
      expect(card.choice('image_size'), '1920');
      // Остальное — значения по умолчанию.
      expect(card.choice('jpeg_quality'), '85');
      expect(ExtensionForms.blocker(card, JobPlatform.android), isNull);
    });

    test('файла ещё нет: «уменьши видео до 720p» — mp4, фото — jpeg', () async {
      final env = _Env(
        JobPlatform.android,
        native: const NativeMediaCaps(targets: <String>{'mp3', 'mp4'}),
      );
      final video =
          (await _assistant(environment: env).handle('уменьши видео до 720p'))
              .job!;
      expect(video.choice('target'), 'mp4');
      expect(video.choice('video_res'), '720');
      final photo =
          (await _assistant(environment: env).handle('сожми фото до 1920'))
              .job!;
      expect(photo.choice('target'), 'jpeg');
      expect(photo.choice('image_size'), '1920');
    });

    test('WebM на телефоне и Mac — честно: не делается, а не ошибка', () async {
      for (final platform in <JobPlatform>[
        JobPlatform.android,
        JobPlatform.macos,
      ]) {
        final response = await _assistant(
          environment: _Env(
            platform,
            native: const NativeMediaCaps(targets: <String>{'mp3', 'mp4'}),
          ),
        ).handle(
          'сконвертируй видео в webm',
          attachments: <JobFile>[_att('клип.mp4')],
        );
        expect(response.replyId, 'converter.unavailable.target');
        expect(response.message, contains('WebM'));
        expect(response.message, contains('MP4'));
        final card = response.job!;
        // Выбор виден, причина — под ним, «Запустить» неактивна.
        expect(card.choice('target'), 'webm');
        expect(
          ExtensionForms.blocker(
            card,
            platform,
            tools: const NativeMediaCaps(
              targets: <String>{'mp3', 'mp4'},
            ).toTools(),
          ),
          contains('WebM не делается'),
        );
      }
    });

    test('FLAC — нигде: ответ называет, что есть здесь', () async {
      final response = await _assistant(
        environment: _Env(JobPlatform.windows, ffmpegReady: true),
      ).handle('сконвертируй песню в flac');
      expect(response.replyId, 'converter.unavailable.format');
      expect(response.message, contains('FLAC'));
      expect(response.message, contains('mp3'));
      final phone = await _assistant(
        environment: _Env(JobPlatform.android),
      ).handle('сконвертируй песню в flac');
      expect(phone.message, contains('звук и видео здесь недоступны'));
    });

    test('без ffmpeg на компьютере качество всё равно в карточке', () async {
      final response = await _assistant(
        environment: _Env(JobPlatform.linux),
      ).handle(
        'сконвертируй в mp4 720p',
        attachments: <JobFile>[_att('клип.mkv')],
      );
      expect(response.replyId, 'converter.noTool');
      expect(response.job!.choice('video_res'), '720');
      expect(response.job!.choice('video_quality'), 'mid');
    });
  });
  group('честные ответы по устройству (ревью ADR-026)', () {
    const partial = NativeMediaCaps(
      targets: <String>{'wav', 'm4a', 'frame-jpeg', 'frame-png'},
    );

    test('нет только MP3 (LAME не загрузился) — не «только картинки»',
        () async {
      final response = await _assistant(
        environment: _Env(JobPlatform.android, native: partial),
      ).handle(
        'сконвертируй видео в mp3',
        attachments: <JobFile>[_att('клип.mp4')],
      );
      expect(response.replyId, 'converter.unavailable.target');
      expect(response.message, contains('MP3'));
      expect(response.message, contains('кодировщик MP3 не загрузился'));
      expect(response.message, isNot(contains('только картинки')));
      final card = response.job!;
      final reason = ExtensionForms.blocker(
        card,
        JobPlatform.android,
        tools: partial.toTools(),
      );
      expect(reason, contains('На телефоне MP3 не делается'));
    });

    test('Mac не открывает MKV — честно, до «Запустить»', () async {
      const mac = NativeMediaCaps(
        targets: <String>{'mp3', 'm4a', 'wav', 'mp4', 'mov'},
      );
      final response = await _assistant(
        environment: _Env(JobPlatform.macos, native: mac),
      ).handle(
        'сконвертируй видео в mp4 720p',
        attachments: <JobFile>[_att('клип.mkv')],
      );
      expect(response.replyId, 'converter.unreadable');
      expect(response.message, contains('MKV'));
      expect(response.message, contains('mp4, mov'));
      final reason = ExtensionForms.blocker(
        response.job!,
        JobPlatform.macos,
        tools: mac.toTools(),
      );
      expect(reason, contains('На Mac файл MKV не открывается'));
    });

    test('поля качества не видны у цели, которая здесь не делается', () {
      List<Choice> quality(
        String code,
        JobPlatform platform,
        Set<String> t,
        String target,
      ) =>
          ExtensionForms.of(ConverterConnector.id)!
              .firstWhere((FieldSpec f) => f.code == code)
              .options!(_card('клип.mp4', target: target), platform, t);
      const phone = NativeMediaCaps(targets: <String>{'mp3', 'mp4'});
      expect(
        quality('video_res', JobPlatform.android, phone.toTools(), 'webm'),
        isEmpty,
      );
      expect(
        quality('video_res', JobPlatform.android, phone.toTools(), 'mp4'),
        isNotEmpty,
      );
      expect(
        quality('audio_kbps', JobPlatform.android, const <String>{}, 'mp3'),
        isEmpty,
      );
      // ffmpeg ещё не скачан — качество видно: его можно скачать.
      expect(
        quality('audio_kbps', JobPlatform.linux, const <String>{}, 'mp3'),
        isNotEmpty,
      );
    });

    test('«в формат mp3 320» — цель и битрейт', () async {
      final request = ConverterPhrases.requestOf(
        Utterance.analyze('сконвертируй видео в формат mp3 320', now: _now),
      );
      expect(request.target, 'mp3');
      expect(request.options, <String, String>{'audio_kbps': '320'});
    });

    test('«видео в jpg качество 75» — кадр в JPEG', () async {
      final request = ConverterPhrases.requestOf(
        Utterance.analyze('сконвертируй видео в jpg качество 75', now: _now),
      );
      expect(request.target, ConvertTargets.frameJpeg);
      expect(request.options, <String, String>{'jpeg_quality': '75'});
    });

    test('файл и формат уже выбраны — не «выберите файл и формат»', () async {
      final response = await _assistant(
        environment: _Env(
          JobPlatform.macos,
          native: const NativeMediaCaps(targets: <String>{'mov', 'mp4'}),
        ),
      ).handle(
        'сконвертируй видео в mov',
        attachments: <JobFile>[_att('клип.mp4')],
      );
      expect(response.replyId, 'converter.form.quality');
      expect(response.message, contains('MOV'));
      expect(response.message, isNot(contains('файл и формат')));
    });
  });
}
