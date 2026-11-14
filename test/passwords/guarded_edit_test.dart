// Правка охраняемой важной записи (3.6, 15.2): без свежего мастер-пароля
// её нельзя ни переименовать, ни сменить логин, адреса, подсказку, пароль
// или заметку, ни «заменить» импортом (D1, D3) — иначе новое название,
// сверенное с куском пароля (флаг «в пароле название или логин»,
// оценка), — оракул по подстрокам без предела. Вторая линия: оценка
// охраняемой записи не пересчитывается, в «слабые» и «название в пароле»
// она не входит. «Проверить себя» для неё тратит общий предел догадок
// ворот (D2). Значения — синтетические CANARY.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/passwords/clipboard_guard.dart';
import 'package:local_assistant/app/passwords/entry_screens.dart';
import 'package:local_assistant/app/passwords/passwords_kit.dart';
import 'package:local_assistant/app/passwords/passwords_platform.dart';
import 'package:local_assistant/app/passwords/secure_card_view.dart';
import 'package:local_assistant/core/models/secure_card.dart';
import 'package:local_assistant/core/passwords/import_rules.dart';
import 'package:local_assistant/core/passwords/keyboard_layouts.dart';
import 'package:local_assistant/core/passwords/password_audit.dart';
import 'package:local_assistant/core/passwords/password_training.dart';
import 'package:local_assistant/core/passwords/vault.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_facade.dart';
import 'package:local_assistant/core/passwords/vault_format.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';

import 'vault_test_support.dart';

void main() {
  late SodiumVaultCrypto crypto;

  setUpAll(() async {
    crypto = await testCrypto();
  });

  late TestClock clock;
  late Vault vault;
  late PasswordsKit kit;
  late InMemoryVaultStore store;

  /// Важная «Почта» (пароль [Canary.password]) и обычный «Форум».
  /// Создание — не подтверждение: «Почта» сразу охраняется.
  Future<String> setUpVault({String password = Canary.password}) async {
    clock = TestClock();
    store = InMemoryVaultStore();
    vault = testVault(store, crypto, clock: clock);
    kit = PasswordsKit(
      vault: vault,
      platform: PasswordsPlatform.linux,
      kdfForTesting: fastKdf,
      wordlists: testWordlists(),
      clipboard: ClipboardGuard(
        platform: PasswordsPlatform.linux,
        cipher: crypto,
        write: (String text) async {},
        read: () async => null,
      ),
    );
    await vault.load();
    await vault.create(secret(Canary.master), params: fastKdf);
    final id = await vault.addEntry(
      service: 'Почта',
      login: 'user@mail.example',
      hint: 'как в детстве',
      urls: <String>['https://mail.example'],
      password: secret(password),
      important: true,
    );
    await vault.addEntry(
      service: 'Форум',
      password: secret('CANARY-forum-Kp2'),
    );
    return id;
  }

  void tearDownVault() {
    vault.lock();
    kit.dispose();
  }

  group('D1: переименование охраняемой — не оракул по подстрокам', () {
    // Куски настоящего пароля `CANARY-pw-9zKt4` и приманки той же формы.
    const probes = <(String, String)>[
      ('service', 'canary'),
      ('service', 'nary-pw'),
      ('service', '9zkt4'),
      ('service', 'banana'),
      ('service', 'qwerty'),
      ('login', 'canary@x.example'),
      ('login', 'zkt4@x.example'),
      ('login', 'mango@x.example'),
      ('login', 'pw-9z@x.example'),
      ('urls', 'https://canary.example'),
      ('urls', 'https://9zkt.example'),
      ('urls', 'https://melon.example'),
      ('urls', 'https://kiwi.example'),
    ];

    Future<String> observe(String id) async {
      final groups = await kit.audit();
      final report = await VaultFacade(vault).audit(clock.now());
      final e = vault.entry(id)!;
      return <Object?>[
        e.service,
        e.login,
        e.urls,
        e.flags,
        e.score,
        groups.weak,
        groups.containsInfo,
        groups.pending,
        groups.flagged,
        report.weak,
        report.ids,
        report.unchecked,
      ].join('|');
    }

    test('13 проб: ответ одинаков для кусков пароля и приманок', () async {
      final id = await setUpVault();
      final baseline = await observe(id);
      expect(vault.guessesLeft, Vault.guessLimit);
      for (final (field, probe) in probes) {
        await expectLater(
          switch (field) {
            'service' => vault.updateInfo(id, service: probe),
            'login' => vault.updateInfo(id, login: probe),
            _ => vault.updateInfo(id, urls: <String>[probe]),
          },
          throwsStateError,
          reason: '$field: $probe',
        );
        expect(await observe(id), baseline, reason: '$field: $probe');
      }
      // Предел догадок не тронут: пробы не тратят и не обходят его.
      expect(vault.guessesLeft, Vault.guessLimit);
      tearDownVault();
    });

    test('контроль: после мастер-пароля флаг честный (оракул был бы)',
        () async {
      final id = await setUpVault();
      expect(await kit.confirm(Canary.master), isTrue);
      await vault.updateInfo(id, service: 'canary');
      expect(vault.entry(id)!.flags, contains(EntryFlags.containsService));
      await vault.updateInfo(id, service: 'banana');
      expect(
        vault.entry(id)!.flags,
        isNot(contains(EntryFlags.containsService)),
      );
      tearDownVault();
    });

    test('вторая линия: оценка заморожена, слабые и «название» скрыты',
        () async {
      // Слабый пароль с названием сервиса внутри.
      final id = await setUpVault(password: 'pochta123456');
      expect(await kit.confirm(Canary.master), isTrue);
      await vault.updateInfo(id, service: 'pochta');
      final open = kit.groups();
      expect(open.weak, contains(id));
      expect(open.containsInfo, contains(id));
      expect(open.pending, isEmpty);
      clock.advance(const Duration(seconds: 61));
      expect(kit.needsReprompt(id), isTrue);
      final before = vault.entry(id)!;
      final guarded = await kit.audit();
      final after = vault.entry(id)!;
      expect(after.flags, before.flags);
      expect(after.score, before.score);
      expect(guarded.weak, isNot(contains(id)));
      expect(guarded.containsInfo, isNot(contains(id)));
      expect(guarded.pending, <String>[id]);
      // Без функции охраны (ядро без хранилища) — всё как раньше.
      expect(CheckGroups.of(vault.entries, clock.now()).weak, contains(id));
      tearDownVault();
    });
  });

  group('D2: «Проверить себя» важной — из общего предела догадок', () {
    test('5 разных догадок на все пути и все важные записи', () async {
      final id = await setUpVault();
      final second = await vault.addEntry(
        service: 'Банк',
        password: secret('CANARY-bank-Wq5'),
        important: true,
      );
      expect(vault.recallLeft(id), Vault.guessLimit);
      expect(
        await vault.recall(id, secret('CANARY-guess-1')),
        RecallVerdict.wrong,
      );
      // Повтор той же догадки — бесплатно.
      expect(
        await vault.recall(id, secret('CANARY-guess-1')),
        RecallVerdict.wrong,
      );
      expect(vault.recallLeft(id), Vault.guessLimit - 1);
      // Другая важная запись — тот же предел.
      expect(
        await vault.recall(second, secret('CANARY-guess-2')),
        RecallVerdict.wrong,
      );
      expect(vault.recallLeft(second), Vault.guessLimit - 2);
      // Ворота entriesMatching — тоже.
      expect(
        vault
            .entriesMatching(secret('CANARY-guess-3'), spendGuess: true)
            .complete,
        isTrue,
      );
      // Варианты «почти» — часть одной попытки (5.2).
      final layout = String.fromCharCodes(
        Canary.password.runes.map(KeyboardLayouts.swap),
      );
      expect(
        await vault.recall(id, secret(layout)),
        RecallVerdict.almostLayout,
      );
      expect(
        await vault.recall(second, secret('CANARY-guess-5')),
        RecallVerdict.wrong,
      );
      expect(vault.guessesLeft, 0);
      // Шестая разная — отказ, и по recall, и по воротам.
      expect(
        await vault.recall(id, secret(Canary.password)),
        RecallVerdict.limited,
      );
      expect(
        vault
            .entriesMatching(secret('CANARY-guess-6'), spendGuess: true)
            .complete,
        isFalse,
      );
      // Обычная запись — свой предел, не общий.
      final forum =
          vault.entries.firstWhere((VaultEntry e) => e.service == 'Форум').id;
      expect(
        await vault.recall(forum, secret('CANARY-forum-Kp2')),
        RecallVerdict.correct,
      );
      clock.advance(const Duration(minutes: 10));
      expect(
        await vault.recall(id, secret(Canary.password)),
        RecallVerdict.correct,
      );
      tearDownVault();
    });

    test('после мастер-пароля — обычный предел записи', () async {
      final id = await setUpVault();
      expect(await kit.confirm(Canary.master), isTrue);
      for (var i = 0; i < 5; i++) {
        expect(
          await vault.recall(id, secret('CANARY-g-$i')),
          RecallVerdict.wrong,
        );
      }
      expect(vault.guessesLeft, Vault.guessLimit);
      expect(
        await vault.recall(id, secret(Canary.password)),
        RecallVerdict.limited,
      );
      tearDownVault();
    });
  });

  group('D3: правка и «заменить» импортом — после мастер-пароля', () {
    test('пароль, заметка, подсказка, логин, адреса — StateError', () async {
      final id = await setUpVault();
      final before = await store.readVault();
      final fp = vault.entry(id)!.fp;
      await expectLater(
        vault.updatePassword(id, secret('CANARY-new-Zz9')),
        throwsStateError,
      );
      await expectLater(
        vault.updateNote(id, secret('CANARY-note-Nn1')),
        throwsStateError,
      );
      for (final change in <Future<void> Function()>[
        () => vault.updateInfo(id, hint: 'новая'),
        () => vault.updateInfo(id, login: 'other@mail.example'),
        () => vault.updateInfo(id, urls: <String>['https://x.example']),
      ]) {
        await expectLater(change(), throwsStateError);
      }
      // Ничего не записано, пароль прежний.
      expect(await store.readVault(), before);
      expect(vault.entry(id)!.fp, fp);
      // Без изменений и «Важный» как был — можно (ничего не сверяется).
      await vault.updateInfo(id, service: 'Почта', important: true);
      expect(vault.entry(id)!.service, 'Почта');
      expect(await kit.confirm(Canary.master), isTrue);
      await vault.updatePassword(id, secret('CANARY-new-Zz9'));
      await vault.updateNote(id, secret('CANARY-note-Nn1'));
      tearDownVault();
    });

    Future<void> replaceVia(String id, {required bool fromBackup}) async {
      final item = ImportItem(
        service: 'Почта',
        login: 'user@mail.example',
        urls: const <String>['https://mail.example'],
        password: secret('CANARY-imported-Q1'),
        sourceId: fromBackup ? id : null,
      );
      final match = vault.matchImport(
        <ImportItem>[item],
        byId: fromBackup,
      ).single;
      expect(match.existingId, id);
      final decisions = <ImportDecision>[
        ImportDecision(item, match, ImportChoice.replace),
      ];
      expect(kit.importNeedsConfirm(decisions), isTrue);
      final rev = await store.readVault();
      await expectLater(
        vault.importItems(decisions, fromBackup: fromBackup),
        throwsStateError,
      );
      // Атомарно: ничего не записано.
      expect(await store.readVault(), rev);
      expect(vault.entries.length, 2);
      expect(await kit.confirm(Canary.master), isTrue);
      expect(kit.importNeedsConfirm(decisions), isFalse);
      final done = await vault.importItems(decisions, fromBackup: fromBackup);
      expect(done.replaced, 1);
    }

    test('CSV: «заменить» охраняемую — StateError, после мастер-пароля — да',
        () async {
      final id = await setUpVault();
      await replaceVia(id, fromBackup: false);
      tearDownVault();
    });

    test('слияние копии: «из копии» охраняемую — тоже', () async {
      final id = await setUpVault();
      await replaceVia(id, fromBackup: true);
      tearDownVault();
    });

    testWidgets('редактор: правка важной спрашивает мастер-пароль',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final id = await setUpVault();
      await tester.pumpWidget(
        MaterialApp(
          theme: AssistantTheme.dark(),
          home: EntryEditorScreen(kit: kit, id: id),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('editor-service')),
        'canary',
      );
      await tester.tap(find.byKey(const ValueKey<String>('editor-save')));
      await tester.pumpAndSettle();
      expect(find.text('Важная запись'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(vault.entry(id)!.service, 'Почта');
      expect(find.textContaining('нужно подтвер'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('editor-save')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('master-dialog-field')),
        Canary.master,
      );
      await tester.tap(find.byKey(const ValueKey<String>('master-dialog-ok')));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(vault.entry(id)!.service, 'canary');
      expect(find.byType(EntryEditorScreen), findsNothing);
      tearDownVault();
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('удаление важной — после мастер-пароля (3.6)', () {
    void big(WidgetTester tester) {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    Future<void> enterMaster(WidgetTester tester) async {
      await tester.enterText(
        find.byKey(const ValueKey<String>('master-dialog-field')),
        Canary.master,
      );
      await tester.tap(find.byKey(const ValueKey<String>('master-dialog-ok')));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    test('хранилище: охраняемую — StateError, ничего не записано', () async {
      final id = await setUpVault();
      final before = await store.readVault();
      final facade = VaultFacade(vault);
      expect(facade.needsMaster(id), isTrue);
      await expectLater(vault.deleteEntry(id), throwsStateError);
      await expectLater(facade.delete(id), throwsStateError);
      expect(await store.readVault(), before);
      expect(vault.entry(id), isNotNull);
      // Обычную — без вопросов.
      final forum = vault.entries.firstWhere(
        (VaultEntry e) => e.service == 'Форум',
      );
      expect(facade.needsMaster(forum.id), isFalse);
      await vault.deleteEntry(forum.id);
      // После мастер-пароля — можно; окно кончилось — снова нельзя.
      expect(await kit.confirm(Canary.master), isTrue);
      expect(facade.needsMaster(id), isFalse);
      clock.advance(Vault.confirmWindow + const Duration(seconds: 1));
      await expectLater(vault.deleteEntry(id), throwsStateError);
      expect(await kit.confirm(Canary.master), isTrue);
      await vault.deleteEntry(id);
      expect(vault.entry(id), isNull);
      tearDownVault();
    });

    testWidgets('экран записи: «Удалить» спрашивает мастер-пароль',
        (WidgetTester tester) async {
      big(tester);
      final id = await setUpVault();
      await tester.pumpWidget(
        MaterialApp(
          theme: AssistantTheme.dark(),
          home: EntryScreen(kit: kit, id: id),
        ),
      );
      Future<void> askDelete() async {
        await tester.tap(find.byKey(const ValueKey<String>('entry-delete')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey<String>('entry-delete-confirm')),
        );
        await tester.pumpAndSettle();
      }

      await askDelete();
      expect(find.text('Удалить важную запись'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(vault.entry(id), isNotNull);
      expect(find.byType(EntryScreen), findsOneWidget);
      await askDelete();
      await enterMaster(tester);
      expect(vault.entry(id), isNull);
      tearDownVault();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('карточка чата: «Удалить» — мастер-пароль в окне, не в чат',
        (WidgetTester tester) async {
      big(tester);
      final id = await setUpVault();
      final sent = <String>[];
      // Ключ `secure-card-delete` и у самой карточки — нужна кнопка.
      final deleteButton = find.byWidgetPredicate(
        (Widget w) =>
            w is FilledButton &&
            w.key == const ValueKey<String>('secure-card-delete'),
      );
      final card = SecureCardRequest(
        kind: SecureCardKind.delete,
        entryIds: <String>[id],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AssistantTheme.dark(),
          home: Scaffold(
            body: SecureCardView(
              card: card,
              kit: kit,
              onCommand: (
                SecureCardRequest c,
                String action, {
                String? entryId,
                String? detail,
              }) =>
                  sent.add('$action:$entryId'),
            ),
          ),
        ),
      );
      await tester.tap(deleteButton);
      await tester.pumpAndSettle();
      expect(find.text('Удалить важную запись'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Отмена'),
        ),
      );
      await tester.pumpAndSettle();
      // Отменили — навыку ничего не ушло.
      expect(sent, isEmpty);
      await tester.tap(deleteButton);
      await tester.pumpAndSettle();
      await enterMaster(tester);
      expect(sent, <String>['${SecureCardCommand.delete}:$id']);
      // Окно подтверждения открыто — удаление теперь проходит.
      expect(VaultFacade(vault).needsMaster(id), isFalse);
      tearDownVault();
      await tester.pumpWidget(const SizedBox());
    });
  });
}
