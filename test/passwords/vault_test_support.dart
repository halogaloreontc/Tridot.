// Общее для тестов хранилища паролей (ADR-014): libsodium, часы,
// хранилище с тестовыми параметрами Argon2id и канарейки.
//
// Канарейки — заведомо искусственные строки `CANARY-…`: в файлах, логах и
// названиях тестов не бывает ничего похожего на настоящий пароль.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:local_assistant/core/passwords/password_wordlists.dart';
import 'package:local_assistant/core/passwords/secret_bytes.dart';
import 'package:local_assistant/core/passwords/vault.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';
import 'package:local_assistant/core/services/clock.dart';

/// libsodium без изолята: тесты с `fakeAsync` и быстрые проверки.
Future<SodiumVaultCrypto> testCrypto({bool isolated = false}) =>
    SodiumVaultCrypto.load(isolated: isolated);

/// Часы, которые двигает тест: стенные ([value]) и монотонные
/// ([elapsed]). [advance] двигает оба; [jump] — только стенные (перевод
/// системных часов), [value] можно и присвоить.
final class TestClock implements Clock, MonotonicClock {
  TestClock([DateTime? start]) : value = start ?? DateTime.utc(2026, 11, 10, 9);

  DateTime value;

  @override
  Duration elapsed = Duration.zero;

  void advance(Duration by) {
    value = value.add(by);
    elapsed += by;
  }

  /// Перевести только стенные часы (вперёд или назад).
  void jump(Duration by) => value = value.add(by);

  @override
  DateTime now() => value;
}

/// Мастер-пароль и прочее из текста (только в тестах).
SecretBytes secret(String text) => SecretBytes.fromText(text);

/// Хранилище на [store] с тестовыми параметрами KDF.
Vault testVault(
  VaultStore store,
  VaultCrypto crypto, {
  Clock? clock,
  VaultPolicy policy = const VaultPolicy(),
}) =>
    Vault(
      store: store,
      crypto: crypto,
      clock: clock ?? TestClock(),
      policy: policy,
      allowTestingKdf: true,
    );

const VaultKdfParams fastKdf = VaultKdfParams.forTesting();

/// Канарейки: мастер-пароль, пароль, заметка, логин, подсказка.
abstract final class Canary {
  static const String master = 'CANARY-master-q7Lx2';
  static const String password = 'CANARY-pw-9zKt4';
  static const String note = 'CANARY-note-Hb3w';
  static const String login = 'canary.login.z5@example.org';
  static const String hint = 'CANARY-hint-Rr8';

  /// Пароль и заметка — им нельзя оказаться нигде, кроме шифротекста.
  static const List<String> secrets = <String>[master, password, note];

  /// Все виды, в которых ищем канарейку: UTF-8, UTF-16LE/BE, другая
  /// раскладка, base64 и hex.
  static List<Uint8List> encodings(String value) {
    final utf8Bytes = utf8.encode(value);
    final le = <int>[];
    final be = <int>[];
    for (final unit in value.codeUnits) {
      le
        ..add(unit & 0xFF)
        ..add(unit >> 8);
      be
        ..add(unit >> 8)
        ..add(unit & 0xFF);
    }
    return <Uint8List>[
      Uint8List.fromList(utf8Bytes),
      Uint8List.fromList(le),
      Uint8List.fromList(be),
      Uint8List.fromList(utf8.encode(swapLayout(value))),
      Uint8List.fromList(ascii.encode(base64.encode(utf8Bytes))),
      Uint8List.fromList(
        ascii.encode(
          utf8Bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join(),
        ),
      ),
    ];
  }

  /// Те же виды текстом — для поиска в строках.
  static List<String> textForms(String value) => <String>[
        value,
        swapLayout(value),
        base64.encode(utf8.encode(value)),
        utf8
            .encode(value)
            .map((int b) => b.toRadixString(16).padLeft(2, '0'))
            .join(),
      ];
}

/// Латиница ↔ ЙЦУКЕН по клавишам.
String swapLayout(String text) {
  const latin =
      'qwertyuiop[]asdfghjkl;\'zxcvbnm,.QWERTYUIOP{}ASDFGHJKL:"ZXCVBNM<>';
  const cyrillic =
      'йцукенгшщзхъфывапролджэячсмитьбюЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ';
  final out = StringBuffer();
  for (final char in text.split('')) {
    final i = latin.indexOf(char);
    final j = cyrillic.indexOf(char);
    out.write(i >= 0 ? cyrillic[i] : (j >= 0 ? latin[j] : char));
  }
  return out.toString();
}

/// Есть ли [needle] в [haystack] байтами.
bool containsBytes(Uint8List haystack, Uint8List needle) {
  if (needle.isEmpty || needle.length > haystack.length) return false;
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// Встроенные словари навыка (assets/passwords/), прочитанные с диска.
PasswordWordlists testWordlists() => PasswordWordlists.parse(
      eff: File('assets/passwords/eff_large_wordlist.txt').readAsStringSync(),
      common: File('assets/passwords/common_passwords.txt').readAsStringSync(),
    );

/// Хранилище в памяти, у которого запись файла хранилища падает по
/// требованию ([fail]): проверка атомарности импорта и слияния.
final class FailingVaultStore implements VaultStore {
  final InMemoryVaultStore inner = InMemoryVaultStore();
  bool fail = false;

  @override
  Future<bool> hasVault() => inner.hasVault();
  @override
  Future<Uint8List?> readVault() => inner.readVault();
  @override
  Future<Uint8List?> readPrevious() => inner.readPrevious();
  @override
  Future<void> writeVault(Uint8List bytes, {bool replacePrevious = false}) {
    if (fail) throw const FileSystemException('диск');
    return inner.writeVault(bytes, replacePrevious: replacePrevious);
  }

  @override
  Future<void> writePrevious(Uint8List bytes) => inner.writePrevious(bytes);
  @override
  Future<List<int>> backupVersions() => inner.backupVersions();
  @override
  Future<Uint8List?> readBackup(int version) => inner.readBackup(version);
  @override
  Future<void> writeBackup(int version, Uint8List bytes) =>
      inner.writeBackup(version, bytes);
  @override
  Future<void> deleteBackup(int version) => inner.deleteBackup(version);
  @override
  Future<Uint8List?> readAttempts() => inner.readAttempts();
  @override
  Future<void> writeAttempts(Uint8List bytes) => inner.writeAttempts(bytes);
  @override
  Future<void> removeTemporary() => inner.removeTemporary();
  @override
  Future<void> archiveVault(String name) => inner.archiveVault(name);
  @override
  Future<List<String>> archived() => inner.archived();
}
