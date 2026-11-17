// Слова не рвутся посреди строки (ADR-021, «Подписи целиком»): главные
// экраны на ширине телефона 320 и 360 и с масштабом шрифта 1.0, 1.3 и 2.0
// проверяет word_wrap_guard — ни одна строка не кончается внутри слова,
// подписи из одного слова не обрезаны и не срезаны краем.
//
// Поводом стал снимок с телефона: «Напомнит/ь» под круглой кнопкой
// пустой сессии (360 px, шрифт 115 %).
//
// Пароли — только канарейки (D24).
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/files/file_opener.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/app/homescreen/home_screen_channel.dart';
import 'package:local_assistant/app/homescreen/home_screen_section.dart';
import 'package:local_assistant/app/jobs/job_hub.dart';
import 'package:local_assistant/app/passwords/backup_screens.dart';
import 'package:local_assistant/app/passwords/clipboard_guard.dart';
import 'package:local_assistant/app/passwords/entry_screens.dart';
import 'package:local_assistant/app/passwords/generator_view.dart';
import 'package:local_assistant/app/passwords/import_screen.dart';
import 'package:local_assistant/app/passwords/passwords_kit.dart';
import 'package:local_assistant/app/passwords/passwords_platform.dart';
import 'package:local_assistant/app/passwords/passwords_screen.dart';
import 'package:local_assistant/app/passwords/passwords_settings_screen.dart';
import 'package:local_assistant/app/passwords/recall_views.dart';
import 'package:local_assistant/app/screens/my_relay_screen.dart';
import 'package:local_assistant/app/shell/project_dialogs.dart';
import 'package:local_assistant/app/shell/session_files_panel.dart';
import 'package:local_assistant/app/voice/voice_kit.dart';
import 'package:local_assistant/app/widgets/action_card_view.dart';
import 'package:local_assistant/app/widgets/extension_card_view.dart';
import 'package:local_assistant/app/widgets/warehouse_card_view.dart';
import 'package:local_assistant/app/widgets/warehouse_connection_card.dart';
import 'package:local_assistant/app/widgets/whole_word_text.dart';
import 'package:local_assistant/core/chats/attachments.dart';
import 'package:local_assistant/core/chats/chat_projects.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
import 'package:local_assistant/core/chats/session_files.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';
import 'package:local_assistant/core/models/action_card.dart';
import 'package:local_assistant/core/models/warehouse_card.dart';
import 'package:local_assistant/core/connectors/manifest/connection.dart';
import 'package:local_assistant/core/connectors/manifest/connection_service.dart';
import 'package:local_assistant/core/connectors/manifest/connection_slots.dart';
import 'package:local_assistant/core/connectors/manifest/manifest_connector.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/passwords/vault.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/converter/convert_caps.dart';
import 'package:local_assistant/core/skills/passwords/passwords_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';
import 'package:local_assistant/core/voice/voice_recognizer.dart';
import 'package:path/path.dart' as p;

import 'passwords/vault_test_support.dart';
import 'support/app_fonts.dart';
import 'support/fake_home_screen.dart';
import 'support/fake_voice.dart';
import 'support/home_nav.dart';
import 'support/word_wrap_guard.dart';

final _clock = FixedClock(DateTime(2026, 11, 4, 12));

/// Исключения проверки (ключ предка или текст целиком) — каждое с
/// причиной. Пока их нет: тепловая карта «Активности» с подписями без
/// масштаба шрифта проверку проходит и так.
const Set<String> _allow = <String>{};

/// Подписи из нескольких слов, которые нельзя резать многоточием: это
/// не текст пользователя, а подсказки и заголовки самого приложения.
const Set<String> _whole = <String>{
  'Новая сессия',
  'История команд',
  'Поиск по задачам…',
  'Поиск по сессиям',
  'Новый проект',
  'Мой Связной',
};

/// Ширина × масштаб: узкий и обычный телефон, обычный, крупный и самый
/// крупный шрифт.
const List<double> _widths = <double>[320, 360];
const List<double> _scales = <double>[1.0, 1.3, 2.0];

void _expectWhole(WidgetTester tester, String label) =>
    expectWholeWords(tester, allow: _allow, whole: _whole, label: label);

/// Проверяет экран и всё, что ниже: прокручивает самый глубокий
/// вертикальный список до конца, проверяя после каждого шага.
Future<void> _checkScrolling(WidgetTester tester, String label) async {
  _expectWhole(tester, label);
  final scrollables = find.byWidgetPredicate(
    (Widget w) =>
        w is Scrollable &&
        (w.axisDirection == AxisDirection.down ||
            w.axisDirection == AxisDirection.up),
  );
  final states = tester
      .stateList<ScrollableState>(scrollables)
      .where(
        (ScrollableState s) =>
            s.position.hasContentDimensions && s.position.maxScrollExtent > 0,
      )
      .toList();
  if (states.isEmpty) return;
  final position = states.last.position;
  var step = 0;
  while (position.pixels < position.maxScrollExtent && step < 40) {
    position.jumpTo(
      (position.pixels + position.viewportDimension * 0.8)
          .clamp(0, position.maxScrollExtent),
    );
    await tester.pump();
    _expectWhole(tester, '$label, шаг $step');
    step++;
  }
}

/// Главный экран: задачи, по желанию «Пароли» ([kit]) и голос ([voice]).
Future<TaskService> _pumpHome(
  WidgetTester tester, {
  PasswordsKit? kit,
  VoiceKit? voice,
  AppSettings settings = const AppSettings(),
}) async {
  final tasks = TaskService(
    repository: InMemoryTaskRepository(),
    clock: _clock,
  );
  final connectors = <Connector>[
    TasksConnector(taskService: tasks, parser: ScenarioParser(clock: _clock)),
    if (kit != null)
      PasswordsConnector(
        vault: kit.facade,
        canCopySecrets: kit.canCopySecrets,
        vaultExisted: () => kit.vaultExisted,
      ),
  ];
  final assistant = AssistantController(
    extensions: ExtensionRegistry(
      connectors: connectors,
      choice: ExtensionChoice(
        enabled: <String>{if (kit != null) PasswordsConnector.id},
      ),
    ),
    clock: _clock,
    knownSecret: kit?.facade.knownSecret,
  );
  final store = InMemorySettingsStore();
  await store.save(
    kit == null
        ? settings
        : settings.copyWith(
            enabledExtensions: <String>{PasswordsConnector.id},
          ),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: _theme(),
      home: HomePage(
        assistant: assistant,
        tasks: tasks,
        clock: _clock,
        settingsStore: store,
        chatStore: InMemoryChatStore(),
        passwords: kit,
        voice: voice,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return tasks;
}

Future<void> _say(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('assistant-input')), text);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

/// Тема текущего теста: тёмная, а в проверках светлой темы — светлая
/// (ADR-027). Шкала текста у тем общая, цвета — свои.
ThemeData Function() _theme = AssistantTheme.dark;

/// Тест [name] на каждой ширине и каждом масштабе в тёмной теме и ещё раз
/// в светлой — на самом тесном варианте (320 px и наибольший масштаб).
void _phones(
  String name,
  Future<void> Function(WidgetTester tester, String label) body, {
  List<double> scales = _scales,
  List<double> heights = const <double>[800],
}) {
  for (final width in _widths) {
    for (final scale in scales) {
      for (final height in heights) {
        final label = '${width.toInt()}x${height.toInt()} ×$scale';
        testWidgets('$name: $label', (WidgetTester tester) async {
          _theme = AssistantTheme.dark;
          setPhone(tester, width: width, height: height, scale: scale);
          await body(tester, '$name $label');
        });
      }
    }
  }
  final scale = scales.reduce(math.max);
  final width = _widths.reduce(math.min);
  final height = heights.first;
  final label = 'светлая ${width.toInt()}x${height.toInt()} ×$scale';
  testWidgets('$name: $label', (WidgetTester tester) async {
    _theme = AssistantTheme.light;
    addTearDown(() => _theme = AssistantTheme.dark);
    setPhone(tester, width: width, height: height, scale: scale);
    await body(tester, '$name $label');
  });
}

/// Открывает [show] кнопкой в пустом экране: диалоги и листы.
Future<void> _pumpLauncher(
  WidgetTester tester,
  void Function(BuildContext context) show,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: _theme(),
      home: Scaffold(
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
  await tester.tap(find.byKey(const Key('launch')));
  await tester.pumpAndSettle();
}

/// Голосовой ввод на подделках: модель не скачана или уже есть.
final class _Voice {
  _Voice._(this.kit, this.recognizer, this.downloader);

  final VoiceKit kit;
  final FakeVoiceRecognizer recognizer;
  final FakeFileDownloader downloader;

  static Future<_Voice> make(
    WidgetTester tester, {
    bool installed = false,
  }) async {
    final temp = Directory.systemTemp.createTempSync('word_wrap_voice');
    addTearDown(() => temp.deleteSync(recursive: true));
    final dir = p.join(temp.path, 'assistant', 'voice');
    final bytes = List<int>.generate(4000, (int i) => i % 251);
    final spec = fakeVoiceSpec(bytes);
    if (installed) installFakeModelSync(dir, spec);
    final recognizer = FakeVoiceRecognizer();
    final downloader = FakeFileDownloader(bytes);
    final kit = fakeVoiceKit(
      recognizer: recognizer,
      downloader: downloader,
      spec: spec,
      dir: dir,
    );
    addTearDown(kit.dispose);
    await tester.runAsync(kit.refresh);
    return _Voice._(kit, recognizer, downloader);
  }
}

void main() {
  setUpAll(loadAppFonts);

  group('проверка и подписи целиком', () {
    Future<void> pumpBox(WidgetTester tester, double width, Widget child) =>
        tester.pumpWidget(
          MaterialApp(
            theme: _theme(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: width, child: child),
              ),
            ),
          ),
        );

    testWidgets('ловит «Напомнит/ь», обрезанное слово и срезанную строку',
        (tester) async {
      setPhone(tester, width: 360, scale: 1.15);
      await pumpBox(tester, 76, const Text('Напомнить'));
      expect(midWordBreaks(tester).single, startsWith('BREAK «Напомн'));
      await pumpBox(
        tester,
        60,
        const Text(
          'Напомнить',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
      expect(midWordBreaks(tester).single, startsWith('CUT'));
      await pumpBox(
        tester,
        60,
        const Text('Напомнить', softWrap: false, overflow: TextOverflow.clip),
      );
      expect(midWordBreaks(tester).single, startsWith('CLIP'));
      // Перенос между словами, у дефиса, в адресе почты — не беда; текст
      // из нескольких слов многоточием резать можно, если он не в [whole].
      await pumpBox(tester, 76, const Text('Купить молоко'));
      expect(midWordBreaks(tester), isEmpty);
      await pumpBox(tester, 80, const Text('сине-зелёный'));
      expect(midWordBreaks(tester), isEmpty);
      await pumpBox(tester, 70, const Text('canary.z5@example.org'));
      expect(midWordBreaks(tester), isEmpty);
      const long = Text(
        'Купить молоко и хлеб',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
      await pumpBox(tester, 76, long);
      expect(midWordBreaks(tester), isEmpty);
      expect(
        midWordBreaks(tester, whole: <String>{'Купить молоко и хлеб'}),
        hasLength(1),
      );
      expect(
        midWordBreaks(tester, allow: <String>{'Напомнить'}),
        isEmpty,
      );
      // Перенос в скрытую строку посреди слова: и без многоточия, и с ним.
      await pumpBox(
        tester,
        50,
        const Text('Напоминания включены', maxLines: 1),
      );
      expect(midWordBreaks(tester), isNotEmpty);
      await pumpBox(
        tester,
        50,
        const Text(
          'Напоминания включены',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
      expect(midWordBreaks(tester), isNotEmpty);
      // «/» между словами — подпись, а не путь: внутри слова рвать нельзя.
      await pumpBox(tester, 40, const Text('Диалог/Документ'));
      expect(midWordBreaks(tester), isNotEmpty);
      await pumpBox(tester, 40, const Text('/home/canary/file'));
      expect(midWordBreaks(tester), isEmpty);
    });

    testWidgets('WholeWordText и fitSingleWord: слово целиком', (
      tester,
    ) async {
      setPhone(tester, width: 320, scale: 2);
      await pumpBox(tester, 120, const WholeWordText('Напомнить'));
      expect(midWordBreaks(tester), isEmpty);
      expect(find.text('Напомнить'), findsOneWidget);
      final shrunk = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byType(WholeWordText),
          matching: find.byType(RichText),
        ),
      );
      expect(shrunk.textScaler.scale(10), lessThan(20));
      // Помещается — масштаб не трогается.
      await pumpBox(tester, 300, const WholeWordText('Напомнить'));
      expect(
        tester
            .renderObject<RenderParagraph>(find.byType(RichText).last)
            .textScaler
            .scale(10),
        20,
      );
      await pumpBox(tester, 60, fitSingleWord('Напомнить'));
      expect(midWordBreaks(tester), isEmpty);
      expect(find.text('Напомнить'), findsOneWidget);
    });

    testWidgets('WholeWordText с «…» не сжимает длинное превью', (
      tester,
    ) async {
      setPhone(tester, width: 320, scale: 1);
      // Две строки и многоточие: обрезается, а не уменьшается до 7–9 px.
      await pumpBox(
        tester,
        200,
        const WholeWordText(
          'сконвертируй видео в mp3 320 и положи рядом с исходным файлом '
          'в той же папке, а потом покажи результат',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.byType(RichText).last,
      );
      expect(paragraph.textScaler.scale(10), 10);
      expect(paragraph.didExceedMaxLines, isTrue);
      expect(midWordBreaks(tester), isEmpty);
    });

    testWidgets('WholeWordText в AlertDialog (своя ширина) — без ошибок', (
      tester,
    ) async {
      setPhone(tester, width: 320, scale: 2);
      await _pumpLauncher(
        tester,
        (context) => showDialog<void>(
          context: context,
          builder: (BuildContext context) => const AlertDialog(
            title: WholeWordText('Доступ к микрофону'),
            content: Text('Текст'),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Доступ к микрофону'), findsOneWidget);
      _expectWhole(tester, 'диалог');
    });
  });

  group('главная', () {
    _phones(
      'пустая сессия',
      (WidgetTester tester, String label) async {
        await _pumpHome(tester);
        _expectWhole(tester, label);
      },
      // 1.15 — как на снимке с телефона; 760 — тесная высота (QuickDock).
      scales: const <double>[1.0, 1.15, 1.3, 2.0],
      heights: const <double>[760, 800],
    );

    _phones('сессия с ответами и меню', (tester, label) async {
      await _pumpHome(tester);
      await _say(tester, 'Добавь задачу купить молоко завтра в 10');
      await _say(tester, 'Покажи задачи');
      await _checkScrolling(tester, '$label: сессия');
      // «⋯ → История команд» — шторкой (ADR-027).
      // На узком экране с задачей в фокусе «⋯» нет — сначала «назад».
      if (find.byKey(const Key('task-back')).evaluate().isNotEmpty) {
        await tester.tap(find.byKey(const Key('task-back')));
        await tester.pumpAndSettle();
      }
      await openCommandHistory(tester);
      await _checkScrolling(tester, '$label: история команд');
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await openDrawerIfNeeded(tester);
      await _checkScrolling(tester, '$label: меню');
    });

    _phones('документ и меню сессии', (tester, label) async {
      await _pumpHome(tester);
      await _say(tester, 'Добавь задачу купить молоко завтра в 10');
      // Заметки и пункты из чата в документе (ADR-033).
      await _say(
        tester,
        'запиши, что их 22шт в ок, 1шт в уценке под артикулом 67782',
      );
      await _say(tester, 'добавь пункты молоко, хлеб и сыр');
      await tester.tap(find.byKey(const Key('mode-document')));
      await tester.pumpAndSettle();
      await _checkScrolling(tester, '$label: документ');
      await tester.tap(find.byKey(const Key('mode-dialogue')));
      await tester.pumpAndSettle();
      // Меню сессии — долгим нажатием на неё в меню.
      await openDrawerIfNeeded(tester);
      final row = sessionEntries().first;
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.longPress(row);
      await tester.pumpAndSettle();
      _expectWhole(tester, '$label: меню сессии');
      await tester.tap(find.byKey(const Key('session-menu-rename')));
      await tester.pumpAndSettle();
      _expectWhole(tester, '$label: переименование');
      await tester.tap(find.byKey(const Key('rename-cancel')));
      await tester.pumpAndSettle();
    });

    _phones('набор в поле и лист «+»', (tester, label) async {
      await _pumpHome(tester);
      // Набранная фраза в капсуле — целыми словами и при шрифте 200 %.
      await tester.enterText(
        find.byKey(const Key('assistant-input')),
        'позвонить маме завтра вечером',
      );
      await tester.pumpAndSettle();
      _expectWhole(tester, '$label: набор');
      // При крупном шрифте капсула — отдельной строкой во всю ширину (было
      // ~110 px между двумя кругами).
      if (tester.platformDispatcher.textScaleFactor > 1.3) {
        final screen =
            tester.view.physicalSize.width / tester.view.devicePixelRatio;
        expect(
          tester.getSize(find.byKey(const Key('assistant-input'))).width,
          greaterThan(screen * 0.75),
          reason: label,
        );
      }
      await tester.tap(find.byKey(const Key('templates-button')));
      await tester.pumpAndSettle();
      await _checkScrolling(tester, '$label: лист «+»');
    });

    _phones('разделы меню', (tester, label) async {
      await _pumpHome(tester);
      await _say(tester, 'Добавь задачу купить молоко завтра в 10');
      for (final id in <String>['tasks', 'projects', 'planning']) {
        await tapInDrawer(tester, Key('nav-$id'));
        await _checkScrolling(tester, '$label: $id');
      }
    });

    _phones('Мой Связной', (tester, label) async {
      await _pumpHome(tester);
      await _say(tester, 'Добавь задачу купить молоко завтра в 10');
      for (final tab in <String>['summary', 'assistants', 'settings']) {
        await openMyRelay(tester, tab);
        await _checkScrolling(tester, '$label: $tab');
      }
      // «Настройки» → «Очистить историю сессий?» и «Данные».
      final clear = find.byKey(const ValueKey<String>('clear-chat'));
      await tester.ensureVisible(clear);
      await tester.pumpAndSettle();
      await tester.tap(clear);
      await tester.pumpAndSettle();
      _expectWhole(tester, '$label: очистить историю');
      await tester.tap(find.byKey(const ValueKey<String>('clear-chat-cancel')));
      await tester.pumpAndSettle();
      final storage = find.byKey(const ValueKey<String>('settings-storage'));
      await tester.ensureVisible(storage);
      await tester.pumpAndSettle();
      await tester.tap(storage);
      await tester.pumpAndSettle();
      await _checkScrolling(tester, '$label: данные');
    });

    _phones('оформление', (tester, label) async {
      await _pumpHome(tester);
      await openMyRelay(tester, 'settings');
      final row = find.byKey(const ValueKey<String>('setting-appearance'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      _expectWhole(tester, '$label: строка');
      await tester.tap(row);
      await tester.pumpAndSettle();
      await _checkScrolling(tester, '$label: оформление');
    });
  });

  group('виджеты рабочего стола', () {
    // «Настройки → Виджеты» (ADR-034): все состояния группы одна под
    // другой — обычное, виджет уже стоит, вход по отпечатку, лаунчер не
    // добавляет по просьбе.
    _phones('группа «Виджеты»', (tester, label) async {
      Widget section(
        FakeHomeScreen platform, {
        AppSettings settings = const AppSettings(),
        bool voice = true,
      }) =>
          HomeScreenSection(
            platform: platform,
            settings: settings,
            onChanged: (_) {},
            voice: voice,
          );
      await tester.pumpWidget(
        MaterialApp(
          theme: _theme(),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  section(
                    FakeHomeScreen(
                      installed: <HomeScreenKind, int>{
                        HomeScreenKind.today: 1,
                      },
                    ),
                  ),
                  section(
                    FakeHomeScreen(),
                    settings: const AppSettings(appLock: true),
                    voice: false,
                  ),
                  section(FakeHomeScreen(canPin: false)),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Виджеты'), findsNWidgets(3));
      expect(find.byIcon(Icons.check), findsOneWidget);
      await _checkScrolling(tester, label);
    });
  });

  group('«Пароли»', () {
    late SodiumVaultCrypto crypto;

    setUpAll(() async {
      crypto = await testCrypto();
    });

    /// Хранилище: [created] — заведено, [unlocked] — открыто, с одной
    /// записью-канарейкой.
    Future<(PasswordsKit, Vault, String?)> makeKit({
      bool created = true,
      bool unlocked = true,
      FakeDeviceKey? device,
    }) async {
      final vault = testVault(InMemoryVaultStore(), crypto, deviceKey: device);
      String? clipboard;
      final kit = PasswordsKit(
        vault: vault,
        platform: PasswordsPlatform.android,
        kdfForTesting: fastKdf,
        clipboard: ClipboardGuard(
          platform: PasswordsPlatform.android,
          cipher: crypto,
          write: (String text) async => clipboard = text,
          read: () async => clipboard,
        ),
      );
      await vault.load();
      String? id;
      if (created && device != null) {
        await kit.createProtected();
        id = await vault.addEntry(
          service: 'Почта',
          password: secret(Canary.password),
        );
        if (!unlocked) vault.lock();
      } else if (created) {
        await vault.create(secret(Canary.master), params: fastKdf);
        id = await vault.addEntry(
          service: 'Почта',
          login: Canary.login,
          hint: Canary.hint,
          password: secret(Canary.password),
          note: secret(Canary.note),
        );
        if (!unlocked) vault.lock();
      }
      return (kit, vault, id);
    }

    Future<void> finish(
      WidgetTester tester,
      PasswordsKit kit,
      Vault vault,
    ) async {
      vault.lock();
      await tester.pumpWidget(const SizedBox.shrink());
      kit.dispose();
    }

    Widget app(Widget home) => MaterialApp(theme: _theme(), home: home);

    _phones('пустая сессия с «Паролем»', (tester, label) async {
      final (kit, vault, _) = await makeKit();
      await _pumpHome(tester, kit: kit);
      expect(find.byKey(const Key('quick-Пароль')), findsOneWidget);
      _expectWhole(tester, label);
      await finish(tester, kit, vault);
    });

    _phones('сейф: создание', (tester, label) async {
      final (kit, vault, _) = await makeKit(created: false);
      await tester.pumpWidget(app(PasswordsScreen(kit: kit)));
      await tester.pumpAndSettle();
      await _checkScrolling(tester, label);
      await finish(tester, kit, vault);
    });

    _phones('сейф: заперт', (tester, label) async {
      final (kit, vault, _) = await makeKit(unlocked: false);
      await tester.pumpWidget(app(PasswordsScreen(kit: kit)));
      await tester.pumpAndSettle();
      await _checkScrolling(tester, label);
      await finish(tester, kit, vault);
    });

    _phones('сейф: список и запись', (tester, label) async {
      final (kit, vault, id) = await makeKit();
      await tester.pumpWidget(app(PasswordsScreen(kit: kit)));
      await tester.pumpAndSettle();
      await _checkScrolling(tester, '$label: список');
      await tester.pumpWidget(app(EntryScreen(kit: kit, id: id!)));
      await tester.pumpAndSettle();
      await _checkScrolling(tester, '$label: запись');
      await tester.pumpWidget(app(EntryEditorScreen(kit: kit, id: id)));
      await tester.pumpAndSettle();
      await _checkScrolling(tester, '$label: правка');
      await finish(tester, kit, vault);
    });

    _phones('сейф с защитой устройством: создание и код', (
      tester,
      label,
    ) async {
      final (kit, vault, _) = await makeKit(
        created: false,
        device: FakeDeviceKey(),
      );
      await tester.pumpWidget(app(PasswordsScreen(kit: kit)));
      await tester.pumpAndSettle();
      await _checkScrolling(tester, '$label: создание');
      await tester.tap(find.byKey(const Key('create-submit')));
      await tester.pumpAndSettle();
      await _checkScrolling(tester, '$label: код');
      await tester.tap(find.byKey(const Key('recovery-code-saved')));
      await tester.pumpAndSettle();
      await _checkScrolling(tester, '$label: проверка кода');
      await finish(tester, kit, vault);
    });

    _phones('сейф с защитой устройством: ПИН-код, код, настройки', (
      tester,
      label,
    ) async {
      final device = FakeDeviceKey();
      final (kit, vault, _) = await makeKit(device: device);
      await tester.pumpWidget(app(PasswordsSettingsScreen(kit: kit)));
      await tester.pumpAndSettle();
      await _checkScrolling(tester, '$label: вход в сейф');
      await tester.pumpWidget(app(BackupExportScreen(kit: kit)));
      await tester.pumpAndSettle();
      await _checkScrolling(tester, '$label: выгрузка');
      await vault.enablePin(secret(canaryPin()));
      vault.lock();
      await tester.pumpWidget(app(PasswordsScreen(kit: kit)));
      await tester.pumpAndSettle();
      await _checkScrolling(tester, '$label: замок с ПИН-кодом');
      await tester.tap(find.byKey(const Key('lock-recover')));
      await tester.pumpAndSettle();
      await _checkScrolling(tester, '$label: восстановить по коду');
      await finish(tester, kit, vault);
    });

    _phones('сейф: настройки, генератор, копии, проверка', (
      tester,
      label,
    ) async {
      final (kit, vault, _) = await makeKit();
      for (final (name, screen) in <(String, Widget)>[
        ('настройки', PasswordsSettingsScreen(kit: kit)),
        ('генератор', GeneratorScreen(kit: kit)),
        ('выгрузка', BackupExportScreen(kit: kit)),
        ('восстановление', BackupRestoreScreen(kit: kit)),
        ('импорт', CsvImportScreen(kit: kit)),
        ('проверка', CheckScreen(kit: kit)),
        ('тренировка', TrainingScreen(kit: kit)),
      ]) {
        await tester.pumpWidget(app(screen));
        await tester.pumpAndSettle();
        await _checkScrolling(tester, '$label: $name');
      }
      await finish(tester, kit, vault);
    });
  });

  group('голосовой ввод', () {
    _phones('предложение и загрузка', (tester, label) async {
      final voice = await _Voice.make(tester);
      final gate = Completer<void>();
      voice.downloader
        ..gate = gate
        ..gateFrom = 1;
      await _pumpHome(tester, voice: voice.kit);
      await tester.tap(find.byKey(const Key('assistant-voice')));
      await tester.pumpAndSettle();
      _expectWhole(tester, '$label: предложение');
      await tester.tap(find.byKey(const Key('voice-offer-download')));
      await tester.pump();
      await pumpUntilVoice(tester, () => voice.kit.received > 0);
      await tester.pump();
      expect(find.byKey(const Key('voice-install-sheet')), findsOneWidget);
      _expectWhole(tester, '$label: загрузка');
      await tester.tap(find.byKey(const Key('voice-cancel')));
      await tester.pump();
      await pumpUntilVoice(
        tester,
        () => voice.kit.phase == VoiceKitPhase.notInstalled,
      );
      await tester.pumpAndSettle();
      gate.complete();
    });

    _phones('объяснение, слушаю и настройки', (tester, label) async {
      final voice = await _Voice.make(tester, installed: true);
      await _pumpHome(
        tester,
        voice: voice.kit,
        settings: const AppSettings(voiceInput: true),
      );
      await tester.tap(find.byKey(const Key('assistant-voice')));
      await tester.pumpAndSettle();
      _expectWhole(tester, '$label: объяснение');
      await tester.tap(find.byKey(const Key('voice-rationale-continue')));
      await tester.pumpAndSettle();
      _expectWhole(tester, '$label: микрофон доступен');
      // Слушаем: нажатие начинает, повторное — заканчивает (ADR-023).
      await tester.tap(find.byKey(const Key('assistant-voice')));
      await tester.pump();
      await tester.pump();
      expect(voice.recognizer.isListening, isTrue);
      voice.recognizer.emit(const VoicePartial('покажи задачи на завтра'));
      await tester.pump();
      _expectWhole(tester, '$label: слушаю');
      await tester.tap(find.byKey(const Key('assistant-voice')));
      await tester.pumpAndSettle();
      await openMyRelay(tester, 'settings');
      await _checkScrolling(tester, '$label: настройки');
    });
  });

  group('карточки', () {
    final now = DateTime(2026, 11, 10, 14, 30);
    ActionCard action(ActionCardState state) => ActionCard(
          rid: 'abcdefghij012345',
          connectorId: 'warehouse',
          kind: ActionKind.move,
          login: 'ivanov',
          name: 'Иван Петров',
          deadline: now.add(const Duration(minutes: 5)),
          lines: const <ActionCardLine>[
            ActionCardLine('what', 'Стул венский белый'),
            ActionCardLine('qty', '3 шт.'),
            ActionCardLine('from', '215-1-1-1 — было 5, станет 2'),
            ActionCardLine(
              'to',
              '215-3-2-1 — было 0, станет 3',
              note: 'to_empty',
            ),
            ActionCardLine('who', 'Иван Петров (ivanov)'),
          ],
          warn: const <String>['to_empty'],
          commit: const <String, Object?>{'qty': 3},
          stamp: 'a' * 64,
          exp: 1,
          state: state,
        );

    Widget phoneCard(Widget card) => MaterialApp(
          theme: _theme(),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: card,
            ),
          ),
        );

    _phones('карточка действия', (tester, label) async {
      for (final state in ActionCardState.values) {
        await tester.pumpWidget(
          phoneCard(
            ActionCardView(
              card: action(state),
              busy: false,
              now: () => now,
              onConfirm: () {},
              onCancel: () {},
              onSettle: () {},
            ),
          ),
        );
        await tester.pump();
        await _checkScrolling(tester, '$label: ${state.name}');
      }
    });

    _phones('карточка склада', (tester, label) async {
      await tester.pumpWidget(
        phoneCard(
          WarehouseCardView(
            onOpen: () {},
            card: const WarehouseCard(
              connector: 'warehouse',
              command: 'where',
              title: 'Где лежит товар',
              say: '«стул венский»: 2 позиции, всего 1 214 шт.',
              more: true,
              rows: <WarehouseRow>[
                WarehouseRow(
                  title: '64115',
                  text: 'Стул венский белый с подлокотниками',
                  badge: '1 200 шт.',
                  linkKind: 'sku',
                  linkId: '64115',
                  rows: <WarehouseRow>[
                    WarehouseRow(
                      title: '215-1-1-1',
                      text: 'годен к продаже',
                      badge: '1 150 шт.',
                      linkKind: 'cell',
                      linkId: '215-1-1-1',
                    ),
                    WarehouseRow(
                      title: '303-зона приёмки',
                      badge: '50 шт.',
                      linkKind: 'cell',
                    ),
                  ],
                ),
                WarehouseRow(
                  title: 'без артикула',
                  text: 'Стул венский (без бирки)',
                  note: 'ПРИХ-00318 · ООО «Ромашка и партнёры»',
                  badge: '14 шт.',
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await _checkScrolling(tester, label);
    });

    _phones('карточка подключения склада', (tester, label) async {
      final secrets = InMemorySecretStore(<String, String>{
        'warehouse.token': 'fake-token-not-real',
        'warehouse.sid': 'fake-sid-not-real',
      });
      final service = ConnectionService(
        connector: ManifestConnector(
          slot: ConnectionSlots.warehouse,
          transport: const _NoNetwork(),
          secrets: secrets,
          record: ConnectionRecord(
            appId: 'halowarekeep',
            baseUri: Uri.parse('https://sklad-vozvratov.example/'),
            login: 'ivanov-petr',
            level: ConnectionLevel.staff,
            scope: 'assist',
            me: const ConnectionMe(
              name: 'Пётр Иванов-Сидоровский',
              role: 'Старший кладовщик',
              perms: <String>['moves', 'post'],
              can: <String>[
                'Отмечать проведение прихода',
                'Переносить товар между ячейками',
              ],
            ),
          ),
        ),
        transport: const _NoNetwork(),
        secrets: secrets,
        store: InMemoryConnectionStore(),
      )..signal = 'Сегодня 3 прихода · не проведено 2 · проверено в 14:05';
      await tester.pumpWidget(
        phoneCard(
          WarehouseConnectionCard(
            service: service,
            onEnabledChanged: (_) {},
            signal: service.signal,
          ),
        ),
      );
      await tester.pump();
      await _checkScrolling(tester, label);
    });

    _phones('карточки расширений', (tester, label) async {
      final progress = ValueNotifier<JobTick?>(null);
      addTearDown(progress.dispose);
      final file = <JobFile>[
        const JobFile(
          path: '/tmp/отчёт за ноябрь.pdf',
          name: 'отчёт за ноябрь.pdf',
        ),
      ];
      final cards = <(String, ExtensionCard)>[
        for (final state in CardState.values)
          (
            'архиватор ${state.name}',
            ExtensionCard(
              id: 'j1_0',
              extensionId: ExtensionForms.archiver,
              updatedAt: DateTime(2026),
              state: state,
              values: <String, Object?>{
                'action': ExtensionForms.zip,
                'level': ExtensionForms.levelStrong,
                'files': file,
              },
            ),
          ),
        (
          'конвертер',
          ExtensionCard(
            id: 'j2_0',
            extensionId: ExtensionForms.converter,
            updatedAt: DateTime(2026),
            values: <String, Object?>{'file': file},
          ),
        ),
        (
          'конвертер видео в mp3 320',
          ExtensionCard(
            id: 'j4_0',
            extensionId: ExtensionForms.converter,
            updatedAt: DateTime(2026),
            values: <String, Object?>{
              'file': <JobFile>[
                const JobFile(
                  path: '/tmp/отпуск на море.mp4',
                  name: 'отпуск на море.mp4',
                ),
              ],
              'target': 'mp3',
              'audio_kbps': '320',
            },
          ),
        ),
        (
          'конвертер видео в mp4 720p',
          ExtensionCard(
            id: 'j5_0',
            extensionId: ExtensionForms.converter,
            updatedAt: DateTime(2026),
            values: <String, Object?>{
              'file': <JobFile>[
                const JobFile(path: '/tmp/клип.mkv', name: 'клип.mkv'),
              ],
              'target': 'mp4',
              'video_res': '720',
              'video_quality': 'eco',
            },
          ),
        ),
        (
          'конвертер фото в jpeg',
          ExtensionCard(
            id: 'j6_0',
            extensionId: ExtensionForms.converter,
            updatedAt: DateTime(2026),
            values: <String, Object?>{
              'file': <JobFile>[
                const JobFile(path: '/tmp/кот.jpg', name: 'кот.jpg'),
              ],
              'target': 'jpeg',
              'jpeg_quality': '60',
              'image_size': '1920',
            },
          ),
        ),
        (
          'загрузчик',
          ExtensionCard(
            id: 'j3_0',
            extensionId: ExtensionForms.ytdl,
            updatedAt: DateTime(2026),
            values: const <String, Object?>{'url': 'https://example.com/v/1'},
          ),
        ),
      ];
      for (final (name, card) in cards) {
        await tester.pumpWidget(
          phoneCard(
            ExtensionCardView(
              card: card,
              platform: JobPlatform.android,
              progress: progress,
              canReveal: false,
              sessionFiles: const <JobFile>[],
              enabled: true,
              temporary: false,
              tools: const <String>{'ytdlp', 'ffmpeg'},
              onAddFiles: () {},
              onAddFolder: () {},
              onAddSessionFile: (JobFile f) {},
              onRemoveFile: (JobFile f) {},
              onChoice: (String c, String v) {},
              onText: (String c, String v) {},
              onRun: () {},
              onCancel: () {},
              onOpen: (String path) {},
              onReveal: (String path) {},
              onRetry: () {},
            ),
          ),
        );
        await tester.pump();
        await _checkScrolling(tester, '$label: $name');
      }
    });
  });

  group('выпадающие списки карточек', () {
    // Открытый список «Во что» и «Качество звука»: длинные подписи и
    // причины недоступности переносятся по словам.
    for (final (code, target) in <(String, String)>[
      ('target', 'mp3'),
      ('audio_kbps', 'mp3'),
      ('video_res', 'mp4'),
    ]) {
      _phones('открытый список $code', (tester, label) async {
        final progress = ValueNotifier<JobTick?>(null);
        addTearDown(progress.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: _theme(),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ExtensionCardView(
                  card: ExtensionCard(
                    id: 'j7_0',
                    extensionId: ExtensionForms.converter,
                    updatedAt: DateTime(2026),
                    values: <String, Object?>{
                      'file': <JobFile>[
                        const JobFile(path: '/tmp/клип.mp4', name: 'клип.mp4'),
                      ],
                      'target': target,
                    },
                  ),
                  // «Во что» — телефон без системных кодировщиков: у
                  // вариантов звука и видео причина второй строкой.
                  // Качество — телефон с кодировщиками без 1080p: у 1080p
                  // причина.
                  platform: JobPlatform.android,
                  progress: progress,
                  tools: code == 'target'
                      ? const <String>{}
                      : const NativeMediaCaps(
                          targets: <String>{'mp3', 'm4a', 'wav', 'mp4'},
                          video1080: false,
                        ).toTools(),
                  onChoice: (String c, String v) {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.tap(
          find.descendant(
            of: find.byKey(ValueKey<String>('ext-card-select-$code')),
            matching: find.byType(DropdownButton<String>),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        _expectWhole(tester, '$label: меню');
      });
    }
  });

  group('выпадающие списки: выбранное видно целиком и шрифтом приложения', () {
    // Регрессия: у плотного DropdownButtonFormField кнопка высотой в одну
    // строку — подпись в две строки («Экономное — меньше файл» на 320 px
    // и шрифте 200 %) срезалась снизу, а проверка слов этого не видит.
    // И style без fontFamily заменял шрифт темы: шрифт приложения терялся.
    for (final (name, values, platform) in <(
      String,
      Map<String, Object?>,
      JobPlatform,
    )>[
      (
        'видео в mp4 720p эконом',
        <String, Object?>{
          'file': <JobFile>[
            const JobFile(path: '/tmp/клип.mp4', name: 'клип.mp4'),
          ],
          'target': 'mp4',
          'video_res': '720',
          'video_quality': 'eco',
        },
        JobPlatform.linux,
      ),
      (
        'архиватор сильное сжатие',
        <String, Object?>{
          'action': ExtensionForms.zip,
          'level': ExtensionForms.levelStrong,
          'files': <JobFile>[
            const JobFile(path: '/tmp/отчёт.txt', name: 'отчёт.txt'),
          ],
        },
        JobPlatform.linux,
      ),
    ]) {
      _phones(name, (tester, label) async {
        final progress = ValueNotifier<JobTick?>(null);
        addTearDown(progress.dispose);
        final extension = values.containsKey('action')
            ? ExtensionForms.archiver
            : ExtensionForms.converter;
        await tester.pumpWidget(
          MaterialApp(
            theme: _theme(),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ExtensionCardView(
                  card: ExtensionCard(
                    id: 'j8_0',
                    extensionId: extension,
                    updatedAt: DateTime(2026),
                    values: values,
                  ),
                  platform: platform,
                  progress: progress,
                  tools: const <String>{'ffmpeg'},
                  onChoice: (String c, String v) {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final selects = find.byWidgetPredicate(
          (Widget w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('ext-card-select-'),
        );
        expect(selects, findsWidgets, reason: label);
        for (final element in selects.evaluate()) {
          final field = find.descendant(
            of: find.byWidget(element.widget),
            matching: find.byType(InputDecorator),
          );
          final box = tester.getRect(field.first);
          final texts = find.descendant(
            of: field.first,
            matching: find.byType(RichText),
          );
          expect(texts, findsWidgets, reason: label);
          for (final text in texts.evaluate()) {
            final paragraph = text.renderObject! as RenderParagraph;
            if (!paragraph.hasSize || paragraph.size.isEmpty) continue;
            final rect = paragraph.localToGlobal(Offset.zero) & paragraph.size;
            final shown = paragraph.text.toPlainText();
            if (shown.isEmpty) continue;
            expect(
              rect.top >= box.top - 0.5 && rect.bottom <= box.bottom + 0.5,
              isTrue,
              reason: '$label: «$shown» ($rect) вне поля ($box)',
            );
            // Текст выше своего места: родитель сжал параграф, и строки
            // ниже срезаны.
            expect(
              paragraph.textSize.height <= paragraph.size.height + 0.5,
              isTrue,
              reason: '$label: «$shown» выше места '
                  '(${paragraph.textSize.height} > ${paragraph.size.height})',
            );
            final family = paragraph.text.style?.fontFamily;
            // Стрелка списка — значок, у него свой шрифт.
            if (family == 'MaterialIcons') continue;
            expect(family, AppFonts.text, reason: '$label: «$shown»');
          }
        }
      });
    }
  });

  group('«Файлы сессии»', () {
    // Правая панель (ADR-028) шириной выдвижной: экран − 30. Имена файлов
    // — данные (до трёх строк с «…»), подписи и пустое состояние — целиком;
    // размер («70 Б») не расходится по строкам, строка не кончается «·».
    final now = DateTime(2026, 11, 4, 15);
    SessionFile attachment(String id, String name, int size, DateTime at) {
      final a = ChatAttachment(
        id: id,
        kind: AttachmentKind.of(name),
        name: name,
        path: 'files/session-1/$id.bin',
        size: size,
        addedAt: at,
      );
      return SessionFile(
        id: 'att:$id',
        source: SessionFileSource.attachment,
        name: name,
        kind: a.kind,
        size: size,
        at: at,
        messageId: 'm1',
        attachment: a,
      );
    }

    SessionFile output(String card, String name, String ext, DateTime at) =>
        SessionFile(
          id: 'out:$card:0',
          source: SessionFileSource.output,
          name: name,
          kind: AttachmentKind.of(name),
          archive: SessionFile.isArchiveName(name),
          at: at,
          messageId: 'm2',
          extensionId: ext,
          absolute: '/out/$card/$name',
        );

    for (final empty in <bool>[true, false]) {
      _phones(empty ? 'файлы сессии: пусто' : 'файлы сессии', (
        tester,
        label,
      ) async {
        final width = tester.view.physicalSize.width - 30;
        await tester.pumpWidget(
          MaterialApp(
            theme: _theme(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: width,
                  child: SessionFilesPanel(
                    outputs: empty
                        ? const <SessionFile>[]
                        : <SessionFile>[
                            output(
                              'j1',
                              'Запись встречи с поставщиком.mp3',
                              ExtensionForms.converter,
                              DateTime(2026, 11, 4, 14, 5),
                            ),
                            output(
                              'j2',
                              'Фотографии дачи.zip',
                              ExtensionForms.archiver,
                              DateTime(2026, 11, 3, 9),
                            ),
                            output(
                              'j3',
                              'Видео с презентации.mp4',
                              ExtensionForms.ytdl,
                              DateTime(2026, 10, 28, 9),
                            ),
                          ],
                    attachments: empty
                        ? const <SessionFile>[]
                        : <SessionFile>[
                            attachment(
                              'm1-0',
                              'Отчёт за ноябрь для бухгалтерии.pdf',
                              2516582,
                              now,
                            ),
                            attachment(
                              'm0-0',
                              'IMG_20261103_181512.jpg',
                              849920,
                              DateTime(2026, 11, 3, 18),
                            ),
                          ],
                    store: InMemoryAttachmentStore(),
                    opener: FileOpener(platform: JobPlatform.android),
                    now: now,
                    stat: (String path) => path.endsWith('.zip')
                        ? (exists: false, folder: false, size: null)
                        : (exists: true, folder: false, size: 2516582),
                    onShowInMessage: (String id) {},
                    onClose: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull, reason: label);
        await _checkScrolling(tester, label);
        if (!empty) _expectSizesWhole(tester, label);
      });
    }
  });

  group('строка статистики «Мой Связной»', () {
    // Пары фраз через «·»: пара не входит — фразы на своих строках, и
    // ни одна строка не кончается и не начинается голой «·».
    _phones('статистика', (tester, label) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: _theme(),
          home: const Scaffold(
            body: Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: RelayStatsLine(
                key: Key('stats'),
                stats: 'Вместе 299 дней · сессий 180 · задач закрыто 50 · '
                    'серия 12 дней',
                pairs: true,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: label);
      var checked = 0;
      for (final paragraph in tester.renderObjectList<RenderParagraph>(
        find.descendant(
          of: find.byKey(const Key('stats')),
          matching: find.byType(RichText),
        ),
      )) {
        checked++;
        final text = paragraph.text.toPlainText();
        final painter = TextPainter(
          text: paragraph.text,
          textDirection: TextDirection.ltr,
          textScaler: paragraph.textScaler,
        )..layout(maxWidth: paragraph.size.width);
        for (final line in painter.computeLineMetrics()) {
          final at = painter.getPositionForOffset(
            Offset(1, line.baseline - line.ascent / 2),
          );
          final range = painter.getLineBoundary(at);
          final shown = text.substring(range.start, range.end).trim();
          expect(shown.endsWith('·'), isFalse, reason: '$label: «$shown»');
          expect(shown.startsWith('·'), isFalse, reason: '$label: «$shown»');
        }
        painter.dispose();
      }
      expect(checked, greaterThan(0), reason: label);
      _expectWhole(tester, label);
    });
  });

  group('диалоги проектов', () {
    final projects = <ChatProject>[
      ChatProject(
        id: 'p1',
        name: 'Переезд склада',
        createdAt: DateTime(2026, 11),
        updatedAt: DateTime(2026, 11),
      ),
      ChatProject(
        id: 'p2',
        name: 'Отпуск',
        createdAt: DateTime(2026, 11, 2),
        updatedAt: DateTime(2026, 11, 2),
      ),
    ];

    _phones('новый проект', (tester, label) async {
      await _pumpLauncher(tester, (context) => showProjectDialog(context));
      _expectWhole(tester, label);
    });

    _phones('перенос в проект', (tester, label) async {
      await _pumpLauncher(
        tester,
        (context) => showMoveToProjectSheet(
          context,
          projects: projects,
          currentProjectId: 'p1',
        ),
      );
      await _checkScrolling(tester, label);
    });

    _phones('удаление проекта', (tester, label) async {
      await _pumpLauncher(
        tester,
        (context) => showDeleteProjectDialog(
          context,
          name: 'Переезд склада',
          sessions: 3,
        ),
      );
      _expectWhole(tester, label);
    });

    _phones('метка проекта', (tester, label) async {
      await _pumpLauncher(
        tester,
        (context) => showProjectTagDialog(
          context,
          suggestions: const <String>['Работа', 'Личное', 'Покупки'],
        ),
      );
      _expectWhole(tester, label);
    });
  });
}

/// Подписи «Файлов сессии»: число и единица размера на одной строке, ни
/// одна строка не кончается и не начинается голой «·» — переносы только
/// между частями, без точки (metaLines).
void _expectSizesWhole(WidgetTester tester, String label) {
  final unit = RegExp(r'^(Б|КБ|МБ)(\s|$)');
  var checked = 0;
  for (final paragraph in tester.renderObjectList<RenderParagraph>(
    find.descendant(
      of: find.byKey(const Key('session-files-list')),
      matching: find.byType(RichText),
    ),
  )) {
    final text = paragraph.text.toPlainText();
    if (!text.contains('·') && !text.contains('\n')) continue;
    checked++;
    final painter = TextPainter(
      text: paragraph.text,
      textDirection: TextDirection.ltr,
      textScaler: paragraph.textScaler,
      maxLines: paragraph.maxLines,
    )..layout(maxWidth: paragraph.size.width);
    final lines = <String>[];
    for (final line in painter.computeLineMetrics()) {
      final at = painter.getPositionForOffset(
        Offset(1, line.baseline - line.ascent / 2),
      );
      final range = painter.getLineBoundary(at);
      lines.add(text.substring(range.start, range.end));
    }
    painter.dispose();
    for (var i = 0; i < lines.length; i++) {
      expect(
        lines[i].trimRight().endsWith('·'),
        isFalse,
        reason: '$label: строка кончается «·» в «$text»: $lines',
      );
      expect(
        lines[i].trimLeft().startsWith('·'),
        isFalse,
        reason: '$label: строка начинается с «·» в «$text»: $lines',
      );
      expect(
        unit.hasMatch(lines[i].trimLeft()),
        isFalse,
        reason: '$label: единица размера оторвана от числа в «$text»',
      );
    }
  }
  expect(checked, greaterThan(0), reason: label);
}

/// Сеть в проверке подписей не нужна.
final class _NoNetwork implements HttpTransport {
  const _NoNetwork();

  @override
  Future<HttpResponseData> send(HttpRequestData request) =>
      throw StateError('сеть не нужна');
}
