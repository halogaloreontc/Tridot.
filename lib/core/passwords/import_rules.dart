import 'secret_bytes.dart';
import 'vault_format.dart';

/// Запись, пришедшая извне (CSV из браузера или резервная копия), уже
/// проверенная по правилам 4.3 и 15.6. Пароль и заметка — только
/// [SecretBytes]; вызывающий затирает их ([wipe]) после импорта или
/// отмены. [toString] — без содержимого.
final class ImportItem {
  ImportItem({
    required this.service,
    required this.password,
    SecretBytes? note,
    this.login = '',
    this.hint = '',
    this.urls = const <String>[],
    this.aliases = const <String>[],
    this.created,
    this.changed,
    this.sourceId,
    this.srcFp,
    this.srcFpOld = const <List<int>>[],
    this.record = 0,
  }) : note = note ?? SecretBytes.empty();

  final String service;
  final String login;

  /// Только из резервной копии (своя подсказка человека); из CSV — никогда
  /// (5.6 д).
  final String hint;
  final List<String> urls;
  final List<String> aliases;
  final SecretBytes password;
  final SecretBytes note;

  /// Даты из файла: Firefox `timePasswordChanged`, KeePassXC «Last
  /// Modified», копия. `null` — неизвестно.
  final DateTime? created;
  final DateTime? changed;

  /// id записи в копии (слияние по `entry.id`, 5.7). В CSV — `null`.
  final String? sourceId;

  /// Отпечатки из копии (ключом `k_fp` копии). Нужны только при «Создать
  /// хранилище из копии»: там `k_fp` берётся из копии, и `fp_old` верны,
  /// если `fp` сошёлся с пересчитанным.
  final List<int>? srcFp;
  final List<List<int>> srcFpOld;

  /// Номер записи в файле (с 1) — для сообщений «запись 14».
  final int record;

  void wipe() {
    password.wipe();
    note.wipe();
  }

  @override
  String toString() => 'ImportItem(#$record)';
}

/// Что пришедшая запись значит для хранилища (по `fp`).
enum ImportStatus {
  /// Такой записи нет.
  fresh,

  /// Та же запись с тем же паролем — дубль.
  same,

  /// Та же запись (id или сервис + логин), но другой пароль.
  conflict,
}

/// Что сделать с пришедшей записью. Для CSV: «пропустить / заменить /
/// оставить обе»; для копии: «текущую / из копии / оставить обе».
enum ImportChoice {
  /// Пропустить (оставить текущую).
  skip,

  /// Добавить отдельной записью («оставить обе» — по умолчанию при
  /// конфликте: неизвестно, какой пароль актуальный).
  keepBoth,

  /// Заменить текущую: прежний `fp` уходит в `fp_old`.
  replace,
}

/// Совпадение пришедшей записи с хранилищем — для предпросмотра. Без
/// паролей: только статус, id и хосты в punycode.
final class ImportMatch {
  const ImportMatch(
    this.status, {
    this.existingId,
    this.addressFrom,
    this.addressTo,
  });

  final ImportStatus status;
  final String? existingId;

  /// «адрес изменится: было … → станет …» (хосты в punycode).
  final String? addressFrom;
  final String? addressTo;

  bool get addressChanges => addressFrom != null && addressTo != null;

  /// По умолчанию: новая — добавить, дубль — пропустить, конфликт —
  /// оставить обе (никогда не «из копии»).
  ImportChoice get defaultChoice => switch (status) {
        ImportStatus.fresh => ImportChoice.keepBoth,
        ImportStatus.same => ImportChoice.skip,
        ImportStatus.conflict => ImportChoice.keepBoth,
      };

  @override
  String toString() => 'ImportMatch(${status.name})';
}

/// Решение по одной записи.
final class ImportDecision {
  const ImportDecision(this.item, this.match, this.choice);

  final ImportItem item;
  final ImportMatch match;
  final ImportChoice choice;

  @override
  String toString() => 'ImportDecision(${choice.name})';
}

/// Итог импорта: только числа.
final class ImportResult {
  const ImportResult({this.added = 0, this.replaced = 0, this.skipped = 0});

  final int added;
  final int replaced;
  final int skipped;

  @override
  String toString() => 'ImportResult($added, $replaced, $skipped)';
}

/// Правила для чужих данных (копия 4.3, враждебный CSV 15.6): длины,
/// запрещённые символы, схемы адресов, хост в punycode, понятные имена.
abstract final class ImportRules {
  /// Управляющие символы и символы направления текста (U+202E показывает
  /// «moc.knab» как «bank.com»). В названии, логине и подсказке запрещены.
  static bool hasForbiddenChars(String text) {
    for (final rune in text.runes) {
      if (rune < 0x20 || rune == 0x7F || (rune >= 0x80 && rune <= 0x9F)) {
        return true;
      }
      if ((rune >= 0x202A && rune <= 0x202E) ||
          (rune >= 0x2066 && rune <= 0x2069) ||
          rune == 0x200E ||
          rune == 0x200F ||
          rune == 0x061C) {
        return true;
      }
    }
    return false;
  }

  /// Текст поля без лишних пробелов по краям, если он годится: не длиннее
  /// [max] и без запрещённых символов. Иначе `null`.
  static String? text(String raw, int max) {
    final value = raw.trim();
    if (value.length > max || hasForbiddenChars(value)) return null;
    return value;
  }

  /// Разрешённые схемы адресов: `http`, `https`, `android://`. Остальные
  /// (`javascript:`, `file:`, `data:`, `intent:`) отбрасываются.
  static const List<String> schemes = <String>[
    'http://',
    'https://',
    'android://',
  ];

  /// Адрес, если он безопасен: разрешённая схема, без пробелов и
  /// запрещённых символов, не длиннее предела. Иначе `null`.
  static String? url(String raw) {
    final value = raw.trim();
    if (value.isEmpty || value.length > VaultFormat.maxUrl) return null;
    if (hasForbiddenChars(value) || value.contains(' ')) return null;
    final lower = value.toLowerCase();
    if (!schemes.any(lower.startsWith)) return null;
    // Браузер (WHATWG) читает «\» в http(s) как «/»: в
    // `https://evil.example\@bank.ru/` настоящий хост — evil.example.
    // Такие адреса не принимаем вовсе.
    if (!lower.startsWith('android://') && value.contains(r'\')) return null;
    if (hostOf(value).isEmpty) return null;
    return value;
  }

  /// Точки-двойники, которые браузер в хосте читает как «.»: U+3002,
  /// U+FF0E, U+FF61.
  static String _dots(String text) => text
      .replaceAll('\u3002', '.')
      .replaceAll('\uFF0E', '.')
      .replaceAll('\uFF61', '.');

  /// Хост адреса без схемы, учётных данных, порта, пути и `www.`.
  /// `android://…@com.vk.android` → `com.vk.android`.
  static String hostOf(String url) {
    var rest = _dots(url.trim().toLowerCase());
    final android = rest.startsWith('android://');
    final scheme = rest.indexOf('://');
    if (scheme >= 0) rest = rest.substring(scheme + 3);
    // В `android://<хеш>@пакет/` хеш (base64) может содержать «/».
    if (android) {
      final at = rest.lastIndexOf('@');
      if (at >= 0) rest = rest.substring(at + 1);
    }
    // Как в браузере: «\» в http(s) — тоже конец хоста.
    final end = rest.indexOf(RegExp(android ? '[/?#]' : r'[/?#\\]'));
    if (end >= 0) rest = rest.substring(0, end);
    final at = rest.lastIndexOf('@');
    if (at >= 0) rest = rest.substring(at + 1);
    if (!rest.startsWith('[')) {
      final port = rest.indexOf(':');
      if (port >= 0) rest = rest.substring(0, port);
    }
    return rest.startsWith('www.') ? rest.substring(4) : rest;
  }

  static bool isAndroid(String url) =>
      url.trim().toLowerCase().startsWith('android://');

  /// IP-адрес или `localhost`: показывается как есть с пометкой
  /// «локальный адрес».
  static bool isLocal(String host) =>
      host == 'localhost' ||
      host.endsWith('.local') ||
      host.startsWith('[') ||
      RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$').hasMatch(host);

  /// Хост для показа — в punycode (видно `xn--…` вместо кириллического
  /// двойника «сбер»). Адреса никогда не открываются автоматически.
  static String displayHost(String url) {
    final host = hostOf(url);
    if (isAndroid(url)) return host;
    return <String>[for (final label in host.split('.')) Punycode.label(label)]
        .join('.');
  }

  /// Понятное название по адресу: приложение Android — по таблице или
  /// последнему сегменту пакета, `accounts.google.com` — «Google», иначе
  /// хост без `www.`.
  static String serviceFor(String url) {
    final host = hostOf(url);
    if (isAndroid(url)) {
      final known = _apps[host];
      if (known != null) return known;
      final parts = host.split('.').where((String s) => s.isNotEmpty);
      final last = parts.isEmpty ? host : parts.last;
      return last == 'android' && parts.length > 1
          ? parts.elementAt(parts.length - 2)
          : last;
    }
    for (final MapEntry(:key, :value) in _domains.entries) {
      if (host == key || host.endsWith('.$key')) return value.$1;
    }
    return host;
  }

  /// Синонимы для поиска по адресу (таблица известных доменов).
  static List<String> aliasesFor(String url) {
    final host = hostOf(url);
    if (isAndroid(url)) return const <String>[];
    for (final MapEntry(:key, :value) in _domains.entries) {
      if (host == key || host.endsWith('.$key')) return value.$2;
    }
    return const <String>[];
  }

  /// Известные приложения Android (пакет → название).
  static const Map<String, String> _apps = <String, String>{
    'com.vkontakte.android': 'ВКонтакте',
    'ru.sberbankmobile': 'Сбербанк',
    'ru.rostel': 'Госуслуги',
    'com.idamob.tinkoff.android': 'Т-Банк',
    'ru.ozon.app.android': 'Ozon',
    'com.wildberries.ru': 'Wildberries',
    'com.avito.android': 'Авито',
    'ru.yandex.mail': 'Яндекс Почта',
    'ru.mail.mailapp': 'Почта Mail.ru',
    'com.google.android.gm': 'Gmail',
    'org.telegram.messenger': 'Telegram',
    'com.whatsapp': 'WhatsApp',
    'com.instagram.android': 'Instagram',
    'com.facebook.katana': 'Facebook',
    'com.twitter.android': 'X (Twitter)',
    'com.discord': 'Discord',
    'com.spotify.music': 'Spotify',
    'com.netflix.mediaclient': 'Netflix',
  };

  /// Известные домены → (название, синонимы).
  static const Map<String, (String, List<String>)> _domains =
      <String, (String, List<String>)>{
    'accounts.google.com': ('Google', <String>['google', 'гугл']),
    'mail.google.com': ('Gmail', <String>['gmail', 'почта']),
    'mail.yandex.ru': ('Яндекс Почта', <String>['яндекс почта', 'почта']),
    'passport.yandex.ru': ('Яндекс', <String>['яндекс']),
    'e.mail.ru': ('Почта Mail.ru', <String>['mail.ru', 'почта']),
    'account.mail.ru': ('Почта Mail.ru', <String>['mail.ru', 'почта']),
    'vk.com': ('ВКонтакте', <String>['вк', 'вконтакте', 'vk']),
    'gosuslugi.ru': ('Госуслуги', <String>['госуслуги', 'гу']),
    'online.sberbank.ru': ('Сбербанк', <String>['сбер', 'сбербанк']),
    'sberbank.ru': ('Сбербанк', <String>['сбер', 'сбербанк']),
    'tbank.ru': ('Т-Банк', <String>['т-банк', 'тинькофф']),
    'tinkoff.ru': ('Т-Банк', <String>['т-банк', 'тинькофф']),
    'ozon.ru': ('Ozon', <String>['озон', 'ozon']),
    'wildberries.ru': ('Wildberries', <String>['вб', 'wildberries']),
    'avito.ru': ('Авито', <String>['авито']),
    'github.com': ('GitHub', <String>['github', 'гитхаб']),
  };
}

/// Punycode (RFC 3492) для показа хоста: `рф` → `xn--p1ai`.
abstract final class Punycode {
  static const int _base = 36;
  static const int _tMin = 1;
  static const int _tMax = 26;
  static const int _skew = 38;
  static const int _damp = 700;

  /// Метка хоста: ASCII — как есть, иначе `xn--` + punycode.
  static String label(String label) {
    final runes = label.toLowerCase().runes.toList();
    if (runes.every((int r) => r < 0x80)) return label.toLowerCase();
    return 'xn--${encode(runes)}';
  }

  static String encode(List<int> input) {
    final out = StringBuffer();
    for (final r in input) {
      if (r < 0x80) out.writeCharCode(r);
    }
    final basic = out.length;
    var handled = basic;
    if (basic > 0) out.write('-');
    var n = 0x80;
    var delta = 0;
    var bias = 72;
    while (handled < input.length) {
      var m = 0x10FFFF + 1;
      for (final r in input) {
        if (r >= n && r < m) m = r;
      }
      delta += (m - n) * (handled + 1);
      n = m;
      for (final r in input) {
        if (r < n) delta++;
        if (r != n) continue;
        var q = delta;
        for (var k = _base;; k += _base) {
          final t = k <= bias ? _tMin : (k >= bias + _tMax ? _tMax : k - bias);
          if (q < t) break;
          out.writeCharCode(_digit(t + (q - t) % (_base - t)));
          q = (q - t) ~/ (_base - t);
        }
        out.writeCharCode(_digit(q));
        bias = _adapt(delta, handled + 1, first: handled == basic);
        delta = 0;
        handled++;
      }
      delta++;
      n++;
    }
    return out.toString();
  }

  static int _digit(int d) => d < 26 ? 0x61 + d : 0x30 + d - 26;

  static int _adapt(int delta, int points, {required bool first}) {
    var d = first ? delta ~/ _damp : delta ~/ 2;
    d += d ~/ points;
    var k = 0;
    while (d > ((_base - _tMin) * _tMax) ~/ 2) {
      d ~/= _base - _tMin;
      k += _base;
    }
    return k + (_base - _tMin + 1) * d ~/ (d + _skew);
  }
}
