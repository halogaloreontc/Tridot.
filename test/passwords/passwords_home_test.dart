// Навык «Пароли» в главном экране (ADR-014, этап 2): карточка под
// ответом, кнопки быстрых действий, пункты «+», плитка в «Расширениях»,
// выключение навыка. Пароли — только канарейки, снимков нет (D24).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/home_page.dart';
import 'package:local_assistant/app/passwords/clipboard_guard.dart';
import 'package:local_assistant/app/passwords/passwords_kit.dart';
import 'package:local_assistant/app/passwords/passwords_platform.dart';
import 'package:local_assistant/app/passwords/passwords_screen.dart';
import 'package:local_assistant/app/screens/my_relay_screen.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/http_transport.dart';
import 'package:local_assistant/core/connectors/manifest/connection.dart';
import 'package:local_assistant/core/connectors/manifest/connection_service.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/extensions/extension_registry.dart';
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

import '../connectors/manifest/fixtures.dart';
import '../support/home_nav.dart';

import 'vault_test_support.dart';

void main() {
  late SodiumVaultCrypto crypto;

  setUpAll(() async {
    crypto = await testCrypto();
  });

  late Vault vault;
  late PasswordsKit kit;
  late AssistantController assistant;
  late TaskService tasks;
  late InMemoryChatStore chats;
  late InMemorySettingsStore settings;
  String? copied;
  List<ConnectionService> connections = const <ConnectionService>[];

  Future<String> setUpHome({
    bool enabled = true,
    bool warehouse = false,
  }) async {
    final clock = FixedClock(DateTime(2026, 11, 10, 12));
    vault = testVault(InMemoryVaultStore(), crypto);
    await vault.load();
    await vault.create(secret(Canary.master), params: fastKdf);
    final id = await vault.addEntry(
      service: 'Почта',
      login: Canary.login,
      hint: Canary.hint,
      password: secret(Canary.password),
      note: secret(Canary.note),
    );
    copied = null;
    kit = PasswordsKit(
      vault: vault,
      platform: PasswordsPlatform.linux,
      kdfForTesting: fastKdf,
      clipboard: ClipboardGuard(
        platform: PasswordsPlatform.linux,
        cipher: crypto,
        write: (String text) async => copied = text,
        read: () async => copied,
      ),
    );
    tasks = TaskService(repository: InMemoryTaskRepository(), clock: clock);
    // Склад без сети: проверка связи получает 503 («нет связи»).
    final store = warehouseConnector(
      path: actionsManifestPath,
      transport: const _NoLink(),
      record: connectedRecord(),
      builtIn: builtInManifest(),
    );
    connections = <ConnectionService>[
      if (warehouse)
        ConnectionService(
          connector: store,
          transport: const _NoLink(),
          secrets: InMemorySecretStore(),
          store: InMemoryConnectionStore(),
          clock: clock,
          builtIn: builtInManifest(),
        ),
    ];
    final registry = ExtensionRegistry(
      connectors: <Connector>[
        TasksConnector(
          taskService: tasks,
          parser: ScenarioParser(clock: clock),
        ),
        if (warehouse) store,
        PasswordsConnector(
          vault: kit.facade,
          canCopySecrets: kit.canCopySecrets,
          vaultExisted: () => kit.vaultExisted,
        ),
      ],
      choice: ExtensionChoice(
        enabled: <String>{if (enabled) PasswordsConnector.id},
      ),
    );
    assistant = AssistantController(
      extensions: registry,
      clock: clock,
      knownSecret: kit.facade.knownSecret,
    );
    chats = InMemoryChatStore();
    settings = InMemorySettingsStore();
    await settings.save(
      AppSettings(
        enabledExtensions: <String>{if (enabled) PasswordsConnector.id},
        enabledRoles: <String>{if (warehouse) Roles.storekeeperId},
      ),
    );
    return id;
  }

  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AssistantTheme.dark(),
        home: HomePage(
          assistant: assistant,
          tasks: tasks,
          clock: FixedClock(DateTime(2026, 11, 10, 12)),
          settingsStore: settings,
          chatStore: chats,
          passwords: kit,
          connections: connections,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('assistant-input')), text);
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  }

  Finder canary(String value) => find.textContaining(value, findRichText: true);

  /// «+» → «Шаблоны команд» → «Найти команду» и поиск [query].
  Future<void> openCommandFinder(WidgetTester tester, String query) async {
    await tester.tap(find.byKey(const Key('templates-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('composer-templates')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('command-find')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('command-search')), query);
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    vault.lock();
    await tester.pumpWidget(const SizedBox.shrink());
    kit.dispose();
  }

  Future<void> expectHistoryClean({bool hint = true}) async {
    for (final thread in await chats.loadIndex()) {
      for (final message in await chats.loadMessages(thread.id)) {
        final json = '${message.toJson()}';
        for (final value in <String>[
          Canary.password,
          Canary.note,
          Canary.master,
          Canary.login,
          if (hint) Canary.hint,
        ]) {
          expect(json, isNot(contains(value)));
        }
      }
    }
  }

  testWidgets('тренировка: строка в пустой сессии, вопрос — по нажатию',
      (tester) async {
    await setUpHome();
    await settings.save(
      const AppSettings(
        enabledExtensions: <String>{PasswordsConnector.id},
        passwordsTrainingDue: '2026-11-10',
      ),
    );
    vault.lock();
    await pumpHome(tester);
    final line = find.byKey(const Key('session-hero-training'));
    expect(line, findsNothing, reason: 'не в первые 30 с');
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();
    expect(line, findsOneWidget);
    expect(tester.getSize(line).height, greaterThanOrEqualTo(44));
    await chats.flush();
    expect(chats.chatIds, isEmpty, reason: 'без нажатия в сессию не пишется');

    await tester.tap(line);
    await tester.pumpAndSettle();
    expect(line, findsNothing);
    expect(find.byKey(const Key('session-hero')), findsNothing);
    await chats.flush();
    expect(chats.chatIds, hasLength(1), reason: 'ответ — в открытую сессию');
    // Нажатие — команда человека: сессия с названием, а не безымянная
    // «Новая сессия» с одним ответом помощника.
    final index = await chats.loadIndex();
    final saved = index.singleWhere((t) => t.isSession);
    expect(saved.title, 'Потренируй меня');
    final stored = await chats.loadMessages(saved.id);
    expect(stored.first.fromUser, isTrue);
    expect(stored.first.text, 'Потренируй меня');
    expect(
      stored.any((m) => !m.fromUser),
      isTrue,
      reason: 'ответ «Паролей» — в той же сессии',
    );
    expect(
      (await settings.load()).passwordsTrainingDue,
      '2026-11-13',
      reason: 'следующая — через 3 дня',
    );
    await expectHistoryClean();
    await finish(tester);
  });

  testWidgets('тренировка из строки не плодит безымянные сессии',
      (tester) async {
    await setUpHome();
    await settings.save(
      const AppSettings(
        enabledExtensions: <String>{PasswordsConnector.id},
        passwordsTrainingDue: '2026-11-10',
      ),
    );
    vault.lock();
    await pumpHome(tester);
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-hero-training')));
    await tester.pumpAndSettle();
    // «+» — новая пустая сессия; ещё раз «+» — она же.
    await tapInDrawer(tester, const Key('new-session'));
    await tapInDrawer(tester, const Key('new-session'));
    await openDrawerIfNeeded(tester);
    expect(drawerEntry('Потренируй меня'), findsOneWidget);
    expect(sessionEntries(), findsNWidgets(2));
    await chats.flush();
    expect(
      (await chats.loadIndex()).where((t) => t.isSession && t.title == null),
      isEmpty,
      reason: 'на диске нет сессий без названия',
    );

    // «сессий N» одинаково до и после перезапуска.
    String stats() => tester
        .widget<RelayStatsLine>(find.byKey(const Key('my-relay-stats')))
        .stats;
    await openMyRelay(tester);
    expect(stats(), contains('сессий 1'));
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpHome(tester);
    await openMyRelay(tester);
    expect(stats(), contains('сессий 1'), reason: 'после перезапуска');
    await finish(tester);
  });

  testWidgets('ползунок длины в ленте не открывает меню свайпом',
      (tester) async {
    await setUpHome();
    await pumpHome(tester);
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    await send(tester, 'сгенерируй пароль');
    final slider = find.byKey(const ValueKey<String>('generator-length'));
    await tester.ensureVisible(slider);
    await tester.pumpAndSettle();
    final before = tester.widget<Slider>(slider).value;
    final rect = tester.getRect(slider);
    await tester.dragFrom(
      Offset(rect.left + rect.width * 0.3, rect.center.dy),
      const Offset(120, 0),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(slider).value, isNot(before));
    expect(find.byKey(const Key('app-sidebar')), findsNothing);
    await finish(tester);
  });

  testWidgets('«забыл пароль от почты»: подсказка в карточке, не в истории',
      (WidgetTester tester) async {
    await setUpHome();
    await pumpHome(tester);
    await send(tester, 'забыл пароль от почты');
    expect(
      find.byKey(const ValueKey<String>('secure-card-hint-text')),
      findsOne,
    );
    expect(find.text(Canary.hint), findsOneWidget);
    expect(canary(Canary.password), findsNothing);
    expect(find.textContaining('Подсказка к «Почта»'), findsOneWidget);
    // Показ по явной кнопке — в историю только факт.
    await tester.tap(find.byKey(const ValueKey<String>('secure-card-reveal')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('secret-show')));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(canary(Canary.password), findsOneWidget);
    expect(find.textContaining('был показан'), findsOneWidget);
    await tester.pump(const Duration(seconds: 16));
    expect(canary(Canary.password), findsNothing);
    await expectHistoryClean();
    expect(assistant.outboundLeaks, 0);
    await finish(tester);
  });

  testWidgets(
      'в «Документе» ответ навыка «Пароли» — не в уведомлении: '
      '«Ответ в диалоге», карточка — в «Диалоге»', (WidgetTester tester) async {
    await setUpHome();
    await pumpHome(tester);
    await tester.tap(find.byKey(const Key('mode-document')));
    await tester.pumpAndSettle();
    await send(tester, 'забыл пароль от почты');
    final toast = find.byKey(const Key('doc-reply-toast'));
    expect(toast, findsOneWidget);
    expect(
      find.descendant(of: toast, matching: find.text('Ответ в диалоге')),
      findsOneWidget,
    );
    for (final value in <String>[
      Canary.hint,
      Canary.password,
      Canary.note,
      Canary.master,
    ]) {
      expect(canary(value), findsNothing, reason: value);
    }
    expect(find.textContaining('Подсказка к «Почта»'), findsNothing);
    // В «Диалоге» — карточка, как обычно.
    await tester.tap(find.byKey(const Key('mode-dialogue')));
    await tester.pumpAndSettle();
    expect(find.text(Canary.hint), findsOneWidget);
    expect(canary(Canary.password), findsNothing);
    await expectHistoryClean();
    expect(assistant.outboundLeaks, 0);
    await finish(tester);
  });

  testWidgets('«скопируй» → «да»: копия в буфере, очистка через 30 с',
      (WidgetTester tester) async {
    await setUpHome();
    await pumpHome(tester);
    await send(tester, 'скопируй пароль от почты');
    expect(find.textContaining('Скопировать пароль от «Почта»?'), findsOne);
    await send(tester, 'да');
    await tester.pump();
    expect(copied, Canary.password);
    expect(canary(Canary.password), findsNothing);
    await tester.pump(const Duration(seconds: 31));
    expect(copied, isEmpty);
    await expectHistoryClean();
    await finish(tester);
  });

  testWidgets('кнопки и «+» навыка — только пока он включён',
      (WidgetTester tester) async {
    await setUpHome(enabled: false);
    await pumpHome(tester);
    expect(find.byKey(const Key('quick-Открыть пароли')), findsNothing);
    // Действия сейфа — в «+» → «Шаблоны команд» → «Найти команду»,
    // раздел «Сейф» (ADR-020): с выключенным навыком раздела нет.
    await openCommandFinder(tester, 'сейф');
    expect(find.byKey(const Key('command-category-vault')), findsNothing);
    expect(find.byKey(const Key('command-entry-pw.open')), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await send(tester, 'забыл пароль от почты');
    expect(find.textContaining('выключен'), findsWidgets);
    expect(await tasks.listAll(), isEmpty);

    // Включили — кнопки и пункты появились.
    assistant.extensions.apply(
      assistant.extensions.choiceWith(PasswordsConnector.id, true),
    );
    await tester.pumpAndSettle();
    // Переписка начата: кнопок навыка над полем ввода нет (ADR-027) —
    // они в новой сессии.
    expect(find.byKey(const Key('quick-Открыть пароли')), findsNothing);
    await tapInDrawer(tester, const Key('new-session'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quick-Открыть пароли')), findsOne);
    expect(find.byKey(const Key('quick-Подсказка к паролю…')), findsOne);
    await openCommandFinder(tester, 'сейф');
    await tester.tap(find.byKey(const Key('command-entry-pw.open')));
    await tester.pumpAndSettle();
    expect(find.byType(PasswordsScreen), findsOneWidget);
    // Выключение заперло хранилище; включение его не открывает.
    expect(find.text('Сейф заперт'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('выключили навык — заперто, карточка гаснет, файл на месте',
      (WidgetTester tester) async {
    await setUpHome();
    await pumpHome(tester);
    await send(tester, 'забыл пароль от почты');
    expect(find.text(Canary.hint), findsOneWidget);
    final before = await vault.store.readVault();
    assistant.extensions.apply(
      assistant.extensions.choiceWith(PasswordsConnector.id, false),
    );
    await tester.pumpAndSettle();
    expect(vault.state, VaultState.disabled);
    expect(find.text(Canary.hint), findsNothing);
    expect(find.textContaining('Навык «Пароли» выключен'), findsWidgets);
    expect(await vault.store.readVault(), before);
    await finish(tester);
  });

  testWidgets('приложение ушло в фон — хранилище заперто',
      (WidgetTester tester) async {
    await setUpHome();
    await pumpHome(tester);
    expect(vault.isUnlocked, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(vault.isUnlocked, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(vault.isUnlocked, isFalse);
    for (final state in <AppLifecycleState>[
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    await finish(tester);
  });

  testWidgets('открыли — в settings.json только версия и «было» (4.1, D28)',
      (WidgetTester tester) async {
    await setUpHome();
    vault.lock();
    await pumpHome(tester);
    await send(tester, 'забыл пароль от почты');
    expect(find.text('Сейф заперт.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('secure-card-open')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('lock-master')),
      Canary.master,
    );
    await tester.tap(find.byKey(const ValueKey<String>('lock-submit')));
    await tester.pumpAndSettle();
    // Карточка повторила команду: подсказка — в новой карточке.
    expect(find.text(Canary.hint), findsOneWidget);
    final saved = await settings.load();
    expect(saved.passwordsVaultExisted, isTrue);
    expect(saved.passwordsSeenRev, vault.rev);
    final json = '${saved.toJson()}';
    expect(json, isNot(contains('Почта')));
    expect(json, isNot(contains(Canary.login)));
    await expectHistoryClean();
    await finish(tester);
  });

  testWidgets('«Расширения»: статус хранилища и «Настроить»',
      (WidgetTester tester) async {
    await setUpHome();
    await pumpHome(tester);
    await openSettingsCategory(tester, 'extensions');
    final status =
        find.byKey(const ValueKey<String>('extension-status-passwords'));
    await tester.ensureVisible(status);
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(status).data,
      startsWith('Сейф открыт до'),
    );
    vault.lock();
    await tester.pump();
    expect(tester.widget<Text>(status).data, 'Сейф заперт');
    await tester.tap(
      find.byKey(const ValueKey<String>('extension-configure-passwords')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PasswordsScreen), findsOneWidget);
    await finish(tester);
  });

  testWidgets('боковая панель: точка «Паролей» — тёплая, пока открыто',
      (WidgetTester tester) async {
    await setUpHome();
    await pumpHome(tester);
    Color dot() => (tester
            .widget<Container>(
              find.byKey(const Key('drawer-extension-dot-passwords')),
            )
            .decoration! as BoxDecoration)
        .color!;
    final status = find.byKey(const Key('drawer-extension-status-passwords'));
    await tester.ensureVisible(status);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(status).data, 'открыт');
    expect(dot(), AppPalette.dark.warning);
    vault.lock();
    await tester.pump();
    expect(tester.widget<Text>(status).data, 'заперт');
    expect(dot(), AppPalette.dark.faint);
    await finish(tester);
  });

  testWidgets('«Расширения»: Склад — первым, Пароли — под ним (макет «Ж1»)',
      (WidgetTester tester) async {
    await setUpHome(warehouse: true);
    await pumpHome(tester);
    final store = find.byKey(const Key('drawer-extension-warehouse'));
    final vaultRow = find.byKey(const Key('drawer-extension-passwords'));
    await tester.ensureVisible(vaultRow);
    await tester.pumpAndSettle();
    expect(store, findsOneWidget);
    expect(
      tester.getTopLeft(store).dy,
      lessThan(tester.getTopLeft(vaultRow).dy),
    );
    await finish(tester);
  });
}

/// Сети нет: склад отвечает 503, приложение показывает «нет связи».
final class _NoLink implements HttpTransport {
  const _NoLink();

  @override
  Future<HttpResponseData> send(HttpRequestData request) async =>
      const HttpResponseData(statusCode: 503, body: '{}');
}
