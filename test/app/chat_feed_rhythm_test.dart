import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/layout.dart';
import 'package:local_assistant/app/widgets/chat_feed_rhythm.dart';

// Ритм ленты — общий у приложения и веб-виджета: таблицы фиксируют
// промежутки, метки времени, повтор имени и «карточку под последним».
void main() {
  final now = DateTime(2026, 3, 12, 15, 30);

  group('метка времени группы', () {
    final cases = <(String, DateTime?, DateTime, bool)>[
      ('первое сообщение', null, DateTime(2026, 3, 12, 14), true),
      (
        'через 15 минут — та же группа',
        DateTime(2026, 3, 12, 14),
        DateTime(2026, 3, 12, 14, 15),
        false,
      ),
      (
        'через 15 минут 1 секунду — новая',
        DateTime(2026, 3, 12, 14),
        DateTime(2026, 3, 12, 14, 15, 1),
        true,
      ),
      (
        'смена дня через минуту — новая',
        DateTime(2026, 3, 11, 23, 59, 30),
        DateTime(2026, 3, 12, 0, 0, 10),
        true,
      ),
    ];
    for (final (name, previous, at, expected) in cases) {
      test(name, () => expect(startsGroup(previous, at), expected));
    }
  });

  group('подпись группы', () {
    final cases = <(DateTime, String)>[
      (DateTime(2026, 3, 12, 14, 5), 'Сегодня, 14:05'),
      (DateTime(2026, 3, 11, 9, 0), 'Вчера, 09:00'),
      (DateTime(2026, 3, 13, 23, 59), 'Завтра, 23:59'),
    ];
    for (final (at, label) in cases) {
      test(label, () => expect(groupTimeLabel(at, now), label));
    }
    test('дальний день — с заглавной и датой', () {
      final label = groupTimeLabel(DateTime(2026, 1, 5, 8, 7), now);
      expect(label, endsWith(', 08:07'));
      expect(label[0], label[0].toUpperCase());
      expect(label, isNot(startsWith('Сегодня')));
    });
    test('время — двумя цифрами', () {
      expect(chatTimeLabel(DateTime(2026, 1, 1, 7, 3)), '07:03');
    });
  });

  group('имя помощника', () {
    final t = DateTime(2026, 3, 12, 14);
    final cases = <(String, String?, bool, String?, DateTime?, DateTime, bool)>[
      ('сообщение пользователя', null, false, 'relay', t, t, false),
      ('новая группа', 'relay', true, 'relay', t, t, true),
      ('первый ответ', 'relay', false, null, null, t, true),
      ('смена автора', 'rio', false, 'relay', t, t, true),
      (
        'тот же автор через 10 минут',
        'relay',
        false,
        'relay',
        t,
        t.add(const Duration(minutes: 10)),
        false,
      ),
      (
        'тот же автор через 10 минут 1 секунду',
        'relay',
        false,
        'relay',
        t,
        t.add(const Duration(minutes: 10, seconds: 1)),
        true,
      ),
    ];
    for (final (name, id, group, lastId, lastAt, at, expected) in cases) {
      test(
        name,
        () => expect(
          showsAuthor(
            authorId: id,
            at: at,
            newGroup: group,
            lastAuthorId: lastId,
            lastReplyAt: lastAt,
          ),
          expected,
        ),
      );
    }
  });

  group('промежуток над сообщением', () {
    // (название, новая группа, от пользователя, выше пользователь,
    //  выше карточка, имя, промежуток)
    final cases = <(String, bool, bool, bool, bool, bool, double)>[
      ('начало группы', true, true, false, true, true, 0),
      ('после карточки', false, true, false, true, false, AppSpace.afterCard),
      ('пузырь за пузырём', false, true, true, false, false, AppSpace.xs),
      ('ответ → пузырь', false, true, false, false, false, AppSpace.toUser),
      ('пузырь → ответ', false, false, true, false, true, AppSpace.toReply),
      (
        'ответ → ответ с именем',
        false,
        false,
        false,
        false,
        true,
        AppSpace.toUser,
      ),
      (
        'ответ → ответ того же автора',
        false,
        false,
        false,
        false,
        false,
        AppSpace.toReply,
      ),
    ];
    for (final (name, group, user, prevUser, card, author, gap) in cases) {
      test(
        name,
        () => expect(
          feedTopGap(
            newGroup: group,
            fromUser: user,
            previousFromUser: prevUser,
            previousHadCard: card,
            showAuthor: author,
          ),
          gap,
        ),
      );
    }
  });

  group('карточка — под последним', () {
    test('индекс последнего с каждым id, без null', () {
      final ids = <String?>['a', null, 'b', 'a', null, 'b', 'c'];
      expect(
        lastIndexById(ids, (String? id) => id),
        <String, int>{'a': 3, 'b': 5, 'c': 6},
      );
    });
    test('пустая лента', () {
      expect(lastIndexById(<String?>[], (String? id) => id), isEmpty);
    });
  });

  group('проход по ленте', () {
    test('группы, имена и промежутки по порядку', () {
      final t = DateTime(2026, 3, 12, 14);
      final rhythm = ChatFeedRhythm();
      expect(rhythm.isEmpty, isTrue);
      expect(rhythm.working(authorId: 'relay').topGap, 0);

      final beats = <FeedBeat>[];
      void add(int minutes, {String? author, bool card = false}) {
        beats.add(
          rhythm.next(
            at: t.add(Duration(minutes: minutes)),
            fromUser: author == null,
            authorId: author,
          ),
        );
        rhythm.placed(hadCard: card);
      }

      add(0); // пузырь — начало группы
      add(1, author: 'relay'); // первый ответ: имя
      add(2, author: 'relay', card: true); // тот же автор, без имени
      add(3); // после карточки
      add(4); // пузырь за пузырём
      add(5, author: 'rio'); // смена автора
      add(30, author: 'rio'); // пауза — новая группа

      expect(
        beats.map((FeedBeat b) => b.newGroup),
        <bool>[true, false, false, false, false, false, true],
      );
      expect(
        beats.map((FeedBeat b) => b.showAuthor),
        <bool>[false, true, false, false, false, true, true],
      );
      expect(beats.map((FeedBeat b) => b.topGap), <double>[
        0,
        AppSpace.toReply,
        AppSpace.toReply,
        AppSpace.afterCard,
        AppSpace.xs,
        AppSpace.toReply,
        0,
      ]);
      expect(rhythm.lastAuthorId, 'rio');

      final same = rhythm.working(authorId: 'rio');
      expect(same.newGroup, isFalse);
      expect(same.showAuthor, isFalse);
      expect(same.topGap, AppSpace.toReply);
      expect(rhythm.working(authorId: 'relay').showAuthor, isTrue);
      expect(rhythm.working().showAuthor, isFalse);
    });

    test('ответ неизвестного помощника не сбрасывает автора', () {
      final t = DateTime(2026, 3, 12, 14);
      final rhythm = ChatFeedRhythm()
        ..next(at: t, fromUser: false, authorId: 'relay');
      final unknown = rhythm.next(
        at: t.add(const Duration(minutes: 1)),
        fromUser: false,
      );
      expect(unknown.showAuthor, isFalse);
      expect(unknown.topGap, AppSpace.toReply);
      expect(rhythm.lastAuthorId, 'relay');
    });
  });
}
