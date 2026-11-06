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
  /// многоточие, тире или пробел: «Noda!», «Нода.», «Noda;2+2». «Рио-де-Жанейро»,
  /// «Нодаа» и имя в середине фразы обращением не считаются. `null` — не
  /// обращение.
  static PersonaAddressing? parse(String message) {
    final match = _pattern.firstMatch(message);
    if (match == null) return null;
    final name = match.group(1)!.toLowerCase();
    final persona = Personas.all.firstWhere(
      (Persona p) =>
          p.name.toLowerCase() == name || p.russianName.toLowerCase() == name,
    );
    return PersonaAddressing(persona, message.substring(match.end).trim());
  }

  static final RegExp _pattern = RegExp(
    r'^\s*(rio|noda|рио|нода)'
    r'(?:\s*[,:;!?.…]+\s*|\s*[—–]\s*|\s*-(?![\p{L}\p{N}])\s*|\s+|$)',
    caseSensitive: false,
    unicode: true,
  );
}
