import '../connectors/connector.dart';
import 'extension_info.dart';
import 'pack.dart';
import 'pack_store.dart';

export 'extension_info.dart';
export 'pack.dart';
export 'extension_kind.dart';
export 'pack_store.dart';

/// Все расширения помощника и выбор пользователя (docs/EXTENSIONS.md).
///
/// Знает навыки и подключения (код в составе приложения, регистрируются в
/// `lib/main.dart`) и установленные паки ([PackStore]). Маршрутизатор
/// спрашивает только [enabledConnectors]. Выбор ([choice]) хранится в
/// настройках приложения и применяется сразу, без перезапуска.
final class ExtensionRegistry {
  ExtensionRegistry({
    required List<Connector> connectors,
    PackStore? packs,
    ExtensionChoice choice = const ExtensionChoice(),
  })  : _connectors = List<Connector>.unmodifiable(connectors),
        packs = packs ?? PackStore.memory(),
        _choice = choice {
    final ids = <String>{};
    for (final connector in _connectors) {
      if (!ids.add(connector.info.id)) {
        throw ArgumentError.value(
          connector.info.id,
          'connectors',
          'Коннектор с таким id уже подключён',
        );
      }
    }
    this.packs.reservedIds = ids;
  }

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
    return found != null && _choice.isEnabled(found);
  }

  /// Включённые навыки и подключения: только их спрашивает маршрутизатор.
  List<Connector> get enabledConnectors => <Connector>[
        for (final connector in _connectors)
          if (_choice.isEnabled(ExtensionInfo.fromConnector(connector.info)))
            connector,
      ];

  /// Id включённых паков.
  Set<String> get enabledPackIds => <String>{
        for (final installed in packs.packs)
          if (_choice.isEnabled(
            ExtensionInfo.fromPack(installed.pack, builtIn: installed.builtIn),
          ))
            installed.pack.id,
      };

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
  ExtensionChoice choiceWith(String id, bool enabled) {
    final found = info(id);
    if (found == null) {
      throw ArgumentError.value(id, 'id', 'Нет такого расширения');
    }
    return _choice.withEnabled(found, enabled);
  }

  /// Применяет выбор сразу. Слушатели узнают об изменении синхронно.
  void apply(ExtensionChoice choice) {
    if (choice.sameAs(_choice)) return;
    _choice = choice;
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
