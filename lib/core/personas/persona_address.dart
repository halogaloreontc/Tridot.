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
    _ensure();
    final match = _pattern.firstMatch(message);
    if (match == null) return null;
    return PersonaAddressing(
      Personas.byAddressName(match.group(1)!)!,
      message.substring(match.end).trim(),
    );
  }

  /// [message] без обращения по имени в начале («Садо, добавь задачу
  /// хлеб» → «добавь задачу хлеб»): так фразу получают навыки — и в
  /// маршрутизаторе, и в корпусном тесте, и в `tool/route_phrases.dart`.
  /// Одно имя без остального не трогается.
  static String commandText(String message) {
    final addressing = parse(message);
    return addressing != null && addressing.rest.isNotEmpty
        ? addressing.rest
        : message;
  }

  /// Обращение по имени в конце ответа: «да, Лиорио», «спасибо — Нода!».
  /// Перед именем — запятая или тире: «съездить в Лион» и «спасибо Лио»
  /// обращением не считаются. [rest] — ответ без имени. `null` — не
  /// обращение или в сообщении одно имя.
  static PersonaAddressing? parseTrailing(String message) {
    _ensure();
    final match = _trailing.firstMatch(message);
    if (match == null) return null;
    final rest = message.substring(0, match.start).trim();
    if (rest.isEmpty) return null;
    return PersonaAddressing(Personas.byAddressName(match.group(1)!)!, rest);
  }

  /// [message] без обращения к помощнику в начале («Лиорио, …»), в конце
  /// («…, Лиорио») и между запятыми («…, Лиорио, …»): разбор команды от
  /// него не зависит. Одно имя без остального не трогается.
  static String withoutAddress(String message) {
    _ensure();
    var value = message;
    final leading = parse(value);
    if (leading != null && leading.rest.isNotEmpty) value = leading.rest;
    final trailing = parseTrailing(value);
    if (trailing != null) value = trailing.rest;
    return value.replaceAll(_between, ', ');
  }

  /// Имена через «|», длинные раньше: «лиорио» проверяется до «лио».
  /// Берутся из текущего состава ([PersonaCast.current]).
  static String get _names {
    final names = <String>{
      for (final persona in PersonaCast.current.members)
        ...persona.addressNames,
    }.toList()
      ..sort((String a, String b) => b.length.compareTo(a.length));
    // «е» в имени совпадает и с «ё»: «Алёна, …» и «Алена, …» — одно
    // обращение ([Persona.fold]).
    return names
        .map((String name) => RegExp.escape(name).replaceAll('е', '[её]'))
        .join('|');
  }

  static int _builtFor = -1;
  static late RegExp _pattern;
  static late RegExp _trailing;
  static late RegExp _between;

  /// Пересобирает образцы, если имена поменялись ([PersonaCast.version]).
  static void _ensure() {
    if (_builtFor == PersonaCast.version) return;
    final names = _names;
    _pattern = RegExp(
      '^\\s*($names)'
      r'(?:\s*[,:;!?.…]+\s*|\s*[—–]\s*|\s*-(?![\p{L}\p{N}])\s*|\s+|$)',
      caseSensitive: false,
      unicode: true,
    );
    _trailing = RegExp(
      '(?:\\s*,\\s*|\\s*[—–]\\s*|\\s+-\\s+)($names)'
      r'\s*[!.…]*\s*$',
      caseSensitive: false,
      unicode: true,
    );
    _between = RegExp(
      '\\s*,\\s*($names)\\s*,\\s*',
      caseSensitive: false,
      unicode: true,
    );
    _builtFor = PersonaCast.version;
  }
}
