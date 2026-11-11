// Оценка надёжности и проверка мастер-пароля: вторая таблица l33t в
// повторах (S1), Shift в клавиатурных рядах (S2), фразы из слов EFF без
// разделителей и CamelCase (S3), числа — не «слова» (S4), генератор не
// выдаёт фраз, которые проверка отклонит (S5), удвоения без учёта
// регистра, утроения и последовательности через разделитель (S6). И
// главное — настоящие пароли по-прежнему годятся. Образцы — синтетика;
// случайные — с фиксированным зерном (`dart:math` в тесте можно).
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/passwords/passwords_kit.dart';
import 'package:local_assistant/core/passwords/password_generator.dart';
import 'package:local_assistant/core/passwords/password_strength.dart';
import 'package:local_assistant/core/passwords/secret_bytes.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';

import 'vault_test_support.dart';

void main() {
  late PasswordStrength strength;

  setUpAll(() => strength = PasswordStrength(testWordlists()));

  StrengthEstimate rate(String text) {
    final bytes = SecretBytes.fromText(text);
    try {
      return strength.estimate(bytes);
    } finally {
      bytes.wipe();
    }
  }

  String? problem(String text) => masterProblem(text, strength: strength);

  final eff = <String>[
    for (final line
        in File('assets/passwords/eff_large_wordlist.txt').readAsLinesSync())
      if (line.trim().isNotEmpty) line.trim().split(RegExp(r'\s+')).last,
  ];

  /// 4–5 разных слов EFF; фраза с «relay» — отдельное правило (5.1), её
  /// не берём.
  List<String> words(Random random) {
    while (true) {
      final count = 4 + random.nextInt(2);
      final set = <String>{};
      while (set.length < count) {
        set.add(eff[random.nextInt(eff.length)]);
      }
      final list = set.toList();
      if (!list.join().contains('relay')) return list;
    }
  }

  group('S1: вторая таблица l33t (1 → l, | → l)', () {
    const samples = <String>[
      'lamp-1amp-lily-1i1y',
      'velvet-ve1vet-ladle-1ad1e',
      'lemon-|emon-cobalt-coba|t',
    ];

    test('повтор найден оценкой и проверкой слов', () {
      for (final weak in samples) {
        final e = rate(weak);
        expect(e.score, lessThanOrEqualTo(2), reason: '$weak: ${e.bits}');
        expect(e.reasons, contains(StrengthReason.repeat), reason: weak);
        expect(problem(weak), isNotNull, reason: weak);
        expect(masterProblem(weak), contains('не должны повторяться'));
      }
    });
  });

  group('S2: Shift в клавиатурных рядах', () {
    const samples = <String>[
      r'!@#$%^&*()_+',
      r'!QAZ@WSX#EDC$RFV',
      r'QWERTYUIOP!@#$%^&*()',
      'ЙЦУКЕНГШЩЗХЪ!"№;%:?*()',
      r'1qaz!QAZ2wsx@WSX',
    ];

    test('ряд с Shift — клавиатура, мастер-паролем не годится', () {
      for (final weak in samples) {
        final e = rate(weak);
        expect(e.score, lessThanOrEqualTo(2), reason: '$weak: ${e.bits}');
        expect(e.reasons, contains(StrengthReason.keyboard), reason: weak);
        expect(problem(weak), isNotNull, reason: weak);
      }
    });
  });

  group('S3: слова EFF без разделителей и CamelCase', () {
    test('powerrackdwarfclover — четыре слова', () {
      expect(rate('powerrackdwarfclover').passphraseWords, 4);
      expect(rate('PowerRackDwarfClover').passphraseWords, 4);
      expect(problem('powerrackdwarfclover'), isNull);
      expect(problem('PowerRackDwarfClover'), isNull);
      // Слово EFF с дефисом внутри фразы — одно слово.
      expect(rate('cobalt-yo-yo-mantis-pebble').passphraseWords, 4);
    });

    test('одно слово повторами — не фраза', () {
      expect(rate('cobaltcobaltcobaltcobalt').passphraseWords, 1);
      expect(problem('cobaltcobaltcobaltcobalt'), isNotNull);
      expect(problem('CobaltMantisCobaltMantis'), isNotNull);
    });

    test('500 фраз без разделителей и 500 CamelCase — годятся', () {
      // Фраза из 4 коротких слов (средняя длина меньше 5) может не
      // пройти — таких меньше 1 %; из 5 слов проходят все.
      final random = Random(3);
      var four = 0;
      var shortRejected = 0;
      for (var n = 0; n < 500; n++) {
        final list = words(random);
        final letters = list.join().length;
        if (list.length == 4) four += 2;
        final plain = list.join();
        final camel =
            list.map((String w) => w[0].toUpperCase() + w.substring(1)).join();
        for (final text in <String>[plain, camel]) {
          if (problem(text) == null) continue;
          expect(list.length, 4, reason: text);
          expect(letters, lessThan(20), reason: text);
          shortRejected++;
        }
      }
      expect(shortRejected * 100, lessThan(four), reason: '$shortRejected');
    });
  });

  group('S4: числа — не слова', () {
    test('длинные случайные числа — без «слова повторяются»', () {
      final random = Random(44);
      var rejected = 0;
      for (var n = 0; n < 300; n++) {
        final length = 20 + random.nextInt(5);
        final digits = String.fromCharCodes(<int>[
          for (var i = 0; i < length; i++) 0x30 + random.nextInt(10),
        ]);
        final p = problem(digits);
        expect(p ?? '', isNot(contains('повторяться')), reason: digits);
        if (p != null) rejected++;
      }
      // Цифры дешевле букв (10 на символ) — часть отклоняется по оценке,
      // но не ложным «повтором слов».
      expect(rejected, lessThan(75));
    });

    test('числа l33t-ом в словах — по-прежнему повтор', () {
      expect(masterProblem('v3lv3t-velvet-m4nt1s'), contains('повторяться'));
      expect(masterProblem('3141-5926-5358-9793'), isNull);
      expect(masterProblem('0451-1540-7731-3771'), isNull);
    });
  });

  group('S5: генератор и проверка мастер-пароля', () {
    late SodiumVaultCrypto crypto;
    late PasswordGenerator generator;

    setUpAll(() async {
      crypto = await testCrypto();
      generator = PasswordGenerator(random: crypto, lists: testWordlists());
    });

    test('фразы генератора проходят проверку (все разделители)', () {
      for (final separator in GeneratorOptions.separators) {
        for (var n = 0; n < 300; n++) {
          final generated = generator.generate(
            GeneratorOptions(separator: separator),
          );
          final text = String.fromCharCodes(generated.value.unsafeBytes);
          generated.wipe();
          expect(text.toLowerCase(), isNot(contains('relay')));
          expect(problem(text), isNull, reason: '«$separator»: $text');
        }
      }
    });

    test('«relay» и пары «задом наперёд» отбраковываются', () {
      bool ok(List<String> list, String sep) =>
          PasswordGenerator.acceptable(list, list.join(sep).codeUnits);
      expect(ok(<String>['cobalt', 'relay', 'mantis', 'lemon'], '-'), isFalse);
      expect(ok(<String>['cobalt', 'Relay', 'mantis', 'lemon'], '-'), isFalse);
      // На стыке слов без разделителя: spare + layer.
      expect(ok(<String>['spare', 'layer', 'mantis', 'lemon'], ''), isFalse);
      expect(ok(<String>['spare', 'layer', 'mantis', 'lemon'], '-'), isTrue);
      expect(ok(<String>['gulp', 'plug', 'mantis', 'lemon'], '.'), isFalse);
      expect(ok(<String>['gulp', 'cobalt', 'mantis', 'lemon'], '.'), isTrue);
      // И проверка мастер-пароля действительно такие отклоняет.
      expect(problem('gulp.plug.mantis.lemon.cobalt'), isNotNull);
      expect(problem('sparelayermantislemon'), isNotNull);
    });
  });

  group('S6: удвоения, утроения, разделители', () {
    const samples = <String>[
      'AaBbCcDdEeFfGgHh',
      'aAbBcCdDeEfFgG12',
      'aaabbbcccdddeeefff',
      'a-b-c-d-e-f-g-h-i-j-k-l',
      'abc-def-ghi-jkl-mno',
      '1.2.3.4.5.6.7.8.9.0.1.2',
    ];

    test('оценка слабая, мастер-паролем не годятся', () {
      for (final weak in samples) {
        final e = rate(weak);
        expect(e.score, lessThanOrEqualTo(1), reason: '$weak: ${e.bits}');
        expect(problem(weak), isNotNull, reason: weak);
      }
    });
  });

  group('настоящие пароли годятся', () {
    test('300 случайных паролей 16–24 символа, весь алфавит', () {
      final random = Random(77);
      const alphabet = GeneratorOptions.lowerSet +
          GeneratorOptions.upperSet +
          GeneratorOptions.digitSet +
          GeneratorOptions.symbolSet;
      for (var n = 0; n < 300; n++) {
        final length = 16 + random.nextInt(9);
        final password = String.fromCharCodes(<int>[
          for (var i = 0; i < length; i++)
            alphabet.codeUnitAt(random.nextInt(alphabet.length)),
        ]);
        expect(problem(password), isNull, reason: password);
      }
    });

    test('300 фраз из 4–5 слов EFF с разделителями', () {
      final random = Random(78);
      const separators = <String>['-', '.', ' ', '_'];
      for (var n = 0; n < 300; n++) {
        final list = words(random);
        final phrase = list.join(separators[random.nextInt(4)]);
        expect(problem(phrase), isNull, reason: phrase);
      }
    });

    test('случайные [a-z0-9] из 16: ложных отказов меньше 1% из 1000', () {
      final random = Random(11);
      const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
      var rejected = 0;
      for (var n = 0; n < 1000; n++) {
        final password = String.fromCharCodes(<int>[
          for (var i = 0; i < 16; i++)
            alphabet.codeUnitAt(random.nextInt(alphabet.length)),
        ]);
        if (problem(password) != null) rejected++;
      }
      expect(rejected, lessThan(10));
    });
  });
}
