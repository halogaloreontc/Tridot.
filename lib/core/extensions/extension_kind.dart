/// Вид расширения помощника (docs/EXTENSIONS.md).
enum ExtensionKind {
  /// Навык: своя логика в составе приложения, без сети. Задачи, калькулятор.
  skill,

  /// Подключение к внешнему приложению: склад, expeora.
  connector,

  /// Пак: только содержимое (шутки, фразы), без кода.
  pack;

  /// Название группы в «Настройки → Расширения».
  String get groupTitle => switch (this) {
        ExtensionKind.skill => 'Навыки',
        ExtensionKind.connector => 'Подключения',
        ExtensionKind.pack => 'Паки',
      };
}
