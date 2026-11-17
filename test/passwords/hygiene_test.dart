// Гигиена хранилища паролей (ADR-014, раздел 11, группа 15): нет вывода в
// логи, изоляция импортов, фасад без методов, отдающих пароль, каталог
// ответов (белый список подстановок, protected), карточка не
// сериализуется, правила резервной копии Android.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/models/secure_card.dart';
import 'package:local_assistant/core/replies/reply_library.dart';
import 'package:local_assistant/core/settings/app_settings.dart';
import 'package:path/path.dart' as p;

/// Строки кода без комментариев.
Iterable<(int, String)> _code(File file) sync* {
  final lines = file.readAsLinesSync();
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('//')) continue;
    final comment = line.indexOf(' // ');
    yield (i + 1, comment < 0 ? line : line.substring(0, comment));
  }
}

List<File> _dart(String dir) => Directory(dir).existsSync()
    ? Directory(dir)
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'))
        .toList()
    : const <File>[];

String _rel(File file) => p.relative(file.path).replaceAll(r'\', '/');

void main() {
  test('в lib нет print, debugPrint, stdout, developer.log (кроме chat_store)',
      () {
    final banned = RegExp(
      r'(?<![\w.])print\(|debugPrint\(|(?<![\w.])stdout\.|(?<![\w.])stderr\.|'
      r'developer\.log\(|dart:developer',
    );
    final found = <String>[];
    for (final file in _dart('lib')) {
      if (_rel(file) == 'lib/core/chats/chat_store.dart') continue;
      for (final (number, line) in _code(file)) {
        if (banned.hasMatch(line)) found.add('${_rel(file)}:$number');
      }
    }
    expect(found, isEmpty);
  });

  test('lib/core/passwords: нет dart:math Random и unawaited', () {
    final files = _dart('lib/core/passwords');
    expect(files, isNotEmpty);
    for (final file in files) {
      for (final (number, line) in _code(file)) {
        expect(
          RegExp(r'(?<![\w.])Random\(').hasMatch(line),
          isFalse,
          reason: '${_rel(file)}:$number',
        );
        expect(
          line,
          isNot(contains('dart:math')),
          reason: '${_rel(file)}:$number',
        );
        expect(
          line,
          isNot(contains('unawaited(')),
          reason: '${_rel(file)}:$number',
        );
      }
    }
  });

  test('импорты: хранилище изолировано от сети и секретов склада', () {
    final imports = RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''');
    List<String> importsOf(File file) => <String>[
          for (final line in file.readAsLinesSync())
            if (imports.firstMatch(line) case final match?) match.group(1)!,
        ];

    // Хранилище не видит сеть, подключения и secrets.json.
    for (final file in _dart('lib/core/passwords')) {
      for (final target in importsOf(file)) {
        for (final banned in <String>[
          'manifest/',
          'io_http_transport',
          'http_transport',
          'secret_store',
          'file_secret_store',
          'connection',
          'package:flutter/',
        ]) {
          expect(target, isNot(contains(banned)), reason: _rel(file));
        }
      }
    }
    // Никто из lib/core/connectors не знает о паролях.
    for (final file in _dart('lib/core/connectors')) {
      for (final target in importsOf(file)) {
        expect(target, isNot(contains('passwords')), reason: _rel(file));
      }
    }
    // Навык (этап 2) получает только VaultFacade.
    for (final file in _dart('lib/core/skills/passwords')) {
      for (final target in importsOf(file)) {
        for (final banned in <String>[
          'vault_crypto',
          'secret_bytes',
          'vault_store',
          'manifest/',
          'io_http_transport',
        ]) {
          expect(target, isNot(contains(banned)), reason: _rel(file));
        }
      }
    }
  });

  test('VaultFacade: нет методов, отдающих пароль, заметку или ключ', () {
    final source =
        File('lib/core/passwords/vault_facade.dart').readAsStringSync();
    for (final banned in <String>[
      'readSecret',
      'SecretBytes',
      'VaultSecret',
      'unsafeBytes',
      'exportKey',
      '.note',
      'fingerprint(',
    ]) {
      expect(source, isNot(contains(banned)), reason: banned);
    }
    // Подсказка — только через hintForHistory и только при флаге.
    expect(
      RegExp(r'\.hint\b').allMatches(source).length,
      1,
      reason: 'единственное чтение подсказки — в hintForHistory',
    );
    expect(source, contains("prefs['hints_in_history'] != true"));
  });

  group('каталог ответов', () {
    final library = ReplyLibrary.builtIn;
    const allowed = <String>{
      'service',
      'login',
      'hint',
      'query',
      'count',
      'total',
      'weak',
      'reused',
      'places',
      'old',
      'minutes',
      'seconds',
      'days',
      'bits',
      'strength',
      'streak',
      'when',
      'code',
      // Название приложения в косвенном падеже (`passwords.lostDevice`).
      'appGenitive',
    };
    const forbidden = <String>{
      'password',
      'pass',
      'secret',
      'note',
      'value',
      'master',
      'error',
    };

    test('ключи паролей: только белый список подстановок', () {
      final ids = library.schema.specs.keys.where(
        (String id) =>
            id.startsWith('passwords.') ||
            id.startsWith('secret.') ||
            id == 'router.failed.quiet',
      );
      expect(
        ids,
        containsAll(<String>['secret.redacted', 'router.failed.quiet']),
      );
      for (final id in ids) {
        final names = library.schema[id]!.placeholders;
        expect(allowed.containsAll(names), isTrue, reason: id);
        expect(names.any(forbidden.contains), isFalse, reason: id);
      }
    });

    test('secret.redacted и router.failed.quiet — protected, без причины', () {
      for (final id in <String>['secret.redacted', 'router.failed.quiet']) {
        expect(library.schema[id]!.protected, isTrue, reason: id);
        expect(library.schema[id]!.placeholders, isEmpty, reason: id);
      }
      expect(
        library.render(const Reply('router.failed.quiet'), const ReplyVoice()),
        'Не получилось выполнить действие.',
      );
    });
  });

  test(
      'экраны паролей: без SelectableText и автозаполнения, поля — '
      'через SecretField', () {
    final files = _dart('lib/app/passwords');
    expect(files, isNotEmpty);
    for (final file in files) {
      final source =
          _code(file).map(((int, String) line) => line.$2).join('\n');
      expect(source, isNot(contains('SelectableText(')), reason: _rel(file));
      expect(source, isNot(contains('AutofillGroup')), reason: _rel(file));
      expect(
        RegExp(r'autofillHints:(?!\s*null)').hasMatch(source),
        isFalse,
        reason: _rel(file),
      );
      // Скрытое поле — только в SecretField.
      if (!file.path.endsWith('secret_widgets.dart')) {
        expect(source, isNot(contains('obscureText')), reason: _rel(file));
      }
      // Системных уведомлений и озвучивания навык не делает (D23).
      for (final banned in <String>['flutter_tts', 'notification']) {
        expect(source, isNot(contains(banned)), reason: _rel(file));
      }
    }
  });

  test('навык и фразы: только VaultFacade, без сети', () {
    final connector = File(
      'lib/core/skills/passwords/passwords_connector.dart',
    ).readAsStringSync();
    expect(connector, contains('VaultFacade'));
    for (final banned in <String>['readSecret', 'unsafeBytes', '.note']) {
      expect(connector, isNot(contains(banned)), reason: banned);
    }
    // Подсказку навык читает только через hintForHistory (при флаге).
    expect(
      RegExp(r'\b(?:ref|entry|e|vault|_vault)\.hint\b').hasMatch(connector),
      isFalse,
    );
  });

  test('ключи навыка этапа 2 есть во всех стилях, предупреждения — protected',
      () {
    final library = ReplyLibrary.builtIn;
    const protectedIds = <String>[
      'passwords.off',
      'passwords.locked',
      'passwords.noRecovery',
      'passwords.lostDevice',
      'passwords.notFoundOnDevice',
      'passwords.reveal.confirm',
      'passwords.revealed',
      'passwords.copy.confirm',
      'passwords.copy.done',
      'passwords.copy.unavailable',
      'passwords.delete.confirm',
      'passwords.delete.button',
      'passwords.failed',
      'secret.redacted.off',
    ];
    for (final id in protectedIds) {
      expect(library.schema[id]?.protected, isTrue, reason: id);
    }
    final ids = library.schema.specs.keys
        .where((String id) => id.startsWith('passwords.'))
        .toList();
    expect(ids.length, greaterThanOrEqualTo(35));
    for (final catalog in library.styles) {
      for (final id in <String>[...ids, 'secret.redacted.off']) {
        expect(
          library.variants(id, catalog.style),
          isNotEmpty,
          reason: '$id/${catalog.style}',
        );
      }
    }
    // secret.redacted говорит, куда вносить пароли.
    expect(
      library.render(const Reply('secret.redacted'), const ReplyVoice()),
      contains('«Пароли»'),
    );
  });

  test('settings.json: только версия файла и «хранилище было»', () {
    const settings = AppSettings(
      passwordsSeenRev: 42,
      passwordsVaultExisted: true,
    );
    final json = settings.toJson();
    expect(json['passwords.seen_rev'], 42);
    expect(json['passwords.vault_existed'], isTrue);
    final back = AppSettings.fromJson(json);
    expect(back.passwordsSeenRev, 42);
    expect(back.passwordsVaultExisted, isTrue);
    expect(
      const AppSettings().toJson().keys.where((k) => k.contains('passw')),
      isEmpty,
    );
    expect(
      AppSettings.fromJson(<String, dynamic>{
        'passwords.seen_rev': 'x',
        'passwords.vault_existed': 'да',
      }).passwordsSeenRev,
      isNull,
    );
  });

  test('ChatMessage.secureCard: нет в toJson и copyAs', () {
    final message = ChatMessage(
      id: 'm_1',
      author: ChatAuthor.persona,
      text: 'Пароль — в карточке.',
      timestamp: DateTime.utc(2026, 11, 10),
      secureCard: const SecureCardRequest(
        kind: SecureCardKind.reveal,
        entryIds: <String>['0123456789abcdef0123456789abcdef'],
      ),
    );
    final json = message.toJson();
    expect(json.keys, isNot(contains(contains('secure'))));
    expect('$json', isNot(contains('0123456789abcdef')));
    expect(message.copyAs('m_2').secureCard, isNull);
    expect(ChatMessage.fromJson(json)!.secureCard, isNull);
    expect(message.secureCard.toString(), 'SecureCardRequest(reveal, 1)');
  });

  test('ConnectorInfo.sensitive по умолчанию выключен', () {
    const info = ConnectorInfo(id: 'x', title: 'X', description: 'X.');
    expect(info.sensitive, isFalse);
  });

  group('резервная копия Android (D20)', () {
    const paths = <String>['assistant/vault/', 'assistant/secrets.json'];
    String read(String name) =>
        File('android/app/src/main/res/xml/$name').readAsStringSync();

    String section(String xml, String tag) {
      final match = RegExp('<$tag>(.*?)</$tag>', dotAll: true).firstMatch(xml);
      expect(match, isNotNull, reason: tag);
      return match!.group(1)!;
    }

    void expectExcluded(String xml, String where) {
      for (final path in paths) {
        expect(
          xml,
          contains('<exclude domain="file" path="$path" />'),
          reason: '$where: $path',
        );
      }
      expect(xml, isNot(contains('<include')), reason: where);
    }

    test('облако и перенос «телефон → телефон» без vault/ и secrets.json', () {
      final rules = read('data_extraction_rules.xml');
      expectExcluded(section(rules, 'cloud-backup'), 'cloud-backup');
      expectExcluded(section(rules, 'device-transfer'), 'device-transfer');
    });

    test('Android ≤ 11 и adb backup — то же', () {
      expectExcluded(
        section(read('backup_rules.xml'), 'full-backup-content'),
        'full-backup-content',
      );
    });

    test('манифест ссылается на оба файла, копия задач не выключена', () {
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(
        manifest,
        contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
      );
      expect(
        manifest,
        contains('android:fullBackupContent="@xml/backup_rules"'),
      );
      expect(manifest, contains('android:allowBackup="true"'));
    });
  });
}
