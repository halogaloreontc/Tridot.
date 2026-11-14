import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/personas/persona.dart';
import 'package:local_assistant/core/personas/persona_names.dart';

void main() {
  final cast = const PersonaSettings().cast;

  String? check(String name, [String id = 'noda', PersonaCast? on]) =>
      PersonaNames.validate(name, id, on ?? cast);

  group('отклоняется', () {
    test('пустое имя', () {
      expect(check(''), 'Имя не может быть пустым.');
      expect(check('   '), 'Имя не может быть пустым.');
    });

    test('длиннее 24 знаков', () {
      expect(check('А' * 24), isNull);
      expect(check('А' * 25), contains('длиннее 24 знаков'));
    });

    for (final name in <String>[
      'Нода2',
      'R2-D2',
      'Мира!',
      'Мира,',
      'Анна  Мария',
      '-Мира',
      'Мира-',
      'Мира_Ника',
      '🙂',
      // Имя из нескольких слов: обращение в конце фразы и в просьбах
      // беседы понимает только одно слово.
      'Анна Мария',
      'Мира Ивановна',
    ]) {
      test('знаки: «$name»', () {
        expect(
          check(name),
          'Имя — одно слово: только буквы и дефис, без пробелов.',
        );
      });
    }

    for (final name in <String>[
      'склад',
      'Склад',
      'СКЛАД',
      'Пароли',
      'пароли',
      'СЕЙФ',
      'сейф',
      'Задачи',
      'Калькулятор',
      'Данные',
      'на складе',
      'Почта',
      'Госуслуги',
    ]) {
      test('обращение к подключению: «$name»', () {
        final error = check(name);
        expect(
          error,
          startsWith('Имя «$name» занято обращением к подключению'),
        );
        expect(error, contains('«${name.toLowerCase()}, …» ушла бы не туда'));
      });
    }

    test('пример из спеки', () {
      expect(
        check('Склад'),
        'Имя «Склад» занято обращением к подключению — фраза «склад, …» '
        'ушла бы не туда.',
      );
    });

    for (final (name, id, owner) in <(String, String, String)>[
      ('Лиорио', 'noda', 'Лиорио'),
      ('лио', 'noda', 'Лиорио'),
      ('Liorio', 'sado', 'Лиорио'),
      ('Нода', 'rio', 'Нода'),
      ('Ноду', 'sado', 'Нода'),
      ('нодочка', 'rio', 'Нода'),
      ('Связной', 'rio', 'Связной'),
      ('СВЯЗНАЯ', 'noda', 'Связной'),
      ('Связного', 'rio', 'Связной'),
      ('Svyaznoy', 'noda', 'Связной'),
    ]) {
      test('имя другого помощника: «$name» для $id', () {
        expect(check(name, id), contains('уже у помощника $owner'));
      });
    }

    test('новое имя другого помощника', () {
      final renamed =
          const PersonaSettings(names: <String, String>{'rio': 'Тим'}).cast;
      expect(check('тим', 'noda', renamed), contains('уже у помощника Тим'));
      // Прежнее имя Лиорио после переименования свободно.
      expect(check('Лиорио', 'noda', renamed), isNull);
    });
  });

  test('короче двух букв', () {
    for (final name in <String>['Я', 'И', 'А', 'ж']) {
      expect(check(name), contains('короче 2 букв'), reason: name);
    }
    expect(check('Ая'), isNull);
  });

  // Имя после пробела отрезается от фразы как обращение: помощник
  // «Добавь» забрал бы «добавь задачу хлеб», «Да» — ответы на вопросы.
  for (final name in <String>[
    'Добавь',
    'Напомни',
    'Покажи',
    'Посчитай',
    'Включи',
    'Привет',
    'Спасибо',
    'Отмена',
    'Задача',
    'Ещё',
    'Еще',
    'Да',
    'Нет',
    'Ок',
    'Ага',
    'Угу',
    'Неа',
    'Конечно',
    'Пожалуйста',
    'Пусть',
    'Сколько',
    'Что',
    'Мы',
    'Он',
  ]) {
    test('обычное слово в начале фраз: «$name»', () {
      expect(check(name), contains('обычное слово в начале фраз'));
    });
  }

  group('«ё» и «е» — одна буква', () {
    test('имя другого помощника через «е»', () {
      final renamed =
          const PersonaSettings(names: <String, String>{'rio': 'Алёна'}).cast;
      expect(check('Алена', 'noda', renamed), contains('уже у помощника'));
      expect(check('АЛЁНА', 'noda', renamed), contains('уже у помощника'));
    });

    test('«Ещё» — как «еще»', () {
      expect(check('Ещё'), contains('обычное слово'));
      expect(check('Еще'), contains('обычное слово'));
    });
  });

  group('принимается', () {
    for (final (name, id) in <(String, String)>[
      ('Мира', 'noda'),
      ('Анна-Мария', 'sado'),
      ('Тим', 'rio'),
      ('Max', 'rio'),
      ('Ёжик', 'noda'),
      // Своё имя и свои формы — можно.
      ('Нода', 'noda'),
      ('Нодочка', 'noda'),
      ('Лио', 'rio'),
      ('Связной', 'sado'),
      // Пробелы по краям обрезаются.
      ('  Мира ', 'noda'),
    ]) {
      test('«$name» для $id', () {
        expect(check(name, id), isNull);
      });
    }
  });

  test('слова подключений в нижнем регистре', () {
    final words = PersonaNames.connectorWords;
    expect(words, containsAll(<String>['склад', 'пароли', 'сейф', 'задачи']));
    expect(words, containsAll(<String>['калькулятор', 'на складе', 'данные']));
    expect(words.every((String w) => w == w.toLowerCase()), isTrue);
  });
}
