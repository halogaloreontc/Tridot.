/// Роли — заготовки поверх навыков и подключений для сферы работы
/// (docs/EXTENSIONS.md, «Роли»; ADR-012).
///
/// Подключение — канал к сервису (склад halowarekeep). Навык — что умеет
/// помощник (задачи, калькулятор, беседа, склад — вопросы через
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
    this.needs,
  });

  /// Подпись: «Где лежит…». Ключ кнопки в интерфейсе — `quick-<label>`.
  final String label;

  /// Текст сообщения или шаблон с `|`.
  final String text;

  final RoleChipAction action;

  /// Имя значка для интерфейса (`search`, `inbox`, `photo`): ядро не знает
  /// о Flutter, значок по имени выбирает интерфейс.
  final String icon;

  /// Id расширения, без которого кнопка ничего не сделает (`warehouse`):
  /// выключили его в «Расширениях» — кнопка прячется, хотя роль включена.
  /// `null` — кнопка нужна всегда, пока включена роль.
  final String? needs;
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
    this.helpsThrough,
    this.actionHint,
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

  /// Id расширения, которым роль на деле помогает ([helpsWith]):
  /// `warehouse` у «Кладовщика». Пока оно выключено в «Расширениях»,
  /// помощник о роли не говорит. `null` — говорит всегда, пока роль
  /// включена.
  final String? helpsThrough;

  /// Подсказка `<id расширения>.<подсказка>`, которая разрешает действия с
  /// записью (ADR-013): `warehouse.actions`. Не входит в [hints]: те
  /// включаются вместе с ролью, а эта — только отдельным переключателем
  /// «Разрешить действия» для одного логина подключения
  /// (`ExtensionChoice.roleActions`). `null` — у роли действий нет.
  final String? actionHint;
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

  /// «Кладовщик»: вопросы складу через подключение к складу DepotDesk
  /// (и прежнему halowarekeep, ADR-031).
  /// Выключен по умолчанию. Навык называется так же, как подключение в
  /// «Расширениях», — «Склад»: одно имя в карточке роли, в «Расширениях»
  /// и в «что умеешь».
  static const RoleInfo storekeeper = RoleInfo(
    id: storekeeperId,
    title: 'Кладовщик',
    description: 'Вопросы складу: где лежит артикул, сколько осталось, '
        'цена, что пришло, приходы без фото. Вход по QR со склада — с вашим '
        'логином и правами; перемещение и отметка проведения — только если '
        'разрешить действия.',
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
        needs: 'warehouse',
      ),
      RoleChip(
        label: 'Что пришло сегодня',
        text: 'Что пришло сегодня',
        icon: 'inbox',
        needs: 'warehouse',
      ),
      RoleChip(
        label: 'Без фото',
        text: 'Без фото',
        icon: 'photo',
        needs: 'warehouse',
      ),
    ],
    // С подключённым складом голый артикул — «где лежит», а «сегодня» и
    // «вчера» — приходы, без «склад, …».
    hints: <String>{'warehouse.bareCodes', 'warehouse.bareWords'},
    helpsThrough: 'warehouse',
    // Перемещение и отметка проведения — отдельным переключателем, для
    // одного логина, после «Подтвердить» на каждой карточке.
    actionHint: 'warehouse.actions',
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

/// Расширение с действиями с записью (ADR-013). Реестр зовёт
/// [applyRoleActions] при каждом изменении выбора: [login] — логин
/// подключения, для которого включена роль и «Разрешить действия»;
/// `null` — действия не разрешены. Коннектор сам сверяет его с логином
/// входа.
abstract interface class RoleActions {
  void applyRoleActions(String? login);
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
