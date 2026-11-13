// Хронология паролей в интерфейсе (ADR-015): флажок в настройках
// (включение с мастер-паролем, выключение с вопросом «удалить или
// оставить»), «Прежние пароли (N)» в карточке записи — показ, удаление
// опечатки, очистка. Пароли — только синтетические канарейки.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/passwords/clipboard_guard.dart';
import 'package:local_assistant/app/passwords/entry_screens.dart';
import 'package:local_assistant/app/passwords/passwords_kit.dart';
import 'package:local_assistant/app/passwords/passwords_platform.dart';
import 'package:local_assistant/app/passwords/passwords_settings_screen.dart';
import 'package:local_assistant/core/passwords/vault.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_format.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';

import 'vault_test_support.dart';

const String _first = 'CANARY-hist-ui-1';
const String _second = 'CANARY-hist-ui-2';
const String _third = 'CANARY-hist-ui-3';

void main() {
  late SodiumVaultCrypto crypto;

  setUpAll(() async {
    crypto = await testCrypto();
  });

  late Vault vault;
  late PasswordsKit kit;

  void big(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  void makeKit() {
    vault = testVault(InMemoryVaultStore(), crypto);
    kit = PasswordsKit(
      vault: vault,
      platform: PasswordsPlatform.linux,
      kdfForTesting: fastKdf,
      clipboard: ClipboardGuard(
        platform: PasswordsPlatform.linux,
        cipher: crypto,
        write: (String _) async {},
        read: () async => null,
      ),
    );
  }

  /// Запись «Почта» с паролем [_first]; с [history] — опция включена и
  /// пароль дважды сменён (прежние: [_second], [_first]).
  Future<String> seed({bool history = false}) async {
    await vault.load();
    await vault.create(secret(Canary.master), params: fastKdf);
    final id = await vault.addEntry(
      service: 'Почта',
      login: Canary.login,
      password: secret(_first),
    );
    if (history) {
      await vault.setPrefs(
        <String, Object?>{'pw_history': true},
        master: secret(Canary.master),
      );
      await vault.updatePassword(id, secret(_second));
      await vault.updatePassword(id, secret(_third));
    }
    return id;
  }

  Widget app(Widget home) => MaterialApp(
        theme: AssistantTheme.dark(),
        home: home,
      );

  Future<void> finish(WidgetTester tester) async {
    vault.lock();
    await tester.pumpWidget(const SizedBox.shrink());
    kit.dispose();
  }

  Finder key(String value) => find.byKey(ValueKey<String>(value));

  Finder canary(String value) => find.textContaining(value, findRichText: true);

  group('настройки', () {
    testWidgets('включение — только с мастер-паролем',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await seed();
      await tester.pumpWidget(app(PasswordsSettingsScreen(kit: kit)));
      expect(find.text('Хранить прежние пароли (хронология)'), findsOneWidget);
      await tester.tap(key('prefs-pw_history'));
      await tester.pumpAndSettle();
      expect(find.text('Хранить прежние пароли?'), findsOneWidget);
      await tester.enterText(key('master-dialog-field'), 'CANARY-wrong-h');
      await tester.tap(key('master-dialog-ok'));
      await tester.pumpAndSettle();
      expect(find.text('Мастер-пароль не подошёл.'), findsOneWidget);
      expect(vault.historyEnabled, isFalse);
      await tester.enterText(key('master-dialog-field'), Canary.master);
      await tester.tap(key('master-dialog-ok'));
      await tester.pumpAndSettle();
      expect(vault.historyEnabled, isTrue);
      expect(
        tester.widget<SwitchListTile>(key('prefs-pw_history')).value,
        isTrue,
      );
      await finish(tester);
    });

    testWidgets('выключение: «Оставить» — сохранённое на месте',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      final id = await seed(history: true);
      await tester.pumpWidget(app(PasswordsSettingsScreen(kit: kit)));
      await tester.tap(key('prefs-pw_history'));
      await tester.pumpAndSettle();
      expect(
        find.text('Удалить сохранённые прежние пароли всех записей?'),
        findsOneWidget,
      );
      await tester.tap(key('prefs-history-keep'));
      await tester.pumpAndSettle();
      expect(vault.historyEnabled, isFalse);
      expect(vault.entry(id)!.history, hasLength(2));
      await finish(tester);
    });

    testWidgets('выключение: «Удалить» — прежние пароли стёрты',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      final id = await seed(history: true);
      await tester.pumpWidget(app(PasswordsSettingsScreen(kit: kit)));
      await tester.tap(key('prefs-pw_history'));
      await tester.pumpAndSettle();
      await tester.tap(key('prefs-history-purge'));
      await tester.pumpAndSettle();
      expect(vault.historyEnabled, isFalse);
      expect(vault.entry(id)!.history, isEmpty);
      expect(vault.historyCount, 0);
      await finish(tester);
    });
  });

  group('карточка записи', () {
    testWidgets('опция выключена и пусто — раздела нет',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      final id = await seed();
      await tester.pumpWidget(app(EntryScreen(kit: kit, id: id)));
      expect(key('entry-history'), findsNothing);
      expect(find.textContaining('Прежние пароли'), findsNothing);
      await finish(tester);
    });

    testWidgets('список, показ, удаление опечатки и очистка',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      final id = await seed(history: true);
      final history = vault.entry(id)!.history;
      await tester.pumpWidget(app(EntryScreen(kit: kit, id: id)));
      expect(find.text('Прежние пароли (2)'), findsOneWidget);
      await tester.tap(find.text('Прежние пароли (2)'));
      await tester.pumpAndSettle();
      // Смены шли подряд: обе похожи на опечатку.
      expect(
        find.text('Использовался меньше часа — похоже на опечатку.'),
        findsNWidgets(2),
      );
      expect(canary('CANARY'), findsNothing);
      // Показ — по кнопке, в маске до неё.
      final row = key('entry-history-${history.first.id}');
      await tester.tap(
        find.descendant(of: row, matching: key('secret-show')),
      );
      await tester.pump();
      await tester.pump();
      expect(canary(_second), findsOneWidget);
      expect(canary(_first), findsNothing);
      expect(canary(_third), findsNothing);
      await tester.pump(const Duration(seconds: 16));
      expect(canary(_second), findsNothing);
      // Удалить опечатку: подтверждение, затем нет ни строки, ни коробки.
      await tester.tap(key('entry-history-delete-${history.first.id}'));
      await tester.pumpAndSettle();
      expect(find.text('Удалить этот пароль из хронологии?'), findsOneWidget);
      expect(
        find.textContaining('Вернуть можно только из резервной копии.'),
        findsOneWidget,
      );
      // Архивы сейфа правка не трогает — диалог об этом говорит.
      expect(find.textContaining('архивах сейфа'), findsOneWidget);
      await tester.tap(key('entry-history-confirm'));
      await tester.pumpAndSettle();
      expect(vault.entry(id)!.history.map((h) => h.id), <String>[
        history.last.id,
      ]);
      expect(find.text('Прежние пароли (1)'), findsOneWidget);
      // Очистить всё.
      await tester.tap(key('entry-history-clear'));
      await tester.pumpAndSettle();
      await tester.tap(key('entry-history-confirm'));
      await tester.pumpAndSettle();
      expect(vault.entry(id)!.history, isEmpty);
      expect(find.text('Прежние пароли (0)'), findsOneWidget);
      expect(canary('CANARY'), findsNothing);
      await finish(tester);
    });

    testWidgets('отмена удаления — ничего не меняется',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      final id = await seed(history: true);
      await tester.pumpWidget(app(EntryScreen(kit: kit, id: id)));
      await tester.tap(find.text('Прежние пароли (2)'));
      await tester.pumpAndSettle();
      await tester.tap(key('entry-history-clear'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(vault.entry(id)!.history, hasLength(2));
      await finish(tester);
    });
  });

  group('даты элемента', () {
    final from = DateTime(2026, 11, 10, 9);
    test('в один день — со временем', () {
      expect(
        historyPeriodText(
          HistoryMeta(
            id: 'a' * 32,
            from: from,
            to: from.add(const Duration(minutes: 10)),
            src: DateSource.user,
          ),
        ),
        '10.11.2026, 09:00–09:10',
      );
    });
    test('разные дни — «с … по …»', () {
      expect(
        historyPeriodText(
          HistoryMeta(
            id: 'a' * 32,
            from: from,
            to: DateTime(2026, 11, 13, 9),
            src: DateSource.import,
          ),
        ),
        'с 10.11.2026 по 13.11.2026',
      );
    });
    test('дата начала неизвестна (CSV без дат) — только «до …»', () {
      expect(
        historyPeriodText(
          HistoryMeta(
            id: 'a' * 32,
            from: from,
            to: from.add(const Duration(minutes: 10)),
          ),
        ),
        'до 10.11.2026',
      );
    });
  });
}
