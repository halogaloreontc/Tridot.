import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/passwords/vault.dart';
import '../../core/passwords/vault_errors.dart';
import '../../core/passwords/vault_facade.dart';
import '../../core/passwords/vault_format.dart';
import '../assistant_theme.dart';
import 'backup_screens.dart';
import 'entry_screens.dart';
import 'generator_view.dart';
import 'import_screen.dart';
import 'passwords_kit.dart';
import 'passwords_settings_screen.dart';
import 'recall_views.dart';
import 'secret_widgets.dart';

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
    if (_recheck && state == VaultState.unlocked) {
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
                '«Настройки → Расширения», чтобы открыть хранилище.',
          ),
        VaultState.notCreated => _CreateView(
            kit: kit,
            onCreated: () => setState(() => _recheck = true),
            onRestored: _done,
          ),
        VaultState.locked => _LockView(kit: kit, onUnlocked: _done),
        VaultState.unlocked => _ListView(kit: kit, now: widget.now),
      };
    }
    return Scaffold(
      backgroundColor: AssistantColors.workspace,
      appBar: AppBar(
        backgroundColor: AssistantColors.workspace,
        title: const Text('Пароли'),
        actions: <Widget>[
          if (state == VaultState.unlocked && !_recheck)
            PopupMenuButton<String>(
              key: const ValueKey<String>('passwords-menu'),
              tooltip: 'Ещё',
              color: AssistantColors.raised,
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
        Icon(icon, size: 32, color: AssistantColors.muted),
        const SizedBox(height: 12),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 18,
            color: AssistantColors.textStrong,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AssistantColors.muted),
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
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            icon,
            size: 18,
            color: strong ? AssistantColors.warning : AssistantColors.muted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color:
                    strong ? AssistantColors.textStrong : AssistantColors.text,
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
        setState(() => _failure = 'Не получилось создать хранилище.');
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
            text: 'Хранилище на этом устройстве не найдено. Если есть '
                'резервная копия, пароли вернёт только она. Можно и создать '
                'новое хранилище.',
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
                    label: const Text('Восстановить из копии'),
                  )
                : OutlinedButton.icon(
                    key: const ValueKey<String>('passwords-restore'),
                    onPressed: _busy ? null : () => unawaited(_restore()),
                    icon: const Icon(Icons.restore, size: 18),
                    label: const Text('Восстановить из копии'),
                  ),
          ),
        ),
        const Text(
          'Создать хранилище паролей',
          style: TextStyle(fontSize: 18, color: AssistantColors.textStrong),
        ),
        const SizedBox(height: 14),
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
          title: const Text(
            'Я понимаю: если забуду мастер-пароль, восстановить данные '
            'нельзя никак.',
            style: TextStyle(color: AssistantColors.text),
          ),
        ),
        if (_failure != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _failure!,
              style: const TextStyle(color: AssistantColors.danger),
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
        const Text(
          'Хранилище создано',
          style: TextStyle(fontSize: 18, color: AssistantColors.textStrong),
        ),
        const SizedBox(height: 8),
        const Text(
          'Введите мастер-пароль ещё раз — по памяти. Так он лучше '
          'запомнится.',
          style: TextStyle(color: AssistantColors.text),
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

// --------------------------------------------------------------- замок

class _LockView extends StatefulWidget {
  const _LockView({required this.kit, required this.onUnlocked});

  final PasswordsKit kit;
  final VoidCallback onUnlocked;

  @override
  State<_LockView> createState() => _LockViewState();
}

class _LockViewState extends State<_LockView> {
  final TextEditingController _master = TextEditingController();
  bool _busy = false;
  String? _error;
  DateTime? _until;
  Timer? _tick;

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
      widget.onUnlocked();
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
    final wait = _waitText;
    return _Column(
      children: <Widget>[
        const SizedBox(height: 8),
        const Icon(Icons.lock_outline, size: 36, color: AssistantColors.muted),
        const SizedBox(height: 12),
        const Text(
          'Хранилище заперто',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 18, color: AssistantColors.textStrong),
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
        Text(
          widget.kit.platform.unlockNote,
          textAlign: TextAlign.center,
          style: technicalTextStyle,
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
    return AlertDialog(
      key: const ValueKey<String>('recovery-dialog'),
      scrollable: true,
      backgroundColor: AssistantColors.raised,
      title: const Text('Забыли мастер-пароль?'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              'Восстановить нельзя: без мастер-пароля хранилище не '
              'расшифровать — ни мне, ни кому-либо ещё.',
              style: TextStyle(color: AssistantColors.textStrong),
            ),
            const SizedBox(height: 10),
            const Text(
              'Часто пароль вспоминается через день-два. Попробуйте '
              'вспомнить, где и когда вы его придумывали, — и не спешите.',
              style: TextStyle(color: AssistantColors.text),
            ),
            const SizedBox(height: 10),
            const Text(
              'Вход по отпечатку и восстановление из резервной копии '
              'появятся в следующих обновлениях.',
              style: TextStyle(color: AssistantColors.muted),
            ),
            if (exists) ...<Widget>[
              const SizedBox(height: 16),
              const Text(
                'Начать заново: старое хранилище не стирается, а '
                'откладывается в архив — вдруг вспомните. Новое хранилище '
                'будет пустым. Чтобы продолжить, введите слово «начать».',
                style: TextStyle(color: AssistantColors.text),
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
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Закрыть'),
        ),
        if (exists)
          TextButton(
            key: const ValueKey<String>('recovery-start-over'),
            style:
                TextButton.styleFrom(foregroundColor: AssistantColors.danger),
            onPressed:
                _busy || !_confirmed ? null : () => unawaited(_startOver()),
            child: const Text('Начать заново'),
          ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AssistantColors.raised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AssistantColors.warning.withAlpha(110)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(
            Icons.warning_amber_outlined,
            size: 18,
            color: AssistantColors.warning,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: AssistantColors.text),
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
        : ' · запрётся в ${lockAt.hour.toString().padLeft(2, '0')}:'
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
            Container(
              key: const ValueKey<String>('passwords-open-bar'),
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
              decoration: BoxDecoration(
                color: AssistantColors.raised,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AssistantColors.borderSoft),
              ),
              child: Row(
                children: <Widget>[
                  const Icon(
                    Icons.lock_open_outlined,
                    size: 16,
                    color: AssistantColors.success,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Открыто$until',
                      style: const TextStyle(color: AssistantColors.text),
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
            if (kit.rolledBack)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: _Banner(
                  key: ValueKey<String>('passwords-rolled-back'),
                  text: 'Файл хранилища старее, чем был. Его могли '
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
                      decoration: const InputDecoration(
                        isDense: true,
                        prefixIcon: Icon(Icons.search, size: 18),
                        hintText: 'Поиск',
                        border: OutlineInputBorder(),
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
                      icon: const Icon(Icons.add, size: 20),
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
                        style: const TextStyle(color: AssistantColors.muted),
                      ),
                    )
                  : ListView.separated(
                      key: const ValueKey<String>('passwords-list'),
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                      itemCount: entries.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (BuildContext context, int i) => EntryTile(
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
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: AssistantColors.bubble,
        child: Text(
          letter,
          style: const TextStyle(color: AssistantColors.textStrong),
        ),
      ),
      title: Text(
        entry.service,
        style: const TextStyle(color: AssistantColors.textStrong),
      ),
      subtitle: entry.login.isEmpty
          ? null
          : Text(
              VaultFacade.maskLogin(entry.login),
              style: const TextStyle(color: AssistantColors.muted),
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
                        AssistantColors.danger,
                      ),
                    if (reused)
                      _badge(
                        'badge-reused-${entry.id}',
                        'Повтор',
                        Icons.copy_all_outlined,
                        AssistantColors.warning,
                      ),
                    if (old)
                      _badge(
                        'badge-old-${entry.id}',
                        'Давно не меняли',
                        Icons.history,
                        AssistantColors.muted,
                      ),
                    if (entry.important)
                      _badge(
                        'badge-important-${entry.id}',
                        'Важный',
                        Icons.star_outline,
                        AssistantColors.warning,
                      ),
                  ],
                )
              : null),
    );
  }
}
