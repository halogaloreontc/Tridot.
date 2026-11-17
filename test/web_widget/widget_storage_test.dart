import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/connectors/manifest/connection.dart';
import 'package:local_assistant/web_widget/widget_storage.dart';

ChatMessage _m(int i, {String text = 'сообщение'}) => ChatMessage(
      id: 'm_$i',
      author: i.isEven ? ChatAuthor.user : ChatAuthor.persona,
      personaId: i.isEven ? null : 'sado',
      text: '$text $i',
      timestamp: DateTime(2026, 11, 15, 12, 0, i % 60),
    );

void main() {
  test('история: под логином, не больше 200 сообщений', () {
    final storage = MemoryStorage();
    final history = WidgetHistory(storage, 'Ivanov');
    expect(history.key, 'svz:hist:ivanov');
    history.save(<ChatMessage>[for (var i = 0; i < 250; i++) _m(i)]);
    final loaded = WidgetHistory(storage, 'ivanov').load();
    expect(loaded, hasLength(WidgetHistory.maxMessages));
    expect(loaded.first.text, 'сообщение 50');
    expect(loaded.last.text, 'сообщение 249');
    expect(WidgetHistory(storage, 'petrov').load(), isEmpty);
    history.clear();
    expect(history.load(), isEmpty);
  });

  test('история: слишком большая — старые уходят первыми', () {
    final storage = MemoryStorage();
    final history = WidgetHistory(storage, 'ivanov');
    final long = 'x' * 6000;
    history
        .save(<ChatMessage>[for (var i = 0; i < 150; i++) _m(i, text: long)]);
    final text = storage.values[history.key]!;
    expect(text.length, lessThanOrEqualTo(WidgetHistory.maxChars));
    final loaded = history.load();
    expect(loaded, isNotEmpty);
    expect(loaded.last.text, endsWith(' 149'));
  });

  test('история: битая запись — пустой разговор', () {
    final storage = MemoryStorage()..values['svz:hist:ivanov'] = '{oops';
    expect(WidgetHistory(storage, 'ivanov').load(), isEmpty);
  });

  test('история: хранилище не пишет — без исключения', () {
    final history = WidgetHistory(_Full(), 'ivanov');
    history.save(<ChatMessage>[_m(1)]);
    expect(history.load(), isEmpty);
  });

  test('подключение: запись и описание без ключей, под svz:', () async {
    final storage = MemoryStorage();
    final store = WidgetConnectionStore(storage);
    await store.save(
      ConnectionRecord(
        appId: 'halowarekeep',
        baseUri: Uri.parse('https://w.example/'),
        login: 'ivanov',
        level: ConnectionLevel.staff,
        scope: 'assist',
        tokenless: true,
      ),
    );
    await store.saveManifest('halowarekeep', '{"format":"assistant/1"}');
    expect(storage.values.keys, everyElement(startsWith(widgetKeyPrefix)));
    final record = (await store.load('halowarekeep'))!;
    expect(record.login, 'ivanov');
    expect(record.tokenless, isTrue);
    expect(await store.loadManifest('halowarekeep'), contains('assistant/1'));
    storage.values[WidgetConnectionStore.recordKey('x')] = 'not json';
    expect(await store.load('x'), isNull);
  });
}

final class _Full implements KeyValueStorage {
  @override
  String? read(String key) => null;

  @override
  void write(String key, String value) =>
      throw StateError('QuotaExceededError');

  @override
  void remove(String key) {}
}
