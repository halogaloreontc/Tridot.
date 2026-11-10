/// Роли — заготовки поверх навыков и подключений для сферы работы
/// (docs/EXTENSIONS.md, «Роли»; ADR-012).
///
/// Подключение — канал к сервису (склад halowarekeep). Навык — что умеет
/// помощник (задачи, калькулятор, беседа, складские вопросы через
/// подключение склада). Роль — набор навыков, кнопок быстрых действий и
/// подсказок маршрутизации, который включается одним переключателем:
/// «Личное», «Кладовщик». Роль — данные в составе приложения, она ничего
/// не выполняет и ничего не хранит, кроме выбора пользователя в
/// `settings.json`.
library;

/// Что делает кнопка быстрого действия роли.
enum RoleChipAction {
  /// Отправить [RoleChip.text] сразу.
  send,

  /// Вставить [RoleChip.text] в поле ввода; `|` — место курсора.
  insert,
}

/// Кнопка быстрого действия над полем ввода.
final class RoleChip {
  const RoleChip({
    required this.label,
    required this.text,
    this.action = RoleChipAction.send,
    this.icon = 'chat',
  });

  /// Подпись: «Где лежит…». Ключ кнопки в интерфейсе — `quick-<label>`.
  final String label;

  /// Текст сообщения или шаблон с `|`.
  final String text;

  final RoleChipAction action;

  /// Имя значка для интерфейса (`search`, `inbox`, `photo`): ядро не знает
  /// о Flutter, значок по имени выбирает интерфейс.
  final String icon;
}

/// Подключение, без которого роль неполна: статус и кнопка «Подключить»
/// в карточке роли.
final class RoleConnection {
  const RoleConnection({
    required this.extensionId,
    required this.appTitle,
    required this.connectLabel,
    required this.notConnectedLabel,
  });

  /// Id подключения ([ConnectionSlot.id]): `warehouse`.
  final String extensionId;

  /// Как назвать приложение в ответе «… ещё не подключён»: «Склад».
  final String appTitle;

  /// Кнопка в карточке: «Подключить склад».
  final String connectLabel;

  /// Статус в карточке без подключения: «Склад не подключён».
  final String notConnectedLabel;
}

/// Роль: id, тексты для карточки, что включает, кнопки, подсказки.
final class RoleInfo {
  const RoleInfo({
    required this.id,
    required this.title,
    required this.description,
    required this.extensions,
    required this.helpsWith,
    this.defaultEnabled = false,
    this.chips = const <RoleChip>[],
    this.hints = const <String>{},
    this.connection,
    this.skillTitles = const <String, String>{},
  });

  /// Постоянный id латиницей: `personal`, `storekeeper`. Хранится в
  /// `settings.json` (`enabled_roles`, `disabled_roles`, `role_owners`).
  final String id;

  /// «Кладовщик».
  final String title;

  /// Одно предложение для карточки.
  final String description;

  /// Id навыков и подключений, которые роль включает. Расширение, которое
  /// входит хоть в одну роль, работает, только пока включена одна из его
  /// ролей (правило старшинства — [RoleRules]).
  final List<String> extensions;

  /// Кусок самоописания помощника для «кто ты» и «что умеешь» — с чем
  /// помогает: «с задачами», «со складом» (творительный падеж с
  /// предлогом).
  final String helpsWith;

  /// Включена, пока пользователь её не выключил.
  final bool defaultEnabled;

  /// Кнопки быстрых действий, пока роль включена.
  final List<RoleChip> chips;

  /// Подсказки маршрутизации вида `<id расширения>.<подсказка>`:
  /// `warehouse.bareCodes`. Расширение получает только свои, без префикса
  /// ([RoleHints]).
  final Set<String> hints;

  /// Подключение роли: статус и «Подключить …» в карточке, ответ «… ещё
  /// не подключён» вместо «не понял».
  final RoleConnection? connection;

  /// Как роль называет навык поверх подключения: `warehouse` →
  /// «Складские вопросы». Без записи — название расширения.
  final Map<String, String> skillTitles;
}

/// Встроенные роли. Порядок важен: общий навык (беседа) ведёт владелец
/// первой включённой роли из этого списка.
abstract final class Roles {
  static const String personalId = 'personal';
  static const String storekeeperId = 'storekeeper';

  /// «Личное»: задачи, калькулятор, беседа. Включено по умолчанию и
  /// выключается; задачи — ядро и остаются всегда (`required`).
  static const RoleInfo personal = RoleInfo(
    id: personalId,
    title: 'Личное',
    description: 'Задачи, калькулятор и беседа — на каждый день.',
    extensions: <String>['tasks', 'calc', 'talk'],
    helpsWith: 'с задачами',
    defaultEnabled: true,
  );

  /// «Кладовщик»: складские вопросы через подключение к складу
  /// halowarekeep. Выключен по умолчанию.
  static const RoleInfo storekeeper = RoleInfo(
    id: storekeeperId,
    title: 'Кладовщик',
    description: 'Складские вопросы: где лежит артикул, что пришло, '
        'приходы без фото. Через подключение к складу halowarekeep, только '
        'чтение.',
    // Беседа — и здесь: без «Личного» помощник всё равно отвечает на
    // «привет» и «кто ты».
    extensions: <String>['warehouse', 'talk'],
    helpsWith: 'со складом',
    chips: <RoleChip>[
      RoleChip(
        label: 'Где лежит…',
        text: 'Где лежит |',
        action: RoleChipAction.insert,
        icon: 'search',
      ),
      RoleChip(
        label: 'Что пришло сегодня',
        text: 'Что пришло сегодня',
        icon: 'inbox',
      ),
      RoleChip(label: 'Без фото', text: 'Без фото', icon: 'photo'),
    ],
    // С подключённым складом голый артикул — «где лежит», а «сегодня» и
    // «вчера» — приходы, без «склад, …».
    hints: <String>{'warehouse.bareCodes', 'warehouse.bareWords'},
    skillTitles: <String, String>{'warehouse': 'Складские вопросы'},
    connection: RoleConnection(
      extensionId: 'warehouse',
      appTitle: 'Склад',
      connectLabel: 'Подключить склад',
      notConnectedLabel: 'Склад не подключён',
    ),
  );

  static const List<RoleInfo> all = <RoleInfo>[personal, storekeeper];

  static RoleInfo? byId(String? id) =>
      all.where((RoleInfo r) => r.id == id).firstOrNull;

  /// Роли для настроек старой версии (без `enabled_roles` и
  /// `disabled_roles`): подключение, которое человек включал сам
  /// (`enabled_extensions`), включает выключенную по умолчанию роль, в
  /// которую оно входит. Так склад, подключённый до ролей, после
  /// обновления продолжает отвечать.
  static Set<String> migratedFrom(Set<String> enabledExtensions) => <String>{
        for (final role in all)
          if (!role.defaultEnabled &&
              role.extensions.any(
                (String id) =>
                    enabledExtensions.contains(id) &&
                    !all.any(
                      (RoleInfo r) =>
                          r.defaultEnabled && r.extensions.contains(id),
                    ),
              ))
            role.id,
      };
}

/// Расширение, которое слушает подсказки маршрутизации включённых ролей
/// ([RoleInfo.hints]). Реестр зовёт [applyRoleHints] при каждом изменении
/// выбора — до того, как маршрутизатор спросит `match`.
abstract interface class RoleHints {
  /// [hints] — подсказки этого расширения без префикса id: `bareCodes`.
  void applyRoleHints(Set<String> hints);
}

/// Правило старшинства выбора (docs/EXTENSIONS.md, «Роли и расширения»).
abstract final class RoleRules {
  /// Подсказки [all] для расширения [extensionId] без префикса.
  static Set<String> hintsFor(String extensionId, Iterable<String> all) {
    final prefix = '$extensionId.';
    return <String>{
      for (final hint in all)
        if (hint.startsWith(prefix)) hint.substring(prefix.length),
    };
  }
}
