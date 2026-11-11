import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../../core/passwords/secret_bytes.dart';
import '../../core/passwords/vault_crypto.dart';
import 'passwords_platform.dart';

/// Буфер обмена для паролей (D22, базовая версия этапа 2).
///
/// Копирует пароль и очищает буфер через заданное время, при запирании
/// хранилища, выходе и выключении навыка. Очищает, только если в буфере
/// всё ещё наше значение: сравнение — по BLAKE2b с ключом сеанса, а не по
/// самому тексту (сам пароль здесь не хранится). На Android буфер
/// очищается без чтения.
///
/// На Windows и macOS копировать пароль нельзя ([canCopySecrets] —
/// `false`): без своего канала Windows уносит буфер в облачный буфер
/// Microsoft, а macOS — на iPhone через Handoff (этап 4).
final class ClipboardGuard {
  ClipboardGuard({
    required this.platform,
    required VaultCipher cipher,
    Future<void> Function(String text)? write,
    Future<String?> Function()? read,
  })  : _cipher = cipher,
        _write = write ?? _systemWrite,
        _read = read ?? _systemRead;

  final PasswordsPlatform platform;
  final VaultCipher _cipher;
  final Future<void> Function(String text) _write;
  final Future<String?> Function() _read;

  VaultKey? _session;
  Uint8List? _ours;
  Timer? _timer;

  /// Можно ли копировать пароль на этой платформе.
  bool get canCopySecrets => platform.canCopySecrets;

  /// В буфере сейчас (насколько мы знаем) наш пароль.
  bool get holdsSecret => _ours != null;

  static Future<void> _systemWrite(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  static Future<String?> _systemRead() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;

  Uint8List _digest(String text) {
    final key = _session ??= _cipher.randomKey();
    final bytes = Uint8List.fromList(utf8.encode(text));
    try {
      return _cipher.keyedHash(key, bytes);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  /// Копирует [secret] и затирает его. Через [clearAfter] буфер
  /// очистится, если в нём всё ещё это значение. На Windows и macOS —
  /// `StateError` (кнопки там нет).
  Future<void> copySecret(SecretBytes secret, Duration clearAfter) async {
    if (!canCopySecrets) {
      secret.wipe();
      throw StateError('копирование пароля здесь недоступно');
    }
    // Строка из пароля создаётся только здесь и в SecretRevealText (3.7).
    final String text;
    try {
      text = utf8.decode(secret.unsafeBytes);
    } finally {
      secret.wipe();
    }
    _timer?.cancel();
    _ours = _digest(text);
    await _write(text);
    _timer = Timer(clearAfter, () => unawaited(clearIfOurs()));
  }

  /// Копирует обычный текст (логин): не секрет, не очищается.
  Future<void> copyText(String text) => _write(text);

  /// Очищает буфер, если там наш пароль. На Android — без чтения.
  Future<void> clearIfOurs() async {
    _timer?.cancel();
    _timer = null;
    final ours = _ours;
    if (ours == null) return;
    _ours = null;
    try {
      if (platform == PasswordsPlatform.android) {
        await _write('');
        return;
      }
      final current = await _read();
      if (current == null || current.isEmpty) return;
      if (_cipher.equal(_digest(current), ours)) await _write('');
    } on Object {
      // Буфер недоступен: очищать нечего или нельзя.
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _session?.dispose();
    _session = null;
  }
}
