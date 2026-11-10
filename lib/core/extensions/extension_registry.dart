import '../connectors/connector.dart';
import '../personas/persona.dart';
import '../replies/reply_library.dart';
import 'extension_info.dart';
import 'pack.dart';
import 'pack_store.dart';
import 'role.dart';

export 'extension_info.dart';
export 'pack.dart';
export 'extension_kind.dart';
export 'pack_store.dart';
export 'role.dart';

/// Все расширения помощника и выбор пользователя (docs/EXTENSIONS.md).
///
/// Знает навыки и подключения (код в составе приложения, регистрируются в
/// `lib/main.dart`) и установленные паки ([PackStore]). Маршрутизатор
/// спрашивает только [enabledConnectors]. Выбор ([choice]) хранится в
/// настройках приложения и применяется сразу, без перезапуска.
///
/// Роли ([roles], ADR-012) — заготовки поверх навыков и подключений: роль
/// включает свои расширения, кнопки быстрых действий и подсказки
/// маршрутизации. Выбор ролей — часть того же [ExtensionChoice].
final class ExtensionRegistry {
  ExtensionRegistry({
    required List<Connector> connectors,
    PackStore? packs,
    ExtensionChoice choice = const ExtensionChoice(),
    List<RoleInfo> roles = Roles.all,
  })  : _connectors = List<Connector>.unmodifiable(connectors),
        packs = packs ?? PackStore.memory(),
        _choice = choice {
    final ids = <String>{};
    final replies = <String, String>{};
    final protectedReplies = <String>{};
    for (final connector in _connectors) {
      if (!ids.add(connector.info.id)) {
        throw ArgumentError.value(
          connector.info.id,
          'connectors',
          'Коннектор с таким id уже подключён',
        );
      }
      for (final MapEntry(:key, :value) in connector.info.replies.entries) {
        if (replies.containsKey(key)) {
          throw ArgumentError.value(
            key,
            'connectors',
            'Запись каталога ответов уже есть у другого коннектора',
          );
        }
        replies[key] = value;
      }
      protectedReplies.addAll(connector.info.protectedReplies);
    }
    this.packs.reservedIds = ids;
    this.replies = ReplyLibrary.builtIn.withEntries(
      replies,
      protectedIds: protectedReplies,
    );
    // Паки ответов проверяются и против записей коннекторов.
    this.packs.replySchema = this.replies.schema;
    // Роль без своих расширений в этой сборке не показывается; роль с
    // подключением — только если подключение зарегистрировано.
    this.roles = List<RoleInfo>.unmodifiable(<RoleInfo>[
      for (final role in roles)
        if (role.extensions.any(ids.contains) &&
            (role.connection == null ||
                ids.contains(role.connection!.extensionId)))
          role,
    ]);
    _pushHints();
  }

  /// Роли этой сборки в порядке показа.
  late final List<RoleInfo> roles;

  /// Встроенные каталоги ответов вместе с записями коннекторов — без
  /// стилей из паков.
  late final ReplyLibrary replies;

  final List<Connector> _connectors;

  final PackStore packs;

  ExtensionChoice _choice;

  final List<void Function()> _listeners = <void Function()>[];

  /// Все навыки и подключения в порядке регистрации.
  List<Connector> get connectors => _connectors;

  ExtensionChoice get choice => _choice;

  /// Навыки, подключения и паки — для экрана настроек.
  List<ExtensionInfo> get all => <ExtensionInfo>[
        for (final connector in _connectors)
          ExtensionInfo.fromConnector(connector.info),
        for (final installed in packs.packs)
          ExtensionInfo.fromPack(installed.pack, builtIn: installed.builtIn),
      ];

  List<ExtensionInfo> ofKind(ExtensionKind kind) =>
      all.where((ExtensionInfo info) => info.kind == kind).toList();

  ExtensionInfo? info(String id) =>
      all.where((ExtensionInfo info) => info.id == id).firstOrNull;

  bool isEnabled(String id) {
    final found = info(id);
    return found != null && enabledUnder(_choice, found);
  }

  // ------------------------------------------------------------- роли

  /// Роли, в которые входит расширение [id].
  List<RoleInfo> rolesOf(String id) => <RoleInfo>[
        for (final role in roles)
          if (role.extensions.contains(id)) role,
      ];

  RoleInfo? role(String id) =>
      roles.where((RoleInfo r) => r.id == id).firstOrNull;

  bool isRoleEnabled(String id) {
    final found = role(id);
    return found != null && _choice.isRoleEnabled(found);
  }

  /// Включённые роли в порядке [roles].
  List<RoleInfo> get activeRoles => <RoleInfo>[
        for (final role in roles)
          if (_choice.isRoleEnabled(role)) role,
      ];

  /// Правило старшинства (docs/EXTENSIONS.md, «Роли и расширения»):
  ///
  /// 1. обязательное (задачи) включено всегда;
  /// 2. выключенное пользователем явно ([ExtensionChoice.disabled])
  ///    выключено, даже если его роль включена;
  /// 3. расширение, которое входит хоть в одну роль, включено, только
  ///    пока включена одна из его ролей — `enabled_extensions` для него не
  ///    действует;
  /// 4. остальное (паки, расширения вне ролей) — как раньше:
  ///    [ExtensionChoice.isEnabled].
  bool enabledUnder(ExtensionChoice choice, ExtensionInfo info) {
    if (info.required) return true;
    final claimed = rolesOf(info.id);
    if (claimed.isEmpty) return choice.isEnabled(info);
    if (choice.disabled.contains(info.id)) return false;
    return claimed.any(choice.isRoleEnabled);
  }

  /// Роль, которая сейчас ведёт расширение [id]: первая включённая из его
  /// ролей; `null` — расширение вне ролей или все его роли выключены.
  RoleInfo? activeRoleOf(String id) =>
      rolesOf(id).where(_choice.isRoleEnabled).firstOrNull;

  /// Кто ведёт роль [roleId] при настройках [personas]: выбранный в
  /// карточке роли или основной. В соло — единственный помощник.
  Persona ownerOf(String roleId, PersonaSettings personas) {
    if (personas.mode == AssistantMode.solo) return personas.solo;
    return Personas.byId(_choice.roleOwners[roleId]) ?? personas.main;
  }

  /// Кто отвечает на фразы расширения [connectorId] в дуэте, если к
  /// помощнику не обращались явно: владелец его включённой роли; `null` —
  /// расширение вне ролей (отвечает адресат по обычным правилам).
  Persona? ownerFor(String connectorId, PersonaSettings personas) {
    final role = activeRoleOf(connectorId);
    return role == null ? null : ownerOf(role.id, personas);
  }

  /// Название навыка для пользователя: как его зовёт включённая роль
  /// («Складские вопросы») или название расширения.
  String skillTitle(String id) {
    for (final role in rolesOf(id)) {
      final title = role.skillTitles[id];
      if (title != null && _choice.isRoleEnabled(role)) return title;
    }
    final found = info(id);
    return found?.title ?? id;
  }

  /// Кнопки быстрых действий включённых ролей, без повторов по подписи.
  List<RoleChip> get activeChips {
    final seen = <String>{};
    return <RoleChip>[
      for (final role in activeRoles)
        for (final chip in role.chips)
          if (seen.add(chip.label)) chip,
    ];
  }

  /// С чем помогает помощник — для «кто ты» и «что умеешь»: «с задачами
  /// и со складом». Пусто, если ролей нет.
  String get helpsWith {
    final parts = <String>[
      for (final role in activeRoles)
        if (role.helpsWith.isNotEmpty) role.helpsWith,
    ];
    if (parts.length <= 1) return parts.join();
    return '${parts.sublist(0, parts.length - 1).join(', ')} и ${parts.last}';
  }

  /// Выбор, в котором роль [id] включена или выключена.
  ExtensionChoice roleChoiceWith(String id, bool enabled) {
    final found = role(id);
    if (found == null) {
      throw ArgumentError.value(id, 'id', 'Нет такой роли');
    }
    return _choice.withRole(found, enabled);
  }

  /// Подсказки маршрутизации включённых ролей — расширениям, которые их
  /// слушают ([RoleHints]).
  void _pushHints() {
    final all = <String>{
      for (final role in activeRoles) ...role.hints,
    };
    for (final connector in _connectors) {
      if (connector case final RoleHints hinted) {
        hinted.applyRoleHints(RoleRules.hintsFor(connector.info.id, all));
      }
    }
  }

  // ------------------------------------------------------------------

  /// Включённые навыки и подключения: только их спрашивает маршрутизатор.
  List<Connector> get enabledConnectors => <Connector>[
        for (final connector in _connectors)
          if (enabledUnder(
            _choice,
            ExtensionInfo.fromConnector(connector.info),
          ))
            connector,
      ];

  /// Id включённых паков.
  Set<String> get enabledPackIds => <String>{
        for (final installed in packs.packs)
          if (enabledUnder(
            _choice,
            ExtensionInfo.fromPack(installed.pack, builtIn: installed.builtIn),
          ))
            installed.pack.id,
      };

  /// Стили из включённых паков ответов (`type: replies`).
  List<ReplyCatalog> get replyStyles => <ReplyCatalog>[
        for (final installed in packs.packs)
          if (installed.pack.type == PackFormat.repliesType &&
              enabledUnder(
                _choice,
                ExtensionInfo.fromPack(
                  installed.pack,
                  builtIn: installed.builtIn,
                ),
              ))
            _replyCatalogs[installed.pack] ??=
                installed.pack.replyCatalog(builtIn: installed.builtIn),
      ];

  /// Разобранные стили паков: пак не меняется, поэтому шаблоны
  /// разбираются один раз, а не при каждой перерисовке настроек.
  static final Expando<ReplyCatalog> _replyCatalogs = Expando<ReplyCatalog>();

  /// Каталоги ответов со стилями включённых паков: из них говорит
  /// помощник и выбираются стили в настройках.
  ReplyLibrary get replyLibrary => replies.withStyles(replyStyles);

  /// Записи включённых паков: для будущих навыков (беседа, шутки).
  List<PackEntry> packEntries({
    String? type,
    Set<String> tags = const <String>{},
    PackPersona persona = PackPersona.any,
  }) =>
      packs.entries(
        type: type,
        tags: tags,
        persona: persona,
        packIds: enabledPackIds,
      );

  /// Выбор, в котором [id] включено или выключено. Обязательное
  /// расширение выключить нельзя — [StateError].
  ExtensionChoice choiceWith(String id, bool enabled) =>
      choiceWithFor(_choice, id, enabled);

  /// То же для выбора [base] (например, из настроек на экране).
  ExtensionChoice choiceWithFor(ExtensionChoice base, String id, bool enabled) {
    final found = info(id);
    if (found == null) {
      throw ArgumentError.value(id, 'id', 'Нет такого расширения');
    }
    return rolesOf(id).isEmpty
        ? base.withEnabled(found, enabled)
        : base.withRoleExtension(found, enabled);
  }

  /// Применяет выбор сразу. Слушатели узнают об изменении синхронно.
  void apply(ExtensionChoice choice) {
    if (choice.sameAs(_choice)) return;
    _choice = choice;
    _pushHints();
    _notify();
  }

  /// Импорт пака текстом (см. [PackStore.importFromString]).
  ///
  /// Новый пак (такого id не было) включается по умолчанию, даже если в
  /// выборе остался след прежнего пака с этим id. Замена пака сохраняет
  /// выбор пользователя.
  Future<PackImportResult> importPack(
    String source, {
    bool replace = false,
  }) async {
    final result = await packs.importFromString(source, replace: replace);
    final pack = result.pack;
    if (pack != null) {
      if (!replace) _choice = _choice.without(pack.id);
      _notify();
    }
    return result;
  }

  /// Удаляет пользовательский пак и забывает его в выборе: повторно
  /// добавленный пак с тем же id придёт включённым. Ошибка удаления файла
  /// — [PackStoreException].
  Future<bool> removePack(String id) async {
    final removed = await packs.remove(id);
    if (removed) {
      _choice = _choice.without(id);
      _notify();
    }
    return removed;
  }

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _notify() {
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }
}
