import 'dart:typed_data';

import 'vault.dart';
import 'vault_format.dart';

/// Ссылка на запись для навыка: id, название и логин в маске. Ни пароля,
/// ни подсказки, ни заметки.
final class VaultEntryRef {
  const VaultEntryRef({
    required this.id,
    required this.service,
    required this.maskedLogin,
  });

  final String id;
  final String service;

  /// `iv***@mail.ru` (D15) или логин целиком, если включено
  /// `prefs.login_in_replies`.
  final String maskedLogin;

  @override
  String toString() => 'VaultEntryRef($id)';
}

/// Сводка для «Расширений» и ответов: только числа и состояние.
final class VaultSummary {
  const VaultSummary({
    required this.state,
    required this.count,
    this.lockAt,
  });

  final VaultState state;

  /// Записей; `0`, пока заперто (число неизвестно без индекса).
  final int count;

  /// Когда запрётся само.
  final DateTime? lockAt;

  @override
  String toString() => 'VaultSummary(${state.name}, $count)';
}

/// Отчёт проверки для истории: только числа и id (названия — во
/// временной карточке, D16).
final class VaultCheckReport {
  const VaultCheckReport({
    required this.total,
    required this.reused,
    required this.reusedPlaces,
    required this.weak,
    required this.old,
    required this.ids,
  });

  final int total;

  /// Групп с одинаковым паролем и сколько записей в них.
  final int reused;
  final int reusedPlaces;
  final int weak;
  final int old;

  /// Записи с замечаниями.
  final List<String> ids;

  @override
  String toString() => 'VaultCheckReport($total)';
}

/// Всё, что навык «Пароли» видит в хранилище (раздел 10).
///
/// Методов, отдающих пароль, подсказку или заметку, здесь нет и не будет:
/// их читают `VaultRevealService` и экраны в `lib/app` прямо из [Vault].
/// Подсказка в истории — только [hintForHistory] и только при флаге
/// `prefs.hints_in_history`.
final class VaultFacade {
  VaultFacade(this._vault);

  final Vault _vault;

  VaultState get state => _vault.state;

  bool get isUnlocked => _vault.isUnlocked;

  void addListener(void Function(VaultSignal) listener) =>
      _vault.addListener(listener);

  void removeListener(void Function(VaultSignal) listener) =>
      _vault.removeListener(listener);

  /// Записи, у которых [query] входит в название, синоним или адрес
  /// (без учёта регистра). Пусто, пока заперто.
  List<VaultEntryRef> find(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const <VaultEntryRef>[];
    return <VaultEntryRef>[
      for (final entry in _vault.entries)
        if (<String>[entry.service, ...entry.aliases, ...entry.urls]
            .any((String s) => s.toLowerCase().contains(needle)))
          _ref(entry),
    ];
  }

  /// Все записи ссылками (для списка в карточке).
  List<VaultEntryRef> all() =>
      <VaultEntryRef>[for (final entry in _vault.entries) _ref(entry)];

  VaultEntryRef _ref(VaultEntry entry) => VaultEntryRef(
        id: entry.id,
        service: entry.service,
        maskedLogin: _vault.prefs['login_in_replies'] == true
            ? entry.login
            : maskLogin(entry.login),
      );

  bool hasHint(String id) => _vault.entry(id)?.hasHint ?? false;

  VaultSummary summary() => VaultSummary(
        state: _vault.state,
        count: _vault.entries.length,
        lockAt: _vault.lockAt,
      );

  /// Повторы по отпечаткам и флаги записей (полная оценка надёжности —
  /// этап 3).
  VaultCheckReport checkReport() {
    final entries = _vault.entries;
    final groups = <List<VaultEntry>>[];
    for (final entry in entries) {
      final group = groups
          .where((List<VaultEntry> g) => _same(g.first.fp, entry.fp))
          .firstOrNull;
      if (group == null) {
        groups.add(<VaultEntry>[entry]);
      } else {
        group.add(entry);
      }
    }
    final reused = groups.where((List<VaultEntry> g) => g.length > 1).toList();
    final flagged = <String>{
      for (final g in reused) ...g.map((VaultEntry e) => e.id),
      for (final e in entries)
        if (e.flags.contains('weak') || e.flags.contains('old')) e.id,
    };
    return VaultCheckReport(
      total: entries.length,
      reused: reused.length,
      reusedPlaces: reused.fold(0, (int n, List<VaultEntry> g) => n + g.length),
      weak: entries.where((VaultEntry e) => e.flags.contains('weak')).length,
      old: entries.where((VaultEntry e) => e.flags.contains('old')).length,
      ids: flagged.toList(),
    );
  }

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// Есть ли запись, которую пора тренировать (`train.next` наступил).
  bool trainingDue(DateTime now) => _vault.entries.any((VaultEntry e) {
        final next = DateTime.tryParse('${e.train['next']}');
        return e.important && next != null && !now.isBefore(next);
      });

  Future<void> delete(String id) => _vault.deleteEntry(id);

  void lock() => _vault.lock();

  /// Совпадает ли [token] с паролем записи (для `SecretGuard`).
  bool knownSecret(String token) => _vault.matchesKnownSecret(token);

  /// Подсказка для текста истории — только при `prefs.hints_in_history`
  /// (по умолчанию выключено, решение владельца №1).
  String? hintForHistory(String id) {
    if (_vault.prefs['hints_in_history'] != true) return null;
    final hint = _vault.entry(id)?.hint;
    return hint == null || hint.isEmpty ? null : hint;
  }

  /// Логин в маске: `ivanov@mail.ru` → `iv***@mail.ru`, `ivanov` → `iv***`.
  static String maskLogin(String login) {
    if (login.isEmpty) return '';
    final at = login.indexOf('@');
    final local = at < 0 ? login : login.substring(0, at);
    final domain = at < 0 ? '' : login.substring(at);
    final keep = local.length > 2 ? 2 : (local.isEmpty ? 0 : 1);
    return '${local.substring(0, keep)}***$domain';
  }

  @override
  String toString() => 'VaultFacade(${state.name})';
}
