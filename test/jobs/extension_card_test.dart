// Карточка-форма расширения: история чата, перезапуск посреди работы,
// неизвестное расширение, очистка строк из файла чата.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/jobs/extension_card.dart';

ExtensionCard _card({CardState state = CardState.form}) => ExtensionCard(
      id: 'j1_0',
      extensionId: ExtensionForms.archiver,
      updatedAt: DateTime(2026, 11, 14, 10),
      state: state,
      values: <String, Object?>{
        'action': ExtensionForms.zip,
        'files': <JobFile>[
          const JobFile(path: '/home/u/отчёт.txt', name: 'отчёт.txt'),
          const JobFile(
            path: 'files/session-1/m_1-0.png',
            name: 'кот.png',
            attachment: true,
          ),
        ],
      },
    );

Object? _roundTrip(Object? json) => jsonDecode(jsonEncode(json));

void main() {
  test('JSON туда и обратно', () {
    final card = _card(state: CardState.done)
      ..outputs = <String>['/home/u/отчёт.zip']
      ..outputDir = '/home/u'
      ..listing = <String>['a.txt · 3 Б']
      ..listingMore = 4;
    final back = ExtensionCard.fromJson(_roundTrip(card.toJson()))!;
    expect(back.id, 'j1_0');
    expect(back.extensionId, ExtensionForms.archiver);
    expect(back.state, CardState.done);
    expect(back.choice('action'), ExtensionForms.zip);
    expect(back.files(), card.files());
    expect(back.files()[1].attachment, isTrue);
    expect(back.outputs, card.outputs);
    expect(back.outputDir, '/home/u');
    expect(back.listing, card.listing);
    expect(back.listingMore, 4);
    expect(back.known, isTrue);
  });

  test('шла задача — после перезапуска «Прервано», временные пути целы', () {
    final card = _card(state: CardState.running)
      ..cleanup = <String>['/home/u/.отчёт.zip.j1_0.part']
      ..progress = 0.4
      ..stage = 'Сжатие';
    final json = card.toJson();
    expect(json.containsKey('progress'), isFalse);
    expect(json.containsKey('stage'), isFalse);
    final back = ExtensionCard.fromJson(_roundTrip(json))!;
    expect(back.state, CardState.interrupted);
    expect(back.state.retryable, isTrue);
    expect(back.cleanup, <String>['/home/u/.отчёт.zip.j1_0.part']);
    expect(back.progress, isNull);
  });

  test('форма остаётся формой, конечные состояния — как есть', () {
    for (final state in <CardState>[
      CardState.form,
      CardState.failed,
      CardState.cancelled,
      CardState.interrupted,
    ]) {
      final back = ExtensionCard.fromJson(
        _roundTrip(_card(state: state).toJson()),
      )!;
      expect(back.state, state);
    }
  });

  test('неизвестное расширение — карточка только для чтения', () {
    final json = _card().toJson()..['ext'] = 'future_thing';
    final back = ExtensionCard.fromJson(_roundTrip(json))!;
    expect(back.known, isFalse);
    expect(ExtensionForms.blocker(back, JobPlatform.linux), isNotNull);
  });

  test('повреждённые записи и опасные строки не проходят', () {
    expect(ExtensionCard.fromJson('x'), isNull);
    expect(ExtensionCard.fromJson(<String, Object?>{'id': '../x'}), isNull);
    final json = _card().toJson()
      ..['values'] = <String, Object?>{
        'action': 'zip\u202e\u0007',
        'files': <Object?>[
          <String, Object?>{'path': '/a\u202eb', 'name': 'x'},
          <String, Object?>{'path': '/ok', 'name': 'имя\u200f\nфайла'},
          'мусор',
        ],
        'BAD KEY': 'x',
      }
      ..['outputs'] = <Object?>['/ok.zip', '/bad\u0000.zip', 7]
      ..['error'] = 'disk; rm -rf';
    final back = ExtensionCard.fromJson(_roundTrip(json))!;
    expect(back.choice('action'), 'zip');
    expect(back.files().single.path, '/ok');
    expect(back.files().single.name, 'имя файла');
    expect(back.values.containsKey('BAD KEY'), isFalse);
    expect(back.outputs, <String>['/ok.zip']);
    expect(back.errorCode, isNull);
  });

  test('ChatMessage.job: в JSON и во всех копиях сообщения', () {
    final card = _card();
    final message = ChatMessage(
      id: 'm_1',
      author: ChatAuthor.persona,
      personaId: 'rio',
      text: 'Карточка ниже',
      timestamp: DateTime(2026, 11, 14),
      job: card,
    );
    expect(message.copyAs('m_2').job, same(card));
    expect(message.withLink(null).job, same(card));
    expect(message.withText('другой').job, same(card));
    final back = ChatMessage.fromJson(_roundTrip(message.toJson()))!;
    expect(back.job?.id, 'j1_0');
    expect(back.job?.files(), card.files());
    final plain = ChatMessage.fromJson(
      _roundTrip(
        ChatMessage(
          id: 'm_3',
          author: ChatAuthor.user,
          text: 'x',
          timestamp: DateTime(2026),
        ).toJson(),
      ),
    )!;
    expect(plain.job, isNull);
  });

  test('«Запустить» неактивна без файлов и с неподходящим действием', () {
    final empty = ExtensionCard(
      id: 'j1_1',
      extensionId: ExtensionForms.archiver,
      updatedAt: DateTime(2026),
      values: <String, Object?>{'action': ExtensionForms.extract},
    );
    expect(ExtensionForms.blocker(empty, JobPlatform.linux), 'Добавьте файлы');
    empty.setValue('files', <JobFile>[
      const JobFile(path: '/a.txt', name: 'a.txt'),
    ]);
    expect(
      ExtensionForms.blocker(empty, JobPlatform.linux),
      'Нужен ровно один файл .zip',
    );
    empty.setValue('files', <JobFile>[
      const JobFile(path: '/a.zip', name: 'a.zip'),
    ]);
    expect(ExtensionForms.blocker(empty, JobPlatform.linux), isNull);
    empty.setValue('action', null);
    expect(ExtensionForms.blocker(empty, JobPlatform.linux), isNotNull);
  });
}
