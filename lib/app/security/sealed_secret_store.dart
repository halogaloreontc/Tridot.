import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/connectors/file_secret_store.dart';
import '../../core/connectors/secret_store.dart';
import '../passwords/device_keys.dart';

/// Шифрует и расшифровывает байты ключом, который не покидает систему
/// (ADR-031): Android Keystore, DPAPI на Windows. Ошибка — исключение.
abstract interface class SecretSealer {
  /// `android-keystore`, `windows-dpapi`: пишется в файл, чтобы чужой
  /// формат не пытались открыть.
  String get kind;

  Future<Uint8List> seal(Uint8List plain);

  Future<Uint8List> open(Uint8List sealed);
}

/// AES-256-GCM ключом `tridot-secrets` в Android Keystore (канал
/// `tridot/secrets`, SecretsChannel.kt): StrongBox, если есть, иначе TEE;
/// без проверки личности — ключи склада нужны и без разблокировки сейфа.
final class AndroidKeystoreSealer implements SecretSealer {
  const AndroidKeystoreSealer([
    this.channel = const MethodChannel('tridot/secrets'),
  ]);

  final MethodChannel channel;

  @override
  String get kind => 'android-keystore';

  @override
  Future<Uint8List> seal(Uint8List plain) async {
    final out = await channel.invokeMethod<Uint8List>(
      'seal',
      <String, Object?>{'data': plain},
    );
    if (out == null || out.isEmpty) throw StateError('seal');
    return out;
  }

  @override
  Future<Uint8List> open(Uint8List sealed) async {
    final out = await channel.invokeMethod<Uint8List>(
      'open',
      <String, Object?>{'data': sealed},
    );
    if (out == null) throw StateError('open');
    return out;
  }
}

/// DPAPI текущего пользователя Windows — тот же защитник, что у ключа
/// сейфа (ADR-025).
final class DpapiSealer implements SecretSealer {
  const DpapiSealer([this.protector = const DpapiProtector()]);

  final DpapiProtector protector;

  @override
  String get kind => 'windows-dpapi';

  @override
  Future<Uint8List> seal(Uint8List plain) async => protector.protect(plain);

  @override
  Future<Uint8List> open(Uint8List sealed) async => protector.unprotect(sealed);
}

/// Секреты подключений одним зашифрованным файлом (ADR-031):
/// `{"format":"tridot-sealed/1","kind":…,"data":<base64>}`. Ключ
/// шифрования — у системы ([SecretSealer]); в файле только шифротекст.
///
/// Файл не открылся:
/// - чужой формат или испорчен (восстановлен из копии с другого
///   устройства) — секретов нет, файл при первой записи откладывается в
///   `.bad`, подключение просит новый вход;
/// - не расшифровался — сначала проверяем, работает ли ключ системы
///   (шифруем и открываем пробу). Работает — ключ сменился, файл в `.bad`.
///   Не работает (временный сбой Keystore, DPAPI, канала) — файл не
///   трогаем и не пишем поверх ([write] бросает), чтение пробует снова:
///   сбой не стирает ключи.
final class SealedSecretStore implements SecretStore {
  SealedSecretStore(this.filePath, this.sealer);

  static const String format = 'tridot-sealed/1';

  final String filePath;
  final SecretSealer sealer;
  Map<String, String>? _cache;
  Future<void> _writes = Future<void>.value();

  /// Файл есть, а прочитать его не вышло: `foreign` — чужой или
  /// испорченный, `sealed` — не расшифровался.
  _Unreadable? _unreadable;

  /// Файл есть, но сейчас не открывается (ключи на месте, писать нельзя).
  Future<bool> unreadable() async {
    await _values();
    return _unreadable != null;
  }

  Future<Map<String, String>> _values() async {
    final cached = _cache;
    if (cached != null) return cached;
    final file = File(filePath);
    try {
      if (!await file.exists()) {
        _unreadable = null;
        return _cache = <String, String>{};
      }
    } on Object {
      _unreadable = _Unreadable.sealed;
      return <String, String>{};
    }
    Map<Object?, Object?> head;
    Uint8List data;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map ||
          decoded['format'] != format ||
          decoded['kind'] != sealer.kind ||
          decoded['data'] is! String) {
        throw const FormatException('sealed');
      }
      head = decoded;
      data = base64Decode(head['data'] as String);
    } on FileSystemException {
      _unreadable = _Unreadable.sealed;
      return <String, String>{};
    } on Object {
      _unreadable = _Unreadable.foreign;
      return <String, String>{};
    }
    final Uint8List plain;
    try {
      plain = await sealer.open(data);
    } on Object {
      // Не кэшируем: следующее чтение попробует снова.
      _unreadable = _Unreadable.sealed;
      return <String, String>{};
    }
    final values = <String, String>{};
    try {
      final decoded = jsonDecode(utf8.decode(plain));
      if (decoded is Map) {
        for (final MapEntry(:key, :value) in decoded.entries) {
          if (key is String && value is String) values[key] = value;
        }
      }
    } on Object {
      _unreadable = _Unreadable.foreign;
      return <String, String>{};
    }
    _unreadable = null;
    return _cache = values;
  }

  /// Ключ системы сейчас работает: проба шифруется и открывается.
  Future<bool> _sealerWorks() async {
    try {
      final probe = Uint8List.fromList(utf8.encode('tridot-probe'));
      final back = await sealer.open(await sealer.seal(probe));
      return utf8.decode(back) == 'tridot-probe';
    } on Object {
      return false;
    }
  }

  /// Непрочитанный файл — в `.bad` (прежний `.bad` заменяется): новый
  /// вход пишет с чистого листа, а шифротекст не теряется молча.
  Future<void> _setAside() async {
    final bad = File('$filePath.bad');
    if (await bad.exists()) await bad.delete();
    await File(filePath).rename(bad.path);
    _unreadable = null;
  }

  @override
  Future<String?> read(String key) async => (await _values())[key];

  @override
  Future<void> write(String key, String value) =>
      _mutate((Map<String, String> values) {
        values[key] = value;
        return true;
      });

  @override
  Future<void> delete(String key) => _mutate(
        (Map<String, String> values) => values.remove(key) != null,
      );

  /// Изменения по очереди: каждое читает итог предыдущего. В кэш — только
  /// после записи на диск; [change] вернул `false` — писать нечего.
  Future<void> _mutate(bool Function(Map<String, String> values) change) {
    final write = _writes.then((_) async {
      var current = await _values();
      if (_unreadable case final _Unreadable why) {
        if (why == _Unreadable.sealed && !await _sealerWorks()) {
          // Временный сбой ключа системы: файл с ключами не трогаем.
          throw StateError('sealed secrets unavailable');
        }
        await _setAside();
        current = const <String, String>{};
      }
      final values = Map<String, String>.of(current);
      if (!change(values)) return;
      final sealed = await sealer.seal(
        Uint8List.fromList(utf8.encode(jsonEncode(values))),
      );
      final text = jsonEncode(<String, Object?>{
        'format': format,
        'kind': sealer.kind,
        'data': base64Encode(sealed),
      });
      final file = File(filePath);
      await file.parent.create(recursive: true);
      final temporary = File('$filePath.tmp');
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(filePath);
      _cache = values;
    });
    _writes = write.catchError((Object _) {});
    return write;
  }
}

enum _Unreadable { foreign, sealed }

/// Связка ключей Mac (ADR-031): «общий пароль» на каждый ключ, служба
/// `Tridot connections`, доступ после первой разблокировки и только на
/// этом устройстве (KeychainChannel.swift, канал `tridot/keychain`).
final class KeychainSecretStore implements SecretStore {
  const KeychainSecretStore([
    this.channel = const MethodChannel('tridot/keychain'),
  ]);

  final MethodChannel channel;

  @override
  Future<String?> read(String key) =>
      channel.invokeMethod<String>('read', <String, Object?>{'key': key});

  @override
  Future<void> write(String key, String value) => channel.invokeMethod<void>(
        'write',
        <String, Object?>{'key': key, 'value': value},
      );

  @override
  Future<void> delete(String key) =>
      channel.invokeMethod<void>('delete', <String, Object?>{'key': key});
}

/// Какое хранилище секретов в работе — для экрана и журнала.
enum SecretBackend { keystore, keychain, dpapi, file }

/// Итог выбора хранилища: само хранилище и чем оно защищено.
final class SecretStoreChoice {
  const SecretStoreChoice(this.store, this.backend, {this.migrated = false});

  final SecretStore store;
  final SecretBackend backend;

  /// Ключи перенесены из открытого файла `secrets.json`.
  final bool migrated;
}

/// Открывает хранилище секретов подключений (ADR-031): защищённое
/// хранилище системы, если оно работает на этом устройстве (проба:
/// запись, чтение, удаление), иначе прежний файл `secrets.json`.
///
/// Перенос: ключи из `secrets.json` пишутся в новое хранилище, каждый
/// читается обратно; совпало всё — открытый файл и его `.tmp`
/// перезаписываются нулями и удаляются. Не совпало или сбой — файл
/// остаётся, в работе он ([SecretBackend.file]).
Future<SecretStoreChoice> openSecretStore({
  required String plainPath,
  required SecretStore? secure,
  required SecretBackend backend,
}) async {
  final plain = FileSecretStore(plainPath);
  if (secure == null) return SecretStoreChoice(plain, SecretBackend.file);
  // Зашифрованный файл есть, но сейчас не открывается (временный сбой
  // ключа системы): пробу не пишем — она переписала бы файл с ключами, — и
  // в открытый файл не уходим. Ключи вернутся при следующем запуске.
  if (secure is SealedSecretStore && await secure.unreadable()) {
    final file = File(secure.filePath);
    if (await file.exists() && !await File(plainPath).exists()) {
      return SecretStoreChoice(secure, backend);
    }
  }
  const probe = 'tridot.probe';
  try {
    await secure.write(probe, 'ok');
    final back = await secure.read(probe);
    await secure.delete(probe);
    if (back != 'ok') return SecretStoreChoice(plain, SecretBackend.file);
  } on Object {
    return SecretStoreChoice(plain, SecretBackend.file);
  }
  final file = File(plainPath);
  if (!await file.exists()) return SecretStoreChoice(secure, backend);
  try {
    final values = await plain.all();
    for (final MapEntry(:key, :value) in values.entries) {
      await secure.write(key, value);
    }
    for (final MapEntry(:key, :value) in values.entries) {
      if (await secure.read(key) != value) {
        return SecretStoreChoice(plain, SecretBackend.file);
      }
    }
    for (final path in <String>[plainPath, '$plainPath.tmp']) {
      await _wipe(File(path));
    }
    return SecretStoreChoice(secure, backend, migrated: true);
  } on Object {
    return SecretStoreChoice(plain, SecretBackend.file);
  }
}

/// Перезаписать нулями и удалить. На флеш-памяти это не гарантирует
/// стирания, но открытый текст не остаётся в файле.
Future<void> _wipe(File file) async {
  if (!await file.exists()) return;
  final length = await file.length();
  await file.writeAsBytes(Uint8List(length), flush: true);
  await file.delete();
}
