// Папки результатов карточек расширений в сессии: files/<сессия>/out/<id>.
// Пути безопасны, уборка не трогает живые и убирает брошенные.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/chats/attachments.dart';
import 'package:local_assistant/core/chats/chat_book.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/chats/chat_store.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:path/path.dart' as p;

void main() {
  test('isSafePath: out/<id>/… — да, побеги и мусор — нет', () {
    expect(ChatAttachment.isSafePath('files/session-1/m_1-0.png'), isTrue);
    expect(
      ChatAttachment.isSafePath('files/session-1/out/j1_0/Архив.zip'),
      isTrue,
    );
    expect(
      ChatAttachment.isSafePath('files/session-1/out/j1_0/фото/1.jpg'),
      isTrue,
    );
    for (final bad in <String>[
      'files/session-1/out/j1_0',
      'files/session-1/out/../x/y',
      'files/session-1/out/j1_0/../../x',
      'files/session-1/out/j 1/x',
      'files/session-1/out/j1_0/a\\b',
      'files/session-1/out/j1_0/a\u0001',
      'other/session-1/out/j1_0/x',
      'files/session-1/out/j1_0/./x',
    ]) {
      expect(ChatAttachment.isSafePath(bad), isFalse, reason: bad);
    }
  });

  test('папка результата: на диске — в папке сессии, в памяти — нет', () {
    final store = IoAttachmentStore('/data/chats');
    final out = store.outputDir('session:1', 'j1_0')!;
    expect(out, endsWith(p.join('out', 'j1_0')));
    expect(
      AttachmentPaths.outFolder('session:1', 'j1_0'),
      startsWith('files/'),
    );
    expect(InMemoryAttachmentStore().outputDir('session:1', 'j1_0'), isNull);
  });

  test('sweep: брошенная out/<id> удаляется, живая остаётся', () async {
    final temp = await Directory.systemTemp.createTemp('attachments_out');
    addTearDown(() => temp.delete(recursive: true));
    final store = IoAttachmentStore(temp.path);
    final live = store.outputDir('session:1', 'j_live')!;
    final dead = store.outputDir('session:1', 'j_dead')!;
    for (final dir in <String>[live, dead]) {
      Directory(p.join(dir, 'sub')).createSync(recursive: true);
      File(p.join(dir, 'sub', 'a.txt')).writeAsStringSync('x');
    }
    await store.sweep('session:1', <String>{
      AttachmentPaths.outFolder('session:1', 'j_live'),
    });
    expect(Directory(live).existsSync(), isTrue);
    expect(Directory(dead).existsSync(), isFalse);
    // Ни одной ссылки — уходит и папка out, и папка сессии.
    await store.sweep('session:1', <String>{});
    expect(Directory(live).existsSync(), isFalse);
  });

  test('ChatBook: карточка в сообщении держит свою папку при уборке', () async {
    final temp = await Directory.systemTemp.createTemp('attachments_book');
    addTearDown(() => temp.delete(recursive: true));
    final store = JsonChatStore(temp.path);
    final book = ChatBook(store: store, clock: FixedClock(DateTime(2026)));
    await book.load();
    final chatId = book.currentId;
    final card = ExtensionCard(
      id: 'j_keep',
      extensionId: ExtensionForms.archiver,
      updatedAt: DateTime(2026),
    );
    book.append(
      chatId,
      ChatMessage(
        id: book.newMessageId(),
        author: ChatAuthor.persona,
        personaId: 'rio',
        text: 'Карточка',
        timestamp: DateTime(2026),
        job: card,
      ),
    );
    final keep = store.attachments.outputDir(chatId, 'j_keep')!;
    final drop = store.attachments.outputDir(chatId, 'j_drop')!;
    for (final dir in <String>[keep, drop]) {
      Directory(dir).createSync(recursive: true);
      File(p.join(dir, 'a.zip')).writeAsStringSync('x');
    }
    await book.discard(chatId, const <ChatAttachment>[]);
    expect(Directory(keep).existsSync(), isTrue);
    expect(Directory(drop).existsSync(), isFalse);
  });

  test('ChatBook: карточка ушла за предел сообщений — её папка убрана',
      () async {
    final temp = await Directory.systemTemp.createTemp('attachments_trim');
    addTearDown(() => temp.delete(recursive: true));
    final store = JsonChatStore(temp.path);
    final book = ChatBook(store: store, clock: FixedClock(DateTime(2026)));
    await book.load();
    final chatId = book.currentId;
    ChatMessage message(String text, {ExtensionCard? job}) => ChatMessage(
          id: book.newMessageId(),
          author: ChatAuthor.persona,
          personaId: 'rio',
          text: text,
          timestamp: DateTime(2026),
          job: job,
        );
    book.append(
      chatId,
      message(
        'Карточка',
        job: ExtensionCard(
          id: 'j_old',
          extensionId: ExtensionForms.archiver,
          updatedAt: DateTime(2026),
        ),
      ),
    );
    final out = store.attachments.outputDir(chatId, 'j_old')!;
    Directory(out).createSync(recursive: true);
    File(p.join(out, 'a.zip')).writeAsStringSync('x');
    for (var i = 0; i < ChatStore.maxMessages; i++) {
      book.append(chatId, message('$i'));
    }
    await book.flush();
    for (var i = 0; i < 50 && Directory(out).existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(Directory(out).existsSync(), isFalse);
  });

  test('ChatBook: прочитанный чат — сразу onThreadLoaded', () async {
    final temp = await Directory.systemTemp.createTemp('attachments_loaded');
    addTearDown(() => temp.delete(recursive: true));
    final first = ChatBook(
      store: JsonChatStore(temp.path),
      clock: FixedClock(DateTime(2026)),
    );
    await first.load();
    final chatId = first.currentId;
    first.append(
      chatId,
      ChatMessage(
        id: first.newMessageId(),
        author: ChatAuthor.persona,
        personaId: 'rio',
        text: 'Карточка',
        timestamp: DateTime(2026),
        job: ExtensionCard(
          id: 'j_run',
          extensionId: ExtensionForms.archiver,
          updatedAt: DateTime(2026),
          state: CardState.running,
        ),
      ),
    );
    await first.flush();
    final second = ChatBook(
      store: JsonChatStore(temp.path),
      clock: FixedClock(DateTime(2026)),
    );
    final loaded = <CardState?>[];
    second.onThreadLoaded = (ChatThread thread) => loaded.addAll(<CardState?>[
          for (final m in thread.messages)
            if (m.job != null) m.job!.state,
        ]);
    await second.load();
    await second.open(chatId);
    expect(loaded, <CardState?>[CardState.interrupted]);
  });
}
