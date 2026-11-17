// «Файлы сессии» справа (ADR-028) на главном экране: на телефоне —
// выдвижная панель (кнопка в шапке, «⋯», свайп влево), «Назад» её
// закрывает, клавиатура после неё сама не выскакивает; на компьютере —
// колонка вместо «Сегодня» в сессии; готовая карточка видна сразу.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/attachments/attachment_picker.dart';
import 'package:local_assistant/app/files/file_opener.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/app/jobs/job_picker.dart';
import 'package:local_assistant/core/chats/attachments.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
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
import 'package:local_assistant/core/skills/files/files_connector.dart';
import 'package:local_assistant/core/skills/talk/talk_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';
import 'package:path/path.dart' as p;

/// Прозрачная картинка 1×1.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

final class _Source implements AttachmentSource {
  _Source(this.name, this.bytes, {this.mimeType});

  @override
  final String name;
  @override
  final String? mimeType;
  final Uint8List bytes;

  @override
  Future<int> length() async => bytes.length;

  @override
  Future<Uint8List> readAsBytes() async => bytes;

  @override
  Future<void> saveTo(String path) async =>
      throw UnsupportedError('в тесте хранилище в памяти');
}

final class _Picker implements AttachmentPicker {
  List<AttachmentSource> next = <AttachmentSource>[];

  @override
  Future<List<AttachmentSource>> pick(PickKind kind) async {
    final files = next;
    next = <AttachmentSource>[];
    return files;
  }
}

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
  void cancel(String cardId) => jobs[cardId]?.close();
}

final class _JobPicker implements JobFilePicker {
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

final class _Harness {
  _Harness(this.store, this.picker, this.runner, this.jobPicker);

  final InMemoryChatStore store;
  final _Picker picker;
  final _Runner runner;
  final _JobPicker jobPicker;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  String? temp,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final clock = FixedClock(DateTime(2026, 11, 13, 12));
  final tasks = TaskService(repository: InMemoryTaskRepository(), clock: clock);
  final settings = InMemorySettingsStore();
  await settings.save(
    const AppSettings().withChoice(
      ExtensionChoice(enabled: <String>{ArchiverConnector.id}),
    ),
  );
  final h = _Harness(
    InMemoryChatStore(attachments: InMemoryAttachmentStore(persistent: true)),
    _Picker(),
    _Runner(),
    _JobPicker(),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.light(),
      home: HomePage(
        assistant: AssistantController(
          extensions: ExtensionRegistry(
            connectors: <Connector>[
              TasksConnector(
                taskService: tasks,
                parser: ScenarioParser(clock: clock),
              ),
              TalkConnector(taskService: tasks),
              ArchiverConnector(),
              FilesConnector(),
            ],
          ),
          clock: clock,
        ),
        tasks: tasks,
        clock: clock,
        settingsStore: settings,
        chatStore: h.store,
        attachmentPicker: h.picker,
        jobRunner: h.runner,
        jobPicker: h.jobPicker,
        jobPlatform: JobPlatform.linux,
        fileOpener: FileOpener(platform: JobPlatform.linux),
        tempRoot: temp == null ? null : () async => temp,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> _say(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('assistant-input')), text);
  await tester.tap(find.byKey(const Key('assistant-send')));
  await tester.pumpAndSettle();
}

/// «+» → «Фото» с картинкой и отправка без текста.
Future<void> _sendPhoto(WidgetTester tester, _Harness h) async {
  h.picker.next = <AttachmentSource>[
    _Source('кот.png', _png, mimeType: 'image/png'),
  ];
  await tester.tap(find.byKey(const Key('templates-button')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('composer-attach')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('attach-photo')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('assistant-send')));
  await tester.pumpAndSettle();
}

Future<ChatAttachment> _sentPhoto(_Harness h) async {
  final messages = await h.store.loadMessages(h.store.chatIds.single);
  return messages
      .firstWhere((ChatMessage m) => m.attachments.isNotEmpty)
      .attachments
      .single;
}

final Finder _panel = find.byKey(const Key('session-files-panel'));

bool _endDrawerOpen(WidgetTester tester) =>
    tester.state<ScaffoldState>(find.byType(Scaffold).first).isEndDrawerOpen;

void main() {
  testWidgets(
      'телефон: без файлов кнопки нет, «⋯ → Файлы сессии» — пусто, '
      '«Назад» закрывает и оставляет в сессии', (tester) async {
    await _pump(tester);
    expect(find.byKey(const Key('session-files')), findsNothing);
    expect(_panel, findsNothing);
    await _say(tester, 'привет');
    expect(find.byKey(const Key('session-files')), findsNothing);
    await tester.tap(find.byKey(const Key('session-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('menu-files')));
    await tester.pumpAndSettle();
    expect(_panel, findsOneWidget);
    expect(find.text('Здесь пока пусто'), findsOneWidget);
    expect(_endDrawerOpen(tester), isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_panel, findsNothing);
    expect(find.byKey(const Key('assistant-input')), findsOneWidget);
    expect(find.text('привет'), findsWidgets, reason: 'та же сессия');
  });

  testWidgets(
      'телефон: фото в сессии — кнопка в шапке открывает панель; '
      '«Показать в сообщении» закрывает её и подсвечивает сообщение',
      (tester) async {
    final h = await _pump(tester);
    await _sendPhoto(tester, h);
    final photo = await _sentPhoto(h);
    final files = find.byKey(const Key('session-files'));
    expect(files, findsOneWidget);
    expect(tester.getSize(files).height, greaterThanOrEqualTo(44));
    await tester.tap(files);
    await tester.pumpAndSettle();
    expect(_panel, findsOneWidget);
    final row = find.byKey(Key('session-file-att:${photo.id}'));
    expect(row, findsOneWidget);
    expect(find.text('Вложения'), findsOneWidget);
    expect(find.text('Артефакты'), findsNothing);

    await tester.tap(find.byKey(Key('session-file-more-att:${photo.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-file-show')));
    await tester.pumpAndSettle();
    expect(_panel, findsNothing);
    expect(find.byKey(Key('msg-${photo.id.split('-').first}')), findsOneWidget);

    // Хранилище в памяти: нажатие по файлу — сведения о нём.
    await tester.tap(files);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('attachment-info')), findsOneWidget);
  });

  testWidgets(
      'телефон: задача в фокусе — «⋯» нет, а «Файлы сессии» в шапке есть',
      (tester) async {
    await _pump(tester);
    await _say(tester, 'Добавь задачу купить хлеб');
    expect(find.byKey(const Key('session-more')), findsNothing);
    final files = find.byKey(const Key('session-files'));
    expect(files, findsOneWidget, reason: 'и без файлов: «⋯» его не заменит');
    await tester.tap(files);
    await tester.pumpAndSettle();
    expect(_panel, findsOneWidget);
  });

  testWidgets('телефон: свайп влево по ленте открывает панель', (tester) async {
    final h = await _pump(tester);
    await _sendPhoto(tester, h);
    await tester.dragFrom(const Offset(300, 300), const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(_panel, findsOneWidget);
    // Свайп вправо по-прежнему — меню.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(80, 300), const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(_panel, findsNothing);
    expect(find.byKey(const Key('drawer-my-relay')), findsOneWidget);
  });

  testWidgets('после панели клавиатура сама не выскакивает', (tester) async {
    final h = await _pump(tester);
    await _sendPhoto(tester, h);
    await tester.tap(find.byKey(const Key('assistant-input')));
    await tester.pumpAndSettle();
    final input = find.byKey(const Key('assistant-input'));
    bool focused() =>
        tester.widget<TextField>(input).focusNode?.hasFocus ??
        FocusManager.instance.primaryFocus?.context?.widget is EditableText;
    expect(focused(), isTrue);

    await tester.tap(find.byKey(const Key('session-files')));
    await tester.pumpAndSettle();
    expect(_panel, findsOneWidget);
    expect(focused(), isFalse);
    await tester.tap(find.byKey(const Key('session-files-close')));
    await tester.pumpAndSettle();
    expect(_panel, findsNothing);
    expect(focused(), isFalse, reason: 'фокус не вернулся полю');
    expect(tester.testTextInput.isVisible, isFalse);

    // И через «Назад» — так же.
    await tester.tap(input);
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(300, 300), const Offset(-200, 0));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(focused(), isFalse);
  });

  testWidgets('в «Мой Связной» и разделах правой панели нет', (tester) async {
    final h = await _pump(tester);
    await _sendPhoto(tester, h);
    await tester.tap(find.byTooltip('Меню'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-tasks')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-files')), findsNothing);
    await tester.dragFrom(const Offset(300, 400), const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(_panel, findsNothing);
  });

  group('компьютер', () {
    late Directory temp;
    setUp(() => temp = Directory.systemTemp.createTempSync('files_panel'));
    tearDown(() => temp.deleteSync(recursive: true));

    testWidgets(
        'колонка вместо «Сегодня»; готовый архив появляется в открытой '
        'панели сразу', (tester) async {
      final h = await _pump(
        tester,
        size: const Size(1440, 900),
        temp: temp.path,
      );
      expect(_panel, findsOneWidget);
      expect(find.byKey(const Key('today-panel')), findsNothing);
      expect(find.text('Здесь пока пусто'), findsOneWidget);

      await _say(tester, 'сожми в zip');
      final source = File(p.join(temp.path, 'отчёт.txt'))
        ..writeAsStringSync('x');
      h.jobPicker.next = <JobFile>[
        JobFile(path: source.path, name: 'отчёт.txt'),
      ];
      await tester.tap(find.byKey(const Key('ext-card-pick-files')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('ext-card-run')));
        for (var i = 0; i < 50 && h.runner.requests.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();
      final request = h.runner.requests.single;
      expect(find.text('Артефакты'), findsNothing, reason: 'ещё идёт');
      File(request.target!).writeAsStringSync('zip');
      h.runner.jobs[request.cardId]!.add(
        JobDone(outputs: <String>[request.target!], outputDir: temp.path),
      );
      await tester.pumpAndSettle();
      expect(find.text('Артефакты'), findsOneWidget);
      final row = find.byKey(Key('session-file-out:${request.cardId}:0'));
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('отчёт.zip')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row,
          // Узкая колонка делит подпись между частями (metaLines).
          matching: find.byWidgetPredicate(
            (Widget w) =>
                w is Text &&
                (w.data ?? '').replaceAll('\n', '\u00A0· ') ==
                    'Архиватор\u00A0· 3\u00A0Б\u00A0· 12:00',
          ),
        ),
        findsOneWidget,
      );

      // Свернуть — кнопка в шапке; снова открыть.
      await tester.tap(find.byKey(const Key('session-files-close')));
      await tester.pumpAndSettle();
      expect(_panel, findsNothing);
      await tester.tap(find.byKey(const Key('session-files')));
      await tester.pumpAndSettle();
      expect(_panel, findsOneWidget);

      // В задачах — «Сегодня».
      await tester.tap(find.byKey(const Key('nav-tasks')));
      await tester.pumpAndSettle();
      expect(_panel, findsNothing);
      expect(find.byKey(const Key('today-panel')), findsOneWidget);
    });

    testWidgets(
        '«удали этот файл» после архива: вопрос с именем, «Удалить» стирает '
        'результат, исходник остаётся (ADR-028)', (tester) async {
      final h = await _pump(
        tester,
        size: const Size(1440, 900),
        temp: temp.path,
      );
      await _say(tester, 'сожми в zip');
      final source = File(p.join(temp.path, 'отчёт.txt'))
        ..writeAsStringSync('x');
      h.jobPicker.next = <JobFile>[
        JobFile(path: source.path, name: 'отчёт.txt'),
      ];
      await tester.tap(find.byKey(const Key('ext-card-pick-files')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('ext-card-run')));
        for (var i = 0; i < 50 && h.runner.requests.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();
      final request = h.runner.requests.single;
      final zip = File(request.target!)..writeAsStringSync('zip');
      h.runner.jobs[request.cardId]!.add(
        JobDone(outputs: <String>[zip.path], outputDir: temp.path),
      );
      await tester.pumpAndSettle();
      final row = find.byKey(Key('session-file-out:${request.cardId}:0'));
      expect(row, findsOneWidget);

      await _say(tester, 'удали этот файл');
      expect(
        find.textContaining('Удалить «отчёт.zip» из файлов сессии?'),
        findsWidgets,
      );
      expect(zip.existsSync(), isTrue, reason: 'до ответа ничего не удалено');
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Удалить'));
        for (var i = 0; i < 50 && zip.existsSync(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(zip.existsSync(), isFalse);
      expect(source.existsSync(), isTrue, reason: 'исходник не трогается');
      expect(row, findsNothing);
      expect(find.textContaining('«отчёт.zip»'), findsWidgets);
    });
  });
}
