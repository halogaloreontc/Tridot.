// Набрано не в той раскладке (LayoutFix): варианты исправления и правило,
// когда исправленный разбор берётся.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/scenario/layout_fix.dart';
import 'package:local_assistant/core/scenario/route_policy.dart';

void main() {
  test('та же клавиша в русской раскладке', () {
    expect(
      LayoutFix.candidates('yfgjvyb pfdnhf d 10 gjpdjybnm vfvt').first,
      'напомни завтра в 10 позвонить маме',
    );
    expect(LayoutFix.candidates('Gjrf;b pflfxb').first, 'Покажи задачи');
    expect(
      LayoutFix.candidates('hfp,elb vtyz d 6^30').first,
      'разбуди меня в 6:30',
    );
    expect(LayoutFix.candidates('ghb[jls').first, 'приходы');
    expect(LayoutFix.candidates('lf').first, 'да');
    expect(LayoutFix.candidates('xnj&').first, 'что?');
  });

  test(
      '«,» и «.»: на клавиатуре — буквы рядом со словом, на телефоне — '
      'только внутри', () {
    expect(LayoutFix.candidates('yf ytltk.'), <String>[
      'на неделю',
      'на недел.',
    ]);
    expect(LayoutFix.candidates(',elbkmybr').first, 'будильник');
    expect(
      LayoutFix.candidates('pfdnhf, gjpdjybnm').last,
      'завтра, позвонить',
    );
    expect(LayoutFix.candidates('pfdnhf d 10.30').first, 'завтра в 10.30');
    expect(LayoutFix.candidates('pfdnhf d 10:30').first, 'завтра в 10:30');
  });

  test('не трогается', () {
    for (final text in <String>[
      'напомни купить хлеб',
      'купить milk',
      'Qwerty123',
      'https://example.com/a',
      'www.example.com',
      'ivan@example.com',
      'a',
      '12:30',
    ]) {
      expect(LayoutFix.candidates(text), isEmpty, reason: text);
    }
  });

  group('prefer', () {
    ConnectorMatch m(String command, {bool fallback = false}) => ConnectorMatch(
          connectorId: command.split('.').first,
          commandId: command,
          confidence: 0.9,
          fallback: fallback,
        );
    const none = RouteDecision.none();
    RouteDecision win(ConnectorMatch match) => RouteDecision.winner(match);

    test('как есть не понял никто — исправленная команда', () {
      expect(LayoutFix.prefer(none, win(m('task.create'))), isTrue);
      expect(
        LayoutFix.prefer(none, win(m('talk.thanks', fallback: true))),
        isTrue,
      );
    });

    test('справочный вопрос беседы — не повод исправлять', () {
      expect(
        LayoutFix.prefer(none, win(m('talk.question', fallback: true))),
        isFalse,
      );
    });

    test('как есть понято явно — не трогаем', () {
      expect(
        LayoutFix.prefer(win(m('talk.capabilities')), win(m('task.create'))),
        isFalse,
      );
    });

    test('как есть — запасной ответ беседы: только явная команда', () {
      final talk = win(m('talk.question', fallback: true));
      expect(LayoutFix.prefer(talk, win(m('alarm.set'))), isTrue);
      expect(
        LayoutFix.prefer(talk, win(m('talk.thanks', fallback: true))),
        isFalse,
      );
    });
  });
}
