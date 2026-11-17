import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/links/incoming_links.dart';
import 'package:local_assistant/app/security/sealed_secret_store.dart';
import 'package:local_assistant/core/connectors/secret_store.dart';

/// Заведомо поддельные значения: настоящих секретов в тестах нет.
const String fakeToken = 'fake-token-not-real';
const String fakeSid = 'fake-sid-not-real';

/// «Шифр» для теста: XOR и метка ключа; [broken] — система ключ потеряла.
final class _FakeSealer implements SecretSealer {
  _FakeSealer({this.key = 0x5a});

  int key;
  bool broken = false;
  int seals = 0;

  @override
  String get kind => 'test-sealer';

  @override
  Future<Uint8List> seal(Uint8List plain) async {
    seals++;
    return Uint8List.fromList(<int>[key, for (final b in plain) b ^ key]);
  }

  @override
  Future<Uint8List> open(Uint8List sealed) async {
    if (broken || sealed.first != key) throw StateError('ключа нет');
    return Uint8List.fromList(<int>[for (final b in sealed.skip(1)) b ^ key]);
  }
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('sealed'));
  tearDown(() => dir.deleteSync(recursive: true));

  String path(String name) => '${dir.path}/$name';

  group('SealedSecretStore (ADR-031)', () {
    test('в файле только шифротекст; после перезапуска читается', () async {
      final sealer = _FakeSealer();
      final store = SealedSecretStore(path('secrets.sealed'), sealer);
      await store.write('warehouse.token', fakeToken);
      await store.write('warehouse.sid', fakeSid);
      final text = File(path('secrets.sealed')).readAsStringSync();
      expect(text, isNot(contains(fakeToken)));
      expect(text, isNot(contains(fakeSid)));
      expect(jsonDecode(text), containsPair('format', 'tridot-sealed/1'));
      final again = SealedSecretStore(path('secrets.sealed'), sealer);
      expect(await again.read('warehouse.token'), fakeToken);
      await again.delete('warehouse.token');
      expect(
        await SealedSecretStore(path('secrets.sealed'), sealer)
            .read('warehouse.token'),
        isNull,
      );
    });

    test('записи подряд не теряют друг друга', () async {
      final store = SealedSecretStore(path('secrets.sealed'), _FakeSealer());
      await Future.wait(<Future<void>>[
        store.write('a', '1'),
        store.write('b', '2'),
        store.write('c', '3'),
      ]);
      final again = SealedSecretStore(path('secrets.sealed'), _FakeSealer());
      expect(await again.read('a'), '1');
      expect(await again.read('b'), '2');
      expect(await again.read('c'), '3');
    });

    test('ключ системы пропал (копия с другого устройства) — пусто', () async {
      await SealedSecretStore(path('secrets.sealed'), _FakeSealer())
          .write('warehouse.token', fakeToken);
      final other = SealedSecretStore(
        path('secrets.sealed'),
        _FakeSealer(key: 0x11),
      );
      expect(await other.read('warehouse.token'), isNull);
    });

    test('временный сбой ключа системы — ключи не стёрты, запись отказана',
        () async {
      final sealer = _FakeSealer();
      final store = SealedSecretStore(path('secrets.sealed'), sealer);
      await store.write('warehouse.token', fakeToken);
      await store.write('warehouse.sid', fakeSid);
      final before = File(path('secrets.sealed')).readAsStringSync();
      final again = SealedSecretStore(path('secrets.sealed'), sealer);
      sealer.broken = true;
      expect(await again.read('warehouse.token'), isNull);
      expect(await again.unreadable(), isTrue);
      await expectLater(again.write('other', 'x'), throwsStateError);
      expect(File(path('secrets.sealed')).readAsStringSync(), before);
      // Проба при запуске файл не переписывает и в открытый файл не уходит.
      final choice = await openSecretStore(
        plainPath: path('secrets.json'),
        secure: again,
        backend: SecretBackend.keystore,
      );
      expect(choice.backend, SecretBackend.keystore);
      expect(File(path('secrets.sealed')).readAsStringSync(), before);
      // Сбой прошёл — ключи на месте, без кэша пустоты.
      sealer.broken = false;
      expect(await again.read('warehouse.token'), fakeToken);
      expect(await again.read('warehouse.sid'), fakeSid);
    });

    test('ключ сменился, система работает — файл в .bad, вход заново',
        () async {
      await SealedSecretStore(path('secrets.sealed'), _FakeSealer())
          .write('warehouse.token', fakeToken);
      final other = SealedSecretStore(
        path('secrets.sealed'),
        _FakeSealer(key: 0x11),
      );
      await other.write('warehouse.sid', fakeSid);
      expect(File(path('secrets.sealed.bad')).existsSync(), isTrue);
      final again = SealedSecretStore(
        path('secrets.sealed'),
        _FakeSealer(key: 0x11),
      );
      expect(await again.read('warehouse.sid'), fakeSid);
      expect(await again.read('warehouse.token'), isNull);
    });
  });

  group('openSecretStore: перенос из secrets.json', () {
    test('ключи перенесены, открытый файл стёрт', () async {
      File(path('secrets.json')).writeAsStringSync(
        jsonEncode(<String, String>{
          'warehouse.token': fakeToken,
          'warehouse.sid': fakeSid,
        }),
      );
      File(path('secrets.json.tmp')).writeAsStringSync('{}');
      final secure = SealedSecretStore(path('secrets.sealed'), _FakeSealer());
      final choice = await openSecretStore(
        plainPath: path('secrets.json'),
        secure: secure,
        backend: SecretBackend.keystore,
      );
      expect(choice.backend, SecretBackend.keystore);
      expect(choice.migrated, isTrue);
      expect(await choice.store.read('warehouse.sid'), fakeSid);
      expect(File(path('secrets.json')).existsSync(), isFalse);
      expect(File(path('secrets.json.tmp')).existsSync(), isFalse);
      // Проба не оставляет следа.
      expect(await secure.read('tridot.probe'), isNull);
    });

    test('хранилище системы не работает — остаётся файл', () async {
      File(path('secrets.json')).writeAsStringSync(
        jsonEncode(<String, String>{'warehouse.token': fakeToken}),
      );
      final sealer = _FakeSealer()..broken = true;
      final choice = await openSecretStore(
        plainPath: path('secrets.json'),
        secure: _Failing(),
        backend: SecretBackend.keychain,
      );
      expect(choice.backend, SecretBackend.file);
      expect(await choice.store.read('warehouse.token'), fakeToken);
      expect(File(path('secrets.json')).existsSync(), isTrue);
      expect(sealer.seals, 0);
    });

    test('чтение не сошлось — файл не тронут', () async {
      File(path('secrets.json')).writeAsStringSync(
        jsonEncode(<String, String>{'warehouse.token': fakeToken}),
      );
      final choice = await openSecretStore(
        plainPath: path('secrets.json'),
        secure: _Forgetful(),
        backend: SecretBackend.dpapi,
      );
      expect(choice.backend, SecretBackend.file);
      expect(File(path('secrets.json')).existsSync(), isTrue);
    });

    test('Linux: без хранилища системы — файл', () async {
      final choice = await openSecretStore(
        plainPath: path('secrets.json'),
        secure: null,
        backend: SecretBackend.file,
      );
      expect(choice.backend, SecretBackend.file);
    });
  });

  group('IncomingItem', () {
    test('только знакомые виды и не длиннее 2048', () {
      expect(
        IncomingItem.fromMap(<String, Object?>{
          'kind': 'link',
          'text': 'tridot://connect?u=x&qr=y',
        })?.kind,
        IncomingKind.link,
      );
      expect(
        IncomingItem.fromMap(<String, Object?>{'kind': 'image', 'path': '/c'})
            ?.path,
        '/c',
      );
      expect(IncomingItem.fromMap(<String, Object?>{'kind': 'run'}), isNull);
      expect(
        IncomingItem.fromMap(<String, Object?>{
          'kind': 'text',
          'text': 'x' * 3000,
        }),
        isNull,
      );
      expect(IncomingItem.fromMap('строка'), isNull);
      expect(
        const IncomingItem.link('tridot://connect?qr=secret').toString(),
        isNot(contains('secret')),
      );
    });
  });
}

/// Хранилище системы, которое не работает (нет связки ключей).
final class _Failing implements SecretStore {
  @override
  Future<String?> read(String key) => throw StateError('нет');

  @override
  Future<void> write(String key, String value) => throw StateError('нет');

  @override
  Future<void> delete(String key) => throw StateError('нет');
}

/// Проба проходит, а перенесённые ключи не читаются обратно.
final class _Forgetful implements SecretStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String key) async =>
      key == 'tridot.probe' ? _values[key] : null;

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}
