// Поле в фокусе всегда видно над экранной клавиатурой (ADR-044): каждый
// экран, шторка и окно с полем ввода — на телефоне 390×844 и маленьком
// 360×640 с клавиатурой 300. Новое поле ввода — новая строка в _cases.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/extensions/tool_kit.dart';
import 'package:local_assistant/app/extensions/weather_kit.dart';
import 'package:local_assistant/app/extensions/weather_screen.dart';
import 'package:local_assistant/app/extensions/ytdl_kit.dart';
import 'package:local_assistant/app/files/file_opener.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/app/links/link_opener.dart';
import 'package:local_assistant/app/passwords/passwords_files.dart';
import 'package:local_assistant/app/shell/project_dialogs.dart';
import 'package:local_assistant/app/shell/session_hold_menu.dart';
import 'package:local_assistant/app/widgets/add_app_screen.dart';
import 'package:local_assistant/app/widgets/command_finder_sheet.dart';
import 'package:local_assistant/app/widgets/connection_screen.dart';
import 'package:local_assistant/app/widgets/keyboard_safe.dart';
import 'package:local_assistant/app/widgets/warehouse_connection_card.dart';
import 'package:local_assistant/core/chats/attachments.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
import 'package:local_assistant/core/commands/command_catalog.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/downloads/verified_download.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/extensions/tools/tool_spec.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/weather/weather_connector.dart';
import 'package:local_assistant/core/skills/ytdl/ytdl_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';
import 'package:local_assistant/main.dart';
import 'package:local_assistant/web_widget/widget_app.dart';
import 'package:local_assistant/web_widget/widget_session.dart';
import 'package:local_assistant/web_widget/widget_storage.dart';
import 'package:path/path.dart' as p;

import '../screens/app_connections_ui_test.dart' show Ui, settle;
import '../support/app_fonts.dart';
import '../support/fake_weather.dart';
import '../support/home_nav.dart';
import '../support/keyboard.dart';
import '../web_widget/fakes.dart' as web;

/// Экран с полями: [open] показывает его на текущем размере экрана,
/// [fields] — все поля ввода на нём; пусто — каждое поле открытого экрана
/// (для экранов, где набор полей зависит от состояния).
final class _Case {
  const _Case(this.name, this.open, [this.fields = const <Finder>[]]);

  final String name;
  final Future<void> Function(WidgetTester tester) open;
  final List<Finder> fields;
}

/// Каждое поле на экране — по одному искателю на поле.
List<Finder> _everyField() => <Finder>[
      for (final element in find.byType(TextField).evaluate())
        find.byWidget(element.widget),
    ];

Finder _key(String key) => find.byKey(Key(key));
Finder _value(String key) => find.byKey(ValueKey<String>(key));

/// Приложение как в `main.dart`: тема и [KeyboardSafeScope] в `builder`.
Widget _app(Widget home) => MaterialApp(
      theme: AssistantTheme.dark(),
      builder: (BuildContext context, Widget? child) =>
          KeyboardSafeScope(child: child!),
      home: home,
    );

/// Пустой экран с кнопкой, которая открывает окно или шторку [show].
Future<void> _launch(
  WidgetTester tester,
  void Function(BuildContext context) show,
) async {
  await tester.pumpWidget(
    _app(
      Scaffold(
        body: Builder(
          builder: (BuildContext context) => Center(
            child: TextButton(
              key: const Key('launch'),
              onPressed: () => show(context),
              child: const Text('Открыть'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(_key('launch'));
  await tester.pumpAndSettle();
}

WeatherKit _weather() => WeatherKit(
      service: WeatherService.memory(
        transport: RecordingTransport.kazan(),
        clock: FixedClock(DateTime(2026, 11, 15, 9, 40)),
        settings: WeatherSettings(
          source: WeatherSource.openMeteo,
          networkAllowedAt: DateTime(2026, 11, 1),
        ),
      ),
      links: LinkOpener(platform: JobPlatform.linux),
    );

/// Приложение целиком, как в `main.dart` ([AssistantApp]).
Future<void> _home(WidgetTester tester) async {
  final clock = FixedClock(DateTime(2026, 11, 9, 12, 40));
  final tasks = TaskService(repository: InMemoryTaskRepository(), clock: clock);
  await tester.pumpWidget(
    AssistantApp(
      assistant: AssistantController(
        connectors: <Connector>[
          TasksConnector(
            taskService: tasks,
            parser: ScenarioParser(clock: clock),
          ),
        ],
        clock: clock,
      ),
      tasks: tasks,
      clock: clock,
      settingsStore: InMemorySettingsStore(),
      chatStore: InMemoryChatStore(),
    ),
  );
  await tester.pumpAndSettle();
}

/// Главный экран с командой в ленте (задача «Отчёт» создана).
Future<void> _homeWithTask(WidgetTester tester) async {
  await _home(tester);
  await tester.enterText(_key('assistant-input'), 'Добавь задачу «Отчёт»');
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

/// Веб-помощник склада: панель открыта, склад ответил.
Future<void> _webWidget(WidgetTester tester) async {
  final host = web.FakeHost();
  final session = WidgetSession(
    host: host,
    transport: web.FakeWarehouse(),
    storage: MemoryStorage(),
    builtInManifest: web.builtInSource(),
    version: '1.0.0',
    updateEvery: const Duration(hours: 1),
  );
  addTearDown(session.dispose);
  await tester.pumpWidget(WidgetApp(session: session));
  await tester.runAsync(() async {
    session.start();
    host.emit(web.initMessage());
    await web.settle();
  });
  await tester.pump();
  await tester.pumpAndSettle();
}

/// Окно приложения поверх веб-помощника: [show] открывает его из
/// контекста помощника — как меню сессии и проекта в `widget_side.dart`.
Future<void> _webWidgetDialog(
  WidgetTester tester,
  void Function(BuildContext context) show,
) async {
  await _webWidget(tester);
  show(tester.element(_value('widget-input')));
  await tester.pumpAndSettle();
}

/// Загрузок в тесте нет: yt-dlp «не установлен».
final class _NoDownloads implements FileDownloader {
  @override
  Stream<DownloadProgress> download(
    Uri uri,
    File partFile, {
    required int expectedBytes,
    required CancelToken cancel,
  }) =>
      const Stream<DownloadProgress>.empty();
}

/// Лента с карточкой загрузчика видео: поле ссылки — в ленте над полем
/// команды (yt-dlp не установлен — сети и файлов не нужно).
Future<void> _homeWithYtdlCard(WidgetTester tester) async {
  final temp = Directory.systemTemp.createTempSync('keyboard_ytdl');
  addTearDown(() => temp.deleteSync(recursive: true));
  final binary = utf8.encode('yt-dlp');
  final ytdl = YtdlKit(
    tool: ToolKit(
      spec: ToolSpec(
        id: 'ytdlp',
        title: 'yt-dlp',
        abi: Abi.linuxX64,
        version: '2026.10.26',
        url: 'https://github.com/yt-dlp/yt-dlp/releases/download/'
            '2026.10.26/yt-dlp_linux',
        sha256: crypto.sha256.convert(binary).toString(),
        bytes: binary.length,
        archive: ToolArchive.none,
        entry: '',
        binaryName: 'yt-dlp',
        binaryBytes: binary.length,
        license: 'Unlicense / GPLv3+',
        sourceUrl: 'https://github.com/yt-dlp/yt-dlp',
      ),
      downloader: _NoDownloads(),
      dir: p.join(temp.path, 'tools', 'ytdlp'),
      chmod: (String path) async {},
    ),
    settingsPath: p.join(temp.path, 'ytdl.json'),
    defaultRoot: () async => p.join(temp.path, 'Загрузки'),
  );
  final clock = FixedClock(DateTime(2026, 11, 14, 12));
  final tasks = TaskService(repository: InMemoryTaskRepository(), clock: clock);
  final settings = InMemorySettingsStore();
  await settings.save(
    const AppSettings().withChoice(
      const ExtensionChoice(enabled: <String>{YtdlConnector.id}),
    ),
  );
  await tester.pumpWidget(
    _app(
      HomePage(
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
        jobPlatform: JobPlatform.linux,
        fileOpener: FileOpener(platform: JobPlatform.linux),
        tempRoot: () async => temp.path,
        ytdl: ytdl,
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.enterText(
    _key('assistant-input'),
    'скачай ролик https://example.com/v/abc123',
  );
  await tester.tap(_key('assistant-send'));
  await tester.pumpAndSettle();
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

final List<_Case> _cases = <_Case>[
  _Case(
    'лента: ссылка в карточке загрузчика',
    _homeWithYtdlCard,
    <Finder>[_key('ext-card-url'), _key('assistant-input')],
  ),
  _Case('веб-помощник склада', _webWidget, <Finder>[_value('widget-input')]),
  _Case(
    'веб-помощник: поиск по сессиям в меню',
    (tester) async {
      await _webWidget(tester);
      await tester.tap(_value('widget-menu'));
      await tester.pumpAndSettle();
    },
    <Finder>[_key('session-search')],
  ),
  _Case(
    'веб-помощник: переименовать сессию',
    (tester) => _webWidgetDialog(
      tester,
      (context) => unawaited(showRenameSessionDialog(context, current: 'План')),
    ),
    <Finder>[_key('rename-field')],
  ),
  _Case(
    'веб-помощник: новый проект',
    (tester) => _webWidgetDialog(
      tester,
      (context) => unawaited(showProjectDialog(context)),
    ),
    <Finder>[_key('project-name-field'), _key('project-description-field')],
  ),
  _Case(
    'веб-помощник: метка задач проекта',
    (tester) => _webWidgetDialog(
      tester,
      (context) => unawaited(
        showProjectTagDialog(context, suggestions: const <String>['склад']),
      ),
    ),
    <Finder>[_key('project-tag-field')],
  ),
  _Case(
    'склад: вставить ссылку',
    (tester) async {
      final ui = Ui();
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: ListView(
              children: <Widget>[
                WarehouseConnectionCard(
                  service: ui.warehouse,
                  onEnabledChanged: (_) {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(_value('warehouse-paste'));
      await tester.pumpAndSettle();
    },
    <Finder>[_value('warehouse-paste-field')],
  ),
  _Case('подключение вручную', (tester) async {
    final ui = Ui();
    await tester.pumpWidget(
      _app(ConnectionScreen(service: ui.warehouse, onEnabledChanged: (_) {})),
    );
    await settle(tester);
  }),
  _Case(
    'подключить приложение',
    (tester) async {
      final ui = Ui();
      await tester.pumpWidget(_app(AddAppScreen(host: ui.host)));
      await settle(tester);
    },
    <Finder>[_value('add-app-address')],
  ),
  _Case(
    'выбор файла',
    (tester) async {
      await _launch(
        tester,
        (context) => unawaited(
          showDialog<String>(
            context: context,
            builder: (BuildContext context) => const FileBrowserDialog(
              title: 'Резервная копия',
              start: 'test/fixtures',
              extensions: <String>['json'],
              fileName: 'сейф.json',
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
    },
    <Finder>[_value('file-browser-path')],
  ),
  _Case('главный: поле команды', _home, <Finder>[_key('assistant-input')]),
  _Case(
    'главный: поле команды с лентой',
    _homeWithTask,
    <Finder>[_key('assistant-input')],
  ),
  _Case(
    'меню: поиск по сессиям',
    (tester) async {
      await _homeWithTask(tester);
      await openDrawerIfNeeded(tester);
    },
    <Finder>[_key('session-search')],
  ),
  _Case(
    'задачи: поиск',
    (tester) async {
      await _homeWithTask(tester);
      await tapInDrawer(tester, const Key('nav-tasks'));
    },
    <Finder>[
      find.descendant(
        of: _key('task-search'),
        matching: find.byType(TextField),
      ),
    ],
  ),
  _Case(
    'документ задачи',
    (tester) async {
      await _homeWithTask(tester);
      await tester.tap(_key('mode-document'));
      await tester.pumpAndSettle();
    },
    <Finder>[
      _key('document-title'),
      _key('document-project'),
      _key('document-editor'),
    ],
  ),
  _Case(
    'настройки: добавить пак',
    (tester) async {
      await _home(tester);
      await openSettings(tester);
      await tester.ensureVisible(_value('pack-add'));
      await tester.pumpAndSettle();
      await tester.tap(_value('pack-add'));
      await tester.pumpAndSettle();
    },
    <Finder>[_value('pack-json')],
  ),
  _Case(
    'помощники: имя помощника',
    (tester) async {
      await _home(tester);
      await openMyRelay(tester, 'assistants');
      await revealAssistantSetting(tester, 'persona-name-rio');
    },
    <Finder>[_value('persona-name-rio')],
  ),
  _Case(
    'переименовать сессию',
    (tester) => _launch(
      tester,
      (context) => unawaited(showRenameSessionDialog(context, current: 'План')),
    ),
    <Finder>[_key('rename-field')],
  ),
  _Case(
    'новый проект',
    (tester) => _launch(
      tester,
      (context) => unawaited(showProjectDialog(context)),
    ),
    <Finder>[_key('project-name-field'), _key('project-description-field')],
  ),
  _Case(
    'метка задач проекта',
    (tester) => _launch(
      tester,
      (context) => unawaited(
        showProjectTagDialog(
          context,
          suggestions: const <String>['дом', 'работа', 'дача', 'машина'],
        ),
      ),
    ),
    <Finder>[_key('project-tag-field')],
  ),
  _Case(
    'погода: город и ссылка',
    (tester) async {
      await tester.pumpWidget(_app(WeatherScreen(kit: _weather())));
      await tester.pumpAndSettle();
    },
    <Finder>[_value('weather-city-field'), _value('weather-link-field')],
  ),
  _Case(
    'найти команду',
    (tester) => _launch(
      tester,
      (context) => unawaited(
        showCommandFinder(context, CommandCatalog.build(connectors: const [])),
      ),
    ),
    <Finder>[_key('command-search')],
  ),
];

void main() {
  setUpAll(loadAppFonts);

  // Сама проверка: поле, которое клавиатура закрывает, она ловит.
  for (final (String name, Widget body) in <(String, Widget)>[
    (
      'экран не сжимается под клавиатуру',
      const Scaffold(
        resizeToAvoidBottomInset: false,
        body: Align(
          alignment: Alignment.bottomCenter,
          child: TextField(key: Key('low')),
        ),
      ),
    ),
    (
      'поле в столбце без прокрутки',
      Scaffold(
        body: Column(
          children: <Widget>[
            const SizedBox(height: 500),
            const TextField(key: Key('low')),
          ],
        ),
      ),
    ),
  ]) {
    testWidgets('проверка ловит: $name', (tester) async {
      setPhoneScreen(tester, keyboardScreens.last);
      await tester.pumpWidget(_app(body));
      await expectLater(
        () => expectFieldAboveKeyboard(tester, _key('low')),
        throwsA(isA<TestFailure>()),
      );
    });
  }

  testWidgets('приложение и веб-помощник — под KeyboardSafeScope',
      (tester) async {
    setPhoneScreen(tester, keyboardScreens.first);
    await _home(tester);
    expect(find.byType(KeyboardSafeScope), findsOneWidget);
    await _webWidget(tester);
    expect(find.byType(KeyboardSafeScope), findsOneWidget);
  });

  testWidgets('после подъёма клавиатуры прокрутку не держит', (tester) async {
    setPhoneScreen(tester, keyboardScreens.last);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: ListView(
            controller: scroll,
            children: <Widget>[
              for (var i = 0; i < 6; i++) const SizedBox(height: 100),
              const TextField(
                key: Key('mid'),
                maxLength: 40,
                decoration: InputDecoration(
                  labelText: 'Поле',
                  helperText: 'Подпись под полем',
                ),
              ),
              for (var i = 0; i < 10; i++) const SizedBox(height: 100),
            ],
          ),
        ),
      ),
    );
    await expectFieldAboveKeyboard(tester, _key('mid'));
    // Клавиатура открыта, человек листает дальше: поле не возвращается.
    await tester.showKeyboard(_key('mid'));
    await setKeyboard(tester, keyboardHeight);
    final shown = scroll.offset;
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    expect(scroll.offset, greaterThan(shown + 300));
  });

  testWidgets('фокус не в поле — ничего не листает', (tester) async {
    setPhoneScreen(tester, keyboardScreens.last);
    final scroll = ScrollController(initialScrollOffset: 300);
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: ListView(
            controller: scroll,
            children: <Widget>[
              const TextField(key: Key('top')),
              for (var i = 0; i < 10; i++) const SizedBox(height: 100),
              TextButton(
                key: const Key('button'),
                onPressed: () {},
                child: const Text('Кнопка'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: keyboardHeight);
    await tester.pumpAndSettle();
    expect(scroll.offset, 300);
  });

  for (final screen in keyboardScreens) {
    final size = '${screen.width.round()}×${screen.height.round()}';
    for (final c in _cases) {
      testWidgets('${c.name}, $size: поле над клавиатурой', (tester) async {
        setPhoneScreen(tester, screen);
        await c.open(tester);
        final fields = c.fields.isEmpty ? _everyField() : c.fields;
        expect(fields, isNotEmpty, reason: 'на экране нет полей');
        for (final field in fields) {
          await expectFieldAboveKeyboard(tester, field);
        }
      });
    }
  }
}
