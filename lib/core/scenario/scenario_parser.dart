import '../models/task.dart';
import '../services/clock.dart';

enum CommandIntent {
  createTask,
  listTasks,
  completeTask,
  rescheduleTask,
  unknown
}

final class ParsedCommand {
  const ParsedCommand({
    required this.intent,
    this.title,
    this.dueAt,
    this.duePrecision = DuePrecision.dateTime,
  });

  final CommandIntent intent;
  final String? title;
  final DateTime? dueAt;
  final DuePrecision duePrecision;
}

/// Первый узкий набор правил. Он намеренно требует кавычки для новых названий,
/// чтобы не угадывать границы свободного русского текста в прототипе.
final class ScenarioParser {
  ScenarioParser({required Clock clock}) : _clock = clock;

  final Clock _clock;

  ParsedCommand parse(String message) {
    final normalized =
        message.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) {
      return const ParsedCommand(intent: CommandIntent.unknown);
    }

    if (_containsAny(
      normalized,
      const <String>['перенеси', 'сдвинь', 'передвинь'],
    )) {
      final due = parseDue(normalized);
      return ParsedCommand(
        intent: CommandIntent.rescheduleTask,
        dueAt: due?.$1,
        duePrecision: due?.$2 ?? DuePrecision.dateTime,
      );
    }

    if (_containsAny(
      normalized,
      const <String>[
        'заверши',
        'выполнил',
        'выполнила',
        'отметь выполненной',
      ],
    )) {
      return const ParsedCommand(intent: CommandIntent.completeTask);
    }

    if (_containsAny(
      normalized,
      const <String>['покажи задачи', 'список задач', 'что запланировано'],
    )) {
      return const ParsedCommand(intent: CommandIntent.listTasks);
    }

    if (_containsAny(
      normalized,
      const <String>['добавь', 'создай', 'новая задача'],
    )) {
      final due = parseDue(normalized);
      return ParsedCommand(
        intent: CommandIntent.createTask,
        title: _extractQuotedTitle(message),
        dueAt: due?.$1,
        duePrecision: due?.$2 ?? DuePrecision.dateTime,
      );
    }

    return const ParsedCommand(intent: CommandIntent.unknown);
  }

  (DateTime, DuePrecision)? parseDue(String normalized) {
    final timeMatch =
        RegExp(r'\b([01]?\d|2[0-3])[:.]([0-5]\d)\b').firstMatch(normalized);
    final hasTomorrow = normalized.contains('завтра');
    final hasToday = normalized.contains('сегодня');
    if (!hasTomorrow && !hasToday && timeMatch == null) return null;

    final now = _clock.now();
    var day = now;
    if (hasTomorrow) day = now.add(const Duration(days: 1));
    if (timeMatch == null) {
      return (DateTime(day.year, day.month, day.day), DuePrecision.date);
    }

    final hour = int.parse(timeMatch.group(1)!);
    final minute = int.parse(timeMatch.group(2)!);
    var result = DateTime(day.year, day.month, day.day, hour, minute);
    if (!hasTomorrow && !hasToday && !result.isAfter(now)) {
      result = result.add(const Duration(days: 1));
    }
    return (result, DuePrecision.dateTime);
  }

  String? _extractQuotedTitle(String message) {
    final match = RegExp('[«"]([^»"]+)[»"]').firstMatch(message);
    return match?.group(1)?.trim();
  }

  bool _containsAny(String message, List<String> markers) {
    return markers.any(message.contains);
  }
}
