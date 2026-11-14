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

  setUp(() {
    temp = Directory.systemTemp.createTempSync('home_converter');
    store = InMemoryChatStore(
      attachments: InMemoryAttachmentStore(persistent: true),
    );
    runner = _Runner();
    picker = _Picker();
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Future<void> pump(WidgetTester tester, {bool fakeRunner = true}) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final clock = FixedClock(DateTime(2026, 11, 14, 12));
    final tasks =
        TaskService(repository: InMemoryTaskRepository(), clock: clock);
    final settings = InMemorySettingsStore();
    await settings.save(
      const AppSettings().withChoice(
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
          jobPlatform: JobPlatform.linux,
          fileOpener: FileOpener(platform: JobPlatform.linux),
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
    await say(tester, 'сконвертируй в png');
    final a = picture('a.jpg');
    picker.next = <JobFile>[JobFile(path: a.path, name: 'a.jpg')];
    await tester.tap(find.byKey(const Key('ext-card-pick-files')));
    await tester.pumpAndSettle();
    final b = picture('b.png');
    picker.next = <JobFile>[JobFile(path: b.path, name: 'b.png')];
    await tester.tap(find.byKey(const Key('ext-card-pick-files')));
    await tester.pumpAndSettle();
    expect(find.text('a.jpg'), findsNothing);
    expect(find.text('b.png'), findsOneWidget);
    final saved = await store.loadMessages(store.chatIds.single);
    // У .png одна цель — jpeg: она и выбрана.
    expect(saved.last.job!.choice('target'), 'jpeg');
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
