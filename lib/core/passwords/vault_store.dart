import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'vault_errors.dart';

/// Файлы хранилища (раздел 4.1) — только байты, без разбора.
///
/// Каталог `<поддержка приложения>/assistant/vault/`: `vault.relayvault`,
/// `vault.prev` (предыдущая версия), `vault.v<N>.bak` (до миграции),
/// `attempts.json` (счётчик неверных вводов, D25). Ошибки ввода-вывода —
/// [VaultError.io] без пути и причины.
abstract interface class VaultStore {
  /// Есть ли файл хранилища.
  Future<bool> hasVault();

  Future<Uint8List?> readVault();

  Future<Uint8List?> readPrevious();

  /// Атомарная запись: `.tmp` → `flush` → прежний файл в `vault.prev` →
  /// `rename`. Сбой посреди оставляет рабочим прежний файл и `vault.prev`.
  ///
  /// [replacePrevious]: в `vault.prev` идёт не прежний файл, а сама новая
  /// версия (удаление записи, новый пароль, смена мастер-пароля — прежняя
  /// версия не должна жить в `.prev`, D7). Это шаг той же записи: если он
  /// не удался, основной файл не тронут и вызывающий узнаёт об отказе
  /// целиком, а не «изменение на диске, но ошибка».
  Future<void> writeVault(Uint8List bytes, {bool replacePrevious = false});

  /// Перезаписать `vault.prev` (после удаления записи и смены
  /// мастер-пароля прежняя версия не должна жить в `.prev`).
  Future<void> writePrevious(Uint8List bytes);

  /// Версии `vault.v<N>.bak`, которые есть.
  Future<List<int>> backupVersions();

  Future<Uint8List?> readBackup(int version);

  Future<void> writeBackup(int version, Uint8List bytes);

  Future<void> deleteBackup(int version);

  /// `attempts.json` или `null`.
  Future<Uint8List?> readAttempts();

  Future<void> writeAttempts(Uint8List bytes);

  /// Остатки `.tmp` после сбоя (они зашифрованы, но не нужны).
  Future<void> removeTemporary();
}

/// Хранилище в каталоге на диске.
///
/// Каталог создаётся с правами 700 **до** первой записи (Dart не задаёт
/// режим при создании файла, поэтому `.tmp` защищает именно каталог),
/// файлы — 600 до записи содержимого (Linux и macOS).
final class FileVaultStore implements VaultStore {
  FileVaultStore(
    this.directory, {
    bool? posixPermissions,
    this.renameForTesting,
  }) : posixPermissions =
            posixPermissions ?? (Platform.isLinux || Platform.isMacOS);

  final String directory;

  /// Ставить ли права 700/600 (`chmod`).
  final bool posixPermissions;

  /// Подмена `rename` для теста сбоя посреди записи.
  final Future<void> Function(File from, String to)? renameForTesting;

  static const String vaultName = 'vault.relayvault';
  static const String previousName = 'vault.prev';
  static const String attemptsName = 'attempts.json';

  static String backupName(int version) => 'vault.v$version.bak';

  static final RegExp _backup = RegExp(r'^vault\.v(\d+)\.bak$');

  bool _prepared = false;

  String _path(String name) => p.join(directory, name);

  Future<void> _prepare() async {
    if (_prepared) return;
    final dir = Directory(directory);
    if (!await dir.exists()) await dir.create(recursive: true);
    await _chmod('700', directory);
    _prepared = true;
  }

  Future<void> _chmod(String mode, String path) async {
    if (!posixPermissions) return;
    final result = await Process.run('chmod', <String>[mode, path]);
    if (result.exitCode != 0) throw VaultError.io;
  }

  Future<T> _io<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on VaultError {
      rethrow;
    } catch (_) {
      throw VaultError.io;
    }
  }

  Future<Uint8List?> _read(String name) => _io(() async {
        final file = File(_path(name));
        if (!await file.exists()) return null;
        return file.readAsBytes();
      });

  /// `.tmp` с правами 600 → содержимое с `flush` → `rename` на место.
  Future<void> _atomic(String name, Uint8List bytes) async {
    await _prepare();
    final target = _path(name);
    final tmp = File('$target.tmp');
    if (await tmp.exists()) await tmp.delete();
    await tmp.create();
    await _chmod('600', tmp.path);
    await tmp.writeAsBytes(bytes, flush: true);
    await _rename(tmp, target);
  }

  Future<void> _rename(File from, String to) async {
    final hook = renameForTesting;
    if (hook != null) return hook(from, to);
    await from.rename(to);
  }

  @override
  Future<bool> hasVault() => _io(() => File(_path(vaultName)).exists());

  @override
  Future<Uint8List?> readVault() => _read(vaultName);

  @override
  Future<Uint8List?> readPrevious() => _read(previousName);

  @override
  Future<void> writeVault(Uint8List bytes, {bool replacePrevious = false}) =>
      _io(() async {
        await _prepare();
        final target = _path(vaultName);
        final tmp = File('$target.tmp');
        if (await tmp.exists()) await tmp.delete();
        await tmp.create();
        await _chmod('600', tmp.path);
        await tmp.writeAsBytes(bytes, flush: true);
        final current = File(target);
        if (replacePrevious) {
          // Новая версия и в .prev: сбой здесь — основной файл прежний,
          // сбой после — в .prev уже нет удалённого (старого) пароля.
          await _atomic(previousName, bytes);
        } else if (await current.exists()) {
          // Прежняя версия — в .prev своей атомарной записью: так в любой
          // момент на диске есть рабочий файл.
          await _atomic(previousName, await current.readAsBytes());
        }
        await _rename(tmp, target);
      });

  @override
  Future<void> writePrevious(Uint8List bytes) =>
      _io(() => _atomic(previousName, bytes));

  @override
  Future<List<int>> backupVersions() => _io(() async {
        final dir = Directory(directory);
        if (!await dir.exists()) return const <int>[];
        final versions = <int>[];
        await for (final entity in dir.list()) {
          final match = _backup.firstMatch(p.basename(entity.path));
          if (match != null) versions.add(int.parse(match.group(1)!));
        }
        return versions..sort();
      });

  @override
  Future<Uint8List?> readBackup(int version) => _read(backupName(version));

  @override
  Future<void> writeBackup(int version, Uint8List bytes) =>
      _io(() => _atomic(backupName(version), bytes));

  @override
  Future<void> deleteBackup(int version) => _io(() async {
        final file = File(_path(backupName(version)));
        if (await file.exists()) await file.delete();
      });

  @override
  Future<Uint8List?> readAttempts() => _read(attemptsName);

  @override
  Future<void> writeAttempts(Uint8List bytes) =>
      _io(() => _atomic(attemptsName, bytes));

  @override
  Future<void> removeTemporary() => _io(() async {
        final dir = Directory(directory);
        if (!await dir.exists()) return;
        await for (final entity in dir.list()) {
          if (entity is File && entity.path.endsWith('.tmp')) {
            await entity.delete();
          }
        }
      });

  @override
  String toString() => 'FileVaultStore';
}

/// Хранилище в памяти: тесты и корпус фраз.
final class InMemoryVaultStore implements VaultStore {
  final Map<String, Uint8List> files = <String, Uint8List>{};

  /// Следующая запись хранилища упадёт (проверка атомарности).
  bool failNextWrite = false;

  Uint8List? _get(String name) {
    final bytes = files[name];
    return bytes == null ? null : Uint8List.fromList(bytes);
  }

  void _put(String name, Uint8List bytes) {
    files[name] = Uint8List.fromList(bytes);
  }

  @override
  Future<bool> hasVault() async => files.containsKey(FileVaultStore.vaultName);

  @override
  Future<Uint8List?> readVault() async => _get(FileVaultStore.vaultName);

  @override
  Future<Uint8List?> readPrevious() async => _get(FileVaultStore.previousName);

  @override
  Future<void> writeVault(
    Uint8List bytes, {
    bool replacePrevious = false,
  }) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw VaultError.io;
    }
    final current = files[FileVaultStore.vaultName];
    if (replacePrevious) {
      _put(FileVaultStore.previousName, bytes);
    } else if (current != null) {
      _put(FileVaultStore.previousName, current);
    }
    _put(FileVaultStore.vaultName, bytes);
  }

  @override
  Future<void> writePrevious(Uint8List bytes) async =>
      _put(FileVaultStore.previousName, bytes);

  @override
  Future<List<int>> backupVersions() async => <int>[
        for (final name in files.keys)
          if (FileVaultStore._backup.firstMatch(name) case final match?)
            int.parse(match.group(1)!),
      ]..sort();

  @override
  Future<Uint8List?> readBackup(int version) async =>
      _get(FileVaultStore.backupName(version));

  @override
  Future<void> writeBackup(int version, Uint8List bytes) async =>
      _put(FileVaultStore.backupName(version), bytes);

  @override
  Future<void> deleteBackup(int version) async =>
      files.remove(FileVaultStore.backupName(version));

  @override
  Future<Uint8List?> readAttempts() async => _get(FileVaultStore.attemptsName);

  @override
  Future<void> writeAttempts(Uint8List bytes) async =>
      _put(FileVaultStore.attemptsName, bytes);

  @override
  Future<void> removeTemporary() async {}

  @override
  String toString() => 'InMemoryVaultStore';
}

/// Счётчик неверных вводов мастер-пароля (D25, `attempts.json`): только
/// число ошибок и время, без вводов и отпечатков. Переживает перезапуск.
final class VaultAttempts {
  const VaultAttempts({this.fails = 0, this.nextAt, this.lastAt});

  /// Неверных вводов подряд.
  final int fails;

  /// Раньше этого времени попытки не принимаются.
  final DateTime? nextAt;

  /// Время последней неверной попытки (защита от перевода часов назад).
  final DateTime? lastAt;

  /// После скольких ошибок начинается пауза.
  static const int freeAttempts = 5;
  static const Duration firstPause = Duration(seconds: 30);
  static const Duration maxPause = Duration(minutes: 15);

  /// Пауза после [fails] ошибок: после 5 — 30 с, дальше удвоение до 15 мин.
  static Duration pauseFor(int fails) {
    if (fails < freeAttempts) return Duration.zero;
    var pause = firstPause;
    for (var i = freeAttempts; i < fails && pause < maxPause; i++) {
      pause *= 2;
    }
    return pause > maxPause ? maxPause : pause;
  }

  /// Состояние на [now]: если часы ушли назад (`now < lastAt`), пауза
  /// отсчитывается заново от [now], а не снимается.
  VaultAttempts at(DateTime now) {
    final last = lastAt;
    if (last == null || !now.isBefore(last)) return this;
    final pause = pauseFor(fails);
    return VaultAttempts(
      fails: fails,
      lastAt: now,
      nextAt: pause == Duration.zero ? null : now.add(pause),
    );
  }

  /// Пауза ещё идёт: до какого времени.
  DateTime? blockedUntil(DateTime now) {
    final next = nextAt;
    return next != null && now.isBefore(next) ? next : null;
  }

  /// Ещё одна неверная попытка в [now].
  VaultAttempts failed(DateTime now) {
    final count = fails + 1;
    final pause = pauseFor(count);
    return VaultAttempts(
      fails: count,
      lastAt: now,
      nextAt: pause == Duration.zero ? null : now.add(pause),
    );
  }

  bool get isClear => fails == 0 && nextAt == null && lastAt == null;

  Uint8List encode() => Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'fails': fails,
            if (nextAt != null) 'next_at': nextAt!.toUtc().toIso8601String(),
            if (lastAt != null) 'last_at': lastAt!.toUtc().toIso8601String(),
          }),
        ),
      );

  /// Испорченный или отсутствующий файл — пустой счётчик. Удалить файл
  /// может только тот, у кого есть доступ к каталогу приложения; на
  /// Android без root до него не добраться (раздел 15.5).
  static VaultAttempts decode(Uint8List? bytes) {
    if (bytes == null) return const VaultAttempts();
    try {
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map<String, Object?>) return const VaultAttempts();
      final fails = json['fails'];
      return VaultAttempts(
        fails: fails is int && fails >= 0 ? fails : 0,
        nextAt: DateTime.tryParse('${json['next_at']}'),
        lastAt: DateTime.tryParse('${json['last_at']}'),
      );
    } catch (_) {
      return const VaultAttempts();
    }
  }

  @override
  String toString() => 'VaultAttempts($fails)';
}
