// «Файлы сессии» (ADR-028): проекция сообщений чата — результаты готовых
// карточек расширений и вложения, новые первыми, без своего хранения.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/chats/attachments.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/chats/session_files.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';

ChatAttachment _att(String id, String name, DateTime at, {int size = 1024}) =>
    ChatAttachment(
      id: id,
      kind: AttachmentKind.of(name),
      name: name,
      path: 'files/session-1/$id.bin',
      size: size,
      addedAt: at,
    );

ChatMessage _msg(
  String id,
  DateTime at, {
  List<ChatAttachment> attachments = const <ChatAttachment>[],
  ExtensionCard? job,
}) =>
    ChatMessage(
      id: id,
      author: job == null ? ChatAuthor.user : ChatAuthor.persona,
      personaId: job == null ? null : 'noda',
      text: job == null ? '' : 'Готово',
      timestamp: at,
      attachments: attachments,
      job: job,
    );

ExtensionCard _card(
  String id,
  DateTime at, {
  CardState state = CardState.done,
  List<String> outputs = const <String>[],
  String extensionId = ExtensionForms.converter,
  Map<String, Object?>? values,
}) =>
    ExtensionCard(
      id: id,
      extensionId: extensionId,
      updatedAt: at,
      state: state,
      outputs: List<String>.of(outputs),
      values: values,
    );

ChatThread _thread(List<ChatMessage> messages) => ChatThread(
      id: 'session:1',
      kind: ChatKind.session,
      createdAt: DateTime(2026, 11, 4, 9),
      messages: messages,
    );

void main() {
  final t0 = DateTime(2026, 11, 4, 10);

  test('пустой чат — два пустых списка', () {
    final files = SessionFiles.of(_thread(<ChatMessage>[]));
    expect(files.outputs, isEmpty);
    expect(files.attachments, isEmpty);
    final talk = SessionFiles.of(
      _thread(<ChatMessage>[_msg('m1', t0), _msg('m2', t0)]),
    );
    expect(talk.outputs, isEmpty);
    expect(talk.attachments, isEmpty);
  });

  test('результаты готовых карточек — новые первыми, без повторов', () {
    final files = SessionFiles.of(
      _thread(<ChatMessage>[
        _msg(
          'm1',
          t0,
          job: _card('j1', t0, outputs: <String>['/out/j1/песня.mp3']),
        ),
        _msg(
          'm2',
          t0.add(const Duration(minutes: 5)),
          job: _card(
            'j2',
            t0.add(const Duration(minutes: 5)),
            extensionId: ExtensionForms.archiver,
            outputs: <String>['/out/j2/Архив.zip'],
          ),
        ),
        // Тот же путь у карточки новее: один раз, по ней.
        _msg(
          'm3',
          t0.add(const Duration(minutes: 9)),
          job: _card(
            'j3',
            t0.add(const Duration(minutes: 9)),
            outputs: <String>['/out/j1/песня.mp3'],
          ),
        ),
      ]),
    );
    expect(
      files.outputs.map((SessionFile f) => f.id),
      <String>['out:j3:0', 'out:j2:0'],
    );
    final song = files.outputs.first;
    expect(song.name, 'песня.mp3');
    expect(song.kind, AttachmentKind.audio);
    expect(song.messageId, 'm3');
    expect(song.extensionId, ExtensionForms.converter);
    expect(song.absolute, '/out/j1/песня.mp3');
    expect(song.size, isNull, reason: 'размер узнаёт панель');
    expect(song.isOutput, isTrue);
    final zip = files.outputs.last;
    expect(zip.archive, isTrue);
    expect(zip.source, SessionFileSource.output);
  });

  test('карточки не «Готово» и без результатов — ничего не дают', () {
    final files = SessionFiles.of(
      _thread(<ChatMessage>[
        for (final (i, state) in <CardState>[
          CardState.form,
          CardState.running,
          CardState.failed,
          CardState.cancelled,
          CardState.interrupted,
        ].indexed)
          _msg(
            'm$i',
            t0,
            job: _card('j$i', t0, state: state, outputs: <String>['/o/$i.mp3']),
          ),
        // «Посмотреть содержимое» архиватора: готово, а файлов нет.
        _msg('m9', t0, job: _card('j9', t0)),
      ]),
    );
    expect(files.outputs, isEmpty);
  });

  test('папка-результат (распаковка) считается', () {
    final files = SessionFiles.of(
      _thread(<ChatMessage>[
        _msg(
          'm1',
          t0,
          job: _card(
            'j1',
            t0,
            extensionId: ExtensionForms.archiver,
            outputs: <String>['/out/j1/фото'],
          ),
        ),
      ]),
    );
    expect(files.outputs.single.name, 'фото');
    expect(files.outputs.single.kind, AttachmentKind.other);
    expect(files.outputs.single.archive, isFalse);
  });

  test('вложения нескольких сообщений — новые первыми, id стабильны', () {
    final a = _att('m1-0', 'Отчёт.pdf', t0);
    final b = _att('m1-1', 'снимок.png', t0);
    final c = _att('m2-0', 'запись.m4a', t0.add(const Duration(hours: 1)));
    final thread = _thread(<ChatMessage>[
      _msg('m1', t0, attachments: <ChatAttachment>[a, b]),
      _msg(
        'm2',
        t0.add(const Duration(hours: 1)),
        attachments: <ChatAttachment>[c],
      ),
    ]);
    final files = SessionFiles.of(thread);
    expect(
      files.attachments.map((SessionFile f) => f.id),
      <String>['att:m2-0', 'att:m1-1', 'att:m1-0'],
    );
    expect(files.attachments.first.attachment, c);
    expect(files.attachments.first.size, c.size);
    expect(files.attachments.first.messageId, 'm2');
    expect(files.attachments.last.kind, AttachmentKind.document);
    // Снова — те же id.
    expect(
      SessionFiles.of(thread).attachments.map((SessionFile f) => f.id),
      files.attachments.map((SessionFile f) => f.id),
    );
  });

  test('исходник карточки — вложение — не повторяется', () {
    final source = _att('m1-0', 'клип.mp4', t0);
    final files = SessionFiles.of(
      _thread(<ChatMessage>[
        _msg('m1', t0, attachments: <ChatAttachment>[source]),
        _msg(
          'm2',
          t0.add(const Duration(minutes: 1)),
          job: _card(
            'j1',
            t0.add(const Duration(minutes: 2)),
            values: <String, Object?>{
              'file': <JobFile>[
                JobFile(path: source.path, name: source.name, attachment: true),
              ],
              'target': 'mp3',
            },
            outputs: <String>['/out/j1/клип.mp3'],
          ),
        ),
      ]),
    );
    expect(files.attachments.map((SessionFile f) => f.name), <String>[
      'клип.mp4',
    ]);
    expect(files.outputs.map((SessionFile f) => f.name), <String>['клип.mp3']);
  });

  test('после записи и чтения чата — то же самое', () {
    final messages = <ChatMessage>[
      _msg(
        'm1',
        t0,
        attachments: <ChatAttachment>[_att('m1-0', 'Отчёт.pdf', t0)],
      ),
      _msg(
        'm2',
        t0.add(const Duration(minutes: 3)),
        job: _card(
          'j1',
          t0.add(const Duration(minutes: 3)),
          outputs: <String>['/out/j1/Отчёт.docx'],
        ),
      ),
    ];
    final restored = <ChatMessage>[
      for (final m in messages)
        ChatMessage.fromJson(jsonDecode(jsonEncode(m.toJson())))!,
    ];
    String ids(ChatThread t) {
      final f = SessionFiles.of(t);
      return <SessionFile>[...f.outputs, ...f.attachments]
          .map((SessionFile s) => '${s.id}|${s.name}|${s.at}|${s.messageId}')
          .join(',');
    }

    expect(ids(_thread(restored)), ids(_thread(messages)));
    expect(ids(_thread(restored)), contains('out:j1:0'));
    expect(ids(_thread(restored)), contains('att:m1-0'));
  });
}
