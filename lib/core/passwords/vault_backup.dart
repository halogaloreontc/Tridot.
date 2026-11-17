import 'dart:convert';
import 'dart:typed_data';

import '../app_info.dart';
import 'import_rules.dart';
import 'secret_bytes.dart';
import 'vault_errors.dart';
import 'vault_format.dart';

/// Резервная копия `.relaybak` (4.3, 5.7): тот же конверт, что у
/// хранилища, с `kind: backup`, своим `vault_id`, ключом и солью.
abstract final class VaultBackup {
  /// Предел размера файла копии.
  static const int maxBytes = 20 * 1024 * 1024;

  /// Предел числа записей.
  static const int maxEntries = 20000;

  static const String extension = 'relaybak';

  /// Версия приложения внутри индекса копии (`app_version`).
  static const String appVersion = AppInfo.version;

  /// `svyaznoy-paroli-2026-11-10.relaybak`.
  static String fileName(DateTime day) {
    String two(int n) => n.toString().padLeft(2, '0');
    final local = day.toLocal();
    return 'svyaznoy-paroli-${local.year}-${two(local.month)}-'
        '${two(local.day)}.$extension';
  }
}

/// Запись индекса копии, прошедшая строгую проверку схемы (4.3). Секрет
/// ещё не расшифрован.
final class BackupEntryInfo {
  const BackupEntryInfo({
    required this.id,
    required this.srev,
    required this.service,
    required this.login,
    required this.hint,
    required this.urls,
    required this.aliases,
    required this.created,
    required this.changed,
    required this.fp,
    required this.fpOld,
    this.history = const <HistoryMeta>[],
  });

  final String id;
  final int srev;
  final String service;
  final String login;
  final String hint;
  final List<String> urls;
  final List<String> aliases;
  final DateTime created;
  final DateTime changed;
  final Uint8List fp;
  final List<Uint8List> fpOld;

  /// Хронология паролей (ADR-015): битый элемент пропущен, запись
  /// остаётся.
  final List<HistoryMeta> history;

  @override
  String toString() => 'BackupEntryInfo($id)';
}

/// Расшифрованная копия: только записи и `k_fp` (4.3). `prefs`, `master`,
/// `backup`, `extra` и неизвестные поля отброшены — копия не включит
/// `hints_in_history`, не удлинит автозапирание, не выключит тренировку.
/// Вызывающий затирает всё ([wipe]).
final class BackupContents {
  BackupContents({
    required this.items,
    required this.kFp,
    required this.skipped,
    this.exportedAt,
  });

  final List<ImportItem> items;

  /// Ключ отпечатков копии (32 байта) — только для «Создать из копии».
  final SecretBytes kFp;

  /// Сколько записей пропущено из-за нарушения схемы (без содержимого).
  final int skipped;
  final DateTime? exportedAt;

  /// В копии есть прежние пароли (хронология, ADR-015).
  bool get hasHistory =>
      items.any((ImportItem item) => item.history.isNotEmpty);

  void wipe() {
    for (final item in items) {
      item.wipe();
    }
    kFp.wipe();
  }

  @override
  String toString() => 'BackupContents(${items.length}, skipped $skipped)';
}

/// Строгий разбор индекса копии: копию мог прислать кто угодно, поэтому
/// после расшифровки она — недоверенные данные (15.4, А4).
abstract final class BackupIndexReader {
  /// Разбор дополненного тела индекса (буфер [padded] затирается). Берёт
  /// только `entries`, `k_fp` и `exported_at`. Запись, нарушающая схему,
  /// пропускается (итог — число). Сам файл не по формату — `corrupt`.
  static (SecretBytes, List<BackupEntryInfo>, int, DateTime?) parse(
    Uint8List padded, {
    required int rev,
  }) {
    try {
      final body = VaultPadding.unpad(padded, VaultFormat.indexBlock);
      final json = JsonLimits.decode(body);
      if (json is! Map<String, Object?>) throw VaultError.corrupt;
      final schema = json['schema'];
      if (schema is! int || schema < 0) throw VaultError.corrupt;
      if (schema > VaultFormat.indexSchema) throw VaultError.tooNew;
      if (json['rev'] != rev) throw VaultError.corrupt;
      final rawKey = json['k_fp'];
      if (rawKey is! String || rawKey.length != 44) throw VaultError.corrupt;
      final Uint8List key;
      try {
        key = base64.decode(rawKey);
      } catch (_) {
        throw VaultError.corrupt;
      }
      if (key.length != VaultFormat.keyBytes) throw VaultError.corrupt;
      final kFp = SecretBytes.adopt(key);
      final raw = json['entries'];
      if (raw is! List<Object?> || raw.length > VaultBackup.maxEntries) {
        kFp.wipe();
        throw VaultError.corrupt;
      }
      final entries = <BackupEntryInfo>[];
      final ids = <String>{};
      var skipped = 0;
      for (final item in raw) {
        final entry = _entry(item);
        if (entry == null || !ids.add(entry.id)) {
          skipped++;
          continue;
        }
        entries.add(entry);
      }
      final exported = json['exported_at'];
      return (
        kFp,
        entries,
        skipped,
        exported is String ? DateTime.tryParse(exported) : null,
      );
    } on VaultError {
      rethrow;
    } catch (_) {
      throw VaultError.corrupt;
    } finally {
      padded.fillRange(0, padded.length, 0);
    }
  }

  static BackupEntryInfo? _entry(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final id = json['id'];
    final srev = json['srev'];
    if (id is! String || !VaultIds.isEntryId(id)) return null;
    if (srev is! int || srev < 1) return null;
    final service = _text(json['service'], VaultFormat.maxService);
    final login = _text(json['login'], VaultFormat.maxLogin, optional: true);
    final hint = _text(json['hint'], VaultFormat.maxHint, optional: true);
    if (service == null || service.isEmpty || login == null || hint == null) {
      return null;
    }
    final rawUrls = json['urls'];
    final urls = <String>[];
    if (rawUrls != null) {
      if (rawUrls is! List<Object?> || rawUrls.length > VaultFormat.maxUrls) {
        return null;
      }
      for (final u in rawUrls) {
        if (u is! String || u.length > VaultFormat.maxUrl) return null;
        // Недопустимая схема — адрес отбрасывается, запись остаётся.
        final safe = ImportRules.url(u);
        if (safe != null && !urls.contains(safe)) urls.add(safe);
      }
    }
    final rawAliases = json['aliases'];
    final aliases = <String>[];
    if (rawAliases != null) {
      if (rawAliases is! List<Object?> ||
          rawAliases.length > VaultFormat.maxAliases) {
        return null;
      }
      for (final a in rawAliases) {
        final alias = _text(a, VaultFormat.maxService);
        if (alias == null) return null;
        if (alias.isNotEmpty) aliases.add(alias);
      }
    }
    final created = _date(json['created']);
    final changed = _date(json['changed']);
    final fp = _fp(json['fp']);
    if (created == null || changed == null || fp == null) return null;
    final rawOld = json['fp_old'];
    final fpOld = <Uint8List>[];
    if (rawOld != null) {
      if (rawOld is! List<Object?> ||
          rawOld.length > VaultEntry.maxOldFingerprints) {
        return null;
      }
      for (final o in rawOld) {
        final old = _fp(o);
        if (old == null) return null;
        fpOld.add(old);
      }
    }
    // Хронология строго, но по элементам: битый элемент или повтор
    // пропускается, запись остаётся. Лишнее сверх предела отброшено.
    final rawHistory = json['hist'];
    final history = <HistoryMeta>[];
    if (rawHistory is List<Object?>) {
      final seen = <String>{};
      for (final h in rawHistory.take(VaultEntry.maxHistory)) {
        final meta = HistoryMeta.tryParse(h);
        if (meta != null && seen.add(meta.id)) history.add(meta);
      }
    }
    return BackupEntryInfo(
      id: id,
      srev: srev,
      service: service,
      login: login,
      hint: hint,
      urls: List<String>.unmodifiable(urls),
      aliases: List<String>.unmodifiable(aliases),
      created: created,
      changed: changed,
      fp: fp,
      fpOld: List<Uint8List>.unmodifiable(fpOld),
      history: List<HistoryMeta>.unmodifiable(history),
    );
  }

  static String? _text(Object? value, int max, {bool optional = false}) {
    if (value == null) return optional ? '' : null;
    if (value is! String) return null;
    if (value.length > max || ImportRules.hasForbiddenChars(value)) {
      return null;
    }
    return value.trim();
  }

  static DateTime? _date(Object? value) {
    if (value is! String || value.length > 40) return null;
    return DateTime.tryParse(value);
  }

  static Uint8List? _fp(Object? value) {
    if (value is! String || value.length != 44) return null;
    try {
      final bytes = base64.decode(value);
      return bytes.length == VaultFormat.keyBytes ? bytes : null;
    } catch (_) {
      return null;
    }
  }
}
