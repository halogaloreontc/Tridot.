import 'dart:convert';

import '../settings/app_settings.dart' show IntentTier;

export '../settings/app_settings.dart' show IntentTier;

/// Выпуск модели понимания не подошёл: другой формат, чужой адрес, битые
/// поля (ADR-041, шаг 3).
final class IntentReleaseException implements Exception {
  const IntentReleaseException(this.message);

  final String message;

  @override
  String toString() => 'IntentReleaseException: $message';
}

/// Архив одного уровня из `latest.json`: адрес, размер и sha256 архива
/// (`tools/intent_model/pack.py`, `latest`).
final class IntentReleaseTier {
  const IntentReleaseTier({
    required this.tier,
    required this.url,
    required this.size,
    required this.sha256,
    this.file = '',
    this.title = '',
    this.threshold,
  });

  /// `light`, `accurate`, `web`.
  final String tier;

  /// Адрес архива — только выпуски Tridot на github.com
  /// ([IntentRelease.allowedPrefix]).
  final Uri url;

  /// Размер архива в байтах.
  final int size;

  /// sha256 архива: 64 строчных шестнадцатеричных знака.
  final String sha256;

  /// Имя архива: `tridot-intent-light-1.0.0.zip`.
  final String file;

  /// «Лёгкая», «Точная».
  final String title;
  final double? threshold;
}

/// `latest.json` постоянного предвыпуска `intent-latest` (ADR-041, п. 4):
/// версия и архивы уровней. Приложение читает его только по явному
/// действию пользователя: «Скачать» или «Проверить обновление».
final class IntentRelease {
  const IntentRelease({required this.version, required this.tiers});

  /// Текст `latest.json`; не тот формат или поле — [IntentReleaseException].
  factory IntentRelease.parse(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw const IntentReleaseException('latest.json: не JSON');
    }
    if (json is! Map<String, Object?>) {
      throw const IntentReleaseException('latest.json: не объект');
    }
    if (json['format'] != format) {
      throw IntentReleaseException('latest.json: формат ${json['format']}');
    }
    final version = json['version'];
    if (version is! String || parseVersion(version) == null) {
      throw const IntentReleaseException('latest.json: версия');
    }
    final raw = json['tiers'];
    if (raw is! Map<String, Object?>) {
      throw const IntentReleaseException('latest.json: нет уровней');
    }
    final tiers = <String, IntentReleaseTier>{};
    for (final MapEntry(:key, :value) in raw.entries) {
      if (value is! Map<String, Object?>) continue;
      final url = Uri.tryParse(value['url'] as String? ?? '');
      final size = value['size'];
      final sha = (value['sha256'] as String? ?? '').toLowerCase();
      if (url == null || !allowedUrl(url)) {
        throw IntentReleaseException('latest.json: адрес уровня $key');
      }
      if (size is! int || size <= 0 || size > maxArchiveBytes) {
        throw IntentReleaseException('latest.json: размер уровня $key');
      }
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) {
        throw IntentReleaseException('latest.json: sha256 уровня $key');
      }
      final threshold = value['threshold'];
      tiers[key] = IntentReleaseTier(
        tier: key,
        url: url,
        size: size,
        sha256: sha,
        file: value['file'] as String? ?? '',
        title: value['title'] as String? ?? '',
        threshold: threshold is num ? threshold.toDouble() : null,
      );
    }
    return IntentRelease(version: version, tiers: tiers);
  }

  static const String format = 'tridot-intent-latest/1';

  /// Откуда приложение берёт `latest.json`.
  static final Uri latestUrl = Uri.parse(
    'https://github.com/halogaloreontc/Tridot./releases/download/'
    'intent-latest/latest.json',
  );

  /// Архивы — только из выпусков Tridot: чужой адрес в `latest.json` не
  /// скачивается, даже если сумма совпала бы.
  static const String allowedPrefix =
      'https://github.com/halogaloreontc/Tridot./releases/download/';

  /// Переадресации GitHub для файлов выпусков (точные имена).
  static const Set<String> redirectHosts = <String>{
    'release-assets.githubusercontent.com',
    'objects.githubusercontent.com',
  };

  /// Архив больше этого не скачивается: «Точная» — ~131 МБ.
  static const int maxArchiveBytes = 512 * 1024 * 1024;

  static bool allowedUrl(Uri url) =>
      url.scheme == 'https' &&
      url.toString().startsWith(allowedPrefix) &&
      !url.path.contains('..') &&
      url.path.endsWith('.zip');

  final String version;
  final Map<String, IntentReleaseTier> tiers;

  /// Архив уровня [tier] или `null`.
  IntentReleaseTier? of(IntentTier tier) => tiers[tier.id];

  /// Есть ли версия новее [installed].
  bool newerThan(String installed) => compareVersions(version, installed) > 0;

  /// `1.2.3` → (1, 2, 3); не такая строка — `null`.
  static List<int>? parseVersion(String version) {
    final match = RegExp(r'^(\d{1,6})\.(\d{1,6})\.(\d{1,6})$').firstMatch(
      version.trim(),
    );
    if (match == null) return null;
    return <int>[for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)];
  }

  /// Сравнение версий `x.y.z`: отрицательное — [a] старше. Неразборчивая
  /// версия считается самой старой.
  static int compareVersions(String a, String b) {
    final x = parseVersion(a);
    final y = parseVersion(b);
    if (x == null || y == null) {
      return (x == null ? 0 : 1) - (y == null ? 0 : 1);
    }
    for (var i = 0; i < 3; i++) {
      if (x[i] != y[i]) return x[i] - y[i];
    }
    return 0;
  }
}
