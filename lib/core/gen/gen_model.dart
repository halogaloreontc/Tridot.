/// Генеративная модель «Продвинутой» (ADR-046) для ядра: ответ по
/// системному запросу и фразе, по желанию — под грамматикой GBNF.
/// Приложение подставляет llama.cpp, тесты — подделку.
abstract interface class GenModel {
  /// Жадный ответ модели. [grammar] — GBNF llama.cpp: вывод строго по ней.
  Future<String> complete({
    required String system,
    required String user,
    String? grammar,
    int maxTokens = 200,
  });
}
