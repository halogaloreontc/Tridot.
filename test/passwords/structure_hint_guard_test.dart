// Подсказка по структуре генератора (5.4) и HintGuard (5.3): постоянный
// текст «5 английских слов через дефис…» не зависит от значения пароля,
// поэтому к паролю этой структуры он не запрещается никогда — даже когда
// транслит или раскладка дают общий кусок (`angl` в «английских» и
// `angler`). Генератор с детерминированным источником, тысячи зёрен;
// значения в названиях тестов и сообщениях не появляются.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/passwords/hint_guard.dart';
import 'package:local_assistant/core/passwords/password_audit.dart';
import 'package:local_assistant/core/passwords/password_generator.dart';
import 'package:local_assistant/core/passwords/password_strength.dart';
import 'package:local_assistant/core/passwords/password_wordlists.dart';
import 'package:local_assistant/core/passwords/secret_bytes.dart';
import 'package:local_assistant/core/passwords/vault_crypto.dart';
import 'package:local_assistant/core/passwords/vault_format.dart';

import 'vault_test_support.dart';

/// Детерминированный источник (xorshift64*): воспроизводимые прогоны.
final class _SeededRandom implements VaultRandom {
  _SeededRandom(int seed) : _state = seed * 0x9E3779B9 + 0x6A09E667;

  int _state;

  int _next() {
    var x = _state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    _state = x;
    return (x * 0x2545F4914F6CDD1D) >> 32;
  }

  @override
  Uint8List bytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _next() & 0xFF;
    }
    return out;
  }

  @override
  int uniform(int upperBound) => throw UnimplementedError();
}

void main() {
  late PasswordWordlists lists;

  setUpAll(() => lists = testWordlists());

  HintVerdict check(String hint, String password) {
    final bytes = SecretBytes.fromText(password);
    try {
      return HintGuard.check(hint, bytes, lists: lists);
    } finally {
      bytes.wipe();
    }
  }

  final variants = <GeneratorOptions>[
    const GeneratorOptions(),
    const GeneratorOptions(separator: ''),
    const GeneratorOptions(separator: ' ', capital: false, digitCount: 0),
    const GeneratorOptions(words: 3, separator: '.', digitCount: 4),
    const GeneratorOptions(words: 10, separator: '_'),
    const GeneratorOptions(mode: GeneratorMode.characters),
    const GeneratorOptions(mode: GeneratorMode.characters, length: 64),
    const GeneratorOptions(
      mode: GeneratorMode.characters,
      length: 8,
      symbols: false,
      noLookAlike: true,
    ),
  ];

  test(
      '2000 зёрен (и по 500 для 7 других видов): подсказка по структуре '
      'принимается всегда', () {
    for (final options in variants) {
      final seeds = identical(options, variants.first) ? 2000 : 500;
      for (var seed = 0; seed < seeds; seed++) {
        final generator =
            PasswordGenerator(random: _SeededRandom(seed), lists: lists);
        final p = generator.generate(options);
        try {
          final hint = p.options.structureHint;
          for (final text in <String>[hint, '$hint.', ' $hint. ']) {
            final verdict = HintGuard.check(text, p.value, lists: lists);
            expect(
              verdict.ok,
              isTrue,
              reason: 'зерно $seed, ${options.mode.name}: ${verdict.block}',
            );
          }
        } finally {
          p.wipe();
        }
      }
    }
  });

  test('случай из сбоя: `angl` в транслите не запрещает подсказку', () {
    const hint = '5 английских слов через дефис, одно с заглавной, в конце '
        '2 цифры';
    expect(check(hint, 'zoom-stack-Pasty-conform-throwback67').ok, isTrue);
    expect(check(hint, 'angler-stack-Pasty-conform-zoom67').ok, isTrue);
    // Своя приписка к структуре по-прежнему проверяется.
    expect(
      check('$hint. angler', 'angler-stack-Pasty-conform-zoom67').block,
      HintProblem.sharedFragment,
    );
  });

  test('пароль не той структуры: текст структуры проверяется как обычно', () {
    const hint = '5 английских слов через дефис, одно с заглавной, в конце '
        '2 цифры';
    // «английских» в английской раскладке — набранный человеком пароль.
    expect(check(hint, 'fyukbqcrb[2019').ok, isFalse);
    // Слова не из EFF, не та длина цифр, не та заглавная.
    expect(check(hint, 'angler-stack-Pasty-conform-zoom6').ok, isFalse);
    expect(check(hint, 'angler-stack-pasty-conform-zoom67').ok, isFalse);
    expect(check(hint, 'angler-stack-Pasty-conform67').ok, isFalse);
    // Символы: длина не та — не маскируется.
    // («cbvdjkjd» — «символов» в английской раскладке.)
    expect(check('8 символов: строчные', 'cbvdjkjdzz').ok, isFalse);
    expect(check('10 символов: строчные', 'cbvdjkjdzz').ok, isTrue);
  });

  test('проверка записи не отмечает подсказку по структуре', () {
    final assessor = PasswordAssessor(PasswordStrength(lists));
    for (var seed = 0; seed < 200; seed++) {
      final p = PasswordGenerator(random: _SeededRandom(seed), lists: lists)
          .generate(const GeneratorOptions());
      try {
        final entry = VaultEntry(
          id: 'e$seed',
          srev: 1,
          service: 'Почта',
          created: DateTime.utc(2026),
          changed: DateTime.utc(2026),
          fp: Uint8List(32),
          hint: p.options.structureHint,
        );
        expect(
          assessor.assess(p.value, entry).flags,
          isNot(contains(EntryFlags.hintLeaks)),
          reason: 'зерно $seed',
        );
      } finally {
        p.wipe();
      }
    }
  });

  test('слова структуры — не догадки о паролях', () {
    const hint = '5 английских слов через дефис, одно с заглавной, в конце '
        '2 цифры';
    expect(HintGuard.candidates(hint), 0);
    expect(HintGuard.candidates('$hint. CANARY-word'), 2);
  });
}
