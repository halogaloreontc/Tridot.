/// Цвета помощников из палитры «П2» (ARGB, ADR-027): единственное место,
/// где они заданы. Ядро не зависит от Flutter, поэтому здесь числа, а
/// `AppPalette` в интерфейсе строит из них `Color` для тёмной и светлой
/// темы.
abstract final class PersonaPalette {
  /// Связной: акцент и фон знака в тёмной теме. Фиолетовый, он же общий
  /// акцент приложения (ADR-016, ADR-027).
  static const int sado = 0xFFB69CFF;
  static const int sadoBg = 0xFF2E2452;

  /// Связной в светлой теме: [sado] на белом слишком светел.
  static const int sadoOnLight = 0xFF6A40D8;
  static const int sadoBgOnLight = 0xFFEEE8FF;

  /// Лиорио: акцент и фон знака. Пастельный лазурный.
  static const int liorio = 0xFF8ED1F2;
  static const int liorioBg = 0xFF123444;
  static const int liorioOnLight = 0xFF085F84;
  static const int liorioBgOnLight = 0xFFE1F2FA;

  /// Нода: акцент и фон знака. Нежно-розовый.
  static const int noda = 0xFFF5A8CB;
  static const int nodaBg = 0xFF4A2334;
  static const int nodaOnLight = 0xFFA8326A;
  static const int nodaBgOnLight = 0xFFFBE7F0;
}
