import 'dart:convert';

import '../core/chats/chat_models.dart';
import '../core/connectors/manifest/connection.dart';

/// Строки «ключ → значение» браузера (`localStorage`) — за интерфейсом:
/// тесты на VM подставляют [MemoryStorage]. Ключи помощника начинаются с
/// `svz:` — страница склада при выходе стирает их по этому началу.
abstract interface class KeyValueStorage {
  String? read(String key);

  /// Не записалось (нет места, запрещено) — исключение.
  void write(String key, String value);

  void remove(String key);
}

final class MemoryStorage implements KeyValueStorage {
  final Map<String, String> values = <String, String>{};

  @override
  String? read(String key) => values[key];

  @override
  void write(String key, String value) => values[key] = value;

  @override
  void remove(String key) => values.remove(key);
}

/// Начало всех ключей помощника в хранилище браузера.
const String widgetKeyPrefix = 'svz:';

/// Состояние подключения и кэш описания в хранилище браузера. Ключа
/// помощника здесь нет: он только в памяти (`InMemorySecretStore`) — страница
/// выдаёт его заново при каждом открытии.
final class WidgetConnectionStore implements ConnectionStore {
  WidgetConnectionStore(this.storage);

  final KeyValueStorage storage;

  static String recordKey(String appId) => '${widgetKeyPrefix}conn:$appId';
  static String manifestKey(String appId) => '${widgetKeyPrefix}desc:$appId';

  @override
  Future<ConnectionRecord?> load(String appId) async {
    final text = storage.read(recordKey(appId));
    if (text == null) return null;
    try {
      return ConnectionRecord.fromJson(appId, jsonDecode(text));
    } on Object {
      return null;
    }
  }

  @override
  Future<void> save(ConnectionRecord record) async =>
      storage.write(recordKey(record.appId), jsonEncode(record.toJson()));

  @override
  Future<String?> loadManifest(String appId) async =>
      storage.read(manifestKey(appId));

  @override
  Future<void> saveManifest(String appId, String source) async =>
      storage.write(manifestKey(appId), source);
}

/// История разговора веб-помощника: последние [maxMessages] сообщений под
/// логином сотрудника (`svz:hist:<логин>`). Не влезает в [maxChars] —
/// старые уходят первыми. Записать не вышло — разговор живёт до закрытия
/// страницы.
final class WidgetHistory {
  WidgetHistory(this.storage, String login)
      : key = '${widgetKeyPrefix}hist:${_safe(login)}';

  final KeyValueStorage storage;
  final String key;

  static const int maxMessages = 200;

  /// Около 1 МБ в UTF-16 `localStorage` — с запасом от предела 5 МБ.
  static const int maxChars = 512 * 1024;

  static String _safe(String login) {
    final clean = login.toLowerCase().replaceAll(RegExp(r'[^a-z0-9._@-]'), '');
    return clean.isEmpty ? '_' : clean;
  }

  List<ChatMessage> load() {
    final text = storage.read(key);
    if (text == null) return <ChatMessage>[];
    try {
      final json = jsonDecode(text);
      if (json is! Map || json['v'] != 1 || json['messages'] is! List) {
        return <ChatMessage>[];
      }
      return <ChatMessage>[
        for (final item in json['messages'] as List)
          if (ChatMessage.fromJson(item) case final ChatMessage m) m,
      ];
    } on Object {
      return <ChatMessage>[];
    }
  }

  void save(List<ChatMessage> messages) {
    var list = messages.length > maxMessages
        ? messages.sublist(messages.length - maxMessages)
        : messages;
    while (true) {
      final text = jsonEncode(<String, Object?>{
        'v': 1,
        'messages': <Object?>[for (final m in list) m.toJson()],
      });
      if (text.length <= maxChars || list.length <= 1) {
        try {
          storage.write(key, text);
        } on Object {
          // Нет места или запрещено — история до закрытия страницы.
        }
        return;
      }
      list = list.sublist(list.length ~/ 4 + 1);
    }
  }

  void clear() => storage.remove(key);
}
