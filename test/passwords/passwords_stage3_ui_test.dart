// Экраны и карточки этапа 3 (часть 1): генератор, лестница подсказок D27
// и «Проверить себя», тренировка, проверка, HintGuard и оценка в
// редакторе, значки и меню списка. Без golden-снимков (D24): только поиск
// канарейки в дереве виджетов; сгенерированные значения — тоже нигде,
// кроме маски и показа по кнопке.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/passwords/clipboard_guard.dart';
import 'package:local_assistant/app/passwords/entry_screens.dart';
import 'package:local_assistant/app/passwords/generator_view.dart';
import 'package:local_assistant/app/passwords/passwords_kit.dart';
import 'package:local_assistant/app/passwords/passwords_platform.dart';
import 'package:local_assistant/app/passwords/passwords_screen.dart';
import 'package:local_assistant/app/passwords/recall_views.dart';
import 'package:local_assistant/app/passwords/secure_card_view.dart';
import 'package:local_assistant/core/models/secure_card.dart';
import 'package:local_assistant/core/passwords/generator_options.dart';
import 'package:local_assistant/core/passwords/hint_guard.dart';
import 'package:local_assistant/core/passwords/keyboard_layouts.dart';
import 'package:local_assistant/core/passwords/vault.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_format.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';

import 'vault_test_support.dart';

void big(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Команда карточки (только имя действия и уточнение).
typedef _Command = (String action, String? entryId, String? detail);

void main() {
  late SodiumVaultCrypto crypto;

  setUpAll(() async {
    crypto = await testCrypto();
  });

  late Vault vault;
  late PasswordsKit kit;
  String? copied;

  void makeKit() {
    vault = testVault(InMemoryVaultStore(), crypto);
    copied = null;
    kit = PasswordsKit(
      vault: vault,
      platform: PasswordsPlatform.linux,
      kdfForTesting: fastKdf,
      wordlists: testWordlists(),
      clipboard: ClipboardGuard(
        platform: PasswordsPlatform.linux,
        cipher: crypto,
        write: (String text) async => copied = text,
        read: () async => copied,
      ),
    );
  }

  Future<String> seed({bool important = false, String? hint}) async {
    await vault.load();
    await vault.create(secret(Canary.master), params: fastKdf);
    return vault.addEntry(
      service: 'Почта',
      login: Canary.login,
      hint: hint ?? 'как в детстве',
      password: secret(Canary.password),
      note: secret(Canary.note),
      important: important,
    );
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

  Finder canary(String value) => find.textContaining(value, findRichText: true);

  Widget card(SecureCardRequest request, List<_Command> commands) => app(
        Scaffold(
          body: SingleChildScrollView(
            child: SecureCardView(
              card: request,
              kit: kit,
              onCommand: (
                SecureCardRequest c,
                String action, {
                String? entryId,
                String? detail,
              }) =>
                  commands.add((action, entryId, detail)),
            ),
          ),
        ),
      );

  /// Сгенерированное значение, если оно показано (иначе `null`).
  String? shownValue(WidgetTester tester) {
    final shown = find.byKey(const ValueKey<String>('secret-shown'));
    if (shown.evaluate().isEmpty) return null;
    final widget = tester.widget(shown);
    if (widget is Text) return widget.data ?? widget.textSpan?.toPlainText();
    return null;
  }

  group('генератор', () {
    testWidgets('карточка: значение в маске, показ по кнопке, стирается',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await vault.load();
      final commands = <_Command>[];
      await tester.pumpWidget(
        card(
          SecureCardRequest(
            kind: SecureCardKind.generate,
            options: const GeneratorOptions(
              mode: GeneratorMode.characters,
              length: 24,
            ).toJson(),
          ),
          commands,
        ),
      );
      await tester.pump();
      // Хранилища нет — генератор всё равно работает (5.4).
      expect(find.byKey(const ValueKey<String>('generator')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('secret-masked')), findsOne);
      expect(find.byKey(const ValueKey<String>('secret-shown')), findsNothing);
      expect(find.textContaining('~'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey<String>('secret-show')));
      await tester.pump();
      await tester.pump();
      final value = shownValue(tester);
      expect(value, isNotNull);
      expect(value!.length, 24);
      // 60 с — значение стёрто, в дереве его нет.
      await tester.pump(const Duration(seconds: 61));
      expect(find.byKey(const ValueKey<String>('generator-expired')), findsOne);
      expect(canary(value), findsNothing);
      expect(commands, isEmpty);
      await finish(tester);
    });

    testWidgets('режим «из слов» по умолчанию из карточки; «Ещё» меняет',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await vault.load();
      await tester.pumpWidget(
        card(
          SecureCardRequest(
            kind: SecureCardKind.generate,
            options: const GeneratorOptions().toJson(),
          ),
          <_Command>[],
        ),
      );
      await tester.pump();
      expect(
        find.textContaining('5 английских слов через дефис'),
        findsOneWidget,
      );
      expect(find.textContaining('высокая'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey<String>('secret-show')));
      await tester.pump();
      await tester.pump();
      final first = shownValue(tester)!;
      expect(RegExp(r'^[A-Za-z-]+\d\d$').hasMatch(first), isTrue);
      await tester.tap(find.byKey(const ValueKey<String>('generator-again')));
      await tester.pump();
      expect(canary(first), findsNothing);
      await finish(tester);
    });

    testWidgets('редактор: «Сгенерировать» подставляет пароль и подсказку',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await seed();
      await tester.pumpWidget(app(EntryEditorScreen(kit: kit, service: 'вк')));
      await tester.tap(find.byKey(const ValueKey<String>('editor-generate')));
      await tester.pumpAndSettle();
      expect(find.byType(GeneratorPanel), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('generator-use')));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('editor-password')),
          matching: find.byType(TextField),
        ),
      );
      final value = field.controller!.text;
      expect(value, isNotEmpty);
      expect(find.textContaining('Надёжность:'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('editor-structure-hint')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('editor-save')));
      await tester.pumpAndSettle();
      final saved = vault.entries.where((VaultEntry e) => e.service == 'Вк');
      expect(saved, hasLength(1));
      expect(saved.single.hint, startsWith('5 английских слов'));
      expect(saved.single.hint, isNot(contains(value)));
      await finish(tester);
    });

    testWidgets('«Сохранить для…» открывает редактор с паролем',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await seed();
      await tester.pumpWidget(app(Scaffold(body: GeneratorPanel(kit: kit))));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('generator-use')));
      await tester.pumpAndSettle();
      expect(find.byType(EntryEditorScreen), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey<String>('editor-service')),
        'Озон',
      );
      await tester.tap(find.byKey(const ValueKey<String>('editor-save')));
      await tester.pumpAndSettle();
      expect(
        vault.entries.map((VaultEntry e) => e.service),
        contains('Озон'),
      );
      await finish(tester);
    });
  });

  group('генератор: после редактора и крупный шрифт', () {
    testWidgets('«Сохранить для…», назад без сохранения — понятно и «Ещё»',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await seed();
      await tester.pumpWidget(app(Scaffold(body: GeneratorPanel(kit: kit))));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('generator-use')));
      await tester.pumpAndSettle();
      expect(find.byType(EntryEditorScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      // Не «мёртвая» маска: пояснение вместо неё, «Ещё» даёт новый.
      expect(find.byKey(const ValueKey<String>('generator-used')), findsOne);
      expect(find.byKey(const ValueKey<String>('secret-show')), findsNothing);
      await tester.tap(find.byKey(const ValueKey<String>('generator-again')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('generator-used')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey<String>('secret-show')));
      await tester.pump();
      await tester.pump();
      expect(shownValue(tester), isNotNull);
      final use = tester.widget<FilledButton>(
        find.byKey(const ValueKey<String>('generator-use')),
      );
      expect(use.onPressed, isNotNull);
      await finish(tester);
    });

    for (final size in <Size>[const Size(320, 640), const Size(390, 844)]) {
      testWidgets(
          'слова, ${size.width.toInt()}×${size.height.toInt()}, шрифт ×2: '
          'разделитель и режим не за краем', (WidgetTester tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        makeKit();
        await vault.load();
        // Экран генератора.
        await tester.pumpWidget(app(GeneratorScreen(kit: kit)));
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey<String>('generator-mode-words')),
        );
        await tester.pump();
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey<String>('generator-separator')),
          120,
          scrollable: find.byType(Scrollable).first,
        );
        expect(tester.takeException(), isNull);
        final dropdown = tester.getRect(
          find.byKey(const ValueKey<String>('generator-separator')),
        );
        expect(dropdown.right, lessThanOrEqualTo(size.width));
        // Карточка в чате (режим «слова» по умолчанию).
        await tester.pumpWidget(
          card(
            SecureCardRequest(
              kind: SecureCardKind.generate,
              options: const GeneratorOptions().toJson(),
            ),
            <_Command>[],
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        await finish(tester);
      });
    }
  });

  group('лестница подсказок и «Проверить себя»', () {
    testWidgets('ступени 2 и 3 — в истории только номер; ответы проверки',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      final id = await seed();
      final commands = <_Command>[];
      await tester.pumpWidget(
        card(
          SecureCardRequest(kind: SecureCardKind.hint, entryIds: <String>[id]),
          commands,
        ),
      );
      expect(find.text('как в детстве'), findsOneWidget);
      // Проверить себя: другая раскладка → «почти»; верно → «Верно».
      await tester.tap(find.byKey(const ValueKey<String>('hint-check-self')));
      await tester.pump();
      final layout = String.fromCharCodes(
        Canary.password.runes.map(KeyboardLayouts.swap),
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('recall-input')),
        layout,
      );
      await tester.tap(find.byKey(const ValueKey<String>('recall-check')));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('другой раскладке'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey<String>('recall-input')),
        Canary.password,
      );
      await tester.tap(find.byKey(const ValueKey<String>('recall-check')));
      await tester.pump();
      await tester.pump();
      expect(find.text('Верно.'), findsOneWidget);
      expect(canary(Canary.password), findsNothing);
      expect(find.byKey(const ValueKey<String>('hint-changed')), findsOne);
      // Ступень 2: длина и классы.
      await tester.tap(find.byKey(const ValueKey<String>('hint-stronger')));
      await tester.pump();
      await tester.pump();
      expect(
        find.textContaining('${Canary.password.length} символов'),
        findsOneWidget,
      );
      // Ступень 3: первый символ — маской, показ по кнопке.
      await tester.tap(find.byKey(const ValueKey<String>('hint-first')));
      await tester.pump();
      expect(
        commands.map((_Command c) => (c.$1, c.$3)),
        <(String, String?)>[
          (SecureCardCommand.hintStep, '2'),
          (SecureCardCommand.hintStep, '3'),
        ],
      );
      expect(canary(Canary.password), findsNothing);
      await finish(tester);
    });

    testWidgets('не оракул: после 5 попыток — пауза, без «насколько близко»',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      final id = await seed();
      await tester.pumpWidget(
        app(
          Scaffold(
            body: RecallField(
              kit: kit,
              entryId: id,
              onVerdict: (_) {},
            ),
          ),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.enterText(
          find.byKey(const ValueKey<String>('recall-input')),
          'CANARY-nope-$i',
        );
        await tester.tap(find.byKey(const ValueKey<String>('recall-check')));
        await tester.pump();
        await tester.pump();
        expect(find.text('Не совпадает.'), findsOneWidget);
      }
      await tester.enterText(
        find.byKey(const ValueKey<String>('recall-input')),
        Canary.password,
      );
      await tester.tap(find.byKey(const ValueKey<String>('recall-check')));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Слишком много попыток'), findsOneWidget);
      // Поле очищается сразу.
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('recall-input')),
          matching: find.byType(TextField),
        ),
      );
      expect(field.controller!.text, isEmpty);
      await finish(tester);
    });
  });

  group('тренировка', () {
    testWidgets('верно — серия и итог в историю без пароля',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      final id = await seed(important: true);
      final commands = <_Command>[];
      await tester.pumpWidget(
        card(
          SecureCardRequest(
            kind: SecureCardKind.training,
            entryIds: <String>[id],
          ),
          commands,
        ),
      );
      expect(find.textContaining('Вспомните пароль от «Почта»'), findsOne);
      await tester.enterText(
        find.byKey(const ValueKey<String>('recall-input')),
        Canary.password,
      );
      await tester.tap(find.byKey(const ValueKey<String>('recall-check')));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Серия 1'), findsOneWidget);
      expect(commands.single, (SecureCardCommand.trained, id, 'correct'));
      expect(vault.entry(id)!.train['streak'], 1);
      expect(canary(Canary.password), findsNothing);
      await finish(tester);
    });

    testWidgets('«Не сейчас» и «Больше не спрашивать»',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      final id = await seed(important: true);
      final commands = <_Command>[];
      await tester.pumpWidget(
        card(
          SecureCardRequest(
            kind: SecureCardKind.training,
            entryIds: <String>[id],
          ),
          commands,
        ),
      );
      await tester.tap(find.byKey(const ValueKey<String>('training-stop')));
      await tester.pump();
      await tester.pump();
      expect(commands.single.$3, 'stopped');
      expect(vault.entry(id)!.train['off'], isTrue);
      expect(vault.entry(id)!.important, isTrue);
      await finish(tester);
    });
  });

  group('проверка и список', () {
    Future<void> seedMany() async {
      await seed(hint: 'кличка barsik');
      await vault.addEntry(service: 'Форум', password: secret('qwerty123'));
      await vault.addEntry(service: 'Кино', password: secret(Canary.password));
      await vault.addEntry(
        service: 'Банк',
        password: secret('Zq8-barsik-Lm3'),
        hint: 'кличка barsik',
      );
    }

    testWidgets('карточка проверки: группы с названиями и «Сменить»',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await seedMany();
      await kit.audit();
      await tester.pumpWidget(
        card(
          SecureCardRequest(
            kind: SecureCardKind.check,
            entryIds: <String>[for (final e in vault.entries) e.id],
          ),
          <_Command>[],
        ),
      );
      expect(find.byKey(const ValueKey<String>('check-weak')), findsOne);
      expect(find.byKey(const ValueKey<String>('check-reused')), findsOne);
      expect(find.byKey(const ValueKey<String>('check-hint')), findsOne);
      expect(find.text('Форум'), findsWidgets);
      final banks =
          vault.entries.where((VaultEntry e) => e.service == 'Банк').single;
      await tester.tap(
        find.byKey(ValueKey<String>('check-change-${banks.id}')).first,
      );
      await tester.pumpAndSettle();
      expect(find.byType(EntryEditorScreen), findsOneWidget);
      expect(canary(Canary.password), findsNothing);
      await finish(tester);
    });

    testWidgets('список: значки; меню — генератор, проверка, тренировка',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await seedMany();
      await kit.audit();
      await tester.pumpWidget(app(PasswordsScreen(kit: kit)));
      final forum =
          vault.entries.where((VaultEntry e) => e.service == 'Форум').single;
      expect(find.byKey(ValueKey<String>('badge-weak-${forum.id}')), findsOne);
      final cinema =
          vault.entries.where((VaultEntry e) => e.service == 'Кино').single;
      expect(
        find.byKey(ValueKey<String>('badge-reused-${cinema.id}')),
        findsOne,
      );
      for (final (item, screen) in <(String, Type)>[
        ('passwords-menu-generator', GeneratorScreen),
        ('passwords-menu-check', CheckScreen),
        ('passwords-menu-training', TrainingScreen),
      ]) {
        await tester.tap(find.byKey(const ValueKey<String>('passwords-menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey<String>(item)));
        await tester.pumpAndSettle();
        expect(find.byType(screen), findsOneWidget, reason: item);
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
      expect(canary(Canary.password), findsNothing);
      await finish(tester);
    });
  });

  group('редактор: HintGuard и оценка', () {
    testWidgets('кусок пароля в подсказке (транслит) — не сохранить',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await seed();
      await tester.pumpWidget(app(EntryEditorScreen(kit: kit)));
      await tester.enterText(
        find.byKey(const ValueKey<String>('editor-service')),
        'Банк',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('editor-password')),
        'Sobaka#77xz',
      );
      // Оценка — после паузы в наборе (не на каждое нажатие).
      await tester.pump();
      expect(find.textContaining('Надёжность:'), findsNothing);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('Надёжность:'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey<String>('editor-hint')),
        'кличка собаки',
      );
      await tester.tap(find.byKey(const ValueKey<String>('editor-save')));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('кусок пароля'), findsOneWidget);
      expect(
        vault.entries.where((VaultEntry e) => e.service == 'Банк'),
        isEmpty,
      );
      await finish(tester);
    });

    testWidgets('повтор пароля: важные записи — не оракул без подтверждения',
        (WidgetTester tester) async {
      makeKit();
      await seed(important: true);
      await vault.addEntry(
        service: 'Форум',
        password: secret('CANARY-forum-Kp2'),
      );
      // Живое предупреждение (на каждое нажатие) важные не сравнивает и
      // попыток не тратит — сколько бы значений ни набрали.
      for (var i = 1; i <= Canary.password.length; i++) {
        expect(kit.sameAs(Canary.password.substring(0, i)), isEmpty);
      }
      for (var i = 0; i < 20; i++) {
        expect(kit.sameAs('CANARY-guess-$i'), isEmpty);
      }
      expect(
        kit.sameAs('CANARY-forum-Kp2').map((VaultEntry e) => e.service),
        <String>['Форум'],
      );
      // При сохранении — честный ответ; то же сохранение попыток не тратит.
      final first = await kit.reviewSave('', Canary.password);
      expect(first.same.map((VaultEntry e) => e.service), <String>['Почта']);
      expect(first.unchecked, isFalse);
      expect((await kit.reviewSave('', Canary.password)).same, hasLength(1));
      expect(
        (await kit.checkHint(Canary.password, 'Zx7#qQ!w2LmT')).block,
        HintProblem.equalsPassword,
      );
      for (var i = 0; i < 3; i++) {
        expect((await kit.reviewSave('', 'CANARY-guess-$i')).same, isEmpty);
      }
      // Пять разных сохранений за 10 минут — дальше важные не сравниваем,
      // и подсказку без мастер-пароля не сохранить, совпала она или нет:
      // предел не превращает запрет в «можно» и не отвечает «да/нет».
      // Уже сверенные догадки — бесплатно (ответ уже известен), новая —
      // нет: подсказку не сверить, повтор нового пароля не сообщается.
      final spent = await kit.reviewSave('Q9vmwz', 'CANARY-fresh-7');
      expect(spent.hint.block, HintProblem.needsConfirm);
      expect(spent.unchecked, isTrue);
      expect(
        (await kit.checkHint('кличка собаки', 'Zx7#qQ!w2LmT')).block,
        HintProblem.needsConfirm,
      );
      // Запрет по самому паролю записи — как прежде, раньше «подтвердите».
      expect(
        (await kit.checkHint('пароль Zx7#qQ!w2LmT', 'Zx7#qQ!w2LmT')).block,
        HintProblem.containsPassword,
      );
      // Уже сверенная догадка — тот же ответ; новая — не сверяется.
      expect((await kit.reviewSave('', Canary.password)).same, hasLength(1));
      final repeat = await kit.reviewSave('', 'CANARY-guess-9');
      expect(repeat.same, isEmpty);
      expect(repeat.unchecked, isTrue);
      // Обычные записи — как прежде (предупреждение о повторе по 5.3).
      expect(
        (await kit.reviewSave('', 'CANARY-forum-Kp2'))
            .same
            .map((VaultEntry e) => e.service),
        <String>['Форум'],
      );
      // Свежий мастер-пароль — снова честно, и живое предупреждение тоже.
      expect(await kit.confirm(Canary.master), isTrue);
      expect(kit.sameAs(Canary.password), hasLength(1));
      expect(
        (await kit.checkHint(Canary.password, 'Zx7#qQ!w2LmT')).block,
        HintProblem.equalsPassword,
      );
      vault.lock();
      kit.dispose();
    });

    testWidgets('подсказка из многих слов — не пачка догадок (15.2)',
        (WidgetTester tester) async {
      makeKit();
      await seed(important: true);
      final decoys = <String>[
        for (var i = 0; i < 20; i++) 'CANARY-decoy-$i',
      ];
      // Пачка с паролем важной записи и без него — один и тот же ответ
      // «нужен мастер-пароль», и попытки на это не тратятся.
      for (var round = 0; round < 8; round++) {
        final withSecret = <String>[...decoys]
          ..insert(round * 2, Canary.password);
        expect(
          (await kit.checkHint(withSecret.join(' '), '')).block,
          HintProblem.needsConfirm,
        );
        expect(
          (await kit.checkHint(decoys.join(' '), '')).block,
          HintProblem.needsConfirm,
        );
        expect(
          (await kit.checkHint('${Canary.password} собаки', '')).block,
          HintProblem.needsConfirm,
        );
      }
      expect(HintGuard.candidates(decoys.join(' ')), greaterThan(1));
      // Одна догадка за попытку — по-прежнему честно, и попыток ровно 5.
      expect(
        (await kit.checkHint(Canary.password, '')).block,
        HintProblem.equalsPassword,
      );
      for (var i = 0; i < 4; i++) {
        expect(
          (await kit.checkHint('CANARY-guess-$i', '')).block,
          isNull,
        );
      }
      expect(
        (await kit.checkHint('CANARY-guess-x', '')).block,
        HintProblem.needsConfirm,
      );
      // Длиннее предела (2001 слово) — отказ до любых сравнений.
      final huge = <String>[
        for (var i = 0; i < 2000; i++) 'CANARY-g$i',
        Canary.password,
      ].join(' ');
      expect(huge.length, greaterThan(HintGuard.maxHint));
      final tooLong = await kit.reviewSave(huge, 'Zx7#qQ!w2LmT');
      expect(tooLong.hint.block, HintProblem.tooLong);
      expect(tooLong.same, isEmpty);
      // С мастер-паролем пачку честно сверяют со всеми записями.
      expect(await kit.confirm(Canary.master), isTrue);
      expect(
        (await kit.checkHint('${Canary.password} собаки', '')).block,
        HintProblem.equalsPassword,
      );
      vault.lock();
      kit.dispose();
    });

    testWidgets('деление пополам: ответы не зависят от пароля в пачке',
        (WidgetTester tester) async {
      makeKit();
      await seed(important: true);
      // Атакующий: 64 догадки, пароль важной записи — среди них.
      final guesses = <String>[
        for (var i = 0; i < 64; i++) 'CANARY-cand-$i',
      ]..[37] = Canary.password;
      var range = guesses;
      final answers = <HintProblem?>{};
      while (range.length > 1) {
        final half = range.sublist(0, range.length ~/ 2);
        final verdict = await kit.checkHint(half.join(' '), '');
        // Одна догадка за попытку — честный ответ, это и есть предел.
        if (half.length > 1) answers.add(verdict.block);
        range = verdict.block == HintProblem.equalsPassword
            ? half
            : range.sublist(range.length ~/ 2);
      }
      // Каждый ответ на пачку — «нужен мастер-пароль»: деление ничего не
      // узнало и пришло не к паролю.
      expect(answers, <HintProblem?>{HintProblem.needsConfirm});
      expect(range.single, isNot(Canary.password));
      vault.lock();
      kit.dispose();
    });

    testWidgets('ключ попытки: пары «пароль + подсказка» не склеиваются',
        (WidgetTester tester) async {
      makeKit();
      await seed(important: true);
      for (var i = 0; i < 4; i++) {
        await kit.reviewSave('', 'CANARY-guess-$i');
      }
      final last = await kit.reviewSave('c', 'CANARY-a\u0000b');
      expect(last.unchecked, isFalse);
      // Прежнее склеивание через нулевой байт дало бы тот же ключ — и
      // бесплатную догадку `CANARY-a`.
      final glued = await kit.reviewSave('b\u0000c', 'CANARY-a');
      expect(glued.unchecked, isTrue);
      expect(glued.hint.block, HintProblem.needsConfirm);
      vault.lock();
      kit.dispose();
    });

    testWidgets('повтор важного: посимвольный ввод не съедает проверку',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await vault.load();
      await vault.create(secret(Canary.master), params: fastKdf);
      await vault.addEntry(
        service: 'Сбербанк',
        password: secret(Canary.password),
        important: true,
      );
      await tester.pumpWidget(app(EntryEditorScreen(kit: kit)));
      await tester.enterText(
        find.byKey(const ValueKey<String>('editor-service')),
        'Форум',
      );
      for (var i = 1; i <= Canary.password.length; i++) {
        await tester.enterText(
          find.byKey(const ValueKey<String>('editor-password')),
          Canary.password.substring(0, i),
        );
        await tester.pump();
      }
      // Живо — молчим (важная запись без подтверждения)…
      expect(find.textContaining('уже используется для'), findsNothing);
      // …а при сохранении предупреждаем; второй «Сохранить» сохраняет.
      await tester.tap(find.byKey(const ValueKey<String>('editor-save')));
      await tester.pump();
      await tester.pump();
      expect(
        find.textContaining('уже используется для: Сбербанк'),
        findsOneWidget,
      );
      expect(
        vault.entries.where((VaultEntry e) => e.service == 'Форум'),
        isEmpty,
      );
      await tester.tap(find.byKey(const ValueKey<String>('editor-save')));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(
        vault.entries.where((VaultEntry e) => e.service == 'Форум'),
        hasLength(1),
      );
      // Новая запись: подсказка = пароль «Сбербанка» — не сохранить.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(app(EntryEditorScreen(kit: kit)));
      await tester.enterText(
        find.byKey(const ValueKey<String>('editor-service')),
        'Почта 2',
      );
      for (final value in <String>['Z', 'Zx', 'Zx7#', 'Zx7#qQ!w2LmT']) {
        await tester.enterText(
          find.byKey(const ValueKey<String>('editor-password')),
          value,
        );
        await tester.pump();
      }
      await tester.enterText(
        find.byKey(const ValueKey<String>('editor-hint')),
        Canary.password,
      );
      await tester.tap(find.byKey(const ValueKey<String>('editor-save')));
      await tester.pump();
      await tester.pump();
      expect(
        find.textContaining('пароль одной из записей'),
        findsOneWidget,
      );
      expect(
        vault.entries.where((VaultEntry e) => e.service == 'Почта 2'),
        isEmpty,
      );
      await finish(tester);
    });

    testWidgets('кончились попытки — подсказка только с мастер-паролем',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      await vault.load();
      await vault.create(secret(Canary.master), params: fastKdf);
      await vault.addEntry(
        service: 'Сбербанк',
        password: secret(Canary.password),
        important: true,
      );
      for (var i = 0; i < 5; i++) {
        await kit.reviewSave('', 'CANARY-guess-$i');
      }
      await tester.pumpWidget(app(EntryEditorScreen(kit: kit)));
      await tester.enterText(
        find.byKey(const ValueKey<String>('editor-service')),
        'Почта 2',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('editor-password')),
        'Zx7#qQ!w2LmT',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('editor-hint')),
        Canary.password,
      );
      await tester.tap(find.byKey(const ValueKey<String>('editor-save')));
      await tester.pumpAndSettle();
      expect(find.text('Проверить подсказку'), findsOneWidget);
      // Отмена — не сохранено.
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(
        vault.entries.where((VaultEntry e) => e.service == 'Почта 2'),
        isEmpty,
      );
      expect(find.textContaining('Подтвердите мастер-паролем'), findsOneWidget);
      // С мастер-паролем — честная проверка: подсказка — пароль записи.
      await tester.tap(find.byKey(const ValueKey<String>('editor-save')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('master-dialog-field')),
        Canary.master,
      );
      await tester.tap(find.byKey(const ValueKey<String>('master-dialog-ok')));
      await tester.pumpAndSettle();
      expect(find.textContaining('пароль одной из записей'), findsOneWidget);
      expect(
        vault.entries.where((VaultEntry e) => e.service == 'Почта 2'),
        isEmpty,
      );
      await finish(tester);
    });

    testWidgets('мастер-пароль: слабый не принимается при словарях',
        (WidgetTester tester) async {
      big(tester);
      makeKit();
      expect(
        masterProblem('qwerty123456', strength: kit.strength),
        contains('Слишком легко подобрать'),
      );
      expect(
        masterProblem(
          'quarry-velvet-mantis-cobalt',
          strength: kit.strength,
        ),
        isNull,
      );
      // Одно слово четыре раза — не фраза из четырёх слов.
      for (final weak in <String>[
        'able-able-able-able',
        'acid acid acid acid',
      ]) {
        expect(
          masterProblem(weak, strength: kit.strength),
          contains('Слишком легко подобрать'),
        );
      }
      // Повторы без учёта регистра, повтор нескольких слов, слово со
      // счётчиком, повтор куска символов — отказ (и без словарей — по
      // повтору слова).
      for (final weak in <String>[
        'Able-able-ABLE-able',
        'able-acid-able-acid',
        'able1-able2-able3-able4',
        'Qwerty1!Qwerty1!',
        'abcABCabcABC123',
        'able-acid-bake-able-acid-bake',
        'cork-dart-quarry-velvet-cork',
      ]) {
        expect(
          masterProblem(weak, strength: kit.strength),
          isNotNull,
          reason: weak,
        );
      }
      for (final weak in <String>[
        'Able-able-ABLE-able',
        'able1-able2-able3-able4',
        'able-acid-bake-able-acid-bake',
      ]) {
        expect(masterProblem(weak), contains('не должны повторяться'));
      }
      // Настоящие фразы из 5 разных слов и случайные 16+ символов — да.
      for (final good in <String>[
        'quarry-velvet-mantis-cobalt-pebble',
        'Quarry.velvet.Mantis.cobalt.pebble7',
        'Kp3vXr9Lm2QwZt7N',
        'gTq7-Lp2x-Wm9v-Rk3s-Hn6c',
      ]) {
        expect(
          masterProblem(good, strength: kit.strength),
          isNull,
          reason: good,
        );
      }
      kit.dispose();
    });
  });
}
