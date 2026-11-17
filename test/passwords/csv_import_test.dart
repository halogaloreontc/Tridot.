// Импорт CSV из браузеров и менеджеров паролей (ADR-014, 5.6, 15.6;
// раздел 11, группы 8 и 18). Пароли — только синтетические канарейки
// `CANARY-…`; в сообщениях об ошибках — только номера записей и строк.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/passwords/csv_import.dart';
import 'package:local_assistant/core/passwords/import_rules.dart';
import 'package:local_assistant/core/passwords/password_audit.dart';
import 'package:local_assistant/core/passwords/password_training.dart';
import 'package:local_assistant/core/passwords/secret_bytes.dart';
import 'package:local_assistant/core/passwords/vault.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_format.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';

import 'vault_test_support.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

String _pw(ImportItem item) => utf8.decode(item.password.unsafeBytes);

void main() {
  late SodiumVaultCrypto crypto;
  late VaultKey digestKey;
  final now = DateTime.utc(2026, 11, 10, 9);

  setUpAll(() async {
    crypto = await testCrypto();
    digestKey = crypto.randomKey();
  });

  Uint8List digest(SecretBytes p) => crypto.keyedHash(digestKey, p.unsafeBytes);

  CsvAnalysis analyze(
    String text, {
    CsvEncoding encoding = CsvEncoding.utf8,
    CsvColumns? mapping,
  }) =>
      CsvImport.analyze(
        _bytes(text),
        digest: digest,
        now: now,
        encoding: encoding,
        mapping: mapping,
      );

  CsvPlan plan(String text, {CsvColumns? mapping}) {
    final result = analyze(text, mapping: mapping);
    expect(result, isA<CsvPlan>(), reason: '$result');
    return result as CsvPlan;
  }

  group('разборщик RFC 4180', () {
    test('кавычки, "", перевод строки в поле, BOM, CRLF', () {
      final table = CsvReader.parse(
        _bytes('﻿a,b,c\r\n"x, y","say ""hi""","multi\nline"\r\n\r\n1,2,3'),
      );
      expect(table.rows.length, 3);
      expect(table.rows[1].map(utf8.decode).toList(), <String>[
        'x, y',
        'say "hi"',
        'multi\nline',
      ]);
      expect(table.lines, <int>[1, 2, 5]);
      table.wipe();
      expect(table.rows[1][0].every((int b) => b == 0), isTrue);
    });

    test('разделитель по заголовку: «;» и табуляция', () {
      final semi = CsvReader.parse(_bytes('name;url;password\nа;б;в'));
      expect(semi.delimiter, 0x3B);
      expect(semi.rows[1].length, 3);
      final tab = CsvReader.parse(_bytes('name\turl\tpassword\nа\tб\tв'));
      expect(tab.delimiter, 0x09);
      expect(tab.rows[1].map(utf8.decode).last, 'в');
    });

    test('незакрытая кавычка — файл не разобран, без содержимого', () {
      expect(
        () => CsvReader.parse(_bytes('name,password\n"CANARY-pw-open,x')),
        throwsA(
          isA<CsvException>()
              .having((e) => e.failure, 'failure', CsvFailure.malformed)
              .having((e) => '$e', 'text', isNot(contains('CANARY'))),
        ),
      );
    });

    test('10 001 запись — отказ целиком, с числом', () {
      final rows = StringBuffer('name,url,username,password\n');
      for (var i = 0; i < 10001; i++) {
        rows.writeln('s$i,https://s$i.example,u$i,CANARY-pw-$i');
      }
      expect(
        () => analyze('$rows'),
        throwsA(
          isA<CsvException>()
              .having((e) => e.failure, 'failure', CsvFailure.tooMany)
              .having((e) => e.count, 'count', 10001),
        ),
      );
    });

    test('больше 5 МБ — отказ', () {
      final big = Uint8List(CsvReader.maxBytes + 1);
      expect(
        () => CsvImport.analyze(big, digest: digest, now: now),
        throwsA(
          isA<CsvException>()
              .having((e) => e.failure, 'failure', CsvFailure.tooLarge),
        ),
      );
    });
  });

  group('форматы по заголовку', () {
    test('Chrome / Edge: name,url,username,password,note', () {
      final result = plan(
        'name,url,username,password,note\n'
        'example.org,https://example.org/login,canary.u@example.org,'
        'CANARY-pw-chrome1,CANARY-note-c1\n',
      );
      expect(result.format, CsvFormat.chromium);
      final item = result.records.single.item;
      expect(item.service, 'example.org');
      expect(item.login, 'canary.u@example.org');
      expect(item.urls, <String>['https://example.org/login']);
      expect(_pw(item), 'CANARY-pw-chrome1');
      expect(utf8.decode(item.note.unsafeBytes), 'CANARY-note-c1');
      expect(item.hint, isEmpty);
      expect(item.changed, isNull);
      expect('$item', isNot(contains('CANARY')));
    });

    test('Firefox: дата смены из timePasswordChanged (мс)', () {
      final result = plan(
        '"url","username","password","httpRealm","formActionOrigin","guid",'
        '"timeCreated","timeLastUsed","timePasswordChanged"\n'
        '"https://forum.example.net","canary-ff","CANARY-pw-ff1",,'
        '"https://forum.example.net","{1}","1700000000000","1700000000000",'
        '"1700000000000"\n',
      );
      expect(result.format, CsvFormat.firefox);
      final item = result.records.single.item;
      expect(item.service, 'forum.example.net');
      expect(
        item.changed,
        DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
      );
    });

    test('Safari: OTPAuth отбрасывается с предупреждением', () {
      final result = plan(
        'Title,URL,Username,Password,Notes,OTPAuth\n'
        'Пример,https://example.com,canary,CANARY-pw-saf1,,'
        'otpauth://totp/x?secret=CANARYOTPSECRET\n'
        'Только код,https://otp.example.com,canary,,,'
        'otpauth://totp/y?secret=CANARYOTPSECRET2\n',
      );
      expect(result.format, CsvFormat.safari);
      expect(result.otpDropped, 2);
      expect(result.records.single.item.service, 'Пример');
      expect(result.skipped[CsvSkip.service], 1);
    });

    test('Bitwarden: только записи входа, «избранное» не становится важным',
        () {
      final result = plan(
        'folder,favorite,type,name,notes,fields,reprompt,login_uri,'
        'login_username,login_password,login_totp\n'
        ',1,login,Почта,CANARY-note-bw,,0,"https://mail.example,'
        'https://m.mail.example",canary-bw,CANARY-pw-bw1,\n'
        ',,note,Заметка,CANARY-note-only,,0,,,,\n',
      );
      expect(result.format, CsvFormat.bitwarden);
      final item = result.records.single.item;
      expect(item.urls.length, 2);
      expect(result.skipped[CsvSkip.service], 1);
    });

    test('KeePassXC: корзина пропускается, дата Last Modified', () {
      final result = plan(
        '"Group","Title","Username","Password","URL","Notes","TOTP","Icon",'
        '"Last Modified","Created"\n'
        '"Root","Банк","canary-kp","CANARY-pw-kp1","https://bank.example",'
        '"","","0","2025-03-01T10:00:00Z","2024-01-01T10:00:00Z"\n'
        '"Recycle Bin","Старое","canary-kp","CANARY-pw-kp2","","","","0",'
        '"2020-01-01T00:00:00Z",""\n',
      );
      expect(result.format, CsvFormat.keepass);
      expect(result.records.single.item.changed, DateTime.utc(2025, 3, 1, 10));
      expect(result.skipped[CsvSkip.service], 1);
    });

    test('заголовок не узнан — ручное сопоставление, примеры в маске', () {
      final result = analyze(
        'сайт;кто;секрет\n'
        'https://x.example;canary-man;CANARY-pw-man1\n',
      );
      expect(result, isA<CsvNeedsMapping>());
      final columns = (result as CsvNeedsMapping).columns;
      expect(columns.length, 3);
      for (final column in columns) {
        expect(column.sample, anyOf('•••', endsWith('•••')));
        expect(column.sample, isNot(contains('CANARY')));
        expect(column.sample, isNot(contains('pw')));
      }
      // Неизвестный заголовок «секрет» не показывается как есть.
      expect(columns.map((c) => c.title), contains('Колонка 3'));
      final mapped = plan(
        'сайт;кто;секрет\n'
        'https://x.example;canary-man;CANARY-pw-man1\n',
        mapping: const CsvColumns(password: 2, url: 0, login: 1),
      );
      expect(mapped.records.single.item.service, 'x.example');
      expect(mapped.excelWarning, isTrue);
    });
  });

  group('грязный CSV', () {
    test('Windows-1251 — вопрос, не «порча»; затем чтение', () {
      // «Почта» в Windows-1251.
      final raw = Uint8List.fromList(<int>[
        ...ascii.encode('name,url,username,password\n'),
        0xCF, 0xEE, 0xF7, 0xF2, 0xE0, //
        ...ascii.encode(',https://mail.example,canary,CANARY-pw-1251\n'),
      ]);
      final first = CsvImport.analyze(raw, digest: digest, now: now);
      expect(first, isA<CsvNeedsEncoding>());
      for (final column in (first as CsvNeedsEncoding).columns) {
        expect(column.sample, isNot(contains('CANARY')));
      }
      final second = CsvImport.analyze(
        raw,
        digest: digest,
        now: now,
        encoding: CsvEncoding.windows1251,
      ) as CsvPlan;
      expect(second.records.single.item.service, 'Почта');
      expect(second.excelWarning, isTrue);
    });

    test('пароль с пробелами по краям и ведущим нулём — как есть', () {
      final result = plan(
        'name,url,username,password\n'
        'Сайт,https://s.example,  canary  ," 0123 CANARY-x "\n',
      );
      final item = result.records.single.item;
      expect(_pw(item), ' 0123 CANARY-x ');
      expect(item.login, 'canary');
    });

    test('android:// → понятное имя; IP — как есть', () {
      final result = plan(
        'name,url,username,password\n'
        ',android://AbC/+d0==@com.vkontakte.android/,canary,CANARY-pw-a1\n'
        ',android://Zz==@org.example.notes.android/,canary,CANARY-pw-a2\n'
        ',https://accounts.google.com/signin,canary,CANARY-pw-a3\n'
        ',http://192.168.1.1/,admin,CANARY-pw-a4\n',
      );
      final names = result.records.map((r) => r.item.service).toList();
      expect(names, <String>['ВКонтакте', 'notes', 'Google', '192.168.1.1']);
      expect(ImportRules.isLocal('192.168.1.1'), isTrue);
      expect(result.records.first.item.aliases, isEmpty);
      expect(result.records[2].item.aliases, contains('google'));
    });

    test('без пароля и служебные пропущены, в ошибках только номера', () {
      final result = plan(
        'name,url,username,password\n'
        'Первый,https://a.example,canary-a,\n'
        'name,url,username,password\n'
        ',,canary-c,CANARY-pw-nourl\n'
        'Четвёртый,https://d.example,canary-d,CANARY-pw-d\n',
      );
      expect(result.records.length, 1);
      expect(result.skipped[CsvSkip.noPassword], 1);
      expect(result.skipped[CsvSkip.service], 2);
      expect(result.errors, <String>[
        'запись 1 (строка файла 2): нет пароля',
        'запись 2 (строка файла 3): заголовок внутри файла',
        'запись 3 (строка файла 4): нет названия и адреса',
      ]);
      for (final error in result.errors) {
        for (final field in <String>['Первый', 'canary', 'CANARY', 'a.ex']) {
          expect(error, isNot(contains(field)));
        }
      }
    });

    test('дубли внутри файла: одинаковые склеены, разные пароли — выбор', () {
      final result = plan(
        '"url","username","password","httpRealm","formActionOrigin","guid",'
        '"timeCreated","timeLastUsed","timePasswordChanged"\n'
        'https://a.example,canary,CANARY-pw-same,,,{1},1,1,1600000000000\n'
        'https://a.example,canary,CANARY-pw-same,,,{2},1,1,1600000000000\n'
        'https://b.example,canary,CANARY-pw-old,,,{3},1,1,1600000000000\n'
        'https://b.example,canary,CANARY-pw-new,,,{4},1,1,1700000000000\n',
      );
      expect(result.merged, 1);
      expect(result.records.length, 2);
      final choice = result.records.firstWhere((r) => r.needsChoice);
      expect(choice.variants.length, 2);
      // Новее — по умолчанию.
      expect(_pw(choice.item), 'CANARY-pw-new');
    });
  });

  group('враждебный CSV (15.6)', () {
    test('адреса javascript:/file:/data:/intent: отброшены', () {
      final result = plan(
        'name,url,username,password\n'
        'Банк,javascript:alert(1),canary,CANARY-pw-js\n'
        'Файл,file:///etc/passwd,canary,CANARY-pw-file\n'
        ',data:text/html;base64,AAAA,canary,CANARY-pw-data\n',
      );
      expect(result.records.map((r) => r.item.urls), everyElement(isEmpty));
      expect(result.badUrls, greaterThanOrEqualTo(2));
      // Без названия и без допустимого адреса — пропущена.
      expect(result.records.length, 2);
    });

    test('U+202E и управляющие символы в названии — запись пропущена', () {
      final result = plan(
        'name,url,username,password\n'
        'moc.knab\u202E,https://evil.example,canary,CANARY-pw-bidi\n'
        'Тест\u0007,https://bell.example,canary,CANARY-pw-bell\n'
        'Норма,https://ok.example,canary\u2066x,CANARY-pw-login\n',
      );
      expect(result.records, isEmpty);
      expect(result.skipped[CsvSkip.invalid], 3);
    });

    test('поле длиннее предела — запись пропущена', () {
      final result = plan(
        'name,url,username,password\n'
        '${'д' * 201},https://long.example,canary,CANARY-pw-long\n'
        'Хорошая,https://ok.example,canary,CANARY-pw-ok\n',
      );
      expect(result.records.single.item.service, 'Хорошая');
      expect(result.skipped[CsvSkip.invalid], 1);
    });

    test('пароли в колонке «Название» — сопоставление отклонено', () {
      final rows = StringBuffer('name,url,username,password\n');
      for (var i = 0; i < 5; i++) {
        rows.writeln('CANARY-pw-Kx$i!,https://s$i.example,canary$i,ordinary$i');
      }
      final result = analyze('$rows');
      expect(result, isA<CsvRejected>());
      expect(
        (result as CsvRejected).reason,
        CsvRejection.passwordInService,
      );
      expect('$result', isNot(contains('CANARY')));
    });

    test('в колонке «Логин» — пароли строк файла: отклонено', () {
      final result = analyze(
        'name,url,username,password\n'
        'Сайт,https://a.example,CANARY-pw-q1,CANARY-pw-q1\n'
        'Другой,https://b.example,canary-user,CANARY-pw-q2\n',
      );
      expect(result, isA<CsvRejected>());
      expect(
        (result as CsvRejected).reason,
        CsvRejection.passwordInLogin,
      );
    });

    test('в «Логине» обычные пароли без знаков (колонки перепутаны)', () {
      final rows = StringBuffer('name,url,username,password\n');
      for (var i = 0; i < 10; i++) {
        rows.writeln('Сайт$i,https://s$i.example,Canary198$i,ivan.petrov$i');
      }
      final result = analyze('$rows');
      expect(result, isA<CsvRejected>());
      expect(
        (result as CsvRejected).reason,
        CsvRejection.passwordInLogin,
      );
      expect('$result', isNot(contains('Canary')));
    });

    test('обычные логины с точкой и цифрами — не похожи на пароли', () {
      expect(CsvImport.looksLikePassword('ivan.petrov85', login: true), false);
      expect(CsvImport.looksLikePassword('canary_user-7', login: true), false);
      expect(CsvImport.looksLikePassword('Canary1980', login: true), true);
      expect(CsvImport.looksLikePassword('Canary1980', login: false), true);
    });

    test('одна колонка на две роли — отклонено', () {
      final result = analyze(
        'a,b\nx,CANARY-pw-1\n',
        mapping: const CsvColumns(password: 1, service: 1),
      );
      expect((result as CsvRejected).reason, CsvRejection.sameColumn);
    });

    test('«\\» и точки-двойники в адресе — как в браузере (WHATWG)', () {
      // Настоящий хост — evil.example: адрес не принимается.
      expect(ImportRules.url(r'https://evil.example\@sberbank.ru/'), isNull);
      const tricky = r'https://evil.example\@sberbank.ru/';
      expect(ImportRules.hostOf(tricky), 'evil.example');
      expect(ImportRules.serviceFor(tricky), isNot('Сбербанк'));
      // U+3002 — тоже точка.
      expect(ImportRules.hostOf('https://evil\u3002example/'), 'evil.example');
      final result = plan(
        'name,url,username,password\n'
        ',https://evil.example\\@sberbank.ru/,canary,CANARY-pw-bs\n'
        ',https://sberbank.ru/,canary,CANARY-pw-ok\n',
      );
      expect(result.records.single.item.service, 'Сбербанк');
      expect(result.records.single.item.urls.single, 'https://sberbank.ru/');
    });

    test('хост в punycode: кириллический двойник виден', () {
      expect(Punycode.label('рф'), 'xn--p1ai');
      expect(Punycode.label('bücher'), 'xn--bcher-kva');
      expect(
        ImportRules.displayHost('https://www.sbеrbank.ru/'),
        startsWith('xn--'),
      );
      expect(ImportRules.displayHost('https://example.org/x'), 'example.org');
    });
  });

  group('импорт в хранилище', () {
    late Vault vault;

    Future<void> openVault([VaultStore? store]) async {
      vault = testVault(store ?? InMemoryVaultStore(), crypto);
      await vault.load();
      await vault.create(secret(Canary.master), params: fastKdf);
    }

    test('новая / дубль / дубль с другим паролем; по умолчанию — обе',
        () async {
      await openVault();
      final existing = await vault.addEntry(
        service: 'Почта',
        login: 'canary@example.org',
        password: secret('CANARY-pw-current'),
      );
      await vault.addEntry(
        service: 'Форум',
        login: 'canary',
        password: secret('CANARY-pw-forum'),
      );
      final result = plan(
        'name,url,username,password\n'
        'Почта,https://mail.example,Canary@Example.org,CANARY-pw-other\n'
        'Форум,https://forum.example,canary,CANARY-pw-forum\n'
        'Новый,https://new.example,canary,CANARY-pw-new\n',
      );
      final items = result.records.map((r) => r.item).toList();
      final matches = vault.matchImport(items);
      expect(matches.map((m) => m.status), <ImportStatus>[
        ImportStatus.conflict,
        ImportStatus.same,
        ImportStatus.fresh,
      ]);
      expect(matches.first.existingId, existing);
      expect(matches.map((m) => m.defaultChoice), <ImportChoice>[
        ImportChoice.keepBoth,
        ImportChoice.skip,
        ImportChoice.keepBoth,
      ]);
      final done = await vault.importItems(
        <ImportDecision>[
          for (var i = 0; i < items.length; i++)
            ImportDecision(items[i], matches[i], matches[i].defaultChoice),
        ],
        fromBackup: false,
      );
      expect(done.added, 2);
      expect(done.skipped, 1);
      expect(vault.entries.length, 4);
      final conflict = vault.entries.where(
        (VaultEntry e) => e.flags.contains(EntryFlags.importConflict),
      );
      expect(conflict.single.service, 'Почта');
      expect(conflict.single.dateSource, DateSource.unknown);
      expect(conflict.single.hint, isEmpty);
      expect(conflict.single.important, isFalse);
      result.wipe();
    });

    test('«заменить»: прежний пароль — в fp_old («это прежний пароль»)',
        () async {
      await openVault();
      final id = await vault.addEntry(
        service: 'Почта',
        login: 'canary',
        password: secret('CANARY-pw-before'),
      );
      final result = plan(
        'name,url,username,password\n'
        'Почта,https://mail.example,canary,CANARY-pw-after\n',
      );
      final item = result.records.single.item;
      final match = vault.matchImport(<ImportItem>[item]).single;
      await vault.importItems(
        <ImportDecision>[ImportDecision(item, match, ImportChoice.replace)],
        fromBackup: false,
      );
      expect(vault.entries.length, 1);
      expect(vault.entry(id)!.fpOld.length, 1);
      expect(vault.entry(id)!.urls, <String>['https://mail.example']);
      expect(
        await vault.recall(id, secret('CANARY-pw-before')),
        RecallVerdict.oldOne,
      );
      expect(
        await vault.recall(id, secret('CANARY-pw-after')),
        RecallVerdict.correct,
      );
      result.wipe();
    });

    test('сбой посреди — хранилище не изменено', () async {
      final store = FailingVaultStore();
      await openVault(store);
      await vault.addEntry(service: 'Было', password: secret('CANARY-pw-x'));
      final before = await store.readVault();
      final result = plan(
        'name,url,username,password\n'
        'А,https://a.example,canary,CANARY-pw-a\n'
        'Б,https://b.example,canary,CANARY-pw-b\n',
      );
      final items = result.records.map((r) => r.item).toList();
      final matches = vault.matchImport(items);
      store.fail = true;
      await expectLater(
        vault.importItems(
          <ImportDecision>[
            for (var i = 0; i < items.length; i++)
              ImportDecision(items[i], matches[i], ImportChoice.keepBoth),
          ],
          fromBackup: false,
        ),
        throwsA(anything),
      );
      expect(vault.entries.length, 1);
      expect(await store.readVault(), before);
      result.wipe();
    });

    test('отпечатки внутри файла — случайный ключ на вызов', () async {
      await openVault();
      final a = vault.withImportDigest((d) => d(secret('CANARY-pw-z')));
      final b = vault.withImportDigest((d) => d(secret('CANARY-pw-z')));
      expect(a, isNot(b));
      expect(a.length, VaultFormat.keyBytes);
    });
  });
}
