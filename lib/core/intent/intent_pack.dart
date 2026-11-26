import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'intent_index.dart';
import 'intent_tokenizer.dart';

/// Пакет не подошёл: другой формат, битый файл, не та сумма.
final class IntentPackException implements Exception {
  const IntentPackException(this.message);

  final String message;

  @override
  String toString() => 'IntentPackException: $message';
}

/// Файл пакета по манифесту: размер и sha256.
final class IntentPackFile {
  const IntentPackFile({required this.size, required this.sha256});

  final int size;

  /// sha256 в шестнадцатеричном виде, нижний регистр.
  final String sha256;
}

/// `manifest.json` пакета модели понимания (`tridot-intent/1`,
/// tools/intent_model/pack.py): что за модель, порог, как готовить фразу и
/// какие файлы в пакете.
final class IntentManifest {
  const IntentManifest({
    required this.tier,
    required this.version,
    required this.threshold,
    required this.k,
    required this.dims,
    required this.maxLength,
    required this.inputs,
    required this.files,
    this.title = '',
    this.output = 'embedding',
    this.prefix = '',
    this.connectors = const <String>[],
    this.baseModel = '',
    this.baseLicense = '',
    this.corpusHash = '',
  });

  /// Текст `manifest.json`.
  factory IntentManifest.parse(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException catch (error) {
      throw IntentPackException('manifest.json: ${error.message}');
    }
    if (json is! Map<String, Object?>) {
      throw const IntentPackException('manifest.json: не объект');
    }
    final Map<String, Object?> map = json;
    if (map['format'] != format) {
      throw IntentPackException(
        'manifest.json: формат ${map['format']}, нужен $format',
      );
    }
    T need<T>(String key) {
      final value = map[key];
      if (value is T) return value;
      throw IntentPackException('manifest.json: нет поля $key');
    }

    List<String> strings(String key) => <String>[
          for (final item in (map[key] as List<Object?>?) ?? const [])
            if (item is String) item,
        ];
    final files = <String, IntentPackFile>{};
    for (final MapEntry(:key, :value)
        in need<Map<String, Object?>>('files').entries) {
      if (value is! Map<String, Object?> ||
          value['size'] is! int ||
          value['sha256'] is! String) {
        throw IntentPackException('manifest.json: файл $key без суммы');
      }
      if (key.contains('/') || key.contains(r'\') || key.startsWith('.')) {
        throw IntentPackException('manifest.json: имя файла $key');
      }
      files[key] = IntentPackFile(
        size: value['size']! as int,
        sha256: (value['sha256']! as String).toLowerCase(),
      );
    }
    final manifest = IntentManifest(
      tier: need<String>('tier'),
      title: json['title'] as String? ?? '',
      version: need<String>('version'),
      threshold: need<num>('threshold').toDouble(),
      k: need<int>('k'),
      dims: need<int>('dims'),
      maxLength: need<int>('max_length'),
      inputs: strings('inputs'),
      output: json['output'] as String? ?? 'embedding',
      prefix: json['prefix'] as String? ?? '',
      connectors: strings('connectors'),
      files: files,
      baseModel: json['base_model'] as String? ?? '',
      baseLicense: json['base_license'] as String? ?? '',
      corpusHash: json['corpus_hash'] as String? ?? '',
    );
    for (final name in required) {
      if (!files.containsKey(name)) {
        throw IntentPackException('manifest.json: в пакете нет $name');
      }
    }
    if (manifest.k < 1 || manifest.dims < 1 || manifest.maxLength < 3) {
      throw const IntentPackException('manifest.json: k, dims, max_length');
    }
    if (!manifest.inputs.contains('input_ids')) {
      throw const IntentPackException('manifest.json: нет входа input_ids');
    }
    return manifest;
  }

  static const String format = 'tridot-intent/1';

  /// Файлы, без которых пакет не работает.
  static const List<String> required = <String>[
    modelFile,
    indexFile,
    labelsFile,
    tokenizerFile,
  ];

  static const String modelFile = 'model.int8.onnx';
  static const String indexFile = 'index.bin';
  static const String labelsFile = 'labels.json';
  static const String tokenizerFile = 'tokenizer.json';
  static const String manifestFile = 'manifest.json';

  /// `light`, `accurate`, `web`.
  final String tier;

  /// «Лёгкая», «Веб-помощник».
  final String title;
  final String version;

  /// Порог сходства лучшего примера победившей метки.
  final double threshold;

  /// Сколько ближайших примеров голосуют.
  final int k;

  /// Размер вектора.
  final int dims;

  /// Длина фразы в токенах вместе со служебными.
  final int maxLength;

  /// Входы модели: `input_ids`, `attention_mask`, `token_type_ids`.
  final List<String> inputs;

  /// Выход модели — нормированный вектор.
  final String output;

  /// Подсказка модели перед фразой (`query: ` у USER-base).
  final String prefix;

  /// Навыки, которые знает индекс; пусто — все.
  final List<String> connectors;

  final Map<String, IntentPackFile> files;
  final String baseModel;
  final String baseLicense;
  final String corpusHash;

  /// Ключ модели: личные примеры, посчитанные другой моделью, считаются
  /// заново ([IntentMemory]).
  String get modelKey => '$tier@$version';
}

/// Откуда читать файлы пакета: папка на устройстве (`intent_pack_io.dart`)
/// или адрес склада в веб-помощнике (шаг 4).
abstract interface class IntentPackSource {
  /// Содержимое файла [name] пакета.
  Future<Uint8List> read(String name);
}

/// Пакет без модели: манифест, токенизатор, индекс примеров. Саму модель
/// читает среда выполнения ([IntentRuntime]) по своему пути.
final class IntentPack {
  const IntentPack({
    required this.manifest,
    required this.index,
  });

  /// Файлы больше этого проверяются по размеру, а sha256 — при установке
  /// (скачивание, шаг 3): считать 130 МБ на каждом запуске незачем.
  static const int hashLimit = 16 * 1024 * 1024;

  final IntentManifest manifest;
  final IntentIndex index;

  /// Манифест пакета [source].
  static Future<IntentManifest> readManifest(IntentPackSource source) async =>
      IntentManifest.parse(
        utf8.decode(await source.read(IntentManifest.manifestFile)),
      );

  /// Пакет из [source]: манифест, проверка файлов ([verify]), индекс и
  /// метки.
  static Future<IntentPack> load(IntentPackSource source) async {
    final manifest = await readManifest(source);
    final index = await readIndex(source, manifest);
    return IntentPack(manifest: manifest, index: index);
  }

  /// Индекс и метки пакета, проверенные по манифесту.
  static Future<IntentIndex> readIndex(
    IntentPackSource source,
    IntentManifest manifest,
  ) async {
    final bytes =
        await readVerified(source, manifest, IntentManifest.indexFile);
    final labels = await readVerified(
      source,
      manifest,
      IntentManifest.labelsFile,
    );
    final index = IntentIndex.parse(
      bytes,
      IntentLabels.parse(utf8.decode(labels)),
    );
    if (index.dims != manifest.dims) {
      throw IntentPackException(
        'index.bin: вектор ${index.dims}, в манифесте ${manifest.dims}',
      );
    }
    return index;
  }

  /// Токенизатор пакета, проверенный по манифесту.
  static Future<IntentTokenizer> readTokenizer(
    IntentPackSource source,
    IntentManifest manifest,
  ) async {
    final bytes = await readVerified(
      source,
      manifest,
      IntentManifest.tokenizerFile,
    );
    try {
      return IntentTokenizer.parse(utf8.decode(bytes));
    } on FormatException catch (error) {
      throw IntentPackException('tokenizer.json: ${error.message}');
    }
  }

  /// Файл [name], сверенный с манифестом.
  static Future<Uint8List> readVerified(
    IntentPackSource source,
    IntentManifest manifest,
    String name,
  ) async {
    final bytes = await source.read(name);
    verify(manifest, name, bytes);
    return bytes;
  }

  /// [bytes] — файл [name] из манифеста: размер и sha256.
  static void verify(IntentManifest manifest, String name, Uint8List bytes) {
    final expected = manifest.files[name];
    if (expected == null) {
      throw IntentPackException('$name нет в манифесте');
    }
    if (bytes.length != expected.size) {
      throw IntentPackException(
        '$name: ${bytes.length} байт, в манифесте ${expected.size}',
      );
    }
    if (bytes.length <= hashLimit &&
        crypto.sha256.convert(bytes).toString() != expected.sha256) {
      throw IntentPackException('$name: не та sha256');
    }
  }
}
