/// Текст по описанию `assistant/1`: порт функций `tools/assistant/core.mjs`
/// приложения halowarekeep один к одному (`askText`, `askNum`,
/// `askPlural`, `askDate`, `askFill`, `askTidy`, `askBody`).
///
/// Числа, даты и формы слов коннектор по описанию пишет только этими
/// функциями, а не своими (`formatDue`): иначе склад и «Tridot» сказали бы
/// одно и то же по-разному.
library;

/// Значения нет вовсе (в JavaScript — `undefined`), в отличие от `null`
/// из JSON. Нужно, чтобы поиск по цепочке шёл дальше только при
/// отсутствии значения, как в `core.mjs`.
final class Absent {
  const Absent._();

  @override
  String toString() => 'undefined';
}

/// Единственное «значения нет».
const Absent absent = Absent._();

/// Поля фразы: `{q}`, `{cell}` — строчная латиница.
final RegExp askSlotPattern = RegExp(r'\{([a-z][a-z0-9_]*)\}');

final RegExp _quotes = RegExp('[«»"“”]');
final RegExp _spaces = RegExp(r'\s+');
final RegExp _edges = RegExp(r'^[\s,.!?;:]+|[\s,.!?;:]+$');

/// Фраза в общий вид: строчные, «ё» → «е», без кавычек, без лишних
/// пробелов и знаков по краям.
String askText(Object? value) => (value == null ? '' : jsString(value))
    .toLowerCase()
    .replaceAll('ё', 'е')
    .replaceAll(_quotes, '')
    .replaceAll(_spaces, ' ')
    .replaceAll(_edges, '');

/// `String(v)` из JavaScript для значений JSON.
String jsString(Object? value) {
  if (value == null) return 'null';
  if (identical(value, absent)) return 'undefined';
  if (value is num) return _jsNumber(value.toDouble());
  if (value is List) {
    return value.map(_element).join(',');
  }
  if (value is Map) return '[object Object]';
  return value.toString();
}

/// Элемент массива в `join`: `null` — пустая строка.
String _element(Object? e) =>
    e == null || identical(e, absent) ? '' : jsString(e);

/// `Number(v)` из JavaScript; `NaN`, если не число.
double jsNumber(Object? value) {
  if (identical(value, absent)) return double.nan;
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  if (value is bool) return value ? 1 : 0;
  if (value is String) {
    final text = value.trim();
    if (text.isEmpty) return 0;
    if (!RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$').hasMatch(text)) {
      return double.nan;
    }
    return double.parse(text);
  }
  if (value is List) {
    if (value.isEmpty) return 0;
    if (value.length == 1) return jsNumber(jsString(value.single));
  }
  return double.nan;
}

/// `Math.round` из JavaScript: половина — вверх.
double _jsRound(double value) => (value + 0.5).floorToDouble();

/// Число как его пишет JavaScript: `12`, `2.5`, без «.0».
String _jsNumber(double value) {
  if (value.isNaN) return 'NaN';
  if (value.isInfinite) return value > 0 ? 'Infinity' : '-Infinity';
  if (value == value.truncateToDouble() && value.abs() < 1e21) {
    return BigInt.from(value).toString();
  }
  return value.toString();
}

final RegExp _thousands = RegExp(r'\B(?=(\d{3})+(?!\d))');

/// Число для человека: «1 234», «2,5», минус «−», до сотых.
String askNum(Object? value) {
  final n = jsNumber(value);
  if (!n.isFinite) {
    return value == null || identical(value, absent) ? '' : jsString(value);
  }
  final rounded = _jsRound(n * 100) / 100;
  final parts = _jsNumber(rounded.abs()).split('.');
  final whole = parts[0].replaceAll(_thousands, ' ');
  final fraction = parts.length > 1 ? ',${parts[1]}' : '';
  return '${rounded < 0 ? '−' : ''}$whole$fraction';
}

/// «1 приход», «2 прихода», «5 приходов»: [forms] — `один,два,пять`.
String askPlural(Object? value, String forms) {
  final number = jsNumber(value);
  final n = (number.isNaN || number == 0 ? 0 : _jsRound(number)).abs();
  final list = forms.split(',').map((String s) => s.trim()).toList();
  String at(int i) => i < list.length ? list[i] : '';
  final one = at(0);
  final few = at(1);
  final many = at(2);
  final String word;
  if (n % 10 == 1 && n % 100 != 11) {
    word = one;
  } else if (n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 12 || n % 100 > 14)) {
    word = few;
  } else {
    word = many;
  }
  final shown = word.isNotEmpty
      ? word
      : many.isNotEmpty
          ? many
          : one;
  return '${askNum(value)} $shown';
}

final RegExp _isoDay = RegExp(r'^(\d{4})-(\d{2})-(\d{2})');

/// «2026-11-05» → «05.11» (этот год) или «05.11.2025».
String askDate(Object? value, ManifestVars? vars) {
  final text = _truthy(value) ? jsString(value) : '';
  final match = _isoDay.firstMatch(text);
  if (match == null) return text;
  final year = vars?.today.substring(0, 4) ?? '';
  final shown = '${match[3]}.${match[2]}';
  return match[1] == year ? shown : '$shown.${match[1]}';
}

/// Значение «истинно» в смысле JavaScript.
bool _truthy(Object? value) {
  if (value == null || identical(value, absent)) return false;
  if (value is bool) return value;
  if (value is num) return value != 0 && !value.isNaN;
  if (value is String) return value.isNotEmpty;
  return true;
}

/// Местный день «ГГГГ-ММ-ДД» со сдвигом [shift] в днях.
String askDay(DateTime now, [int shift = 0]) {
  final day = DateTime(now.year, now.month, now.day + shift);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${day.year.toString().padLeft(4, '0')}-${two(day.month)}-'
      '${two(day.day)}';
}

/// Встроенные значения: `{$today}`, `{$yesterday}`, `{$today-6}`, `{$tz}`,
/// `{$zone}`.
final class ManifestVars {
  ManifestVars(this.now, {this.zone = ''})
      : today = askDay(now),
        yesterday = askDay(now, -1),
        // Как `getTimezoneOffset()`: минуты от местного времени до UTC,
        // для Москвы — «-180». Строкой, как в core.mjs.
        tz = '${-now.timeZoneOffset.inMinutes}';

  final DateTime now;
  final String today;
  final String yesterday;
  final String tz;

  /// IANA-имя пояса. В Dart без пакета его не узнать, поэтому пусто: сервер
  /// тогда считает по [tz] (в России перехода на летнее время нет).
  final String zone;

  static final RegExp _shift = RegExp(r'^today([+-]\d{1,3})$');

  /// Значение `{$name}` или [absent].
  Object? lookup(String name) {
    final shift = _shift.firstMatch(name);
    if (shift != null) return askDay(now, int.parse(shift[1]!));
    return switch (name) {
      'today' => today,
      'yesterday' => yesterday,
      'tz' => tz,
      'zone' => zone,
      'now' => now.toIso8601String(),
      _ => absent,
    };
  }
}

/// Значение из [value] по пути «a.b.c»; [absent], если его нет.
Object? askGet(Object? value, String? path) {
  if (path == null || path.isEmpty) return value;
  var current = value;
  for (final key in path.split('.')) {
    if (current is Map) {
      current = current.containsKey(key) ? current[key] : absent;
    } else if (current is List) {
      final index = int.tryParse(key);
      if (key == 'length') {
        current = current.length;
      } else {
        current = index != null && index >= 0 && index < current.length
            ? current[index]
            : absent;
      }
    } else {
      return absent;
    }
  }
  return current;
}

final RegExp _placeholder =
    RegExp(r'\{([$a-z][^{}|]*)((?:\|[^{}]*)?)\}', caseSensitive: false);

/// Подстановка в шаблон: `{путь}`, `{$встроенное}`, `{путь|фильтр:параметр}`.
/// Фильтры: `num`, `plural:приход,прихода,приходов`, `date`, `or:текст`,
/// `if:текст`, `unless:текст`. Значение ищется по цепочке [chain]: строка
/// списка, строка выше, ответ, поля фразы.
String askFill(Object? template, List<Object?> chain, ManifestVars? vars) {
  if (template == null || identical(template, absent)) return '';
  Object? look(String path) {
    if (path.startsWith(r'$')) return vars?.lookup(path.substring(1)) ?? absent;
    for (final context in chain) {
      final value = askGet(context, path);
      if (!identical(value, absent)) return value;
    }
    return absent;
  }

  return jsString(template).replaceAllMapped(_placeholder, (Match m) {
    final value = look(m[1]!.trim());
    final filters =
        m[2]!.isEmpty ? const <String>[] : m[2]!.substring(1).split('|');
    String? shown;
    for (final filter in filters) {
      final colon = filter.indexOf(':');
      final name = (colon < 0 ? filter : filter.substring(0, colon)).trim();
      final arg = colon < 0 ? '' : filter.substring(colon + 1);
      final empty = value == null ||
          identical(value, absent) ||
          value == '' ||
          value == false ||
          (value is num && value == 0) ||
          (value is List && value.isEmpty);
      switch (name) {
        case 'num':
          shown = askNum(value);
        case 'plural':
          shown = askPlural(value, arg);
        case 'date':
          shown = askDate(value, vars);
        case 'or':
          shown = empty ? arg : shown ?? jsString(value);
        case 'if':
          shown = empty ? '' : arg;
        case 'unless':
          shown = empty ? arg : '';
      }
    }
    if (shown != null) return shown;
    if (value == null || identical(value, absent) || value == false) return '';
    if (value is num) return askNum(value);
    if (value is List) {
      return value.map(_element).join(', ');
    }
    if (value is Map) return '';
    return jsString(value);
  });
}

final RegExp _dots = RegExp(r'\s*·\s*(·\s*)+');
final RegExp _edgeDots = RegExp(r'^\s*·\s*|\s*·\s*$');

/// Пустые хвосты после подстановки: «Приход 12 · » → «Приход 12».
String askTidy(String? text) => (text ?? '')
    .replaceAll(_dots, ' · ')
    .replaceAll(_edgeDots, '')
    .replaceAll(_spaces, ' ')
    .trim();

final RegExp _wholeField = RegExp(
  r'^\{(\$?[a-z][a-z0-9_+-]*)\}$',
  caseSensitive: false,
);

/// Тело запроса по шаблону `call.body`: поля фразы [slots] и встроенные
/// значения. Значение-поле целиком передаётся как есть (число остаётся
/// числом); отсутствующее значение в тело не попадает, как у
/// `JSON.stringify`.
Map<String, Object?> askBody(
  Map<String, Object?> body,
  Map<String, String> slots,
  ManifestVars vars,
) {
  final out = <String, Object?>{};
  for (final MapEntry(:key, :value) in body.entries) {
    if (value is! String) {
      out[key] = value;
      continue;
    }
    final whole = _wholeField.firstMatch(value);
    if (whole != null) {
      final name = whole[1]!;
      final found = name.startsWith(r'$')
          ? vars.lookup(name.substring(1))
          : slots.containsKey(name)
              ? slots[name]
              : absent;
      if (!identical(found, absent)) out[key] = found;
      continue;
    }
    out[key] = askFill(value, <Object?>[slots], vars);
  }
  return out;
}
