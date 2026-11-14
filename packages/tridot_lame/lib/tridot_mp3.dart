/// Привязки dart:ffi к libtridot_mp3 (ADR-026). В приложении кодировщик
/// зовут Kotlin (JNI) и Swift (dlopen) — PCM от системного декодера не
/// ходит через Dart. Эти привязки нужны тестам на компьютере (Linux):
/// библиотеку собирает hook/build.dart.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Коды ошибок обёртки (src/tridot_lame.h).
abstract final class TlError {
  static const int arg = -1;
  static const int noMemory = -2;
  static const int params = -3;
  static const int space = -4;
  static const int encode = -5;
}

@Native<Int32 Function(Int32, Int32)>(symbol: 'tl_auto_rate')
external int tlAutoRate(int rate, int kbps);

@Native<Int32 Function(Int32, Int32, Int32, Int32, Pointer<Pointer<Void>>)>(
  symbol: 'tl_open',
)
external int tlOpen(
  int rate,
  int channels,
  int kbps,
  int outRate,
  Pointer<Pointer<Void>> handle,
);

@Native<Int32 Function(Int32)>(symbol: 'tl_out_cap')
external int tlOutCap(int frames);

@Native<Int32 Function(Int32, Int32, Int32)>(symbol: 'tl_out_cap_rate')
external int tlOutCapRate(int frames, int inRate, int outRate);

@Native<Int32 Function(Pointer<Void>, Int32)>(symbol: 'tl_out_cap_h')
external int tlOutCapH(Pointer<Void> handle, int frames);

@Native<
  Int32 Function(Pointer<Void>, Pointer<Int16>, Int32, Pointer<Uint8>, Int32)
>(symbol: 'tl_encode')
external int tlEncode(
  Pointer<Void> handle,
  Pointer<Int16> pcm,
  int frames,
  Pointer<Uint8> out,
  int cap,
);

@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32)>(
  symbol: 'tl_flush',
)
external int tlFlush(Pointer<Void> handle, Pointer<Uint8> out, int cap);

@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32)>(
  symbol: 'tl_lametag',
)
external int tlLametag(Pointer<Void> handle, Pointer<Uint8> out, int cap);

@Native<Int32 Function(Pointer<Void>)>(symbol: 'tl_out_rate')
external int tlOutRate(Pointer<Void> handle);

@Native<Void Function(Pointer<Void>)>(symbol: 'tl_close')
external void tlClose(Pointer<Void> handle);

@Native<Pointer<Utf8> Function()>(symbol: 'tl_version')
external Pointer<Utf8> tlVersion();
