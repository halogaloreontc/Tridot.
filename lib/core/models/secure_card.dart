/// Вид временной карточки навыка «Пароли» (раздел 8).
enum SecureCardKind {
  unlock,
  hint,
  reveal,
  copy,
  generate,
  check,
  choose,
  list,
  training,
  importPreview,
}

/// Временная карточка под ответом (D10): несёт только id записей и
/// параметры, значение пароля берёт `VaultRevealService` в момент показа.
///
/// Её нет в `ChatMessage.toJson`/`fromJson`, и `ChatMessage.copyAs` её не
/// копирует: после перезапуска в истории остаётся только текст ответа.
final class SecureCardRequest {
  const SecureCardRequest({
    required this.kind,
    this.entryIds = const <String>[],
    this.options = const <String, Object?>{},
    this.resume,
  });

  final SecureCardKind kind;

  /// Записи карточки — только id.
  final List<String> entryIds;

  /// Параметры без секретов: длина генератора, номер ступени подсказки.
  final Map<String, Object?> options;

  /// Команда, которую повторить после открытия хранилища (`unlock`).
  final String? resume;

  @override
  String toString() => 'SecureCardRequest(${kind.name}, ${entryIds.length})';
}
