import 'package:characters/characters.dart';

import 'attachments.dart';
import '../models/action_card.dart';
import '../models/assistant_types.dart';
import '../models/bulk.dart';
import '../commands/command_suggest.dart';
import '../models/clarification.dart';
import '../models/secure_card.dart';

/// Какой это чат: чат одной задачи или сессия (ADR-015).
///
/// [main] — прежний чат «Главный»: приложение его больше не создаёт и
/// читает только при переносе старых файлов в обычную сессию (ADR-010,
/// «Обновление: только сессии»; [ChatThread.legacyMainSessionId]).
enum ChatKind { main, task, session }

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

/// Ссылка из сообщения на другой чат: «Открыть сессию задачи» под ответом
/// в сессии или «из сессии «…»» под копией в чате задачи.
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
    this.card,
    this.link,
    this.secureCard,
    this.clarification,
    this.suggestions,
    this.attachments = const <ChatAttachment>[],
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

  /// Карточка действия с записью под ответом (ADR-013) — данные без полей
  /// записи. После перезапуска ждущая — устаревшая, отправленная без
  /// ответа — «итог неизвестен» ([ActionCard.fromJson]).
  final ActionCard? card;

  /// Ссылка на другой чат под сообщением.
  final ChatLink? link;

  /// Временная карточка навыка «Пароли» (D10): живёт только в памяти. Её
  /// нет в [toJson] и [fromJson], и [copyAs] её не копирует — после
  /// перезапуска остаётся только текст.
  final SecureCardRequest? secureCard;

  /// Уточняющий вопрос с вариантами под ответом: кнопки вариантов, пока
  /// вопрос ждёт ответа. Живёт только в памяти, как [secureCard]: его нет
  /// в [toJson] и [fromJson], и [copyAs] его не копирует.
  final Clarification? clarification;

  /// Подсказка команд под ответом «не до конца понял» (ADR-022). Только в
  /// памяти, как [clarification]: её нет в [toJson] и [fromJson], и
  /// [copyAs] её не копирует.
  final CommandSuggestions? suggestions;

  /// Прикреплённые файлы (ADR-019): описания копий в папке сессии. Пишутся
  /// в JSON, только если есть; [copyAs] их не копирует — в чат задачи
  /// файлы не попадают.
  final List<ChatAttachment> attachments;

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
        card: card,
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
        card: card,
        link: link,
        secureCard: secureCard,
        clarification: clarification,
        suggestions: suggestions,
        attachments: attachments,
      );

  /// То же сообщение с другим текстом [text] (строка о сохранённых файлах
  /// под ответом).
  ChatMessage withText(String text) => ChatMessage(
        id: id,
        author: author,
        text: text,
        timestamp: timestamp,
        personaId: personaId,
        status: status,
        taskId: taskId,
        checklist: checklist,
        card: card,
        link: link,
        secureCard: secureCard,
        clarification: clarification,
        suggestions: suggestions,
        attachments: attachments,
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
        if (card != null) 'card': card!.toJson(),
        if (link != null) 'link': link!.toJson(),
        if (attachments.isNotEmpty)
          'attachments': <Map<String, Object?>>[
            for (final attachment in attachments) attachment.toJson(),
          ],
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
    final files = json['attachments'];
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
      card: json.containsKey('card') ? ActionCard.fromJson(json['card']) : null,
      link: ChatLink.fromJson(json['link']),
      attachments: files is List
          ? <ChatAttachment>[
              for (final file in files)
                if (ChatAttachment.fromJson(file)
                    case final ChatAttachment attachment)
                  attachment,
            ]
          : const <ChatAttachment>[],
    );
  }
}

/// Чат: чат задачи (`task:<id задачи>`) или сессия
/// (`session:<микросекунды>_<случайное>`; перенесённый прежний «Главный» —
/// [legacyMainSessionId]).
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
    this.title,
    this.customTitle,
    this.pinnedAt,
    this.preview,
    this.lastPersonaId,
    this.unread = false,
    this.ownTalk = false,
    this.projectId,
    List<ChatMessage>? messages,
    this.loaded = true,
    int storedCount = 0,
  })  : lastActivityAt = lastActivityAt ?? createdAt,
        messages = messages ?? <ChatMessage>[],
        _storedCount = storedCount;

  /// Id прежнего чата «Главный» — только для переноса старых файлов
  /// ([ChatKind.main]) и старых ссылок на него ([ChatLink.chatId]).
  static const String mainId = 'main';

  /// Сессия, в которую перенесён прежний «Главный» (файл
  /// `session-main.json`).
  static const String legacyMainSessionId = '${sessionPrefix}main';

  /// Id чата задачи [taskId].
  static String taskChatId(String taskId) => 'task:$taskId';

  /// Префикс id сессии.
  static const String sessionPrefix = 'session:';

  /// Название новой сессии, пока в ней нет команды.
  static const String untitledSession = 'Новая сессия';

  /// Самое длинное название, которое пользователь может дать сессии
  /// ([customTitle]).
  static const int customTitleLimit = 60;

  final String id;
  final ChatKind kind;

  /// Задача чата; `null` у сессии.
  final String? taskId;

  /// Задача, из чата которой создана эта задача: первый уровень
  /// «иерархии контекста» (docs/PLANS.md). Хранится в чате, а не в
  /// задаче: tasks.json не меняется.
  final String? parentTaskId;

  /// Когда создан. Меняется только у пустой сессии ([touchEmpty]).
  DateTime createdAt;
  DateTime lastActivityAt;

  /// Адресат «Кому:» из прежних версий: читается из старых файлов без
  /// ошибок, но интерфейс его не использует (выбора «Кому» нет,
  /// отвечает ведущий роли или тот, к кому обратились по имени).
  String? addressee;

  /// Название сессии: первая команда пользователя (уже без секретов);
  /// `null` — команды ещё не было. У чатов задач не задаётся.
  String? title;

  /// Название, которое дал пользователь («Переименовать»): важнее [title].
  /// Только у сессий; `null` — не переименовывали.
  String? customTitle;

  /// Когда сессию закрепили; `null` — не закреплена.
  DateTime? pinnedAt;

  /// Одна строка из последнего ответа помощника для меню: копия уже
  /// сохранённого (очищенного) текста или нейтральная фраза вместо
  /// карточки «Паролей», действия, списка и ответов навыков с секретами
  /// (ChatPreview, ADR-010). `null` — помощник ещё не отвечал.
  String? preview;

  /// Кто из помощников ответил последним (`rio`, `noda`); `null` — ещё
  /// никто.
  String? lastPersonaId;

  /// В чат пришло сообщение, пока он был закрыт (напоминание помощника,
  /// ответ на команду, отправленную перед уходом из чата).
  bool unread;

  /// В чате задачи есть своя реплика пользователя — не копия команды,
  /// которой задачу создали ([ChatBook.onTaskCreated]). Только такие чаты
  /// задач стоят в меню среди сессий: иначе каждая созданная задача
  /// добавляла бы строку рядом с сессией, где её создали. У сессий не
  /// используется.
  bool ownTalk;

  /// Проект-папка, в которой лежит чат ([ChatBook.moveToProject],
  /// ADR-018); `null` — вне проектов. Только у сессий и чатов задач.
  /// Ссылка на проект, которого уже нет, при чтении становится `null`
  /// (ChatBook.load).
  String? projectId;

  /// Сообщения по порядку. Пока чат не открыт ([loaded] = false), здесь
  /// только написанное в этом запуске, а сохранённых — [messageCount] из
  /// index.json.
  final List<ChatMessage> messages;

  /// Сообщения прочитаны с диска (или чат создан в этом запуске).
  bool loaded;

  final int _storedCount;

  bool get isSession => kind == ChatKind.session;

  /// Закреплена ([pinnedAt]).
  bool get pinned => pinnedAt != null;

  /// Пустую сессию открыли снова («+», удаление открытого чата): она
  /// «создана» сейчас и в меню стоит в «Сегодня», а не в дне, когда её
  /// впервые оставили пустой. На диск пустая сессия не пишется. У чата с
  /// сообщениями ничего не меняется.
  void touchEmpty(DateTime now) {
    if (!isSession || messageCount > 0) return;
    createdAt = now;
    lastActivityAt = now;
  }

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
        if (title != null) 'title': title,
        if (customTitle != null) 'custom_title': customTitle,
        if (pinnedAt != null) 'pinned_at': pinnedAt!.toIso8601String(),
        if (preview != null) 'preview': preview,
        if (lastPersonaId != null) 'last_persona': lastPersonaId,
        if (unread) 'unread': true,
        if (kind == ChatKind.task) 'own_talk': ownTalk,
        if (projectId != null) 'project_id': projectId,
        'count': messageCount,
      };

  /// Чат по метаданным без сообщений ([loaded] = false). Повреждённые
  /// метаданные — `null`. Поля, которых нет в старых файлах
  /// (`custom_title`, `pinned_at`, `preview`, `last_persona`), читаются
  /// осторожно: нет или не того типа — `null`. `project_id` старые
  /// версии не пишут и при чтении пропускают.
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
    if (kind == ChatKind.session &&
        (!id.startsWith(sessionPrefix) || id.length == sessionPrefix.length)) {
      return null;
    }
    final parent = json['parent_task_id'];
    final addressee = json['addressee'];
    final title = json['title'];
    final count = json['count'];
    final custom = json['custom_title'];
    final pinned = json['pinned_at'];
    final preview = json['preview'];
    final persona = json['last_persona'];
    final own = json['own_talk'];
    final project = json['project_id'];
    final session = kind == ChatKind.session;
    final stored = count is int && count >= 0 ? count : 0;
    return ChatThread(
      id: id,
      kind: kind,
      taskId: taskId is String ? taskId : null,
      parentTaskId: parent is String ? parent : null,
      createdAt: created,
      lastActivityAt: DateTime.tryParse('${json['last_activity_at']}'),
      addressee: addressee is String ? addressee : null,
      title: session && title is String && title.isNotEmpty ? title : null,
      customTitle:
          session && custom is String ? cleanCustomTitle(custom) : null,
      pinnedAt: pinned is String ? DateTime.tryParse(pinned) : null,
      preview: preview is String && preview.trim().isNotEmpty
          ? preview.replaceAll(RegExp(r'\s+'), ' ').trim()
          : null,
      lastPersonaId: persona is String && persona.isNotEmpty ? persona : null,
      unread: json['unread'] == true,
      // Старые файлы без признака: свои реплики, вероятно, есть, если
      // сообщений больше двух копий из onTaskCreated. При открытии чата
      // признак уточняется по сообщениям.
      ownTalk: kind == ChatKind.task && (own is bool ? own : stored > 2),
      projectId:
          kind != ChatKind.main && project is String && project.isNotEmpty
              ? project
              : null,
      loaded: false,
      storedCount: stored,
    );
  }

  /// Команда [messages]`[i]` — копия из ChatBook.onTaskCreated: за ней
  /// идёт копия ответа со ссылкой на исходное сообщение
  /// ([ChatLink.messageId]). Исходный ответ ссылается на чат задачи без
  /// сообщения.
  static bool isCopiedCommand(List<ChatMessage> messages, int i) {
    if (!messages[i].fromUser || i + 1 >= messages.length) return false;
    final next = messages[i + 1];
    return !next.fromUser && next.link?.messageId != null;
  }

  /// Есть ли в [messages] своя реплика пользователя, а не копия команды
  /// ([isCopiedCommand]) — признак [ownTalk] по сообщениям.
  static bool hasOwnTalk(List<ChatMessage> messages) {
    for (var i = 0; i < messages.length; i++) {
      if (messages[i].fromUser && !isCopiedCommand(messages, i)) return true;
    }
    return false;
  }

  /// Название от пользователя: пробелы схлопнуты, края обрезаны, не
  /// длиннее [customTitleLimit] видимых знаков ([titleLength]). Пустое —
  /// `null`.
  static String? cleanCustomTitle(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return null;
    final chars = flat.characters;
    return chars.length <= customTitleLimit
        ? flat
        : chars.take(customTitleLimit).toString().trimRight();
  }

  /// Длина названия в видимых знаках (графемах), как её считает поле
  /// ввода с `maxLength`: эмодзи, флаг или буква с ударением — один знак,
  /// а не две-четыре единицы UTF-16, и обрезка не режет знак пополам.
  static int titleLength(String text) => text.characters.length;
}
