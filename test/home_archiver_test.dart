// Архиватор в чате (ADR-024): фраза → карточка Лиорио → выбор файла →
// «Запустить» → ход работы → «Готово», состояние карточки в истории;
// вложение сессии с .zip подставляется само; карточка из «Найти команду».
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:local_assistant/core/skills/archiver/archiver_connector.dart';
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
    temp = Directory.systemTemp.createTempSync('home_archiver');
    store = InMemoryChatStore(
      attachments: InMemoryAttachmentStore(persistent: true),
    );
    runner = _Runner();
    picker = _Picker();
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Future<void> pump(WidgetTester tester, {bool enabled = true}) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final clock = FixedClock(DateTime(2026, 11, 14, 12));
    final tasks =
        TaskService(repository: InMemoryTaskRepository(), clock: clock);
    final settings = InMemorySettingsStore();
    await settings.save(
      const AppSettings().withChoice(
        ExtensionChoice(enabled: <String>{if (enabled) ArchiverConnector.id}),
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
                ArchiverConnector(),
              ],
            ),
            clock: clock,
          ),
          tasks: tasks,
          clock: clock,
          settingsStore: settings,
          chatStore: store,
          jobRunner: runner,
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

  testWidgets('«сожми в zip» → файл → «Запустить» → готово, в истории', (
    WidgetTester tester,
  ) async {
    await pump(tester);
    await say(tester, 'сожми в zip');
    expect(find.text('Архиватор'), findsOneWidget);
    expect(button(tester, 'ext-card-run').onPressed, isNull);
    final source = File(p.join(temp.path, 'отчёт.txt'))..writeAsStringSync('x');
    picker.next = <JobFile>[JobFile(path: source.path, name: 'отчёт.txt')];
    await tester.tap(find.byKey(const Key('ext-card-pick-files')));
    await tester.pumpAndSettle();
    expect(find.text('отчёт.txt'), findsOneWidget);
    expect(button(tester, 'ext-card-run').onPressed, isNotNull);
    // Сжатие — выпадающим списком, «Сильное».
    expect(find.text('Обычное'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('ext-card-select-level')),
        matching: find.byType(DropdownButton<String>),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .ancestor(
            of: find
                .byKey(const ValueKey<String>('ext-card-choice-strong'))
                .last,
            matching: find.byType(InkWell),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('ext-card-run')));
      for (var i = 0; i < 50 && runner.requests.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    final request = runner.requests.single;
    expect(request.options, <String, String>{'level': 'strong'});
    expect(request.target, p.join(temp.path, 'отчёт.zip'));
    expect(request.sources.single.path, source.path);
    expect(find.byKey(const Key('ext-card-cancel')), findsOneWidget);
    runner.jobs[request.cardId]!.add(const JobProgress(0.5, 'Сжатие'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Сжатие: 50%'), findsOneWidget);
    runner.jobs[request.cardId]!.add(
      JobDone(outputs: <String>[request.target!], outputDir: temp.path),
    );
    await tester.pumpAndSettle();
    expect(find.text('Готово: отчёт.zip'), findsOneWidget);
    expect(find.byKey(const Key('ext-card-reveal')), findsOneWidget);
    final saved = await store.loadMessages(store.chatIds.single);
    final job = saved.last.job!;
    expect(job.state, CardState.done);
    expect(job.outputs.single, request.target);
    expect(saved.last.personaId, 'rio');
  });

  testWidgets('«Отмена» — «Отменено» и «Повторить» возвращает форму', (
    WidgetTester tester,
  ) async {
    await pump(tester);
    await say(tester, 'сожми в zip');
    final source = File(p.join(temp.path, 'a.txt'))..writeAsStringSync('x');
    picker.next = <JobFile>[JobFile(path: source.path, name: 'a.txt')];
    await tester.tap(find.byKey(const Key('ext-card-pick-files')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('ext-card-run')));
      for (var i = 0; i < 50 && runner.requests.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    await tester.tap(find.byKey(const Key('ext-card-cancel')));
    await tester.pumpAndSettle();
    expect(find.text('Отменено'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ext-card-retry')));
    await tester.pumpAndSettle();
    expect(find.text('a.txt'), findsOneWidget);
    expect(button(tester, 'ext-card-run').onPressed, isNotNull);
  });

  testWidgets('архиватор выключен — подсказка, без карточки', (
    WidgetTester tester,
  ) async {
    await pump(tester, enabled: false);
    await say(tester, 'распакуй архив');
    expect(find.textContaining('Архиватор выключен'), findsOneWidget);
    expect(find.text('Запустить'), findsNothing);
  });

  testWidgets('«Найти команду» → «Распаковать ZIP» — пустая карточка', (
    WidgetTester tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('templates-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('composer-templates')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('command-find')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('command-search')), 'zip');
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('command-entry-ext.archiver.extract')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Архиватор'), findsOneWidget);
    expect(find.byKey(const Key('ext-card-files-empty')), findsOneWidget);
    final saved = await store.loadMessages(store.chatIds.single);
    expect(saved.single.job?.choice('action'), ExtensionForms.extract);
  });
}
