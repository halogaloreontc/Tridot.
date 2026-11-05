import 'dart:math' as math;

import 'rational.dart';

export 'rational.dart' show Rational;

/// Почему пример не посчитан.
enum CalcFailure {
  /// Пример не разобран: лишние слова, незакрытая скобка.
  malformed,

  /// Деление на ноль (в том числе ноль в отрицательной степени).
  divisionByZero,

  /// Слишком большое число: длинная степень, больше 1000 цифр.
  tooBig,

  /// Квадратный корень из отрицательного числа.
  negativeRoot,

  /// Результат не определён: отрицательное число в дробной степени.
  undefined,

  /// Пример длиннее [Calculator.maxLength] символов.
  tooLong,

  /// Скобки вложены глубже [Calculator.maxDepth].
  tooDeep,
}

/// Разобранный пример: дерево выражения.
sealed class CalcNode {
  const CalcNode();

  /// Приоритет для расстановки скобок при выводе.
  int get _precedence;
}

/// Число из примера (цифрами или словами).
final class CalcNumber extends CalcNode {
  const CalcNumber(this.value);

  final Rational value;

  @override
  int get _precedence => 6;
}

/// Смена знака: «−5», «минус (2 + 3)».
final class CalcNegate extends CalcNode {
  const CalcNegate(this.operand);

  final CalcNode operand;

  @override
  int get _precedence => 3;
}

enum CalcOperator { add, subtract, multiply, divide }

/// Двухместная операция.
final class CalcBinary extends CalcNode {
  const CalcBinary(this.operator, this.left, this.right);

  final CalcOperator operator;
  final CalcNode left;
  final CalcNode right;

  @override
  int get _precedence => switch (operator) {
        CalcOperator.add || CalcOperator.subtract => 1,
        CalcOperator.multiply || CalcOperator.divide => 2,
      };
}

/// Проценты: «15%». Смысл зависит от соседей: «2400 + 15%» — прибавить
/// 15 % от 2400, «15% от 2400» — доля, одно «15%» — 0,15.
final class CalcPercent extends CalcNode {
  const CalcPercent(this.operand);

  final CalcNode operand;

  @override
  int get _precedence => 5;
}

/// «X% от Y».
final class CalcPercentOf extends CalcNode {
  const CalcPercentOf(this.percent, this.base);

  final CalcPercent percent;
  final CalcNode base;

  @override
  int get _precedence => 2;
}

/// Степень: «2^10», «5 в квадрате» ([CalcPower.square]).
final class CalcPower extends CalcNode {
  const CalcPower(
    this.base,
    this.exponent, {
    this.style = CalcPowerStyle.caret,
  });

  final CalcNode base;
  final CalcNode exponent;
  final CalcPowerStyle style;

  @override
  int get _precedence => style == CalcPowerStyle.caret ? 4 : 5;
}

enum CalcPowerStyle { caret, square, cube }

/// Квадратный корень.
final class CalcSqrt extends CalcNode {
  const CalcSqrt(this.operand);

  final CalcNode operand;

  @override
  int get _precedence => 5;
}

/// Как калькулятор понял сообщение: есть ли слово-маркер и что за пример.
final class CalcRecognition {
  const CalcRecognition({
    required this.explicit,
    required this.expression,
    this.failure,
  });

  /// В сообщении есть маркер: «сколько будет», «посчитай», «= ?», «равно».
  final bool explicit;

  /// Разобранное выражение или `null`, если разобрать не удалось.
  final CalcNode? expression;

  /// Почему не разобрано: [CalcFailure.malformed], [CalcFailure.tooLong],
  /// [CalcFailure.tooDeep].
  final CalcFailure? failure;

  /// В примере есть действие: операция, корень, степень, «% от».
  bool get hasOperation =>
      expression != null && Calculator._hasOperation(expression!);
}

/// Результат счёта.
final class CalcResult {
  const CalcResult._({
    required this.expression,
    this.value,
    this.approximate = false,
    this.failure,
  });

  /// Пример в обычной записи: «2 + 2 × 2». Пусто, если не разобран.
  final String expression;

  /// Ответ в русской записи: «6», «3,333333333», «2 400».
  final String? value;

  /// Ответ округлён: десятичная дробь бесконечна или счёт приближённый.
  final bool approximate;

  final CalcFailure? failure;

  bool get ok => failure == null;

  /// Ответ без примера: «6», «≈ 3,333333333» или текст ошибки.
  String get answer => ok
      ? (approximate ? '≈ $value' : value!)
      : Calculator.failureMessage(failure!);

  /// Сообщение пользователю: «2 + 2 × 2 = 6», «10 / 3 ≈ 3,333333333».
  String get message =>
      ok ? '$expression ${approximate ? '≈' : '='} $value' : answer;
}

/// Значение при счёте: точное или приближённое.
sealed class _Value {
  const _Value();
}

final class _Exact extends _Value {
  const _Exact(this.value);

  final Rational value;
}

final class _Approx extends _Value {
  const _Approx(this.value);

  final double value;
}

final class _CalcError implements Exception {
  const _CalcError(this.failure);

  final CalcFailure failure;
}

/// Калькулятор: свой разбор примера и точный счёт, без выполнения кода.
///
/// Понимает цифры с запятой или точкой, `+ - * / × ÷ : ^`, скобки, унарный
/// минус, `%`, слова («плюс», «умножить на», «корень из», «в квадрате»,
/// «15% от 2400», числа «ноль»…«тысяча») и маркеры («сколько будет»,
/// «посчитай», «вычисли», «реши», «… равно?», «=» в конце).
abstract final class Calculator {
  /// Длиннее — не считаем: защита от злоупотребления.
  static const int maxLength = 200;

  /// Наибольшая глубина скобок.
  static const int maxDepth = 20;

  /// Наибольший целый показатель степени по модулю.
  static const int maxExponent = 1000;

  /// Наибольшее число цифр в числителе или знаменателе результата.
  static const int maxDigits = 1000;

  /// Сколько значащих цифр показывать у округлённого ответа.
  static const int significantDigits = 10;

  /// Неразрывный пробел между разрядами: «2 400».
  static const String groupSeparator = ' ';

  static const String malformedMessage =
      'Не понял пример. Например: «сколько будет 15% от 2400».';

  static String failureMessage(CalcFailure failure) => switch (failure) {
        CalcFailure.malformed => malformedMessage,
        CalcFailure.divisionByZero => 'На ноль делить нельзя.',
        CalcFailure.tooBig =>
          'Получается слишком большое число — такое не посчитаю.',
        CalcFailure.negativeRoot =>
          'Квадратный корень из отрицательного числа не извлекается.',
        CalcFailure.undefined =>
          'Так не посчитать: отрицательное число в дробной степени '
              'не определено.',
        CalcFailure.tooLong =>
          'Слишком длинный пример: не больше $maxLength символов.',
        CalcFailure.tooDeep =>
          'Слишком много вложенных скобок: не больше $maxDepth.',
      };

  /// Разбирает сообщение. `null` — сообщение не похоже на пример: в нём
  /// нет ни маркера, ни выражения целиком (дата, время, телефон, задача).
  static CalcRecognition? recognize(String message) {
    // Длину проверяем до любых регулярных выражений: длинная вставка
    // (список, текст с рядом точек) не должна тормозить разбор каждого
    // сообщения. Смотрим только на начало: есть ли маркер.
    if (message.length > maxLength) return _tooLong(message);
    var text = message.toLowerCase().replaceAll('ё', 'е').trim();
    if (text.isEmpty) return null;
    var explicit = false;

    // Хвост: «?», «=», «равно», «пожалуйста».
    while (true) {
      final match = _tail.firstMatch(text);
      if (match == null || match.group(0)!.isEmpty) break;
      if (match.group(0)!.contains(_tailMarker)) explicit = true;
      text = text.substring(0, match.start).trimRight();
    }
    var weakMarker = false;
    final head = _head.firstMatch(text);
    if (head != null) {
      explicit = true;
      text = text.substring(head.end).trim();
    } else {
      final weak = _weakHead.firstMatch(text);
      if (weak != null) {
        weakMarker = true;
        text = text.substring(weak.end).trim();
      }
    }
    if (text.isEmpty) return null;
    // «Умножить 3 на 4», «раздели 10 на 4»: действие впереди.
    final prefix = _prefixOperation.firstMatch(text);
    if (prefix != null) {
      final sign = prefix.group(1)!.contains('множ') ? '*' : '/';
      text = '(${prefix.group(2)}) $sign (${prefix.group(3)})';
    }
    // Без маркера пример должен выглядеть как пример: без лишних слов.
    final mathLike = _mathLike.hasMatch(text);
    if (!mathLike) return null;

    final List<_Token> tokens;
    try {
      tokens = _Lexer(text).tokenize();
    } on _CalcError catch (error) {
      return explicit
          ? CalcRecognition(
              explicit: true,
              expression: null,
              failure: error.failure,
            )
          : null;
    }
    if (!explicit && _looksLikeNotMath(tokens)) {
      return null;
    }
    CalcNode? node;
    CalcFailure? failure;
    try {
      node = _Parser(tokens).parse();
    } on _CalcError catch (error) {
      failure = error.failure;
    }
    if (node == null) {
      return explicit
          ? CalcRecognition(
              explicit: true,
              expression: null,
              failure: failure ?? CalcFailure.malformed,
            )
          : null;
    }
    final recognition = CalcRecognition(
      explicit: explicit || weakMarker,
      expression: node,
    );
    if (!explicit && !recognition.hasOperation) return null;
    return recognition;
  }

  /// Слишком длинное сообщение: «слишком длинный пример», только если оно
  /// начинается с маркера и дальше похоже на пример; иначе не наше.
  static CalcRecognition? _tooLong(String message) {
    // Начала хватает: маркер короткий, а пример виден по первым символам.
    final start = message
        .substring(0, math.min(message.length, maxLength))
        .toLowerCase()
        .replaceAll('ё', 'е')
        .trimLeft();
    final head = _head.firstMatch(start);
    if (head == null) return null;
    if (!_mathLike.hasMatch(start.substring(head.end))) return null;
    return const CalcRecognition(
      explicit: true,
      expression: null,
      failure: CalcFailure.tooLong,
    );
  }

  /// Считает пример целиком: удобно для тестов и корпуса. Непохожее на
  /// пример сообщение — [CalcFailure.malformed].
  static CalcResult calculate(String message) {
    final recognition = recognize(message);
    if (recognition == null) {
      return const CalcResult._(
        expression: '',
        failure: CalcFailure.malformed,
      );
    }
    return evaluateRecognition(recognition);
  }

  static CalcResult evaluateRecognition(CalcRecognition recognition) {
    final node = recognition.expression;
    if (node == null) {
      return CalcResult._(
        expression: '',
        failure: recognition.failure ?? CalcFailure.malformed,
      );
    }
    return evaluate(node);
  }

  static CalcResult evaluate(CalcNode node) {
    final expression = render(node);
    try {
      final value = _eval(node);
      return switch (value) {
        _Exact(:final value) => _formatExact(expression, value),
        _Approx(:final value) => _formatApprox(expression, value),
      };
    } on _CalcError catch (error) {
      return CalcResult._(expression: expression, failure: error.failure);
    } on CalcDivisionByZero {
      return CalcResult._(
        expression: expression,
        failure: CalcFailure.divisionByZero,
      );
    }
  }

  // ------------------------------------------------------------ распознавание

  static final RegExp _tail = RegExp(
    r'(?:[\s?!.,]+|\s*=|(?<![а-я])(?:равно|равняется|будет|пожалуйста))$',
  );
  static final RegExp _tailMarker = RegExp(r'=|равно|равняется');

  static final RegExp _head = RegExp(
    r'^(?:а\s+)?(?:пожалуйста[,\s]+)?'
    r'(?:сколько\s+будет|посчитай(?:те)?|подсчитай(?:те)?|сосчитай(?:те)?|'
    r'вычисли(?:те)?|реши(?:те)?|рассчитай(?:те)?)'
    r'(?:[,\s]+пожалуйста)?(?:[,:\s]+|$)',
  );

  static final RegExp _prefixOperation = RegExp(
    r'^(умножь|умножить|помножь|помножить|раздели|разделить|подели|поделить)'
    r'\s+(.+?)\s+на\s+(.+)$',
  );

  static final RegExp _weakHead =
      RegExp(r'^(?:а\s+)?(?:сколько|чему\s+равно|чему\s+равен)(?:[,:\s]+)');

  /// Есть ли в тексте хоть что-то от примера: цифра, знак или слово
  /// калькулятора («плюс», «корень», «пять»).
  static final RegExp _mathLike = RegExp(
    '[\\d+*×·/÷:^√%²³]|(?<![а-я])(?:'
    '${<String>[
      ..._Lexer._numberWords.keys,
      ..._Lexer._thousands,
      'плюс',
      'минус',
      'корень',
      'процент',
      'процента',
      'процентов',
    ].join('|')}'
    ')(?![а-я])',
  );

  /// Без маркера отбрасываем то, что лишь похоже на пример: телефон
  /// «+7 999 123-45-67», «8-800-555-35-35», дату «2026-11-05», время
  /// «18:30».
  ///
  /// Целые числа, сцепленные вплотную «-» или «/», и больше ничего — это
  /// скорее код, диапазон или дата, чем пример: артикул «64115-01»,
  /// «64115/2», телефон «555-1234», диапазон «10-15», «2–3», дата «12/11»,
  /// «05/11/2026», «24/7». С пробелами («10 - 15», «24 / 7»), с другими
  /// знаками («2+10/5») или с маркером («посчитай 24/7») это пример.
  /// Двоеточие вплотную отбрасываем, только если это время «18:30»,
  /// «9:05»: «2,5:0,5» и «100:4» — деление.
  static bool _looksLikeNotMath(List<_Token> tokens) {
    if (tokens.isEmpty) return true;
    if (tokens.first.kind == _Kind.plus) return true;
    var tightHyphens = 0;
    var onlyTightJoins = true;
    var joins = 0;
    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      final literal = token.literal;
      if (token.kind == _Kind.number) {
        if (literal == null || !_integerLiteral.hasMatch(literal)) {
          onlyTightJoins = false;
        }
        continue;
      }
      if (token.tight &&
          (token.kind == _Kind.minus || token.kind == _Kind.divide)) {
        joins++;
      } else {
        onlyTightJoins = false;
      }
      if (token.kind == _Kind.minus && token.tight) tightHyphens++;
      if (token.kind == _Kind.colon && token.tight) {
        final before = i > 0 ? tokens[i - 1].literal : null;
        final after = i + 1 < tokens.length ? tokens[i + 1].literal : null;
        if (before != null &&
            after != null &&
            _integerLiteral.hasMatch(before) &&
            _integerLiteral.hasMatch(after) &&
            before.length <= 2 &&
            after.length == 2) {
          return true;
        }
      }
    }
    if (onlyTightJoins && joins > 0) return true;
    return tightHyphens >= 2;
  }

  static final RegExp _integerLiteral = RegExp(r'^\d+$');

  static bool _hasOperation(CalcNode node) => switch (node) {
        CalcNumber() => false,
        // Двойное отрицание «−(−3)», «--3» — действие: одно «−3» без
        // маркера примером не считается, а «−(−3)» — да.
        CalcNegate(:final operand) =>
          operand is CalcNegate || _hasOperation(operand),
        CalcPercent(:final operand) => _hasOperation(operand),
        CalcBinary() || CalcPercentOf() || CalcPower() || CalcSqrt() => true,
      };

  // --------------------------------------------------------------- счёт

  /// Битов в числе из [maxDigits] цифр не больше этого: быстрая проверка
  /// заведомо огромного до точного сравнения с [_digitLimit].
  static final int _maxBits = (maxDigits * math.ln10 / math.ln2).ceil();

  /// 10^[maxDigits]: наименьшее число из `maxDigits + 1` цифр.
  static final BigInt _digitLimit = BigInt.from(10).pow(maxDigits);

  static _Value _checked(Rational value) {
    if (value.bitLength > _maxBits ||
        value.numerator.abs() >= _digitLimit ||
        value.denominator >= _digitLimit) {
      throw const _CalcError(CalcFailure.tooBig);
    }
    return _Exact(value);
  }

  static _Value _approx(double value) {
    if (value.isNaN) throw const _CalcError(CalcFailure.undefined);
    if (value.isInfinite) throw const _CalcError(CalcFailure.tooBig);
    return _Approx(value);
  }

  static double _toDouble(_Value value) => switch (value) {
        _Exact(:final value) => value.toDouble(),
        _Approx(:final value) => value,
      };

  static _Value _eval(CalcNode node) {
    switch (node) {
      case CalcNumber(:final value):
        return _Exact(value);
      case CalcNegate(:final operand):
        return switch (_eval(operand)) {
          _Exact(:final value) => _Exact(-value),
          _Approx(:final value) => _Approx(-value),
        };
      case CalcPercent(:final operand):
        return _binary(
          CalcOperator.divide,
          _eval(operand),
          _Exact(Rational.hundred),
        );
      case CalcPercentOf(:final percent, :final base):
        return _binary(CalcOperator.multiply, _eval(percent), _eval(base));
      case CalcBinary(:final operator, :final left, :final right):
        final a = _eval(left);
        if (right is CalcPercent &&
            (operator == CalcOperator.add ||
                operator == CalcOperator.subtract)) {
          // «2400 + 15%» — прибавить 15 % от 2400.
          final share = _binary(CalcOperator.multiply, a, _eval(right));
          return _binary(operator, a, share);
        }
        return _binary(operator, a, _eval(right));
      case CalcPower(:final base, :final exponent):
        return _power(_eval(base), _eval(exponent));
      case CalcSqrt(:final operand):
        final value = _eval(operand);
        if (value case _Exact(:final value)) {
          if (value.isNegative) {
            throw const _CalcError(CalcFailure.negativeRoot);
          }
          final exact = value.exactSqrt();
          if (exact != null) return _Exact(exact);
        }
        final x = _toDouble(value);
        if (x < 0) throw const _CalcError(CalcFailure.negativeRoot);
        return _approx(math.sqrt(x));
    }
  }

  static _Value _binary(CalcOperator operator, _Value a, _Value b) {
    if (a is _Exact && b is _Exact) {
      final x = a.value;
      final y = b.value;
      return _checked(
        switch (operator) {
          CalcOperator.add => x + y,
          CalcOperator.subtract => x - y,
          CalcOperator.multiply => x * y,
          CalcOperator.divide => x / y,
        },
      );
    }
    final x = _toDouble(a);
    final y = _toDouble(b);
    if (operator == CalcOperator.divide && y == 0) {
      throw const _CalcError(CalcFailure.divisionByZero);
    }
    return _approx(
      switch (operator) {
        CalcOperator.add => x + y,
        CalcOperator.subtract => x - y,
        CalcOperator.multiply => x * y,
        CalcOperator.divide => x / y,
      },
    );
  }

  static _Value _power(_Value base, _Value exponent) {
    if (base is _Exact && exponent is _Exact && exponent.value.isInteger) {
      final b = base.value;
      final n = exponent.value.numerator;
      if (b.isZero && n.isNegative) {
        throw const _CalcError(CalcFailure.divisionByZero);
      }
      // 0, 1 и −1 в любой степени малы.
      if (b.isZero || b.abs() == Rational.one) {
        if (b.isZero) return _Exact(n == BigInt.zero ? Rational.one : b);
        return _Exact(b.isNegative && n.isOdd ? b : Rational.one);
      }
      if (n.abs() > BigInt.from(maxExponent)) {
        throw const _CalcError(CalcFailure.tooBig);
      }
      final e = n.toInt();
      // Оценка снизу числа битов результата: заведомо огромное не считаем.
      final low = math.max(
        b.numerator.abs().bitLength,
        b.denominator.bitLength,
      );
      if ((low - 1) * e.abs() > _maxBits) {
        throw const _CalcError(CalcFailure.tooBig);
      }
      return _checked(b.pow(e));
    }
    final x = _toDouble(base);
    final y = _toDouble(exponent);
    if (x == 0 && y < 0) throw const _CalcError(CalcFailure.divisionByZero);
    return _approx(math.pow(x, y).toDouble());
  }

  // ------------------------------------------------------------- вывод

  /// Пример в обычной записи: «2 + 2 × 2», «15% от 2 400», «√144».
  static String render(CalcNode node) => _render(node);

  static String _render(CalcNode node) {
    String wrap(CalcNode child, int minimum) {
      final text = _render(child);
      return child._precedence < minimum ? '($text)' : text;
    }

    switch (node) {
      case CalcNumber(:final value):
        return formatNumber(value);
      case CalcNegate(:final operand):
        return '−${wrap(operand, 4)}';
      case CalcPercent(:final operand):
        return '${wrap(operand, 6)}%';
      case CalcPercentOf(:final percent, :final base):
        return '${_render(percent)} от ${wrap(base, 3)}';
      case CalcBinary(:final operator, :final left, :final right):
        final p = node._precedence;
        final sign = switch (operator) {
          CalcOperator.add => '+',
          CalcOperator.subtract => '−',
          CalcOperator.multiply => '×',
          CalcOperator.divide => '/',
        };
        return '${wrap(left, p)} $sign ${wrap(right, p + 1)}';
      case CalcPower(:final base, :final exponent, :final style):
        return switch (style) {
          CalcPowerStyle.square => '${wrap(base, 6)}²',
          CalcPowerStyle.cube => '${wrap(base, 6)}³',
          CalcPowerStyle.caret => '${wrap(base, 5)}^${wrap(exponent, 3)}',
        };
      case CalcSqrt(:final operand):
        return '√${wrap(operand, 6)}';
    }
  }

  /// Точное число в русской записи, если оно конечная десятичная дробь
  /// не длиннее 20 знаков после запятой; иначе округлённое.
  ///
  /// Конечная дробь с большим числом знаков, но не больше
  /// [_maxExactDigits] значащих цифр, пишется точно с порядком:
  /// «1 × 10^−21», «4,76837158203125 × 10^−7».
  static String formatNumber(Rational value) => _exactOrRounded(value).$1;

  /// Сколько значащих цифр конечной дроби показать точно.
  static const int _maxExactDigits = 20;

  /// Запись числа и признак «округлено».
  static (String, bool) _exactOrRounded(Rational value) {
    final places = _terminatingPlaces(value.denominator);
    if (places != null && places <= 20) return (_decimal(value, places), false);
    if (places != null) {
      final scaled = value.numerator.abs() *
          BigInt.from(10).pow(places) ~/
          value.denominator;
      final all = scaled.toString();
      final digits = all.replaceFirst(RegExp(r'0+$'), '');
      if (digits.length <= _maxExactDigits) {
        final sign = value.isNegative ? '−' : '';
        return (_layout(sign, digits, all.length - 1 - places), false);
      }
    }
    return (_significant(value), true);
  }

  static CalcResult _formatExact(String expression, Rational value) {
    final (text, rounded) = _exactOrRounded(value);
    return CalcResult._(
      expression: expression,
      value: text,
      approximate: rounded,
    );
  }

  static CalcResult _formatApprox(String expression, double value) {
    final rational = Rational.tryParseDecimal(value.toStringAsPrecision(17)) ??
        Rational.zero;
    return CalcResult._(
      expression: expression,
      value: _significant(rational),
      approximate: true,
    );
  }

  /// Сколько знаков после запятой у конечной дроби с таким знаменателем,
  /// или `null`, если дробь бесконечная.
  static int? _terminatingPlaces(BigInt denominator) {
    var d = denominator;
    var twos = 0;
    var fives = 0;
    final two = BigInt.two;
    final five = BigInt.from(5);
    while (d % two == BigInt.zero) {
      d ~/= two;
      twos++;
    }
    while (d % five == BigInt.zero) {
      d ~/= five;
      fives++;
    }
    return d == BigInt.one ? math.max(twos, fives) : null;
  }

  static String _decimal(Rational value, int places) {
    final scale = BigInt.from(10).pow(places);
    final scaled = value.numerator.abs() * scale ~/ value.denominator;
    final digits = scaled.toString().padLeft(places + 1, '0');
    final whole = digits.substring(0, digits.length - places);
    final fraction = digits.substring(digits.length - places);
    final sign = value.isNegative ? '−' : '';
    final trimmed = fraction.replaceFirst(RegExp(r'0+$'), '');
    return '$sign${_group(whole)}${trimmed.isEmpty ? '' : ',$trimmed'}';
  }

  /// Округление до [significantDigits] значащих цифр; большие и очень
  /// малые числа — с порядком: «1,234567890 × 10^20».
  static String _significant(Rational value) {
    if (value.isZero) return '0';
    final n = value.numerator.abs();
    final d = value.denominator;
    final ten = BigInt.from(10);
    // Порядок e: 10^e ≤ n/d < 10^(e+1).
    var e = n.toString().length - d.toString().length;
    bool below(int exp) =>
        exp >= 0 ? n < d * ten.pow(exp) : n * ten.pow(-exp) < d;
    if (below(e)) e--;
    if (!below(e + 1)) e++;
    const sig = significantDigits;
    final shift = sig - 1 - e;
    BigInt round(BigInt numerator, BigInt denominator) =>
        (numerator * BigInt.two + denominator) ~/ (denominator * BigInt.two);
    var mantissa = shift >= 0
        ? round(n * ten.pow(shift), d)
        : round(n, d * ten.pow(-shift));
    if (mantissa >= ten.pow(sig)) {
      mantissa = mantissa ~/ ten;
      e++;
    }
    final sign = value.isNegative ? '−' : '';
    return _layout(sign, mantissa.toString(), e);
  }

  /// Значащие цифры [digits] (первая не ноль) с порядком первой цифры
  /// [e]: обычная запись или, для больших и очень малых, с «× 10^e».
  static String _layout(String sign, String digits, int e) {
    if (e >= 15 || e < -6) {
      final rest = digits.substring(1).replaceFirst(RegExp(r'0+$'), '');
      final head = rest.isEmpty ? digits[0] : '${digits[0]},$rest';
      return '$sign$head × 10^${e < 0 ? '−${-e}' : e}';
    }
    final places = digits.length - 1 - e;
    if (places <= 0) {
      return '$sign${_group('$digits${'0' * -places}')}';
    }
    final padded = digits.padLeft(places + 1, '0');
    final whole = padded.substring(0, padded.length - places);
    final fraction = padded
        .substring(padded.length - places)
        .replaceFirst(RegExp(r'0+$'), '');
    return '$sign${_group(whole)}${fraction.isEmpty ? '' : ',$fraction'}';
  }

  /// Разряды через неразрывный пробел, начиная с четырёх цифр: «2 400».
  static String _group(String digits) {
    if (digits.length < 4) return digits;
    final buffer = StringBuffer();
    final first = digits.length % 3;
    if (first > 0) buffer.write(digits.substring(0, first));
    for (var i = first; i < digits.length; i += 3) {
      if (buffer.isNotEmpty) buffer.write(groupSeparator);
      buffer.write(digits.substring(i, i + 3));
    }
    return buffer.toString();
  }
}

// ------------------------------------------------------------------ лексер

enum _Kind {
  number,
  plus,
  minus,
  times,
  divide,
  colon,
  caret,
  percent,
  of,
  lparen,
  rparen,
  sqrt,
  square,
  cube,
}

final class _Token {
  const _Token(
    this.kind, {
    this.value,
    this.tight = false,
    this.literal,
    this.word = false,
  });

  /// Знак записан словом: «корень из», «плюс».
  final bool word;

  final _Kind kind;
  final Rational? value;

  /// Число цифрами как в тексте, без разрядных пробелов: «64115», «2,5».
  /// `null` у чисел словами и у знаков.
  final String? literal;

  /// Знак стоит вплотную между цифрами: «123-45», «18:30».
  final bool tight;
}

final class _Lexer {
  _Lexer(this.text);

  final String text;
  int _pos = 0;
  final List<_Token> _tokens = <_Token>[];

  static final RegExp _space = RegExp(r'[\s  ]+');

  /// Число с разрядами через пробел («2 400», «1 000 000») или без.
  static final RegExp _number = RegExp(
    r'\d{1,3}(?:[   ]\d{3})+(?!\d)(?:[.,]\d+)?|\d+(?:[.,]\d+)?',
  );

  /// Слова-операции; длинные формы раньше коротких.
  static final List<(RegExp, _Kind)> _words = <(RegExp, _Kind)>[
    for (final (pattern, kind) in <(String, _Kind)>[
      ('квадратный корень из', _Kind.sqrt),
      ('корень квадратный из', _Kind.sqrt),
      ('квадратный корень', _Kind.sqrt),
      ('корень из', _Kind.sqrt),
      ('корень', _Kind.sqrt),
      ('в степени', _Kind.caret),
      ('в квадрате', _Kind.square),
      ('в кубе', _Kind.cube),
      ('умножить на', _Kind.times),
      ('умножь на', _Kind.times),
      ('помножить на', _Kind.times),
      ('помножь на', _Kind.times),
      ('умноженное на', _Kind.times),
      ('умножить', _Kind.times),
      ('разделить на', _Kind.divide),
      ('раздели на', _Kind.divide),
      ('поделить на', _Kind.divide),
      ('подели на', _Kind.divide),
      ('делить на', _Kind.divide),
      ('деленное на', _Kind.divide),
      ('разделенное на', _Kind.divide),
      ('плюс', _Kind.plus),
      ('минус', _Kind.minus),
      ('процентов', _Kind.percent),
      ('процента', _Kind.percent),
      ('процент', _Kind.percent),
      ('от', _Kind.of),
    ])
      (RegExp('${pattern.replaceAll(' ', r'\s+')}(?![а-я])'), kind),
  ];

  static const Map<String, (int, int)> _numberWords = <String, (int, int)>{
    // значение, ранг: единицы и 10–19 — 0, десятки — 1, сотни — 2.
    'ноль': (0, -1),
    'нуль': (0, -1),
    'один': (1, 0),
    'одна': (1, 0),
    'одно': (1, 0),
    'два': (2, 0),
    'две': (2, 0),
    'три': (3, 0),
    'четыре': (4, 0),
    'пять': (5, 0),
    'шесть': (6, 0),
    'семь': (7, 0),
    'восемь': (8, 0),
    'девять': (9, 0),
    'десять': (10, 0),
    'одиннадцать': (11, 0),
    'двенадцать': (12, 0),
    'тринадцать': (13, 0),
    'четырнадцать': (14, 0),
    'пятнадцать': (15, 0),
    'шестнадцать': (16, 0),
    'семнадцать': (17, 0),
    'восемнадцать': (18, 0),
    'девятнадцать': (19, 0),
    'двадцать': (20, 1),
    'тридцать': (30, 1),
    'сорок': (40, 1),
    'пятьдесят': (50, 1),
    'шестьдесят': (60, 1),
    'семьдесят': (70, 1),
    'восемьдесят': (80, 1),
    'девяносто': (90, 1),
    'сто': (100, 2),
    'двести': (200, 2),
    'триста': (300, 2),
    'четыреста': (400, 2),
    'пятьсот': (500, 2),
    'шестьсот': (600, 2),
    'семьсот': (700, 2),
    'восемьсот': (800, 2),
    'девятьсот': (900, 2),
    // Родительный падеж: «15% от двухсот», «корень из шестнадцати».
    'нуля': (0, -1),
    'одного': (1, 0),
    'одной': (1, 0),
    'двух': (2, 0),
    'трех': (3, 0),
    'четырех': (4, 0),
    'пяти': (5, 0),
    'шести': (6, 0),
    'семи': (7, 0),
    'восьми': (8, 0),
    'девяти': (9, 0),
    'десяти': (10, 0),
    'одиннадцати': (11, 0),
    'двенадцати': (12, 0),
    'тринадцати': (13, 0),
    'четырнадцати': (14, 0),
    'пятнадцати': (15, 0),
    'шестнадцати': (16, 0),
    'семнадцати': (17, 0),
    'восемнадцати': (18, 0),
    'девятнадцати': (19, 0),
    'двадцати': (20, 1),
    'тридцати': (30, 1),
    'сорока': (40, 1),
    'пятидесяти': (50, 1),
    'шестидесяти': (60, 1),
    'семидесяти': (70, 1),
    'восьмидесяти': (80, 1),
    'девяноста': (90, 1),
    'ста': (100, 2),
    'двухсот': (200, 2),
    'трехсот': (300, 2),
    'четырехсот': (400, 2),
    'пятисот': (500, 2),
    'шестисот': (600, 2),
    'семисот': (700, 2),
    'восьмисот': (800, 2),
    'девятисот': (900, 2),
  };

  static const Set<String> _thousands = <String>{'тысяча', 'тысячи', 'тысяч'};

  static final RegExp _word = RegExp('[а-я]+');

  bool _digitBefore(int index) =>
      index > 0 && _isDigit(text.codeUnitAt(index - 1));

  bool _digitAfter(int index) =>
      index + 1 < text.length && _isDigit(text.codeUnitAt(index + 1));

  static bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

  bool _spaceAround(int index) {
    final before = index > 0 && _space.hasMatch(text[index - 1]);
    final after = index + 1 < text.length && _space.hasMatch(text[index + 1]);
    return before && after;
  }

  List<_Token> tokenize() {
    while (_pos < text.length) {
      final space = _space.matchAsPrefix(text, _pos);
      if (space != null) {
        _pos = space.end;
        continue;
      }
      final number = _number.matchAsPrefix(text, _pos);
      if (number != null) {
        final literal = number.group(0)!.replaceAll(_space, '');
        final value = Rational.tryParseDecimal(literal.replaceAll(',', '.'));
        if (value == null) throw const _CalcError(CalcFailure.malformed);
        _tokens.add(_Token(_Kind.number, value: value, literal: literal));
        _pos = number.end;
        continue;
      }
      final char = text[_pos];
      final symbol = switch (char) {
        '+' => _Kind.plus,
        '-' || '−' || '–' || '—' => _Kind.minus,
        '*' || '×' || '·' => _Kind.times,
        '/' || '÷' => _Kind.divide,
        ':' => _Kind.colon,
        '^' => _Kind.caret,
        '%' => _Kind.percent,
        '(' => _Kind.lparen,
        ')' => _Kind.rparen,
        '√' => _Kind.sqrt,
        '²' => _Kind.square,
        '³' => _Kind.cube,
        // «3 х 4»: буква «х» — умножение, только с пробелами вокруг.
        'x' || 'х' when _spaceAround(_pos) => _Kind.times,
        _ => null,
      };
      if (symbol != null) {
        if (char == '*' && _pos + 1 < text.length && text[_pos + 1] == '*') {
          _tokens.add(const _Token(_Kind.caret));
          _pos += 2;
          continue;
        }
        final tight = _digitBefore(_pos) && _digitAfter(_pos);
        _tokens.add(_Token(symbol, tight: tight));
        _pos++;
        continue;
      }
      if (_readWordOperator() || _readNumberWords()) continue;
      throw const _CalcError(CalcFailure.malformed);
    }
    return _tokens;
  }

  bool _readWordOperator() {
    for (final (pattern, kind) in _words) {
      final match = pattern.matchAsPrefix(text, _pos);
      if (match == null) continue;
      _tokens.add(_Token(kind, word: true));
      _pos = match.end;
      return true;
    }
    return false;
  }

  /// «двадцать пять», «сто двадцать», «две тысячи», «тысяча». Слова
  /// идут от старших разрядов к младшим: «пять двадцать» — не число.
  bool _readNumberWords() {
    var total = 0;
    var current = 0;
    // Следующее слово должно быть младше этого ранга.
    var rank = 3;
    var any = false;
    var thousands = false;
    var position = _pos;
    while (true) {
      var start = position;
      if (any) {
        final space = _space.matchAsPrefix(text, position);
        if (space == null) break;
        start = space.end;
      }
      final match = _word.matchAsPrefix(text, start);
      if (match == null) break;
      final word = match.group(0)!;
      if (_thousands.contains(word)) {
        if (thousands || rank == -2) break;
        total = (any ? current : 1) * 1000;
        current = 0;
        rank = 3;
        thousands = true;
      } else {
        final entry = _numberWords[word];
        if (entry == null) break;
        final (value, wordRank) = entry;
        if (wordRank == -1) {
          // «ноль» — только одним словом.
          if (any) break;
          rank = -2;
        } else {
          if (wordRank >= rank) break;
          current += value;
          // После единиц и 11–19 младших разрядов нет.
          rank = wordRank == 0 ? -1 : wordRank;
        }
      }
      any = true;
      position = match.end;
    }
    if (!any) return false;
    _tokens.add(
      _Token(_Kind.number, value: Rational.fromInt(total + current)),
    );
    _pos = position;
    return true;
  }
}

// ------------------------------------------------------------------ парсер

/// Рекурсивный спуск с ограничением глубины:
///
/// ```text
/// expr    := term (('+' | '-') term)*
/// term    := unary (('*' | '/' | ':' | 'от') unary)*
/// unary   := ('-' | '+') unary | power
/// power   := postfix ('^' unary)?
/// postfix := primary ('%' | '²' | '³')*
/// primary := число | '(' expr ')' | '√' unary
/// ```
final class _Parser {
  _Parser(this.tokens);

  final List<_Token> tokens;
  int _pos = 0;
  int _depth = 0;

  /// Общий предел рекурсии: унарные минусы и корни тоже углубляют разбор.
  static const int _maxRecursion = 200;
  int _recursion = 0;

  _Token? get _peek => _pos < tokens.length ? tokens[_pos] : null;

  bool _accept(_Kind kind) {
    if (_peek?.kind != kind) return false;
    _pos++;
    return true;
  }

  CalcNode parse() {
    if (tokens.isEmpty) throw const _CalcError(CalcFailure.malformed);
    final node = _expr();
    if (_pos != tokens.length) throw const _CalcError(CalcFailure.malformed);
    return node;
  }

  T _guard<T>(T Function() body) {
    if (++_recursion > _maxRecursion) {
      throw const _CalcError(CalcFailure.tooDeep);
    }
    try {
      return body();
    } finally {
      _recursion--;
    }
  }

  CalcNode _expr() => _guard(() {
        var node = _term();
        while (true) {
          if (_accept(_Kind.plus)) {
            node = CalcBinary(CalcOperator.add, node, _term());
          } else if (_accept(_Kind.minus)) {
            node = CalcBinary(CalcOperator.subtract, node, _term());
          } else {
            return node;
          }
        }
      });

  CalcNode _term() => _guard(() {
        var node = _unary();
        while (true) {
          if (_accept(_Kind.times)) {
            node = CalcBinary(CalcOperator.multiply, node, _unary());
          } else if (_accept(_Kind.divide) || _accept(_Kind.colon)) {
            node = CalcBinary(CalcOperator.divide, node, _unary());
          } else if (_peek?.kind == _Kind.of) {
            // «15% от 2400»: слева обязательно проценты — сами по себе,
            // со знаком («−15% от 200») или последним множителем
            // («10 × 15% от 2400» = 10 × (15% от 2400)).
            _pos++;
            node = _attachOf(node, _unary()) ??
                (throw const _CalcError(CalcFailure.malformed));
          } else {
            return node;
          }
        }
      });

  /// Привязывает «от [base]» к процентам в конце [node]; `null`, если
  /// процентов там нет.
  static CalcNode? _attachOf(CalcNode node, CalcNode base) {
    switch (node) {
      case CalcPercent():
        return CalcPercentOf(node, base);
      case CalcNegate(:final operand):
        final inner = _attachOf(operand, base);
        return inner == null ? null : CalcNegate(inner);
      case CalcBinary(:final operator, :final left, :final right)
          when operator == CalcOperator.multiply ||
              operator == CalcOperator.divide:
        final inner = _attachOf(right, base);
        return inner == null ? null : CalcBinary(operator, left, inner);
      default:
        return null;
    }
  }

  CalcNode _unary() => _guard(() {
        if (_accept(_Kind.minus)) return CalcNegate(_unary());
        if (_accept(_Kind.plus)) return _unary();
        return _power();
      });

  CalcNode _power() => _guard(() {
        final base = _postfix();
        if (_accept(_Kind.caret)) return CalcPower(base, _unary());
        return base;
      });

  CalcNode _postfix() => _guard(() {
        var node = _primary();
        while (true) {
          if (_accept(_Kind.percent)) {
            node = CalcPercent(node);
          } else if (_accept(_Kind.square)) {
            node = CalcPower(
              node,
              CalcNumber(Rational.fromInt(2)),
              style: CalcPowerStyle.square,
            );
          } else if (_accept(_Kind.cube)) {
            node = CalcPower(
              node,
              CalcNumber(Rational.fromInt(3)),
              style: CalcPowerStyle.cube,
            );
          } else {
            return node;
          }
        }
      });

  /// «1/4» сразу за словом «корень из»: число, «/», число, а дальше
  /// конец или знак слабее деления. Иначе `null` и позиция прежняя.
  CalcNode? _simpleFraction() {
    if (_pos + 2 >= tokens.length) return null;
    final a = tokens[_pos];
    final slash = tokens[_pos + 1];
    final b = tokens[_pos + 2];
    if (a.kind != _Kind.number ||
        slash.kind != _Kind.divide ||
        b.kind != _Kind.number) {
      return null;
    }
    final next = _pos + 3 < tokens.length ? tokens[_pos + 3].kind : null;
    if (next != null &&
        next != _Kind.plus &&
        next != _Kind.minus &&
        next != _Kind.rparen) {
      return null;
    }
    _pos += 3;
    return CalcBinary(
      CalcOperator.divide,
      CalcNumber(a.value!),
      CalcNumber(b.value!),
    );
  }

  CalcNode _primary() => _guard(() {
        final token = _peek;
        if (token == null) throw const _CalcError(CalcFailure.malformed);
        switch (token.kind) {
          case _Kind.number:
            _pos++;
            return CalcNumber(token.value!);
          case _Kind.lparen:
            _pos++;
            if (++_depth > Calculator.maxDepth) {
              throw const _CalcError(CalcFailure.tooDeep);
            }
            final inner = _expr();
            if (!_accept(_Kind.rparen)) {
              throw const _CalcError(CalcFailure.malformed);
            }
            _depth--;
            return inner;
          case _Kind.sqrt:
            _pos++;
            // «корень из 1/4» словами — корень из дроби, как читается
            // вслух; знак «√1/4» — по правилам, (√1) / 4.
            if (token.word) {
              final fraction = _simpleFraction();
              if (fraction != null) return CalcSqrt(fraction);
            }
            return CalcSqrt(_unary());
          default:
            throw const _CalcError(CalcFailure.malformed);
        }
      });
}
