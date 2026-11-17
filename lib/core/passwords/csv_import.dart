import 'dart:convert';
import 'dart:typed_data';

import 'import_rules.dart';
import 'secret_bytes.dart';
import 'vault_format.dart';

/// Кодировка файла CSV. Файл, пересохранённый в Excel, часто в
/// Windows-1251: это не «порча», а вопрос человеку (5.6).
enum CsvEncoding { utf8, windows1251 }

/// Почему файл не разобран целиком (без частичного импорта).
enum CsvFailure {
  /// Больше 5 МБ.
  tooLarge,

  /// Больше 10 000 записей: [CsvException.count] — сколько в файле.
  tooMany,

  /// Незакрытая кавычка или слишком много колонок.
  malformed,

  /// Ни одной строки.
  empty,
}

/// Ошибка разбора CSV: только код и число, без содержимого файла.
final class CsvException implements Exception {
  const CsvException(this.failure, {this.count = 0});

  final CsvFailure failure;
  final int count;

  @override
  String toString() => 'CsvException(${failure.name})';
}

/// Разобранная таблица: поля — байты UTF-8 (пароль не становится строкой).
/// [wipe] затирает все поля.
final class CsvTable {
  CsvTable._(this.rows, this.lines, this.overlong, this.delimiter);

  final List<List<Uint8List>> rows;

  /// Строка файла (с 1), с которой начинается каждая строка таблицы.
  final List<int> lines;

  /// Строка таблицы с полем длиннее предела или лишними колонками.
  final List<bool> overlong;
  final int delimiter;

  void wipe() {
    for (final row in rows) {
      for (final field in row) {
        field.fillRange(0, field.length, 0);
      }
    }
  }

  @override
  String toString() => 'CsvTable(${rows.length})';
}

/// Свой разборщик RFC 4180 (~ без пакета `csv`: меньше кода, через который
/// идут пароли): кавычки, `""`, переводы строк в полях, BOM, CRLF,
/// разделитель `,` / `;` / табуляция — по первой строке.
abstract final class CsvReader {
  static const int maxBytes = 5 * 1024 * 1024;
  static const int maxRecords = 10000;
  static const int maxColumns = 64;

  /// Поле длиннее — строка помечается [CsvTable.overlong] (запись будет
  /// пропущена), байты дальше не копятся.
  static const int maxField = 64 * 1024;

  static const int _quote = 0x22;
  static const int _cr = 0x0D;
  static const int _lf = 0x0A;

  /// Корректный ли UTF-8 (без создания строки из файла).
  static bool isUtf8(Uint8List bytes) {
    var i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      int need;
      if (b < 0x80) {
        i++;
        continue;
      } else if (b >= 0xC2 && b <= 0xDF) {
        need = 1;
      } else if (b >= 0xE0 && b <= 0xEF) {
        need = 2;
      } else if (b >= 0xF0 && b <= 0xF4) {
        need = 3;
      } else {
        return false;
      }
      if (i + need >= bytes.length) return false;
      for (var k = 1; k <= need; k++) {
        if (bytes[i + k] & 0xC0 != 0x80) return false;
      }
      i += need + 1;
    }
    return true;
  }

  /// Windows-1251 → UTF-8 по своей таблице на 128 значений (без пакета).
  /// Вызывающий затирает и исходные байты, и результат.
  static Uint8List windows1251ToUtf8(Uint8List bytes) {
    var size = 0;
    for (final b in bytes) {
      size += b < 0x80 ? 1 : (_cp1251[b - 0x80] < 0x800 ? 2 : 3);
    }
    final out = Uint8List(size);
    var o = 0;
    for (final b in bytes) {
      if (b < 0x80) {
        out[o++] = b;
        continue;
      }
      final c = _cp1251[b - 0x80];
      if (c < 0x800) {
        out[o++] = 0xC0 | (c >> 6);
        out[o++] = 0x80 | (c & 0x3F);
      } else {
        out[o++] = 0xE0 | (c >> 12);
        out[o++] = 0x80 | ((c >> 6) & 0x3F);
        out[o++] = 0x80 | (c & 0x3F);
      }
    }
    return out;
  }

  /// Разбор байтов UTF-8. Пустые строки не считаются. Больше
  /// [maxRecords] + 1 строк — [CsvFailure.tooMany] целиком.
  static CsvTable parse(Uint8List bytes) {
    var i = 0;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      i = 3;
    }
    final delimiter = _delimiter(bytes, i);
    final rows = <List<Uint8List>>[];
    final lines = <int>[];
    final overlong = <bool>[];
    var total = 0;
    var line = 1;
    var rowLine = 1;
    var row = <Uint8List>[];
    var rowLong = false;
    var buffer = Uint8List(256);
    var length = 0;
    var quoted = false;
    var started = false;

    void append(int byte) {
      if (length >= maxField) {
        rowLong = true;
        return;
      }
      if (length == buffer.length) {
        final next = Uint8List(buffer.length * 2)..setRange(0, length, buffer);
        buffer.fillRange(0, buffer.length, 0);
        buffer = next;
      }
      buffer[length++] = byte;
    }

    void endField() {
      if (row.length >= maxColumns) {
        rowLong = true;
      } else {
        row.add(Uint8List.fromList(buffer.sublist(0, length)));
      }
      buffer.fillRange(0, length, 0);
      length = 0;
      started = false;
    }

    void endRow() {
      final blank = row.every((Uint8List f) => f.isEmpty) && !rowLong;
      if (!blank) {
        total++;
        if (total <= maxRecords + 1) {
          rows.add(row);
          lines.add(rowLine);
          overlong.add(rowLong);
        } else {
          for (final f in row) {
            f.fillRange(0, f.length, 0);
          }
        }
      }
      row = <Uint8List>[];
      rowLong = false;
    }

    try {
      while (i < bytes.length) {
        final c = bytes[i];
        if (quoted) {
          if (c == _quote) {
            if (i + 1 < bytes.length && bytes[i + 1] == _quote) {
              append(_quote);
              i += 2;
            } else {
              quoted = false;
              i++;
            }
            continue;
          }
          if (c == _lf) line++;
          append(c);
          i++;
          continue;
        }
        if (c == delimiter) {
          endField();
          i++;
        } else if (c == _cr || c == _lf) {
          endField();
          endRow();
          if (c == _cr && i + 1 < bytes.length && bytes[i + 1] == _lf) i++;
          i++;
          line++;
          rowLine = line;
        } else if (c == _quote && !started) {
          quoted = true;
          started = true;
          i++;
        } else {
          append(c);
          started = true;
          i++;
        }
      }
      if (quoted) throw const CsvException(CsvFailure.malformed);
      if (length > 0 || row.isNotEmpty || started) {
        endField();
        endRow();
      }
    } catch (_) {
      for (final r in rows) {
        for (final f in r) {
          f.fillRange(0, f.length, 0);
        }
      }
      rethrow;
    } finally {
      buffer.fillRange(0, buffer.length, 0);
    }
    if (total == 0) throw const CsvException(CsvFailure.empty);
    if (total > maxRecords + 1) {
      for (final r in rows) {
        for (final f in r) {
          f.fillRange(0, f.length, 0);
        }
      }
      throw CsvException(CsvFailure.tooMany, count: total - 1);
    }
    return CsvTable._(rows, lines, overlong, delimiter);
  }

  /// Разделитель по первой строке: чаще всего встреченный вне кавычек
  /// из `,`, `;`, табуляции.
  static int _delimiter(Uint8List bytes, int start) {
    var comma = 0;
    var semicolon = 0;
    var tab = 0;
    var quoted = false;
    for (var i = start; i < bytes.length; i++) {
      final c = bytes[i];
      if (c == _quote) {
        quoted = !quoted;
      } else if (!quoted) {
        if (c == _lf || c == _cr) break;
        if (c == 0x2C) comma++;
        if (c == 0x3B) semicolon++;
        if (c == 0x09) tab++;
      }
    }
    if (semicolon > comma && semicolon >= tab) return 0x3B;
    if (tab > comma && tab > semicolon) return 0x09;
    return 0x2C;
  }

  /// Windows-1251, верхняя половина (0x80–0xFF) → кодовые точки.
  static const List<int> _cp1251 = <int>[
    0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021, //
    0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
    0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0xFFFD, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
    0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7,
    0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
    0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7,
    0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
    0x0410, 0x0411, 0x0412, 0x0413, 0x0414, 0x0415, 0x0416, 0x0417,
    0x0418, 0x0419, 0x041A, 0x041B, 0x041C, 0x041D, 0x041E, 0x041F,
    0x0420, 0x0421, 0x0422, 0x0423, 0x0424, 0x0425, 0x0426, 0x0427,
    0x0428, 0x0429, 0x042A, 0x042B, 0x042C, 0x042D, 0x042E, 0x042F,
    0x0430, 0x0431, 0x0432, 0x0433, 0x0434, 0x0435, 0x0436, 0x0437,
    0x0438, 0x0439, 0x043A, 0x043B, 0x043C, 0x043D, 0x043E, 0x043F,
    0x0440, 0x0441, 0x0442, 0x0443, 0x0444, 0x0445, 0x0446, 0x0447,
    0x0448, 0x0449, 0x044A, 0x044B, 0x044C, 0x044D, 0x044E, 0x044F,
  ];
}

/// Откуда файл (по заголовку).
enum CsvFormat {
  /// Chrome, Edge, Яндекс, Opera, Brave, Vivaldi: `name,url,username,
  /// password[,note]`.
  chromium,

  /// Firefox: `timePasswordChanged` (мс) → дата смены.
  firefox,

  /// Safari / «Пароли» Apple: `OTPAuth` отбрасывается.
  safari,
  bitwarden,
  keepass,

  /// Заголовок не узнан — ручное сопоставление колонок.
  manual,
}

/// Номера колонок по ролям. Подсказки, «Важный» и настройки из CSV не
/// берутся никогда (5.6 д) — для них ролей нет.
final class CsvColumns {
  const CsvColumns({
    required this.password,
    this.service,
    this.url,
    this.login,
    this.note,
    this.changed,
    this.changedMs = false,
    this.otp,
    this.type,
    this.group,
  });

  final int password;
  final int? service;
  final int? url;
  final int? login;
  final int? note;

  /// Дата смены пароля: мс от эпохи ([changedMs], Firefox) или ISO 8601.
  final int? changed;
  final bool changedMs;

  /// Одноразовые коды (`OTPAuth`, `TOTP`): значение отбрасывается.
  final int? otp;

  /// Bitwarden `type`: не `login` — служебная запись.
  final int? type;

  /// KeePassXC `Group`: «Recycle Bin» — служебная.
  final int? group;

  @override
  String toString() => 'CsvColumns(p$password)';
}

/// Колонка для ручного сопоставления: название (только из словаря
/// известных заголовков, иначе «Колонка N») и пример в маске (первые 2
/// символа + `•••`).
final class CsvColumnInfo {
  const CsvColumnInfo({required this.title, required this.sample});

  final String title;
  final String sample;

  @override
  String toString() => 'CsvColumnInfo($title)';
}

/// Почему пропущена строка.
enum CsvSkip {
  /// Нет пароля.
  noPassword,

  /// Служебные: заголовок внутри файла, не-логин Bitwarden, корзина
  /// KeePassXC, только одноразовый код, без названия и адреса.
  service,

  /// Нарушение пределов: длина поля, управляющие символы, направление
  /// текста.
  invalid,
}

/// Почему сопоставление не принято.
enum CsvRejection {
  /// Пароли, похоже, лежат в колонке «Название» (15.6).
  passwordInService,

  /// Пароли, похоже, лежат в колонке «Логин».
  passwordInLogin,

  /// Не выбрана колонка пароля.
  noPassword,

  /// Нет ни названия, ни адреса.
  noService,

  /// Одна колонка выбрана для двух ролей.
  sameColumn,
}

/// Итог разбора.
sealed class CsvAnalysis {
  const CsvAnalysis();
}

/// Файл не в UTF-8: спросить, читать ли как Windows-1251. Колонки — с
/// примерами в маске.
final class CsvNeedsEncoding extends CsvAnalysis {
  const CsvNeedsEncoding(this.columns);

  final List<CsvColumnInfo> columns;

  @override
  String toString() => 'CsvNeedsEncoding(${columns.length})';
}

/// Заголовок не узнан: ручное сопоставление. [suggested] — роли по
/// знакомым названиям колонок, если нашлись.
final class CsvNeedsMapping extends CsvAnalysis {
  const CsvNeedsMapping(this.columns, {this.suggested, this.header = false});

  final List<CsvColumnInfo> columns;
  final CsvColumns? suggested;

  /// Первая строка — заголовок.
  final bool header;

  @override
  String toString() => 'CsvNeedsMapping(${columns.length})';
}

/// Сопоставление не принято.
final class CsvRejected extends CsvAnalysis {
  const CsvRejected(this.reason);

  final CsvRejection reason;

  @override
  String toString() => 'CsvRejected(${reason.name})';
}

/// Запись предпросмотра: один вариант или несколько паролей для одной
/// пары (сервис, логин) — «нужно выбрать» (новее — по умолчанию).
final class CsvRecord {
  CsvRecord(this.variants, {required this.record, required this.line});

  final List<ImportItem> variants;
  int selected = 0;
  final int record;
  final int line;

  ImportItem get item => variants[selected];

  bool get needsChoice => variants.length > 1;

  void wipe() {
    for (final v in variants) {
      v.wipe();
    }
  }

  @override
  String toString() => 'CsvRecord(#$record)';
}

/// План импорта (до подтверждения хранилище не тронуто).
final class CsvPlan extends CsvAnalysis {
  CsvPlan({
    required this.format,
    required this.records,
    required this.skipped,
    required this.errors,
    this.merged = 0,
    this.otpDropped = 0,
    this.badUrls = 0,
    this.excelWarning = false,
  });

  final CsvFormat format;
  final List<CsvRecord> records;
  final Map<CsvSkip, int> skipped;

  /// «запись 14 (строка файла 17): нет пароля» — только номера.
  final List<String> errors;

  /// Одинаковые (сервис, логин, пароль) внутри файла склеены.
  final int merged;

  /// Сколько одноразовых кодов отброшено.
  final int otpDropped;

  /// Адресов с недопустимой схемой (`javascript:`, `file:`…) отброшено.
  final int badUrls;

  /// Файл, похоже, пересохраняли в Excel (Windows-1251, `;`): часть
  /// паролей могла измениться.
  final bool excelWarning;

  int get skippedTotal => skipped.values.fold<int>(0, (int a, int b) => a + b);

  void wipe() {
    for (final r in records) {
      r.wipe();
    }
  }

  @override
  String toString() => 'CsvPlan(${records.length})';
}

/// Отпечаток пароля для сравнения внутри файла (случайный ключ на сеанс
/// импорта): одинаковые пароли — одинаковые отпечатки.
typedef CsvDigest = Uint8List Function(SecretBytes password);

/// Разбор CSV из браузера или менеджера паролей (5.6, 15.6).
abstract final class CsvImport {
  /// Сколько сообщений об ошибках показывать.
  static const int maxErrors = 100;

  /// Порог 15.6 (г): больше этой доли строк «похожи на пароль» в
  /// несекретной колонке — сопоставление не принимается.
  static const double passwordShare = 0.2;

  /// Разобрать файл [raw] (байты не затираются: их владелец — вызывающий).
  /// Без [mapping] — по заголовку; не узнан (или [manual]) —
  /// [CsvNeedsMapping].
  static CsvAnalysis analyze(
    Uint8List raw, {
    required CsvDigest digest,
    required DateTime now,
    CsvEncoding encoding = CsvEncoding.utf8,
    CsvColumns? mapping,
    bool manual = false,
  }) {
    if (raw.length > CsvReader.maxBytes) {
      throw const CsvException(CsvFailure.tooLarge);
    }
    final utf8Input = encoding == CsvEncoding.utf8;
    if (utf8Input && !CsvReader.isUtf8(raw)) {
      final converted = CsvReader.windows1251ToUtf8(raw);
      try {
        final table = CsvReader.parse(converted);
        try {
          // Предпросмотр «без пароля» (5.6): у узнанной колонки пароля
          // примера нет вовсе, даже в маске.
          final header = _isHeader(table);
          final password = header
              ? (_detect(table.rows.first)?.$2 ?? _suggest(table.rows.first))
                  ?.password
              : null;
          return CsvNeedsEncoding(
            _columns(table, header, hidden: password),
          );
        } finally {
          table.wipe();
        }
      } finally {
        converted.fillRange(0, converted.length, 0);
      }
    }
    final bytes = utf8Input ? raw : CsvReader.windows1251ToUtf8(raw);
    try {
      final table = CsvReader.parse(bytes);
      try {
        final excel =
            !utf8Input || table.delimiter == 0x3B || table.delimiter == 0x09;
        final header = _isHeader(table);
        if (mapping != null) {
          return _plan(
            table,
            mapping,
            header: header,
            format: CsvFormat.manual,
            digest: digest,
            now: now,
            excel: excel,
          );
        }
        final known = header && !manual ? _detect(table.rows.first) : null;
        if (known == null) {
          return CsvNeedsMapping(
            _columns(table, header),
            suggested: header
                ? (_detect(table.rows.first)?.$2 ?? _suggest(table.rows.first))
                : null,
            header: header,
          );
        }
        return _plan(
          table,
          known.$2,
          header: true,
          format: known.$1,
          digest: digest,
          now: now,
          excel: excel,
        );
      } finally {
        table.wipe();
      }
    } finally {
      if (!utf8Input) bytes.fillRange(0, bytes.length, 0);
    }
  }

  // ------------------------------------------------------------ заголовок

  /// Известные названия колонок → роль. Название колонки показывается
  /// человеку, только если оно из этого словаря (иначе «Колонка N»: в
  /// файле без заголовка первая строка — данные, может быть и пароль).
  static const Map<String, String> _vocabulary = <String, String>{
    'name': 'service',
    'title': 'service',
    'название': 'service',
    'сервис': 'service',
    'url': 'url',
    'login_uri': 'url',
    'uri': 'url',
    'website': 'url',
    'web site': 'url',
    'сайт': 'url',
    'адрес': 'url',
    'username': 'login',
    'login_username': 'login',
    'login': 'login',
    'user': 'login',
    'email': 'login',
    'e-mail': 'login',
    'user name': 'login',
    'логин': 'login',
    'пользователь': 'login',
    'почта': 'login',
    'password': 'password',
    'login_password': 'password',
    'pass': 'password',
    'pwd': 'password',
    'пароль': 'password',
    'note': 'note',
    'notes': 'note',
    'comment': 'note',
    'comments': 'note',
    'заметка': 'note',
    'примечание': 'note',
    'комментарий': 'note',
    'timepasswordchanged': 'changedMs',
    'last modified': 'changed',
    'otpauth': 'otp',
    'totp': 'otp',
    'login_totp': 'otp',
    'type': 'type',
    'group': 'group',
    'httprealm': 'other',
    'formactionorigin': 'other',
    'guid': 'other',
    'timecreated': 'other',
    'timelastused': 'other',
    'folder': 'other',
    'favorite': 'other',
    'fields': 'other',
    'reprompt': 'other',
    'icon': 'other',
    'created': 'other',
  };

  /// Название поля, если оно — известный заголовок (сравнение байтами,
  /// без строки из произвольного поля).
  static String? _known(Uint8List field) {
    if (field.length > 40) return null;
    for (final name in _vocabulary.keys) {
      if (_equalsIgnoreCase(field, name)) return name;
    }
    return null;
  }

  static bool _equalsIgnoreCase(Uint8List field, String name) {
    var start = 0;
    var end = field.length;
    while (start < end && field[start] == 0x20) {
      start++;
    }
    while (end > start && field[end - 1] == 0x20) {
      end--;
    }
    final runes = _runes(field, start, end);
    if (runes == null) return false;
    try {
      if (runes.length != name.length) return false;
      for (var i = 0; i < runes.length; i++) {
        var r = runes[i];
        if (r >= 0x41 && r <= 0x5A) r += 0x20;
        if (r >= 0x410 && r <= 0x42F) r += 0x20;
        if (r != name.codeUnitAt(i)) return false;
      }
      return true;
    } finally {
      runes.fillRange(0, runes.length, 0);
    }
  }

  static List<int>? _runes(Uint8List bytes, int start, int end) {
    final view = Uint8List.sublistView(bytes, start, end);
    if (!CsvReader.isUtf8(view)) return null;
    final out = <int>[];
    var i = 0;
    while (i < view.length) {
      final b = view[i];
      if (b < 0x80) {
        out.add(b);
        i++;
      } else if (b < 0xE0) {
        out.add(((b & 0x1F) << 6) | (view[i + 1] & 0x3F));
        i += 2;
      } else if (b < 0xF0) {
        out.add(
          ((b & 0x0F) << 12) |
              ((view[i + 1] & 0x3F) << 6) |
              (view[i + 2] & 0x3F),
        );
        i += 3;
      } else {
        out.add(
          ((b & 0x07) << 18) |
              ((view[i + 1] & 0x3F) << 12) |
              ((view[i + 2] & 0x3F) << 6) |
              (view[i + 3] & 0x3F),
        );
        i += 4;
      }
      if (out.length > 64) return out;
    }
    return out;
  }

  /// Первая строка — заголовок, если хотя бы половина её полей —
  /// известные названия колонок.
  static bool _isHeader(CsvTable table) {
    final first = table.rows.first;
    var known = 0;
    for (final field in first) {
      if (_known(field) != null) known++;
    }
    return known > 0 && known * 2 >= first.length;
  }

  static Map<String, int> _names(List<Uint8List> header) => <String, int>{
        for (var i = header.length - 1; i >= 0; i--)
          if (_known(header[i]) case final name?) name: i,
      };

  /// Знакомый формат по заголовку.
  static (CsvFormat, CsvColumns)? _detect(List<Uint8List> header) {
    final n = _names(header);
    int? col(String name) => n[name];
    if (col('group') != null &&
        col('title') != null &&
        col('password') != null) {
      return (
        CsvFormat.keepass,
        CsvColumns(
          password: col('password')!,
          service: col('title'),
          url: col('url'),
          login: col('username'),
          note: col('notes'),
          changed: col('last modified'),
          otp: col('totp'),
          group: col('group'),
        ),
      );
    }
    if (col('login_password') != null) {
      return (
        CsvFormat.bitwarden,
        CsvColumns(
          password: col('login_password')!,
          service: col('name'),
          url: col('login_uri'),
          login: col('login_username'),
          note: col('notes'),
          otp: col('login_totp'),
          type: col('type'),
        ),
      );
    }
    if (col('password') != null &&
        col('url') != null &&
        col('username') != null &&
        (col('timepasswordchanged') != null || col('httprealm') != null)) {
      return (
        CsvFormat.firefox,
        CsvColumns(
          password: col('password')!,
          url: col('url'),
          login: col('username'),
          changed: col('timepasswordchanged'),
          changedMs: true,
        ),
      );
    }
    if (col('password') != null &&
        col('name') != null &&
        col('url') != null &&
        col('username') != null) {
      return (
        CsvFormat.chromium,
        CsvColumns(
          password: col('password')!,
          service: col('name'),
          url: col('url'),
          login: col('username'),
          note: col('note') ?? col('notes'),
        ),
      );
    }
    if (col('password') != null &&
        col('title') != null &&
        col('username') != null &&
        col('url') != null) {
      return (
        CsvFormat.safari,
        CsvColumns(
          password: col('password')!,
          service: col('title'),
          url: col('url'),
          login: col('username'),
          note: col('notes') ?? col('note'),
          otp: col('otpauth'),
        ),
      );
    }
    return null;
  }

  /// Роли по знакомым названиям для ручного сопоставления.
  static CsvColumns? _suggest(List<Uint8List> header) {
    int? role(String role) {
      for (var i = 0; i < header.length; i++) {
        final name = _known(header[i]);
        if (name != null && _vocabulary[name] == role) return i;
      }
      return null;
    }

    final password = role('password');
    if (password == null) return null;
    return CsvColumns(
      password: password,
      service: role('service'),
      url: role('url'),
      login: role('login'),
      note: role('note'),
    );
  }

  /// Колонки с примерами в маске (первые 2 символа + `•••`). У колонки
  /// [hidden] (узнанный пароль) примера нет: «скрыт».
  static List<CsvColumnInfo> _columns(
    CsvTable table,
    bool header, {
    int? hidden,
  }) {
    final width = table.rows.take(6).fold<int>(
          0,
          (int w, List<Uint8List> r) => r.length > w ? r.length : w,
        );
    final data = header ? table.rows.skip(1) : table.rows;
    return <CsvColumnInfo>[
      for (var c = 0; c < width; c++)
        CsvColumnInfo(
          title: header && c < table.rows.first.length
              ? (_titleOf(table.rows.first[c]) ?? 'Колонка ${c + 1}')
              : 'Колонка ${c + 1}',
          sample: c == hidden
              ? hiddenSample
              : maskSample(
                  data
                      .take(5)
                      .map(
                        (List<Uint8List> r) =>
                            c < r.length ? r[c] : Uint8List(0),
                      )
                      .firstWhere(
                        (Uint8List f) => f.isNotEmpty,
                        orElse: () => Uint8List(0),
                      ),
                ),
        ),
    ];
  }

  static String? _titleOf(Uint8List field) {
    final name = _known(field);
    if (name == null) return null;
    return name.length <= 1 ? name : name[0].toUpperCase() + name.substring(1);
  }

  /// Пример колонки пароля на шаге кодировки.
  static const String hiddenSample = 'скрыт';

  /// Пример значения в маске: первые 2 символа + `•••` (короче 4
  /// символов — только `•••`); управляющие символы — `•`.
  static String maskSample(Uint8List field) {
    if (field.isEmpty) return '—';
    final runes = _runes(field, 0, field.length > 64 ? 64 : field.length);
    if (runes == null || runes.length < 4) {
      runes?.fillRange(0, runes.length, 0);
      return '•••';
    }
    final out = StringBuffer();
    for (final r in runes.take(2)) {
      out.writeCharCode(
        ImportRules.hasForbiddenChars(String.fromCharCode(r)) ? 0x2022 : r,
      );
    }
    runes.fillRange(0, runes.length, 0);
    out.write('•••');
    return out.toString();
  }

  // ------------------------------------------------------------ план

  static CsvAnalysis _plan(
    CsvTable table,
    CsvColumns columns, {
    required bool header,
    required CsvFormat format,
    required CsvDigest digest,
    required DateTime now,
    required bool excel,
  }) {
    final roles = <int?>[
      columns.password,
      columns.service,
      columns.url,
      columns.login,
      columns.note,
    ].whereType<int>().toList();
    if (roles.toSet().length != roles.length) {
      return const CsvRejected(CsvRejection.sameColumn);
    }
    if (columns.service == null && columns.url == null) {
      return const CsvRejected(CsvRejection.noService);
    }
    final skipped = <CsvSkip, int>{
      for (final s in CsvSkip.values) s: 0,
    };
    final errors = <String>[];
    var otp = 0;
    var badUrls = 0;
    final start = header ? 1 : 0;
    final headerRow = header ? table.rows.first : null;
    final built = <(ImportItem, int, int, String)>[];
    final digests = <String>{};

    void skip(CsvSkip why, int record, int line, String reason) {
      skipped[why] = skipped[why]! + 1;
      if (errors.length < maxErrors) {
        errors.add('запись $record (строка файла $line): $reason');
      }
    }

    try {
      for (var r = start; r < table.rows.length; r++) {
        final row = table.rows[r];
        final record = r - start + 1;
        final line = table.lines[r];
        Uint8List field(int? c) =>
            c != null && c < row.length ? row[c] : Uint8List(0);
        String text(int? c) => utf8.decode(field(c), allowMalformed: true);

        if (table.overlong[r]) {
          skip(CsvSkip.invalid, record, line, 'слишком длинное поле');
          continue;
        }
        if (headerRow != null &&
            columns.password < headerRow.length &&
            _sameBytes(field(columns.password), headerRow[columns.password])) {
          skip(CsvSkip.service, record, line, 'заголовок внутри файла');
          continue;
        }
        final type = columns.type == null ? '' : text(columns.type).trim();
        if (type.isNotEmpty && type.toLowerCase() != 'login') {
          skip(CsvSkip.service, record, line, 'не запись входа');
          continue;
        }
        if (columns.group != null &&
            text(columns.group).trim().toLowerCase() == 'recycle bin') {
          skip(CsvSkip.service, record, line, 'корзина');
          continue;
        }
        final hasOtp = field(columns.otp).isNotEmpty;
        if (hasOtp) otp++;
        final password = field(columns.password);
        if (password.isEmpty) {
          skip(
            hasOtp ? CsvSkip.service : CsvSkip.noPassword,
            record,
            line,
            hasOtp ? 'только одноразовый код' : 'нет пароля',
          );
          continue;
        }
        if (password.length > VaultFormat.maxPassword) {
          skip(CsvSkip.invalid, record, line, 'слишком длинный пароль');
          continue;
        }
        final note = field(columns.note);
        if (note.length > VaultFormat.maxNote) {
          skip(CsvSkip.invalid, record, line, 'слишком длинная заметка');
          continue;
        }
        final urls = <String>[];
        if (columns.url != null) {
          for (final part in text(columns.url).split(RegExp(r'[,\n]'))) {
            if (part.trim().isEmpty) continue;
            final url = ImportRules.url(part);
            if (url == null) {
              badUrls++;
            } else if (urls.length < VaultFormat.maxUrls &&
                !urls.contains(url)) {
              urls.add(url);
            }
          }
        }
        final rawService = text(columns.service);
        var service = ImportRules.text(rawService, VaultFormat.maxService);
        if (service == null) {
          skip(CsvSkip.invalid, record, line, 'недопустимое название');
          continue;
        }
        if (service.isEmpty && urls.isNotEmpty) {
          service = ImportRules.serviceFor(urls.first);
        }
        if (service.isEmpty) {
          skip(CsvSkip.service, record, line, 'нет названия и адреса');
          continue;
        }
        final login =
            ImportRules.text(text(columns.login), VaultFormat.maxLogin);
        if (login == null) {
          skip(CsvSkip.invalid, record, line, 'недопустимый логин');
          continue;
        }
        final item = ImportItem(
          service: service,
          login: login,
          urls: List<String>.unmodifiable(urls),
          aliases: urls.isEmpty
              ? const <String>[]
              : ImportRules.aliasesFor(urls.first),
          password: SecretBytes.copy(password),
          note: SecretBytes.copy(note),
          changed:
              _date(text(columns.changed), ms: columns.changedMs, now: now),
          record: record,
        );
        final d = base64.encode(digest(item.password));
        digests.add(d);
        built.add((item, record, line, d));
      }

      // 15.6 (г): пароль не должен лечь в несекретное поле.
      final rejection = _passwordsInPlain(built, digests, digest);
      if (rejection != null) {
        for (final b in built) {
          b.$1.wipe();
        }
        return CsvRejected(rejection);
      }

      // Дубли внутри файла.
      final groups = <String, List<(ImportItem, int, int, String)>>{};
      for (final b in built) {
        final key = '${b.$1.service.toLowerCase()}\u0000'
            '${b.$1.login.toLowerCase()}';
        (groups[key] ??= <(ImportItem, int, int, String)>[]).add(b);
      }
      var merged = 0;
      final records = <CsvRecord>[];
      for (final group in groups.values) {
        final unique = <String, (ImportItem, int, int, String)>{};
        for (final b in group) {
          final kept = unique[b.$4];
          if (kept == null) {
            unique[b.$4] = b;
            continue;
          }
          merged++;
          // Склеенная запись — с более поздней датой.
          if (_newer(b.$1.changed, kept.$1.changed)) {
            unique[b.$4] = b;
            kept.$1.wipe();
          } else {
            b.$1.wipe();
          }
        }
        final variants = unique.values.toList()
          ..sort(
            (a, b) => _newer(a.$1.changed, b.$1.changed)
                ? -1
                : (_newer(b.$1.changed, a.$1.changed) ? 1 : a.$2 - b.$2),
          );
        records.add(
          CsvRecord(
            <ImportItem>[for (final v in variants) v.$1],
            record: variants.first.$2,
            line: variants.first.$3,
          ),
        );
      }
      records.sort((CsvRecord a, CsvRecord b) => a.record - b.record);
      return CsvPlan(
        format: format,
        records: records,
        skipped: skipped,
        errors: errors,
        merged: merged,
        otpDropped: otp,
        badUrls: badUrls,
        excelWarning: excel,
      );
    } catch (_) {
      for (final b in built) {
        b.$1.wipe();
      }
      rethrow;
    }
  }

  /// 15.6 (г): значения «Название»/«Логин» совпадают с паролями строк
  /// файла или выглядят как пароли в > 20 % строк.
  static CsvRejection? _passwordsInPlain(
    List<(ImportItem, int, int, String)> built,
    Set<String> digests,
    CsvDigest digest,
  ) {
    if (built.isEmpty) return null;
    var serviceHits = 0;
    var serviceEqual = 0;
    var loginHits = 0;
    var loginEqual = 0;
    for (final (item, _, _, _) in built) {
      if (_equalsSome(item.service, digests, digest)) {
        serviceEqual++;
      } else if (looksLikePassword(item.service)) {
        serviceHits++;
      }
      if (item.login.isNotEmpty) {
        if (_equalsSome(item.login, digests, digest)) {
          loginEqual++;
        } else if (looksLikePassword(item.login, login: true)) {
          loginHits++;
        }
      }
    }
    bool bad(int equal, int hits) =>
        equal >= 3 || (equal + hits) > built.length * passwordShare;
    if (bad(serviceEqual, serviceHits)) return CsvRejection.passwordInService;
    if (bad(loginEqual, loginHits)) return CsvRejection.passwordInLogin;
    return null;
  }

  static bool _equalsSome(String value, Set<String> digests, CsvDigest digest) {
    if (value.isEmpty) return false;
    final bytes = SecretBytes.fromText(value);
    try {
      return digests.contains(base64.encode(digest(bytes)));
    } finally {
      bytes.wipe();
    }
  }

  /// Похоже на пароль: ≥ 8 символов, ≥ 3 классов (строчные, заглавные,
  /// цифры, знаки), не e-mail, не адрес, без пробелов. Для логина знаки
  /// `._-@+` классом не считаются.
  static bool looksLikePassword(String value, {bool login = false}) {
    if (value.runes.length < 8 || value.contains(' ')) return false;
    if (RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value)) return false;
    final lower = value.toLowerCase();
    if (lower.contains('://') || lower.startsWith('www.')) return false;
    if (RegExp(r'^[a-z0-9-]+(?:\.[a-z0-9-]+)+$').hasMatch(lower)) return false;
    var classes = 0;
    if (RegExp('[a-zа-яё]').hasMatch(value)) classes++;
    if (RegExp('[A-ZА-ЯЁ]').hasMatch(value)) classes++;
    if (RegExp('[0-9]').hasMatch(value)) classes++;
    // В логине `._-@+` — обычные разделители имени, а не класс «знаки»;
    // но строчные + заглавные + цифры («Canary1980») — уже три класса.
    final symbols = login
        ? RegExp(r'[^A-Za-zА-Яа-яЁё0-9._@+\-]').hasMatch(value)
        : RegExp(r'[^A-Za-zА-Яа-яЁё0-9]').hasMatch(value);
    if (symbols) classes++;
    return classes >= 3;
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static bool _newer(DateTime? a, DateTime? b) =>
      a != null && (b == null || a.isAfter(b));

  /// Дата из файла: мс от эпохи или ISO 8601; вне 1990…завтра — `null`.
  static DateTime? _date(
    String raw, {
    required bool ms,
    required DateTime now,
  }) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    DateTime? date;
    if (ms) {
      final n = int.tryParse(value);
      if (n != null) {
        date = DateTime.fromMillisecondsSinceEpoch(n, isUtc: true);
      }
    } else {
      date = DateTime.tryParse(value);
    }
    if (date == null) return null;
    if (date.isBefore(DateTime.utc(1990)) ||
        date.isAfter(now.add(const Duration(days: 1)))) {
      return null;
    }
    return date;
  }
}
