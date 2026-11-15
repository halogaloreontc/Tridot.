import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/passwords/vault.dart';
import '../../core/passwords/vault_errors.dart';
import '../../core/passwords/vault_prefs.dart';
import '../assistant_theme.dart';
import '../widgets/grouped.dart';
import 'entry_screens.dart';
import 'passwords_kit.dart';
import 'passwords_screen.dart';
import 'secret_widgets.dart';
import 'vault_access.dart';
import 'vault_confirm.dart';
import '../widgets/whole_word_text.dart';

/// «Пароли → Настройки» (раздел 9). Защитные настройки живут внутри
/// зашифрованного индекса: меняются только в открытом хранилище, а
/// ослабление (дольше, реже, подсказки или логин в истории, без
/// переспроса) — только после подтверждения (ПИН-код, биометрия,
/// блокировка экрана; у старого сейфа — мастер-пароль, ADR-025).
class PasswordsSettingsScreen extends StatefulWidget {
  const PasswordsSettingsScreen({super.key, required this.kit});

  final PasswordsKit kit;

  @override
  State<PasswordsSettingsScreen> createState() =>
      _PasswordsSettingsScreenState();
}

class _PasswordsSettingsScreenState extends State<PasswordsSettingsScreen> {
  PasswordsKit get kit => widget.kit;
  bool _busy = false;

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
    if (!mounted) return;
    if (!kit.isUnlocked) {
      closeVaultRoute(context);
      return;
    }
    setState(() {});
  }

  Future<void> _set(String key, Object value) async {
    if (_busy) return;
    final changes = <String, Object?>{key: value};
    var ok = false;
    setState(() => _busy = true);
    try {
      if (kit.vault.prefsWeaken(changes)) {
        ok = await askVaultConfirm(
          context,
          kit: kit,
          title: 'Ослабить защиту?',
          text: 'Эта настройка делает сейф менее защищённым. Подтвердите.',
          check: (VaultProof proof) => kit.setPrefs(changes, proof: proof),
        );
      } else {
        ok = await kit.setPrefs(changes);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!ok && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Настройка не изменена.')),
      );
    }
  }

  Widget _choice(String title, VaultPref<int> pref, String unit) {
    final value = pref.of(kit.vault.prefs);
    return ListTile(
      key: ValueKey<String>('prefs-${pref.key}'),
      title: WholeWordText(title),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final option in pref.choices)
              ChoiceChip(
                key: ValueKey<String>('prefs-${pref.key}-$option'),
                label: Text('$option $unit'),
                selected: option == value,
                // Заливкой без рамки (тема); выбранный — тоном акцента.
                labelStyle: TextStyle(
                  color: option == value
                      ? context.colors.accent
                      : context.colors.text,
                  fontWeight:
                      option == value ? FontWeight.w600 : FontWeight.w400,
                ),
                // Выбранный вариант не серый «недоступный»: нажатие на
                // него просто ничего не меняет.
                onSelected: _busy
                    ? null
                    : (_) {
                        if (option != value) unawaited(_set(pref.key, option));
                      },
              ),
          ],
        ),
      ),
    );
  }

  Widget _flag(String title, String subtitle, VaultPref<bool> pref) {
    return SwitchListTile(
      key: ValueKey<String>('prefs-${pref.key}'),
      value: pref.of(kit.vault.prefs),
      onChanged: _busy ? null : (bool v) => unawaited(_set(pref.key, v)),
      title: WholeWordText(title),
      subtitle: WholeWordText(subtitle),
    );
  }

  /// Хронология паролей (ADR-015): включение — ослабление D7, только с
  /// мастер-паролем; при выключении — спросить, удалить ли сохранённое.
  Future<void> _setHistory(bool enabled) async {
    if (_busy) return;
    setState(() => _busy = true);
    var ok = false;
    try {
      if (enabled) {
        ok = await askVaultConfirm(
          context,
          kit: kit,
          title: 'Хранить прежние пароли?',
          text: 'Прежние пароли будут храниться в сейфе зашифрованными — '
              'это ослабляет защиту. Подтвердите.',
          check: (VaultProof proof) =>
              kit.setPasswordHistory(true, proof: proof),
        );
      } else {
        bool? purge = false;
        if (kit.historyCount > 0) {
          purge = await showDialog<bool>(
            context: context,
            builder: (BuildContext context) => AlertDialog(
              scrollable: true,
              title: const WholeWordText(
                'Удалить сохранённые прежние пароли всех записей?',
              ),
              content: const Text(
                'Если оставить, при смене пароля старый больше не '
                'сохраняется, а сохранённые останутся в записях — их можно '
                'удалить по одному. Удалённое вернуть можно только из '
                'резервной копии.',
              ),
              actions: <Widget>[
                TextButton(
                  key: const ValueKey<String>('prefs-history-keep'),
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Оставить'),
                ),
                TextButton(
                  key: const ValueKey<String>('prefs-history-purge'),
                  style: TextButton.styleFrom(
                    foregroundColor: context.colors.danger,
                  ),
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Удалить'),
                ),
              ],
            ),
          );
          // Закрыли диалог мимо кнопок — ничего не меняем.
          if (purge == null) return;
        }
        ok = await kit.setPasswordHistory(false, purge: purge);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!ok && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Настройка не изменена.')),
      );
    }
  }

  Future<void> _changeMaster() async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => _ChangeMasterDialog(kit: kit),
    );
    if ((changed ?? false) && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text(
            'Мастер-пароль сменён, сейф перешифрован новым ключом.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Настройки сейфа — сгруппированный экран (ADR-027).
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        backgroundColor: context.colors.background,
        title: const Text('Настройки паролей'),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 32),
            children: <Widget>[
              InsetGroup(
                header: 'Защита',
                footer: kit.isProtected
                    ? 'Эти настройки хранятся внутри зашифрованного сейфа. '
                        'Ослабить защиту можно только с подтверждением.'
                    : 'Эти настройки хранятся внутри зашифрованного сейфа. '
                        'Ослабить защиту можно только мастер-паролем.',
                children: <Widget>[
                  _choice(
                    'Запирать без действий через',
                    VaultPrefs.autolockMinutes,
                    'мин',
                  ),
                  if (!kit.isProtected)
                    _choice(
                      'Мастер-пароль каждые',
                      VaultPrefs.masterEveryHours,
                      'ч',
                    ),
                  _choice(
                    'Время показа пароля',
                    VaultPrefs.revealSeconds,
                    'с',
                  ),
                  if (kit.canCopySecrets)
                    _choice(
                      'Очистка буфера через',
                      VaultPrefs.clipboardSeconds,
                      'с',
                    ),
                  _flag(
                    'Переспрашивать для важных',
                    'Показ и копирование важных записей — с подтверждением.',
                    VaultPrefs.repromptImportant,
                  ),
                  SwitchListTile(
                    key: const ValueKey<String>('prefs-pw_history'),
                    value: kit.historyEnabled,
                    onChanged:
                        _busy ? null : (bool v) => unawaited(_setHistory(v)),
                    title: const WholeWordText(
                      'Хранить прежние пароли (хронология)',
                    ),
                    subtitle: const WholeWordText(
                      'Выключено: старый пароль стирается при смене. '
                      'Включено: прежние пароли хранятся зашифрованными в '
                      'записи, ошибочные можно удалить.',
                    ),
                  ),
                ],
              ),
              VaultAccessSection(kit: kit),
              InsetGroup(
                header: 'Что попадает в историю',
                footer: 'Пароли и заметки в историю не попадают никогда: в '
                    'сессии остаются только названия, логин в маске и факты '
                    'вроде «пароль был показан». «Очистить историю» сейф не '
                    'трогает.',
                children: <Widget>[
                  _flag(
                    'Подсказки можно хранить в истории',
                    'Выключено: подсказка видна только во временной '
                        'карточке, в историю сессии не пишется.',
                    VaultPrefs.hintsInHistory,
                  ),
                  _flag(
                    'Показывать логин целиком в сессии',
                    'Выключено: в ответах логин в маске (iv***@mail.ru), '
                        'целиком — только в карточке.',
                    VaultPrefs.loginInReplies,
                  ),
                ],
              ),
              InsetGroup(
                header: kit.isProtected ? 'Сейф' : 'Мастер-пароль',
                footer: kit.protectionNoteFor(
                  pin: kit.vault.protection?.pin ?? false,
                  bio: kit.vault.protection?.bio ?? false,
                  inSettings: true,
                ),
                children: <Widget>[
                  if (!kit.isProtected)
                    GroupedRow(
                      key: const ValueKey<String>('prefs-change-master'),
                      icon: Icons.key_outlined,
                      tile: context.colors.tileGray,
                      title: 'Сменить мастер-пароль',
                      subtitle: 'Сейф перешифруется новым ключом: старый '
                          'мастер-пароль больше ничего не откроет.',
                      chevron: true,
                      onTap: () => unawaited(_changeMaster()),
                    ),
                  GroupedRow(
                    key: const ValueKey<String>('prefs-start-over'),
                    icon: Icons.inventory_2_outlined,
                    tile: context.colors.tileRed,
                    title: 'Отложить сейф в архив',
                    subtitle: kit.isProtected
                        ? 'Начать заново с пустым сейфом: файл не стирается.'
                        : 'Для тех, кто забыл мастер-пароль: файл не '
                            'стирается, можно начать заново.',
                    chevron: true,
                    onTap: () => unawaited(showRecovery(context, kit)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChangeMasterDialog extends StatefulWidget {
  const _ChangeMasterDialog({required this.kit});

  final PasswordsKit kit;

  @override
  State<_ChangeMasterDialog> createState() => _ChangeMasterDialogState();
}

class _ChangeMasterDialogState extends State<_ChangeMasterDialog> {
  final TextEditingController _current = TextEditingController();
  final TextEditingController _next = TextEditingController();
  final TextEditingController _repeat = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in <TextEditingController>[_current, _next, _repeat]) {
      c
        ..clear()
        ..dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    // Повтор с записями — в [PasswordsKit.changeMaster], после проверки
    // текущего мастер-пароля (15.2): до неё это оракул по важным записям.
    final problem = masterProblem(_next.text, strength: widget.kit.strength);
    if (problem != null || _next.text != _repeat.text) {
      setState(() => _error = problem ?? 'Новые пароли не совпадают.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final current = _current.text;
    final next = _next.text;
    for (final c in <TextEditingController>[_current, _next, _repeat]) {
      c.clear();
    }
    try {
      await widget.kit.changeMaster(current, next);
      if (mounted) Navigator.of(context).pop(true);
    } on PasswordProblem catch (problem) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = problem.text;
        });
      }
    } on VaultError catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = vaultErrorText(error.code);
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Не получилось сменить мастер-пароль.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const WholeWordText('Сменить мастер-пароль'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SecretField(
              key: const ValueKey<String>('change-current'),
              controller: _current,
              label: 'Текущий мастер-пароль',
              enabled: !_busy,
            ),
            const SizedBox(height: 10),
            SecretField(
              key: const ValueKey<String>('change-next'),
              controller: _next,
              label: 'Новый мастер-пароль',
              helper: 'Не короче 12 символов.',
              enabled: !_busy,
            ),
            const SizedBox(height: 10),
            SecretField(
              key: const ValueKey<String>('change-repeat'),
              controller: _repeat,
              label: 'Новый ещё раз',
              error: _error,
              enabled: !_busy,
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(minHeight: 2),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Отмена'),
        ),
        TextButton(
          key: const ValueKey<String>('change-submit'),
          onPressed: _busy ? null : () => unawaited(_submit()),
          child: const Text('Сменить'),
        ),
      ],
    );
  }
}
