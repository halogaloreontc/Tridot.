// Загрузчик видео в чате (ADR-024, шаг 3): фраза со ссылкой → карточка
// Лиорио со ссылкой в поле (в тексте ответа её нет) → «Скачать» →
// задача получает ссылку, формат и папку загрузок → «Готово»; без yt-dlp
// «Скачать» неактивна; карточка из «Найти команду» пустая.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/extensions/tool_kit.dart';
import 'package:local_assistant/app/extensions/ytdl_kit.dart';
import 'package:local_assistant/app/files/file_opener.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/core/chats/attachments.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/downloads/verified_download.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/extensions/tools/tool_spec.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';
import 'package:local_assistant/core/jobs/job_runner.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/ytdl/ytdl_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';
import 'package:path/path.dart' as p;

const String _url = 'https://example.com/v/abc123';

final List<int> _binary = utf8.encode('yt-dlp');

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

final class _Downloader implements FileDownloader {
  @override
  Stream<DownloadProgress> download(
    Uri uri,
    File partFile, {
    required int expectedBytes,
    required CancelToken cancel,
  }) async* {
    await partFile.parent.create(recursive: true);
    await partFile.writeAsBytes(_binary);
    yield DownloadProgress(expectedBytes, expectedBytes);
  }
}

void main() {
  late Directory temp;
  late _Runner runner;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('home_ytdl');
    runner = _Runner();
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Future<YtdlKit> kit(WidgetTester tester, {required bool installed}) async {
    final ytdl = YtdlKit(
      tool: ToolKit(
        spec: ToolSpec(
          id: 'ytdlp',
          title: 'yt-dlp',
          abi: Abi.linuxX64,
          version: '2026.10.26',
          url: 'https://github.com/yt-dlp/yt-dlp/releases/download/'
              '2026.10.26/yt-dlp_linux',
          sha256: crypto.sha256.convert(_binary).toString(),
          bytes: _binary.length,
          archive: ToolArchive.none,
          entry: '',
          binaryName: 'yt-dlp',
          binaryBytes: _binary.length,
          license: 'Unlicense / GPLv3+',
          sourceUrl: 'https://github.com/yt-dlp/yt-dlp',
        ),
        downloader: _Downloader(),
        dir: p.join(temp.path, 'tools', 'ytdlp'),
        chmod: (String path) async {},
      ),
      settingsPath: p.join(temp.path, 'ytdl.json'),
      defaultRoot: () async => p.join(temp.path, 'Загрузки'),
    );
    if (installed) await tester.runAsync(ytdl.tool.install);
    return ytdl;
  }

  Future<void> pump(WidgetTester tester, YtdlKit ytdl) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final clock = FixedClock(DateTime(2026, 11, 14, 12));
    final tasks =
        TaskService(repository: InMemoryTaskRepository(), clock: clock);
    final settings = InMemorySettingsStore();
    await settings.save(
      const AppSettings().withChoice(
        const ExtensionChoice(enabled: <String>{YtdlConnector.id}),
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
                YtdlConnector(),
              ],
            ),
            clock: clock,
          ),
          tasks: tasks,
          clock: clock,
          settingsStore: settings,
          chatStore: InMemoryChatStore(
            attachments: InMemoryAttachmentStore(persistent: true),
          ),
          jobRunner: runner,
          jobPlatform: JobPlatform.linux,
          fileOpener: FileOpener(platform: JobPlatform.linux),
          tempRoot: () async => temp.path,
          ytdl: ytdl,
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

  ButtonStyleButton run(WidgetTester tester) =>
      tester.widget<ButtonStyleButton>(find.byKey(const Key('ext-card-run')));

  testWidgets('ссылка из фразы → «Скачать» → задача с ссылкой и папкой',
      (WidgetTester tester) async {
    final ytdl = await kit(tester, installed: true);
    await pump(tester, ytdl);
    await say(tester, 'скачай видео в 1080p по ссылке $_url');
    expect(find.text('Загрузчик видео'), findsOneWidget);
    // В ответе Лиорио ссылки нет — только в поле карточки (и в
    // сообщении пользователя, это его история).
    expect(find.textContaining('example.com'), findsNWidgets(2));
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('ext-card-url')))
          .controller!
          .text,
      _url,
    );
    expect(run(tester).onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('ext-card-run')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    final request = runner.requests.single;
    expect(request.extensionId, YtdlConnector.id);
    expect(request.url, _url);
    expect(request.action, YtdlFormats.video1080);
    expect(request.outputDir, p.join(temp.path, 'Загрузки', 'Tridot'));
    expect(p.isWithin(request.outputDir, request.temp!), isTrue);
    expect(find.byKey(const Key('ext-card-cancel')), findsOneWidget);
    final file = p.join(request.outputDir, 'Ролик [abc123].mp4');
    runner.jobs[request.cardId]!
      ..add(JobDone(outputs: <String>[file], outputDir: request.outputDir))
      ..close();
    await tester.pumpAndSettle();
    expect(find.textContaining('Готово: Ролик [abc123].mp4'), findsOneWidget);
    expect(find.byKey(const Key('ext-card-reveal')), findsOneWidget);
  });

  testWidgets('без yt-dlp «Скачать» неактивна и сказано, где его взять',
      (WidgetTester tester) async {
    final ytdl = await kit(tester, installed: false);
    await pump(tester, ytdl);
    await say(tester, 'скачай ролик $_url');
    expect(run(tester).onPressed, isNull);
    expect(find.textContaining('Нужен yt-dlp'), findsOneWidget);
    expect(runner.requests, isEmpty);
  });

  testWidgets('«Найти команду» → пустая карточка; ссылку вставляют сами',
      (WidgetTester tester) async {
    final ytdl = await kit(tester, installed: true);
    await pump(tester, ytdl);
    await tester.tap(find.byKey(const Key('templates-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('composer-templates')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('command-find')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('command-search')), 'видео');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('command-entry-ext.ytdl')));
    await tester.pumpAndSettle();
    expect(find.text('Загрузчик видео'), findsOneWidget);
    expect(run(tester).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('ext-card-url')), _url);
    await tester.pumpAndSettle();
    expect(run(tester).onPressed, isNotNull);
  });
}
