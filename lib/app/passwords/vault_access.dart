import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/passwords/secret_bytes.dart';
import '../../core/passwords/vault.dart';
import '../../core/passwords/vault_codes.dart';
import '../../core/passwords/vault_errors.dart';
import '../assistant_theme.dart';
import '../widgets/grouped.dart';
import '../widgets/whole_word_text.dart';
import 'passwords_kit.dart';
import 'pin_pad.dart';
import 'recovery_code_view.dart';
import 'vault_confirm.dart';

/// «Сейф → Настройки → Вход в сейф» (ADR-025): ПИН-код сейфа и вход по
/// отпечатку / Face ID — по желанию, по умолчанию выключены; новый код
/// восстановления. Только у сейфа, защищённого устройством.
class VaultAccessSection extends StatefulWidget {
  const VaultAccessSection({super.key, required this.kit});

  final PasswordsKit kit;

  @override
  State<VaultAccessSection> createState() => _VaultAccessSectionState();
}

class _VaultAccessSectionState extends State<VaultAccessSection> {
  PasswordsKit get kit => widget.kit;
  bool _bioAvailable = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_probe());
  }

  Future<void> _probe() async {
    final available = await kit.bioAvailable();
    if (mounted) setState(() => _bioAvailable = available);
  }

  void _say(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(text)),
      );

  Future<void> _guarded(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setPin(bool on) => _guarded(() async {
        if (on) {
          final ok = await askNewPin(context, kit);
          if (ok && mounted) {
            _say(
              'ПИН-код сейфа включён. Забудете — откроет код '
              'восстановления.',
            );
          }
          return;
        }
        final ok = await askVaultConfirm(
          context,
          kit: kit,
          title: 'Выключить ПИН-код?',
          text: 'Без ПИН-кода сейф снова будет открываться сам, пока открыто '
              'приложение.',
          check: kit.disablePin,
        );
        if (!mounted) return;
        _say(ok ? 'ПИН-код сейфа выключен.' : 'ПИН-код не выключен.');
      });

  Future<void> _changePin() => _guarded(() async {
        final ok = await askNewPin(context, kit, change: true);
        if (ok && mounted) _say('ПИН-код сейфа сменён.');
      });

  Future<void> _setBio(bool on) => _guarded(() async {
        if (on) {
          try {
            await kit.enableBio();
            if (mounted) {
              _say('Сейф теперь открывается по отпечатку / Face ID.');
            }
          } on VaultError catch (error) {
            if (mounted) _say(vaultErrorText(error.code));
          } on Object {
            if (mounted) _say('Не получилось включить.');
          }
          return;
        }
        final ok = await askVaultConfirm(
          context,
          kit: kit,
          title: 'Выключить вход по отпечатку?',
          text: 'Сейф снова будет открываться ПИН-кодом или сам, пока '
              'открыто приложение.',
          check: kit.disableBio,
        );
        if (!mounted) return;
        _say(
          ok ? 'Вход по отпечатку выключен.' : 'Вход по отпечатку не выключен.',
        );
      });

  Future<void> _newCode() => _guarded(() async {
        String? code;
        var rotated = true;
        final ok = await askVaultConfirm(
          context,
          kit: kit,
          title: 'Новый код восстановления',
          text: 'Прежний код перестанет открывать этот сейф.',
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
        if (!rotated && mounted) _say(recoveryNotRotatedNote);
      });

  @override
  Widget build(BuildContext context) {
    final info = kit.vault.protection;
    if (info == null || info.usesMaster) return const SizedBox.shrink();
    return InsetGroup(
      header: 'Вход в Сейф',
      footer: kit.protectionNoteFor(
        pin: kit.vault.protection?.pin ?? false,
        bio: kit.vault.protection?.bio ?? false,
        inSettings: true,
      ),
      children: <Widget>[
        SwitchListTile(
          key: const ValueKey<String>('prefs-vault-pin'),
          value: info.pin,
          onChanged: _busy || !kit.pinAllowed
              ? null
              : (bool v) => unawaited(_setPin(v)),
          title: const WholeWordText('ПИН-код сейфа'),
          subtitle: WholeWordText(
            kit.pinAllowed
                ? '6 цифр, по желанию. После 10 ошибок — только код '
                    'восстановления.'
                : 'На компьютере ПИН-кода нет: его перебрали бы без '
                    'ограничений.',
          ),
        ),
        if (info.pin)
          GroupedRow(
            key: const ValueKey<String>('prefs-vault-pin-change'),
            icon: Icons.pin_outlined,
            tile: context.colors.tileBlue,
            title: 'Сменить ПИН-код',
            chevron: true,
            onTap: _busy ? null : () => unawaited(_changePin()),
          ),
        if (_bioAvailable || info.bio)
          SwitchListTile(
            key: const ValueKey<String>('prefs-vault-bio'),
            value: info.bio,
            onChanged: _busy ? null : (bool v) => unawaited(_setBio(v)),
            title: const WholeWordText('Сейф по отпечатку / Face ID'),
            subtitle: const WholeWordText(
              'Ключ сейфа выдаёт система после отпечатка или блокировки '
              'экрана. Новый отпечаток сбросит этот вход.',
            ),
          ),
        GroupedRow(
          key: const ValueKey<String>('prefs-vault-new-code'),
          icon: Icons.vpn_key_outlined,
          tile: context.colors.tileViolet,
          title: 'Новый код восстановления',
          subtitle: 'Прежний код перестанет открывать этот сейф. Копии, '
              'сделанные раньше, открываются тем, чем были закрыты.',
          chevron: true,
          onTap: _busy ? null : () => unawaited(_newCode()),
        ),
      ],
    );
  }
}

/// Задать (или сменить, [change]) ПИН-код сейфа: текущий, новый, ещё раз.
/// Слабый ПИН-код (одинаковые цифры, подряд, повторы) не принимается.
/// `true` — записан.
Future<bool> askNewPin(
  BuildContext context,
  PasswordsKit kit, {
  bool change = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => _NewPinDialog(kit: kit, change: change),
  );
  return ok ?? false;
}

enum _PinStep { current, first, repeat }

class _NewPinDialog extends StatefulWidget {
  const _NewPinDialog({required this.kit, required this.change});

  final PasswordsKit kit;
  final bool change;

  @override
  State<_NewPinDialog> createState() => _NewPinDialogState();
}

class _NewPinDialogState extends State<_NewPinDialog> {
  late _PinStep _step = widget.change ? _PinStep.current : _PinStep.first;
  SecretBytes? _current;
  SecretBytes? _first;
  String? _error;
  bool _busy = false;
  DateTime? _until;

  @override
  void dispose() {
    _current?.wipe();
    _first?.wipe();
    super.dispose();
  }

  Future<void> _entered(SecretBytes pin) async {
    switch (_step) {
      case _PinStep.current:
        _current?.wipe();
        _current = pin.clone();
        setState(() {
          _step = _PinStep.first;
          _error = null;
        });
      case _PinStep.first:
        final problem = VaultPin.problem(pin);
        if (problem != null) {
          setState(() => _error = problem);
          return;
        }
        _first?.wipe();
        _first = pin.clone();
        setState(() {
          _step = _PinStep.repeat;
          _error = null;
        });
      case _PinStep.repeat:
        final first = _first;
        if (first == null) return;
        if (!_same(first, pin)) {
          first.wipe();
          _first = null;
          setState(() {
            _step = _PinStep.first;
            _error = 'ПИН-коды не совпали. Задайте ещё раз.';
          });
          return;
        }
        await _save(pin);
    }
  }

  static bool _same(SecretBytes a, SecretBytes b) {
    final x = a.unsafeBytes;
    final y = b.unsafeBytes;
    if (x.length != y.length) return false;
    var diff = 0;
    for (var i = 0; i < x.length; i++) {
      diff |= x[i] ^ y[i];
    }
    return diff == 0;
  }

  Future<void> _save(SecretBytes pin) async {
    setState(() => _busy = true);
    try {
      final current = _current;
      if (widget.change && current != null) {
        await widget.kit.changePin(current, pin);
      } else {
        await widget.kit.enablePin(pin);
      }
      if (mounted) Navigator.of(context).pop(true);
    } on VaultError catch (error) {
      final String text;
      DateTime? until;
      if (error.code == VaultErrorCode.wrongPassword ||
          error.code == VaultErrorCode.rateLimited) {
        final result = await pinError(widget.kit);
        text = result.text;
        until = result.until;
      } else {
        text = vaultErrorText(error.code);
      }
      if (!mounted) return;
      _current?.wipe();
      _current = null;
      _first?.wipe();
      _first = null;
      setState(() {
        _busy = false;
        _error = until == null ? text : null;
        _until = until;
        _step = widget.change ? _PinStep.current : _PinStep.first;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Не получилось записать ПИН-код.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final prompt = switch (_step) {
      _PinStep.current => 'Текущий ПИН-код сейфа',
      _PinStep.first => 'Новый ПИН-код: 6 цифр',
      _PinStep.repeat => 'Ещё раз',
    };
    return SecureWindowScope(
      auth: widget.kit.auth,
      child: AlertDialog(
        key: const ValueKey<String>('new-pin-dialog'),
        scrollable: true,
        title: WholeWordText(
          widget.change ? 'Сменить ПИН-код' : 'ПИН-код сейфа',
        ),
        content: SizedBox(
          width: 340,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              WholeWordText(
                prompt,
                key: const ValueKey<String>('new-pin-step'),
                textAlign: TextAlign.center,
                style: TextStyle(color: context.colors.text),
              ),
              // Низкий экран: подсказку не показываем — иначе «0» и
              // «стереть» уходят за край диалога.
              if (_step == _PinStep.first &&
                  !widget.change &&
                  MediaQuery.sizeOf(context).height >= 700) ...<Widget>[
                const SizedBox(height: 6),
                WholeWordText(
                  'Не 111111 и не 123456. Забудете — сейф откроет код '
                  'восстановления.',
                  key: ValueKey<String>('new-pin-hint'),
                  textAlign: TextAlign.center,
                  style: metaStyle(context),
                ),
              ],
              const SizedBox(height: 12),
              PinPad(
                now: widget.kit.vault.clock.now,
                key: ValueKey<_PinStep>(_step),
                enabled: !_busy,
                error: _error,
                until: _step == _PinStep.current ? _until : null,
                onPauseEnd: () => setState(() {
                  _until = null;
                  _error = null;
                }),
                onComplete: _entered,
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
        ],
      ),
    );
  }
}
