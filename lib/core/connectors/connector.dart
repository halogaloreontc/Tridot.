import '../app_info.dart';
import '../extensions/extension_registry.dart';
import '../jobs/extension_card.dart';
import '../models/action_card.dart';
import '../models/assistant_types.dart';
import '../models/bulk.dart';
import '../models/clarification.dart';
import '../models/secure_card.dart';
import '../models/task.dart';
import '../personas/persona.dart';
import '../replies/reply_library.dart';
import '../services/clock.dart';
import 'utterance.dart';

export '../extensions/extension_kind.dart';
export '../models/assistant_types.dart' show AssistantResponse, AssistantStatus;
export '../models/clarification.dart';
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
    this.kind = ExtensionKind.connector,
    this.version = '1.0.0',
    this.author = defaultAuthor,
    this.defaultEnabled = true,
    this.required = false,
    this.replies = const <String, String>{},
    this.protectedReplies = const <String>{},
    this.sensitive = false,
    this.chips = const <RoleChip>[],
    this.offHint = false,
    this.unavailable = false,
  }) : assert(kind != ExtensionKind.pack, 'Пак — данные, а не коннектор');

  /// Автор встроенных расширений.
  static const String defaultAuthor = AppInfo.name;

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

  /// Навык (своя логика без сети) или подключение к внешнему приложению.
  /// В «Настройки → Расширения» навыки и подключения — разные группы.
  final ExtensionKind kind;

  /// Версия для пользователя: «1.0.0».
  final String version;

  final String author;

  /// Включён у пользователя, который его ещё не трогал. Новое расширение
  /// с `true` после обновления приложения появляется включённым.
  final bool defaultEnabled;

  /// Нельзя выключить: без него помощник теряет смысл (задачи).
  final bool required;

  /// Свои записи каталога ответов: id → нейтральный текст с разметкой
  /// (docs/REPLIES.md). Маршрутизатор добавляет их в каталог; остальные
  /// стили берут нейтральный текст, паки ответов могут дать свои
  /// варианты. Id не должен совпадать со встроенной записью.
  final Map<String, String> replies;

  /// Какие из [replies] — предупреждения и вопросы-подтверждения («Товар
  /// не найден», «Списать 3 шт.?»): паки ответов их не переопределяют, и
  /// звучит нейтральный текст коннектора (docs/REPLIES.md).
  final Set<String> protectedReplies;

  /// Коннектор работает с секретами (навык «Пароли»): если его `run`
  /// упал, маршрутизатор отвечает `router.failed.quiet` без текста ошибки
  /// — в исключении мог оказаться пароль (D13).
  final bool sensitive;

  /// Кнопки быстрых действий навыка вне ролей (D17): видны, пока навык
  /// включён ([ExtensionRegistry.activeChips]). У навыков ролей кнопки
  /// задаёт роль.
  final List<RoleChip> chips;

  /// Выключенное расширение подсказывает, где его включить: если его
  /// `match` явно узнаёт фразу, а включённые навыки берут её только без
  /// маркера или не берут вовсе, ответ — `extension.off` («Архиватор
  /// выключен — включите в «Настройки → Расширения»»). Фразы у
  /// включённых навыков он не перехватывает.
  final bool offHint;

  /// Расширения нет в этой сборке или на этой платформе, а коннектор лишь
  /// честно говорит об этом на его фразы (загрузчик видео на Android,
  /// ADR-024). Слушает всегда, как обязательное, но нигде не
  /// показывается: ни в «Настройки → Расширения» (там вместо плитки —
  /// приглушённая строка «{title} — {description}», если [description]
  /// не пуст), ни в «что умеешь», ни в «как дела», ни в каталоге команд.
  final bool unavailable;
}

/// Ответ коннектора на вопрос «это твоя фраза?».
final class ConnectorMatch {
  const ConnectorMatch({
    required this.connectorId,
    required this.commandId,
    required this.confidence,
    this.payload,
    this.implicit = false,
    this.fallback = false,
    this.acknowledgement = false,
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

  /// Совпадение «на крайний случай»: забирает фразу, только если больше
  /// никто не откликнулся, даже без маркера. Так беседа отвечает на
  /// «привет», но никогда не перехватывает команды задач, калькулятора
  /// и подключений.
  final bool fallback;

  /// Короткий отклик, похожий на согласие, но не ответ «да» или «нет»:
  /// «хорошо», «ладно», «понял», «спасибо». Пока коннектор ждёт
  /// подтверждения, маршрутизатор такое совпадение не берёт: вопрос не
  /// пропадает молча, а помощник переспрашивает «да» или «нет» и ничего не
  /// делает ([AssistantController]).
  final bool acknowledgement;
}

/// Состояние коннектора для «Как дела?».
enum HealthStatus {
  /// Всё работает.
  ok,

  /// Работает с перебоями: медленно, часть данных недоступна.
  degraded,

  /// Не работает: нет связи, вход не принят.
  down,

  /// Ещё не подключено: входа не было или из приложения вышли. Это не
  /// неисправность — «Как дела?» не жалуется и не предлагает жалобу, а
  /// коротко подсказывает, где подключить.
  notConnected,
}

/// Отчёт о здоровье коннектора: состояние, пояснение по-русски и с какого
/// момента так.
final class HealthReport {
  const HealthReport(this.status, {this.detail = '', this.since});

  const HealthReport.ok() : this(HealthStatus.ok);

  final HealthStatus status;

  /// Что не так, для пользователя: «нет связи с сервером склада». У
  /// [HealthStatus.ok] может быть пустым.
  final String detail;

  /// С какого момента такое состояние (последний успех, начало сбоя);
  /// `null` — неизвестно.
  final DateTime? since;

  bool get isOk => status == HealthStatus.ok;

  /// Подключения ещё нет: не сбой ([HealthStatus.notConnected]).
  bool get isNotConnected => status == HealthStatus.notConnected;
}

/// Необязательная проверка здоровья коннектора (docs/CONNECTORS.md,
/// «Проверка здоровья»). Её спрашивает «Как дела?» у каждого включённого
/// коннектора. Проверка не должна ничего менять и должна быть быстрой:
/// маршрутизатор ждёт её не дольше [timeout].
abstract interface class ConnectorHealth {
  /// Сколько ждать ответа проверки: дольше — «не ответил вовремя».
  static const Duration timeout = Duration(seconds: 3);

  Future<HealthReport> health();
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
    this.onDropped,
  });

  /// Вызывается, когда ожидание снято без ответа: другое сообщение, новый
  /// вопрос, выключенный коннектор. Так карточка вопроса узнаёт, что он
  /// устарел. Маршрутизатор вызывает его не больше одного раза.
  final void Function()? onDropped;

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

/// Коннектор, который понимает уточнение ответа на свой вопрос, кроме
/// «да» и «нет»: «кроме хлеба», «только отчёт» на «Перенести эти 5
/// задач…?». Маршрутизатор спрашивает владельца ожидания до обычного
/// разбора; совпадение уходит в `run` владельца, а ожидание снимается,
/// если `run` не попросит подтверждения снова.
abstract interface class ConfirmationFollowUp {
  /// Совпадение для [utterance] как уточнения ответа на [pending] или
  /// `null`. Без ввода-вывода, как `match`.
  ConnectorMatch? matchFollowUp(
    Utterance utterance,
    PendingConfirmation pending,
  );

  /// Ответ с пояснением («да, хлеб тоже», [ConfirmationReply.leading]),
  /// в котором нет явной команды. `null` — принять [reply] как есть;
  /// совпадение — выполнить его вместо ответа: например, переспросить,
  /// если пояснение может менять смысл согласия. Без ввода-вывода.
  ConnectorMatch? matchLeadingAnswer(
    Utterance utterance,
    PendingConfirmation pending,
    ConfirmationReply reply,
  );
}

/// Ответ пользователя на [PendingConfirmation]: так его получает `run`.
final class ConfirmationAnswer {
  const ConfirmationAnswer(this.pending, this.reply, {this.viaButton = false});

  final PendingConfirmation pending;
  final ConfirmationReply reply;

  /// Ответ — кнопкой карточки, а не текстом. Действие с записью во
  /// внешнем приложении выполняется только по кнопке «Подтвердить»
  /// (ADR-013): текстовое «да» лишь просит нажать её, «нет» отменяет.
  final bool viaButton;

  bool get confirmed => reply == ConfirmationReply.yes;
}

/// Совпадение, которое маршрутизатор выполняет как другую фразу: так
/// коннектор, понявший фразу по контексту сессии, отдаёт её тому, кто её
/// выполнит («сделай бэкап» после разговора о паролях — «сделай резервную
/// копию сейфа»). Кладётся в [ConnectorMatch.payload].
final class Reroute {
  const Reroute({
    required this.text,
    required this.connectorId,
    this.noteReplyId,
    this.orElse,
  });

  /// Каноническая фраза без секретов: её разберут заново, со всеми
  /// правилами (SecretGuard, фраза о паролях не уходит в сеть).
  final String text;

  /// Коннектор, которому предназначена [text]. Если он выключен,
  /// маршрутизатор не перенаправляет, а запускает исходное совпадение с
  /// [orElse] в payload.
  final String connectorId;

  /// Запись каталога, которой начинается ответ: «Понял как копию
  /// паролей.» (как понята фраза — PLANS.md, слой 7). `null` — без неё.
  final String? noteReplyId;

  /// Payload исходного совпадения, если перенаправить нельзя.
  final Object? orElse;
}

/// Состояние диалога, общее для всех коннекторов.
///
/// Живёт столько же, сколько контроллер. Коннектор читает и меняет выбор
/// только своих объектов: «её» в «Заверши её» — задача, а не товар склада.
final class AssistantSession {
  AssistantSession({
    this.clock = const SystemClock(),
    ReplyLibrary? replies,
  }) : replies = replies ?? ReplyLibrary.builtIn;

  /// Источник времени. Коннекторы не вызывают `DateTime.now()` напрямую.
  final Clock clock;

  /// Расширения: включённые навыки, подключения и паки. Маршрутизатор
  /// ставит его при создании; беседа берёт отсюда, что умеет помощник,
  /// здоровье коннекторов и шутки.
  ExtensionRegistry? extensions;

  /// Кто отвечает на текущее сообщение. Маршрутизатор ставит его вместе
  /// с [voice].
  Persona speaker = Personas.sado;

  /// Настройки помощников на начало текущего сообщения.
  PersonaSettings personas = const PersonaSettings();

  /// Каталоги ответов: маршрутизатор обновляет их при смене расширений.
  ReplyLibrary replies;

  /// Голос текущей реплики: маршрутизатор ставит его в начале каждого
  /// сообщения, и до конца ответа он не меняется, даже если настройки
  /// поменяли посреди ответа.
  ReplyVoice voice = const ReplyVoice();

  /// Номер реплики в разговоре: от него зависит, какой вариант фразы
  /// прозвучит. Растёт с каждой репликой, поэтому соседние ответы
  /// звучат по-разному.
  int turn = 0;

  /// Текст записи [id] каталога ответов голосом [voice].
  String say(
    String id, [
    Map<String, String> values = const <String, String>{},
  ]) =>
      replies.render(Reply(id, values), voice, turn: turn++);

  /// Текст записи [id] голосом [voice], но в роде [gender]: фраза о другом
  /// помощнике склоняется по его роду (`talk.who.helper`), стиль и
  /// обращение — говорящего.
  String sayAs(
    String id,
    ReplyGender gender, [
    Map<String, String> values = const <String, String>{},
  ]) =>
      replies.render(
        Reply(id, values),
        voice.copyWith(gender: gender),
        turn: turn++,
      );

  /// Ответ из каталога: текст по записи [id] с фактами [values].
  AssistantResponse reply(
    String id, {
    Map<String, String> values = const <String, String>{},
    required String intent,
    required AssistantStatus status,
    Task? task,
    PersonaSettingsChange? settingsChange,
    BulkChecklist? checklist,
    ActionCard? card,
    SecureCardRequest? secureCard,
    Clarification? clarification,
    ExtensionCard? job,
    String? prefix,
  }) =>
      AssistantResponse(
        message:
            prefix == null ? say(id, values) : '$prefix ${say(id, values)}',
        intent: intent,
        status: status,
        task: task,
        replyId: id,
        values: values,
        settingsChange: settingsChange,
        checklist: checklist,
        card: card,
        secureCard: secureCard,
        clarification: clarification,
        job: job,
      );

  /// Файлы, прикреплённые к текущему сообщению (ADR-019), — только для
  /// чтения: навык-расширение подставляет их в свою карточку. Маршрутизатор
  /// ставит их в начале сообщения.
  List<JobFile> attachments = const <JobFile>[];

  /// Файлы недавних сообщений этой сессии (без файлов текущего).
  List<JobFile> recentAttachments = const <JobFile>[];

  SelectedItem? _selection;

  /// Задача чата, в котором пришло текущее сообщение (ADR-010); `null` —
  /// главный чат. Маршрутизатор ставит её в начале сообщения и не меняет
  /// до конца ответа. В чате задачи она — цель «готово», «перенеси на
  /// завтра» по умолчанию, важнее выбора ([selectedItemFor]).
  String? chatTaskId;

  /// Метка задач проекта-папки, в сессии которого пришло сообщение
  /// (ADR-018), без «#»; `null` — сессия вне проектов или проект не связан
  /// с меткой. Новая задача без своей метки получает эту. Ставится вместе
  /// с [chatTaskId].
  String? projectTag;

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
  ///
  /// Запоминается и тот, кто спросил ([pendingSpeaker], по умолчанию —
  /// текущий [speaker]): в дуэте на «да» или «нет» отвечает он, даже если
  /// адресат в поле ввода с тех пор сменился.
  void requestConfirmation(PendingConfirmation pending, {Persona? speaker}) {
    _pendingConfirmation = pending;
    _pendingSpeaker = speaker ?? this.speaker;
  }

  Persona? _pendingSpeaker;

  /// Кто задал вопрос [pendingConfirmation]; `null`, если ожидания нет.
  Persona? get pendingSpeaker =>
      _pendingConfirmation == null ? null : _pendingSpeaker;

  /// Забирает ожидание: после этого его больше нет. Вызывает маршрутизатор
  /// в начале каждого сообщения.
  PendingConfirmation? takePendingConfirmation() {
    final pending = _pendingConfirmation;
    _pendingConfirmation = null;
    _pendingSpeaker = null;
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
    onForget?.call(connectorId, itemId);
  }

  /// Вызывается при каждом [forget]: маршрутизатор хранит выбор главного
  /// чата, пока открыт чат задачи, и забывает в нём тот же объект
  /// (задачу завершили в её чате — в главном она больше не «её»).
  void Function(String connectorId, String itemId)? onForget;
}

/// Навык-расширение с карточкой-формой (docs/EXTENSIONS.md): карточку
/// можно открыть без фразы — из «+» → «Шаблоны команд».
abstract interface class FormConnector {
  /// Ответ с пустой карточкой (действие [action], если задано).
  AssistantResponse openForm(String? action, AssistantSession session);
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
