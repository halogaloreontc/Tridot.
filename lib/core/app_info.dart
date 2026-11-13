/// Название приложения для пользователя (ADR-009, ADR-016).
///
/// Приложение — хаб Tridot (по-русски «Тридот»), в котором работают
/// помощники Садо, Лиорио и Нода; само оно помощником не называется.
/// Прежнее название — «Связной» (ADR-009).
///
/// Только название: applicationId, bundle id, имя пакета Dart и папки
/// данных остались прежними (ADR-008, ADR-009, ADR-016) — новая версия
/// ставится поверх старой и читает те же данные.
abstract final class AppInfo {
  /// Название в интерфейсе: боковая панель, заголовок окна, подпись на
  /// телефоне, «О приложении», автор встроенных расширений. Пишется
  /// латиницей и в русском тексте (ADR-016).
  static const String name = 'Tridot';

  /// Прежнее латинское имя для служебных мест, а не для пользователя:
  /// `Relay.app` и `PRODUCT_NAME` на macOS, `ProductName` в Windows (от него
  /// и `CompanyName` зависит папка данных в RoamingAppData), User-Agent.
  /// Не меняется: иначе обновление потеряло бы данные (ADR-016).
  static const String latinName = 'Relay';

  /// Название в косвенных падежах. «Tridot» не склоняется (ADR-016):
  /// «установите Tridot», «в Tridot». Формы — здесь, чтобы текст с
  /// названием в косвенном падеже не собирал их сам.
  static const String nameGenitive = 'Tridot';

  /// Дательный падеж.
  static const String nameDative = 'Tridot';

  /// Творительный падеж.
  static const String nameInstrumental = 'Tridot';

  /// Предложный падеж: «(в) Tridot».
  static const String namePrepositional = 'Tridot';

  /// Раздел приложения с помощниками, сводкой и настройками: «Мой
  /// Tridot». Одна константа, чтобы смена названия была правкой в одном
  /// месте.
  static const String hubName = 'Мой $name';

  /// Версия для пользователя — как `version:` в pubspec.yaml до «+»
  /// (тест держит их вместе). Видна в меню рядом с названием.
  static const String version = '0.1.0';

  /// Номер сборки — число после «+» в pubspec.yaml.
  static const int build = 1;
}
