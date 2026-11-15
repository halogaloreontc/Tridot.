import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/passwords/secret_bytes.dart';
import '../../core/passwords/vault.dart';
import '../../core/passwords/vault_errors.dart';
import '../../core/passwords/vault_facade.dart';
import '../../core/passwords/vault_format.dart';
import '../assistant_theme.dart';
import '../layout.dart';
import '../widgets/grouped.dart';
import 'backup_screens.dart';
import 'entry_screens.dart';
import 'generator_view.dart';
import 'import_screen.dart';
import 'passwords_kit.dart';
import 'passwords_settings_screen.dart';
import 'pin_pad.dart';
import 'recall_views.dart';
import 'recovery_code_view.dart';
import 'secret_widgets.dart';
import 'vault_confirm.dart';
import '../widgets/whole_word_text.dart';
import '../widgets/app_dialog.dart';

/// Экран «Пароли» (раздел 8): создание хранилища, замок, список записей.
///
/// Открывается из «Настроить» навыка в «Расширениях», из меню «+» и из
/// карточек. [unlockOnly] — открыт карточкой «Хранилище заперто»: после
/// входа (или создания) экран закрывается с `true`, и карточка повторяет
/// команду.
class PasswordsScreen extends StatefulWidget {
  const PasswordsScreen({
    super.key,
    required this.kit,
    this.unlockOnly = false,
    this.now = DateTime.now,
  });

  final PasswordsKit kit;
  final bool unlockOnly;
  final DateTime Function() now;

  @override
  State<PasswordsScreen> createState() => _PasswordsScreenState();
}

class _PasswordsScreenState extends State<PasswordsScreen> {
  PasswordsKit get kit => widget.kit;

  /// Только что создали хранилище: ждём ввода «ещё раз по памяти».
  bool _recheck = false;

  /// Код восстановления, который нужно показать (ADR-025): новый сейф или
  /// переход с мастер-пароля.
  String? _code;

  @override
  void initState() {
    super.initState();
    kit.addListener(_changed);
  }

  @override
  void dispose() {
    kit.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _done() {
    if (widget.unlockOnly && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final state = kit.state;
    final Widget body;
    final code = _code;
    if (code != null && state == VaultState.unlocked) {
      body = RecoveryCodeView(
        kit: kit,
        code: code,
        onDone: () {
          setState(() => _code = null);
          _done();
        },
      );
    } else if (_recheck && state == VaultState.unlocked) {
      body = _RecheckView(
        kit: kit,
        onDone: () {
          setState(() => _recheck = false);
          _done();
        },
      );
    } else {
      body = switch (state) {
        VaultState.disabled => const _Message(
            key: ValueKey<String>('passwords-disabled'),
            icon: Icons.lock_outline,
            title: 'Навык «Пароли» выключен',
            text: 'Данные сохранены и заперты. Включите навык в '
                '«Настройки → Расширения», чтобы открыть сейф.',
          ),
        VaultState.notCreated => kit.deviceProtection
            ? _ProtectedCreateView(
                kit: kit,
                onCode: (String code) => setState(() => _code = code),
                onRestored: _done,
              )
            : _CreateView(
                kit: kit,
                onCreated: () => setState(() => _recheck = true),
                onRestored: _done,
              ),
        VaultState.locked => _LockView(
            kit: kit,
            onUnlocked: _done,
            onCode: (String code) => setState(() => _code = code),
          ),
        VaultState.unlocked => _ListView(kit: kit, now: widget.now),
      };
    }
    // Список сейфа — сгруппированным экраном на фоне (ADR-027); вход,
    // создание и код — на листе: поля ввода заливкой видны на нём.
    final grouped = state == VaultState.unlocked && !_recheck && code == null;
    final surface =
        grouped ? context.colors.background : context.colors.workspace;
    return Scaffold(
      backgroundColor: surface,
      appBar: AppBar(
        backgroundColor: surface,
        // На списке название — крупным заголовком под полосой (§4.2),
        // а не вторым маленьким в ней.
        title: grouped ? null : const Text('Сейф'),
        actions: <Widget>[
          if (state == VaultState.unlocked && !_recheck && _code == null)
            PopupMenuButton<String>(
              key: const ValueKey<String>('passwords-menu'),
              tooltip: 'Ещё',
              // «⋯», как в шапке сессии.
              icon: const Icon(Icons.more_horiz),
              onSelected: (String value) {
                final Widget screen = switch (value) {
                  'generator' => GeneratorScreen(kit: kit),
                  'check' => CheckScreen(kit: kit),
                  'training' => TrainingScreen(kit: kit),
                  'import' => CsvImportScreen(kit: kit),
                  'backup' => BackupExportScreen(kit: kit),
                  'restore' => BackupRestoreScreen(kit: kit),
                  _ => PasswordsSettingsScreen(kit: kit),
                };
                unawaited(
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (BuildContext context) => screen,
                    ),
                  ),
                );
              },
              itemBuilder: (BuildContext context) =>
                  const <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  key: ValueKey<String>('passwords-menu-generator'),
                  value: 'generator',
                  child: Text('Генератор'),
                ),
                PopupMenuItem<String>(
                  key: ValueKey<String>('passwords-menu-check'),
                  value: 'check',
                  child: Text('Проверка'),
                ),
                PopupMenuItem<String>(
                  key: ValueKey<String>('passwords-menu-training'),
                  value: 'training',
                  child: Text('Тренировка'),
                ),
                PopupMenuItem<String>(
                  key: ValueKey<String>('passwords-menu-import'),
                  value: 'import',
                  child: Text('Импорт из браузера'),
                ),
                PopupMenuItem<String>(
                  key: ValueKey<String>('passwords-menu-backup'),
                  value: 'backup',
                  child: Text('Резервная копия'),
                ),
                PopupMenuItem<String>(
                  key: ValueKey<String>('passwords-menu-restore'),
                  value: 'restore',
                  child: Text('Восстановить из копии'),
                ),
                PopupMenuItem<String>(
                  value: 'settings',
                  child: Text('Настройки'),
                ),
              ],
            ),
        ],
      ),
      body: SafeArea(child: body),
    );
  }
}

/// Колонка по центру, не шире 560.
class _Column extends StatelessWidget {
  const _Column({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: children,
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    super.key,
    required this.icon,
    required this.title,
    required this.text,
  });

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return _Column(
      children: <Widget>[
        Icon(icon, size: 32, color: context.colors.muted),
        const SizedBox(height: 12),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .headlineSmall!
              .copyWith(color: context.colors.textStrong),
        ),
        const SizedBox(height: 8),
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: context.colors.muted),
        ),
      ],
    );
  }
}

/// Пункт с точкой: «на устройстве, никуда не отправляется».
class _Point extends StatelessWidget {
  const _Point(this.icon, this.text, {this.strong = false});

  final IconData icon;
  final String text;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            icon,
            size: 18,
            color: strong ? context.colors.warning : context.colors.muted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: WholeWordText(
              text,
              style: TextStyle(
                color: strong ? context.colors.textStrong : context.colors.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ создание

class _CreateView extends StatefulWidget {
  const _CreateView({
    required this.kit,
    required this.onCreated,
    required this.onRestored,
  });

  final PasswordsKit kit;
  final VoidCallback onCreated;

  /// Хранилище создано из копии — оно уже открыто.
  final VoidCallback onRestored;

  @override
  State<_CreateView> createState() => _CreateViewState();
}

class _CreateViewState extends State<_CreateView> {
  final TextEditingController _master = TextEditingController();
  final TextEditingController _repeat = TextEditingController();
  bool _understood = false;
  bool _busy = false;
  String? _masterError;
  String? _repeatError;
  String? _failure;

  @override
  void dispose() {
    _master
      ..clear()
      ..dispose();
    _repeat
      ..clear()
      ..dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (BuildContext context) => BackupRestoreScreen(kit: widget.kit),
      ),
    );
    if (mounted && widget.kit.isUnlocked) widget.onRestored();
  }

  Future<void> _create() async {
    final problem = masterProblem(_master.text, strength: widget.kit.strength);
    final mismatch = _master.text != _repeat.text;
    setState(() {
      _masterError = problem;
      _repeatError =
          problem == null && mismatch ? 'Пароли не совпадают.' : null;
      _failure = null;
    });
    if (problem != null || mismatch || !_understood) return;
    setState(() => _busy = true);
    final text = _master.text;
    _master.clear();
    _repeat.clear();
    try {
      await widget.kit.create(text);
      if (mounted) widget.onCreated();
    } on VaultError catch (error) {
      if (mounted) setState(() => _failure = vaultErrorText(error.code));
    } on Object {
      if (mounted) {
        setState(() => _failure = 'Не получилось создать сейф.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final kit = widget.kit;
    return _Column(
      children: <Widget>[
        if (kit.vaultExisted)
          const _Banner(
            key: ValueKey<String>('passwords-not-found'),
            text: 'Сейф на этом устройстве не найден. Если есть '
                'резервная копия, пароли вернёт только она. Можно и создать '
                'новый сейф.',
          ),
        // D28: на новом устройстве первым пунктом — восстановление.
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: kit.vaultExisted
                ? FilledButton.icon(
                    key: const ValueKey<String>('passwords-restore'),
                    onPressed: _busy ? null : () => unawaited(_restore()),
                    icon: const Icon(Icons.restore, size: 18),
                    label: const WholeWordText('Восстановить из копии'),
                  )
                : OutlinedButton.icon(
                    key: const ValueKey<String>('passwords-restore'),
                    onPressed: _busy ? null : () => unawaited(_restore()),
                    icon: const Icon(Icons.restore, size: 18),
                    label: const WholeWordText('Восстановить из копии'),
                  ),
          ),
        ),
        Text(
          'Создать сейф паролей',
          style: Theme.of(context)
              .textTheme
              .headlineSmall!
              .copyWith(color: context.colors.textStrong),
        ),
        const SizedBox(height: 12),
        const _Point(
          Icons.phone_android_outlined,
          'Пароли хранятся только на этом устройстве, зашифрованными, и '
          'никуда не отправляются.',
        ),
        const _Point(
          Icons.warning_amber_outlined,
          'Без мастер-пароля данные не восстановить — ни вам, ни мне, ни '
          'кому-либо ещё.',
          strong: true,
        ),
        _Point(Icons.info_outline, kit.platform.unlockNote),
        const _Point(
          Icons.edit_note_outlined,
          'Мастер-пароль можно записать на бумаге и хранить дома, отдельно '
          'от устройства, — это надёжнее, чем надеяться на память.',
        ),
        const SizedBox(height: 8),
        SecretField(
          key: const ValueKey<String>('create-master'),
          controller: _master,
          label: 'Мастер-пароль',
          helper: 'Не короче 12 символов. Хорошо подходит фраза из '
              'нескольких слов.',
          error: _masterError,
          enabled: !_busy,
        ),
        const SizedBox(height: 12),
        SecretField(
          key: const ValueKey<String>('create-repeat'),
          controller: _repeat,
          label: 'Ещё раз',
          error: _repeatError,
          enabled: !_busy,
          onSubmitted: (_) => unawaited(_create()),
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          key: const ValueKey<String>('create-understood'),
          value: _understood,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          onChanged: _busy
              ? null
              : (bool? value) => setState(() => _understood = value ?? false),
          title: WholeWordText(
            'Я понимаю: если забуду мастер-пароль, восстановить данные '
            'нельзя никак.',
            style: TextStyle(color: context.colors.text),
          ),
        ),
        if (_failure != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _failure!,
              style: TextStyle(color: context.colors.danger),
            ),
          ),
        const SizedBox(height: 8),
        FilledButton(
          key: const ValueKey<String>('create-submit'),
          onPressed: _busy || !_understood ? null : () => unawaited(_create()),
          child: Text(_busy ? 'Готовлю ключ…' : 'Создать'),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }
}

/// Сразу после создания — ввести мастер-пароль ещё раз по памяти.
class _RecheckView extends StatefulWidget {
  const _RecheckView({required this.kit, required this.onDone});

  final PasswordsKit kit;
  final VoidCallback onDone;

  @override
  State<_RecheckView> createState() => _RecheckViewState();
}

class _RecheckViewState extends State<_RecheckView> {
  final TextEditingController _master = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _master
      ..clear()
      ..dispose();
    super.dispose();
  }

  Future<void> _check() async {
    if (_busy || _master.text.isEmpty) return;
    setState(() => _busy = true);
    final text = _master.text;
    _master.clear();
    final ok = await widget.kit.confirm(text);
    if (!mounted) return;
    if (ok) {
      widget.onDone();
      return;
    }
    setState(() {
      _busy = false;
      _error = 'Не совпало. Вспомните его ещё раз — сейчас это ещё легко.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return _Column(
      children: <Widget>[
        Text(
          'Сейф создан',
          style: Theme.of(context)
              .textTheme
              .headlineSmall!
              .copyWith(color: context.colors.textStrong),
        ),
        const SizedBox(height: 8),
        Text(
          'Введите мастер-пароль ещё раз — по памяти. Так он лучше '
          'запомнится.',
          style: TextStyle(color: context.colors.text),
        ),
        const SizedBox(height: 16),
        SecretField(
          key: const ValueKey<String>('recheck-master'),
          controller: _master,
          label: 'Мастер-пароль',
          error: _error,
          enabled: !_busy,
          autofocus: true,
          onSubmitted: (_) => unawaited(_check()),
        ),
        const SizedBox(height: 12),
        FilledButton(
          key: const ValueKey<String>('recheck-submit'),
          onPressed: _busy ? null : () => unawaited(_check()),
          child: Text(_busy ? 'Проверяю…' : 'Проверить'),
        ),
      ],
    );
  }
}

// ------------------------------------------- защита устройством (ADR-025)

/// Создание сейфа, защищённого устройством: без мастер-пароля. Сразу
/// после — код восстановления, один раз ([RecoveryCodeView]).
class _ProtectedCreateView extends StatefulWidget {
  const _ProtectedCreateView({
    required this.kit,
    required this.onCode,
    required this.onRestored,
  });

  final PasswordsKit kit;
  final ValueChanged<String> onCode;
  final VoidCallback onRestored;

  @override
  State<_ProtectedCreateView> createState() => _ProtectedCreateViewState();
}

class _ProtectedCreateViewState extends State<_ProtectedCreateView> {
  bool _busy = false;
  String? _failure;

  Future<void> _restore() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (BuildContext context) => BackupRestoreScreen(kit: widget.kit),
      ),
    );
    if (mounted && widget.kit.isUnlocked) widget.onRestored();
  }

  Future<void> _create() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final code = await widget.kit.createProtected();
      if (mounted) widget.onCode(code);
    } on VaultError catch (error) {
      if (mounted) setState(() => _failure = vaultErrorText(error.code));
    } on Object {
      if (mounted) setState(() => _failure = 'Не получилось создать сейф.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final kit = widget.kit;
    final restore = kit.vaultExisted
        ? FilledButton.icon(
            key: const ValueKey<String>('passwords-restore'),
            onPressed: _busy ? null : () => unawaited(_restore()),
            icon: const Icon(Icons.restore, size: 18),
            label: const WholeWordText('Восстановить из копии'),
          )
        : OutlinedButton.icon(
            key: const ValueKey<String>('passwords-restore'),
            onPressed: _busy ? null : () => unawaited(_restore()),
            icon: const Icon(Icons.restore, size: 18),
            label: const WholeWordText('Восстановить из копии'),
          );
    return _Column(
      children: <Widget>[
        if (kit.vaultExisted)
          const _Banner(
            key: ValueKey<String>('passwords-not-found'),
            text: 'Сейф на этом устройстве не найден. Если есть '
                'резервная копия, пароли вернёт только она (вместе с кодом '
                'восстановления). Можно и создать новый сейф.',
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: restore,
          ),
        ),
        Text(
          'Создать сейф паролей',
          style: Theme.of(context)
              .textTheme
              .headlineSmall!
              .copyWith(color: context.colors.textStrong),
        ),
        const SizedBox(height: 12),
        const _Point(
          Icons.phone_android_outlined,
          'Пароли хранятся только на этом устройстве, зашифрованными, и '
          'никуда не отправляются.',
        ),
        const _Point(
          Icons.lock_open_outlined,
          'Отдельного пароля не нужно: сейф открывается ключом этого '
          'устройства, пока открыто приложение. ПИН-код сейфа и вход по '
          'отпечатку / Face ID можно включить в настройках сейфа.',
        ),
        const _Point(
          Icons.warning_amber_outlined,
          'После создания покажу код восстановления — один раз. Сохраните '
          'его: без него при смене телефона или сбросе блокировки экрана '
          'пароли не восстановить.',
          strong: true,
        ),
        if (_failure != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _failure!,
              style: TextStyle(color: context.colors.danger),
            ),
          ),
        const SizedBox(height: 8),
        FilledButton(
          key: const ValueKey<String>('create-submit'),
          onPressed: _busy ? null : () => unawaited(_create()),
          child: Text(_busy ? 'Готовлю ключ…' : 'Создать'),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }
}

/// Замок сейфа, защищённого устройством: ключ устройства открывает сам;
/// ПИН-код — набором; биометрия — системным запросом; всегда можно
/// «Восстановить по коду».
class _ProtectedLock extends StatefulWidget {
  const _ProtectedLock({
    required this.kit,
    required this.info,
    required this.onUnlocked,
  });

  final PasswordsKit kit;
  final VaultLockInfo info;
  final ValueChanged<UnlockOutcome> onUnlocked;

  @override
  State<_ProtectedLock> createState() => _ProtectedLockState();
}

class _ProtectedLockState extends State<_ProtectedLock> {
  final TextEditingController _code = TextEditingController();
  late VaultLockInfo _info = widget.info;
  bool _busy = false;
  bool _useCode = false;
  String? _error;

  /// Пауза ПИН-кода: пульт сам ведёт отсчёт и не нажимается.
  DateTime? _until;

  PasswordsKit get kit => widget.kit;

  @override
  void initState() {
    super.initState();
    _useCode = !_info.device && !_info.pin && !_info.bio;
    if (_info.pin) unawaited(_loadPause());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_info.device) {
        unawaited(_device());
      } else if (_info.bio) {
        unawaited(_bio());
      }
    });
  }

  @override
  void dispose() {
    _code
      ..clear()
      ..dispose();
    super.dispose();
  }

  Future<void> _loadPause() async {
    final attempts = await kit.pinAttempts();
    final until = attempts.blockedUntil(DateTime.now());
    if (!mounted || until == null) return;
    setState(() => _until = until);
  }

  Future<void> _refresh() async {
    final info = await kit.lockInfo();
    if (!mounted || info == null) return;
    setState(() {
      _info = info;
      if (!info.device && !info.pin && !info.bio) _useCode = true;
    });
  }

  Future<void> _attempt(
    Future<UnlockOutcome> Function() open, {
    bool pin = false,
    bool code = false,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final outcome = await open();
    if (!mounted) return;
    if (outcome.ok) {
      setState(() => _busy = false);
      if (outcome.recovered) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: WholeWordText(
              'Сейф открыт кодом восстановления. ПИН-код и вход по '
              'отпечатку сняты — их можно включить снова в настройках '
              'сейфа.',
            ),
          ),
        );
      }
      widget.onUnlocked(outcome);
      return;
    }
    final error = outcome.error ?? VaultErrorCode.wrongPassword;
    String text;
    DateTime? until;
    if (pin &&
        (error == VaultErrorCode.wrongPassword ||
            error == VaultErrorCode.rateLimited ||
            error == VaultErrorCode.pinLocked)) {
      final result = await pinError(kit);
      text = result.text;
      until = result.until;
    } else if (code && error == VaultErrorCode.rateLimited) {
      text = _waitText(outcome.until) ?? vaultErrorText(error);
    } else if (error == VaultErrorCode.bioCanceled) {
      text = '';
    } else {
      text = vaultErrorText(error, recovery: code);
    }
    if (error == VaultErrorCode.deviceKeyLost ||
        error == VaultErrorCode.bioInvalidated ||
        error == VaultErrorCode.pinLocked) {
      await _refresh();
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = text.isEmpty || until != null ? null : text;
      _until = until;
      if (error == VaultErrorCode.deviceKeyLost) _useCode = true;
    });
  }

  static String? _waitText(DateTime? until) {
    if (until == null) return null;
    final left = until.difference(DateTime.now());
    if (left <= Duration.zero) return null;
    final minutes = left.inMinutes;
    final seconds = (left.inSeconds % 60).toString().padLeft(2, '0');
    return 'Следующая попытка через $minutes:$seconds.';
  }

  Future<void> _device() => _attempt(kit.unlockDevice);

  Future<void> _bio() => _attempt(kit.unlockBio);

  Future<void> _pin(SecretBytes pin) =>
      _attempt(() => kit.unlockPin(pin), pin: true);

  Future<void> _recover() async {
    if (_code.text.isEmpty) return;
    final text = _code.text;
    _code.clear();
    await _attempt(() => kit.unlock(text), code: true);
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final error = _error;
    return SecureWindowScope(
      auth: kit.auth,
      child: _Column(
        children: <Widget>[
          const SizedBox(height: 8),
          Icon(
            Icons.lock_outline,
            size: 44,
            color: context.colors.muted,
          ),
          const SizedBox(height: 12),
          WholeWordText(
            'Сейф заперт',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .headlineSmall!
                .copyWith(color: context.colors.textStrong),
          ),
          const SizedBox(height: 20),
          if (_useCode) ...<Widget>[
            WholeWordText(
              'Откройте сейф кодом восстановления — тем, что был показан при '
              'создании сейфа.',
              style: TextStyle(color: context.colors.text),
            ),
            const SizedBox(height: 12),
            SecretField(
              key: const ValueKey<String>('lock-code'),
              controller: _code,
              label: 'Код восстановления',
              helper: 'XXXXX-XXXXX-XXXXX-XXXXX-XXXXX, регистр не важен.',
              error: error,
              allowShow: true,
              autofocus: true,
              enabled: !_busy,
              onSubmitted: (_) => unawaited(_recover()),
            ),
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey<String>('lock-code-submit'),
              onPressed: _busy ? null : () => unawaited(_recover()),
              child: Text(_busy ? 'Открываю…' : 'Открыть'),
            ),
          ] else if (info.pin) ...<Widget>[
            WholeWordText(
              'Введите ПИН-код сейфа',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.colors.text),
            ),
            const SizedBox(height: 12),
            Center(
              child: PinPad(
                now: kit.vault.clock.now,
                key: const ValueKey<String>('lock-pin'),
                enabled: !_busy,
                error: error,
                until: _until,
                onPauseEnd: () => setState(() {
                  _until = null;
                  _error = null;
                }),
                onComplete: _pin,
              ),
            ),
          ] else if (info.device) ...<Widget>[
            if (_busy)
              WholeWordText(
                'Открываю…',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.colors.text),
              ),
            if (error != null) ...<Widget>[
              WholeWordText(
                error,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.colors.danger),
              ),
              const SizedBox(height: 12),
            ],
            if (!_busy)
              FilledButton(
                key: const ValueKey<String>('lock-device'),
                onPressed: () => unawaited(_device()),
                child: const Text('Открыть'),
              ),
          ] else if (error != null)
            WholeWordText(
              error,
              textAlign: TextAlign.center,
              style: TextStyle(color: context.colors.danger),
            ),
          if (info.bio && !_useCode)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: OutlinedButton.icon(
                key: const ValueKey<String>('lock-bio'),
                onPressed: _busy ? null : () => unawaited(_bio()),
                icon: const Icon(Icons.fingerprint, size: 18),
                label: const Text('По отпечатку / Face ID'),
              ),
            ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          const SizedBox(height: 16),
          if (!_useCode)
            TextButton(
              key: const ValueKey<String>('lock-recover'),
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _useCode = true;
                        _error = null;
                      }),
              child: const Text('Восстановить по коду'),
            )
          else if (info.device || info.pin || info.bio)
            TextButton(
              key: const ValueKey<String>('lock-back'),
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _useCode = false;
                        _error = null;
                      }),
              child: Text(info.pin ? 'Ввести ПИН-код' : 'Назад'),
            ),
          WholeWordText(
            kit.protectionNoteFor(
              pin: info.pin,
              bio: info.bio,
              codeOnly: !info.device && !info.pin && !info.bio,
            ),
            textAlign: TextAlign.center,
            style: metaStyle(context),
          ),
          const SizedBox(height: 8),
          TextButton(
            key: const ValueKey<String>('lock-forgot'),
            onPressed: () => unawaited(showRecovery(context, kit)),
            child: const Text('Нет кода восстановления?'),
          ),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------- замок

class _LockView extends StatefulWidget {
  const _LockView({
    required this.kit,
    required this.onUnlocked,
    required this.onCode,
  });

  final PasswordsKit kit;
  final VoidCallback onUnlocked;

  /// Сейф с мастер-паролем перешёл на защиту устройством: новый код.
  final ValueChanged<String> onCode;

  @override
  State<_LockView> createState() => _LockViewState();
}

class _LockViewState extends State<_LockView> {
  final TextEditingController _master = TextEditingController();
  bool _busy = false;
  String? _error;
  DateTime? _until;
  Timer? _tick;

  /// Чем открывается сейф (ADR-025). Пока не прочитано — у сборки с
  /// ключом устройства ждём, без него — прежний мастер-пароль.
  VaultLockInfo? _info;
  bool _infoLoaded = false;

  @override
  void initState() {
    super.initState();
    if (widget.kit.deviceProtection) unawaited(_loadInfo());
  }

  Future<void> _loadInfo() async {
    final info = await widget.kit.lockInfo();
    if (!mounted) return;
    setState(() {
      _info = info;
      _infoLoaded = true;
    });
  }

  void _opened(UnlockOutcome outcome) {
    final code = outcome.recoveryCode;
    if (code != null) {
      widget.onCode(code);
    } else {
      widget.onUnlocked();
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _master
      ..clear()
      ..dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    if (_busy || _master.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final text = _master.text;
    _master.clear();
    final outcome = await widget.kit.unlock(text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (outcome.ok) {
      if (outcome.variantHit) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content:
                Text('Вошли. Похоже, была другая раскладка или Caps Lock.'),
          ),
        );
      }
      _opened(outcome);
      return;
    }
    final until = outcome.until;
    setState(() {
      _error = vaultErrorText(outcome.error ?? VaultErrorCode.wrongPassword);
      _until = until;
    });
    _tick?.cancel();
    if (until != null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
        if (!mounted) return timer.cancel();
        if (!DateTime.now().isBefore(until)) {
          timer.cancel();
          setState(() {
            _until = null;
            _error = null;
          });
        } else {
          setState(() {});
        }
      });
    }
  }

  String? get _waitText {
    final until = _until;
    if (until == null) return null;
    final left = until.difference(DateTime.now());
    if (left <= Duration.zero) return null;
    final minutes = left.inMinutes;
    final seconds = (left.inSeconds % 60).toString().padLeft(2, '0');
    return 'Следующая попытка через $minutes:$seconds.';
  }

  @override
  Widget build(BuildContext context) {
    final kit = widget.kit;
    if (kit.deviceProtection && !_infoLoaded) {
      return const Center(child: CircularProgressIndicator());
    }
    final info = _info;
    if (info != null && !info.usesMaster) {
      return _ProtectedLock(kit: kit, info: info, onUnlocked: _opened);
    }
    final wait = _waitText;
    return _Column(
      children: <Widget>[
        const SizedBox(height: 8),
        Icon(Icons.lock_outline, size: 44, color: context.colors.muted),
        const SizedBox(height: 12),
        Text(
          'Сейф заперт',
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .headlineSmall!
              .copyWith(color: context.colors.textStrong),
        ),
        if (kit.deviceProtection)
          Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Введите мастер-пароль в последний раз: дальше сейф будет '
              'открываться ключом этого устройства, а на случай потери я '
              'покажу код восстановления.',
              key: ValueKey<String>('lock-migrate-note'),
              textAlign: TextAlign.center,
              style: TextStyle(color: context.colors.text),
            ),
          ),
        const SizedBox(height: 20),
        SecretField(
          key: const ValueKey<String>('lock-master'),
          controller: _master,
          label: 'Мастер-пароль',
          error: wait ?? _error,
          enabled: !_busy && wait == null,
          autofocus: true,
          onSubmitted: (_) => unawaited(_unlock()),
        ),
        const SizedBox(height: 12),
        FilledButton(
          key: const ValueKey<String>('lock-submit'),
          onPressed: _busy || wait != null ? null : () => unawaited(_unlock()),
          child: Text(_busy ? 'Открываю…' : 'Открыть'),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: LinearProgressIndicator(minHeight: 2),
          ),
        const SizedBox(height: 16),
        // При переходе всё сказано сверху (lock-migrate-note).
        if (!kit.deviceProtection)
          Text(
            kit.platform.unlockNote,
            textAlign: TextAlign.center,
            style: metaStyle(context),
          ),
        const SizedBox(height: 8),
        TextButton(
          key: const ValueKey<String>('lock-forgot'),
          onPressed: () => unawaited(showRecovery(context, widget.kit)),
          child: const Text('Забыли мастер-пароль?'),
        ),
      ],
    );
  }
}

/// «Забыли мастер-пароль?» (5.11): честно — восстановить нельзя; на этом
/// устройстве сейчас есть только «начать заново» (старое хранилище уходит
/// в архив, а не стирается).
Future<void> showRecovery(BuildContext context, PasswordsKit kit) =>
    showDialog<void>(
      context: context,
      builder: (BuildContext context) => _RecoveryDialog(kit: kit),
    );

class _RecoveryDialog extends StatefulWidget {
  const _RecoveryDialog({required this.kit});

  final PasswordsKit kit;

  @override
  State<_RecoveryDialog> createState() => _RecoveryDialogState();
}

class _RecoveryDialogState extends State<_RecoveryDialog> {
  final TextEditingController _word = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _word.dispose();
    super.dispose();
  }

  bool get _confirmed => _word.text.trim().toLowerCase() == 'начать';

  Future<void> _startOver() async {
    setState(() => _busy = true);
    try {
      await widget.kit.vault.startOver();
    } on Object {
      // Файл не перенесли — хранилище на месте.
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final exists = widget.kit.state == VaultState.locked ||
        widget.kit.state == VaultState.unlocked;
    final protectedVault = widget.kit.deviceProtection;
    return AppDialog(
      contentWidth: 460,
      key: const ValueKey<String>('recovery-dialog'),
      scrollable: true,
      title: WholeWordText(
        protectedVault ? 'Нет кода восстановления?' : 'Забыли мастер-пароль?',
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              protectedVault
                  ? 'Если ключ этого устройства, ПИН-код и отпечаток сейф уже '
                      'не открывают, то без кода восстановления его не '
                      'расшифровать — ни мне, ни кому-либо ещё.'
                  : 'Восстановить нельзя: без мастер-пароля сейф не '
                      'расшифровать — ни мне, ни кому-либо ещё.',
              style: TextStyle(color: context.colors.textStrong),
            ),
            const SizedBox(height: 8),
            Text(
              protectedVault
                  ? 'Поищите записанный код: он из пяти групп по пять знаков. '
                      'Есть резервная копия — её откроет тот же код или '
                      'отдельный пароль копии.'
                  : 'Часто пароль вспоминается через день-два. Попробуйте '
                      'вспомнить, где и когда вы его придумывали, — и не '
                      'спешите.',
              style: TextStyle(color: context.colors.text),
            ),
            if (exists) ...<Widget>[
              const SizedBox(height: 16),
              Text(
                'Начать заново: старый сейф не стирается, а '
                'откладывается в архив — вдруг вспомните. Новый сейф '
                'будет пустым. Чтобы продолжить, введите слово «начать».',
                style: TextStyle(color: context.colors.text),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey<String>('recovery-word'),
                controller: _word,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Слово «начать»',
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const ActionLabel('Закрыть'),
        ),
        if (exists)
          TextButton(
            key: const ValueKey<String>('recovery-start-over'),
            style: TextButton.styleFrom(foregroundColor: context.colors.danger),
            onPressed:
                _busy || !_confirmed ? null : () => unawaited(_startOver()),
            child: const ActionLabel('Начать заново'),
          ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.text, this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: context.colors.workspace,
        borderRadius: BorderRadius.circular(AppRadius.group),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            Icons.warning_amber_outlined,
            size: 22,
            color: context.colors.warning,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  text,
                  style: TextStyle(color: context.colors.text),
                ),
                if (action != null) action!,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------- список

class _ListView extends StatefulWidget {
  const _ListView({required this.kit, required this.now});

  final PasswordsKit kit;
  final DateTime Function() now;

  @override
  State<_ListView> createState() => _ListViewState();
}

class _ListViewState extends State<_ListView> {
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _open(Widget screen) => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (BuildContext context) => screen),
      );

  /// Код не подтвердили (приложение закрыли раньше «Я сохранил»): новый.
  Future<void> _newCode() async {
    final kit = widget.kit;
    String? code;
    var rotated = true;
    final ok = await askVaultConfirm(
      context,
      kit: kit,
      title: 'Новый код восстановления',
      text: 'Прежний код (если вы его всё же записали) перестанет '
          'открывать сейф.',
      check: (VaultProof proof) async {
        final result = await kit.regenerateRecovery(proof);
        code = result?.code;
        rotated = result?.rotated ?? true;
        return result != null;
      },
    );
    final shown = code;
    if (!ok || shown == null || !mounted) return;
    await showRecoveryCode(context, kit, shown);
    if (!rotated && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text(recoveryNotRotatedNote)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final kit = widget.kit;
    final vault = kit.vault;
    final query = _search.text.trim().toLowerCase();
    final entries = <VaultEntry>[
      for (final entry in vault.entries)
        if (query.isEmpty ||
            entry.service.toLowerCase().contains(query) ||
            entry.login.toLowerCase().contains(query) ||
            entry.urls.any((String u) => u.toLowerCase().contains(query)))
          entry,
    ]..sort(
        (VaultEntry a, VaultEntry b) =>
            a.service.toLowerCase().compareTo(b.service.toLowerCase()),
      );
    final groups = kit.groups();
    final reused = <String>{for (final g in groups.reused) ...g};
    final weak = groups.weak.toSet();
    final old = groups.old.toSet();
    final lockAt = vault.lockAt?.toLocal();
    final until = lockAt == null
        ? ''
        : '\u00A0· запрётся в ${lockAt.hour.toString().padLeft(2, '0')}:'
            '${lockAt.minute.toString().padLeft(2, '0')}';
    // Узко или крупный шрифт: «Запереть» и «Добавить» — значками, иначе
    // они сжимают полосу до разрыва слов, а поиск — до невидимой подсказки.
    final width = math.min(MediaQuery.sizeOf(context).width, 720.0) - 32;
    final compact = width / MediaQuery.textScalerOf(context).scale(1) < 300;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const LargeTitle('Сейф', key: ValueKey<String>('passwords-title')),
            Container(
              key: const ValueKey<String>('passwords-open-bar'),
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
              constraints: const BoxConstraints(minHeight: AppSize.rowMin),
              decoration: BoxDecoration(
                color: context.colors.workspace,
                borderRadius: BorderRadius.circular(AppRadius.group),
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.lock_open_outlined,
                    size: 20,
                    color: context.colors.success,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Сейф открыт$until',
                      style: TextStyle(color: context.colors.text),
                    ),
                  ),
                  if (compact)
                    IconButton(
                      key: const ValueKey<String>('passwords-lock'),
                      tooltip: 'Запереть',
                      onPressed: vault.lock,
                      icon: const Icon(Icons.lock_outline, size: 18),
                    )
                  else
                    TextButton.icon(
                      key: const ValueKey<String>('passwords-lock'),
                      onPressed: vault.lock,
                      icon: const Icon(Icons.lock_outline, size: 16),
                      label: const Text('Запереть'),
                    ),
                ],
              ),
            ),
            if (kit.recoveryUnconfirmed)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _Banner(
                  key: const ValueKey<String>('passwords-code-unconfirmed'),
                  text: 'Код восстановления не подтверждён. Если вы его не '
                      'записали, получите новый — без него при смене '
                      'телефона пароли не восстановить.',
                  action: TextButton(
                    key: const ValueKey<String>('passwords-new-code'),
                    onPressed: () => unawaited(_newCode()),
                    child: const Text('Новый код'),
                  ),
                ),
              ),
            if (kit.isProtected && kit.platform.fileKeyOnly)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: _Banner(
                  key: ValueKey<String>('passwords-file-key'),
                  text: 'На этом компьютере пароли защищены только вашей '
                      'учётной записью.',
                ),
              ),
            if (kit.rolledBack)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: _Banner(
                  key: ValueKey<String>('passwords-rolled-back'),
                  text: 'Файл сейфа старее, чем был. Его могли '
                      'подменить или восстановить из старой копии. '
                      'Последние изменения могли пропасть.',
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      key: const ValueKey<String>('passwords-search'),
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        isDense: true,
                        fillColor: context.colors.workspace,
                        prefixIcon: const Icon(Icons.search, size: 20),
                        hintText: 'Поиск',
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 12,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.search),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.search),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.search),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (compact)
                    IconButton.filled(
                      key: const ValueKey<String>('passwords-add'),
                      tooltip: 'Добавить',
                      onPressed: () =>
                          unawaited(_open(EntryEditorScreen(kit: kit))),
                      // Цвет глифа явно: иначе `iconTheme` темы (`icon`)
                      // перебивает onAccent и «+» почти не виден на акценте.
                      style: IconButton.styleFrom(
                        backgroundColor: context.colors.accent,
                        foregroundColor: context.colors.onAccent,
                      ),
                      icon: Icon(
                        Icons.add,
                        size: 20,
                        color: context.colors.onAccent,
                      ),
                    )
                  else
                    FilledButton.icon(
                      key: const ValueKey<String>('passwords-add'),
                      onPressed: () =>
                          unawaited(_open(EntryEditorScreen(kit: kit))),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Добавить'),
                    ),
                ],
              ),
            ),
            Expanded(
              child: entries.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        vault.entries.isEmpty
                            ? 'Записей пока нет. Нажмите «Добавить» или '
                                'напишите в сессии: «запомни пароль от почты».'
                            : 'Ничего не нашлось.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: context.colors.muted),
                      ),
                    )
                  // Записи — одной сгруппированной панелью: строки лениво,
                  // скругление у первой и последней (ADR-027).
                  : ListView.builder(
                      key: const ValueKey<String>('passwords-list'),
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      itemCount: entries.length,
                      itemBuilder: (BuildContext context, int i) =>
                          GroupedListCell(
                        first: i == 0,
                        last: i == entries.length - 1,
                        indent: AppSpace.separatorInset,
                        child: EntryTile(
                          entry: entries[i],
                          weak: weak.contains(entries[i].id),
                          reused: reused.contains(entries[i].id),
                          old: old.contains(entries[i].id),
                          onTap: () => unawaited(
                            _open(EntryScreen(kit: kit, id: entries[i].id)),
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Строка списка: буква-значок, сервис, логин в маске, «важный».
class EntryTile extends StatelessWidget {
  const EntryTile({
    super.key,
    required this.entry,
    this.onTap,
    this.trailing,
    this.weak = false,
    this.reused = false,
    this.old = false,
  });

  final VaultEntry entry;
  final VoidCallback? onTap;
  final Widget? trailing;

  /// Значки «слабый», «повтор», «старый» (5.5).
  final bool weak;
  final bool reused;
  final bool old;

  static Widget _badge(String key, String tip, IconData icon, Color color) =>
      Tooltip(
        message: tip,
        child: Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Icon(icon, key: ValueKey<String>(key), size: 18, color: color),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final letter = entry.service.isEmpty
        ? '?'
        : String.fromCharCode(entry.service.runes.first).toUpperCase();
    return ListTile(
      key: ValueKey<String>('entry-${entry.id}'),
      onTap: onTap,
      // Монограмма 28 со скруглением 7 (ADR-027).
      leading: DecoratedBox(
        decoration: BoxDecoration(
          color: context.colors.bubble,
          borderRadius: BorderRadius.circular(AppRadius.tile),
        ),
        child: SizedBox.square(
          dimension: AppSize.iconTile,
          child: Center(
            child: MediaQuery.withNoTextScaling(
              child: Text(
                letter,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: context.colors.textStrong,
                ),
              ),
            ),
          ),
        ),
      ),
      title: WholeWordText(
        entry.service,
        style: TextStyle(color: context.colors.textStrong),
      ),
      subtitle: entry.login.isEmpty
          ? null
          // Логин — одной строкой: перенос рвал бы адрес посреди слова
          // («ca***@exa|mple.org»). Не входит — уменьшается целиком.
          : WholeWordText(
              VaultFacade.maskLogin(entry.login),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              firstWordOnly: true,
              style: TextStyle(color: context.colors.muted),
            ),
      trailing: trailing ??
          (entry.important || weak || reused || old
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (weak)
                      _badge(
                        'badge-weak-${entry.id}',
                        'Слабый',
                        Icons.warning_amber_outlined,
                        context.colors.danger,
                      ),
                    if (reused)
                      _badge(
                        'badge-reused-${entry.id}',
                        'Повтор',
                        Icons.copy_all_outlined,
                        context.colors.warning,
                      ),
                    if (old)
                      _badge(
                        'badge-old-${entry.id}',
                        'Давно не меняли',
                        Icons.history,
                        context.colors.muted,
                      ),
                    if (entry.important)
                      _badge(
                        'badge-important-${entry.id}',
                        'Важный',
                        Icons.star_outline,
                        context.colors.warning,
                      ),
                  ],
                )
              : null),
    );
  }
}
