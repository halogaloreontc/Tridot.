// Обходы оценки надёжности и проверки мастер-пароля (5.1, 5.5), третья
// волна: ряды клавиш с Shift вперемешку и в русской раскладке
// (нормализованная копия), чередование нескольких рядов (`q1w2e3`), одна
// клавиша с Shift и без (`1!`, `Qq`); фраза из коротких слов EFF; повтор
// слова внутри слитного куска; части слов с дефисом в генераторе.
// Образцы — синтетика, не чьи-то пароли.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/passwords/passwords_kit.dart';
import 'package:local_assistant/core/passwords/password_generator.dart';
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

  String? problem(String text) => masterProblem(text, strength: strength);

  group('M1: ряды клавиш с Shift, в раскладке, вперемешку', () {
    const walks = <String>[
      r'!Q@W#E$R%T^Y&U*I',
      r'!q@w#e$r%t^y&u*i',
      r'Q!W@E#R$T%Y^U&I*',
      '1й2ц3у4к5е6н7г8ш',
      '!Й"Ц№У;К%Е:Н?Г*Ш',
      r'1!2@3#4$5%6^7&8*9(0)',
      'q1w2e3r4t5y6u7i8o9p0',
      r'Qq1!Ww2@Ee3#Rr4$',
      r'q!w@e#r$t%y^u&i*o(p)',
    ];

    test('оценка не выше «средней», мастер-паролем не годятся', () {
      for (final walk in walks) {
        final e = rate(walk);
        expect(e.score, lessThanOrEqualTo(1), reason: '$walk: ${e.bits}');
        expect(problem(walk), isNotNull, reason: walk);
      }
    });

    test('причина — соседние клавиши или повтор, не «частый пароль»', () {
      for (final walk in walks) {
        expect(
          rate(walk).reasons.intersection(<StrengthReason>{
            StrengthReason.keyboard,
            StrengthReason.repeat,
            StrengthReason.sequence,
          }),
          isNotEmpty,
          reason: walk,
        );
      }
    });

    test('одна клавиша с Shift и без — около бита на пару', () {
      final plain = rate('1234567890').bits;
      final paired = rate(r'1!2@3#4$5%6^7&8*9(0)').bits;
      expect(paired - plain, lessThan(12), reason: '$plain → $paired');
      final letters = rate('qwertyui').bits;
      final doubled = rate('QqWwEeRrTtYyUuIi').bits;
      expect(doubled - letters, lessThan(12), reason: '$letters → $doubled');
    });

    test('случайные пароли из тех же символов остаются сильными', () {
      final random = Random(11);
      const alphabet = r'qwertyuiop1234567890!@#$%^&*()QWERTYUIOP';
      for (var n = 0; n < 300; n++) {
        final text = String.fromCharCodes(<int>[
          for (var i = 0; i < 16; i++)
            alphabet.codeUnitAt(random.nextInt(alphabet.length)),
        ]);
        expect(rate(text).score, greaterThanOrEqualTo(3), reason: text);
      }
    });
  });

  group('M2: фраза из коротких слов EFF', () {
    test('четыре слова по 3 буквы — не фраза для мастер-пароля', () {
      expect(rate('iceaimfaxlid').passphraseWords, 4);
      expect(problem('iceaimfaxlid'), isNotNull);
      expect(problem('IceAimFaxLid'), isNotNull);
    });

    test('обычная фраза из 4 слов по-прежнему проходит', () {
      expect(problem('powerrackdwarfclover'), isNull);
      expect(problem('racingvineyardrefreezematrix'), isNull);
    });
  });

  group('L4: повтор слова внутри слитного куска', () {
    test('powerrackdwarfcloverpower — повтор', () {
      expect(problem('powerrackdwarfcloverpower'), contains('повторяться'));
      expect(problem('PowerRackDwarfCloverPower'), contains('повторяться'));
      expect(problem('powerrackpowerdwarfclover'), contains('повторяться'));
    });
  });

  group('L1: генератор — части слов с дефисом', () {
    List<int> joined(List<String> words) => words.join('-').codeUnits.toList();

    test('drop-down + down, t-shirt + shirt — не годятся', () {
      for (final words in <List<String>>[
        <String>['drop-down', 'cobalt', 'down', 'mantis'],
        <String>['shirt', 'pebble', 't-shirt', 'velvet'],
        <String>['drop-down', 'nwod', 'mantis', 'pebble'],
      ]) {
        expect(
          PasswordGenerator.acceptable(words, joined(words)),
          isFalse,
          reason: words.join(' '),
        );
      }
    });

    test('слова с дефисом без общих частей — годятся', () {
      for (final words in <List<String>>[
        <String>['drop-down', 'cobalt', 'shirt', 'mantis'],
        <String>['t-shirt', 'yo-yo', 'felt-tip', 'pebble'],
      ]) {
        expect(
          PasswordGenerator.acceptable(words, joined(words)),
          isTrue,
          reason: words.join(' '),
        );
      }
    });
  });
}
