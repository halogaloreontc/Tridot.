// Разговорная обёртка вокруг команды (CommandFrame): что снимается, что
// остаётся и чей разбор берёт маршрутизатор.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/scenario/command_frame.dart';
import 'package:local_assistant/core/scenario/route_policy.dart';

ConnectorMatch _m(
  String connector,
  String command, {
  bool implicit = false,
  bool fallback = false,
}) =>
    ConnectorMatch(
      connectorId: connector,
      commandId: command,
      confidence: 0.9,
      implicit: implicit,
      fallback: fallback,
    );

void main() {
  group('strip', () {
    const cases = <String, String>{
      'так, поставь будильник на 7': 'Поставь будильник на 7',
      'короче, корень из 144': 'Корень из 144',
      'будь добр, покажи пароль от вк': 'Покажи пароль от вк',
      'будьте любезны, покажи пароль от вк': 'Покажи пароль от вк',
      'если тебе не трудно, поставь будильник на 7': 'Поставь будильник на 7',
      'слушай, а сконвертируй видео в mp3': 'Сконвертируй видео в mp3',
      'слышь, где лежит 64115': 'Где лежит 64115',
      'эээ закрой все просроченные': 'Закрой все просроченные',
      'алло напомни в пятницу оплатить интернет':
          'Напомни в пятницу оплатить интернет',
      'плиз, сожми файлы в zip': 'Сожми файлы в zip',
      'давай-ка перенеси встречу на завтра': 'Перенеси встречу на завтра',
      'перенеси-ка встречу на завтра': 'Перенеси встречу на завтра',
      'запиши себе купить хлеб': 'Запиши купить хлеб',
      'где лежит 64115, пожалуйста': 'Где лежит 64115',
      'что умеет склад — спасибо': 'Что умеет склад',
      'а можешь запереть пароли?': 'Запри пароли',
      'не мог бы ты сделать бэкап?': 'Сделай бэкап',
      'а ты можешь поставить таймер на 5 минут?': 'Поставь таймер на 5 минут',
      'так, короче, эээ, удали этот файл': 'Удали этот файл',
      'ДОБАВЬ  кУПИТЬ  молоко': 'ДОБАВЬ купить молоко',
    };
    cases.forEach((String input, String expected) {
      test('«$input»', () => expect(CommandFrame.strip(input), expected));
    });

    test('разговорные формы — словами команд', () {
      const colloquial = <String, String>{
        'кинь напоминалку на завтра позвонить маме':
            'Напомни на завтра позвонить маме',
        'не дай мне забыть позвонить маме': 'Напомни позвонить маме',
        'закинь в задачи купить хлеб': 'Добавь задачу купить хлеб',
        'вычеркни купить хлеб': 'Заверши купить хлеб',
        'перекинь встречу на завтра': 'Перенеси встречу на завтра',
        'поставь будилку на 7': 'Поставь будильник на 7',
        'на 7 будильник поставь': 'Поставь будильник на 7',
        'архив распакуй': 'Распакуй архив',
        'купить хлеб добавь в задачи': 'Добавь задачу купить хлеб',
        'в чём завтра идти на улицу': 'Что надеть завтра',
      };
      colloquial.forEach((String input, String expected) {
        expect(CommandFrame.strip(input), expected, reason: input);
      });
    });

    test('разговорное слово без своего сочетания — как есть', () {
      for (final text in <String>[
        'кинь мяч',
        'перекинь деньги маме',
        'вычеркни',
        'всё, закрой',
        'ну, перенеси',
      ]) {
        expect(
          CommandFrame.strip(text),
          anyOf(isNull, isNot(startsWith('Закрой'))),
          reason: text,
        );
        expect(
          CommandFrame.strip(text),
          isNot(anyOf(startsWith('Добавь'), startsWith('Перенеси д'))),
          reason: text,
        );
      }
      expect(CommandFrame.strip('кинь мяч'), isNull);
      expect(CommandFrame.strip('перекинь деньги маме'), isNull);
      expect(CommandFrame.strip('всё, закрой'), isNull);
    });

    test('не обёртка — фраза как есть', () {
      for (final text in <String>[
        'так держать',
        'короче говоря, отчёт готов',
        'вот это купить',
        'напомни сказать маме спасибо',
        'напомни отправить Олегу спасибо',
        'ну спасибо',
        'спасибо',
        'а можешь рассказать анекдот?',
        'не мог бы ты напомнить мне, как тебя зовут?',
        'можешь сказать, сколько будет 2+2?',
        'добавь задачу «Так, всё проверить»',
        'поставь будильник на 7',
      ]) {
        expect(CommandFrame.strip(text), isNull, reason: text);
      }
    });

    test('«спасибо» в конце без запятой — только у надиктованного', () {
      const text = 'напомни завтра позвонить маме спасибо';
      expect(CommandFrame.strip(text), isNull);
      expect(
        CommandFrame.strip(text, fromVoice: true),
        'Напомни завтра позвонить маме',
      );
      expect(
        CommandFrame.strip('напомни сказать маме спасибо', fromVoice: true),
        isNull,
        reason: '«спасибо» после «сказать» — часть дела',
      );
    });

    test('внутри кавычек ничего не снимается', () {
      expect(CommandFrame.strip('так, «пожалуйста»'), isNull);
      expect(
        CommandFrame.strip(
          'будь добр, добавь задачу «Купить хлеб, пожалуйста»',
        ),
        'Добавь задачу «Купить хлеб, пожалуйста»',
      );
    });
  });

  group('prefer', () {
    const none = RouteDecision.none();
    RouteDecision win(ConnectorMatch m) => RouteDecision.winner(m);

    test('тот же навык той же командой — без обёртки', () {
      expect(
        CommandFrame.prefer(
          win(_m('tasks', 'task.create')),
          win(_m('tasks', 'task.create')),
        ),
        isTrue,
      );
    });

    test('как есть не понял никто — без обёртки, даже беседа', () {
      expect(
        CommandFrame.prefer(
          none,
          win(_m('talk', 'talk.greet', fallback: true)),
        ),
        isTrue,
      );
      expect(CommandFrame.prefer(none, none), isFalse);
    });

    test('явная команда без обёртки сильнее догадки и беседы', () {
      expect(
        CommandFrame.prefer(
          win(_m('talk', 'talk.reaction', fallback: true)),
          win(_m('alarm', 'alarm.set')),
        ),
        isTrue,
      );
    });

    test('догадка без обёртки не вытесняет реплику беседы', () {
      // «ок, всё понял, спасибо!»: без обёртки — «всё понял», сообщение о
      // сделанном.
      expect(
        CommandFrame.prefer(
          win(_m('talk', 'talk.thanks', fallback: true)),
          win(_m('tasks', 'task.complete', implicit: true)),
        ),
        isFalse,
      );
    });

    test('другая явная команда как есть — остаётся', () {
      expect(
        CommandFrame.prefer(
          win(_m('tasks', 'task.create')),
          win(_m('passwords', 'passwords.reveal')),
        ),
        isFalse,
      );
    });
  });
}
