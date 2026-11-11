// Экраны и карточки навыка «Пароли»: исправления по ревью этапа 2
// (переспрос для важных, гонки показа, запирание поверх диалога, вёрстка
// при крупном шрифте). Пароли — только канарейки.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

  /// Ввести мастер-пароль в диалоге. Без `pumpAndSettle` после показа:
  /// он докрутил бы таймер показа до конца.
  Future<void> pumpMaster(
    WidgetTester tester,
    String master, {
    bool settle = false,
  }) async {
    await tester.enterText(
      find.byKey(const ValueKey<String>('master-dialog-field')),
      master,
    );
    await tester.tap(find.byKey(const ValueKey<String>('master-dialog-ok')));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump(const Duration(milliseconds: 400));
    }
  }

  group('важная запись: ослабление только с мастер-паролем', () {
    test('ядро: снять «Важный» без мастер-пароля нельзя', () async {
      makeKit();
      final id = await seed(important: true);
      await expectLater(
        vault.updateInfo(id, important: false),
        throwsArgumentError,
      );
      expect(vault.entry(id)!.important, isTrue);
      await expectLater(
        vault.updateInfo(
          id,
          important: false,
          master: secret('CANARY-wrong-m'),
        ),
        throwsA(anything),
      );
      expect(vault.entry(id)!.important, isTrue);
      // Прочие поля и ужесточение — без вопроса.
      await vault.updateInfo(id, hint: 'новая');
      await vault.updateInfo(
        id,
        important: false,
        master: secret(Canary.master),
      );
      expect(vault.entry(id)!.important, isFalse);
      await vault.updateInfo(id, important: true);
      expect(vault.entry(id)!.important, isTrue);
      // Переспрос выключен — отметка ничего не защищает.
      await vault.setPrefs(
        <String, Object?>{VaultPrefs.repromptImportant.key: false},
        master: secret(Canary.master),
      );
      await vault.updateInfo(id, important: false);
      expect(vault.entry(id)!.important, isFalse);
      vault.lock();
      kit.dispose();
    });

    testWidgets('редактор: «Важный» выключен — спросить мастер-пароль',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      final id = await seed(important: true);
      await tester.pumpWidget(app(EntryEditorScreen(kit: kit, id: id)));
      await tester.tap(find.byKey(const ValueKey<String>('editor-important')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('editor-save')));
      await tester.pumpAndSettle();
      expect(find.text('Снять «Важный»?'), findsOneWidget);
      // Отмена — отметка осталась, редактор открыт.
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(vault.entry(id)!.important, isTrue);
      expect(find.textContaining('нужен мастер-пароль'), findsOneWidget);
      // Неверный — тоже нет.
      await tester.tap(find.byKey(const ValueKey<String>('editor-save')));
      await tester.pumpAndSettle();
      await pumpMaster(tester, 'CANARY-wrong-m', settle: true);
      expect(find.text('Мастер-пароль не подошёл.'), findsOneWidget);
      expect(vault.entry(id)!.important, isTrue);
      await pumpMaster(tester, Canary.master, settle: true);
      expect(vault.entry(id)!.important, isFalse);
      expect(find.byType(EntryEditorScreen), findsNothing);
      await finish(tester);
    });

    testWidgets('заметка важной записи — тоже после мастер-пароля',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      final id = await seed(important: true);
      vault.lock();
      await kit.unlock(Canary.master);
      (vault.clock as TestClock).advance(const Duration(seconds: 61));
      expect(kit.needsReprompt(id), isTrue);
      await tester.pumpWidget(app(EntryScreen(kit: kit, id: id)));
      // Вторая кнопка «Показать» — у заметки.
      await tester.tap(find.byKey(const ValueKey<String>('secret-show')).last);
      await tester.pumpAndSettle();
      expect(find.text('Важная запись'), findsOneWidget);
      expect(canary(Canary.note), findsNothing);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(canary(Canary.note), findsNothing);
      await tester.tap(find.byKey(const ValueKey<String>('secret-show')).last);
      await tester.pumpAndSettle();
      await pumpMaster(tester, Canary.master);
      expect(canary(Canary.note), findsOneWidget);
      await finish(tester);
    });
  });

  group('SecretRevealText: гонки показа', () {
    testWidgets('сигнал «спрятать» во время загрузки — не показываем',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      final id = await seed();
      final pending = Completer<void>();
      await tester.pumpWidget(
        app(
          Scaffold(
            body: SecretRevealText(
              load: () async {
                await pending.future;
                return kit.password(id);
              },
              seconds: 15,
              hide: kit.hideTicks,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey<String>('secret-show')));
      await tester.pump();
      kit.hideTicks.value++;
      await tester.pump();
      pending.complete();
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(canary(Canary.password), findsNothing);
      expect(find.byKey(const ValueKey<String>('secret-shown')), findsNothing);
      // Следующий показ работает как обычно.
      await tester.tap(find.byKey(const ValueKey<String>('secret-show')));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(canary(Canary.password), findsOneWidget);
      await finish(tester);
    });

    testWidgets('удержание: отпустили до конца загрузки — гаснет по таймеру',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      final id = await seed();
      final pending = Completer<void>();
      await tester.pumpWidget(
        app(
          Scaffold(
            body: SecretRevealText(
              load: () async {
                await pending.future;
                return kit.password(id);
              },
              seconds: 15,
              hide: kit.hideTicks,
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey<String>('secret-hold'))),
      );
      await tester.pump(const Duration(seconds: 1));
      await gesture.up();
      await tester.pump();
      pending.complete();
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(canary(Canary.password), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('secret-timer')), findsOne);
      await tester.pump(const Duration(seconds: 16));
      expect(canary(Canary.password), findsNothing);
      await finish(tester);
    });

    testWidgets('удержание с переспросом важной записи — не дольше таймера',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      final id = await seed(important: true);
      vault.lock();
      await kit.unlock(Canary.master);
      (vault.clock as TestClock).advance(const Duration(seconds: 61));
      await tester.pumpWidget(app(EntryScreen(kit: kit, id: id)));
      final gesture = await tester.startGesture(
        tester
            .getCenter(find.byKey(const ValueKey<String>('secret-hold')).first),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Важная запись'), findsOneWidget);
      await gesture.up();
      await tester.pump();
      await pumpMaster(tester, Canary.master);
      expect(canary(Canary.password), findsOneWidget);
      await tester.pump(const Duration(seconds: 16));
      expect(canary(Canary.password), findsNothing);
      await finish(tester);
    });
  });

  group('запирание поверх диалога', () {
    testWidgets('диалог удаления открыт — закрылись и диалог, и запись',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await seed();
      await tester.pumpWidget(app(PasswordsScreen(kit: kit)));
      await tester.tap(find.text('Почта'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('entry-delete')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('entry-delete-confirm')),
        findsOne,
      );
      vault.lock();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(EntryScreen), findsNothing);
      expect(find.byKey(const ValueKey<String>('entry-delete')), findsNothing);
      expect(find.text(Canary.login), findsNothing);
      expect(find.text('Хранилище заперто'), findsOneWidget);
      expect(vault.entries, isEmpty);
      await finish(tester);
    });

    testWidgets('переспрос в редакторе открыт — закрылись редактор и запись',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await seed(important: true);
      await tester.pumpWidget(app(PasswordsScreen(kit: kit)));
      await tester.tap(find.text('Почта'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('entry-edit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('editor-important')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('editor-save')));
      await tester.pumpAndSettle();
      expect(find.text('Снять «Важный»?'), findsOneWidget);
      vault.lock();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(EntryEditorScreen), findsNothing);
      expect(find.byType(EntryScreen), findsNothing);
      expect(find.text('Хранилище заперто'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('настройки с вопросом мастер-пароля — закрылись целиком',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await seed();
      await tester.pumpWidget(
        app(
          Builder(
            builder: (BuildContext context) => Scaffold(
              body: TextButton(
                onPressed: () => unawaited(
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => PasswordsSettingsScreen(kit: kit),
                    ),
                  ),
                ),
                child: const Text('настройки'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('настройки'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('prefs-hints_in_history')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Ослабить защиту?'), findsOneWidget);
      vault.lock();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(PasswordsSettingsScreen), findsNothing);
      expect(find.text('настройки'), findsOneWidget);
      await finish(tester);
    });
  });

  group('вёрстка', () {
    testWidgets('карточка выбора — строки на Material, без ошибок',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      final id = await seed();
      final chosen = <String?>[];
      for (final kind in <SecureCardKind>[
        SecureCardKind.choose,
        SecureCardKind.list,
      ]) {
        await tester.pumpWidget(
          app(
            Scaffold(
              body: SecureCardView(
                card: SecureCardRequest(kind: kind, entryIds: <String>[id]),
                kit: kit,
                onCommand: (
                  SecureCardRequest c,
                  String action, {
                  String? entryId,
                }) =>
                    chosen.add(entryId),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull, reason: kind.name);
        expect(find.byType(EntryTile), findsOneWidget);
      }
      await tester.pumpWidget(
        app(
          Scaffold(
            body: SecureCardView(
              card: SecureCardRequest(
                kind: SecureCardKind.choose,
                entryIds: <String>[id],
              ),
              kit: kit,
              onCommand: (
                SecureCardRequest c,
                String action, {
                String? entryId,
              }) =>
                  chosen.add(entryId),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(EntryTile));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(chosen, <String?>[id]);
      await finish(tester);
    });

    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }

    testWidgets('список: 320 px и шрифт ×2 — кнопки значками, поиск виден',
        (WidgetTester tester) async {
      phone(tester);
      makeKit();
      await seed();
      await tester.pumpWidget(app(PasswordsScreen(kit: kit)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final search = find.byKey(const ValueKey<String>('passwords-search'));
      expect(tester.getSize(search).width, greaterThan(180));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('passwords-add')),
          matching: find.text('Добавить'),
        ),
        findsNothing,
      );
      // Полоса «Открыто»: текст не рвётся посреди слова — ему хватает места
      // хотя бы на слово «Открыто» целиком.
      final bar = find.descendant(
        of: find.byKey(const ValueKey<String>('passwords-open-bar')),
        matching: find.textContaining('Открыто'),
      );
      expect(tester.getSize(bar).width, greaterThan(140));
      await finish(tester);
    });

    testWidgets('редактор: 320 px и шрифт ×2 — предупреждение не обрезано',
        (WidgetTester tester) async {
      phone(tester);
      makeKit();
      await seed();
      await tester.pumpWidget(app(EntryEditorScreen(kit: kit)));
      await tester.pumpAndSettle();
      final helper = find.textContaining('Не пишите в ней сам пароль');
      expect(helper, findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(helper);
      expect(paragraph.didExceedMaxLines, isFalse);
      await finish(tester);
    });
  });
}
