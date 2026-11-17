import 'password_audit.dart';
import 'password_training.dart';
import 'vault.dart';
import 'vault_format.dart';
import 'vault_prefs.dart';

/// Ссылка на запись для навыка: id, название и логин в маске. Ни пароля,
/// ни подсказки, ни заметки.
final class VaultEntryRef {
  const VaultEntryRef({
    required this.id,
    required this.service,
    required this.maskedLogin,
    this.names = const <String>[],
    this.hasLogin = false,
  });

  final String id;
  final String service;

  /// По чему искать запись: название, синонимы и хосты адресов (без
  /// схемы и `www.`). Не секрет.
  final List<String> names;

  /// У записи есть логин.
  final bool hasLogin;

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
    this.similar = 0,
    this.unknownDate = 0,
    this.hintLeaks = 0,
    this.unchecked = 0,
  });

  final int total;

  /// Групп с одинаковым паролем и сколько записей в них.
  final int reused;
  final int reusedPlaces;
  final int weak;
  final int old;

  /// Групп «почти повтор» (`Kotik2019` / `kotik2020`).
  final int similar;

  /// Дата смены неизвестна.
  final int unknownDate;

  /// Подсказка раскрывает пароль.
  final int hintLeaks;

  /// Ещё не оценены (нет словарей или проверки не было).
  final int unchecked;

  /// Замечаний нет.
  bool get allGood =>
      weak == 0 && reused == 0 && old == 0 && similar == 0 && hintLeaks == 0;

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

  /// Время хранилища (часы приложения).
  DateTime get now => _vault.clock.now();

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
        maskedLogin: loginInReplies ? entry.login : maskLogin(entry.login),
        names: <String>[
          entry.service,
          ...entry.aliases,
          for (final url in entry.urls) hostOf(url),
        ],
        hasLogin: entry.login.isNotEmpty,
      );

  /// Ссылка на запись [id] или `null`.
  VaultEntryRef? ref(String id) {
    final entry = _vault.entry(id);
    return entry == null ? null : _ref(entry);
  }

  /// Хост адреса без схемы, порта, пути и `www.`: `https://www.ozon.ru/x`
  /// → `ozon.ru`; `android://…@com.vk` → `com.vk`.
  static String hostOf(String url) {
    var rest = url.trim().toLowerCase();
    final scheme = rest.indexOf('://');
    if (scheme >= 0) rest = rest.substring(scheme + 3);
    final at = rest.lastIndexOf('@');
    if (at >= 0) rest = rest.substring(at + 1);
    final end = rest.indexOf(RegExp('[/:?#]'));
    if (end >= 0) rest = rest.substring(0, end);
    return rest.startsWith('www.') ? rest.substring(4) : rest;
  }

  /// Логин в ответах целиком (`prefs.login_in_replies`), иначе в маске.
  bool get loginInReplies => VaultPrefs.loginInReplies.of(_vault.prefs);

  /// Сколько секунд виден показанный пароль (`prefs.reveal_s`).
  int get revealSeconds => VaultPrefs.revealSeconds.of(_vault.prefs);

  /// Через сколько секунд очищается буфер (`prefs.clipboard_s`).
  int get clipboardSeconds => VaultPrefs.clipboardSeconds.of(_vault.prefs);

  /// Минут простоя до запирания.
  int get idleMinutes => _vault.idleTimeout.inMinutes;

  bool hasHint(String id) => _vault.entry(id)?.hasHint ?? false;

  VaultSummary summary() => VaultSummary(
        state: _vault.state,
        count: _vault.entries.length,
        lockAt: _vault.lockAt,
      );

  /// Отчёт проверки по индексу: повторы по отпечаткам, флаги записей,
  /// даты. Только числа и id (D16).
  VaultCheckReport checkReport([DateTime? now]) {
    final groups = CheckGroups.of(
      _vault.entries,
      now ?? _vault.clock.now(),
      equal: _vault.crypto.equal,
      guarded: _vault.isGuarded,
    );
    return VaultCheckReport(
      total: groups.total,
      reused: groups.reused.length,
      reusedPlaces: groups.reusedPlaces,
      weak: groups.weak.length,
      old: groups.old.length,
      similar: groups.similar.length,
      unknownDate: groups.unknownDate.length,
      hintLeaks: groups.hintLeaks.length,
      unchecked: groups.unchecked.length,
      ids: groups.flagged,
    );
  }

  /// Полная проверка (5.5): хранилище само расшифровывает пароли по
  /// одному и пересчитывает оценки; навыку достаются только числа.
  Future<VaultCheckReport> audit([DateTime? now]) async {
    await _vault.reassess();
    return checkReport(now);
  }

  /// Есть ли запись, которую пора тренировать (5.8).
  bool trainingDue(DateTime now) => _vault.entries.any(
        (VaultEntry e) => e.important && TrainingSchedule.isDue(e.train, now),
      );

  /// Важные записи в тренировке: сначала те, кому пора, затем по дате.
  List<VaultEntryRef> trainingQueue(DateTime now) {
    final list = <VaultEntry>[
      for (final e in _vault.entries)
        if (e.important && !TrainingSchedule.isOff(e.train)) e,
    ]..sort((VaultEntry a, VaultEntry b) {
        final x = TrainingSchedule.nextOf(a.train) ?? now;
        final y = TrainingSchedule.nextOf(b.train) ?? now;
        return x.compareTo(y);
      });
    return <VaultEntryRef>[for (final e in list) _ref(e)];
  }

  /// Серия и дней до следующей тренировки записи [id].
  (int streak, int days)? training(String id, DateTime now) {
    final entry = _vault.entry(id);
    if (entry == null) return null;
    return (
      TrainingSchedule.streakOf(entry.train),
      TrainingSchedule.daysUntil(entry.train, now),
    );
  }

  /// Важная ли запись.
  bool isImportant(String id) => _vault.entry(id)?.important ?? false;

  /// Действие с записью [id] сейчас требует мастер-пароля: она важная,
  /// переспрос включён, а подтверждали больше минуты назад
  /// ([Vault.isGuarded], 3.6). Мастер-пароль спрашивает карточка, не чат.
  bool needsMaster(String id) {
    final entry = _vault.entry(id);
    return entry != null && _vault.isGuarded(entry);
  }

  /// Удалить запись. Охраняемую важную ([needsMaster]) хранилище без
  /// свежего мастер-пароля не удаляет (`StateError`).
  Future<void> delete(String id) => _vault.deleteEntry(id);

  void lock() => _vault.lock();

  /// Совпадает ли [token] с паролем записи (для `SecretGuard`).
  bool knownSecret(String token) => _vault.matchesKnownSecret(token);

  /// Подсказка для текста истории — только при `prefs.hints_in_history`
  /// (по умолчанию выключено, решение владельца №1).
  String? hintForHistory(String id) {
    if (_vault.prefs['hints_in_history'] != true) return null;
    if (!VaultPrefs.hintsInHistory.of(_vault.prefs)) return null;
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
