import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/models/secure_card.dart';
import '../../core/passwords/csv_import.dart';
import '../../core/passwords/hint_guard.dart';
import '../../core/passwords/import_rules.dart';
import '../../core/passwords/keyboard_layouts.dart';
import '../../core/passwords/password_audit.dart';
import '../../core/passwords/password_generator.dart';
import '../../core/passwords/password_strength.dart';
import '../../core/passwords/password_training.dart';
import '../../core/passwords/password_wordlists.dart';
import '../../core/passwords/secret_bytes.dart';
import '../../core/passwords/vault.dart';
import '../../core/passwords/vault_backup.dart';
import '../../core/passwords/vault_crypto.dart';
import '../../core/passwords/vault_errors.dart';
import '../../core/passwords/vault_facade.dart';
import '../../core/passwords/vault_format.dart';
import '../../core/passwords/vault_prefs.dart';
import '../../core/replies/reply_template.dart';
import '../../core/settings/app_settings.dart';
import 'clipboard_guard.dart';
import 'passwords_files.dart';
import 'passwords_platform.dart';
import 'vault_lifecycle.dart';

/// Итог ввода мастер-пароля на экране.
final class UnlockOutcome {
  const UnlockOutcome._({
    this.ok = false,
    this.variantHit = false,
    this.rolledBack = false,
    this.error,
    this.until,
  });

  const UnlockOutcome.success({
    bool variantHit = false,
    bool rolledBack = false,
  }) : this._(ok: true, variantHit: variantHit, rolledBack: rolledBack);

  const UnlockOutcome.failure(VaultErrorCode error, {DateTime? until})
      : this._(error: error, until: until);

  final bool ok;

  /// Подошёл вариант ввода (раскладка, Caps Lock, D25).
  final bool variantHit;

  /// Файл старее, чем был (`passwords.seen_rev`, раздел 4.1).
  final bool rolledBack;

  final VaultErrorCode? error;

  /// До какого времени пауза (D25).
  final DateTime? until;
}

/// Всё, что нужно экранам и карточкам навыка «Пароли» в `lib/app`:
/// хранилище, буфер, запирание и служебные флаги `settings.json`.
///
/// Пароль и заметку отсюда берут только [SecretRevealText] и
/// [ClipboardGuard] — в момент показа или копирования, байтами, которые
/// сразу затираются. Навык (`lib/core/skills/passwords`) видит только
/// [facade].
final class PasswordsKit extends ChangeNotifier {
  PasswordsKit({
    required this.vault,
    PasswordsPlatform? platform,
    ClipboardGuard? clipboard,
    this.kdfForTesting,
    PasswordWordlists? wordlists,
    PasswordFiles? files,
  })  : platform = platform ?? PasswordsPlatform.current,
        files = files ?? const IoPasswordFiles() {
    _useWordlists(wordlists ?? PasswordWordlists.empty());
    this.clipboard = clipboard ??
        ClipboardGuard(platform: this.platform, cipher: vault.crypto);
    lifecycle = VaultLifecycle(vault: vault, clipboard: this.clipboard);
    vault.addListener(_onSignal);
  }

  /// Id навыка в «Расширениях».
  static const String skillId = VaultLifecycle.skillId;

  final Vault vault;

  /// Параметры Argon2id вместо калибровки (только тесты: хранилище с
  /// `allowTestingKdf`).
  final VaultKdfParams? kdfForTesting;

  late final VaultFacade facade = VaultFacade(vault);
  final PasswordsPlatform platform;

  /// Открыть CSV и копию, сохранить копию.
  final PasswordFiles files;
  late final ClipboardGuard clipboard;
  late final VaultLifecycle lifecycle;

  /// Сигнал «спрятать показанное»: окно неактивно или хранилище заперто.
  final ValueNotifier<int> hideTicks = ValueNotifier<int>(0);

  /// `passwords.seen_rev` и `passwords.vault_existed` из настроек.
  int? seenRev;
  bool vaultExisted = false;

  /// Служебные флаги изменились — записать в `settings.json`.
  void Function({int? seenRev, bool? vaultExisted, String? trainingDue})?
      onSettings;

  /// Словари (EFF large, частые пароли). Пока не загрузились — пустые:
  /// генератор слов недоступен, оценка — без словарей.
  PasswordWordlists get wordlists => _wordlists;
  late PasswordWordlists _wordlists;
  late PasswordStrength _strength;

  PasswordStrength get strength => _strength;

  void _useWordlists(PasswordWordlists lists) {
    _wordlists = lists;
    _strength = PasswordStrength(lists);
    vault.assessor = PasswordAssessor(_strength);
  }

  /// Словари из `assets/passwords/` ([read] — `rootBundle.loadString`).
  /// Не загрузились — остаются пустые, навык работает без них.
  Future<void> loadWordlists(Future<String> Function(String) read) async {
    try {
      final lists = PasswordWordlists.parse(
        eff: await read('assets/passwords/eff_large_wordlist.txt'),
        common: await read('assets/passwords/common_passwords.txt'),
      );
      _useWordlists(lists);
      notifyListeners();
    } on Object {
      // Без словарей: генератор символов и оценка по остальным моделям.
    }
  }

  /// Генератор (5.4): случайность — libsodium `randombytes`.
  PasswordGenerator get generator =>
      PasswordGenerator(random: vault.crypto, lists: _wordlists);

  /// Оценка надёжности набранного [text] с учётом данных записи.
  StrengthEstimate estimate(
    String text, {
    List<String> userInputs = const <String>[],
  }) {
    final bytes = SecretBytes.fromText(text);
    try {
      return _strength.estimate(bytes, userInputs: userInputs);
    } finally {
      bytes.wipe();
    }
  }

  /// Проверка подсказки [hint] к паролю [password] (5.3). Пустой
  /// [password] при правке — проверяется сохранённый пароль записи [id].
  /// Тратит попытку сравнения с важными записями, как [reviewSave].
  Future<HintVerdict> checkHint(
    String hint,
    String password, {
    String? id,
  }) async =>
      (await reviewSave(hint, password, id: id)).hint;

  /// Проверка перед сохранением записи (5.3): [HintGuard] для подсказки
  /// [hint] и повтор пароля [password] (пустой — пароль не меняется).
  ///
  /// Сравнение с охраняемыми важными записями (без свежего мастер-пароля,
  /// 15.2) — оракул отпечатков, поэтому идёт только через
  /// [Vault.entriesMatching] с пределом: каждая разная догадка — пароль
  /// и подсказка по отдельности — тратит одну из 5 попыток за 10 мин
  /// (повтор уже сверенной — бесплатно). Подсказка из нескольких слов от
  /// 4 символов ([HintGuard.candidates]) при охраняемых записях с ними не
  /// сравнивается вовсе: иначе подсказка из тысячи слов — тысяча догадок
  /// за раз, а деление пополам находит пароль за несколько сохранений.
  /// Сохранить её можно только с мастер-паролем
  /// ([HintProblem.needsConfirm]), и ответ не зависит от того, есть ли
  /// среди слов пароль. Подсказка длиннее [HintGuard.maxHint]
  /// отклоняется до любых сравнений.
  ///
  /// Новая подсказка охраняемой важной записи [id] сверяется с её же
  /// паролем (кусок от 4 символов, слово фразы) — это тоже оракул, поэтому
  /// сразу [HintProblem.needsConfirm], сохранённый пароль не читается.
  ///
  /// Предел никогда не превращает запрет в «можно»: когда попытки
  /// кончились, подсказка не проверена против важных записей — и
  /// сохранить её нельзя, пока не введён мастер-пароль. Повтор с важными
  /// в этом случае не сообщается ([SaveReview.unchecked]).
  Future<SaveReview> reviewSave(
    String hint,
    String password, {
    String? id,
  }) async {
    final hasHint = hint.trim().isNotEmpty;
    if (!hasHint && password.isEmpty) return SaveReview.fine;
    if (hint.trim().length > HintGuard.maxHint) {
      return const SaveReview(
        hint: HintVerdict(block: HintProblem.tooLong),
        unchecked: true,
      );
    }
    final open = vault.isUnlocked;
    final entry = id == null || !open ? null : vault.entry(id);
    if (entry != null &&
        vault.isGuarded(entry) &&
        hasHint &&
        hint.trim() != entry.hint) {
      return const SaveReview(
        hint: HintVerdict(block: HintProblem.needsConfirm),
        unchecked: true,
      );
    }
    final SecretBytes bytes;
    if (password.isNotEmpty) {
      bytes = SecretBytes.fromText(password);
    } else if (entry != null) {
      bytes = await this.password(entry.id);
    } else {
      bytes = SecretBytes.empty();
    }
    try {
      final same = open && password.isNotEmpty
          ? vault.entriesMatching(bytes, except: id, spendGuess: true)
          : const SecretMatches.none();
      // Несколько кандидатов в подсказке — с охраняемыми не сравниваем и
      // попыток на них не тратим.
      final batch = hasHint && HintGuard.candidates(hint) > 1;
      var hintComplete = true;
      bool known(String token) {
        if (token.isEmpty || !vault.isUnlocked) return false;
        final candidate = SecretBytes.fromText(token);
        try {
          final found = vault.entriesMatching(candidate, spendGuess: !batch);
          if (!found.complete) hintComplete = false;
          return found.entries.isNotEmpty;
        } finally {
          candidate.wipe();
        }
      }

      final verdict = hasHint
          ? HintGuard.check(
              hint,
              bytes,
              knownPassword: open ? known : null,
              lists: _wordlists,
            )
          : HintVerdict.fine;
      return SaveReview(
        hint: verdict.ok && hasHint && !hintComplete
            ? const HintVerdict(block: HintProblem.needsConfirm)
            : verdict,
        same: same.entries,
        unchecked: !same.complete,
      );
    } finally {
      bytes.wipe();
    }
  }

  /// «Проверить себя» / тренировка: только верно, «почти» или нет.
  Future<RecallVerdict> recall(String id, String text) async {
    final bytes = SecretBytes.fromText(text);
    try {
      return await vault.recall(id, bytes);
    } on VaultError {
      return RecallVerdict.wrong;
    } finally {
      bytes.wipe();
    }
  }

  /// Итог тренировки записи [id]; ближайшая дата — в настройки.
  Future<void> train(String id, TrainingOutcome outcome) async {
    final entry = vault.entry(id);
    if (entry == null || !entry.important) return;
    await vault.recordTraining(id, outcome);
    final due = nextTrainingDay();
    if (due != null) onSettings?.call(trainingDue: due);
  }

  /// День ближайшей тренировки (не раньше завтра после ответа), или
  /// `null`, если тренировать нечего.
  String? nextTrainingDay() {
    DateTime? next;
    for (final entry in vault.entries) {
      if (!entry.important || TrainingSchedule.isOff(entry.train)) continue;
      final at = TrainingSchedule.nextOf(entry.train);
      if (at != null && (next == null || at.isBefore(next))) next = at;
    }
    if (next == null) return null;
    final tomorrow = vault.clock.now().add(const Duration(days: 1));
    final day = next.isBefore(tomorrow) ? tomorrow : next;
    return AppSettings.dayKey(day.toLocal());
  }

  /// Длина и классы символов (ступень 2 лестницы D27) и «похоже на
  /// русское слово в английской раскладке».
  Future<(PasswordShape, bool)> shape(String id) async {
    final bytes = await password(id);
    try {
      final shape = PasswordShape.of(bytes);
      final layout = _strength
          .estimate(bytes)
          .reasons
          .contains(StrengthReason.russianLayout);
      return (shape, layout);
    } finally {
      bytes.wipe();
    }
  }

  /// Первый символ пароля (ступень 3 лестницы D27). Вызывающий затирает.
  Future<SecretBytes> firstChar(String id) async {
    final bytes = await password(id);
    try {
      final runes = Utf8Runes.decode(bytes.unsafeBytes) ?? <int>[];
      final first = runes.isEmpty ? <int>[] : <int>[runes.first];
      runes.fillRange(0, runes.length, 0);
      return SecretBytes.adopt(Utf8Runes.encode(first));
    } finally {
      bytes.wipe();
    }
  }

  /// Группы проверки по текущему индексу (без расшифровки).
  CheckGroups groups() => CheckGroups.of(
        vault.entries,
        vault.clock.now(),
        equal: vault.crypto.equal,
        guarded: vault.isGuarded,
      );

  /// Полная проверка: пароли расшифровываются по одному и оцениваются.
  Future<CheckGroups> audit() async {
    await vault.reassess();
    return groups();
  }

  /// Последнее открытие показало откат файла (раздел 4.1).
  bool rolledBack = false;

  /// Окно свежего подтверждения мастер-паролем (3.6): хранит хранилище
  /// ([Vault.isGuarded]).
  static const Duration repromptWindow = Vault.confirmWindow;

  final Expando<bool> _handled = Expando<bool>('secure-card');

  VaultState get state => vault.state;

  bool get isUnlocked => vault.isUnlocked;

  bool get canCopySecrets => clipboard.canCopySecrets;

  int get revealSeconds => VaultPrefs.revealSeconds.of(vault.prefs);

  int get clipboardSeconds => VaultPrefs.clipboardSeconds.of(vault.prefs);

  void _onSignal(VaultSignal signal) {
    if (signal == VaultSignal.hide || signal == VaultSignal.locked) {
      hideTicks.value++;
    }
    if (signal == VaultSignal.changed && vault.isUnlocked) {
      // Ближайшая тренировка — в settings.json (только дата, 5.8).
      final due = nextTrainingDay();
      if (due != null) onSettings?.call(trainingDue: due);
    }
    notifyListeners();
  }

  /// Карточка с автоматическим действием (копирование после «да») уже
  /// выполнила его: перестроение ленты не повторяет.
  bool takeOnce(SecureCardRequest card) {
    if (_handled[card] == true) return false;
    _handled[card] = true;
    return true;
  }

  /// Флаги из загруженных настроек.
  void syncSettings({int? seenRev, required bool vaultExisted}) {
    this.seenRev = seenRev;
    this.vaultExisted = vaultExisted;
    notifyListeners();
  }

  /// [fresh] — новое хранилище (создано, восстановлено из копии, «Заменить
  /// всё»): его `rev` начинается заново, прежний `seen_rev` не про него.
  void _remember(int rev, {bool fresh = false}) {
    final changed = fresh || seenRev == null || rev > seenRev!;
    if (changed) seenRev = rev;
    final existed = !vaultExisted;
    vaultExisted = true;
    if (changed || existed) {
      onSettings?.call(seenRev: seenRev, vaultExisted: true);
    }
  }

  /// Новое хранилище. Текст поля приходит сюда и сразу превращается в
  /// байты, которые затираются после вызова.
  Future<void> create(String master) async {
    final bytes = SecretBytes.fromText(master);
    try {
      await vault.create(bytes, params: kdfForTesting);
    } finally {
      bytes.wipe();
    }
    final rev = vault.rev;
    if (rev != null) _remember(rev, fresh: true);
  }

  /// Открыть мастер-паролем (с вариантами ввода, D25).
  Future<UnlockOutcome> unlock(String master) async {
    final bytes = SecretBytes.fromText(master);
    try {
      final result = await vault.unlock(bytes, seenRev: seenRev);
      rolledBack = result.rolledBack;
      _remember(result.rev);
      return UnlockOutcome.success(
        variantHit: result.variantHit,
        rolledBack: result.rolledBack,
      );
    } on VaultRateLimited catch (error) {
      return UnlockOutcome.failure(error.code, until: error.until);
    } on VaultError catch (error) {
      return UnlockOutcome.failure(error.code);
    } on ArgumentError {
      return const UnlockOutcome.failure(VaultErrorCode.wrongPassword);
    } finally {
      bytes.wipe();
    }
  }

  /// Проверить мастер-пароль открытого хранилища (переспрос для важных,
  /// ослабление настроек). Пауза — тоже `false`.
  Future<bool> confirm(String master) async {
    final bytes = SecretBytes.fromText(master);
    try {
      return await vault.verifyMaster(bytes);
    } on VaultError {
      return false;
    } finally {
      bytes.wipe();
    }
  }

  /// Сменить мастер-пароль (D5: всегда с новым ключом хранилища). Повтор
  /// нового пароля с записями проверяется только после верного [current]
  /// ([PasswordProblem]): до него это оракул по важным записям (15.2).
  Future<void> changeMaster(String current, String next) async {
    final from = SecretBytes.fromText(current);
    final to = SecretBytes.fromText(next);
    try {
      await vault.changeMaster(
        current: from,
        next: to,
        params: kdfForTesting,
        afterVerify: () => reusedProblem(next),
      );
    } on VaultRejected catch (rejected) {
      throw PasswordProblem(rejected.reason);
    } finally {
      from.wipe();
      to.wipe();
    }
  }

  /// Пароль уже стоит у одной из записей (по отпечатку) — для мастер-
  /// пароля и отдельного пароля копии это запрещено (5.1, 5.7): утечка
  /// у стороннего сайта открыла бы всё хранилище. Какая запись — не
  /// называем. Охраняемые важные записи не сравниваются
  /// ([Vault.matchesKnownSecret]), поэтому звать — после проверки
  /// мастер-пароля ([changeMaster], [exportBackup]).
  String? reusedProblem(String password) {
    if (!vault.isUnlocked || password.isEmpty) return null;
    return vault.matchesKnownSecret(password)
        ? 'Этот пароль уже стоит у одной из записей. Придумайте другой — '
            'хорошо подходит фраза из 4–5 случайных слов.'
        : null;
  }

  /// Важной записи [id] нужно свежее подтверждение мастер-паролем. С
  /// [margin] — и тогда, когда до конца окна осталось меньше [margin].
  bool needsReprompt(String id, {Duration margin = Duration.zero}) {
    final entry = vault.entry(id);
    return entry != null && vault.isGuarded(entry, margin: margin);
  }

  /// Запас окна подтверждения для сохранения правки: если до конца окна
  /// меньше, редактор спрашивает мастер-пароль заранее — окно не кончится
  /// посреди проверок и записи.
  static const Duration saveMargin = Duration(seconds: 10);

  /// Снять с записи [id] отметку «Важный» — ослабление защиты, только с
  /// мастер-паролем (3.6). `false` — мастер-пароль не подошёл или пауза.
  Future<bool> dropImportant(String id, String master) async {
    final bytes = SecretBytes.fromText(master);
    try {
      await vault.updateInfo(id, important: false, master: bytes);
      return true;
    } on VaultError {
      return false;
    } on ArgumentError {
      return false;
    } finally {
      bytes.wipe();
    }
  }

  /// Пароль записи — для показа или копирования. Вызывающий затирает.
  Future<SecretBytes> password(String id) async {
    final secret = await vault.readSecret(id);
    secret.note.wipe();
    return secret.password;
  }

  /// Заметка записи (маскируется так же, как пароль).
  Future<SecretBytes> note(String id) async {
    final secret = await vault.readSecret(id);
    secret.password.wipe();
    return secret.note;
  }

  /// Скопировать пароль записи [id] (не на Windows и macOS).
  Future<void> copyPassword(String id) async {
    final secret = await password(id);
    await clipboard.copySecret(secret, Duration(seconds: clipboardSeconds));
  }

  // ------------------------------------- хронология паролей (ADR-015)

  /// Включена ли хронология паролей.
  bool get historyEnabled => vault.historyEnabled;

  /// Сколько прежних паролей хранится во всём сейфе.
  int get historyCount => vault.historyCount;

  /// Прежний пароль [historyId] записи [id] — только для показа в карточке
  /// записи (в чат не выходит). Вызывающий затирает.
  Future<SecretBytes> historyPassword(String id, String historyId) =>
      vault.readHistoryPassword(id, historyId);

  /// Удалить прежний пароль из хронологии (опечатка). `false` — не вышло.
  Future<bool> deleteHistory(String id, String historyId) =>
      _quietly(() => vault.deleteHistoryItem(id, historyId));

  /// Очистить хронологию записи [id]. `false` — не вышло.
  Future<bool> clearHistory(String id) =>
      _quietly(() => vault.clearHistory(id));

  /// Удалить прежние пароли всех записей. `false` — не вышло.
  Future<bool> purgeHistory() => _quietly(vault.purgeHistory);

  /// Включить (только с мастер-паролем [master]) или выключить хронологию.
  /// При выключении с [purge] прежние пароли всех записей удаляются;
  /// без него — новые не копятся, сохранённые остаются.
  Future<bool> setPasswordHistory(
    bool enabled, {
    String? master,
    bool purge = false,
  }) async {
    final ok = await setPrefs(
      <String, Object?>{VaultPrefs.passwordHistory.key: enabled},
      master: master,
    );
    if (!ok || enabled || !purge) return ok;
    return purgeHistory();
  }

  Future<bool> _quietly(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } on VaultError {
      return false;
    } on ArgumentError {
      return false;
    } on StateError {
      return false;
    }
  }

  /// Записи с этим же паролем (по отпечатку) — для живого предупреждения
  /// о повторе в редакторе (на каждое нажатие клавиши).
  ///
  /// Это оракул отпечатков: «уже используется для: Сбербанк» подтверждает
  /// догадку. Поэтому важные записи без свежего мастер-пароля (15.2) здесь
  /// не сравниваются вовсе и попыток не тратят — повтор с ними сообщает
  /// [reviewSave] при сохранении.
  List<VaultEntry> sameAs(String password, {String? except}) {
    if (!vault.isUnlocked || password.isEmpty) return const <VaultEntry>[];
    final bytes = SecretBytes.fromText(password);
    try {
      return vault.entriesMatching(bytes, except: except).entries;
    } finally {
      bytes.wipe();
    }
  }

  /// Изменить защитные настройки. Ослабление — только с мастер-паролем.
  Future<bool> setPrefs(Map<String, Object?> changes, {String? master}) async {
    final bytes = master == null ? null : SecretBytes.fromText(master);
    try {
      await vault.setPrefs(changes, master: bytes);
      return true;
    } on VaultError {
      return false;
    } on ArgumentError {
      return false;
    } finally {
      bytes?.wipe();
    }
  }

  // ------------------------------------------- импорт и резервная копия

  /// Разобрать CSV [raw] (5.6). Хранилище не меняется. Байты [raw]
  /// затирает вызывающий; план — тоже ([CsvPlan.wipe]).
  CsvAnalysis analyzeCsv(
    Uint8List raw, {
    CsvEncoding encoding = CsvEncoding.utf8,
    CsvColumns? mapping,
    bool manual = false,
  }) =>
      vault.withImportDigest(
        (Uint8List Function(SecretBytes) digest) => CsvImport.analyze(
          raw,
          digest: digest,
          now: vault.clock.now(),
          encoding: encoding,
          mapping: mapping,
          manual: manual,
        ),
      );

  /// Статусы «новая / дубль / дубль с другим паролем» по `fp`.
  List<ImportMatch> matchImport(List<ImportItem> items, {bool byId = false}) =>
      vault.matchImport(items, byId: byId);

  /// Среди решений [decisions] есть «заменить» охраняемую важную запись
  /// (15.2): перед [applyImport] нужен мастер-пароль ([confirm]), иначе
  /// хранилище откажет (`StateError`). С запасом [saveMargin]: окно не
  /// кончится между подтверждением и записью; хранилище проверяет охрану
  /// один раз на весь импорт и применяет его целиком или никак.
  bool importNeedsConfirm(List<ImportDecision> decisions) => decisions.any(
        (ImportDecision d) =>
            d.choice == ImportChoice.replace &&
            d.match.existingId != null &&
            needsReprompt(d.match.existingId!, margin: saveMargin),
      );

  /// Импорт после подтверждения предпросмотра — одной записью хранилища.
  Future<ImportResult> applyImport(
    List<ImportDecision> decisions, {
    required bool fromBackup,
  }) =>
      vault.importItems(decisions, fromBackup: fromBackup);

  /// Резервная копия, уже проверенная чтением (5.7). Мастер-пароль
  /// обязателен; отдельный пароль копии [separate] — с теми же жёсткими
  /// требованиями, что у мастер-пароля ([BackupProblem], если не годится).
  ///
  /// Повтор пароля копии с записями — только после проверки мастер-пароля
  /// (15.2): до неё ответ «уже стоит у одной из записей» — оракул по
  /// важным записям без предела.
  Future<Uint8List> exportBackup(String master, {String? separate}) async {
    if (separate != null) {
      final problem = masterProblem(separate, strength: strength);
      if (problem != null) throw BackupProblem(problem);
    }
    final from = SecretBytes.fromText(master);
    final pass = separate == null ? null : SecretBytes.fromText(separate);
    try {
      return await vault.exportBackup(
        master: from,
        passphrase: pass,
        params: kdfForTesting,
        afterVerify: separate == null ? null : () => reusedProblem(separate),
      );
    } on VaultRejected catch (rejected) {
      throw BackupProblem(rejected.reason);
    } finally {
      from.wipe();
      pass?.wipe();
    }
  }

  /// Копия сохранена и проверена — дата в индекс.
  Future<void> recordBackup({required bool separate}) =>
      vault.recordBackup(separate: separate);

  /// Открыть копию её паролем. Результат затирает вызывающий.
  Future<BackupContents> openBackup(Uint8List bytes, String passphrase) async {
    final pass = SecretBytes.fromText(passphrase);
    try {
      return await vault.readBackup(bytes, pass);
    } finally {
      pass.wipe();
    }
  }

  /// «Создать хранилище из копии» с мастер-паролем [master]. [keepHistory]
  /// — перенести прежние пароли из копии и включить хронологию паролей.
  Future<void> restoreAsNew(
    BackupContents contents,
    String master, {
    bool keepHistory = false,
  }) async {
    final bytes = SecretBytes.fromText(master);
    try {
      await vault.createFromBackup(
        contents,
        bytes,
        params: kdfForTesting,
        keepHistory: keepHistory,
      );
    } finally {
      bytes.wipe();
    }
    final rev = vault.rev;
    if (rev != null) _remember(rev, fresh: true);
  }

  /// «Заменить всё»: текущее — в архив. `false` — мастер-пароль не
  /// подошёл (или пауза).
  Future<bool> replaceAll(BackupContents contents, String master) async {
    final bytes = SecretBytes.fromText(master);
    try {
      await vault.replaceWithBackup(contents, bytes);
    } on VaultError catch (error) {
      if (error.code == VaultErrorCode.wrongPassword ||
          error.code == VaultErrorCode.rateLimited) {
        return false;
      }
      rethrow;
    } finally {
      bytes.wipe();
    }
    final rev = vault.rev;
    if (rev != null) _remember(rev, fresh: true);
    return true;
  }

  @override
  void dispose() {
    vault.removeListener(_onSignal);
    lifecycle.dispose();
    clipboard.dispose();
    hideTicks.dispose();
    super.dispose();
  }
}

/// Итог [PasswordsKit.reviewSave]: вердикт подсказки и записи с тем же
/// паролем. [unchecked] — с важными записями не сравнивали (кончились
/// попытки без мастер-пароля). Ни пароля, ни подсказки внутри.
final class SaveReview {
  const SaveReview({
    this.hint = HintVerdict.fine,
    this.same = const <VaultEntry>[],
    this.unchecked = false,
  });

  static const SaveReview fine = SaveReview();

  final HintVerdict hint;
  final List<VaultEntry> same;
  final bool unchecked;

  @override
  String toString() =>
      'SaveReview($hint, same: ${same.length}, unchecked: $unchecked)';
}

/// Новый пароль (мастер-пароль, пароль копии) не годится: текст для
/// человека (без самого пароля).
class PasswordProblem implements Exception {
  const PasswordProblem(this.text);

  final String text;

  @override
  String toString() => 'PasswordProblem';
}

/// Пароль копии не годится.
final class BackupProblem extends PasswordProblem {
  const BackupProblem(super.text);

  @override
  String toString() => 'BackupProblem';
}

/// Текст для пользователя по коду ошибки хранилища: без подробностей.
String vaultErrorText(VaultErrorCode code) => switch (code) {
      VaultErrorCode.wrongPassword => 'Мастер-пароль не подошёл.',
      VaultErrorCode.rateLimited =>
        'Слишком много неверных попыток — подождите.',
      VaultErrorCode.corrupt =>
        'Файл сейфа повреждён или подменён. Данные не тронуты.',
      VaultErrorCode.kdfInvalid =>
        'В файле сейфа подозрительные параметры — его не открываем.',
      VaultErrorCode.tooNew =>
        'Сейф создан более новой версией приложения — обновите его.',
      VaultErrorCode.io => 'Не удалось прочитать или записать файл сейфа.',
      VaultErrorCode.locked => 'Сейф заперт.',
      _ => 'Не получилось. Данные не пострадали.',
    };

/// Нижняя граница оценки для фразы из ≥ 4 слов в [masterProblem]. Не
/// 50: оценка занижает настоящие фразы из частых слов EFF
/// (`racingvineyardrefreezematrix` — 46 бит), и около 1 % случайных фраз
/// из 4 слов оказались бы ниже; наименьшая у 20 000 случайных — около 42.
const double phraseFloorBits = 40;

/// Наименьшая средняя длина слова фразы из [words] слов, чтобы фраза
/// прошла в [masterProblem] без оценки «высокая»: 4 слова — 5 букв
/// (`bothtintcaneavid`, `oak-elf-art-ion-1` — нет; из случайных фраз EFF
/// отсеивается около 0,4 %, и их можно перегенерировать), 5 и больше —
/// 4 буквы (`ice aim fax lid jam` — нет; случайных отсеивается около
/// 0,001 %).
double phraseWordLength(int words) => words <= 4 ? 5 : 4;

/// Мастер-пароль и отдельный пароль копии (5.1, 5.7) годятся: не короче
/// 12 символов, не из одного символа, без «связной» и «relay»
/// ([forbiddenInMaster]), ни одно слово (буквы, от 3) не повторяется без
/// учёта регистра, l33t-замен (обе таблицы) и задом наперёд
/// (`Able-able-ABLE-able`, `able1-able2-able3`, `velvet-v3lv3t`,
/// `lily-1i1y`, `able-elba`); связки вроде `and`, «или» не в счёт
/// ([PasswordStrength.fillerWords]). С [strength] — ещё и надёжность
/// «высокая» и выше или фраза из 4 и больше разных слов EFF (не меньше
/// 16 букв и [phraseFloorBits] бит). Повтор ищется и внутри слитных слов
/// (`powerrackdwarfcloverpower`).
String? masterProblem(String master, {PasswordStrength? strength}) {
  if (master.runes.length < 12) return 'Нужно не меньше 12 символов.';
  if (master.runes.toSet().length < 4) return 'Слишком однообразно.';
  final lower = master.toLowerCase();
  for (final word in forbiddenInMaster) {
    if (lower.contains(word)) return 'Не используйте «$word» в мастер-пароле.';
  }
  if (strength != null) {
    final bytes = SecretBytes.fromText(master);
    try {
      final estimate = strength.estimate(bytes);
      // Фраза из ≥ 4 слов (5.1) проходит и с оценкой ниже 3 — но не из
      // коротких слов: четыре слова по 3 буквы (`iceaimfaxlid`) — около
      // 25 настоящих бит. Нужны ≥ 16 букв, оценка ≥ [phraseFloorBits] и
      // средняя длина слова фразы ([phraseWordLength]).
      final letters = master.runes.where(KeyboardLayouts.isLetter).length;
      final words = estimate.passphraseWords;
      final phrase = words >= 4 &&
          letters >= 16 &&
          estimate.passphraseLetters >= phraseWordLength(words) * words &&
          estimate.bits >= phraseFloorBits;
      if (estimate.score < 3 && !phrase) {
        return 'Слишком легко подобрать (надёжность ${estimate.label}). '
            'Добавьте слов или символов — хорошо подходит фраза из 4–5 '
            'случайных слов.';
      }
    } finally {
      bytes.wipe();
    }
  }
  if (_repeatsWord(lower, strength) ||
      _repeatsWord(_unleetWords(lower, alt: false), strength) ||
      _repeatsWord(_unleetWords(lower, alt: true), strength)) {
    return 'Слова в пароле не должны повторяться — повтор подбирают '
        'почти даром. Возьмите 4–5 разных случайных слов.';
  }
  return null;
}

/// [lower] без l33t-замен (обе таблицы: [alt] — `1 → l`), но только в
/// кусках, где есть хоть одна буква: `v3lv3t` → `velvet`, а число
/// `3141592653` остаётся числом и не превращается в «слова» (иначе цифры
/// давали бы ложное «слова повторяются»). Куски — подряд идущие буквы,
/// цифры и знаки l33t; между ними — пробел.
String _unleetWords(String lower, {required bool alt}) {
  final out = <int>[];
  final token = <int>[];
  void flush() {
    if (token.isEmpty) return;
    final hasLetter = token.any(KeyboardLayouts.isLetter);
    out
      ..addAll(hasLetter ? KeyboardLayouts.unleet(token, alt: alt) : token)
      ..add(0x20);
    token.clear();
  }

  for (final r in lower.runes) {
    if (KeyboardLayouts.isLetter(r) ||
        KeyboardLayouts.isDigit(r) ||
        KeyboardLayouts.isLeet(r)) {
      token.add(r);
    } else {
      flush();
    }
  }
  flush();
  return String.fromCharCodes(out);
}

/// Есть ли в [text] (нижний регистр) слово, повторённое как есть или
/// задом наперёд; связки не считаются. Слитный кусок букв сначала
/// делится на слова EFF ([PasswordStrength.effWordsOf]):
/// `powerrackdwarfcloverpower` — повтор `power`.
bool _repeatsWord(String text, [PasswordStrength? strength]) {
  final seen = <String>{};
  String keyOf(String word) {
    final back = String.fromCharCodes(word.runes.toList().reversed);
    return word.compareTo(back) <= 0 ? word : back;
  }

  for (final m in _letters.allMatches(text)) {
    final token = m[0]!;
    var split = strength?.effWordsOf(token);
    // Слитный кусок с «s» на конце (`powerrackdwarfcloverpowers`): слова
    // без неё, «s» — к последнему.
    if (split == null && token.length > 3 && token.endsWith('s')) {
      final stem = strength?.effWordsOf(token.substring(0, token.length - 1));
      if (stem != null && stem.length > 1) {
        split = <String>[...stem.take(stem.length - 1), '${stem.last}s'];
      }
    }
    final words = split != null && split.length > 1 ? split : <String>[token];
    for (final word in words) {
      if (PasswordStrength.isFiller(word)) continue;
      // Множественное число — тот же корень: `power` и `powers`, `box` и
      // `boxes` («es» — только после s, x, z, ch, sh: `tapes` — не `tap`).
      final plural = word.length > 3 && word.endsWith('s');
      final stem = plural ? word.substring(0, word.length - 1) : word;
      final esStem = word.length > 4 && _esPlural.hasMatch(word)
          ? word.substring(0, word.length - 2)
          : stem;
      final esForm = _esStem.hasMatch(word) ? '${word}es' : '${word}s';
      if (seen.contains(keyOf(word)) ||
          seen.contains(keyOf(stem)) ||
          seen.contains(keyOf(esStem)) ||
          seen.contains(keyOf('${word}s')) ||
          seen.contains(keyOf(esForm))) {
        return true;
      }
      seen
        ..add(keyOf(word))
        ..add(keyOf(stem))
        ..add(keyOf(esStem));
    }
  }
  return false;
}

/// Множественное на «es» (`boxes`, `buses`, `matches`, `wishes`).
final RegExp _esPlural = RegExp(r'(?:[sxz]|ch|sh)es$');

/// Корень, к которому множественное — на «es» (`box`, `bus`, `match`).
final RegExp _esStem = RegExp(r'(?:[sxz]|ch|sh)$');

/// Слова пароля для [masterProblem]: буквы любого алфавита, от 3.
final RegExp _letters = RegExp(r'\p{L}{3,}', unicode: true);

/// «1 запись», «2 записи», «5 записей» — число со словом в нужной форме.
String countText(int n, String one, String few, String many) =>
    '$n ${switch (ReplyTemplate.pluralIndex(n)) {
      0 => one,
      1 => few,
      _ => many,
    }}';

/// «Изменён 14 мес. назад».
String agoText(DateTime when, DateTime now) {
  final days = now.difference(when).inDays;
  if (days < 1) return 'сегодня';
  if (days < 31) return '$days дн. назад';
  if (days < 365) return '${days ~/ 30} мес. назад';
  return '${days ~/ 365} г. назад';
}

/// Запустить без ожидания; ошибка не выходит наружу (в ней не бывает
/// данных, но и показывать её некому).
void fireAndForget(Future<void> future) => unawaited(
      future.then<void>((_) {}, onError: (Object _) {}),
    );
