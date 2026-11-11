import 'dart:typed_data';

import 'generator_options.dart';
import 'password_wordlists.dart';
import 'secret_bytes.dart';
import 'vault_crypto.dart';

export 'generator_options.dart';

/// Чего не может быть в мастер-пароле и пароле копии (5.1): название
/// приложения подбирают первым. Генератор таких фраз не выдаёт.
const List<String> forbiddenInMaster = <String>['связной', 'relay'];

/// Сгенерированный пароль: значение — только [SecretBytes] (в чат не
/// попадает никогда, только в редактор и временную карточку), энтропия и
/// подсказка по структуре.
final class GeneratedPassword {
  GeneratedPassword({required this.value, required this.options});

  final SecretBytes value;
  final GeneratorOptions options;

  double get bits => options.bits;

  int get score => StrengthScale.scoreOf(bits);

  void wipe() => value.wipe();

  @override
  String toString() => 'GeneratedPassword(•••)';
}

/// Генератор паролей (5.4): криптографически стойкий источник ОС
/// ([VaultRandom], libsodium `randombytes`) и выбор без смещения
/// отбраковкой ([below]). Слова — только из EFF large (решение владельца
/// №6). `dart:math Random` здесь запрещён тестом.
final class PasswordGenerator {
  PasswordGenerator({required this.random, required this.lists});

  final VaultRandom random;
  final PasswordWordlists lists;

  /// Сколько раз перегенерировать, пока не найдутся все классы.
  static const int _maxAttempts = 10000;

  /// Равномерно в `[0, n)` без смещения по модулю: 32-битное случайное
  /// число отбрасывается, если попало в «хвост», не кратный [n].
  int below(int n) {
    if (n <= 0 || n > 0x7FFFFFFF) throw ArgumentError('вне пределов');
    const range = 0x100000000;
    final limit = range - range % n;
    while (true) {
      final b = random.bytes(4);
      final v = b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24);
      b.fillRange(0, b.length, 0);
      final value = v & 0xFFFFFFFF;
      if (value < limit) return value % n;
    }
  }

  /// Новый пароль. Слова без словаря EFF — `StateError`.
  GeneratedPassword generate(GeneratorOptions options) {
    final o = options.normalized();
    return GeneratedPassword(
      value: o.mode == GeneratorMode.words ? _words(o) : _characters(o),
      options: o,
    );
  }

  SecretBytes _characters(GeneratorOptions o) {
    final classes = <Uint8List>[
      for (final set in o.classes) Uint8List.fromList(set.codeUnits),
    ];
    final alphabet = Uint8List.fromList(<int>[
      for (final c in classes) ...c,
    ]);
    final out = Uint8List(o.length);
    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      for (var i = 0; i < out.length; i++) {
        out[i] = alphabet[below(alphabet.length)];
      }
      // Каждый выбранный класс есть — иначе перегенерировать целиком
      // (так все допустимые строки равновероятны).
      if (classes.every((Uint8List c) => out.any(c.contains))) {
        return SecretBytes.adopt(out);
      }
    }
    out.fillRange(0, out.length, 0);
    throw StateError('генератор не сошёлся');
  }

  SecretBytes _words(GeneratorOptions o) {
    if (!lists.hasEff) throw StateError('словарь EFF не загружен');
    // Слова не повторяются: повтор подбирают почти даром, и мастер-пароль
    // или пароль копии с повтором не принимается (5.1, 5.7). Потеря
    // энтропии — меньше тысячной бита.
    // Фраза, которую не примет проверка мастер-пароля, — перевыбор
    // целиком (отбраковка: остальные фразы равновероятны): «relay»
    // ([forbiddenInMaster]) где угодно, в том числе на стыке слов без
    // разделителя, и пара слов «задом наперёд» (`gulp` и `plug`).
    final buffer = <int>[];
    for (var attempt = 0;; attempt++) {
      if (attempt > 1000) throw StateError('генератор не сошёлся');
      final picked = <int>{};
      for (var tries = 0; picked.length < o.words; tries++) {
        if (tries > 1000) throw StateError('генератор не сошёлся');
        picked.add(below(lists.eff.length));
      }
      final chosen = <String>[for (final i in picked) lists.eff[i]];
      final capitalIndex = o.capital ? below(o.words) : -1;
      final sep = o.separator.codeUnits;
      buffer.fillRange(0, buffer.length, 0);
      buffer.clear();
      for (var i = 0; i < chosen.length; i++) {
        if (i > 0) buffer.addAll(sep);
        final units = chosen[i].codeUnits;
        for (var k = 0; k < units.length; k++) {
          final c = units[k];
          buffer.add(
            k == 0 && i == capitalIndex && c >= 0x61 && c <= 0x7A
                ? c - 0x20
                : c,
          );
        }
      }
      if (acceptable(chosen, buffer)) break;
    }
    for (var i = 0; i < o.digitCount; i++) {
      buffer.add(0x30 + below(10));
    }
    final bytes = Uint8List.fromList(buffer);
    buffer.fillRange(0, buffer.length, 0);
    return SecretBytes.adopt(bytes);
  }

  /// Фраза [phrase] из слов [words] годится в мастер-пароль: нет
  /// [forbiddenInMaster] (без учёта регистра, в том числе на стыке слов)
  /// и слова, которое — другое слово задом наперёд. Слова с дефисом
  /// сравниваются и по частям от 3 букв: `drop-down` и `down`, `t-shirt`
  /// и `shirt` вместе — повтор, проверка мастер-пароля его отвергнет.
  static bool acceptable(List<String> words, List<int> phrase) {
    for (final word in words) {
      final back = String.fromCharCodes(word.codeUnits.reversed);
      if (back != word && words.contains(back)) return false;
    }
    final seen = <String>{};
    for (final word in words) {
      final parts = <String>{
        for (final part in word.toLowerCase().split('-'))
          if (part.length >= 3) part,
      };
      for (final part in parts) {
        final back = String.fromCharCodes(part.codeUnits.reversed);
        if (seen.contains(part) || seen.contains(back)) return false;
      }
      seen.addAll(parts);
    }
    final lower = <int>[
      for (final c in phrase) c >= 0x41 && c <= 0x5A ? c + 0x20 : c,
    ];
    try {
      for (final bad in forbiddenInMaster) {
        final units = bad.codeUnits;
        for (var i = 0; i + units.length <= lower.length; i++) {
          var hit = true;
          for (var k = 0; k < units.length && hit; k++) {
            hit = lower[i + k] == units[k];
          }
          if (hit) return false;
        }
      }
      return true;
    } finally {
      lower.fillRange(0, lower.length, 0);
    }
  }

  @override
  String toString() => 'PasswordGenerator';
}
