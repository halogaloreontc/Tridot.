/// Цвета помощников из палитры «П1» (ARGB): единственное место, где они
/// заданы. Ядро не зависит от Flutter, поэтому здесь числа, а
/// `AssistantColors` в интерфейсе строит из них `Color`.
abstract final class PersonaPalette {
  /// Связной: акцент и фон знака. Третий акцент П1, фиолетовый (ADR-016).
  static const int sado = 0xFFB69CFF;
  static const int sadoBg = 0xFF2A1D4D;

  /// Связной на светлом фоне (#FFFFFF, #F5F7F6): [sado] там слишком светел.
  /// Светлой темы пока нет — цвет на будущее, контраст проверен тестом.
  static const int sadoOnLight = 0xFF6A40D8;

  /// Лиорио: акцент и фон знака. Пастельный лазурный.
  static const int liorio = 0xFF8ED1F2;
  static const int liorioBg = 0xFF10313F;

  /// Нода: акцент и фон знака. Нежно-розовый.
  static const int noda = 0xFFF5A8CB;
  static const int nodaBg = 0xFF46202F;
}
