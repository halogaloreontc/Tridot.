import '../models/assistant_types.dart';
import '../models/bulk.dart';

/// Какой это чат: главный или чат одной задачи.
enum ChatKind { main, task }

/// Кто написал сообщение.
enum ChatAuthor {
  /// Пользователь: команда или реплика.
  user,

  /// Помощник ([ChatMessage.personaId]: `rio`, `noda`).
  persona,

  /// Служебная строка приложения (сейчас не используется, оставлена для
  /// формата: читается и пишется как есть).
  system,
}

/// Ссылка из сообщения на другой чат: «Открыть чат задачи» под ответом
/// в главном чате или «из чата «Главный»» под копией в чате задачи.
final class ChatLink {
  const ChatLink({required this.chatId, this.messageId, this.taskId});

  /// Чат, который откроется по ссылке.
  final String chatId;

  /// Сообщение в том чате, на которое ведёт ссылка; `null` — чат целиком.
  final String? messageId;

  /// Задача чата по ссылке (для подписи и проверки, что она жива).
  final String? taskId;

  Map<String, Object?> toJson() => <String, Object?>{
        'chat_id': chatId,
        if (messageId != null) 'message_id': messageId,
        if (taskId != null) 'task_id': taskId,
      };

  /// Повреждённая ссылка — `null`: сообщение читается и без неё.
  static ChatLink? fromJson(Object? json) {
    if (json is! Map) return null;
    final chatId = json['chat_id'];
    if (chatId is! String || chatId.isEmpty) return null;
    final messageId = json['message_id'];
    final taskId = json['task_id'];
    return ChatLink(
      chatId: chatId,
      messageId: messageId is String ? messageId : null,
      taskId: taskId is String ? taskId : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ChatLink &&
      other.chatId == chatId &&
      other.messageId == messageId &&
      other.taskId == taskId;

  @override
  int get hashCode => Object.hash(chatId, messageId, taskId);
}

/// Сообщение чата: готовый текст, как он был показан, и его автор. Смена
/// стиля или помощника потом его не переписывает.
final class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.author,
    required this.text,
    required this.timestamp,
    this.personaId,
    this.status,
    this.taskId,
    this.checklist,
    this.link,
  });

  /// `m_<микросекунды>_<номер>`: уникален в пределах устройства.
  final String id;
  final ChatAuthor author;

  /// Кто из помощников написал: `rio`, `noda`. Только у
  /// [ChatAuthor.persona].
  final String? personaId;

  /// Готовый текст, как он показан в чате.
  final String text;

  final DateTime timestamp;

  /// «Уточните» / «Ошибка» над ответом; `null` — без пометки.
  final AssistantStatus? status;

  /// Задача под ответом (плитка задачи).
  final String? taskId;

  /// Карточка массовой команды под ответом — данные, а не текст.
  /// После перезапуска неотвеченный вопрос — устаревший
  /// ([BulkChecklist.fromJson]).
  final BulkChecklist? checklist;

  /// Ссылка на другой чат под сообщением.
  final ChatLink? link;

  bool get fromUser => author == ChatAuthor.user;

  /// То же сообщение с другим [id] и ссылкой [link] (копия в чат задачи).
  ChatMessage copyAs(String id, {ChatLink? link}) => ChatMessage(
        id: id,
        author: author,
        text: text,
        timestamp: timestamp,
        personaId: personaId,
        status: status,
        taskId: taskId,
        checklist: checklist,
        link: link,
      );

  /// То же сообщение со ссылкой [link].
  ChatMessage withLink(ChatLink? link) => ChatMessage(
        id: id,
        author: author,
        text: text,
        timestamp: timestamp,
        personaId: personaId,
        status: status,
        taskId: taskId,
        checklist: checklist,
        link: link,
      );

  /// Пустые поля не пишутся.
  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'author': author.name,
        if (personaId != null) 'persona_id': personaId,
        'text': text,
        'ts': timestamp.toIso8601String(),
        if (status != null) 'status': status!.name,
        if (taskId != null) 'task_id': taskId,
        if (checklist != null) 'checklist': checklist!.toJson(),
        if (link != null) 'link': link!.toJson(),
      };

  /// Сообщение из файла чата. Повреждённая запись — `null`: её
  /// пропускают, а остальные сообщения читаются.
  static ChatMessage? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final text = json['text'];
    final author = ChatAuthor.values
        .where((ChatAuthor a) => a.name == json['author'])
        .firstOrNull;
    final ts = json['ts'];
    final timestamp = ts is String ? DateTime.tryParse(ts) : null;
    if (id is! String ||
        id.isEmpty ||
        text is! String ||
        author == null ||
        timestamp == null) {
      return null;
    }
    final personaId = json['persona_id'];
    final taskId = json['task_id'];
    return ChatMessage(
      id: id,
      author: author,
      text: text,
      timestamp: timestamp,
      personaId: personaId is String ? personaId : null,
      status: AssistantStatus.values
          .where((AssistantStatus s) => s.name == json['status'])
          .firstOrNull,
      taskId: taskId is String ? taskId : null,
      checklist: json.containsKey('checklist')
          ? BulkChecklist.fromJson(json['checklist'])
          : null,
      link: ChatLink.fromJson(json['link']),
    );
  }
}

/// Чат: главный (`main`) или чат задачи (`task:<id задачи>`).
///
/// Метаданные (id, вид, задача, адресат, время, «не прочитано», число
/// сообщений) лежат в `chats/index.json` и в шапке файла чата; сообщения —
/// только в файле чата и читаются лениво, при первом открытии
/// ([loaded]).
final class ChatThread {
  ChatThread({
    required this.id,
    required this.kind,
    required this.createdAt,
    DateTime? lastActivityAt,
    this.taskId,
    this.parentTaskId,
    this.addressee,
    this.unread = false,
    List<ChatMessage>? messages,
    this.loaded = true,
    int storedCount = 0,
  })  : lastActivityAt = lastActivityAt ?? createdAt,
        messages = messages ?? <ChatMessage>[],
        _storedCount = storedCount;

  /// Id главного чата.
  static const String mainId = 'main';

  /// Id чата задачи [taskId].
  static String taskChatId(String taskId) => 'task:$taskId';

  final String id;
  final ChatKind kind;

  /// Задача чата; `null` у главного.
  final String? taskId;

  /// Задача, из чата которой создана эта задача: первый уровень
  /// «иерархии контекста» (docs/PLANS.md). Хранится в чате, а не в
  /// задаче: tasks.json не меняется.
  final String? parentTaskId;

  final DateTime createdAt;
  DateTime lastActivityAt;

  /// «Кому:» этого чата; `null` — основной помощник.
  String? addressee;

  /// В чат пришло сообщение, пока он был закрыт (напоминание помощника,
  /// ответ на команду, отправленную перед уходом из чата).
  bool unread;

  /// Сообщения по порядку. Пока чат не открыт ([loaded] = false), здесь
  /// только написанное в этом запуске, а сохранённых — [messageCount] из
  /// index.json.
  final List<ChatMessage> messages;

  /// Сообщения прочитаны с диска (или чат создан в этом запуске).
  bool loaded;

  final int _storedCount;

  bool get isMain => kind == ChatKind.main;

  /// Сколько сообщений в чате, даже если они ещё не прочитаны.
  int get messageCount =>
      loaded ? messages.length : _storedCount + messages.length;

  /// Метаданные для index.json и шапки файла чата.
  Map<String, Object?> metaJson() => <String, Object?>{
        'id': id,
        'kind': kind.name,
        if (taskId != null) 'task_id': taskId,
        if (parentTaskId != null) 'parent_task_id': parentTaskId,
        'created_at': createdAt.toIso8601String(),
        'last_activity_at': lastActivityAt.toIso8601String(),
        if (addressee != null) 'addressee': addressee,
        if (unread) 'unread': true,
        'count': messageCount,
      };

  /// Чат по метаданным без сообщений ([loaded] = false). Повреждённые
  /// метаданные — `null`.
  static ChatThread? fromMetaJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final kind = ChatKind.values
        .where((ChatKind k) => k.name == json['kind'])
        .firstOrNull;
    final created = DateTime.tryParse('${json['created_at']}');
    if (id is! String || kind == null || created == null) return null;
    final taskId = json['task_id'];
    if (kind == ChatKind.main && id != mainId) return null;
    if (kind == ChatKind.task &&
        (taskId is! String || id != taskChatId(taskId))) {
      return null;
    }
    final parent = json['parent_task_id'];
    final addressee = json['addressee'];
    final count = json['count'];
    return ChatThread(
      id: id,
      kind: kind,
      taskId: taskId is String ? taskId : null,
      parentTaskId: parent is String ? parent : null,
      createdAt: created,
      lastActivityAt: DateTime.tryParse('${json['last_activity_at']}'),
      addressee: addressee is String ? addressee : null,
      unread: json['unread'] == true,
      loaded: false,
      storedCount: count is int && count >= 0 ? count : 0,
    );
  }
}
