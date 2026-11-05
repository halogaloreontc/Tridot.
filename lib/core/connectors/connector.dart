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
    this.implicit = false,
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

  /// Совпадение без маркера команды: намерение угадано по форме фразы
  /// («купить хлеб» — инфинитив, «я купил хлеб» — прошедшее время).
  /// Такое совпадение уступает любому явному совпадению другого коннектора,
  /// даже менее уверенному: «узнать, где лежит 64115» — вопрос складу,
  /// а не задача «Узнать, где лежит 64115».
  final bool implicit;
}

/// Выбранный в интерфейсе или в диалоге объект: задача, товар, документ.
final class SelectedItem {
  const SelectedItem({required this.connectorId, required this.itemId});

  /// Коннектор, которому принадлежит объект.
  final String connectorId;

  final String itemId;
}

/// Ответ пользователя на вопрос подтверждения.
enum ConfirmationReply {
  yes,
  no;

  static const Set<String> _yesWords = <String>{
    'да',
    'ага',
    'угу',
    'конечно',
    'отмечай',
    'отметь',
    'подтверждаю',
    'давай',
    'ок',
    'окей',
    'верно',
    'точно',
    'пожалуйста',
    'спасибо',
  };

  static const Set<String> _noWords = <String>{
    'нет',
    'неа',
    'не',
    'надо',
    'нужно',
    'отмена',
    'отмени',
    'отменить',
    'отмечай',
    'отмечать',
    'спасибо',
  };

  /// Слова, без которых ответ «нет» — не ответ: «надо» — не «не надо».
  static const Set<String> _negations = <String>{
    'нет',
    'неа',
    'не',
    'отмена',
    'отмени',
    'отменить',
  };

  /// Вежливость: одна она ответом не бывает.
  static const Set<String> _courtesy = <String>{'пожалуйста', 'спасибо'};

  /// Первое слово, которое само по себе — ответ: «да, купил хлеб»,
  /// «нет, не купил».
  static const Set<String> _leadingYes = <String>{
    'да',
    'ага',
    'угу',
    'конечно',
    'ок',
    'окей',
  };

  static const Set<String> _leadingNo = <String>{'нет', 'неа'};

  static const Set<String> _yesSymbols = <String>{'+', '👍', '👌', '✅', '✔'};
  static const Set<String> _noSymbols = <String>{
    '-',
    '—',
    '–',
    '👎',
    '❌',
    '✖',
  };

  /// Сообщение без пробелов, вариантов эмодзи и оттенков кожи: «👍🏻» → «👍».
  static String _symbols(String text) => text.replaceAll(_ignoredSymbols, '');

  static final RegExp _ignoredSymbols =
      RegExp('[\\s\u{FE0F}\u{1F3FB}-\u{1F3FF}]', unicode: true);

  /// «Да», «ага», «конечно, отмечай», «да, спасибо», «+», «👍» — [yes];
  /// «нет», «неа», «не надо», «отмена», «-», «👎» — [no]; всё остальное,
  /// в том числе вопрос, — `null`. Ответ — всё сообщение целиком:
  /// «нет, добавь задачу» — уже новая команда, а не ответ. Ответ с
  /// пояснением («да, купил хлеб») — [leading].
  static ConfirmationReply? of(Utterance utterance) {
    final symbols = _symbols(utterance.original);
    if (_yesSymbols.contains(symbols)) return yes;
    if (_noSymbols.contains(symbols)) return no;
    if (utterance.isQuestion || utterance.quotedTitles.isNotEmpty) return null;
    final words = utterance.words;
    if (words.isEmpty) return null;
    if (words.any(_negations.contains) && words.every(_noWords.contains)) {
      return no;
    }
    if (words.every(_yesWords.contains) && !words.every(_courtesy.contains)) {
      return yes;
    }
    return null;
  }

  /// Ответ по первому слову, когда дальше идёт пояснение: «да, купил
  /// хлеб» — [yes], «нет, не купил» — [no]. Пояснение может оказаться
  /// новой командой («нет, добавь задачу молоко»), поэтому маршрутизатор
  /// принимает такой ответ, только если ни один коннектор не нашёл в
  /// сообщении явной команды.
  static ConfirmationReply? leading(Utterance utterance) {
    if (utterance.isQuestion || utterance.quotedTitles.isNotEmpty) return null;
    final words = utterance.words;
    if (words.isEmpty) return null;
    if (_leadingYes.contains(words.first)) return yes;
    if (_leadingNo.contains(words.first)) return no;
    if (words.length >= 2 &&
        words[0] == 'не' &&
        (words[1] == 'надо' || words[1] == 'нужно' || words[1] == 'отмечай')) {
      return no;
    }
    return null;
  }
}

/// Изменяющее действие, которое ждёт подтверждения в следующем сообщении.
///
/// Коннектор кладёт его в [AssistantSession.requestConfirmation] вместе
/// с вопросом «…? Ответьте «да» или «нет».». Если следующее сообщение —
/// «да» или «нет» ([ConfirmationReply.of]), маршрутизатор до обычного
/// разбора вызывает `run` этого коннектора с [ConfirmationAnswer]
/// в [ConnectorMatch.payload]. Любое другое сообщение снимает ожидание
/// и разбирается как обычно. Ожидание живёт ровно одно сообщение.
final class PendingConfirmation {
  const PendingConfirmation({
    required this.connectorId,
    required this.commandId,
    this.itemId,
    this.payload,
  });

  /// Коннектор, который задал вопрос и выполнит действие.
  final String connectorId;

  /// Действие: `task.complete`, `warehouse.writeOff`. Становится
  /// [ConnectorMatch.commandId] ответа.
  final String commandId;

  /// Объект действия, если он один: id задачи, артикул.
  final String? itemId;

  /// Всё остальное, что нужно для выполнения. Маршрутизатор его не читает.
  final Object? payload;
}

/// Ответ пользователя на [PendingConfirmation]: так его получает `run`.
final class ConfirmationAnswer {
  const ConfirmationAnswer(this.pending, this.reply);

  final PendingConfirmation pending;
  final ConfirmationReply reply;

  bool get confirmed => reply == ConfirmationReply.yes;
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

  PendingConfirmation? _pendingConfirmation;

  /// Действие, которое ждёт «да» или «нет» в следующем сообщении.
  PendingConfirmation? get pendingConfirmation => _pendingConfirmation;

  /// Запоминает действие до следующего сообщения. Вызывается из `run`
  /// вместе с ответом-вопросом `needsClarification`. Новое ожидание
  /// заменяет прежнее.
  void requestConfirmation(PendingConfirmation pending) {
    _pendingConfirmation = pending;
  }

  /// Забирает ожидание: после этого его больше нет. Вызывает маршрутизатор
  /// в начале каждого сообщения.
  PendingConfirmation? takePendingConfirmation() {
    final pending = _pendingConfirmation;
    _pendingConfirmation = null;
    return pending;
  }

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
