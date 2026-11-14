import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart' as hash;
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../core/passwords/vault_crypto.dart';
import '../../core/passwords/vault_device_key.dart';
import '../security/device_auth.dart';

/// Ключ устройства для сейфа на этой платформе (ADR-025):
///
/// * Android — Android Keystore через канал `tridot/vault_key`
///   (неэкспортируемый ключ HMAC в StrongBox или TEE);
/// * Windows — секрет, защищённый DPAPI учётной записи;
/// * macOS и Linux — честный запасной вариант: секрет файлом с правами
///   600 в папке приложения ([FileVaultDeviceKey]). Keychain и Secret
///   Service — позже (ADR-025: подпись ad-hoc и отсутствие libsecret при
///   сборке).
///
/// [directory] — папка ключей на компьютере (`<поддержка>/assistant/
/// vault_keys`, рядом с сейфом, но не внутри него).
VaultDeviceKey deviceKeyFor(String directory, VaultRandom random) {
  if (Platform.isAndroid) return const AndroidVaultDeviceKey();
  if (Platform.isWindows) {
    return FileVaultDeviceKey(
      directory,
      random,
      kind: VaultDeviceKinds.windowsDpapi,
      protector: const DpapiProtector(),
    );
  }
  return FileVaultDeviceKey(directory, random);
}

/// Android Keystore (MainActivity, `VaultKeyChannel.kt`).
final class AndroidVaultDeviceKey implements VaultDeviceKey {
  const AndroidVaultDeviceKey([
    this.channel = const MethodChannel('tridot/vault_key'),
  ]);

  final MethodChannel channel;

  @override
  String get kind => VaultDeviceKinds.androidKeystore;

  @override
  bool get pinAllowed => true;

  @override
  Future<bool> bioAvailable() async {
    try {
      return await channel.invokeMethod<bool>('bioAvailable') ?? false;
    } on Object {
      return false;
    }
  }

  @override
  Future<String> create({bool userAuth = false}) => _call(() async {
        final alias = await channel.invokeMethod<String>(
          'create',
          <String, Object?>{'userAuth': userAuth},
        );
        if (alias == null) {
          throw const DeviceKeyException(DeviceKeyFailure.unavailable);
        }
        return alias;
      });

  @override
  Future<Uint8List> mac(
    String alias,
    Uint8List message, {
    String? reason,
  }) {
    Future<Uint8List> run() => _call(() async {
          final copy = Uint8List.fromList(message);
          try {
            final out = await channel.invokeMethod<Uint8List>(
              'mac',
              <String, Object?>{
                'alias': alias,
                'message': copy,
                if (reason != null) 'reason': reason,
              },
            );
            if (out == null) {
              throw const DeviceKeyException(DeviceKeyFailure.unavailable);
            }
            return out;
          } finally {
            copy.fillRange(0, copy.length, 0);
          }
        });
    // Запрос личности уводит приложение за системный экран: сейф не
    // запирается от этого (SystemAuthGuard).
    return reason == null ? run() : SystemAuthGuard.run(run);
  }

  @override
  Future<void> delete(String alias) => _call(
        () => channel.invokeMethod<void>(
          'delete',
          <String, Object?>{'alias': alias},
        ),
      );

  static Future<T> _call<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on PlatformException catch (error) {
      throw DeviceKeyException(
        switch (error.code) {
          'KEY_LOST' => DeviceKeyFailure.lost,
          'KEY_INVALIDATED' => DeviceKeyFailure.invalidated,
          'AUTH_CANCELED' => DeviceKeyFailure.canceled,
          'AUTH_LOCKOUT' => DeviceKeyFailure.lockout,
          _ => DeviceKeyFailure.unavailable,
        },
      );
    } on MissingPluginException {
      throw const DeviceKeyException(DeviceKeyFailure.unavailable);
    }
  }
}

/// Защита секрета ключа на диске: DPAPI на Windows; без неё — как есть.
abstract interface class KeyProtector {
  Uint8List protect(Uint8List data);

  Uint8List unprotect(Uint8List data);
}

/// Ключ устройства файлом: 32 случайных байта на имя ключа в [directory]
/// (права 700/600 на Linux и macOS), HMAC-SHA256 считается здесь.
///
/// Без [protector] это честный запасной вариант (`file-key`): защищает
/// только учётная запись — копия папки приложения целиком открывает сейф.
/// С DPAPI (`windows-dpapi`) копия файла на другой компьютер или в другую
/// учётную запись бесполезна; от программы, запущенной той же учётной
/// записью, DPAPI не защищает.
///
/// ПИН-код не включается ни там, ни там: один вызов `CryptUnprotectData`
/// под учётной записью отдаёт сырой секрет HMAC, и дальше миллион
/// ПИН-кодов перебирают офлайн на любой машине, а счётчик попыток лежит
/// в той же папке и удаляется без прав администратора (ADR-025).
final class FileVaultDeviceKey implements VaultDeviceKey {
  FileVaultDeviceKey(
    this.directory,
    this.random, {
    this.kind = VaultDeviceKinds.fileKey,
    this.protector,
    bool? posixPermissions,
  }) : posixPermissions =
            posixPermissions ?? (Platform.isLinux || Platform.isMacOS);

  final String directory;
  final VaultRandom random;
  final KeyProtector? protector;
  final bool posixPermissions;

  @override
  final String kind;

  @override
  bool get pinAllowed => false;

  @override
  Future<bool> bioAvailable() async => false;

  static final RegExp _alias = RegExp(r'^[a-z0-9-]{1,64}$');

  File _file(String alias) {
    if (!_alias.hasMatch(alias)) {
      throw const DeviceKeyException(DeviceKeyFailure.lost);
    }
    return File(p.join(directory, '$alias.key'));
  }

  @override
  Future<String> create({bool userAuth = false}) async {
    if (userAuth) throw const DeviceKeyException(DeviceKeyFailure.unavailable);
    try {
      final dir = Directory(directory);
      if (!await dir.exists()) await dir.create(recursive: true);
      await _chmod('700', directory);
      final id = random.bytes(16);
      final alias =
          'k-${id.map((int b) => b.toRadixString(16).padLeft(2, '0')).join()}';
      final secret = random.bytes(32);
      final file = _file(alias);
      await file.create();
      await _chmod('600', file.path);
      try {
        final data = protector?.protect(secret) ?? secret;
        await file.writeAsBytes(data, flush: true);
      } finally {
        secret.fillRange(0, secret.length, 0);
      }
      return alias;
    } on DeviceKeyException {
      rethrow;
    } on Object {
      throw const DeviceKeyException(DeviceKeyFailure.unavailable);
    }
  }

  @override
  Future<Uint8List> mac(
    String alias,
    Uint8List message, {
    String? reason,
  }) async {
    final file = _file(alias);
    Uint8List raw;
    try {
      if (!await file.exists()) {
        throw const DeviceKeyException(DeviceKeyFailure.lost);
      }
      raw = await file.readAsBytes();
    } on DeviceKeyException {
      rethrow;
    } on Object {
      throw const DeviceKeyException(DeviceKeyFailure.unavailable);
    }
    final Uint8List secret;
    try {
      secret = protector?.unprotect(raw) ?? raw;
    } on Object {
      // Сбой DPAPI бывает временным (профиль ещё не загружен, сбой
      // мастер-ключа домена): это НЕ потеря ключа — иначе сейф снял бы
      // единственный слот. «Потерян» — только когда файла нет.
      raw.fillRange(0, raw.length, 0);
      throw const DeviceKeyException(DeviceKeyFailure.unavailable);
    }
    try {
      if (secret.length != 32) {
        throw const DeviceKeyException(DeviceKeyFailure.lost);
      }
      return Uint8List.fromList(
        hash.Hmac(hash.sha256, secret).convert(message).bytes,
      );
    } finally {
      secret.fillRange(0, secret.length, 0);
      raw.fillRange(0, raw.length, 0);
    }
  }

  @override
  Future<void> delete(String alias) async {
    try {
      final file = _file(alias);
      if (await file.exists()) {
        // Сначала затереть: удалённый файл мог бы остаться на диске.
        final length = await file.length();
        await file.writeAsBytes(Uint8List(length), flush: true);
        await file.delete();
      }
    } on Object {
      // Не удалился — останется ключом без слота.
    }
  }

  Future<void> _chmod(String mode, String path) async {
    if (!posixPermissions) return;
    final result = await Process.run('chmod', <String>[mode, path]);
    if (result.exitCode != 0) {
      throw const DeviceKeyException(DeviceKeyFailure.unavailable);
    }
  }
}

/// DPAPI текущего пользователя Windows (`CryptProtectData`), без окон
/// (`CRYPTPROTECT_UI_FORBIDDEN`). Дополнительная энтропия — метка Tridot:
/// чужая программа, не знающая её, через тот же вызов секрет не получит
/// «случайно» (от целенаправленной программы той же учётной записи это не
/// защита — честно в ADR-025).
final class DpapiProtector implements KeyProtector {
  const DpapiProtector();

  static const int _uiForbidden = 0x1;
  static final Uint8List _entropy =
      Uint8List.fromList('tridot-vault-device-key'.codeUnits);

  @override
  Uint8List protect(Uint8List data) => _run(data, protect: true);

  @override
  Uint8List unprotect(Uint8List data) => _run(data, protect: false);

  static Uint8List _run(Uint8List data, {required bool protect}) {
    final crypt32 = DynamicLibrary.open('crypt32.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final call = crypt32.lookupFunction<_CryptNative, _CryptDart>(
      protect ? 'CryptProtectData' : 'CryptUnprotectData',
    );
    final localFree =
        kernel32.lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');
    final input = calloc<_DataBlob>();
    final entropy = calloc<_DataBlob>();
    final output = calloc<_DataBlob>();
    final inBytes = calloc<Uint8>(data.length);
    final entropyBytes = calloc<Uint8>(_entropy.length);
    try {
      inBytes.asTypedList(data.length).setAll(0, data);
      entropyBytes.asTypedList(_entropy.length).setAll(0, _entropy);
      input.ref
        ..cbData = data.length
        ..pbData = inBytes;
      entropy.ref
        ..cbData = _entropy.length
        ..pbData = entropyBytes;
      final ok = call(
        input,
        nullptr,
        entropy,
        nullptr,
        nullptr,
        _uiForbidden,
        output,
      );
      if (ok == 0) throw StateError('DPAPI');
      final out = Uint8List.fromList(
        output.ref.pbData.asTypedList(output.ref.cbData),
      );
      output.ref.pbData.asTypedList(output.ref.cbData).fillRange(
            0,
            output.ref.cbData,
            0,
          );
      localFree(output.ref.pbData.cast());
      return out;
    } finally {
      inBytes.asTypedList(data.length).fillRange(0, data.length, 0);
      calloc
        ..free(inBytes)
        ..free(entropyBytes)
        ..free(input)
        ..free(entropy)
        ..free(output);
    }
  }
}

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;

  external Pointer<Uint8> pbData;
}

typedef _CryptNative = Int32 Function(
  Pointer<_DataBlob> dataIn,
  Pointer<Utf16> description,
  Pointer<_DataBlob> entropy,
  Pointer<Void> reserved,
  Pointer<Void> prompt,
  Uint32 flags,
  Pointer<_DataBlob> dataOut,
);
typedef _CryptDart = int Function(
  Pointer<_DataBlob> dataIn,
  Pointer<Utf16> description,
  Pointer<_DataBlob> entropy,
  Pointer<Void> reserved,
  Pointer<Void> prompt,
  int flags,
  Pointer<_DataBlob> dataOut,
);
typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void> memory);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void> memory);
