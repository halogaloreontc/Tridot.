import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/passwords/import_rules.dart';
import '../../core/passwords/vault.dart';
import '../../core/passwords/vault_backup.dart';
import '../../core/passwords/vault_errors.dart';
import '../assistant_theme.dart';
import 'entry_screens.dart';
import 'passwords_files.dart';
import 'passwords_kit.dart';
import 'recovery_code_view.dart';
import 'secret_widgets.dart';
import 'vault_confirm.dart';
import '../widgets/whole_word_text.dart';
import '../widgets/app_dialog.dart';

/// «Резервная копия» (5.7): только из открытого хранилища и с мастер-
/// паролем. Пароль копии — мастер-пароль или отдельный (с теми же
/// требованиями). Копия проверяется чтением; после записи файл ещё раз
/// читается и сравнивается — не совпало, файл удаляется.
///
/// Сейф, защищённый устройством (ADR-025): копия закрывается кодом
/// восстановления (его вводят здесь — заодно проверка, что код сохранён)
/// или отдельным паролем копии после подтверждения. ПИН-кодом — никогда.
class BackupExportScreen extends StatefulWidget {
  const BackupExportScreen({super.key, required this.kit});

  final PasswordsKit kit;

  @override
  State<BackupExportScreen> createState() => _BackupExportScreenState();
}

class _BackupExportScreenState extends State<BackupExportScreen> {
  PasswordsKit get kit => widget.kit;

  final TextEditingController _master = TextEditingController();
  final TextEditingController _separate = TextEditingController();
  final TextEditingController _repeat = TextEditingController();
  bool _own = false;
  bool _busy = false;
  String? _masterError;
  String? _separateError;
  String? _failure;
  String? _savedTo;

  @override
  void initState() {
    super.initState();
    kit.addListener(_onKit);
  }

  @override
  void dispose() {
    kit.removeListener(_onKit);
    for (final c in <TextEditingController>[_master, _separate, _repeat]) {
      c
        ..clear()
        ..dispose();
    }
    super.dispose();
  }

  void _onKit() {
    if (!mounted) return;
    if (!kit.isUnlocked) {
      _clear();
      closeVaultRoute(context);
      return;
    }
    setState(() {});
  }

  void _clear() {
    _master.clear();
    _separate.clear();
    _repeat.clear();
  }

  Future<void> _export() async {
    if (_busy) return;
    setState(() {
      _masterError = null;
      _separateError = null;
      _failure = null;
    });
    final protectedVault = kit.isProtected;
    // Защищённый сейф с отдельным паролем копии: код не нужен, хватит
    // подтверждения.
    final needsSecret = !protectedVault || !_own;
    if (needsSecret && _master.text.isEmpty) {
      setState(
        () => _masterError = protectedVault
            ? 'Введите код восстановления.'
            : 'Введите мастер-пароль.',
      );
      return;
    }
    if (_own) {
      if (_separate.text != _repeat.text) {
        setState(() => _separateError = 'Пароли копии не совпадают.');
        return;
      }
    }
    final master = needsSecret ? _master.text : null;
    final separate = _own ? _separate.text : null;
    setState(() => _busy = true);
    try {
      Uint8List? bytes;
      try {
        if (master != null) {
          bytes = await kit.exportBackup(master, separate: separate);
        } else {
          String? problem;
          final ok = await askVaultConfirm(
            context,
            kit: kit,
            title: 'Сделать копию',
            text: 'Копия с отдельным паролем: подтвердите, что это вы.',
            check: (VaultProof proof) async {
              try {
                bytes = await kit.exportBackup(
                  null,
                  separate: separate,
                  proof: proof,
                );
                return true;
              } on BackupProblem catch (rejected) {
                problem = rejected.text;
                return true;
              } on VaultError {
                return false;
              }
            },
          );
          if (problem != null) throw BackupProblem(problem!);
          if (!ok || bytes == null) {
            if (mounted) setState(() => _failure = 'Копия не сделана.');
            return;
          }
        }
      } on BackupProblem catch (problem) {
        if (mounted) setState(() => _separateError = problem.text);
        return;
      } on VaultError catch (error) {
        if (!mounted) return;
        setState(() {
          if (error.code == VaultErrorCode.wrongPassword) {
            _masterError = protectedVault
                ? 'Код восстановления не подошёл.'
                : 'Мастер-пароль не подошёл.';
          } else {
            _failure = vaultErrorText(error.code);
          }
        });
        return;
      }
      final data = bytes!;
      _clear();
      if (!mounted) return;
      final String? path;
      try {
        path = await kit.files.save(
          context,
          title: 'Куда сохранить копию',
          fileName: VaultBackup.fileName(kit.vault.clock.now()),
          bytes: data,
        );
      } on Object {
        if (mounted) {
          setState(() => _failure = 'Копия не получилась: файл не записан.');
        }
        return;
      }
      if (path == null) {
        if (mounted) setState(() => _failure = 'Копия не сохранена.');
        return;
      }
      // Проверка записанного: файл читается и совпадает байт в байт.
      final written = await kit.files.read(path);
      if (written == null || !listEquals(written, data)) {
        await kit.files.delete(path);
        if (mounted) {
          setState(
            () => _failure = 'Копия не получилась: записанный файл не '
                'совпал с проверенным. Файл удалён — попробуйте другую папку.',
          );
        }
        return;
      }
      await kit.recordBackup(separate: separate != null);
      if (mounted) setState(() => _savedTo = path);
    } on Object {
      if (mounted) setState(() => _failure = 'Копия не получилась.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final saved = _savedTo;
    final last = kit.vault.lastBackupAt;
    return Scaffold(
      backgroundColor: context.colors.workspace,
      appBar: AppBar(
        backgroundColor: context.colors.workspace,
        title: const Text('Резервная копия'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: saved != null
              ? <Widget>[
                  Text(
                    'Копия готова и проверена.',
                    key: ValueKey<String>('backup-done'),
                    style: TextStyle(
                      color: context.colors.textStrong,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    saved,
                    style: TextStyle(color: context.colors.muted),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Храните её не только на этом устройстве: на другом '
                    'компьютере, флешке или в облаке — файл зашифрован. Без '
                    'пароля копии её не открыть никому, и мне тоже.',
                    style: TextStyle(color: context.colors.text),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Готово'),
                  ),
                ]
              : <Widget>[
                  Text(
                    'Если потеряете телефон или ноутбук, пароли вернёт только '
                    'копия. Она зашифрована: без её пароля её не открыть '
                    'никому.',
                    style: TextStyle(color: context.colors.text),
                  ),
                  if (last != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Последняя копия: ${agoText(last, kit.vault.clock.now())}.',
                        style: TextStyle(color: context.colors.muted),
                      ),
                    ),
                  const SizedBox(height: 16),
                  if (!kit.isProtected || !_own)
                    SecretField(
                      key: const ValueKey<String>('backup-master'),
                      controller: _master,
                      label: kit.isProtected
                          ? 'Код восстановления'
                          : 'Мастер-пароль',
                      helper: kit.isProtected
                          ? 'Копия будет закрыта этим кодом: на новом '
                              'телефоне её откроет он.'
                          : null,
                      allowShow: kit.isProtected,
                      error: _masterError,
                      enabled: !_busy,
                    ),
                  CheckboxListTile(
                    key: const ValueKey<String>('backup-own'),
                    value: _own,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: _busy
                        ? null
                        : (bool? v) => setState(() => _own = v ?? false),
                    title: WholeWordText(
                      'Отдельный пароль для копии',
                      style: TextStyle(color: context.colors.text),
                    ),
                    subtitle: WholeWordText(
                      kit.isProtected
                          ? 'По умолчанию копия закрыта кодом '
                              'восстановления — он у вас уже записан.'
                          : 'По умолчанию копия закрыта мастер-паролем — '
                              'меньше запоминать.',
                      style: TextStyle(color: context.colors.muted),
                    ),
                  ),
                  if (_own) ...<Widget>[
                    SecretField(
                      key: const ValueKey<String>('backup-separate'),
                      controller: _separate,
                      label: 'Пароль копии',
                      helper: 'Не короче 12 символов, хорошо подходит фраза '
                          'из нескольких слов: копию могут перебирать '
                          'офлайн. Запишите его на бумаге.',
                      error: _separateError,
                      enabled: !_busy,
                    ),
                    const SizedBox(height: 8),
                    SecretField(
                      key: const ValueKey<String>('backup-repeat'),
                      controller: _repeat,
                      label: 'Ещё раз',
                      enabled: !_busy,
                    ),
                  ],
                  if (_failure != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _failure!,
                        key: const ValueKey<String>('backup-failure'),
                        style: TextStyle(color: context.colors.danger),
                      ),
                    ),
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const ValueKey<String>('backup-make'),
                    onPressed: _busy ? null : () => unawaited(_export()),
                    child: Text(_busy ? 'Шифрую и проверяю…' : 'Сделать копию'),
                  ),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                ],
        ),
      ),
    );
  }
}

/// «Восстановить из копии» (5.7, 5.12): на новом устройстве — «Создать
/// хранилище из копии»; в открытом — слияние по `entry.id`, затем по
/// (сервис, логин) с выбором при конфликте, или «Заменить всё» (текущее —
/// в архив, с мастер-паролем). Копия — недоверенные данные (15.4).
class BackupRestoreScreen extends StatefulWidget {
  const BackupRestoreScreen({super.key, required this.kit});

  final PasswordsKit kit;

  @override
  State<BackupRestoreScreen> createState() => _BackupRestoreScreenState();
}

class _BackupRestoreScreenState extends State<BackupRestoreScreen> {
  PasswordsKit get kit => widget.kit;

  final TextEditingController _pass = TextEditingController();
  final TextEditingController _master = TextEditingController();
  final TextEditingController _repeat = TextEditingController();
  PickedFile? _file;
  BackupContents? _contents;
  List<ImportMatch> _matches = const <ImportMatch>[];
  List<ImportChoice> _choices = const <ImportChoice>[];
  bool _sameMaster = true;

  /// «Создать из копии»: перенести прежние пароли и включить хронологию
  /// паролей (ADR-015). По умолчанию — нет: опция выключена.
  bool _keepHistory = false;
  bool _busy = false;
  String? _error;
  String? _done;

  /// Экран открыт при открытом хранилище (слияние): запирание закрывает.
  bool _merge = false;

  /// Идёт «Заменить всё»: хранилище на миг запирается (прежнее уходит в
  /// архив, ставится новое) — это не повод закрывать экран с итогом.
  bool _replacing = false;

  @override
  void initState() {
    super.initState();
    _merge = kit.isUnlocked;
    kit.addListener(_onKit);
  }

  @override
  void dispose() {
    kit.removeListener(_onKit);
    _contents?.wipe();
    for (final c in <TextEditingController>[_pass, _master, _repeat]) {
      c
        ..clear()
        ..dispose();
    }
    super.dispose();
  }

  void _onKit() {
    if (!mounted) return;
    if (_merge && !kit.isUnlocked && _done == null && !_replacing) {
      _contents?.wipe();
      _contents = null;
      closeVaultRoute(context);
      return;
    }
    setState(() {});
  }

  Future<void> _pick() async {
    setState(() => _error = null);
    try {
      final file = await kit.files.open(
        context,
        title: 'Файл резервной копии',
        extensions: const <String>[VaultBackup.extension],
        maxBytes: VaultBackup.maxBytes,
      );
      if (file != null && mounted) setState(() => _file = file);
    } on FileTooLarge {
      setState(() => _error = 'Файл больше 20 МБ — это не копия «Паролей».');
    } on Object {
      setState(() => _error = 'Файл не открылся.');
    }
  }

  Future<void> _open() async {
    final file = _file;
    if (file == null || _busy || _pass.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final contents = await kit.openBackup(file.bytes, _pass.text);
      if (!mounted) {
        contents.wipe();
        return;
      }
      setState(() {
        _contents = contents;
        if (kit.isUnlocked) {
          _matches = kit.matchImport(contents.items, byId: true);
          _choices = <ImportChoice>[for (final m in _matches) m.defaultChoice];
        }
      });
    } on VaultError catch (error) {
      if (!mounted) return;
      setState(() {
        _error = switch (error.code) {
          VaultErrorCode.wrongPassword => 'Пароль копии не подошёл.',
          VaultErrorCode.kdfInvalid =>
            'В копии подозрительные параметры — её не открываем.',
          VaultErrorCode.tooNew =>
            'Копия сделана более новой версией приложения — обновите его.',
          _ => 'Файл повреждён или это не копия «Паролей».',
        };
      });
    } on Object {
      if (mounted) setState(() => _error = 'Копию открыть не вышло.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreAsNew() async {
    final contents = _contents;
    if (contents == null || _busy) return;
    if (kit.deviceProtection) return _restoreProtected(contents);
    final master = _sameMaster ? _pass.text : _master.text;
    if (!_sameMaster && _master.text != _repeat.text) {
      setState(() => _error = 'Мастер-пароли не совпадают.');
      return;
    }
    final problem = masterProblem(master, strength: kit.strength);
    if (problem != null) {
      setState(() {
        _error = _sameMaster
            ? 'Пароль копии слабоват для мастер-пароля: $problem Задайте '
                'новый мастер-пароль.'
            : problem;
        _sameMaster = false;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await kit.restoreAsNew(
        contents,
        master,
        keepHistory: _keepHistory && contents.hasHistory,
      );
      _finish('Сейф восстановлен: '
          '${countText(contents.items.length, 'запись', 'записи', 'записей')}.');
    } on VaultError catch (error) {
      if (mounted) setState(() => _error = vaultErrorText(error.code));
    } on Object {
      if (mounted) setState(() => _error = 'Восстановить не вышло.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _mergeNow() async {
    final contents = _contents;
    if (contents == null || _busy) return;
    final decisions = <ImportDecision>[
      for (var i = 0; i < contents.items.length; i++)
        ImportDecision(contents.items[i], _matches[i], _choices[i]),
    ];
    // «Взять из копии» для важной записи — правка (15.2).
    if (kit.importNeedsConfirm(decisions)) {
      final ok = await askVaultConfirm(
        context,
        kit: kit,
        title: 'Заменить важные записи',
        text: 'Замену важной записи нужно подтвердить.',
        check: kit.confirmProof,
      );
      if (!ok || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      final result = await kit.applyImport(decisions, fromBackup: true);
      _finish('Объединено: новых ${result.added}, из копии '
          '${result.replaced}, оставлено как есть ${result.skipped}.');
    } on VaultError catch (error) {
      if (mounted) setState(() => _error = vaultErrorText(error.code));
    } on Object {
      if (mounted) {
        setState(() => _error = 'Объединить не вышло. Сейф не изменён.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _replaceAll() async {
    final contents = _contents;
    if (contents == null) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AppDialog(
        title: const WholeWordText('Заменить всё?'),
        content: Text(
          kit.isProtected
              ? 'Текущий сейф не сотрётся, а уйдёт в архив. Вместо него будут '
                  'записи из копии — с новым кодом восстановления; ПИН-код и '
                  'вход по отпечатку включите заново.'
              : 'Текущий сейф не сотрётся, а уйдёт в архив. Вместо него будут '
                  'записи из копии — с тем же мастер-паролем.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const ActionLabel('Отмена'),
          ),
          FilledButton(
            key: const ValueKey<String>('restore-replace-go'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const ActionLabel('Заменить'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    String? code;
    final protectedVault = kit.isProtected;
    final ok = await askVaultConfirm(
      context,
      kit: kit,
      title: 'Заменить всё',
      text: 'Подтвердите замену этого сейфа.',
      check: (VaultProof proof) async {
        _replacing = true;
        try {
          if (protectedVault) {
            code = await kit.replaceAllProtected(contents, proof);
            return code != null;
          }
          final master = proof is SecretProof
              ? utf8.decode(proof.secret.unsafeBytes)
              : null;
          return master != null && await kit.replaceAll(contents, master);
        } finally {
          _replacing = false;
        }
      },
    );
    if (ok) {
      _finish('Сейф заменён копией. Прежний — в архиве.');
      final shown = code;
      if (shown != null && mounted) await showRecoveryCode(context, kit, shown);
    } else if (mounted && !kit.isUnlocked) {
      // Замена сорвалась после архивации — хранилище заперто: закрываем.
      _onKit();
    }
  }

  /// «Создать сейф из копии» с защитой устройством (ADR-025): мастер-
  /// пароль не нужен, новый код восстановления — один раз.
  Future<void> _restoreProtected(BackupContents contents) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final code = await kit.restoreAsNewProtected(
        contents,
        keepHistory: _keepHistory && contents.hasHistory,
      );
      final count = contents.items.length;
      _finish('Сейф восстановлен: '
          '${countText(count, 'запись', 'записи', 'записей')}.');
      if (mounted) await showRecoveryCode(context, kit, code);
    } on VaultError catch (error) {
      if (mounted) setState(() => _error = vaultErrorText(error.code));
    } on Object {
      if (mounted) setState(() => _error = 'Восстановить не вышло.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _finish(String text) {
    _contents?.wipe();
    _contents = null;
    _pass.clear();
    _master.clear();
    _repeat.clear();
    final raw = _file?.bytes;
    raw?.fillRange(0, raw.length, 0);
    if (mounted) setState(() => _done = text);
  }

  @override
  Widget build(BuildContext context) {
    final contents = _contents;
    final List<Widget> children;
    if (_done != null) {
      children = <Widget>[
        Text(
          _done!,
          key: const ValueKey<String>('restore-done'),
          style: TextStyle(color: context.colors.textStrong),
        ),
        const SizedBox(height: 8),
        Text(
          kit.protectionNote,
          style: TextStyle(color: context.colors.muted),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Готово'),
        ),
      ];
    } else if (contents == null) {
      children = _openView();
    } else if (kit.state == VaultState.notCreated) {
      children = _newView(contents);
    } else if (kit.isUnlocked) {
      children = _mergeView(contents);
    } else {
      children = <Widget>[
        Text(
          'Сначала откройте сейф.',
          style: TextStyle(color: context.colors.text),
        ),
      ];
    }
    return Scaffold(
      backgroundColor: context.colors.workspace,
      appBar: AppBar(
        backgroundColor: context.colors.workspace,
        title: const Text('Восстановить из копии'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            ...children,
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  key: const ValueKey<String>('restore-error'),
                  style: TextStyle(color: context.colors.danger),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _openView() => <Widget>[
        WholeWordText(
          'Выберите файл копии (.relaybak) и введите её пароль — код '
          'восстановления, мастер-пароль (старые копии) или отдельный '
          'пароль копии.',
          style: TextStyle(color: context.colors.text),
        ),
        const SizedBox(height: 4),
        Text(
          kit.files.placeNote,
          style: TextStyle(color: context.colors.muted),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const ValueKey<String>('restore-pick'),
          onPressed: _busy ? null : () => unawaited(_pick()),
          icon: const Icon(Icons.file_open_outlined, size: 18),
          label: Text(_file == null ? 'Выбрать файл' : _file!.name),
        ),
        if (_file != null) ...<Widget>[
          const SizedBox(height: 12),
          SecretField(
            key: const ValueKey<String>('restore-pass'),
            controller: _pass,
            label: 'Пароль копии',
            enabled: !_busy,
            onSubmitted: (_) => unawaited(_open()),
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const ValueKey<String>('restore-open'),
            onPressed: _busy ? null : () => unawaited(_open()),
            child: Text(_busy ? 'Открываю…' : 'Открыть копию'),
          ),
        ],
      ];

  List<Widget> _summary(BackupContents contents) => <Widget>[
        Text(
          'В копии '
          '${countText(contents.items.length, 'запись', 'записи', 'записей')}.',
          key: const ValueKey<String>('restore-count'),
          style: TextStyle(color: context.colors.textStrong),
        ),
        if (contents.skipped > 0)
          Text(
            'Пропущено ${contents.skipped}: не прошли проверку.',
            style: TextStyle(color: context.colors.warning),
          ),
        if (kit.isUnlocked && contents.hasHistory && !kit.historyEnabled)
          Text(
            'Прежние пароли из копии не перенесены: хронология выключена.',
            key: ValueKey<String>('restore-history-dropped'),
            style: TextStyle(color: context.colors.muted),
          ),
        const SizedBox(height: 8),
      ];

  List<Widget> _newView(BackupContents contents) => <Widget>[
        ..._summary(contents),
        Text(
          kit.deviceProtection
              ? 'Создать сейф из копии. Он будет защищён этим устройством, '
                  'а после создания я покажу новый код восстановления. '
                  'Настройки защиты не переносятся — ПИН-код и вход по '
                  'отпечатку можно включить заново.'
              : 'Создать сейф из копии. Настройки защиты не переносятся — '
                  'они по умолчанию; вход по отпечатку можно включить заново.',
          style: TextStyle(color: context.colors.text),
        ),
        if (!kit.deviceProtection)
          CheckboxListTile(
            key: const ValueKey<String>('restore-same-master'),
            value: _sameMaster,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            onChanged: _busy
                ? null
                : (bool? v) => setState(() => _sameMaster = v ?? true),
            title: WholeWordText(
              'Мастер-пароль — тот же, что пароль копии',
              style: TextStyle(color: context.colors.text),
            ),
          ),
        if (contents.hasHistory)
          CheckboxListTile(
            key: const ValueKey<String>('restore-keep-history'),
            value: _keepHistory,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            onChanged: _busy
                ? null
                : (bool? v) => setState(() => _keepHistory = v ?? false),
            title: WholeWordText(
              'Включить хронологию паролей?',
              style: TextStyle(color: context.colors.text),
            ),
            subtitle: WholeWordText(
              'В копии есть прежние пароли. Включено: они перенесутся и '
              'будут храниться зашифрованными. Выключено: не перенесутся.',
              style: TextStyle(color: context.colors.muted),
            ),
          ),
        if (!_sameMaster && !kit.deviceProtection) ...<Widget>[
          SecretField(
            key: const ValueKey<String>('restore-master'),
            controller: _master,
            label: 'Новый мастер-пароль',
            helper: 'Не короче 12 символов. Хорошо подходит фраза из '
                'нескольких слов.',
            enabled: !_busy,
          ),
          const SizedBox(height: 8),
          SecretField(
            key: const ValueKey<String>('restore-repeat'),
            controller: _repeat,
            label: 'Ещё раз',
            enabled: !_busy,
          ),
        ],
        const SizedBox(height: 12),
        FilledButton(
          key: const ValueKey<String>('restore-create'),
          onPressed: _busy ? null : () => unawaited(_restoreAsNew()),
          child: Text(_busy ? 'Готовлю ключ…' : 'Восстановить'),
        ),
      ];

  List<Widget> _mergeView(BackupContents contents) => <Widget>[
        ..._summary(contents),
        Text(
          'Объединить с текущим сейфом. При разных паролях по умолчанию '
          'остаются обе записи.',
          style: TextStyle(color: context.colors.text),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < contents.items.length; i++) _mergeRow(contents, i),
        const SizedBox(height: 12),
        FilledButton(
          key: const ValueKey<String>('restore-merge'),
          onPressed: _busy ? null : () => unawaited(_mergeNow()),
          child: Text(_busy ? 'Объединяю…' : 'Объединить'),
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const ValueKey<String>('restore-replace'),
          onPressed: _busy ? null : () => unawaited(_replaceAll()),
          style: TextButton.styleFrom(foregroundColor: context.colors.danger),
          child: const Text('Заменить всё…'),
        ),
      ];

  Widget _mergeRow(BackupContents contents, int i) {
    final item = contents.items[i];
    final match = _matches[i];
    final host = item.urls.isEmpty
        ? ''
        : ' · ${ImportRules.displayHost(item.urls.first)}';
    final status = switch (match.status) {
      ImportStatus.fresh => 'новая',
      ImportStatus.same => 'такая же',
      ImportStatus.conflict => 'другой пароль',
    };
    return Padding(
      key: ValueKey<String>('restore-row-$i'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '${item.service}$host · $status',
            style: TextStyle(
              color: match.status == ImportStatus.conflict
                  ? context.colors.warning
                  : context.colors.text,
            ),
          ),
          if (match.addressChanges)
            Text(
              'адрес изменится: было ${match.addressFrom} → станет '
              '${match.addressTo}',
              style: TextStyle(color: context.colors.warning),
            ),
          if (match.status == ImportStatus.conflict)
            DropdownButton<ImportChoice>(
              key: ValueKey<String>('restore-choice-$i'),
              value: _choices[i],
              dropdownColor: context.colors.raised,
              items: const <DropdownMenuItem<ImportChoice>>[
                DropdownMenuItem<ImportChoice>(
                  value: ImportChoice.keepBoth,
                  child: Text('Оставить обе'),
                ),
                DropdownMenuItem<ImportChoice>(
                  value: ImportChoice.replace,
                  child: Text('Из копии'),
                ),
                DropdownMenuItem<ImportChoice>(
                  value: ImportChoice.skip,
                  child: Text('Текущую'),
                ),
              ],
              onChanged: (ImportChoice? v) {
                if (v == null) return;
                setState(() => _choices = <ImportChoice>[..._choices]..[i] = v);
              },
            ),
        ],
      ),
    );
  }
}
