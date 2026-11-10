import 'vault_format.dart';

/// Проверка: совпадает ли токен по отпечатку с паролем записи открытого
/// хранилища (`VaultFacade.knownSecret`). Заперто — всегда `false`.
typedef FingerprintMatcher = bool Function(String token);

/// Итог [SecretGuard.redact].
final class GuardResult {
  const GuardResult(this.text, this.redactions);

  /// Текст с паролями, заменёнными на [SecretGuard.mask].
  final String text;

  /// Сколько фрагментов скрыто.
  final int redactions;

  /// В тексте был пароль: фразу не получает ни один коннектор.
  bool get guarded => redactions > 0;

  @override
  String toString() => 'GuardResult($redactions)';
}

/// Пароль, вставленный в чат (раздел 5.9, D12): маскируется до записи в
/// историю, список команд, «обрабатывается…» и маршрутизатор. Сам
/// захваченный токен выбрасывается — в хранилище он не попадает. Работает
/// и при выключенном навыке «Пароли».
///
/// Правила (нужен явный разделитель или кавычки; дефис и тире —
/// не разделитель):
/// - `(мой )?(пароль|пароли|паролю|пасс|pass(word)?|pwd|пин(-код)?|
///   PIN-код|pin)( от|для|к|на X| сервис)? [:=：] остаток строки` —
///   «пароль почты: …», «пароль: фраза из слов» (скрыта вся);
/// - `логин X (и )?пароль токен`, `login X password токен`;
/// - `пароль (от X)? «что угодно в кавычках»`;
/// - `пароль от X это токен` — если токен похож на пароль;
/// - при открытом хранилище — любой токен от 6 символов (и его части между
///   знаками препинания), совпавший по отпечатку с паролем записи
///   ([known]);
/// - в фразе «пароль от X …» — токены после названия сервиса, похожие на
///   пароль: «пароль от почты Kx9!mq2z».
///
/// Ложные пропуски возможны (честно в docs/PASSWORDS.md): при запертом
/// хранилище пароль без слова «пароль» и без разделителя не распознать.
abstract final class SecretGuard {
  /// Чем заменяется пароль в тексте запроса.
  static const String mask = '••••••';

  /// Чем заменяется совпадение в тексте ответа (выходной фильтр).
  static const String outboundMask = '•••';

  static const String _start = r'(?<![\p{L}\p{N}_])';

  /// Слово «пароль» и его родня целиком (формы, PIN-код, pwd).
  static const String _word = r'(?:пароль|пароля|паролю|паролем|пароле|'
      r'пароли|паролей|паролям|паролями|паролях|'
      r'пасс|passwords|password|passwd|pwd|pass|'
      r'пин-код[а-яё]*|pin-код[а-яё]*|пинкод[а-яё]*|pin-code|pincode|'
      r'пин|pin)'
      r'(?![\p{L}\p{N}_-])';

  static const String _keyword =
      '$_start' r'(?:(?:мой|моя|мои|my)\s+)?' '$_word';

  /// Разделитель: `:`, `=`, полноширинное `：`. Двоеточие времени
  /// («в 10:00») и схемы адреса («https://») — не разделитель.
  static const String _separator =
      r'\s*(?:(?<!\d)[:=：]|[:=：](?!\d))(?!(?<=:)//)\s*';

  /// Сервис: «от|для|к|на|у X» любой длины или одно-три слова без
  /// предлога («пароль почты», «пароль wifi»). Адрес с `://` — часть
  /// названия.
  static const String _service = r'(?:\s+(?:'
      r'(?:от|для|к|на|у)\s+(?:[^:=：\n«»"“”„]|:(?=//))+?'
      r'|(?:[^\s:=：«»"“”„]|:(?=//))+'
      r'(?:\s+(?:[^\s:=：«»"“”„]|:(?=//))+){0,2}'
      r'))?';

  /// Остаток строки: пароль-фраза из нескольких слов скрывается целиком.
  static const String _rest = r'(\S(?:[^\n]*\S)?)';

  static final RegExp _separated = RegExp(
    '$_keyword$_service$_separator$_rest',
    caseSensitive: false,
    unicode: true,
  );

  static final RegExp _loginPassword = RegExp(
    '$_start'
    r'(?:логин|login)\s*[:=：]?\s*'
    r'(?!(?:и|или|а|and|or)\s)\S+\s+(?:(?:и|а|and)\s+)?'
    '$_keyword'
    r'\s*[:=：]?\s*(?!(?:от|для|к|на|у)\s)'
    '$_rest',
    caseSensitive: false,
    unicode: true,
  );

  static final RegExp _quoted = RegExp(
    '$_keyword$_service' r'\s*[:=：]?\s*["«“„' "'" r'](.+?)["»”“' "'" r']',
    caseSensitive: false,
    unicode: true,
  );

  static final RegExp _thisIs = RegExp(
    '$_keyword$_service' r'\s+это\s+(\S+)',
    caseSensitive: false,
    unicode: true,
  );

  static final RegExp _phrase = RegExp(
    '$_keyword' r'\s+(?:(?:от|для|к|на|у)\s+)?\S+',
    caseSensitive: false,
    unicode: true,
  );

  static final RegExp _token = RegExp(r'\S+');

  static final RegExp _edgePunctuation =
      RegExp(r'^[«»"“”„(\[]+|[«»"“”„.,!?;:)\]]+$');

  /// Где можно разрезать токен для сверки отпечатков.
  static final RegExp _cut = RegExp(r'[\p{P}\p{S}]', unicode: true);

  /// Сколько подстрок одного токена сверять по отпечатку. Больше —
  /// токен скрывается целиком (не уверены — значит, пароль).
  static const int _maxChecks = 8192;

  /// Длиннее пароль записи не бывает: такие подстроки не сверяем.
  static const int _maxKnown = VaultFormat.maxPassword;

  /// Короче пароль по отпечатку не ищем.
  static const int _minKnown = 6;

  static final RegExp _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
  static final RegExp _url =
      RegExp(r'^(?:https?://|www\.)', caseSensitive: false);
  static final RegExp _dateTime =
      RegExp(r'^\d{1,4}(?:[.:/-]\d{1,4}){1,2}$|^\d{1,2}:\d{2}$');

  /// Текст с замаскированными паролями.
  static GuardResult redact(String text, {FingerprintMatcher? known}) {
    final ranges = <(int, int)>[];
    void group(RegExpMatch match, {bool needsLook = false}) {
      final start = match.start + match.group(0)!.lastIndexOf(match.group(1)!);
      final value = match.group(1)!;
      if (needsLook && !looksLikePassword(value, allowSpaces: true)) return;
      ranges.add((start, start + value.length));
    }

    for (final match in _separated.allMatches(text)) {
      group(match);
    }
    for (final match in _loginPassword.allMatches(text)) {
      group(match);
    }
    for (final match in _quoted.allMatches(text)) {
      group(match);
    }
    for (final match in _thisIs.allMatches(text)) {
      group(match, needsLook: true);
    }
    // «пароль от почты Kx9!mq2z»: после названия сервиса.
    for (final match in _phrase.allMatches(text)) {
      for (final token in _token.allMatches(text, match.end)) {
        final core = _strip(token.group(0)!);
        if (core.length >= 6 && looksLikePassword(core)) {
          ranges.add((token.start, token.end));
        }
      }
    }
    if (known != null) {
      for (final token in _token.allMatches(text)) {
        if (_knownParts(token.group(0)!, known).isNotEmpty) {
          ranges.add((token.start, token.end));
        }
      }
    }
    return _apply(text, ranges, mask);
  }

  /// Выходной фильтр: в тексте ответа токены (и их части между знаками
  /// препинания), совпавшие по отпечатку с паролем записи, заменяются на
  /// [outboundMask].
  static GuardResult redactKnown(String text, FingerprintMatcher known) {
    final ranges = <(int, int)>[];
    for (final token in _token.allMatches(text)) {
      for (final (start, end) in _knownParts(token.group(0)!, known)) {
        ranges.add((token.start + start, token.start + end));
      }
    }
    return _apply(text, ranges, outboundMask);
  }

  /// Части [token], совпавшие по отпечатку: сам токен и каждая подстрока
  /// между знаками препинания и символами (любые две точки разреза). Так
  /// находится и «CANARY!» в «(CANARY!)», «CANARY!.», «mail:CANARY!» и в
  /// середине длинного адреса — край не обрезается вслепую (знак может
  /// быть частью пароля). Перебор ограничен [_maxChecks]: не уложились —
  /// скрыт весь токен.
  static List<(int, int)> _knownParts(String token, FingerprintMatcher known) {
    if (token.length < _minKnown) return const <(int, int)>[];
    final cuts = <int>{0, token.length};
    for (final match in _cut.allMatches(token)) {
      cuts
        ..add(match.start)
        ..add(match.end);
    }
    final points = cuts.toList()..sort();
    final whole = <(int, int)>[(0, token.length)];
    final found = <(int, int)>[];
    var checks = 0;
    for (var i = 0; i < points.length; i++) {
      for (var j = points.length - 1; j > i; j--) {
        final (start, end) = (points[i], points[j]);
        if (end - start < _minKnown) break;
        if (end - start > _maxKnown) continue;
        if (found.any(((int, int) f) => f.$1 <= start && end <= f.$2)) {
          continue;
        }
        if (++checks > _maxChecks) return whole;
        if (_safe(known, token.substring(start, end))) {
          found.add((start, end));
          break;
        }
      }
    }
    return found;
  }

  static bool _safe(FingerprintMatcher known, String token) {
    try {
      return known(token);
    } catch (_) {
      return false;
    }
  }

  static String _strip(String token) => token.replaceAll(_edgePunctuation, '');

  /// Похоже на пароль: цифра среди букв, символ, заглавные не только в
  /// начале (`Kx9!mq2z`, `wifi2024`, `CANARY-x`); не e-mail, не адрес, не
  /// дата и не время. Слово с заглавной первой буквой («Яндекс») —
  /// не пароль.
  static bool looksLikePassword(String token, {bool allowSpaces = false}) {
    if (token.isEmpty) return false;
    if (_email.hasMatch(token) || _url.hasMatch(token)) return false;
    if (_dateTime.hasMatch(token)) return false;
    var lower = false;
    var upperInside = false;
    var digit = false;
    var symbol = false;
    var letter = false;
    var index = 0;
    for (final rune in token.runes) {
      final char = String.fromCharCode(rune);
      final isLetter = char.toLowerCase() != char.toUpperCase();
      if (isLetter) {
        letter = true;
        if (char == char.toLowerCase()) {
          lower = true;
        } else if (index > 0) {
          upperInside = true;
        }
      } else if (rune >= 0x30 && rune <= 0x39) {
        digit = true;
      } else if (char == '-' || char == "'" || (char == ' ' && allowSpaces)) {
        // Дефис и апостроф бывают в словах («какой-нибудь»), пробел внутри
        // кавычек — часть пароля-фразы: не класс символов.
      } else {
        symbol = true;
      }
      index++;
    }
    if (!letter) return digit && token.length >= 4 || symbol && digit;
    return digit || symbol || (upperInside && lower);
  }

  static GuardResult _apply(
    String text,
    List<(int, int)> ranges,
    String replacement,
  ) {
    if (ranges.isEmpty) return GuardResult(text, 0);
    ranges.sort(((int, int) a, (int, int) b) => a.$1.compareTo(b.$1));
    final merged = <(int, int)>[];
    for (final range in ranges) {
      if (merged.isNotEmpty && range.$1 <= merged.last.$2) {
        final last = merged.removeLast();
        merged.add((last.$1, range.$2 > last.$2 ? range.$2 : last.$2));
      } else {
        merged.add(range);
      }
    }
    final out = StringBuffer();
    var at = 0;
    for (final (start, end) in merged) {
      out
        ..write(text.substring(at, start))
        ..write(replacement);
      at = end;
    }
    out.write(text.substring(at));
    return GuardResult(out.toString(), merged.length);
  }
}
