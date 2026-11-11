import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/models/secure_card.dart';
import '../../core/passwords/secret_bytes.dart';
import '../../core/passwords/vault.dart';
import '../../core/passwords/vault_crypto.dart';
import '../../core/passwords/vault_errors.dart';
import '../../core/passwords/vault_facade.dart';
import '../../core/passwords/vault_format.dart';
import '../../core/passwords/vault_prefs.dart';
import 'clipboard_guard.dart';
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
  }) : platform = platform ?? PasswordsPlatform.current {
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
  late final ClipboardGuard clipboard;
  late final VaultLifecycle lifecycle;

  /// Сигнал «спрятать показанное»: окно неактивно или хранилище заперто.
  final ValueNotifier<int> hideTicks = ValueNotifier<int>(0);

  /// `passwords.seen_rev` и `passwords.vault_existed` из настроек.
  int? seenRev;
  bool vaultExisted = false;

  /// Служебные флаги изменились — записать в `settings.json`.
  void Function({int? seenRev, bool? vaultExisted})? onSettings;

  /// Последнее открытие показало откат файла (раздел 4.1).
  bool rolledBack = false;

  /// Когда последний раз подтверждали мастер-паролем показ важной записи
  /// (3.6, «Переспрашивать для важных»).
  DateTime? _confirmedAt;

  static const Duration repromptWindow = Duration(seconds: 60);

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
    if (signal == VaultSignal.locked) _confirmedAt = null;
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

  void _remember(int rev) {
    final changed = seenRev == null || rev > seenRev!;
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
    if (rev != null) _remember(rev);
  }

  /// Открыть мастер-паролем (с вариантами ввода, D25).
  Future<UnlockOutcome> unlock(String master) async {
    final bytes = SecretBytes.fromText(master);
    try {
      final result = await vault.unlock(bytes, seenRev: seenRev);
      rolledBack = result.rolledBack;
      _remember(result.rev);
      _confirmedAt = vault.clock.now();
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
      final ok = await vault.verifyMaster(bytes);
      if (ok) _confirmedAt = vault.clock.now();
      return ok;
    } on VaultError {
      return false;
    } finally {
      bytes.wipe();
    }
  }

  /// Сменить мастер-пароль (D5: всегда с новым ключом хранилища).
  Future<void> changeMaster(String current, String next) async {
    final from = SecretBytes.fromText(current);
    final to = SecretBytes.fromText(next);
    try {
      await vault.changeMaster(current: from, next: to, params: kdfForTesting);
    } finally {
      from.wipe();
      to.wipe();
    }
  }

  /// Важной записи [id] нужно свежее подтверждение мастер-паролем.
  bool needsReprompt(String id) {
    final entry = vault.entry(id);
    if (entry == null || !entry.important) return false;
    if (!VaultPrefs.repromptImportant.of(vault.prefs)) return false;
    final at = _confirmedAt;
    return at == null || vault.clock.now().difference(at) > repromptWindow;
  }

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

  /// Записи с этим же паролем (по отпечатку) — для предупреждения о
  /// повторе в редакторе.
  List<VaultEntry> sameAs(String password, {String? except}) {
    if (!vault.isUnlocked || password.isEmpty) return const <VaultEntry>[];
    final bytes = SecretBytes.fromText(password);
    try {
      final fp = vault.fingerprint(bytes);
      return <VaultEntry>[
        for (final entry in vault.entries)
          if (entry.id != except && vault.crypto.equal(fp, entry.fp)) entry,
      ];
    } on Object {
      return const <VaultEntry>[];
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

  @override
  void dispose() {
    vault.removeListener(_onSignal);
    lifecycle.dispose();
    clipboard.dispose();
    hideTicks.dispose();
    super.dispose();
  }
}

/// Текст для пользователя по коду ошибки хранилища: без подробностей.
String vaultErrorText(VaultErrorCode code) => switch (code) {
      VaultErrorCode.wrongPassword => 'Мастер-пароль не подошёл.',
      VaultErrorCode.rateLimited =>
        'Слишком много неверных попыток — подождите.',
      VaultErrorCode.corrupt =>
        'Файл хранилища повреждён или подменён. Данные не тронуты.',
      VaultErrorCode.kdfInvalid =>
        'В файле хранилища подозрительные параметры — его не открываем.',
      VaultErrorCode.tooNew =>
        'Хранилище создано более новой версией приложения — обновите его.',
      VaultErrorCode.io => 'Не удалось прочитать или записать файл хранилища.',
      VaultErrorCode.locked => 'Хранилище заперто.',
      _ => 'Не получилось. Данные не пострадали.',
    };

/// Мастер-пароль годится (5.1, без оценки надёжности — она на этапе 3):
/// не короче 12 символов, не из одного символа, без «связной» и «relay».
String? masterProblem(String master) {
  if (master.runes.length < 12) return 'Нужно не меньше 12 символов.';
  if (master.runes.toSet().length < 4) return 'Слишком однообразно.';
  final lower = master.toLowerCase();
  for (final word in <String>['связной', 'relay']) {
    if (lower.contains(word)) return 'Не используйте «$word» в мастер-пароле.';
  }
  return null;
}

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
