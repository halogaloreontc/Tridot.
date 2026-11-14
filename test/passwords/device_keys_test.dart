// Ключ устройства для сейфа (ADR-025): канал Android Keystore (подделка
// MethodChannel) и запасной вариант файлом. Значения — синтетические.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/passwords/device_keys.dart';
import 'package:local_assistant/app/security/device_auth.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_device_key.dart';
import 'package:local_assistant/core/passwords/vault_store.dart';
import 'package:path/path.dart' as p;

import 'vault_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumVaultCrypto crypto;

  setUpAll(() async {
    crypto = await testCrypto();
  });

  group('канал Android Keystore', () {
    const channel = MethodChannel('tridot/vault_key');
    final calls = <MethodCall>[];
    String? fail;
    int? activeDuringMac;

    setUp(() {
      calls.clear();
      fail = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        if (fail != null) throw PlatformException(code: fail!);
        return switch (call.method) {
          'create' => 'tridot-vault-x',
          'mac' => () {
              activeDuringMac = SystemAuthGuard.active.value;
              return Uint8List(32);
            }(),
          'bioAvailable' => true,
          _ => null,
        };
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('аргументы: создание, ответ, удаление; затирание копии сообщения',
        () async {
      const key = AndroidVaultDeviceKey();
      expect(key.kind, VaultDeviceKinds.androidKeystore);
      expect(key.pinAllowed, isTrue);
      expect(await key.create(userAuth: true), 'tridot-vault-x');
      expect(calls.last.arguments, <String, Object?>{'userAuth': true});
      final message = Uint8List.fromList(<int>[1, 2, 3]);
      final mac = await key.mac('tridot-vault-x', message);
      expect(mac, hasLength(32));
      expect(message, <int>[1, 2, 3], reason: 'исходное не трогаем');
      final args = calls.last.arguments as Map<Object?, Object?>;
      expect(args['alias'], 'tridot-vault-x');
      expect(args.containsKey('reason'), isFalse);
      expect(activeDuringMac, 0, reason: 'без запроса — не системная проверка');
      await key.mac('tridot-vault-x', message, reason: 'Открыть сейф');
      expect(
        (calls.last.arguments as Map<Object?, Object?>)['reason'],
        'Открыть сейф',
      );
      expect(activeDuringMac, 1, reason: 'запрос личности — SystemAuthGuard');
      expect(SystemAuthGuard.busy, isFalse);
      await key.delete('tridot-vault-x');
      expect(calls.last.method, 'delete');
      expect(await key.bioAvailable(), isTrue);
    });

    test('коды ошибок системы → DeviceKeyFailure', () async {
      const key = AndroidVaultDeviceKey();
      for (final (code, failure) in <(String, DeviceKeyFailure)>[
        ('KEY_LOST', DeviceKeyFailure.lost),
        ('KEY_INVALIDATED', DeviceKeyFailure.invalidated),
        ('AUTH_CANCELED', DeviceKeyFailure.canceled),
        ('AUTH_LOCKOUT', DeviceKeyFailure.lockout),
        ('UNAVAILABLE', DeviceKeyFailure.unavailable),
      ]) {
        fail = code;
        await expectLater(
          key.mac('a', Uint8List(1)),
          throwsA(
            isA<DeviceKeyException>().having(
              (DeviceKeyException e) => e.failure,
              'failure',
              failure,
            ),
          ),
        );
      }
      expect(await key.bioAvailable(), isFalse);
    });
  });

  group('ключ файлом', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('vault_keys'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('создать, ответить, удалить; ПИН-код и биометрия недоступны',
        () async {
      final key = FileVaultDeviceKey(dir.path, crypto);
      expect(key.kind, VaultDeviceKinds.fileKey);
      expect(key.pinAllowed, isFalse);
      expect(await key.bioAvailable(), isFalse);
      final alias = await key.create();
      final file = File(p.join(dir.path, '$alias.key'));
      expect(file.lengthSync(), 32);
      if (Platform.isLinux || Platform.isMacOS) {
        final mode = file.statSync().mode & 0x1FF;
        expect(mode, 0x180, reason: 'права 600');
      }
      final a = await key.mac(alias, Uint8List.fromList(<int>[7]));
      final b = await key.mac(alias, Uint8List.fromList(<int>[7]));
      expect(a, b);
      expect(a, hasLength(32));
      await key.delete(alias);
      expect(file.existsSync(), isFalse);
      await expectLater(
        key.mac(alias, Uint8List(1)),
        throwsA(isA<DeviceKeyException>()),
      );
      await expectLater(
        key.create(userAuth: true),
        throwsA(isA<DeviceKeyException>()),
      );
    });

    test('сейф на ключе файлом: защищённое создание и открытие', () async {
      final key = FileVaultDeviceKey(dir.path, crypto);
      final store = InMemoryVaultStore();
      final vault = testVault(store, crypto, deviceKey: key);
      final code = await vault.createProtected(params: fastKdf);
      code.wipe();
      vault.lock();
      final again = testVault(store, crypto, deviceKey: key);
      await again.unlockDevice();
      expect(again.isProtected, isTrue);
      expect(again.pinAllowed, isFalse);
    });

    test('защита DPAPI: ПИН-кода нет, сбой расшифровки — не «потерян»',
        () async {
      final protector = _FlakyProtector();
      final key = FileVaultDeviceKey(
        dir.path,
        crypto,
        kind: VaultDeviceKinds.windowsDpapi,
        protector: protector,
      );
      expect(key.pinAllowed, isFalse);
      final alias = await key.create();
      final good = await key.mac(alias, Uint8List.fromList(<int>[1]));
      protector.fail = true;
      await expectLater(
        key.mac(alias, Uint8List.fromList(<int>[1])),
        throwsA(
          isA<DeviceKeyException>().having(
            (DeviceKeyException e) => e.failure,
            'failure',
            DeviceKeyFailure.unavailable,
          ),
        ),
      );
      protector.fail = false;
      expect(await key.mac(alias, Uint8List.fromList(<int>[1])), good);
    });

    test('чужое имя ключа (путь) не принимается', () async {
      final key = FileVaultDeviceKey(dir.path, crypto);
      await expectLater(
        key.mac('../escape', Uint8List(1)),
        throwsA(isA<DeviceKeyException>()),
      );
    });
  });
}

/// Защита, которая может временно отказать (как DPAPI до загрузки
/// профиля). Шифрования нет — только переворот байтов.
final class _FlakyProtector implements KeyProtector {
  bool fail = false;

  @override
  Uint8List protect(Uint8List data) =>
      Uint8List.fromList(data.reversed.toList());

  @override
  Uint8List unprotect(Uint8List data) {
    if (fail) throw StateError('DPAPI');
    return Uint8List.fromList(data.reversed.toList());
  }
}
