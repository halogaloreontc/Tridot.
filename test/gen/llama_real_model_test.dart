import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/gen/llama_gen_model.dart';
import 'package:local_assistant/core/gen/table_ask.dart';
import 'package:local_assistant/core/gen/table_data.dart';

/// Настоящая Qwen3-4B через обёртку llama.cpp (ADR-046), если собраны
/// библиотека и скачана модель:
///
/// ```bash
/// tool/fetch_llama.sh
/// cmake -S native/tridot_llama -B build/tridot_llama -DCMAKE_BUILD_TYPE=Release
/// cmake --build build/tridot_llama -j
/// TRIDOT_GEN_MODEL=~/.cache/tridot-gen/Qwen3-4B-Instruct-2507-Q4_K_M.gguf \
///   flutter test --no-pub test/gen/llama_real_model_test.dart
/// ```
///
/// В CI нет ни того, ни другого — тест пропускается.
void main() {
  final lib = File('build/tridot_llama/libtridot_llama.so');
  final model = Platform.environment['TRIDOT_GEN_MODEL'];
  final skip = !lib.existsSync()
      ? 'нет build/tridot_llama/libtridot_llama.so'
      : model == null || !File(model).existsSync()
          ? 'нет модели (TRIDOT_GEN_MODEL)'
          : false;

  test(
    'вопрос к таблице: грамматика, запрос, ответ считает код',
    () async {
      final gen = await LlamaGenModel.open(model!, library: lib.absolute.path);
      addTearDown(gen.close);
      final table = TableData.fromCsv(
        File('tools/gen_model/eval/tables/deliveries.csv').readAsBytesSync(),
      )!;
      final a = await TableAsk.ask(
        gen,
        table,
        'на какую сумму поставила ООО Ромашка?',
      );
      expect(a?.value, 15500);
      final b = await TableAsk.ask(gen, table, 'сколько было поставок?');
      expect(b?.value, 7);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'нет файла модели — понятная ошибка',
    () async {
      await expectLater(
        LlamaGenModel.open('/нет/такой.gguf', library: lib.absolute.path),
        throwsA(isA<GenModelException>()),
      );
    },
    skip:
        lib.existsSync() ? false : 'нет build/tridot_llama/libtridot_llama.so',
  );
}
