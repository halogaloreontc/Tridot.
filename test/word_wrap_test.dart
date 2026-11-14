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

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
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
import 'package:local_assistant/app/shell/project_dialogs.dart';
import 'package:local_assistant/app/voice/voice_kit.dart';
import 'package:local_assistant/app/widgets/action_card_view.dart';
import 'package:local_assistant/app/widgets/extension_card_view.dart';
import 'package:local_assistant/app/widgets/whole_word_text.dart';
import 'package:local_assistant/core/chats/chat_projects.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';
import 'package:local_assistant/core/models/action_card.dart';
import 'package:local_assistant/core/passwords/vault.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:local_assistant/core/skills/passwords/passwords_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';
import 'package:local_assistant/core/voice/voice_recognizer.dart';
import 'package:path/path.dart' as p;

import 'passwords/vault_test_support.dart';
import 'support/app_fonts.dart';
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
  'Спросить, найти или поручить…',
  'Поиск по задачам…',
  'Поиск по сессиям',
  'Новый проект',
  'Мой Tridot',
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
      theme: AssistantTheme.dark(),
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

/// Тест [name] на каждой ширине и каждом масштабе.
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
          setPhone(tester, width: width, height: height, scale: scale);
          await body(tester, '$name $label');
        });
      }
    }
  }
}

/// Открывает [show] кнопкой в пустом экране: диалоги и листы.
Future<void> _pumpLauncher(
  WidgetTester tester,
  void Function(BuildContext context) show,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AssistantTheme.dark(),
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
            theme: AssistantTheme.dark(),
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
      expect(midWordBreaks(tester).single, startsWith('BREAK «Напомни'));
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
      await pumpBox(tester, 70, const Text('сине-зелёный'));
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
      await openDrawerIfNeeded(tester);
      await _checkScrolling(tester, '$label: меню');
    });

    _phones('документ и меню сессии', (tester, label) async {
      await _pumpHome(tester);
      await _say(tester, 'Добавь задачу купить молоко завтра в 10');
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

    _phones('разделы меню', (tester, label) async {
      await _pumpHome(tester);
      await _say(tester, 'Добавь задачу купить молоко завтра в 10');
      for (final id in <String>['tasks', 'projects', 'planning']) {
        await tapInDrawer(tester, Key('nav-$id'));
        await _checkScrolling(tester, '$label: $id');
      }
    });

    _phones('Мой Tridot', (tester, label) async {
      await _pumpHome(tester);
      await _say(tester, 'Добавь задачу купить молоко завтра в 10');
      for (final tab in <String>[
        'summary',
        'activity',
        'assistants',
        'settings',
      ]) {
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

    Widget app(Widget home) =>
        MaterialApp(theme: AssistantTheme.dark(), home: home);

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
          theme: AssistantTheme.dark(),
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
