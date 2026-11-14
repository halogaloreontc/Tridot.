// Конвертер в чате (ADR-024, шаг 2): фраза → карточка Лиорио → файл →
// формат → «Запустить» → «Готово» (картинка — настоящей задачей в
// изоляте); звук и видео без ffmpeg не запускаются; карточка из «Найти
// команду».
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/files/file_opener.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/app/jobs/job_picker.dart';
import 'package:local_assistant/core/chats/attachments.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';
import 'package:local_assistant/core/jobs/job_runner.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/converter/converter_connector.dart';
import 'package:local_assistant/core/skills/converter/platform_media_job.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';
import 'package:path/path.dart' as p;

final class _Runner implements JobRunner {
  final Map<String, StreamController<JobEvent>> jobs =
      <String, StreamController<JobEvent>>{};
  final List<JobRequest> requests = <JobRequest>[];

  @override
  Stream<JobEvent> start(JobRequest request) {
    requests.add(request);
    return (jobs[request.cardId] = StreamController<JobEvent>()).stream;
  }

  @override
  void cancel(String cardId) => jobs[cardId]
    ?..add(const JobFailed(JobCodes.cancelled))
    ..close();
}

final class _Picker implements JobFilePicker {
  List<JobFile> next = <JobFile>[];

  @override
  Future<List<JobFile>> files() async => next;

  @override
  Future<JobFile?> folder() async => null;

  @override
  Future<String?> saveFile(String suggestedName, String initialDirectory) =>
      throw UnimplementedError();

  @override
  Future<String?> chooseFolder(String initialDirectory) =>
      throw UnimplementedError();
}

void main() {
  late Directory temp;
  late InMemoryChatStore store;
  late _Runner runner;
  late _Picker picker;
  late InMemorySettingsStore settings;

  setUp(() {
    settings = InMemorySettingsStore();
    temp = Directory.systemTemp.createTempSync('home_converter');
    store = InMemoryChatStore(
      attachments: InMemoryAttachmentStore(persistent: true),
    );
    runner = _Runner();
    picker = _Picker();
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Future<void> pump(
    WidgetTester tester, {
    bool fakeRunner = true,
    JobPlatform platform = JobPlatform.linux,
    NativeMedia? nativeMedia,
  }) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final clock = FixedClock(DateTime(2026, 11, 14, 12));
    final tasks =
        TaskService(repository: InMemoryTaskRepository(), clock: clock);
    final saved = await settings.load();
    await settings.save(
      saved.withChoice(
        const ExtensionChoice(enabled: <String>{ConverterConnector.id}),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AssistantTheme.dark(),
        home: HomePage(
          assistant: AssistantController(
            extensions: ExtensionRegistry(
              connectors: <Connector>[
                TasksConnector(
                  taskService: tasks,
                  parser: ScenarioParser(clock: clock),
                ),
                ConverterConnector(),
              ],
            ),
            clock: clock,
          ),
          tasks: tasks,
          clock: clock,
          settingsStore: settings,
          chatStore: store,
          jobRunner: fakeRunner ? runner : null,
          jobPicker: picker,
          jobPlatform: platform,
          nativeMedia: nativeMedia,
          fileOpener: FileOpener(platform: platform),
          tempRoot: () async => temp.path,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> say(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('assistant-input')), text);
    await tester.tap(find.byKey(const Key('assistant-send')));
    await tester.pumpAndSettle();
  }

  ButtonStyleButton button(WidgetTester tester, String key) =>
      tester.widget<ButtonStyleButton>(find.byKey(Key(key)));

  File picture(String name) => File(p.join(temp.path, name))
    ..writeAsBytesSync(
      img.encodePng(
        img.Image(width: 8, height: 8)..clear(img.ColorRgb8(200, 10, 10)),
      ),
    );

  testWidgets('«сконвертируй в jpg» → файл → «Запустить» → готово', (
    WidgetTester tester,
  ) async {
    await pump(tester);
    await say(tester, 'сконвертируй в jpg');
    expect(find.text('Конвертер'), findsOneWidget);
    expect(button(tester, 'ext-card-run').onPressed, isNull);
    final source = picture('кот.png');
    picker.next = <JobFile>[JobFile(path: source.path, name: 'кот.png')];
    await tester.tap(find.byKey(const Key('ext-card-pick-files')));
    await tester.pumpAndSettle();
    expect(find.text('кот.png'), findsOneWidget);
    expect(button(tester, 'ext-card-run').onPressed, isNotNull);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('ext-card-run')));
      for (var i = 0; i < 50 && runner.requests.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    final request = runner.requests.single;
    expect(request.extensionId, ConverterConnector.id);
    expect(request.action, 'jpeg');
    expect(request.target, p.join(temp.path, 'кот.jpg'));
    runner.jobs[request.cardId]!.add(
      JobDone(outputs: <String>[request.target!], outputDir: temp.path),
    );
    await tester.pumpAndSettle();
    expect(find.text('Готово: кот.jpg'), findsOneWidget);
    final saved = await store.loadMessages(store.chatIds.single);
    expect(saved.last.job!.state, CardState.done);
    expect(saved.last.personaId, 'rio');
  });

  testWidgets('картинка конвертируется по-настоящему, исходник цел', (
    WidgetTester tester,
  ) async {
    await pump(tester, fakeRunner: false);
    await say(tester, 'конвертируй фото в jpg');
    final source = picture('закат.png');
    final before = source.readAsBytesSync();
    picker.next = <JobFile>[JobFile(path: source.path, name: 'закат.png')];
    await tester.tap(find.byKey(const Key('ext-card-pick-files')));
    await tester.pumpAndSettle();
    final out = File(p.join(temp.path, 'закат.jpg'));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('ext-card-run')));
      for (var i = 0; i < 300 && !out.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(out.existsSync(), isTrue);
    expect(img.decodeJpg(out.readAsBytesSync())!.width, 8);
    expect(source.readAsBytesSync(), before);
    expect(find.text('Готово: закат.jpg'), findsOneWidget);
  });

  testWidgets('видео без ffmpeg — причина видна, «Запустить» неактивна', (
    WidgetTester tester,
  ) async {
    await pump(tester);
    await say(tester, 'сконвертируй в mp3');
    final source = File(p.join(temp.path, 'клип.mp4'))..writeAsStringSync('v');
    picker.next = <JobFile>[JobFile(path: source.path, name: 'клип.mp4')];
    await tester.tap(find.byKey(const Key('ext-card-pick-files')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Нужен ffmpeg'), findsWidgets);
    expect(button(tester, 'ext-card-run').onPressed, isNull);
  });

  testWidgets('новый файл заменяет прежний; неподходящая цель сбрасывается',
      (WidgetTester tester) async {
    await pump(tester);
    await say(tester, 'сконвертируй в mp3');
    picker.next = <JobFile>[
      JobFile(path: p.join(temp.path, 'a.wav'), name: 'a.wav'),
    ];
    await tester.tap(find.byKey(const Key('ext-card-pick-files')));
    await tester.pumpAndSettle();
    var saved = await store.loadMessages(store.chatIds.single);
    expect(saved.last.job!.choice('target'), 'mp3');
    // Качество звука по умолчанию уже в карточке.
    expect(saved.last.job!.choice('audio_kbps'), '192');
    final b = picture('b.png');
    picker.next = <JobFile>[JobFile(path: b.path, name: 'b.png')];
    await tester.tap(find.byKey(const Key('ext-card-pick-files')));
    await tester.pumpAndSettle();
    expect(find.text('a.wav'), findsNothing);
    expect(find.text('b.png'), findsOneWidget);
    saved = await store.loadMessages(store.chatIds.single);
    // mp3 картинке не подходит: цель сброшена, лишнее качество убрано.
    expect(saved.last.job!.choice('target'), isNull);
    expect(saved.last.job!.choice('audio_kbps'), isNull);
  });

  Future<void> choose(WidgetTester tester, String code, String value) async {
    await tester.tap(
      find
          .descendant(
            of: find.byKey(ValueKey<String>('ext-card-select-$code')),
            matching: find.byType(DropdownButton<String>),
          )
          .last,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .ancestor(
            of: find.byKey(ValueKey<String>('ext-card-choice-$value')).last,
            matching: find.byType(InkWell),
          )
          .first,
    );
    await tester.pumpAndSettle();
  }

  Future<JobRequest> run(WidgetTester tester) async {
    final before = runner.requests.length;
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('ext-card-run')).last);
      for (var i = 0; i < 50 && runner.requests.length == before; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    return runner.requests.last;
  }

  testWidgets('качество из списка — в задаче и запоминается для новой карточки',
      (WidgetTester tester) async {
    await pump(tester);
    await say(tester, 'сконвертируй в jpg');
    final source = picture('кот.png');
    picker.next = <JobFile>[JobFile(path: source.path, name: 'кот.png')];
    await tester.tap(find.byKey(const Key('ext-card-pick-files')));
    await tester.pumpAndSettle();
    expect(find.text('Качество JPEG'), findsOneWidget);
    expect(find.text('85 — обычно'), findsOneWidget);
    await choose(tester, 'jpeg_quality', '60');
    await choose(tester, 'image_size', '1280');
    expect((await settings.load()).formDefaults, <String, String>{
      'converter.image_size': '1280',
      'converter.jpeg_quality': '60',
    });
    final request = await run(tester);
    expect(request.options, <String, String>{
      'jpeg_quality': '60',
      'image_size': '1280',
    });
    runner.jobs[request.cardId]!.add(const JobFailed(JobCodes.failed));
    await tester.pumpAndSettle();

    // Новая карточка — с последним выбором; фраза важнее запомненного.
    await say(tester, 'сконвертируй в jpg качество 75');
    picker.next = <JobFile>[JobFile(path: source.path, name: 'кот.png')];
    await tester.tap(find.byKey(const Key('ext-card-pick-files')).last);
    await tester.pumpAndSettle();
    final saved = await store.loadMessages(store.chatIds.single);
    final card = saved.last.job!;
    expect(card.choice('jpeg_quality'), '75');
    expect(card.choice('image_size'), '1280');
  });

  group('телефон: звук и видео делает система (ADR-026)', () {
    const caps = NativeMediaCaps(
      targets: <String>{'mp3', 'm4a', 'wav', 'mp4', 'frame-jpeg', 'frame-png'},
      video1080: false,
    );

    testWidgets('видео → mp3 320 уходит системе, а не в изолят', (
      WidgetTester tester,
    ) async {
      final native = _Runner();
      await pump(
        tester,
        fakeRunner: false,
        platform: JobPlatform.android,
        nativeMedia: NativeMedia(caps: caps, runner: native),
      );
      await say(tester, 'сконвертируй видео в mp3 320');
      final source = File(p.join(temp.path, 'клип.mp4'))
        ..writeAsStringSync('v');
      picker.next = <JobFile>[JobFile(path: source.path, name: 'клип.mp4')];
      await tester.tap(find.byKey(const Key('ext-card-pick-files')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Нужен ffmpeg'), findsNothing);
      expect(button(tester, 'ext-card-run').onPressed, isNotNull);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('ext-card-run')));
        for (var i = 0; i < 50 && native.requests.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();
      final request = native.requests.single;
      expect(request.action, 'mp3');
      expect(request.options, <String, String>{'audio_kbps': '320'});
      native.jobs[request.cardId]!.add(
        JobDone(outputs: <String>[request.target!], outputDir: temp.path),
      );
      await tester.pumpAndSettle();
      expect(find.text('Готово: клип.mp3'), findsOneWidget);
    });

    testWidgets('картинка на телефоне — по-прежнему на Dart', (
      WidgetTester tester,
    ) async {
      final native = _Runner();
      await pump(
        tester,
        fakeRunner: false,
        platform: JobPlatform.android,
        nativeMedia: NativeMedia(caps: caps, runner: native),
      );
      await say(tester, 'конвертируй фото в jpg');
      final source = picture('закат.png');
      picker.next = <JobFile>[JobFile(path: source.path, name: 'закат.png')];
      await tester.tap(find.byKey(const Key('ext-card-pick-files')));
      await tester.pumpAndSettle();
      // На телефоне результат — в папке карточки, не рядом с исходником.
      File? found() => temp
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => p.basename(f.path) == 'закат.jpg')
          .firstOrNull;
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('ext-card-run')));
        for (var i = 0; i < 300 && found() == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(found(), isNotNull);
      expect(find.text('Готово: закат.jpg'), findsOneWidget);
      expect(native.requests, isEmpty);
    });

    testWidgets('1080p, которого нет у телефона, — недоступен с причиной', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        platform: JobPlatform.android,
        nativeMedia: NativeMedia(caps: caps, runner: _Runner()),
      );
      await say(tester, 'сконвертируй видео в mp4');
      final source = File(p.join(temp.path, 'клип.mov'))
        ..writeAsStringSync('v');
      picker.next = <JobFile>[JobFile(path: source.path, name: 'клип.mov')];
      await tester.tap(find.byKey(const Key('ext-card-pick-files')));
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(
              of: find
                  .byKey(const ValueKey<String>('ext-card-select-video_res')),
              matching: find.byType(DropdownButton<String>),
            )
            .last,
      );
      await tester.pumpAndSettle();
      expect(find.text('Телефон не умеет кодировать 1080p'), findsWidgets);
    });

    testWidgets('без системного конвертера на телефоне — только картинки', (
      WidgetTester tester,
    ) async {
      await pump(tester, platform: JobPlatform.android);
      await say(tester, 'сконвертируй в mp3');
      final source = File(p.join(temp.path, 'клип.mp4'))
        ..writeAsStringSync('v');
      picker.next = <JobFile>[JobFile(path: source.path, name: 'клип.mp4')];
      await tester.tap(find.byKey(const Key('ext-card-pick-files')));
      await tester.pumpAndSettle();
      expect(find.textContaining('только картинки'), findsWidgets);
      expect(button(tester, 'ext-card-run').onPressed, isNull);
    });
  });

  testWidgets('«Найти команду» → «Сконвертировать файл» — пустая карточка', (
    WidgetTester tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('templates-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('composer-templates')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('command-find')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('command-search')),
      'сконвертировать',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('command-entry-ext.converter')));
    await tester.pumpAndSettle();
    expect(find.text('Конвертер'), findsOneWidget);
    final saved = await store.loadMessages(store.chatIds.single);
    expect(saved.single.job?.extensionId, ConverterConnector.id);
  });
}
