import 'persona.dart';

/// Обращение по имени в начале сообщения: «Noda, покажи задачи»,
/// «Рио: добавь задачу …», «нода — сколько будет 2+2».
final class PersonaAddressing {
  const PersonaAddressing(this.persona, this.rest);

  /// К кому обратились.
  final Persona persona;

  /// Сообщение без имени и знака после него: его и разбирает помощник.
  final String rest;

  /// Имя — первое слово (без учёта регистра, латиницей или кириллицей),
  /// дальше запятая, двоеточие, точка с запятой, «!», «?», точка,
  /// многоточие, тире или пробел: «Noda!», «Нода.», «Noda;2+2». «Рио-де-Жанейро»
  /// и «Рио де Жанейро» (город, а не помощник), «Нодаа» и имя в середине
  /// фразы обращением не считаются. `null` — не обращение.
  static PersonaAddressing? parse(String message) {
    final match = _pattern.firstMatch(message);
    if (match == null) return null;
    return PersonaAddressing(
      _byName(match.group(1)!),
      message.substring(match.end).trim(),
    );
  }

  /// Обращение по имени в конце ответа: «да, Рио», «спасибо — Нода!».
  /// Перед именем — запятая или тире: «съездить в Рио» обращением не
  /// считается. [rest] — ответ без имени. `null` — не обращение или в
  /// сообщении одно имя.
  static PersonaAddressing? parseTrailing(String message) {
    final match = _trailing.firstMatch(message);
    if (match == null) return null;
    final rest = message.substring(0, match.start).trim();
    if (rest.isEmpty) return null;
    return PersonaAddressing(_byName(match.group(1)!), rest);
  }

  static Persona _byName(String raw) {
    final name = raw.toLowerCase();
    return Personas.all.firstWhere(
      (Persona p) =>
          p.name.toLowerCase() == name || p.russianName.toLowerCase() == name,
    );
  }

  static final RegExp _pattern = RegExp(
    r'^\s*(rio|noda|рио|нода)'
    r'(?:\s*[,:;!?.…]+\s*|\s*[—–]\s*|\s*-(?![\p{L}\p{N}])\s*'
    r'|\s+(?!\s*де(?![\p{L}\p{N}]))|$)',
    caseSensitive: false,
    unicode: true,
  );

  static final RegExp _trailing = RegExp(
    r'(?:\s*,\s*|\s*[—–]\s*|\s+-\s+)(rio|noda|рио|нода)\s*[!.…]*\s*$',
    caseSensitive: false,
    unicode: true,
  );
}
