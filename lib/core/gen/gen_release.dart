import 'dart:convert';

import '../intent/intent_release.dart';

/// Выпуск «Продвинутой» не подошёл: формат, адрес, поля (ADR-046).
final class GenReleaseException implements Exception {
  const GenReleaseException(this.message);

  final String message;

  @override
  String toString() => 'GenReleaseException: $message';
}

/// Часть файла модели: GitHub не принимает файлы выпуска больше 2 ГиБ,
/// поэтому модель (~2,9 ГБ) выложена частями, которые склеиваются по
/// порядку.
final class GenPart {
  const GenPart({required this.url, required this.size, required this.sha256});

  final Uri url;
  final int size;
  final String sha256;
}

/// `latest.json` постоянного предвыпуска `gen-latest`: одна модель GGUF
/// частями. Читается только по нажатию: «Скачать», «Проверить обновление».
///
/// ```json
/// {"format": "tridot-gen-latest/1", "version": "1.0.0",
///  "model": {"size": 2497000000, "sha256": "…",
///            "parts": [{"url": "…/tridot-gen-1.0.0.gguf.001", "size": …,
///                       "sha256": "…"}, …],
///            "title": "Qwen3-4B-Instruct-2507", "license": "Apache-2.0",
///            "min_ram_mb": 7000}}
/// ```
final class GenRelease {
  const GenRelease({
    required this.version,
    required this.size,
    required this.sha256,
    required this.parts,
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
    final size = _size(model['size'], maxModelBytes, 'размер модели');
    final sha = _sha(model['sha256'], 'sha256 модели');
    final raw = model['parts'];
    if (raw is! List<Object?> || raw.isEmpty || raw.length > maxParts) {
      throw const GenReleaseException('latest.json: части модели');
    }
    final parts = <GenPart>[];
    for (final part in raw) {
      if (part is! Map<String, Object?>) {
        throw const GenReleaseException('latest.json: часть модели');
      }
      final url = Uri.tryParse(part['url'] as String? ?? '');
      if (url == null || !allowedUrl(url)) {
        throw const GenReleaseException('latest.json: адрес части');
      }
      parts.add(
        GenPart(
          url: url,
          size: _size(part['size'], maxPartBytes, 'размер части'),
          sha256: _sha(part['sha256'], 'sha256 части'),
        ),
      );
    }
    if (parts.fold<int>(0, (a, b) => a + b.size) != size) {
      throw const GenReleaseException('latest.json: части не складываются');
    }
    final ram = model['min_ram_mb'];
    return GenRelease(
      version: version,
      size: size,
      sha256: sha,
      parts: parts,
      minRamMb: ram is int && ram > 0 ? ram : defaultMinRamMb,
      title: model['title'] as String? ?? '',
      license: model['license'] as String? ?? '',
    );
  }

  static int _size(Object? v, int max, String what) {
    if (v is! int || v <= 0 || v > max) {
      throw GenReleaseException('latest.json: $what');
    }
    return v;
  }

  static String _sha(Object? v, String what) {
    final sha = (v as String? ?? '').toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) {
      throw GenReleaseException('latest.json: $what');
    }
    return sha;
  }

  static const String format = 'tridot-gen-latest/1';

  static final Uri latestUrl = Uri.parse(
    '${IntentRelease.allowedPrefix}gen-latest/latest.json',
  );

  /// Модель больше не скачивается: Qwen3-4B Q5_K_M — ~2,9 ГБ.
  static const int maxModelBytes = 4 * 1000 * 1000 * 1000;

  /// Памяти меньше — «Продвинутую» не предлагаем (ADR-046: от 8 ГБ;
  /// система показывает чуть меньше номинала).
  static const int defaultMinRamMb = 7000;

  /// Часть — до 2 ГиБ (предел файла выпуска GitHub).
  static const int maxPartBytes = 2 * 1024 * 1024 * 1024;
  static const int maxParts = 8;

  static bool allowedUrl(Uri url) =>
      url.scheme == 'https' &&
      url.toString().startsWith(IntentRelease.allowedPrefix) &&
      !url.path.contains('..') &&
      RegExp(r'\.gguf\.\d{3}$').hasMatch(url.path);

  final String version;

  /// Файл модели целиком: размер и sha256.
  final int size;
  final String sha256;
  final List<GenPart> parts;
  final int minRamMb;
  final String title;
  final String license;

  bool newerThan(String installed) =>
      IntentRelease.compareVersions(version, installed) > 0;
}
