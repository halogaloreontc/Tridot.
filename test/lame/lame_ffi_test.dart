// Встроенный кодировщик MP3 (ADR-026) на компьютере: build-хук пакета
// tridot_lame собирает libtridot_mp3 для Linux, тест зовёт обёртку через
// dart:ffi. На Android те же функции зовёт Kotlin через JNI.
@TestOn('linux')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tridot_lame/tridot_mp3.dart';

/// Библиотека собрана и загружается (иначе тесты пропускаются с причиной).
String? _unavailable() {
  try {
    tlVersion();
    return null;
  } on Object catch (error) {
    return 'libtridot_mp3 недоступна: $error';
  }
}

/// [seconds] секунд синуса 440 Гц, int16, [channels] канала.
Int16List _sine(int rate, int channels, double seconds) {
  final frames = (rate * seconds).round();
  final pcm = Int16List(frames * channels);
  for (var i = 0; i < frames; i++) {
    final v = (math.sin(2 * math.pi * 440 * i / rate) * 12000).round();
    for (var c = 0; c < channels; c++) {
      pcm[i * channels + c] = v;
    }
  }
  return pcm;
}

/// Кодирует [pcm] целиком: MP3 и частота результата.
(Uint8List, int) _encode(
  Int16List pcm, {
  required int rate,
  required int channels,
  required int kbps,
}) {
  final handle = calloc<Pointer<Void>>();
  final frames = pcm.length ~/ channels;
  final input = calloc<Int16>(pcm.length);
  // Кусками, как приходит PCM от системного декодера.
  const chunk = 4096;
  try {
    input.asTypedList(pcm.length).setAll(0, pcm);
    expect(tlOpen(rate, channels, kbps, 0, handle), 0);
    final h = handle.value;
    // Буфер — на один кусок, по частоте MP3 (как в Kotlin и Swift).
    final cap = tlOutCapH(h, chunk);
    final out = calloc<Uint8>(cap);
    try {
      final bytes = BytesBuilder();
      for (var at = 0; at < frames; at += chunk) {
        final n = math.min(chunk, frames - at);
        final written = tlEncode(h, input + at * channels, n, out, cap);
        expect(written, greaterThanOrEqualTo(0));
        bytes.add(Uint8List.fromList(out.asTypedList(written)));
      }
      final tail = tlFlush(h, out, cap);
      expect(tail, greaterThanOrEqualTo(0));
      bytes.add(Uint8List.fromList(out.asTypedList(tail)));
      final mp3 = bytes.toBytes();
      // Кадр «Info» поверх первого кадра — как делают Kotlin и Swift.
      final tag = tlLametag(h, out, cap);
      expect(tag, greaterThan(0));
      mp3.setRange(0, tag, out.asTypedList(tag));
      final outRate = tlOutRate(h);
      return (mp3, outRate);
    } finally {
      calloc.free(out);
      tlClose(h);
    }
  } finally {
    calloc
      ..free(handle)
      ..free(input);
  }
}

/// Индекс битрейта MPEG-1 Layer III.
const Map<int, int> _mpeg1Index = <int, int>{
  128: 9,
  192: 11,
  256: 13,
  320: 14,
};

void main() {
  final skip = _unavailable();

  test(
    'версия LAME — 3.100',
    () {
      expect(tlVersion().toDartString(), '3.100');
    },
    skip: skip,
  );

  for (final kbps in <int>[128, 192, 256, 320]) {
    test(
      '1 с синуса 44,1 кГц стерео → MP3 CBR $kbps',
      () {
        final (mp3, outRate) = _encode(
          _sine(44100, 2, 1),
          rate: 44100,
          channels: 2,
          kbps: kbps,
        );
        expect(outRate, 44100);
        // Синхрослово, MPEG-1, Layer III.
        expect(mp3[0], 0xFF);
        expect(mp3[1] & 0xFE, 0xFA);
        expect(mp3[2] >> 4, _mpeg1Index[kbps]);
        expect((mp3[2] >> 2) & 3, 0, reason: '44,1 кГц');
        // Кадр «Info» (CBR) и размер около битрейта · секунда.
        expect(String.fromCharCodes(mp3.sublist(36, 40)), 'Info');
        final expected = kbps * 1000 / 8;
        expect(mp3.length, inInclusiveRange(expected * 0.9, expected * 1.3));
        // Без ID3: в начале файла нет «ID3».
        expect(String.fromCharCodes(mp3.sublist(0, 3)), isNot('ID3'));
      },
      skip: skip,
    );
  }

  test(
    'моно 48 кГц → MP3 моно',
    () {
      final (mp3, outRate) = _encode(
        _sine(48000, 1, 0.5),
        rate: 48000,
        channels: 1,
        kbps: 128,
      );
      expect(outRate, 48000);
      expect((mp3[2] >> 2) & 3, 1, reason: '48 кГц');
      expect(mp3[3] >> 6, 3, reason: 'режим «моно»');
    },
    skip: skip,
  );

  test(
    '16 кГц на 320 кбит/с — пересэмплирование в 44,1 кГц',
    () {
      final (mp3, outRate) = _encode(
        _sine(16000, 2, 1),
        rate: 16000,
        channels: 2,
        kbps: 320,
      );
      expect(outRate, 44100);
      expect(mp3[1] & 0xFE, 0xFA, reason: 'MPEG-1');
      expect(mp3[2] >> 4, 14);
    },
    skip: skip,
  );

  // Регрессия: буфер считался по кадрам входа, и на 8–24 кГц с высоким
  // битрейтом (пересэмплирование вверх) LAME не хватало места — задание
  // падало с «encoder». Кусками по 16384 кадра, буфер — на один кусок,
  // как в Mp3Sink (Kotlin) и Mp3Encoder (Swift).
  for (final (rate, kbps) in <(int, int)>[
    (8000, 128),
    (8000, 320),
    (11025, 192),
    (16000, 320),
    (22050, 320),
    (44100, 320),
  ]) {
    test(
      '$rate Гц на $kbps кбит/с кусками по 16384 кадра',
      () {
        const chunk = 16384;
        final pcm = _sine(rate, 2, 3);
        final frames = pcm.length ~/ 2;
        final handle = calloc<Pointer<Void>>();
        final input = calloc<Int16>(pcm.length);
        try {
          input.asTypedList(pcm.length).setAll(0, pcm);
          expect(tlOpen(rate, 2, kbps, 0, handle), 0);
          final h = handle.value;
          final outRate = tlOutRate(h);
          final cap = tlOutCapH(h, chunk);
          expect(cap, tlOutCapRate(chunk, rate, outRate));
          final out = calloc<Uint8>(cap);
          var total = 0;
          try {
            for (var at = 0; at < frames; at += chunk) {
              final n = math.min(chunk, frames - at);
              final written = tlEncode(h, input + at * 2, n, out, cap);
              expect(written, greaterThanOrEqualTo(0), reason: 'кадр $at');
              total += written;
            }
            final tail = tlFlush(h, out, cap);
            expect(tail, greaterThanOrEqualTo(0));
            total += tail;
          } finally {
            calloc.free(out);
            tlClose(h);
          }
          final expected = kbps * 1000 / 8 * 3;
          expect(total, inInclusiveRange(expected * 0.9, expected * 1.2));
        } finally {
          calloc
            ..free(handle)
            ..free(input);
        }
      },
      skip: skip,
    );
  }

  test(
    'ёмкость буфера растёт с пересэмплированием вверх',
    () {
      expect(tlOutCapRate(16384, 44100, 44100), tlOutCap(16384));
      expect(tlOutCapRate(16384, 96000, 48000), tlOutCap(16384));
      final up = tlOutCapRate(16384, 8000, 44100);
      expect(up, greaterThan(16384 * 44100 ~/ 8000));
      expect(tlOutCapRate(-1, 8000, 44100), TlError.arg);
      expect(tlOutCapRate(16, 0, 44100), TlError.arg);
      expect(tlOutCapH(nullptr, 16), TlError.arg);
    },
    skip: skip,
  );

  test(
    'частота MP3 по входу и битрейту',
    () {
      expect(tlAutoRate(44100, 320), 0);
      expect(tlAutoRate(48000, 128), 0);
      expect(tlAutoRate(16000, 320), 44100);
      expect(tlAutoRate(16000, 128), 0);
      expect(tlAutoRate(8000, 64), 0);
      expect(tlAutoRate(8000, 128), 44100);
      expect(tlAutoRate(96000, 128), 48000);
      expect(tlAutoRate(96000, 192), 44100);
      expect(tlAutoRate(37800, 128), 44100);
    },
    skip: skip,
  );

  test(
    'неверные аргументы — код ошибки, без падения',
    () {
      final handle = calloc<Pointer<Void>>();
      final out = calloc<Uint8>(16);
      try {
        expect(tlOpen(44100, 3, 192, 0, handle), TlError.arg);
        expect(tlOpen(44100, 2, 191, 0, handle), TlError.arg);
        expect(tlOpen(1000, 2, 192, 0, handle), TlError.arg);
        expect(tlOpen(44100, 2, 192, 12345, handle), TlError.arg);
        expect(handle.value, nullptr);
        expect(tlOpen(44100, 2, 192, 0, handle), 0);
        final pcm = calloc<Int16>(2048);
        // Мал буфер результата.
        expect(tlEncode(handle.value, pcm, 1024, out, 16), TlError.space);
        expect(tlFlush(handle.value, out, 16), TlError.space);
        expect(tlEncode(nullptr, pcm, 1024, out, 16), TlError.arg);
        calloc.free(pcm);
        tlClose(handle.value);
        tlClose(nullptr);
        expect(tlOutCap(-1), TlError.arg);
      } finally {
        calloc
          ..free(handle)
          ..free(out);
      }
    },
    skip: skip,
  );

  test(
    'обёртка собирается без предупреждений (-Wall -Wextra -Werror)',
    () {
      const root = 'packages/tridot_lame';
      final result = Process.runSync('cc', <String>[
        '-std=c99',
        '-Wall',
        '-Wextra',
        '-Werror',
        '-fsyntax-only',
        '-I$root/src',
        '-I$root/third_party/lame-3.100/include',
        '$root/src/tridot_lame.c',
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    },
    skip: _compiler() ? null : 'нет компилятора cc',
  );
}

bool _compiler() {
  try {
    return Process.runSync('cc', <String>['--version']).exitCode == 0;
  } on Object {
    return false;
  }
}
