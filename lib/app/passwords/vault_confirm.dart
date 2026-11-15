import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/passwords/secret_bytes.dart';
import '../../core/passwords/vault.dart';
import '../../core/passwords/vault_errors.dart';
import '../../core/passwords/vault_store.dart';
import '../assistant_theme.dart';
import '../security/device_auth.dart';
import '../widgets/whole_word_text.dart';
import 'passwords_kit.dart';
import 'pin_pad.dart';
import 'secret_widgets.dart';

/// Подтверждение действия с открытым сейфом (ADR-025) — вместо прежнего
/// «введите мастер-пароль»: переспрос для важных записей, ослабление
/// настроек, «Заменить всё», новый код восстановления.
///
/// Чем подтверждать, решает защита сейфа:
/// * старый сейф с мастер-паролем — мастер-пароль, как раньше;
/// * ПИН-код и (или) биометрия — набор ПИН-кода и кнопка «По отпечатку /
///   Face ID»; только биометрия — сразу системный запрос;
/// * только устройство — системный запрос блокировки экрана, а если её
///   нет — кнопка «Подтвердить» (честно: такой сейф открывает любой, у
///   кого телефон и приложение);
/// * путь по ПИН-коду закрыт и другого нет — код восстановления.
///
/// [check] получает подтверждение и выполняет действие; `true` — готово.
/// Байты ввода затираются сразу после [check].
Future<bool> askVaultConfirm(
  BuildContext context, {
  required PasswordsKit kit,
  required String title,
  required Future<bool> Function(VaultProof proof) check,
  String? text,
}) async {
  final info = kit.vault.protection;
  if (info == null || info.usesMaster) {
    return askMaster(
      context,
      title: title,
      text: text,
      check: (String master) async {
        final bytes = SecretBytes.fromText(master);
        try {
          return await check(SecretProof(bytes));
        } finally {
          bytes.wipe();
        }
      },
    );
  }
  if (!info.pin && info.bio) {
    final ok = await check(const BioProof('Подтвердить действие с сейфом'));
    if (ok || !context.mounted) return ok;
    // Отпечаток сброшен системой — слот снят: подтвердить кодом.
    if (kit.vault.protection?.bio ?? false) return false;
  } else if (info.device) {
    final status = await kit.auth.status();
    if (status.available) {
      final result = await kit.auth.authenticate(title);
      if (result == DeviceAuthResult.ok) return check(const DeviceProof());
      if (result != DeviceAuthResult.unavailable) return false;
    }
    if (!context.mounted) return false;
    final go = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        scrollable: true,
        title: WholeWordText(title),
        content: WholeWordText(
          text ?? 'Подтвердите действие.',
          style: TextStyle(color: context.colors.text),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            key: const ValueKey<String>('vault-confirm-ok'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Подтвердить'),
          ),
        ],
      ),
    );
    if (go != true) return false;
    return check(const DeviceProof());
  }
  if (!context.mounted) return false;
  final result = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => _ConfirmDialog(
      kit: kit,
      title: title,
      text: text,
      check: check,
    ),
  );
  return result ?? false;
}

/// Текст ошибки ПИН-кода по счётчику и защите сейфа (без цифр).
Future<String> pinErrorText(PasswordsKit kit) async =>
    (await pinError(kit)).text;

/// Ошибка ПИН-кода и пауза: пока пауза идёт ([until] не `null`), пульт
/// сам показывает отсчёт и не нажимается ([PinPad.until]).
Future<({String text, DateTime? until})> pinError(PasswordsKit kit) async {
  final info = kit.vault.protection ?? await kit.lockInfo();
  if (info != null && !info.pin) {
    return (
      text: 'ПИН-код больше не принимается. Откройте сейф кодом '
          'восстановления.',
      until: null,
    );
  }
  final attempts = await kit.pinAttempts();
  final now = kit.vault.clock.now();
  final until = attempts.blockedUntil(now);
  if (until != null) {
    return (text: PinPad.pauseText(until, now), until: until);
  }
  if (attempts.fails >= PinAttempts.warnFrom) {
    return (
      text: 'ПИН-код не подошёл. Осталось попыток: ${attempts.left}.',
      until: null,
    );
  }
  return (text: 'ПИН-код не подошёл.', until: null);
}

class _ConfirmDialog extends StatefulWidget {
  const _ConfirmDialog({
    required this.kit,
    required this.title,
    required this.check,
    this.text,
  });

  final PasswordsKit kit;
  final String title;
  final String? text;
  final Future<bool> Function(VaultProof proof) check;

  @override
  State<_ConfirmDialog> createState() => _ConfirmDialogState();
}

class _ConfirmDialogState extends State<_ConfirmDialog> {
  final TextEditingController _code = TextEditingController();
  late bool _useCode = !(widget.kit.vault.protection?.pin ?? false) &&
      !(widget.kit.vault.protection?.bio ?? false);
  bool _busy = false;
  String? _error;
  DateTime? _until;

  @override
  void initState() {
    super.initState();
    if (widget.kit.vault.protection?.pin ?? false) unawaited(_loadPause());
  }

  /// Пауза могла начаться раньше (прошлый диалог, замок).
  Future<void> _loadPause() async {
    final attempts = await widget.kit.pinAttempts();
    final until = attempts.blockedUntil(DateTime.now());
    if (!mounted || until == null) return;
    setState(() => _until = until);
  }

  @override
  void dispose() {
    _code
      ..clear()
      ..dispose();
    super.dispose();
  }

  Future<void> _run(Future<bool> Function() action, {bool pin = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await action();
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    final info = widget.kit.vault.protection;
    final String error;
    DateTime? until;
    if (pin) {
      final result = await pinError(widget.kit);
      error = result.text;
      until = result.until;
    } else if (_useCode) {
      error = 'Код восстановления не подошёл (или слишком много ошибок — '
          'подождите).';
    } else if (info != null && !info.bio) {
      error = vaultErrorText(VaultErrorCode.bioInvalidated);
    } else {
      error = 'Не подтверждено.';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = until == null ? error : null;
      _until = until;
      if (info != null && !info.pin && !info.bio) _useCode = true;
    });
  }

  Future<void> _pin(SecretBytes pin) =>
      _run(() => widget.check(PinProof(pin)), pin: true);

  Future<void> _bio() =>
      _run(() => widget.check(const BioProof('Подтвердить действие с сейфом')));

  Future<void> _submitCode() async {
    if (_code.text.isEmpty) return;
    final text = _code.text;
    _code.clear();
    await _run(() async {
      final bytes = SecretBytes.fromText(text);
      try {
        return await widget.check(SecretProof(bytes));
      } finally {
        bytes.wipe();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.kit.vault.protection;
    final bio = info?.bio ?? false;
    final pin = (info?.pin ?? false) && !_useCode;
    return SecureWindowScope(
      auth: widget.kit.auth,
      child: AlertDialog(
        key: const ValueKey<String>('vault-confirm'),
        scrollable: true,
        title: WholeWordText(widget.title),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (widget.text != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: WholeWordText(
                    widget.text!,
                    style: TextStyle(color: context.colors.muted),
                  ),
                ),
              if (pin) ...<Widget>[
                WholeWordText(
                  'Введите ПИН-код сейфа.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.colors.text),
                ),
                const SizedBox(height: 12),
                Center(
                  child: PinPad(
                    now: widget.kit.vault.clock.now,
                    enabled: !_busy,
                    error: _error,
                    until: _until,
                    onPauseEnd: () => setState(() {
                      _until = null;
                      _error = null;
                    }),
                    onComplete: _pin,
                  ),
                ),
              ] else if (_useCode) ...<Widget>[
                SecretField(
                  key: const ValueKey<String>('vault-confirm-code'),
                  controller: _code,
                  label: 'Код восстановления',
                  error: _error,
                  autofocus: true,
                  allowShow: true,
                  enabled: !_busy,
                  onSubmitted: (_) => unawaited(_submitCode()),
                ),
              ] else if (_error != null)
                WholeWordText(
                  _error!,
                  style: TextStyle(color: context.colors.danger),
                ),
              if (bio && !_useCode)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: OutlinedButton.icon(
                    key: const ValueKey<String>('vault-confirm-bio'),
                    onPressed: _busy ? null : () => unawaited(_bio()),
                    icon: const Icon(Icons.fingerprint, size: 18),
                    label: const Text('По отпечатку / Face ID'),
                  ),
                ),
              if (!_useCode)
                TextButton(
                  key: const ValueKey<String>('vault-confirm-use-code'),
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                            _useCode = true;
                            _error = null;
                          }),
                  child: const Text('Подтвердить кодом восстановления'),
                ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          if (_useCode)
            TextButton(
              key: const ValueKey<String>('vault-confirm-submit'),
              onPressed: _busy ? null : () => unawaited(_submitCode()),
              child: Text(_busy ? 'Проверяю…' : 'Подтвердить'),
            ),
        ],
      ),
    );
  }
}
