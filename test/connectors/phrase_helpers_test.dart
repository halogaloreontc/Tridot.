import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/person_names.dart';
import 'package:local_assistant/core/connectors/question_phrases.dart';
import 'package:local_assistant/core/connectors/utterance.dart';
import 'package:local_assistant/core/connectors/verb_forms.dart';

void main() {
  group('VerbForms.toInfinitive', () {
    test('правильные глаголы', () {
      expect(VerbForms.toInfinitive('написал'), 'написать');
      expect(VerbForms.toInfinitive('позвонила'), 'позвонить');
      expect(VerbForms.toInfinitive('оплатили'), 'оплатить');
      expect(VerbForms.toInfinitive('умылся'), 'умыться');
      expect(VerbForms.toInfinitive('записалась'), 'записаться');
    });

    test('исключения', () {
      expect(VerbForms.toInfinitive('пошел'), 'пойти');
      expect(VerbForms.toInfinitive('принес'), 'принести');
      expect(VerbForms.toInfinitive('смогла'), 'смочь');
      expect(VerbForms.toInfinitive('съел'), 'съесть');
    });

    test('не глагол — null', () {
      expect(VerbForms.toInfinitive('стол'), isNull);
      expect(VerbForms.toInfinitive('хлеб'), isNull);
      expect(VerbForms.toInfinitive('школа'), isNull);
    });
  });

  group('PersonNames', () {
    test('имена в косвенных падежах — с заглавной', () {
      expect(PersonNames.capitalizeIn('Написать андрею'), 'Написать Андрею');
      expect(PersonNames.capitalizeIn('Встреча с ольгой'), 'Встреча с Ольгой');
      expect(PersonNames.capitalizeIn('Позвонить маше'), 'Позвонить Маше');
      expect(PersonNames.capitalizeIn('Поздравить марию'), 'Поздравить Марию');
      expect(
        PersonNames.capitalizeIn('Забрать у сергея ключи'),
        'Забрать у Сергея ключи',
      );
    });

    test('имена-омонимы — только рядом с глаголом общения или предлогом', () {
      expect(PersonNames.capitalizeIn('Позвонить вере'), 'Позвонить Вере');
      expect(PersonNames.capitalizeIn('Купить марку'), 'Купить марку');
      expect(PersonNames.capitalizeIn('Посадить семена'), 'Посадить семена');
      expect(PersonNames.capitalizeIn('Дочитать роман'), 'Дочитать роман');
      expect(
        PersonNames.capitalizeIn('Встреча с романом'),
        'Встреча с Романом',
      );
    });
  });

  group('QuestionPhrases', () {
    QuestionKind? kind(String text) => QuestionPhrases.detect(
          Utterance.analyze(text, now: DateTime(2026, 11, 2)),
        )?.kind;

    test('вопрос после «напомни», «подскажи»', () {
      expect(
        kind('Нужен напомни пожалуйста какая формула суммы в гугл таблицах?'),
        QuestionKind.info,
      );
      expect(
        kind('подскажи как называется столица австралии'),
        QuestionKind.info,
      );
      expect(kind('не подскажешь где ближайшая аптека'), QuestionKind.info);
      expect(kind('напомни что такое ипотека'), QuestionKind.info);
      expect(kind('напомни что я хотел купить'), QuestionKind.recall);
    });

    test('перевод единиц и валют — честный ответ, а не конвертер', () {
      expect(kind('переведи 5 миль в километры'), QuestionKind.units);
      expect(kind('переведи 320 рублей в доллары'), QuestionKind.units);
      expect(kind('сколько метров в миле'), QuestionKind.units);
      expect(kind('переведи видео в mp3'), isNull);
      expect(kind('напомни перевести 100 долларов в рубли'), isNull);
      expect(
        kind('сколько стульев в ячейке 215-1-1'),
        isNot(QuestionKind.units),
      );
    });

    test('дело, а не вопрос', () {
      expect(kind('напомни купить хлеб'), isNull);
      expect(kind('напомни что надо купить хлеб'), isNull);
      expect(kind('напомни что завтра встреча с андреем'), isNull);
      expect(kind('напомни завтра что я обещал позвонить маме'), isNull);
      expect(kind('как только приду домой напомни позвонить'), isNull);
      expect(kind('как дела у проекта?'), isNull);
      expect(kind('кто ты такой'), isNull);
    });
  });
}
