import 'dart:math' as math;
import 'dart:typed_data';

import 'intent_pack.dart';
import 'intent_tokenizer.dart';

/// Кодировщик фраз модели понимания (ADR-041): фразы → нормированные
/// векторы. Разные среды подключают своё: приложение — onnxruntime через
/// FFI в отдельном изоляте (`lib/app/intent/`), веб-помощник —
/// onnxruntime-web (шаг 4), тесты — поддельный кодировщик.
abstract interface class IntentEncoder {
  /// Размер вектора.
  int get dims;

  /// Векторы [texts] в том же порядке. Фраза — как её сказал пользователь:
  /// подсказку модели (`prefix` манифеста) добавляет кодировщик.
  Future<List<Float32List>> embed(List<String> texts);

  /// Освободить модель. После этого [embed] не вызывают.
  Future<void> close();
}

/// Среда выполнения модели: пакет токенов → векторы `[rows, dims]` с
/// выхода `embedding`. Пулинг и нормировка уже внутри графа.
abstract interface class IntentRuntime {
  Future<Float32List> run(TokenBatch batch, List<String> inputs);

  Future<void> close();
}

/// [IntentEncoder] из токенизатора пакета и [IntentRuntime]: подсказка
/// модели, усечение до `max_length`, пакеты по [batchSize] фраз. Один и
/// тот же для приложения и веб-помощника — у них разная только среда.
///
/// По умолчанию — по одной фразе: динамическое int8 считает масштаб по
/// всему пакету, и дополнение чужих фраз чуть сдвигает вектор. Порог
/// подобран на векторах по одной фразе.
final class TokenizedEncoder implements IntentEncoder {
  TokenizedEncoder({
    required this.tokenizer,
    required this.runtime,
    required this.manifest,
    this.batchSize = 1,
  });

  final IntentTokenizer tokenizer;
  final IntentRuntime runtime;
  final IntentManifest manifest;
  final int batchSize;

  @override
  int get dims => manifest.dims;

  @override
  Future<List<Float32List>> embed(List<String> texts) async {
    final out = <Float32List>[];
    for (var start = 0; start < texts.length; start += batchSize) {
      final part = texts.sublist(
        start,
        math.min(start + batchSize, texts.length),
      );
      final batch = TokenBatch.of(
        <List<int>>[
          for (final text in part)
            tokenizer.encode(
              '${manifest.prefix}$text',
              maxLength: manifest.maxLength,
            ),
        ],
        padId: tokenizer.padId,
      );
      final flat = await runtime.run(batch, manifest.inputs);
      if (flat.length != part.length * dims) {
        throw IntentPackException(
          'модель вернула ${flat.length} чисел вместо ${part.length * dims}',
        );
      }
      for (var row = 0; row < part.length; row++) {
        out.add(Float32List.sublistView(flat, row * dims, (row + 1) * dims));
      }
    }
    return out;
  }

  @override
  Future<void> close() => runtime.close();
}
