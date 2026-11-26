import 'dart:convert';

import '../intent/intent_release.dart';

/// Выпуск «Продвинутой» не подошёл: формат, адрес, поля (ADR-046).
final class GenReleaseException implements Exception {
  const GenReleaseException(this.message);

  final String message;

  @override
  String toString() => 'GenReleaseException: $message';
}

/// `latest.json` постоянного предвыпуска `gen-latest`: одна модель GGUF.
/// Читается только по нажатию: «Скачать», «Проверить обновление».
///
/// ```json
/// {"format": "tridot-gen-latest/1", "version": "1.0.0",
///  "model": {"url": "…/tridot-gen-1.0.0.gguf", "size": 2497000000,
///            "sha256": "…", "title": "Qwen3-4B-Instruct-2507",
///            "license": "Apache-2.0", "min_ram_mb": 7500}}
/// ```
final class GenRelease {
  const GenRelease({
    required this.version,
    required this.url,
    required this.size,
    required this.sha256,
    required this.minRamMb,
    this.title = '',
    this.license = '',
  });

  factory GenRelease.parse(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw const GenReleaseException('latest.json: не JSON');
    }
    if (json is! Map<String, Object?> || json['format'] != format) {
      throw const GenReleaseException('latest.json: формат');
    }
    final version = json['version'];
    if (version is! String || IntentRelease.parseVersion(version) == null) {
      throw const GenReleaseException('latest.json: версия');
    }
    final model = json['model'];
    if (model is! Map<String, Object?>) {
      throw const GenReleaseException('latest.json: нет модели');
    }
    final url = Uri.tryParse(model['url'] as String? ?? '');
    if (url == null || !allowedUrl(url)) {
      throw const GenReleaseException('latest.json: адрес модели');
    }
    final size = model['size'];
    if (size is! int || size <= 0 || size > maxModelBytes) {
      throw const GenReleaseException('latest.json: размер модели');
    }
    final sha = (model['sha256'] as String? ?? '').toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) {
      throw const GenReleaseException('latest.json: sha256 модели');
    }
    final ram = model['min_ram_mb'];
    return GenRelease(
      version: version,
      url: url,
      size: size,
      sha256: sha,
      minRamMb: ram is int && ram > 0 ? ram : defaultMinRamMb,
      title: model['title'] as String? ?? '',
      license: model['license'] as String? ?? '',
    );
  }

  static const String format = 'tridot-gen-latest/1';

  static final Uri latestUrl = Uri.parse(
    '${IntentRelease.allowedPrefix}gen-latest/latest.json',
  );

  /// Модель больше не скачивается: Qwen3-4B Q4_K_M — ~2,5 ГБ.
  static const int maxModelBytes = 4 * 1000 * 1000 * 1000;

  /// Памяти меньше — «Продвинутую» не предлагаем (ADR-046: от 8 ГБ;
  /// система показывает чуть меньше номинала).
  static const int defaultMinRamMb = 7000;

  static bool allowedUrl(Uri url) =>
      url.scheme == 'https' &&
      url.toString().startsWith(IntentRelease.allowedPrefix) &&
      !url.path.contains('..') &&
      url.path.endsWith('.gguf');

  final String version;
  final Uri url;
  final int size;
  final String sha256;
  final int minRamMb;
  final String title;
  final String license;

  bool newerThan(String installed) =>
      IntentRelease.compareVersions(version, installed) > 0;
}
