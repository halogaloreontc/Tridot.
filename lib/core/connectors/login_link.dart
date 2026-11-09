/// Ссылка входа из окна «Войти на телефоне» (`https://<склад>/#qr=<код>`),
/// вставленная не туда — в чат. Код одноразовый и меняется на пароль
/// склада и личный ключ: в истории чата его быть не должно (ADR-011).
abstract final class LoginLinks {
  /// `#qr=`, `?qr=` или `&qr=` и хотя бы 8 знаков hex: и обрезанный код
  /// не сохраняем.
  static final RegExp _code = RegExp(r'([#?&]qr=)[0-9a-fA-F]{8,}');

  /// В тексте есть код входа.
  static bool contains(String text) => _code.hasMatch(text);

  /// Текст без кода: `https://wh.example/#qr=…`.
  static String redact(String text) =>
      text.replaceAllMapped(_code, (Match m) => '${m[1]}…');
}
