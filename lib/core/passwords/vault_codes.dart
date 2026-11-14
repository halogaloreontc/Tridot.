import 'dart:convert';
import 'dart:typed_data';

import 'keyboard_layouts.dart';
import 'secret_bytes.dart';
import 'vault_crypto.dart';

/// Код восстановления сейфа (ADR-025): 25 знаков Crockford base32
/// (125 бит), пятью группами по пять: `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`.
/// Без I, L, O, U — их не спутать с 1 и 0. Показывается один раз при
/// создании сейфа; на диск в открытом виде не пишется никогда.
abstract final class RecoveryCode {
  /// Алфавит Crockford base32.
  static const String alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  static const int groups = 5;
  static const int groupLength = 5;
  static const int length = groups * groupLength;

  /// Новый код в виде для показа (с дефисами). Вызывающий затирает.
  static SecretBytes generate(VaultRandom random) {
    final out = Uint8List(length + groups - 1);
    var at = 0;
    for (var i = 0; i < length; i++) {
      if (i > 0 && i % groupLength == 0) out[at++] = 0x2D; // -
      out[at++] = alphabet.codeUnitAt(random.uniform(alphabet.length));
    }
    return SecretBytes.adopt(out);
  }

  /// Ввод человека → 25 знаков без дефисов (то, из чего выводится ключ),
  /// или `null`, если это не код. Регистр не важен, пробелы и дефисы
  /// пропускаются, `O → 0`, `I` и `L → 1`; набранное в русской раскладке
  /// переводится по клавишам. Вызывающий затирает результат.
  static SecretBytes? canonical(SecretBytes input) {
    final String text;
    try {
      text = utf8.decode(input.unsafeBytes);
    } on FormatException {
      return null;
    }
    final out = Uint8List(length);
    var n = 0;
    for (var rune in text.runes) {
      if (rune == 0x20 || rune == 0x2D || rune == 0x09) continue;
      if (KeyboardLayouts.isCyrillic(rune)) rune = KeyboardLayouts.swap(rune);
      final c = _normalize(rune);
      if (c == null || n >= length) {
        out.fillRange(0, out.length, 0);
        return null;
      }
      out[n++] = c;
    }
    if (n != length) {
      out.fillRange(0, out.length, 0);
      return null;
    }
    return SecretBytes.adopt(out);
  }

  /// Похоже ли [text] на код восстановления (`SecretGuard`): 5 групп по 5
  /// знаков через дефис или пробел, либо 25 знаков подряд, среди которых
  /// есть цифры и буквы.
  static bool looksLike(String text) =>
      _grouped.hasMatch(text) ||
      _solid.allMatches(text).any((Match m) {
        final s = m[0]!;
        return s.contains(_digit) && s.contains(_letter);
      });

  /// Все места в [text], похожие на код (для маскировки).
  static Iterable<Match> matches(String text) sync* {
    yield* _grouped.allMatches(text);
    for (final m in _solid.allMatches(text)) {
      final s = m[0]!;
      if (s.contains(_digit) && s.contains(_letter)) yield m;
    }
  }

  static final RegExp _grouped = RegExp(
    r'(?<![0-9A-Za-z])[0-9A-Za-z]{5}(?:[- ][0-9A-Za-z]{5}){4}(?![0-9A-Za-z])',
  );
  static final RegExp _solid =
      RegExp(r'(?<![0-9A-Za-z])[0-9A-Za-z]{25}(?![0-9A-Za-z])');
  static final RegExp _digit = RegExp('[0-9]');
  static final RegExp _letter = RegExp('[A-Za-z]');

  static int? _normalize(int rune) {
    if (rune >= 0x61 && rune <= 0x7A) rune -= 0x20; // a-z → A-Z
    if (rune == 0x4F) return 0x30; // O → 0
    if (rune == 0x49 || rune == 0x4C) return 0x31; // I, L → 1
    if (rune > 0x7F) return null;
    return alphabet.contains(String.fromCharCode(rune)) ? rune : null;
  }

  /// Последняя группа кода в виде для показа (проверка «Я сохранил»).
  static String lastGroup(String display) =>
      display.substring(display.length - groupLength);
}

/// ПИН-код сейфа (ADR-025): ровно 6 цифр, по желанию.
abstract final class VaultPin {
  static const int length = 6;

  /// Ровно [length] цифр ASCII.
  static bool isWellFormed(SecretBytes pin) {
    final bytes = pin.unsafeBytes;
    if (bytes.length != length) return false;
    for (final b in bytes) {
      if (b < 0x30 || b > 0x39) return false;
    }
    return true;
  }

  /// Почему этот ПИН-код не годится (текст для человека, без цифр), или
  /// `null`. Отклоняются: все цифры одинаковые, подряд по возрастанию или
  /// убыванию, повтор блока (`123123`, `121212`, `112233`) и самые частые
  /// ПИН-коды. Даты не запрещаются: их слишком много, и запрет только
  /// раздражал бы.
  static String? problem(SecretBytes pin) {
    if (!isWellFormed(pin)) return 'Нужно ровно $length цифр.';
    final d = <int>[for (final b in pin.unsafeBytes) b - 0x30];
    try {
      if (d.toSet().length == 1) {
        return 'Все цифры одинаковые — так легко угадать.';
      }
      var up = true;
      var down = true;
      for (var i = 1; i < d.length; i++) {
        if (d[i] != (d[i - 1] + 1) % 10) up = false;
        if (d[i] != (d[i - 1] + 9) % 10) down = false;
      }
      if (up || down) return 'Цифры подряд — так легко угадать.';
      bool repeats(int block) {
        for (var i = block; i < d.length; i++) {
          if (d[i] != d[i - block]) return false;
        }
        return true;
      }

      if (repeats(2) || repeats(3)) {
        return 'Повтор одной и той же части — так легко угадать.';
      }
      // Пары одинаковых цифр: 112233, 998877.
      if (d[0] == d[1] && d[2] == d[3] && d[4] == d[5]) {
        return 'Пары одинаковых цифр — так легко угадать.';
      }
      // Сравнение по цифрам, без строки из ПИН-кода (строки Dart не
      // затираются).
      for (final known in _common) {
        var same = true;
        for (var i = 0; i < length; i++) {
          if (known.codeUnitAt(i) - 0x30 != d[i]) same = false;
        }
        if (same) return 'Этот ПИН-код слишком частый — придумайте другой.';
      }
      return null;
    } finally {
      d.fillRange(0, d.length, 0);
    }
  }

  /// Самые частые шестизначные ПИН-коды, которых нет среди правил выше.
  static const Set<String> _common = <String>{
    '123321',
    '654321',
    '123654',
    '159753',
    '147258',
    '258369',
    '147852',
    '789456',
    '456789',
    '102030',
    '100200',
    '000123',
    '123000',
    '111222',
    '121314',
    '696969',
    '420420',
    '159357',
    '753951',
    '852456',
    '741852',
    '963852',
  };
}
