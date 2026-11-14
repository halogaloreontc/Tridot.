import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Привязка `dart:ffi` к C API Vosk (`vosk_api.h`, Apache-2.0), ADR-023.
///
/// Только нужные голосовому вводу функции. `libvosk.so` приходит из AAR
/// `com.alphacephei:vosk-android` (только arm64-v8a); Java-классы AAR не
/// используются. На других платформах библиотеки нет — [tryOpen] вернёт
/// `null`, и голосовой ввод скрыт.
final class VoskBindings {
  VoskBindings._(DynamicLibrary library)
      : setLogLevel =
            library.lookupFunction<Void Function(Int32), void Function(int)>(
          'vosk_set_log_level',
        ),
        modelNew = library.lookupFunction<Pointer<Void> Function(Pointer<Utf8>),
            Pointer<Void> Function(Pointer<Utf8>)>('vosk_model_new'),
        modelFree = library.lookupFunction<Void Function(Pointer<Void>),
            void Function(Pointer<Void>)>('vosk_model_free'),
        recognizerNew = library.lookupFunction<
            Pointer<Void> Function(Pointer<Void>, Float),
            Pointer<Void> Function(Pointer<Void>, double)>(
          'vosk_recognizer_new',
        ),
        recognizerFree = library.lookupFunction<Void Function(Pointer<Void>),
            void Function(Pointer<Void>)>('vosk_recognizer_free'),
        acceptWaveform = library.lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32),
            int Function(Pointer<Void>, Pointer<Uint8>, int)>(
          'vosk_recognizer_accept_waveform',
        ),
        result = library.lookupFunction<Pointer<Utf8> Function(Pointer<Void>),
            Pointer<Utf8> Function(Pointer<Void>)>('vosk_recognizer_result'),
        partialResult = library.lookupFunction<
            Pointer<Utf8> Function(Pointer<Void>),
            Pointer<Utf8> Function(Pointer<Void>)>(
          'vosk_recognizer_partial_result',
        ),
        finalResult = library.lookupFunction<
            Pointer<Utf8> Function(Pointer<Void>),
            Pointer<Utf8> Function(Pointer<Void>)>(
          'vosk_recognizer_final_result',
        ),
        reset = library.lookupFunction<Void Function(Pointer<Void>),
            void Function(Pointer<Void>)>('vosk_recognizer_reset');

  /// Имя библиотеки на Android.
  static const String libraryName = 'libvosk.so';

  /// Открывает библиотеку и находит функции; `null` — нет библиотеки или
  /// функции (другая платформа, другая сборка).
  static VoskBindings? tryOpen([String name = libraryName]) {
    try {
      return VoskBindings._(DynamicLibrary.open(name));
    } on Object {
      return null;
    }
  }

  /// `vosk_set_log_level(-1)` — Kaldi и Vosk ничего не пишут в logcat.
  final void Function(int level) setLogLevel;

  /// `NULL`, если модель не загрузилась.
  final Pointer<Void> Function(Pointer<Utf8> path) modelNew;
  final void Function(Pointer<Void> model) modelFree;
  final Pointer<Void> Function(Pointer<Void> model, double sampleRate)
      recognizerNew;
  final void Function(Pointer<Void> recognizer) recognizerFree;

  /// 1 — конец фразы (готов [result]), 0 — продолжается
  /// ([partialResult]), -1 — ошибка. [length] — в байтах, PCM 16 бит.
  final int Function(Pointer<Void> recognizer, Pointer<Uint8> data, int length)
      acceptWaveform;

  /// JSON `{"text": "..."}`; строка принадлежит распознавателю.
  final Pointer<Utf8> Function(Pointer<Void> recognizer) result;

  /// JSON `{"partial": "..."}`.
  final Pointer<Utf8> Function(Pointer<Void> recognizer) partialResult;

  /// JSON `{"text": "..."}` с остатком речи.
  final Pointer<Utf8> Function(Pointer<Void> recognizer) finalResult;
  final void Function(Pointer<Void> recognizer) reset;
}
