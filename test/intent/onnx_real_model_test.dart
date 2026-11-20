import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/intent/onnx_intent_encoder.dart';
import 'package:local_assistant/core/intent/intent_fallback.dart';
import 'package:local_assistant/core/intent/intent_io.dart';

import 'local_packs.dart';

/// Настоящая модель «Лёгкой» через ONNX Runtime (ADR-041), если пакет
/// собран и распакован локально, а библиотека onnxruntime находится:
///
/// ```bash
/// TRIDOT_INTENT_PACKS=<папка с light/> \
/// LD_LIBRARY_PATH=~/.pub-cache/hosted/pub.dev/onnxruntime_v2-1.23.2+2/linux \
///   flutter test --no-pub test/intent/onnx_real_model_test.dart
/// ```
///
/// В CI пакета нет — тест пропускается. Эталон — Python-сборка шага 1
/// (`test/fixtures/intent/light_expect.json`): тот же пакет, onnxruntime на
/// CPU, kNN из tools/intent_model/knn.py.
void main() {
  final dir = localPackDir('light');
  final library = _nativeLibrary();
  final skip = dir == null
      ? 'пакет light не распакован (TRIDOT_INTENT_PACKS)'
      : library == null
          ? 'нет libonnxruntime (LD_LIBRARY_PATH)'
          : false;
  final expected = jsonDecode(
    File('test/fixtures/intent/light_expect.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final rows =
      (expected['rows']! as List<Object?>).cast<Map<String, Object?>>();

  test(
    'векторы и подсказки — как у Python-сборки',
    () async {
      final source = DirectoryPackSource(dir!.path);
      final pack = await IntentPack.load(source);
      expect(pack.manifest.version, expected['version']);
      final encoder = await OnnxIntentEncoder.open(dir.path, pack.manifest);
      addTearDown(encoder.close);
      final model = IntentModel(
        manifest: pack.manifest,
        index: pack.index,
        encoder: encoder,
      );
      final fallback = IntentFallback(
        model: model,
        memory: IntentMemory(blocks: (_) => false),
        blocks: (_) => false,
      );
      final texts = <String>[for (final row in rows) row['text']! as String];
      // По одной фразе, как на устройстве: динамическое int8 считает
      // масштаб по всему пакету, и дополнение меняет числа.
      final watch = Stopwatch()..start();
      final vectors = <Float32List>[
        for (final text in texts) (await encoder.embed(<String>[text])).single,
      ];
      watch.stop();
      for (final (index, row) in rows.indexed) {
        final head = (row['head']! as List<Object?>).cast<num>();
        for (var d = 0; d < head.length; d++) {
          expect(
            vectors[index][d],
            closeTo(head[d], 0.005),
            reason: texts[index],
          );
        }
        final vote = pack.index.vote(vectors[index], model.k);
        final pred = pack.index.labels[vote.winner].id;
        expect(pred, row['pred'], reason: texts[index]);
        final sim = (row['sim']! as num).toDouble();
        expect(vote.similarity, closeTo(sim, 0.005), reason: texts[index]);
        if ((sim - model.threshold).abs() > 0.01) {
          final s = fallback.decide(texts[index], vectors[index], model);
          expect(s != null, row['suggests'], reason: texts[index]);
          if (s != null) expect(s.first.id, pred);
        }
      }
      // ignore: avoid_print
      print('${texts.length} фраз за ${watch.elapsedMilliseconds} мс');
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

/// Библиотека ONNX Runtime пакета onnxruntime_v2 для Linux или `null`.
DynamicLibrary? _nativeLibrary() {
  if (!Platform.isLinux) return null;
  try {
    return DynamicLibrary.open('libonnxruntime.so.1.22.0');
  } on Object {
    return null;
  }
}
