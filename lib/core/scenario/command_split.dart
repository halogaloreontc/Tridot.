/// Две команды в одном сообщении (ADR-037, дополнение о составных
/// просьбах): «напомни купить молоко и поставь будильник на 7», «засеки 20
/// минут и напомни снять пирог», «перенеси созвон на четверг, а отчёт на
/// пятницу».
///
/// [candidates] только режет текст: на союзе («и», «а потом», «потом»,
/// «затем», «а также», «а ещё», «;»), за которым — повелительное слово
/// команды из закрытого списка [_commandVerbs]. Брать ли разрез, решает
/// [RecognitionLayers]: обе половины должны быть поняты явно сами по себе,
/// и выполняется только первая — вторая предлагается кнопкой. Внутри
/// кавычек не режется: «добавь задачу «закрой и добавь»» — одно название.
///
/// Повтор глагола: «перенеси созвон на четверг, а отчёт на пятницу» —
/// вторая половина без глагола получает глагол первой («перенеси отчёт на
/// пятницу»). Только у переноса и только после «, а» с другим предметом:
/// «не завтра, а в среду» — поправка, а не вторая команда.
abstract final class CommandSplit {
  /// Разрезы [text] — пары (первая команда, вторая) по порядку в тексте;
  /// пусто — резать нечего.
  static List<(String, String)> candidates(String text) {
    if (text.length > 400) return const <(String, String)>[];
    final quoted = <(int, int)>[
      for (final m in _quoted.allMatches(text)) (m.start, m.end),
    ];
    bool inQuotes(int at) =>
        quoted.any(((int, int) q) => q.$1 <= at && at < q.$2);
    final found = <(String, String)>[];
    for (final m in _joint.allMatches(text)) {
      if (inQuotes(m.start)) continue;
      final head = _trim(text.substring(0, m.start));
      final rest = _trim(text.substring(m.end));
      if (head.isEmpty || rest.isEmpty) continue;
      final verb = _firstWord(rest);
      if (!_commandVerbs.contains(verb)) continue;
      found.add((head, rest[0].toUpperCase() + rest.substring(1)));
    }
    for (final m in _elliptic.allMatches(text)) {
      if (inQuotes(m.start)) continue;
      final head = _trim(text.substring(0, m.start));
      final rest = _trim(text.substring(m.end));
      final words = _words(head);
      if (words.isEmpty || !_moveVerbs.contains(words.first)) continue;
      // «Перенеси отчёт не на завтра, а на пятницу» — поправка срока.
      if (words.contains('не') || words.contains('нет')) continue;
      final restWords = _words(rest);
      // Предмет и срок: «отчёт на пятницу», а не только «на пятницу».
      if (restWords.length < 2 || _dueStarts.contains(restWords.first)) {
        continue;
      }
      if (_commandVerbs.contains(restWords.first) ||
          _notSubjects.contains(restWords.first)) {
        continue;
      }
      found.add((head, '${_capital(words.first)} $rest'));
    }
    return found;
  }

  static String _capital(String word) =>
      word[0].toUpperCase() + word.substring(1);

  static String _trim(String text) =>
      text.replaceAll(_edges, '').replaceAll(_spaces, ' ').trim();

  static String _firstWord(String text) {
    final words = _words(text);
    return words.isEmpty ? '' : words.first;
  }

  static List<String> _words(String text) => <String>[
        for (final m in _word.allMatches(text.toLowerCase()))
          m.group(0)!.replaceAll('ё', 'е'),
      ];

  static final RegExp _word = RegExp('[a-zа-яё0-9]+');
  static final RegExp _spaces = RegExp(r'\s+');
  static final RegExp _edges = RegExp(r'^[\s,;:.—–-]+|[\s,;:—–-]+$');
  static final RegExp _quoted = RegExp('«[^»]*»|"[^"]*"|“[^”]*”');

  /// Союз между командами: «и», «, и», «а потом», «потом», «затем», «а
  /// также», «а ещё», «и ещё», «;». После союза могут стоять «ещё»,
  /// «также», «тоже» — они не часть второй команды.
  static final RegExp _joint = RegExp(
    r'(?:\s*[,;]\s*|\s+)'
    r'(?:(?:и|а)\s+(?:потом|затем|ещ[её]|также|после\s+этого)|и|потом|'
    r'затем|после\s+этого)'
    r'(?:\s+(?:ещ[её]|также|тоже))?\s+'
    r'|\s*;\s*',
    caseSensitive: false,
  );

  /// «, а отчёт на пятницу» — вторая половина без глагола.
  static final RegExp _elliptic = RegExp(r'\s*,\s*а\s+', caseSensitive: false);

  /// Глаголы переноса, которые повторяются во второй половине без глагола.
  static const Set<String> _moveVerbs = <String>{
    'перенеси',
    'перенесите',
    'сдвинь',
    'сдвиньте',
    'передвинь',
    'отложи',
    'отложите',
    'перекинь',
  };

  /// «, а то забуду», «, а если не успею»: не предмет второй команды.
  static const Set<String> _notSubjects = <String>{
    'то',
    'вот',
    'если',
    'потом',
    'еще',
    'также',
    'лучше',
    'не',
  };

  /// Срок в начале второй половины: «, а на пятницу» — без предмета.
  static const Set<String> _dueStarts = <String>{
    'на',
    'в',
    'во',
    'к',
    'до',
    'через',
    'завтра',
    'послезавтра',
    'сегодня',
  };

  /// Повелительные слова команд навыков: с них начинается вторая команда.
  /// Закрытый список: «купить хлеб и молоко», «позвонить маме и папе»,
  /// «отвезти кота и купить ему корм» (инфинитивы) — одно дело.
  static const Set<String> _commandVerbs = <String>{
    'напомни',
    'напомните',
    'поставь',
    'поставьте',
    'добавь',
    'добавьте',
    'создай',
    'создайте',
    'запиши',
    'запишите',
    'заведи',
    'засеки',
    'закрой',
    'закройте',
    'отметь',
    'отметьте',
    'заверши',
    'вычеркни',
    'перенеси',
    'перенесите',
    'сдвинь',
    'отложи',
    'покажи',
    'покажите',
    'разбуди',
    'посчитай',
    'сосчитай',
    'вычисли',
    'установи',
    'включи',
    'запусти',
    'сожми',
    'заархивируй',
    'распакуй',
    'конвертируй',
    'сконвертируй',
    'скачай',
    'удали',
    'сделай',
    'запри',
    'заблокируй',
  };
}
