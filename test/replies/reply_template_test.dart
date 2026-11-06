import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/replies/reply_template.dart';

String render(
  String source, {
  Map<String, String> values = const <String, String>{},
  ReplyGender gender = ReplyGender.male,
  ReplyAddress address = ReplyAddress.formal,
  bool emoji = true,
}) =>
    ReplyTemplate.parse(source).render(
      values,
      gender: gender,
      address: address,
      emoji: emoji,
    );

void main() {
  group('разметка', () {
    test('подстановки вставляются как есть, без разбора разметки', () {
      expect(
        render('Создал «{title}».', values: <String, String>{'title': '{м:x}'}),
        'Создал «{м:x}».',
      );
      expect(
        ReplyTemplate.parse('{title} на {due}').placeholders,
        <String>{'title', 'due'},
      );
    });

    test('род и обращение', () {
      const source = '{м:Добавил|ж:Добавила}. {вы:Хотите|ты:Хочешь} ещё?';
      expect(render(source), 'Добавил. Хотите ещё?');
      expect(
        render(
          source,
          gender: ReplyGender.female,
          address: ReplyAddress.informal,
        ),
        'Добавила. Хочешь ещё?',
      );
      // Порядок вариантов не важен, пустой вариант допустим.
      expect(
        render('Записал{ж:а|м:}', gender: ReplyGender.female),
        'Записала',
      );
      expect(render('Здравствуй{вы:те|ты:}'), 'Здравствуйте');
    });

    test('подстановка внутри варианта', () {
      expect(
        render(
          '{м:Он нашёл «{q}»|ж:Она нашла «{q}»}',
          values: <String, String>{'q': 'хлеб'},
          gender: ReplyGender.female,
        ),
        'Она нашла «хлеб»',
      );
    });

    test('число: одна, две, пять', () {
      const source = '{n} {мн:n|задача|задачи|задач}';
      String of(int n) => render(source, values: <String, String>{'n': '$n'});
      expect(of(1), '1 задача');
      expect(of(2), '2 задачи');
      expect(of(5), '5 задач');
      expect(of(11), '11 задач');
      expect(of(12), '12 задач');
      expect(of(21), '21 задача');
      expect(of(24), '24 задачи');
      expect(of(111), '111 задач');
    });

    test('скобки {{ и }}', () {
      expect(render('{{как есть}}'), '{как есть}');
    });

    test('эмодзи убираются без двойных пробелов и пробела перед точкой', () {
      expect(render('Готово {э:✅}'), 'Готово ✅');
      expect(render('Готово {э:✅}', emoji: false), 'Готово');
      expect(render('Готово. {э:🎉} Дальше', emoji: false), 'Готово. Дальше');
      expect(render('{э:👋} Привет', emoji: false), 'Привет');
      expect(render('Ура {э:🎉}!', emoji: false), 'Ура!');
      expect(
        render(
          '«{t}» {э:✅}',
          values: <String, String>{'t': 'a  '},
          emoji: false,
        ),
        '«a  »',
        reason: 'значение не трогается',
      );
      expect(ReplyTemplate.parse('Готово {э:✅}').hasEmoji, isTrue);
      expect(ReplyTemplate.parse('Готово').hasEmoji, isFalse);
    });
  });

  group('ошибки разметки', () {
    for (final (source, fragment) in <(String, String)>[
      ('Создал {title', 'не закрыта'),
      ('Создал }', 'лишняя'),
      ('{Title}', 'строчной'),
      ('{м:Создал}', 'ровно два'),
      ('{м:Создал|ж:Создала|м:Ещё}', 'повторяется'),
      ('{м:A|ты:B}', 'ровно два'),
      ('{вы:A}', 'ровно два'),
      ('{пол:A|B}', 'неизвестная метка'),
      ('{м:A {вы:B|ты:C}|ж:D}', 'выбор внутри выбора'),
      ('{мн:n|задача|задачи}', 'три формы'),
      ('{мн:N|a|b|c}', 'не имя'),
      ('Готово ✅', 'вне метки'),
      ('{э:ok}', 'буквы'),
      ('{э: }', 'пустая'),
      ('{a|b}', 'без вида выбора'),
      // Без эмодзи слова слиплись бы: «Готово«Хлеб»».
      ('Готово{э:✅}«{title}»', 'приклеена'),
      ('{title}{э:✅}{name}', 'приклеена'),
      ('{м:Рад{э:🙂}!|ж:Рада}', 'приклеена'),
    ]) {
      test(source, () {
        expect(
          () => ReplyTemplate.parse(source),
          throwsA(
            isA<ReplyFormatException>().having(
              (ReplyFormatException e) => e.message,
              'message',
              contains(fragment),
            ),
          ),
        );
      });
    }

    test('метка эмодзи с пробелом хотя бы с одной стороны — можно', () {
      for (final source in <String>[
        'Готово {э:✅}',
        '{э:👋} Привет',
        'Готово! {э:✅}«{title}»',
        'Готово{э:✅} дальше',
        '{э:🙂}',
      ]) {
        final template = ReplyTemplate.parse(source);
        expect(
          template.render(const <String, String>{'title': 'Х'}, emoji: false),
          isNot(contains('  ')),
          reason: source,
        );
      }
    });

    test('нет значения подстановки — ошибка кода', () {
      expect(
        () => ReplyTemplate.parse('{title}').render(const <String, String>{}),
        throwsArgumentError,
      );
    });
  });
}
