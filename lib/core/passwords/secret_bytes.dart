import 'dart:convert';
import 'dart:typed_data';

/// Байты секрета: мастер-пароль, пароль записи, заметка (ADR-014).
///
/// Обёртка над [Uint8List], которая не выдаёт содержимое случайно: у неё
/// нет `==`, `hashCode` по значению и `toJson`, а [toString] —
/// `SecretBytes(•••)`. После работы байты затираются [wipe]. Строки Dart
/// из секрета не создаются нигде, кроме мест показа в `lib/app`
/// (строки Dart не затираются — честно в docs/PASSWORDS.md).
final class SecretBytes {
  /// Забирает [bytes] себе: вызывающий больше их не трогает, затирает их
  /// [wipe].
  SecretBytes.adopt(Uint8List bytes) : _bytes = bytes;

  /// Копия [bytes]; исходный список вызывающий затирает сам.
  SecretBytes.copy(List<int> bytes) : _bytes = Uint8List.fromList(bytes);

  /// Пустой секрет.
  SecretBytes.empty() : _bytes = Uint8List(0);

  /// Пароль, набранный в поле: UTF-8 после приведения к NFC
  /// ([normalizeNfc]). Пробелы по краям не обрезаются. Только для
  /// полей ввода `lib/app` и тестов: сама строка остаётся в куче Dart.
  factory SecretBytes.fromText(String text) =>
      SecretBytes.adopt(Uint8List.fromList(utf8.encode(normalizeNfc(text))));

  Uint8List _bytes;
  bool _wiped = false;

  /// Длина в байтах.
  int get length => _bytes.length;

  bool get isEmpty => _bytes.isEmpty;

  /// Затёрт ли секрет.
  bool get isWiped => _wiped;

  /// Сами байты — только для криптографии и разбора внутри
  /// `lib/core/passwords`. Ссылку не сохранять и не отдавать дальше.
  Uint8List get unsafeBytes {
    if (_wiped) throw StateError('SecretBytes(•••): уже затёрт');
    return _bytes;
  }

  /// Независимая копия (её тоже нужно затереть).
  SecretBytes clone() => SecretBytes.copy(unsafeBytes);

  /// Затирает байты нулями. Повторный вызов ничего не делает.
  void wipe() {
    if (_wiped) return;
    _bytes.fillRange(0, _bytes.length, 0);
    _bytes = Uint8List(0);
    _wiped = true;
  }

  @override
  String toString() => 'SecretBytes(•••)';
}

/// Приведение пароля к NFC для частых случаев: кириллические «й», «ё»,
/// «ї», «ў» и латиница с распространёнными диакритиками, набранные как
/// буква + комбинирующий знак. Полной таблицы Unicode в Dart нет; другие
/// сочетания остаются как есть (одинаково при создании и вводе на одном
/// устройстве). Так «й», набранная двумя кодовыми точками на одной
/// клавиатуре и одной на другой, даёт одни и те же байты.
String normalizeNfc(String text) {
  if (!text.runes.any(_combining.containsKey)) return text;
  final out = StringBuffer();
  int? pending;
  for (final rune in text.runes) {
    final marks = _combining[rune];
    if (pending != null && marks != null) {
      final composed = marks[pending];
      if (composed != null) {
        pending = composed;
        continue;
      }
    }
    if (pending != null) out.writeCharCode(pending);
    pending = rune;
  }
  if (pending != null) out.writeCharCode(pending);
  return out.toString();
}

/// Комбинирующий знак → (основа → готовая буква).
final Map<int, Map<int, int>> _combining = <int, Map<int, int>>{
  // U+0306 бреве: й Й ў Ў, ă Ă.
  0x0306: _pairs('иИуУaA', 'йЙўЎăĂ'),
  // U+0308 диерезис: ё Ё ї Ї, ä ë ï ö ü ÿ Ä Ë Ï Ö Ü.
  0x0308: _pairs('еЕіІaeiouyAEIOU', 'ёЁїЇäëïöüÿÄËÏÖÜ'),
  // U+0301 акут.
  0x0301: _pairs('aeiouyAEIOUYcnsz', 'áéíóúýÁÉÍÓÚÝćńśź'),
  // U+0300 гравис.
  0x0300: _pairs('aeiouAEIOU', 'àèìòùÀÈÌÒÙ'),
  // U+0302 циркумфлекс.
  0x0302: _pairs('aeiouAEIOU', 'âêîôûÂÊÎÔÛ'),
  // U+0303 тильда.
  0x0303: _pairs('anoANO', 'ãñõÃÑÕ'),
  // U+0327 седиль.
  0x0327: _pairs('cCsS', 'çÇşŞ'),
  // U+030C гачек.
  0x030C: _pairs('csznrCSZNR', 'čšžňřČŠŽŇŘ'),
};

Map<int, int> _pairs(String bases, String composed) {
  final from = bases.runes.toList();
  final to = composed.runes.toList();
  assert(from.length == to.length, 'таблица NFC');
  return <int, int>{for (var i = 0; i < from.length; i++) from[i]: to[i]};
}
