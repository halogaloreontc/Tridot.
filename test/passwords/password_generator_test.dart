// Генератор паролей (5.4, раздел 11, группа 5): длины и классы, χ² по
// символам, словарь EFF large (7776 слов, решение владельца №6 — только
// английский), выбор без смещения, энтропия, подсказка по структуре.
// Значения генератора в названиях тестов и сообщениях не появляются.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/passwords/password_generator.dart';
import 'package:local_assistant/core/passwords/password_wordlists.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';

import 'vault_test_support.dart';

/// Источник с заданными байтами (для проверки отбраковки).
final class _ScriptedRandom implements VaultRandom {
  _ScriptedRandom(this._values);

  final List<int> _values;
  int calls = 0;

  @override
  Uint8List bytes(int length) {
    final v = _values[calls++ % _values.length];
    return Uint8List.fromList(<int>[
      v & 0xFF,
      (v >> 8) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 24) & 0xFF,
    ]);
  }

  @override
  int uniform(int upperBound) => throw UnimplementedError();
}

String _text(GeneratedPassword p) => utf8.decode(p.value.unsafeBytes);

void main() {
  late VaultCrypto crypto;
  late PasswordWordlists lists;
  late PasswordGenerator generator;

  setUpAll(() async {
    crypto = await testCrypto();
    lists = testWordlists();
    generator = PasswordGenerator(random: crypto, lists: lists);
  });

  group('словарь EFF large', () {
    test('7776 разных слов, только латиница, не длиннее 9 букв', () {
      expect(lists.eff, hasLength(7776));
      expect(lists.eff.toSet(), hasLength(7776));
      for (final word in lists.eff) {
        expect(RegExp(r'^[a-z-]{3,9}$').hasMatch(word), isTrue, reason: word);
      }
      expect(lists.hasEff, isTrue);
    });

    test('без номеров кубиков; повреждённый файл не принимается', () {
      final raw =
          File('assets/passwords/eff_large_wordlist.txt').readAsStringSync();
      expect(raw, isNot(contains('\t')));
      expect(RegExp(r'\d').hasMatch(raw), isFalse);
      expect(
        () => PasswordWordlists.parse(eff: 'one\ntwo\n', common: ''),
        throwsFormatException,
      );
      final doubled = '${raw.split('\n').first}\n$raw';
      expect(
        () => PasswordWordlists.parse(
          eff: doubled.split('\n').take(7776).join('\n'),
          common: '',
        ),
        throwsFormatException,
      );
    });

    test('лицензии записаны рядом со словарями', () {
      final notice = File('assets/passwords/NOTICE.txt').readAsStringSync();
      expect(notice, contains('CC BY 3.0 US'));
      expect(notice, contains('MIT'));
      expect(notice, contains('SecLists'));
      final common =
          File('assets/passwords/common_passwords.txt').readAsLinesSync();
      expect(common.length, greaterThanOrEqualTo(10000));
      expect(common.toSet().length, common.length);
    });

    test('без словаря генератор слов честно отказывает', () {
      final bare = PasswordGenerator(
        random: crypto,
        lists: PasswordWordlists.empty(),
      );
      expect(
        () => bare.generate(const GeneratorOptions()),
        throwsStateError,
      );
      final chars = bare.generate(
        const GeneratorOptions(mode: GeneratorMode.characters),
      );
      expect(chars.value.length, 20);
      chars.wipe();
      expect(chars.value.isWiped, isTrue);
    });
  });

  group('символы', () {
    test('длина 8–64, все выбранные классы есть', () {
      for (final length in <int>[8, 12, 20, 33, 64]) {
        for (var i = 0; i < 20; i++) {
          final p = generator.generate(
            GeneratorOptions(mode: GeneratorMode.characters, length: length),
          );
          final text = _text(p);
          expect(text.length, length);
          expect(RegExp('[a-z]').hasMatch(text), isTrue);
          expect(RegExp('[A-Z]').hasMatch(text), isTrue);
          expect(RegExp('[0-9]').hasMatch(text), isTrue);
          expect(RegExp(r'[!#$%&*+\-=?@^_~]').hasMatch(text), isTrue);
          p.wipe();
        }
      }
    });

    test('границы длины, «без похожих», «только буквы и цифры»', () {
      expect(
        const GeneratorOptions(length: 3).normalized().length,
        GeneratorOptions.minLength,
      );
      expect(
        const GeneratorOptions(length: 500).normalized().length,
        GeneratorOptions.maxLength,
      );
      for (var i = 0; i < 50; i++) {
        final p = generator.generate(
          const GeneratorOptions(
            mode: GeneratorMode.characters,
            length: 40,
            symbols: false,
            noLookAlike: true,
          ),
        );
        final text = _text(p);
        expect(RegExp(r'^[A-Za-z0-9]+$').hasMatch(text), isTrue);
        expect(RegExp('[0O1lI|]').hasMatch(text), isFalse);
        p.wipe();
      }
    });

    test('χ² по 100 000 символов: распределение равномерное', () {
      const options = GeneratorOptions(
        mode: GeneratorMode.characters,
        length: 50,
      );
      final alphabet = options.classes.join();
      final counts = <int, int>{for (final c in alphabet.codeUnits) c: 0};
      var total = 0;
      while (total < 100000) {
        final p = generator.generate(options);
        for (final b in p.value.unsafeBytes) {
          counts[b] = counts[b]! + 1;
          total++;
        }
        p.wipe();
      }
      final expected = total / alphabet.length;
      var chi = 0.0;
      for (final n in counts.values) {
        chi += (n - expected) * (n - expected) / expected;
      }
      // 75 степеней свободы: 99,9-й процентиль ≈ 122. Перегенерация ради
      // классов почти не сдвигает частоты при длине 50.
      expect(alphabet.length, 76);
      expect(chi, lessThan(140));
    });

    test('энтропия — точное число строк со всеми классами', () {
      const all = GeneratorOptions(mode: GeneratorMode.characters, length: 20);
      // 76^20 ≈ 2^124,9; доля строк без какого-то класса мала.
      expect(all.bits, closeTo(124.9, 0.5));
      const digitsOnly = GeneratorOptions(
        mode: GeneratorMode.characters,
        length: 8,
        lower: false,
        upper: false,
        symbols: false,
      );
      // 10^8.
      expect(digitsOnly.bits, closeTo(26.6, 0.05));
      expect(StrengthScale.scoreOf(digitsOnly.bits), 0);
      expect(StrengthScale.scoreOf(all.bits), 4);
    });
  });

  group('слова', () {
    test('5 слов EFF через дефис, одно с заглавной, 2 цифры в конце', () {
      for (var i = 0; i < 30; i++) {
        final p = generator.generate(const GeneratorOptions());
        final text = _text(p);
        expect(RegExp(r'\d\d$').hasMatch(text), isTrue);
        final words = text.substring(0, text.length - 2);
        // Слова EFF с дефисом внутри («yo-yo») делят по словарю.
        final lower = words.toLowerCase();
        expect(_splitEff(lower, lists.eff.toSet()), 5);
        expect(RegExp('[A-Z]').allMatches(words).length, 1);
        expect(RegExp('[а-яё]').hasMatch(text), isFalse);
        p.wipe();
      }
    });

    test('разделитель, число слов, без заглавной и цифр', () {
      final p = generator.generate(
        const GeneratorOptions(
          words: 7,
          separator: '.',
          capital: false,
          digitCount: 0,
        ),
      );
      final text = _text(p);
      expect(text.split('.'), hasLength(7));
      expect(text, equals(text.toLowerCase()));
      p.wipe();
    });

    test('энтропия: 5 слов ≈ 73,6 бита, «высокая»; 6 слов — «очень высокая»',
        () {
      const five = GeneratorOptions();
      expect(five.bits, closeTo(5 * 12.925 + 2.32 + 6.64, 0.05));
      expect(StrengthScale.scoreOf(five.bits), 3);
      expect(StrengthScale.scoreOf(const GeneratorOptions(words: 6).bits), 4);
    });

    test('подсказка по структуре без слов и символов пароля', () {
      final p = generator.generate(const GeneratorOptions());
      final hint = p.options.structureHint;
      expect(
          hint,
          '5 английских слов через дефис, одно с заглавной, в конце '
          '2 цифры');
      for (final word in _text(p).toLowerCase().split(RegExp('[^a-z]+'))) {
        if (word.length >= 3) expect(hint, isNot(contains(word)));
      }
      p.wipe();
      expect(
        const GeneratorOptions(mode: GeneratorMode.characters).structureHint,
        '20 символов: строчные, прописные, цифры, символы',
      );
    });
  });

  group('случайность', () {
    test('отбраковка: числа из «хвоста» 2^32 отбрасываются', () {
      // n = 3: limit = 2^32 − 1. 0xFFFFFFFF ≥ limit — отброшено, затем 7.
      final random = _ScriptedRandom(<int>[0xFFFFFFFF, 7]);
      final g = PasswordGenerator(random: random, lists: lists);
      expect(g.below(3), 7 % 3);
      expect(random.calls, 2);
      expect(() => g.below(0), throwsArgumentError);
    });

    test('below(n) покрывает весь диапазон', () {
      final seen = <int>{};
      for (var i = 0; i < 2000; i++) {
        seen.add(generator.below(10));
      }
      expect(seen, <int>{0, 1, 2, 3, 4, 5, 6, 7, 8, 9});
    });

    test('toString без значения', () {
      final p = generator.generate(const GeneratorOptions());
      expect('$p', 'GeneratedPassword(•••)');
      expect('${p.value}', 'SecretBytes(•••)');
      p.wipe();
    });
  });

  test('параметры: JSON туда и обратно, мусор → значения по умолчанию', () {
    const options = GeneratorOptions(
      mode: GeneratorMode.characters,
      length: 24,
      symbols: false,
    );
    final back = GeneratorOptions.fromJson(options.toJson());
    expect(back.mode, GeneratorMode.characters);
    expect(back.length, 24);
    expect(back.symbols, isFalse);
    final junk = GeneratorOptions.fromJson(<String, Object?>{
      'mode': 'cyrillic',
      'length': 'x',
      'words': 99,
      'separator': '<script>',
    });
    expect(junk.mode, GeneratorMode.words);
    expect(junk.words, GeneratorOptions.maxWords);
    expect(junk.separator, '-');
    // Ни одного класса — строчные остаются.
    expect(
      const GeneratorOptions(
        lower: false,
        upper: false,
        digits: false,
        symbols: false,
      ).normalized().lower,
      isTrue,
    );
  });
}

/// Сколько слов словаря [eff] в [text] (жадно, с учётом слов с дефисом).
int _splitEff(String text, Set<String> eff) {
  final parts = text.split('-');
  var count = 0;
  var i = 0;
  while (i < parts.length) {
    if (i + 1 < parts.length && eff.contains('${parts[i]}-${parts[i + 1]}')) {
      count++;
      i += 2;
    } else {
      expect(eff.contains(parts[i]), isTrue, reason: 'слово не из словаря');
      count++;
      i++;
    }
  }
  return count;
}
