/// Цвета помощников из палитры «П1» (ARGB): единственное место, где они
/// заданы. Ядро не зависит от Flutter, поэтому здесь числа, а
/// `AssistantColors` в интерфейсе строит из них `Color`.
abstract final class PersonaPalette {
  /// Лиорио: акцент и фон знака.
  static const int liorio = 0xFF6CB8FF;
  static const int liorioBg = 0xFF12304D;

  /// Нода: акцент и фон знака.
  static const int noda = 0xFFFFAE63;
  static const int nodaBg = 0xFF40280F;
}
