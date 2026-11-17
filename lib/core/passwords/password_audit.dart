import 'dart:typed_data';

import 'hint_guard.dart';
import 'keyboard_layouts.dart';
import 'password_strength.dart';
import 'secret_bytes.dart';
import 'vault_format.dart';

/// Флаги записи в индексе (5.5). `reused`, `similar` и `old` не хранятся:
/// они зависят от других записей и от даты и считаются на лету
/// ([CheckGroups]).
abstract final class EntryFlags {
  /// Оценка ≤ 2.
  static const String weak = 'weak';

  /// Короче 12 символов.
  static const String short = 'short';

  /// Пароль содержит логин.
  static const String containsLogin = 'containsLogin';

  /// Пароль содержит название сервиса.
  static const String containsService = 'containsService';

  /// Подсказка раскрывает пароль ([HintGuard]).
  static const String hintLeaks = 'hintLeaks';

  /// Новый пароль совпал с одним из прежних (`fp_old`).
  static const String returnedOld = 'returnedOld';

  /// Импортирована рядом с записью с тем же сервисом и логином, но другим
  /// паролем («оставить обе», 5.6): какой актуальный — решает человек.
  static const String importConflict = 'importConflict';

  /// Флаги, которые выставляет [PasswordAssessor] (остальные — хранилище).
  static const Set<String> assessed = <String>{
    weak,
    short,
    containsLogin,
    containsService,
    hintLeaks,
  };
}

/// Оценка и флаги записи по её паролю.
final class EntryAssessment {
  const EntryAssessment({required this.score, required this.flags});

  final int score;
  final List<String> flags;

  @override
  String toString() => 'EntryAssessment($score)';
}

/// Оценивает пароль записи: надёжность с учётом её названия, логина и
/// адресов, подсказку — [HintGuard]. Пароль не выходит наружу: только
/// число и флаги.
final class PasswordAssessor {
  PasswordAssessor(this.strength);

  final PasswordStrength strength;

  EntryAssessment assess(SecretBytes password, VaultEntry entry) {
    final login = entry.login.toLowerCase();
    final at = login.indexOf('@');
    final local = at < 0 ? login : login.substring(0, at);
    final estimate = strength.estimate(
      password,
      userInputs: <String>[
        entry.service,
        ...entry.aliases,
        if (login.isNotEmpty) login,
        if (local.isNotEmpty) local,
        for (final url in entry.urls) _host(url),
      ],
    );
    final runes = Utf8Runes.decode(password.unsafeBytes) ?? <int>[];
    final lower = KeyboardLayouts.lowerAll(runes);
    try {
      bool has(String part) =>
          part.length >= 3 && _contains(lower, part.runes.toList());
      final flags = <String>[
        if (estimate.score <= 2) EntryFlags.weak,
        if (estimate.length < 12) EntryFlags.short,
        if (has(local)) EntryFlags.containsLogin,
        if (has(entry.service.toLowerCase())) EntryFlags.containsService,
        if (!HintGuard.check(entry.hint, password, lists: strength.lists).ok)
          EntryFlags.hintLeaks,
      ];
      return EntryAssessment(score: estimate.score, flags: flags);
    } finally {
      runes.fillRange(0, runes.length, 0);
      lower.fillRange(0, lower.length, 0);
    }
  }

  static String _host(String url) {
    var rest = url.trim().toLowerCase();
    final scheme = rest.indexOf('://');
    if (scheme >= 0) rest = rest.substring(scheme + 3);
    final end = rest.indexOf(RegExp('[/:?#]'));
    if (end >= 0) rest = rest.substring(0, end);
    return rest.startsWith('www.') ? rest.substring(4) : rest;
  }

  static bool _contains(List<int> haystack, List<int> needle) {
    if (needle.isEmpty || needle.length > haystack.length) return false;
    for (var i = 0; i + needle.length <= haystack.length; i++) {
      var ok = true;
      for (var k = 0; k < needle.length; k++) {
        if (haystack[i + k] != needle[k]) {
          ok = false;
          break;
        }
      }
      if (ok) return true;
    }
    return false;
  }

  @override
  String toString() => 'PasswordAssessor';
}

/// Группы проверки (5.5) — только id записей: названия показывает
/// временная карточка и экран «Проверка», в историю — только числа (D16).
final class CheckGroups {
  const CheckGroups({
    required this.total,
    this.weak = const <String>[],
    this.reused = const <List<String>>[],
    this.similar = const <List<String>>[],
    this.old = const <String>[],
    this.unknownDate = const <String>[],
    this.hintLeaks = const <String>[],
    this.returnedOld = const <String>[],
    this.containsInfo = const <String>[],
    this.unchecked = const <String>[],
    this.pending = const <String>[],
  });

  /// Порог «старый»: 365 дней, для важных — 180.
  static const int oldDays = 365;
  static const int oldImportantDays = 180;

  /// Группы по записям [entries] на дату [now].
  ///
  /// [guarded] — важные записи без свежего мастер-пароля (15.2): в
  /// повторы и «почти повторы» они не входят. Иначе «добавить запись с
  /// догадкой → посмотреть повторы → удалить» — оракул без предела. Не
  /// входят они и в «слабые» и «в пароле название или логин»: эти флаги
  /// зависят от куска пароля, и любой их пересчёт после правки названия
  /// был бы оракулом по подстрокам. Такие записи — в [pending]
  /// («проверка после мастер-пароля»).
  factory CheckGroups.of(
    List<VaultEntry> entries,
    DateTime now, {
    bool Function(Uint8List a, Uint8List b)? equal,
    int oldAfterDays = oldDays,
    bool Function(VaultEntry entry)? guarded,
  }) {
    final same = equal ?? _equal;
    bool hidden(VaultEntry e) => guarded != null && guarded(e);
    List<List<String>> groupsBy(Uint8List? Function(VaultEntry) key) {
      final groups = <List<VaultEntry>>[];
      for (final entry in entries) {
        if (hidden(entry)) continue;
        final k = key(entry);
        if (k == null) continue;
        final group = groups
            .where((List<VaultEntry> g) => same(key(g.first)!, k))
            .firstOrNull;
        if (group == null) {
          groups.add(<VaultEntry>[entry]);
        } else {
          group.add(entry);
        }
      }
      return <List<String>>[
        for (final g in groups)
          if (g.length > 1) <String>[for (final e in g) e.id],
      ];
    }

    final reused = groupsBy((VaultEntry e) => e.fp);
    final reusedIds = <String>{for (final g in reused) ...g};
    // «Почти повтор»: тот же пароль без хвоста из цифр и знаков
    // (`Kotik2019` / `kotik2020`), если это не точный повтор.
    final similar = <List<String>>[
      for (final g in groupsBy((VaultEntry e) => e.fpLoose))
        if (!g.every(reusedIds.contains)) g,
    ];
    return CheckGroups(
      total: entries.length,
      weak: <String>[
        for (final e in entries)
          if (!hidden(e) && e.flags.contains(EntryFlags.weak)) e.id,
      ],
      reused: reused,
      similar: similar,
      old: <String>[
        for (final e in entries)
          if (e.dateSource != DateSource.unknown &&
              now.difference(e.changed).inDays >
                  (e.important ? oldImportantDays : oldAfterDays))
            e.id,
      ],
      unknownDate: <String>[
        for (final e in entries)
          if (e.dateSource == DateSource.unknown) e.id,
      ],
      hintLeaks: <String>[
        for (final e in entries)
          if (e.flags.contains(EntryFlags.hintLeaks)) e.id,
      ],
      returnedOld: <String>[
        for (final e in entries)
          if (e.flags.contains(EntryFlags.returnedOld)) e.id,
      ],
      containsInfo: <String>[
        for (final e in entries)
          if (!hidden(e) &&
              (e.flags.contains(EntryFlags.containsLogin) ||
                  e.flags.contains(EntryFlags.containsService)))
            e.id,
      ],
      unchecked: <String>[
        for (final e in entries)
          if (e.score == null) e.id,
      ],
      pending: <String>[
        for (final e in entries)
          if (hidden(e)) e.id,
      ],
    );
  }

  final int total;
  final List<String> weak;
  final List<List<String>> reused;
  final List<List<String>> similar;
  final List<String> old;
  final List<String> unknownDate;
  final List<String> hintLeaks;
  final List<String> returnedOld;
  final List<String> containsInfo;

  /// Ещё не оценённые (до первой проверки).
  final List<String> unchecked;

  /// Важные записи, проверенные не полностью: надёжность, повторы и
  /// «название в пароле» — после мастер-пароля (15.2).
  final List<String> pending;

  /// Сколько записей в группах повторов.
  int get reusedPlaces =>
      reused.fold(0, (int n, List<String> g) => n + g.length);

  /// Все записи с замечаниями.
  List<String> get flagged => <String>{
        ...weak,
        for (final g in reused) ...g,
        for (final g in similar) ...g,
        ...old,
        ...hintLeaks,
        ...returnedOld,
        ...containsInfo,
      }.toList();

  static bool _equal(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  @override
  String toString() => 'CheckGroups($total)';
}
