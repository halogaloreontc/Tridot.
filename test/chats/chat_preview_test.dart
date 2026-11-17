// Вторая строка сессии в меню (ADR-010): только ответы помощника, одной
// строкой; карточки и ответы навыков с секретами — нейтральной фразой.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/chats/chat_book.dart';
import 'package:local_assistant/core/chats/chat_models.dart';
import 'package:local_assistant/core/chats/chat_preview.dart';
import 'package:local_assistant/core/models/action_card.dart';
import 'package:local_assistant/core/models/bulk.dart';
import 'package:local_assistant/core/models/secure_card.dart';

final _t = DateTime(2026, 11, 12, 9);

ChatMessage _m(
  String text, {
  ChatAuthor author = ChatAuthor.persona,
  SecureCardRequest? secure,
  ActionCard? card,
  BulkChecklist? checklist,
}) =>
    ChatMessage(
      id: 'm1',
      author: author,
      personaId: author == ChatAuthor.persona ? 'rio' : null,
      text: text,
      timestamp: _t,
      secureCard: secure,
      card: card,
      checklist: checklist,
    );

void main() {
  test('ответ помощника — одной строкой, длинный — с «…»', () {
    expect(
      ChatPreview.of(_m('Принят,\n  но не проведён  ')),
      'Принят, но не проведён',
    );
    final long = ChatPreview.of(_m('а' * 200))!;
    expect(long.length, ChatPreview.limit);
    expect(long.endsWith('…'), isTrue);
    expect(ChatPreview.of(_m('   ')), isNull);
  });

  test('команда пользователя и служебная строка превью не дают', () {
    expect(ChatPreview.of(_m('купить хлеб', author: ChatAuthor.user)), isNull);
    expect(ChatPreview.of(_m('служебное', author: ChatAuthor.system)), isNull);
  });

  test('карточки и секреты — нейтральной фразой', () {
    expect(
      ChatPreview.of(
        _m(
          'Пароль CANARY-7f3a показан',
          secure: const SecureCardRequest(kind: SecureCardKind.reveal),
        ),
      ),
      ChatPreview.secure,
    );
    expect(
      ChatPreview.of(
        _m('CANARY-7f3a', author: ChatAuthor.persona),
        sensitive: true,
      ),
      ChatPreview.secure,
    );
    expect(
      ChatPreview.of(
        _m(
          'Провести приход 318?',
          card: ActionCard(
            rid: 'aaaaaaaaaaaaaaaa',
            connectorId: 'warehouse',
            kind: ActionKind.post,
            login: 'ivanov',
            name: 'Иван',
            deadline: _t.add(const Duration(minutes: 5)),
            lines: const <ActionCardLine>[],
          ),
        ),
      ),
      ChatPreview.action,
    );
    expect(
      ChatPreview.of(
        _m(
          'Отметить приход?',
          checklist: BulkChecklist(
            id: 'b1',
            action: BulkAction.complete,
            selection: const BulkSelection(),
            items: <BulkItem>[BulkItem(taskId: 't1', title: 'Хлеб')],
          ),
        ),
      ),
      ChatPreview.checklist,
    );
  });

  test('длинная строка с эмодзи не режется посреди знака', () {
    final line = ChatPreview.line('${'а' * 78}📦📦📦')!;
    expect(line.endsWith('…'), isTrue);
    final units = line.codeUnits;
    final before = units[units.length - 2];
    expect(before >= 0xD800 && before <= 0xDBFF, isFalse);
    expect(line, contains('📦'));
    final title = ChatBook.sessionTitle('${'б' * 38}📦📦📦');
    expect(title.runes.every((r) => r < 0xD800 || r > 0xDFFF), isTrue);
    expect(title, endsWith('📦…'));
  });
}
