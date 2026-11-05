import '../models/task.dart';
import '../services/clock.dart';

enum CommandIntent {
  createTask,
  listTasks,
  completeTask,
  rescheduleTask,
  unknown,
}

/// Почему срок не удалось однозначно разобрать. Контроллер превращает это
/// в уточнение, а не сохраняет догадку.
enum DueIssue {
  none,

  /// Явно указанный день («сегодня», дата) или время на этот день уже прошли.
  inPast,

  /// Дата вида 31.02 не существует.
  invalidDate,

  /// Время вида 24:00, 25:10 или «в 7.5» не распознано.
  invalidTime,

  /// В команде несколько разных дней: «сегодня или завтра», «10.11 или 12.11».
  conflictingDays,

  /// В команде несколько разных времён: «в 10:00 или в 11:00».
  conflictingTimes,
}

/// Проблемы с названием в кавычках.
enum TitleIssue {
  none,

  /// Кавычка открыта, но не закрыта.
  unbalancedQuotes,

  /// В команде несколько названий в кавычках.
  multipleTitles,
}

final class ParsedCommand {
  const ParsedCommand({
    required this.intent,
    this.title,
    this.dueAt,
    this.duePrecision = DuePrecision.dateTime,
    this.dueIssue = DueIssue.none,
    this.titleIssue = TitleIssue.none,
    this.projects = const <String>[],
  });

  final CommandIntent intent;

  /// Метки проектов из команды: «#работа» вне кавычек, без «#».
  final List<String> projects;

  /// Для создания — название новой задачи; для переноса и завершения —
  /// название задачи, к которой относится команда.
  final String? title;
  final DateTime? dueAt;
  final DuePrecision duePrecision;
  final DueIssue dueIssue;
  final TitleIssue titleIssue;
}

final class DueParseResult {
  const DueParseResult({
    this.dueAt,
    this.precision = DuePrecision.dateTime,
    this.issue = DueIssue.none,
  });

  final DateTime? dueAt;
  final DuePrecision precision;
  final DueIssue issue;
}

/// Узкий набор правил первого среза.
///
/// Название задачи по-прежнему требуется в кавычках. Текст в кавычках
/// вырезается до распознавания намерения и срока, поэтому слова и даты внутри
/// названия («Завершить отчёт», «Планёрка завтра») не меняют смысл команды.
/// При любой неоднозначности парсер сообщает о проблеме, а не угадывает.
final class ScenarioParser {
  ScenarioParser({required Clock clock}) : _clock = clock;

  final Clock _clock;

  /// Открывающая кавычка → допустимые закрывающие.
  static const Map<String, Set<String>> _quotePairs = <String, Set<String>>{
    '«': <String>{'»'},
    '»': <String>{'«'},
    '“': <String>{'”', '“'},
    '„': <String>{'“', '”'},
    '"': <String>{'"'},
  };

  static final RegExp _word = RegExp('[a-zа-я0-9]+');

  /// ЧЧ:ММ с необязательными секундами. Диапазон проверяется отдельно,
  /// чтобы «25:10» стало уточнением, а не молча пропало.
  static final RegExp _colonTime =
      RegExp(r'(?<![\d.:])(\d{1,2}):(\d{2})(?::(\d{2}))?(?![\d:])');

  /// Число с точкой: дата ДД.ММ[.ГГ|.ГГГГ] или время ЧЧ.ММ — решается
  /// по контексту. Точка в конце предложения не считается частью числа.
  static final RegExp _dotted = RegExp(
    r'(?<![\d.:])(\d{1,2})\.(\d{1,2})(?:\.(\d{4}|\d{2}))?(?!\d|\.\d)',
  );

  /// Предлоги, после которых указывается исходный срок при переносе:
  /// «с 15:00 на 17:00».
  static const Set<String> _sourcePrepositions = <String>{'с', 'со', 'от'};

  static final RegExp _hashtag =
      RegExp(r'(?<![\p{L}\p{N}])#([\p{L}\p{N}_-]+)', unicode: true);

  ParsedCommand parse(String message) {
    final quotes = _extractQuoted(message);
    final projects = <String>[
      for (final match in _hashtag.allMatches(quotes.rest))
        match.group(1)!.toLowerCase(),
    ];
    // Метки вырезаются до разбора, чтобы «#завтра» не стало сроком.
    final rest = _normalize(quotes.rest.replaceAll(_hashtag, ' '));
    final words = _word
        .allMatches(rest)
        .map((Match m) => m.group(0)!)
        .toList(growable: false);
    if (words.isEmpty && quotes.titles.isEmpty) {
      return const ParsedCommand(intent: CommandIntent.unknown);
    }

    final intent = _detectIntent(words, rest);
    final titleIssue = quotes.unbalanced
        ? TitleIssue.unbalancedQuotes
        : quotes.titles.length > 1
            ? TitleIssue.multipleTitles
            : TitleIssue.none;
    final title = titleIssue == TitleIssue.none && quotes.titles.isNotEmpty
        ? quotes.titles.single
        : null;

    switch (intent) {
      case CommandIntent.createTask:
      case CommandIntent.rescheduleTask:
        final due = parseDueDetailed(rest);
        return ParsedCommand(
          intent: intent,
          title: title,
          dueAt: due.dueAt,
          duePrecision: due.precision,
          dueIssue: due.issue,
          titleIssue: titleIssue,
          projects:
              intent == CommandIntent.createTask ? projects : const <String>[],
        );
      case CommandIntent.completeTask:
        return ParsedCommand(
          intent: intent,
          title: title,
          titleIssue: titleIssue,
        );
      case CommandIntent.listTasks:
      case CommandIntent.unknown:
        return ParsedCommand(intent: intent);
    }
  }

  /// Совместимая обёртка: только успешно разобранный срок.
  (DateTime, DuePrecision)? parseDue(String text) {
    final result = parseDueDetailed(_normalize(text));
    final due = result.dueAt;
    if (due == null || result.issue != DueIssue.none) return null;
    return (due, result.precision);
  }

  /// Разбирает срок в уже нормализованном тексте без названия.
  DueParseResult parseDueDetailed(String normalized) {
    final now = _clock.now();
    final today = DateTime(now.year, now.month, now.day);

    final times = <_Mention<(int, int)>>[];
    final dates = <_Mention<DateTime>>[];
    var dateText = normalized;

    for (final match in _colonTime.allMatches(normalized)) {
      final hour = int.parse(match.group(1)!);
      final minute = int.parse(match.group(2)!);
      final second = match.group(3);
      if (hour > 23 ||
          minute > 59 ||
          (second != null && int.parse(second) > 59)) {
        return const DueParseResult(issue: DueIssue.invalidTime);
      }
      times.add(
        _Mention((hour, minute), _isSource(normalized, match.start)),
      );
      dateText = dateText.replaceRange(
        match.start,
        match.end,
        ' ' * (match.end - match.start),
      );
    }

    for (final match in _dotted.allMatches(dateText)) {
      final previous = _previousWord(dateText, match.start);
      if (previous != null &&
          (previous.startsWith('верси') || previous == 'v')) {
        continue;
      }
      final first = int.parse(match.group(1)!);
      final secondText = match.group(2)!;
      final second = int.parse(secondText);
      final yearText = match.group(3);
      final source = _sourcePrepositions.contains(previous);
      final looksLikeTime =
          yearText == null && secondText.length == 2 && first <= 23;

      if (yearText == null && previous == 'в') {
        // После «в» число с точкой — это время: «в 19.30».
        if (!looksLikeTime || second > 59) {
          return const DueParseResult(issue: DueIssue.invalidTime);
        }
        times.add(_Mention((first, second), source));
        continue;
      }

      final date = _resolveDate(first, second, yearText, today);
      if (date != null) {
        if (yearText != null && date.isBefore(today)) {
          return const DueParseResult(issue: DueIssue.inPast);
        }
        dates.add(_Mention(date, source));
        continue;
      }
      if (looksLikeTime && second <= 59) {
        // «на 18.30»: такой даты нет, но это корректное время.
        times.add(_Mention((first, second), source));
        continue;
      }
      return const DueParseResult(issue: DueIssue.invalidDate);
    }

    for (final word in _word.allMatches(normalized)) {
      final offset = switch (word.group(0)) {
        'сегодня' => 0,
        'завтра' => 1,
        'послезавтра' => 2,
        _ => null,
      };
      if (offset == null) continue;
      dates.add(
        _Mention(
          DateTime(today.year, today.month, today.day + offset),
          _isSource(normalized, word.start),
        ),
      );
    }

    final days = _pickDistinct(dates);
    if (days.length > 1) {
      return const DueParseResult(issue: DueIssue.conflictingDays);
    }
    final clock = _pickDistinct(times);
    if (clock.length > 1) {
      return const DueParseResult(issue: DueIssue.conflictingTimes);
    }

    final explicitDay = days.isEmpty ? null : days.single;
    final time = clock.isEmpty ? null : clock.single;
    if (explicitDay == null && time == null) return const DueParseResult();

    if (time == null) {
      if (explicitDay!.isBefore(today)) {
        return const DueParseResult(issue: DueIssue.inPast);
      }
      return DueParseResult(dueAt: explicitDay, precision: DuePrecision.date);
    }

    final day = explicitDay ?? today;
    var result = DateTime(day.year, day.month, day.day, time.$1, time.$2);
    if (!result.isAfter(now)) {
      if (explicitDay != null) {
        return const DueParseResult(issue: DueIssue.inPast);
      }
      // Только время, и оно уже прошло: ближайшее будущее — завтра.
      result = DateTime(day.year, day.month, day.day + 1, time.$1, time.$2);
    }
    return DueParseResult(dueAt: result, precision: DuePrecision.dateTime);
  }

  /// Различные значения без исходного срока «с …». Если указан только
  /// исходный срок, используются его значения.
  Set<T> _pickDistinct<T>(List<_Mention<T>> mentions) {
    final targets = mentions
        .where((_Mention<T> m) => !m.isSource)
        .map((_Mention<T> m) => m.value)
        .toSet();
    if (targets.isNotEmpty) return targets;
    return mentions.map((_Mention<T> m) => m.value).toSet();
  }

  DateTime? _resolveDate(int day, int month, String? yearText, DateTime today) {
    if (yearText != null) {
      final year = yearText.length == 2
          ? 2000 + int.parse(yearText)
          : int.parse(yearText);
      return _isValidDate(year, month, day) ? DateTime(year, month, day) : null;
    }
    // Без года — ближайшее будущее или сегодняшнее вхождение даты.
    // Для 29.02 это может быть через несколько лет.
    for (var year = today.year; year <= today.year + 4; year++) {
      if (!_isValidDate(year, month, day)) continue;
      final candidate = DateTime(year, month, day);
      if (!candidate.isBefore(today)) return candidate;
    }
    return null;
  }

  bool _isSource(String text, int position) =>
      _sourcePrepositions.contains(_previousWord(text, position));

  String? _previousWord(String text, int position) {
    final before = _word.allMatches(text.substring(0, position));
    return before.isEmpty ? null : before.last.group(0);
  }

  CommandIntent _detectIntent(List<String> words, String text) {
    // Намерение определяет самый ранний маркер: «Добавь задачу выполнить
    // отчёт» — создание, а не завершение.
    for (var i = 0; i < words.length; i++) {
      final word = words[i];
      final negated = i > 0 && (words[i - 1] == 'не' || words[i - 1] == 'нет');
      if (_isCreate(word, i, words)) {
        return negated ? CommandIntent.unknown : CommandIntent.createTask;
      }
      if (_isReschedule(word)) {
        return negated ? CommandIntent.unknown : CommandIntent.rescheduleTask;
      }
      if (_isComplete(word, i)) {
        // «Не выполнено», «Что выполнить?» — не команда завершить задачу.
        if (negated || words.contains('не') || text.contains('?')) {
          return CommandIntent.unknown;
        }
        return CommandIntent.completeTask;
      }
      if (_isList(word, words)) return CommandIntent.listTasks;
    }
    return CommandIntent.unknown;
  }

  static const Set<String> _createVerbs = <String>{
    'добавь',
    'добавьте',
    'добавить',
    'создай',
    'создайте',
    'создать',
    'запиши',
    'запишите',
    'записать',
    'напомни',
    'напомните',
  };

  bool _isCreate(String word, int index, List<String> words) {
    if (_createVerbs.contains(word)) return true;
    return word == 'новая' &&
        index + 1 < words.length &&
        words[index + 1] == 'задача';
  }

  bool _isReschedule(String word) =>
      word.startsWith('перенес') ||
      word.startsWith('передвин') ||
      word.startsWith('сдвин') ||
      word.startsWith('отлож');

  /// Повелительные, прошедшие и краткие формы. «Выполненные задачи»
  /// и «нужно выполнить» не считаются командой завершения.
  static const Set<String> _completeWords = <String>{
    'заверши',
    'завершите',
    'завершил',
    'завершила',
    'завершили',
    'завершено',
    'завершена',
    'выполни',
    'выполните',
    'выполнил',
    'выполнила',
    'выполнили',
    'выполнено',
    'выполнена',
    'выполненной',
    'сделал',
    'сделала',
    'сделали',
    'сделано',
    'сделана',
    'сделанной',
    'готово',
  };

  /// Инфинитив допустим только первым словом: «Завершить задачу».
  static const Set<String> _completeInfinitives = <String>{
    'завершить',
    'выполнить',
  };

  bool _isComplete(String word, int index) =>
      _completeWords.contains(word) ||
      (index == 0 && _completeInfinitives.contains(word));

  static const Set<String> _listVerbs = <String>{
    'покажи',
    'покажите',
    'показать',
    'выведи',
    'список',
    'какие',
  };

  bool _isList(String word, List<String> words) {
    if (word == 'запланировано') return true;
    return _listVerbs.contains(word) &&
        words.any((String w) => w.startsWith('задач') || w == 'дела');
  }

  /// Вырезает все названия в парных кавычках. Незакрытая кавычка не
  /// продолжает поиск внутри фрагмента, чтобы не взять кусок названия.
  _Quotes _extractQuoted(String message) {
    final titles = <String>[];
    final rest = StringBuffer();
    var index = 0;
    while (index < message.length) {
      final open = message[index];
      final closers = _quotePairs[open];
      if (closers == null) {
        rest.write(open);
        index++;
        continue;
      }
      final end = _findClose(message, index, open, closers);
      if (end == null) {
        rest.write(' ');
        rest.write(message.substring(index + 1));
        return _Quotes(titles: titles, rest: rest.toString(), unbalanced: true);
      }
      final title = message.substring(index + 1, end).trim();
      if (title.isNotEmpty) titles.add(title);
      rest.write(' ');
      index = end + 1;
    }
    return _Quotes(titles: titles, rest: rest.toString(), unbalanced: false);
  }

  int? _findClose(
    String message,
    int start,
    String open,
    Set<String> closers,
  ) {
    // Вложенность поддерживается для разных открывающей и закрывающей:
    // «Отчёт по «Ромашке»».
    final nests = !closers.contains(open);
    var depth = 1;
    for (var i = start + 1; i < message.length; i++) {
      final char = message[i];
      if (nests && char == open) {
        depth++;
      } else if (closers.contains(char)) {
        depth--;
        if (depth == 0) return i;
      }
    }
    return null;
  }

  String _normalize(String text) => text
      .trim()
      .toLowerCase()
      .replaceAll('ё', 'е')
      .replaceAll(RegExp(r'\s+'), ' ');

  bool _isValidDate(int year, int month, int day) {
    if (month < 1 || month > 12 || day < 1) return false;
    final candidate = DateTime(year, month, day);
    return candidate.month == month && candidate.day == day;
  }
}

final class _Quotes {
  const _Quotes({
    required this.titles,
    required this.rest,
    required this.unbalanced,
  });

  final List<String> titles;
  final String rest;
  final bool unbalanced;
}

final class _Mention<T> {
  const _Mention(this.value, this.isSource);

  final T value;
  final bool isSource;
}
