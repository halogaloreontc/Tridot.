// Обходы оценки надёжности, четвёртая волна (5.1, 5.5): цепочки, где
// связи вперемешку («та же клавиша с Shift» и «соседняя клавиша»,
// `1!2@3#`), чередование блоками по 2–3 символа (`qw12er34`), фразы из
// коротких слов EFF (выбор длины слова — один раз на ряд, порядок слов
// фразы не в счёт, разделители между словами и хвост — дёшево), повтор
// слова во множественном числе. Образцы — синтетика, не чьи-то пароли.
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
  late List<String> eff;
  late SodiumVaultCrypto crypto;

  setUpAll(() async {
    crypto = await testCrypto();
    strength = PasswordStrength(testWordlists());
    eff = <String>[
      for (final line
          in File('assets/passwords/eff_large_wordlist.txt').readAsLinesSync())
        if (line.trim().isNotEmpty) line.trim().split(RegExp(r'\s+')).last,
    ];
  });

  StrengthEstimate rate(String text) {
    final bytes = SecretBytes.fromText(text);
    try {
      return strength.estimate(bytes);
    } finally {
      bytes.wipe();
    }
  }

  String? problem(String text) => masterProblem(text, strength: strength);

  group('D-M1: связи вперемешку и чередование блоками', () {
    const mixed = <String>[
      r'q1w!e2r@t3y#u4i$',
      r'qw1!er2@ty3#ui4$',
      'Qw1!Er3#Ty5%Ui7&',
      'Йц1!Ук2"Ен3№Гш4;',
    ];
    const blocks = <String>[
      'qw12er34ty56ui78',
      r'QW!@ER#$TY%^UI&*',
      r'Qw12!@Er34#$Ty56',
      'йц12ук34ен56гш78',
    ];

    test('оценка не выше «слабой», мастер-паролем не годятся', () {
      for (final walk in <String>[...mixed, ...blocks]) {
        final e = rate(walk);
        expect(e.score, lessThanOrEqualTo(1), reason: '$walk: ${e.bits}');
        expect(e.reasons, contains(StrengthReason.keyboard), reason: walk);
        expect(problem(walk), isNotNull, reason: walk);
      }
    });

    test('смесь связей стоит несколько бит, а не перебор', () {
      final plain = rate('q1w2e3r4t5y6u7i8').bits;
      final mix = rate(r'q1w!e2r@t3y#u4i$').bits;
      expect(mix - plain, lessThan(12), reason: '$plain → $mix');
    });

    test('случайные пароли из тех же символов остаются сильными', () {
      final random = Random(23);
      const alphabet = r'qwertyuiop1234567890!@#$%^&*()QWERTYUIOPйцукенгшщз';
      var weak = 0;
      for (var n = 0; n < 300; n++) {
        final text = String.fromCharCodes(<int>[
          for (var i = 0; i < 16; i++)
            alphabet.runes.elementAt(random.nextInt(alphabet.runes.length)),
        ]);
        if (rate(text).score < 3) weak++;
      }
      expect(weak, lessThan(3));
    });

    test('генератор символов: 1000 паролей по 16 — «высокая» и выше', () {
      final generator =
          PasswordGenerator(random: crypto, lists: testWordlists());
      for (var n = 0; n < 1000; n++) {
        final generated = generator.generate(
          const GeneratorOptions(
            mode: GeneratorMode.characters,
            length: 16,
          ),
        );
        final e = strength.estimate(generated.value);
        generated.wipe();
        expect(e.score, greaterThanOrEqualTo(3), reason: '${e.bits}');
      }
    });
  });

  group('N2: фразы из коротких слов EFF', () {
    const short = <String>[
      'ice aim fax lid jam',
      'IceAimFaxLidJamFox',
      'both tint cane avid',
      'Ice-Aim-Fax-Lid-1',
      'ice_aim_fax_lid!',
      'oak-elf-art-ion-1',
      'bothtintcaneavid',
    ];

    test('мастер-паролем не годятся, оценка ниже «высокой»', () {
      for (final phrase in short) {
        expect(rate(phrase).score, lessThan(3), reason: phrase);
        expect(problem(phrase), isNotNull, reason: phrase);
      }
    });

    test('длина слова — один раз на ряд, порядок слов не в счёт', () {
      // 4 слова по 4 буквы из 467: ≈ 4 · 8,9 + выбор длины.
      expect(rate('bothtintcaneavid').bits, lessThan(40));
      // Разделитель между словами и хвост — несколько бит.
      final bare = rate('IceAimFaxLid1').bits;
      final dashed = rate('Ice-Aim-Fax-Lid-1').bits;
      expect(dashed - bare, lessThan(6), reason: '$bare → $dashed');
    });

    String phrase(Random random, int count, String style) {
      while (true) {
        final set = <String>{};
        while (set.length < count) {
          set.add(eff[random.nextInt(eff.length)]);
        }
        final words = set.toList();
        final text = style == 'Camel'
            ? words
                .map((String w) => w[0].toUpperCase() + w.substring(1))
                .join()
            : words.join(style);
        if (PasswordGenerator.acceptable(words, text.codeUnits)) return text;
      }
    }

    const styles = <String>['-', '.', '_', ' ', '', 'Camel'];

    test('случайные 4 слова: отказ меньше чем у 1 % и только коротким', () {
      final random = Random(91);
      var rejected = 0;
      var total = 0;
      for (final style in styles) {
        for (var n = 0; n < 200; n++) {
          final text = phrase(random, 4, style);
          total++;
          if (problem(text) == null) continue;
          rejected++;
          final e = rate(text);
          expect(
            e.passphraseLetters,
            lessThan(20),
            reason: 'отказ не из-за коротких слов: $text',
          );
        }
      }
      expect(rejected * 100, lessThan(total), reason: '$rejected/$total');
    });

    test('случайные 5 и 6 слов: годятся все', () {
      final random = Random(92);
      for (final count in <int>[5, 6]) {
        for (final style in styles) {
          for (var n = 0; n < 60; n++) {
            final text = phrase(random, count, style);
            expect(problem(text), isNull, reason: text);
          }
        }
      }
    });
  });

  group('повтор слова во множественном числе', () {
    test('powerrackdwarfcloverpowers — повтор', () {
      expect(problem('powerrackdwarfcloverpowers'), isNotNull);
      expect(
        problem(r'Xq7#powerrackdwarfcloverpowers'),
        contains('повторяться'),
      );
      expect(problem(r'Xq7#power-rack-dwarf-powers'), contains('повторяться'));
      expect(problem('powerrackdwarfclover'), isNull);
    });

    test('«es»: box и boxes, match и matches — повтор; tap и tapes — нет', () {
      expect(problem(r'Xq7#box-rack-dwarf-boxes'), contains('повторяться'));
      expect(problem(r'Xq7#boxes-rack-dwarf-box'), contains('повторяться'));
      expect(
        problem(r'Xq7#match-rack-dwarf-matches'),
        contains('повторяться'),
      );
      expect(
        problem(r'Xq7#tap-rack-dwarf-tapes') ?? '',
        isNot(contains('повторяться')),
      );
    });
  });
}
