import 'dart:convert';
import 'dart:typed_data';

import 'secret_bytes.dart';

/// Частые опечатки при вводе мастер-пароля (D25): другая раскладка
/// ЙЦУКЕН↔QWERTY, Caps Lock, первая буква другого регистра, пробелы по
/// краям. Хранилище пробует их сразу после неверного ввода — это одна
/// попытка счётчика. Варианты стоят человеку пару секунд и ничего не
/// дают тому, кто перебирает файл офлайн.
abstract final class MasterVariants {
  /// Сколько вариантов пробовать после основного ввода.
  static const int limit = 4;

  static const String _latin =
      'qwertyuiop[]asdfghjkl;\'zxcvbnm,.`QWERTYUIOP{}ASDFGHJKL:"ZXCVBNM<>~';
  static const String _cyrillic =
      'йцукенгшщзхъфывапролджэячсмитьбюёЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮЁ';

  static final Map<int, int> _swap = () {
    final latin = _latin.runes.toList();
    final cyrillic = _cyrillic.runes.toList();
    assert(latin.length == cyrillic.length, 'таблица раскладок');
    return <int, int>{
      for (var i = 0; i < latin.length; i++) ...<int, int>{
        latin[i]: cyrillic[i],
        cyrillic[i]: latin[i],
      },
    };
  }();

  /// Варианты ввода [master] без него самого и без повторов, не больше
  /// [limit]. Вызывающий затирает каждый.
  static List<SecretBytes> of(SecretBytes master) {
    final List<int> runes;
    try {
      runes = utf8.decode(master.unsafeBytes).runes.toList();
    } on FormatException {
      return const <SecretBytes>[];
    }
    final candidates = <List<int>>[
      <int>[for (final r in runes) _swap[r] ?? r],
      <int>[for (final r in runes) _flipCase(r)],
      if (runes.isNotEmpty) <int>[_flipCase(runes.first), ...runes.skip(1)],
      _trim(runes),
    ];
    final out = <SecretBytes>[];
    final seen = <List<int>>[runes];
    for (final candidate in candidates) {
      if (candidate.isEmpty) continue;
      if (seen.any((List<int> s) => _same(s, candidate))) continue;
      seen.add(candidate);
      final bytes =
          Uint8List.fromList(utf8.encode(String.fromCharCodes(candidate)));
      out.add(SecretBytes.adopt(bytes));
      if (out.length == limit) break;
    }
    for (final s in seen) {
      s.fillRange(0, s.length, 0);
    }
    return out;
  }

  static int _flipCase(int rune) {
    final char = String.fromCharCode(rune);
    final lower = char.toLowerCase();
    final upper = char.toUpperCase();
    if (lower == upper || lower.runes.length != 1 || upper.runes.length != 1) {
      return rune;
    }
    return char == lower ? upper.runes.first : lower.runes.first;
  }

  static List<int> _trim(List<int> runes) {
    var start = 0;
    var end = runes.length;
    while (start < end && _space(runes[start])) {
      start++;
    }
    while (end > start && _space(runes[end - 1])) {
      end--;
    }
    return runes.sublist(start, end);
  }

  static bool _space(int rune) =>
      rune == 0x20 || rune == 0x09 || rune == 0xA0 || rune == 0x0A;

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
