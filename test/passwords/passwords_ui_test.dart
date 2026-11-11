// Экраны и карточки навыка «Пароли» (ADR-014, этап 2, раздел 11 группа
// 14). Golden-снимков показанного пароля нет (D24): только поиск
// канарейки в дереве виджетов.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/passwords/clipboard_guard.dart';
import 'package:local_assistant/app/passwords/entry_screens.dart';
import 'package:local_assistant/app/passwords/passwords_kit.dart';
import 'package:local_assistant/app/passwords/passwords_platform.dart';
import 'package:local_assistant/app/passwords/passwords_screen.dart';
import 'package:local_assistant/app/passwords/passwords_settings_screen.dart';
import 'package:local_assistant/app/passwords/secret_widgets.dart';
import 'package:local_assistant/app/passwords/secure_card_view.dart';
import 'package:local_assistant/core/models/secure_card.dart';
import 'package:local_assistant/core/passwords/vault.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_format.dart';
import 'package:local_assistant/core/passwords/vault_prefs.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';

import 'vault_test_support.dart';

/// Буфер обмена в памяти.
final class _Clipboard {
  String? value;
  int reads = 0;

  Future<void> write(String text) async => value = text;

  Future<String?> read() async {
    reads++;
    return value;
  }
}

/// Высокое окно: формы целиком в дереве, без прокрутки.
void big(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  late SodiumVaultCrypto crypto;

  setUpAll(() async {
    crypto = await testCrypto();
  });

  late Vault vault;
  late PasswordsKit kit;
  late _Clipboard clipboard;

  PasswordsKit makeKit({
    PasswordsPlatform platform = PasswordsPlatform.linux,
  }) {
    vault = testVault(InMemoryVaultStore(), crypto);
    clipboard = _Clipboard();
    kit = PasswordsKit(
      vault: vault,
      platform: platform,
      kdfForTesting: fastKdf,
      clipboard: ClipboardGuard(
        platform: platform,
        cipher: crypto,
        write: clipboard.write,
        read: clipboard.read,
      ),
    );
    return kit;
  }

  Future<String> seed({bool important = false}) async {
    await vault.load();
    await vault.create(secret(Canary.master), params: fastKdf);
    return vault.addEntry(
      service: 'Почта',
      login: Canary.login,
      hint: Canary.hint,
      password: secret(Canary.password),
      note: secret(Canary.note),
      important: important,
    );
  }

  Widget app(Widget home) => MaterialApp(
        theme: AssistantTheme.dark(),
        home: home,
      );

  /// Таймеры хранилища и буфера не переживают тест.
  Future<void> finish(WidgetTester tester) async {
    big(tester);
    vault.lock();
    await tester.pumpWidget(const SizedBox.shrink());
    kit.dispose();
  }

  Finder canary(String value) => find.textContaining(value, findRichText: true);

  /// Все поля секретов — с нужными флагами (раздел 8).
  void expectSecretFieldsSafe(WidgetTester tester) {
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .where((TextField f) => f.obscureText)
        .toList();
    expect(fields, isNotEmpty);
    for (final field in fields) {
      expect(field.enableSuggestions, isFalse);
      expect(field.autocorrect, isFalse);
      expect(field.enableIMEPersonalizedLearning, isFalse);
      expect(field.autofillHints, isNull);
      expect(field.keyboardType, TextInputType.visiblePassword);
      expect(field.textCapitalization, TextCapitalization.none);
    }
    expect(find.byType(AutofillGroup), findsNothing);
    expect(find.byType(SelectableText), findsNothing);
  }

  group('создание хранилища', () {
    testWidgets('честно о восстановлении; без галочки не пускает',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await vault.load();
      await tester.pumpWidget(app(PasswordsScreen(kit: kit)));
      expect(
        find.textContaining('Без мастер-пароля данные не восстановить'),
        findsOneWidget,
      );
      expectSecretFieldsSafe(tester);
      final submit = find.byKey(const ValueKey<String>('create-submit'));
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey<String>('create-master')),
        'короткий',
      );
      await tester.tap(find.byKey(const ValueKey<String>('create-understood')));
      await tester.pump();
      await tester.tap(submit);
      await tester.pump();
      expect(find.text('Нужно не меньше 12 символов.'), findsOneWidget);
      expect(vault.state, VaultState.notCreated);

      await tester.enterText(
        find.byKey(const ValueKey<String>('create-master')),
        Canary.master,
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('create-repeat')),
        Canary.master,
      );
      await tester.tap(submit);
      await tester.pump();
      await tester.pump();
      expect(vault.state, VaultState.unlocked);
      // Сразу — ещё раз по памяти.
      expect(find.byKey(const ValueKey<String>('recheck-master')), findsOne);
      await tester.enterText(
        find.byKey(const ValueKey<String>('recheck-master')),
        'CANARY-wrong-r',
      );
      await tester.tap(find.byKey(const ValueKey<String>('recheck-submit')));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Не совпало'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey<String>('recheck-master')),
        Canary.master,
      );
      await tester.tap(find.byKey(const ValueKey<String>('recheck-submit')));
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('passwords-open-bar')),
        findsOne,
      );
      expect(kit.vaultExisted, isTrue);
      expect(kit.seenRev, isNotNull);
      expect(canary(Canary.master), findsNothing);
      await finish(tester);
    });

    testWidgets('хранилище уже было — «не найдено на устройстве» (D28)',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await vault.load();
      kit.syncSettings(vaultExisted: true);
      await tester.pumpWidget(app(PasswordsScreen(kit: kit)));
      expect(
        find.byKey(const ValueKey<String>('passwords-not-found')),
        findsOne,
      );
      await finish(tester);
    });
  });

  group('замок', () {
    testWidgets('неверный, затем верный мастер-пароль; поле очищается',
        (WidgetTester tester) async {
      big(tester);
      makeKit(platform: PasswordsPlatform.windows);
      await seed();
      vault.lock();
      await tester.pumpWidget(app(PasswordsScreen(kit: kit)));
      expect(find.text('Хранилище заперто'), findsOneWidget);
      expect(
        find.text('На Windows хранилище открывается только мастер-паролем.'),
        findsOneWidget,
      );
      expectSecretFieldsSafe(tester);
      final field = find.byKey(const ValueKey<String>('lock-master'));
      await tester.enterText(field, 'CANARY-wrong-1');
      await tester.tap(find.byKey(const ValueKey<String>('lock-submit')));
      await tester.pump();
      await tester.pump();
      expect(find.text('Мастер-пароль не подошёл.'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: field, matching: find.byType(TextField)),
            )
            .controller!
            .text,
        isEmpty,
      );
      await tester.enterText(field, Canary.master);
      await tester.tap(find.byKey(const ValueKey<String>('lock-submit')));
      await tester.pump();
      await tester.pump();
      expect(vault.isUnlocked, isTrue);
      expect(find.text('Почта'), findsOneWidget);
      expect(canary(Canary.login), findsNothing);
      expect(find.textContaining('ca***@example.org'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('файл старее, чем был (seen_rev) — предупреждение',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await seed();
      vault.lock();
      kit.syncSettings(seenRev: 999, vaultExisted: true);
      final outcome = await kit.unlock(Canary.master);
      expect(outcome.ok, isTrue);
      expect(outcome.rolledBack, isTrue);
      // seen_rev не уменьшается.
      expect(kit.seenRev, 999);
      await tester.pumpWidget(app(PasswordsScreen(kit: kit)));
      expect(
        find.byKey(const ValueKey<String>('passwords-rolled-back')),
        findsOne,
      );
      await finish(tester);
    });

    testWidgets('Caps Lock — вошли и сказали об этом',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await vault.load();
      await vault.create(secret('Canary-Master-q7'), params: fastKdf);
      vault.lock();
      await tester.pumpWidget(app(PasswordsScreen(kit: kit)));
      await tester.enterText(
        find.byKey(const ValueKey<String>('lock-master')),
        'cANARY-mASTER-Q7',
      );
      await tester.tap(find.byKey(const ValueKey<String>('lock-submit')));
      await tester.pump();
      await tester.pump();
      expect(vault.isUnlocked, isTrue);
      expect(find.textContaining('Caps Lock'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('«Забыли мастер-пароль?» — начать заново только словом',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await seed();
      vault.lock();
      await tester.pumpWidget(app(PasswordsScreen(kit: kit)));
      await tester.tap(find.byKey(const ValueKey<String>('lock-forgot')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Восстановить нельзя'), findsOneWidget);
      final start = find.byKey(const ValueKey<String>('recovery-start-over'));
      expect(tester.widget<TextButton>(start).onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey<String>('recovery-word')),
        'начать',
      );
      await tester.pump();
      await tester.tap(start);
      await tester.pumpAndSettle();
      expect(vault.state, VaultState.notCreated);
      expect(await vault.store.archived(), hasLength(1));
      await finish(tester);
    });
  });

  group('показ пароля', () {
    testWidgets('маска, показ на 15 с, семантика без значения, гаснет',
        (WidgetTester tester) async {
      big(tester);
      final handle = tester.ensureSemantics();
      makeKit();
      final id = await seed();
      var revealed = 0;
      await tester.pumpWidget(
        app(
          Scaffold(
            body: SecretRevealText(
              load: () => kit.password(id),
              seconds: 15,
              hide: kit.hideTicks,
              onRevealed: () => revealed++,
            ),
          ),
        ),
      );
      expect(canary(Canary.password), findsNothing);
      expect(find.bySemanticsLabel('Пароль скрыт'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('secret-show')));
      await tester.pump();
      await tester.pump();
      expect(canary(Canary.password), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
      expect(find.bySemanticsLabel('Пароль показан'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('CANARY')), findsNothing);
      expect(revealed, 1);
      await tester.pump(const Duration(seconds: 14));
      expect(canary(Canary.password), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(canary(Canary.password), findsNothing);
      expect(find.bySemanticsLabel('Пароль скрыт'), findsOneWidget);
      // Снова показали и заперли хранилище — гаснет сразу.
      await tester.tap(find.byKey(const ValueKey<String>('secret-show')));
      await tester.pump();
      await tester.pump();
      expect(canary(Canary.password), findsOneWidget);
      vault.lock();
      await tester.pump();
      expect(canary(Canary.password), findsNothing);
      expect(revealed, 1);
      handle.dispose();
      await finish(tester);
    });

    testWidgets('окно неактивно (inactive) — показанное прячется',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      final id = await seed();
      await tester.pumpWidget(
        app(
          Scaffold(
            body: SecretRevealText(
              load: () => kit.password(id),
              seconds: 15,
              hide: kit.hideTicks,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey<String>('secret-show')));
      await tester.pump();
      await tester.pump();
      expect(canary(Canary.password), findsOneWidget);
      kit.lifecycle.onAppState(AppLifecycleState.inactive);
      await tester.pump();
      expect(canary(Canary.password), findsNothing);
      expect(vault.isUnlocked, isTrue);
      kit.lifecycle.onAppState(AppLifecycleState.paused);
      expect(vault.isUnlocked, isFalse);
      await finish(tester);
    });
  });

  group('карточка записи', () {
    testWidgets('логин целиком, пароль в маске, копирование, запирание',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      final id = await seed();
      await tester.pumpWidget(app(EntryScreen(kit: kit, id: id)));
      expect(find.text(Canary.login), findsOneWidget);
      expect(find.text(Canary.hint), findsOneWidget);
      expect(canary(Canary.password), findsNothing);
      expect(canary(Canary.note), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey<String>('entry-copy-password')),
      );
      await tester.pump();
      await tester.pump();
      expect(clipboard.value, Canary.password);
      expect(find.textContaining('Очистится через 30 с'), findsOneWidget);
      await tester.pump(const Duration(seconds: 31));
      expect(clipboard.value, isEmpty);
      await finish(tester);
    });

    testWidgets('Windows: кнопки «Скопировать» у пароля нет (D22)',
        (WidgetTester tester) async {
      big(tester);
      makeKit(platform: PasswordsPlatform.windows);
      final id = await seed();
      await tester.pumpWidget(app(EntryScreen(kit: kit, id: id)));
      expect(
        find.byKey(const ValueKey<String>('entry-copy-password')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey<String>('entry-copy-note')), findsOne);
      await finish(tester);
    });

    testWidgets(
        'важная запись — показ после мастер-пароля, если прошла '
        'минута (3.6)', (WidgetTester tester) async {
      big(tester);
      makeKit();
      final id = await seed(important: true);
      vault.lock();
      await kit.unlock(Canary.master);
      expect(kit.needsReprompt(id), isFalse);
      (vault.clock as TestClock).advance(const Duration(seconds: 61));
      expect(kit.needsReprompt(id), isTrue);
      await tester.pumpWidget(app(EntryScreen(kit: kit, id: id)));
      await tester.tap(find.byKey(const ValueKey<String>('secret-show')).first);
      await tester.pumpAndSettle();
      expect(find.text('Важная запись'), findsOneWidget);
      expect(canary(Canary.password), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey<String>('master-dialog-field')),
        Canary.master,
      );
      await tester.tap(find.byKey(const ValueKey<String>('master-dialog-ok')));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(canary(Canary.password), findsOneWidget);
      expect(kit.needsReprompt(id), isFalse);
      await finish(tester);
    });

    testWidgets('заперли — экран записи закрылся', (WidgetTester tester) async {
      big(tester);
      makeKit();
      final id = await seed();
      await tester.pumpWidget(app(PasswordsScreen(kit: kit)));
      await tester.tap(find.text('Почта'));
      await tester.pumpAndSettle();
      expect(find.byType(EntryScreen), findsOneWidget);
      vault.lock();
      await tester.pumpAndSettle();
      expect(find.byType(EntryScreen), findsNothing);
      expect(find.text('Хранилище заперто'), findsOneWidget);
      expect(id, isNotEmpty);
      await finish(tester);
    });

    testWidgets('редактор: новая запись, повтор пароля, подсказка без пароля',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await seed();
      await tester.pumpWidget(
        app(EntryEditorScreen(kit: kit, service: 'озон')),
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey<String>('editor-service')),
            )
            .controller!
            .text,
        'Озон',
      );
      expectSecretFieldsSafe(tester);
      await tester.enterText(
        find.byKey(const ValueKey<String>('editor-password')),
        Canary.password,
      );
      await tester.pump();
      expect(find.textContaining('уже используется для: Почта'), findsOne);
      await tester.enterText(
        find.byKey(const ValueKey<String>('editor-hint')),
        'там ${Canary.password}',
      );
      await tester.tap(find.byKey(const ValueKey<String>('editor-save')));
      await tester.pump();
      expect(
        find.text('В подсказке не должно быть самого пароля.'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('editor-hint')),
        'как у почты',
      );
      await tester.tap(find.byKey(const ValueKey<String>('editor-save')));
      await tester.pump();
      await tester.pump();
      expect(vault.entries.map((VaultEntry e) => e.service), contains('Озон'));
      await finish(tester);
    });
  });

  group('временные карточки', () {
    testWidgets('заперто — «Открыть»; открыли — повтор команды',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await seed();
      vault.lock();
      final commands = <String>[];
      const card = SecureCardRequest(
        kind: SecureCardKind.unlock,
        resume: 'passwords.hint',
        options: <String, Object?>{'query': 'почта'},
      );
      await tester.pumpWidget(
        app(
          Scaffold(
            body: SecureCardView(
              card: card,
              kit: kit,
              onCommand: (
                SecureCardRequest c,
                String action, {
                String? entryId,
              }) =>
                  commands.add(action),
            ),
          ),
        ),
      );
      expect(find.text('Хранилище заперто.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('secure-card-open')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('lock-master')),
        Canary.master,
      );
      await tester.tap(find.byKey(const ValueKey<String>('lock-submit')));
      await tester.pumpAndSettle();
      expect(find.byType(PasswordsScreen), findsNothing);
      expect(commands, <String>[SecureCardCommand.resume]);
      expect(find.text('Хранилище открыто.'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('подсказка: сначала подсказка, пароль — только по кнопке',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      final id = await seed();
      final commands = <String>[];
      final card = SecureCardRequest(
        kind: SecureCardKind.hint,
        entryIds: <String>[id],
      );
      await tester.pumpWidget(
        app(
          Scaffold(
            body: SecureCardView(
              card: card,
              kit: kit,
              onCommand: (
                SecureCardRequest c,
                String action, {
                String? entryId,
              }) =>
                  commands.add(action),
            ),
          ),
        ),
      );
      expect(find.text(Canary.hint), findsOneWidget);
      expect(find.text(Canary.login), findsOneWidget);
      expect(canary(Canary.password), findsNothing);
      expect(find.byType(SecretRevealText), findsNothing);
      await tester
          .tap(find.byKey(const ValueKey<String>('secure-card-reveal')));
      await tester.pump();
      expect(canary(Canary.password), findsNothing);
      await tester.tap(find.byKey(const ValueKey<String>('secret-show')));
      await tester.pump();
      await tester.pump();
      expect(canary(Canary.password), findsOneWidget);
      expect(commands, <String>[SecureCardCommand.revealed]);
      // Заперли — карточка «Хранилище заперто», пароля нет.
      vault.lock();
      await tester.pump();
      expect(canary(Canary.password), findsNothing);
      expect(canary(Canary.hint), findsNothing);
      expect(find.text('Хранилище заперто.'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('копирование после «да» — один раз, даже при перестройке',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      final id = await seed();
      final card = SecureCardRequest(
        kind: SecureCardKind.copy,
        entryIds: <String>[id],
        options: const <String, Object?>{'auto': true},
      );
      Widget view() => app(
            Scaffold(
              body: SecureCardView(
                card: card,
                kit: kit,
                onCommand: (
                  SecureCardRequest c,
                  String a, {
                  String? entryId,
                }) {},
              ),
            ),
          );
      await tester.pumpWidget(view());
      await tester.pump();
      await tester.pump();
      expect(clipboard.value, Canary.password);
      expect(canary(Canary.password), findsNothing);
      clipboard.value = 'чужое';
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(view());
      await tester.pump();
      expect(clipboard.value, 'чужое');
      // Таймер очистки: в буфере уже не наше — не трогаем.
      await tester.pump(const Duration(seconds: 31));
      expect(clipboard.value, 'чужое');
      await finish(tester);
    });
  });

  group('ClipboardGuard', () {
    test('очистка при запирании; Android — без чтения', () async {
      makeKit(platform: PasswordsPlatform.android);
      final id = await seed();
      await kit.copyPassword(id);
      expect(clipboard.value, Canary.password);
      vault.lock();
      await Future<void>.delayed(Duration.zero);
      expect(clipboard.value, isEmpty);
      expect(clipboard.reads, 0);
      kit.dispose();
    });

    test('Windows и macOS: копировать пароль нельзя', () async {
      for (final platform in <PasswordsPlatform>[
        PasswordsPlatform.windows,
        PasswordsPlatform.macos,
      ]) {
        makeKit(platform: platform);
        final id = await seed();
        expect(kit.canCopySecrets, isFalse);
        await expectLater(kit.copyPassword(id), throwsStateError);
        expect(clipboard.value, isNull);
        vault.lock();
        kit.dispose();
      }
    });

    test('выключили навык — буфер очищен, хранилище заперто', () async {
      makeKit();
      final id = await seed();
      await kit.copyPassword(id);
      vault.setEnabled(false);
      await Future<void>.delayed(Duration.zero);
      expect(clipboard.value, isEmpty);
      expect(vault.state, VaultState.disabled);
      kit.dispose();
    });
  });

  group('настройки', () {
    testWidgets('ослабление — только с мастер-паролем',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await seed();
      await tester.pumpWidget(app(PasswordsSettingsScreen(kit: kit)));
      await tester.tap(
        find.byKey(const ValueKey<String>('prefs-hints_in_history')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Ослабить защиту?'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey<String>('master-dialog-field')),
        'CANARY-wrong-s',
      );
      await tester.tap(find.byKey(const ValueKey<String>('master-dialog-ok')));
      await tester.pumpAndSettle();
      expect(find.text('Мастер-пароль не подошёл.'), findsOneWidget);
      expect(VaultPrefs.hintsInHistory.of(vault.prefs), isFalse);
      await tester.enterText(
        find.byKey(const ValueKey<String>('master-dialog-field')),
        Canary.master,
      );
      await tester.tap(find.byKey(const ValueKey<String>('master-dialog-ok')));
      await tester.pumpAndSettle();
      expect(VaultPrefs.hintsInHistory.of(vault.prefs), isTrue);
      // Ужесточение — без вопроса.
      await tester.tap(
        find.byKey(const ValueKey<String>('prefs-autolock_min-1')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Ослабить защиту?'), findsNothing);
      expect(VaultPrefs.autolockMinutes.of(vault.prefs), 1);
      await finish(tester);
    });
  });
}
