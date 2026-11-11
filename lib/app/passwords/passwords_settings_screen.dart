import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/passwords/vault_errors.dart';
import '../../core/passwords/vault_prefs.dart';
import '../assistant_theme.dart';
import '../widgets/task_tile.dart';
import 'entry_screens.dart';
import 'passwords_kit.dart';
import 'passwords_screen.dart';
import 'secret_widgets.dart';

/// «Пароли → Настройки» (раздел 9). Защитные настройки живут внутри
/// зашифрованного индекса: меняются только в открытом хранилище, а
/// ослабление (дольше, реже, подсказки или логин в истории, без
/// переспроса) — только после ввода мастер-пароля.
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
        ok = await askMaster(
          context,
          title: 'Ослабить защиту?',
          text: 'Эта настройка делает хранилище менее защищённым. '
              'Подтвердите мастер-паролем.',
          check: (String master) => kit.setPrefs(changes, master: master),
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      title: Text(title, style: const TextStyle(color: AssistantColors.text)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final option in pref.choices)
              ChoiceChip(
                key: ValueKey<String>('prefs-${pref.key}-$option'),
                label: Text('$option $unit'),
                selected: option == value,
                selectedColor: AssistantColors.bubble,
                backgroundColor: AssistantColors.workspace,
                checkmarkColor: AssistantColors.success,
                labelStyle: TextStyle(
                  color: option == value
                      ? AssistantColors.textStrong
                      : AssistantColors.text,
                ),
                side: BorderSide(
                  color: option == value
                      ? AssistantColors.success
                      : AssistantColors.border,
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      value: pref.of(kit.vault.prefs),
      onChanged: _busy ? null : (bool v) => unawaited(_set(pref.key, v)),
      title: Text(title, style: const TextStyle(color: AssistantColors.text)),
      subtitle: Text(
        subtitle,
        style: const TextStyle(color: AssistantColors.muted),
      ),
    );
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
            'Мастер-пароль сменён, хранилище перешифровано новым ключом.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AssistantColors.workspace,
      appBar: AppBar(
        backgroundColor: AssistantColors.workspace,
        title: const Text('Настройки паролей'),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 32),
            children: <Widget>[
              const SectionLabel('ЗАЩИТА'),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  'Эти настройки хранятся внутри зашифрованного хранилища. '
                  'Ослабить защиту можно только мастер-паролем.',
                  style: technicalTextStyle,
                ),
              ),
              _choice(
                'Запирать без действий через',
                VaultPrefs.autolockMinutes,
                'мин',
              ),
              _choice('Мастер-пароль каждые', VaultPrefs.masterEveryHours, 'ч'),
              _choice('Время показа пароля', VaultPrefs.revealSeconds, 'с'),
              if (kit.canCopySecrets)
                _choice(
                  'Очистка буфера через',
                  VaultPrefs.clipboardSeconds,
                  'с',
                ),
              _flag(
                'Переспрашивать для важных',
                'Показ и копирование важных записей — с мастер-паролем.',
                VaultPrefs.repromptImportant,
              ),
              const SectionLabel('ЧТО ПОПАДАЕТ В ИСТОРИЮ'),
              _flag(
                'Подсказки можно хранить в истории',
                'Выключено: подсказка видна только во временной карточке, '
                    'в историю чата не пишется.',
                VaultPrefs.hintsInHistory,
              ),
              _flag(
                'Показывать логин целиком в чате',
                'Выключено: в ответах логин в маске (iv***@mail.ru), '
                    'целиком — только в карточке.',
                VaultPrefs.loginInReplies,
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: Text(
                  'Пароли и заметки в историю не попадают никогда: в чате '
                  'остаются только названия, логин в маске и факты вроде '
                  '«пароль был показан». «Очистить историю» хранилище не '
                  'трогает.',
                  style: technicalTextStyle,
                ),
              ),
              const SectionLabel('МАСТЕР-ПАРОЛЬ'),
              ListTile(
                key: const ValueKey<String>('prefs-change-master'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                leading: const Icon(Icons.key_outlined),
                title: const Text('Сменить мастер-пароль'),
                subtitle: const Text(
                  'Хранилище перешифруется новым ключом: старый мастер-пароль '
                  'больше ничего не откроет.',
                ),
                onTap: () => unawaited(_changeMaster()),
              ),
              ListTile(
                key: const ValueKey<String>('prefs-start-over'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                leading: const Icon(
                  Icons.inventory_2_outlined,
                  color: AssistantColors.danger,
                ),
                title: const Text('Отложить хранилище в архив'),
                subtitle: const Text(
                  'Для тех, кто забыл мастер-пароль: файл не стирается, '
                  'можно начать заново.',
                ),
                onTap: () => unawaited(showRecovery(context, kit)),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(kit.platform.unlockNote, style: technicalTextStyle),
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
      backgroundColor: AssistantColors.raised,
      title: const Text('Сменить мастер-пароль'),
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
