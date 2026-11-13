import 'dart:io';

/// Платформа для навыка «Пароли»: что здесь можно и что честно сказать.
enum PasswordsPlatform {
  android,
  windows,
  macos,
  linux,
  other;

  static PasswordsPlatform get current {
    if (Platform.isAndroid) return android;
    if (Platform.isWindows) return windows;
    if (Platform.isMacOS) return macos;
    if (Platform.isLinux) return linux;
    return other;
  }

  /// Копировать пароль в буфер: на Windows и macOS — нет, пока нет канала
  /// без облачного буфера, истории и Handoff (D22, этап 4).
  bool get canCopySecrets => this != windows && this != macos;

  /// Честная строка о входе на этой платформе (решения владельца №3, №5).
  String get unlockNote => switch (this) {
        windows => 'На Windows сейф открывается только мастер-паролем.',
        macos => 'На macOS пока только мастер-пароль: вход по Touch ID '
            'появится, когда сборка будет подписана.',
        linux => 'На Linux вход по отпечатку и защита от снимков экрана '
            'недоступны — только мастер-пароль.',
        android => 'Вход по отпечатку появится в следующем обновлении — '
            'пока только мастер-пароль.',
        other => 'Сейф открывается мастер-паролем.',
      };

  /// Почему кнопки «Скопировать» у пароля нет.
  String? get copyNote => canCopySecrets
      ? null
      : 'Копирование паролей на этом компьютере появится позже: Windows и '
          'macOS могут отправить буфер обмена на другие устройства.';
}
