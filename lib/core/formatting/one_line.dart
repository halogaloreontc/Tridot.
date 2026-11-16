/// Текст для мест, где он виден вне приложения одной строкой: уведомление
/// (ADR-029), виджет рабочего стола (ADR-034).
library;

final RegExp _control = RegExp(r'[\u0000-\u001f\u007f-\u009f]');
final RegExp _spaces = RegExp(r'\s+');

/// [text] в одну строку: управляющие знаки и переводы строк — пробелом,
/// пробелы подряд — одним, по краям — без них. Длиннее [max] знаков —
/// обрезается с «…»: вместе с ним не длиннее [max], пробела перед «…» нет.
String oneLine(String text, {required int max}) {
  final line = text.replaceAll(_control, ' ').replaceAll(_spaces, ' ').trim();
  if (line.runes.length <= max) return line;
  final cut = String.fromCharCodes(line.runes.take(max - 1)).trimRight();
  return '$cut…';
}
