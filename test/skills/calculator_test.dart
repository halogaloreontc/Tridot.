import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/connectors/connector.dart';
import 'package:local_assistant/core/connectors/tasks_connector.dart';
import 'package:local_assistant/core/scenario/assistant_controller.dart';
import 'package:local_assistant/core/scenario/scenario_parser.dart';
import 'package:local_assistant/core/services/clock.dart';
import 'package:local_assistant/core/services/task_service.dart';
import 'package:local_assistant/core/skills/calculator/calculator.dart';
import 'package:local_assistant/core/skills/calculator/calculator_connector.dart';
import 'package:local_assistant/core/storage/in_memory_task_repository.dart';

/// Сообщение калькулятора с обычными пробелами вместо неразрывных.
String say(String text) => Calculator.calculate(text)
    .message
    .replaceAll(Calculator.groupSeparator, ' ');

void main() {
  group('ответы', () {
    const cases = <String, String>{
      // Порядок действий и знаки.
      'сколько будет 2+2*2': '2 + 2 × 2 = 6',
      '2 + 2 × 2': '2 + 2 × 2 = 6',
      '(2 + 2) * 2': '(2 + 2) × 2 = 8',
      '10 - 2 - 3': '10 − 2 − 3 = 5',
      '10 - (2 - 3)': '10 − (2 − 3) = 11',
      '100 / 10 / 2': '100 / 10 / 2 = 5',
      '12 ÷ 4': '12 / 4 = 3',
      '10 : 4': '10 / 4 = 2,5',
      '7 × 8': '7 × 8 = 56',
      '7·8': '7 × 8 = 56',
      '3 х 4': '3 × 4 = 12',
      '2 ** 3': '2^3 = 8',
      '-5 + 3': '−5 + 3 = −2',
      '−5 − 3': '−5 − 3 = −8',
      '2 * -3': '2 × −3 = −6',
      '-(2 + 3)': '−(2 + 3) = −5',
      '((((1 + 1))))': '1 + 1 = 2',
      // Десятичные: запятая и точка, точный счёт.
      '3,5 умножить на 12': '3,5 × 12 = 42',
      '3.5 * 2': '3,5 × 2 = 7',
      '0,1 + 0,2': '0,1 + 0,2 = 0,3',
      'сколько будет 1/8': '1 / 8 = 0,125',
      '1 / 8': '1 / 8 = 0,125',
      '1/3*3': '1 / 3 × 3 = 1',
      '10 / 3': '10 / 3 ≈ 3,333333333',
      '2 / 3': '2 / 3 ≈ 0,6666666667',
      '1 / 7': '1 / 7 ≈ 0,1428571429',
      '1 000 000 / 4': '1 000 000 / 4 = 250 000',
      '1 000 000 / 7': '1 000 000 / 7 ≈ 142 857,1429',
      '0.000001 / 3': '0,000001 / 3 ≈ 3,333333333 × 10^−7',
      '10^20 / 3': '10^20 / 3 ≈ 3,333333333 × 10^19',
      '123456789 * 987654321':
          '123 456 789 × 987 654 321 = 121 932 631 112 635 269',
      // Степени и корни.
      'вычисли 2^10': '2^10 = 1 024',
      '2^-2': '2^−2 = 0,25',
      '(-2)^2': '(−2)^2 = 4',
      '-2^2': '−2^2 = −4',
      '(-2)^3': '(−2)^3 = −8',
      '2^3^2': '2^3^2 = 512',
      '0^0': '0^0 = 1',
      '1^5000': '1^5 000 = 1',
      '(-1)^5001': '(−1)^5 001 = −1',
      '2 в квадрате': '2² = 4',
      '5 в кубе': '5³ = 125',
      '2 в степени 8': '2^8 = 256',
      '(1/2) в квадрате': '(1 / 2)² = 0,25',
      'корень из 144': '√144 = 12',
      'квадратный корень из 16 + 9': '√16 + 9 = 13',
      'корень из (16 + 9)': '√(16 + 9) = 5',
      '√81': '√81 = 9',
      'корень из 0,25': '√0,25 = 0,5',
      'корень из 2': '√2 ≈ 1,414213562',
      // «корень из 1/4» словами — корень из дроби; знак «√» — по правилам.
      'корень из 1/4': '√(1 / 4) = 0,5',
      'корень из 1/4 + 1': '√(1 / 4) + 1 = 1,5',
      '√1/4': '√1 / 4 = 0,25',
      '4^0,5': '4^0,5 ≈ 2',
      '2^0,5': '2^0,5 ≈ 1,414213562',
      // Проценты.
      '15% от 2400': '15% от 2 400 = 360',
      'сколько будет 15% от 2400': '15% от 2 400 = 360',
      '15 процентов от 2400': '15% от 2 400 = 360',
      '2400 плюс 15%': '2 400 + 15% = 2 760',
      '2400 + 15%': '2 400 + 15% = 2 760',
      '2400 минус 10%': '2 400 − 10% = 2 160',
      '200 * 5%': '200 × 5% = 10',
      'посчитай 15%': '15% = 0,15',
      // Слова.
      'два плюс два': '2 + 2 = 4',
      'ноль плюс один': '0 + 1 = 1',
      'десять минус три': '10 − 3 = 7',
      'двадцать пять умножить на четыре': '25 × 4 = 100',
      'сто разделить на восемь': '100 / 8 = 12,5',
      'сто двадцать минус пять': '120 − 5 = 115',
      'две тысячи плюс один': '2 000 + 1 = 2 001',
      'тысяча делить на 4': '1 000 / 4 = 250',
      'девяносто девять плюс один': '99 + 1 = 100',
      '7 умножь на 6': '7 × 6 = 42',
      '7 помножить на 6': '7 × 6 = 42',
      '81 поделить на 9': '81 / 9 = 9',
      'умножить 3 на 4': '3 × 4 = 12',
      'раздели 10 на 4': '10 / 4 = 2,5',
      'умножь 2 + 3 на 4': '(2 + 3) × 4 = 20',
      'минус 5 плюс 3': '−5 + 3 = −2',
      // Маркеры и хвосты.
      'посчитай (10 + 5) / 3': '(10 + 5) / 3 = 5',
      'Посчитайте, пожалуйста, 6 * 7': '6 × 7 = 42',
      'реши 100 - 37': '100 − 37 = 63',
      'вычисли: 9 * 9': '9 × 9 = 81',
      '2+2=': '2 + 2 = 4',
      '2+2 = ?': '2 + 2 = 4',
      '2+2 равно?': '2 + 2 = 4',
      'чему равно 7*8': '7 × 8 = 56',
      'сколько 5 + 5?': '5 + 5 = 10',
      'А сколько будет 2 + 2?': '2 + 2 = 4',
      'посчитай 18:30': '18 / 30 = 0,6',
    };
    for (final entry in cases.entries) {
      test(entry.key, () => expect(say(entry.key), entry.value));
    }
    test('случаев не меньше 60', () => expect(cases.length, greaterThan(60)));
  });

  group('большие числа в приближённом счёте (2^127 и больше)', () {
    // Раньше Rational.toDouble() считал 2^−shift целым math.pow и
    // переполнялся: «≈ 0» и «из отрицательного» для положительных чисел.
    const cases = <String, String>{
      'корень из 10^101': '√(10^101) ≈ 3,16227766 × 10^50',
      'корень из 10^39': '√(10^39) ≈ 3,16227766 × 10^19',
      'корень из (2^127)': '√(2^127) ≈ 1,304381783 × 10^19',
      '2^127 * 2^0,5': '2^127 × 2^0,5 ≈ 2,406159692 × 10^38',
      '(10^40)^0,5': '(10^40)^0,5 ≈ 1 × 10^20',
      '10^40 * 2^0,5': '10^40 × 2^0,5 ≈ 1,414213562 × 10^40',
      '2^1000 * 2^0,5': '2^1 000 × 2^0,5 ≈ 1,515342004 × 10^301',
      '2^126 * 2^0,5': '2^126 × 2^0,5 ≈ 1,203079846 × 10^38',
      '1 / 10^400 * 2^0,5': '1 / 10^400 × 2^0,5 ≈ 0',
    };
    for (final entry in cases.entries) {
      test(entry.key, () => expect(say(entry.key), entry.value));
    }

    test('Rational.toDouble: большие, малые и отрицательные', () {
      final two = BigInt.two;
      expect(Rational(two.pow(127)).toDouble(), 1.7014118346046923e38);
      expect(Rational(-two.pow(200)).toDouble(), -1.6069380442589903e60);
      expect(
        Rational(BigInt.one, two.pow(200)).toDouble(),
        6.223015277861142e-61,
      );
      expect(Rational(BigInt.from(10).pow(400)).toDouble(), double.infinity);
      expect(
        Rational(BigInt.one, BigInt.from(3)).toDouble(),
        closeTo(1 / 3, 1e-16),
      );
    });

    test('за пределами double — «слишком большое число»', () {
      expect(say('корень из 10^400'), startsWith('√(10^400) = 1'));
      expect(say('10^400 * 2^0,5'), contains('слишком большое число'));
    });
  });

  group('предел 1000 цифр', () {
    const big = 'Получается слишком большое число — такое не посчитаю.';
    test('1001 цифра — слишком большое', () {
      expect(say('10^1000'), big);
      expect(say('(10^500)^2'), big);
      expect(say('10^-1000'), big);
    });
    test('ровно 1000 цифр — считается', () {
      final answer = Calculator.calculate('10^999').value!;
      expect(answer.replaceAll(Calculator.groupSeparator, '').length, 1000);
      expect(say('10^-999'), '10^−999 = 1 × 10^−999');
    });
  });

  group('конечные дроби длиннее 20 знаков — точно, без «≈»', () {
    const cases = <String, String>{
      '10^-21': '10^−21 = 1 × 10^−21',
      '1/2^21': '1 / 2^21 = 4,76837158203125 × 10^−7',
      '3 × 10^-25': '3 × 10^−25 = 3 × 10^−25',
      // Конечная, но больше 20 значащих цифр — округляем честно, с «≈».
      '1/2^100': '1 / 2^100 ≈ 7,888609052 × 10^−31',
    };
    for (final entry in cases.entries) {
      test(entry.key, () => expect(say(entry.key), entry.value));
    }
  });

  group('естественные формы процентов, слов и знаков', () {
    const cases = <String, String>{
      '-15% от 200': '−(15% от 200) = −30',
      'минус 15% от 200': '−(15% от 200) = −30',
      '10 * 15% от 2400': '10 × (15% от 2 400) = 3 600',
      '2400 / 15% от 200': '2 400 / (15% от 200) = 80',
      'двадцать пять процентов от двухсот': '25% от 200 = 50',
      '10% от трехсот': '10% от 300 = 30',
      'корень из шестнадцати': '√16 = 4',
      'корень из ста': '√100 = 10',
      'корень из двадцати пяти': '√25 = 5',
      'сколько будет 1 — 2': '1 − 2 = −1',
      '2,5:0,5': '2,5 / 0,5 = 5',
      '100:4': '100 / 4 = 25',
      '-(-3)': '−(−3) = 3',
      '--3': '−(−3) = 3',
      '10 - 15': '10 − 15 = −5',
      '24 / 7': '24 / 7 ≈ 3,428571429',
      '2+10/5': '2 + 10 / 5 = 4',
      'посчитай 24/7': '24 / 7 ≈ 3,428571429',
      'посчитай 64115-01': '64 115 − 1 = 64 114',
    };
    for (final entry in cases.entries) {
      test(entry.key, () => expect(say(entry.key), entry.value));
    }
  });

  group('длинные сообщения не тормозят разбор', () {
    test('ряд точек и вопросов — быстро и не пример', () {
      final watch = Stopwatch()..start();
      expect(Calculator.recognize('Список дел${'.' * 20000} конец'), isNull);
      expect(Calculator.recognize('${'?' * 100000}x'), isNull);
      expect(Calculator.recognize('2+2${'.' * 50000}'), isNull);
      expect(watch.elapsedMilliseconds, lessThan(500));
    });

    test('длинный пример с маркером — «слишком длинный»', () {
      final r = Calculator.recognize('посчитай 2+2${'.' * 50000}')!;
      expect(r.failure, CalcFailure.tooLong);
      expect(Calculator.recognize('посчитай что-нибудь${'.' * 300}'), isNull);
    });
  });

  group('ошибки и пределы', () {
    test('деление на ноль', () {
      expect(say('10 / 0'), 'На ноль делить нельзя.');
      expect(say('5 / (2 - 2)'), 'На ноль делить нельзя.');
      expect(say('0^-1'), 'На ноль делить нельзя.');
      expect(say('2 / 0%'), 'На ноль делить нельзя.');
    });

    test('слишком большое число', () {
      const big = 'Получается слишком большое число — такое не посчитаю.';
      expect(say('2^5000'), big);
      expect(say('2^1001'), big);
      expect(say('10^999 * 10^999'), big);
      expect(say('2^1000'), startsWith('2^1 000 = 10 715 086'));
    });

    test('корень из отрицательного и дробная степень отрицательного', () {
      expect(
        say('корень из -4'),
        'Квадратный корень из отрицательного числа не извлекается.',
      );
      expect(say('(-8)^(1/3)'), contains('не определено'));
    });

    test('длинный пример и глубокие скобки', () {
      final long = 'посчитай ${List<String>.filled(120, '1').join('+')}';
      expect(long.length, greaterThan(Calculator.maxLength));
      expect(say(long), contains('Слишком длинный пример'));
      expect(Calculator.recognize(long.substring(9)), isNull);
      final deep = 'посчитай ${'(' * 21}1${')' * 21}';
      expect(say(deep), contains('Слишком много вложенных скобок'));
      final ok = '${'(' * 20}1 + 1${')' * 20}';
      expect(say(ok), '1 + 1 = 2');
    });

    test('неполный пример с маркером — уточнение', () {
      expect(say('сколько будет 2 +'), Calculator.malformedMessage);
      expect(say('посчитай 5 коробок'), Calculator.malformedMessage);
      expect(say('посчитай (2 + 3'), Calculator.malformedMessage);
      expect(say('посчитай 5 от 10'), Calculator.malformedMessage);
    });
  });

  group('не примеры', () {
    for (final text in <String>[
      '12.11',
      '12.11.2026',
      '2026-11-05',
      '18:30',
      'в 10',
      'в 18:30',
      '64115',
      'где лежит 64115',
      '10-15 минут',
      '2-3 дня',
      '+7 999 123-45-67',
      '8-800-555-35-35',
      '123-45-67',
      '8 (999) 123-45-67',
      '2.10',
      'обновить до версии 2.10',
      '#2',
      'купить 2 кг муки',
      'добавь задачу 2+2',
      'через 2 часа',
      'A-03-2',
      '64115 где лежит',
      'пять',
      '100%',
      'минус 5',
      'реши задачу',
      'сколько задач',
      'сколько стоит хлеб',
      'посчитай что-нибудь',
      'сколько 5',
      '+',
      '-',
      '1, 2, 3',
      'привет',
      'один из вариантов',
      'Добавь «2+2» на завтра',
      'разделить торт на 8 частей',
      'умножить усилия на два',
      // Целые через «-» или «/» вплотную — коды, диапазоны, даты.
      '64115-01',
      '64115/2',
      '12-345',
      '123-4567',
      '555-1234',
      '999 123-45',
      '10-15',
      '10–15',
      '10—15',
      '2-3',
      '05/11/2026',
      '12/11',
      '24/7',
      '1/8',
      '9:05',
      '-3',
    ]) {
      test(text, () => expect(Calculator.recognize(text), isNull));
    }
  });

  group('CalculatorConnector', () {
    const connector = CalculatorConnector();
    final now = DateTime(2026, 11, 5, 12);
    Utterance u(String text) => Utterance.analyze(text, now: now);

    test('паспорт: навык, встроен, включён по умолчанию', () {
      expect(connector.info.id, 'calc');
      expect(connector.info.kind, ExtensionKind.skill);
      expect(connector.info.defaultEnabled, isTrue);
      expect(connector.info.required, isFalse);
      expect(connector.info.requiresNetwork, isFalse);
    });

    test('каждый пример из паспорта распознаётся', () {
      for (final example in connector.info.examples) {
        expect(connector.match(u(example)), isNotNull, reason: example);
      }
    });

    test('уверенность: маркер 0.9, выражение 0.85, неполный 0.45', () {
      expect(connector.match(u('сколько будет 2+2'))!.confidence, 0.9);
      expect(connector.match(u('2+2'))!.confidence, 0.85);
      final malformed = connector.match(u('посчитай 5 коробок'))!;
      expect(malformed.confidence, 0.45);
      expect(malformed.implicit, isTrue);
    });

    test('ответы и статусы', () async {
      final session = AssistantSession(clock: FixedClock(now));
      Future<AssistantResponse> run(String text) =>
          connector.run(connector.match(u(text))!, session);
      var response = await run('2+2*2');
      expect(response.message, '2 + 2 × 2 = 6');
      expect(response.intent, 'calc.evaluate');
      expect(response.status, AssistantStatus.completed);
      response = await run('10 / 0');
      expect(response.status, AssistantStatus.noAction);
      response = await run('посчитай 5 коробок');
      expect(response.status, AssistantStatus.needsClarification);
    });

    test('вместе с задачами: примеры — калькулятору, задачи — задачам',
        () async {
      final clock = FixedClock(now);
      final tasks = TaskService(
        repository: InMemoryTaskRepository(),
        clock: clock,
      );
      final assistant = AssistantController(
        connectors: <Connector>[
          TasksConnector(
            taskService: tasks,
            parser: ScenarioParser(clock: clock),
          ),
          connector,
        ],
        clock: clock,
      );
      var response = await assistant.handle('сколько будет 15% от 2400');
      expect(response.message, '15% от 2 400 = 360');
      response = await assistant.handle('умножить 3 на 4');
      expect(response.message, '3 × 4 = 12');
      response = await assistant.handle('3 умножить на 4');
      expect(response.message, '3 × 4 = 12');
      response = await assistant.handle('добавь задачу 2+2');
      expect(response.intent, 'task.create');
      response = await assistant.handle('купить 2 кг муки');
      expect(response.intent, 'task.create');
      expect(
        (await tasks.listActive()).map((t) => t.title),
        <String>['2+2', 'Купить 2 кг муки'],
      );
    });
  });
}
