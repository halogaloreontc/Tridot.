import '../passwords/keyboard_layouts.dart';
import 'route_policy.dart';

/// Набрано не в той раскладке: «yfgjvyb pfdnhf d 10 gjpdjybnm vfvt» —
/// «напомни завтра в 10 позвонить маме» (ЙЦУКЕН на клавишах QWERTY).
///
/// Это спасательный проход: маршрутизатор зовёт его, только если фразу как
/// есть не понял никто (или ответила только беседа), а исправленную понял
/// навык. Исправление — не догадка по смыслу, а та же клавиша в другой
/// раскладке, поэтому оно и не подходит под любую английскую фразу:
/// «buy milk» превращается в бессмыслицу, которую никто не берёт.
///
/// Не трогается: фраза с кириллицей, ссылки, почта, слова из букв и цифр
/// вперемешку (так выглядят пароли и коды), меньше двух латинских букв.
abstract final class LayoutFix {
  /// Варианты исправления по порядку или пустой список. Первый — «,» и «.»
  /// рядом с буквой — тоже буквы «б» и «ю»: на клавиатуре с ЙЦУКЕН точка и
  /// запятая — на других клавишах («/» и «?»), так что «ytltk.» — это
  /// «неделю», а «,elbkmybr» — «будильник». Второй — как на экранной
  /// клавиатуре телефона, где «,» и «.» — свои клавиши: буквы они только
  /// внутри слова («hfp,elb» — «разбуди»).
  static List<String> candidates(String text) {
    if (text.length > 400 || !_eligible(text)) return const <String>[];
    final keys = _map(text, phone: false);
    final phone = _map(text, phone: true);
    return <String>[keys, if (phone != keys) phone];
  }

  /// Взять ли исправленный разбор: фразу как есть не понял никто явно, а
  /// исправленную — навык, без спора. Запасной ответ беседы («спасибо»,
  /// «пока») — только если фразу как есть не понял совсем никто, и не
  /// справочный вопрос: он отвечает на что угодно.
  static bool prefer(RouteDecision original, RouteDecision repaired) {
    final was = original.winner;
    if (original.isAmbiguous || (was != null && !was.fallback)) return false;
    final winner = repaired.winner;
    if (winner == null || repaired.isAmbiguous) return false;
    if (!winner.fallback) return true;
    return was == null && !winner.commandId.endsWith('.question');
  }

  static final RegExp _blocked = RegExp(r'://|www\.|@|\.(?:ru|com|org|net)\b');
  static final RegExp _mixedToken = RegExp(
    r'(?:[a-zA-Z][^\s]*\d|\d[^\s]*[a-zA-Z])',
  );

  static bool _eligible(String text) {
    var latin = 0;
    for (final rune in text.runes) {
      if (KeyboardLayouts.isCyrillic(rune)) return false;
      if (KeyboardLayouts.isLatinLetter(rune)) latin++;
    }
    if (latin < 2) return false;
    if (_blocked.hasMatch(text.toLowerCase())) return false;
    return !_mixedToken.hasMatch(text);
  }

  static String _map(String text, {required bool phone}) {
    final runes = text.runes.toList();
    final out = StringBuffer();
    for (var i = 0; i < runes.length; i++) {
      final rune = runes[i];
      final char = String.fromCharCode(rune);
      final prev = i > 0 ? runes[i - 1] : null;
      final next = i + 1 < runes.length ? runes[i + 1] : null;
      bool latin(int? r) => r != null && KeyboardLayouts.isLatinLetter(r);
      bool digit(int? r) => r != null && KeyboardLayouts.isDigit(r);
      switch (char) {
        // На ЙЦУКЕН «б» и «ю» — на клавишах «,» и «.»: рядом с буквой это
        // буквы; на телефоне — только внутри слова ([phone]).
        case ',' || '.':
          final letter =
              phone ? latin(prev) && latin(next) : latin(prev) || latin(next);
          out.write(
            letter
                ? String.fromCharCodes(KeyboardLayouts.latinToCyrillic([rune]))
                : char,
          );
        // Знаки русской раскладки на тех же клавишах: «?» — запятая, «/» —
        // точка, «&» — вопрос, «^» между цифрами — двоеточие («6^30»).
        case '?':
          out.write(',');
        case '/':
          out.write('.');
        case '&':
          out.write('?');
        case '^' when digit(prev) && digit(next):
          out.write(':');
        // «10:30» — время и в английской раскладке.
        case ':' when digit(prev) && digit(next):
          out.write(':');
        case r'$':
          out.write(';');
        default:
          out.write(
            String.fromCharCodes(KeyboardLayouts.latinToCyrillic([rune])),
          );
      }
    }
    return out.toString();
  }
}
