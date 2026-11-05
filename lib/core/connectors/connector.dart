import '../models/assistant_types.dart';
import '../services/clock.dart';
import 'utterance.dart';

export '../models/assistant_types.dart' show AssistantResponse, AssistantStatus;
export 'utterance.dart';

/// Что коннектору разрешено делать с данными своего приложения.
enum ConnectorAccess {
  /// Только чтение: поиск, просмотр, справки. Значение по умолчанию.
  readOnly,

  /// Чтение и изменение. Каждое изменяющее действие выполняется только
  /// после явного подтверждения пользователя (ADR-004).
  readWrite,
}

/// Паспорт коннектора: как его показывать и что от него ждать.
final class ConnectorInfo {
  const ConnectorInfo({
    required this.id,
    required this.title,
    required this.description,
    this.examples = const <String>[],
    this.requiresNetwork = false,
    this.access = ConnectorAccess.readOnly,
  });

  /// Постоянный идентификатор латиницей: `tasks`, `warehouse`. Попадает
  /// в корпус фраз (поле `connector`) и в [ConnectorMatch.connectorId].
  final String id;

  /// Короткое имя для пользователя: «Задачи», «Склад».
  final String title;

  /// Одно предложение: что умеет коннектор.
  final String description;

  /// Примеры фраз, которые коннектор понимает. Каждый пример обязан
  /// распознаваться — это проверяется тестом коннектора.
  final List<String> examples;

  /// Коннектор ходит в сеть. Сеть разрешена только внутри коннекторов.
  final bool requiresNetwork;

  final ConnectorAccess access;
}

/// Ответ коннектора на вопрос «это твоя фраза?».
final class ConnectorMatch {
  const ConnectorMatch({
    required this.connectorId,
    required this.commandId,
    required this.confidence,
    this.payload,
  }) : assert(confidence >= 0 && confidence <= 1);

  /// [ConnectorInfo.id] коннектора, который вернул совпадение.
  final String connectorId;

  /// Команда внутри коннектора: `task.create`, `warehouse.locate`.
  /// Используется как [AssistantResponse.intent] при ошибке выполнения.
  final String commandId;

  /// Уверенность от 0 до 1 (шкала — docs/CONNECTORS.md). Маршрутизатор
  /// выбирает самое уверенное совпадение.
  final double confidence;

  /// Всё, что коннектор разобрал в `match` и что понадобится в `run`:
  /// разобранная команда, код товара и т. п. Маршрутизатор его не читает.
  final Object? payload;
}

/// Выбранный в интерфейсе или в диалоге объект: задача, товар, документ.
final class SelectedItem {
  const SelectedItem({required this.connectorId, required this.itemId});

  /// Коннектор, которому принадлежит объект.
  final String connectorId;

  final String itemId;
}

/// Состояние диалога, общее для всех коннекторов.
///
/// Живёт столько же, сколько контроллер. Коннектор читает и меняет выбор
/// только своих объектов: «её» в «Заверши её» — задача, а не товар склада.
final class AssistantSession {
  AssistantSession({this.clock = const SystemClock()});

  /// Источник времени. Коннекторы не вызывают `DateTime.now()` напрямую.
  final Clock clock;

  SelectedItem? _selection;

  /// Коннектор, который обработал предыдущее сообщение (`run` вызван, даже
  /// если закончился ошибкой). `null`, если предыдущее сообщение никто не
  /// взял или маршрутизатор переспросил. Во время `run` здесь ещё значение
  /// для предыдущего сообщения — по нему коннектор понимает, что «да»
  /// отвечает именно на его вопрос.
  String? lastConnectorId;

  SelectedItem? get selection => _selection;

  /// Выбранный объект коннектора [connectorId] или `null`.
  String? selectedItemFor(String connectorId) {
    final selection = _selection;
    if (selection == null || selection.connectorId != connectorId) return null;
    return selection.itemId;
  }

  void select(String connectorId, String itemId) {
    _selection = SelectedItem(connectorId: connectorId, itemId: itemId);
  }

  void clearSelection() {
    _selection = null;
  }

  /// Снимает выбор, только если выбран именно этот объект.
  void forget(String connectorId, String itemId) {
    if (selectedItemFor(connectorId) == itemId) clearSelection();
  }
}

/// Подключаемый набор команд: задачи, склад, внешнее приложение.
///
/// Как написать свой коннектор — docs/CONNECTORS.md.
abstract interface class Connector {
  ConnectorInfo get info;

  /// Решает, относится ли фраза к коннектору. Чистая синхронная функция:
  /// без сети, файлов, обращения к хранилищу и изменения состояния.
  /// `null` — «не моя фраза». Всё нужное для выполнения кладётся
  /// в [ConnectorMatch.payload].
  ConnectorMatch? match(Utterance utterance);

  /// Выполняет команду, найденную [match]. Здесь допустимы ввод-вывод и
  /// сеть (если [ConnectorInfo.requiresNetwork]). Ошибки можно не ловить:
  /// маршрутизатор превратит исключение в ответ со статусом `failed`.
  Future<AssistantResponse> run(ConnectorMatch match, AssistantSession session);
}
