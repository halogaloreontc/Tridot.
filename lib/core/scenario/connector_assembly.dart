import '../connectors/connector.dart';
import '../connectors/manifest/app_connections.dart';
import '../extensions/extension_registry.dart';
import 'assistant_controller.dart';

/// Набор коннекторов помощника — один путь сборки при запуске и после
/// «Подключить» / «Удалить» приложение (ADR-039): навыки до подключений
/// ([before]), подключения ([AppConnections.services]: склад, затем
/// приложения из каталога), навыки после ([after]). Порядок важен только
/// при равной уверенности.
///
/// Реестр не меняется по кусочкам: после изменения подключений он
/// пересобирается целиком ([ExtensionRegistry.rebuild]) из того же
/// [build], между ходами диалога ([AssistantController.betweenTurns]).
final class ConnectorAssembly {
  ConnectorAssembly({
    required this.connections,
    List<Connector> before = const <Connector>[],
    List<Connector> after = const <Connector>[],
  })  : before = List<Connector>.unmodifiable(before),
        after = List<Connector>.unmodifiable(after);

  final AppConnections connections;
  final List<Connector> before;
  final List<Connector> after;

  /// Коннекторы сейчас.
  List<Connector> build() => <Connector>[
        ...before,
        for (final service in connections.services) service.connector,
        ...after,
      ];

  void Function()? _listener;

  /// Пересобирать [registry] при каждом изменении подключений — между
  /// ходами [controller]. Повторный вызов заменяет прежнюю привязку.
  void attach(ExtensionRegistry registry, AssistantController controller) {
    detach();
    void listener() => controller.betweenTurns(() => registry.rebuild(build()));
    _listener = listener;
    connections.addListener(listener);
  }

  void detach() {
    final listener = _listener;
    if (listener != null) connections.removeListener(listener);
    _listener = null;
  }
}
