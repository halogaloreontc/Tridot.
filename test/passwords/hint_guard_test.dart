// HintGuard (5.3, раздел 11, группа 7): подсказка не должна раскрывать
// пароль — ни целиком, ни куском от 4 символов с учётом регистра,
// раскладки, транслита и l33t; совпадение с паролем любой записи по
// отпечатку — запрет; слово из пароля-фразы — предупреждение. Пароли —
// синтетические образцы и канарейки.
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/core/passwords/hint_guard.dart';
import 'package:local_assistant/core/passwords/password_wordlists.dart';
import 'package:local_assistant/core/passwords/secret_bytes.dart';

import 'vault_test_support.dart';

void main() {
  late PasswordWordlists lists;

  setUpAll(() => lists = testWordlists());

  HintVerdict check(
    String hint,
    String password, {
    bool Function(String)? known,
  }) {
    final bytes = SecretBytes.fromText(password);
    try {
      return HintGuard.check(
        hint,
        bytes,
        knownPassword: known,
        lists: lists,
      );
    } finally {
      bytes.wipe();
    }
  }

  group('запрет', () {
    test('весь пароль в подсказке', () {
      expect(
        check('там ${Canary.password}', Canary.password).block,
        HintProblem.containsPassword,
      );
      expect(check('мой: 1a2', '1a2').block, HintProblem.containsPassword);
    });

    test('общий кусок от 4 символов, без учёта регистра', () {
      expect(
        check('кличка Barsik', 'barsik!2019Q').block,
        HintProblem.sharedFragment,
      );
      expect(check('год 2019', 'Qx-2019-zz').block, HintProblem.sharedFragment);
    });

    test('l33t и раскладка — и на стороне подсказки', () {
      // l33t в подсказке: «k0tik» — это `kotik`.
      expect(check('k0tik', 'kotik2019').block, HintProblem.sharedFragment);
      expect(check('s0b@ka', 'sobaka77').block, HintProblem.sharedFragment);
      // Подсказка набрана в английской раскладке, пароль — кириллицей.
      expect(check('rjnbr', 'котик2019').block, HintProblem.sharedFragment);
      // Пароль — «собака» в английской раскладке, подсказка — транслитом.
      expect(check('sobaka', 'cj,frf2019').block, HintProblem.sharedFragment);
    });

    test('транслит: подсказка кириллицей, пароль латиницей', () {
      expect(
        check('кличка собаки', 'Sobaka#77xz').block,
        HintProblem.sharedFragment,
      );
      // «жены» → zheny: общий кусок «zhen» — 4 символа.
      expect(
        check('имя жены', 'Zhena-kv9').block,
        HintProblem.sharedFragment,
      );
    });

    test('раскладка: подсказка кириллицей, пароль в английской раскладке', () {
      // «собака» в английской раскладке.
      expect(
        check('собака', 'cj,frf_9Kq').block,
        isNotNull,
      );
    });

    test('l33t: подсказка словом, пароль с заменами', () {
      expect(
        check('слово sunshine', r'5un$h1ne-Kq').block,
        HintProblem.sharedFragment,
      );
    });

    test('подсказка — пароль другой записи (по отпечатку)', () {
      final verdict = check(
        'как от wifi: ${Canary.note}',
        'Zq8-kv-Lm3',
        known: (String token) => token == Canary.note,
      );
      expect(verdict.block, HintProblem.equalsPassword);
    });
  });

  group('можно', () {
    test('подсказка без общего с паролем', () {
      expect(check('как у почты', Canary.password).ok, isTrue);
      expect(check('', Canary.password), same(HintVerdict.fine));
      expect(check('первая машина и год', 'Xq7#vT2!mL').ok, isTrue);
    });

    test('3 общих символа — не запрет', () {
      expect(check('кот', 'kotXq7#vT2').ok, isTrue);
    });
  });

  test('слово из пароля-фразы короче 4 букв — предупреждение', () {
    // «ace» и «art» — слова EFF.
    expect(lists.effWords.contains('art'.runes.toList()), isTrue);
    final verdict = check('про art', 'quarry-art-mantis');
    expect(verdict.ok, isTrue);
    expect(verdict.warning, HintProblem.passphraseWord);
    expect(verdict.message, contains('пароля-фразы'));
  });

  test('сообщение и toString не содержат пароля и подсказки', () {
    final verdict = check('там ${Canary.password}', Canary.password);
    expect(verdict.message, isNot(contains('CANARY')));
    expect('$verdict', isNot(contains('CANARY')));
  });

  group('оракул отпечатков (15.2)', () {
    test('кандидаты: вся подсказка и слова от 4 символов, без повторов', () {
      expect(HintGuard.candidates(''), 0);
      expect(HintGuard.candidates('Rex'), 1);
      expect(HintGuard.candidates(Canary.password), 1);
      expect(HintGuard.candidates('  ${Canary.password}  '), 1);
      expect(HintGuard.candidates('кот и пёс'), 1);
      expect(HintGuard.candidates('кличка собаки'), 3);
      expect(HintGuard.candidates('CANARY-a CANARY-a'), 2);
    });

    test('длиннее предела — отказ до любых сравнений', () {
      final asked = <String>[];
      final huge = <String>[
        for (var i = 0; i < 2001; i++) 'CANARY-g$i',
      ].join(' ');
      final verdict = check(
        huge,
        'Zx7#qQ!w2LmT',
        known: (String token) {
          asked.add(token);
          return false;
        },
      );
      expect(verdict.block, HintProblem.tooLong);
      expect(asked, isEmpty);
      expect(verdict.message, contains('${HintGuard.maxHint}'));
      final edge = 'a' * HintGuard.maxHint;
      expect(check(edge, 'Zx7#qQ!w2LmT').block, isNot(HintProblem.tooLong));
    });
  });
}
