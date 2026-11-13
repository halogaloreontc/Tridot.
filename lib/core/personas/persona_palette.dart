/// Цвета помощников из палитры «П1» (ARGB): единственное место, где они
/// заданы. Ядро не зависит от Flutter, поэтому здесь числа, а
/// `AssistantColors` в интерфейсе строит из них `Color`.
abstract final class PersonaPalette {
  /// Садо: акцент и фон знака. Третий акцент П1, фиолетовый (ADR-016).
  static const int sado = 0xFFB69CFF;
  static const int sadoBg = 0xFF2A1D4D;

  /// Садо на светлом фоне (#FFFFFF, #F5F7F6): [sado] там слишком светел.
  /// Светлой темы пока нет — цвет на будущее, контраст проверен тестом.
  static const int sadoOnLight = 0xFF6A40D8;

  /// Лиорио: акцент и фон знака.
  static const int liorio = 0xFF6CB8FF;
  static const int liorioBg = 0xFF12304D;

  /// Нода: акцент и фон знака.
  static const int noda = 0xFFFFAE63;
  static const int nodaBg = 0xFF40280F;
}
