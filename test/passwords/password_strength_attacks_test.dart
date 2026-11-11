// Оценка надёжности и проверка мастер-пароля против обходов (5.1, 5.5):
// копии кусков задом наперёд и с l33t, длинные повторы за пределом
// разбора, шаг последовательности до 3, удвоенные символы, связки во
// фразе, время разбора. Образцы — синтетика из слов EFF и случайных
// символов, не чьи-то пароли. Случайные образцы — с фиксированным
// зерном (`dart:math` здесь, в тесте, можно; в lib/core — нет).
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/passwords/passwords_kit.dart';
import 'package:local_assistant/core/passwords/generator_options.dart';
import 'package:local_assistant/core/passwords/password_strength.dart';
import 'package:local_assistant/core/passwords/secret_bytes.dart';

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

  void rejected(List<String> samples, {bool alsoWithoutLists = false}) {
    for (final weak in samples) {
      expect(
        masterProblem(weak, strength: strength),
        isNotNull,
        reason: '${weak.length > 40 ? weak.substring(0, 40) : weak}: '
            '${rate(weak).bits}',
      );
      if (alsoWithoutLists) {
        expect(
          masterProblem(weak),
          contains('не должны повторяться'),
          reason: weak,
        );
      }
    }
  }

  group('копии задом наперёд (B1)', () {
    const samples = <String>[
      'able-elba-acid-dica',
      'cobalt-tlaboc-pebble-elbbep',
      'Kp3vXr9L-L9rXv3pK',
      'Xq7!mZ2#-#2Zm!7qX',
    ];

    test('оценка не выше «средней», причина — повтор', () {
      for (final weak in samples) {
        final e = rate(weak);
        expect(e.score, lessThanOrEqualTo(2), reason: '$weak: ${e.bits}');
        expect(e.reasons, contains(StrengthReason.repeat), reason: weak);
      }
    });

    test('мастер-паролем не годятся (и без словарей — по словам)', () {
      rejected(samples, alsoWithoutLists: true);
    });

    test('слово EFF задом наперёд — словарное', () {
      // «elbbep» — «pebble» наоборот: дешевле перебора.
      expect(rate('elbbep').bits, lessThan(rate('xqzvwk').bits));
    });
  });

  group('копии с l33t (B2)', () {
    const samples = <String>[
      'velvet-v3lv3t-mantis-m4nt1s',
      'Mantis-M4NT15-Cobalt-C0B4LT',
      'tiger-t1g3r-lamp-l4mp',
    ];

    test('оценка не выше «средней», причина — повтор', () {
      for (final weak in samples) {
        final e = rate(weak);
        expect(e.score, lessThanOrEqualTo(2), reason: '$weak: ${e.bits}');
        expect(e.reasons, contains(StrengthReason.repeat), reason: weak);
      }
    });

    test('мастер-паролем не годятся (и без словарей — по словам)', () {
      rejected(samples, alsoWithoutLists: true);
    });
  });

  group('повтор за пределом разбора (B3)', () {
    final samples = <String>[
      'abcd' * 36,
      'qwerty' * 23,
      '1234567890' * 20,
      r'!@#$' * 50,
      'Kp3vXr9L' * 40,
    ];

    test('хвост повтора — не перебор', () {
      for (final weak in samples) {
        final e = rate(weak);
        expect(e.score, lessThanOrEqualTo(2), reason: '${e.bits}');
        expect(e.reasons, contains(StrengthReason.repeat));
      }
    });

    test('мастер-паролем не годятся', () => rejected(samples));

    test('новое в хвосте по-прежнему считается', () {
      // Тот же повтор, а за ним — случайный хвост: надёжность растёт.
      final base = rate('abcd' * 36).bits;
      expect(
        rate('${'abcd' * 36}Kp3vXr9Lm2QwZt7N').bits,
        greaterThan(base + 40),
      );
    });
  });

  group('время разбора (B4)', () {
    test('худшие случаи до 128 символов и длиннее — быстро', () {
      final random = Random(20261111);
      final digits = String.fromCharCodes(<int>[
        for (var i = 0; i < 128; i++) 0x30 + random.nextInt(10),
      ]);
      final printable = String.fromCharCodes(<int>[
        for (var i = 0; i < 128; i++) 0x21 + random.nextInt(94),
      ]);
      final samples = <String>[
        '1' * 128,
        '12' * 64,
        '1234567890' * 20,
        digits,
        printable,
        'a1' * 64,
        'aa11' * 32,
        'Ab1!' * 256,
        'a' * 1024,
      ];
      for (final s in samples) {
        rate(s); // прогрев
      }
      for (final s in samples) {
        final watch = Stopwatch()..start();
        rate(s);
        watch.stop();
        expect(
          watch.elapsedMilliseconds,
          lessThan(200),
          reason: '${s.length > 20 ? s.substring(0, 20) : s}…',
        );
      }
    });
  });

  group('шаг последовательности и удвоения (B5)', () {
    const samples = <String>[
      'aa11bb22cc33dd44',
      'acegikmoqsuwy',
      'adgjmpsvy-2468024',
      'zwtqnkheb97531',
      'qqwweerrttyyuuii',
    ];

    test('оценка слабая', () {
      for (final weak in samples) {
        expect(rate(weak).score, lessThanOrEqualTo(1), reason: weak);
      }
      expect(
        rate('acegikmoqsuwy').reasons,
        contains(StrengthReason.sequence),
      );
      expect(rate('aa11bb22cc33dd44').reasons, contains(StrengthReason.repeat));
    });

    test('мастер-паролем не годятся', () => rejected(samples));
  });

  group('связки во фразе (B6)', () {
    test('повтор «and» — не повтор слова', () {
      for (final good in <String>[
        'cobalt and velvet and mantis and pebble',
        'cobalt-and-velvet-and-mantis-and-pebble',
        'quarry the velvet the mantis the cobalt',
      ]) {
        expect(masterProblem(good, strength: strength), isNull, reason: good);
        expect(masterProblem(good), isNull, reason: good);
      }
    });

    test('повтор слова со связками — по-прежнему отказ', () {
      expect(
        masterProblem('cobalt and cobalt and mantis and pebble'),
        contains('не должны повторяться'),
      );
      expect(
        masterProblem(
          'cobalt and cobalt and mantis and pebble',
          strength: strength,
        ),
        isNotNull,
      );
    });

    test('связки — не слова фразы', () {
      expect(rate('cobalt and velvet and mantis').passphraseWords, 3);
      expect(rate('and-the-for-with-and').passphraseWords, 0);
      expect(PasswordStrength.isFiller('and'), isTrue);
      expect(PasswordStrength.isFiller('cobalt'), isFalse);
    });
  });

  group('настоящие пароли по-прежнему годятся', () {
    final eff = <String>[
      for (final line
          in File('assets/passwords/eff_large_wordlist.txt').readAsLinesSync())
        if (line.trim().isNotEmpty) line.trim().split(RegExp(r'\s+')).last,
    ];
    const separators = <String>['-', '.', ' ', '_'];

    test('300 фраз из 4–5 разных слов EFF', () {
      // Фраза из 4 коротких слов (средняя длина меньше 5) может не
      // пройти — таких меньше 1 %; из 5 слов проходят все.
      final random = Random(42);
      var four = 0;
      var shortRejected = 0;
      for (var n = 0; n < 300; n++) {
        final count = 4 + random.nextInt(2);
        final words = <String>{};
        while (words.length < count) {
          words.add(eff[random.nextInt(eff.length)]);
        }
        final list = words.toList();
        if (random.nextBool()) {
          final k = random.nextInt(list.length);
          list[k] = list[k][0].toUpperCase() + list[k].substring(1);
        }
        final phrase = list.join(separators[random.nextInt(separators.length)]);
        if (count == 4) four++;
        if (masterProblem(phrase, strength: strength) == null) continue;
        expect(count, 4, reason: phrase);
        expect(list.join().length, lessThan(20), reason: phrase);
        shortRejected++;
      }
      expect(shortRejected * 100, lessThan(four), reason: '$shortRejected');
    });

    test('300 случайных паролей от 16 символов', () {
      final random = Random(7);
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
        expect(
          masterProblem(password, strength: strength),
          isNull,
          reason: '$password: ${rate(password).bits}',
        );
      }
    });
  });
}
