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

  /// «Импорт из браузера» (5.6): кнопка экрана импорта CSV.
  importPreview,

  /// «Резервная копия» (5.7): кнопка экрана копии.
  backup,

  /// «Восстановить из копии» (5.7, 5.12): работает и без хранилища.
  restore,

  /// Логин записи целиком (в пузыре — маска, D15).
  login,

  /// Открыть редактор записи (добавить или сменить пароль).
  editor,

  /// «Забыл мастер-пароль»: честные пути этого устройства (5.11).
  recovery,

  /// Удалить запись — только кнопкой карточки.
  delete,
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

/// Нажатие в карточке, которое выполняет навык (не сообщение в чате):
/// выбор записи, удаление кнопкой, отметка «пароль был показан». Несёт
/// только id и имя действия.
final class SecureCardCommand {
  const SecureCardCommand(
    this.card,
    this.action, {
    this.entryId,
    this.detail,
  });

  final SecureCardRequest card;

  /// `choose` (выбрана запись), `resume` (хранилище открыто — повторить
  /// команду), `delete` (кнопка «Удалить»), `revealed` / `copied` (в
  /// историю — только факт).
  final String action;

  final String? entryId;

  /// Уточнение без секретов: номер ступени подсказки (`hintStep`), итог
  /// тренировки (`trained`: `correct`, `helped`, `wrong`, `skipped`,
  /// `stopped`).
  final String? detail;

  static const String choose = 'choose';
  static const String resume = 'resume';
  static const String delete = 'delete';
  static const String revealed = 'revealed';
  static const String copied = 'copied';

  /// Ступень лестницы подсказок D27 (в историю — только её номер).
  static const String hintStep = 'hintStep';

  /// Итог тренировки (5.8).
  static const String trained = 'trained';

  /// «Заметка дня»: пора тренировки (5.8).
  static const String notice = 'notice';

  @override
  String toString() => 'SecureCardCommand($action)';
}
