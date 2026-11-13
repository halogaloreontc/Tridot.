// Экраны импорта CSV и резервной копии (ADR-014, 5.6, 5.7, 15.6 ж): файлы
// — через подменённый PasswordFiles, пароли — канарейки. Без golden-
// снимков (D24): канареек паролей нет в дереве виджетов ни на одном шаге.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/assistant_theme.dart';
import 'package:local_assistant/app/passwords/backup_screens.dart';
import 'package:local_assistant/app/passwords/clipboard_guard.dart';
import 'package:local_assistant/app/passwords/import_screen.dart';
import 'package:local_assistant/app/passwords/passwords_files.dart';
import 'package:local_assistant/app/passwords/passwords_kit.dart';
import 'package:local_assistant/app/passwords/passwords_platform.dart';
import 'package:local_assistant/app/passwords/passwords_screen.dart';
import 'package:local_assistant/app/passwords/secure_card_view.dart';
import 'package:local_assistant/core/models/secure_card.dart';
import 'package:local_assistant/core/passwords/password_audit.dart';
import 'package:local_assistant/core/passwords/vault.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_format.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';

import 'vault_test_support.dart';

/// Файлы в памяти вместо выбора на диске.
final class FakeFiles implements PasswordFiles {
  final Map<String, Uint8List> disk = <String, Uint8List>{};
  String? next;

  @override
  bool get canDelete => true;

  @override
  String get placeNote => 'Файл — в «Загрузках».';

  @override
  Future<PickedFile?> open(
    BuildContext context, {
    required String title,
    required List<String> extensions,
    required int maxBytes,
  }) async {
    final path = next;
    final bytes = path == null ? null : disk[path];
    if (path == null || bytes == null) return null;
    if (bytes.length > maxBytes) throw const FileTooLarge();
    return PickedFile(path: path, bytes: Uint8List.fromList(bytes));
  }

  @override
  Future<String?> save(
    BuildContext context, {
    required String title,
    required String fileName,
    required Uint8List bytes,
  }) async {
    final path = '/fake/$fileName';
    disk[path] = Uint8List.fromList(bytes);
    return path;
  }

  @override
  Future<Uint8List?> read(String path) async => disk[path];

  @override
  Future<bool> delete(String path) async => disk.remove(path) != null;
}

void big(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2600);
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
  late FakeFiles files;

  PasswordsKit makeKit(Vault forVault, FakeFiles withFiles) => PasswordsKit(
        vault: forVault,
        platform: PasswordsPlatform.linux,
        kdfForTesting: fastKdf,
        wordlists: testWordlists(),
        files: withFiles,
        clipboard: ClipboardGuard(
          platform: PasswordsPlatform.linux,
          cipher: crypto,
          write: (String text) async {},
          read: () async => null,
        ),
      );

  Future<void> setUpKit({bool open = true}) async {
    vault = testVault(InMemoryVaultStore(), crypto);
    files = FakeFiles();
    kit = makeKit(vault, files);
    await vault.load();
    if (open) await vault.create(secret(Canary.master), params: fastKdf);
  }

  Widget app(Widget home) =>
      MaterialApp(theme: AssistantTheme.dark(), home: home);

  Finder text(String value) => find.textContaining(value, findRichText: true);

  void expectNoCanary(List<String> values) {
    for (final value in values) {
      expect(text(value), findsNothing, reason: value);
    }
  }

  Future<void> finish(WidgetTester tester, [PasswordsKit? other]) async {
    vault.lock();
    await tester.pumpWidget(const SizedBox.shrink());
    kit.dispose();
    other?.dispose();
  }

  /// Экран [screen] поверх пустого первого — как его открывает приложение.
  Future<void> pushOver(WidgetTester tester, Widget screen) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: AssistantTheme.dark(),
        navigatorKey: nav,
        home: const Scaffold(),
      ),
    );
    unawaited(
      nav.currentState!.push(
        MaterialPageRoute<void>(builder: (BuildContext context) => screen),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Узкий экран и крупный шрифт: переполнение строк — ошибка теста.
  void small(WidgetTester tester, {Size size = const Size(320, 640)}) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  /// Кнопка ниже края узкого экрана: прокрутить к ней и нажать.
  Future<void> tapFar(WidgetTester tester, String key) async {
    final target = find.byKey(ValueKey<String>(key));
    await tester.scrollUntilVisible(
      target,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pump();
    await tester.pump();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey<String>(key)));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('CSV из Chrome: предпросмотр без паролей, импорт, удаление',
      (WidgetTester tester) async {
    big(tester);
    await setUpKit();
    await vault.addEntry(
      service: 'Почта',
      login: 'canary@example.org',
      password: secret('CANARY-pw-old-mail'),
    );
    files.disk['/dl/passwords.csv'] = Uint8List.fromList(
      utf8.encode(
        'name,url,username,password,note\n'
        'Почта,https://mail.example,canary@example.org,CANARY-pw-csv1,'
        'CANARY-note-csv1\n'
        'Форум,https://forum.example,canary,CANARY-pw-csv2,\n'
        'Пустой,https://empty.example,canary,,\n',
      ),
    );
    files.next = '/dl/passwords.csv';
    await tester.pumpWidget(app(CsvImportScreen(kit: kit)));
    await tapKey(tester, 'import-pick');
    expect(text('Нашёл 2: новых 1, дублей 0, с другим паролем 1.'), findsOne);
    expect(text('Пропущено 1: без пароля 1'), findsOne);
    expect(text('дубль с другим паролем'), findsOne);
    expect(text('Оставить обе'), findsOne);
    expectNoCanary(<String>['CANARY-pw-csv1', 'CANARY-pw-csv2', 'CANARY-note']);
    // Логин — в маске.
    expect(text('ca***@example.org'), findsOne);
    await tapKey(tester, 'import-confirm');
    expect(text('Импортировано: новых 2, заменено 0.'), findsOne);
    expect(vault.entries.length, 3);
    expect(
      vault.entries.where((e) => e.flags.contains(EntryFlags.importConflict)),
      hasLength(1),
    );
    await tapKey(tester, 'import-delete-csv');
    expect(files.disk.containsKey('/dl/passwords.csv'), isFalse);
    expect(find.byKey(const ValueKey<String>('import-deleted')), findsOne);
    expectNoCanary(<String>['CANARY-pw-csv1', 'CANARY-pw-csv2']);
    await finish(tester);
  });

  testWidgets('ручное сопоставление: пароли в «Названии» не видны, отказ',
      (WidgetTester tester) async {
    big(tester);
    await setUpKit();
    final rows = StringBuffer('a;b;c\n');
    for (var i = 0; i < 4; i++) {
      rows.writeln('CANARY-pw-Nm$i!;https://s$i.example;CANARY-pw-Nm$i!');
    }
    files.disk['/dl/x.csv'] = Uint8List.fromList(utf8.encode('$rows'));
    files.next = '/dl/x.csv';
    await tester.pumpWidget(app(CsvImportScreen(kit: kit)));
    await tapKey(tester, 'import-pick');
    expect(
      find.byKey(const ValueKey<String>('import-role-password')),
      findsOne,
    );
    expectNoCanary(<String>['CANARY-pw-Nm', 'pw-Nm', 'Nm0']);
    // Пароль — колонка 3, «Название» — колонка 1.
    await tester
        .tap(find.byKey(const ValueKey<String>('import-role-password')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Колонка 3').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('import-role-service')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Колонка 1').last);
    await tester.pumpAndSettle();
    expectNoCanary(<String>['CANARY-pw-Nm', 'pw-Nm']);
    await tapKey(tester, 'import-mapping-next');
    expect(text('Похоже, в колонке «Название» лежат пароли'), findsOne);
    expectNoCanary(<String>['CANARY-pw-Nm', 'pw-Nm']);
    expect(vault.entries, isEmpty);
    await finish(tester);
  });

  testWidgets('копия: мастер-пароль, проверка, файл без канареек',
      (WidgetTester tester) async {
    big(tester);
    await setUpKit();
    await vault.addEntry(
      service: 'Почта',
      login: Canary.login,
      password: secret(Canary.password),
      note: secret(Canary.note),
    );
    await tester.pumpWidget(app(BackupExportScreen(kit: kit)));
    await tester.enterText(
      find.byKey(const ValueKey<String>('backup-master')),
      'CANARY-wrong-m',
    );
    await tapKey(tester, 'backup-make');
    expect(text('Мастер-пароль не подошёл.'), findsOne);
    expect(files.disk, isEmpty);
    // Отдельный пароль копии — с требованиями мастер-пароля.
    await tester.enterText(
      find.byKey(const ValueKey<String>('backup-master')),
      Canary.master,
    );
    await tapKey(tester, 'backup-own');
    await tester.enterText(
      find.byKey(const ValueKey<String>('backup-separate')),
      'qwerty123456',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('backup-repeat')),
      'qwerty123456',
    );
    await tapKey(tester, 'backup-make');
    expect(text('Слишком легко подобрать'), findsOne);
    expect(files.disk, isEmpty);
    await tapKey(tester, 'backup-own');
    await tester.enterText(
      find.byKey(const ValueKey<String>('backup-master')),
      Canary.master,
    );
    await tapKey(tester, 'backup-make');
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('backup-done')), findsOne);
    final saved = files.disk.entries.single;
    expect(saved.key, endsWith('.relaybak'));
    for (final canary in <String>[...Canary.secrets, Canary.login]) {
      for (final form in Canary.encodings(canary)) {
        expect(containsBytes(saved.value, form), isFalse, reason: canary);
      }
    }
    expect(vault.lastBackupAt, isNotNull);
    await finish(tester);
  });

  testWidgets('новое устройство: «Восстановить из копии» на экране создания',
      (WidgetTester tester) async {
    big(tester);
    await setUpKit();
    await vault.addEntry(service: 'Почта', password: secret(Canary.password));
    final bytes = await kit.exportBackup(Canary.master);

    final device = testVault(InMemoryVaultStore(), crypto);
    await device.load();
    final deviceFiles = FakeFiles()
      ..disk['/dl/copy.relaybak'] = bytes
      ..next = '/dl/copy.relaybak';
    final deviceKit = makeKit(device, deviceFiles)
      ..syncSettings(seenRev: 40, vaultExisted: true);
    await tester.pumpWidget(app(PasswordsScreen(kit: deviceKit)));
    expect(find.byKey(const ValueKey<String>('passwords-not-found')), findsOne);
    await tester.tap(find.byKey(const ValueKey<String>('passwords-restore')));
    await tester.pumpAndSettle();
    await tapKey(tester, 'restore-pick');
    await tester.enterText(
      find.byKey(const ValueKey<String>('restore-pass')),
      'CANARY-wrong-p',
    );
    await tapKey(tester, 'restore-open');
    expect(text('Пароль копии не подошёл.'), findsOne);
    await tester.enterText(
      find.byKey(const ValueKey<String>('restore-pass')),
      Canary.master,
    );
    await tapKey(tester, 'restore-open');
    expect(text('В копии 1 запись.'), findsOne);
    // Пароль копии слабоват для мастер-пароля — просим новый.
    await tapKey(tester, 'restore-create');
    await tester.pumpAndSettle();
    expect(text('Пароль копии слабоват для мастер-пароля'), findsOne);
    expect(device.state, VaultState.notCreated);
    const strong = 'CANARY-Vq8#mT2!zK9pL-wR4';
    await tester.enterText(
      find.byKey(const ValueKey<String>('restore-master')),
      strong,
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('restore-repeat')),
      strong,
    );
    await tapKey(tester, 'restore-create');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('restore-done')), findsOne);
    expect(device.isUnlocked, isTrue);
    expect(device.entries.single.service, 'Почта');
    // Новое хранилище — свой отсчёт версий: отката нет.
    expect(deviceKit.seenRev, device.rev);
    expectNoCanary(<String>[Canary.password, Canary.master, strong]);
    device.lock();
    await device.unlock(secret(strong));
    device.lock();
    await finish(tester, deviceKit);
  });

  testWidgets('слияние и «Заменить всё» (кнопка + мастер-пароль)',
      (WidgetTester tester) async {
    big(tester);
    await setUpKit();
    await vault.addEntry(service: 'Почта', password: secret(Canary.password));
    final bytes = await kit.exportBackup(Canary.master);
    final forum = await vault.addEntry(
      service: 'Форум',
      password: secret('CANARY-pw2-Lm5'),
    );
    files
      ..disk['/dl/copy.relaybak'] = bytes
      ..next = '/dl/copy.relaybak';
    // Как в приложении: экран поверх другого (из меню списка или карточки).
    // На миг замены хранилище запирается — экран с итогом не закрывается.
    await pushOver(tester, BackupRestoreScreen(kit: kit));
    await tapKey(tester, 'restore-pick');
    await tester.enterText(
      find.byKey(const ValueKey<String>('restore-pass')),
      Canary.master,
    );
    await tapKey(tester, 'restore-open');
    expect(text('такая же'), findsOne);
    expect(text('В копии 1 запись.'), findsOne);
    await tester.tap(find.byKey(const ValueKey<String>('restore-replace')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('restore-replace-go')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('master-dialog-field')),
      Canary.master,
    );
    await tester.tap(find.byKey(const ValueKey<String>('master-dialog-ok')));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byType(BackupRestoreScreen), findsOne);
    expect(find.byKey(const ValueKey<String>('restore-done')), findsOne);
    expect(text('Сейф заменён копией. Прежний — в архиве.'), findsOne);
    expect(vault.isUnlocked, isTrue);
    expect(vault.entries.single.service, 'Почта');
    expect(vault.entry(forum), isNull);
    expect(await vault.store.archived(), hasLength(1));
    expectNoCanary(<String>[Canary.password, 'CANARY-pw2-Lm5']);
    await finish(tester);
  });

  testWidgets('карточки: импорт и копия — кнопки; восстановление без хранилища',
      (WidgetTester tester) async {
    big(tester);
    await setUpKit(open: false);
    Widget cardOf(SecureCardKind kind) => app(
          Scaffold(
            body: SecureCardView(
              card: SecureCardRequest(kind: kind),
              kit: kit,
              onCommand: (
                SecureCardRequest c,
                String action, {
                String? entryId,
                String? detail,
              }) {},
            ),
          ),
        );
    await tester.pumpWidget(cardOf(SecureCardKind.restore));
    expect(
      find.byKey(const ValueKey<String>('secure-card-restore-open')),
      findsOne,
    );
    expect(
      find.byKey(const ValueKey<String>('secure-card-backup-open')),
      findsNothing,
    );
    await vault.create(secret(Canary.master), params: fastKdf);
    await tester.pumpWidget(cardOf(SecureCardKind.importPreview));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('secure-card-import-open')),
      findsOne,
    );
    await tester.pumpWidget(cardOf(SecureCardKind.backup));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('secure-card-backup-open')),
      findsOne,
    );
    vault.lock();
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('secure-card-backup-open')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey<String>('secure-card-open')), findsOne);
    await finish(tester);
  });

  testWidgets(
      'предпросмотр CSV: 320×640, шрифт ×2 — кнопка видна, без переполнения',
      (WidgetTester tester) async {
    small(tester);
    await setUpKit();
    final rows = StringBuffer('name,url,username,password\n')
      ..writeln('Пустой,https://empty.example,canary,')
      ..writeln('Злой,javascript:alert(1),canary,CANARY-pw-js');
    for (var i = 0; i < 40; i++) {
      rows.writeln('Сайт$i\u202E,https://s$i.example,canary,CANARY-pw-r$i');
    }
    rows.writeln('Форум,https://forum.example,canary,CANARY-pw-ok');
    files
      ..disk['/dl/p.csv'] = Uint8List.fromList(utf8.encode('$rows'))
      ..next = '/dl/p.csv';
    await tester.pumpWidget(app(CsvImportScreen(kit: kit)));
    await tapFar(tester, 'import-pick');
    // Замечания раскрыты — всё равно без переполнения.
    final errors = find.textContaining('Строки с замечаниями');
    await tester.ensureVisible(errors);
    await tester.pumpAndSettle();
    await tester.tap(errors);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final confirm = find.byKey(const ValueKey<String>('import-confirm'));
    expect(confirm.hitTestable(), findsOne);
    await tester.tap(confirm);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('import-done')), findsOne);
    expect(
      vault.entries.map((VaultEntry e) => e.service),
      unorderedEquals(<String>['Злой', 'Форум']),
    );
    expectNoCanary(<String>['CANARY-pw']);
    await finish(tester);
  });

  testWidgets('выбор варианта пароля: строка влезает, число без «5 пароля»',
      (WidgetTester tester) async {
    small(tester, size: const Size(390, 844));
    await setUpKit();
    final rows = StringBuffer('name,url,username,password\n');
    for (var i = 0; i < 5; i++) {
      rows.writeln('Почта,https://mail.example,canary,CANARY-pw-v$i');
    }
    files
      ..disk['/dl/v.csv'] = Uint8List.fromList(utf8.encode('$rows'))
      ..next = '/dl/v.csv';
    await tester.pumpWidget(app(CsvImportScreen(kit: kit)));
    await tapFar(tester, 'import-pick');
    expect(find.byKey(const ValueKey<String>('import-variant-0')), findsOne);
    expect(tester.takeException(), isNull);
    expect(text('Вариант 1 из 5'), findsOne);
    expect(text('пароля'), findsNothing);
    expect(importVariantTitle(5, 1, null), 'Вариант 2 из 5 · дата неизвестна');
    expectNoCanary(<String>['CANARY-pw']);
    await finish(tester);
  });

  testWidgets('Windows-1251: шрифт ×2 без переполнения, пароль без примера',
      (WidgetTester tester) async {
    small(tester, size: const Size(390, 844));
    await setUpKit();
    // «Почта» в Windows-1251: не UTF-8.
    final cp = <int>[0xCF, 0xEE, 0xF7, 0xF2, 0xE0];
    files
      ..disk['/dl/w.csv'] = Uint8List.fromList(<int>[
        ...utf8.encode('name,url,username,password\n'),
        ...cp,
        ...utf8.encode(',https://mail.example,canary,CANARY-pw-1251\n'),
      ])
      ..next = '/dl/w.csv';
    await tester.pumpWidget(app(CsvImportScreen(kit: kit)));
    await tapFar(tester, 'import-pick');
    expect(find.byKey(const ValueKey<String>('import-cp1251')), findsOne);
    expect(tester.takeException(), isNull);
    // Первые символы пароля не показываются даже в маске.
    expect(text('CA•••'), findsNothing);
    expect(text('скрыт'), findsOne);
    expect(text('По•••'), findsOne);
    expectNoCanary(<String>['CANARY-pw-1251']);
    await finish(tester);
  });

  testWidgets('ручное сопоставление: шрифт ×2, подписи не рвутся',
      (WidgetTester tester) async {
    small(tester);
    await setUpKit();
    files
      ..disk['/dl/m.csv'] = Uint8List.fromList(
        utf8.encode('a;b;c;d\nСайт;https://a.example;canary;CANARY-pw-m\n'),
      )
      ..next = '/dl/m.csv';
    await tester.pumpWidget(app(CsvImportScreen(kit: kit)));
    await tapFar(tester, 'import-pick');
    expect(find.byKey(const ValueKey<String>('import-role-note')), findsOne);
    expect(tester.takeException(), isNull);
    // Подпись — над списком на всю ширину, а не в колонке 110 px.
    final label = tester.getSize(find.text('Название'));
    expect(label.width, greaterThan(110));
    await finish(tester);
  });

  testWidgets('отдельный пароль копии не может быть паролем записи (5.7)',
      (WidgetTester tester) async {
    await setUpKit();
    const reused = 'CANARY-Vq8#mT2!zK9pL-wR4';
    await vault.addEntry(service: 'Почта', password: secret(reused));
    await expectLater(
      kit.exportBackup(Canary.master, separate: reused),
      throwsA(
        isA<BackupProblem>().having(
          (BackupProblem p) => p.text,
          'text',
          contains('уже стоит у одной из записей'),
        ),
      ),
    );
    expect(kit.reusedProblem(reused), isNotNull);
    expect(kit.reusedProblem('CANARY-other-Zx7#Lp2!Qw9'), isNull);
    // Повтор одного слова — не фраза: тоже отказ.
    // Повторы без учёта регистра, слово со счётчиком, повтор куска — тоже.
    for (final weak in <String>[
      'acid acid acid acid',
      'Able-able-ABLE-able',
      'able-acid-able-acid',
      'able1-able2-able3-able4',
      'Qwerty1!Qwerty1!',
      'abcABCabcABC123',
    ]) {
      await expectLater(
        kit.exportBackup(Canary.master, separate: weak),
        throwsA(isA<BackupProblem>()),
        reason: weak,
      );
    }
    final ok = await kit.exportBackup(
      Canary.master,
      separate: 'CANARY-other-Zx7#Lp2!Qw9',
    );
    expect(ok, isNotEmpty);
    await finish(tester);
  });

  test('число записей — в нужной форме', () {
    expect(countText(1, 'запись', 'записи', 'записей'), '1 запись');
    expect(countText(2, 'запись', 'записи', 'записей'), '2 записи');
    expect(countText(5, 'запись', 'записи', 'записей'), '5 записей');
    expect(countText(11, 'запись', 'записи', 'записей'), '11 записей');
    expect(countText(21, 'запись', 'записи', 'записей'), '21 запись');
  });
}
