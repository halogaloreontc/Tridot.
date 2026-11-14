// Сборка libtridot_mp3 (ADR-026): LAME 3.100 из third_party и обёртка
// src/tridot_lame.c — одной разделяемой библиотекой. Динамическая сборка:
// библиотеку можно пересобрать и заменить (LGPL-2.0-or-later).
//
// - Android — со шимом JNI (src/tridot_lame_jni.c): её грузит Kotlin;
// - macOS — её грузит Swift через dlopen (ADR-026, шаг S3);
// - Linux — только для тестов на компьютере (dart:ffi,
//   lib/tridot_mp3.dart).
//
// На Windows (там MP3 делает скачиваемый ffmpeg), iOS и прочих — ничего не
// собирается.
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const String _lame = 'third_party/lame-3.100';

/// Файлы libmp3lame, которые нужны кодировщику (без декодера mpglib и
/// без ассемблера).
const List<String> _lameSources = <String>[
  'bitstream',
  'encoder',
  'fft',
  'gain_analysis',
  'id3tag',
  'lame',
  'newmdct',
  'presets',
  'psymodel',
  'quantize',
  'quantize_pvt',
  'reservoir',
  'set_get',
  'tables',
  'takehiro',
  'util',
  'vbrquantize',
  'VbrTag',
  'version',
];

void main(List<String> args) async {
  await build(args, (BuildInput input, BuildOutputBuilder output) async {
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    if (os != OS.android && os != OS.macOS && os != OS.linux) return;
    // Только предупреждения и ошибки: команды компилятора не печатаются.
    final logger = Logger('tridot_lame')
      ..onRecord.listen((LogRecord record) {
        if (record.level >= Level.WARNING) stderr.writeln(record.message);
      });
    await CBuilder.library(
      name: 'tridot_mp3',
      assetName: 'tridot_mp3.dart',
      sources: <String>[
        'src/tridot_lame.c',
        if (os == OS.android) 'src/tridot_lame_jni.c',
        for (final file in _lameSources) '$_lame/libmp3lame/$file.c',
      ],
      includes: <String>['src', '$_lame/include', '$_lame/libmp3lame'],
      defines: <String, String?>{
        'STDC_HEADERS': '1',
        'HAVE_STDINT_H': '1',
        'HAVE_STDLIB_H': '1',
        'HAVE_STRING_H': '1',
        'HAVE_LIMITS_H': '1',
        'HAVE_ERRNO_H': '1',
        'ieee754_float32_t': 'float',
        'TAKEHIRO_IEEE754_HACK': '1',
        'USE_FAST_LOG': '1',
      },
      // Предупреждения исходников LAME не наши: обёртка проверяется
      // отдельно (test/lame/lame_ffi_test.dart собирает её с -Wall).
      flags: <String>['-w'],
      libraries: <String>['m'],
      optimizationLevel: OptimizationLevel.o2,
    ).run(input: input, output: output, logger: logger);
  });
}
