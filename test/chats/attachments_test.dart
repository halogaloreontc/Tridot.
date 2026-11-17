// Вложения сессий (ADR-019): описание в JSON чата, копии в
// `chats/files/<сессия>/`, стирание вместе с сессией, лимиты, меню
// облачного диска.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/chats/attachments.dart';
import 'package:local_assistant/core/chats/chat_book.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
import 'package:local_assistant/core/cloud/cloud_disk.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/storage/storage_info.dart';
import 'package:path/path.dart' as p;

final class _Clock implements Clock {
  DateTime value = DateTime(2026, 11, 13, 12);

  @override
  DateTime now() => value;
}

/// Файл «с устройства»: байты в памяти, копируется на диск.
final class _Source implements AttachmentSource {
  _Source(this.name, this.bytes, {this.mimeType, int? reportedSize})
      : _size = reportedSize ?? bytes.length;

  @override
  final String name;
  @override
  final String? mimeType;
  final Uint8List bytes;
  final int _size;

  @override
  Future<int> length() async => _size;

  @override
  Future<Uint8List> readAsBytes() async => bytes;

  @override
  Future<void> saveTo(String path) => File(path).writeAsBytes(bytes);
}

/// Файл, копирование которого останавливается на полпути (копия `.tmp`
/// уже на диске) до команды теста.
final class _HeldSource implements AttachmentSource {
  _HeldSource(this.name);

  @override
  final String name;
  @override
  String? get mimeType => null;
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<int> length() async => 4;

  @override
  Future<Uint8List> readAsBytes() async => Uint8List.fromList(<int>[1, 2, 3]);

  @override
  Future<void> saveTo(String path) async {
    await File(path).writeAsBytes(<int>[1, 2, 3, 4]);
    started.complete();
    await release.future;
  }
}

_Source _file(String name, [int size = 16, String? mime]) => _Source(
      name,
      Uint8List.fromList(List<int>.generate(size, (int i) => i % 256)),
      mimeType: mime,
    );

ChatAttachment _sample({String path = 'files/session-1/m1-0.jpg'}) =>
    ChatAttachment(
      id: 'm1-0',
      kind: AttachmentKind.image,
      name: 'кот.jpg',
      path: path,
      size: 2048,
      mime: 'image/jpeg',
      addedAt: DateTime.utc(2026, 11, 13, 9),
    );

void main() {
  group('модель', () {
    test('вложения пишутся в JSON сообщения и читаются обратно', () {
      final message = ChatMessage(
        id: 'm1',
        author: ChatAuthor.user,
        text: '',
        timestamp: DateTime.utc(2026, 11, 13, 9),
        attachments: <ChatAttachment>[_sample()],
      );
      final json = jsonDecode(jsonEncode(message.toJson())) as Map;
      expect(json['attachments'], hasLength(1));
      final back = ChatMessage.fromJson(json.cast<String, Object?>())!;
      expect(back.attachments.single, _sample());
    });

    test('без вложений поля в JSON нет', () {
      final message = ChatMessage(
        id: 'm1',
        author: ChatAuthor.user,
        text: 'привет',
        timestamp: DateTime.utc(2026, 11, 13, 9),
      );
      expect(message.toJson().containsKey('attachments'), isFalse);
    });

    test('битая запись пропускается, сообщение читается', () {
      final json = <String, Object?>{
        'id': 'm1',
        'author': 'user',
        'text': 'смотри',
        'ts': '2026-11-13T09:00:00.000Z',
        'attachments': <Object?>[
          _sample().toJson(),
          'мусор',
          <String, Object?>{'id': 'x'},
          // Путь за пределы папки вложений — не принимается.
          _sample(path: 'files/../secrets.json').toJson(),
          _sample(path: '/etc/passwd').toJson(),
          _sample(path: 'files/a/b/c.jpg').toJson(),
        ],
      };
      final message = ChatMessage.fromJson(json)!;
      expect(message.text, 'смотри');
      expect(message.attachments, <ChatAttachment>[_sample()]);
    });

    test('копия в чат задачи — без файлов, ссылка их сохраняет', () {
      final message = ChatMessage(
        id: 'm1',
        author: ChatAuthor.user,
        text: 'добавь задачу',
        timestamp: DateTime.utc(2026, 11, 13, 9),
        attachments: <ChatAttachment>[_sample()],
      );
      expect(message.copyAs('m2').attachments, isEmpty);
      expect(message.withLink(null).attachments, hasLength(1));
      expect(message.withText('x').attachments, hasLength(1));
    });

    test('вид по MIME и расширению, подписи и название сессии', () {
      expect(AttachmentKind.of('a.HEIC'), AttachmentKind.image);
      expect(AttachmentKind.of('clip', 'video/mp4'), AttachmentKind.video);
      expect(AttachmentKind.of('voice.ogg'), AttachmentKind.audio);
      expect(AttachmentKind.of('отчёт.pdf'), AttachmentKind.document);
      expect(AttachmentKind.of('archive.zip'), AttachmentKind.other);
      expect(_sample().sessionTitle, 'Фото');
      final doc = ChatAttachment(
        id: 'm1-0',
        kind: AttachmentKind.document,
        name: 'отчёт.pdf',
        path: 'files/s/m1-0.pdf',
        size: 1,
        addedAt: DateTime(2026),
      );
      expect(doc.sessionTitle, 'Файл: отчёт.pdf');
      expect(ChatAttachment.sizeLabel(12), '12 Б');
      expect(ChatAttachment.sizeLabel(2048), '2 КБ');
      expect(ChatAttachment.sizeLabel(2516582), '2,4 МБ');
      expect(ChatAttachment.cleanName('  а\nб\u202e.txt '), 'а б .txt');
      expect(ChatAttachment.cleanName(''), 'файл');
    });

    test('имя копии на диске — без имени файла пользователя', () {
      final path = AttachmentPaths.relative(
        'session:1700_ab',
        'm-1',
        2,
        'Паспорт Иванова.JPG',
      );
      expect(path, 'files/session-1700_ab/m-1-2.jpg');
      expect(ChatAttachment.isSafePath(path), isTrue);
      expect(
        AttachmentPaths.fileName('m1', 0, 'странное.расширение'),
        'm1-0',
      );
    });
  });

  group('CloudDiskMenu', () {
    test('ни одного диска — «Подключить диск»', () {
      expect(
        CloudDiskMenu.entries(const <CloudDisk>[]),
        isA<CloudDiskConnect>(),
      );
      expect(CloudDiskConnect.label, 'Подключить диск');
    });

    test('один диск — без выбора', () {
      final menu = CloudDiskMenu.entries(<CloudDisk>[CloudDisk.google]);
      expect(menu, isA<CloudDiskSingle>());
      expect((menu as CloudDiskSingle).disk, CloudDisk.google);
    });

    test('два диска — подменю в постоянном порядке', () {
      final menu = CloudDiskMenu.entries(
        <CloudDisk>[CloudDisk.google, CloudDisk.yandex, CloudDisk.google],
      );
      expect(menu, isA<CloudDiskChoice>());
      expect(
        (menu as CloudDiskChoice).disks,
        <CloudDisk>[CloudDisk.yandex, CloudDisk.google],
      );
    });
  });

  group('хранилище на диске', () {
    late Directory dir;
    late _Clock clock;
    late String chats;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('attachments_test');
      chats = p.join(dir.path, 'chats');
      clock = _Clock();
    });

    tearDown(() => dir.deleteSync(recursive: true));

    Future<ChatBook> open() async {
      final book = ChatBook(
        store: JsonChatStore(chats, debounce: Duration.zero),
        clock: clock,
      );
      await book.load();
      return book;
    }

    Future<ChatMessage> sendFiles(
      ChatBook book,
      List<_Source> files, {
      String text = '',
    }) async {
      final id = book.newMessageId();
      final imported = await book.attach(book.currentId, id, <(
        AttachmentSource,
        String,
      )>[
        for (final file in files) (file, file.name),
      ]);
      final message = ChatMessage(
        id: id,
        author: ChatAuthor.user,
        text: text,
        timestamp: clock.now(),
        attachments: imported.saved,
      );
      book.append(book.currentId, message);
      return message;
    }

    Directory folderOf(String chatId) => Directory(
          p.join(chats, 'files', AttachmentPaths.chatFolder(chatId)),
        );

    test('файл копируется в папку сессии и переживает перезапуск', () async {
      final book = await open();
      final sessionId = book.currentId;
      final sent = await sendFiles(book, <_Source>[
        _file('кот.jpg', 64, 'image/jpeg'),
        _file('отчёт.pdf', 32),
      ]);
      await book.flush();
      expect(sent.attachments, hasLength(2));
      expect(sent.attachments.first.kind, AttachmentKind.image);
      expect(sent.attachments.first.size, 64);
      final copies = folderOf(sessionId).listSync().whereType<File>();
      expect(copies, hasLength(2));
      expect(
        copies.map((File f) => p.basename(f.path)),
        everyElement(isNot(contains('кот'))),
        reason: 'на диске имя без имени пользователя',
      );
      expect(book.thread(sessionId)!.title, 'Фото');

      final again = await open();
      final thread = await again.open(sessionId);
      final restored = thread.messages.single.attachments;
      expect(restored.map((ChatAttachment a) => a.name), <String>[
        'кот.jpg',
        'отчёт.pdf',
      ]);
      expect(again.store.attachments.exists(restored.first), isTrue);
      await again.flush();
      expect(
        folderOf(sessionId).listSync(),
        hasLength(2),
        reason: 'чтение не убирает живые файлы',
      );
    });

    test('файл больше 25 МБ не копируется', () async {
      final book = await open();
      final big = _Source(
        'фильм.mp4',
        Uint8List(4),
        reportedSize: AttachmentStore.maxBytes + 1,
      );
      final id = book.newMessageId();
      final result = await book.attach(book.currentId, id, <(
        AttachmentSource,
        String,
      )>[
        (big, big.name),
        (_file('a.txt'), 'a.txt'),
      ]);
      expect(result.tooLarge, <String>['фильм.mp4']);
      expect(result.saved, hasLength(1));
      expect(result.failed, 0);
    });

    test('к сообщению — не больше 10 файлов', () async {
      final book = await open();
      final result = await book.attach(book.currentId, 'm', <(
        AttachmentSource,
        String,
      )>[
        for (var i = 0; i < 12; i++) (_file('f$i.txt'), 'f$i.txt'),
      ]);
      expect(result.saved, hasLength(AttachmentStore.maxPerMessage));
    });

    test('удаление сессии стирает её папку файлов', () async {
      final book = await open();
      final sessionId = book.currentId;
      await sendFiles(book, <_Source>[_file('a.png')]);
      await book.flush();
      expect(folderOf(sessionId).existsSync(), isTrue);
      await book.remove(sessionId);
      await book.flush();
      expect(folderOf(sessionId).existsSync(), isFalse);
    });

    test('«Очистить историю» стирает все файлы', () async {
      final book = await open();
      await sendFiles(book, <_Source>[_file('a.png')]);
      await book.flush();
      expect(Directory(p.join(chats, 'files')).existsSync(), isTrue);
      await book.clearAll();
      await book.flush();
      expect(Directory(p.join(chats, 'files')).existsSync(), isFalse);
    });

    test('архив чата задачи файлы не трогает', () async {
      final store = JsonChatStore(chats, debounce: Duration.zero);
      final attachment = await store.attachments.import(
        'task:t1',
        'm1',
        0,
        _file('a.png'),
        name: 'a.png',
        now: clock.now(),
      );
      await store.delete('task:t1');
      await store.flush();
      expect(store.attachments.exists(attachment), isTrue);
      await store.erase('task:t1');
      await store.flush();
      expect(store.attachments.exists(attachment), isFalse);
    });

    test('файлы без сообщения убираются при чтении чата', () async {
      final book = await open();
      final sessionId = book.currentId;
      await sendFiles(book, <_Source>[_file('a.png')]);
      // Сбой между копированием и записью: файл есть, сообщения нет.
      await book.attach(sessionId, 'lost', <(AttachmentSource, String)>[
        (_file('b.png'), 'b.png'),
      ]);
      await book.flush();
      expect(folderOf(sessionId).listSync(), hasLength(2));

      final again = await open();
      await again.open(sessionId);
      await again.flush();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(folderOf(sessionId).listSync(), hasLength(1));
    });

    test('сессию удалили, пока копировались файлы: на диске ничего', () async {
      final book = await open();
      final sessionId = book.currentId;
      book.append(
        sessionId,
        ChatMessage(
          id: book.newMessageId(),
          author: ChatAuthor.user,
          text: 'привет',
          timestamp: clock.now(),
        ),
      );
      final held = _HeldSource('b.png');
      final attaching =
          book.attach(sessionId, 'm', <(AttachmentSource, String)>[
        (_file('a.png'), 'a.png'),
        (held, 'b.png'),
        (_file('c.png'), 'c.png'),
      ]);
      await held.started.future;
      await book.remove(sessionId);
      held.release.complete();
      final result = await attaching;
      expect(result.saved, isEmpty);
      await book.flush();
      expect(folderOf(sessionId).existsSync(), isFalse);
    });

    test('уборка во время копирования не стирает новый файл', () async {
      final book = await open();
      final sessionId = book.currentId;
      final held = _HeldSource('b.png');
      final attaching =
          book.attach(sessionId, 'm', <(AttachmentSource, String)>[
        (held, 'b.png'),
      ]);
      await held.started.future;
      // Уборка «сирот» (обрезка, discard) в это время: `.tmp` ждущего
      // вложения — не сирота.
      await book.discard(sessionId, const <ChatAttachment>[]);
      held.release.complete();
      final result = await attaching;
      expect(result.saved, hasLength(1));
      expect(result.failed, 0);
      final store = JsonChatStore(chats, debounce: Duration.zero);
      expect(store.attachments.exists(result.saved.single), isTrue);
    });

    test('ненужные вложения стираются (discard)', () async {
      final book = await open();
      final sessionId = book.currentId;
      final result = await book.attach(sessionId, 'm', <(
        AttachmentSource,
        String,
      )>[
        (_file('a.png'), 'a.png'),
      ]);
      await book.discard(sessionId, result.saved);
      expect(folderOf(sessionId).existsSync(), isFalse);
    });

    test('«Данные» считают и прикреплённые файлы', () async {
      final tasks = File(p.join(dir.path, 'tasks.json'))..writeAsStringSync('');
      final info = JsonStorageInfo(tasks.path, chatsDirectory: chats);
      final book = await open();
      await sendFiles(book, <_Source>[_file('a.png', 1000)]);
      await book.flush();
      final size = await info.sizeBytes();
      expect(size, greaterThanOrEqualTo(1000));
    });
  });

  group('хранилище в памяти', () {
    test('обрезка старых сообщений убирает их файлы', () async {
      final store = InMemoryAttachmentStore(persistent: true);
      final book = ChatBook(
        store: InMemoryChatStore(attachments: store),
        clock: _Clock(),
      );
      await book.load();
      final id = book.currentId;
      final first = await book.attach(id, 'm0', <(AttachmentSource, String)>[
        (_file('a.png'), 'a.png'),
      ]);
      book.append(
        id,
        ChatMessage(
          id: 'm0',
          author: ChatAuthor.user,
          text: '',
          timestamp: DateTime(2026),
          attachments: first.saved,
        ),
      );
      expect(store.paths, hasLength(1));
      for (var i = 1; i <= ChatStore.maxMessages; i++) {
        book.append(
          id,
          ChatMessage(
            id: 'm$i',
            author: ChatAuthor.user,
            text: 'сообщение $i',
            timestamp: DateTime(2026),
          ),
        );
      }
      await Future<void>.delayed(Duration.zero);
      expect(store.paths, isEmpty);
    });
  });
}
