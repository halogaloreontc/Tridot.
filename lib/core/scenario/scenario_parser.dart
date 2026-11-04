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

  /// Явно указанный день («сегодня», дата) вместе со временем уже прошёл.
  inPast,

  /// Дата вида 31.02 не существует.
  invalidDate,

  /// В команде несколько противоречащих дней: «сегодня … завтра».
  conflictingDays,
}

final class ParsedCommand {
  const ParsedCommand({
    required this.intent,
    this.title,
    this.dueAt,
    this.duePrecision = DuePrecision.dateTime,
    this.dueIssue = DueIssue.none,
  });

  final CommandIntent intent;
  final String? title;
  final DateTime? dueAt;
  final DuePrecision duePrecision;
  final DueIssue dueIssue;
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
/// Название новой задачи по-прежнему требуется в кавычках. Текст в кавычках
/// вырезается до распознавания намерения и срока, поэтому слова и даты внутри
/// названия («Завершить отчёт», «Планёрка завтра») не меняют смысл команды.
final class ScenarioParser {
  ScenarioParser({required Clock clock}) : _clock = clock;

  final Clock _clock;

  /// Открывающая кавычка → закрывающая. «Ёлочки» могут быть вложенными.
  static const Map<String, String> _quotePairs = <String, String>{
    '«': '»',
    '“': '”',
    '„': '“',
    '"': '"',
  };

  static final RegExp _word = RegExp('[a-zа-яё0-9]+');
  static final RegExp _colonTime =
      RegExp(r'(?<![\d.:])([01]?\d|2[0-3]):([0-5]\d)(?![\d:])');
  static final RegExp _dottedTimeAfterV =
      RegExp(r'(?<![a-zа-яё])в\s+([01]?\d|2[0-3])\.([0-5]\d)(?![\d.])');
  static final RegExp _date =
      RegExp(r'(?<![\d.:])(\d{1,2})\.(\d{1,2})(?:\.(\d{4}))?(?![\d:])');

  ParsedCommand parse(String message) {
    final quoted = _extractQuoted(message);
    final rest = _normalize(quoted?.rest ?? message);
    final words = _word
        .allMatches(rest)
        .map((Match m) => m.group(0)!)
        .toList(growable: false);
    if (words.isEmpty && quoted == null) {
      return const ParsedCommand(intent: CommandIntent.unknown);
    }

    final intent = _detectIntent(words, rest);
    switch (intent) {
      case CommandIntent.createTask:
        final due = parseDueDetailed(rest);
        return ParsedCommand(
          intent: intent,
          title: quoted?.title,
          dueAt: due.dueAt,
          duePrecision: due.precision,
          dueIssue: due.issue,
        );
      case CommandIntent.rescheduleTask:
        final due = parseDueDetailed(rest);
        return ParsedCommand(
          intent: intent,
          dueAt: due.dueAt,
          duePrecision: due.precision,
          dueIssue: due.issue,
        );
      case CommandIntent.listTasks:
      case CommandIntent.completeTask:
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
    final words = _word.allMatches(normalized).map((Match m) => m.group(0)!);
    final dayWords = <int>{};
    for (final word in words) {
      if (word == 'сегодня') dayWords.add(0);
      if (word == 'завтра') dayWords.add(1);
      if (word == 'послезавтра') dayWords.add(2);
    }

    final now = _clock.now();
    final today = DateTime(now.year, now.month, now.day);

    // Сначала время: «в 18.00» не должно разбираться как дата 18 декабря.
    var timeSource = normalized;
    int? hour;
    int? minute;
    final colon = _colonTime.firstMatch(normalized);
    final dotted =
        colon == null ? _dottedTimeAfterV.firstMatch(normalized) : null;
    final timeMatch = colon ?? dotted;
    if (timeMatch != null) {
      hour = int.parse(timeMatch.group(1)!);
      minute = int.parse(timeMatch.group(2)!);
      timeSource = normalized.replaceRange(
        timeMatch.start,
        timeMatch.end,
        ' ',
      );
    }

    DateTime? explicitDate;
    final dateMatch = _date.firstMatch(timeSource);
    if (dateMatch != null) {
      final day = int.parse(dateMatch.group(1)!);
      final month = int.parse(dateMatch.group(2)!);
      final yearText = dateMatch.group(3);
      var year = yearText == null ? today.year : int.parse(yearText);
      if (!_isValidDate(year, month, day)) {
        return const DueParseResult(issue: DueIssue.invalidDate);
      }
      var candidate = DateTime(year, month, day);
      if (yearText == null && candidate.isBefore(today)) {
        year += 1;
        if (!_isValidDate(year, month, day)) {
          return const DueParseResult(issue: DueIssue.invalidDate);
        }
        candidate = DateTime(year, month, day);
      }
      explicitDate = candidate;
    }

    final daySpecs = dayWords.length + (explicitDate == null ? 0 : 1);
    if (daySpecs > 1) {
      return const DueParseResult(issue: DueIssue.conflictingDays);
    }
    if (daySpecs == 0 && hour == null) return const DueParseResult();

    final DateTime day;
    if (explicitDate != null) {
      day = explicitDate;
    } else if (dayWords.isNotEmpty) {
      day = DateTime(today.year, today.month, today.day + dayWords.single);
    } else {
      day = today;
    }

    if (hour == null || minute == null) {
      return DueParseResult(dueAt: day, precision: DuePrecision.date);
    }

    var result = DateTime(day.year, day.month, day.day, hour, minute);
    if (!result.isAfter(now)) {
      if (daySpecs > 0) {
        return DueParseResult(dueAt: result, issue: DueIssue.inPast);
      }
      // Только время, и оно уже прошло: ближайшее будущее — завтра.
      result = DateTime(day.year, day.month, day.day + 1, hour, minute);
    }
    return DueParseResult(dueAt: result, precision: DuePrecision.dateTime);
  }

  CommandIntent _detectIntent(List<String> words, String text) {
    // Намерение определяет самый ранний маркер: «Добавь задачу выполнить
    // отчёт» — создание, а не завершение.
    for (var i = 0; i < words.length; i++) {
      final word = words[i];
      if (_isCreate(word, i, words)) return CommandIntent.createTask;
      if (_isReschedule(word)) return CommandIntent.rescheduleTask;
      if (_isComplete(word)) return CommandIntent.completeTask;
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

  static const Set<String> _completeWords = <String>{
    'готово',
    'сделано',
    'сделал',
    'сделала',
  };

  bool _isComplete(String word) =>
      word.startsWith('заверш') ||
      word.startsWith('выполн') ||
      _completeWords.contains(word);

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

  /// Находит первое название в парных кавычках и возвращает его вместе
  /// с текстом команды без этого фрагмента.
  _Quoted? _extractQuoted(String message) {
    for (var start = 0; start < message.length; start++) {
      final open = message[start];
      final close = _quotePairs[open];
      if (close == null) continue;
      var depth = 1;
      for (var end = start + 1; end < message.length; end++) {
        final char = message[end];
        if (char == close && open != close) {
          depth--;
        } else if (char == close) {
          depth = 0;
        } else if (char == open) {
          depth++;
        }
        if (depth == 0) {
          final title = message.substring(start + 1, end).trim();
          if (title.isEmpty) break;
          return _Quoted(
            title: title,
            rest: '${message.substring(0, start)} '
                '${message.substring(end + 1)}',
          );
        }
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

final class _Quoted {
  const _Quoted({required this.title, required this.rest});

  final String title;
  final String rest;
}
