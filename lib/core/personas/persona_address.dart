import 'persona.dart';

/// Обращение по имени в начале сообщения: «Noda, покажи задачи»,
/// «Лиорио: добавь задачу …», «лио — сколько будет 2+2».
final class PersonaAddressing {
  const PersonaAddressing(this.persona, this.rest);

  /// К кому обратились.
  final Persona persona;

  /// Сообщение без имени и знака после него: его и разбирает помощник.
  final String rest;

  /// Имя ([Persona.addressNames]: «Liorio», «Лиорио», «Лио», «Noda»,
  /// «Нодочка», «Нодь») — первое слово без учёта регистра, дальше запятая,
  /// двоеточие, точка с запятой, «!», «?», точка, многоточие, тире или
  /// пробел: «Noda!», «Лио.», «Noda;2+2». Слово, которое только
  /// начинается с имени («Лион», «Нодаа», «Лио-Лио»), и имя в середине
  /// фразы обращением не считаются. `null` — не обращение.
  static PersonaAddressing? parse(String message) {
    final match = _pattern.firstMatch(message);
    if (match == null) return null;
    return PersonaAddressing(
      Personas.byAddressName(match.group(1)!)!,
      message.substring(match.end).trim(),
    );
  }

  /// Обращение по имени в конце ответа: «да, Лиорио», «спасибо — Нода!».
  /// Перед именем — запятая или тире: «съездить в Лион» и «спасибо Лио»
  /// обращением не считаются. [rest] — ответ без имени. `null` — не
  /// обращение или в сообщении одно имя.
  static PersonaAddressing? parseTrailing(String message) {
    final match = _trailing.firstMatch(message);
    if (match == null) return null;
    final rest = message.substring(0, match.start).trim();
    if (rest.isEmpty) return null;
    return PersonaAddressing(Personas.byAddressName(match.group(1)!)!, rest);
  }

  /// Имена через «|», длинные раньше: «лиорио» проверяется до «лио».
  static String get _names {
    final names = <String>[
      for (final persona in Personas.all) ...persona.addressNames,
    ]..sort((String a, String b) => b.length.compareTo(a.length));
    return names.map(RegExp.escape).join('|');
  }

  static final RegExp _pattern = RegExp(
    '^\\s*($_names)'
    r'(?:\s*[,:;!?.…]+\s*|\s*[—–]\s*|\s*-(?![\p{L}\p{N}])\s*|\s+|$)',
    caseSensitive: false,
    unicode: true,
  );

  static final RegExp _trailing = RegExp(
    '(?:\\s*,\\s*|\\s*[—–]\\s*|\\s+-\\s+)($_names)'
    r'\s*[!.…]*\s*$',
    caseSensitive: false,
    unicode: true,
  );
}
