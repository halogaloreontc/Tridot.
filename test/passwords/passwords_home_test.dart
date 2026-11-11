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
import 'package:local_assistant/core/chats/chat_store.dart';
import 'package:local_assistant/core/connectors/connector.dart';
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

  Future<String> setUpHome({bool enabled = true}) async {
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
    final registry = ExtensionRegistry(
      connectors: <Connector>[
        TasksConnector(
          taskService: tasks,
          parser: ScenarioParser(clock: clock),
        ),
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
    await tester.tap(find.byKey(const Key('templates-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('composer-action-Пароли')), findsNothing);
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
    expect(find.byKey(const Key('quick-Открыть пароли')), findsOne);
    expect(find.byKey(const Key('quick-Подсказка к паролю…')), findsOne);
    await tester.tap(find.byKey(const Key('templates-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('composer-action-Пароли')));
    await tester.pumpAndSettle();
    expect(find.byType(PasswordsScreen), findsOneWidget);
    // Выключение заперло хранилище; включение его не открывает.
    expect(find.text('Хранилище заперто'), findsOneWidget);
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
    expect(find.text('Хранилище заперто.'), findsOneWidget);
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
    await tester.tap(find.byKey(const Key('nav-settings')).first);
    await tester.pumpAndSettle();
    final status =
        find.byKey(const ValueKey<String>('extension-status-passwords'));
    await tester.scrollUntilVisible(
      status,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester.widget<Text>(status).data,
      startsWith('Открыто до'),
    );
    vault.lock();
    await tester.pump();
    expect(tester.widget<Text>(status).data, 'Заперто');
    await tester.tap(
      find.byKey(const ValueKey<String>('extension-configure-passwords')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PasswordsScreen), findsOneWidget);
    await finish(tester);
  });
}
