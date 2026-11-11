// Оценка надёжности (5.5, раздел 11, группа 6): таблица образцов, модели
// (частые, словарь, раскладка, клавиатура, последовательности, повторы,
// даты, l33t, данные записи), пороги и форма пароля для ступени 2.
// Образцы — общеизвестные слабые пароли и синтетика, не чьи-то пароли.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/passwords/keyboard_layouts.dart';
import 'package:local_assistant/core/passwords/password_strength.dart';
import 'package:local_assistant/core/passwords/password_wordlists.dart';
import 'package:local_assistant/core/passwords/secret_bytes.dart';

import 'vault_test_support.dart';

void main() {
  late PasswordStrength strength;

  setUpAll(() => strength = PasswordStrength(testWordlists()));

  StrengthEstimate rate(String text, [List<String> inputs = const <String>[]]) {
    final bytes = SecretBytes.fromText(text);
    try {
      return strength.estimate(bytes, userInputs: inputs);
    } finally {
      bytes.wipe();
    }
  }

  group('таблица образцов', () {
    // Ожидаемая оценка не выше (слабые) или не ниже (сильные).
    const weakest = <String>[
      'password', '123456', '12345678', 'qwerty', 'qwerty123', 'gfhjkm', //
      'ghbdtn', 'привет', 'пароль', 'пароль123', 'йцукен', 'йцукен123',
      'qazwsx', '1qaz2wsx', 'zxcvbnm', 'asdfgh', 'aaaaaaaa', '11111111',
      'abcabcabc', 'abcdef', '987654321', '01.01.1990', '19900101',
      '31121985', 'iloveyou', 'sunshine', 'trustno1', 'P@ssw0rd',
      r'p@$$w0rd', 'Password1', 'monkey', 'dragon', 'letmein', 'football',
      'hjvfirf', 'yfnfif', 'vfrcbv1990', 'ghbdtn2024', 'Natasha1985',
      'mypassword', 'admin123', 'qwertyuiop', 'zaq12wsx', '1q2w3e4r',
      'q1w2e3r4', '555555', 'abc123', 'master', 'shadow', 'superman',
    ];
    const strong = <String>[
      'correct-Horse-battery-staple-ocean47',
      'Xk9!mQ2#vL7@pR4zTq8\$',
      'quarry.Velvet.mantis.cobalt.pebble.91',
      'gTq7-Lp2x-Wm9v-Rk3s-Hn6c',
    ];

    for (final (i, sample) in weakest.indexed) {
      test('слабый образец №${i + 1} — оценка 0–1', () {
        expect(rate(sample).score, lessThanOrEqualTo(1), reason: '№${i + 1}');
      });
    }

    for (final (i, sample) in strong.indexed) {
      test('сильный образец №${i + 1} — оценка ≥ 3', () {
        expect(rate(sample).score, greaterThanOrEqualTo(3));
      });
    }

    test('из дизайна: qwerty123 → 0, ghbdtn2024 ≤ 1, gfhjkm → 0, 5 слов → 4',
        () {
      expect(rate('qwerty123').score, 0);
      expect(rate('ghbdtn2024').score, lessThanOrEqualTo(1));
      expect(rate('gfhjkm').score, 0);
      expect(rate('correct-Horse-battery-staple-ocean47').score, 4);
    });
  });

  group('повторы без учёта регистра, куски и счётчики', () {
    // Синтетика из слов EFF: повтор подбирают почти даром.
    const repeats = <String>[
      'Able-able-ABLE-able',
      'able-acid-able-acid',
      'able1-able2-able3-able4',
      'Able1Able2Able3Able4',
      'Qwerty1!Qwerty1!',
      'abcABCabcABC123',
      'ACID-acid-Acid-aCID',
      'able-acid-able-acid-able',
      'cork9-cork8-cork7-cork6',
    ];
    for (final sample in repeats) {
      test('$sample — не выше «средней»', () {
        final e = rate(sample);
        expect(e.score, lessThanOrEqualTo(2), reason: '${e.bits}');
        expect(e.reasons, contains(StrengthReason.repeat));
      });
    }

    test('5 разных слов EFF и случайные 16+ символов — по-прежнему сильные',
        () {
      for (final sample in <String>[
        'quarry.Velvet.mantis.cobalt.pebble.91',
        'correct-Horse-battery-staple-ocean47',
        'able-acid-bake-cork-dart',
        'Kp3vXr9Lm2QwZt7N',
        'Xk9!mQ2#vL7@pR4zTq8\$',
        'gTq7-Lp2x-Wm9v-Rk3s-Hn6c',
      ]) {
        expect(rate(sample).score, greaterThanOrEqualTo(3), reason: sample);
      }
    });

    test('повтор слова не увеличивает число слов фразы', () {
      expect(rate('Able-able-ABLE-able').passphraseWords, 1);
      expect(rate('able-acid-able-acid').passphraseWords, 2);
    });
  });

  group('модели и причины', () {
    test('частые пароли и l33t', () {
      expect(rate('trustno1').reasons, contains(StrengthReason.common));
      expect(rate('P@ssw0rd').reasons, contains(StrengthReason.leet));
    });

    test('русское слово в английской раскладке и кириллицей', () {
      expect(rate('ghbdtn').reasons, contains(StrengthReason.russianLayout));
      expect(rate('привет').reasons, contains(StrengthReason.russianWord));
    });

    test('ряды QWERTY и ЙЦУКЕН, последовательности, повторы, даты', () {
      expect(rate('wertyu').reasons, contains(StrengthReason.keyboard));
      expect(rate('фывапр').reasons, contains(StrengthReason.keyboard));
      expect(rate('lmnopq').reasons, contains(StrengthReason.sequence));
      expect(rate('zzzzzzzz').reasons, contains(StrengthReason.repeat));
      expect(rate('xyqxyqxyq').reasons, contains(StrengthReason.repeat));
      expect(rate('k1987').reasons, contains(StrengthReason.date));
      expect(rate('k12.05.2003').reasons, contains(StrengthReason.date));
      // Год вне 1940–2035 — не дата.
      expect(rate('k1812').reasons, isNot(contains(StrengthReason.date)));
    });

    test('название, логин, домен записи ослабляют пароль', () {
      final plain = rate('ozonmarket');
      final known = rate('ozonmarket', <String>['Ozon', 'ozon.ru']);
      expect(known.bits, lessThan(plain.bits));
      expect(known.reasons, contains(StrengthReason.userInput));
    });

    test('короткий — причина short; пустой — 0', () {
      expect(rate('Kx9!').reasons, contains(StrengthReason.short));
      expect(rate('').score, 0);
    });

    test('слов EFF во фразе — для мастер-пароля', () {
      expect(
        rate('quarry-velvet-mantis-cobalt').passphraseWords,
        4,
      );
      expect(rate('Xk9!mQ2#').passphraseWords, 0);
    });

    test('повтор слова не делает фразу: считаются разные слова', () {
      expect(rate('able-able-able-able').passphraseWords, 1);
      expect(rate('acid acid acid acid').passphraseWords, 1);
      expect(rate('able-acid-able-acid').passphraseWords, 2);
    });

    test('без словарей — оценка по остальным моделям', () {
      final bare = PasswordStrength(PasswordWordlists.empty());
      final bytes = SecretBytes.fromText('gfhjkm');
      expect(bare.estimate(bytes).score, 0);
      bytes.wipe();
    });

    test('пороги: < 28 → 0, < 36 → 1, < 60 → 2, < 80 → 3, иначе 4', () {
      expect(
        <int>[
          for (final b in <double>[0, 27.9, 28, 35.9, 36, 59.9, 60, 80])
            StrengthEstimate(bits: b, reasons: const {}, length: 1).score,
        ],
        <int>[0, 0, 1, 1, 2, 2, 3, 4],
      );
    });

    test('длинный пароль разбирается быстро', () {
      final watch = Stopwatch()..start();
      rate('Ab1!' * 256);
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });

  group('форма пароля (ступень 2) и служебное', () {
    test('длина и классы без значения', () {
      final bytes = SecretBytes.fromText('Abc12345xyz!');
      final shape = PasswordShape.of(bytes);
      bytes.wipe();
      expect(
        shape.describe(),
        '12 символов: строчные латинские, прописные латинские, цифры, знаки',
      );
      expect('$shape', 'PasswordShape(•••)');
      final one = SecretBytes.fromText('пароль 1');
      expect(
        PasswordShape.of(one).describe(),
        '8 символов: русские буквы, цифры, пробелы',
      );
      one.wipe();
    });

    test('UTF-8 ↔ кодовые точки без строк', () {
      final runes = 'Ёжик-😀-x'.runes.toList();
      final bytes = Utf8Runes.encode(runes);
      expect(Utf8Runes.decode(bytes), runes);
      expect(
        Utf8Runes.decode(Uint8List.fromList(<int>[0xC3])),
        isNull,
      );
    });

    test('раскладка, транслит, l33t', () {
      List<int> r(String s) => s.runes.toList();
      expect(
        String.fromCharCodes(KeyboardLayouts.latinToCyrillic(r('ghbdtn'))),
        'привет',
      );
      expect(
        String.fromCharCodes(KeyboardLayouts.translit(r('Собака'))),
        'sobaka',
      );
      expect(
        String.fromCharCodes(KeyboardLayouts.unleet(r('p@ssw0rd'))),
        'password',
      );
      expect(KeyboardLayouts.swap('q'.runes.first), 'й'.runes.first);
    });

    test('логарифмы без dart:math', () {
      expect(PasswordMath.log2(1024), closeTo(10, 1e-9));
      expect(PasswordMath.log2(7776), closeTo(12.92481, 1e-4));
      expect(PasswordMath.pow2(10), closeTo(1024, 1e-6));
    });
  });
}
