import 'dart:math' as math;

/// Точное рациональное число: числитель и знаменатель на [BigInt].
///
/// Всегда несократимо, знаменатель положителен. Калькулятор считает
/// сложение, вычитание, умножение, деление и целые степени точно и только
/// в конце переводит результат в десятичную запись.
final class Rational implements Comparable<Rational> {
  factory Rational(BigInt numerator, [BigInt? denominator]) {
    var n = numerator;
    var d = denominator ?? BigInt.one;
    if (d == BigInt.zero) {
      throw const CalcDivisionByZero();
    }
    if (d.isNegative) {
      n = -n;
      d = -d;
    }
    final g = n.gcd(d);
    if (g > BigInt.one) {
      n = n ~/ g;
      d = d ~/ g;
    }
    return Rational._(n, d);
  }

  const Rational._(this.numerator, this.denominator);

  factory Rational.fromInt(int value) => Rational(BigInt.from(value));

  /// Десятичная запись из цифр: «12», «3.5», «0,125», «1.5e+20».
  /// `null`, если это не число.
  static Rational? tryParseDecimal(String text) {
    final match = _decimal.firstMatch(text.trim());
    if (match == null) return null;
    final negative = match.group(1) == '-';
    final whole = match.group(2)!;
    final fraction = match.group(3) ?? '';
    final exponent = int.tryParse(match.group(4) ?? '0');
    if (exponent == null || exponent.abs() > 5000) return null;
    var n = BigInt.parse('$whole$fraction');
    var d = BigInt.from(10).pow(fraction.length);
    if (exponent > 0) n *= BigInt.from(10).pow(exponent);
    if (exponent < 0) d *= BigInt.from(10).pow(-exponent);
    return Rational(negative ? -n : n, d);
  }

  static final RegExp _decimal =
      RegExp(r'^([+-])?(\d+)(?:[.,](\d+))?(?:e([+-]?\d+))?$');

  static final Rational zero = Rational._(BigInt.zero, BigInt.one);
  static final Rational one = Rational._(BigInt.one, BigInt.one);
  static final Rational hundred = Rational._(BigInt.from(100), BigInt.one);

  final BigInt numerator;
  final BigInt denominator;

  bool get isInteger => denominator == BigInt.one;
  bool get isZero => numerator == BigInt.zero;
  bool get isNegative => numerator.isNegative;

  /// Число битов самой длинной части: мера «размера» числа.
  int get bitLength => math.max(
        numerator.abs().bitLength,
        denominator.bitLength,
      );

  Rational operator +(Rational other) => Rational(
        numerator * other.denominator + other.numerator * denominator,
        denominator * other.denominator,
      );

  Rational operator -(Rational other) => Rational(
        numerator * other.denominator - other.numerator * denominator,
        denominator * other.denominator,
      );

  Rational operator *(Rational other) => Rational(
        numerator * other.numerator,
        denominator * other.denominator,
      );

  Rational operator /(Rational other) {
    if (other.isZero) throw const CalcDivisionByZero();
    return Rational(
      numerator * other.denominator,
      denominator * other.numerator,
    );
  }

  Rational operator -() => Rational._(-numerator, denominator);

  Rational abs() => isNegative ? -this : this;

  /// Целая степень; отрицательная — через обратное число.
  Rational pow(int exponent) {
    if (exponent == 0) return one;
    if (exponent < 0) {
      if (isZero) throw const CalcDivisionByZero();
      return Rational(denominator.pow(-exponent), numerator.pow(-exponent));
    }
    return Rational._(numerator.pow(exponent), denominator.pow(exponent));
  }

  /// Точный квадратный корень, если числитель и знаменатель — полные
  /// квадраты; иначе `null`.
  Rational? exactSqrt() {
    if (isNegative) return null;
    final n = _isqrt(numerator);
    final d = _isqrt(denominator);
    if (n * n != numerator || d * d != denominator) return null;
    return Rational(n, d);
  }

  /// Приближение числом с плавающей точкой без переполнения на длинных
  /// числителях: делим целочисленно с запасом точности.
  double toDouble() {
    if (isZero) return 0;
    final n = numerator.abs();
    final shift = 64 - (n.bitLength - denominator.bitLength);
    final BigInt q;
    if (shift >= 0) {
      q = (n << shift) ~/ denominator;
    } else {
      q = n ~/ (denominator << -shift);
    }
    // q < 2^66, так что q.toDouble() точен до округления; порядок
    // возвращаем по частям, чтобы промежуточная степень двойки не ушла в
    // бесконечность или в ноль раньше времени. Слишком большое число —
    // бесконечность: вызывающий считает это «слишком большим».
    final value = _scale(q.toDouble(), -shift);
    return isNegative ? -value : value;
  }

  /// `x · 2^exponent` в числах с плавающей точкой (`math.pow(2.0, …)`, не
  /// целочисленный `math.pow(2, …)`, который переполняется молча).
  static double _scale(double x, int exponent) {
    var result = x;
    var rest = exponent;
    while (rest > 1000 && result.isFinite && result != 0) {
      result *= math.pow(2.0, 1000).toDouble();
      rest -= 1000;
    }
    while (rest < -1000 && result != 0) {
      result *= math.pow(2.0, -1000).toDouble();
      rest += 1000;
    }
    return result * math.pow(2.0, rest).toDouble();
  }

  static BigInt _isqrt(BigInt value) {
    if (value < BigInt.two) return value;
    // Метод Ньютона от оценки сверху.
    var x = BigInt.one << ((value.bitLength + 1) ~/ 2);
    while (true) {
      final y = (x + value ~/ x) >> 1;
      if (y >= x) return x;
      x = y;
    }
  }

  @override
  int compareTo(Rational other) =>
      (numerator * other.denominator).compareTo(other.numerator * denominator);

  @override
  bool operator ==(Object other) =>
      other is Rational &&
      other.numerator == numerator &&
      other.denominator == denominator;

  @override
  int get hashCode => Object.hash(numerator, denominator);

  @override
  String toString() => isInteger ? '$numerator' : '$numerator/$denominator';
}

/// Деление на ноль при точном счёте.
final class CalcDivisionByZero implements Exception {
  const CalcDivisionByZero();
}
